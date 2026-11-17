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
        let plan = RestorePlan.make(restoreDiff(point), installed: packages, pinAfter: pinAfter)
        restorePoints.pendingPlan = plan
    }

    /// Runs the confirmed plan through the queue, as one sheet session.
    /// Each step is recorded in History by the queue's observer.
    public func confirmRestore() {
        guard let plan = restorePoints.pendingPlan else { return }
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
                                               base: client.environment(for: detection, readOnly: false)) }
    }

    nonisolated static func restoreCommand(_ step: RestoreStep, brew: String, base: [String: String]) -> QueuedCommand {
        var env = base
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return QueuedCommand(executable: brew, arguments: step.arguments, environment: env.merging(step.environment) { $1 },
                             display: step.display)
    }

    private func startRestoreSession(_ steps: [RestoreStep]) {
        guard !isUpgrading, !autoUpdate.isRunning, let client = try? resolvedClient(),
              let detection = report?.intelbrew else { return }
        let brew = client.installation.brewPath
        let base = client.environment(for: detection, readOnly: false)
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
                               return Self.restoreCommand(s, brew: brew, base: base)
                           },
                           chainKey: { p in byID[p.id].flatMap { $0.kind == .reinstall ? nil : $0.package } })
    }
}
