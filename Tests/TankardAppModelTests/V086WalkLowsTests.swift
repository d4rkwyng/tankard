import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6: the walkthrough's cheap Lows (L1 404 vs build failure, L7 restore
// points for runs that changed nothing, L8 "No bottle yet" for tap formulae).
@MainActor
struct V086WalkLowsTests {
    @Test func a404AndABuildFailureAreToldApart() {
        let notFound = ["==> Downloading http://127.0.0.1:8765/walk-404-1.1.tar.gz",
                        "curl: (22) The requested URL returned error: 404",
                        "Error: walk-404: Failed to download resource \"walk-404\""]
        #expect(BrewFailure.classify(notFound) == .notFound)
        let build = ["==> Installing walktest/probe/walk-fail", "Error: An exception occurred within a child process:",
                     "  RuntimeError: walk-fail failed on purpose"]
        #expect(BrewFailure.classify(build) == .buildFailed)
        #expect(BrewFailure.classify(["curl: (6) Could not resolve host: example.com"]) == .network)
        #expect(UpgradeSession.nextStep(.notFound) == "Check Now (it runs brew update) to get the current download address, then upgrade again.")
    }

    func session(_ output: @escaping @Sendable (String) -> String) -> UpgradeSession {
        UpgradeSession(packages: [Package.command("walk-404"), Package.command("walk-fail")], intelbrewMode: false, action: .upgrade,
                       queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { args, out in
                           out(Data(output(args.last ?? "").utf8)); return 1
                       }),
                       makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: ["upgrade", p.name], environment: [:], display: "brew upgrade \(p.name)") },
                       logURL: nil, onFinish: { _ in })
    }

    @Test func a404IsNotOfferedForRetry() async {
        let s = session { name in
            name == "walk-404" ? "curl: (22) The requested URL returned error: 404\n" : "Error: An exception occurred within a child process:\n"
        }
        #expect(await waitUntil { s.isFinished })
        #expect(s.failedItems.count == 2)
        #expect(s.retryableItems.map(\.package.name) == ["walk-fail"])
        #expect(s.subtitle == "The build from source failed")
    }

    /// 0.8.6 (HK-47 review): a run that changed nothing on disk (brew said
    /// "already installed" for each step, exit 0) keeps no restore point.
    @Test func aRunThatChangedNothingKeepsNoRestorePoint() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            out(Data("Warning: \(args.last ?? "") 1.2 already installed\n".utf8))
            return 0
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let before = store.restorePoints.points.count
        let p = try #require(store.upgradable.first { store.deps.classifier.upgradeWarning($0) == nil })
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(store.restorePoints.points.count == before + 1) // saved before it runs
        #expect(await waitUntil { s.isFinished })
        #expect(s.succeededCount == 0)
        #expect(await waitUntil { store.restorePoints.points.count == before })
    }

    /// 0.8.6 (HK-47 review): brew poured a dependency, then the package
    /// asked for failed: the dependency changed, so the point stays
    /// (succeededCount was 0, and the point used to be deleted).
    @Test func aFailedRunThatPouredADependencyKeepsItsRestorePoint() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            out(Data("==> Upgrading \(args.last ?? "")\n==> Installing \(args.last ?? "") dependency: libdep\n==> Pouring libdep--2.0.sonoma.bottle.tar.gz\nError: An exception occurred within a child process:\n".utf8))
            return 1
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let before = store.restorePoints.points.count
        let p = try #require(store.upgradable.first { store.deps.classifier.upgradeWarning($0) == nil })
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
        #expect(s.succeededCount == 0)
        // Give a deletion every chance to happen (it would follow a read).
        #expect(await waitUntil { store.refreshesCompleted >= 2 && !store.isRefreshing })
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.restorePoints.points.count == before + 1)
    }

    /// A stopped run keeps its point too.
    @Test func aStoppedRunKeepsItsRestorePoint() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in
            try await Task.sleep(for: .seconds(30))
            return 0
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let before = store.restorePoints.points.count
        let p = try #require(store.upgradable.first { store.deps.classifier.upgradeWarning($0) == nil })
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        s.stopNow()
        #expect(await waitUntil { s.isFinished })
        #expect(await waitUntil { store.refreshesCompleted >= 2 && !store.isRefreshing })
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.restorePoints.points.count == before + 1)
    }

    @Test func tapFormulaeAreNotPromisedABottle() {
        var p = Package.command("walk-a")
        p.status = .noBottle
        p.tap = "walktest/probe"
        #expect(p.badgeLabel(intelbrewMode: false) == "No bottle")
        #expect(p.noBottleDetail == "Its tap has no bottle for this Mac, so reinstalling or upgrading builds it from source.")
        p.tap = "homebrew/core"
        #expect(p.badgeLabel(intelbrewMode: false) == "No bottle yet")
    }
}
