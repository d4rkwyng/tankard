import Foundation
import Observation
import TankardCore

// v0.6 (part B): smarter auto-update rules on top of 0.5's AutoUpdate.
// "Skip this version" per package, snooze, and bump rules (all versions,
// minor and patch only, patch only). All local, all in UserDefaults.

// MARK: version bumps

/// How big a step an upgrade is, by brew's version strings.
public enum VersionBump: Equatable, Sendable {
    case patch, minor, major
    /// Dates, letters, or anything that isn't dotted numbers: can't be
    /// classified, so only "All versions" upgrades it automatically.
    case unknown

    public var title: String {
        switch self {
        case .patch: return "patch"
        case .minor: return "minor"
        case .major: return "major"
        case .unknown: return "unknown"
        }
    }

    /// Classifies `from` → `to` (installed → current). Formula revisions
    /// ("_1") are split off with the PkgVersion port: a revision-only change
    /// is a patch. Cask build suffixes after a comma ("1.2.3,456") are
    /// treated the same way.
    public static func classify(from: String, to: String) -> VersionBump {
        let a = PkgVersion(parsing: from), b = PkgVersion(parsing: to)
        guard a.version.compare(to: b.version) != nil else { return .unknown }
        if a.version.raw == b.version.raw { return a.revision == b.revision ? .unknown : .patch }
        func head(_ s: String) -> (String, String) {
            guard let i = s.firstIndex(of: ",") else { return (s, "") }
            return (String(s[..<i]), String(s[s.index(after: i)...]))
        }
        let (ha, ta) = head(a.version.raw), (hb, tb) = head(b.version.raw)
        guard let na = numbers(ha), let nb = numbers(hb) else { return .unknown }
        if na == nb { return ta != tb ? .patch : .unknown }
        // A date-like first part (2024, 20241101) isn't a major version.
        if (na.first ?? 0) >= 1000 || (nb.first ?? 0) >= 1000 { return .unknown }
        let x = na + Array(repeating: 0, count: max(0, 3 - na.count))
        let y = nb + Array(repeating: 0, count: max(0, 3 - nb.count))
        if x[0] != y[0] { return .major }
        if x[1] != y[1] { return .minor }
        return .patch
    }

    /// "1.2.3" → [1, 2, 3]; nil for anything else (letters, dashes, empty).
    static func numbers(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }
}

/// Which upgrades auto-update takes.
public enum BumpRule: String, CaseIterable, Identifiable, Sendable, Codable {
    case all, minorAndPatch, patchOnly
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All versions"
        case .minorAndPatch: return "Minor and patch only"
        case .patchOnly: return "Patch only"
        }
    }

    /// Whether this rule lets auto-update take `bump`. An unknown bump
    /// counts as "All versions" only.
    public func allows(_ bump: VersionBump) -> Bool {
        switch (self, bump) {
        case (.all, _): return true
        case (_, .unknown): return false
        case (.minorAndPatch, .major): return false
        case (.minorAndPatch, _): return true
        case (.patchOnly, .patch): return true
        case (.patchOnly, _): return false
        }
    }
}

// MARK: snooze

public enum SnoozeLength: String, CaseIterable, Identifiable, Sendable {
    case day, week, untilResumed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .day: return "For 1 Day"
        case .week: return "For 1 Week"
        case .untilResumed: return "Until Turned Back On"
        }
    }
}

// MARK: settings

/// v0.6 settings, in the same UserDefaults as `AppSettings`. Like every
/// 0.5 setting, a write of the value already there is ignored (no
/// notification, no defaults write).
@Observable @MainActor
public final class UpgradeRulesSettings {
    enum Key {
        static let skipped = "upgradeSkippedVersions"
        static let snoozeUntil = "autoUpdateSnoozeUntil"
        static let snoozeIndefinite = "autoUpdateSnoozeIndefinite"
        static let bumpRule = "autoUpdateBumpRule"
    }

    @ObservationIgnored public let defaults: UserDefaults
    /// Told after a skip is added or removed (the store re-decorates).
    @ObservationIgnored public var onSkipsChange: (() -> Void)?

    /// Package id → the exact version the user skipped.
    public var skippedVersions: [String: String] {
        get { access(keyPath: \.skippedVersions); return _skipped }
        set {
            guard newValue != _skipped else { return }
            withMutation(keyPath: \.skippedVersions) { _skipped = newValue }
            defaults.set(newValue, forKey: Key.skipped)
            onSkipsChange?()
        }
    }
    @ObservationIgnored private var _skipped: [String: String]

    /// Auto-update paused until this time.
    public var snoozeUntil: Date? {
        get { access(keyPath: \.snoozeUntil); return _snoozeUntil }
        set {
            guard newValue != _snoozeUntil else { return }
            withMutation(keyPath: \.snoozeUntil) { _snoozeUntil = newValue }
            defaults.set(newValue, forKey: Key.snoozeUntil)
        }
    }
    @ObservationIgnored private var _snoozeUntil: Date?

    /// Auto-update paused until turned back on.
    public var snoozedIndefinitely: Bool {
        get { access(keyPath: \.snoozedIndefinitely); return _snoozeIndefinite }
        set {
            guard newValue != _snoozeIndefinite else { return }
            withMutation(keyPath: \.snoozedIndefinitely) { _snoozeIndefinite = newValue }
            defaults.set(newValue, forKey: Key.snoozeIndefinite)
        }
    }
    @ObservationIgnored private var _snoozeIndefinite: Bool

    public var bumpRule: BumpRule {
        get { access(keyPath: \.bumpRule); return _bumpRule }
        set {
            guard newValue != _bumpRule else { return }
            withMutation(keyPath: \.bumpRule) { _bumpRule = newValue }
            defaults.set(newValue.rawValue, forKey: Key.bumpRule)
        }
    }
    @ObservationIgnored private var _bumpRule: BumpRule

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        _skipped = defaults.dictionary(forKey: Key.skipped) as? [String: String] ?? [:]
        _snoozeUntil = defaults.object(forKey: Key.snoozeUntil) as? Date
        _snoozeIndefinite = defaults.bool(forKey: Key.snoozeIndefinite)
        _bumpRule = BumpRule(rawValue: defaults.string(forKey: Key.bumpRule) ?? "") ?? .all
    }

    // MARK: skip this version

    /// The skipped version for this package, if it is still the one on offer.
    public func isSkipped(_ p: Package) -> Bool {
        guard let v = skippedVersions[p.id], let current = p.currentVersion else { return false }
        return v == current
    }

    /// Skip the version currently on offer.
    public func skip(_ p: Package) {
        guard p.upgradeAvailable, let v = p.currentVersion else { return }
        skippedVersions[p.id] = v
    }

    public func unskip(_ p: Package) {
        guard skippedVersions[p.id] != nil else { return }
        skippedVersions[p.id] = nil
    }

    /// Drops skips that no longer apply: a newer (or any other) version is
    /// on offer, or the package was upgraded or removed. Only called with a
    /// fresh read of every installed package.
    public func prune(_ packages: [Package], notify: Bool = true) {
        guard !_skipped.isEmpty else { return }
        let byID = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = _skipped.filter { id, v in
            guard let p = byID[id], p.upgradeAvailable, let current = p.currentVersion else { return false }
            return current == v
        }
        guard kept != _skipped else { return }
        let hook = onSkipsChange
        if !notify { onSkipsChange = nil }
        skippedVersions = kept
        onSkipsChange = hook
    }

    /// Marks the report's packages whose offered version is skipped.
    public func decorate(_ report: StatusReport) -> StatusReport {
        var r = report
        for i in r.packages.indices {
            let skipped = isSkippedRaw(r.packages[i])
            if r.packages[i].versionSkipped != skipped { r.packages[i].versionSkipped = skipped }
        }
        return r
    }

    private func isSkippedRaw(_ p: Package) -> Bool? {
        guard let v = _skipped[p.id], let current = p.currentVersion, p.upgradeAvailable, v == current else { return nil }
        return true
    }

    // MARK: snooze

    public func snooze(_ length: SnoozeLength, now: Date) {
        switch length {
        case .day: snoozedIndefinitely = false; snoozeUntil = now.addingTimeInterval(86_400)
        case .week: snoozedIndefinitely = false; snoozeUntil = now.addingTimeInterval(7 * 86_400)
        case .untilResumed: snoozeUntil = nil; snoozedIndefinitely = true
        }
    }

    public func resume() {
        snoozeUntil = nil
        snoozedIndefinitely = false
    }

    /// Paused at `now`. A snooze whose time has passed has expired.
    public func isSnoozed(now: Date) -> Bool {
        if snoozedIndefinitely { return true }
        if let until = snoozeUntil { return now < until }
        return false
    }

    /// When the snooze ends (nil: until turned back on). Only meaningful
    /// while `isSnoozed`.
    public var snoozeEnds: Date? { snoozedIndefinitely ? nil : snoozeUntil }
}

// MARK: the plan's extra rules

/// What the auto-update plan needs from the rules, as values (pure).
public struct UpgradeRuleSnapshot: Equatable, Sendable {
    public var bumpRule: BumpRule
    public var skipped: [String: String]
    public init(bumpRule: BumpRule = .all, skipped: [String: String] = [:]) {
        self.bumpRule = bumpRule
        self.skipped = skipped
    }

    /// Why the rules keep `p` out of an automatic run, or nil.
    public func skipReason(_ p: Package) -> AutoUpdateSkip? {
        guard let current = p.currentVersion else { return nil }
        if skipped[p.id] == current { return .versionSkipped(current) }
        let bump = VersionBump.classify(from: p.installedVersion, to: current)
        if !bumpRule.allows(bump) {
            return .bumpRule(from: p.installedVersion, to: current, bump: bump.title)
        }
        return nil
    }
}

public extension UpgradeRulesSettings {
    var snapshot: UpgradeRuleSnapshot { UpgradeRuleSnapshot(bumpRule: bumpRule, skipped: skippedVersions) }
}

public extension AutoUpdateText {
    /// "Snoozed until tomorrow 21:45", "Snoozed until turned back on".
    static func snoozed(until: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let until else { return "Snoozed until turned back on" }
        return "Snoozed until \(when(until, now: now, calendar: calendar))"
    }
}
