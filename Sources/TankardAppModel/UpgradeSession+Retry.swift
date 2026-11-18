import Foundation
import TankardCore

// 0.8.3: Retry inside the sheet, and one plain next step for a failure
// Tankard recognises. Retry goes back through the normal, gated path for
// the action (as History's Retry does): an upgrade through requestUpgrade
// (compile plan, pins, rules), an install through startSession (the App
// Management explainer), a bottle swap through startReplaceWithBottle.
// Other actions show no Retry: they ask first from where they started.

extension UpgradeSession {
    /// The one thing to do next, for the last failure brew's output explains.
    /// Nil for App Management (its own explainer opens) and when not known.
    public var nextStep: String? {
        guard isFinished, !failedItems.isEmpty, let kind = failureKinds.last else { return nil }
        return Self.nextStep(kind)
    }

    nonisolated static func nextStep(_ kind: BrewFailureKind) -> String? {
        switch kind {
        case .locked: return String(localized: "Another Homebrew command kept brew's lock. Retry once it has finished.")
        case .network: return String(localized: "Check your internet connection, then retry.")
        case .diskFull: return String(localized: "Free up some space (Clean Up helps), then retry.")
        case .permissions: return String(localized: "Homebrew ▸ Health shows which folder isn't writable and how to fix it.")
        case .checksum: return String(localized: "Refresh (it runs brew update), then retry.")
        case .appManagement: return nil
        }
    }

    /// Whether this action can be retried from the sheet.
    nonisolated static func retriesInSheet(_ action: SessionAction) -> Bool {
        switch action {
        case .upgrade, .install, .replaceBottle: return true
        default: return false
        }
    }

    /// The failed steps the sheet offers to retry (not the ones macOS
    /// blocked: the App Management explainer has its own retry).
    public var retryableItems: [Item] {
        guard isFinished, Self.retriesInSheet(action) else { return [] }
        return failedItems.filter { !appManagementBlocked.contains($0.id) }
    }
}

extension AppStore {
    /// Retry (one failed step) or Retry Failed (all of them), through the
    /// action's normal path.
    public func retryInSheet(_ items: [UpgradeSession.Item]? = nil) {
        guard let s = upgrade, s.isFinished else { return }
        let chosen = items ?? s.retryableItems
        let ids = Set(s.retryableItems.map(\.id))
        // The package as brew lists it now (the run's copy may be stale).
        let pkgs = chosen.filter { ids.contains($0.id) }.map(\.package).map { p in packages.first { $0.id == p.id } ?? p }
        guard !pkgs.isEmpty else { return }
        switch s.action {
        case .upgrade:
            let targets = pkgs.filter(\.isManualUpgradeTarget)
            guard !targets.isEmpty else {
                error = StoreError(title: String(localized: "Nothing to retry"),
                                   detail: String(localized: "\(pkgs.map(\.name).joined(separator: ", ")) has nothing left to upgrade."))
                return
            }
            requestUpgradeInActivity(targets)
        case .install:
            let left = pkgs.filter { !installedIDs.contains($0.id) }
            guard !left.isEmpty else { return }
            startSession(.install, packages: left)
        case .replaceBottle:
            startReplaceWithBottle(pkgs)
        default:
            return
        }
    }
}
