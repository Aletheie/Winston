import Foundation
import Observation

@MainActor
@Observable
final class ToastCenter {
    struct Message: Identifiable, Equatable {
        enum Style: Equatable { case info, success, error }
        enum Persistence: Equatable { case automatic, untilDismissed }
        enum Action: Equatable {
            case reviewEditionProposals
            case reviewImport
            case relinkBook(UUID)
            case attachDigitalFile(UUID)
        }
        let id = UUID()
        var text: String
        var style: Style
        var action: Action?
        var persistence: Persistence
    }

    private(set) var messages: [Message] = []

    func post(
        _ text: String,
        style: Message.Style,
        action: Message.Action? = nil,
        persistence: Message.Persistence? = nil
    ) {
        let resolvedPersistence = persistence
            ?? ((style == .error || action != nil) ? .untilDismissed : .automatic)
        let message = Message(
            text: text,
            style: style,
            action: action,
            persistence: resolvedPersistence
        )
        messages.append(message)
        guard resolvedPersistence == .automatic else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.messages.removeAll { $0.id == message.id }
        }
    }

    func info(_ text: String)    { post(text, style: .info) }
    func success(_ text: String) { post(text, style: .success) }
    func error(_ text: String)   { post(text, style: .error) }

    func dismiss(_ id: UUID) { messages.removeAll { $0.id == id } }
}
