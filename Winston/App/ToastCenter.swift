import Foundation
import Observation

@MainActor
@Observable
final class ToastCenter {
    struct Message: Identifiable, Equatable {
        enum Style: Equatable { case info, success, error }
        enum Action: Equatable {
            case reviewEditionProposals
        }
        let id = UUID()
        var text: String
        var style: Style
        var action: Action?
    }

    private(set) var messages: [Message] = []

    func post(_ text: String, style: Message.Style, action: Message.Action? = nil) {
        let message = Message(text: text, style: style, action: action)
        messages.append(message)
        Task {
            try? await Task.sleep(for: .seconds(5))
            messages.removeAll { $0.id == message.id }
        }
    }

    func info(_ text: String)    { post(text, style: .info) }
    func success(_ text: String) { post(text, style: .success) }
    func error(_ text: String)   { post(text, style: .error) }

    func dismiss(_ id: UUID) { messages.removeAll { $0.id == id } }
}
