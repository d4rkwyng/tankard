import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3: what a click in the menu-bar panel leaves the main window showing.

@MainActor
struct MenuBarNavigationTests {
    /// The Intel demo: upgrades listed in the panel, and openssl@4 and
    /// expat vulnerable once its scan ran.
    func demoStore() async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: scanningSettings())
        await store.start()
        await store.insights.waitForIdle()
        return store
    }

    func panelRows(_ store: AppStore) -> [MenuBarSummary.Row] {
        MenuBarSummary(packages: store.report?.packages).rows
    }

    /// From Discover, with a search and a More filter: Installed, no
    /// search, All, the package selected and in the rows, a scroll asked for.
    @Test func packageRowFromAnywhereSelectsIt() async throws {
        let store = await demoStore()
        let row = try #require(panelRows(store).first)
        store.moreFilterSelection = .hasNotes
        store.search = "zzz-nothing"
        store.tab = .discover
        store.tabChanged(to: .discover)   // what the window's onChange does
        store.selection = nil
        let before = store.revealRequest

        store.showFromMenuBar(.package(row.id))
        store.tabChanged(to: store.tab)

        #expect(store.tab == .installed)
        #expect(store.search.isEmpty)
        #expect(store.filter == .all)
        #expect(store.selection == row.id)
        #expect(store.selectedPackage?.name == row.name)
        #expect(store.visiblePackages.contains { $0.id == row.id })
        #expect(store.revealRequest == before + 1)
    }

    /// A More filter is cleared even when it would show the package
    /// (the Vulnerable list and openssl@4).
    @Test func moreFilterIsClearedEvenWhenItMatches() async throws {
        let store = await demoStore()
        let p = try #require(store.packages.first { $0.name == "openssl@4" })
        #expect(p.isVulnerable && p.isUpgradeTarget)
        store.moreFilterSelection = .vulnerable
        store.showFromMenuBar(.package(p.id))
        #expect(store.filter == .all)
        #expect(store.moreFilterSelection == nil)
        #expect(store.selection == p.id)
    }

    /// Upgrades lists every package the panel does, so it stays; a segment
    /// that hides the package goes back to All.
    @Test func segmentedFilterStaysOnlyIfItShowsThePackage() async throws {
        let store = await demoStore()
        let rows = panelRows(store)
        #expect(!rows.isEmpty)
        for row in rows {
            store.filter = .upgrades
            store.showFromMenuBar(.package(row.id))
            #expect(store.filter == .upgrades)
            #expect(store.selection == row.id)
            #expect(store.visiblePackages.contains { $0.id == row.id }, "\(row.name) hidden under Upgrades")
        }
        let p = try #require(store.packages.first { $0.id == rows[0].id })
        let hiding = try #require([PackageFilter.newer, .source, .bottleAvailable].first { !$0.includes(p) })
        store.filter = hiding
        store.showFromMenuBar(.package(p.id))
        #expect(store.filter == .all)
        #expect(store.visiblePackages.contains { $0.id == p.id })
    }

    /// A second click on the same row changes and notifies nothing the
    /// window draws from, only asks for the scroll again.
    @Test func repeatClickWritesNothing() async throws {
        let store = await demoStore()
        let row = try #require(panelRows(store).first)
        store.showFromMenuBar(.package(row.id))
        let reveal = store.revealRequest
        let notified = Flag()
        withObservationTracking { _ = (store.tab, store.filter, store.search, store.selection) } onChange: { notified.set() }
        store.showFromMenuBar(.package(row.id))
        #expect(!notified.value)
        #expect(store.revealRequest == reveal + 1)
    }

    /// A package gone since the panel was drawn: the Upgrades list, the
    /// selection left alone, no scroll.
    @Test func missingPackageShowsUpgrades() async throws {
        let store = await demoStore()
        let kept = try #require(store.packages.first?.id)
        store.selection = kept
        store.tab = .discover
        let before = store.revealRequest
        store.showFromMenuBar(.package("homebrew/core/not-installed"))
        #expect(store.tab == .installed)
        #expect(store.filter == .upgrades)
        #expect(store.selection == kept)
        #expect(store.revealRequest == before)
    }

    /// "N upgrades ready": Installed, Upgrades, no search; the selection stays.
    @Test func headerShowsUpgrades() async throws {
        let store = await demoStore()
        store.moreFilterSelection = .pinned
        store.search = "curl"
        store.tab = .services
        let kept = store.packages.first?.id
        store.selection = kept
        store.showFromMenuBar(.upgrades)
        #expect(store.tab == .installed)
        #expect(store.filter == .upgrades)
        #expect(store.search.isEmpty)
        #expect(store.selection == kept)
        #expect(Set(store.visiblePackages.map(\.id)) == Set(store.packages.filter(\.upgradeAvailable).map(\.id)))
    }

    /// The scan line: Installed, Vulnerable, no search.
    @Test func scanLineShowsVulnerable() async throws {
        let store = await demoStore()
        store.filter = .upgrades
        store.search = "curl"
        store.tab = .discover
        store.showFromMenuBar(.vulnerable)
        #expect(store.tab == .installed)
        #expect(store.filter == .vulnerable)
        #expect(store.moreFilterSelection == .vulnerable)
        #expect(store.search.isEmpty)
        #expect(!store.visiblePackages.isEmpty)
        #expect(store.visiblePackages.allSatisfy { $0.isVulnerable })
    }
}
