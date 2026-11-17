import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3 (queue robustness): Stop Now for single runs, waiting for brew's
// lock, the quit guard's interrupted-run offer, and Retry in the sheet.
// Fakes only; the real-brew checks are in V083QueueRobustRealTests.

@MainActor
struct V083StopTests {
    /// A store whose `brew <verb>` streams one line, then runs until cancelled.
    func store(blocking verb: String, log: CallLog = CallLog()) -> AppStore {
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: { args, out in
            if args.first == verb {
                out(Data("==> Pouring something\n".utf8))
                try await sleepUntilCancelled()
            }
            return 0
        })
        return AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
    }

    @Test func confirmationOnlyWhileBrewChangesAPackage() {
        let f = UpgradeSession.stopNeedsConfirmation
        #expect(f(.install, true, false, false))
        #expect(f(.upgrade, true, false, false))
        #expect(f(.restore, true, false, false))
        #expect(!f(.install, true, true, false), "downloading: safe")
        #expect(!f(.install, true, false, true), "waiting for the lock: nothing runs")
        #expect(!f(.install, false, false, false), "nothing running")
        #expect(!f(.uninstall, true, false, false), "brew defers interrupts while it removes a keg")
        #expect(!f(.cleanup, true, false, false))
    }

    @Test func singleInstallStopsNowAfterConfirming() async throws {
        let log = CallLog()
        let store = store(blocking: "upgrade", log: log)
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        let reads = log.calls.count
        store.startUpgrade([xz])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        #expect(s.total == 1)
        // Pouring (no download seen): asks first, stops nothing yet.
        s.requestStopNow()
        #expect(s.confirmingStop)
        #expect(!s.stopRequested)
        #expect(s.items[0].state == .running)
        s.stopNow()
        #expect(s.statusLine.contains("Stopping xz"))
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .cancelled)
        #expect(s.title == "Upgrade stopped")
        // History: one entry, stopped; then the list is read again.
        #expect(await waitUntil { store.history.entries.contains { $0.arguments.first == "upgrade" } })
        #expect(store.history.entries.first { $0.arguments.first == "upgrade" }?.outcome == .cancelled)
        #expect(await waitUntil { log.calls.count > reads + 1 })
    }

    @Test func stopNowWithoutRunningStepNeedsNoConfirmation() async throws {
        let store = store(blocking: "uninstall")
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.startSession(.uninstall, packages: [xz])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        s.requestStopNow()
        #expect(!s.confirmingStop)
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .cancelled)
    }
}

/// Flips when told; read from the queue's thread.
final class LockSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@MainActor
struct V083LockWaitTests {
    nonisolated static let lockedLine = "Error: A `brew install ffmpeg` process has already locked /opt/homebrew/Cellar/xz.\n"

    @Test func lockFileFromBrewsMessages() {
        let p = "/opt/homebrew"
        #expect(BrewLock.prefix(ofBrew: "/opt/homebrew/bin/brew") == p)
        #expect(BrewLock.prefix(ofBrew: "/usr/local/bin/brew") == "/usr/local")
        #expect(BrewLock.lockFile(["Error: A `brew install ffmpeg` process has already locked /opt/homebrew/Cellar/x265.",
                                   "Please wait for it to finish or terminate it to continue."], prefix: p)
                == "/opt/homebrew/var/homebrew/locks/x265.formula.lock")
        #expect(BrewLock.lockFile(["Error: A `brew install --cask firefox` process has already locked /opt/homebrew/Caskroom/firefox."], prefix: p)
                == "/opt/homebrew/var/homebrew/locks/firefox.cask.lock")
        #expect(BrewLock.lockFile(["Error: A `brew fetch` process has already locked /Users/me/Library/Caches/Homebrew/downloads/abc--x.tar.gz.",
                                   "Gave up after waiting 180 seconds. Terminate it to continue."], prefix: p)
                == "/opt/homebrew/var/homebrew/locks/abc--x.tar.gz.download.lock")
        #expect(BrewLock.lockFile(["Error: Another `brew update` process is already running.",
                                   "Please wait for it to finish or terminate it to continue."], prefix: p)
                == "/opt/homebrew/var/homebrew/locks/update")
        #expect(BrewLock.lockFile(["Error: something else"], prefix: p) == nil)
        // The same text classifies as the lock.
        #expect(BrewFailure.classify([Self.lockedLine]) == .locked)
    }

    func fakeWait(held: LockSwitch, files: CallLog? = nil, limit: Duration = .seconds(5)) -> BrewLockWait {
        BrewLockWait(interval: .milliseconds(10), limit: limit, maxAttempts: 5, holders: { file in
            files?.add([file])
            return held.value ? ["4312 /bin/bash /opt/homebrew/Library/Homebrew/brew.sh install ffmpeg"] : []
        })
    }

    @Test func queueWaitsAndRunsAgain() async throws {
        let calls = CallLog()
        let held = LockSwitch(true)
        let runner = FakeStreamRunner(log: calls, behaviour: { args, out in
            if calls.count("upgrade") == 1 {
                out(Data(Self.lockedLine.utf8))
                return 1
            }
            out(Data("upgraded\n".utf8))
            return 0
        })
        let files = CallLog()
        let queue = CommandQueue(runner: runner)
        let events = CommandQueueTests.Events()
        queue.enqueue(QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "xz"], environment: [:], display: "brew upgrade xz"),
                      lockWait: fakeWait(held: held, files: files)) { events.add("u", $0) }
        try await waitFor { events.all.contains { $0.1 == .lockWait("4312 /bin/bash /opt/homebrew/Library/Homebrew/brew.sh install ffmpeg") } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.count("upgrade") == 1, "still waiting while the lock is held")
        #expect(files.calls.first == ["/opt/homebrew/var/homebrew/locks/xz.formula.lock"])
        held.value = false
        try await waitFor { events.all.contains { if case .finished = $0.1 { true } else { false } } }
        #expect(events.terminal("u") == .finished(exitCode: 0))
        #expect(calls.count("upgrade") == 2)
        #expect(events.all.contains { $0.1 == .lockWait(nil) })
    }

    @Test func otherFailuresDontWait() async throws {
        let calls = CallLog()
        let runner = FakeStreamRunner(log: calls, behaviour: { _, out in
            out(Data("curl: (6) Could not resolve host: ghcr.io\n".utf8))
            return 1
        })
        let queue = CommandQueue(runner: runner)
        let events = CommandQueueTests.Events()
        queue.enqueue(QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "xz"], environment: [:], display: "x"),
                      lockWait: fakeWait(held: LockSwitch(true))) { events.add("u", $0) }
        try await waitFor { events.terminal("u") != nil }
        #expect(events.terminal("u") == .finished(exitCode: 1))
        #expect(calls.count("upgrade") == 1)
    }

    @Test func givesUpAfterTheLimit() async throws {
        let calls = CallLog()
        let runner = FakeStreamRunner(log: calls, behaviour: { _, out in
            out(Data(Self.lockedLine.utf8))
            return 1
        })
        let queue = CommandQueue(runner: runner)
        let events = CommandQueueTests.Events()
        queue.enqueue(QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "xz"], environment: [:], display: "x"),
                      lockWait: fakeWait(held: LockSwitch(true), limit: .milliseconds(100))) { events.add("u", $0) }
        try await waitFor { events.all.contains { if case .finished = $0.1 { true } else { false } } }
        #expect(events.terminal("u") == .finished(exitCode: 1))
        #expect(calls.count("upgrade") == 1)
    }

    func store(held: LockSwitch, calls: CallLog) -> AppStore {
        let client = makeClient(FakeInfoRunner(log: calls, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: calls, behaviour: { args, out in
            guard args.first == "upgrade" else { return 0 }
            if held.value {
                out(Data(Self.lockedLine.utf8))
                return 1
            }
            return 0
        })
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil)
        deps.lockWait = fakeWait(held: held)
        return AppStore(deps: deps)
    }

    @Test func sheetSaysItWaitsThenUpgrades() async throws {
        let calls = CallLog()
        let held = LockSwitch(true)
        let store = store(held: held, calls: calls)
        await store.start()
        let pkgs = Array(store.upgradable.prefix(2))
        #expect(pkgs.count == 2)
        store.startUpgrade(pkgs)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.lockWait != nil })
        #expect(s.statusLine == "Waiting for another Homebrew command to finish…")
        #expect(!s.stopNowNeedsConfirmation, "nothing runs while it waits")
        #expect(s.items[0].state == .running && s.items[1].state == .waiting)
        held.value = false
        #expect(await waitUntil { s.isFinished })
        #expect(s.items.allSatisfy { $0.state == .done })
        #expect(s.failureKinds.isEmpty)
        #expect(s.log.lines.contains { $0.contains("running it again") })
        // History: one entry per step, both succeeded; the lock attempt's output isn't kept.
        #expect(await waitUntil { store.history.entries.filter { $0.arguments.first == "upgrade" }.count == 2 })
        #expect(store.history.entries.filter { $0.arguments.first == "upgrade" }.allSatisfy { $0.outcome == .succeeded })
    }

    @Test func stopNowWhileWaiting() async throws {
        let calls = CallLog()
        let store = store(held: LockSwitch(true), calls: calls)
        await store.start()
        let pkgs = Array(store.upgradable.prefix(2))
        store.startUpgrade(pkgs)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.lockWait != nil })
        s.requestStopNow()
        #expect(await waitUntil { s.isFinished })
        #expect(s.items.allSatisfy { $0.state == .cancelled })
        #expect(s.lockWait == nil)
    }
}

@MainActor
struct V083QuitGuardTests {
    /// `brew upgrade` waits for `gate` (the second and later run until cancelled when `block`).
    func store(settings: AppSettings, gate: Latch?, untilCancelled: Bool = false, calls: CallLog = CallLog()) -> AppStore {
        let client = makeClient(FakeInfoRunner(log: calls, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: calls, behaviour: { args, _ in
            guard args.first == "upgrade" else { return 0 }
            if untilCancelled { try await sleepUntilCancelled() }
            if let gate { await gate.wait() }
            return 0
        })
        return AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                        settings: settings)
    }

    @Test func promptOnlyWhileARunIsGoing() async throws {
        let settings = AppSettings.ephemeral("net.mindtricks.tankard.test.quit1")
        let gate = Latch()
        let store = store(settings: settings, gate: gate)
        await store.start()
        #expect(store.quitPrompt == nil)
        let pkgs = Array(store.upgradable.filter(\.isManualUpgradeTarget).prefix(3))
        #expect(pkgs.count == 3)
        store.startUpgrade(pkgs)
        #expect(await waitUntil { store.upgrade?.current != nil })
        let p = try #require(store.quitPrompt)
        #expect(p.message == "Homebrew is still upgrading \(pkgs[0].name) (1 of 3).")
        gate.release()
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(store.quitPrompt == nil)
        // A run that ended in Tankard leaves no journal.
        #expect(settings.defaults.data(forKey: RunJournal.key) == nil)
    }

    @Test func quitNowKeepsTheRestForNextLaunch() async throws {
        let name = "net.mindtricks.tankard.test.quit2"
        let settings = AppSettings.ephemeral(name)
        let store = store(settings: settings, gate: nil, untilCancelled: true)
        await store.start()
        let pkgs = Array(store.upgradable.filter(\.isManualUpgradeTarget).prefix(3))
        store.startUpgrade(pkgs)
        #expect(await waitUntil { store.upgrade?.current != nil })
        #expect(settings.defaults.data(forKey: RunJournal.key) != nil, "saved when the run starts")
        let quit = Box(false)
        store.prepareToQuit(.now) { quit.value = true }
        #expect(await waitUntil { quit.value })
        #expect(store.upgrade?.items.allSatisfy { $0.state == .cancelled } == true)
        let j = try #require(settings.defaults.data(forKey: RunJournal.key).flatMap(RunJournal.decode))
        #expect(j.targets == pkgs.map(\.fullName))
        // The next launch (same settings): offered, through the Upgrade path.
        let next = self.store(settings: AppSettings(defaults: settings.defaults), gate: nil)
        await next.start()
        #expect(await waitUntil { next.interruptedRun != nil })
        #expect(next.interruptedRun?.packages.map(\.fullName) == pkgs.map(\.fullName))
        #expect(next.showUpgradeSheet)
        #expect(settings.defaults.data(forKey: RunJournal.key) == nil, "offered once")
        next.interruptedRunConfirm()
        #expect(next.interruptedRun == nil)
        #expect(await waitUntil { next.upgrade?.isFinished == true || next.upgradePlan != nil })
        if let s = next.upgrade { #expect(s.items.map(\.package.fullName) == pkgs.map(\.fullName)) }
    }

    @Test func stopAfterCurrentKeepsOnlyTheRest() async throws {
        let settings = AppSettings.ephemeral("net.mindtricks.tankard.test.quit3")
        let gate = Latch()
        let calls = CallLog()
        let client = makeClient(FakeInfoRunner(log: calls, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: calls, behaviour: { args, _ in
            guard args.first == "upgrade" else { return 0 }
            await gate.wait()
            return 0
        })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                             settings: settings)
        await store.start()
        let pkgs = Array(store.upgradable.filter(\.isManualUpgradeTarget).prefix(3))
        store.startUpgrade(pkgs)
        #expect(await waitUntil { store.upgrade?.current != nil })
        let quit = Box(false)
        store.prepareToQuit(.afterCurrent) { quit.value = true }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!quit.value, "waits for the running step")
        gate.release()
        #expect(await waitUntil { quit.value })
        #expect(store.upgrade?.items.map(\.state) == [.done, .cancelled, .cancelled])
        let j = try #require(settings.defaults.data(forKey: RunJournal.key).flatMap(RunJournal.decode))
        #expect(j.targets == pkgs.dropFirst().map(\.fullName))
        #expect(j.finished == 1)
        // Nothing offered in this process (it is quitting).
        #expect(store.interruptedRun == nil)
    }
}
