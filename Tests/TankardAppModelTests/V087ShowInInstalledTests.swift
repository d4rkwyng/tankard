import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.7 (B2): Discover's Show in Installed only switched the tab and the
// selection. With "aws-c-auth" still in the Installed search, the detail
// pane showed the cask just installed but the list didn't.
@MainActor
struct V087ShowInInstalledTests {
    func demoStore() async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: testSettings())
        await store.start()
        return store
    }

    @Test func aSearchThatHidesThePackageIsCleared() async throws {
        let store = await demoStore()
        let target = try #require(store.packages.first { $0.kind == .cask })
        let other = try #require(store.packages.first { $0.kind == .formula && !AppStore.matches($0, target.name.lowercased()) && !AppStore.matches(target, $0.name.lowercased()) })
        store.search = other.name
        #expect(!store.visiblePackages.contains { $0.id == target.id })
        store.tab = .discover
        let before = store.revealRequest

        store.showInInstalled(target.id)

        #expect(store.tab == .installed)
        #expect(store.search.isEmpty)
        #expect(store.selection == target.id)
        #expect(store.visiblePackages.contains { $0.id == target.id })
        #expect(store.revealRequest == before + 1) // the table scrolls to it
    }

    @Test func aSearchThatShowsThePackageStays() async throws {
        let store = await demoStore()
        let target = try #require(store.packages.first { $0.kind == .cask })
        store.search = target.name
        store.tab = .discover
        store.showInInstalled(target.id)
        #expect(store.search == target.name)
        #expect(store.selection == target.id)
        #expect(store.visiblePackages.contains { $0.id == target.id })
    }

    @Test func aFilterThatHidesThePackageGoesBackToAll() async throws {
        let store = await demoStore()
        let target = try #require(store.packages.first { !PackageFilter.upgrades.includes($0) })
        store.filter = .upgrades
        #expect(!store.visiblePackages.contains { $0.id == target.id })
        store.showInInstalled(target.id)
        #expect(store.filter == .all)
        #expect(store.visiblePackages.contains { $0.id == target.id })
    }

    /// The read after the install hasn't landed: selected anyway, with
    /// nothing left that could hide it when it does.
    @Test func aPackageNotListedYetClearsTheSearch() async throws {
        let store = await demoStore()
        store.search = "zzz"
        store.filter = .upgrades
        store.showInInstalled("cask:not-yet-listed")
        #expect(store.tab == .installed)
        #expect(store.search.isEmpty)
        #expect(store.filter == .all)
        #expect(store.selection == "cask:not-yet-listed")
    }

    /// The detail pane's dependency links go the same way (and scroll now).
    @Test func dependencyLinkRevealsAndScrolls() async throws {
        let store = await demoStore()
        let target = try #require(store.packages.first { $0.kind == .formula })
        store.search = "zzz-nothing"
        let before = store.revealRequest
        store.reveal(target.id)
        #expect(store.search.isEmpty)
        #expect(store.selection == target.id)
        #expect(store.revealRequest == before + 1)
    }
}
