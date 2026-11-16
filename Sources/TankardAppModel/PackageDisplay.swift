import Foundation
import TankardCore

/// The segmented filter above the table.
public enum PackageFilter: String, CaseIterable, Identifiable, Sendable {
    case all, upgrades, source, newer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .upgrades: return "Upgrades"
        case .source: return "From source"
        case .newer: return "Newer"
        }
    }

    public func includes(_ p: Package) -> Bool {
        switch self {
        case .all: return true
        case .upgrades: return p.upgradeAvailable
        case .source: return p.status == .source
        case .newer: return p.status == .newer
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
            case (true, .intelbrew): return "Intelbrew bottle"
            case (true, .homebrew): return "Homebrew bottle"
            default: return "Bottle"
            }
        case .source: return "Built from source"
        case .newer: return intelbrewMode ? "Newer than Intelbrew" : "Newer than tap"
        case .noBottle: return "No bottle yet"
        case .cask: return "Cask"
        }
    }

    /// A short second line under the name, only when it says something the
    /// columns don't.
    var subtitle: String? {
        var parts: [String] = []
        if pinned { parts.append("Pinned") }
        if disabled { parts.append("Disabled") } else if deprecated { parts.append("Deprecated") }
        if upgradeAvailable && kind == .formula && upgradeHasBottle != true {
            parts.append("Upgrade builds from source")
        } else if status == .noBottle {
            parts.append("No bottle for this Mac; reinstalling compiles")
        }
        if status == .newer, let current = currentVersion {
            parts.append("Tap has \(current)")
        }
        if autoUpdates == true && kind == .cask { parts.append("Updates itself") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    public static func arguments(_ action: SessionAction, for p: Package) -> [String] {
        switch action {
        case .upgrade: return upgradeArguments(for: p)
        case .install: return installArguments(kind: p.kind, qualifiedName: p.qualifiedName)
        case .uninstall: return uninstallArguments(for: p)
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

/// Spots brew output that means a step needed sudo. The app has no way to
/// type a password (stdin is /dev/null), so it tells the user to run the
/// command in Terminal instead.
public enum SudoDetector {
    static let markers = [
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
        var parts = ["\(s.installed) installed"]
        if intelbrewMode {
            parts.append("\(s.intelbrewBottled) Intelbrew bottle\(s.intelbrewBottled == 1 ? "" : "s")")
            let others = s.bottled - s.intelbrewBottled
            if others > 0 { parts.append("\(others) Homebrew bottle\(others == 1 ? "" : "s")") }
        } else {
            parts.append("\(s.bottled) bottle\(s.bottled == 1 ? "" : "s")")
        }
        parts.append("\(s.source) from source")
        if s.newer > 0 || intelbrewMode { parts.append("\(s.newer) newer") }
        if s.noBottle > 0 { parts.append("\(s.noBottle) no bottle") }
        if s.casks > 0 { parts.append("\(s.casks) cask\(s.casks == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// ("5 upgrades ready", "(4 with bottles, 1 compiles)"), or nil when none.
    public static func upgrades(_ s: StatusSummary) -> (String, String)? {
        guard s.upgrades > 0 else { return nil }
        var detail = ["\(s.upgradesWithBottle) with bottles"]
        if s.upgradesFromSource > 0 { detail.append("\(s.upgradesFromSource) compile\(s.upgradesFromSource == 1 ? "s" : "")") }
        if s.caskUpgrades > 0 { detail.append("\(s.caskUpgrades) cask\(s.caskUpgrades == 1 ? "" : "s")") }
        return ("\(s.upgrades) upgrade\(s.upgrades == 1 ? "" : "s") ready", "(\(detail.joined(separator: ", ")))")
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
        let core = fork.coreOrigin ?? "none (API mode)"
        help = "core: \(core)\(fork.coreBranch.map { " (\($0))" } ?? "")\nbrew: \(fork.brewOrigin ?? "unknown")"
            + (fork.brewNewestTag.map { "\nnewest brew tag: \($0) (\(fork.brewNewestTagSource ?? "local"))" } ?? "")
        if !fork.coreIsFork {
            level = .problem
            text = fork.coreTapPath == nil ? "Core: API mode, not the Intelbrew fork" : "Core: not the Intelbrew fork"
        } else if !fork.brewIsFork {
            level = .warning
            text = "Core: Intelbrew fork · brew: upstream (\(version))"
        } else if fork.brewAtNewestTag == false, let newest = fork.brewNewestTag {
            level = .warning
            text = "Fork: behind (\(version); \(newest) available)"
        } else if fork.brewTag == nil {
            level = .warning
            text = "Fork: not on a release tag (\(version))"
        } else {
            level = .ok
            text = "Fork: current (\(version))"
        }
    }
}

/// "just now", "2 min ago", "3 h ago", "2 days ago".
public func updatedAgo(_ date: Date, now: Date) -> String {
    let s = max(0, now.timeIntervalSince(date))
    switch s {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(s / 60)) min ago"
    case ..<86400: return "\(Int(s / 3600)) h ago"
    default:
        let d = Int(s / 86400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
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
        case .forThisMac: return "Bottle for your Mac"
        case .intelbrew: return "Intelbrew bottle ✓"
        case .fromSource: return "Builds from source"
        case .cask: return "Cask"
        case .unknown: return detailsLoaded ? "Unknown" : "Checking…"
        }
    }

    /// `brew install --formula homebrew/core/xz`
    var installDisplay: String { BrewCommands.display(BrewCommands.installArguments(for: self)) }
}
