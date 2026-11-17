import Foundation
import TankardCore

// v0.6 (part B): the store's side of "Skip this version". Kept out of
// AppStore.swift so that file only gains the hook.

extension AppStore {
    /// 0.6: skip this version, snooze, bump rules.
    public var upgradeRules: UpgradeRulesSettings { autoUpdate.rules }

    func wireUpgradeRules() {
        let rules = autoUpdate.rules
        insights.extraDecoration = { [weak rules] r in
            guard let rules else { return r }
            // A newer version (or an upgrade) clears a skip. Silent: this
            // runs inside a decoration, which is already re-laying the report.
            rules.prune(r.packages, notify: false)
            return rules.decorate(r)
        }
        rules.onSkipsChange = { [weak self] in self?.applyInsights() }
    }

    /// "Skip This Version" / "Don't Skip" (detail pane, right-click).
    public func setVersionSkipped(_ p: Package, _ skipped: Bool) {
        if skipped { upgradeRules.skip(p) } else { upgradeRules.unskip(p) }
    }
}
