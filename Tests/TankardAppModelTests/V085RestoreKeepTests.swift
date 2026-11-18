import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: Restore Points says why upgrades can't be rolled back: a banner
// with Keep Old Versions while "Keep the previous version after upgrades" is
// off, and each row whose old version is gone says it was removed by cleanup.
@MainActor
struct V085RestoreKeepTests {
    func at(_ name: String, _ version: String, kegs: [String]) -> Package {
        var p = pkg(name, outdated: false)
        p.installedVersion = version
        p.installedVersions = kegs
        return p
    }

    @Test func bannerUntilKeepOldVersions() {
        let defaults = freshDefaults()
        let points = RestorePointStore(directory: nil, settings: RollbackSettings(defaults: defaults))
        #expect(points.showsKeepOldVersionsBanner)
        points.keepOldVersions()
        #expect(points.settings.keepPreviousVersion)
        #expect(!points.showsKeepOldVersionsBanner)
        // The same setting as Settings ▸ Upgrades, saved.
        #expect(RollbackSettings(defaults: defaults).keepPreviousVersion)
        #expect(!RestorePointStore(directory: nil, settings: RollbackSettings(defaults: defaults)).showsKeepOldVersionsBanner)
    }

    @Test func cleanedUpRowsSayWhy() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let point = RestorePoint.capture([at("xz", "5.8.2", kegs: ["5.8.2"]), at("jq", "1.7", kegs: ["1.7"])], at: t0, reason: .upgrade)
        let now = [at("xz", "5.8.3", kegs: ["5.8.3"]), at("jq", "1.8", kegs: ["1.8"])]
        let diff = RestoreDiff.between(point, now)
        for c in diff.upgraded {
            #expect(RollbackPolicy.eligibility(c, installed: now) == .manual(.cleanedUp))
        }
        #expect(RollbackBlock.cleanedUp.title == "Old version removed by cleanup")
        let plan = RestorePlan.make(diff, installed: now, pinAfter: false)
        #expect(plan.steps.isEmpty)
        #expect(plan.nothingToRestoreReason == "The old versions were removed by cleanup, so nothing here can be rolled back.")
        let text = try? #require(plan.notIncludedText)
        #expect(text?.hasPrefix("Not included, can't roll back automatically: ") == true)
        #expect(text?.contains("xz (Old version removed by cleanup)") == true)
        #expect(text?.contains("jq (Old version removed by cleanup)") == true)
        // Keeping old versions: the help no longer says to turn it on.
        #expect(RollbackBlock.cleanedUp.explanation(keepPrevious: false).contains("Keep the previous version after upgrades"))
        #expect(!RollbackBlock.cleanedUp.explanation(keepPrevious: true).contains("Keep the previous version after upgrades"))
        #expect(RollbackBlock.pinned.explanation(keepPrevious: true) == RollbackBlock.pinned.explanation)
    }

    @Test func otherBlocksKeepTheGenericReason() {
        let plan = RestorePlan()
        #expect(plan.notIncludedText == nil)
        #expect(plan.nothingToRestoreReason == "Nothing here can be restored automatically")
    }
}
