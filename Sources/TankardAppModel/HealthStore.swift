import Foundation
import Observation
import TankardCore

// v0.6 (part A): the Health sheet, the autoremove sheet, and the
// deprecated/disabled/keg-only details. Read-only brew runs go straight to
// the runner (as the Cleanup dry run does); the one that changes things,
// `brew autoremove`, goes through the queue and the activity sheet.

/// The sheets opened from the Homebrew menu in 0.6.
public enum ToolSheet: String, Identifiable, Sendable {
    case health, history, autoremove
    /// 0.7: Homebrew ▸ Taps… (TapsStore.swift).
    case taps
    /// 0.8: Homebrew ▸ Adopt Apps… (AdoptStore.swift).
    case adopt
    public var id: String { rawValue }
}

/// `brew doctor`, `brew config` and `brew missing`, all read-only.
@Observable @MainActor
public final class HealthStore {
    public enum Phase: Equatable, Sendable {
        case idle, running, ready
        case failed(String)
    }

    public struct Missing: Equatable, Sendable, Identifiable {
        public var formula: String
        public var missing: [String]
        public var id: String { formula }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var doctor: DoctorReport?
    public private(set) var doctorRaw = ""
    public private(set) var config = ""
    public private(set) var missing: [Missing] = []
    public private(set) var missingRaw = ""

    @ObservationIgnored let client: BrewClient
    @ObservationIgnored let env: [String: String]

    public static let doctorArguments = ["doctor"]
    public static let configArguments = ["config"]
    public static let missingArguments = ["missing"]

    public init(client: BrewClient, env: [String: String]) {
        self.client = client
        self.env = env
    }

    public func load() async {
        guard phase != .running else { return }
        phase = .running
        let path = client.installation.brewPath, runner = client.runner, env = self.env
        func text(_ r: ProcessResult) -> String {
            [r.stdoutString, r.stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        do {
            // doctor writes its warnings to stderr and exits 1 when it has any.
            async let d = runner.run(path, Self.doctorArguments, environment: env)
            async let c = runner.run(path, Self.configArguments, environment: env)
            async let m = runner.run(path, Self.missingArguments, environment: env)
            let (dr, cr, mr) = try await (d, c, m)
            // brew prints the maintainers' note on stderr, the warnings after it.
            doctorRaw = [dr.stderrString, dr.stdoutString].filter { !$0.isEmpty }.joined(separator: "\n")
            doctor = DoctorReport.parse(doctorRaw)
            config = text(cr).trimmingCharacters(in: .whitespacesAndNewlines)
            missingRaw = text(mr).trimmingCharacters(in: .whitespacesAndNewlines)
            missing = MissingDependencies.parse(mr.stdoutString).map { Missing(formula: $0.formula, missing: $0.missing) }
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// The summary line under the title.
    public var summary: String {
        guard let d = doctor else { return "" }
        if d.warnings.isEmpty { return d.ready ? String(localized: "brew doctor found nothing to fix.") : String(localized: "brew doctor printed no warnings.") }
        return d.warnings.count == 1
            ? String(localized: "brew doctor: \(d.warnings.count) warning")
            : String(localized: "brew doctor: \(d.warnings.count) warnings")
    }
}

/// `brew autoremove --dry-run`, then (on confirm) `brew autoremove`.
@Observable @MainActor
public final class AutoremoveStore {
    public enum Phase: Equatable, Sendable {
        case idle, running, ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var plan: AutoremovePlan?
    public private(set) var raw = ""

    @ObservationIgnored let client: BrewClient
    @ObservationIgnored let env: [String: String]

    public init(client: BrewClient, env: [String: String]) {
        self.client = client
        self.env = env
    }

    public var dryRunCommand: String { BrewCommands.display(AutoremovePlan.dryRunArguments) }
    public var command: String { BrewCommands.display(AutoremovePlan.runArguments) }

    public func load() async {
        guard phase != .running else { return }
        phase = .running
        do {
            let r = try await client.runner.run(client.installation.brewPath, AutoremovePlan.dryRunArguments, environment: env)
            raw = [r.stdoutString, r.stderrString].filter { !$0.isEmpty }.joined(separator: "\n")
            if r.exitCode != 0 {
                let tail = raw.split(separator: "\n").suffix(4).joined(separator: "\n")
                phase = .failed(tail.isEmpty ? String(localized: "\(dryRunCommand) exited \(r.exitCode)") : tail)
                return
            }
            plan = AutoremovePlan.parse(r.stdoutString)
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

public extension Package {
    /// 0.6: deprecated or disabled by Homebrew.
    var isRetired: Bool { deprecated || disabled }

    /// "disabled" / "deprecated" / nil: the list's badge.
    var retiredLabel: String? { disabled ? String(localized: "disabled") : deprecated ? String(localized: "deprecated") : nil }

    /// "Deprecated since 2026-10-30: is a versioned formula." / "Disabled
    /// …". nil when neither applies.
    var retiredDetail: String? {
        guard isRetired else { return nil }
        let l = lifecycle
        let date = disabled ? l?.disableDate : l?.deprecationDate
        let reason = PackageLifecycle.describe(reason: disabled ? l?.disableReason : l?.deprecationReason)
        let s: String
        switch (disabled, date) {
        case (true, let date?): s = String(localized: "Disabled since \(date)")
        case (true, nil): s = String(localized: "Disabled")
        case (false, let date?): s = String(localized: "Deprecated since \(date)")
        case (false, nil): s = String(localized: "Deprecated")
        }
        if let reason { return String(localized: "\(s): \(name) \(reason).") }
        return s + "."
    }

    /// The replacement brew names, if any (disable first, then deprecate).
    var replacement: PackageReplacement? {
        guard isRetired, let l = lifecycle else { return nil }
        let pairs: [(String?, PackageKind)] = disabled
            ? [(l.disableReplacementFormula, .formula), (l.disableReplacementCask, .cask),
               (l.deprecationReplacementFormula, .formula), (l.deprecationReplacementCask, .cask)]
            : [(l.deprecationReplacementFormula, .formula), (l.deprecationReplacementCask, .cask)]
        for (name, kind) in pairs { if let name, !name.isEmpty { return PackageReplacement(name: name, kind: kind) } }
        return nil
    }

    /// 0.6, formulae: "keg-only: macOS provides BSD libedit" and "not
    /// linked" lines for the detail pane. Empty for casks.
    var linkNotes: [String] {
        guard kind == .formula else { return [] }
        var out: [String] = []
        if kegOnly == true {
            if let kegOnlyReason {
                out.append(String(localized: "Keg-only: \(kegOnlyReason). Not linked into the prefix on purpose."))
            } else {
                out.append(String(localized: "Keg-only. Not linked into the prefix on purpose."))
            }
        } else if linked == false {
            out.append(String(localized: "Not linked: its commands aren't in Homebrew's bin. `brew link \(name)` links it."))
        }
        return out
    }

    /// A row for a package that isn't installed yet (a replacement), for
    /// the install flow.
    static func placeholder(kind: PackageKind, name: String) -> Package {
        var p = Package.command(name)
        p.id = "\(kind.rawValue):\(name)"
        p.kind = kind
        p.name = name.split(separator: "/").last.map(String.init) ?? name
        p.fullName = name
        p.statusLabel = kind == .cask ? "cask" : "bottle"
        return p
    }
}

public extension AppStore {
    /// The installed package a replacement name refers to, if any.
    func installedReplacement(_ r: PackageReplacement) -> Package? {
        packages.first { $0.kind == r.kind && ($0.name == r.name || $0.fullName == r.name) }
    }

    /// "Install <replacement>": the same install flow as Discover (queue
    /// and the activity sheet).
    func installReplacement(for p: Package) {
        guard let r = p.replacement, installedReplacement(r) == nil else { return }
        startSession(.install, packages: [Package.placeholder(kind: r.kind, name: r.name)])
    }

    /// Homebrew ▸ Health…: doctor, config and missing, read-only.
    func openHealth() {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        let h = HealthStore(client: client, env: client.environment(for: detection))
        health = h
        toolSheet = .health
        Task { await h.load() }
    }

    /// Homebrew ▸ Remove Unused Dependencies…: the dry run first.
    func openAutoremove() {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        let a = AutoremoveStore(client: client, env: client.environment(for: detection))
        autoremove = a
        toolSheet = .autoremove
        Task { await a.load() }
    }

    /// The confirmed `brew autoremove`, through the queue and the live log.
    func startAutoremove() {
        guard autoremove?.plan?.formulae.isEmpty == false else { return }
        toolSheet = nil
        startSession(.autoremove, packages: [Package.command("brew autoremove")])
    }

    /// Closes a 0.6 sheet. Only a real change is written.
    func closeToolSheet() {
        if toolSheet != nil { toolSheet = nil }
    }
}
