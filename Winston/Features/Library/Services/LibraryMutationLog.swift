import Foundation
import Observation

@MainActor
@Observable
// Write-driven invalidation tokens. Persistence observers can follow every save, while
// library UI follows only catalog-affecting writes and avoids rebuilding for notices/wishlist.
final class LibraryMutationLog {
    static let shared = LibraryMutationLog()

    private(set) var revision = 0
    private(set) var catalogRevision = 0

    func bump(catalogChanged: Bool = true) {
        revision &+= 1
        if catalogChanged { catalogRevision &+= 1 }
    }
}
