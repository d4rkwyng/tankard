import Foundation
import Observation
import TankardCore

// v0.7: restore points ("undo that upgrade").
//
// Before every upgrade session and every auto-update run, Tankard saves what
// is installed (formulae and casks with exact versions, their taps, pins).
// The last 20 are kept in Application Support/net.mindtricks.tankard/
// restore-points/ (AppPaths.bundleID), one JSON file each.
//
// What Restore can actually do, and why (brew 7.0.14):
// - A package that was removed: `brew install` it again. That installs the
//   version Homebrew has now, not necessarily the one recorded.
// - An upgraded formula, only when the old keg is still in the Cellar
//   (Homebrew's cleanup removes it after an upgrade unless
//   HOMEBREW_NO_INSTALL_CLEANUP is set; see "Keep the previous version").
//   Then two documented commands bring it back: `brew uninstall --formula X`
//   removes only the version in use (FAQ: "it will only remove the latest
//   version you have installed"), and `brew link --formula X` links the one
//   keg left (`brew link` always picks the newest remaining keg; it cannot
//   be pointed at a version). So it is offered only when the recorded
//   version is exactly the keg that would be left, the formula isn't
//   keg-only (link would need --force) or pinned, and nothing installed
//   depends on it (brew refuses that uninstall, and Homebrew doesn't support
//   mixing versions under dependents).
// - Anything else (a cleaned-up keg, a cask, a dependency) is marked "can't
//   roll back automatically", with the manual path shown, never run.

/// One package as it was.
public struct RestorePointPackage: Codable, Sendable, Equatable, Hashable {
    /// `Package.id`: "formula:homebrew/core/xz".
    public var id: String
    public var name: String
    public var fullName: String
    public var tap: String?
    public var kind: PackageKind
    public var version: String
    public var pinned: Bool
    public var requested: Bool

    public init(id: String, name: String, fullName: String, tap: String?, kind: PackageKind, version: String,
                pinned: Bool, requested: Bool) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.tap = tap
        self.kind = kind
        self.version = version
        self.pinned = pinned
        self.requested = requested
    }

    public init(_ p: Package) {
        self.init(id: p.id, name: p.name, fullName: p.fullName, tap: p.tap, kind: p.kind, version: p.installedVersion,
                  pinned: p.pinned, requested: p.requested)
    }

    public var key: String { id }

    /// `homebrew/core/xz`: the id without its kind (as `Package.qualifiedName`).
    public var qualifiedName: String {
        guard let colon = id.firstIndex(of: ":") else { return fullName }
        return String(id[id.index(after: colon)...])
    }
}

/// A saved snapshot.
public struct RestorePoint: Codable, Sendable, Equatable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        case upgrade, autoUpdate, manual
        public var title: String {
            switch self {
            case .upgrade: return String(localized: "Before upgrade")
            case .autoUpdate: return String(localized: "Before auto-update")
            case .manual: return String(localized: "Saved by hand")
            }
        }
    }

    public var id: UUID
    public var createdAt: Date
    public var reason: Reason
    /// What was about to be upgraded ("xz, git"), for the list.
    public var note: String?
    public var packages: [RestorePointPackage]
    /// Taps the installed packages came from (no `brew tap` call is made;
    /// a tap with nothing installed from it isn't listed).
    public var taps: [String]

    public init(id: UUID = UUID(), createdAt: Date, reason: Reason, note: String? = nil,
                packages: [RestorePointPackage], taps: [String]) {
        self.id = id
        self.createdAt = createdAt
        self.reason = reason
        self.note = note
        self.packages = packages
        self.taps = taps
    }

    /// The snapshot of `packages` (Tankard's own report rows).
    public static func capture(_ packages: [Package], at date: Date, reason: Reason, note: String? = nil) -> RestorePoint {
        let rows = packages.filter { !$0.id.hasPrefix("command:") }.map(RestorePointPackage.init)
            .sorted { ($0.kind.rawValue, $0.fullName) < ($1.kind.rawValue, $1.fullName) }
        let taps = Set(rows.compactMap(\.tap)).sorted()
        return RestorePoint(createdAt: date, reason: reason, note: note, packages: rows, taps: taps)
    }

    public var pins: [String] { packages.filter(\.pinned).map(\.fullName) }

    /// A Brewfile with the same packages (no versions: Brewfiles have none).
    public var brewfile: String {
        var lines = taps.filter { $0 != "homebrew/core" && $0 != "homebrew/cask" }.map { "tap \"\($0)\"" }
        lines += packages.filter { $0.kind == .formula && $0.requested }.map { "brew \"\($0.qualifiedName)\"" }
        lines += packages.filter { $0.kind == .cask }.map { "cask \"\($0.qualifiedName)\"" }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: diff

/// What changed between a restore point and now.
public struct RestoreDiff: Sendable, Equatable {
    public struct Change: Sendable, Equatable, Identifiable {
        public var then: RestorePointPackage
        public var now: Package
        public var id: String { then.key }
    }

    public var upgraded: [Change] = []
    /// Now older than then (another tool, or an earlier rollback).
    public var downgraded: [Change] = []
    public var added: [Package] = []
    public var removed: [RestorePointPackage] = []
    public var tapsAdded: [String] = []
    public var tapsRemoved: [String] = []
    public var pinsChanged: [String] = []

    public var isEmpty: Bool {
        upgraded.isEmpty && downgraded.isEmpty && added.isEmpty && removed.isEmpty
            && tapsAdded.isEmpty && tapsRemoved.isEmpty && pinsChanged.isEmpty
    }

    public static func between(_ point: RestorePoint, _ current: [Package]) -> RestoreDiff {
        let now = current.filter { !$0.id.hasPrefix("command:") }
        var byKey: [String: Package] = [:]
        for p in now { byKey[p.id] = p }
        let thenKeys = Set(point.packages.map(\.key))
        var d = RestoreDiff()
        for t in point.packages {
            guard let n = byKey[t.key] else {
                d.removed.append(t)
                continue
            }
            if n.pinned != t.pinned { d.pinsChanged.append(t.fullName) }
            guard n.installedVersion != t.version else { continue }
            if RollbackPolicy.isOlder(n.installedVersion, than: t.version) {
                d.downgraded.append(Change(then: t, now: n))
            } else {
                d.upgraded.append(Change(then: t, now: n))
            }
        }
        d.added = now.filter { !thenKeys.contains($0.id) }.sorted { $0.name < $1.name }
        let nowTaps = Set(now.compactMap(\.tap))
        d.tapsAdded = nowTaps.subtracting(point.taps).sorted()
        d.tapsRemoved = Set(point.taps).subtracting(nowTaps).sorted()
        return d
    }
}

// MARK: eligibility

/// Whether an upgrade can be undone by Tankard, and if not, why.
public enum RollbackEligibility: Sendable, Equatable {
    /// The old keg is on disk and `brew uninstall` + `brew link` bring it back.
    case automatic
    case manual(RollbackBlock)

    public var isAutomatic: Bool { self == .automatic }
}

public enum RollbackBlock: String, Sendable, Equatable, CaseIterable {
    case cask, cleanedUp, kegOnly, pinned, hasDependents, otherKegWouldLink, headVersion

    /// Short, for the row.
    public var title: String {
        switch self {
        case .cask: return String(localized: "Cask: no older version")
        case .cleanedUp: return String(localized: "Old version removed by cleanup")
        case .kegOnly: return String(localized: "Not linked into Terminal")
        case .pinned: return String(localized: "Pinned")
        case .hasDependents: return String(localized: "Other packages need it")
        case .otherKegWouldLink: return String(localized: "Another old version is installed")
        case .headVersion: return String(localized: "Built from the latest source")
        }
    }

    /// 0.8.5: the detail, saying how to keep old versions only while
    /// Tankard isn't keeping them.
    public func explanation(keepPrevious: Bool) -> String {
        if self == .cleanedUp && keepPrevious {
            return String(localized: "The older version was removed by a clean-up (Tankard's Clean Up, or Homebrew outside Tankard).")
        }
        return explanation
    }

    /// The detail, for help text.
    public var explanation: String {
        switch self {
        case .cask:
            return String(localized: "Homebrew keeps only the current cask definition, so it can't install an older version of an app.")
        case .cleanedUp:
            return String(localized: "The older version was removed after the upgrade. Turn on \"Keep the previous version after upgrades\" to keep it next time.")
        case .kegOnly:
            return String(localized: "Switching back would change which version other programs see, so Tankard leaves it to you.")
        case .pinned:
            return String(localized: "It's pinned. Unpin it first.")
        case .hasDependents:
            return String(localized: "Other installed packages need the current version, and Homebrew can't give them an older one.")
        case .otherKegWouldLink:
            return String(localized: "Another older version is also on this Mac, and Homebrew would switch to that one instead.")
        case .headVersion:
            return String(localized: "It was built from the latest source, so there is no fixed version to go back to.")
        }
    }
}

public enum RollbackPolicy {
    /// brew's version order (with `_N` revisions).
    public static func isOlder(_ a: String, than b: String) -> Bool {
        PkgVersion(parsing: a).compare(to: PkgVersion(parsing: b)) == -1
    }

    /// Can `change` (an upgrade from the diff) be undone automatically?
    public static func eligibility(_ change: RestoreDiff.Change, installed: [Package]) -> RollbackEligibility {
        let p = change.now
        let want = change.then.version
        if p.kind == .cask { return .manual(.cask) }
        if want.hasPrefix("HEAD") || p.installedVersion.hasPrefix("HEAD") { return .manual(.headVersion) }
        guard p.installedVersions.contains(want) else { return .manual(.cleanedUp) }
        if p.kegOnly == true { return .manual(.kegOnly) }
        if p.pinned { return .manual(.pinned) }
        if !Dependents.of(p, among: installed).isEmpty { return .manual(.hasDependents) }
        // After uninstalling the version in use, `brew link` takes the
        // newest of what's left: it must be the recorded one.
        var left = p.installedVersions
        if let i = left.firstIndex(of: p.installedVersion) { left.remove(at: i) }
        let newestLeft = left.max { isOlder($0, than: $1) }
        guard newestLeft == want else { return .manual(.otherKegWouldLink) }
        return .automatic
    }

    /// The supported manual route, shown and never run.
    public static func manualCommands(_ change: RestoreDiff.Change, block: RollbackBlock) -> [String] {
        let name = change.now.name
        let v = change.then.version
        switch block {
        case .cask, .headVersion:
            return []
        case .cleanedUp:
            // brew version-install extracts the old formula into a personal
            // tap (brew extract needs the homebrew/core git checkout).
            let plainVersion = v.split(separator: "_").first.map(String.init) ?? v
            return ["brew tap --force homebrew/core", "brew version-install \(name) \(plainVersion)"]
        case .pinned:
            return ["brew unpin \(name)"]
        case .kegOnly, .hasDependents, .otherKegWouldLink:
            return ["brew info \(name)"]
        }
    }
}

// MARK: restore plan

/// One queued brew command in a restore.
public struct RestoreStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case reinstall, rollbackUninstall, rollbackLink, pin }
    public var kind: Kind
    /// The package it is for (groups a rollback's steps).
    public var package: String
    public var arguments: [String]
    /// Extra environment shown in the command (HOMEBREW_NO_AUTOREMOVE=1).
    public var environment: [String: String]
    /// A rollback's uninstall: the old keg it brings back. It must still be
    /// in the Cellar right before the uninstall runs; without it,
    /// `brew uninstall` would remove the only version left.
    public var keg: Keg?
    public var id: String { "\(package)|\(kind.rawValue)" }

    public struct Keg: Sendable, Equatable, Hashable {
        /// The formula's short name: its rack in the Cellar.
        public var name: String
        public var version: String
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public init(kind: Kind, package: String, arguments: [String], environment: [String: String], keg: Keg? = nil) {
        self.kind = kind
        self.package = package
        self.arguments = arguments
        self.environment = environment
        self.keg = keg
    }

    public var display: String { BrewCommands.display(arguments, environment: environment) }
}

public struct RestorePlan: Sendable, Equatable {
    /// What a plan was made from, so it can be made again from what is on
    /// disk when the user confirms it.
    public struct Source: Sendable, Equatable {
        public var point: RestorePoint
        public var pinAfter: Bool
        public var keepPrevious: Bool
    }

    public var steps: [RestoreStep] = []

    /// 0.8.5 (newbie review H4): the confirmation in words, one line per
    /// package ("Put wget back", "Return curl to 8.1.0 and pin it"); the
    /// brew commands go under Details.
    public var summaryLines: [String] {
        var order: [String] = []
        var byPackage: [String: [RestoreStep]] = [:]
        for s in steps {
            if byPackage[s.package] == nil { order.append(s.package) }
            byPackage[s.package, default: []].append(s)
        }
        return order.compactMap { key in
            let group = byPackage[key] ?? []
            let name = Self.shortName(key)
            let pinned = group.contains { $0.kind == .pin }
            if group.contains(where: { $0.kind == .reinstall }) {
                return String(localized: "Put \(name) back")
            }
            if let keg = group.first(where: { $0.kind == .rollbackUninstall })?.keg {
                return pinned ? String(localized: "Return \(keg.name) to \(keg.version) and pin it there")
                              : String(localized: "Return \(keg.name) to \(keg.version)")
            }
            return pinned ? String(localized: "Pin \(name)") : nil
        }
    }

    /// "Restore 2 packages?"
    public var confirmTitle: String {
        let n = summaryLines.count
        return n == 1 ? String(localized: "Restore 1 package?") : String(localized: "Restore \(n) packages?")
    }

    static func shortName(_ key: String) -> String {
        let base = key.split(separator: "|").first.map(String.init) ?? key
        return base.split(separator: "/").last.map(String.init) ?? base
    }

    /// Upgrades that need the manual route.
    public var manual: [(change: RestoreDiff.Change, block: RollbackBlock)] = []
    public var source: Source?

    /// 0.8.5: what the confirmation leaves out, each with its reason:
    /// "Not included, can't roll back automatically: xz (Old version
    /// removed by cleanup), node (Pinned)". nil when nothing is left out.
    public var notIncludedText: String? {
        guard !manual.isEmpty else { return nil }
        let list = manual.map { "\($0.change.now.name) (\($0.block.title))" }.joined(separator: ", ")
        return String(localized: "Not included, can't roll back automatically: \(list)")
    }

    /// 0.8.5: why Restore… is off when there is nothing to run; the
    /// cleanup reason when that is what happened to every old version.
    public var nothingToRestoreReason: String {
        if !manual.isEmpty && manual.allSatisfy({ $0.block == .cleanedUp }) {
            return String(localized: "The old versions were removed by cleanup, so nothing here can be rolled back.")
        }
        return String(localized: "Nothing here can be restored automatically")
    }
    /// Set when the plan changed between showing it and confirming it (an
    /// old keg was cleaned up meanwhile): why, for the confirmation.
    public var notice: String?

    public init(steps: [RestoreStep] = [], manual: [(change: RestoreDiff.Change, block: RollbackBlock)] = [],
                source: Source? = nil, notice: String? = nil) {
        self.steps = steps
        self.manual = manual
        self.source = source
        self.notice = notice
    }

    public static func == (a: RestorePlan, b: RestorePlan) -> Bool {
        a.steps == b.steps && a.manual.map(\.change) == b.manual.map(\.change) && a.manual.map(\.block) == b.manual.map(\.block)
            && a.source == b.source && a.notice == b.notice
    }

    /// Reinstall what was removed, roll back what can be. `pinAfter`: pin
    /// rolled-back formulae, so the next upgrade (or auto-update) doesn't
    /// undo the rollback.
    ///
    /// The reinstalls run first, and `brew install` runs brew's periodic
    /// cleanup, which would remove the very kegs the rollbacks after it
    /// need. So they run with HOMEBREW_NO_INSTALL_CLEANUP=1 whenever the
    /// plan rolls something back, or "Keep the previous version" is on.
    public static func make(_ diff: RestoreDiff, installed: [Package], pinAfter: Bool, keepPrevious: Bool = false,
                            rollback: Set<String>? = nil, reinstall: Set<String>? = nil) -> RestorePlan {
        var plan = RestorePlan()
        var rollbacks: [RestoreStep] = []
        for c in diff.upgraded {
            switch RollbackPolicy.eligibility(c, installed: installed) {
            case .automatic:
                guard rollback?.contains(c.id) ?? true else { continue }
                let q = c.now.qualifiedName
                rollbacks.append(RestoreStep(kind: .rollbackUninstall, package: c.id,
                                             arguments: ["uninstall", "--formula", q],
                                             environment: [Self.noAutoremoveKey: "1"],
                                             keg: RestoreStep.Keg(name: c.now.name, version: c.then.version)))
                rollbacks.append(RestoreStep(kind: .rollbackLink, package: c.id,
                                             arguments: ["link", "--formula", q], environment: [:]))
                if pinAfter {
                    rollbacks.append(RestoreStep(kind: .pin, package: c.id,
                                                 arguments: ["pin", "--formula", q], environment: [:]))
                }
            case .manual(let block):
                plan.manual.append((c, block))
            }
        }
        let noCleanup: [String: String] = keepPrevious || !rollbacks.isEmpty ? [RollbackSettings.noInstallCleanupKey: "1"] : [:]
        for r in diff.removed where reinstall?.contains(r.key) ?? true {
            plan.steps.append(RestoreStep(kind: .reinstall, package: r.key,
                                          arguments: BrewCommands.installArguments(kind: r.kind, qualifiedName: r.qualifiedName),
                                          environment: noCleanup))
        }
        plan.steps += rollbacks
        return plan
    }

    /// The plan again, from the same restore point, with `kegExists` as the
    /// truth about which old kegs are still in the Cellar (the package list
    /// may be older than the last `brew cleanup`). Only steps that were in
    /// this plan are kept: confirming never runs a command that wasn't
    /// shown. A rollback whose old keg is gone loses all its steps.
    public func rechecked(installed: [Package], kegExists: (RestoreStep.Keg) -> Bool) -> RestorePlan {
        var plan = self
        plan.notice = nil
        if let src = source {
            let onDisk = installed.map { p -> Package in
                guard p.kind == .formula else { return p }
                var q = p
                q.installedVersions = p.installedVersions.filter {
                    $0 == p.installedVersion || kegExists(RestoreStep.Keg(name: p.name, version: $0))
                }
                return q
            }
            let again = RestorePlan.make(RestoreDiff.between(src.point, onDisk), installed: onDisk,
                                         pinAfter: src.pinAfter, keepPrevious: src.keepPrevious)
            let shown = Set(steps.map(\.id))
            plan.steps = again.steps.filter { shown.contains($0.id) }
            plan.manual = again.manual
        }
        // Also for a plan without a source: the kegs themselves decide.
        let gone = Set(plan.steps.compactMap { s in s.keg.flatMap { kegExists($0) ? nil : s.package } })
        plan.steps.removeAll { gone.contains($0.package) }

        let kept = Set(plan.steps.map(\.package))
        let lost = steps.filter { $0.kind == .rollbackUninstall && !kept.contains($0.package) }
            .map { s in s.keg.map { "\($0.name) \($0.version)" } ?? s.package }
        if !lost.isEmpty {
            let names = lost.joined(separator: ", ")
            plan.notice = String(localized: "No longer in the Cellar: \(names). brew cleanup removed it after this list was made, so it can't be rolled back and was taken out of the restore. Nothing has run yet. Check the commands and click Restore again.")
        } else if plan.steps != steps {
            plan.notice = String(localized: "What is installed changed since this list was made. Nothing has run yet. Check the commands and click Restore again.")
        }
        return plan
    }

    /// Keeps `brew uninstall` from removing dependencies the old keg still uses.
    public static let noAutoremoveKey = "HOMEBREW_NO_AUTOREMOVE"
}

// MARK: storage

/// The saved restore points, newest first. `directory` nil: memory only.
@Observable @MainActor
public final class RestorePointStore {
    public nonisolated static let maxPoints = 20

    public private(set) var points: [RestorePoint]
    /// The sheet (Homebrew → Restore Points…).
    public var isShowing = false
    public var selection: RestorePoint.ID?
    /// The confirmation for a restore, when open.
    public var pendingPlan: RestorePlan?
    @ObservationIgnored public let directory: URL?
    @ObservationIgnored public let settings: RollbackSettings

    public nonisolated static var defaultDirectory: URL {
        AutoUpdateLog.defaultURL.deletingLastPathComponent().appendingPathComponent("restore-points", isDirectory: true)
    }

    public init(directory: URL?, settings: RollbackSettings) {
        self.directory = directory
        self.settings = settings
        points = directory.map(Self.load) ?? []
    }

    /// 0.8.5: the banner at the top of Restore Points: rolling back needs
    /// the old version, and Tankard isn't keeping old versions.
    public var showsKeepOldVersionsBanner: Bool { !settings.keepPreviousVersion }

    /// 0.8.5: the banner's Keep Old Versions (the Settings toggle, on).
    public func keepOldVersions() {
        settings.keepPreviousVersion = true
    }

    /// Saves `point` and drops the oldest past `maxPoints`.
    @discardableResult
    public func save(_ point: RestorePoint) -> RestorePoint {
        var list = points.filter { $0.id != point.id }
        list.append(point)
        list.sort { $0.createdAt > $1.createdAt }
        let kept = Array(list.prefix(Self.maxPoints))
        let dropped = list.dropFirst(Self.maxPoints)
        points = kept
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? StatusReport.jsonEncoder().encode(point) {
                try? data.write(to: Self.fileURL(point, in: directory), options: .atomic)
            }
            for d in dropped { try? FileManager.default.removeItem(at: Self.fileURL(d, in: directory)) }
        }
        return point
    }

    /// Demo: show these without saving.
    public func seed(_ list: [RestorePoint]) {
        points = Array(list.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maxPoints))
    }

    public func delete(_ id: RestorePoint.ID) {
        guard let p = points.first(where: { $0.id == id }) else { return }
        points.removeAll { $0.id == id }
        if selection == id { selection = nil }
        if let directory { try? FileManager.default.removeItem(at: Self.fileURL(p, in: directory)) }
    }

    public var selected: RestorePoint? {
        selection.flatMap { id in points.first { $0.id == id } } ?? points.first
    }

    nonisolated static func fileURL(_ p: RestorePoint, in dir: URL) -> URL {
        dir.appendingPathComponent("restore-point-\(p.id.uuidString).json")
    }

    nonisolated static func load(_ dir: URL) -> [RestorePoint] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = StatusReport.jsonDecoder()
        let all = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(RestorePoint.self, from: $0) } }
        return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(maxPoints))
    }
}

// MARK: settings

/// "Keep the previous version after upgrades" (off by default).
///
/// On: every upgrade, install and reinstall Tankard runs (formulae and
/// casks, the sheet and auto-update) has HOMEBREW_NO_INSTALL_CLEANUP=1, so
/// brew keeps the old keg (Homebrew FAQ, "How do I keep old versions of a
/// formula when upgrading?"). Not only formula upgrades: any install,
/// upgrade or reinstall can trigger brew's periodic cleanup, which removes
/// every formula's old kegs, not just its own. That old keg is what makes an
/// automatic rollback possible. It costs disk space until Clean Up
/// (`brew cleanup`) removes it; brew's own 30-day cleanup, run by an install
/// or upgrade outside Tankard, can remove it too.
@Observable @MainActor
public final class RollbackSettings {
    enum Key {
        static let keepPrevious = "keepPreviousVersionAfterUpgrade"
    }

    @ObservationIgnored public let defaults: UserDefaults

    /// Ignores a write of the value it already has (no notification, no
    /// UserDefaults write), like every other Tankard setting.
    public var keepPreviousVersion: Bool {
        get { access(keyPath: \.keepPreviousVersion); return _keepPreviousVersion }
        set {
            guard newValue != _keepPreviousVersion else { return }
            withMutation(keyPath: \.keepPreviousVersion) { _keepPreviousVersion = newValue }
            defaults.set(newValue, forKey: Key.keepPrevious)
        }
    }
    @ObservationIgnored private var _keepPreviousVersion: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _keepPreviousVersion = defaults.bool(forKey: Key.keepPrevious)
    }

    public nonisolated static let noInstallCleanupKey = "HOMEBREW_NO_INSTALL_CLEANUP"

    /// The variable for one step: every upgrade, install and reinstall
    /// (formula or cask), only when on.
    public nonisolated static func extraEnvironment(_ action: SessionAction, _ p: Package, keep: Bool) -> [String: String] {
        guard keep, appliesTo(action) else { return [:] }
        return [noInstallCleanupKey: "1"]
    }

    /// The brew commands that can run brew's periodic cleanup.
    public nonisolated static func appliesTo(_ action: SessionAction) -> Bool {
        switch action {
        case .upgrade, .install, .replaceBottle, .adopt: return true
        case .uninstall, .cleanup, .autoremove, .tap, .untap, .restore: return false
        }
    }
}
