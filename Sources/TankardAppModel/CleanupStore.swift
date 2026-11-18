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

/// 0.8.5: a cask in an upgrade whose app is open now.
public struct RunningCaskApp: Equatable, Sendable {
    public var packageID: String
    /// The app's name as Finder shows it ("Google Chrome").
    public var name: String
    public init(packageID: String, name: String) {
        self.packageID = packageID
        self.name = name
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
    /// 0.8.5 (newbie review H2): the apps of casks in this plan that are
    /// open now ("Google Chrome"). brew closes a running app to upgrade its
    /// cask, so the plan page says so before starting. Empty when nothing is
    /// open or "Don't quit running apps during upgrades" is on.
    public var runningApps: [RunningCaskApp] = []

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
    public var needsConfirmation: Bool { hasCompiling || !needingPassword.isEmpty || !runningAppsToRun.isEmpty }

    /// The open apps among what Start runs (a skipped package's app isn't
    /// touched).
    public var runningAppsToRun: [String] {
        let run = Set(toRun.map(\.id))
        return runningApps.filter { run.contains($0.packageID) }.map(\.name)
    }

    /// "These apps will be closed during the upgrade: Google Chrome, Visual
    /// Studio Code." nil when none is open.
    public var runningAppsNote: String? {
        let names = runningAppsToRun
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1
            ? String(localized: "This app will be closed during the upgrade and opened again afterwards: \(list). Save your work in it first.")
            : String(localized: "These apps will be closed during the upgrade and opened again afterwards: \(list). Save your work in them first.")
    }

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
