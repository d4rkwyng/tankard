import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.8: Uninstall lists the dependencies nothing would need any more, with
// "Also remove these" (on by default, as brew's own autoremove would remove
// them). On: each is uninstalled by name after the package; off: they stay.
// brew's autoremove stays off either way, so nothing else is removed.

@MainActor
struct UninstallOrphansTests {
    /// A store on the Intel demo, and a requested leaf with unneeded dependencies.
    func rig() async throws -> (AppStore, Package, [Package]) {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let p = try #require(store.packages.first {
            $0.kind == .formula && $0.requested && store.dependents(of: $0).isEmpty && !store.uninstallOrphans(of: $0).isEmpty
        })
        return (store, p, store.uninstallOrphans(of: p))
    }

    @Test func onRemovesThemByNameAfterThePackage() async throws {
        let (store, p, orphans) = try await rig()
        store.uninstallRemovesOrphans = false
        store.requestUninstall(p)
        #expect(store.uninstallRemovesOrphans) // every sheet starts on
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.name) == [p.name] + orphans.map(\.name))
        #expect(s.subtitle == "With the dependencies nothing else needs")
        #expect(s.items.allSatisfy { $0.command.environment[RestorePlan.noAutoremoveKey] == "1" })
        #expect(s.items.dropFirst().allSatisfy { $0.command.arguments.prefix(2) == ["uninstall", "--formula"] })
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(s.failedItems.isEmpty)
        #expect(await waitUntil { !store.isRefreshing })
        for o in orphans + [p] { #expect(!store.packages.contains { $0.id == o.id }, "\(o.name)") }
    }

    @Test func offKeepsThem() async throws {
        let (store, p, orphans) = try await rig()
        store.requestUninstall(p)
        store.uninstallRemovesOrphans = false
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.name) == [p.name])
        #expect(s.subtitle.hasPrefix("Its dependencies stay installed"))
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(await waitUntil { !store.isRefreshing })
        for o in orphans { #expect(store.packages.contains { $0.id == o.id }, "\(o.name)") }
    }

    @Test func aFailedUninstallSkipsTheDependencies() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log) { args, out in
            out(Data("Error: Permission denied @ unlink_internal\n".utf8))
            return 1
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        let p = try #require(store.packages.first {
            $0.kind == .formula && $0.requested && store.dependents(of: $0).isEmpty && !store.uninstallOrphans(of: $0).isEmpty
        })
        store.requestUninstall(p)
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(log.count("uninstall") == 1)   // only the package's own
        #expect(s.failedItems.map(\.package.name) == [p.name])
        #expect(s.items.dropFirst().allSatisfy { $0.state == .cancelled })
    }

    @Test func scriptStepChecksTheListAndTheOutcome() async throws {
        let (store, p, orphans) = try await rig()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = orphans.map(\.name).sorted().joined(separator: " ")
        let runner = ScriptRunner(store: store, steps: try ScriptParser.parse("""
            uninstall formula \(p.name) deps off \(names)
            """), outputDirectory: dir) { path in FileManager.default.createFile(atPath: path, contents: Data()) }
        let summary = await runner.run()
        #expect(summary.ok, "\(summary.failures)")
        for o in orphans { #expect(store.packages.contains { $0.id == o.id }) }
        // A wrong expectation fails the step.
        let wrong = ScriptRunner(store: store, steps: try ScriptParser.parse("""
            uninstall formula \(orphans[0].name) deps on not-a-dependency
            """), outputDirectory: dir) { path in FileManager.default.createFile(atPath: path, contents: Data()) }
        let bad = await wrong.run()
        #expect(!bad.ok)
    }
}
