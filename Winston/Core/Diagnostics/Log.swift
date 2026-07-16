import OSLog

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
}
