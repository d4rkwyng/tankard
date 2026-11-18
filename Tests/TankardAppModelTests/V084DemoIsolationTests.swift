import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4: demo mode shows the fixtures only, never this Mac's disk (its
// screenshots are published). Demo's own prefixes (/opt/homebrew,
// /usr/local) hold the real brew on a real Mac, so these run the demo
// against a stand-in prefix (a temp dir) with decoys in it.
@MainActor
struct V084DemoIsolationTests {
    final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ p: String) { lock.lock(); list.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// The demo store at `prefix`, with every path hook recording what it is asked.
    func demoStore(_ variant: Demo.Variant, prefix: URL, paths: Paths) throws -> AppStore {
        var deps = Demo.dependencies(variant, pace: 0, prefix: prefix.path)
        var client = try deps.makeClient()
        #expect(client.caskFolderTime == nil, "demo mode must not read the Caskroom")
        let exists = client.fileExists
        client.fileExists = { paths.add($0); return exists($0) }
        let c = client
        deps.makeClient = { c }
        let caskroom = deps.selfCaskroomExists, probe = deps.appManagementProbeExists
        deps.selfCaskroomExists = { paths.add($0); return caskroom($0) }
        deps.appManagementProbeExists = { paths.add($0); return probe($0) }
        return AppStore(deps: deps, settings: testSettings())
    }

    /// A decoy install folder per demo cask, dated so that reading it would
    /// change the date shown (brew's value taken as already correct).
    func plantDecoys(in prefix: URL) throws {
        let info = try JSONDecoder().decode(BrewInfoJSON.self, from: Demo.fixtureInfo(.arm64))
        for c in info.casks {
            guard let v = c.installed, let t = c.installedTime else { continue }
            let d = prefix.appendingPathComponent("Caskroom/\(c.token)/.metadata/\(v)/20200101000000.000/Casks")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)],
                                                  ofItemAtPath: d.deletingLastPathComponent().path)
        }
    }

    @Test func caskDatesComeFromTheFixturesAlone() async throws {
        let decoy = try tempDir(), empty = try tempDir()
        defer { try? FileManager.default.removeItem(at: decoy); try? FileManager.default.removeItem(at: empty) }
        try plantDecoys(in: decoy)
        let a = try demoStore(.arm64, prefix: decoy, paths: Paths())
        let b = try demoStore(.arm64, prefix: empty, paths: Paths())
        await a.start(); await b.start()
        let dates = { (s: AppStore) in s.packages.filter { $0.kind == .cask }.map { "\($0.name) \($0.installedAt.map { "\($0.timeIntervalSince1970)" } ?? "-")" } }
        #expect(!dates(a).isEmpty)
        #expect(dates(a) == dates(b))
        // The fixture's brew value with the (folder-less) correction.
        let chrome = try #require(a.packages.first { $0.name == "google-chrome" })
        #expect(chrome.installedAt == CaskInstallTime.date(brewInstalledTime: 1_794_368_601, folderTime: nil))
    }

    @Test(arguments: [Demo.Variant.arm64, .intelbrew])
    func nothingOutsideTheStandInPrefixIsAsked(variant: Demo.Variant) async throws {
        let prefix = try tempDir()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try plantDecoys(in: prefix)
        let paths = Paths()
        let store = try demoStore(variant, prefix: prefix, paths: paths)
        await store.start()
        await store.refresh(manual: false)
        // What the window asks about: Show in Finder, Tankard's own cask,
        // the App Management check, Intelbrew's revert plan.
        for p in store.packages where p.kind == .formula {
            _ = store.pathExists("\(prefix.path)/Cellar/\(p.name)/\(p.installedVersion)")
        }
        _ = store.needsSelfCaskRead
        _ = store.revertPlan()
        let home = ["/Users/demo/", "/Users/you/"]
        let outside = paths.all.filter { p in !p.hasPrefix(prefix.path + "/") && !home.contains { p.hasPrefix($0) } }
        #expect(outside.isEmpty, "demo asked about real paths: \(outside)")
        #expect(!paths.all.contains { $0.hasPrefix("/Applications") })
        // Demo's answers are made up, not looked up: a planted folder doesn't exist for it.
        let c = try store.resolvedClient()
        #expect(!c.fileExists(prefix.appendingPathComponent("Caskroom").path))
    }
}
