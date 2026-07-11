import Foundation
import Observation

@MainActor
@Observable
final class ToastCenter {
    struct Message: Identifiable, Equatable {
        enum Style: Equatable { case info, success, error }
        let id = UUID()
        var text: String
        var style: Style
    }

    private(set) var messages: [Message] = []

    func post(_ text: String, style: Message.Style) {
        let message = Message(text: text, style: style)
        messages.append(message)
        Task {
            try? await Task.sleep(for: .seconds(5))
            messages.removeAll { $0.id == message.id }
        }
    }

    func info(_ text: String)    { post(text, style: .info) }
    func success(_ text: String) { post(text, style: .success) }
    func error(_ text: String)   { post(text, style: .error) }
}
