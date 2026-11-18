import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3: one `brew fetch` (brew 7's parallel download queue) before a
// multi-package upgrade or install; then the per-package steps as before.

@MainActor
struct PrefetchTests {
    // MARK: what gets fetched

    func formula(_ name: String, bottle: Bool = true, pinned: Bool = false) -> Package {
        var p = Package.command(name)
        p.id = "formula:homebrew/core/\(name)"
        p.kind = .formula
        p.fullName = name
        p.tap = "homebrew/core"
        p.upgradeHasBottle = bottle
        p.pinned = pinned
        return p
    }

    func cask(_ name: String, version: String = "1.0") -> Package {
        var p = Package.command(name)
        p.id = "cask:homebrew/cask/\(name)"
        p.kind = .cask
        p.fullName = name
        p.tap = "homebrew/cask"
        p.currentVersion = version
        return p
    }

    @Test func planIsOneFetchPerKindWithTwoOrMore() {
        let pkgs = [formula("xz"), cask("rectangle"), formula("ruby", bottle: false), formula("sqlite"),
                    formula("wget", pinned: true), cask("maccy"), cask("chrome", version: "latest")]
        let plan = Prefetch.plan(.upgrade, pkgs)
        #expect(plan.map(\.arguments) == [
            ["fetch", "--formula", "homebrew/core/xz", "homebrew/core/sqlite"],
            ["fetch", "--cask", "homebrew/cask/rectangle", "homebrew/cask/maccy"],
        ])
        #expect(plan.map { $0.targets.map(\.name) } == [["xz", "sqlite"], ["rectangle", "maccy"]])
        // Installs too (a Brewfile's missing packages).
        #expect(Prefetch.plan(.install, pkgs).count == 2)
    }

    @Test func noFetchForOneOfAKindOrOtherActions() {
        // One formula and one cask: each would be a queue of one.
        #expect(Prefetch.plan(.upgrade, [formula("xz"), cask("rectangle")]).isEmpty)
        // Only one bottle among them (the other compiles).
        #expect(Prefetch.plan(.upgrade, [formula("xz"), formula("ruby", bottle: false)]).isEmpty)
        // A single package keeps today's path.
        #expect(Prefetch.plan(.upgrade, [formula("xz")]).isEmpty)
        // Duplicates count once.
        #expect(Prefetch.plan(.upgrade, [formula("xz"), formula("xz")]).isEmpty)
        for a in [SessionAction.uninstall, .replaceBottle, .cleanup, .autoremove, .tap, .untap, .restore, .adopt] {
            #expect(Prefetch.plan(a, [formula("xz"), formula("sqlite")]).isEmpty)
        }
        // Placeholder rows (brew cleanup) never.
        #expect(!Prefetch.fetchable(Package.command("brew cleanup")))
    }

    @Test func usersDownloadConcurrencyIsPassedThrough() {
        #expect(Prefetch.environment(nil).isEmpty)
        #expect(Prefetch.environment(EnvironmentSources(process: [:])).isEmpty)
        let shell = EnvironmentSources(process: [:], shellProfiles: [("~/.zshrc", ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"])])
        #expect(Prefetch.environment(shell) == ["HOMEBREW_DOWNLOAD_CONCURRENCY": "1"])
        let empty = EnvironmentSources(process: ["HOMEBREW_DOWNLOAD_CONCURRENCY": ""])
        #expect(Prefetch.environment(empty).isEmpty)
    }

    @Test func brewfilePackagesSayWhetherTheyCompile() {
        let plan = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .formula, name: "xz"),
                                                 BrewfileEntry(kind: .formula, name: "ruby"),
                                                 BrewfileEntry(kind: .cask, name: "maccy")],
                                       path: "/tmp/Brewfile", compiles: ["xz": false, "ruby": true])
        let pkgs = plan.packages()
        #expect(pkgs.map(\.upgradeHasBottle) == [true, false, nil])
    }

    // MARK: counting from brew's output

    @Test func countsFinishedFilesFromParallelOutput() {
        // Real brew 7.0.14 output on a pipe (Mac mini, 2026-11-17).
        let lines = """
        Fetching: hugo, pandoc, fd, bat
        ==> Fetching hugo from homebrew/core
        ✔︎ Bottle Manifest hugo (0.170.1)
        ✔︎ Bottle Manifest fd (10.5.2)
        ✔︎ Bottle bat (0.26.1)
        ✔︎ Bottle hugo (0.170.1)
        """.split(separator: "\n").map(String.init)
        #expect(FetchOutput.finished(lines) == 2)
        let casks = """
        Fetching: tankard-pfetch-missing, tankard-pfetch-ok, rectangle
        ✘ Cask tankard-pfetch-missing (1.0)
        Error: Download failed on Cask 'tankard-pfetch-missing' with message: Download failed: http://127.0.0.1:18765/missing.zip
        curl: (22) The requested URL returned error: 404
        ✔︎ Cask rectangle (2.0.4)
        ✔︎ Cask tankard-pfetch-ok (1.0)
        """.split(separator: "\n").map(String.init)
        #expect(FetchOutput.finished(casks) == 3)
        #expect(FetchOutput.finished(["✔︎ Formula tankard-pfetch-src (1.0)"]) == 1)
    }

    @Test func countsFinishedFilesFromSerialOutput() {
        // HOMEBREW_DOWNLOAD_CONCURRENCY=1: brew's older one-at-a-time lines.
        let lines = """
        ==> Downloading https://ghcr.io/v2/homebrew/core/hugo/manifests/0.170.1
        Downloaded to: /c/downloads/f1a6--hugo-0.170.1.bottle_manifest.json
        ==> Downloading https://ghcr.io/v2/homebrew/core/hugo/blobs/sha256:8322
        Downloaded to: /c/downloads/40e1--hugo--0.170.1.arm64_golden_gate.bottle.tar.gz
        """.split(separator: "\n").map(String.init)
        #expect(FetchOutput.finished(lines) == 1)
    }

    // MARK: the sheet session

    struct Rig {
        var store: AppStore
        var log: CallLog
        var dir: URL
    }

    /// The demo-tweaked Intel fixture: 5 formula upgrades, 4 with a bottle
    /// (openssl@4, python@3.15, sqlite, xz) and ruby from source.
    func rig(stream: @escaping @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32) throws -> Rig {
        let dir = try tempDir()
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: stream)
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil,
                                         logURL: dir.appendingPathComponent("Logs/upgrade.log"), ttl: 3600, now: { Date() })
        return Rig(store: AppStore(deps: deps), log: log, dir: dir)
    }

    static let bottles = ["homebrew/core/openssl@4", "homebrew/core/python@3.15", "homebrew/core/sqlite", "homebrew/core/xz"]

    @Test func upgradeAllFetchesFirstThenUpgradesOneByOne() async throws {
        let r = try rig { args, out in
            if args.first == "fetch" {
                for n in args.dropFirst(2) { out(Data("✔︎ Bottle \(n.split(separator: "/").last!) (1)\n".utf8)) }
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.isFinished })
        let brew = r.log.calls.filter { $0.first == "fetch" || $0.first == "upgrade" }
        #expect(brew.first == ["fetch", "--formula"] + Self.bottles)
        #expect(brew.dropFirst().map(\.first) == Array(repeating: "upgrade", count: 5))
        #expect(s.items.allSatisfy { $0.state == .done })
        #expect(s.fetchedCount == 4 && s.fetchTotal == 4)
        #expect(s.statusLine == "5 upgraded")
        let fetch = try #require(s.prefetch.first?.command)
        #expect(fetch.display == "brew fetch --formula " + Self.bottles.joined(separator: " "))
        #expect(fetch.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(fetch.environment["HOMEBREW_CORE_GIT_REMOTE"] == Intelbrew.coreRemote)
        #expect(fetch.environment == s.items[0].command.environment.filter { $0.key != RollbackSettings.noInstallCleanupKey })
        // The live log and the log file show the fetch like any step.
        #expect(s.log.lines.first == "$ " + fetch.display)
        let text = try String(contentsOf: r.dir.appendingPathComponent("Logs/upgrade.log"), encoding: .utf8)
        #expect(text.contains("$ brew fetch --formula"))
    }

    @Test func singleUpgradeHasNoFetch() async throws {
        let r = try rig { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade(r.store.upgradable.filter { $0.name == "xz" })
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.isFinished })
        #expect(r.log.count("fetch") == 0)
        #expect(s.prefetch.isEmpty)
        #expect(r.log.count("upgrade") == 1)
    }

    @Test func failedFetchStillRunsEveryUpgradeAndTheFailedOneFailsVisibly() async throws {
        let r = try rig { args, out in
            if args.first == "fetch" {
                out(Data("✔︎ Bottle openssl@4 (4)\n✘ Bottle sqlite (3)\nError: sqlite: Failed to download resource\ncurl: (22) The requested URL returned error: 404\n".utf8))
                out(Data("✔︎ Bottle python@3.15 (3.15)\n✔︎ Bottle xz (5)\n".utf8))
                return 1
            }
            if args.last == "homebrew/core/sqlite" {
                out(Data("curl: (22) The requested URL returned error: 404\nError: sqlite: Failed to download resource\n".utf8))
                return 1
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.isFinished })
        #expect(r.log.count("upgrade") == 5)
        #expect(s.failedItems.map(\.package.name) == ["sqlite"])
        #expect(s.succeededCount == 4)
        #expect(s.title == "Upgrade finished with problems")
        #expect(s.statusLine == "4 upgraded, 1 failed")
        #expect(s.log.lines.contains { $0.hasPrefix("tankard: brew fetch exited with status 1") })
        // brew's own error, from the fetch and again from sqlite's step.
        #expect(s.log.lines.filter { $0.contains("returned error: 404") }.count == 2)
        #expect(s.fetchStates.values.allSatisfy { $0 == .failed(1) })
    }

    @Test func stopNowDuringFetchKillsItAndRunsNothing() async throws {
        let r = try rig { args, out in
            if args.first == "fetch" {
                out(Data("Fetching: openssl@4, python@3.15, sqlite, xz\n".utf8))
                try await sleepUntilCancelled()
            }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.isFetching })
        #expect(s.current == nil)
        #expect(s.runningFetch?.arguments.first == "fetch")
        s.stopAfterCurrent()
        s.stopNow()
        #expect(await waitUntil { s.isFinished })
        #expect(r.log.count("upgrade") == 0)
        #expect(s.items.allSatisfy { $0.state == .cancelled })
        #expect(s.fetchStates.values.allSatisfy { $0 == .cancelled })
        #expect(s.log.lines.contains("tankard: Stopped."))
        #expect(s.title == "Upgrade stopped")
    }

    @Test func stopAfterCurrentDuringFetchLetsItFinishAndSkipsTheUpgrades() async throws {
        let gate = Latch()
        let r = try rig { args, _ in
            if args.first == "fetch" { await gate.wait() }
            return 0
        }
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        r.store.startUpgrade()
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.isFetching })
        s.stopAfterCurrent()
        gate.release()
        #expect(await waitUntil { s.isFinished })
        #expect(r.log.count("fetch") == 1)
        #expect(r.log.count("upgrade") == 0)
        #expect(s.fetchStates.values.allSatisfy { $0 == .done })
        #expect(s.items.allSatisfy { $0.state == .cancelled })
        #expect(s.title == "Upgrade stopped")
    }

    @Test func secondFetchIsSkippedByStopAfterCurrent() async throws {
        // Formulae and casks: two fetches; Stop After Current during the first.
        let gate = Latch()
        let log = CallLog()
        let runner = FakeStreamRunner(log: log) { args, _ in
            if args.first == "fetch" && args.contains("--formula") { await gate.wait() }
            return 0
        }
        let s = UpgradeSession(packages: [formula("xz"), formula("sqlite"), cask("rectangle"), cask("maccy")],
                               intelbrewMode: false, action: .upgrade, queue: CommandQueue(runner: runner),
                               makeCommand: { p in Self.command(BrewCommands.upgradeArguments(for: p)) }, logURL: nil,
                               prefetch: Prefetch.steps(.upgrade, [formula("xz"), formula("sqlite"), cask("rectangle"), cask("maccy")],
                                                        make: Self.command),
                               onFinish: { _ in })
        #expect(s.prefetch.count == 2)
        #expect(await waitUntil { s.isFetching })
        s.stopAfterCurrent()
        gate.release()
        #expect(await waitUntil { s.isFinished })
        #expect(log.calls.map { Array($0.prefix(2)) } == [["fetch", "--formula"]])
        #expect(s.fetchStates.values.sorted { "\($0)" < "\($1)" } == [.cancelled, .done])
    }

    nonisolated static func h(_ c: Character) -> String { String(repeating: c, count: 64) }

    nonisolated static func manifest(_ v: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["manifests": [
            ["annotations": ["org.opencontainers.image.ref.name": "\(v).arm64_tahoe", "sh.brew.bottle.size": "100000000"]],
        ]])
    }

    nonisolated static func command(_ args: [String]) -> QueuedCommand {
        QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: args, environment: [:], display: BrewCommands.display(args))
    }

    // MARK: progress

    @Test func fetchPhaseShowsCombinedCountAndBytes() async throws {
        let folder = GrowingFolder(modified: Date())
        let first = Latch(), second = Latch(), third = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "fetch" else { return 0 }
            out(Data("Fetching: xz, sqlite\n".utf8))
            folder.set(Self.h("a") + "--xz-5.8.bottle_manifest.json", size: 1, data: Self.manifest("5.8"))
            folder.set(Self.h("b") + "--sqlite-3.50.bottle_manifest.json", size: 1, data: Self.manifest("3.50"))
            folder.set(Self.h("c") + "--xz--5.8.arm64_tahoe.bottle.tar.gz.incomplete", size: 60_000_000)
            folder.set(Self.h("d") + "--sqlite--3.50.arm64_tahoe.bottle.tar.gz.incomplete", size: 60_000_000)
            await first.wait()
            folder.rename(Self.h("c") + "--xz--5.8.arm64_tahoe.bottle.tar.gz.incomplete", Self.h("c") + "--xz--5.8.arm64_tahoe.bottle.tar.gz")
            out(Data("✔︎ Bottle Manifest xz (5.8)\n✔︎ Bottle xz (5.8)\n".utf8))
            await second.wait()
            folder.rename(Self.h("d") + "--sqlite--3.50.arm64_tahoe.bottle.tar.gz.incomplete", Self.h("d") + "--sqlite--3.50.arm64_tahoe.bottle.tar.gz")
            out(Data("✔︎ Bottle sqlite (3.50)\n".utf8))
            await third.wait()
            return 0
        }
        let monitor = DownloadMonitor(directory: { "/cache/downloads" }, reader: folder, interval: .milliseconds(5),
                                      now: { folder.modified })
        let pkgs = [formula("xz"), formula("sqlite")]
        let s = UpgradeSession(packages: pkgs, intelbrewMode: false, action: .upgrade, queue: CommandQueue(runner: runner),
                               makeCommand: { p in Self.command(BrewCommands.upgradeArguments(for: p)) }, logURL: nil,
                               downloads: monitor, prefetch: Prefetch.steps(.upgrade, pkgs, make: Self.command),
                               onFinish: { _ in })
        // Both downloading: 120 of 200 MB, none finished yet.
        #expect(await waitUntil { s.download?.total == 200_000_000 })
        #expect(s.download?.bytes == 120_000_000 && s.download?.files == 2)
        #expect(s.statusLine.hasPrefix("Downloading 0 of 2 · "))
        #expect(s.statusLine.contains("120.0") && s.statusLine.contains("200.0") && s.statusLine.contains("60%"))
        #expect(s.countLine == "0 of 2")
        first.release()
        #expect(await waitUntil { s.fetchedCount == 1 })
        #expect(await waitUntil { s.statusLine.hasPrefix("Downloading 1 of 2 · ") })
        second.release()
        #expect(await waitUntil { s.fetchedCount == 2 && s.download == nil })
        #expect(s.statusLine == "Downloading 2 of 2…")
        #expect(s.fraction == 1)
        third.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.statusLine == "2 upgraded")
        #expect(s.download == nil)
    }

    // MARK: auto-update

    @Test func autoUpdatePrefetchesQuietlyBeforeItsUpgrades() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        deps.logURL = dir.appendingPathComponent("upgrade.log")
        let envs = EnvLog()
        deps.streamRunner = RecordingRunner(inner: deps.streamRunner, log: envs)
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: nil))
        let calls = envs.calls.filter { $0.0.first == "fetch" || $0.0.first == "upgrade" }
        #expect(calls.first?.0 == ["fetch", "--formula", "homebrew/core/openssl@4", "homebrew/core/python@3.15",
                                   "homebrew/core/sqlite", "homebrew/core/xz"])
        #expect(calls.first?.1["HOMEBREW_NO_AUTO_UPDATE"] == "1" && calls.first?.1["HOMEBREW_NO_ASK"] == "1")
        #expect(calls.dropFirst().allSatisfy { $0.0.first == "upgrade" } && calls.count == 5)
        #expect(run.upgraded.count == 4)
        // Quietly: in the log file, not in the run's record.
        let text = try String(contentsOf: dir.appendingPathComponent("upgrade.log"), encoding: .utf8)
        #expect(text.contains("$ brew fetch --formula homebrew/core/openssl@4"))
        #expect(text.contains("✔︎ Bottle xz"))
        #expect(run.failed.isEmpty)
    }
}
