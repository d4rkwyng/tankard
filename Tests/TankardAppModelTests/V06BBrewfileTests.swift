import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.6 (part B): Brewfile commands and parsing. The check output is what
// brew 7.0.14 printed on 2026-11-16 for a scratch Brewfile (read-only).

struct BrewfileTests {
    @Test func commands() {
        #expect(BrewfileCommands.dump(path: "/tmp/Brewfile", force: false) == ["bundle", "dump", "--file=/tmp/Brewfile", "--no-vscode", "--no-mas"])
        #expect(BrewfileCommands.dump(path: "/tmp/Brewfile", force: true) == ["bundle", "dump", "--file=/tmp/Brewfile", "--no-vscode", "--no-mas", "--force"])
        #expect(BrewfileCommands.tapDisplay("hashicorp/tap") == "brew tap hashicorp/tap")
        #expect(BrewfileCommands.check(path: "/b") == ["bundle", "check", "--file=/b", "--verbose", "--no-upgrade"])
        #expect(BrewfileCommands.list(path: "/b", kind: .cask) == ["bundle", "list", "--file=/b", "--cask"])
        #expect(BrewfileCommands.list(path: "/b", kind: nil) == ["bundle", "list", "--file=/b", "--all"])
        #expect(BrewfileCommands.installDisplay(path: "/Users/me/Brewfile") == "brew bundle install --file=/Users/me/Brewfile --no-upgrade")
        #expect(BrewfileCommands.installDisplay(path: "/Users/me/My Files/it's") == "brew bundle install --file='/Users/me/My Files/it'\\''s' --no-upgrade")
    }

    static let checkOutput = """
    Warning: Formulae dependency graph sorting found a circular dependency:
      libtiff, webp
    brew bundle can't satisfy your Brewfile's dependencies.
    → Tap d4rkwyng/nonexistent needs to be tapped.
    → Cask firefox needs to be installed.
    → Formula jq needs to be installed.
    → Formula zzz-not-a-real-formula-xyz needs to be installed.
    Satisfy missing dependencies with `brew bundle install`.
    """

    @Test func checkParsing() {
        let m = BrewfileParser.missing(Self.checkOutput.components(separatedBy: "\n"))
        #expect(m == [BrewfileEntry(kind: .tap, name: "d4rkwyng/nonexistent"), BrewfileEntry(kind: .cask, name: "firefox"),
                      BrewfileEntry(kind: .formula, name: "jq"), BrewfileEntry(kind: .formula, name: "zzz-not-a-real-formula-xyz")])
        #expect(BrewfileParser.missing(["The Brewfile's dependencies are satisfied."]).isEmpty)
        #expect(BrewfileParser.missing(["→ Go golang.org/x/tools needs to be installed."]) == [BrewfileEntry(kind: nil, name: "golang.org/x/tools")])
    }

    @Test func listContents() {
        // brew bundle list --all, then per kind (same scratch Brewfile).
        let all = BrewfileParser.listNames("d4rkwyng/nonexistent\njq\nzzz\nfirefox\ngopls\n")
        let c = BrewfileParser.contents(all: all, byKind: [.tap: ["d4rkwyng/nonexistent"], .formula: ["jq", "zzz"], .cask: ["firefox"]])
        #expect(c.filter { $0.kind == .formula }.map(\.name) == ["jq", "zzz"])
        #expect(c.last == BrewfileEntry(kind: nil, name: "gopls"))
        #expect(c.count == 5)
    }

    @Test func restorePlan() {
        let missing = BrewfileParser.missing(Self.checkOutput.components(separatedBy: "\n"))
        let plan = BrewfileRestorePlan(missing: missing, path: "/b", compiles: ["zzz-not-a-real-formula-xyz": true, "jq": false],
                                       needsAdmin: ["firefox"])
        #expect(plan.queued.map(\.entry.name) == ["firefox", "jq", "zzz-not-a-real-formula-xyz"])
        #expect(plan.terminalOnly.map(\.entry.name) == ["d4rkwyng/nonexistent"])
        #expect(plan.compiling.map(\.entry.name) == ["zzz-not-a-real-formula-xyz"])
        #expect(plan.adminCasks.map(\.entry.name) == ["firefox"])
        let pk = plan.packages()
        #expect(pk.map(\.kind) == [.cask, .formula, .formula])
        #expect(BrewCommands.installArguments(kind: pk[0].kind, qualifiedName: pk[0].qualifiedName) == ["install", "--cask", "firefox"])
        #expect(plan.terminalCommand == "brew bundle install --file=/b --no-upgrade")
    }
}

// v0.6 (part B): the Brewfile sheet's store: summary counts, the timeout,
// and building the restore plan from `brew info` (the demo's fixtures).

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ a: [String]) { lock.lock(); calls.append(a); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}

@MainActor
struct BrewfileStoreTests {
    static let arm64 = BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar")

    nonisolated static func ok(_ s: String, exit: Int32 = 0) -> ProcessResult {
        ProcessResult(exitCode: exit, stdout: Data(s.utf8), stderr: Data())
    }

    @Test func summaryCounts() {
        let s = BrewfileSummary(path: "/b", tapList: "hashicorp/tap\n", formulaList: "jq\nwget\n\nxz\n", caskList: "")
        #expect(s == BrewfileSummary(path: "/b", taps: 1, formulae: 3, casks: 0))
        #expect(s.line == "1 tap, 3 formulae, 0 casks")
    }

    @Test func exportRunsDumpThenListsEachKind() async {
        let rec = Recorder()
        let store = BrewfileStore()
        store.run = { args in
            rec.add(args)
            if args.contains("--tap") { return Self.ok("a/b\n") }
            if args.contains("--formula") { return Self.ok("jq\nwget\n") }
            if args.contains("--cask") { return Self.ok("firefox\niterm2\nzoom\n") }
            return Self.ok("")
        }
        store.export(to: "/x/Brewfile", force: true)
        await store.waitForIdle()
        #expect(store.page == .exported(BrewfileSummary(path: "/x/Brewfile", taps: 1, formulae: 2, casks: 3)))
        #expect(rec.all.first == ["bundle", "dump", "--file=/x/Brewfile", "--no-vscode", "--no-mas", "--force"])
        #expect(rec.all.count == 4)
        store.dismiss()
        #expect(store.page == .idle)
    }

    @Test func dumpFailureIsShown() async {
        let store = BrewfileStore()
        store.run = { _ in ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: no permission\n".utf8)) }
        store.export(to: "/x", force: false)
        await store.waitForIdle()
        guard case .failed(let m) = store.page else { Issue.record("not failed: \(store.page)"); return }
        #expect(m.contains("no permission"))
    }

    @Test func timeoutStopsDumpAndCheck() async {
        let store = BrewfileStore()
        store.timeout = .milliseconds(150)
        store.run = { _ in
            try await Task.sleep(for: .seconds(30)) // a hung `code`; cancelled by the timeout
            return Self.ok("")
        }
        let start = Date()
        store.export(to: "/x", force: false)
        await store.waitForIdle()
        #expect(store.page == .failed(BrewfileError.timedOut(seconds: 0).description))
        store.check(path: "/x")
        await store.waitForIdle()
        guard case .failed(let m) = store.page else { Issue.record("check didn't time out"); return }
        #expect(m.contains("didn't finish"))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(BrewfileError.timedOut(seconds: 60).description.hasPrefix("brew bundle didn't finish within 60 seconds"))
    }

    @Test func checkParsesMissingDespiteExitOne() async {
        let store = BrewfileStore()
        store.run = { _ in Self.ok(BrewfileTests.checkOutput, exit: 1) }
        store.check(path: "/b")
        await store.waitForIdle()
        guard case .checked(let r) = store.page else { Issue.record("not checked"); return }
        #expect(r.names(.formula) == ["jq", "zzz-not-a-real-formula-xyz"])
        #expect(r.names(.tap) == ["d4rkwyng/nonexistent"])
        // Satisfied, and a real failure (exit 1, nothing parsed).
        store.run = { _ in Self.ok("The Brewfile's dependencies are satisfied.\n") }
        store.check(path: "/b")
        await store.waitForIdle()
        #expect(store.page == .checked(BrewfileCheckResult(path: "/b", missing: [])))
        store.run = { _ in Self.ok("Error: No Brewfile found\n", exit: 1) }
        store.check(path: "/b")
        await store.waitForIdle()
        guard case .failed = store.page else { Issue.record("not failed"); return }
    }

    /// The demo's arm64 fixtures: jsontoolkit has no arm64 bottle, and
    /// chrome-remote-desktop-host carries a pkg artifact.
    @Test func restorePlanMarksCompilesAndAdmin() async {
        let state = Demo.State()
        let rec = Recorder()
        let run: @Sendable ([String]) async throws -> ProcessResult = { args in
            rec.add(args)
            if let r = try await Demo.brewfile(.arm64, state: state, info: Data(), arguments: args) { return r }
            return Demo.catalogInfo(.arm64, arguments: args)
        }
        let result = BrewfileCheckResult(path: "/b", missing: Demo.brewfileMissing(.arm64))
        let (plan, note) = await BrewfileStore.buildPlan(result, platform: Self.arm64, run: run)
        #expect(note == nil)
        #expect(plan.compiling.map(\.entry.name) == ["jsontoolkit"])
        #expect(plan.items.first { $0.entry.name == "bit-git" }?.compiles == false)
        #expect(plan.adminCasks.map(\.entry.name) == ["chrome-remote-desktop-host"])
        #expect(plan.terminalOnly.map(\.entry.name) == ["hashicorp/tap"])
        #expect(plan.packages().map(\.qualifiedName) == ["bit-git", "git-absorb", "jsontoolkit", "firefox", "chrome-remote-desktop-host"])
        // One batched read-only `brew info` per kind.
        #expect(rec.all == [["info", "--json=v2", "--formula", "bit-git", "git-absorb", "jsontoolkit"],
                            ["info", "--json=v2", "--cask", "firefox", "chrome-remote-desktop-host"]])
    }

    @Test func restorePlanWithoutDetailsNotesIt() async {
        let result = BrewfileCheckResult(path: "/b", missing: [BrewfileEntry(kind: .formula, name: "nope"), BrewfileEntry(kind: .cask, name: "nada")])
        let (plan, note) = await BrewfileStore.buildPlan(result, platform: Self.arm64) { _ in
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: No available formula\n".utf8))
        }
        #expect(plan.items.allSatisfy { $0.compiles == nil && !$0.needsAdmin })
        #expect(note?.contains("compiles aren't marked") == true)
        #expect(note?.contains("admin passwords aren't marked") == true)
    }

    @Test func storeRestorePlanPage() async {
        let state = Demo.State()
        let store = BrewfileStore()
        store.platform = Self.arm64
        store.run = { args in
            if let r = try await Demo.brewfile(.arm64, state: state, info: Data(), arguments: args) { return r }
            return Demo.catalogInfo(.arm64, arguments: args)
        }
        store.check(path: "/b")
        await store.waitForIdle()
        guard case .checked(let r) = store.page else { Issue.record("not checked"); return }
        #expect(r.missing.count == 6)
        store.planRestore(r)
        await store.waitForIdle()
        guard case .plan(let p, nil) = store.page else { Issue.record("no plan: \(store.page)"); return }
        #expect(p.queued.count == 5)
        store.back(to: r)
        #expect(store.page == .checked(r))
    }

    @Test func caskPkgArtifactDecodes() throws {
        let json = #"{"formulae":[],"casks":[{"token":"a","version":"1","artifacts":[{"pkg":["A.pkg"]}]},{"token":"b","version":"1","artifacts":[{"app":["B.app"]}]},{"token":"c","version":"1"}]}"#
        let info = try JSONDecoder().decode(BrewInfoJSON.self, from: Data(json.utf8))
        #expect(info.casks.map(\.installsPkg) == [true, false, nil])
        #expect(BrewfilePlanner.needsAdmin(info) == ["a"])
    }
}
