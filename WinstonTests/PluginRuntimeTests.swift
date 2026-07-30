import Darwin
import Foundation
import Testing
@testable import Winston

private actor PendingPluginHostCallGate {
    private var enteredCount = 0
    private var enteredWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        enteredCount += 1
        let ready = enteredWaiters.filter { $0.count <= enteredCount }
        enteredWaiters.removeAll { $0.count <= enteredCount }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitUntilEntered(count: Int) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation {
            enteredWaiters.append((count: count, continuation: $0))
        }
    }

    func releaseAll() {
        let continuations = blocked
        blocked.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
struct PluginRuntimeTests {
    @MainActor
    private final class HostRecorder {
        private(set) var calls: [PluginAPICall] = []
        var result: Result<Data?, PluginError> = .success(nil)
        var gate: PendingPluginHostCallGate?

        func handler() -> PluginHostHandler {
            { call in
                self.calls.append(call)
                if let gate = self.gate {
                    await gate.suspend()
                }
                return self.result
            }
        }
    }

    private final class FaultRecorder: Sendable {
        let buffer = PluginLogBuffer()
        var count: Int { buffer.snapshot.count }
        var callback: @Sendable (PluginRuntimeFault) -> Void {
            { [buffer] fault in
                switch fault {
                case .script(let message), .terminated(let message):
                    buffer.append(.error, message)
                }
            }
        }
    }

    private func makeRuntime(
        source: String,
        permissions: Set<PluginPermission> = [],
        executionDeadline: TimeInterval = PluginRuntime.defaultExecutionDeadline,
        maximumMemoryBytes: UInt64 = PluginRuntime.defaultMaximumMemoryBytes,
        faults: FaultRecorder = FaultRecorder()
    ) throws -> PluginRuntime {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "WinstonRuntimeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "cz.test.plugin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = PluginManifest(id: "cz.test.plugin", name: "Test", version: "1.0.0",
                                      api: "1", entry: "index.js", permissions: permissions,
                                      description: nil, author: nil)
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        try Data(source.utf8).write(to: folder.appending(path: "index.js"))
        let digest = try PluginDiscovery.bundleSnapshot(in: folder).contentDigest
        return PluginRuntime(
            manifest: manifest,
            folderURL: folder,
            contentDigest: digest,
            executionDeadline: executionDeadline,
            maximumMemoryBytes: maximumMemoryBytes,
            onFault: faults.callback
        )
    }

    private func logged(_ needle: String, in runtime: PluginRuntime,
                        timeout: TimeInterval = 3) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if runtime.logBuffer.snapshot.contains(where: { $0.message.contains(needle) }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return runtime.logBuffer.snapshot.contains { $0.message.contains(needle) }
    }

    // MARK: - Console & exceptions

    @Test func consoleRoutesToTheBufferWithLevels() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            console.log("hello", 42);
            console.warn("careful");
            console.error("bad");
            """)
        try await runtime.load(granted: [], handler: recorder.handler())

        let entries = runtime.logBuffer.snapshot
        #expect(entries.contains { $0.message == "hello 42" && $0.level == .info })
        #expect(entries.contains { $0.message == "careful" && $0.level == .warning })
        #expect(entries.contains { $0.message == "bad" && $0.level == .error })
    }

    @Test func topLevelExceptionFailsTheLoadAndReportsAFault() async throws {
        let faults = FaultRecorder()
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: #"throw new Error("boom");"#, faults: faults)

        do {
            try await runtime.load(granted: [], handler: recorder.handler())
            Issue.record("load should have thrown")
        } catch let error as PluginError {
            #expect(error.message.contains("boom"))
        }
        #expect(faults.count == 1)
    }

    @Test func activateExceptionFailsTheLoad() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.activate = () => { throw new Error("bad activate"); };
            """)
        do {
            try await runtime.load(granted: [], handler: recorder.handler())
            Issue.record("load should have thrown")
        } catch let error as PluginError {
            #expect(error.message.contains("bad activate"))
        }
    }

    // MARK: - The Promise bridge

    @Test func asyncCallRoundTripsThroughTheHostHandler() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                await Winston.ui.toast("hi");
                console.log("resolved");
            };
            """, permissions: [.uiToast])
        try await runtime.load(granted: [.uiToast], handler: recorder.handler())

        #expect(await logged("resolved", in: runtime))
        #expect(recorder.calls == [.toast(message: "hi", style: .info)])
    }

    @Test func hostFailureRejectsWithACodedError() async throws {
        let recorder = HostRecorder()
        recorder.result = .failure(.unavailable("nope"))
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                try { await Winston.ui.toast("x"); }
                catch (e) { console.log("code:" + e.code + " msg:" + e.message); }
            };
            """, permissions: [.uiToast])
        try await runtime.load(granted: [.uiToast], handler: recorder.handler())

        #expect(await logged("code:unavailable msg:nope", in: runtime))
    }

    @Test func badArgumentsRejectWithoutReachingTheHost() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                try { await Winston.ui.toast(); }
                catch (e) { console.log("code:" + e.code); }
            };
            """, permissions: [.uiToast])
        try await runtime.load(granted: [.uiToast], handler: recorder.handler())

        #expect(await logged("code:invalid-argument", in: runtime))
        #expect(recorder.calls.isEmpty)
    }

    @Test func oversizedLibraryPageIsRejectedBeforeReachingTheHost() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                try { await Winston.library.list({ limit: 101 }); }
                catch (e) { console.log("code:" + e.code); }
            };
            """, permissions: [.libraryRead])
        try await runtime.load(granted: [.libraryRead], handler: recorder.handler())

        #expect(await logged("code:invalid-argument", in: runtime))
        #expect(recorder.calls.isEmpty)
    }

    @Test func oversizedStorageValueRejectsBeforeReachingTheHost() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                try { await Winston.storage.set("large", "x".repeat(300 * 1024)); }
                catch (e) { console.log("code:" + e.code); }
            };
            """)
        try await runtime.load(granted: [], handler: recorder.handler())

        #expect(await logged("code:invalid-argument", in: runtime))
        #expect(recorder.calls.isEmpty)
    }

    @Test func oversizedToastRejectsBeforeReachingTheHost() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                try { await Winston.ui.toast("x".repeat(5000)); }
                catch (e) { console.log("code:" + e.code); }
            };
            """, permissions: [.uiToast])
        try await runtime.load(granted: [.uiToast], handler: recorder.handler())

        #expect(await logged("code:invalid-argument", in: runtime))
        #expect(recorder.calls.isEmpty)
    }

    @Test func pendingHostCallsAreBounded() async throws {
        let recorder = HostRecorder()
        let gate = PendingPluginHostCallGate()
        recorder.gate = gate
        let total = PluginRuntime.maximumPendingHostCalls + 6
        let runtime = try makeRuntime(source: """
            exports.activate = () => {
                const calls = [];
                let rejected = 0;
                for (let i = 0; i < \(total); i++) {
                    calls.push(Winston.ui.toast("x").catch(e => {
                        if (e.code === "unavailable") rejected++;
                    }));
                }
                Promise.all(calls).then(() => console.log("rejected:" + rejected));
            };
            """, permissions: [.uiToast])
        try await runtime.load(granted: [.uiToast], handler: recorder.handler())

        await gate.waitUntilEntered(count: PluginRuntime.maximumPendingHostCalls)
        #expect(recorder.calls.count == PluginRuntime.maximumPendingHostCalls)
        await gate.releaseAll()
        #expect(await logged("rejected:6", in: runtime))
        #expect(recorder.calls.count == PluginRuntime.maximumPendingHostCalls)
    }

    // MARK: - Permission gating

    @Test func ungrantedNamespacesDoNotExist() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            console.log(typeof Winston.library, typeof Winston.ui, typeof Winston.metadata,
                        Winston.capabilities.has("storage"), Winston.capabilities.has("library.list"));
            """)
        try await runtime.load(granted: [], handler: recorder.handler())

        #expect(runtime.logBuffer.snapshot.contains {
            $0.message == "undefined undefined undefined true false"
        })
    }

    @Test func grantedLibraryNamespaceExists() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            console.log(typeof Winston.library, typeof Winston.library.list,
                        typeof Winston.metadata, typeof Winston.ui);
            """, permissions: [.libraryRead])
        try await runtime.load(granted: [.libraryRead], handler: recorder.handler())
        #expect(runtime.logBuffer.snapshot.contains { $0.message == "object function undefined undefined" })
    }

    @Test func metadataNamespaceRequiresDedicatedPermission() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            console.log(typeof Winston.library, typeof Winston.metadata,
                        Winston.capabilities.has("library.list"),
                        Winston.capabilities.has("metadata.fetch"));
            """, permissions: [.metadataFetch])
        try await runtime.load(granted: [.metadataFetch], handler: recorder.handler())

        #expect(runtime.logBuffer.snapshot.contains {
            $0.message == "undefined object false true"
        })
    }

    @Test func optionsObjectsAreOptional() async throws {
        let recorder = HostRecorder()
        recorder.result = .success(Data(#"{"items":[],"nextCursor":null}"#.utf8))
        let runtime = try makeRuntime(source: """
            exports.activate = async () => {
                const page = await Winston.library.list();
                console.log("count:" + page.items.length);
            };
            """, permissions: [.libraryRead])
        try await runtime.load(granted: [.libraryRead], handler: recorder.handler())

        #expect(await logged("count:0", in: runtime))
        #expect(recorder.calls == [
            .libraryList(
                searchText: nil,
                cursor: nil,
                limit: PluginLibraryLimits.defaultPageSize
            ),
        ])
    }

    @Test func hostInfoIsExposed() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            console.log("api:" + Winston.host.apiVersion);
            """)
        try await runtime.load(granted: [], handler: recorder.handler())
        #expect(runtime.logBuffer.snapshot.contains { $0.message == "api:\(PluginManifest.hostAPIVersion)" })
    }

    // MARK: - Lifecycle

    @Test func workerConfigurationRoundTripsWithinTheCurrentWireBuild() throws {
        let manifest = PluginManifest(
            id: "cz.test.plugin",
            name: "Test",
            version: "1.0.0",
            api: "1",
            entry: "index.js",
            permissions: [.libraryRead],
            description: nil,
            author: nil
        )
        let configuration = PluginWorkerConfiguration(
            manifest: manifest,
            entrySource: "console.log('ready')",
            granted: [.libraryRead],
            appVersion: "2",
            locale: "cs_CZ"
        )

        let decoded = try JSONDecoder().decode(
            PluginWorkerConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        #expect(decoded.manifest == manifest)
        #expect(decoded.entrySource == configuration.entrySource)
        #expect(decoded.granted == configuration.granted)
        #expect(decoded.appVersion == configuration.appVersion)
        #expect(decoded.locale == configuration.locale)
    }

    @Test func cumulativeCPUAcrossBoundedTurnsDoesNotKillWorker() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(
            source: """
                exports.activate = async () => {
                    for (let i = 0; i < 18; i++) {
                        await Winston.storage.get("turn-" + i);
                        const end = Date.now() + 75;
                        while (Date.now() < end) {}
                    }
                    console.log("cumulative-complete");
                };
                """,
            executionDeadline: 0.3
        )

        try await runtime.load(granted: [], handler: recorder.handler())

        #expect(await logged("cumulative-complete", in: runtime, timeout: 5))
        #expect(recorder.calls.count == 18)
        #expect(await runtime.isWorkerRunning())
        await runtime.shutdown()
    }

    @Test func infiniteLoopWorkerIsActuallyTerminatedAtTheDeadline() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(
            source: "while (true) {}",
            executionDeadline: 0.2
        )
        let load = Task {
            try await runtime.load(granted: [], handler: recorder.handler())
        }

        var pid: Int32?
        let pidDeadline = Date.now.addingTimeInterval(2)
        while pid == nil, Date.now < pidDeadline {
            pid = await runtime.workerProcessIdentifier()
            if pid == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        let result = await load.result

        if case .failure(let error as PluginError) = result {
            #expect(error == .timeout)
        } else {
            Issue.record("infinite loop should time out")
        }
        #expect(!(await runtime.isWorkerRunning()))
        if let pid {
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    @Test func repeatedRunawayWorkersDoNotAccumulateProcesses() async throws {
        let recorder = HostRecorder()
        var pids: [Int32] = []
        for _ in 0 ..< 3 {
            let runtime = try makeRuntime(
                source: "const blocks = []; while (true) { blocks.push(new ArrayBuffer(1048576)); }",
                executionDeadline: 0.2
            )
            let load = Task {
                try await runtime.load(granted: [], handler: recorder.handler())
            }
            let pidDeadline = Date.now.addingTimeInterval(2)
            while await runtime.workerProcessIdentifier() == nil, Date.now < pidDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if let pid = await runtime.workerProcessIdentifier() { pids.append(pid) }
            _ = await load.result
            #expect(!(await runtime.isWorkerRunning()))
        }

        for pid in pids {
            #expect(kill(pid, 0) == -1)
        }
    }

    @Test func memoryBombWorkerIsTerminatedByTheFootprintLimit() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(
            source: """
                const blocks = [];
                while (true) {
                    const block = new Uint8Array(4 * 1024 * 1024);
                    block.fill(1);
                    blocks.push(block);
                }
                """,
            executionDeadline: 5,
            maximumMemoryBytes: 64 * 1_024 * 1_024
        )

        do {
            try await runtime.load(granted: [], handler: recorder.handler())
            Issue.record("memory bomb should have been terminated")
        } catch PluginError.workerTerminated(let message) {
            #expect(message.contains("memory limit"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(!(await runtime.isWorkerRunning()))
    }

    @Test func shutdownCallsDeactivate() async throws {
        let recorder = HostRecorder()
        let runtime = try makeRuntime(source: """
            exports.deactivate = () => { console.log("deactivated"); };
            """)
        try await runtime.load(granted: [], handler: recorder.handler())
        await runtime.shutdown()
        #expect(runtime.logBuffer.snapshot.contains { $0.message == "deactivated" })
    }
}
