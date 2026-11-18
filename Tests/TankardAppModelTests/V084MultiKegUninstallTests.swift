import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4 fix from the 0.8.3 test pass (F1): a formula with two kegs (after
// an upgrade with "Keep the previous version", or a rollback). Plain
// `brew uninstall --formula X` removed only one, printed "X 1.0 is still
// installed" and exited 0, and Tankard said "Uninstall complete".

/// `brew info --json=v2 --installed` with `name`'s kegs replaced:
/// `versions` (the last one linked), or the formula left out when empty.
func infoWithKegs(_ data: Data, name: String, versions: [String], pinned: Bool? = nil) throws -> Data {
    // Plain throws, not #require: rigs call this outside a test's own flow.
    struct NotFound: Error {}
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var formulae = root["formulae"] as? [[String: Any]],
          let i = formulae.firstIndex(where: { $0["name"] as? String == name }) else { throw NotFound() }
    if versions.isEmpty {
        formulae.remove(at: i)
    } else {
        var f = formulae[i]
        guard let first = (f["installed"] as? [[String: Any]])?.first else { throw NotFound() }
        f["installed"] = versions.map { v -> [String: Any] in
            var k = first
            k["version"] = v
            return k
        }
        f["linked_keg"] = versions.last
        if let pinned { f["pinned"] = pinned }
        formulae[i] = f
    }
    root["formulae"] = formulae
    return try JSONSerialization.data(withJSONObject: root)
}

@MainActor
struct V084MultiKegUninstallTests {
    /// A requested formula nothing depends on and that leaves no orphans.
    static func leafName() async throws -> String {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        return try #require(store.packages.first {
            $0.kind == .formula && $0.requested && store.dependents(of: $0).isEmpty && store.uninstallOrphans(of: $0).isEmpty
        }).name
    }

    /// A store on the Intel fixture where `name` has kegs 1.0 and 1.1;
    /// `uninstall` answers each `brew uninstall` (the info runner's state
    /// can be changed from it).
    func store(name: String, versions: [String] = ["1.0", "1.1"], pinned: Bool? = nil, log: CallLog,
               uninstall: @escaping @Sendable (FakeInfoRunner, Int, @escaping @Sendable (Data) -> Void) async throws -> Int32,
               unpin: (@Sendable (FakeInfoRunner) -> Void)? = nil) async throws -> (AppStore, FakeInfoRunner) {
        let info = FakeInfoRunner(log: log, info: try infoWithKegs(demoIntelInfo(), name: name, versions: versions, pinned: pinned))
        let client = makeClient(info)
        let count = CallLog()
        let runner = FakeStreamRunner(log: log) { args, out in
            if args.first == "uninstall" {
                count.add(args)
                return try await uninstall(info, count.calls.count, out)
            }
            if args.first == "unpin" { unpin?(info) }
            return 0
        }
        let store = AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil),
                             settings: testSettings())
        await store.start()
        return (store, info)
    }

    // MARK: pure

    @Test func stillInstalledLinesAreParsed() {
        // brew 7.0.14 uninstall.rb:86-90 with Utils::Text.to_sentence.
        #expect(BrewRefusal.stillInstalled(["Uninstalling /opt/homebrew/Cellar/probe/1.1... (3 files, 4KB)",
                                            "probe 1.0 is still installed.",
                                            "To remove all versions, run:", "  brew uninstall --force probe"], name: "probe") == ["1.0"])
        #expect(BrewRefusal.stillInstalled(["probe 1.0 and 1.1 are still installed."], name: "probe") == ["1.0", "1.1"])
        #expect(BrewRefusal.stillInstalled(["probe 0.9, 1.0 and 1.1 are still installed."], name: "probe") == ["0.9", "1.0", "1.1"])
        #expect(BrewRefusal.stillInstalled(["probe-two 1.0 is still installed."], name: "probe") == nil)
        #expect(BrewRefusal.stillInstalled(["Uninstalling /opt/homebrew/Cellar/probe/1.1... (3 files, 4KB)"], name: "probe") == nil)
        #expect(BrewRefusal.stillInstalled([String](), name: "probe") == nil)
    }

    @Test func oneStepPerInstalledVersionOfAFormula() {
        var f = Package.command("probe")
        f.kind = .formula
        f.installedVersions = ["1.0", "1.1"]
        var one = f
        one.installedVersions = ["1.1"]
        var none = f
        none.installedVersions = []
        var cask = f
        cask.kind = .cask
        #expect(AppStore.uninstallSteps([f]).count == 2)
        #expect(AppStore.uninstallSteps([one]).count == 1)
        #expect(AppStore.uninstallSteps([none]).count == 1)
        #expect(AppStore.uninstallSteps([cask]).count == 1)
        #expect(AppStore.uninstallSteps([f, one]).map(\.installedVersions.count) == [2, 2, 1])
        // The command shown runs once per version.
        #expect(AppStore.uninstallDisplay(f).split(separator: "\n").count == 2)
        #expect(AppStore.uninstallDisplay(one).split(separator: "\n").count == 1)
    }

    @Test func confirmationSaysEveryVersionGoes() {
        var f = Package.command("probe")
        f.kind = .formula
        f.installedVersion = "1.10"
        f.installedVersions = ["1.10", "1.9"]
        #expect(AppStore.uninstallSummary(f, dependenciesStay: true)
                == "Removes all installed versions of probe (1.9, 1.10). Its dependencies stay installed.")
        #expect(AppStore.uninstallSummary(f, dependenciesStay: false) == "Removes all installed versions of probe (1.9, 1.10).")
        f.installedVersions = ["1.10"]
        #expect(AppStore.uninstallSummary(f, dependenciesStay: true) == "Removes probe 1.10. Its dependencies stay installed.")
        #expect(AppStore.uninstallSummary(f, dependenciesStay: false) == "Removes probe 1.10.")
    }

    // MARK: the store

    @Test func twoKegsTwoUninstallsThenComplete() async throws {
        let name = try await Self.leafName()
        let log = CallLog()
        let (store, _) = try await store(name: name, log: log) { info, n, out in
            if n == 1 {
                out(Data("Uninstalling /usr/local/Cellar/\(name)/1.1... (3 files, 4KB)\n\(name) 1.0 is still installed.\nTo remove all versions, run:\n  brew uninstall --force \(name)\n".utf8))
                info.info = try infoWithKegs(demoIntelInfo(), name: name, versions: ["1.0"])
            } else {
                out(Data("Uninstalling /usr/local/Cellar/\(name)/1.0... (3 files, 4KB)\n".utf8))
                info.info = try infoWithKegs(demoIntelInfo(), name: name, versions: [])
            }
            return 0
        }
        let p = try #require(store.packages.first { $0.name == name })
        #expect(p.installedVersions.count == 2)
        store.requestUninstall(p)
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(s.items.count == 2)
        #expect(s.packages.map(\.name) == [name])
        #expect(s.title == "Uninstalling \(name)")
        #expect(await waitUntil { s.isFinished && !s.checkingInstalled })
        // Plain uninstall each time: never --force.
        let uninstalls = log.calls.filter { $0.first == "uninstall" }
        #expect(uninstalls.count == 2)
        #expect(uninstalls.allSatisfy { !$0.contains("--force") && $0.contains("--formula") })
        #expect(s.stillInstalled.isEmpty)
        #expect(!s.hasProblems)
        #expect(s.title == "Uninstall complete")
        // 0.8.5: both counts, in words, beside "2 of 2 versions".
        #expect(s.statusLine == "1 uninstalled (2 versions)")
        #expect(s.countLine == "2 of 2 versions")
        #expect(s.subtitle == "Every installed version, one brew uninstall each")
        #expect(await waitUntil { !store.isRefreshing && !store.packages.contains { $0.name == name } })
    }

    @Test func stillInstalledAfterTheLastStepIsNotComplete() async throws {
        // Tankard's list said 2 kegs; brew had 3 (installed from Terminal since).
        let name = try await Self.leafName()
        let log = CallLog()
        let (store, _) = try await store(name: name, log: log) { info, n, out in
            let left = n == 1 ? ["0.9", "1.0"] : ["0.9"]
            out(Data("Uninstalling /usr/local/Cellar/\(name)/x... (3 files, 4KB)\n".utf8))
            out(Data("\(name) \(left.joined(separator: " and ")) \(left.count == 1 ? "is" : "are") still installed.\n".utf8))
            info.info = try infoWithKegs(demoIntelInfo(), name: name, versions: left)
            return 0
        }
        let p = try #require(store.packages.first { $0.name == name })
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && !s.checkingInstalled })
        #expect(log.count("uninstall") == 2)
        #expect(s.failedItems.isEmpty) // brew exited 0 each time…
        #expect(s.stillInstalled == [name: ["0.9"]]) // …but it is still there
        #expect(s.hasProblems)
        #expect(s.title == "Uninstall incomplete")
        #expect(!s.title.contains("complete") || s.title == "Uninstall incomplete")
        #expect(s.statusLine == "0 uninstalled (2 versions), \(name) 0.9 still installed")
        #expect(s.log.lines.contains { $0.contains("\(name) 0.9 still installed: the uninstall didn't remove every version") })
        #expect(await waitUntil { !store.isRefreshing })
        #expect(store.packages.contains { $0.name == name })
    }

    @Test func theCheckAfterTheRunCatchesWhatBrewDidntSay() async throws {
        // Every step exits 0 and says nothing, but the package is still listed.
        let name = try await Self.leafName()
        let log = CallLog()
        let (store, _) = try await store(name: name, log: log) { info, n, out in
            out(Data("Uninstalling something... (3 files, 4KB)\n".utf8))
            info.info = try infoWithKegs(demoIntelInfo(), name: name, versions: ["1.0"])
            return 0
        }
        let p = try #require(store.packages.first { $0.name == name })
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && !s.checkingInstalled })
        #expect(s.stillInstalled == [name: ["1.0"]])
        #expect(s.title == "Uninstall incomplete")
    }

    @Test func aFailedCheckIsSaidAndClaimsNothingLeft() async throws {
        let name = try await Self.leafName()
        let log = CallLog()
        let (store, _) = try await store(name: name, versions: ["1.1"], log: log) { info, _, _ in
            info.failInfo = true
            return 0
        }
        let p = try #require(store.packages.first { $0.name == name })
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && !s.checkingInstalled })
        #expect(s.items.count == 1)
        #expect(s.log.lines.contains { $0.contains("Couldn't check what is still installed") })
    }

    @Test func titleWaitsForTheCheck() async throws {
        let name = try await Self.leafName()
        let s = UpgradeSession(packages: [Package.command(name)], intelbrewMode: false, action: .uninstall,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { _, _ in 0 }),
                               makeCommand: { p in QueuedCommand(executable: "/bin/true", arguments: [p.name], environment: [:], display: p.name) },
                               logURL: nil, onFinish: { $0.beginInstalledCheck() })
        #expect(await waitUntil { s.isFinished })
        #expect(s.checkingInstalled)
        #expect(s.title == "Checking what is still installed…")
        s.finishInstalledCheck([:])
        #expect(s.title == "Uninstall complete")
    }

    /// A formula with two kegs and one no-longer-needed dependency is three
    /// steps but two packages: the running title counts packages.
    @Test func runningTitleCountsPackagesNotSteps() {
        var p = Package.command("probe")
        p.installedVersions = ["1.0", "1.1"]
        let steps = AppStore.uninstallSteps([p, Package.command("probe-dep")])
        let s = UpgradeSession(packages: steps, intelbrewMode: false, action: .uninstall,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { _, _ in 0 }),
                               makeCommand: { p in QueuedCommand(executable: "/bin/true", arguments: [p.name], environment: [:], display: p.name) },
                               logURL: nil, onFinish: { _ in })
        #expect(s.total == 3)
        #expect(s.packages.count == 2)
        #expect(!s.isFinished)
        #expect(s.title == "Uninstalling 2 packages")
    }

    /// After a rollback: 1.0 pinned, 1.1 kept. Unpin and Uninstall unpins,
    /// re-reads, then removes both kegs.
    @Test func unpinAndUninstallAfterARollbackRemovesBoth() async throws {
        let name = try await Self.leafName()
        let log = CallLog()
        let (store, _) = try await store(name: name, versions: ["1.1", "1.0"], pinned: true, log: log, uninstall: { info, n, out in
            if n == 1 {
                out(Data("Uninstalling /usr/local/Cellar/\(name)/1.0... (3 files, 4KB)\n\(name) 1.1 is still installed.\n".utf8))
                info.info = try infoWithKegs(demoIntelInfo(), name: name, versions: ["1.1"])
            } else {
                info.info = try infoWithKegs(demoIntelInfo(), name: name, versions: [])
            }
            return 0
        }, unpin: { info in
            info.info = (try? infoWithKegs(demoIntelInfo(), name: name, versions: ["1.1", "1.0"], pinned: false)) ?? info.info
        })
        let p = try #require(store.packages.first { $0.name == name })
        #expect(p.pinned)
        #expect(p.installedVersions.count == 2)
        store.requestUninstall(p)
        store.unpinAndUninstall(p)
        #expect(await waitUntil { store.upgrade?.isFinished == true && store.upgrade?.checkingInstalled == false })
        let s = try #require(store.upgrade)
        // Split up: Swift 6.1's type checker times out on the one-line chain.
        let verbs: [String] = log.calls.map { (call: [String]) -> String in call.first ?? "" }
        let relevant: [String] = verbs.filter { (v: String) -> Bool in v == "unpin" || v == "uninstall" }
        #expect(relevant == ["unpin", "uninstall", "uninstall"])
        #expect(s.items.count == 2)
        #expect(s.title == "Uninstall complete")
        #expect(s.stillInstalled.isEmpty)
    }

    /// A step that fails stops the chain: the next version's step is skipped.
    @Test func aFailedStepSkipsTheRest() async throws {
        let name = try await Self.leafName()
        let log = CallLog()
        let (store, _) = try await store(name: name, log: log) { _, _, out in
            out(Data("Error: Permission denied\n".utf8))
            return 1
        }
        let p = try #require(store.packages.first { $0.name == name })
        store.startUninstall(p)
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && !s.checkingInstalled })
        #expect(log.count("uninstall") == 1)
        #expect(s.items.map(\.state) == [.failed(1), .cancelled])
        #expect(s.title == "Uninstall finished with errors")
    }
}
