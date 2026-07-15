import SwiftUI
import Foundation

struct SidebarRow: View {
    let title: Text
    let systemImage: String
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Label { title } icon: { Image(systemName: systemImage) }
            .font(theme.label(size: 12))
            .badge(count)
            .lineLimit(1)
    }
}

struct DeviceSidebarRow: View {
    let info: DeviceInfo?

    @Environment(\.theme) private var theme

    var body: some View {
        if let info {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name)
                        .font(theme.label(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(detail(for: info))
                        .font(theme.label(size: 10, weight: .regular))
                        .foregroundStyle(theme.textTertiary)
                }
            } icon: {
                Image(systemName: "ipad.landscape")
                    .foregroundStyle(theme.success)
            }
        } else {
            Label(theme.usesTerminalCopy ? "NO DEVICE" : "No device", systemImage: "bolt.horizontal.circle")
                .font(theme.label(size: 12))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private func detail(for info: DeviceInfo) -> String {
        let free = ByteCountFormatter.string(fromByteCount: Int64(info.freeBytes), countStyle: .file)
        return "\(free) free \u{00B7} \(info.kind == .mtp ? "MTP" : "USB")"
    }
}

// MARK: - Collections section

struct CollectionsSection: View {
    let collections: [BookCollection]
    let smartCounts: [UUID: Int]
    let wishlistCount: Int
    let onNew: () -> Void
    let onRename: (BookCollection) -> Void
    let onDelete: (BookCollection) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            ForEach(collections) { collection in
                SidebarRow(
                    title: collection.isWishlist
                        ? theme.styledText(terminal: "WISHLIST", native: "Wishlist")
                        : Text(verbatim: collection.name),
                    systemImage: collection.isWishlist
                        ? "heart"
                        : (collection.isSmart ? "sparkles" : "tray.full"),
                    count: collection.isWishlist
                        ? wishlistCount
                        : (collection.isSmart ? smartCounts[collection.id, default: 0] : collection.books.count)
                )
                    .tag(SidebarItem.collection(collection.id))
                    .contextMenu {
                        if !collection.isSystem {
                            Button("Rename\u{2026}") { onRename(collection) }
                            Button("Delete", role: .destructive) { onDelete(collection) }
                        }
                    }
            }
        } header: {
            HStack {
                theme.styledText(terminal: "COLLECTIONS", native: "Collections")
                    .font(theme.label(size: 10, weight: .semibold))
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("New Collection")
            }
        }
    }
}

// MARK: - Browse disclosure

struct BrowseDisclosure: View {
    let terminal: String
    let native: LocalizedStringKey
    @Binding var isExpanded: Bool
    let items: [String]
    let icon: String
    let count: (String) -> Int
    let make: (String) -> SidebarItem
    let onRename: (String) -> Void
    let onDelete: ((String) -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        if !items.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(items, id: \.self) { item in
                    SidebarRow(title: Text(verbatim: item), systemImage: icon, count: count(item))
                        .tag(make(item))
                        .contextMenu {
                            Button("Rename\u{2026}") { onRename(item) }
                            if let onDelete {
                                Button("Delete Tag", role: .destructive) { onDelete(item) }
                            }
                        }
                }
            } label: {
                theme.styledText(terminal: terminal, native: native)
                    .font(theme.label(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .badge(items.count)
            }
        }
    }
}

// MARK: - Fix tips (author / series)

struct SidebarFixTip: View {
    let title: Text
    let applyHelp: Text
    let original: String
    let suggestion: String
    let onApply: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.highlight)
                title
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            Button(action: onApply) {
                HStack(spacing: 4) {
                    Text(verbatim: original)
                        .foregroundStyle(theme.textTertiary)
                        .strikethrough()
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(verbatim: suggestion)
                        .foregroundStyle(theme.textPrimary)
                }
                .font(theme.label(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(theme.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.pressable)
            .help(applyHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
