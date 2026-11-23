import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.4 (part B): the app's side of vulnerabilities, caveats, sizes and
// self-updating apps, with fake runners and the captured fixtures.

private func fixtureData(_ name: String, _ ext: String = "json") throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TankardCoreTests/Fixtures/\(name).\(ext)")
    return try Data(contentsOf: url)
}

@MainActor
struct InsightsStoreTests {
    struct Rig {
        var store: AppStore
        var info: FakeInfoRunner
        var log: CallLog
        var dir: URL
    }

    /// The Intel VM capture as it is (not the demo's tweaks), with the VM's
    /// `brew vulns --json` and `brew info --sizes`.
    func rig(info: Data? = nil, now: Date = Date(), settings: AppSettings? = nil, cache: Bool = false) throws -> Rig {
        let dir = try tempDir()
        let log = CallLog()
        let runner = FakeInfoRunner(log: log, info: info ?? Demo.fixtureInfo(.intelbrew))
        runner.setInsight(BrewClient.vulnsArguments, ProcessResult(exitCode: 1, stdout: try fixtureData("sonoma-intelbrew-vulns"), stderr: Data()))
        runner.setInsight(BrewClient.sizesArguments, ProcessResult(exitCode: 0, stdout: try fixtureData("sonoma-intelbrew-sizes", "txt"), stderr: Data()))
        let client = makeClient(runner)
        let stream = FakeStreamRunner(log: log) { _, out in out(Data("ok\n".utf8)); return 0 }
        var deps = AppStore.Dependencies(makeClient: { client }, streamRunner: stream,
                                         cache: StatusCache(url: dir.appendingPathComponent("status.json")),
                                         logURL: nil, ttl: 3600, now: { now })
        if cache { deps.insightsCache = InsightsCache(url: dir.appendingPathComponent("insights.json")) }
        return Rig(store: AppStore(deps: deps, settings: settings ?? scanningSettings()), info: runner, log: log, dir: dir)
    }

    @Test func scanAndSizesAreLaidOverTheReport() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.info.insightLog.calls.sorted { $0[0] < $1[0] } == [["info", "--sizes"], ["vulns", "--json"]])
        // The status reads stay the only `info --json` calls.
        #expect(r.log.count("info") == 1)
        let s = r.store
        #expect(s.packages.first { $0.name == "expat" }?.vulnerabilities?.count == 2)
        #expect(s.packages.first { $0.name == "openssl@4" }?.vulnerabilityBadge == "Vulnerable · 4") // all UNKNOWN in OSV
        #expect(s.count(.vulnerable) == 2)
        #expect(s.count(.hasNotes) == 5)
        s.filter = .vulnerable
        #expect(s.visiblePackages.map(\.name).sorted() == ["expat", "openssl@4"])
        s.filter = .hasNotes
        #expect(s.visiblePackages.map(\.name).sorted() == ["lua", "openssl@4", "python@3.15", "ruby", "vim"])
        #expect(s.packages.first { $0.name == "python@3.15" }?.diskBytes == 77_300_000)
        #expect(s.packages.allSatisfy { $0.diskBytes != nil })
        let total = try #require(s.totalDiskBytes)
        #expect(abs(total - 289_100_000) < 1_000_000)
        #expect(s.insights.vulnerabilityScan?.complete == false)
        #expect(s.insights.scanState == .idle)
    }

    @Test func badgeNamesTheWorstSeverity() {
        var p = Package.command("x")
        p.kind = .formula
        #expect(p.vulnerabilityBadge == nil)
        p.vulnerabilities = [PackageVulnerability(id: "A", severity: .low), PackageVulnerability(id: "B", severity: .high)]
        #expect(p.vulnerabilityBadge == "High · 2")
        #expect(p.worstSeverity == .high)
        p.vulnerabilities = [PackageVulnerability(id: "A", severity: .unknown)]
        #expect(p.vulnerabilityBadge == "Vulnerable")
    }

    /// A refresh after an upgrade re-scans; until then a package whose
    /// version changed isn't shown with the old findings.
    @Test func failedScanKeepsTheLastResult() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.store.count(.vulnerable) == 2)
        r.info.setInsight(BrewClient.vulnsArguments, ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: OSV API request to https://api.osv.dev/v1/querybatch failed (curl exit 6)".utf8)))
        r.store.scanVulnerabilitiesNow()
        await r.store.insights.waitForIdle()
        guard case .failed(let message) = r.store.insights.scanState else {
            Issue.record("expected a failure, got \(r.store.insights.scanState)")
            return
        }
        #expect(message.contains("curl exit 6"))
        #expect(r.store.count(.vulnerable) == 2)
    }

    @Test func brewWithoutVulnsSaysSo() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.info.setInsight(BrewClient.vulnsArguments, ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: Unknown command: brew vulns".utf8)))
        await r.store.start()
        await r.store.insights.waitForIdle()
        guard case .unsupported = r.store.insights.scanState else {
            Issue.record("expected unsupported, got \(r.store.insights.scanState)")
            return
        }
        #expect(r.store.count(.vulnerable) == 0)
    }

    @Test func scanOnRefreshCanBeTurnedOff() async throws {
        let settings = testSettings()
        InsightSettings(defaults: settings.defaults).scanVulnerabilitiesOnRefresh = false
        let r = try rig(settings: settings)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        #expect(r.store.insights.settings.scanVulnerabilitiesOnRefresh == false)
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.info.insightLog.calls == [["info", "--sizes"]])
        r.store.scanVulnerabilitiesNow() // on demand still works
        await r.store.insights.waitForIdle()
        #expect(r.store.count(.vulnerable) == 2)
    }

    /// 0.4 review: off by default. A refresh sends nothing to OSV.dev
    /// until the user opts in; Scan now still runs one scan on request.
    @Test func scanOnRefreshIsOffByDefault() async throws {
        let r = try rig(settings: testSettings())
        defer { try? FileManager.default.removeItem(at: r.dir) }
        #expect(!r.store.insights.settings.scanVulnerabilitiesOnRefresh)
        await r.store.start()
        await r.store.insights.waitForIdle()
        await r.store.refresh(manual: true)
        await r.store.insights.waitForIdle()
        #expect(!r.info.insightLog.calls.contains(BrewClient.vulnsArguments))
        #expect(r.store.insights.vulnerabilityScan == nil)
        r.store.scanVulnerabilitiesNow()
        await r.store.insights.waitForIdle()
        #expect(r.info.insightLog.calls.filter { $0 == BrewClient.vulnsArguments }.count == 1)
        #expect(r.store.count(.vulnerable) == 2)
        #expect(InsightSettings.scanPrivacyNote == "Sends your installed formula names and versions to OSV.dev (via brew vulns).")
    }

    /// A brew vulns that hangs is stopped after `scanTimeout` (a real child
    /// process here, killed through ProcessRunner's cancellation), and the
    /// strip says the scan timed out; the last result stays.
    @Test func hungScanTimesOut() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.store.count(.vulnerable) == 2)
        let hanging = HangingVulnsRunner(fallback: r.info)
        let client = makeClient(hanging)
        r.store.insights.scanTimeout = .milliseconds(300)
        let started = Date()
        r.store.insights.scanVulnerabilities(client: client, env: [:])
        #expect(r.store.insights.scanState == .running)
        await r.store.insights.waitForIdle()
        let elapsed = Date().timeIntervalSince(started)
        #expect(r.store.insights.scanState == .failed(InsightsStore.scanTimedOutMessage))
        #expect(elapsed < 10, "the hung child was not stopped (\(elapsed) s)")
        #expect(hanging.ran.value)
        #expect(r.store.count(.vulnerable) == 2)
        #expect(InsightsStore.scanTimedOutMessage.hasPrefix("Scan timed out"))
        #expect(InsightsStore(settings: InsightSettings(defaults: testSettings().defaults), cache: nil, ttl: 1, now: { Date() })
                    .scanTimeout == .seconds(60))
    }

    /// Cached like status: fresh results are used without asking brew; a
    /// manual refresh asks again.
    @Test func cachedInsightsAreReusedUntilStale() async throws {
        let now = Date()
        let r = try rig(now: now, cache: true)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.info.insightLog.calls.count == 2)

        // A new launch: status and insights both from the cache, no brew.
        let log2 = CallLog()
        let runner2 = FakeInfoRunner(log: log2, info: Demo.fixtureInfo(.intelbrew))
        let client2 = makeClient(runner2)
        var deps = AppStore.Dependencies(makeClient: { client2 }, streamRunner: FakeStreamRunner(log: log2) { _, _ in 0 },
                                         cache: StatusCache(url: r.dir.appendingPathComponent("status.json")),
                                         logURL: nil, ttl: 3600, now: { now.addingTimeInterval(60) })
        deps.insightsCache = InsightsCache(url: r.dir.appendingPathComponent("insights.json"))
        let store2 = AppStore(deps: deps, settings: scanningSettings())
        await store2.start()
        await store2.insights.waitForIdle()
        #expect(log2.count("info") == 0)
        #expect(runner2.insightLog.calls.isEmpty)
        #expect(store2.count(.vulnerable) == 2)
        #expect(store2.packages.first { $0.name == "vim" }?.diskBytes == 45_400_000)

        // The refresh button re-reads everything.
        await store2.refresh(manual: true)
        await store2.insights.waitForIdle()
        #expect(runner2.insightLog.calls.count == 2)
    }

    @Test func caveatsShowThisMacsPrefix() {
        #expect(Caveats.display("Python is installed as\n  $HOMEBREW_PREFIX/bin/python3\n", prefix: "/usr/local")
                == "Python is installed as\n  /usr/local/bin/python3")
        #expect(Caveats.display("x $HOMEBREW_PREFIX", prefix: nil) == "x $HOMEBREW_PREFIX")
    }

    @Test func filterListsCoverEveryFilter() {
        #expect(Set(PackageFilter.segmented + PackageFilter.more) == Set(PackageFilter.allCases))
        #expect(PackageFilter.vulnerable.title == "Vulnerable")
        #expect(PackageFilter.hasNotes.title == "Has notes")
    }
}

@MainActor
struct VulnerableUpgradeTests {
    /// The Intel demo: its older openssl@4 is vulnerable and has an
    /// upgrade; expat is vulnerable with no upgrade yet.
    func demoStore() async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: scanningSettings())
        await store.start()
        await store.insights.waitForIdle()
        return store
    }

    @Test func upgradesOnlyVulnerablePackagesWithAnUpgrade() async throws {
        let store = await demoStore()
        #expect(store.packages.filter(\.isVulnerable).map(\.name).sorted() == ["expat", "openssl@4"])
        #expect(store.vulnerableUpgradeTargets.map(\.name) == ["openssl@4"])
        #expect(VulnerabilityUpgrades.withoutUpgrade(store.packages).map(\.name) == ["expat"])
        store.upgradeVulnerable()
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.command.arguments) == [["upgrade", "--formula", "homebrew/core/openssl@4"]])
        #expect(await waitUntil { session.isFinished })
        // Re-read and re-scanned: 4.1.0 is what brew checked, and OSV still
        // lists it (fixes are upstream commits, no release yet).
        #expect(await waitUntil { !store.isRefreshing && store.insights.scanState == .idle
                && store.packages.first { $0.name == "openssl@4" }?.upgradeAvailable == false })
        #expect(store.packages.first { $0.name == "openssl@4" }?.isVulnerable == true)
    }

    /// The hook v0.4a's pins plug into: held packages are left out.
    @Test func heldPackagesAreLeftOut() async throws {
        let store = await demoStore()
        store.insights.isHeld = { $0.name == "openssl@4" }
        #expect(store.vulnerableUpgradeTargets.isEmpty)
        store.upgradeVulnerable()
        #expect(store.upgrade == nil)
        store.insights.isHeld = { $0.pinned }
        var pinned = try #require(store.packages.first { $0.name == "openssl@4" })
        pinned.pinned = true
        #expect(VulnerabilityUpgrades.targets([pinned], isHeld: store.insights.isHeld).isEmpty)
    }
}

@MainActor
struct PostInstallNotesTests {
    @Test func notesFollowTheUpgradeOnce() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let targets = store.upgradable.filter { ["python@3.15", "sqlite"].contains($0.name) }
        store.startUpgrade(targets)
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.isFinished })
        // The sheet is still open: the notes wait for it to close.
        #expect(await waitUntil { !store.isRefreshing && store.insights.pendingNotes != nil })
        #expect(store.insights.postInstallNotes == nil)
        store.closeUpgrade()
        #expect(await waitUntil { store.insights.postInstallNotes != nil })
        let notes = try #require(store.insights.postInstallNotes)
        #expect(notes.notes.map(\.name) == ["python@3.15"]) // sqlite has none
        #expect(notes.notes[0].version == "3.15.2")
        #expect(notes.notes[0].text.contains("/usr/local/bin/python3"))
        #expect(!notes.notes[0].text.contains("$HOMEBREW_PREFIX"))
        #expect(notes.subtitle == "Notes from 1 upgraded package")
        store.insights.postInstallNotes = nil
        store.closeUpgrade()
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.insights.postInstallNotes == nil) // once
    }

    @Test func onlyInstallsAndUpgradesWithCaveats() throws {
        var p = Package.command("x")
        p.id = "formula:homebrew/core/x"
        p.caveats = "Run x --init"
        #expect(PostInstallNotes.make(action: .install, changedIDs: [p.id], packages: [p], prefix: nil)?.notes.count == 1)
        #expect(PostInstallNotes.make(action: .uninstall, changedIDs: [p.id], packages: [p], prefix: nil) == nil)
        #expect(PostInstallNotes.make(action: .upgrade, changedIDs: ["formula:homebrew/core/y"], packages: [p], prefix: nil) == nil)
        p.caveats = nil
        #expect(PostInstallNotes.make(action: .upgrade, changedIDs: [p.id], packages: [p], prefix: nil) == nil)
    }

    @Test func notesShowAtOnceWhenTheSheetIsClosed() {
        let insights = InsightsStore(settings: InsightSettings(defaults: testSettings().defaults), cache: nil, ttl: 3600, now: { Date() })
        let notes = PostInstallNotes(action: .install, notes: [.init(id: "a", name: "a", version: "1", kind: .formula, text: "t")])
        insights.offer(notes, sheetOpen: false)
        #expect(insights.postInstallNotes == notes)
        #expect(insights.pendingNotes == nil)
    }
}

@MainActor
struct SelfUpdatingAndNoQuitTests {
    func armStore(_ configure: (InsightSettings) -> Void = { _ in }) async -> AppStore {
        let settings = testSettings()
        settings.appManagementExplained = true
        configure(InsightSettings(defaults: settings.defaults))
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: settings)
        await store.start()
        return store
    }

    @Test func offByDefault() async {
        let store = await armStore()
        #expect(!store.insights.settings.includeSelfUpdatingApps)
        #expect(!store.insights.settings.dontQuitAppsDuringUpgrade)
        let tailscale = store.packages.first { $0.name == "tailscale-app" }
        #expect(tailscale?.upgradeAvailable == true && tailscale?.selfUpdateHeld == true && tailscale?.isUpgradeTarget == false)
    }

    @Test func greedyCasksAppearAndGoWithTheSetting() async throws {
        let store = await armStore { $0.includeSelfUpdatingApps = true }
        let before = store.upgradable.count
        let ts = try #require(store.packages.first { $0.name == "tailscale-app" })
        #expect(ts.upgradeAvailable && ts.selfUpdatingUpgrade == true)
        #expect(ts.currentVersion == "1.104.7")
        // 0.8.6 (M5): off leaves every self-updating cask to its app, not
        // only the greedy one (tailscale-app).
        let selfUpdating = store.upgradable.filter { $0.kind == .cask && ($0.autoUpdates == true || $0.selfUpdatingUpgrade == true) }.count
        #expect(selfUpdating > 1)
        store.insights.settings.includeSelfUpdatingApps = false
        // The recovered greedy-only cask remains listed as a held upgrade, but
        // only non-self-updating packages are still Upgrade All targets.
        #expect(store.upgradable.count == before - selfUpdating)
        #expect(store.report?.summary.upgrades == before)
        store.insights.settings.includeSelfUpdatingApps = true // re-reads with --greedy
        #expect(await waitUntil { store.upgradable.count == before && !store.isRefreshing })
    }

    @Test func greedyCaskUpgradesWithTheNormalCommand() async throws {
        let store = await armStore { $0.includeSelfUpdatingApps = true }
        let ts = try #require(store.packages.first { $0.name == "tailscale-app" })
        store.startUpgrade([ts])
        let session = try #require(store.upgrade)
        #expect(session.items.map(\.command.arguments) == [["upgrade", "--cask", "homebrew/cask/tailscale-app"]])
        #expect(await waitUntil { session.isFinished && !store.isRefreshing })
        #expect(await waitUntil { store.packages.first { $0.name == "tailscale-app" }?.upgradeAvailable == false })
    }

    @Test func dontQuitAppliesToCaskUpgradesOnly() async throws {
        // 0.8.6 (M5): Chrome (auto_updates) in Upgrade All.
        let store = await armStore { $0.dontQuitAppsDuringUpgrade = true; $0.includeSelfUpdatingApps = true }
        let cask = try #require(store.upgradable.first { $0.kind == .cask })
        let formula = try #require(store.upgradable.first { $0.kind == .formula })
        store.startUpgrade([cask, formula])
        let session = try #require(store.upgrade)
        let c = session.items[0].command, f = session.items[1].command
        #expect(c.environment["HOMEBREW_NO_UPGRADE_QUIT_CASKS"] == "1")
        #expect(c.display == "HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 brew upgrade --cask \(cask.qualifiedName)")
        #expect(f.environment["HOMEBREW_NO_UPGRADE_QUIT_CASKS"] == nil)
        #expect(f.display == "brew upgrade --formula \(formula.qualifiedName)")
        #expect(store.insights.upgradeDisplay(for: cask).hasPrefix("HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 brew upgrade --cask"))
        #expect(InsightSettings.extraEnvironment(.uninstall, cask, dontQuitApps: true).isEmpty)
        #expect(await waitUntil { session.isFinished })
    }

    @Test func settingsPersist() {
        let d = testSettings().defaults
        let a = InsightSettings(defaults: d)
        #expect(!a.scanVulnerabilitiesOnRefresh) // off by default: it sends data to OSV.dev
        a.includeSelfUpdatingApps = true
        a.dontQuitAppsDuringUpgrade = true
        a.notifyNewVulnerabilities = true
        a.seenVulnerabilities = ["x#CVE-1"]
        let b = InsightSettings(defaults: d)
        #expect(b.includeSelfUpdatingApps && b.dontQuitAppsDuringUpgrade && b.notifyNewVulnerabilities)
        #expect(b.seenVulnerabilities == ["x#CVE-1"])
    }
}

@MainActor
struct VulnerabilityNoticeTests {
    func scan(_ findings: [String: [String]]) -> VulnerabilityScan {
        var s = VulnerabilityScan(json: try! BrewVulnsJSON.decode(stdout: Data(#"{"findings":[]}"#.utf8)), scannedAt: Date())
        s.findings = findings.mapValues { $0.map { PackageVulnerability(id: $0, severity: .high) } }
        return s
    }

    @Test func onlyNewOnesAfterABaseline() {
        let first = scan(["expat": ["CVE-1"]])
        #expect(VulnerabilityNotice.newFormulae(seen: nil, scan: first).isEmpty)
        let seen = VulnerabilityNotice.keys(first)
        #expect(VulnerabilityNotice.newFormulae(seen: seen, scan: first).isEmpty)
        let second = scan(["expat": ["CVE-1", "CVE-2"], "xz": ["CVE-3"]])
        #expect(VulnerabilityNotice.newFormulae(seen: seen, scan: second) == ["expat", "xz"])
        #expect(VulnerabilityNotice.newFormulae(seen: seen, scan: scan([:])).isEmpty) // fixed: nothing to say
    }

    @Test func noticeInTheStore() async {
        let settings = scanningSettings()
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: settings)
        await store.start()
        await store.insights.waitForIdle()
        #expect(store.insights.newVulnerableFormulae.isEmpty) // off by default
        store.insights.settings.notifyNewVulnerabilities = true
        // Turning it on takes what is known now as the baseline.
        #expect(store.insights.settings.seenVulnerabilities?.count == 6)
        #expect(store.insights.newVulnerableFormulae.isEmpty)
        store.insights.settings.seenVulnerabilities = ["expat#CVE-2026-124317"]
        #expect(store.insights.newVulnerableFormulae == ["expat", "openssl@4"])
        store.filter = .all
        store.showVulnerable()
        #expect(store.filter == .vulnerable)
        #expect(store.insights.newVulnerableFormulae.isEmpty)
    }
}

struct InsightColorTests {
    @Test func warningColoursMeetAAInEveryTheme() {
        let pairs = VulnerabilityColors.textPairs
        #expect(pairs.count >= 60)
        for (name, text, bg) in pairs {
            let c = TankardPalette.contrast(text, bg)
            #expect(c >= 4.5, "\(name): \(String(format: "%.2f", c)):1")
        }
        for theme in AppTheme.allCases {
            #expect(pairs.contains { $0.0.hasPrefix(theme == .system ? "system" : theme.rawValue) })
        }
    }

    @Test func displayWithEnvironment() {
        #expect(BrewCommands.display(["upgrade", "--cask", "homebrew/cask/iterm2"], environment: [:]) == "brew upgrade --cask homebrew/cask/iterm2")
        #expect(BrewCommands.display(["upgrade"], environment: ["B": "x y", "A": "1"]) == "A=1 B='x y' brew upgrade")
    }

    @Test func demoInsightFixturesMatchTheCaptures() throws {
        for (name, ext) in [("sonoma-intelbrew-vulns", "json"), ("arm64-vulns", "json"), ("arm64-outdated-greedy", "json"),
                            ("sonoma-intelbrew-outdated-greedy", "json")] {
            // `try` outside #expect: Swift 6.0 (the Intel VM's CLT) rejects it inside.
            let captured = try fixtureData(name, ext)
            #expect(Demo.fixtureData(name) == captured, "\(name) differs")
        }
        for name in ["sonoma-intelbrew-sizes", "arm64-sizes", "arm64-vulns-stderr"] {
            let captured = try fixtureData(name, "txt")
            #expect(Data(Demo.fixtureText(name).utf8) == captured, "\(name) differs")
        }
    }
}

/// `brew vulns` that never finishes: runs a real `/bin/sleep 600` through
/// ProcessRunner, so only cancellation (SIGTERM to its group) ends it.
final class HangingVulnsRunner: CommandRunning, @unchecked Sendable {
    let fallback: FakeInfoRunner
    let ran = Flag()
    init(fallback: FakeInfoRunner) { self.fallback = fallback }
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard arguments == BrewClient.vulnsArguments else {
            return try await fallback.run(executable, arguments, environment: environment)
        }
        ran.set()
        return try await ProcessRunner().run("/bin/sleep", ["600"], environment: [:])
    }
}
