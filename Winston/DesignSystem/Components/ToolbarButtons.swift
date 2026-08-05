import SwiftUI

struct DetailActionButton: View {
    let title: Text
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                title
            } icon: {
                Image(systemName: icon)
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.gray)
    }
}
