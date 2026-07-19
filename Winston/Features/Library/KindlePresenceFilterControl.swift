import SwiftUI

struct KindlePresenceFilterControl: View {
    @Binding var selection: KindlePresenceFilter

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Label("Kindle", systemImage: "ipad.landscape")
                .font(theme.label(size: 11))
                .foregroundStyle(theme.textSecondary)

            Picker("Kindle", selection: $selection) {
                ForEach(KindlePresenceFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("library.kindlePresenceFilter")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }
}

private extension KindlePresenceFilter {
    var label: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .onKindle: "On Kindle"
        case .notOnKindle: "Not on Kindle"
        }
    }
}
