import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

@MainActor
struct DisplayAndDemoTests {
    func intelReport() async throws -> StatusReport {
        try await makeClient(FakeInfoRunner(log: CallLog(), info: demoIntelInfo())).status()
    }

    @Test func qualifiedNamesAndCommands() async throws {
        let r = try await intelReport()
        let xz = try #require(r.packages.first { $0.name == "xz" })
        #expect(xz.qualifiedName == "homebrew/core/xz")
        #expect(BrewCommands.upgradeArguments(for: xz) == ["upgrade", "--formula", "homebrew/core/xz"])
        #expect(BrewCommands.upgradeDisplay(for: xz) == "brew upgrade --formula homebrew/core/xz")
        #expect(BrewCommands.shellQuoted("it's here") == "'it'\\''s here'")
    }

    @Test func casksUseTheCaskFlag() async throws {
        let client = BrewClient(installation: BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"),
                                runner: FakeInfoRunner(log: CallLog(), info: Demo.fixtureInfo(.arm64)),
                                sources: EnvironmentSources(process: ["HOME": "/Users/t"]), fileExists: { _ in false })
        let r = try await client.status()
        let chrome = try #require(r.packages.first { $0.name == "google-chrome" })
        #expect(BrewCommands.upgradeArguments(for: chrome) == ["upgrade", "--cask", "homebrew/cask/google-chrome"])
        #expect(chrome.badgeKind == .cask)
        #expect(!r.intelbrew.detected)
    }

    @Test func badgesAndReleasePage() async throws {
        let r = try await intelReport()
        func pkg(_ n: String) throws -> Package { try #require(r.packages.first { $0.name == n }) }
        let curl = try pkg("curl-impersonate")
        #expect(curl.badgeLabel(intelbrewMode: true) == "Intelbrew bottle")
        #expect(curl.badgeLabel(intelbrewMode: false) == "Bottle")
        #expect(curl.releasePageURL?.absoluteString == "https://github.com/d4rkwyng/intelbrew-core/releases/tag/curl-impersonate-2.3.2")
        #expect(curl.bottleRepository == "d4rkwyng/intelbrew-core")
        #expect(try pkg("lua").badgeLabel(intelbrewMode: true) == "Homebrew bottle")
        #expect(try pkg("lua").releasePageURL == nil) // ghcr.io has no page
        #expect(try pkg("vim").badgeLabel(intelbrewMode: true) == "Built from source")
        #expect(try pkg("zstd").badgeLabel(intelbrewMode: true) == "Newer than Intelbrew")
        #expect(try pkg("ruby").badgeKind == .noBottle)
        #expect(try pkg("ruby").subtitle == "Upgrade builds from source")
        #expect(try pkg("zstd").subtitle == "Tap has 1.5.7_1")
    }

    /// 0.8.1: a self-updating cask gets a symbol next to its name, not an
    /// "Updates itself" line under it; the tooltip names who updates it.
    @Test func selfUpdatingCaskIsASymbolNotSubtitleText() async throws {
        let client = BrewClient(installation: BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"),
                                runner: FakeInfoRunner(log: CallLog(), info: Demo.fixtureInfo(.arm64)),
                                sources: EnvironmentSources(process: ["HOME": "/Users/t"]), fileExists: { _ in false })
        let r = try await client.status()
        let chrome = try #require(r.packages.first { $0.name == "google-chrome" })
        #expect(chrome.autoUpdates == true)
        #expect(chrome.selfUpdates)
        #expect(chrome.subtitle == nil)
        #expect(r.packages.allSatisfy { !($0.subtitle ?? "").contains("Updates itself") })
        #expect(chrome.selfUpdateHelp(policy: .automatic, includeSelfUpdating: false) == "Updates itself (auto_updates).\nUpdates: Default (app updates itself)")
        #expect(chrome.selfUpdateHelp(policy: .automatic, includeSelfUpdating: true) == "Updates itself (auto_updates).\nUpdates: Default (Homebrew updates it)")
        for on in [false, true] {
            #expect(chrome.selfUpdateHelp(policy: .app, includeSelfUpdating: on).hasSuffix("Updates: App updates itself"))
            #expect(chrome.selfUpdateHelp(policy: .homebrew, includeSelfUpdating: on).hasSuffix("Updates: Homebrew updates it"))
        }
        let cmake = try #require(r.packages.first { $0.name == "cmake" })
        #expect(!cmake.selfUpdates)
    }

    @Test func summaryText() async throws {
        let r = try await intelReport()
        #expect(SummaryText.line(r.summary, intelbrewMode: true)
                == "20 installed · 8 Intelbrew bottles · 9 Homebrew bottles · 1 from source · 1 newer · 1 no bottle")
        let up = try #require(SummaryText.upgrades(r.summary))
        #expect(up.0 == "5 upgrades ready")
        #expect(up.1 == "(4 with bottles, 1 compiles)")
    }

    @Test func summaryTextShorterForms() async throws {
        let r = try await intelReport()
        let lines = SummaryText.lines(r.summary, intelbrewMode: true)
        #expect(lines == [
            "20 installed · 8 Intelbrew bottles · 9 Homebrew bottles · 1 from source · 1 newer · 1 no bottle",
            "20 installed · 8 Intelbrew bottles · 9 Homebrew bottles · 1 from source",
            "20 installed · 17 bottles · 1 from source",
            "20 installed · 17 bottles",
            "20 installed",
        ])
        // Each form is shorter than the one before; the first is the full line.
        #expect(lines.first == SummaryText.line(r.summary, intelbrewMode: true))
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.count > $1.count })
        // Not Intelbrew mode: the bottle split doesn't exist, so no repeat.
        let plain = SummaryText.lines(r.summary, intelbrewMode: false)
        #expect(Set(plain).count == plain.count)
        #expect(plain.last == "20 installed")
    }

    @Test func forkSummary() {
        var f = ForkStatus(coreTapPath: "/x", coreOrigin: Intelbrew.coreRemote, coreIsFork: true, brewRepository: "/r",
                           brewOrigin: Intelbrew.brewRemote, brewIsFork: true, brewVersion: "7.0.14", brewTag: "7.0.14",
                           brewNewestTag: "7.0.14", brewNewestTagSource: "local", brewAtNewestTag: true)
        #expect(ForkSummary(f).text == "Fork: current (Homebrew 7.0.14)")
        #expect(ForkSummary(f).level == .ok)
        f.brewAtNewestTag = false
        f.brewNewestTag = "7.0.15"
        #expect(ForkSummary(f).text == "Fork: behind (Homebrew 7.0.14; 7.0.15 available)")
        f.brewIsFork = false
        #expect(ForkSummary(f).level == .warning)
        f.coreIsFork = false
        #expect(ForkSummary(f).level == .problem)
    }

    @Test func updatedAgoText() {
        let now = Date()
        #expect(updatedAgo(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(updatedAgo(now.addingTimeInterval(-125), now: now) == "2 min ago")
        #expect(updatedAgo(now.addingTimeInterval(-7300), now: now) == "2 h ago")
    }

    @Test func sudoDetection() {
        #expect(SudoDetector.needsSudo(["sudo: a terminal is required to read the password; either use -S"]))
        #expect(SudoDetector.needsSudo(["Password:"]))
        #expect(!SudoDetector.needsSudo(["==> Pouring xz", "🍺 done"]))
    }

    @Test func demoFixturesMatchTheTestFixtures() throws {
        // The app ships copies of two step 1 fixtures for demo mode; they
        // must stay byte-identical to the tested originals.
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TankardCoreTests/Fixtures")
        for name in ["sonoma-intelbrew-info", "arm64-api-info", "sonoma-intelbrew-deps-info"] {
            let original = try Data(contentsOf: fixtures.appendingPathComponent("\(name).json"))
            #expect(Demo.fixtureData(name) == original, "\(name) differs")
        }
    }

    @Test func demoModeUpgradesEndToEnd() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        #expect(store.intelbrewMode)
        #expect(store.upgradable.count == 5)
        #expect(ForkSummary(try #require(store.report).fork).text == "Fork: current (Homebrew 7.0.14)")
        store.startUpgrade()
        let session = try #require(store.upgrade)
        #expect(await waitUntil { session.isFinished })
        #expect(session.succeededCount == 5)
        // Reconciled: demo brew now reports them current.
        #expect(await waitUntil { store.upgradable.isEmpty && !store.isRefreshing })
        #expect(session.log.lines.contains { $0.hasPrefix("🍺  /usr/local/Cellar/python@3.15/3.15.2") })
    }
}
