import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8 QA round 2: the e2e harness's isolation, and the sheet waiting behind
// a background `brew update`.

struct APICacheRedirectTests {
    @Test func aScriptedRunKeepsDiscoversCacheInItsStateFolder() {
        let real = APICache.defaultDirectory
        #expect(real.path.hasSuffix("/Library/Caches/net.mindtricks.tankard/api"))
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-e2e-state/api", isDirectory: true)
        APICache.redirect(to: state)
        defer { APICache.redirect(to: nil) }
        #expect(APICache.defaultDirectory == state)
        // Discover's and Adopt Apps' fetchers use the default directory.
        #expect(APIFetcher().cache.directory == state)
    }
}
