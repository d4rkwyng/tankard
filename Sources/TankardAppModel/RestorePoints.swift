import Foundation
import Observation
import TankardCore

// v0.7: restore points ("undo that upgrade").
//
// Before every upgrade session and every auto-update run, Tankard saves what
// is installed (formulae and casks with exact versions, their taps, pins).
// The last 20 are kept in Application Support/Tankard/restore-points/, one
// JSON file each.
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
        case .cleanedUp: return String(localized: "Old version was cleaned up")
        case .kegOnly: return String(localized: "Keg-only")
        case .pinned: return String(localized: "Pinned")
        case .hasDependents: return String(localized: "Other packages need it")
        case .otherKegWouldLink: return String(localized: "Another old version is installed")
        case .headVersion: return String(localized: "HEAD build")
        }
    }

    /// The detail, for help text.
    public var explanation: String {
        switch self {
        case .cask:
            return String(localized: "Homebrew keeps only the current cask definition, so it can't install an older version of an app.")
        case .cleanedUp:
            return String(localized: "brew cleanup removed the old keg after the upgrade. Turn on \"Keep the previous version after upgrades\" to keep it next time.")
        case .kegOnly:
            return String(localized: "brew link would need --force for a keg-only formula, which links it where it wasn't before.")
        case .pinned:
            return String(localized: "brew won't uninstall a pinned formula. Unpin it first.")
        case .hasDependents:
            return String(localized: "brew refuses to uninstall a formula other installed packages need, and Homebrew doesn't support mixing versions under them.")
        case .otherKegWouldLink:
            return String(localized: "brew link always links the newest version left, which isn't the one in this restore point.")
        case .headVersion:
            return String(localized: "HEAD builds have no fixed version to go back to.")
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
    public var id: String { "\(package)|\(kind.rawValue)" }

    public var display: String { BrewCommands.display(arguments, environment: environment) }
}

public struct RestorePlan: Sendable, Equatable {
    public var steps: [RestoreStep] = []
    /// Upgrades that need the manual route.
    public var manual: [(change: RestoreDiff.Change, block: RollbackBlock)] = []

    public static func == (a: RestorePlan, b: RestorePlan) -> Bool {
        a.steps == b.steps && a.manual.map(\.change) == b.manual.map(\.change) && a.manual.map(\.block) == b.manual.map(\.block)
    }

    /// Reinstall what was removed, roll back what can be. `pinAfter`: pin
    /// rolled-back formulae, so the next upgrade (or auto-update) doesn't
    /// undo the rollback.
    public static func make(_ diff: RestoreDiff, installed: [Package], pinAfter: Bool,
                            rollback: Set<String>? = nil, reinstall: Set<String>? = nil) -> RestorePlan {
        var plan = RestorePlan()
        for r in diff.removed where reinstall?.contains(r.key) ?? true {
            plan.steps.append(RestoreStep(kind: .reinstall, package: r.key,
                                          arguments: BrewCommands.installArguments(kind: r.kind, qualifiedName: r.qualifiedName),
                                          environment: [:]))
        }
        for c in diff.upgraded {
            switch RollbackPolicy.eligibility(c, installed: installed) {
            case .automatic:
                guard rollback?.contains(c.id) ?? true else { continue }
                let q = c.now.qualifiedName
                plan.steps.append(RestoreStep(kind: .rollbackUninstall, package: c.id,
                                              arguments: ["uninstall", "--formula", q],
                                              environment: [Self.noAutoremoveKey: "1"]))
                plan.steps.append(RestoreStep(kind: .rollbackLink, package: c.id,
                                              arguments: ["link", "--formula", q], environment: [:]))
                if pinAfter {
                    plan.steps.append(RestoreStep(kind: .pin, package: c.id,
                                                  arguments: ["pin", "--formula", q], environment: [:]))
                }
            case .manual(let block):
                plan.manual.append((c, block))
            }
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
/// On: Tankard's own formula upgrades (the sheet and auto-update) run with
/// HOMEBREW_NO_INSTALL_CLEANUP=1, so brew keeps the old keg (Homebrew FAQ,
/// "How do I keep old versions of a formula when upgrading?"). That old keg
/// is what makes an automatic rollback possible. It costs disk space until
/// Clean Up (`brew cleanup`) removes it; brew's own 30-day cleanup, run by an
/// install or upgrade outside Tankard, can remove it too.
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

    /// The variable for one step: formula upgrades only, and only when on.
    public nonisolated static func extraEnvironment(_ action: SessionAction, _ p: Package, keep: Bool) -> [String: String] {
        guard keep, action == .upgrade, p.kind == .formula else { return [:] }
        return [noInstallCleanupKey: "1"]
    }
}
