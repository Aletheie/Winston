import Foundation
import JavaScriptCore
import OSLog

nonisolated enum PluginAPICall: Sendable, Equatable {
    case libraryList(searchText: String?)
    case libraryGet(uuid: UUID)
    case libraryUpdate(uuid: UUID, patch: PluginMetadataPatch)
    case metadataFetch(isbn: String?, title: String?, author: String?)
    case storageGet(key: String)
    case storageSet(key: String, valueJSON: String)
    case storageRemove(key: String)
    case toast(message: String, style: PluginToastStyle)
}

nonisolated enum PluginToastStyle: String, Sendable { case info, success, error }

nonisolated struct PluginMetadataPatch: Sendable, Equatable {
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

// Every JSContext/JSValue is confined to `queue`; nothing JSC-typed may leave it — that invariant is what makes @unchecked Sendable sound.
nonisolated final class PluginRuntime: @unchecked Sendable {
    static let maximumPendingHostCalls = 64

    let manifest: PluginManifest
    let folderURL: URL
    let logBuffer = PluginLogBuffer()

    private let queue: DispatchQueue
    private let onFault: @Sendable (String) -> Void

    private var vm: JSVirtualMachine?
    private var context: JSContext?
    private var pending: [UInt64: (resolve: JSValue, reject: JSValue)] = [:]
    private var nextCallID: UInt64 = 0
    private var lastException: String?

    init(manifest: PluginManifest, folderURL: URL, onFault: @escaping @Sendable (String) -> Void) {
        self.manifest = manifest
        self.folderURL = folderURL
        self.onFault = onFault
        self.queue = DispatchQueue(label: "cz.annajung.Winston.plugin.\(manifest.id)")
    }

    // MARK: - Lifecycle

    func load(granted: Set<PluginPermission>, handler: @escaping PluginHostHandler) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.loadOnQueue(granted: granted, handler: handler)
                    continuation.resume()
                } catch {
                    self.teardownOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let context = self.context,
                   let deactivate = context.objectForKeyedSubscript("exports")?
                       .objectForKeyedSubscript("deactivate"),
                   !deactivate.isUndefined {
                    deactivate.call(withArguments: [])
                }
                self.teardownOnQueue()
                continuation.resume()
            }
        }
    }

    private func loadOnQueue(granted: Set<PluginPermission>, handler: @escaping PluginHostHandler) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard context == nil else { throw PluginError.loadFailed("plugin is already loaded") }

        let entryURL = folderURL.appending(path: manifest.entry)
        guard let sourceData = try? Data(contentsOf: entryURL),
              sourceData.count <= PluginDiscovery.maxEntryBytes,
              let source = String(data: sourceData, encoding: .utf8) else {
            throw PluginError.loadFailed("could not read entry script \"\(manifest.entry)\"")
        }

        let vm = JSVirtualMachine()
        guard let context = JSContext(virtualMachine: vm) else { throw PluginError.contextCreationFailed }
        context.name = "Winston plugin \(manifest.id)"

        let buffer = logBuffer
        let fault = onFault
        let pluginID = manifest.id
        context.exceptionHandler = { [weak self] _, exception in
            let text = exception?.toString() ?? "unknown error"
            buffer.append(.error, text)
            Log.plugins.error("[\(pluginID, privacy: .public)] uncaught: \(text, privacy: .public)")
            self?.lastException = text
            fault(text)
        }

        installConsole(in: context)
        installWinston(in: context, granted: granted, handler: handler)
        context.setObject(JSValue(newObjectIn: context), forKeyedSubscript: "exports" as NSString)

        self.vm = vm
        self.context = context

        lastException = nil
        context.evaluateScript(source, withSourceURL: entryURL)
        if let text = lastException { throw PluginError.loadFailed(text) }

        if let activate = context.objectForKeyedSubscript("exports")?.objectForKeyedSubscript("activate"),
           !activate.isUndefined {
            lastException = nil
            activate.call(withArguments: [])
            if let text = lastException { throw PluginError.loadFailed("activate() threw: \(text)") }
        }
        Log.plugins.info("[\(pluginID, privacy: .public)] loaded (v\(self.manifest.version, privacy: .public))")
    }

    private func teardownOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeAll()
        lastException = nil
        context = nil
        vm = nil
    }

    // MARK: - console

    private func installConsole(in context: JSContext) {
        let buffer = logBuffer
        let pluginID = manifest.id
        let console = JSValue(newObjectIn: context)!
        let levels: [(name: String, level: PluginLogEntry.Level, osType: OSLogType)] = [
            ("debug", .debug, .debug), ("log", .info, .info),
            ("info", .info, .info), ("warn", .warning, .default), ("error", .error, .error),
        ]
        for (name, level, osType) in levels {
            let block: @convention(block) () -> Void = {
                let args = (JSContext.currentArguments() as? [JSValue]) ?? []
                let text = args.map { $0.toString() ?? "undefined" }.joined(separator: " ")
                buffer.append(level, text)
                Log.plugins.log(level: osType, "[\(pluginID, privacy: .public)] \(text, privacy: .public)")
            }
            console.setObject(block, forKeyedSubscript: name)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - The Winston namespace

    private func installWinston(in context: JSContext, granted: Set<PluginPermission>,
                                handler: @escaping PluginHostHandler) {
        let winston = JSValue(newObjectIn: context)!

        let host = JSValue(newObjectIn: context)!
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        host.setObject(appVersion, forKeyedSubscript: "appVersion")
        host.setObject(PluginManifest.hostAPIVersion, forKeyedSubscript: "apiVersion")
        host.setObject(Locale.current.identifier, forKeyedSubscript: "locale")
        winston.setObject(host, forKeyedSubscript: "host")

        var capabilities: Set<String> = ["storage"]
        if granted.contains(.libraryRead) { capabilities.formUnion(["library.list", "library.get"]) }
        if granted.contains(.libraryWrite) { capabilities.insert("library.update") }
        if granted.contains(.metadataFetch) { capabilities.insert("metadata.fetch") }
        if granted.contains(.uiToast) { capabilities.insert("ui.toast") }
        let has: @convention(block) (String?) -> Bool = { name in capabilities.contains(name ?? "") }
        let capabilitiesObject = JSValue(newObjectIn: context)!
        capabilitiesObject.setObject(has, forKeyedSubscript: "has")
        winston.setObject(capabilitiesObject, forKeyedSubscript: "capabilities")

        let storage = JSValue(newObjectIn: context)!
        installAsyncMethod(named: "get", on: storage, handler: handler) { arg0, _ in
            let key = try Self.requireString(arg0, "storage.get expects a string key")
            guard PluginStorageLimits.accepts(key: key) else {
                throw PluginError.invalidArgument("storage keys are limited to 256 UTF-8 bytes")
            }
            return .storageGet(key: key)
        }
        installAsyncMethod(named: "set", on: storage, handler: handler) { arg0, arg1 in
            let key = try Self.requireString(arg0, "storage.set expects a string key")
            let object = arg1?.toObject() ?? NSNull()
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else {
                throw PluginError.invalidArgument("storage.set value must be JSON-serializable")
            }
            guard PluginStorageLimits.accepts(key: key),
                  data.count <= PluginStorageLimits.maxValueBytes else {
                throw PluginError.invalidArgument("plugin storage key or value exceeds its size limit")
            }
            return .storageSet(key: key, valueJSON: json)
        }
        installAsyncMethod(named: "remove", on: storage, handler: handler) { arg0, _ in
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
                installAsyncMethod(named: "list", on: library, handler: handler) { arg0, _ in
                    .libraryList(searchText: Self.optionalString(Self.property("text", of: arg0)))
                }
                installAsyncMethod(named: "get", on: library, handler: handler) { arg0, _ in
                    .libraryGet(uuid: try Self.requireUUID(arg0, "library.get expects a book uuid string"))
                }
            }
            if granted.contains(.libraryWrite) {
                installAsyncMethod(named: "update", on: library, handler: handler) { arg0, arg1 in
                    let uuid = try Self.requireUUID(arg0, "library.update expects a book uuid string")
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
                    return .libraryUpdate(uuid: uuid, patch: patch)
                }
            }
            winston.setObject(library, forKeyedSubscript: "library")
        }

        if granted.contains(.metadataFetch) {
            let metadata = JSValue(newObjectIn: context)!
            installAsyncMethod(named: "fetch", on: metadata, handler: handler) { arg0, _ in
                guard let arg0, arg0.isObject else {
                    throw PluginError.invalidArgument("metadata.fetch expects an options object")
                }
                let isbn = Self.optionalString(arg0.objectForKeyedSubscript("isbn"))
                let title = Self.optionalString(arg0.objectForKeyedSubscript("title"))
                let author = Self.optionalString(arg0.objectForKeyedSubscript("author"))
                guard isbn != nil || title != nil else {
                    throw PluginError.invalidArgument("metadata.fetch needs an isbn or a title")
                }
                return .metadataFetch(isbn: isbn, title: title, author: author)
            }
            winston.setObject(metadata, forKeyedSubscript: "metadata")
        }

        if granted.contains(.uiToast) {
            let ui = JSValue(newObjectIn: context)!
            installAsyncMethod(named: "toast", on: ui, handler: handler) { arg0, arg1 in
                let message = try Self.requireString(arg0, "ui.toast expects a message string")
                let style = PluginToastStyle(rawValue: Self.optionalString(arg1) ?? "info") ?? .info
                return .toast(message: message, style: style)
            }
            winston.setObject(ui, forKeyedSubscript: "ui")
        }

        context.setObject(winston, forKeyedSubscript: "Winston" as NSString)
    }

    // MARK: - Promise plumbing

    private func installAsyncMethod(
        named name: String, on object: JSValue,
        handler: @escaping PluginHostHandler,
        decode: @escaping (JSValue?, JSValue?) throws -> PluginAPICall
    ) {
        let block: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [weak self] arg0, arg1 in
            guard let context = JSContext.current() else { return nil }
            guard let self else {
                return JSValue(newPromiseRejectedWithReason: "plugin runtime is gone", in: context)
            }
            do {
                return self.makePendingPromise(for: try decode(arg0, arg1), handler: handler, in: context)
            } catch let error as PluginError {
                return JSValue(newPromiseRejectedWithReason: Self.errorValue(error, in: context), in: context)
            } catch {
                return JSValue(newPromiseRejectedWithReason: "\(error)", in: context)
            }
        }
        object.setObject(block, forKeyedSubscript: name)
    }

    private func makePendingPromise(for call: PluginAPICall, handler: @escaping PluginHostHandler,
                                    in context: JSContext) -> JSValue? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pending.count < Self.maximumPendingHostCalls else {
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
        Task { [weak self] in
            let result = await handler(call)
            self?.complete(id, with: result)
        }
        return promise
    }

    private func complete(_ id: UInt64, with result: Result<Data?, PluginError>) {
        queue.async {
            guard let context = self.context,
                  let callbacks = self.pending.removeValue(forKey: id) else { return }
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
              let object = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else {
            return JSValue(nullIn: context)
        }
        return JSValue(object: object, in: context) ?? JSValue(nullIn: context)
    }

    private static func errorValue(_ error: PluginError, in context: JSContext) -> JSValue {
        let value = JSValue(newErrorFromMessage: error.message, in: context) ?? JSValue(newObjectIn: context)!
        value.setObject(error.code, forKeyedSubscript: "code")
        return value
    }

    // Subscripting an undefined JSValue raises a TypeError on the whole context — guard isObject first.
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
