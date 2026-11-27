import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4 (review round 1): a multi-selection never keeps rows the list no
// longer shows (search, filter, refresh), and single-package navigation
// (the menu bar's package rows, Show in Installed) always collapses a
// multi-selection to that package, even when it is already the primary.

@MainActor
struct V094SelectionReconcileTests {
    func store() async throws -> AppStore {
        let s = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await s.start()
        #expect(s.upgradable.count >= 4, "the demo needs several upgrades")
        return s
    }

    func cmdClick(_ s: AppStore, _ ps: [Package]) {
        var ids: Set<Package.ID> = []
        for p in ps {
            ids.insert(p.id)
            s.selectRows(ids)
        }
    }

    /// A search term that finds `p` and none of `others`.
    func term(finding p: Package, notFinding others: [Package], in s: AppStore) throws -> String {
        let candidates = [p.fullName, p.name] + (1...p.name.count).reversed().map { String(p.name.prefix($0)) }
        let t = try #require(candidates.first { q in
            let q = q.lowercased()
            return AppStore.matches(p, q) && !others.contains { AppStore.matches($0, q) }
        }, "no term finds only \(p.name)")
        return t
    }

    // MARK: search

    @Test func aSearchDropsTheHiddenRowsAndKeepsAVisiblePrimary() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, ups)
        #expect(s.selection == ups[2].id)
        s.search = try term(finding: ups[2], notFinding: [ups[0], ups[1]], in: s)
        #expect(s.visiblePackages.contains { $0.id == ups[2].id })
        #expect(s.selectedIDs == [ups[2].id])
        #expect(s.selection == ups[2].id)
        #expect(s.selectedUpgradeTargets.map(\.id) == [ups[2].id])
        #expect(s.upgradeBarButton.title == "Upgrade 1 Selected")
        // ⌘U and the status bar queue only the visible row.
        s.upgradeFromBar()
        let queued = s.upgradePlan.map { $0.rows.map(\.package.id) } ?? s.upgrade?.packages.map(\.id)
        #expect(queued == [ups[2].id])
    }

    @Test func aSearchHidingThePrimaryPicksAVisibleSurvivorInTableOrder() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, ups)
        #expect(s.selection == ups[2].id)
        s.search = try term(finding: ups[0], notFinding: [ups[1], ups[2]], in: s)
        #expect(s.selectedIDs == [ups[0].id])
        #expect(s.selection == ups[0].id)
        #expect(s.selectedPackage?.id == ups[0].id)
    }

    @Test func aSearchHidingEveryRowClearsTheSelection() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, ups)
        s.search = "zzz-no-such-package-zzz"
        #expect(s.visiblePackages.isEmpty)
        #expect(s.selectedIDs.isEmpty)
        #expect(s.selection == nil)
        #expect(s.upgradeBarButton.scope == .all)
    }

    @Test func aFilterRespectsTheSearchToo() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        let current = try #require(s.packages.first { !$0.upgradeAvailable })
        cmdClick(s, ups + [current])
        // The filter hides `current`; the search hides ups[0] as well
        // (reconciled on the search, and the filter keeps only what both show).
        s.search = try term(finding: ups[1], notFinding: [ups[0], current], in: s)
        s.filter = .upgrades
        #expect(s.selectedIDs == [ups[1].id])
        #expect(s.selection == ups[1].id)
    }

    // MARK: single-package navigation

    @Test func aMenuBarPackageRowCollapsesASelectionOnItsPrimary() async throws {
        let s = try await store()
        s.filter = .upgrades
        let ups = Array(s.upgradable.filter { s.visiblePackages.contains($0) }.prefix(2))
        cmdClick(s, ups)
        #expect(s.selection == ups[1].id)
        #expect(s.selectedIDs.count == 2)
        s.showFromMenuBar(.package(ups[1].id))
        #expect(s.selection == ups[1].id)
        #expect(s.selectedIDs == [ups[1].id])
        #expect(s.upgradeBarButton.title == "Upgrade 1 Selected")
    }

    @Test func showInInstalledCollapsesASelectionOnItsPrimary() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        cmdClick(s, ups)
        #expect(s.selection == ups[1].id)
        s.showInInstalled(ups[1].id)
        #expect(s.selection == ups[1].id)
        #expect(s.selectedIDs == [ups[1].id])
        #expect(s.selectedUpgradeTargets.map(\.id) == [ups[1].id])
    }

    @Test func aLoneSelectionStillSurvivesASearchThatHidesIt() async throws {
        // Unchanged from before 0.9.4: a lone selection (the detail pane
        // shows it) is not dropped by a search.
        let s = try await store()
        let up = try #require(s.upgradable.first)
        s.selection = up.id
        s.search = "zzz-no-such-package-zzz"
        #expect(s.selection == up.id)
    }
}
