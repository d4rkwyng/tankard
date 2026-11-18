import Foundation
import TankardCore

// v0.6 (part B): the store's side of "Skip this version". Kept out of
// AppStore.swift so that file only gains the hook.

extension AppStore {
    /// 0.6: skip this version, snooze, bump rules.
    public var upgradeRules: UpgradeRulesSettings { autoUpdate.rules }

    func wireUpgradeRules() {
        let rules = autoUpdate.rules
        insights.extraDecoration = { [weak rules, weak self] r in
            guard let rules else { return r }
            // A newer version (or an upgrade) clears a skip. Silent: this
            // runs inside a decoration, which is already re-laying the report.
            rules.prune(r.packages, notify: false)
            // 0.8.6 (M5): "Include self-updating apps" off leaves them all to the app.
            return rules.decorate(r, includeSelfUpdating: self?.insights.settings.includeSelfUpdatingApps ?? true)
        }
        rules.onSkipsChange = { [weak self] in self?.applyInsights() }
        // 0.8: per-app self-update choices.
        insights.keepSelfUpdating = { [weak rules] p in
            guard let rules else { return false }
            return SelfUpdateRule.keptByHomebrew(p, homebrewTokens: rules.homebrewUpdatedTokens)
        }
        rules.onPolicyChange = { [weak self] in
            guard let self else { return }
            self.applyInsights()
            // A cask newly set to "Homebrew updates it" needs brew's --greedy list.
            if !self.insights.settings.includeSelfUpdatingApps, self.report != nil,
               self.packages.contains(where: { SelfUpdateRule.keptByHomebrew($0, homebrewTokens: rules.homebrewUpdatedTokens) && $0.selfUpdatingUpgrade == nil && !$0.upgradeAvailable }) {
                Task { await self.refresh(manual: false) }
            }
        }
    }

    /// 0.8: "App updates itself" / "Homebrew updates it" (detail pane, Adopt Apps).
    public func selfUpdatePolicy(_ p: Package) -> SelfUpdatePolicy { upgradeRules.selfUpdatePolicy(SelfUpdateRule.key(p)) }

    public func setSelfUpdatePolicy(_ p: Package, _ policy: SelfUpdatePolicy) {
        guard p.kind == .cask else { return }
        upgradeRules.setSelfUpdatePolicy(SelfUpdateRule.key(p), policy)
    }

    /// "Skip Version X" / "Don't Skip" (detail pane, right-click).
    public func setVersionSkipped(_ p: Package, _ skipped: Bool) {
        if skipped { upgradeRules.skip(p) } else { upgradeRules.unskip(p) }
    }
}
