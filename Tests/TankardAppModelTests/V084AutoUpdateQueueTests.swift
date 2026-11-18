import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4: automatic updates get what the sheet's runs got in 0.8.3: the wait
// for brew's lock, and the quit guard. Fakes only (the demo's brew plus a
// runner that fails on the lock or blocks a step).

@MainActor
struct V084AutoUpdateQueueTests {
    nonisolated static let lockedLine = "Error: A `brew upgrade` process has already locked /usr/local/Cellar/xz.\n"

    /// The demo's four safe upgrades (openssl@4, python@3.15, sqlite, xz;
    /// ruby pinned). `behaviour` sees each `brew upgrade`'s package (its
    /// short name) first; nil: the demo runs it.
    func rig(logURL: URL? = nil, lockWait: BrewLockWait? = nil,
             behaviour: @escaping @Sendable (String, @escaping @Sendable (Data) -> Void) async throws -> Int32? = { _, _ in nil })
        async -> (AppStore, CallLog, FakeNotifier) {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.logURL = logURL
        deps.lockWait = lockWait
        let calls = CallLog()
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: calls) { args, out in
            if args.first == "upgrade", let last = args.last {
                let name = last.split(separator: "/").last.map(String.init) ?? last
                if let code = try await behaviour(name, out) { return code }
            }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.calendar = utc
        store.autoUpdate.settings.enabled = true
        return (store, calls, FakeNotifier())
    }

    func fakeWait(held: LockSwitch, limit: Duration = .seconds(5)) -> BrewLockWait {
        BrewLockWait(interval: .milliseconds(10), limit: limit, maxAttempts: 5, holders: { _ in
            held.value ? ["4312 /bin/bash /usr/local/Homebrew/Library/Homebrew/brew.sh upgrade"] : []
        })
    }

    func upgrades(_ calls: CallLog, _ name: String) -> Int {
        calls.calls.filter { $0.first == "upgrade" && ($0.last ?? "").hasSuffix("/" + name) }.count
    }

    // MARK: the lock

    @Test func waitsForTheLockThenUpgrades() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = LockSwitch(true)
        let (store, calls, notifier) = await rig(logURL: dir.appendingPathComponent("upgrade.log"), lockWait: fakeWait(held: held)) { name, out in
            guard name == "xz", held.value else { return nil }
            out(Data(Self.lockedLine.utf8))
            return 1
        }
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: notifier) }
        #expect(await waitUntil { u.activity == "Waiting for another Homebrew command to finish…" })
        #expect(u.step == AutoUpdateStep(name: "xz", index: 4, total: 4))
        try await Task.sleep(for: .milliseconds(50))
        #expect(upgrades(calls, "xz") == 1, "waits while the lock is held, no retry yet")
        held.value = false
        let run = try #require(await task.value)
        #expect(upgrades(calls, "xz") == 2)
        #expect(run.upgraded.map(\.name) == ["openssl@4", "python@3.15", "sqlite", "xz"])
        #expect(run.upgraded.first { $0.name == "xz" }?.detail == "5.8.3 → 5.8.4 · waited for another Homebrew command")
        #expect(run.failed.isEmpty)
        // Quietly: the same notification as any run.
        #expect(notifier.posted.map(\.title) == ["Tankard upgraded 4 packages"])
        let text = try String(contentsOf: dir.appendingPathComponent("upgrade.log"), encoding: .utf8)
        #expect(text.contains("has already locked /usr/local/Cellar/xz"))
        #expect(text.contains("tankard: another Homebrew command holds brew's lock (pid 4312 "))
        #expect(text.contains("tankard: brew's lock is free: running it again"))
        #expect(!text.contains("brew exited with status"))
    }

    @Test func lockWaitThatRunsOutIsSkippedNotFailed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, calls, notifier) = await rig(logURL: dir.appendingPathComponent("upgrade.log"),
                                                 lockWait: fakeWait(held: LockSwitch(true), limit: .milliseconds(100))) { name, out in
            guard name == "sqlite" || name == "xz" else { return nil }
            out(Data(Self.lockedLine.utf8))
            return 1
        }
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(run.upgraded.map(\.name) == ["openssl@4", "python@3.15"])
        #expect(run.failed.isEmpty)
        #expect(run.skipped.first { $0.name == "sqlite" }?.detail == "Homebrew was busy")
        #expect(run.skipped.first { $0.name == "xz" }?.detail == "Homebrew was busy")
        // One bounded wait per run: after sqlite's ran out, xz didn't wait again.
        #expect(upgrades(calls, "sqlite") == 1 && upgrades(calls, "xz") == 1)
        #expect(run.summary == "2 upgraded · 3 skipped")
        #expect(notifier.posted.first?.body.contains("Failed") == false)
        let text = try String(contentsOf: dir.appendingPathComponent("upgrade.log"), encoding: .utf8)
        #expect(text.contains("tankard: skipped sqlite: Homebrew was busy"))
        #expect(text.contains("tankard: skipped xz: Homebrew was busy"))
    }

    @Test func lockedWithoutLockWaitIsSkippedToo() async throws {
        // Demo mode and tests have no lock wait: a lock failure is still
        // "Homebrew was busy", not a failure.
        let (store, _, notifier) = await rig { name, out in
            guard name == "xz" else { return nil }
            out(Data(Self.lockedLine.utf8))
            return 1
        }
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(run.failed.isEmpty)
        #expect(run.skipped.first { $0.name == "xz" }?.detail == "Homebrew was busy")
    }

    // MARK: the quit guard

    @Test func quitNowMidAutomaticRun() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, calls, notifier) = await rig(logURL: dir.appendingPathComponent("upgrade.log")) { name, out in
            guard name == "python@3.15" else { return nil }
            out(Data("==> Pouring python@3.15\n".utf8))
            try await sleepUntilCancelled()
            return 0
        }
        let u = store.autoUpdate
        let before = Date(timeIntervalSince1970: 1_000_000)
        u.settings.lastRun = before
        #expect(store.quitPrompt == nil)
        let task = Task { await u.run(store: store, notifier: notifier) }
        #expect(await waitUntil { u.step?.name == "python@3.15" })
        let p = try #require(store.quitPrompt)
        #expect(p.isAutomatic)
        #expect(p.message == "Tankard is upgrading python@3.15 automatically (2 of 4).")
        #expect(p.detail == "Quitting now stops it: Homebrew undoes the unfinished step. The next automatic run upgrades what's left.")
        var quit = false
        store.prepareToQuit(.now) { quit = true }
        #expect(store.quitPrompt == nil, "asked once")
        let run = try #require(await task.value)
        #expect(await waitUntil { quit })
        #expect(run.upgraded.map(\.name) == ["openssl@4"])
        #expect(run.failed.isEmpty, "stopped, not failed")
        #expect(run.skipped.filter { $0.detail == "Tankard quit; the next automatic run upgrades it" }.map(\.name)
                == ["python@3.15", "sqlite", "xz"])
        #expect(run.note == "Tankard quit during the run")
        #expect(upgrades(calls, "sqlite") == 0 && upgrades(calls, "xz") == 0)
        // Recorded in the auto-update log; the slot opens again for the next
        // launch's scheduler; no notification while quitting.
        #expect(u.log.latest == run)
        #expect(u.settings.lastRun == before)
        #expect(notifier.posted.isEmpty)
        // No manual journal, so no "Upgrade the Remaining N" sheet next launch.
        #expect(store.settings.defaults.data(forKey: RunJournal.key) == nil)
        #expect(!store.offerInterruptedRun())
        #expect(store.interruptedRun == nil && !store.showUpgradeSheet)
        let text = try String(contentsOf: dir.appendingPathComponent("upgrade.log"), encoding: .utf8)
        #expect(text.contains("tankard: stopped python@3.15: Tankard is quitting"))
    }

    @Test func stopAfterCurrentLetsTheStepFinish() async throws {
        let gate = Latch()
        let (store, calls, notifier) = await rig { name, _ in
            guard name == "python@3.15" else { return nil }
            await gate.wait()
            return nil
        }
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: notifier) }
        #expect(await waitUntil { u.step?.name == "python@3.15" })
        var quit = false
        store.prepareToQuit(.afterCurrent) { quit = true }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!quit, "waits for the running step")
        gate.release()
        let run = try #require(await task.value)
        #expect(await waitUntil { quit })
        #expect(run.upgraded.map(\.name) == ["openssl@4", "python@3.15"])
        #expect(run.skipped.filter { $0.detail == "Tankard quit; the next automatic run upgrades it" }.map(\.name) == ["sqlite", "xz"])
        #expect(upgrades(calls, "sqlite") == 0)
        #expect(u.settings.lastRun == nil, "the slot runs again")
    }

    @Test func noPromptOutsideTheUpgradeSteps() async throws {
        // brew update and the downloads aren't steps that change a package.
        let gate = Latch()
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "fetch" { await gate.wait() }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.settings.enabled = true
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: nil) }
        #expect(await waitUntil { u.activity?.hasPrefix("Auto-update: downloading") == true })
        #expect(u.isRunning && store.quitPrompt == nil)
        gate.release()
        _ = await task.value
        #expect(store.quitPrompt == nil)
    }
}

@MainActor
struct V084AutoUpdateQuitLastStepTests {
    @Test func stopAfterTheLastStepKeepsTheSlotRun() async throws {
        let gate = Latch()
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let demo = deps.streamRunner
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "upgrade", args.last?.hasSuffix("/xz") == true { await gate.wait() }
            return try await demo.stream("/usr/local/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.settings.enabled = true
        let u = store.autoUpdate
        let task = Task { await u.run(store: store, notifier: nil) }
        #expect(await waitUntil { u.step?.name == "xz" })
        #expect(store.quitPrompt?.message == "Tankard is upgrading xz automatically (4 of 4).")
        store.prepareToQuit(.afterCurrent) {}
        gate.release()
        let run = try #require(await task.value)
        #expect(run.upgraded.count == 4 && run.note == nil)
        #expect(u.settings.lastRun == run.startedAt, "nothing left: the slot counts as run")
    }
}
