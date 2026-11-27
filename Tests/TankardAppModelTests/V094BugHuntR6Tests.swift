import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt, round 6: the R5 reviews' remaining MUST-FIX, against fake
// Homebrew. A foreground upgrade's follow-up status read is held open:
// until it succeeds, Clean Up (whose keep list needs the version the
// upgrade left) starts nothing.

/// Fake Homebrew whose `brew upgrade` of a formula leaves its old version
/// on disk (every read from then on lists two), and holds the status read
/// after it until the test releases it.
@MainActor
private func v094R6HeldReadAfterUpgrade() async throws
    -> (AppStore, V094StatusRunner, CallLog, formula: Package, hold: V094R6HoldBox) {
    var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
    let reads = try v094WrapStatus(&deps)
    let upgraded = V094R6Flag()
    let box = V094R6HoldBox()
    let target = V094R6Flag()
    reads.transform = { data in
        guard upgraded.isSet, let name = target.name else { return data }
        return V094R5InheritedKeepListTests.addOldVersion(of: name, to: data)
    }
    let demo = deps.streamRunner
    let log = CallLog()
    deps.streamRunner = FakeStreamRunner(log: log) { args, out in
        let code = try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        if args.first == "upgrade", code == 0, !upgraded.isSet {
            // The next status read (the run's follow-up) is held.
            box.hold = reads.arm()
            upgraded.set()
        }
        return code
    }
    let store = AppStore(deps: deps, settings: testSettings())
    await store.start()
    store.restorePoints.settings.keepPreviousVersion = true
    let f = try #require(store.upgradable.first {
        $0.kind == .formula && Set($0.installedVersions).count <= 1
            && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
    })
    target.name = f.name
    return (store, reads, log, f, box)
}

final class V094R6Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _set = false
    private var _name: String?
    var isSet: Bool { lock.withLock { _set } }
    func set() { lock.withLock { _set = true } }
    var name: String? {
        get { lock.withLock { _name } }
        set { lock.withLock { _name = newValue } }
    }
}

final class V094R6HoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _hold: V094StatusRunner.Hold?
    var hold: V094StatusRunner.Hold? {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
}

/// Whether fake brew was asked to run the real `brew cleanup`.
private func ranCleanup(_ log: CallLog) -> Bool {
    log.calls.contains { $0 == ["cleanup"] }
}

@MainActor
struct V094R6CleanupWaitsForFollowUpReadTests {
    /// The upgrade finished and its follow-up read is still out: a direct
    /// Clean Up starts nothing. Once the read lands with two versions, the
    /// command Clean Up runs keeps the formula.
    @Test func aDirectStartWaitsForThePendingRead() async throws {
        let (store, reads, log, f, box) = try await v094R6HeldReadAfterUpgrade()
        defer { reads.releaseAll() }
        store.startUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && reads.held == 1 && store.isRefreshing })
        #expect(s.succeededCount == 1)
        let hold = try #require(box.hold)
        #expect(await waitUntil { hold.sampled.isOpen })
        try #require(store.packages.first { $0.id == f.id }.map { Set($0.installedVersions).count } == 1,
                     "the list on screen is still the pre-upgrade one")
        store.closeUpgrade()
        try #require(store.cleanup == nil)
        store.startCleanup()
        #expect(store.upgrade?.action != .cleanup, "no Clean Up against the pre-upgrade list")
        #expect(!ranCleanup(log))

        let completed = store.refreshesCompleted
        hold.gate.release()
        #expect(await waitUntil { store.refreshesCompleted > completed && !store.isRefreshing })
        #expect(store.packages.first { $0.id == f.id }.map { Set($0.installedVersions).count } == 2)
        #expect(!ranCleanup(log), "the held try didn't queue a command for later")
        store.startCleanup()
        let c = try #require(store.upgrade)
        #expect(c.action == .cleanup)
        let keep = c.items.first?.command.environment[CleanupKeep.key] ?? ""
        #expect(keep.split(separator: ",").map(String.init).contains(f.name),
                "the version the upgrade left is kept")
    }

    /// The same with a preview made while the read is out (from the
    /// pre-upgrade list): its Clean Up waits too, and the one that runs is
    /// worked out from the read after the upgrade.
    @Test func aReadyPreviewWaitsForThePendingRead() async throws {
        let (store, reads, log, f, box) = try await v094R6HeldReadAfterUpgrade()
        defer { reads.releaseAll() }
        store.startUpgrade([f])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && reads.held == 1 && store.isRefreshing })
        let hold = try #require(box.hold)
        store.closeUpgrade()
        store.openCleanup()
        let preview = try #require(store.cleanup)
        #expect(await waitUntil { preview.phase == .ready })
        #expect(!(preview.extraEnvironment[CleanupKeep.key] ?? "").contains(f.name), "the old list's preview")
        store.startCleanup()
        #expect(store.upgrade?.action != .cleanup, "the old list's preview doesn't run")
        #expect(!ranCleanup(log))

        let completed = store.refreshesCompleted
        hold.gate.release()
        #expect(await waitUntil { store.refreshesCompleted > completed && !store.isRefreshing })
        // The first try after the read works the preview out again.
        store.startCleanup()
        if store.upgrade?.action != .cleanup {
            let fresh = try #require(store.cleanup)
            #expect(await waitUntil { fresh.phase == .ready })
            store.startCleanup()
        }
        let c = try #require(store.upgrade)
        #expect(c.action == .cleanup)
        let keep = c.items.first?.command.environment[CleanupKeep.key] ?? ""
        #expect(keep.split(separator: ",").map(String.init).contains(f.name))
    }

    /// Before any change, Clean Up isn't held (no read is pending).
    @Test func noChangeNoWait() async throws {
        let (store, reads, _, _, _) = try await v094R6HeldReadAfterUpgrade()
        defer { reads.releaseAll() }
        store.startCleanup()
        #expect(store.upgrade?.action == .cleanup)
    }
}
