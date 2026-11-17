import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.8.3: Homebrew ▸ Health ▸ Environment.
@MainActor
struct V083EnvironmentAppTests {
    @Test func healthListsTheEnvironmentTankardPasses() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.openHealth()
        let h = try #require(store.health)
        let rows = Dictionary(uniqueKeysWithValues: h.environment.map { ($0.key, $0) })
        // The demo user sets nothing; Tankard's own values and Intelbrew's are listed.
        #expect(rows["HOMEBREW_NO_COLOR"]?.status == .tankard(.output))
        #expect(rows["HOMEBREW_NO_AUTO_UPDATE"]?.status == .tankard(.autoUpdate))
        #expect(rows["HOMEBREW_CORE_GIT_REMOTE"]?.status == .tankard(.intelbrew))
        #expect(rows["HOMEBREW_CORE_GIT_REMOTE"]?.tankardValue == Intelbrew.coreRemote)
        #expect(h.environment.allSatisfy { $0.value == nil })
    }
}
