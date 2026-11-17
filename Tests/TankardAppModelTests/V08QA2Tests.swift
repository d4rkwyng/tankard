import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8 QA round 2: the e2e harness's isolation, and the sheet waiting behind
// a background `brew update`.

struct APICacheRedirectTests {
    @Test func aScriptedRunKeepsDiscoversCacheInItsStateFolder() {
        let real = APICache.defaultDirectory
        #expect(real.path.hasSuffix("/Library/Caches/net.mindtricks.tankard/api"))
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-e2e-state/api", isDirectory: true)
        APICache.redirect(to: state)
        defer { APICache.redirect(to: nil) }
        #expect(APICache.defaultDirectory == state)
        // Discover's and Adopt Apps' fetchers use the default directory.
        #expect(APIFetcher().cache.directory == state)
    }
}

struct ScriptProcessCheckTests {
    /// `expect no-process` counts only the app's own descendants: another
    /// run's (or the user's) `brew vulns` isn't this run's leftover.
    @Test func onlyThisAppsDescendantsCount() {
        let ps = """
              1     0 /sbin/launchd
            100     1 /Applications/Tankard.app/Contents/MacOS/Tankard
            110   100 /bin/bash /opt/homebrew/bin/brew vulns --json
            111   110 /opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby brew.rb vulns --json
            200     1 /other/worktree/dist/Tankard.app/Contents/MacOS/Tankard
            210   200 /bin/bash /opt/homebrew/bin/brew vulns --json
            300     1 /bin/bash /opt/homebrew/bin/brew vulns --json
            120   100 /bin/ps -axww -o pid=,ppid=,command=
            """
        let mine = ScriptContext.processes(matching: " vulns --json", psOutput: ps, root: 100)
        #expect(mine.map { $0.split(separator: " ").first.map(String.init) ?? "" }.sorted() == ["110", "111"])
        #expect(ScriptContext.processes(matching: " vulns --json", psOutput: ps, root: 100, excluding: [111]).count == 1)
        #expect(ScriptContext.processes(matching: "-axww", psOutput: ps, root: 100, excluding: [120]).isEmpty)
        #expect(ScriptContext.processes(matching: " vulns --json", psOutput: ps, root: 999).isEmpty)
    }
}

@MainActor
struct WaitingForBrewUpdateTests {
    let base = ParallelLoadTests()

    /// HK-47: Upgrade clicked while the background `brew update` runs: the
    /// sheet says it is waiting for the update, then the usual lines.
    @Test func theSheetSaysItWaitsForTheBackgroundUpdate() async throws {
        let gate = Latch()
        let upgradeGate = Latch()
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            if args.first == "update" { await gate.wait() }
            if args.first == "upgrade" { await upgradeGate.wait() }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(!r.store.sessionWaitsForBrewUpdate)  // no sheet
        let bg = Task { await r.store.runBackgroundUpdate() }
        #expect(await waitUntil { r.stream.count("update") == 1 })
        let target = try #require(r.store.upgradable.first)
        r.store.startUpgrade([target])
        let session = try #require(r.store.upgrade)
        #expect(r.store.sessionWaitsForBrewUpdate)
        #expect(session.statusLine(behindBrewUpdate: r.store.sessionWaitsForBrewUpdate) == "Waiting for brew update to finish…")
        #expect(session.statusLine == "Waiting for brew…")  // without the update
        gate.release()
        _ = await bg.value
        // The update is done; the upgrade runs (held) and the line names it.
        #expect(await waitUntil { session.current != nil })
        #expect(!r.store.sessionWaitsForBrewUpdate)
        #expect(session.statusLine(behindBrewUpdate: r.store.sessionWaitsForBrewUpdate).contains(target.name))
        upgradeGate.release()
        #expect(await waitUntil { session.isFinished })
        #expect(!r.store.sessionWaitsForBrewUpdate)
        #expect(await waitUntil { !r.store.isRefreshing })
    }

    @Test func aSheetWithoutAnUpdateNeverSaysSo() async throws {
        let gate = Latch()
        let r = try await base.rig(backgroundUpdates: true, stream: { args, out in
            if args.first == "upgrade" { await gate.wait() }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let target = try #require(r.store.upgradable.first)
        r.store.startUpgrade([target])
        #expect(!r.store.sessionWaitsForBrewUpdate)
        gate.release()
        #expect(await waitUntil { !r.store.isUpgrading })
        #expect(await waitUntil { !r.store.isRefreshing })
    }
}

@MainActor
struct E2EBackgroundIntervalTests {
    let base = ParallelLoadTests()

    /// The e2e harness's seconds interval replaces Settings' hours, for the
    /// decision and for the checker's next look after a run; the count is
    /// what `expect-background-updates` reads.
    @Test func aSecondsIntervalMakesItDueAndCountsRuns() async throws {
        let r = try await base.rig(backgroundUpdates: true, backgroundInterval: 5)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: nil, launchedAt: Date().addingTimeInterval(-60))
        #expect(r.store.backgroundUpdateRuns == 0)
        let wait = await checker.tick()
        #expect(r.stream.count("update") == 1)
        #expect(r.store.backgroundUpdateRuns == 1)
        #expect(wait == 5)  // not Settings' hours
        // Inside the 5 s: not due; after it: due again.
        if case .notDue = r.store.backgroundUpdateDecision(launchedAt: .distantPast, now: Date()) {} else {
            Issue.record("expected notDue right after the update")
        }
        #expect(r.store.backgroundUpdateDecision(launchedAt: .distantPast, now: Date().addingTimeInterval(6)) == .run)
        // Without the override: hours, as before.
        let plain = try await base.rig(backgroundUpdates: true)
        defer { try? FileManager.default.removeItem(at: plain.dir) }
        await plain.store.start()
        await plain.store.insights.waitForIdle()
        let c2 = BackgroundChecker(store: plain.store, settings: plain.settings, notifier: nil, launchedAt: Date().addingTimeInterval(-60))
        #expect(await c2.tick() >= 3600)
    }
}

@MainActor
struct BackgroundUpdateAfterCachedLaunchTests {
    let base = ParallelLoadTests()

    /// A relaunch inside the status cache's hour shows the cache and reads
    /// no status (homebrewState stays .checking): the background update
    /// must still run. Before, it waited for .ready all session.
    @Test func aCachedLaunchStillUpdates() async throws {
        let cacheDir = try tempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let url = cacheDir.appendingPathComponent("status.json")
        let first = try await base.rig(backgroundUpdates: true, cacheURL: url)
        defer { try? FileManager.default.removeItem(at: first.dir) }
        await first.store.start()
        await first.store.insights.waitForIdle()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let r = try await base.rig(backgroundUpdates: true, backgroundInterval: 5, cacheURL: url)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        #expect(r.store.reportFromCache)
        #expect(r.store.homebrewState == .checking)
        #expect(r.store.backgroundUpdateDecision(launchedAt: .distantPast, now: Date()) == .run)
        let checker = BackgroundChecker(store: r.store, settings: r.settings, notifier: nil, launchedAt: Date().addingTimeInterval(-60))
        await checker.tick()
        #expect(r.stream.count("update") == 1)
        #expect(r.store.homebrewState == .ready)  // the re-read after it
        #expect(!r.store.reportFromCache)
    }
}
