import Foundation
import Observation
import TankardCore

/// The Cleanup sheet: `brew cleanup -n` (dry run, read-only, off the queue),
/// brew's download cache size (`brew --cache`, `du -sk`), then the real
/// `brew cleanup` through the queue when the user clicks Clean up.
@Observable @MainActor
public final class CleanupStore {
    public enum Phase: Equatable, Sendable {
        case idle, running, ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var dryRun: CleanupDryRun?
    /// brew's exit code for the dry run (it can be non-zero and still list items).
    public private(set) var exitCode: Int32 = 0
    public private(set) var cachePath: String?
    public private(set) var cacheBytes: Int64?
    public private(set) var measuringCache = false

    @ObservationIgnored let client: BrewClient
    @ObservationIgnored let env: [String: String]
    /// 0.8.5 (bug hunt M1): the formulae whose old versions Clean Up leaves
    /// alone, because "Keep the previous version after upgrades" is on and
    /// Restore Points rolls back to them. Empty when the setting is off.
    public let kept: [String]
    /// Whether "Keep the previous version after upgrades" is on.
    public let keepPrevious: Bool
    /// brew's own variable for "don't touch these formulae", on the dry run
    /// and on the real `brew cleanup` alike (so the preview is what runs).
    public let extraEnvironment: [String: String]

    public init(client: BrewClient, env: [String: String], kept: [String] = [], keepPrevious: Bool = false) {
        self.client = client
        self.env = env
        self.kept = kept
        self.keepPrevious = keepPrevious
        extraEnvironment = CleanupKeep.environment(kept, existing: env[CleanupKeep.key])
    }

    /// `brew cleanup` exactly as it will run (copyable).
    public var command: String { BrewCommands.display(BrewCommands.cleanupArguments, environment: extraEnvironment) }
    public var dryRunCommand: String { BrewCommands.display(BrewCommands.cleanupDryRunArguments) }

    /// 0.8.5 (M1): old versions this Clean Up would remove, as "xz 5.8.1".
    /// Restore Points can roll back to an old version only while it is on
    /// disk, so these are listed apart and Clean Up isn't the Return default.
    public var removesRollbackVersions: [String] {
        (dryRun?.items ?? []).filter { $0.kind == .oldVersion }.compactMap { CleanupKeep.kegLabel($0.path) }
    }

    /// Whether Return runs Clean Up: not while it would remove versions
    /// you could roll back to.
    public var cleanUpIsDefault: Bool { removesRollbackVersions.isEmpty }

    /// "Keeps the old versions of xz and 2 more for Restore Points …"
    public var keptNote: String? {
        guard !kept.isEmpty else { return nil }
        let names = kept.prefix(3).joined(separator: ", ") + (kept.count > 3 ? String(localized: " and \(kept.count - 3) more") : "")
        return String(localized: "Keeps the old versions of \(names) for Restore Points, because “Keep the previous version after upgrades” is on.")
    }

    /// brew's problem lines, when it exited non-zero.
    public var problem: String? {
        guard let d = dryRun, exitCode != 0 || !d.errors.isEmpty else { return nil }
        let lines = d.errors.isEmpty ? [String(localized: "brew cleanup -n exited \(exitCode).")] : d.errors
        return lines.prefix(3).joined(separator: "\n")
    }

    public func load() async {
        guard phase != .running else { return }
        phase = .running
        let client = self.client, env = self.env
        let cache = await client.cachePath(env: env)
        cachePath = cache
        measuringCache = cache != nil
        async let size: Int64? = cache == nil ? nil : client.diskUsage(cache!)
        do {
            let (d, code) = try await client.cleanupDryRun(env: env.merging(extraEnvironment) { $1 }, cachePath: cache)
            dryRun = d
            exitCode = code
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
        cacheBytes = await size
        measuringCache = false
    }
}

/// 0.8.5 (bug hunt M1): Clean Up used to remove the old versions "Keep the
/// previous version after upgrades" keeps for Restore Points. brew's
/// HOMEBREW_NO_CLEANUP_FORMULAE makes `brew cleanup` (and its `-n` preview)
/// skip the listed formulae's old versions; the rest is cleaned as before
/// (brew 7.0.14, Homebrew/cleanup.rb `clean!`, checked against a probe tap:
/// the kept keg leaves the preview, its old download stays in it).
public enum CleanupKeep {
    public static let key = "HOMEBREW_NO_CLEANUP_FORMULAE"

    /// The formulae with more than one version installed, when the setting
    /// is on (by short name: brew matches the name or an alias).
    public static func keptFormulae(_ packages: [Package], keepPrevious: Bool) -> [String] {
        guard keepPrevious else { return [] }
        let names = packages.filter { $0.kind == .formula && Set($0.installedVersions).count > 1 }.map(\.name)
        return Array(Set(names)).sorted()
    }

    /// The variable with `kept` added to what brew.env already lists.
    public static func environment(_ kept: [String], existing: String?) -> [String: String] {
        guard !kept.isEmpty else { return [:] }
        var list = (existing ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for name in kept where !list.contains(name) { list.append(name) }
        return [key: list.joined(separator: ",")]
    }

    /// "/opt/homebrew/Cellar/xz/5.8.1" → "xz 5.8.1".
    public static func kegLabel(_ path: String) -> String? {
        guard let r = path.range(of: "/Cellar/") else { return nil }
        let parts = path[r.upperBound...].split(separator: "/")
        guard parts.count >= 2 else { return parts.first.map(String.init) }
        return "\(parts[0]) \(parts[1])"
    }
}

/// The upgrade sheet's first page when something would compile: every
/// package with its bottle-or-compile mark, and "Skip packages that would
/// compile".
public struct UpgradePlan: Equatable, Sendable, Identifiable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var package: Package
        public var warning: CompileWarning?
        public var id: String { package.id }

        public init(package: Package, warning: CompileWarning?) {
            self.package = package
            self.warning = warning
        }
    }

    public var id = UUID()
    public var rows: [Row]
    public var skipCompiling = false

    public init(packages: [Package], classifier: CompileClassifier) {
        // 0.8.5: in the order the run takes (password casks last).
        rows = AdminPassword.passwordStepsLast(packages).map { Row(package: $0, warning: classifier.upgradeWarning($0)) }
    }

    public var compiling: [Package] { rows.filter { $0.warning != nil }.map(\.package) }
    public var hasCompiling: Bool { rows.contains { $0.warning != nil } }
    /// 0.8.3: casks whose installer brew runs with sudo: the dialog will
    /// ask for the administrator password.
    public var needingPassword: [Package] { rows.map(\.package).filter(AdminPassword.required) }
    /// Whether the plan page is shown before starting (else it starts at once).
    public var needsConfirmation: Bool { hasCompiling || !needingPassword.isEmpty }

    /// What Start runs.
    public var toRun: [Package] {
        rows.filter { !(skipCompiling && $0.warning != nil) }.map(\.package)
    }

    /// "Upgrade 5" / "Upgrade 4 (skip 1)"
    public var startTitle: String {
        let n = toRun.count
        let skipped = rows.count - n
        return skipped > 0 ? String(localized: "Upgrade \(n) (skip \(skipped))") : String(localized: "Upgrade \(n)")
    }
}
