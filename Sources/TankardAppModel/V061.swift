import Foundation
import TankardCore

// 0.6.1: the More filter as a standard picker, settings explanations on
// click (ⓘ), and the vulnerability scan's progress.

/// The explanations behind each setting's ⓘ button (and its tooltip).
public enum SettingsHelp {
    // General
    public static let showMenuBarIcon = String(localized: "Shows a tankard icon with the number of upgrades ready. While it's on, closing the window keeps Tankard running.")
    /// 0.8.6: the count next to the icon.
    public static let showMenuBarCount = String(localized: "Off: the menu bar shows only the tankard, full when upgrades are ready. The number stays in its tooltip and in the menu. On by default.")
    /// 0.8.1: Hide Dock icon when the window is closed.
    public static let hideDockIcon = String(localized: "With every Tankard window closed, the Dock icon and the app menu go away and Tankard stays in the menu bar; opening a window brings them back. Needs \"Show Tankard in the menu bar\". On by default.")
    public static let notifyNewUpgrades = String(localized: "Checks for new versions now and then and tells you when upgrades are ready. While the Tankard window is in front, the list shows them instead. Off by default.")
    public static let checkInterval = String(localized: "How often Tankard checks for new versions in the background.")
    /// 0.8: the background `brew update`.
    public static let backgroundUpdate = String(localized: "Checks Homebrew for new versions in the background, so the upgrade counts stay current. If it can't (offline), it tries again later. On by default.")
    public static let openAtLogin = String(localized: "Opens Tankard when you log in, as a macOS login item.")

    // Upgrades
    public static let includeSelfUpdatingApps = String(localized: "Also upgrades apps that have their own updater, like Chrome, in Upgrade All and automatic updates. Off, Tankard leaves them to their own updater even when Homebrew has a newer version: they show with ⟳ but aren't counted or upgraded unless you upgrade one yourself.")
    public static let dontQuitApps = String(localized: "Normally an open app is closed while it upgrades and opened again afterwards. With this on, it keeps running and the new version starts the next time you open it.")
    public static let scanOnRefresh = String(localized: "Checks your command-line tools for known security problems after each refresh. ") + InsightSettings.scanPrivacyNote + String(localized: " Apps aren't checked. Scan Now checks once, whenever you ask. Off by default.")
    /// 0.7: Keep the previous version after upgrades.
    public static let keepPreviousVersion = String(localized: "Keeps the old version on disk after an upgrade, so Restore Points can switch back to it. Uses extra space. Clean Up leaves these old versions alone while this is on; turn it off first to remove them. Apps (casks) always replace the old version. Off by default.")
    public static let notifyNewVulnerabilities = String(localized: "Off by default. Shows a notice in the menu-bar menu when a scan finds vulnerabilities that weren't there before. Scan Now (here) or Homebrew ▸ Scan for Vulnerabilities runs one scan whenever you ask.")

    // Upgrades → Automatic updates
    public static let autoUpgrade = String(localized: "Runs only while Tankard is running, on AC power, after \(Int(AutoUpdatePolicy.idleThreshold / 60)) minutes without keyboard or mouse input. A run that was missed (the Mac was asleep or Tankard wasn't open) happens once, at the next chance. Off by default.")
    public static var safeMode: String { String(localized: "Safe mode (always on):") + "\n" + AutoUpdateSafeMode.rules.map { "• " + $0 }.joined(separator: "\n") }
    public static let bumpRule = String(localized: "Compares versions as brew does. Packages that don't qualify are skipped and logged, to upgrade by hand. Versions that can't be compared (dates, letters) upgrade automatically only under All versions.")

    /// Every explanation (tests: none is empty).
    public static var all: [String] {
        [showMenuBarIcon, hideDockIcon, backgroundUpdate, notifyNewUpgrades, checkInterval, openAtLogin,
         includeSelfUpdatingApps, dontQuitApps, keepPreviousVersion, scanOnRefresh, notifyNewVulnerabilities,
         autoUpgrade, safeMode, bumpRule]
    }
}

extension AppStore {
    /// The More picker's selection: the filter when it is one of
    /// `PackageFilter.more`, else nil ("More"). Only a real change to a
    /// More filter is written, so a picker writing back its value (or nil)
    /// invalidates nothing.
    public var moreFilterSelection: PackageFilter? {
        get { PackageFilter.more.contains(filter) ? filter : nil }
        set {
            guard let f = newValue, PackageFilter.more.contains(f), f != filter else { return }
            filter = f
        }
    }

    /// Leaving the Installed tab clears a More filter (Has notes, Pinned…),
    /// so Installed comes back showing All instead of a filter the owner
    /// no longer sees in the pop-up's label. The segmented filters stay.
    public func tabChanged(to tab: MainTab) {
        if tab != .installed, PackageFilter.more.contains(filter) { filter = .all }
    }

    /// Installed formulae (what brew vulns checks; casks aren't).
    public var formulaCount: Int { packages.filter { $0.kind == .formula }.count }
}

/// How the last vulnerability scan this session ended.
public enum ScanOutcome: Equatable, Sendable {
    case done(checked: Int, found: Int, complete: Bool)
    case stopped
    case timedOut
}

/// The scan's progress line.
public enum ScanProgressText {
    /// "Scanning 42 formulae…"
    public static func running(formulae: Int) -> String {
        formulae > 0 ? (formulae == 1 ? String(localized: "Scanning \(formulae) formula…") : String(localized: "Scanning \(formulae) formulae…")) : String(localized: "Scanning…")
    }

    /// "0:07", "1:02".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "Scanned 42 · found 2", "… · partial scan", "Scan stopped".
    public static func outcome(_ o: ScanOutcome) -> String {
        switch o {
        case .done(let checked, let found, let complete):
            return String(localized: "Scanned \(checked) · found \(found)") + (complete ? "" : String(localized: " · partial scan"))
        case .stopped: return String(localized: "Scan stopped")
        case .timedOut: return String(localized: "Scan timed out")
        }
    }
}
