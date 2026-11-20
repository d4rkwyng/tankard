import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.9: polish from the 0.8.8 confirm runs.

/// Upgrading Tankard's own cask: the plan no longer says Tankard will be
/// "closed during the upgrade and opened again afterwards"; it stays open
/// and offers to relaunch.
@MainActor
struct V089SelfUpgradeWordingTests {
    func cask(_ name: String, tap: String) -> Package {
        var p = pkg(name, kind: .cask)
        p.id = "cask:\(tap)/\(name)"
        p.tap = tap
        return p
    }

    @Test func tankardIsNotListedAsClosedAndGetsItsOwnNote() {
        let tankard = AppStore.demoTankardCask(bundlePath: "/Applications/Tankard.app", version: "0.8.8")
        #expect(SelfInstall.isTankardCask(tankard))
        var plan = UpgradePlan(packages: [tankard], classifier: CompileClassifier())
        plan.runningApps = [RunningCaskApp(packageID: tankard.id, name: "Tankard")]
        #expect(plan.runningAppsToRun.isEmpty)
        #expect(plan.runningAppsNote == nil)
        #expect(plan.selfUpgradeNote == "Tankard stays open while Homebrew replaces it, then offers to relaunch into the new version.")
        // Still confirmed first, as before.
        #expect(plan.needsConfirmation)
    }

    @Test func otherOpenAppsStillListed() {
        let tankard = AppStore.demoTankardCask(bundlePath: "/Applications/Tankard.app", version: "0.8.8")
        let chrome = cask("google-chrome", tap: "homebrew/cask")
        var plan = UpgradePlan(packages: [tankard, chrome], classifier: CompileClassifier())
        plan.runningApps = [RunningCaskApp(packageID: tankard.id, name: "Tankard"),
                            RunningCaskApp(packageID: chrome.id, name: "Google Chrome")]
        #expect(plan.runningAppsToRun == ["Google Chrome"])
        #expect(plan.runningAppsNote?.contains("Tankard") == false)
        #expect(plan.selfUpgradeNote != nil)
        // A tankard cask from another tap is just another app.
        let other = cask("tankard", tap: "someone/tap")
        var plan2 = UpgradePlan(packages: [other], classifier: CompileClassifier())
        plan2.runningApps = [RunningCaskApp(packageID: other.id, name: "Tankard")]
        #expect(plan2.selfUpgradeNote == nil)
        #expect(plan2.runningAppsToRun == ["Tankard"])
    }
}
