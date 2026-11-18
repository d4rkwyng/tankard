import Foundation
import TankardCore

/// The segmented filter above the table.
public enum PackageFilter: String, CaseIterable, Identifiable, Sendable {
    case all, upgrades, source, newer
    /// 0.3: source builds whose version has a bottle for this Mac.
    case bottleAvailable
    /// 0.4: pinned with `brew pin`.
    case pinned
    /// 0.4: "Installed by you" (0.4–0.8.1: "Requested only"): packages
    /// brew marks installed-on-request, not ones pulled in as dependencies.
    /// Every cask counts. 0.8.2: no longer also "needed by nothing" (`brew
    /// leaves -r`), which hid things you installed that something else uses.
    case leaves
    /// 0.4: open vulnerabilities from `brew vulns`; caveats from `brew info`.
    case vulnerable, hasNotes
    /// 0.6: deprecated or disabled by Homebrew.
    case deprecated

    public var id: String { rawValue }

    /// The segmented control's filters, in order; the others are in its
    /// "More" menu. 0.8.2: Bottle available moved up next to Upgrades (it
    /// is the other "something to do" filter). Which of them show:
    /// `visibleSegmented`.
    public static let segmented: [PackageFilter] = [.all, .upgrades, .bottleAvailable, .source, .newer]
    /// 0.4: the "More" menu next to the segmented control. 0.8.2:
    /// Vulnerable first.
    public static let more: [PackageFilter] = [.vulnerable, .pinned, .leaves, .hasNotes, .deprecated]
    /// 0.8.2: the segments shown even when nothing matches.
    public static let alwaysShown: Set<PackageFilter> = [.all, .upgrades]

    /// 0.8.2: the segments to show: All and Upgrades always, the others
    /// only when something matches, so the bar isn't full of zeros
    /// ("Bottle available 0"). The selected filter stays while it is
    /// selected, even at 0 (an upgrade or a refresh can empty it), so the
    /// bar doesn't jump under the mouse; it goes once the user picks
    /// another filter.
    public static func visibleSegmented(selected: PackageFilter, count: (PackageFilter) -> Int) -> [PackageFilter] {
        segmented.filter { alwaysShown.contains($0) || $0 == selected || count($0) > 0 }
    }

    /// 0.8.2: one item of the More menu: its count, and whether it can be
    /// chosen (greyed at 0, except the selected filter).
    public struct MenuItem: Equatable, Sendable, Identifiable {
        public var filter: PackageFilter
        public var count: Int
        public var isEnabled: Bool
        public var id: PackageFilter { filter }
    }

    /// 0.8.2: the More menu's items, in `more` order.
    public static func moreItems(selected: PackageFilter, count: (PackageFilter) -> Int) -> [MenuItem] {
        more.map { f in
            let n = count(f)
            return MenuItem(filter: f, count: n, isEnabled: n > 0 || f == selected)
        }
    }

    public var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .upgrades: return String(localized: "Upgrades")
        case .source: return String(localized: "From source")
        case .newer: return String(localized: "Newer")
        case .bottleAvailable: return String(localized: "Bottle available")
        case .pinned: return String(localized: "Pinned")
        case .leaves: return String(localized: "Installed by you")
        case .vulnerable: return String(localized: "Vulnerable")
        case .hasNotes: return String(localized: "Has notes")
        case .deprecated: return String(localized: "Deprecated")
        }
    }

    /// 0.8.2: what a filter means, for tooltips (nil: the title says it).
    public var help: String? {
        switch self {
        case .leaves: return String(localized: "Packages you installed yourself, not ones pulled in as dependencies")
        case .pinned: return String(localized: "Packages brew won't upgrade (brew pin)")
        default: return nil
        }
    }

    public func includes(_ p: Package) -> Bool {
        switch self {
        case .all: return true
        case .upgrades: return p.upgradeAvailable
        case .source: return p.status == .source
        case .newer: return p.status == .newer
        case .bottleAvailable: return BottleReplacement.isEligible(p)
        case .pinned: return p.pinned
        case .leaves: return p.requested
        case .vulnerable: return p.isVulnerable
        case .hasNotes: return p.hasCaveats
        case .deprecated: return p.isRetired
        }
    }
}

/// The Source column's badge.
public enum BadgeKind: Sendable, Equatable {
    case bottle      // green
    case source      // orange
    case newer       // blue
    case noBottle    // grey
    case cask        // purple
}

public extension Package {
    /// The tap-qualified name brew is given for commands, e.g.
    /// "homebrew/core/xz" or "homebrew/cask/iterm2" (the id without its kind
    /// prefix). Fully qualified so a formula and a cask, or two taps, with
    /// the same short name can't be confused.
    var qualifiedName: String {
        guard let colon = id.firstIndex(of: ":") else { return fullName }
        return String(id[id.index(after: colon)...])
    }

    var badgeKind: BadgeKind {
        switch status {
        case .bottle: return .bottle
        case .source: return .source
        case .newer: return .newer
        case .noBottle: return .noBottle
        case .cask: return .cask
        }
    }

    /// The badge text. In Intelbrew mode bottles say whose bottle it was.
    func badgeLabel(intelbrewMode: Bool) -> String {
        switch status {
        case .bottle:
            switch (intelbrewMode, bottleOrigin) {
            case (true, .intelbrew): return String(localized: "Intelbrew bottle")
            case (true, .homebrew): return String(localized: "Homebrew bottle")
            default: return String(localized: "Bottle")
            }
        case .source: return String(localized: "Built from source")
        case .newer: return intelbrewMode ? String(localized: "Newer than Intelbrew") : String(localized: "Newer than tap")
        case .noBottle: return String(localized: "No bottle yet")
        case .cask: return String(localized: "Cask")
        }
    }

    /// A short second line under the name, only when it says something the
    /// columns don't.
    var subtitle: String? {
        var parts: [String] = []
        // Pinned is the "pinned" badge next to the name (PinnedBadge), not text here.
        if disabled { parts.append(String(localized: "Disabled")) } else if deprecated { parts.append(String(localized: "Deprecated")) }
        if upgradeAvailable && kind == .formula && upgradeHasBottle != true {
            parts.append(String(localized: "Upgrade builds from source"))
        } else if BottleReplacement.isEligible(self) {
            parts.append(bottleOrigin(of: bottleURL) == .intelbrew ? String(localized: "Bottle available (Intelbrew)") : String(localized: "Bottle available"))
        } else if status == .noBottle {
            parts.append(String(localized: "No bottle for this Mac; reinstalling compiles"))
        }
        if status == .newer, let current = currentVersion {
            parts.append(String(localized: "Tap has \(current)"))
        }
        // A self-updating cask is marked with a symbol next to the name
        // (selfUpdates/selfUpdateHelp), not with text here.
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 0.8.1: a cask whose `auto_updates` is set. The Installed list marks it
    /// with a small symbol next to the name; the detail pane's Kind row says it in words.
    var selfUpdates: Bool { autoUpdates == true && kind == .cask }

    /// The tooltip for that symbol: what it means and who updates the app
    /// (the per-app choice in the detail pane).
    func selfUpdateHelp(policy: SelfUpdatePolicy, includeSelfUpdating: Bool) -> String {
        String(localized: "Updates itself (auto_updates).\nUpdates: \(policy.title(includeSelfUpdating: includeSelfUpdating))")
    }

    private func bottleOrigin(of url: String?) -> BottleOrigin? {
        url.map { StatusClassifier.bottleOrigin(url: $0) }
    }

    /// The release page for a bottle hosted on GitHub releases
    /// (…/releases/download/<tag>/<file> → …/releases/tag/<tag>). nil for
    /// other hosts (ghcr.io blobs have no page).
    var releasePageURL: URL? {
        guard let s = bottleURL, let url = URL(string: s), url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents // ["/", owner, repo, "releases", "download", tag, file]
        guard parts.count >= 7, parts[3] == "releases", parts[4] == "download" else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "github.com"
        c.path = "/" + [parts[1], parts[2], "releases", "tag", parts[5]].joined(separator: "/")
        return c.url
    }

    /// "d4rkwyng/intelbrew-core" from a GitHub release bottle URL.
    var bottleRepository: String? {
        guard let s = bottleURL, let url = URL(string: s), url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents
        return parts.count >= 3 ? "\(parts[1])/\(parts[2])" : nil
    }
}

/// Builds the commands the app runs. Arguments are literal argv, never a
/// shell string.
public enum BrewCommands {
    /// `brew upgrade --formula homebrew/core/xz` (or `--cask`). The kind
    /// flag plus the qualified name keeps formula/cask name clashes apart.
    public static func upgradeArguments(for p: Package) -> [String] {
        ["upgrade", p.kind == .cask ? "--cask" : "--formula", p.qualifiedName]
    }

    /// `brew install --formula homebrew/core/xz` (or `--cask`).
    public static func installArguments(kind: PackageKind, qualifiedName: String) -> [String] {
        ["install", kind == .cask ? "--cask" : "--formula", qualifiedName]
    }

    public static func installArguments(for e: CatalogEntry) -> [String] {
        installArguments(kind: e.kind, qualifiedName: e.qualifiedName)
    }

    /// `brew uninstall --formula homebrew/core/xz` (or `--cask`). No
    /// `--ignore-dependencies`: brew refuses too if something needs it.
    public static func uninstallArguments(for p: Package) -> [String] {
        ["uninstall", p.kind == .cask ? "--cask" : "--formula", p.qualifiedName]
    }

    /// `brew reinstall --force-bottle --formula homebrew/core/vim`.
    public static func replaceWithBottleArguments(for p: Package) -> [String] {
        BottleReplacement.arguments(qualifiedName: p.qualifiedName)
    }

    /// `brew cleanup` (the real run) and `brew cleanup -n` (the dry run).
    public static let cleanupArguments = ["cleanup"]
    public static let cleanupDryRunArguments = ["cleanup", "-n"]

    public static func arguments(_ action: SessionAction, for p: Package) -> [String] {
        switch action {
        case .upgrade: return upgradeArguments(for: p)
        case .install: return installArguments(kind: p.kind, qualifiedName: p.qualifiedName)
        case .uninstall: return uninstallArguments(for: p)
        case .replaceBottle: return replaceWithBottleArguments(for: p)
        case .cleanup: return cleanupArguments
        case .autoremove: return AutoremovePlan.runArguments
        case .tap: return TapCommands.tap(p.fullName, url: p.desc)
        case .untap: return TapCommands.untap(p.fullName)
        // A restore's commands come from its plan (RestorePoints.swift).
        case .restore: return []
        case .adopt: return AdoptCommands.arguments(qualifiedName: p.qualifiedName)
        }
    }

    public static func display(_ arguments: [String]) -> String {
        (["brew"] + arguments.map(shellQuoted)).joined(separator: " ")
    }

    /// Quotes for display/copy only (commands are never run through a shell).
    public static func shellQuoted(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func upgradeDisplay(for p: Package) -> String {
        display(upgradeArguments(for: p))
    }
}

/// Spots brew output that means a step needed sudo and didn't get it. brew
/// has no terminal (stdin is /dev/null); 0.8.3: for cask changes Tankard's
/// password dialog answers sudo (AdminPassword.swift), and when that was
/// cancelled, the password was wrong, or there was no dialog, the sheet
/// offers the command for Terminal.
public enum SudoDetector {
    static let markers = [
        // 0.8.3: sudo -A after the dialog: cancelled, or wrong three times.
        "sudo: no password was provided",
        "incorrect password attempt",
        // 0.8.3: automatic updates set HOMEBREW_NO_SUDO (cask/installer.rb,
        // system_command.rb).
        "but homebrew_no_sudo is set",
        "sudo is disabled by homebrew_no_sudo",
        "sudo: a terminal is required",
        "sudo: a password is required",
        "sudo: no tty present",
        "a terminal is required to read the password",
        "sudo: unable to read password",
        "need sudo access",
        "requires administrator",
    ]

    public static func needsSudo(_ lines: some Sequence<String>) -> Bool {
        lines.contains { line in
            let l = line.lowercased()
            return markers.contains { l.contains($0) } || l.hasPrefix("password:")
        }
    }
}

/// The text in the summary strip and the status bar.
public enum SummaryText {
    /// "20 installed · 8 Intelbrew bottles · 9 Homebrew bottles · 1 from source · 1 newer"
    public static func line(_ s: StatusSummary, intelbrewMode: Bool) -> String {
        var parts = [String(localized: "\(s.installed) installed")]
        if intelbrewMode {
            parts.append(s.intelbrewBottled == 1 ? String(localized: "\(s.intelbrewBottled) Intelbrew bottle") : String(localized: "\(s.intelbrewBottled) Intelbrew bottles"))
            let others = s.bottled - s.intelbrewBottled
            if others > 0 { parts.append(others == 1 ? String(localized: "\(others) Homebrew bottle") : String(localized: "\(others) Homebrew bottles")) }
        } else {
            parts.append(s.bottled == 1 ? String(localized: "\(s.bottled) bottle") : String(localized: "\(s.bottled) bottles"))
        }
        parts.append(String(localized: "\(s.source) from source"))
        if s.newer > 0 || intelbrewMode { parts.append(String(localized: "\(s.newer) newer")) }
        if s.noBottle > 0 { parts.append(String(localized: "\(s.noBottle) no bottle")) }
        if s.casks > 0 { parts.append(s.casks == 1 ? String(localized: "\(s.casks) cask") : String(localized: "\(s.casks) casks")) }
        return parts.joined(separator: " · ")
    }

    /// 0.6.2: `line`, then shorter forms for a narrow strip (a wide More
    /// picker, a scan in progress, a longer language), least important parts
    /// dropped first: "no bottle" and "newer", then the bottle split
    /// becomes one count, then source and casks go, leaving "20 installed".
    /// The strip shows the first that fits; hovering shows the full line.
    public static func lines(_ s: StatusSummary, intelbrewMode: Bool) -> [String] {
        let installed = String(localized: "\(s.installed) installed")
        let bottles = s.bottled == 1 ? String(localized: "\(s.bottled) bottle") : String(localized: "\(s.bottled) bottles")
        let source = String(localized: "\(s.source) from source")
        let casks = s.casks > 0 ? (s.casks == 1 ? String(localized: "\(s.casks) cask") : String(localized: "\(s.casks) casks")) : nil
        var parts = [installed]
        if intelbrewMode {
            parts.append(s.intelbrewBottled == 1 ? String(localized: "\(s.intelbrewBottled) Intelbrew bottle") : String(localized: "\(s.intelbrewBottled) Intelbrew bottles"))
            let others = s.bottled - s.intelbrewBottled
            if others > 0 { parts.append(others == 1 ? String(localized: "\(others) Homebrew bottle") : String(localized: "\(others) Homebrew bottles")) }
        } else {
            parts.append(bottles)
        }
        parts.append(source)
        if let casks { parts.append(casks) }
        let candidates = [
            line(s, intelbrewMode: intelbrewMode),
            parts.joined(separator: " · "),
            ([installed, bottles, source] + (casks.map { [$0] } ?? [])).joined(separator: " · "),
            [installed, bottles].joined(separator: " · "),
            installed,
        ]
        // Drop repeats (a summary with nothing to drop has fewer forms).
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// ("5 upgrades ready", "(4 with bottles, 1 compiles)"), or nil when none.
    public static func upgrades(_ s: StatusSummary) -> (String, String)? {
        guard s.upgrades > 0 else { return nil }
        var detail = [String(localized: "\(s.upgradesWithBottle) with bottles")]
        if s.upgradesFromSource > 0 { detail.append(s.upgradesFromSource == 1 ? String(localized: "\(s.upgradesFromSource) compiles") : String(localized: "\(s.upgradesFromSource) compile")) }
        if s.caskUpgrades > 0 { detail.append(s.caskUpgrades == 1 ? String(localized: "\(s.caskUpgrades) cask") : String(localized: "\(s.caskUpgrades) casks")) }
        return (s.upgrades == 1 ? String(localized: "\(s.upgrades) upgrade ready") : String(localized: "\(s.upgrades) upgrades ready"), "(\(detail.joined(separator: ", ")))")
    }
}

/// The Intelbrew fork line in the status bar.
public struct ForkSummary: Equatable, Sendable {
    public enum Level: Sendable { case ok, warning, problem }
    public var level: Level
    public var text: String
    public var help: String

    public init(_ fork: ForkStatus) {
        let version = fork.brewVersion.map { "Homebrew \($0)" } ?? "Homebrew"
        let core = fork.coreOrigin ?? String(localized: "none (API mode)")
        help = "core: \(core)\(fork.coreBranch.map { " (\($0))" } ?? "")\nbrew: \(fork.brewOrigin ?? "unknown")"
            + (fork.brewNewestTag.map { "\nnewest brew tag: \($0) (\(fork.brewNewestTagSource ?? "local"))" } ?? "")
        if !fork.coreIsFork {
            level = .problem
            text = fork.coreTapPath == nil ? String(localized: "Core: API mode, not the Intelbrew fork") : String(localized: "Core: not the Intelbrew fork")
        } else if !fork.brewIsFork {
            level = .warning
            text = String(localized: "Core: Intelbrew fork · brew: upstream (\(version))")
        } else if fork.brewAtNewestTag == false, let newest = fork.brewNewestTag {
            level = .warning
            text = String(localized: "Fork: behind (\(version); \(newest) available)")
        } else if fork.brewTag == nil {
            level = .warning
            text = String(localized: "Fork: not on a release tag (\(version))")
        } else {
            level = .ok
            text = String(localized: "Fork: current (\(version))")
        }
    }
}

/// "just now", "2 min ago", "3 h ago", "2 days ago".
public func updatedAgo(_ date: Date, now: Date) -> String {
    let s = max(0, now.timeIntervalSince(date))
    switch s {
    case ..<60: return String(localized: "just now")
    case ..<3600: return String(localized: "\(Int(s / 60)) min ago")
    case ..<86400: return String(localized: "\(Int(s / 3600)) h ago")
    default:
        let d = Int(s / 86400)
        return d == 1 ? String(localized: "\(d) day ago") : String(localized: "\(d) days ago")
    }
}

public extension CatalogEntry {
    /// Discover's bottle badge colour.
    var badgeKind: BadgeKind {
        switch bottle {
        case .forThisMac, .intelbrew: return .bottle
        case .fromSource: return .source
        case .cask: return .cask
        case .unknown: return .noBottle
        }
    }

    /// Discover's bottle badge text.
    var badgeLabel: String {
        switch bottle {
        case .forThisMac: return String(localized: "Bottle for your Mac")
        case .intelbrew: return String(localized: "Intelbrew bottle ✓")
        case .fromSource: return CompileWarning(context: .install).label
        case .cask: return String(localized: "Cask")
        case .unknown: return detailsLoaded ? String(localized: "Unknown") : String(localized: "Checking…")
        }
    }

    /// `brew install --formula homebrew/core/xz`
    var installDisplay: String { BrewCommands.display(BrewCommands.installArguments(for: self)) }
}
