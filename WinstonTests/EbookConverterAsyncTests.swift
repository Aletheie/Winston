import Testing
import Foundation
@testable import Winston

@Suite(.serialized)
struct EbookConverterAsyncTests {

    private func makeScript(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonCalibreFake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "ebook-convert")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path(percentEncoded: false))
        return script
    }

    private func makeFB2Source() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonFB2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appending(path: "book.fb2")
        try Data("<fake fb2/>".utf8).write(to: source)
        return source
    }

    private func withOverrides(
        executable: URL?, timeout: TimeInterval = 180,
        run: () async throws -> Void
    ) async rethrows {
        EbookConverter.calibreExecutableOverride = .some(executable)
        EbookConverter.conversionTimeout = timeout
        defer {
            EbookConverter.calibreExecutableOverride = nil
            EbookConverter.conversionTimeout = 180
        }
        try await run()
    }

    @Test func successfulConversionReturnsOutputFile() async throws {
        let script = try makeScript(#"cp "$1" "$2""#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        try await withOverrides(executable: script) {
            let output = try await EbookConverter.convert(source, to: .epub)
            defer { try? FileManager.default.removeItem(at: output) }
            #expect(output.lastPathComponent.hasSuffix("-book.epub"))
            #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        }
    }

    @Test func concurrentSameBasenameConversionsUseDistinctOutputs() async throws {
        let script = try makeScript(#"cp "$1" "$2""#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let first = try makeFB2Source()
        let second = try makeFB2Source()
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        try await withOverrides(executable: script) {
            async let firstOutput = EbookConverter.convert(first, to: .epub)
            async let secondOutput = EbookConverter.convert(second, to: .epub)
            let outputs = try await [firstOutput, secondOutput]
            defer { outputs.forEach { try? FileManager.default.removeItem(at: $0) } }

            #expect(outputs[0] != outputs[1])
            #expect(try Data(contentsOf: outputs[0]) != Data(contentsOf: outputs[1]))
        }
    }

    @Test func nonZeroExitThrowsConversionFailedWithStatus() async throws {
        let script = try makeScript("exit 3")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        await withOverrides(executable: script) {
            do {
                _ = try await EbookConverter.convert(source, to: .epub)
                Issue.record("expected conversionFailed")
            } catch let error as EbookConverter.ConversionError {
                guard case .conversionFailed(let status) = error else {
                    Issue.record("expected conversionFailed, got \(error)")
                    return
                }
                #expect(status == 3)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func stalledConverterIsTerminatedAfterTimeout() async throws {
        let script = try makeScript("sleep 30")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let clock = ContinuousClock()
        let start = clock.now
        await withOverrides(executable: script, timeout: 1) {
            do {
                _ = try await EbookConverter.convert(source, to: .epub)
                Issue.record("expected timedOut")
            } catch let error as EbookConverter.ConversionError {
                guard case .timedOut = error else {
                    Issue.record("expected timedOut, got \(error)")
                    return
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(clock.now - start < .seconds(10))
    }

    @Test func converterIgnoringTerminationIsKilledAfterGracePeriod() async throws {
        let script = try makeScript("trap '' TERM\nsleep 30")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let clock = ContinuousClock()
        let start = clock.now
        await withOverrides(executable: script, timeout: 0.2) {
            await #expect(throws: EbookConverter.ConversionError.self) {
                try await EbookConverter.convert(source, to: .epub)
            }
        }

        #expect(clock.now - start < .seconds(6))
    }

    @Test func cancellationTerminatesTheConverterPromptly() async throws {
        let script = try makeScript("sleep 30")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let clock = ContinuousClock()
        let start = clock.now
        await withOverrides(executable: script) {
            let task = Task { try await EbookConverter.convert(source, to: .epub) }
            try? await Task.sleep(for: .milliseconds(100))
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func missingCalibreThrowsConverterNotFound() async throws {
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        await withOverrides(executable: nil) {
            do {
                _ = try await EbookConverter.convert(source, to: .epub)
                Issue.record("expected converterNotFound")
            } catch let error as EbookConverter.ConversionError {
                guard case .converterNotFound = error else {
                    Issue.record("expected converterNotFound, got \(error)")
                    return
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @MainActor
    @Test func deletingBookDuringCalibreConversionDiscardsOutputAndState() async throws {
        let script = try makeScript("""
        cp "$1" "$2"
        sleep 1
        """)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let source = try makeFB2Source()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let library = try await TestLibrary()
        let uuid = UUID()
        let oldFileName = "\(uuid.uuidString).fb2"
        try library.installBookFile(from: source, fileName: oldFileName)
        let book = Book(uuid: uuid, fileName: oldFileName, originalFileName: "book.fb2")
        library.context.insert(book)
        try library.context.save()

        let conversionDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConversions", directoryHint: .isDirectory)

        EbookConverter.calibreExecutableOverride = .some(script)
        EbookConverter.conversionTimeout = 180
        defer {
            EbookConverter.calibreExecutableOverride = nil
            EbookConverter.conversionTimeout = 180
        }

        let service = ConversionService(modelContext: library.context, toasts: ToastCenter())
        service.convert(book, to: .epub)

        let outputDeadline = Date.now.addingTimeInterval(2)
        var outputCandidate: URL?
        while outputCandidate == nil, Date.now < outputDeadline {
            outputCandidate = (try? FileManager.default.contentsOfDirectory(
                at: conversionDirectory, includingPropertiesForKeys: nil
            ))?.first { $0.lastPathComponent.hasSuffix("-\(uuid.uuidString).epub") }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let temporaryOutput = try #require(outputCandidate)
        #expect(FileManager.default.fileExists(atPath: temporaryOutput.path(percentEncoded: false)))

        BookFileStore.delete(fileName: oldFileName)
        CoverStore.delete(for: uuid)
        library.context.delete(book)
        library.context.saveQuietly()

        let completionDeadline = Date.now.addingTimeInterval(3)
        while service.convertingUUIDs.contains(uuid), Date.now < completionDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!service.convertingUUIDs.contains(uuid))
        #expect(!FileManager.default.fileExists(atPath: temporaryOutput.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: "\(uuid.uuidString).epub").path(percentEncoded: false)
        ))
        #expect(!CoverStore.exists(for: uuid))
        _ = library
    }
}
