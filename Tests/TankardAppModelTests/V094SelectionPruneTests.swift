import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4 (review round 3): every refresh and every insights pass (a
// vulnerability scan landing) prunes a multi-selection to the rows the
// table still shows, in one reconciliation that looks at the selection
// count from before the prune (a removed row must not shrink it to one
// hidden survivor that the lone-selection rule then keeps). The fallback
// primary is the first survivor in the table's sort order, not the model's.

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
struct V094SelectionPruneTests {
    func store() async throws -> AppStore {
        let s = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await s.start()
        return s
    }

    func cmdClick(_ s: AppStore, _ ps: [Package]) {
        var ids: Set<Package.ID> = []
        for p in ps {
            ids.insert(p.id)
            s.selectRows(ids)
        }
    }

    /// A scan that finds an open vulnerability in each of `ps`.
    func scan(vulnerable ps: [Package]) throws -> VulnerabilityScan {
        var scan = VulnerabilityScan(json: try BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: Date())
        for p in ps {
            scan.findings[p.fullName] = [PackageVulnerability(id: "CVE-2026-\(p.name)", severity: .high)]
        }
        return scan
    }

    /// Two upgradable formulae, the first one Uninstall can remove alone.
    func twoVulnerableUpgrades(_ s: AppStore) throws -> (gone: Package, survivor: Package) {
        let formulae = s.upgradable.filter { $0.kind == .formula && $0.isManualUpgradeTarget }
        let gone = try #require(formulae.first { s.dependents(of: $0).isEmpty && !$0.pinned })
        let survivor = try #require(formulae.first { $0.id != gone.id })
        return (gone, survivor)
    }

    // MARK: refresh

    @Test func aRefreshThatRemovesOneRowAndHidesTheOtherLeavesNoHiddenTarget() async throws {
        let s = try await store()
        let (gone, survivor) = try twoVulnerableUpgrades(s)
        s.insights.scanFinished(try scan(vulnerable: [gone, survivor]))
        s.filter = .vulnerable
        #expect(Set(s.visiblePackages.map(\.id)).isSuperset(of: [gone.id, survivor.id]))
        cmdClick(s, [gone, survivor])
        #expect(s.selectedIDs == [gone.id, survivor.id])
        #expect(s.upgradeBarButton.title == "Upgrade 2 Selected")

        // A later scan clears the survivor's vulnerability; it lands
        // without redecorating the list, so the next refresh is the one
        // that both removes `gone` and hides `survivor`.
        let onUpdate = s.insights.onUpdate
        s.insights.onUpdate = nil
        s.insights.scanFinished(try scan(vulnerable: []))
        s.insights.onUpdate = onUpdate
        #expect(s.visiblePackages.contains { $0.id == survivor.id }, "not redecorated yet")

        s.uninstallRemovesOrphans = false
        s.requestUninstall(gone)
        let reads = s.refreshesCompleted
        s.startUninstall(gone)
        let session = try #require(s.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(session.failedItems.isEmpty)
        s.closeUpgrade()
        #expect(await waitForRead(s, after: reads))

        #expect(!s.packages.contains { $0.id == gone.id })
        let still = try #require(s.packages.first { $0.id == survivor.id })
        #expect(still.isManualUpgradeTarget, "still installed and upgradable")
        #expect(!s.visiblePackages.contains { $0.id == survivor.id }, "no longer vulnerable")
        // Neither the status button nor ⌘U targets the hidden survivor.
        #expect(s.selectedIDs.isEmpty)
        #expect(s.selection == nil)
        #expect(s.selectedUpgradeTargets.isEmpty)
        #expect(s.upgradeBarButton.scope == .all)
    }

    // MARK: insights

    @Test func aScanThatClearsASelectedRowsVulnerabilityDropsItFromTheBatch() async throws {
        let s = try await store()
        let formulae = s.upgradable.filter { $0.kind == .formula && $0.isManualUpgradeTarget }
        try #require(formulae.count >= 3)
        let ups = Array(formulae.prefix(3))
        s.insights.scanFinished(try scan(vulnerable: ups))
        s.filter = .vulnerable
        cmdClick(s, ups)
        #expect(s.upgradeBarButton.title == "Upgrade 3 Selected")
        #expect(s.selection == ups[2].id)

        // The scan clears the primary's vulnerability; its upgrade stays.
        s.insights.scanFinished(try scan(vulnerable: [ups[0], ups[1]]))
        #expect(s.packages.first { $0.id == ups[2].id }?.isManualUpgradeTarget == true)
        #expect(!s.visiblePackages.contains { $0.id == ups[2].id })
        #expect(s.selectedIDs == [ups[0].id, ups[1].id])
        #expect(s.selectedUpgradeTargets.map(\.id).sorted() == [ups[0].id, ups[1].id].sorted())
        #expect(s.upgradeBarButton.title == "Upgrade 2 Selected")
        let rows = s.tableRows.map(\.id)
        #expect(s.selection == rows.first { [ups[0].id, ups[1].id].contains($0) })
    }

    @Test func applyInsightsPrunesToo() async throws {
        let s = try await store()
        let formulae = s.upgradable.filter { $0.kind == .formula && $0.isManualUpgradeTarget }
        let ups = Array(formulae.prefix(2))
        try #require(ups.count == 2)
        s.insights.scanFinished(try scan(vulnerable: ups))
        s.filter = .vulnerable
        cmdClick(s, ups)
        let onUpdate = s.insights.onUpdate
        s.insights.onUpdate = nil
        s.insights.scanFinished(try scan(vulnerable: []))
        s.insights.onUpdate = onUpdate
        #expect(s.selectedIDs.count == 2, "not applied yet")
        s.applyInsights()
        #expect(s.selectedIDs.isEmpty)
        #expect(s.selection == nil)
        #expect(s.selectedUpgradeTargets.isEmpty)
    }

    // MARK: the table's sort

    @Test func theFallbackPrimaryIsTheFirstSurvivorInTheTablesSortOrder() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.filter(\.isManualUpgradeTarget).prefix(2))
        try #require(ups.count == 2)
        let current = try #require(s.packages.first { !$0.upgradeAvailable })
        // The primary (clicked last) is a row the Upgrades filter hides.
        cmdClick(s, ups + [current])
        #expect(s.selection == current.id)
        let ids: Set<Package.ID> = [ups[0].id, ups[1].id]
        // A sort whose first survivor differs from the model's order.
        let modelFirst = try #require(s.visiblePackages.first { ids.contains($0.id) })
        let sorts: [[KeyPathComparator<Package>]] = [
            [KeyPathComparator(\Package.name, comparator: .localizedStandard, order: .reverse)],
            [KeyPathComparator(\Package.name, comparator: .localizedStandard)],
        ]
        let sort = try #require(sorts.first { sort in
            s.visiblePackages.sorted(using: sort).first { ids.contains($0.id) }?.id != modelFirst.id
        })
        s.tableSortOrder = sort
        let expected = try #require(s.visiblePackages.sorted(using: sort).first { ids.contains($0.id) })
        #expect(expected.id != modelFirst.id)
        s.filter = .upgrades
        #expect(s.selectedIDs == ids)
        #expect(s.selection == expected.id)
        #expect(s.selection != modelFirst.id)
    }

    @Test func theTablesRowsAreTheVisibleRowsInItsSortOrder() async throws {
        let s = try await store()
        // Default: by name, as the Finder sorts.
        #expect(s.tableRows.map(\.id) == s.visiblePackages.sorted(using: AppStore.defaultTableSort).map(\.id))
        let reverse = [KeyPathComparator(\Package.name, comparator: .localizedStandard, order: .reverse)]
        s.tableSortOrder = reverse
        #expect(s.tableRows.map(\.id) == s.visiblePackages.sorted(using: reverse).map(\.id))
        #expect(AppStore.tableOrder(s.visiblePackages, sort: reverse).map(\.id) == s.tableRows.map(\.id))
    }

    @Test func theTableSortsThroughTheStore() throws {
        let src = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/ContentView.swift"), encoding: .utf8)
        #expect(src.contains("store.tableRows"))
        #expect(src.contains("$store.tableSortOrder"))
    }

    // MARK: Esc while something else holds it

    @Test func escIsTheSheetsWhileAnUninstallSheetIsUp() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        cmdClick(s, ups)
        s.requestUninstall(ups[0])
        #expect(s.isSheetPresented)
        #expect(!s.clearSelection())
        #expect(s.selectedIDs.count == 2)
    }

    @Test func escIsTheProgressPanelsWhileItIsUp() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        cmdClick(s, ups)
        s.activityPresentation = .progressPanel
        s.showUpgradeSheet = true
        #expect(s.showsProgressPanel)
        #expect(!s.clearSelection())
        #expect(s.selectedIDs.count == 2)
    }
}
