import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.9 batch 2: the "Quit anyway?" alert follows the run, and a Brewfile's
// `tap "homebrew/cask"` no longer holds up Install with Tankard.

@MainActor
struct V089Batch2Tests {
    static func prompt(_ name: String, _ index: Int, _ total: Int = 17) -> QuitPrompt {
        QuitPrompt(name: name, index: index, total: total, isUpgrade: true)
    }

    // MARK: the quit alert

    @Test func theAlertKeepsItsTextWhileTheStepIsTheSame() {
        #expect(QuitAlertUpdate.next(shown: Self.prompt("lz4", 9), current: Self.prompt("lz4", 9)) == .unchanged)
    }

    @Test func theAlertTakesTheNextStep() {
        let next = Self.prompt("mise", 10)
        #expect(QuitAlertUpdate.next(shown: Self.prompt("lz4", 9), current: next) == .text(next))
        #expect(QuitAlertUpdate.title(next) == "Homebrew is still upgrading mise (10 of 17). Quit anyway?")
    }

    @Test func theAlertClosesWhenTheRunHasEnded() {
        #expect(QuitAlertUpdate.next(shown: Self.prompt("lz4", 9), current: nil) == .finished)
        #expect(QuitAlertUpdate.finishedTitle == "Homebrew has finished. Quit Tankard?")
        #expect(!QuitAlertUpdate.finishedDetail.isEmpty)
    }

    /// The store's prompt (what the alert's timer reads) moves with the
    /// run and is nil once it has ended, so an open alert closes.
    @Test func theStorePromptFollowsARealRun() async throws {
        let hold = Latch()
        var deps = Demo.dependencies(.arm64, pace: 0.01)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, _ in
            if args.first == "upgrade" { await hold.wait() }
            return 0
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let plain = store.packages.filter {
            $0.isManualUpgradeTarget && $0.kind == .formula && $0.caveats == nil
                && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        }
        try #require(plain.count >= 2)
        store.startUpgrade(Array(plain.prefix(2)))
        let session = try #require(store.upgrade)
        let first = try #require(store.quitPrompt)
        #expect(first.index == 1 && first.total == 2)
        hold.release()
        #expect(await waitUntil { session.isFinished })
        #expect(QuitAlertUpdate.next(shown: first, current: store.quitPrompt) == .finished)
    }

    // MARK: Brewfile built-in taps

    @Test func homebrewCaskTapDoesNotHoldUpInstall() {
        let plan = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .tap, name: "homebrew/cask"),
                                                 BrewfileEntry(kind: .cask, name: "anybar")],
                                       path: "/x/Brewfile", tapSources: ["homebrew/cask": .standard])
        #expect(plan.missingTaps.isEmpty)
        #expect(plan.canInstallWithTankard)
        let tap = plan.items[0]
        #expect(tap.isBuiltInTap)
        #expect(!tap.canAddTap)
    }

    @Test func builtInTapNamesAreMatchedAsBrewBundleDoes() {
        for name in ["homebrew/core", "Homebrew/homebrew-cask", "HOMEBREW/CORE"] {
            let item = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .tap, name: name)], path: "/x").items[0]
            #expect(item.isBuiltInTap, "\(name)")
        }
        // Another Homebrew tap still needs adding.
        let other = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .tap, name: "homebrew/services"),
                                                  BrewfileEntry(kind: .formula, name: "jq")],
                                        path: "/x", tapSources: ["homebrew/services": .standard])
        #expect(!other.items[0].isBuiltInTap)
        #expect(other.missingTaps.count == 1)
        #expect(!other.canInstallWithTankard)
    }
}
