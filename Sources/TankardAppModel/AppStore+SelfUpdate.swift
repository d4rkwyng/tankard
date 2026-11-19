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

    /// One GET to GitHub, then the sheet shows the result. 0.8.3: when the
    /// list on screen doesn't show the tankard cask but brew's Caskroom has
    /// one (the cask was installed after the status cache was written, and
    /// the cache is under an hour old), the list is re-read first, so the
    /// sheet offers Upgrade with Homebrew rather than Download.
    public func checkForTankardUpdates() {
        guard let feed = deps.updateFeed, selfUpdate != .checking, !selfReplaced else { return }
        selfUpdate = .checking
        showSelfUpdate = true
        let reread = needsSelfCaskRead
        Task {
            async let result = feed.check(current: TankardVersion.string)
            if reread { await refresh(manual: false) }
            self.selfUpdate = await result
        }
    }

    /// No tankard cask in the list, but `<prefix>/Caskroom/tankard` exists.
    var needsSelfCaskRead: Bool {
        guard tankardCask == nil, let client = try? resolvedClient() else { return false }
        let room = (client.installation.prefix as NSString).appendingPathComponent("Caskroom/tankard")
        return deps.selfCaskroomExists(room)
    }

    public func closeSelfUpdate() {
        showSelfUpdate = false
        if selfUpdate != .checking { selfUpdate = nil }
    }

    /// Upgrade with Homebrew: `brew update` first (Tankard's runs skip
    /// brew's auto-update, and the tap must know the new version), then
    /// the normal upgrade of the cask through the queue and sheet.
    public func upgradeTankardWithBrew(to version: String) {
        guard tankardCask != nil, !isBusy, !selfReplaced else { return }
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
            selfReplaced = true
            offerRelaunch = true
        }
    }

    /// The "Tankard was upgraded" alert's Relaunch: the same quit-then-open
    /// helper as the App Management relaunch (deps.relaunch). It closes
    /// every sheet, quits this process, and the helper opens the new bundle
    /// only once this pid has exited, so two Tankards never run. Without a
    /// relaunch (a build run outside an app bundle) or if the helper can't
    /// start: say to quit and reopen.
    public func relaunchAfterSelfUpgrade() {
        offerRelaunch = false
        dismissPresentations()
        if let relaunch = deps.relaunch, relaunch() { return }
        error = StoreError(title: String(localized: "Couldn't relaunch Tankard"),
                           detail: Self.quitAndReopen)
    }

    /// Every sheet the store presents, closed in its own state, so SwiftUI
    /// doesn't put one back after the relaunch ends it in AppKit (AppKit
    /// refuses to terminate under a sheet; the first e2e run saw the first
    /// terminate refused with the History sheet's state still set).
    /// The same set as `isSheetPresented` (Pins.swift); a test keeps them
    /// in step.
    func dismissPresentations() {
        if upgrade.map(\.isFinished) ?? true { showUpgradeSheet = false }
        showSelfUpdate = false
        uninstallCandidate = nil
        showCleanupSheet = false
        managementSheet = nil
        showAutoUpdateLog = false
        toolSheet = nil
        restorePoints.isShowing = false
        insights.postInstallNotes = nil
        // Counted by isSheetPresented but missing here before 0.8.5.
        brewfile.dismiss()
        discover?.confirmInstall = nil
    }

    /// The relaunch couldn't quit this copy (or couldn't start).
    public static var quitAndReopen: String {
        String(localized: "Quit Tankard and open it again to use the new version.")
    }

    /// The relaunch started but this process is still running: something
    /// refused to let it quit. The helper opens nothing; the user quits.
    public func relaunchGaveUp() {
        terminationCancelled()
        error = StoreError(title: String(localized: "Couldn't relaunch Tankard"), detail: Self.quitAndReopen)
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
