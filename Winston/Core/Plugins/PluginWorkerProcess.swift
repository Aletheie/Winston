import Darwin
import Foundation
import JavaScriptCore

nonisolated enum PluginWorkerProcessMain {
    static var isWorkerInvocation: Bool {
        ProcessInfo.processInfo.arguments.contains(PluginRuntime.workerArgument)
    }

    static func run() -> Never {
        let writer = PluginWorkerWriter()
        let engine = PluginWorkerEngine(writer: writer)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let command = try PluginWorkerWire.decode(PluginWorkerCommand.self, from: data)
                engine.receive(command)
            } catch {
                writer.send(.loadFailed("invalid command from Winston"))
                Darwin.exit(EXIT_FAILURE)
            }
        }
        Darwin.exit(EXIT_SUCCESS)
    }
}

private nonisolated final class PluginWorkerWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let output = FileHandle.standardOutput

    func send(_ event: PluginWorkerEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try output.write(contentsOf: PluginWorkerWire.encode(event))
        } catch {
            if let fallback = try? PluginWorkerWire.encode(
                PluginWorkerEvent.fault("plugin worker emitted an oversized IPC message")
            ) {
                try? output.write(contentsOf: fallback)
            }
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

/// Child-process JavaScriptCore owner. Every JSC object remains confined to `queue`.
private nonisolated final class PluginWorkerEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cz.annajung.Winston.plugin-worker")
    private let writer: PluginWorkerWriter

    private var vm: JSVirtualMachine?
    private var context: JSContext?
    private var pending: [UInt64: (resolve: JSValue, reject: JSValue)] = [:]
    private var nextCallID: UInt64 = 0
    private var nextExecutionID: UInt64 = 0
    private var lastException: String?

    init(writer: PluginWorkerWriter) {
        self.writer = writer
    }

    func receive(_ command: PluginWorkerCommand) {
        switch command {
        case .start(let configuration):
            do {
                try PluginWorkerResourceLimits.apply(configuration)
            } catch {
                writer.send(.loadFailed(
                    "could not apply plugin resource limits: \(error.localizedDescription)"
                ))
                return
            }
            queue.async {
                do {
                    try self.loadOnQueue(configuration)
                    self.writer.send(.loaded)
                } catch let error as PluginError {
                    self.teardownOnQueue()
                    self.writer.send(.loadFailed(error.message))
                } catch {
                    self.teardownOnQueue()
                    self.writer.send(.loadFailed(error.localizedDescription))
                }
            }

        case .hostResponse(let id, let response):
            queue.async { self.complete(id, with: response.result) }

        case .shutdown:
            queue.async {
                if let context = self.context,
                   let deactivate = context.objectForKeyedSubscript("exports")?
                       .objectForKeyedSubscript("deactivate"),
                   !deactivate.isUndefined {
                    self.performJavaScript {
                        deactivate.call(withArguments: [])
                    }
                }
                self.teardownOnQueue()
                self.writer.send(.stopped)
                Darwin.exit(EXIT_SUCCESS)
            }
        }
    }

    private func loadOnQueue(_ configuration: PluginWorkerConfiguration) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard context == nil else { throw PluginError.loadFailed("plugin is already loaded") }

        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else {
            throw PluginError.contextCreationFailed
        }
        context.name = "Winston plugin \(configuration.manifest.id)"
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            let text = exception?.toString() ?? "unknown error"
            self.lastException = text
            self.writer.send(.log(level: .error, message: text))
            self.writer.send(.fault(text))
        }

        installConsole(in: context)
        installWinston(in: context, configuration: configuration)
        context.setObject(JSValue(newObjectIn: context), forKeyedSubscript: "exports" as NSString)
        self.vm = vm
        self.context = context

        lastException = nil
        performJavaScript {
            let sourceURL = URL(
                string: "winston-plugin://\(configuration.manifest.id)/\(configuration.manifest.entry)"
            )
            context.evaluateScript(configuration.entrySource, withSourceURL: sourceURL)
            if self.lastException == nil,
               let activate = context.objectForKeyedSubscript("exports")?
                   .objectForKeyedSubscript("activate"),
               !activate.isUndefined {
                activate.call(withArguments: [])
            }
        }
        if let text = lastException { throw PluginError.loadFailed(text) }
    }

    private func teardownOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeAll()
        lastException = nil
        context = nil
        vm = nil
    }

    // MARK: - JavaScript execution boundary

    @discardableResult
    private func performJavaScript<T>(_ operation: () -> T) -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        nextExecutionID += 1
        let token = nextExecutionID
        writer.send(.executionBegan(token))
        defer { writer.send(.executionEnded(token)) }
        return operation()
    }

    // MARK: - console

    private func installConsole(in context: JSContext) {
        let writer = writer
        let console = JSValue(newObjectIn: context)!
        let levels: [(String, PluginLogEntry.Level)] = [
            ("debug", .debug),
            ("log", .info),
            ("info", .info),
            ("warn", .warning),
            ("error", .error),
        ]
        for (name, level) in levels {
            let block: @convention(block) () -> Void = {
                let args = (JSContext.currentArguments() as? [JSValue]) ?? []
                let text = args.map { $0.toString() ?? "undefined" }.joined(separator: " ")
                writer.send(.log(level: level, message: text))
            }
            console.setObject(block, forKeyedSubscript: name)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - Winston namespace

    private func installWinston(
        in context: JSContext,
        configuration: PluginWorkerConfiguration
    ) {
        let granted = configuration.granted
        let winston = JSValue(newObjectIn: context)!

        let host = JSValue(newObjectIn: context)!
        host.setObject(configuration.appVersion, forKeyedSubscript: "appVersion")
        host.setObject(PluginManifest.hostAPIVersion, forKeyedSubscript: "apiVersion")
        host.setObject(configuration.locale, forKeyedSubscript: "locale")
        winston.setObject(host, forKeyedSubscript: "host")

        var capabilities: Set<String> = ["storage"]
        if granted.contains(.libraryRead) { capabilities.formUnion(["library.list", "library.get"]) }
        if granted.contains(.libraryWrite) { capabilities.insert("library.update") }
        if granted.contains(.metadataFetch) { capabilities.insert("metadata.fetch") }
        if granted.contains(.uiToast) { capabilities.insert("ui.toast") }
        let has: @convention(block) (String?) -> Bool = { capabilities.contains($0 ?? "") }
        let capabilitiesObject = JSValue(newObjectIn: context)!
        capabilitiesObject.setObject(has, forKeyedSubscript: "has")
        winston.setObject(capabilitiesObject, forKeyedSubscript: "capabilities")

        let storage = JSValue(newObjectIn: context)!
        installAsyncMethod(named: "get", on: storage) { arg0, _ in
            let key = try Self.requireString(arg0, "storage.get expects a string key")
            guard PluginStorageLimits.accepts(key: key) else {
                throw PluginError.invalidArgument("storage keys are limited to 256 UTF-8 bytes")
            }
            return .storageGet(key: key)
        }
        installAsyncMethod(named: "set", on: storage) { arg0, arg1 in
            let key = try Self.requireString(arg0, "storage.set expects a string key")
            let object = arg1?.toObject() ?? NSNull()
            guard let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.fragmentsAllowed]
            ), let json = String(data: data, encoding: .utf8) else {
                throw PluginError.invalidArgument("storage.set value must be JSON-serializable")
            }
            guard PluginStorageLimits.accepts(key: key),
                  data.count <= PluginStorageLimits.maxValueBytes else {
                throw PluginError.invalidArgument("plugin storage key or value exceeds its size limit")
            }
            return .storageSet(key: key, valueJSON: json)
        }
        installAsyncMethod(named: "remove", on: storage) { arg0, _ in
            let key = try Self.requireString(arg0, "storage.remove expects a string key")
            guard PluginStorageLimits.accepts(key: key) else {
                throw PluginError.invalidArgument("storage keys are limited to 256 UTF-8 bytes")
            }
            return .storageRemove(key: key)
        }
        winston.setObject(storage, forKeyedSubscript: "storage")

        if granted.contains(.libraryRead) || granted.contains(.libraryWrite) {
            let library = JSValue(newObjectIn: context)!
            if granted.contains(.libraryRead) {
                installAsyncMethod(named: "list", on: library) { arg0, _ in
                    let limitValue = Self.property("limit", of: arg0)
                    let limit = limitValue?.isNumber == true
                        ? Int(limitValue?.toInt32() ?? 0)
                        : PluginLibraryLimits.defaultPageSize
                    guard (1 ... PluginLibraryLimits.maximumPageSize).contains(limit) else {
                        throw PluginError.invalidArgument(
                            "library.list limit must be between 1 and \(PluginLibraryLimits.maximumPageSize)"
                        )
                    }
                    let searchText = Self.optionalString(Self.property("text", of: arg0))
                    let cursor = Self.optionalString(Self.property("cursor", of: arg0))
                    guard PluginValueLimits.accepts(
                        searchText,
                        maximumBytes: PluginLibraryLimits.maximumSearchBytes
                    ), PluginValueLimits.accepts(
                        cursor,
                        maximumBytes: PluginValueLimits.maximumCursorBytes
                    ) else {
                        throw PluginError.invalidArgument("library.list options exceed their size limit")
                    }
                    return .libraryList(
                        searchText: searchText,
                        cursor: cursor,
                        limit: limit
                    )
                }
                installAsyncMethod(named: "get", on: library) { arg0, _ in
                    .libraryGet(uuid: try Self.requireUUID(
                        arg0,
                        "library.get expects a book uuid string"
                    ))
                }
            }
            if granted.contains(.libraryWrite) {
                installAsyncMethod(named: "update", on: library) { arg0, arg1 in
                    let uuid = try Self.requireUUID(
                        arg0,
                        "library.update expects a book uuid string"
                    )
                    guard let arg1, arg1.isObject else {
                        throw PluginError.invalidArgument("library.update expects a patch object")
                    }
                    func field(_ key: String) -> String? {
                        Self.optionalString(arg1.objectForKeyedSubscript(key))
                    }
                    var patch = PluginMetadataPatch()
                    patch.title = field("title")
                    patch.author = field("author")
                    patch.publisher = field("publisher")
                    patch.year = field("year")
                    patch.language = field("language")
                    patch.translator = field("translator")
                    patch.isbn = field("isbn")
                    patch.series = field("series")
                    patch.seriesIndex = field("seriesIndex")
                    patch.description = field("description")
                    if let tags = arg1.objectForKeyedSubscript("tags"), tags.isArray {
                        patch.tags = tags.toArray()?.compactMap { $0 as? String }
                    }
                    guard PluginValueLimits.accepts(patch: patch) else {
                        throw PluginError.invalidArgument(
                            "library.update patch exceeds its size limit"
                        )
                    }
                    return .libraryUpdate(uuid: uuid, patch: patch)
                }
            }
            winston.setObject(library, forKeyedSubscript: "library")
        }

        if granted.contains(.metadataFetch) {
            let metadata = JSValue(newObjectIn: context)!
            installAsyncMethod(named: "fetch", on: metadata) { arg0, _ in
                guard let arg0, arg0.isObject else {
                    throw PluginError.invalidArgument("metadata.fetch expects an options object")
                }
                let isbn = Self.optionalString(arg0.objectForKeyedSubscript("isbn"))
                let title = Self.optionalString(arg0.objectForKeyedSubscript("title"))
                let author = Self.optionalString(arg0.objectForKeyedSubscript("author"))
                guard isbn != nil || title != nil else {
                    throw PluginError.invalidArgument("metadata.fetch needs an isbn or a title")
                }
                guard PluginValueLimits.accepts(
                    isbn,
                    maximumBytes: PluginValueLimits.maximumISBNBytes
                ), PluginValueLimits.accepts(
                    title,
                    maximumBytes: PluginValueLimits.maximumQueryBytes
                ), PluginValueLimits.accepts(
                    author,
                    maximumBytes: PluginValueLimits.maximumQueryBytes
                ) else {
                    throw PluginError.invalidArgument("metadata.fetch query exceeds its size limit")
                }
                return .metadataFetch(isbn: isbn, title: title, author: author)
            }
            winston.setObject(metadata, forKeyedSubscript: "metadata")
        }

        if granted.contains(.uiToast) {
            let ui = JSValue(newObjectIn: context)!
            installAsyncMethod(named: "toast", on: ui) { arg0, arg1 in
                let message = try Self.requireString(arg0, "ui.toast expects a message string")
                guard PluginValueLimits.accepts(
                    message,
                    maximumBytes: PluginValueLimits.maximumToastBytes
                ) else {
                    throw PluginError.invalidArgument("ui.toast message exceeds its size limit")
                }
                let style = PluginToastStyle(
                    rawValue: Self.optionalString(arg1) ?? "info"
                ) ?? .info
                return .toast(message: message, style: style)
            }
            winston.setObject(ui, forKeyedSubscript: "ui")
        }

        context.setObject(winston, forKeyedSubscript: "Winston" as NSString)
    }

    // MARK: - Promise bridge

    private func installAsyncMethod(
        named name: String,
        on object: JSValue,
        decode: @escaping (JSValue?, JSValue?) throws -> PluginAPICall
    ) {
        let block: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak self] arg0, arg1 in
            guard let context = JSContext.current() else { return nil }
            guard let self else {
                return JSValue(newPromiseRejectedWithReason: "plugin runtime is gone", in: context)
            }
            do {
                return self.makePendingPromise(for: try decode(arg0, arg1), in: context)
            } catch let error as PluginError {
                return JSValue(
                    newPromiseRejectedWithReason: Self.errorValue(error, in: context),
                    in: context
                )
            } catch {
                return JSValue(newPromiseRejectedWithReason: "\(error)", in: context)
            }
        }
        object.setObject(block, forKeyedSubscript: name)
    }

    private func makePendingPromise(
        for call: PluginAPICall,
        in context: JSContext
    ) -> JSValue? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pending.count < PluginRuntime.maximumPendingHostCalls else {
            let error = PluginError.unavailable("too many pending host calls")
            return JSValue(
                newPromiseRejectedWithReason: Self.errorValue(error, in: context),
                in: context
            )
        }
        nextCallID += 1
        let id = nextCallID
        let promise = JSValue(newPromiseIn: context) { resolve, reject in
            guard let resolve, let reject else { return }
            self.pending[id] = (resolve, reject)
        }
        writer.send(.hostCall(id: id, call: call))
        return promise
    }

    private func complete(_ id: UInt64, with result: Result<Data?, PluginError>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let context, let callbacks = pending.removeValue(forKey: id) else { return }
        performJavaScript {
            switch result {
            case .success(let json):
                callbacks.resolve.call(withArguments: [Self.jsonValue(json, in: context)])
            case .failure(let error):
                callbacks.reject.call(withArguments: [Self.errorValue(error, in: context)])
            }
        }
    }

    // MARK: - Value conversion

    private static func jsonValue(_ json: Data?, in context: JSContext) -> JSValue {
        guard let json,
              let object = try? JSONSerialization.jsonObject(
                  with: json,
                  options: [.fragmentsAllowed]
              ) else {
            return JSValue(nullIn: context)
        }
        return JSValue(object: object, in: context) ?? JSValue(nullIn: context)
    }

    private static func errorValue(_ error: PluginError, in context: JSContext) -> JSValue {
        let value = JSValue(
            newErrorFromMessage: error.message,
            in: context
        ) ?? JSValue(newObjectIn: context)!
        value.setObject(error.code, forKeyedSubscript: "code")
        return value
    }

    private static func property(_ key: String, of value: JSValue?) -> JSValue? {
        guard let value, value.isObject else { return nil }
        return value.objectForKeyedSubscript(key)
    }

    private static func optionalString(_ value: JSValue?) -> String? {
        guard let value, value.isString else { return nil }
        return value.toString()
    }

    private static func requireString(_ value: JSValue?, _ complaint: String) throws -> String {
        guard let string = optionalString(value), !string.isEmpty else {
            throw PluginError.invalidArgument(complaint)
        }
        return string
    }

    private static func requireUUID(_ value: JSValue?, _ complaint: String) throws -> UUID {
        guard let uuid = UUID(uuidString: try requireString(value, complaint)) else {
            throw PluginError.invalidArgument(complaint)
        }
        return uuid
    }
}

private nonisolated enum PluginWorkerResourceLimits {
    static func apply(_ configuration: PluginWorkerConfiguration) throws {
        signal(SIGXCPU, SIG_DFL)
        try lower(
            name: "CPU",
            resource: RLIMIT_CPU,
            soft: rlim_t(configuration.maximumCPUSeconds),
            hard: rlim_t(configuration.maximumCPUSeconds + 1)
        )
    }

    private static func lower(
        name: String,
        resource: Int32,
        soft requestedSoft: rlim_t,
        hard requestedHard: rlim_t
    ) throws {
        var current = rlimit()
        guard getrlimit(resource, &current) == 0 else {
            throw LimitError(name: name, operation: "read", code: errno)
        }
        let hard = min(current.rlim_max, requestedHard)
        let soft = min(requestedSoft, hard)
        var proposed = rlimit(rlim_cur: soft, rlim_max: hard)
        guard setrlimit(resource, &proposed) == 0 else {
            throw LimitError(name: name, operation: "set", code: errno)
        }
    }

    private struct LimitError: LocalizedError {
        let name: String
        let operation: String
        let code: Int32

        var errorDescription: String? {
            "could not \(operation) \(name) limit (errno \(code))"
        }
    }
}
