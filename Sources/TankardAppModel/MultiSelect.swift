import Foundation
import TankardCore

// 0.9.4: Cmd-click (and Shift-click) multi-select in the Installed table.
// `selectedIDs` holds every selected row; `selection` stays the one package
// the detail pane shows (the last clicked). The status bar's one Upgrade
// button adapts: with upgradable rows selected it upgrades only those
// ("Upgrade N Selected"), otherwise everything (as before).

extension AppStore {
    /// The table's selection changed to `ids` (a click, Cmd-click,
    /// Shift-click, Select All). The primary is the row just added when
    /// there is one, else the current primary if it is still selected, else
    /// the first selected row in `order` (the table's rows, top down).
    public func selectRows(_ ids: Set<Package.ID>, order: [Package.ID] = []) {
        let added = ids.subtracting(selectedIDs)
        let primary: Package.ID?
        if ids.isEmpty {
            primary = nil
        } else if added.count == 1 {
            primary = added.first
        } else if let s = selection, ids.contains(s) {
            primary = s
        } else {
            primary = order.first(where: ids.contains) ?? ids.sorted().first
        }
        adoptingRowSelection = true
        defer { adoptingRowSelection = false }
        if selectedIDs != ids { selectedIDs = ids }
        if selection != primary { selection = primary }
    }

    /// 0.9.4 (review): the rows a multi-selection keeps when the list
    /// changes (search, filter, refresh): only those still visible. The
    /// primary stays if it is visible, else the first kept row in the
    /// table's order, else none. A lone selection is left as it was (Show
    /// in Installed may select a package before its row arrives; Show
    /// Dependencies lists rows other than the selected one).
    func reconcileSelectionWithVisibleRows() {
        guard selectedIDs.count > 1 else { return }
        let order = visiblePackages.map(\.id)
        let kept = selectedIDs.intersection(order)
        guard kept != selectedIDs else { return }
        selectRows(kept, order: order)
    }

    /// Esc in the Installed table: back to no selection. Not while a
    /// sheet, a plan or the progress panel's activity is up (Esc is
    /// theirs). Returns whether it cleared anything. Starts nothing.
    @discardableResult
    public func clearSelection() -> Bool {
        guard !isSheetPresented, upgradePlan == nil, !progressPanelHoldsActivity else { return false }
        guard selection != nil || !selectedIDs.isEmpty else { return false }
        selectRows([])
        return true
    }

    /// The selected packages (Installed tab) an Upgrade can run: upgrade
    /// available and not pinned, in the list's order. Rows without an
    /// upgrade don't count.
    public var selectedUpgradeTargets: [Package] {
        guard tab == .installed else { return [] }
        return upgradeTargets(selectedIDs)
    }

    /// The packages among `ids` an Upgrade can run (a right-click's rows).
    public func upgradeTargets(_ ids: Set<Package.ID>) -> [Package] {
        guard !ids.isEmpty else { return [] }
        return packages.filter { ids.contains($0.id) && $0.isManualUpgradeTarget }
    }

    /// The status bar's Upgrade button: its label, help and VoiceOver name.
    public var upgradeBarButton: UpgradeBarButton {
        let selected = selectedUpgradeTargets
        if !selected.isEmpty {
            return UpgradeBarButton(scope: .selected, count: selected.count, blockedNote: windowBrewActionsNote)
        }
        return UpgradeBarButton(scope: .all, count: upgradable.count, blockedNote: windowBrewActionsNote)
    }

    /// The status bar's Upgrade: the selected upgrade targets when there
    /// are any, else everything upgradable. The same plan and confirmation
    /// path either way (`requestUpgrade`).
    public func upgradeFromBar() {
        let selected = selectedUpgradeTargets
        requestUpgrade(selected.isEmpty ? nil : selected)
    }
}

/// 0.9.4: the status bar's one Upgrade button, all upgrades or the selection.
public struct UpgradeBarButton: Equatable, Sendable {
    public enum Scope: Equatable, Sendable { case all, selected }
    public var scope: Scope
    /// How many packages it upgrades.
    public var count: Int
    /// Why brew buttons are off now (the progress panel), for the help.
    public var blockedNote: String?

    public init(scope: Scope, count: Int, blockedNote: String? = nil) {
        self.scope = scope
        self.count = count
        self.blockedNote = blockedNote
    }

    /// Nothing to upgrade: "Up to date", disabled.
    public var isUpToDate: Bool { count == 0 }

    /// The button's text: "Upgrade" (the count pill beside it), "Upgrade
    /// N Selected", or "Up to date".
    public var title: String {
        if isUpToDate { return String(localized: "Up to date") }
        switch scope {
        case .all: return String(localized: "Upgrade")
        case .selected: return UpgradeMenu.selectionTitle(count: count)
        }
    }

    /// The count pill: only for all upgrades (the selection's title says N).
    public var showsCountPill: Bool { scope == .all && count > 0 }

    public var help: String {
        if isUpToDate { return String(localized: "Nothing to upgrade") }
        if let blockedNote { return blockedNote }
        switch scope {
        case .all:
            return count == 1 ? String(localized: "Upgrade the 1 package that has a newer version")
                : String(localized: "Upgrade the \(count) packages that have a newer version, one at a time")
        case .selected:
            return String(localized: "Upgrade only the \(count) selected packages that have a newer version", bundle: L10n.bundle)
        }
    }

    /// What VoiceOver reads for the button ("Upgrade, 5" read the pill as
    /// a bare number).
    public var accessibilityLabel: String {
        if isUpToDate { return String(localized: "Up to date") }
        switch scope {
        case .all: return String(localized: "Upgrade all \(count) packages", bundle: L10n.bundle)
        case .selected: return UpgradeMenu.selectionTitle(count: count)
        }
    }
}

extension UpgradeMenu {
    /// 0.9.4: "Upgrade 3 Selected" (also "Upgrade 1 Selected").
    public static func selectionTitle(count: Int) -> String {
        String(localized: "Upgrade \(count) Selected", bundle: L10n.bundle)
    }

    /// 0.9.4: Homebrew ▸ Upgrade (⌘U) follows the selection: "Upgrade wget"
    /// for one target, "Upgrade 3 Selected" for several, "Upgrade Package"
    /// (off) for none.
    public static func selectedTitle(_ targets: [Package]) -> String {
        targets.count > 1 ? selectionTitle(count: targets.count) : selectedTitle(targets.first)
    }
}
