import SwiftUI

struct KindlePresenceFilterControl: View {
    @Binding var selection: KindlePresenceFilter

    var body: some View {
        Menu {
            ForEach(KindlePresenceFilter.allCases) { filter in
                Button {
                    selection = filter
                } label: {
                    if selection == filter {
                        Label {
                            Text(filter.label)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(filter.label)
                    }
                }
            }
        } label: {
            Label("Kindle", systemImage: "ipad.landscape")
                .labelStyle(.iconOnly)
        }
        .help("Kindle")
        .accessibilityLabel("Kindle")
        .accessibilityValue(Text(selection.label))
        .accessibilityIdentifier("library.kindlePresenceFilter")
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
