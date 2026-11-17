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
    // MARK: review: the list is re-checked right before each dependency goes

    /// brew info JSON with `remove` gone and `onRequest` marked as installed on request.
    static func info(_ base: Data, remove: String, onRequest: String? = nil, pinned: String? = nil) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: base) as? [String: Any])
        var formulae = try #require(root["formulae"] as? [[String: Any]])
        formulae.removeAll { $0["name"] as? String == remove }
        for i in formulae.indices {
            let name = formulae[i]["name"] as? String
            if name == onRequest, var inst = formulae[i]["installed"] as? [[String: Any]], !inst.isEmpty {
                inst[0]["installed_on_request"] = true
                inst[0]["installed_as_dependency"] = false
                formulae[i]["installed"] = inst
            }
            if name == pinned { formulae[i]["pinned"] = true }
        }
        root["formulae"] = formulae
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// A box the fake brew reads once, from its first queued command.
    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func set(_ d: Data) { lock.withLock { data = d } }
        func take() -> Data? { lock.withLock { defer { data = nil }; return data } }
    }

    @Test func aDependencyInstalledOnRequestSinceIsKept() async throws {
        let log = CallLog()
        let infoRunner = FakeInfoRunner(log: log, info: demoIntelInfo())
        let client = makeClient(infoRunner)
        let pending = Pending()
        let runner = FakeStreamRunner(log: log) { _, _ in
            // The package's own uninstall: brew's state is now what the test set.
            if let next = pending.take() { infoRunner.info = next }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        let p = try #require(store.packages.first {
            $0.kind == .formula && $0.requested && store.dependents(of: $0).isEmpty && store.uninstallOrphans(of: $0).count >= 1
        })
        let orphans = store.uninstallOrphans(of: p)
        let kept = try #require(orphans.last)
        // In Terminal, after the sheet listed it: brew install <kept> (now on request).
        pending.set(try Self.info(infoRunner.info, remove: p.name, onRequest: kept.name))
        store.requestUninstall(p)
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(await waitUntil(timeout: .seconds(10)) { s.isFinished })
        #expect(s.failedItems.isEmpty)
        #expect(s.items.first { $0.package.id == kept.id }?.state == .skipped)
        #expect(s.items.filter { $0.package.id != kept.id }.allSatisfy { $0.state == .done })
        #expect(log.count("uninstall") == orphans.count) // the package and all but one dependency
        #expect(s.log.lines.contains { $0.contains("Kept \(kept.name): it is now installed on request") })
        #expect(s.statusLine.contains("1 skipped"))
    }

    @Test func recheckRules() throws {
        let base = demoIntelInfo()
        let classifier = StatusClassifier(platform: intelPlatform, intelbrewMode: true)
        func live(_ d: Data) throws -> [Package] { classifier.classify(info: try JSONDecoder().decode(BrewInfoJSON.self, from: d)) }
        let before = try live(base)
        let graph = DependencyGraph(before)
        let p = try #require(before.first {
            $0.kind == .formula && $0.requested && graph.dependents(of: $0).isEmpty && !graph.orphans(afterRemoving: [$0]).isEmpty
        })
        let o = try #require(graph.orphans(afterRemoving: [p]).last)
        // Still unneeded once p is gone: remove it.
        #expect(DependencyGraph.recheckOrphan(o, live: try live(try Self.info(base, remove: p.name))) == nil)
        // p still installed (its uninstall didn't happen): needed.
        #expect(DependencyGraph.recheckOrphan(o, live: before)?.hasPrefix("Kept \(o.name): still needed by") == true)
        #expect(DependencyGraph.recheckOrphan(o, live: try live(try Self.info(base, remove: p.name, onRequest: o.name)))?
            .contains("installed on request") == true)
        #expect(DependencyGraph.recheckOrphan(o, live: try live(try Self.info(base, remove: p.name, pinned: o.name)))?
            .contains("pinned") == true)
        #expect(DependencyGraph.recheckOrphan(o, live: try live(try Self.info(base, remove: o.name)))?
            .contains("no longer installed") == true)
    }
}
