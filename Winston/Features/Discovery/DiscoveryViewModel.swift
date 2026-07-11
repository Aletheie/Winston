import Foundation
import Observation

@MainActor
@Observable
final class DiscoveryViewModel {
    enum Phase: Equatable {
        case disabledOnline
        case disabledToken
        case loading
        case loaded([DiscoveryBook])
        case empty
        case failed
    }

    private let settings: AppSettings
    private let service: any DiscoveryFetching

    var selectedGenre: DiscoveryGenre = .default
    private(set) var phase: Phase = .loading

    private var cache: [DiscoveryGenre: [DiscoveryBook]] = [:]

    private var loadGeneration = 0
    private var credentialReloadTask: Task<Void, Never>?

    init(settings: AppSettings, service: any DiscoveryFetching = DiscoveryService()) {
        self.settings = settings
        self.service = service
    }

    var isOnlineEnabled: Bool { settings.onlineMetadataEnabled }

    func select(_ genre: DiscoveryGenre) {
        guard genre != selectedGenre else { return }
        selectedGenre = genre
    }

    func load() async {
        let genre = selectedGenre

        guard settings.onlineMetadataEnabled else {
            phase = .disabledOnline
            return
        }
        if let cached = cache[genre] {
            phase = cached.isEmpty ? .empty : .loaded(cached)
            return
        }

        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading

        let result = await service.books(matching: genre.queryTerm, token: settings.hardcoverToken)

        guard generation == loadGeneration, genre == selectedGenre else { return }

        switch result {
        case .needsToken:
            phase = .disabledToken
        case .failed:
            phase = .failed
        case .books(let list):
            cache[genre] = list
            phase = list.isEmpty ? .empty : .loaded(list)
        }
    }

    func retry() async {
        cache[selectedGenre] = nil
        await load()
    }

    func hardcoverCredentialDidChange(delay: Duration = .milliseconds(500)) {
        invalidateLoads()
        credentialReloadTask?.cancel()
        credentialReloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.load()
        }
    }

    func onlineSettingDidChange() {
        invalidateLoads()
        credentialReloadTask?.cancel()
        Task { await load() }
    }

    func reset() {
        invalidateLoads()
    }

    private func invalidateLoads() {
        loadGeneration += 1
        cache.removeAll()
    }
}

#if DEBUG
extension DiscoveryViewModel {
    static func preview(_ phase: Phase) -> DiscoveryViewModel {
        let vm = DiscoveryViewModel(settings: AppSettings())
        vm.phase = phase
        return vm
    }
}
#endif
