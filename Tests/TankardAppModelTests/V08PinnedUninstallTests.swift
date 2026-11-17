import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.8 fix from the e2e pass: uninstalling a pinned package. brew refuses
// it and still exits 0, so Tankard said "Uninstall complete" while nothing
// changed.

@MainActor
struct PinnedUninstallTests {
    /// A requested formula nothing depends on, in the Intel demo.
    func leaf(_ store: AppStore) throws -> Package {
        try #require(store.packages.first { $0.kind == .formula && $0.requested && store.dependents(of: $0).isEmpty })
    }

    @Test func brewsPinnedRefusalIsRecognised() {
        // brew 7.0.14: uninstall.rb:62, cask/uninstall.rb:65, cmd/reinstall.rb:164/181 (onoe, exit 0).
        #expect(BrewRefusal.pinned(["Error: hello is pinned. You must unpin it to uninstall."]))
        #expect(BrewRefusal.pinned(["Error: homebrew/cask/anybar is pinned. You must unpin it to uninstall."]))
        #expect(BrewRefusal.pinned(["==> x", "Error: xz is pinned. You must unpin it to reinstall."]))
        #expect(!BrewRefusal.pinned(["Uninstalling /usr/local/Cellar/hello/2.12.2... (11 files, 289KB)"]))
        #expect(!BrewRefusal.pinned(["Pinned formulae are not upgraded"]))
        #expect(!BrewRefusal.pinned([String]()))
    }

    @Test func uninstallOfAPinnedPackageRunsNothing() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let p = try leaf(store)
        let store2 = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0, pinned: [p.name]), settings: testSettings())
        await store2.start()
        let pinned = try #require(store2.packages.first { $0.id == p.id })
        #expect(pinned.pinned)
        store2.requestUninstall(pinned)
        #expect(store2.uninstallCandidate?.id == pinned.id)
        store2.startUninstall(pinned)
        #expect(store2.uninstallCandidate == nil)
        #expect(store2.upgrade == nil)
        #expect(store2.appManagementPrompt == nil)
    }

    @Test func unpinAndUninstallUnpinsThroughTheQueueThenUninstalls() async throws {
        let probe = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await probe.start()
        let name = try leaf(probe).name
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0, pinned: [name]), settings: testSettings())
        await store.start()
        let p = try #require(store.packages.first { $0.name == name })
        store.requestUninstall(p)
        store.unpinAndUninstall(p)
        #expect(store.uninstallCandidate == nil)
        #expect(await waitUntil(timeout: .seconds(10)) { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        #expect(session.action == .uninstall)
        #expect(session.items.map(\.package.name) == [name])
        #expect(session.items.first?.package.pinned == false) // the re-read package, not the stale one
        #expect(session.failedItems.isEmpty)
        #expect(await waitUntil { !store.isRefreshing && !store.packages.contains { $0.name == name } })
        #expect(store.error == nil)
        // History: the unpin, then the uninstall.
        let cmds = store.history.entries.map(\.command)
        #expect(cmds.contains { $0.hasPrefix("brew unpin --formula") && $0.hasSuffix("/" + name) })
        #expect(cmds.contains { $0.contains("brew uninstall") && $0.hasSuffix("/" + name) })
    }

    @Test func unpinFailureStopsBeforeTheUninstall() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { args, out in
            if args.first == "unpin" { out(Data("Error: No such keg\n".utf8)); return 1 }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        var p = try leaf(store)
        p.pinned = true // the fixture has nothing pinned; the sheet only asks for a pinned one
        store.unpinAndUninstall(p)
        #expect(await waitUntil { store.error != nil && store.quickAction == nil })
        #expect(store.error?.title == "Unpin \(p.name) failed (exit 1)")
        #expect(log.count("uninstall") == 0)
        #expect(store.upgrade == nil)
    }

    /// Defensive: if a pinned package's uninstall reaches brew anyway, its
    /// "is pinned" message with exit 0 is a failure, in the sheet and History.
    @Test func brewsExitZeroRefusalIsAFailure() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { args, out in
            if args.first == "uninstall" { out(Data("Error: \(args.last ?? "") is pinned. You must unpin it to uninstall.\n".utf8)) }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        let p = try leaf(store)
        store.startSession(.uninstall, packages: [p], skipGate: true)
        let session = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { session.isFinished })
        #expect(session.failedItems.map(\.package.name) == [p.name])
        #expect(session.title == "Uninstall finished with errors")
        #expect(session.log.lines.contains { $0.contains("is pinned (brew still exited 0)") })
        #expect(await waitUntil { store.history.entries.contains { $0.command.contains("uninstall") } })
        let entry = try #require(store.history.entries.first { $0.command.contains("uninstall") })
        #expect(entry.outcome == .failed)
        #expect(entry.outputTail.contains { $0.contains("is pinned") })
        // A normal exit 0 is still done.
        let ok = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await ok.start()
        let q = try leaf(ok)
        ok.startUninstall(q)
        let s2 = try #require(ok.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s2.isFinished })
        #expect(s2.failedItems.isEmpty)
    }

    @Test func pinnedScriptStepsPassInTheDemo() async throws {
        let probe = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await probe.start()
        let name = try leaf(probe).name
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let runner = ScriptRunner(store: store, steps: try ScriptParser.parse("""
            pin \(name)
            uninstall formula \(name)
            """), outputDirectory: dir) { path in FileManager.default.createFile(atPath: path, contents: Data()) }
        let blocked = await runner.run()
        #expect(blocked.failures.first?.contains("is pinned") == true)
        #expect(store.packages.contains { $0.name == name })

        let runner2 = ScriptRunner(store: store, steps: try ScriptParser.parse("""
            uninstall-blocked formula \(name) pinned
            expect pinned \(name)
            unpin-uninstall formula \(name)
            expect not-installed \(name)
            """), outputDirectory: dir) { path in FileManager.default.createFile(atPath: path, contents: Data()) }
        let summary = await runner2.run()
        #expect(summary.ok, "\(summary.failures)")
        #expect(summary.passed == 4)
    }
}
