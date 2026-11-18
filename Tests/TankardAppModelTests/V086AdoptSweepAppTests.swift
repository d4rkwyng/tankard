import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6: the 0.8.5 Adopt sweep's examples through AdoptStore (the default
// ticks, the copyable --force command, the row notes). Same fixtures as
// TankardCoreTests/V086AdoptSweepTests (read from that folder).

@MainActor
struct V086AdoptSweepAppTests {
    struct Meta: Decodable { var path: String; var bid: String; var ver: String }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TankardCoreTests/Fixtures")

    func store() throws -> AdoptStore {
        let index = try AdoptIndex.decode(caskJSON: Data(contentsOf: Self.fixtures.appendingPathComponent("adopt-sweep-casks.json")))
        let meta = try JSONDecoder().decode([Meta].self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("adopt-sweep-apps.json")))
        let apps = meta.map { m in
            InstalledApp(path: "/Applications/" + m.path, root: "/Applications", relativePath: m.path, bundleID: m.bid,
                         shortVersion: m.ver, bundleVersion: m.ver)
        }
        let a = AdoptStore()
        a.apply(AdoptInput(index: index, apps: apps, source: "sweep"))
        return a
    }

    func row(_ a: AdoptStore, _ path: String) throws -> AdoptRow {
        try #require(a.scan.rows.first { $0.app.relativePath == path })
    }

    @Test func onlySingleAppIDMatchesAreTicked() throws {
        let a = try store()
        // H1/H2/M1: none of these is ticked for you.
        for p in ["Firefox.app", "Thunderbird.app", "Parallels Desktop.app", "Beyond Compare.app", "Little Snitch.app",
                  "Slack.app", "1Password.app", "Copilot.app", "Outline.app", "Caffeine.app", "Paper.app", "Vienna.app",
                  "Base.app", "Goose.app", "Godot.app", "LibreOffice.app", "Blender.app", "ChatGPT.app", "1Password 7.app"] {
            #expect(!a.isTicked(try row(a, p)), "\(p)")
        }
        // Single app-ID matches at the cask's version are.
        for p in ["Obsidian.app", "Notion.app", "Docker.app", "Zen.app", "Loop.app", "Amethyst.app", "Opera.app"] {
            let r = try row(a, p)
            #expect(a.group(r) == .ready && a.isTicked(r), "\(p)")
        }
        // Every ticked row is an app-ID match with one cask.
        for r in a.scan.rows where a.isTicked(r) {
            #expect(a.confidence(r) == .high && !r.isAmbiguous, "\(r.app.relativePath)")
        }
        #expect(!a.plan.contains { ["copilot-money", "firefox", "parallels", "godot", "libreoffice", "blender"].contains($0.token) })
    }

    @Test func forceCommandOnlyForOneSureCask() throws {
        let a = try store()
        // H3: Couchbase has two casks: no `brew install --cask --force` of either.
        let cb = try row(a, "Couchbase Server.app")
        #expect(a.group(cb) == .needsUpdate && !a.offersReplace(cb))
        // Godot 3, LibreOffice still, Blender LTS: ready as their own cask, not "needs update".
        for (p, t) in [("Godot.app", "godot@3"), ("LibreOffice.app", "libreoffice-still"), ("Blender.app", "blender@lts")] {
            let r = try row(a, p)
            #expect(a.token(r) == t && a.group(r) == .ready && !a.offersReplace(r), "\(p)")
        }
        // Picking the other line by hand: still no --force (ambiguous).
        let godot = try row(a, "Godot.app")
        a.choose("godot", for: godot)
        #expect(a.group(godot) == .needsUpdate && !a.offersReplace(godot))
    }

    @Test func nameOnlyNeedsUpdateSaysItMayBeADifferentApp() throws {
        let a = try store()
        let im = try row(a, "Impactor.app")
        #expect(a.group(im) == .needsUpdate && !a.offersReplace(im))
        #expect(a.matchNote(im) == "Only the name matches, so this may be a different app rather than an older version of it.")
        #expect(a.evidence(im) == .nameOnly)
    }

    @Test func differentAppsListedUnderNoCask() throws {
        let a = try store()
        let names = a.rows(.noCask).compactMap { a.differentAppNote($0) != nil ? $0.app.displayName : nil }
        #expect(Set(names).isSuperset(of: ["Copilot", "Outline", "Caffeine", "Paper", "Vienna", "Base", "Goose"]))
        let ch = try row(a, "ChatGPT.app")
        #expect(a.group(ch) == .cantAdopt && a.evidence(ch) == .developer)
        #expect(a.verdict(ch) == .blocked(.unverifiedSelfUpdating))
    }
}
