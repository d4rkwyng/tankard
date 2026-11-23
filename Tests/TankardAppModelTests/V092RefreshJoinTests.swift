import Foundation
import os
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.9.2 (bug hunt): `refresh` set `refreshTask = nil` unconditionally,
/// and every non-automatic caller that had waited for a running read
/// started its own once that one ended. Two such callers (a background
/// update's `.afterUpdate`, a scheduled check) waiting on the same read
/// both started one, the two `brew info` reads ran at once, the first to
/// end set `isRefreshing` false and cleared `refreshTask` while the
/// other still ran, so a later automatic refresh started a third instead
/// of joining it.
@MainActor
struct V092RefreshJoinTests {
    /// Status reads (`brew info --installed`) wait, one gate per read, once
    /// `gating` is on; counts how many run at once.
    final class GatedInfo: CommandRunning, @unchecked Sendable {
        let inner: FakeInfoRunner
        private let lock = NSLock()
        private var _gating = false
        private var gates: [Latch] = []
        private var inFlight = 0
        private var _maxInFlight = 0

        init(_ inner: FakeInfoRunner) { self.inner = inner }

        var gating: Bool {
            get { lock.withLock { _gating } }
            set { lock.withLock { _gating = newValue } }
        }
        var started: Int { lock.withLock { gates.count } }
        var running: Int { lock.withLock { inFlight } }
        var maxInFlight: Int { lock.withLock { _maxInFlight } }
        func release(_ i: Int) { lock.withLock { gates[i] }.release() }

        func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
            let isStatusRead = executable.hasSuffix("brew") && arguments.first == "info" && arguments.contains("--installed")
            let gate: Latch? = lock.withLock {
                guard _gating, isStatusRead else { return nil }
                let g = Latch()
                gates.append(g)
                inFlight += 1
                _maxInFlight = max(_maxInFlight, inFlight)
                return g
            }
            if let gate {
                await gate.wait()
                lock.withLock { inFlight -= 1 }
            }
            return try await inner.run(executable, arguments, environment: environment)
        }
    }

    @Test(.timeLimit(.minutes(1))) func twoCallersWaitingOnOneReadDoNotRunTheirsAtOnce() async throws {
        let log = CallLog()
        let runner = GatedInfo(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let client = makeClient(runner)
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client },
                                                         streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                                         cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        #expect(await waitUntil { !store.isRefreshing })
        runner.gating = true

        // Read A runs; B and C (both re-read after it, whatever it read)
        // wait for it.
        let done = Box(0)
        Task { await store.refresh(.automatic); done.value += 1 }
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 1 })
        Task { await store.refresh(.afterUpdate); done.value += 1 }
        Task { await store.refresh(.afterUpdate); done.value += 1 }
        try await Task.sleep(for: .milliseconds(50)) // B and C reach their wait (A can't end yet)
        runner.release(0)
        #expect(await waitUntil(timeout: .seconds(10)) { done.value == 1 })
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started >= 2 })
        // One of B and C reads; the other waits for it rather than reading too.
        try await Task.sleep(for: .milliseconds(100))
        try #require(runner.started == 2, "B and C read at the same time")
        #expect(store.isRefreshing && store.refreshTask != nil)
        // A refresh asked for now joins the read that is running.
        Task { await store.refresh(.automatic); done.value += 1 }
        runner.release(1)
        try #require(await waitUntil(timeout: .seconds(10)) { runner.started == 3 })
        #expect(store.isRefreshing)
        runner.release(2)
        #expect(await waitUntil(timeout: .seconds(10)) { done.value == 4 })
        #expect(runner.started == 3)
        #expect(runner.maxInFlight == 1)
        #expect(!store.isRefreshing && store.refreshTask == nil)
    }
}
