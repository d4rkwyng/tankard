import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (final gauntlet, bug 1): a quit from outside (the Dock's Quit,
// AppleScript's `quit`, a logout, restart or shutdown) did nothing while a
// sheet was open: AppKit refused the quit Apple Event under the sheet
// (-128). It now takes ⌘Q's path: brew running, ⌘Q's question; otherwise
// every sheet closes and Tankard quits. A sheet changes nothing.
struct V088ExternalQuitTests {
    static let prompt = QuitPrompt(name: "xz", index: 2, total: 7, isUpgrade: true)
    static let sources: [QuitSource] = [.menu] + QuitEventReason.allCases.map { .appleEvent($0) }

    @Test func theQuitReasonsCodes() {
        #expect(QuitEventReason(code: nil) == .user)
        #expect(QuitEventReason(code: 0) == .user)
        #expect(QuitEventReason(code: QuitEventReason.fourCC("logo")) == .logOut)   // kAELogOut
        #expect(QuitEventReason(code: QuitEventReason.fourCC("rlgo")) == .logOut)   // kAEReallyLogOut
        #expect(QuitEventReason(code: QuitEventReason.fourCC("rrst")) == .restart)  // kAEShowRestartDialog
        #expect(QuitEventReason(code: QuitEventReason.fourCC("rest")) == .restart)  // kAERestart
        #expect(QuitEventReason(code: QuitEventReason.fourCC("rsdn")) == .shutDown) // kAEShowShutdownDialog
        #expect(QuitEventReason(code: QuitEventReason.fourCC("shut")) == .shutDown) // kAEShutDown
        #expect(QuitEventReason.fourCC("logo") == 0x6C6F_676F)
        #expect(!QuitEventReason.user.isSystem)
        #expect(QuitEventReason.allCases.filter(\.isSystem).count == 3)
    }

    /// Nothing running: every source, with or without a sheet, closes the
    /// sheets and quits (no question; a logout isn't held up).
    @Test func notRunningAlwaysClosesSheetsAndQuits() {
        for source in Self.sources {
            for sheet in [false, true] {
                #expect(QuitDecision.decide(source, step: .closeSheetsAndQuit, sheetOpen: sheet) == .closeSheetsAndQuit,
                        "\(source) sheet=\(sheet)")
            }
        }
    }

    /// brew running: every source, with or without a sheet, asks ⌘Q's
    /// question; one from outside brings Tankard forward to ask it.
    @Test func runningAlwaysAsksFirst() {
        for source in Self.sources {
            for sheet in [false, true] {
                let d = QuitDecision.decide(source, step: .ask(Self.prompt), sheetOpen: sheet)
                #expect(d == .ask(Self.prompt, bringForward: source != .menu), "\(source) sheet=\(sheet)")
            }
        }
    }

    /// A quit already agreed to (the App Management relaunch, an answered
    /// question) or no store: straight to closing sheets and quitting.
    @Test func anAgreedQuitDoesNotAskAgain() {
        for source in Self.sources {
            #expect(QuitDecision.decide(source, step: nil, sheetOpen: true) == .closeSheetsAndQuit)
        }
        #expect(QuitDecision.cancelledReplyError == -128)
    }

    /// The decision follows the store's own state: a run going asks, a
    /// finished run's sheet ("Upgrade complete") still up quits.
    @MainActor
    @Test func theStoresRunDecides() async throws {
        let hold = Latch()
        var deps = Demo.dependencies(.arm64, pace: 0.01)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, _ in
            if args.first == "upgrade" { await hold.wait() }
            return 0
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let p = try #require(store.packages.first {
            $0.isManualUpgradeTarget && $0.kind == .formula && $0.caveats == nil
                && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        })
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        #expect(store.showUpgradeSheet)
        for reason in QuitEventReason.allCases {
            guard case .ask(let prompt, true) = QuitDecision.decide(.appleEvent(reason), step: store.quitStep, sheetOpen: true) else {
                Issue.record("expected the question for \(reason)")
                continue
            }
            #expect(prompt.name == p.name)
        }
        hold.release()
        #expect(await waitUntil { s.isFinished })
        #expect(store.showUpgradeSheet)
        for reason in QuitEventReason.allCases {
            #expect(QuitDecision.decide(.appleEvent(reason), step: store.quitStep, sheetOpen: true) == .closeSheetsAndQuit)
        }
    }
}
