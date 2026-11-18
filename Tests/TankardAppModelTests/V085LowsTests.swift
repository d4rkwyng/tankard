import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 bug hunt, the low findings: L6 (Restore with nothing to run), L8
// (Remove Tap and trust), L9 (multi-keg uninstall chips), L12 (Services
// command box).
@MainActor
struct V085LowsTests {
    @Test func restoreWithNothingToRunSaysWhy() {
        func at(_ name: String, _ version: String) -> Package {
            var p = pkg(name, outdated: false)
            p.installedVersion = version
            p.installedVersions = [version]
            return p
        }
        let point = RestorePoint.capture([at("bh-b", "1.0")], at: Date(timeIntervalSince1970: 1_800_000_000), reason: .upgrade)
        let now = [at("bh-b", "1.1")]
        let plan = RestorePlan.make(RestoreDiff.between(point, now), installed: now, pinAfter: false, keepPrevious: true)
        #expect(plan.steps.isEmpty)
        #expect(plan.confirmTitle == "Nothing to restore")
        #expect(!plan.confirmTitle.contains("0"))
        #expect(plan.confirmSubtitle.contains("The old versions were removed by cleanup"))
        #expect(plan.confirmSubtitle.contains("bh-b: Old version removed by cleanup"))
        let one = RestorePlan(steps: [RestoreStep(kind: .pin, package: "x", arguments: ["pin", "x"], environment: [:])])
        #expect(one.confirmTitle == "Run 1 brew command?")
        #expect(one.confirmSubtitle.hasPrefix("One at a time"))
    }

    @Test func removeTapUntrustsFirst() {
        #expect(TapCommands.remove("me/tools", official: false) == [["untrust", "--tap", "me/tools"], ["untap", "me/tools"]])
        #expect(TapCommands.remove("homebrew/cask", official: true) == [["untap", "homebrew/cask"]])
        let rows = AppStore.removeTapPlaceholders(TapInfo(name: "me/tools"))
        #expect(rows.map { BrewCommands.arguments(.untap, for: $0) } == [["untrust", "--tap", "me/tools"], ["untap", "me/tools"]])
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(AppStore.removeTapPlaceholders(TapInfo(name: "homebrew/cask", official: true)).count == 1)
    }

    @Test func multiKegStepsCarryTheirVersion() {
        var f = pkg("bh-a", outdated: false)
        f.installedVersion = "1.2"
        f.installedVersions = ["1.0", "1.2", "1.1"]
        let steps = AppStore.uninstallSteps([f])
        #expect(steps.map(\.installedVersion) == ["1.2", "1.1", "1.0"])
        #expect(steps.allSatisfy { $0.id == f.id && $0.installedVersions.count == 3 })
        #expect(steps.map { BrewCommands.uninstallArguments(for: $0) }.allSatisfy { $0 == ["uninstall", "--formula", f.qualifiedName] })
        var one = pkg("jq", outdated: false)
        one.installedVersion = "1.7"
        one.installedVersions = ["1.7"]
        #expect(AppStore.uninstallSteps([one]).map(\.installedVersion) == ["1.7"])
    }

    @Test func servicesCommandBoxHasNoStrayDashes() {
        #expect(BrewServices.displayArguments(.stop, "bh-svc") == ["services", "stop", "bh-svc"])
        #expect(BrewServices.arguments(.stop, "bh-svc") == ["services", "stop", "--", "bh-svc"])
        #expect(BrewServices.displayArguments(.stop, "--all") == ["services", "stop", "--", "--all"])
    }
}
