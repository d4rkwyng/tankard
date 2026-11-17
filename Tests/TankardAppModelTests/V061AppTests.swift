import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.6.1: the More filter picker's binding, the scan's progress states and
// the settings explanations.

private func fixtureData(_ name: String, _ ext: String = "json") throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TankardCoreTests/Fixtures/\(name).\(ext)")
    return try Data(contentsOf: url)
}

@MainActor
struct V061MoreFilterTests {
    @Test func pickerSelectionSetsTheFilter() {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        #expect(store.filter == .all)
        #expect(store.moreFilterSelection == nil)
        store.moreFilterSelection = .vulnerable
        #expect(store.filter == .vulnerable)
        #expect(store.moreFilterSelection == .vulnerable)
        store.moreFilterSelection = .hasNotes
        #expect(store.filter == .hasNotes)
        // A segmented filter shows "More" (nil).
        store.filter = .upgrades
        #expect(store.moreFilterSelection == nil)
    }

    /// Equal writes, nil ("More") and filters outside the More list change
    /// and notify nothing.
    @Test func equalAndForeignWritesAreIgnored() {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        store.moreFilterSelection = .pinned
        let notified = Flag()
        withObservationTracking { _ = store.filter } onChange: { notified.set() }
        store.moreFilterSelection = .pinned
        store.moreFilterSelection = nil
        store.moreFilterSelection = .upgrades
        #expect(!notified.value)
        #expect(store.filter == .pinned)
    }

    /// Leaving Installed clears a More filter; segmented filters and
    /// staying on Installed keep theirs.
    @Test func leavingInstalledClearsAMoreFilter() {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        store.moreFilterSelection = .hasNotes
        store.tabChanged(to: .installed)
        #expect(store.filter == .hasNotes)
        store.tabChanged(to: .discover)
        #expect(store.filter == .all)
        #expect(store.moreFilterSelection == nil)
        store.filter = .upgrades
        store.tabChanged(to: .discover)
        #expect(store.filter == .upgrades)
    }
}

@MainActor
struct V061ScanProgressTests {
    struct Rig {
        var store: AppStore
        var info: FakeInfoRunner
        var dir: URL
    }

    /// Scan on refresh off, so only the test starts scans.
    func rig() throws -> Rig {
        let dir = try tempDir()
        let runner = FakeInfoRunner(log: CallLog(), info: Demo.fixtureInfo(.intelbrew))
        runner.setInsight(BrewClient.vulnsArguments, ProcessResult(exitCode: 1, stdout: try fixtureData("sonoma-intelbrew-vulns"), stderr: Data()))
        runner.setInsight(BrewClient.sizesArguments, ProcessResult(exitCode: 0, stdout: try fixtureData("sonoma-intelbrew-sizes", "txt"), stderr: Data()))
        let client = makeClient(runner)
        let stream = FakeStreamRunner(log: CallLog()) { _, out in out(Data("ok\n".utf8)); return 0 }
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: stream,
                                         cache: StatusCache(url: dir.appendingPathComponent("status.json")),
                                         logURL: nil, ttl: 3600, now: { Date() })
        return Rig(store: AppStore(deps: deps, settings: testSettings()), info: runner, dir: dir)
    }

    /// idle → running (start time, formula count) → done ("Scanned N · found M").
    @Test func idleRunningDone() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let i = r.store.insights
        #expect(i.scanState == .idle)
        #expect(i.scanOutcome == nil)
        #expect(i.scanStartedAt == nil)
        let formulae = r.store.formulaCount
        #expect(formulae > 0)
        r.store.scanVulnerabilitiesNow()
        #expect(i.scanState == .running)
        #expect(i.scanStartedAt != nil)
        #expect(i.scanFormulaCount == formulae)
        await i.waitForIdle()
        #expect(i.scanState == .idle)
        #expect(i.scanStartedAt == nil)
        let scan = try #require(i.vulnerabilityScan)
        #expect(i.scanOutcome == .done(checked: scan.checked, found: 2, complete: scan.complete))
        #expect(ScanProgressText.outcome(i.scanOutcome!).hasPrefix("Scanned \(scan.checked) · found 2"))
    }

    /// Stop cancels a hung brew vulns (a real child process) at once; the
    /// last result stays. A second Stop, with nothing running, notifies nothing.
    @Test func runningStopped() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let i = r.store.insights
        let hanging = HangingVulnsRunner(fallback: r.info)
        i.scanVulnerabilities(client: makeClient(hanging), env: [:], formulae: 7)
        #expect(i.scanState == .running)
        #expect(i.scanFormulaCount == 7)
        let started = Date()
        while !hanging.ran.value && Date().timeIntervalSince(started) < 5 { try await Task.sleep(for: .milliseconds(20)) }
        i.stopScan()
        #expect(i.scanState == .idle)
        #expect(i.scanOutcome == .stopped)
        #expect(i.scanStartedAt == nil)
        await i.waitForIdle()
        #expect(Date().timeIntervalSince(started) < 10, "Stop did not end brew vulns")
        #expect(i.scanState == .idle)
        #expect(i.scanOutcome == .stopped)

        let notified = Flag()
        withObservationTracking { _ = (i.scanState, i.scanOutcome, i.scanStartedAt, i.scanFormulaCount) } onChange: { notified.set() }
        i.stopScan()
        #expect(!notified.value)
    }

    /// running → timed out after `scanTimeout`.
    @Test func runningTimedOut() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let i = r.store.insights
        i.scanTimeout = .milliseconds(300)
        i.scanVulnerabilities(client: makeClient(HangingVulnsRunner(fallback: r.info)), env: [:], formulae: 3)
        #expect(i.scanState == .running)
        await i.waitForIdle()
        #expect(i.scanState == .failed(InsightsStore.scanTimedOutMessage))
        #expect(i.scanOutcome == .timedOut)
        #expect(i.scanStartedAt == nil)
    }

    /// Scan now while one runs starts nothing new.
    @Test func scanNowWhileRunningIsIgnored() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let i = r.store.insights
        i.scanVulnerabilities(client: makeClient(HangingVulnsRunner(fallback: r.info)), env: [:], formulae: 3)
        let notified = Flag()
        withObservationTracking { _ = (i.scanState, i.scanOutcome, i.scanStartedAt, i.scanFormulaCount) } onChange: { notified.set() }
        r.store.scanVulnerabilitiesNow()
        #expect(!notified.value)
        i.stopScan()
        await i.waitForIdle()
    }

    @Test func progressText() {
        #expect(ScanProgressText.running(formulae: 42) == "Scanning 42 formulae…")
        #expect(ScanProgressText.running(formulae: 1) == "Scanning 1 formula…")
        #expect(ScanProgressText.elapsed(7) == "0:07")
        #expect(ScanProgressText.elapsed(62) == "1:02")
        #expect(ScanProgressText.outcome(.done(checked: 40, found: 2, complete: false)) == "Scanned 40 · found 2 · partial scan")
        #expect(ScanProgressText.outcome(.stopped) == "Scan stopped")
        #expect(ScanProgressText.outcome(.timedOut) == "Scan timed out")
    }
}

struct V061SettingsHelpTests {
    @Test func everyExplanationHasText() {
        #expect(SettingsHelp.all.count == 12)  // 0.8: + backgroundUpdate
        for text in SettingsHelp.all {
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20)
        }
        #expect(SettingsHelp.scanOnRefresh.contains(InsightSettings.scanPrivacyNote))
        #expect(SettingsHelp.safeMode.hasPrefix("Safe mode (always on):"))
    }
}
