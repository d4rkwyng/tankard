import Foundation
import Testing
@testable import TankardCore

// v0.7: `brew tap-info --installed --json` captured read-only on the arm64
// Mac (brew 7.0.14, 2026-11-17; core's and cask's name lists trimmed to
// 25), the Add Tap input checks, untap blocking and the argv.

struct V07TapsCoreTests {
    @Test func decodesTheCapturedTapInfo() throws {
        let taps = try TapInfo.decode(Fixture.data("arm64-tap-info"))
        #expect(taps.map(\.name) == ["homebrew/cask", "homebrew/core", "mull-project/mull", "steipete/tap", "yakitrak/yakitrak"])
        let core = try #require(taps.first { $0.name == "homebrew/core" })
        // API mode: listed, official, trusted, not tapped, no remote.
        #expect(core.official && core.trusted == true && !core.tapped && core.remote == nil && core.lastCommit == nil)
        #expect(core.formulaCount == 25 && core.caskCount == 0)
        let mull = try #require(taps.first { $0.name == "mull-project/mull" })
        #expect(!mull.official && mull.trusted == false && mull.tapped)
        #expect(mull.remote == "https://github.com/mull-project/homebrew-mull")
        #expect(mull.formulaCount == 51 && mull.caskCount == 0)
        #expect(mull.lastCommit == "35 hours ago" && !mull.customRemote && !mull.isPrivate)
        let steipete = try #require(taps.first { $0.name == "steipete/tap" })
        #expect(steipete.trusted == true && steipete.formulaCount == 22 && steipete.caskCount == 5)
        #expect(steipete.originLabel == "Third-party" && core.originLabel == "Official")
    }

    @Test func badJSONThrows() {
        #expect(throws: (any Error).self) { try TapInfo.decode(Data("Error: no such tap".utf8)) }
        #expect((try? TapInfo.decode(Data("[]".utf8))) == [])
    }

    @Test func nameAndURLValidation() {
        func ok(_ n: String, _ u: String = "") -> Bool { TapInput.problem(name: n, url: u) == nil }
        #expect(ok("steipete/tap"))
        #expect(ok("  d4rkwyng/homebrew-tap  "))
        #expect(ok("mull-project/mull", "https://github.com/mull-project/homebrew-mull"))
        #expect(ok("me/tools", "git@github.com:me/homebrew-tools.git"))
        #expect(ok("me/tools", "ssh://git@example.com/me/tools.git"))
        #expect(ok("me/tools", "file:///Users/me/src/homebrew-tools"))
        #expect(TapInput.problem(name: "") == .emptyName)
        for bad in ["steipete", "a/b/c", "-x/tap", "user/-repo", "user /repo", "user/re po", "user/..", "../etc", "user/repo;rm"] {
            #expect(TapInput.problem(name: bad) == .badName, "\(bad)")
        }
        for bad in ["github.com/me/tools", "https://x y", "--force", "ftp//x", "javascript:alert(1)",
                    // Nothing that starts with '-' reaches brew's argv as a URL.
                    "-f@x:y", "--force@x:y", "-@x:y", ".@x:y", "-oProxyCommand@x:y", "git@-oProxyCommand:x",
                    "git@.host:x", "-https://x", " -f@x:y"] {
            #expect(TapInput.problem(name: "me/tools", url: bad) == .badURL, "\(bad)")
        }
        #expect(ok("me/tools", "_svc@git.example.com:me/tools.git"))
        #expect(ok("me/tools", "git@10.0.0.2:me/tools.git"))
        // Names: neither part can start with '-' (or '.', or '_').
        for bad in ["--force/tap", "-/tap", "user/--force", ".x/tap", "user/_repo", "_x/tap"] {
            #expect(TapInput.problem(name: bad) == .badName, "\(bad)")
        }
        // Whatever passes never starts with '-' in either argv element.
        for (n, u) in [("a/b", "x@y:z"), ("a1/b-c", "https://e.com/a"), ("a/b", "file:///tmp/t")] {
            if case .success(let v) = TapInput.validate(name: n, url: u) {
                #expect(!v.name.hasPrefix("-") && !(v.url ?? "").hasPrefix("-"))
            } else {
                Issue.record("expected \(n) \(u) to pass")
            }
        }
        if case .success(let v) = TapInput.validate(name: " a/b ", url: " https://e.com/a/b ") {
            #expect(v.name == "a/b" && v.url == "https://e.com/a/b")
        } else {
            Issue.record("expected success")
        }
        #expect(TapInput.defaultRemote("steipete/tap") == "https://github.com/steipete/homebrew-tap")
        #expect(TapInput.defaultRemote("d4rkwyng/homebrew-tap") == "https://github.com/d4rkwyng/homebrew-tap")
    }

    @Test func untapIsBlockedWhilePackagesComeFromTheTap() throws {
        let taps = try TapInfo.decode(Fixture.data("arm64-tap-info"))
        let yak = try #require(taps.first { $0.name == "yakitrak/yakitrak" })
        var cli = Package.command("obsidian-cli")
        cli.tap = "yakitrak/yakitrak"
        var xz = Package.command("xz")
        xz.tap = "homebrew/core"
        #expect(TapRemoval.check(yak, packages: [cli, xz]) == .inUse(["obsidian-cli"]))
        #expect(TapRemoval.check(yak, packages: [cli]).reason?.contains("brew refuses to untap") == true)
        // brew treats tap names case-insensitively.
        cli.tap = "YakiTrak/yakitrak"
        #expect(!TapRemoval.check(yak, packages: [cli]).isAllowed)
        #expect(TapRemoval.check(yak, packages: [xz]) == .allowed)
        let core = try #require(taps.first { $0.name == "homebrew/core" })
        #expect(TapRemoval.check(core, packages: []) == .notTapped)
    }

    @Test func commandArguments() {
        #expect(TapCommands.infoArguments == ["tap-info", "--installed", "--json"])
        #expect(TapCommands.tap("steipete/tap") == ["tap", "steipete/tap"])
        #expect(TapCommands.tap("me/tools", url: "git@github.com:me/homebrew-tools.git") == ["tap", "me/tools", "git@github.com:me/homebrew-tools.git"])
        #expect(TapCommands.untap("steipete/tap") == ["untap", "steipete/tap"])
        #expect(!TapCommands.untap("x/y").contains("--force") && !TapCommands.untap("x/y").contains("-f"))
        #expect(TapCommands.trust("mull-project/mull", true) == ["trust", "--tap", "mull-project/mull"])
        #expect(TapCommands.trust("mull-project/mull", false) == ["untrust", "--tap", "mull-project/mull"])
    }
}
