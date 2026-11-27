import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4: Cmd-click multi-select in the Installed table, the status bar's
// one adaptive Upgrade button, Esc to clear, the multi-selection's context
// menu, ⌘U following the selection, and no Upgrade button in the detail
// pane. The store does the work (tested here); the views' wiring is
// checked in their source, as V093AccessibilityTests does.

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// One declaration's source: from `start` up to the next top-level
/// `struct`/`enum`/`extension`/`// MARK:` (or the file's end).
private func source(_ file: String, from start: String) throws -> String {
    let src = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/\(file)"), encoding: .utf8)
    let begin = try #require(src.range(of: start), "\(start) not in \(file)")
    let rest = src[begin.upperBound...]
    let ends = ["\nstruct ", "\nenum ", "\nextension ", "\n// MARK:", "\n@MainActor\n", "\nfinal class "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(src[begin.lowerBound..<(ends.min() ?? src.endIndex)])
}

@MainActor
struct V094MultiSelectTests {
    func store() async throws -> AppStore {
        let s = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await s.start()
        #expect(s.upgradable.count >= 4, "the demo needs several upgrades")
        return s
    }

    /// Cmd-click one row after another, as the table reports it (the whole set).
    func cmdClick(_ s: AppStore, _ ps: [Package]) {
        var ids: Set<Package.ID> = []
        for p in ps {
            ids.insert(p.id)
            s.selectRows(ids)
        }
    }

    // MARK: selection

    @Test func cmdClickSelectsSeveralAndTheLastClickedIsShown() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, ups)
        #expect(s.selectedIDs == Set(ups.map(\.id)))
        // The detail pane shows one package: the last clicked.
        #expect(s.selection == ups[2].id)
        #expect(s.selectedPackage?.id == ups[2].id)
        #expect(s.selectedUpgradeTargets.map(\.id).sorted() == ups.map(\.id).sorted())
        // Cmd-click the primary off: another selected row is shown.
        s.selectRows(Set(ups.prefix(2).map(\.id)), order: ups.map(\.id))
        #expect(s.selection == ups[0].id)
        #expect(s.selectedIDs.count == 2)
        // A plain click: just that row.
        s.selectRows([ups[1].id])
        #expect(s.selection == ups[1].id)
        #expect(s.selectedIDs == [ups[1].id])
    }

    @Test func shiftClickKeepsThePrimary() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        s.selectRows([ups[0].id])
        s.selectRows(Set(ups.map(\.id)), order: ups.map(\.id))
        #expect(s.selection == ups[0].id)
        #expect(s.selectedIDs.count == 3)
    }

    @Test func aRowWithoutAnUpgradeDoesNotCount() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        let current = try #require(s.packages.first { !$0.upgradeAvailable })
        cmdClick(s, ups + [current])
        #expect(s.selectedIDs.count == 3)
        #expect(s.selection == current.id)
        #expect(s.selectedUpgradeTargets.count == 2)
        #expect(s.upgradeBarButton.scope == .selected)
        #expect(s.upgradeBarButton.count == 2)
        // Only the up-to-date row: the button upgrades everything again.
        s.selectRows([current.id])
        #expect(s.selectedUpgradeTargets.isEmpty)
        #expect(s.upgradeBarButton.scope == .all)
        #expect(s.upgradeBarButton.count == s.upgradable.count)
    }

    @Test func pinnedRowsDoNotCount() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        let i = try #require(s.report?.packages.firstIndex { $0.id == ups[1].id })
        s.report?.packages[i].pinned = true
        let pinned = try #require(s.packages.first { $0.id == ups[1].id })
        #expect(pinned.isHeld)
        let up = ups[0]
        cmdClick(s, [up, pinned])
        #expect(s.selectedUpgradeTargets.map(\.id) == [up.id])
    }

    @Test func settingTheSelectionDirectlySelectsOneRow() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, ups)
        // Show in Installed, a menu-bar row, the tests: one package.
        s.selection = ups[0].id
        #expect(s.selectedIDs == [ups[0].id])
        s.selection = nil
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func onlyTheInstalledTabCounts() async throws {
        let s = try await store()
        cmdClick(s, Array(s.upgradable.prefix(2)))
        s.tab = .discover
        #expect(s.selectedUpgradeTargets.isEmpty)
        #expect(s.upgradeBarButton.scope == .all)
    }

    @Test func aFilterDropsTheHiddenRowsOfASelection() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        let current = try #require(s.packages.first { !$0.upgradeAvailable })
        cmdClick(s, ups + [current])
        s.filter = .upgrades
        #expect(s.selectedIDs == Set(ups.map(\.id)))
        #expect(s.selection.map { Set(ups.map(\.id)).contains($0) } == true)
    }

    // MARK: the status bar's button

    @Test func theButtonSaysAllUpgradesWithNothingSelected() async throws {
        let s = try await store()
        let b = s.upgradeBarButton
        #expect(b.scope == .all)
        #expect(b.count == s.upgradable.count)
        #expect(b.title == "Upgrade")
        #expect(b.showsCountPill)
        #expect(b.help == "Upgrade the \(s.upgradable.count) packages that have a newer version, one at a time")
        #expect(b.accessibilityLabel == "Upgrade all \(s.upgradable.count) packages")
        #expect(UpgradeBarButton(scope: .all, count: 1).accessibilityLabel == "Upgrade 1 package")
    }

    @Test func theButtonSaysUpgradeNSelected() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, [ups[0]])
        var b = s.upgradeBarButton
        #expect(b.scope == .selected)
        #expect(b.title == "Upgrade 1 Selected")
        #expect(!b.showsCountPill)
        #expect(b.accessibilityLabel == "Upgrade 1 Selected")
        #expect(b.help == "Upgrade only the 1 selected package that has a newer version")
        cmdClick(s, ups)
        b = s.upgradeBarButton
        #expect(b.count == 3)
        #expect(b.title == "Upgrade 3 Selected")
        #expect(b.accessibilityLabel == "Upgrade 3 Selected")
        #expect(b.help == "Upgrade only the 3 selected packages that have a newer version")
    }

    @Test func theButtonIsUpToDateWithNothingToUpgrade() {
        let b = UpgradeBarButton(scope: .all, count: 0)
        #expect(b.isUpToDate)
        #expect(b.title == "Up to date")
        #expect(b.help == "Nothing to upgrade")
        #expect(!b.showsCountPill)
        // The progress panel's reason wins while there is something to do.
        #expect(UpgradeBarButton(scope: .selected, count: 2, blockedNote: "Busy").help == "Busy")
    }

    // MARK: Esc

    @Test func escClearsTheSelectionAndStartsNothing() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        cmdClick(s, ups)
        #expect(s.upgradeBarButton.title == "Upgrade 3 Selected")
        #expect(s.clearSelection())
        #expect(s.selectedIDs.isEmpty)
        #expect(s.selection == nil)
        #expect(s.selectedPackage == nil)
        #expect(s.upgrade == nil)
        #expect(s.upgradePlan == nil)
        #expect(!s.showUpgradeSheet)
        // Back to the all-upgrades button.
        #expect(s.upgradeBarButton.scope == .all)
        #expect(s.upgradeBarButton.title == "Upgrade")
        #expect(s.upgradeBarButton.count == s.upgradable.count)
        // Nothing left to clear.
        #expect(!s.clearSelection())
    }

    @Test func escClearsALoneSelection() async throws {
        let s = try await store()
        let up = try #require(s.upgradable.first)
        s.selection = up.id
        #expect(s.clearSelection())
        #expect(s.selection == nil)
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func escIsTheSheetsWhileOneIsUp() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        cmdClick(s, ups)
        s.requestUpgradeAllPlan()
        #expect(s.upgradePlan != nil)
        #expect(!s.clearSelection())
        #expect(s.selectedIDs.count == 2)
    }

    // MARK: the request

    @Test func upgradingASelectionQueuesOnlyThose() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(2))
        #expect(s.upgradable.count > ups.count)
        cmdClick(s, ups)
        s.upgradeFromBar()
        let queued = s.upgradePlan.map { $0.rows.map(\.package.id) } ?? s.upgrade?.packages.map(\.id)
        #expect(queued.map(Set.init) == Set(ups.map(\.id)))
    }

    @Test func upgradingWithNothingSelectedQueuesEverything() async throws {
        let s = try await store()
        s.upgradeFromBar()
        let queued = s.upgradePlan.map { $0.rows.map(\.package.id) } ?? s.upgrade?.packages.map(\.id)
        #expect(queued.map(Set.init) == Set(s.upgradable.map(\.id)))
    }

    // MARK: the menus

    @Test func theUpgradeMenuItemFollowsTheSelection() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        #expect(UpgradeMenu.selectedTitle(s.selectedUpgradeTargets) == "Upgrade Package")
        cmdClick(s, [ups[0]])
        #expect(UpgradeMenu.selectedTitle(s.selectedUpgradeTargets) == "Upgrade \(ups[0].name)")
        cmdClick(s, ups)
        #expect(UpgradeMenu.selectedTitle(s.selectedUpgradeTargets) == "Upgrade 3 Selected")
    }

    @Test func theContextMenuOfASelectionUpgradesThem() async throws {
        let s = try await store()
        let ups = Array(s.upgradable.prefix(3))
        let m = ContextMenus.installedSelection(targets: ups, busy: false)
        let item = try #require(m.compactMap(\.item).first { $0.id == "upgrade-selected" })
        #expect(item.title == "Upgrade 3 Selected")
        #expect(item.action == .upgradeSelected)
        #expect(item.isEnabled)
        #expect(ContextMenus.installedSelection(targets: ups, busy: true).first?.item?.isEnabled == false)
        let none = try #require(ContextMenus.installedSelection(targets: [], busy: false).first?.item)
        #expect(none.title == "No Upgrades Selected")
        #expect(!none.isEnabled)
    }

    // MARK: the views' wiring

    @Test func theDetailPaneHasNoUpgradeButton() throws {
        let detail = try source("DetailPane.swift", from: "struct PackageDetail: View")
        #expect(!detail.contains("Label(\"Upgrade \\(p.name)\""))
        #expect(!detail.contains("Button(action: upgrade)"))
        #expect(!detail.contains("var upgrade: () -> Void"))
        // The rest of the upgrade section stays.
        #expect(detail.contains("Text(\"Upgrade command\")"))
        #expect(detail.contains("CommandBox(command: command)"))
        #expect(detail.contains("SkipVersionRow("))
        #expect(detail.contains("UninstallSection("))
        let pane = try source("DetailPane.swift", from: "struct DetailPane: View")
        #expect(!pane.contains("upgrade: {"))
    }

    @Test func theStatusBarHasOneAdaptiveUpgradeButton() throws {
        let bar = try source("StatusBar.swift", from: "struct StatusBar: View")
        #expect(bar.contains("store.upgradeFromBar()"))
        #expect(!bar.contains("store.requestUpgrade()"))
        #expect(bar.components(separatedBy: ".buttonStyle(.primaryAction)").count == 2)
        #expect(bar.contains(".accessibilityLabel(Text(button.accessibilityLabel))"))
        #expect(bar.contains(".help(button.help)"))
        #expect(bar.contains(".disabled(button.isUpToDate || store.windowBrewActionsBlocked || store.isRefreshing)"))
    }

    @Test func theTableSelectsManyRowsAndEscClears() throws {
        let table = try source("ContentView.swift", from: "struct PackageTable: View")
        #expect(table.contains("Binding<Set<Package.ID>>"))
        #expect(table.contains("store.selectRows("))
        #expect(table.contains(".onExitCommand"))
        #expect(table.contains("store.clearSelection()"))
        // The themed painting is redone when any selected row changes.
        #expect(table.contains("h.combine(store.selectedIDs)"))
    }

    @Test func theMenusUseTheSelection() throws {
        let menu = try source("TankardApp.swift", from: "Button(\"Upgrade All…\")")
        #expect(menu.contains("UpgradeMenu.selectedTitle(store.selectedUpgradeTargets)"))
        let src = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/ContextMenus.swift"), encoding: .utf8)
        #expect(src.contains("ContextMenus.installedSelection("))
        #expect(src.contains("case .upgradeSelected"))
    }

    // MARK: localization

    @Test func theNewStringsAreTranslated() throws {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Resources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        for key in ["Upgrade %lld Selected", "Upgrade only the %lld selected packages that have a newer version",
                    "Upgrade all %lld packages", "No Upgrades Selected"] {
            let locs = try #require(strings[key]?["localizations"] as? [String: Any], "\(key)")
            for lang in ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"] {
                #expect(locs[lang] != nil, "\(key): \(lang)")
            }
        }
    }
}
