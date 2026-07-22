import Darwin
import Foundation
import Synchronization

nonisolated enum PluginAPICall: Codable, Sendable, Equatable {
    case libraryList(searchText: String?, cursor: String?, limit: Int)
    case libraryGet(uuid: UUID)
    case libraryUpdate(uuid: UUID, patch: PluginMetadataPatch)
    case metadataFetch(isbn: String?, title: String?, author: String?)
    case storageGet(key: String)
    case storageSet(key: String, valueJSON: String)
    case storageRemove(key: String)
    case toast(message: String, style: PluginToastStyle)
}

nonisolated enum PluginToastStyle: String, Codable, Sendable { case info, success, error }

nonisolated struct PluginMetadataPatch: Codable, Sendable, Equatable {
    var title: String?
    var author: String?
    var publisher: String?
    var year: String?
    var language: String?
    var translator: String?
    var isbn: String?
    var series: String?
    var seriesIndex: String?
    var description: String?
    var tags: [String]?
}

typealias PluginHostHandler = @MainActor @Sendable (PluginAPICall) async -> Result<Data?, PluginError>

nonisolated enum PluginRuntimeFault: Sendable, Equatable {
    case script(String)
    case terminated(String)
}

nonisolated struct PluginWorkerConfiguration: Codable, Sendable {
    let manifest: PluginManifest
    let entrySource: String
    let granted: Set<PluginPermission>
    let appVersion: String
    let locale: String
    let maximumCPUSeconds: Int
    let maximumMemoryBytes: UInt64
}

nonisolated struct PluginHostResponse: Codable, Sendable {
    let data: Data?
    let error: PluginError?

    init(_ result: Result<Data?, PluginError>) {
        switch result {
        case .success(let data):
            self.data = data
            error = nil
        case .failure(let error):
            data = nil
            self.error = error
        }
    }

    var result: Result<Data?, PluginError> {
        if let error { return .failure(error) }
        return .success(data)
    }
}

nonisolated enum PluginWorkerCommand: Codable, Sendable {
    case start(PluginWorkerConfiguration)
    case hostResponse(id: UInt64, response: PluginHostResponse)
    case shutdown
}

nonisolated enum PluginWorkerEvent: Codable, Sendable {
    case loaded
    case loadFailed(String)
    case log(level: PluginLogEntry.Level, message: String)
    case fault(String)
    case hostCall(id: UInt64, call: PluginAPICall)
    case executionBegan(UInt64)
    case executionEnded(UInt64)
    case stopped
}

nonisolated enum PluginWorkerWire {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

private nonisolated final class PluginLineFramer: Sendable {
    private let buffered = Mutex(Data())

    func append(_ chunk: Data) -> [Data] {
        buffered.withLock { buffer in
            buffer.append(chunk)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
            return lines
        }
    }
}

/// Parent-side owner of one killable plugin process. No JavaScriptCore value or
/// plugin code exists in the host process; the only bridge is the Codable wire protocol above.
actor PluginRuntime {
    static let maximumPendingHostCalls = 64
    static let defaultExecutionDeadline: TimeInterval = 10
    static let defaultMaximumMemoryBytes: UInt64 = 512 * 1_024 * 1_024
    static let workerArgument = "--winston-plugin-worker"

    nonisolated let manifest: PluginManifest
    nonisolated let folderURL: URL
    nonisolated let contentDigest: String
    nonisolated let logBuffer = PluginLogBuffer()

    private let onFault: @Sendable (PluginRuntimeFault) -> Void
    private let workerExecutableURL: URL?
    private let executionDeadline: TimeInterval
    private let outputFramer = PluginLineFramer()
    private let errorFramer = PluginLineFramer()

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var handler: PluginHostHandler?
    private var hostTasks: [UInt64: Task<Void, Never>] = [:]
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    private var executionWatchdog: Task<Void, Never>?
    private var executionToken: UInt64?
    private var loaded = false
    private var stopping = false
    private var expectedStop = false
    private var timedOut = false

    init(
        manifest: PluginManifest,
        folderURL: URL,
        contentDigest: String,
        executionDeadline: TimeInterval = PluginRuntime.defaultExecutionDeadline,
        workerExecutableURL: URL? = nil,
        onFault: @escaping @Sendable (PluginRuntimeFault) -> Void
    ) {
        self.manifest = manifest
        self.folderURL = folderURL
        self.contentDigest = contentDigest
        self.executionDeadline = max(0.05, executionDeadline)
        self.workerExecutableURL = workerExecutableURL
        self.onFault = onFault
    }

    deinit {
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Lifecycle

    func load(granted: Set<PluginPermission>, handler: @escaping PluginHostHandler) async throws {
        guard process == nil, loadContinuation == nil else {
            throw PluginError.loadFailed("plugin is already loaded")
        }
        let snapshot: PluginBundleSnapshot
        do {
            snapshot = try PluginDiscovery.bundleSnapshot(
                in: folderURL,
                expectedManifest: manifest,
                expectedDigest: contentDigest
            )
        } catch {
            throw PluginError.loadFailed(error.localizedDescription)
        }

        self.handler = handler
        try launchWorker()
        let configuration = PluginWorkerConfiguration(
            manifest: manifest,
            entrySource: snapshot.entrySource,
            granted: granted,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0",
            locale: Locale.current.identifier,
            maximumCPUSeconds: max(1, Int(ceil(executionDeadline * 2))),
            maximumMemoryBytes: Self.defaultMaximumMemoryBytes
        )

        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            armExecutionWatchdog(token: 0)
            do {
                try send(.start(configuration))
            } catch {
                loadContinuation = nil
                continuation.resume(throwing: PluginError.workerTerminated(
                    "could not start the plugin worker: \(error.localizedDescription)"
                ))
                Task { await self.terminate() }
            }
        }
    }

    func shutdown() async {
        guard process != nil else {
            cancelOutstandingWork()
            return
        }
        expectedStop = true
        stopping = true
        cancelOutstandingWork()
        try? send(.shutdown)
        await waitForExit(grace: 0.35)
        if process?.isRunning == true {
            await terminateProcess()
        }
    }

    func terminate() async {
        expectedStop = true
        stopping = true
        cancelOutstandingWork()
        await terminateProcess()
    }

    func workerProcessIdentifier() -> Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func isWorkerRunning() -> Bool {
        process?.isRunning == true
    }

    // MARK: - Process

    private func launchWorker() throws {
        let executable = try resolvedWorkerExecutableURL()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.workerArgument]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = outputPipe.fileHandleForReading
        output.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            guard let self else { return }
            let lines = self.outputFramer.append(chunk)
            guard !lines.isEmpty else { return }
            Task { await self.receive(lines: lines) }
        }
        let error = errorPipe.fileHandleForReading
        error.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            for line in self.errorFramer.append(chunk) where !line.isEmpty {
                let message = String(data: line, encoding: .utf8) ?? "plugin worker error"
                self.logBuffer.append(.warning, message)
            }
        }
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.workerDidTerminate(
                    pid: process.processIdentifier,
                    status: process.terminationStatus,
                    reason: process.terminationReason
                )
            }
        }

        try process.run()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = output
        errorHandle = error
    }

    private func resolvedWorkerExecutableURL() throws -> URL {
        if let workerExecutableURL { return workerExecutableURL }
        if let override = ProcessInfo.processInfo.environment["WINSTON_PLUGIN_WORKER_EXECUTABLE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let executable = Bundle.main.executableURL { return executable }
        if let executable = Bundle.allBundles.first(where: {
            $0.bundleIdentifier == "cz.annajung.Winston"
        })?.executableURL {
            return executable
        }
        throw PluginError.unavailable("plugin worker executable is unavailable")
    }

    private func send(_ command: PluginWorkerCommand) throws {
        guard let inputHandle, process?.isRunning == true else {
            throw PluginError.workerTerminated("plugin worker is not running")
        }
        try inputHandle.write(contentsOf: PluginWorkerWire.encode(command))
    }

    private func receive(lines: [Data]) async {
        for line in lines where !line.isEmpty {
            do {
                let event = try PluginWorkerWire.decode(PluginWorkerEvent.self, from: line)
                await handle(event)
            } catch {
                logBuffer.append(.error, "invalid response from plugin worker")
                expectedStop = true
                await terminateProcess()
                resumeLoad(throwing: .workerTerminated("plugin worker sent an invalid response"))
                return
            }
        }
    }

    private func handle(_ event: PluginWorkerEvent) async {
        switch event {
        case .loaded:
            loaded = true
            resumeLoad()

        case .loadFailed(let message):
            resumeLoad(throwing: .loadFailed(message))
            expectedStop = true
            await terminateProcess()

        case .log(let level, let message):
            logBuffer.append(level, message)

        case .fault(let message):
            onFault(.script(message))

        case .hostCall(let id, let call):
            guard !stopping, let handler else {
                try? send(.hostResponse(
                    id: id,
                    response: PluginHostResponse(.failure(.unavailable("plugin session is inactive")))
                ))
                return
            }
            let task = Task { @MainActor [weak self, handler] in
                let result = await handler(call)
                await self?.completeHostCall(id: id, result: result)
            }
            hostTasks[id] = task

        case .executionBegan(let token):
            armExecutionWatchdog(token: token)

        case .executionEnded(let token):
            guard executionToken == token else { return }
            executionToken = nil
            executionWatchdog?.cancel()
            executionWatchdog = nil

        case .stopped:
            expectedStop = true
        }
    }

    private func completeHostCall(
        id: UInt64,
        result: Result<Data?, PluginError>
    ) async {
        hostTasks.removeValue(forKey: id)
        guard !stopping else { return }
        do {
            try send(.hostResponse(id: id, response: PluginHostResponse(result)))
        } catch {
            expectedStop = true
            await terminateProcess()
        }
    }

    private func executionExpired(token: UInt64) async {
        guard executionToken == token, process?.isRunning == true else { return }
        executionToken = nil
        timedOut = true
        expectedStop = true
        let message = "plugin execution exceeded its \(executionDeadline.formatted()) s limit"
        logBuffer.append(.error, message)
        if loaded { onFault(.terminated(message)) }
        await terminateProcess()
    }

    private func armExecutionWatchdog(token: UInt64) {
        executionToken = token
        executionWatchdog?.cancel()
        let deadline = executionDeadline
        executionWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(deadline))
            } catch {
                return
            }
            await self?.executionExpired(token: token)
        }
    }

    private func workerDidTerminate(
        pid: Int32,
        status: Int32,
        reason: Process.TerminationReason
    ) {
        guard process?.processIdentifier == pid else { return }
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        cancelOutstandingWork()

        if timedOut {
            resumeLoad(throwing: .timeout)
        } else if loadContinuation != nil {
            resumeLoad(throwing: .workerTerminated(
                "plugin worker exited unexpectedly (status \(status))"
            ))
        } else if loaded, !expectedStop {
            let description = reason == .uncaughtSignal
                ? "plugin worker was terminated by signal \(status)"
                : "plugin worker exited with status \(status)"
            logBuffer.append(.error, description)
            onFault(.terminated(description))
        }
        loaded = false
        handler = nil
    }

    private func resumeLoad(throwing error: PluginError? = nil) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func cancelOutstandingWork() {
        executionWatchdog?.cancel()
        executionWatchdog = nil
        executionToken = nil
        for task in hostTasks.values { task.cancel() }
        hostTasks.removeAll()
    }

    private func waitForExit(grace: TimeInterval) async {
        let deadline = Date.now.addingTimeInterval(grace)
        while process?.isRunning == true, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func terminateProcess() async {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        await waitForExit(grace: 0.15)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            await waitForExit(grace: 0.15)
        }
    }
}
