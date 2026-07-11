import Foundation
import Observation

@MainActor
@Observable
// Write-driven invalidation token: saveQuietly() bumps it, sidebar/device aggregates rebuild on it.
final class LibraryMutationLog {
    static let shared = LibraryMutationLog()

    private(set) var revision = 0

    func bump() { revision += 1 }
}
