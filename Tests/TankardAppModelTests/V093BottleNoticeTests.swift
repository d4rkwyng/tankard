import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

// 0.9.3 (hardening of 0a905e1 / 85db319): banner paths the 0.9.2 tests
// don't reach. The banner adds a later bottle to the ones it names, and a
// Replace with Bottle takes formulae off it only when its run starts.

/// demoIntelInfo() with `sourceBuilt` installed from source, and those in
/// `noBottle` without a bottle for their current version.
func bottleNoticeInfo(sourceBuilt: Set<String>, noBottle: Set<String>) -> Data {
    let base = demoIntelInfo()
    guard var root = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
          var formulae = root["formulae"] as? [[String: Any]] else { return base }
    for i in formulae.indices {
        guard let name = formulae[i]["name"] as? String else { continue }
        if sourceBuilt.contains(name), var installed = formulae[i]["installed"] as? [[String: Any]] {
            for k in installed.indices { installed[k]["poured_from_bottle"] = false }
            formulae[i]["installed"] = installed
        }
        if noBottle.contains(name) { formulae[i]["bottle"] = [String: Any]() }
    }
    root["formulae"] = formulae
    return (try? JSONSerialization.data(withJSONObject: root)) ?? base
}

@MainActor
struct V093BottleNoticeTests {
    let base = BottleNoticeStoreTests()
    /// A second formula built from source (vim is the fixture's own).
    static let other = "lua"
    static let both: Set<String> = ["vim", other]

    /// vim gains a bottle, then lua: one banner naming both.
    func bothAnnounced(_ settings: AppSettings,
                       stream: @escaping @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32 = { _, _ in 0 })
        async throws -> (AppStore, MutableInfoRunner, CallLog) {
        let (store, runner, log, _) = await base.rig(settings, info: bottleNoticeInfo(sourceBuilt: Self.both, noBottle: Self.both),
                                                      stream: stream)
        try #require(store.bottleReplaceable.isEmpty)
        runner.info = bottleNoticeInfo(sourceBuilt: Self.both, noBottle: [Self.other])
        await store.refreshFromUser(windowInFront: { true })
        try #require(store.bottleNoticePackages.map(\.name) == ["vim"])
        runner.info = bottleNoticeInfo(sourceBuilt: Self.both, noBottle: [])
        await store.refreshFromUser(windowInFront: { true })
        try #require(Set(store.bottleReplaceable.map(\.name)) == Self.both, "the fixture's \(Self.other) isn't a plain source build")
        return (store, runner, log)
    }

    /// A bottle announced while the banner names another: the banner names
    /// both (not only the latest), and the status bar says only the new one.
    @Test func aLaterBottleIsAddedToTheBanner() async throws {
        let (store, _, log) = try await bothAnnounced(testSettings())
        #expect(store.bottleNoticePackages.map(\.name).sorted() == ["lua", "vim"])
        #expect(store.bottleNoticeText == "Bottles are available for lua, vim")
        #expect(store.checkNote?.hasPrefix("A bottle is available for lua") == true)
        #expect(log.count("reinstall") == 0)
        // Closed: neither comes back on the next refresh.
        store.dismissBottleNotice()
        await store.refreshFromUser(windowInFront: { true })
        #expect(store.bottleNotice == nil)
    }

    /// Replace with Bottle for one of them (the detail pane's button): only
    /// that one leaves the banner.
    @Test func replacingOneTakesOnlyThatOneOffTheBanner() async throws {
        let (store, _, log) = try await bothAnnounced(testSettings())
        let vim = try #require(store.packages.first { $0.name == "vim" })
        store.startReplaceWithBottle([vim])
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.package.name) == ["vim"])
        #expect(store.bottleNoticePackages.map(\.name) == ["lua"])
        #expect(await waitUntil { session.isFinished })
        #expect(log.calls.filter { $0.first == "reinstall" } == [["reinstall", "--force-bottle", "--formula", "homebrew/core/vim"]])
    }

    /// Replace with Bottle while another run has the sheet: nothing starts,
    /// so the banner keeps naming them (they weren't replaced).
    @Test(.timeLimit(.minutes(1))) func aReplaceThatDoesNotStartKeepsTheBanner() async throws {
        let gate = Latch()
        let (store, _, log) = try await bothAnnounced(testSettings()) { args, _ in
            if args.first == "upgrade" { await gate.wait() }
            return 0
        }
        let target = try #require(store.upgradable.filter(\.isManualUpgradeTarget).first)
        store.startUpgrade([target])
        let running = try #require(store.upgrade)
        #expect(await waitUntil { running.current != nil })
        store.replaceNoticedBottles()
        #expect(store.upgrade === running, "a replace started over a running upgrade")
        #expect(store.bottleNoticePackages.map(\.name).sorted() == ["lua", "vim"])
        let vim = try #require(store.packages.first { $0.name == "vim" })
        store.startReplaceWithBottle([vim])
        #expect(store.upgrade === running)
        #expect(store.bottleNoticePackages.map(\.name).sorted() == ["lua", "vim"])
        gate.release()
        #expect(await waitUntil { running.isFinished })
        #expect(log.count("reinstall") == 0)
    }
}
