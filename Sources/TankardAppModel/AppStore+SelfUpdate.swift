import Foundation
import TankardCore

// Tankard ▸ Check for Tankard Updates… (see SelfUpdate.swift).
extension AppStore {
    /// The menu item works only with a feed (not in demo mode or tests).
    public var canCheckForTankardUpdates: Bool { deps.updateFeed != nil && selfUpdate != .checking }

    /// The tankard cask from d4rkwyng/tap that installed this app, if any.
    public var tankardCask: Package? {
        deps.selfCaskOverride ?? SelfInstall.brewPackage(in: packages, bundlePath: deps.bundlePath)
    }

    /// One GET to GitHub, then the sheet shows the result.
    public func checkForTankardUpdates() {
        guard let feed = deps.updateFeed, selfUpdate != .checking else { return }
        selfUpdate = .checking
        showSelfUpdate = true
        Task {
            let result = await feed.check(current: TankardVersion.string)
            self.selfUpdate = result
        }
    }

    public func closeSelfUpdate() {
        showSelfUpdate = false
        if selfUpdate != .checking { selfUpdate = nil }
    }

    /// Upgrade with Homebrew: `brew update` first (Tankard's runs skip
    /// brew's auto-update, and the tap must know the new version), then
    /// the normal upgrade of the cask through the queue and sheet.
    public func upgradeTankardWithBrew(to version: String) {
        guard tankardCask != nil, !isBusy else { return }
        showSelfUpdate = false
        Task {
            await refresh(manual: true)
            if let p = tankardCask, p.upgradeAvailable {
                selfUpdate = nil
                requestUpgrade([p])
            } else {
                selfUpdate = .failed(String(localized: "Homebrew doesn't list Tankard \(version) yet: the tap can take a little while after a release. Try again later, or download it."))
                showSelfUpdate = true
            }
        }
    }

    /// After a run: the tankard cask upgraded, so the app on disk is new
    /// and this process is the old one.
    func selfUpgradeFinished(_ session: UpgradeSession) {
        guard session.action == .upgrade else { return }
        if session.items.contains(where: { $0.state == .done && SelfInstall.isTankardCask($0.package) }) {
            offerRelaunch = true
        }
    }

    /// A stand-in tankard cask for screenshots of the brew-installed sheet.
    public nonisolated static func demoTankardCask(bundlePath: String, version: String = TankardVersion.string) -> Package {
        var p = Package.command("tankard")
        p.id = "cask:d4rkwyng/tap/tankard"
        p.kind = .cask
        p.name = "tankard"
        p.fullName = UpdateFeed.tapCask
        p.tap = "d4rkwyng/tap"
        p.installedVersion = version
        p.installedVersions = [version]
        p.appPaths = [bundlePath]
        return p
    }
}
