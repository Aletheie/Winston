import Foundation
import Synchronization

nonisolated struct PluginLogEntry: Sendable, Identifiable, Equatable {
    enum Level: Sendable, Equatable { case debug, info, warning, error }
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

nonisolated enum PluginError: Error, Sendable, Equatable {
    case contextCreationFailed
    case loadFailed(String)
    case invalidArgument(String)
    case permissionDenied(String)
    case unavailable(String)
    case timeout

    var code: String {
        switch self {
        case .contextCreationFailed: "internal"
        case .loadFailed: "load-failed"
        case .invalidArgument: "invalid-argument"
        case .permissionDenied: "permission-denied"
        case .unavailable: "unavailable"
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

// JSC has no interruption API: on timeout the plugin is quarantined and its wedged
// queue thread is deliberately leaked (one thread, never the main actor).
nonisolated func withPluginDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeGate()
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            if gate.claim() { continuation.resume(with: result) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.claim() { continuation.resume(throwing: PluginError.timeout) }
        }
    }
}

private nonisolated final class ResumeGate: Sendable {
    private let resumed = Mutex(false)
    func claim() -> Bool {
        resumed.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
