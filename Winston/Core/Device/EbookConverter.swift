import Foundation
import OSLog
import os
import Darwin

nonisolated enum EbookConverter {
    enum ConversionError: Error, LocalizedError {
        case converterNotFound
        case conversionFailed(status: Int32)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .converterNotFound:
                "ebook-convert not found \u{2014} install calibre (calibre-ebook.com) to convert EPUBs for Kindle"
            case .conversionFailed(let status):
                "ebook-convert failed (exit code \(status))"
            case .timedOut:
                "ebook-convert took too long and was stopped"
            }
        }
    }

    nonisolated(unsafe) static var conversionTimeout: TimeInterval = 180

    enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
        case azw3, epub, mobi, pdf

        var id: Self { self }
        var ext: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    private static let kindleNativeFormats: Set<String> = ["azw", "azw3", "mobi", "pdf", "txt", "kfx"]

    static func needsConversion(format: String) -> Bool {
        !kindleNativeFormats.contains(format.lowercased())
    }

    nonisolated(unsafe) static var calibreExecutableOverride: URL??

    static func calibreExecutableURL() -> URL? {
        if let override = calibreExecutableOverride { return override }
        let candidates = [
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            "/opt/homebrew/bin/ebook-convert",
            "/usr/local/bin/ebook-convert",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isCalibreAvailable: Bool {
        calibreExecutableURL() != nil
    }

    private static let nativeMOBISources: Set<String> = ["epub", "txt", "html", "htm", "pdf"]

    static func canConvertNatively(from sourceFormat: String, to format: OutputFormat) -> Bool {
        format == .mobi && nativeMOBISources.contains(sourceFormat.lowercased())
    }

    static func canConvert(from sourceFormat: String, to format: OutputFormat) -> Bool {
        guard sourceFormat.lowercased() != format.ext else { return false }
        return canConvertNatively(from: sourceFormat, to: format) || isCalibreAvailable
    }

    static var prefersAZW3ForKindle: Bool {
        UserDefaults.standard.bool(forKey: "preferKindleAZW3")
    }

    // Kindles render AZW3 and complete MOBI6; a raw EPUB is never sent as-is.
    static func kindleTarget(forFormat sourceFormat: String) -> OutputFormat {
        if prefersAZW3ForKindle, isCalibreAvailable { return .azw3 }
        return nativeMOBISources.contains(sourceFormat.lowercased()) ? .mobi : .azw3
    }

    static func canConvertForKindle(_ sourceFormat: String) -> Bool {
        canConvert(from: sourceFormat, to: kindleTarget(forFormat: sourceFormat))
    }

    static func convertForKindle(_ source: URL) async throws -> URL {
        try await convert(source, to: kindleTarget(forFormat: source.pathExtension))
    }

    // Off-main; awaits ebook-convert via terminationHandler — don't wrap in Task.detached or semaphores.
    @concurrent
    static func convert(_ source: URL, to format: OutputFormat) async throws -> URL {
        let ext = source.pathExtension.lowercased()
        let signposter = Log.conversionSignposter
        let interval = signposter.beginInterval(
            "Convert", id: signposter.makeSignpostID(),
            "\(ext, privacy: .public) → \(format.ext, privacy: .public)"
        )
        defer { signposter.endInterval("Convert", interval) }

        Log.conversion.info(
            "Converting \(source.lastPathComponent, privacy: .public) (\(ext, privacy: .public) → \(format.ext, privacy: .public))"
        )
        do {
            let output = try await route(source, ext: ext, to: format)
            Log.conversion.notice("Converted → \(output.lastPathComponent, privacy: .public)")
            return output
        } catch {
            Log.conversion.error(
                "Conversion of \(source.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private static func route(_ source: URL, ext: String, to format: OutputFormat) async throws -> URL {
        if canConvertNatively(from: ext, to: format) {
            switch ext {
            case "epub":
                return try MOBIWriter.write(epub: source)
            case "txt":
                return try MOBIWriter.write(document: TextReader.read(source), source: source)
            case "html", "htm":
                return try MOBIWriter.write(document: HTMLReader.read(source), source: source)
            case "pdf":
                return try MOBIWriter.write(document: PDFReader.read(source), source: source)
            default:
                break
            }
        }
        return try await convertViaCalibre(source, to: format)
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let group = OSAllocatedUnfairLock<Int32?>(initialState: nil)

        init(process: Process) {
            self.process = process
        }

        func captureProcessGroup() {
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            if setpgid(pid, pid) == 0 || getpgid(pid) == pid {
                group.withLock { $0 = pid }
            }
        }

        func signal(_ signal: Int32) {
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            if let groupID = group.withLock({ $0 }) {
                _ = kill(-groupID, signal)
            } else {
                _ = kill(pid, signal)
            }
        }
    }

    private final class ProcessRunState: @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Int32, any Error>?
            var result: Result<Int32, any Error>?
            var requestedError: (any Error)?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func install(_ continuation: CheckedContinuation<Int32, any Error>) -> Bool {
            let result = state.withLock { state -> Result<Int32, any Error>? in
                if let result = state.result { return result }
                guard state.continuation == nil else { return nil }
                state.continuation = continuation
                return nil
            }
            if let result { continuation.resume(with: result); return false }
            return true
        }

        func complete(_ result: Result<Int32, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<Int32, any Error>? in
                guard state.result == nil else { return nil }
                state.result = result
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(with: result)
        }

        func requestTermination(_ error: any Error) -> Bool {
            state.withLock { state in
                guard state.result == nil, state.requestedError == nil else { return false }
                state.requestedError = error
                return true
            }
        }

        func completeAfterTermination(status: Int32) {
            let result = state.withLock { state -> Result<Int32, any Error>? in
                guard state.result == nil else { return nil }
                return state.requestedError.map(Result.failure) ?? .success(status)
            }
            if let result { complete(result) }
        }

        func completeRequestedTermination() {
            let error = state.withLock { $0.requestedError }
            if let error { complete(.failure(error)) }
        }

        var terminationWasRequested: Bool {
            state.withLock { $0.requestedError != nil }
        }

        var isCompleted: Bool {
            state.withLock { $0.result != nil }
        }
    }

    private static func convertViaCalibre(_ source: URL, to format: OutputFormat) async throws -> URL {
        guard let executable = calibreExecutableURL() else {
            Log.conversion.error("Calibre not installed; cannot convert \(source.lastPathComponent, privacy: .public)")
            throw ConversionError.converterNotFound
        }
        Log.conversion.info("Falling back to Calibre (\(executable.lastPathComponent, privacy: .public)) for \(source.lastPathComponent, privacy: .public)")

        let outputDir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConversions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputName = "\(UUID().uuidString)-\(source.deletingPathExtension().lastPathComponent).\(format.ext)"
        let output = outputDir.appending(path: outputName)
        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: output) }
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            source.path(percentEncoded: false),
            output.path(percentEncoded: false),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let status = try await run(process, timeout: conversionTimeout)

        guard status == 0,
              FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            Log.conversion.error("Calibre exited with status \(status)")
            throw ConversionError.conversionFailed(status: status)
        }
        succeeded = true
        return output
    }

    private static func run(_ process: Process, timeout: TimeInterval) async throws -> Int32 {
        let box = ProcessBox(process: process)
        let state = ProcessRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    guard state.requestTermination(ConversionError.timedOut) else { return }
                    stop(box, state: state)
                    Log.conversion.error("Calibre timed out after \(Int(timeout))s and was stopped")
                }

                process.terminationHandler = { finished in
                    watchdog.cancel()
                    state.completeAfterTermination(status: finished.terminationStatus)
                }

                guard !state.isCompleted else {
                    watchdog.cancel()
                    return
                }
                do {
                    try process.run()
                    box.captureProcessGroup()
                    if state.terminationWasRequested { stop(box, state: state) }
                } catch {
                    watchdog.cancel()
                    state.complete(.failure(error))
                }
            }
        } onCancel: {
            guard state.requestTermination(CancellationError()) else { return }
            stop(box, state: state)
        }
    }

    private static func stop(_ box: ProcessBox, state: ProcessRunState) {
        guard box.process.isRunning else {
            state.completeRequestedTermination()
            return
        }
        box.signal(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if box.process.isRunning { box.signal(SIGKILL) }
        }
    }
}
