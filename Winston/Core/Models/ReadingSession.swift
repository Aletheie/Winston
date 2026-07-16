import Foundation
import SwiftData

nonisolated enum ReadingSessionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case reading
    case paused
    case finished
    case didNotFinish

    var id: Self { self }

    var label: String {
        switch self {
        case .reading:      String(localized: "Reading", comment: "Reading cycle status")
        case .paused:       String(localized: "Paused", comment: "Reading cycle status")
        case .finished:     String(localized: "Finished", comment: "Reading cycle status")
        case .didNotFinish: String(localized: "Did Not Finish", comment: "Reading cycle status")
        }
    }

    var systemImage: String {
        switch self {
        case .reading:      "book"
        case .paused:       "pause.circle.fill"
        case .finished:     "checkmark.circle.fill"
        case .didNotFinish: "xmark.circle.fill"
        }
    }

    var isActive: Bool {
        self == .reading || self == .paused
    }

    var readingStatus: ReadingStatus {
        switch self {
        case .reading:      .reading
        case .paused:       .paused
        case .finished:     .finished
        case .didNotFinish: .didNotFinish
        }
    }
}

@Model
final class ReadingSession {
    @Attribute(.unique) var uuid: UUID
    var startedAt: Date
    var endedAt: Date?
    var statusRaw: String
    var progress: Double
    var book: Book?

    init(
        uuid: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        status: ReadingSessionStatus = .reading,
        progress: Double = 0,
        book: Book? = nil
    ) {
        self.uuid = uuid
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.statusRaw = status.rawValue
        self.progress = min(max(progress, 0), 1)
        self.book = book
    }

    var status: ReadingSessionStatus {
        get { ReadingSessionStatus(rawValue: statusRaw) ?? .reading }
        set { statusRaw = newValue.rawValue }
    }

    func setProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
    }
}
