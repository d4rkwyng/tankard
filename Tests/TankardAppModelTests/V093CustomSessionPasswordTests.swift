import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.3 (hardening of 0ae1a37): startCustomSession (a restore's sheet)
// hands the session its password cancel count in init too, before its
// steps are enqueued. The V089 test covers startSession; this is the same
// forced gap for the custom path.

/// Serialized: the held main actor would starve other tests' waits.
@MainActor
@Suite(.serialized)
struct V093CustomSessionPasswordTests {
    static let helper = AdminPasswordTests.helper
    static let args = ["reinstall", "--cask", "homebrew/cask/google-chrome"]

    func store(cancels: OSAllocatedUnfairLock<Int>, runner: FakeStreamRunner) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = Self.helper
        deps.streamRunner = runner
        deps.askpassFocus = AskpassFocus(find: { nil }, yield: { _ in }, cancelCount: { cancels.withLock { $0 } })
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        return store
    }

    /// A restore's cask step, with the password dialog's environment.
    func startRestoreStep(_ store: AppStore) {
        let display = BrewCommands.display(Self.args)
        let row = Package.command(display)
        store.startCustomSession(.restore, packages: [row], intelbrewMode: false,
                                 makeCommand: { _ in
                                     QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: Self.args,
                                                   environment: AdminPassword.environment(helper: Self.helper, arguments: Self.args,
                                                                                          display: display),
                                                   display: display)
                                 },
                                 chainKey: nil)
    }

    /// The store's `upgrade` assignment (the session's init done, its step
    /// enqueued) holds the main actor until brew has exited: the step's
    /// `.started` was sent before the store returned. The Cancel during it
    /// is still recorded.
    @Test func aRestoreStepTheQueueStartsBeforeTheStoreReturnsStillHasItsCount() async throws {
        let cancels = OSAllocatedUnfairLock(initialState: 2)
        let brewExited = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "reinstall" else { return 0 }
            out(Data("==> Removing launchctl service com.google.keystone.agent\n".utf8))
            cancels.withLock { $0 += 1 }
            brewExited.withLock { $0 = true }
            return 0
        }
        let store = await store(cancels: cancels, runner: runner)
        let held = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = store.upgrade } onChange: {
            let deadline = Date().addingTimeInterval(10)
            while !brewExited.withLock({ $0 }), Date() < deadline { usleep(2_000) }
            held.withLock { $0 = true }
        }
        startRestoreStep(store)
        #expect(held.withLock { $0 } && brewExited.withLock { $0 }, "brew ran while the store was still setting up the session")
        let session = try #require(store.upgrade)
        #expect(session.action == .restore)
        await #expect(waitUntil { session.isFinished })
        let item = try #require(session.items.first)
        #expect(item.state == .done)
        #expect(session.sudoSkipped[item.id] == ["com.google.keystone.agent"])
        #expect(session.log.lines.contains {
            $0.contains("The password dialog was cancelled, so brew couldn't remove the background service com.google.keystone.agent")
        })
    }

    /// No Cancel during the step: a plain ✓, no note.
    @Test func aRestoreStepWithNoCancelIsAPlainTick() async throws {
        let cancels = OSAllocatedUnfairLock(initialState: 2)
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "reinstall" else { return 0 }
            out(Data("==> Removing launchctl service com.google.keystone.agent\n".utf8))
            return 0
        }
        let store = await store(cancels: cancels, runner: runner)
        startRestoreStep(store)
        let session = try #require(store.upgrade)
        await #expect(waitUntil { session.isFinished })
        let item = try #require(session.items.first)
        #expect(item.state == .done)
        #expect(session.sudoSkipped.isEmpty)
        #expect(!session.log.lines.contains { $0.contains("The password dialog was cancelled") })
    }
}
