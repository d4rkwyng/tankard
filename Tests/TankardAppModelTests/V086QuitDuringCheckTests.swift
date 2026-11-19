import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (HK-47 review, item 4): while "Checking what brew upgraded…" no step
// is running or waiting, so ⌘Q quits without asking, and the run journal
// (saved with every target when the run started) was only updated when the
// run finished: the next launch offered to resume a run that had ended. Every
// step has run once the check starts, so the journal is settled then.
@MainActor
struct V086QuitDuringCheckTests {
    /// Holds `brew info --installed` reads while `held` is set.
    final class GatedRunner: CommandRunning, @unchecked Sendable {
        let inner: CommandRunning
        let gate = Latch()
        private let lock = NSLock()
        private var _held = false
        var held: Bool {
            get { lock.withLock { _held } }
            set { lock.withLock { _held = newValue } }
        }
        init(_ inner: CommandRunning) { self.inner = inner }
        func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
            if held, arguments.contains("--installed") { await gate.wait() }
            return try await inner.run(executable, arguments, environment: environment)
        }
    }

    @Test func theJournalIsSettledWhenTheCheckStarts() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        var client = try deps.makeClient()
        let gated = GatedRunner(client.runner)
        client.runner = gated
        let fixed = client
        deps.makeClient = { fixed }
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, out in
            out(Data("Error: other: the dependency lz4 is pinned\n".utf8))
            return 1
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let p = try #require(store.upgradable.first { store.deps.classifier.upgradeWarning($0) == nil })
        gated.held = true
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(store.settings.defaults.data(forKey: RunJournal.key) != nil) // saved when it starts
        #expect(await waitUntil { s.checkingUpgraded })
        #expect(store.quitPrompt == nil)
        // A quit now ends Tankard without asking: nothing may be offered at
        // the next launch.
        #expect(store.settings.defaults.data(forKey: RunJournal.key) == nil)
        gated.held = false
        gated.gate.release()
        #expect(await waitUntil { s.isFinished })
        #expect(store.settings.defaults.data(forKey: RunJournal.key) == nil)
    }
}
