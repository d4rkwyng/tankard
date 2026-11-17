import Foundation
import Testing
@testable import TankardCore

// v0.8: what an installed cask puts in /Applications, carried onto the
// Package (the App Management explainer is only for casks with apps).
struct V08FixesCoreTests {
    @Test func caskPackagesCarrySuitesAndPkg() throws {
        let json = """
        [{"token": "font-press-start-2p", "version": "4.000", "installed": "4.000",
          "artifacts": [{"font": ["PressStart2P-Regular.ttf"]}]},
         {"token": "anybar", "version": "0.2.3", "installed": "0.2.3",
          "artifacts": [{"app": ["AnyBar.app"], "target": "/Applications/AnyBar.app"}]},
         {"token": "kicad", "version": "10.0.6", "installed": "10.0.6",
          "artifacts": [{"suite": ["KiCad"], "target": "/Applications/KiCad"}]},
         {"token": "zoom", "version": "6.0", "installed": "6.0",
          "artifacts": [{"pkg": ["zoomusInstallerFull.pkg"]}]},
         {"token": "noartifacts", "version": "1", "installed": "1"}]
        """
        let casks = try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: Data(json.utf8))
        let c = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false)
        let by = Dictionary(uniqueKeysWithValues: casks.map { ($0.token, c.classify(cask: $0, outdated: false)) })
        let font = try #require(by["font-press-start-2p"])
        #expect(font.appPaths == [] && font.suitePaths == [] && font.installsPkg == false)
        #expect(by["anybar"]?.appPaths == ["/Applications/AnyBar.app"])
        #expect(by["kicad"]?.suitePaths == ["/Applications/KiCad"])
        #expect(by["zoom"]?.installsPkg == true)
        let none = try #require(by["noartifacts"])
        #expect(none.appPaths == nil && none.suitePaths == nil && none.installsPkg == nil)
        // Round trip through the status cache's Codable.
        let back = try JSONDecoder().decode(Package.self, from: JSONEncoder().encode(by["kicad"]!))
        #expect(back.suitePaths == ["/Applications/KiCad"])
    }
}
