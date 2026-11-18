import Foundation
import TankardCore

// v0.7: restore points. The model is in RestorePoints.swift.

extension AppStore {
    /// Saves what is installed now. Called before every upgrade session
    /// and every auto-update run; skipped when there is no report yet.
    @discardableResult
    public func saveRestorePoint(_ reason: RestorePoint.Reason, upgrading: [Package] = []) -> RestorePoint? {
        guard report != nil, !packages.isEmpty else { return nil }
        let names = upgrading.map(\.name)
        let note: String? = names.isEmpty ? nil
            : names.count <= 3 ? names.joined(separator: ", ") : "\(names.prefix(3).joined(separator: ", ")) +\(names.count - 3)"
        return restorePoints.save(RestorePoint.capture(packages, at: deps.now(), reason: reason, note: note))
    }

    /// Homebrew → Restore Points…
    public func openRestorePoints() {
        restorePoints.isShowing = true
    }

    /// What changed since `point`.
    public func restoreDiff(_ point: RestorePoint) -> RestoreDiff {
        RestoreDiff.between(point, packages)
    }

    /// Opens the confirmation for restoring `point`.
    public func requestRestore(_ point: RestorePoint, pinAfter: Bool) {
        let keep = restorePoints.settings.keepPreviousVersion
        var plan = RestorePlan.make(restoreDiff(point), installed: packages, pinAfter: pinAfter, keepPrevious: keep)
        plan.source = RestorePlan.Source(point: point, pinAfter: pinAfter, keepPrevious: keep)
        restorePoints.pendingPlan = plan
    }

    /// Runs the confirmed plan through the queue, as one sheet session.
    /// Each step is recorded in History by the queue's observer.
    ///
    /// The package list can be older than the last `brew cleanup` (run
    /// from Terminal, or brew's own periodic one), so the plan is made again
    /// from what is in the Cellar now. If that changed it, nothing runs:
    /// the confirmation shows the new plan and why, to confirm again.
    public func confirmRestore() {
        guard let shown = restorePoints.pendingPlan else { return }
        guard let client = try? resolvedClient() else { return }
        let plan = shown.rechecked(installed: packages) { client.fileExists(client.kegPath($0.name, $0.version)) }
        if plan.steps != shown.steps {
            restorePoints.pendingPlan = plan
            return
        }
        restorePoints.pendingPlan = nil
        guard !plan.steps.isEmpty else { return }
        restorePoints.isShowing = false
        startRestoreSession(plan.steps)
    }

    public func cancelRestore() {
        restorePoints.pendingPlan = nil
    }

    /// The queued commands of `steps`, exactly as they will run.
    public func restoreCommands(_ steps: [RestoreStep]) -> [QueuedCommand]? {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return nil }
        return steps.map { Self.restoreCommand($0, brew: client.installation.brewPath,
                                               base: client.environment(for: detection, readOnly: false),
                                               askpass: deps.askpassHelper, foreign: foreignAskpass(client)) }
    }

    nonisolated static func restoreCommand(_ step: RestoreStep, brew: String, base: [String: String],
                                           askpass: String? = nil, foreign: ForeignAskpass? = nil) -> QueuedCommand {
        var env = base
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        // 0.8.3: a cask reinstall or uninstall may run sudo: the password dialog.
        // 0.8.4: not with brew.env's own helper (ForeignAskpass).
        let password = AdminPassword.environment(helper: askpass, arguments: step.arguments, display: step.display,
                                                 foreign: foreign)
        return QueuedCommand(executable: brew, arguments: step.arguments,
                             environment: env.merging(step.environment) { $1 }.merging(password) { $1 },
                             display: step.display)
    }

    private func startRestoreSession(_ steps: [RestoreStep]) {
        guard !isUpgrading, !autoUpdate.isRunning, let client = try? resolvedClient(),
              let detection = report?.intelbrew else { return }
        let brew = client.installation.brewPath
        let base = client.environment(for: detection, readOnly: false)
        let askpass = deps.askpassHelper
        let foreign = foreignAskpass(client)
        let files = deps.brewEnvFiles
        // One sheet row per step; a rollback's steps chain (a failed
        // uninstall skips its link and pin).
        var byID: [String: RestoreStep] = [:]
        let rows: [Package] = steps.map { s in
            let p = Package.command(s.display)
            byID[p.id] = s
            return p
        }
        startCustomSession(.restore, packages: rows, intelbrewMode: detection.detected,
                           makeCommand: { p in
                               guard let s = byID[p.id] else {
                                   return QueuedCommand(executable: brew, arguments: ["--version"], environment: base, display: "brew --version")
                               }
                               return Self.restoreCommand(s, brew: brew, base: base, askpass: askpass, foreign: foreign)
                           },
                           chainKey: { p in byID[p.id].flatMap { $0.kind == .reinstall ? nil : $0.package } },
                           precondition: { p in
                               guard let s = byID[p.id] else { return nil }
                               let keg = Self.kegCheck(s, client: client)
                               guard AdminPassword.mayNeedSudo(s.arguments) else { return keg }
                               // 0.8.4: brew.env read again right before the step.
                               let env = Self.restoreCommand(s, brew: brew, base: [:], askpass: askpass, foreign: foreign).environment
                               return {
                                   if let refusal = keg?() { return refusal }
                                   return AdminPassword.refusal(arguments: s.arguments, package: nil, environment: env,
                                                                foreign: ForeignAskpass.detect(brewEnvFiles: files(client), own: askpass))
                               }
                           })
        upgrade?.foreignAskpass = foreign
    }

    /// For a rollback's uninstall: checked by the queue right before it
    /// runs. If the old keg has gone (a cleanup after the confirmation),
    /// the uninstall doesn't run, and neither do the rest of its steps.
    nonisolated static func kegCheck(_ step: RestoreStep, client: BrewClient) -> (@Sendable () -> String?)? {
        guard step.kind == .rollbackUninstall, let keg = step.keg else { return nil }
        let path = client.kegPath(keg.name, keg.version)
        let exists = client.fileExists
        return {
            exists(path) ? nil
                : "\(keg.name) \(keg.version) is no longer in the Cellar (\(path) is gone; brew cleanup removed it). Skipped the uninstall, so \(keg.name) stays installed as it is."
        }
    }
}
