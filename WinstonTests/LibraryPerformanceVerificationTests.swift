import Foundation
import Testing
@testable import Winston

struct LibraryPerformanceVerificationTests {
    @Test
    func preparationArgumentsProduceAnIsolatedRequest() throws {
        let parsed = try LibraryPerformanceConfiguration.preparationRequest(arguments: [
            "Winston",
            LibraryPerformanceConfiguration.preparationArgument,
            "10000",
            "/private/tmp/WinstonLibraryPerformanceFixture",
        ])
        let request = try #require(parsed)

        #expect(request.bookCount == 10_000)
        #expect(
            request.rootDirectory
                == URL(
                    fileURLWithPath: "/private/tmp/WinstonLibraryPerformanceFixture",
                    isDirectory: true
                ).standardizedFileURL
        )
    }

    @Test
    func preparationRejectsAnUnsafeRoot() {
        #expect(throws: LibraryPerformanceError.self) {
            try LibraryPerformanceConfiguration.preparationRequest(arguments: [
                "Winston",
                LibraryPerformanceConfiguration.preparationArgument,
                "1000",
                "/",
            ])
        }
    }

    @Test
    func preparationRejectsUnsupportedDatasetSize() {
        #expect(throws: LibraryPerformanceError.self) {
            try LibraryPerformanceConfiguration.preparationRequest(arguments: [
                "Winston",
                LibraryPerformanceConfiguration.preparationArgument,
                "50001",
                "/private/tmp/WinstonLibraryPerformanceFixture",
            ])
        }
    }
}
