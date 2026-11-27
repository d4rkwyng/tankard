import Foundation
import TankardCore

// 0.8.3: the menu-bar panel's lines open the main window on what they show.

/// What a click in the menu-bar panel shows in the main window.
public enum MenuBarDestination: Equatable, Sendable {
    /// A package row: that package, selected, in Installed.
    case package(Package.ID)
    /// The "N upgrades ready" header (and "and N more…"): the Upgrades filter.
    case upgrades
    /// The scan line ("Scanned 11 · found 2"): the Vulnerable filter.
    case vulnerable
}

extension AppStore {
    /// The panel's click, after the window was opened. Writes go through
    /// the same paths as the window's own controls (`tab`, `search`,
    /// `filter`, `selection`), and only real changes are written.
    public func showFromMenuBar(_ destination: MenuBarDestination) {
        switch destination {
        case .upgrades: showUpgrades()
        case .vulnerable: showVulnerable()
        case .package(let id): showPackageFromMenuBar(id)
        }
    }

    /// Installed, no search, the Upgrades filter (0.8.8; before, the filter
    /// on screen when it showed the package, else All). Then
    /// the package is selected and the table asked to scroll to it. A
    /// package gone since the panel was drawn (upgraded, refreshed away)
    /// shows the Upgrades list instead.
    private func showPackageFromMenuBar(_ id: Package.ID) {
        guard let p = packages.first(where: { $0.id == id }) else {
            showUpgrades()
            return
        }
        if tab != .installed { tab = .installed }
        if !search.isEmpty { search = "" }
        // 0.8.8 (owner report): the panel lists upgrades, so its row opens
        // the Upgrades list with the package selected, as "and N more…"
        // does; All only for a package Upgrades wouldn't show.
        let target: PackageFilter = PackageFilter.upgrades.includes(p) ? .upgrades : .all
        if filter != target { filter = target }
        // 0.9.4 (review): one package, even when it is already the
        // primary of a multi-selection.
        if selection != p.id || selectedIDs != [p.id] { selection = p.id }
        revealRequest &+= 1
    }

    /// 0.8.7: Discover's Show in Installed (its button and context menu)
    /// and the detail pane's dependency links: Installed with the package
    /// selected and the table scrolled to it. A search that would hide it
    /// is cleared, then, if it is still hidden, the filter goes back to All
    /// (a search or filter that shows it stays). A package not in the list
    /// yet (the read after an install hasn't landed) is selected anyway,
    /// with the search and a filter cleared, so it shows when it arrives.
    /// Before, Show in Installed only switched tab and selection: after
    /// searching Installed for something else, the detail pane showed the
    /// package but the list didn't.
    public func showInInstalled(_ id: Package.ID) {
        if tab != .installed { tab = .installed }
        // 0.9.4 (review): just this package, even when it is already the
        // primary of a multi-selection.
        if selection != id || selectedIDs != [id] { selection = id }
        if packages.contains(where: { $0.id == id }) {
            func hidden() -> Bool { !visiblePackages.contains { $0.id == id } }
            if hidden(), !search.isEmpty { search = "" }
            if hidden(), filter != .all { filter = .all }
        } else {
            if !search.isEmpty { search = "" }
            if filter != .all { filter = .all }
        }
        revealRequest &+= 1
    }
}

/// 0.8.8 (gauntlet 3, B1): the segmented controls' arrow keys. The control
/// is one keyboard stop; Left and Right select the neighbouring segment and
/// stop at the ends (no wrap, as NSSegmentedControl). nil when `current`
/// isn't one of `options`: then the first (Right) or last (Left) one.
public enum SegmentedStep {
    public static func move<T: Equatable>(from current: T, in options: [T], by delta: Int) -> T? {
        guard !options.isEmpty, delta != 0 else { return nil }
        guard let i = options.firstIndex(of: current) else { return delta > 0 ? options.first : options.last }
        return options[min(max(i + delta, 0), options.count - 1)]
    }
}
