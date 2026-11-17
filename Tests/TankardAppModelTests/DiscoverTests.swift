import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// MARK: fake URLProtocol

/// Answers formulae.brew.sh requests from a handler and records them.
final class FakeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var path: String; var ifNoneMatch: String? }
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _seen: [Seen] = []

    static func reset(_ h: @escaping Handler) { lock.withLock { _handler = h; _seen = [] } }
    static var seen: [Seen] { lock.withLock { _seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, req) = Self.lock.withLock { () -> (Handler?, URLRequest) in
            Self._seen.append(Seen(path: request.url?.path ?? "", ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")))
            return (Self._handler, request)
        }
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let (status, headers, body) = try handler(req)
            let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeURLProtocol.self]
        c.urlCache = nil
        return URLSession(configuration: c)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

let formulaJSON = Data(#"""
[{"name":"xz","full_name":"xz","tap":"homebrew/core","desc":"General-purpose data compression",
  "versions":{"stable":"5.8.4"},"revision":0,"license":"0BSD","homepage":"https://tukaani.org/xz/",
  "dependencies":[],"bottle":{"stable":{"files":{"arm64_golden_gate":{"cellar":":any","url":"https://ghcr.io/v2/homebrew/core/xz/blobs/sha256:1"}}}}},
 {"name":"zstd","full_name":"zstd","tap":"homebrew/core","desc":"Zstandard compression","versions":{"stable":"1.5.7"},
  "revision":1,"dependencies":["lz4","xz"],"bottle":{"stable":{"files":{}}}}]
"""#.utf8)
let caskJSON = Data(#"[{"token":"firefox","full_token":"firefox","tap":"homebrew/cask","name":["Mozilla Firefox"],"desc":"Web browser","version":"160.0"}]"#.utf8)

@Suite(.serialized)
struct APICacheTests {
    func fetcher(_ dir: URL, _ clock: Clock) -> APIFetcher {
        APIFetcher(session: FakeURLProtocol.session(), cache: APICache(directory: dir), ttl: 3600, now: { clock.now })
    }

    @Test func etagTTLAndNotModified() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        FakeURLProtocol.reset { req in
            if req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return (304, [:], Data()) }
            return (200, ["ETag": "\"v1\""], formulaJSON)
        }
        let f = fetcher(dir, clock)

        let (d1, _, o1) = try await f.fetch("formula.json")
        #expect(o1 == .downloaded)
        #expect(d1 == formulaJSON)
        #expect(FakeURLProtocol.seen.count == 1)
        #expect(FakeURLProtocol.seen[0].path == "/api/formula.json")
        #expect(FakeURLProtocol.seen[0].ifNoneMatch == nil)

        // Within the TTL: the disk copy, no request at all.
        clock.advance(1800)
        let (d2, _, o2) = try await f.fetch("formula.json")
        #expect(o2 == .cacheFresh)
        #expect(d2 == formulaJSON)
        #expect(FakeURLProtocol.seen.count == 1)

        // Past the TTL: revalidate with the ETag; 304 keeps the copy and restarts the TTL.
        clock.advance(1801)
        let (d3, t3, o3) = try await f.fetch("formula.json")
        #expect(o3 == .notModified)
        #expect(d3 == formulaJSON)
        #expect(t3 == clock.now)
        #expect(FakeURLProtocol.seen.count == 2)
        #expect(FakeURLProtocol.seen[1].ifNoneMatch == "\"v1\"")
        let (_, _, o4) = try await f.fetch("formula.json")
        #expect(o4 == .cacheFresh)
        #expect(FakeURLProtocol.seen.count == 2)

        // A new instance (next launch) uses the same disk cache.
        let again = fetcher(dir, clock)
        #expect(try await again.fetch("formula.json").2 == .cacheFresh)
    }

    @Test func changedDataReplacesTheCopy() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        FakeURLProtocol.reset { _ in (200, ["ETag": "\"v1\""], Data("[]".utf8)) }
        let f = fetcher(dir, clock)
        _ = try await f.fetch("cask.json")
        clock.advance(4000)
        FakeURLProtocol.reset { _ in (200, ["ETag": "\"v2\""], caskJSON) }
        let (d, _, o) = try await f.fetch("cask.json")
        #expect(o == .downloaded)
        #expect(d == caskJSON)
        #expect(APICache(directory: dir).load("cask.json")?.1.etag == "\"v2\"")
    }

    @Test func failureFallsBackToStaleCopyOrThrows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let f = fetcher(dir, clock)
        FakeURLProtocol.reset { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: (any Error).self) { _ = try await f.fetch("formula.json") }

        FakeURLProtocol.reset { _ in (200, ["ETag": "\"v1\""], formulaJSON) }
        _ = try await f.fetch("formula.json")
        clock.advance(7200)
        FakeURLProtocol.reset { _ in (503, [:], Data()) }
        let (d, _, o) = try await f.fetch("formula.json")
        #expect(d == formulaJSON)
        if case .staleAfterError = o {} else { Issue.record("expected staleAfterError, got \(o)") }
    }

    @Test func catalogLoadsBothFilesAndSearches() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        FakeURLProtocol.reset { req in
            (200, ["ETag": "\"e\""], req.url!.lastPathComponent == "cask.json" ? caskJSON : formulaJSON)
        }
        let catalog = APICatalog(fetcher: fetcher(dir, clock), platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"))
        let store = await DiscoverStore(provider: catalog, debounce: .zero)
        await store.activate()
        await MainActor.run {
            #expect(store.phase == .ready)
            #expect(store.totalCount == 3)
            #expect(store.casksEnabled)
            #expect(store.casksNotice == nil)
            #expect(store.source.hasPrefix("formulae.brew.sh"))
            store.query = "compression"
        }
        await store.searchNow()
        await MainActor.run {
            #expect(store.results.map(\.name) == ["xz", "zstd"]) // both on description; shorter first
            #expect(store.results[0].bottle == .forThisMac)
            #expect(store.results[1].bottle == .fromSource)
            #expect(store.results[1].version == "1.5.7_1")
        }
        // Opening Discover again within the TTL fetches nothing.
        let before = FakeURLProtocol.seen.count
        await store.activate()
        #expect(FakeURLProtocol.seen.count == before)
        #expect(Set(FakeURLProtocol.seen.map(\.path)) == ["/api/formula.json", "/api/cask.json"])
    }
}

// MARK: Intelbrew mode

/// Answers `brew info --json=v2 --formula <names>` from the Intel fixture
/// (unknown names fail the whole call, like brew) and records each call.
final class CatalogInfoRunner: CommandRunning, @unchecked Sendable {
    let log = CallLog()
    let formulae: [String: Any]

    init() {
        let root = try! JSONSerialization.jsonObject(with: Demo.fixtureInfo(.intelbrew)) as! [String: Any]
        var byName: [String: Any] = [:]
        for f in root["formulae"] as! [[String: Any]] { byName[f["name"] as! String] = f }
        formulae = byName
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard executable.hasSuffix("brew") else { return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data()) }
        log.add(arguments)
        var out: [Any] = []
        for q in arguments.dropFirst(3) {
            let name = q.split(separator: "/").last.map(String.init) ?? q
            guard let f = formulae[name] else {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: No available formula with the name \"\(q)\".\n".utf8))
            }
            out.append(f)
        }
        return ProcessResult(exitCode: 0, stdout: try JSONSerialization.data(withJSONObject: ["formulae": out, "casks": []]), stderr: Data())
    }
}

struct FixedIndexer: TapIndexing {
    var entries: [TapIndexEntry]
    var taps = ["homebrew/core"]
    func index() -> TapIndex { TapIndex(entries: entries, taps: taps) }
}

@MainActor
struct IntelbrewDiscoverTests {
    let names = [
        ("python@3.15", "Interpreted, interactive, object-oriented programming language"),
        ("xz", "General-purpose data compression with high compression ratio"),
        ("zstd", "Zstandard is a real-time compression algorithm"),
        ("ghost", "Listed in the tap but brew can't load it"),
    ]

    func store(taps: [String] = ["homebrew/core"]) -> (DiscoverStore, CatalogInfoRunner) {
        let runner = CatalogInfoRunner()
        let client = makeClient(runner)
        let indexer = FixedIndexer(entries: names.map { TapIndexEntry(kind: .formula, name: $0.0, tap: "homebrew/core", desc: $0.1) },
                                   taps: taps)
        let detection = IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: client.sources)
        let catalog = TapCatalog(client: client, detection: detection, indexer: indexer)
        return (DiscoverStore(provider: catalog, debounce: .zero), runner)
    }

    @Test func searchesTheTapThenAsksBrewInfoForTheRows() async throws {
        let (d, runner) = store()
        await d.activate()
        #expect(d.isLocalTaps)
        #expect(d.source == "Local taps (homebrew/core) · 4 formulae")
        // Loading the index runs no brew at all.
        #expect(runner.log.calls.isEmpty)

        d.query = "compression"
        await d.searchNow()
        #expect(d.results.map(\.name) == ["xz", "zstd"])
        await d.waitForDetails()
        // One batch for the visible rows, fully qualified, formula kind.
        #expect(runner.log.calls == [["info", "--json=v2", "--formula", "homebrew/core/xz", "homebrew/core/zstd"]])
        let xz = try #require(d.results.first)
        #expect(xz.detailsLoaded)
        #expect(xz.version == "5.8.4")
        #expect(xz.bottle == .intelbrew)
        #expect(xz.badgeLabel == "Intelbrew bottle ✓")
        #expect(xz.desc == "General-purpose data compression with high compression ratio")

        // Asking again doesn't call brew again.
        d.needDetails(d.results.map(\.id))
        await d.waitForDetails()
        #expect(runner.log.calls.count == 1)
    }

    @Test func anUnloadableNameIsDroppedAndTheRestRetried() async throws {
        let (d, runner) = store()
        await d.activate()
        d.query = "o" // matches every name, ghost included
        await d.searchNow()
        await d.waitForDetails()
        #expect(runner.log.calls.count == 2)
        #expect(runner.log.calls[1].contains("homebrew/core/ghost") == false)
        let ghost = try #require(d.results.first { $0.name == "ghost" })
        #expect(ghost.detailsLoaded)
        #expect(ghost.bottle == .unknown)
        #expect(ghost.badgeLabel == "Unknown")
        #expect(d.results.first { $0.name == "python@3.15" }?.version == "3.15.2")
    }

    @Test func casksNoticeWithoutTheCaskTap() async {
        let (d, _) = store()
        await d.activate()
        #expect(d.casksNotice == "Casks aren't enabled: run `brew tap homebrew/cask` (about 620 MB)")
        let (withCasks, _) = store(taps: ["homebrew/cask", "homebrew/core"])
        await withCasks.activate()
        #expect(withCasks.casksNotice == nil)
    }

    @Test func debouncedQueryOnlySearchesTheLastValue() async {
        let runner = CatalogInfoRunner()
        let client = makeClient(runner)
        let catalog = TapCatalog(client: client, detection: IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: client.sources),
                                 indexer: FixedIndexer(entries: names.map { TapIndexEntry(kind: .formula, name: $0.0, tap: "homebrew/core", desc: $0.1) }))
        let d = DiscoverStore(provider: catalog, debounce: .milliseconds(80))
        await d.activate()
        d.query = "x"
        d.query = "xz"
        d.query = "zst"
        #expect(d.results.isEmpty) // not yet
        #expect(await waitUntil { d.resultsQuery == "zst" })
        #expect(d.results.map(\.name) == ["zstd"])
    }
}

// MARK: install and uninstall

@MainActor
struct InstallUninstallTests {
    func rig() async throws -> (AppStore, CallLog, URL) {
        let dir = try tempDir()
        let log = CallLog()
        let info = FakeInfoRunner(log: log, info: demoIntelInfo())
        let client = makeClient(info)
        let runner = FakeStreamRunner(log: log) { _, output in
            output(Data("ok\n".utf8))
            return 0
        }
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil,
                                         logURL: dir.appendingPathComponent("log"), hardware: .intel)
        let store = AppStore(deps: deps)
        await store.start()
        return (store, log, dir)
    }

    @Test func commandBuilding() throws {
        let e = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .intelbrew)
        #expect(BrewCommands.installArguments(for: e) == ["install", "--formula", "homebrew/core/xz"])
        #expect(e.installDisplay == "brew install --formula homebrew/core/xz")
        let c = CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: nil, bottle: .cask)
        #expect(c.installDisplay == "brew install --cask homebrew/cask/firefox")
        let t = CatalogEntry(kind: .formula, name: "thing", fullName: "someone/tools/thing", tap: "someone/tools", desc: nil, bottle: .unknown)
        #expect(BrewCommands.installArguments(for: t) == ["install", "--formula", "someone/tools/thing"])
        let p = c.asPackage()
        #expect(BrewCommands.uninstallArguments(for: p) == ["uninstall", "--cask", "homebrew/cask/firefox"])
        #expect(BrewCommands.arguments(.install, for: p) == ["install", "--cask", "homebrew/cask/firefox"])
    }

    @Test func installRunsThroughTheQueueAndReconciles() async throws {
        let (store, log, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = CatalogEntry(kind: .formula, name: "jq", fullName: "jq", tap: "homebrew/core", desc: "JSON", version: "1.8.1", bottle: .intelbrew)
        store.startInstall(e)
        let session = try #require(store.upgrade)
        #expect(session.action == .install)
        #expect(session.title == "Installing jq")
        #expect(session.subtitle == "1 bottle from Intelbrew")
        #expect(session.items[0].command.display == "brew install --formula homebrew/core/jq")
        #expect(session.items[0].command.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(session.items[0].command.environment[Intelbrew.noAPIKey] == "1")
        #expect(store.showUpgradeSheet)
        #expect(await waitUntil { session.isFinished })
        #expect(session.title == "Install complete")
        #expect(session.statusLine == "1 installed")
        #expect(log.calls.contains(["install", "--formula", "homebrew/core/jq"]))
        // Reconciled: status read again afterwards.
        #expect(await waitUntil { log.count("info") >= 2 })
    }

    @Test func installSubtitleSaysWhoseBottle() async throws {
        let (store, _, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = CatalogEntry(kind: .formula, name: "jq", fullName: "jq", tap: "homebrew/core", desc: nil, bottle: .forThisMac)
        store.startInstall(e)
        let session = try #require(store.upgrade)
        #expect(session.subtitle == "1 Homebrew bottle")
        #expect(await waitUntil { session.isFinished })
        let src = CatalogEntry(kind: .formula, name: "jo", fullName: "jo", tap: "homebrew/core", desc: nil, bottle: .fromSource)
        #expect(await waitUntil { !store.isRefreshing })
        store.closeUpgrade()
        store.startInstall(src)
        #expect(store.upgrade?.subtitle == "1 build from source (jo)")
    }

    @Test func installingSomethingInstalledIsANoOp() async throws {
        let (store, log, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xz = try #require(store.packages.first { $0.name == "xz" })
        let e = CatalogEntry(kind: .formula, name: "xz", fullName: "xz", tap: "homebrew/core", desc: nil, bottle: .intelbrew)
        #expect(store.installedIDs.contains(xz.id))
        store.startInstall(e)
        #expect(store.upgrade == nil)
        #expect(log.count("install") == 0)
    }

    @Test func dependentsBlockUninstall() async throws {
        let (store, log, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try #require(store.packages.first { $0.name == "ca-certificates" })
        let needs = store.dependents(of: ca).map(\.name)
        #expect(needs.contains("python@3.15"))
        store.requestUninstall(ca)
        #expect(store.uninstallCandidate?.id == ca.id)
        store.startUninstall(ca) // blocked: nothing runs
        #expect(store.uninstallCandidate == nil)
        #expect(store.upgrade == nil)
        #expect(log.count("uninstall") == 0)
    }

    @Test func uninstallALeaf() async throws {
        let (store, log, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vim = try #require(store.packages.first { $0.name == "vim" })
        #expect(store.dependents(of: vim).isEmpty)
        store.requestUninstall(vim)
        store.startUninstall(vim)
        let session = try #require(store.upgrade)
        #expect(session.title == "Uninstalling vim")
        #expect(await waitUntil { session.isFinished })
        #expect(session.title == "Uninstall complete")
        #expect(log.calls.contains(["uninstall", "--formula", "homebrew/core/vim"]))
    }

    @Test func discoverIsMadeOnDemandOnly() async throws {
        let (store, _, dir) = try await rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.discover == nil) // nothing at launch
        let d = try #require(store.openDiscover())
        #expect(d.isLocalTaps) // Intelbrew detected: local taps, not formulae.brew.sh
        #expect(d.phase == .idle) // made, but nothing loaded until activate()
        #expect(store.openDiscover() === d)
    }
}

// MARK: themes

@MainActor
struct AppearanceTests {
    func defaults() -> UserDefaults {
        let name = "tankard-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultIsSystemAndChoicePersists() {
        let d = defaults()
        let s = AppearanceSettings(defaults: d)
        #expect(s.theme == .system)
        var applied: [AppTheme] = []
        s.onChange = { applied.append($0) }
        s.theme = .tankard
        #expect(applied == [.tankard])
        #expect(d.string(forKey: AppearanceSettings.defaultsKey) == "tankard")
        #expect(AppearanceSettings(defaults: d).theme == .tankard)
        s.theme = .system
        #expect(AppearanceSettings(defaults: d).theme == .system)
    }

    @Test func overrideIsNotSaved() {
        let d = defaults()
        d.set("light", forKey: AppearanceSettings.defaultsKey)
        let s = AppearanceSettings(defaults: d, override: .tankard)
        #expect(s.theme == .tankard)
        #expect(d.string(forKey: AppearanceSettings.defaultsKey) == "light")
        d.set("nonsense", forKey: AppearanceSettings.defaultsKey)
        #expect(AppearanceSettings(defaults: d).theme == .system)
    }

    @Test func appearanceMapping() {
        #expect(AppTheme.dark.forcesDark == true)
        #expect(AppTheme.tankard.forcesDark == true)
        #expect(AppTheme.dracula.forcesDark == true)
        #expect(AppTheme(name: "Dracula") == .dracula)
        #expect(AppTheme.allCases.map(\.title) == ["Dark", "Light", "System", "Tankard", "Dracula"])
        #expect(AppTheme.light.forcesDark == false)
        #expect(AppTheme.system.forcesDark == nil)
        #expect(AppTheme(name: "TANKARD") == .tankard)
        #expect(AppTheme(name: "sepia") == nil)
    }

    @Test func tankardPaletteMeetsWCAGAA() {
        for (name, fg, bg) in TankardPalette.textPairs + StandardActionGreen.textPairs {
            let ratio = TankardPalette.contrast(fg, bg)
            #expect(ratio >= 4.5, "\(name): \(ratio)")
        }
        #expect(abs(TankardPalette.contrast(0xffffff, 0x000000) - 21) < 0.01)
        #expect(TankardPalette.blend(0xffffff, alpha: 0.5, over: 0x000000) == 0x808080)
        // Fills (the accent as button, picker and progress) against their
        // backgrounds: WCAG 1.4.11's 3:1 for non-text contrast.
        for (name, fg, bg) in TankardPalette.fillPairs + StandardActionGreen.fillPairs {
            let ratio = TankardPalette.contrast(fg, bg)
            #expect(ratio >= 3, "\(name): \(ratio)")
        }
        // Light's green carries white text with margin, not just at 4.5.
        #expect(TankardPalette.contrast(StandardActionGreen.onLight, StandardActionGreen.light) >= 4.8)
        #expect(TankardPalette.all.map(\.name).contains("dracula"))
        #expect(TankardPalette.palette(for: .dracula)?.name == "dracula")
        #expect(TankardPalette.palette(for: .tankard)?.name == TankardPalette.active.name)
        #expect(TankardPalette.palette(for: .dark) == nil)
    }

    /// The Installed/Available version columns: installed >= 7:1 and an
    /// unchanged Available >= 5.5:1 on rows and stripes, in Tankard (the
    /// active palette and the deep and L1 ones), Dracula, and the Dark and Light
    /// themes. L2 is held to AA (4.5:1) by the test above only.
    @Test func versionColumnsContrast() {
        var pairs = StandardVersionText.pairs
        for p in [TankardPalette.active, TankardPalette.deep, TankardPalette.lighter, TankardPalette.dracula] {
            pairs += TankardPalette.versionColumnPairs(p)
        }
        for (name, fg, bg, target) in pairs {
            let ratio = TankardPalette.contrast(fg, bg)
            #expect(ratio >= target, "\(name): \(ratio) < \(target)")
        }
    }
}

// MARK: welcome

final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.withLock { on } }
    func set(_ v: Bool) { lock.withLock { on = v } }
}

@MainActor
struct WelcomeTests {
    @Test func platformDetection() {
        #expect(MacHardware(machine: "x86_64", translated: false, arm64Capable: false).isIntel)
        // Intel binary under Rosetta on Apple silicon.
        #expect(!MacHardware(machine: "x86_64", translated: true, arm64Capable: true).isIntel)
        #expect(!MacHardware(machine: "x86_64", translated: false, arm64Capable: true).isIntel)
        #expect(!MacHardware(machine: "arm64", translated: false, arm64Capable: true).isIntel)
        #expect(HomebrewInstaller.options(for: .intel) == [.intelbrew, .homebrew])
        #expect(HomebrewInstaller.options(for: .appleSilicon) == [.homebrew])
        let rosetta = MacHardware(machine: "x86_64", translated: true, arm64Capable: true)
        #expect(HomebrewInstaller.options(for: rosetta) == [.homebrew])
    }

    @Test func commandScripts() throws {
        let ib = HomebrewInstaller.intelbrew.script
        let lines = ib.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "#!/bin/bash")
        #expect(lines.contains(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/d4rkwyng/intelbrew/main/install.sh)""#))
        #expect(lines.contains(#"echo "When it finishes, return to Tankard and click Check again.""#))
        #expect(!ib.contains("Homebrew/install"))
        let hb = HomebrewInstaller.homebrew.script
        #expect(hb.contains(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#))
        #expect(!hb.contains("intelbrew/main"))
        // Exactly one command besides the echoes.
        #expect(hb.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("echo") }.count == 1)

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try HomebrewInstaller.homebrew.writeScript(in: dir)
        #expect(url.lastPathComponent == "tankard-install-homebrew.command")
        #expect(try String(contentsOf: url, encoding: .utf8) == hb)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
    }

    @Test func welcomeUntilBrewAppearsThenMain() async throws {
        let found = Switch()
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let deps = AppStore.Dependencies(
            makeClient: {
                guard found.isOn else { throw BrewClientError.brewNotFound(searched: BrewInstallation.candidates) }
                return client
            },
            streamRunner: FakeStreamRunner(log: log) { _, _ in 0 }, cache: nil, logURL: nil, hardware: .intel)
        let store = AppStore(deps: deps)
        await store.start()
        #expect(store.homebrewState == .missing(searched: BrewInstallation.candidates))
        #expect(store.homebrewState.needsWelcome)
        #expect(store.report == nil)

        await store.checkAgain() // still nothing
        #expect(store.homebrewState.needsWelcome)

        found.set(true) // the user ran the installer
        await store.checkAgain()
        #expect(store.homebrewState == .ready)
        #expect(!store.homebrewState.needsWelcome)
        #expect(store.packages.count == 20)
    }

    @Test func brokenBrewShowsWhatItSaid() async throws {
        struct Broken: CommandRunning {
            func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
                ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: Homebrew's Ruby is missing\n".utf8))
            }
        }
        let client = makeClient(Broken())
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 },
                                         cache: nil, logURL: nil, hardware: .appleSilicon)
        let store = AppStore(deps: deps)
        await store.start()
        #expect(store.homebrewState == .broken(path: "/usr/local/bin/brew", detail: "Error: Homebrew's Ruby is missing"))
        #expect(store.homebrewState.needsWelcome)
    }

    @Test func aRefreshFailureWithWorkingBrewIsNotTheWelcome() async throws {
        // brew --version works, only `brew info` fails: keep the normal error banner.
        struct InfoFails: CommandRunning {
            func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
                arguments == ["--version"]
                    ? ProcessResult(exitCode: 0, stdout: Data("Homebrew 7.0.14\n".utf8), stderr: Data())
                    : ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: boom".utf8))
            }
        }
        let client = makeClient(InfoFails())
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: CallLog()) { _, _ in 0 },
                                         cache: nil, logURL: nil)
        let store = AppStore(deps: deps)
        await store.start()
        #expect(!store.homebrewState.needsWelcome)
        #expect(store.error?.title == "Refresh failed")
    }
}
