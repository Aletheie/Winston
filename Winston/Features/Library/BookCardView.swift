import SwiftUI
import SwiftData

struct BookCardView: View {
    let book: Book
    var isSelected = false
    var isOnDevice = false
    var isConverting = false
    var isMissing = false
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isDeleteHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                coverArea
                CardTitleStrip(book: book, isOnDevice: isOnDevice, isMissing: isMissing)
            }
            .background(.ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                    .fill(theme.surfaceGlass.opacity(0.6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                    .stroke(
                        isSelected  ? theme.accentSecondary.opacity(0.7)
                                    : (isHovered ? theme.accent.opacity(0.4) : theme.borderSubtle),
                        lineWidth: isSelected ? 2 : 1
                    )
            }

            if isHovered && !isConverting {
                deleteButton
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }

            if isConverting {
                convertingOverlay
            }
        }
        .padding(4)
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .shadow(
            color: isSelected
                ? theme.accentSecondary.opacity(0.18)
                : Color.black.opacity(isHovered ? 0.14 : 0.07),
            radius: isSelected ? 8 : (isHovered ? 6 : 3),
            y: isHovered ? 2 : 1
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.25), value: isConverting)
        .onHover { hovering in isHovered = hovering }
        .help("\(book.displayTitle)\(book.displayAuthor.map { " \u{2014} \($0)" } ?? "")")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.displayTitle), \(book.displayAuthor ?? "unknown author"), \(book.format) format")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var coverArea: some View {
        BookCoverImageView(book: book)
            .frame(maxWidth: .infinity)
            .aspectRatio(WinstonLayout.coverAspect, contentMode: .fill)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(6)
    }

    private var convertingOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous)
                .fill(theme.surface.opacity(theme.colorScheme == .dark ? 0.55 : 0.75))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous))
                .shimmering()

            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
                Text(theme.usesTerminalCopy ? "converting..." : "Converting\u{2026}")
                    .font(theme.label(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(theme.borderSubtle, lineWidth: 1))
        }
        .clipShape(RoundedRectangle(cornerRadius: WinstonLayout.cornerLarge, style: .continuous))
        .padding(4)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Text("\u{2715}")
                .font(theme.label(size: 11, weight: .bold))
                .foregroundStyle(isDeleteHovered ? theme.destructive : theme.textPrimary)
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(
                        isDeleteHovered ? theme.destructive.opacity(0.6) : theme.borderSubtle,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .padding(8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isDeleteHovered = hovering }
        }
        .accessibilityLabel("Delete \(book.displayTitle)")
    }
}

private struct CardTitleStrip: View {
    let book: Book
    let isOnDevice: Bool
    let isMissing: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        let accent = theme.coverAccents(for: book).primary

        VStack(alignment: .leading, spacing: 3) {
            Text(book.displayTitle)
                .font(theme.body(size: 12, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)

            if let author = book.displayAuthor {
                Text(author)
                    .font(theme.label(size: 9))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                Text(book.format.isEmpty ? "FILE" : book.format)
                    .font(theme.label(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(accent.opacity(0.18))
                    )
                if book.readingStatus != .unread {
                    Image(systemName: book.readingStatus.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(book.readingStatus == .finished ? theme.success : theme.accent)
                        .help(book.readingStatus.label)
                }
                if isOnDevice {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accentSecondary)
                        .help("On device")
                }
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.destructive)
                        .help("File missing \u{2014} right-click to relink")
                }
                if !book.highlights.isEmpty {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accentSecondary)
                        .help("Has highlights")
                }
                if book.drmProtected == true {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                        .help("DRM\u{2011}protected \u{2014} can't be converted or sideloaded")
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

#Preview("Card") {
    BookCardView(book: Book(fileName: "neuromancer.epub", originalFileName: "Neuromancer-William-Gibson.epub")) {}
        .frame(width: 200)
        .padding(20)
        .background(ThemedBackground())
}

#Preview("Card \u{2013} Selected") {
    BookCardView(
        book: Book(fileName: "androids.pdf", originalFileName: "Do-Androids-Dream.pdf"),
        isSelected: true
    ) {}
        .frame(width: 200)
        .padding(20)
        .background(ThemedBackground())
}
