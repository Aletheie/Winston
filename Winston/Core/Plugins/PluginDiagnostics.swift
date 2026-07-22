import Foundation
import Synchronization

nonisolated struct PluginLogEntry: Sendable, Identifiable, Equatable {
    enum Level: String, Codable, Sendable, Equatable { case debug, info, warning, error }
    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

nonisolated final class PluginLogBuffer: Sendable {
    private let entries = Mutex<[PluginLogEntry]>([])
    private let capacity = 300

    func append(_ level: PluginLogEntry.Level, _ message: String) {
        entries.withLock { list in
            list.append(PluginLogEntry(date: .now, level: level, message: message))
            if list.count > capacity { list.removeFirst(list.count - capacity) }
        }
    }

    var snapshot: [PluginLogEntry] { entries.withLock { $0 } }
}

nonisolated enum PluginError: Error, Codable, Sendable, Equatable {
    case contextCreationFailed
    case loadFailed(String)
    case invalidArgument(String)
    case permissionDenied(String)
    case unavailable(String)
    case workerTerminated(String)
    case timeout

    var code: String {
        switch self {
        case .contextCreationFailed: "internal"
        case .loadFailed: "load-failed"
        case .invalidArgument: "invalid-argument"
        case .permissionDenied: "permission-denied"
        case .unavailable: "unavailable"
        case .workerTerminated: "worker-terminated"
        case .timeout: "timeout"
        }
    }

    var message: String {
        switch self {
        case .contextCreationFailed: "could not create a JavaScript context"
        case .loadFailed(let detail): detail
        case .invalidArgument(let detail): detail
        case .permissionDenied(let detail): detail
        case .unavailable(let detail): detail
        case .workerTerminated(let detail): detail
        case .timeout: "the operation timed out"
        }
    }
}

nonisolated enum PluginStorageLimits {
    static let maxKeyBytes = 256
    static let maxValueBytes = 256 * 1_024
    static let maxFileBytes = 2 * 1_024 * 1_024
    static let maxEntries = 512

    static func accepts(key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maxKeyBytes
    }
}
