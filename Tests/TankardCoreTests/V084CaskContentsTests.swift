import Foundation
import Testing
@testable import TankardCore

// v0.8.4: the detail pane says what a cask installs, from its artifacts
// (a font cask said "installs the vendor's app").
struct V084CaskContentsTests {
    func classify(_ json: String) throws -> [String: Package] {
        let casks = try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: Data(json.utf8))
        let c = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false)
        return Dictionary(uniqueKeysWithValues: casks.map { ($0.token, c.classify(cask: $0, outdated: false)) })
    }

    @Test func realShapes() throws {
        // As `brew info --json=v2` gives them (font-press-start-2p and maccy verbatim).
        let by = try classify("""
        [{"token": "font-press-start-2p", "version": "4.000", "installed": "4.000",
          "artifacts": [{"font": ["PressStart2P-Regular.ttf"], "target": "/Users/me/Library/Fonts/PressStart2P-Regular.ttf"}, {"zap": []}]},
         {"token": "maccy", "version": "2.6", "installed": "2.6",
          "artifacts": [{"uninstall": [{"quit": "org.p0deje.Maccy"}]}, {"app": ["Maccy.app"], "target": "/Applications/Maccy.app"},
                        {"zap": [{"trash": ["~/Library/Preferences/org.p0deje.Maccy.plist"]}]}]},
         {"token": "zoom", "version": "6.0", "installed": "6.0",
          "artifacts": [{"uninstall": [{"pkgutil": "us.zoom.pkg.videomeeting"}]}, {"pkg": ["zoomusInstallerFull.pkg"]}]},
         {"token": "tool", "version": "1", "installed": "1",
          "artifacts": [{"binary": ["tool"], "target": "/opt/homebrew/bin/tool"}, {"manpage": ["tool.1"]}]},
         {"token": "ql", "version": "1", "installed": "1", "artifacts": [{"qlplugin": ["X.qlgenerator"]}]},
         {"token": "app-and-cli", "version": "1", "installed": "1",
          "artifacts": [{"binary": ["x"]}, {"app": ["X.app"], "target": "/Applications/X.app"}]},
         {"token": "staged", "version": "1", "installed": "1", "artifacts": [{"stage_only": [true]}]},
         {"token": "none", "version": "1", "installed": "1"}]
        """)
        #expect(by["font-press-start-2p"]?.caskArtifacts == ["font"])
        #expect(by["maccy"]?.caskArtifacts == ["app"])
        #expect(by["none"]?.caskArtifacts == nil)
        func contents(_ t: String) -> CaskContents? { by[t].map(CaskContents.init) }
        #expect(contents("font-press-start-2p") == .font)
        #expect(contents("maccy") == .app)
        #expect(contents("zoom") == .installer)
        #expect(contents("tool") == .commandLineTool)
        #expect(contents("ql") == .plugin)
        #expect(contents("app-and-cli") == .app)
        #expect(contents("staged") == .other)
        #expect(contents("none") == .other)
        // Through the status cache's Codable.
        let back = try JSONDecoder().decode(Package.self, from: JSONEncoder().encode(by["font-press-start-2p"]!))
        #expect(CaskContents(back) == .font)
    }

    /// A status cache written before 0.8.4 (no kinds): apps and pkg still count.
    @Test func olderCache() throws {
        let by = try classify("""
        [{"token": "a", "version": "1", "installed": "1", "artifacts": [{"app": ["A.app"], "target": "/Applications/A.app"}]},
         {"token": "p", "version": "1", "installed": "1", "artifacts": [{"pkg": ["P.pkg"]}]},
         {"token": "f", "version": "1", "installed": "1", "artifacts": [{"font": ["F.ttf"]}]}]
        """)
        var a = try #require(by["a"]), p = try #require(by["p"]), f = try #require(by["f"])
        a.caskArtifacts = nil; p.caskArtifacts = nil; f.caskArtifacts = nil
        #expect(CaskContents(a) == .app)
        #expect(CaskContents(p) == .installer)
        #expect(CaskContents(f) == .other)
    }
}
