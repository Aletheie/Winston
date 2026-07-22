import Foundation
import OSLog

nonisolated final class DispatchQueueSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }
}

nonisolated enum Log {
    static let subsystem = "cz.annajung.Winston"

    static let conversion = Logger(subsystem: subsystem, category: "conversion")
    static let device = Logger(subsystem: subsystem, category: "device")
    static let metadata = Logger(subsystem: subsystem, category: "metadata")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let plugins = Logger(subsystem: subsystem, category: "plugins")
    static let search = Logger(subsystem: subsystem, category: "search")

    static let ui = Logger(subsystem: subsystem, category: "ui")

    static let conversionSignposter = OSSignposter(subsystem: subsystem, category: "conversion")
    static let deviceSignposter = OSSignposter(subsystem: subsystem, category: "device")
    static let librarySignposter = OSSignposter(subsystem: subsystem, category: "library")
    static let metadataSignposter = OSSignposter(subsystem: subsystem, category: "metadata")
    static let persistenceSignposter = OSSignposter(subsystem: subsystem, category: "persistence")
    static let searchSignposter = OSSignposter(subsystem: subsystem, category: "search")
}
