import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.6 (part B): skip this version, snooze, bump rules.

func freshDefaults(_ tag: String = #function) -> UserDefaults {
    let name = "tankard-test-v06b-\(tag)-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

struct VersionBumpTests {
    @Test func classifies() {
        #expect(VersionBump.classify(from: "1.2.3", to: "1.2.4") == .patch)
        #expect(VersionBump.classify(from: "1.9", to: "1.10") == .minor)
        #expect(VersionBump.classify(from: "2.4.1", to: "3.0") == .major)
        #expect(VersionBump.classify(from: "2.9", to: "3.0.0") == .major)
        #expect(VersionBump.classify(from: "1.2", to: "1.2.1") == .patch)
        #expect(VersionBump.classify(from: "1", to: "2") == .major)
        #expect(VersionBump.classify(from: "1.2.3.4", to: "1.2.3.5") == .patch)
    }

    @Test func revisions() {
        // "_1" revisions: a revision-only change is a patch; the version part decides otherwise.
        #expect(VersionBump.classify(from: "1.5.7", to: "1.5.7_1") == .patch)
        #expect(VersionBump.classify(from: "1.5.7_1", to: "1.5.7_2") == .patch)
        #expect(VersionBump.classify(from: "1.5.7_2", to: "1.6.0") == .minor)
        #expect(VersionBump.classify(from: "1.5.7_2", to: "2.0_1") == .major)
    }

    @Test func uncomparable() {
        #expect(VersionBump.classify(from: "20240101", to: "20241101") == .unknown)
        #expect(VersionBump.classify(from: "2024.01.15", to: "2024.02.01") == .unknown)
        #expect(VersionBump.classify(from: "1.2a", to: "1.2b") == .unknown)
        #expect(VersionBump.classify(from: "9.1-beta", to: "9.1") == .unknown)
        #expect(VersionBump.classify(from: "latest", to: "latest") == .unknown)
        #expect(VersionBump.classify(from: "1.2.3", to: "1.2.3") == .unknown)
        #expect(VersionBump.classify(from: "HEAD-abc", to: "1.0") == .unknown)
    }

    @Test func caskBuildSuffix() {
        #expect(VersionBump.classify(from: "1.2.3,100", to: "1.2.3,101") == .patch)
        #expect(VersionBump.classify(from: "1.2.3,100", to: "1.3.0,120") == .minor)
    }

    @Test func rules() {
        for b in [VersionBump.patch, .minor, .major, .unknown] { #expect(BumpRule.all.allows(b)) }
        #expect(BumpRule.minorAndPatch.allows(.patch))
        #expect(BumpRule.minorAndPatch.allows(.minor))
        #expect(!BumpRule.minorAndPatch.allows(.major))
        #expect(!BumpRule.minorAndPatch.allows(.unknown))
        #expect(BumpRule.patchOnly.allows(.patch))
        #expect(!BumpRule.patchOnly.allows(.minor))
        #expect(!BumpRule.patchOnly.allows(.unknown))
    }
}

func versioned(_ name: String, _ from: String, _ to: String, kind: PackageKind = .formula) -> Package {
    var p = pkg(name, kind: kind)
    p.installedVersion = from
    p.installedVersions = [from]
    p.currentVersion = to
    return p
}

@MainActor
struct UpgradeRulesTests {
    /// The 0.3.1 rule: writing the value a setting already has notifies
    /// nothing and writes nothing.
    @Test func equalWritesDropped() {
        let d = freshDefaults()
        let s = UpgradeRulesSettings(defaults: d)
        func unchanged<T>(_ key: String, _ read: @escaping () -> T, _ write: () -> Void) {
            let notified = Flag()
            withObservationTracking { _ = read() } onChange: { notified.set() }
            write()
            #expect(!notified.value, "\(key) notified on an equal write")
            #expect(d.object(forKey: key) == nil, "\(key) was written on an equal write")
        }
        unchanged("autoUpdateBumpRule", { s.bumpRule }) { s.bumpRule = .all }
        unchanged("autoUpdateSnoozeUntil", { s.snoozeUntil }) { s.snoozeUntil = nil }
        unchanged("autoUpdateSnoozeIndefinite", { s.snoozedIndefinitely }) { s.snoozedIndefinitely = false }
        unchanged("upgradeSkippedVersions", { s.skippedVersions }) { s.skippedVersions = [:] }
        unchanged("upgradeSkippedVersions", { s.skippedVersions }) { s.resume() }
        unchanged("upgradeSkippedVersions", { s.skippedVersions }) { s.unskip(versioned("xz", "1", "2")) }
        unchanged("upgradeSkippedVersions", { s.skippedVersions }) { s.prune([]) }
        // A real change notifies once.
        let notified = Flag()
        withObservationTracking { _ = s.bumpRule } onChange: { notified.set() }
        s.bumpRule = .patchOnly
        #expect(notified.value)
    }

    @Test func persists() {
        let d = freshDefaults()
        let s = UpgradeRulesSettings(defaults: d)
        s.bumpRule = .minorAndPatch
        s.skip(versioned("xz", "5.8.1", "5.8.2"))
        s.snooze(.week, now: at(10))
        let t = UpgradeRulesSettings(defaults: d)
        #expect(t.bumpRule == .minorAndPatch)
        #expect(t.skippedVersions == ["formula:homebrew/core/xz": "5.8.2"])
        #expect(t.snoozeUntil == at(10, days: 7))
    }

    @Test func skipAndAutoClear() {
        let s = UpgradeRulesSettings(defaults: freshDefaults())
        let xz = versioned("xz", "5.8.1", "5.8.2")
        s.skip(xz)
        #expect(s.isSkipped(xz))
        // The same version still on offer: kept.
        s.prune([xz])
        #expect(s.isSkipped(xz))
        // A newer version appears: cleared.
        let newer = versioned("xz", "5.8.1", "5.8.3")
        #expect(!s.isSkipped(newer))
        s.prune([newer])
        #expect(s.skippedVersions.isEmpty)
        // Upgraded by hand, or uninstalled: cleared too.
        s.skip(xz)
        var done = xz
        done.upgradeAvailable = false
        s.prune([done])
        #expect(s.skippedVersions.isEmpty)
        s.skip(xz)
        s.prune([])
        #expect(s.skippedVersions.isEmpty)
        // Nothing on offer: nothing to skip.
        s.skip(done)
        #expect(s.skippedVersions.isEmpty)
    }

    @Test func skippedLeavesCountsNotManualUpgrade() {
        let s = UpgradeRulesSettings(defaults: freshDefaults())
        let xz = versioned("xz", "5.8.1", "5.8.2")
        s.skip(xz)
        let packages = [xz, versioned("jq", "1.7", "1.8")].map { p -> Package in
            var p = p
            p.versionSkipped = s.isSkipped(p) ? true : nil
            return p
        }
        let dxz = packages[0]
        #expect(dxz.versionSkipped == true)
        #expect(!dxz.isUpgradeTarget)
        #expect(dxz.isManualUpgradeTarget)
        #expect(packages[1].isUpgradeTarget)
        #expect(MenuBarSummary(packages: packages).count == 1)
    }

    @Test func snoozeExpiry() {
        let s = UpgradeRulesSettings(defaults: freshDefaults())
        #expect(!s.isSnoozed(now: at(10)))
        s.snooze(.day, now: at(10))
        #expect(s.isSnoozed(now: at(10)))
        #expect(s.isSnoozed(now: at(9, 59, days: 1)))
        #expect(!s.isSnoozed(now: at(10, days: 1)))
        s.snooze(.untilResumed, now: at(10))
        #expect(s.snoozeUntil == nil)
        #expect(s.isSnoozed(now: at(10, days: 400)))
        #expect(s.snoozeEnds == nil)
        s.resume()
        #expect(!s.isSnoozed(now: at(10)))
        s.snooze(.week, now: at(10))
        #expect(!s.snoozedIndefinitely)
        #expect(s.isSnoozed(now: at(10, days: 6)))
        #expect(!s.isSnoozed(now: at(10, days: 7)))
    }

    @Test func snoozedDecision() {
        let d = AutoUpdatePolicy.decide(enabled: true, schedule: AutoUpdateSchedule(), since: nil, lastRun: nil,
                                        launchedAt: at(0, days: -1), now: at(10), onAC: true, idle: 3600, busy: false,
                                        snoozed: true, snoozeEnds: at(10, days: 1), calendar: utc)
        #expect(d == .snoozed(until: at(10, days: 1)))
        #expect(AutoUpdateText.status(d, now: at(10), calendar: utc) == "Snoozed until tomorrow 10:00")
        #expect(AutoUpdateText.status(.snoozed(until: nil), now: at(10), calendar: utc) == "Snoozed until turned back on")
        // Off still wins.
        let off = AutoUpdatePolicy.decide(enabled: false, schedule: AutoUpdateSchedule(), since: nil, lastRun: nil,
                                          launchedAt: at(0), now: at(10), onAC: true, idle: 3600, busy: false,
                                          snoozed: true, calendar: utc)
        #expect(off == .off)
    }

    @Test func planAppliesRules() {
        let c = CompileClassifier()
        let all = [versioned("a", "1.2.3", "1.2.4"), versioned("b", "1.9", "1.10"), versioned("c", "2.4", "3.0"),
                   versioned("d", "20240101", "20241101"), versioned("e", "1.0", "1.0_1"), versioned("f", "1.0", "1.1")]
        func plan(_ rule: BumpRule, skipped: [String: String] = [:]) -> AutoUpdatePlan {
            AutoUpdateSafeMode.plan(all, classifier: c, running: [], dontQuitApps: false,
                                    rules: UpgradeRuleSnapshot(bumpRule: rule, skipped: skipped))
        }
        #expect(plan(.all).run.map(\.name) == ["a", "b", "c", "d", "e", "f"])
        #expect(plan(.minorAndPatch).run.map(\.name) == ["a", "b", "e", "f"])
        let patch = plan(.patchOnly)
        #expect(patch.run.map(\.name) == ["a", "e"])
        let reasons = Dictionary(uniqueKeysWithValues: patch.skipped.map { ($0.package.name, $0.reason.text) })
        #expect(reasons["c"] == "2.4 → 3.0: major version; upgrade by hand")
        #expect(reasons["b"] == "1.9 → 1.10: minor version; upgrade by hand")
        #expect(reasons["d"]?.contains("can't be compared") == true)
        let skipped = plan(.all, skipped: ["formula:homebrew/core/f": "1.1"])
        #expect(!skipped.run.map(\.name).contains("f"))
        #expect(skipped.skipped.first { $0.package.name == "f" }?.reason == .versionSkipped("1.1"))
        // A skip of an older version doesn't hold back the newer one.
        let stale = plan(.all, skipped: ["formula:homebrew/core/f": "1.0.5"])
        #expect(stale.run.map(\.name).contains("f"))
        // Safe mode still comes first: a pinned package is "pinned", not a bump.
        var pinned = versioned("g", "1.0", "2.0")
        pinned.pinned = true
        let p2 = AutoUpdateSafeMode.plan([pinned], classifier: c, running: [], dontQuitApps: false,
                                         rules: UpgradeRuleSnapshot(bumpRule: .patchOnly))
        #expect(p2.skipped.first?.reason == .pinned)
    }
}


@MainActor
struct SkipVersionStoreTests {
    @Test func skipInDemo() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        #expect(store.upgradable.count == 5)
        let p = try #require(store.upgradable.first)
        store.setVersionSkipped(p, true)
        #expect(store.upgradable.count == 4)
        let skipped = try #require(store.packages.first { $0.id == p.id })
        #expect(skipped.versionSkipped == true)
        #expect(skipped.upgradeAvailable)
        #expect(MenuBarSummary(packages: store.packages).count == 4)
        // A refresh with the same version on offer keeps the skip.
        await store.refresh(manual: false)
        #expect(store.upgradable.count == 4)
        #expect(store.upgradeRules.skippedVersions[p.id] == p.currentVersion)
        // Manual Upgrade of that package still runs it.
        store.startUpgrade([skipped])
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.package.id) == [p.id])
        #expect(await waitUntil { session.isFinished })
        // Upgraded: the skip clears on the reconcile.
        #expect(await waitUntil { !store.isRefreshing && store.upgradeRules.skippedVersions.isEmpty })
        store.setVersionSkipped(skipped, false)
        #expect(store.upgradeRules.skippedVersions.isEmpty)
    }
}
