import SwiftUI
import Combine
import Sparkle

@MainActor
@Observable
final class SoftwareUpdater {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: Task<Void, Never>?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates

        observation = Task { [weak self] in
            guard let updater = self?.controller.updater else { return }
            for await canCheck in updater.publisher(for: \.canCheckForUpdates).values {
                self?.canCheckForUpdates = canCheck
            }
        }
    }

    deinit { observation?.cancel() }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

struct CheckForUpdatesCommand: View {
    let updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
