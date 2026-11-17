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

    /// Installed, no search, and a filter that shows the package: a More
    /// filter (Pinned, Has notes…) or a segment that hides it goes back to
    /// All; Upgrades (it lists every package the panel does) stays. Then
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
        if PackageFilter.more.contains(filter) || !filter.includes(p) { filter = .all }
        if selection != p.id { selection = p.id }
        revealRequest &+= 1
    }
}
