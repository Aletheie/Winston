import Foundation
import OSLog
import os

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

    private struct ProcessBox: @unchecked Sendable {
        let process: Process
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

        let outputName = source.deletingPathExtension().lastPathComponent + ".\(format.ext)"
        let output = outputDir.appending(path: outputName)
        try? FileManager.default.removeItem(at: output)

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
        return output
    }

    private static func run(_ process: Process, timeout: TimeInterval) async throws -> Int32 {
        let box = ProcessBox(process: process)
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func claimResume() -> Bool {
                resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
            }

            let watchdog = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, claimResume() else { return }
                box.process.terminate()
                Log.conversion.error("Calibre timed out after \(Int(timeout))s and was stopped")
                continuation.resume(throwing: ConversionError.timedOut)
            }

            process.terminationHandler = { finished in
                watchdog.cancel()
                guard claimResume() else { return }
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                if claimResume() {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
