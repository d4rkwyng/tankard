import Foundation
import Testing
@testable import TankardCore

// 0.8.6 (walkthrough M1): an installed package brew can't load (obsidian-cli
// from the untrusted, renamed yakitrak/yakitrak tap) vanished from Tankard:
// `brew info --installed` leaves it out. It is now a row marked unreadable,
// with brew's reason, and its tap can't be removed from under it.

struct V086UnreadableTests {
    static let install = BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew")

    /// A prefix with Cellar/Caskroom folders: xz (in the fixture),
    /// obsidian-cli (not), a cask in the fixture and one not.
    func prefix() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-unreadable-\(UUID().uuidString)")
        let fm = FileManager.default
        func dir(_ p: String) throws { try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true) }
        try dir("Cellar/xz/5.8.3")
        try dir("Cellar/obsidian-cli/0.2.3")
        try #"{"installed_on_request":true,"poured_from_bottle":false,"time":1700000000,"source":{"tap":"yakitrak/yakitrak"}}"#
            .write(to: root.appendingPathComponent("Cellar/obsidian-cli/0.2.3/INSTALL_RECEIPT.json"), atomically: true, encoding: .utf8)
        try dir("Cellar/empty-rack") // no version inside: not a package
        try dir("Caskroom/tailscale/1.104.5")
        return root
    }

    func info() throws -> BrewInfoJSON { try Fixture.info("sonoma-intelbrew-info") }

    @Test func kegsTheJSONLeavesOutBecomeRows() throws {
        let root = try prefix()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = UnreadableKegs.find(cellar: root.appendingPathComponent("Cellar").path,
                                       caskroom: root.appendingPathComponent("Caskroom").path, info: try info())
        #expect(rows.map(\.name) == ["obsidian-cli", "tailscale"])
        let o = try #require(rows.first)
        #expect(o.id == "formula:yakitrak/yakitrak/obsidian-cli")
        #expect(o.tap == "yakitrak/yakitrak")
        #expect(o.installedVersion == "0.2.3")
        #expect(o.requested)
        #expect(o.status == .source)
        #expect(o.isUnreadable)
        #expect(o.upgradeAvailable == false)
        #expect(rows[1].kind == .cask && rows[1].tap == nil)
    }

    @Test func brewsReasonIsTheErrorLineAndItsAdvice() {
        let stderr = """
        Error: Refusing to load formula yakitrak/yakitrak/notesmd-cli from untrusted tap yakitrak/yakitrak.
        Run `brew trust --formula yakitrak/yakitrak/notesmd-cli` or `brew trust yakitrak/yakitrak` to trust it.

        """
        #expect(UnreadableKegs.reason(stderr: stderr) == "Refusing to load formula yakitrak/yakitrak/notesmd-cli from untrusted tap yakitrak/yakitrak. Run `brew trust --formula yakitrak/yakitrak/notesmd-cli` or `brew trust yakitrak/yakitrak` to trust it.")
        #expect(UnreadableKegs.reason(stderr: "Warning: something\n") == nil)
    }

    @Test func statusAddsThemWithBrewsReasonAndDropsWhatBrewCanRead() async throws {
        let root = try prefix()
        defer { try? FileManager.default.removeItem(at: root) }
        let infoData = try Fixture.data("sonoma-intelbrew-info")
        let runner = FakeRunner { exe, args in
            guard exe.hasSuffix("brew") else { return failed }
            if args == ["info", "--json=v2", "--installed"] { return ok(infoData) }
            if args.last == "obsidian-cli" {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("Error: Refusing to load formula yakitrak/yakitrak/notesmd-cli from untrusted tap yakitrak/yakitrak.\n".utf8))
            }
            if args.last == "tailscale" { return ok("{}") } // brew can read it after all
            return failed
        }
        var c = BrewClient(installation: Self.install, platform: .intelSonoma, runner: runner,
                           sources: EnvironmentSources(process: ["HOME": "/Users/x"]))
        let cellar = root.appendingPathComponent("Cellar").path, caskroom = root.appendingPathComponent("Caskroom").path
        c.unreadableScan = { UnreadableKegs.find(cellar: cellar, caskroom: caskroom, info: $0) }
        let report = try await c.status()
        let o = try #require(report.packages["obsidian-cli"])
        #expect(o.unreadable == "Refusing to load formula yakitrak/yakitrak/notesmd-cli from untrusted tap yakitrak/yakitrak.")
        #expect(o.unreadableDetail?.contains("Installed from yakitrak/yakitrak.") == true)
        #expect(report.packages["tailscale"] == nil)
        #expect(report.summary.installed == 21)
        #expect(runner.calls.contains { $0.arguments == ["info", "--json=v2", "--formula", "obsidian-cli"] })
    }

    @Test func aTapWithAnUnreadablePackageCantBeRemoved() throws {
        let tap = TapInfo(name: "yakitrak/yakitrak", formulaNames: ["notesmd-cli"])
        var p = UnreadableKegs.row(kind: .formula, name: "obsidian-cli", tap: "yakitrak/yakitrak", versions: ["0.2.3"],
                                   requested: true, poured: false, time: nil)
        p.unreadable = "Refusing to load"
        let check = TapRemoval.check(tap, packages: [p])
        #expect(!check.isAllowed)
        #expect(check.reason?.contains("Homebrew can't read obsidian-cli any more") == true)
        #expect(TapRemoval.check(tap, packages: []).isAllowed)
    }
}
