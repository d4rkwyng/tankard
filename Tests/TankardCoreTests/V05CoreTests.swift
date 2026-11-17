import Foundation
import Testing
@testable import TankardCore

// v0.5: the cask artifacts auto-update reads to tell whether an app is
// running. Shapes as `brew info --json=v2 --installed` prints them (brew
// 7.0.14 on the arm64 Mac, read-only): `{"app": ["Cursor.app"], "target":
// "/Applications/Cursor.app"}`, `{"uninstall": [{"quit": "<bundle id>"}]}`.

struct CaskArtifactTests {
    func decode(_ casks: String) throws -> [BrewInfoJSON.Cask] {
        try JSONDecoder().decode(BrewInfoJSON.self, from: Data(#"{"formulae":[],"casks":[\#(casks)]}"#.utf8)).casks
    }

    func cask(_ token: String, artifacts: String?) -> String {
        let a = artifacts.map { #","artifacts":\#($0)"# } ?? ""
        return #"{"token":"\#(token)","full_token":"\#(token)","tap":"homebrew/cask","version":"2.0","installed":"1.0","outdated":true\#(a)}"#
    }

    @Test func appTargetAndQuit() throws {
        let c = try decode(cask("geekbench", artifacts: #"[{"uninstall":[{"quit":"com.primatelabs.parkdale"}]},{"app":["Geekbench 7.app"],"target":"/Applications/Geekbench 7.app"},{"zap":[{"trash":["~/Library/x"]}]}]"#))
        #expect(c[0].appPaths == ["/Applications/Geekbench 7.app"])
        #expect(c[0].quitBundleIDs == ["com.primatelabs.parkdale"])
        let p = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(cask: c[0], outdated: true)
        #expect(p.appPaths == ["/Applications/Geekbench 7.app"])
        #expect(p.quitBundleIDs == ["com.primatelabs.parkdale"])
    }

    @Test func otherShapes() throws {
        let c = try decode([
            // No top-level target: the app name under /Applications; a renamed item's own target.
            cask("a", artifacts: #"[{"app":["A.app"]}]"#),
            cask("b", artifacts: #"[{"app":["Original.app",{"target":"Renamed.app"}]}]"#),
            // CLI-only cask: artifacts, but no app.
            cask("claude-code", artifacts: #"[{"binary":["claude"],"target":"/opt/homebrew/bin/claude"}]"#),
            // quit as a list; an odd stanza shape is ignored, not fatal.
            cask("d", artifacts: #"[{"uninstall":[{"quit":["x.one","x.two"]},"weird"]},42]"#),
            cask("e", artifacts: nil),
        ].joined(separator: ","))
        #expect(c.count == 5)
        #expect(c[0].appPaths == ["/Applications/A.app"])
        #expect(c[1].appPaths == ["/Applications/Renamed.app"])
        #expect(c[2].appPaths == [])
        #expect(c[2].quitBundleIDs == [])
        #expect(c[3].appPaths == [])
        #expect(c[4].appPaths == nil)
        #expect(c[4].quitBundleIDs == nil)
    }

    @Test func oldCachedReportsStillDecode() throws {
        // A 0.4 status.json package has no appPaths: it decodes as nil.
        var p = Package.command("x")
        p.appPaths = nil
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Package.self, from: data)
        #expect(back.appPaths == nil)
        #expect(back == p)
    }
}
