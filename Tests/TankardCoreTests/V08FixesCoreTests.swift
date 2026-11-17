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

// v0.8: the dependencies an uninstall leaves unneeded (the uninstall
// sheet's "No longer needed by anything").
struct OrphanTests {
    func pkg(_ name: String, _ deps: [String] = [], requested: Bool = false, pinned: Bool = false,
             kind: PackageKind = .formula) -> Package {
        var p = Package.command(name)
        p.id = "\(kind.rawValue):homebrew/\(kind == .cask ? "cask" : "core")/\(name)"
        p.kind = kind
        p.name = name
        p.fullName = name
        p.tap = kind == .cask ? "homebrew/cask" : "homebrew/core"
        p.dependencies = deps     // a receipt's runtime dependencies are already recursive
        p.requested = requested
        p.pinned = pinned
        return p
    }

    @Test func onlyWhatNothingElseNeedsInRemovalOrder() throws {
        // app → lib → base; app → shared (also needed by other); app → asked
        // (installed on request); app → held (pinned); stale was unused before.
        let app = pkg("app", ["lib", "base", "shared", "asked", "held"], requested: true)
        let other = pkg("other", ["shared"], requested: true)
        let lib = pkg("lib", ["base"])
        let all = [pkg("base"), app, other, lib, pkg("shared"), pkg("asked", requested: true),
                   pkg("held", pinned: true), pkg("stale")]
        let g = DependencyGraph(all)
        let out = g.orphans(afterRemoving: [app]).map(\.name)
        #expect(Set(out) == ["lib", "base"])
        // lib needs base: lib goes first, or brew would refuse base.
        #expect(out == ["lib", "base"])
        // Nothing for a package with no dependencies, or one whose deps others need.
        #expect(g.orphans(afterRemoving: [other]).isEmpty)
        #expect(g.orphans(afterRemoving: [pkg("leaf", requested: true)]).isEmpty)
        // Removing both: shared goes too.
        #expect(Set(g.orphans(afterRemoving: [app, other]).map(\.name)) == ["lib", "base", "shared"])
    }

    @Test func aCasksFormulaDependenciesCount() {
        let c = pkg("tool-app", ["helper"], requested: true, kind: .cask)
        let g = DependencyGraph([c, pkg("helper")])
        #expect(g.orphans(afterRemoving: [c]).map(\.name) == ["helper"])
    }

    /// The real arm64 capture: every orphan is a non-requested formula
    /// whose dependents are all in the removed set.
    @Test func realGraphOrphansAreConsistent() throws {
        let info = try JSONDecoder().decode(BrewInfoJSON.self, from: Fixture.data("arm64-deps-info"))
        let pkgs = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false).classify(info: info)
        let g = DependencyGraph(pkgs)
        var nonEmpty = 0
        for p in pkgs where p.requested && g.isLeaf(p) {
            let out = g.orphans(afterRemoving: [p])
            if !out.isEmpty { nonEmpty += 1 }
            let removed = Set([p.id] + out.map(\.id))
            for o in out {
                #expect(o.kind == .formula && !o.requested && !o.pinned)
                #expect(g.dependents(of: o).allSatisfy { removed.contains($0.id) }, "\(p.name) → \(o.name)")
            }
        }
        #expect(nonEmpty > 0)
    }
}

// 0.8.1: Discover's cask entries carry the cask's artifacts, so the App
// Management explainer can skip a font cask.
@Suite struct V081CatalogArtifactTests {
    func entry(_ json: String) throws -> CatalogEntry {
        let c = try JSONDecoder().decode(BrewInfoJSON.Cask.self, from: Data(json.utf8))
        return CatalogBuilder(platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"),
                              intelbrewMode: false).entry(c)
    }

    @Test func artifactsReachThePackage() throws {
        let font = try entry(#"{"token":"font-fira-code","full_token":"font-fira-code","tap":"homebrew/cask","version":"6.2","artifacts":[{"font":["FiraCode-Bold.ttf"]}]}"#)
        #expect(font.appPaths == [])
        #expect(font.asPackage().appPaths == [])
        #expect(font.asPackage().installsPkg == false)
        let app = try entry(#"{"token":"anybar","full_token":"anybar","tap":"homebrew/cask","version":"1.0","artifacts":[{"app":["AnyBar.app"]}]}"#)
        #expect(app.asPackage().appPaths?.count == 1)
        let none = try entry(#"{"token":"x","full_token":"x","tap":"homebrew/cask","version":"1.0"}"#)
        #expect(none.appPaths == nil) // unknown: the explainer still shows
    }
}
