import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

// 0.8.3: the Installed search understands a pasted brew command, and an
// empty result offers the same search in Discover.

@MainActor
struct InstalledSearchTests {
    func rig() async throws -> (AppStore, URL) {
        let dir = try tempDir()
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { _, _ in 0 }
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil,
                                         logURL: dir.appendingPathComponent("log"), hardware: .intel)
        let store = AppStore(deps: deps)
        await store.start()
        return (store, dir)
    }

    @Test func pastedCommandFindsTheInstalledPackage() async throws {
        let (store, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.search = "xz"
        let plain = store.visiblePackages.map(\.id)
        #expect(!plain.isEmpty)
        store.search = "brew install xz"
        #expect(store.visiblePackages.map(\.id) == plain)
        #expect(store.searchTerm == "xz")
        store.search = "brew upgrade --formula xz"
        #expect(store.visiblePackages.map(\.id) == plain)
        #expect(!store.searchFindsNothingInstalled)
    }

    @Test func nothingInstalledOffersDiscover() async throws {
        let (store, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.search = "brew install --cask zzz-not-here"
        #expect(store.visiblePackages.isEmpty)
        #expect(store.searchFindsNothingInstalled)
        #expect(store.searchTerm == "zzz-not-here")
        let d = try #require(store.searchDiscover(for: store.searchTerm))
        #expect(store.tab == .discover)
        #expect(d.query == "zzz-not-here")
        #expect(store.discover === d)
    }

    @Test func otherFilterHidingAMatchIsNotNothingInstalled() async throws {
        let (store, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.filter = .pinned
        store.search = "xz"
        #expect(store.visiblePackages.isEmpty)
        // xz is installed, just not in this filter: the plain "No matches".
        #expect(!store.searchFindsNothingInstalled)
        store.search = ""
        #expect(!store.searchFindsNothingInstalled)
        // deps:/uses: lists are not searches for a name.
        store.search = "deps:zzz"
        #expect(!store.searchFindsNothingInstalled)
    }
}
