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

    public init(client: BrewClient, env: [String: String]) {
        self.client = client
        self.env = env
    }

    /// `brew cleanup` exactly as it will run (copyable).
    public var command: String { BrewCommands.display(BrewCommands.cleanupArguments) }
    public var dryRunCommand: String { BrewCommands.display(BrewCommands.cleanupDryRunArguments) }

    /// brew's problem lines, when it exited non-zero.
    public var problem: String? {
        guard let d = dryRun, exitCode != 0 || !d.errors.isEmpty else { return nil }
        let lines = d.errors.isEmpty ? ["brew cleanup -n exited \(exitCode)."] : d.errors
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
            let (d, code) = try await client.cleanupDryRun(env: env, cachePath: cache)
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
        rows = packages.map { Row(package: $0, warning: classifier.upgradeWarning($0)) }
    }

    public var compiling: [Package] { rows.filter { $0.warning != nil }.map(\.package) }
    public var hasCompiling: Bool { rows.contains { $0.warning != nil } }

    /// What Start runs.
    public var toRun: [Package] {
        rows.filter { !(skipCompiling && $0.warning != nil) }.map(\.package)
    }

    /// "Upgrade 5" / "Upgrade 4 (skip 1)"
    public var startTitle: String {
        let n = toRun.count
        let skipped = rows.count - n
        return skipped > 0 ? "Upgrade \(n) (skip \(skipped))" : "Upgrade \(n)"
    }
}
