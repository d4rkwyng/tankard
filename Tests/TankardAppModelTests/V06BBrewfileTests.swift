import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.6 (part B): Brewfile commands and parsing. The check output is what
// brew 7.0.14 printed on 2026-11-16 for a scratch Brewfile (read-only).

struct BrewfileTests {
    @Test func commands() {
        #expect(BrewfileCommands.dump(path: "/tmp/Brewfile", force: false) == ["bundle", "dump", "--file=/tmp/Brewfile"])
        #expect(BrewfileCommands.dump(path: "/tmp/Brewfile", force: true) == ["bundle", "dump", "--file=/tmp/Brewfile", "--force"])
        #expect(BrewfileCommands.dump(path: "/b", force: false, noVSCode: true).last == "--no-vscode")
        #expect(BrewfileCommands.check(path: "/b") == ["bundle", "check", "--file=/b", "--verbose", "--no-upgrade"])
        #expect(BrewfileCommands.list(path: "/b", kind: .cask) == ["bundle", "list", "--file=/b", "--cask"])
        #expect(BrewfileCommands.list(path: "/b", kind: nil) == ["bundle", "list", "--file=/b", "--all"])
        #expect(BrewfileCommands.installDisplay(path: "/Users/me/Brewfile") == "brew bundle install --file=/Users/me/Brewfile")
        #expect(BrewfileCommands.installDisplay(path: "/Users/me/My Files/it's") == "brew bundle install --file='/Users/me/My Files/it'\\''s'")
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
        #expect(plan.terminalCommand == "brew bundle install --file=/b")
    }
}
