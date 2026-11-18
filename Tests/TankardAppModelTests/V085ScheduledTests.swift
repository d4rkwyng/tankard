import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: scheduled checks and sleep (ScheduledChecks.swift). Fake clock,
// fake sleep/network state (ScheduleConditions driven directly), fake runner.

final class FakeClock85: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = Date()) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

private let offlineOutput = "fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve host: github.com\n"
private let lockedOutput = "Error: Another active Homebrew update process is already in progress.\nPlease wait for it to finish or terminate it to continue.\n"

@MainActor
struct ScheduleConditionsTests {
    @Test func gateFollowsSleepWakeAndNetwork() {
        let c = ScheduleConditions()
        let t = Date()
        #expect(c.gate(now: t) == .open)  // nothing reported: open
        c.willSleep()
        #expect(c.gate(now: t) == .asleep)
        #expect(c.sleepCount == 1)
        c.didWake(at: t)
        #expect(c.gate(now: t.addingTimeInterval(5)) == .settling(until: t.addingTimeInterval(ScheduleConditions.settleDelay)))
        #expect(c.retry(now: t.addingTimeInterval(5)) == ScheduleConditions.settleDelay - 5)
        #expect(c.gate(now: t.addingTimeInterval(ScheduleConditions.settleDelay + 1)) == .open)
        let later = t.addingTimeInterval(100)
        c.network(satisfied: false, at: later)
        #expect(c.gate(now: later) == .offline)
        #expect(c.retry(now: later) == ScheduleConditions.gatedRetry)
        c.network(satisfied: true, at: later)
        #expect(c.gate(now: later.addingTimeInterval(1)) == .settling(until: later.addingTimeInterval(ScheduleConditions.settleDelay)))
        // A path update that stays satisfied doesn't restart the settle delay.
        let much = later.addingTimeInterval(500)
        c.network(satisfied: true, at: much)
        #expect(c.gate(now: much) == .open)
    }

    @Test func quietReasonClassification() {
        #expect(ScheduledQuietReason.classify(slept: true, timedOut: false, failure: .network) == .slept)
        #expect(ScheduledQuietReason.classify(slept: false, timedOut: true, failure: nil) == .timedOut)
        #expect(ScheduledQuietReason.classify(slept: false, timedOut: false, failure: .network) == .offline)
        #expect(ScheduledQuietReason.classify(slept: false, timedOut: false, failure: .locked) == .busy)
        #expect(ScheduledQuietReason.classify(slept: false, timedOut: false, failure: .diskFull) == nil)
        #expect(ScheduledQuietReason.classify(slept: false, timedOut: false, failure: nil) == nil)
    }

    @Test func historyWithoutTheNewFieldsStillLoads() throws {
        // A 0.8.4 history.json: no quietReason / quietCount / quietSince.
        let old = #"[{"id":"6C1D1D0A-8B3B-4C1E-9E61-1D3E4E2C5A10","startedAt":"2026-11-17T19:18:00Z","duration":5632,"command":"brew update","arguments":["update"],"outcome":"failed","exitCode":1,"origin":"user","failure":"network","outputTail":["x"]}]"#
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        try Data(old.utf8).write(to: url)
        let log = HistoryLog(url: url)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].quietReason == nil)
        #expect(log.entries[0].isFailure)
    }

    @Test func markQuietMergesRepeatedScheduledFailures() {
        let log = HistoryLog(url: nil)
        let t = Date()
        let a = HistoryEntry(startedAt: t, duration: 5, command: "brew update", arguments: ["update"], outcome: .failed, failure: "network")
        log.record(a)
        #expect(log.markQuiet(a.id, reason: .offline))
        #expect(!log.entries[0].isFailure)
        #expect(!log.entries[0].canRetry)
        #expect(log.entries[0].resultText == ScheduledQuietReason.offline.text)
        let b = HistoryEntry(startedAt: t.addingTimeInterval(3600), duration: 0.2, command: "brew update", arguments: ["update"], outcome: .failed, failure: "locked")
        log.record(b)
        #expect(log.markQuiet(b.id, reason: .busy))
        #expect(log.entries.count == 1)  // one line for both
        let e = log.entries[0]
        #expect(e.id == a.id)
        #expect(e.quietReason == .busy)
        #expect(e.quietCount == 2)
        #expect(e.quietSince == t)
        #expect(e.startedAt == b.startedAt)
        #expect(e.resultText.contains("(2 times)"))
        // A successful update in between starts a new line.
        log.record(HistoryEntry(startedAt: t.addingTimeInterval(7200), duration: 3, command: "brew update", arguments: ["update"], outcome: .succeeded))
        let c = HistoryEntry(startedAt: t.addingTimeInterval(9000), duration: 3, command: "brew update", arguments: ["update"], outcome: .failed, failure: "network")
        log.record(c)
        log.markQuiet(c.id, reason: .offline)
        #expect(log.entries.count == 3)
        #expect(log.entries[0].quietCount == nil)
        #expect(!log.markQuiet(UUID(), reason: .offline))
    }
}

@MainActor
struct ScheduledUpdateTests {
    let base = ParallelLoadTests()

    func started(_ r: ParallelLoadTests.Rig) async {
        await r.store.start()
        await r.store.insights.waitForIdle()
    }

    @Test func offlineScheduledUpdateIsOneQuietHistoryLine() async throws {
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            out(Data(offlineOutput.utf8))
            return args.first == "update" ? 1 : 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await started(r)
        #expect(await r.store.runBackgroundUpdate() == false)
        #expect(r.store.lastScheduledUpdate?.quiet == .offline)
        #expect(r.store.error == nil)
        #expect(await waitUntil { r.store.history.entries.first?.quietReason == .offline })
        // Again (an hour on): still one line, now "2 times", never red.
        r.store.lastBackgroundUpdateFailure = nil
        #expect(await r.store.runBackgroundUpdate() == false)
        #expect(await waitUntil { r.store.history.entries.first?.quietCount == 2 })
        #expect(r.store.history.entries.filter { $0.category == .update }.count == 1)
        #expect(!r.store.history.entries.contains { $0.isFailure })
        #expect(r.store.history.filtered(.failed).isEmpty)
    }

    @Test func lockedScheduledUpdateRetriesSoonAndQuietly() async throws {
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            out(Data(lockedOutput.utf8))
            return args.first == "update" ? 1 : 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await started(r)
        #expect(await r.store.runBackgroundUpdate() == false)
        #expect(r.store.lastScheduledUpdate?.quiet == .busy)
        #expect(r.store.backgroundFailureRetry == ScheduledQuietReason.busy.retryAfter)
        let failedAt = try #require(r.store.lastBackgroundUpdateFailure)
        let launched = failedAt.addingTimeInterval(-86400)
        // Not before 10 minutes; then due.
        if case .notDue(let next) = r.store.backgroundUpdateDecision(launchedAt: launched, now: failedAt.addingTimeInterval(60)) {
            #expect(next.timeIntervalSince(failedAt) <= 10 * 60 + 1)
        } else { Issue.record("expected notDue") }
        #expect(await waitUntil { r.store.history.entries.first?.quietReason == .busy })
    }

    @Test func aHungScheduledUpdateIsStoppedAtTheTimeLimit() async throws {
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            if args.first == "update" {
                try await Task.sleep(for: .seconds(60))  // a hung brew update; cancelled by the limit
            }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await started(r)
        // Rig's deps are fixed; a store of its own with a short limit.
        var deps = r.store.deps
        deps.scheduledUpdateTimeout = 0.3
        let store = AppStore(deps: deps, settings: r.settings)
        await store.start()
        await store.insights.waitForIdle()
        let begin = ContinuousClock.now
        #expect(await store.runBackgroundUpdate() == false)
        #expect(ContinuousClock.now - begin < .seconds(20))
        #expect(store.lastScheduledUpdate?.quiet == .timedOut)
        #expect(store.error == nil)
        #expect(await waitUntil { store.history.entries.first?.quietReason == .timedOut })
        #expect(store.history.entries.first?.outcome == .cancelled)
    }

    @Test func sleepingMidRunStopsItAndIsNotAFailure() async throws {
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            if args.first == "update" { try await Task.sleep(for: .seconds(60)) }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await started(r)
        let run = Task { await r.store.runBackgroundUpdate() }
        #expect(await waitUntil { r.stream.count("update") == 1 && r.store.queue.runningID != nil })
        r.store.system.willSleep()
        #expect(await run.value == false)
        #expect(r.store.lastScheduledUpdate?.quiet == .slept)
        #expect(r.store.backgroundFailureRetry == 0)
        #expect(r.store.error == nil)
        #expect(await waitUntil { r.store.history.entries.first?.quietReason == .slept })
        // Asleep: the next one waits for the wake (BackgroundChecker's gate).
        #expect(r.store.system.gate(now: Date()) == .asleep)
    }

    @Test func aUserRefreshFailureIsStillReportedInFull() async throws {
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            out(Data(offlineOutput.utf8))
            return args.first == "update" ? 1 : 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await started(r)
        await r.store.refresh(manual: true)
        #expect(r.store.error?.title == BrewFailureKind.network.title)
        #expect(await waitUntil { r.store.history.entries.first?.category == .update })
        #expect(r.store.history.entries.first?.isFailure == true)
        #expect(r.store.history.entries.first?.quietReason == nil)
    }
}

@MainActor
struct ScheduledTickTests {
    let base = ParallelLoadTests()

    @Test func nothingStartsAsleepOrOfflineThenOneCatchUpAfterTheSettleDelay() async throws {
        let clock = FakeClock85()
        let r = try await base.rig(backgroundUpdates: true, now: { clock.now })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: nil,
                                        launchedAt: clock.now.addingTimeInterval(-86400), now: { clock.now })
        r.store.system.willSleep()
        #expect(await checker.tick() == ScheduleConditions.gatedRetry)
        #expect(r.stream.count("update") == 0)
        clock.advance(8 * 3600)  // the night
        r.store.system.didWake(at: clock.now)
        r.store.system.network(satisfied: false, at: clock.now)
        #expect(await checker.tick() == ScheduleConditions.gatedRetry)  // offline
        r.store.system.network(satisfied: true, at: clock.now)
        let wait = await checker.tick()  // settling
        #expect(wait > 0 && wait <= ScheduleConditions.settleDelay)
        #expect(r.stream.count("update") == 0)
        clock.advance(ScheduleConditions.settleDelay + 1)
        await checker.tick()
        #expect(r.stream.count("update") == 1)  // the one catch-up
        await checker.tick()
        #expect(r.stream.count("update") == 1)  // not again
    }

    @Test func aFailedBackgroundUpdateIsntFollowedByASecondOne() async throws {
        // Derek's History: a lock failure 0.2 s after each network failure.
        let clock = FakeClock85()
        let r = try await base.rig(backgroundUpdates: true, now: { clock.now }, stream: { args, out in
            out(Data(offlineOutput.utf8))
            return args.first == "update" ? 1 : 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        r.settings.notifyNewUpgrades = true
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: nil,
                                        launchedAt: clock.now.addingTimeInterval(-86400), now: { clock.now })
        let wait = await checker.tick()
        #expect(r.stream.count("update") == 1)
        #expect(wait > 60)  // backs off to the retry, not the busy recheck
    }
}

@MainActor
struct ScheduledAutoUpdateTests {
    let base = ParallelLoadTests()

    @Test func anOfflineBrewUpdateLeavesTheSlotOpenAndWaits() async throws {
        let r = try await base.rig(stream: { args, out in
            out(Data(offlineOutput.utf8))
            return args.first == "update" ? 1 : 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        r.store.autoUpdate.settings.enabled = true
        let run = try #require(await r.store.autoUpdate.run(store: r.store, notifier: nil))
        #expect(run.note == ScheduledQuietReason.offline.text)
        #expect(run.failed.isEmpty)
        #expect(r.store.autoUpdate.settings.lastRun == nil)  // the slot runs again later
        #expect(r.store.error == nil)
        #expect(r.stream.count("upgrade") == 0)
        let retry = try #require(r.store.autoUpdate.retryNotBefore)
        #expect(retry.timeIntervalSinceNow >= AutoUpdater.quietRetry - 5)
        if case .waiting = r.store.autoUpdate.decide(store: r.store, launchedAt: .distantPast, now: Date()) {} else {
            Issue.record("expected the slot to wait")
        }
    }
}

// HK-47 review (0.8.5), item 3: a step the Mac slept through is "interrupted
// by sleep", even when its time limit fired too (on the wake), never "took
// too long".
@MainActor
struct ScheduledStepSleepTests {
    let base = ParallelLoadTests()

    @Test func aStepTheMacSleptThroughIsSleepNotTooLong() async throws {
        let r = try await base.rig(stream: { args, out in
            if args.first == "upgrade" { try await Task.sleep(for: .seconds(60)) }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        r.store.autoUpdate.settings.enabled = true
        r.store.autoUpdate.stepTimeoutOverride = 0.5
        let run = Task { await r.store.autoUpdate.run(store: r.store, notifier: nil) }
        #expect(await waitUntil { r.stream.count("upgrade") == 1 })
        r.store.system.willSleep()
        r.store.system.didWake(at: Date())
        // The limit fires (as it would right after the wake), stopping brew.
        let record = try #require(await run.value)
        let qualified = try #require(r.stream.calls.first { $0.first == "upgrade" }?.last)
        let name = String(qualified.split(separator: "/").last ?? "")
        let first = try #require(record.skipped.first { $0.name == name })
        #expect(first.detail == AutoUpdateSkip.slept.text)
    }
}
// END ITEM 3

// HK-47 review (0.8.5), item 5: a scheduled refresh that can't even find
// brew doesn't leave the last scheduled check's quiet result behind (auto-
// update read it and postponed itself again and again).
@MainActor
struct ScheduledRefreshResultTests {
    @Test func aScheduledRefreshWithoutBrewForgetsTheLastResult() async throws {
        let deps = AppStore.Dependencies(makeClient: { throw BrewClientError.brewNotFound(searched: ["/opt/homebrew/bin/brew"]) },
                                         streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 },
                                         cache: nil, logURL: nil)
        let store = AppStore(deps: deps, settings: testSettings())
        store.lastScheduledUpdate = ScheduledUpdateResult(quiet: .offline)
        await store.refresh(.scheduled)
        #expect(store.lastScheduledUpdate == nil)
        #expect(store.error?.title == "Homebrew not found")
    }
}
// END ITEM 5

// HK-47 review (0.8.5), item 6: a willSleep whose didWake never came
// doesn't hold scheduled checks off for good.
@MainActor
struct ScheduleConditionsMissedWakeTests {
    @Test func aMissedWakeExpires() {
        let c = ScheduleConditions()
        c.willSleep()
        let t = Date()
        #expect(c.gate(now: t.addingTimeInterval(60)) == .asleep)
        #expect(c.gate(now: t.addingTimeInterval(11 * 60)) == .open)
        // A real wake later still settles as before.
        c.didWake(at: t.addingTimeInterval(12 * 60))
        #expect(c.gate(now: t.addingTimeInterval(12 * 60 + 5)) == .settling(until: t.addingTimeInterval(12 * 60 + ScheduleConditions.settleDelay)))
    }
}
// END ITEM 6
