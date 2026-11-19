import Foundation
import TankardCore

// v0.4 (part B): the store's side of the insights. Kept out of
// AppStore.swift so that file only gains the hooks.

extension AppStore {
    func wireInsights() {
        insights.installedPackages = { [weak self] in self?.report?.packages ?? [] }
        insights.onUpdate = { [weak self] in self?.applyInsights() }
        insights.settings.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .selfUpdating:
                self.applyInsights()
                // Turned on: ask brew (`brew outdated --greedy`). Off needs no brew.
                if self.insights.settings.includeSelfUpdatingApps, self.report != nil {
                    Task { await self.refresh(manual: false) }
                }
            case .notifyVulnerabilities:
                if self.insights.settings.notifyNewVulnerabilities { self.insights.noticeTurnedOn() }
            case .other:
                break
            }
        }
    }

    /// Lays the latest insights over the report on screen.
    func applyInsights() {
        if let r = report { report = insights.decorate(r) }
    }

    /// Starts the background reads for this brew (sizes; the vulnerability
    /// scan when that setting is on).
    ///
    /// `measureSizes` false: the caller already started `brew info --sizes`
    /// (0.8: beside the status read) or nothing changed on disk.
    func startInsights(force: Bool, measureSizes: Bool = true) {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        insights.refresh(client: client, env: client.environment(for: detection), force: force, formulae: formulaCount,
                         measureSizes: measureSizes)
    }

    /// "Scan now": `brew vulns --json`, whatever the setting.
    public func scanVulnerabilitiesNow() {
        guard insights.scanState != .running else { return }
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return }
        insights.scanVulnerabilities(client: client, env: client.environment(for: detection), formulae: formulaCount)
    }

    /// With "Include self-updating apps" on: `brew outdated --greedy`, run
    /// beside the status read (0.8; it was run after it).
    nonisolated static func readGreedy(_ client: BrewClient, env: [String: String]) async -> Result<BrewOutdatedJSON, Error> {
        do {
            return .success(try await client.greedyOutdatedCasks(env: env))
        } catch {
            return .failure(error)
        }
    }

    /// The casks `brew outdated --greedy` adds (nil: the setting is off).
    /// A failure keeps brew's normal list and says so.
    nonisolated static func markSelfUpdating(_ report: StatusReport, greedy: Result<BrewOutdatedJSON, Error>?) -> StatusReport {
        guard let greedy, report.packages.contains(where: { $0.kind == .cask }) else { return report }
        switch greedy {
        case .success(let g):
            return SelfUpdatingCasks.mark(report, greedy: g)
        case .failure(let error):
            var r = report
            r.warnings.append(String(localized: "Self-updating apps not checked: \(String(describing: error))"))
            return r
        }
    }

    /// "Upgrade vulnerable packages": the vulnerable ones with an upgrade,
    /// through the normal upgrade path (plan sheet, queue), held ones left out.
    public var vulnerableUpgradeTargets: [Package] {
        VulnerabilityUpgrades.targets(packages, isHeld: insights.isHeld)
    }

    public func upgradeVulnerable() {
        requestUpgrade(vulnerableUpgradeTargets)
    }

    /// Total size of everything installed (nil before brew answered).
    public var totalDiskBytes: Int64? { insights.totalBytes(packages) }

    /// After a run: the caveats of what it installed or upgraded, once.
    func offerPostInstallNotes(for session: UpgradeSession) {
        // 0.8.8: not while quitting (a sheet would block the quit).
        guard !terminating else { return }
        let changed = session.items.filter { $0.state == .done }.map(\.package.id)
        let notes = PostInstallNotes.make(action: session.action, changedIDs: changed, packages: packages,
                                          prefix: report?.host.prefix)
        // 0.8.5 (review): a progress-panel run keeps them for its panel, even
        // hidden (the panel shows them when the run is closed).
        insights.offer(notes, sheetOpen: showUpgradeSheet || (runHome == .progressPanel && upgrade === session))
    }

    /// The menu-bar notice's "Show": the Vulnerable list, marked as seen.
    public func showVulnerable() {
        tab = .installed
        search = ""
        filter = .vulnerable
        insights.markVulnerabilitiesSeen()
    }

    /// 0.5: the menu-bar panel's "and N more…": the Upgrades list. Only a
    /// real change is written, so a click on an already-shown list
    /// invalidates nothing.
    public func showUpgrades() {
        if tab != .installed { tab = .installed }
        if !search.isEmpty { search = "" }
        if filter != .upgrades { filter = .upgrades }
    }
}
