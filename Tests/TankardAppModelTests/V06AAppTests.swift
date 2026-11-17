import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.6 (part A), app side: the Deprecated filter and replacement install,
// History (recording, persistence, the 500 cap, Retry), Health and
// autoremove through demo mode, and friendly failures. Demo and fakes only.

@MainActor
struct V06ARetiredTests {
    @Test func deprecatedFilterAndReplacement() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        #expect(PackageFilter.more.contains(.deprecated))
        #expect(store.count(.deprecated) == 1)
        let p = try #require(store.packages.first { $0.name == "json-c" })
        #expect(p.retiredLabel == "deprecated")
        #expect(p.retiredDetail == "Deprecated since 2026-09-01: json-c has an archived upstream repository.")
        #expect(p.replacement == PackageReplacement(name: "cjson", kind: .formula))
        #expect(store.installedReplacement(p.replacement!) == nil)
        store.installReplacement(for: p)
        let session = try #require(store.upgrade)
        #expect(session.action == .install)
        #expect(session.items.first?.command.arguments == ["install", "--formula", "cjson"])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(await waitUntil { store.packages.contains { $0.name == "cjson" } })
    }

    @Test func linkNotes() {
        var p = Package.command("x")
        p.kegOnly = true
        p.kegOnlyReason = "macOS provides BSD libedit"
        #expect(p.linkNotes == ["Keg-only: macOS provides BSD libedit. Not linked into the prefix on purpose."])
        p.kegOnly = false
        p.linked = false
        #expect(p.linkNotes.first?.hasPrefix("Not linked") == true)
        p.kind = .cask
        #expect(p.linkNotes.isEmpty)
    }
}

@MainActor
struct V06AHistoryTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tankard-history-\(UUID().uuidString).json")
    }

    @Test func queueCommandsAreRecorded() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.setPinned(xz, true)
        #expect(await waitUntil { store.history.entries.contains { $0.arguments.first == "pin" } })
        let e = try #require(store.history.entries.first { $0.arguments.first == "pin" })
        #expect(e.command == "brew pin --formula homebrew/core/xz")
        #expect(e.outcome == .succeeded && e.exitCode == 0)
        #expect(e.duration >= 0)
        #expect(e.origin == .user)
        #expect(e.category == .pin)
        #expect(e.outputTail.isEmpty)
    }

    @Test func failureIsClassifiedAndRetried() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let fails = OSAllocatedFlag()
        let runner = FakeStreamRunner(log: log, behaviour: { args, out in
            if args.first == "pin", fails.takeFirst() {
                out(Data("Error: Another `brew pin` process is already running.\n".utf8))
                return 1
            }
            return 0
        })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.setPinned(xz, true)
        #expect(await waitUntil { store.history.entries.contains { $0.outcome == .failed } })
        let failed = try #require(store.history.entries.first { $0.outcome == .failed })
        #expect(failed.failureKind == .locked)
        #expect(failed.canRetry)
        #expect(failed.outputTail.last?.contains("already running") == true)
        // The banner says it in words too.
        #expect(await waitUntil { store.error?.title.contains(BrewFailureKind.locked.title) == true })
        #expect(await waitUntil { !store.isBusy && !store.isRefreshing })
        store.retry(failed)
        #expect(await waitUntil { store.history.entries.filter { $0.arguments.first == "pin" }.count == 2 })
        #expect(store.history.entries.first { $0.arguments.first == "pin" }?.outcome == .succeeded)
    }

    @Test func persistsAndCaps() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = HistoryLog(url: url)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(HistoryLog.maxEntries + 5) {
            log.record(HistoryEntry(startedAt: base.addingTimeInterval(Double(i)), duration: 1, command: "brew update",
                                    arguments: ["update"], outcome: i == 3 ? .failed : .succeeded))
        }
        #expect(log.entries.count == HistoryLog.maxEntries)
        #expect(log.entries.first?.startedAt == base.addingTimeInterval(Double(HistoryLog.maxEntries + 4)))
        let again = HistoryLog(url: url)
        #expect(again.entries == log.entries)
        // The same encoder as the auto-update log: ISO dates.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"startedAt\" : \"2027-"))
    }

    @Test func filters() {
        let log = HistoryLog(url: nil)
        Demo.seedHistory(log, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(log.filtered(.failed).count == 2)
        #expect(log.filtered(.autoUpdate).count == 2)
        #expect(log.filtered(.category(.upgrade)).count == 3)
        #expect(log.filtered(.all, search: "jq").count == 1)
        let failed = log.filtered(.failed)
        #expect(failed.allSatisfy { $0.canRetry })
        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test func cancelledBeforeStartIsNotHistory() async {
        let recorder = HistoryRecorder()
        let got = Box<[HistoryEntry]>([])
        recorder.setSink { got.value.append($0) }
        let cmd = QueuedCommand(executable: "/x/brew", arguments: ["update"], environment: [:], display: "brew update")
        recorder.observe(UUID(), cmd, .cancelled)
        let id = UUID()
        recorder.observe(id, cmd, .started)
        recorder.observe(id, cmd, .finished(exitCode: 0))
        #expect(await waitUntil { got.value.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(got.value.count == 1 && got.value[0].outcome == .succeeded)
    }
}

@MainActor
struct V06AHealthTests {
    @Test func healthReadsDoctorConfigMissing() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.openHealth()
        #expect(store.toolSheet == .health)
        let h = try #require(store.health)
        #expect(await waitUntil { h.phase == .ready })
        #expect(h.doctor?.warnings.count == 4)
        #expect(h.doctor?.maintainersNote == true)
        #expect(h.config.contains("HOMEBREW_VERSION"))
        #expect(h.missing.isEmpty)
        // Read-only: nothing went through the queue.
        #expect(store.history.entries.isEmpty)
    }

    @Test func autoremoveDryRunThenRun() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.openAutoremove()
        let a = try #require(store.autoremove)
        #expect(await waitUntil { a.phase == .ready })
        #expect(a.plan?.formulae == ["icu4c@78", "libyaml", "homebrew/core/m4"])
        #expect(store.history.entries.isEmpty) // the dry run is not queued
        store.startAutoremove()
        #expect(store.toolSheet == nil)
        #expect(store.upgrade?.action == .autoremove)
        #expect(store.upgrade?.items.first?.command.arguments == ["autoremove"])
        #expect(await waitUntil { store.history.entries.contains { $0.arguments == ["autoremove"] && $0.outcome == .succeeded } })
        await a.load()
        #expect(a.plan?.formulae.isEmpty == true)
    }

    @Test func closeToolSheetDropsEqualWrites() async {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        let notified = Flag()
        withObservationTracking { _ = store.toolSheet } onChange: { notified.set() }
        store.closeToolSheet() // already nil: no write
        #expect(!notified.value)
        store.openHistory()
        #expect(notified.value)
    }

    @Test func sessionNotesFriendlyFailure() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: { args, out in
            if args.first == "upgrade" {
                out(Data("curl: (6) Could not resolve host: ghcr.io\n".utf8))
                return 1
            }
            return 0
        })
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.startUpgrade([xz])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(store.upgrade?.failureKinds == [.network])
        #expect(store.upgrade?.log.lines.contains { $0.contains(BrewFailureKind.network.title) } == true)
    }
}

/// A one-shot flag: true the first time.
final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func takeFirst() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

@MainActor final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}
