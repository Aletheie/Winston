import SwiftUI

struct SendSeriesButton: View {
    let books: [Book]

    @Environment(\.theme) private var theme
    @Environment(DeviceMonitor.self) private var deviceMonitor
    @Environment(TransferQueue.self) private var transferQueue

    var body: some View {
        let deviceFileNames = deviceMonitor.deviceFileNames
        let pendingBooks = Self.pendingSend(in: books, deviceFileNames: deviceFileNames)
        let entireSeriesIsOnDevice = Self.entireSeriesIsOnDevice(
            books,
            deviceFileNames: deviceFileNames
        )

        if deviceMonitor.isConnected, entireSeriesIsOnDevice {
            Label("Series is on the Kindle", systemImage: "checkmark.circle")
                .font(theme.label(size: 9))
                .foregroundStyle(theme.success)
        } else if deviceMonitor.isConnected, pendingBooks.isEmpty {
            Label("No sendable books", systemImage: "lock")
                .font(theme.label(size: 9))
                .foregroundStyle(theme.textTertiary)
                .help("The remaining books are DRM-protected.")
        } else {
            Button {
                transferQueue.beginSend(books: pendingBooks, via: deviceMonitor)
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Send Series to Kindle (\(pendingBooks.count))", systemImage: "paperplane")
                        .lineLimit(1)
                    Label("Send \(pendingBooks.count) to Kindle", systemImage: "paperplane")
                        .lineLimit(1)
                    Image(systemName: "paperplane")
                }
            }
            .accessibilityLabel("Send Series to Kindle (\(pendingBooks.count))")
            .disabled(!deviceMonitor.isConnected || pendingBooks.isEmpty || transferQueue.isTransferring)
            .help(helpText)
        }
    }

    static func pendingSend(in books: [Book], deviceFileNames: Set<String>) -> [Book] {
        books
            .filter {
                $0.hasDigitalFile && $0.drmProtected != true
                    && !$0.isOnDevice(fileNames: deviceFileNames)
            }
            .sorted {
                let lhs = $0.seriesIndex.flatMap(Double.init) ?? .greatestFiniteMagnitude
                let rhs = $1.seriesIndex.flatMap(Double.init) ?? .greatestFiniteMagnitude
                if lhs != rhs { return lhs < rhs }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
    }

    static func entireSeriesIsOnDevice(_ books: [Book], deviceFileNames: Set<String>) -> Bool {
        let digitalBooks = books.filter(\.hasDigitalFile)
        return !digitalBooks.isEmpty
            && digitalBooks.allSatisfy { $0.isOnDevice(fileNames: deviceFileNames) }
    }

    private var helpText: String {
        if !deviceMonitor.isConnected {
            String(localized: "Connect a Kindle to send the series.")
        } else {
            String(localized: "Sends the books of this series that aren’t on the Kindle yet (DRM-protected are skipped).")
        }
    }

}
