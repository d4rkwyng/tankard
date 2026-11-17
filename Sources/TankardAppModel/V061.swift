import Foundation
import TankardCore

// 0.6.1: the More filter as a standard picker, settings explanations on
// click (ⓘ), and the vulnerability scan's progress.

/// The explanations behind each setting's ⓘ button (and its tooltip).
public enum SettingsHelp {
    // General
    public static let showMenuBarIcon = String(localized: "A tankard with the number of upgrades ready. With it on, closing the window keeps Tankard running.")
    public static let notifyNewUpgrades = String(localized: "Runs brew update and checks for upgrades in the background. A notification appears only when new upgrades show up. Off by default.")
    public static let checkInterval = String(localized: "How often the background brew update runs, while \"Check for new versions in the background\" or \"Notify me about new upgrades\" is on.")
    /// 0.8: the background `brew update`.
    public static let backgroundUpdate = String(localized: "After the list is shown, runs brew update in the background at most once per check interval, then refreshes the upgrade counts. It waits while brew is busy, and a failure (offline) is only logged. Off when HOMEBREW_NO_AUTO_UPDATE is set. On by default.")
    public static let openAtLogin = String(localized: "Opens Tankard when you log in, as a macOS login item.")

    // Upgrades
    public static let includeSelfUpdatingApps = String(localized: "Also lists apps that update themselves (casks with auto_updates) or always download the newest version, as brew outdated --greedy does. These apps usually keep themselves current, so this is off by default.")
    public static let dontQuitApps = String(localized: "By default brew quits a running app before upgrading its cask and opens it again afterwards. With this on, Tankard sets HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 for cask upgrades (shown in the command): the app keeps running, and the new version starts the next time you open it.")
    public static let scanOnRefresh = String(localized: "Runs brew vulns after each refresh. ") + InsightSettings.scanPrivacyNote + String(localized: " Casks aren't checked. A scan that runs longer than a minute is stopped. Scan Now runs one scan whenever you ask. Off by default.")
    public static let notifyNewVulnerabilities = String(localized: "Off by default. Shows a notice in the menu-bar menu when a scan finds vulnerabilities that weren't there before. Scan Now (here) or Homebrew ▸ Scan for Vulnerabilities runs one scan whenever you ask.")

    // Upgrades → Automatic updates
    public static let autoUpgrade = String(localized: "Runs only while Tankard is running, on AC power, after \(Int(AutoUpdatePolicy.idleThreshold / 60)) minutes without keyboard or mouse input. A run that was missed (the Mac was asleep or Tankard wasn't open) happens once, at the next chance. Off by default.")
    public static var safeMode: String { String(localized: "Safe mode (always on):") + "\n" + AutoUpdateSafeMode.rules.map { "• " + $0 }.joined(separator: "\n") }
    public static let bumpRule = String(localized: "Compares versions as brew does. Packages that don't qualify are skipped and logged, to upgrade by hand. Versions that can't be compared (dates, letters) upgrade automatically only under All versions.")

    /// Every explanation (tests: none is empty).
    public static var all: [String] {
        [showMenuBarIcon, backgroundUpdate, notifyNewUpgrades, checkInterval, openAtLogin,
         includeSelfUpdatingApps, dontQuitApps, scanOnRefresh, notifyNewVulnerabilities,
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
