import Foundation
import Testing
@testable import TankardCore

// 0.8.6: the 0.8.5 Adopt matching sweep (T3-M4, 2026-11-18). Fixtures:
// adopt-sweep-casks.json is the casks the sweep's examples touch, copied
// from formulae.brew.sh's cask.json (7,838 casks, 2026-11-18);
// adopt-sweep-apps.json is the sweep's 52 dummy apps (path, bundle id,
// version; some ids assumed, as noted there). The apps are written as
// real bundles (an Info.plist each) and read with AppScanner, as the
// sweep did, then treated as being in /Applications.

struct V086AdoptSweepTests {
    struct Meta: Decodable { var path: String; var bid: String; var ver: String }

    static func index() throws -> AdoptIndex { try AdoptIndex.decode(caskJSON: Fixture.data("adopt-sweep-casks")) }

    static func casks() throws -> [BrewInfoJSON.Cask] {
        try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: Fixture.data("adopt-sweep-casks"))
    }

    /// The dummy apps, written to a temporary folder and scanned.
    static func apps() throws -> [InstalledApp] {
        let meta = try JSONDecoder().decode([Meta].self, from: Fixture.data("adopt-sweep-apps"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-adopt-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for m in meta {
            let contents = root.appendingPathComponent(m.path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let name = ((m.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let plist: [String: Any] = ["CFBundleIdentifier": m.bid, "CFBundleShortVersionString": m.ver,
                                        "CFBundleVersion": m.ver, "CFBundleName": name]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let scanned = AppScanner.scan(roots: [root.path])
        #expect(scanned.count == meta.count)
        return scanned.map { a in
            var b = a
            b.root = AppScanner.systemApplications
            b.path = AppScanner.systemApplications + "/" + a.relativePath
            return b
        }
    }

    static func rows() throws -> [String: AdoptRow] {
        let scan = AdoptMatcher.match(try apps(), index: try index(), managed: ManagedApps())
        return Dictionary(uniqueKeysWithValues: scan.rows.map { ($0.app.relativePath, $0) })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANKARD_SWEEP_DUMP"] != nil)) func dump() throws {
        for (k, r) in try Self.rows().sorted(by: { $0.key < $1.key }) {
            print("SWEEP \(k) [\(r.app.bundleID ?? "-") \(r.app.shortVersion ?? "-")] how=\(r.how?.rawValue ?? "-") "
                  + r.candidates.map { "\($0)[\(r.confidence[$0]!.rawValue)|\(r.evidence[$0]?.rawValue ?? "?")|\(r.verdicts[$0]!)]" }.joined(separator: " ")
                  + " rejected=\(r.rejected)")
        }
    }

    // MARK: H1: release lines (the version picks the cask)

    @Test func releaseLinesPickTheCaskTheVersionFits() throws {
        let r = try Self.rows()
        func best(_ p: String) -> String? { r[p]?.bestToken }
        #expect(best("Firefox.app") == "firefox@esr")
        #expect(best("Thunderbird.app") == "thunderbird@esr")
        #expect(best("Parallels Desktop.app") == "parallels@18")
        #expect(best("Beyond Compare.app") == "beyond-compare@4")
        #expect(best("1Password.app") == "1password@beta")
        #expect(best("Little Snitch.app") == "little-snitch@5")
        // Each is still a choice among several (never ticked by default:
        // V086AdoptSweepAppTests).
        for p in ["Firefox.app", "Thunderbird.app", "Parallels Desktop.app", "Beyond Compare.app", "1Password.app",
                  "Little Snitch.app", "Slack.app"] {
            #expect(r[p]?.isAmbiguous == true, "\(p)")
        }
        // Little Snitch 5: @5 names only its developer's IDs, and updates
        // itself, so it can't be adopted unchecked.
        #expect(r["Little Snitch.app"]?.verdicts["little-snitch@5"] == .blocked(.unverifiedSelfUpdating))
        // L1: variants in natural order after the pick.
        #expect(r["Parallels Desktop.app"]?.candidates == ["parallels@18", "parallels", "parallels@19", "parallels@20", "parallels@26"])
    }

    // MARK: H2: same name, different app

    @Test func sameNameDifferentAppIsNotOffered() throws {
        let r = try Self.rows()
        #expect(r["Copilot.app"]?.candidates == [] && r["Copilot.app"]?.rejected == ["copilot-money"])
        #expect(r["Outline.app"]?.candidates == [] && r["Outline.app"]?.rejected == ["getoutline", "outline"])
        #expect(r["Caffeine.app"]?.candidates == [] && r["Caffeine.app"]?.rejected == ["caffeine", "domzilla-caffeine"])
        // The right cask still wins where the ID backs it.
        #expect(r["Zen.app"]?.candidates == ["zen"] && r["Zen.app"]?.rejected == ["irbis-zen"])
        #expect(r["Whale.app"]?.candidates == ["naver-whale"])
        #expect(r["Loop.app"]?.candidates == ["loop"])
        #expect(r["Helium.app"]?.candidates == ["helium-browser"])
        #expect(r["Amethyst.app"]?.candidates == ["amethyst"])
    }

    @Test func selfUpdatingCaskNeedsTheAppID() throws {
        let r = try Self.rows()
        // ChatGPT: the chatgpt cask names only Codex ids (com.openai.*): the developer, not the app.
        #expect(r["ChatGPT.app"]?.verdicts["chatgpt"] == .blocked(.unverifiedSelfUpdating))
        #expect(r["ChatGPT.app"]?.confidence["chatgpt"] == .medium)
        #expect(r["1Password 7.app"]?.verdicts["1password@7"] == .blocked(.unverifiedSelfUpdating))
        // Nothing name-only or developer-only is ready for a self-updating cask.
        let idx = try Self.index()
        for row in r.values {
            for t in row.candidates where idx.byToken[t]?.autoUpdates == true && row.confidence[t] != .high {
                #expect(row.verdicts[t].map(AdoptGroupProbe.isReady) != true, "\(row.app.relativePath) \(t)")
            }
        }
    }

    // MARK: H3: the right line is ready, the wrong one needs an update

    @Test func oldLinesAreReadyAsTheirOwnCask() throws {
        let r = try Self.rows()
        #expect(r["Godot.app"]?.bestToken == "godot@3" && r["Godot.app"]?.verdicts["godot@3"] == .ready)
        #expect(r["LibreOffice.app"]?.bestToken == "libreoffice-still" && r["LibreOffice.app"]?.verdicts["libreoffice-still"] == .ready)
        #expect(r["Blender.app"]?.bestToken == "blender@lts" && r["Blender.app"]?.verdicts["blender@lts"] == .ready)
        #expect(r["Couchbase Server.app"]?.isAmbiguous == true)
    }

    // MARK: M1: shared prefixes are not a developer

    @Test func sharedPrefixesAreNotADeveloper() throws {
        let r = try Self.rows()
        #expect(r["Paper.app"]?.candidates == [] && r["Paper.app"]?.rejected == ["paper-design"])
        #expect(r["Vienna.app"]?.candidates == [] && r["Vienna.app"]?.rejected == ["vienna"])
        #expect(r["Base.app"]?.candidates == [] && r["Base.app"]?.rejected == ["base"])
        #expect(r["Goose.app"]?.candidates == [] && r["Goose.app"]?.rejected == ["block-goose"])
        #expect(AdoptVendor.vendorLabelCount(["com", "electron", "goose"]) == 3)
        #expect(AdoptVendor.vendorLabelCount(["uk", "co", "example", "vienna"]) == 3)
        #expect(AdoptVendor.vendorLabelCount(["jp", "co", "x", "y"]) == 3)
        #expect(AdoptVendor.vendorLabelCount(["com", "todesktop", "abc"]) == 3)
        #expect(AdoptVendor.vendorLabelCount(["org", "scummvm", "app"]) == 2)
        // A team id or group. prefix is dropped before comparing.
        #expect(AdoptMatcher.sameVendor("com.agilebits.onepassword7", ["2bua8c4s2c.com.agilebits.x"]))
        #expect(AdoptMatcher.sameVendor("com.foo.bar", ["group.com.foo.baz"]))
        #expect(!AdoptMatcher.sameVendor("com.electron.a", ["com.electron.b"]))
    }

    // MARK: M2: Impactor (a different product, no ids in the cask)

    @Test func impactorIsNameOnly() throws {
        let r = try Self.rows()
        let im = try #require(r["Impactor.app"])
        #expect(im.candidates == ["impactor"] && im.confidence["impactor"] == .low)
        #expect(im.evidence["impactor"] == AdoptMatcher.IDEvidence.none)
    }

    // MARK: M3: an app found by ID only uses the cask's own ids

    @Test func bundleIDFallbackUsesOwnIDsOnly() throws {
        let r = try Self.rows()
        // bookends' zap trashes ~/Library/Application Scripts/com.microsoft.Word/...: not Word's cask.
        #expect(r["Microsoft Word.app"]?.candidates.contains("bookends") != true)
        #expect(try Self.index().byToken["bookends"]?.ownBundleIDs.contains("com.microsoft.word") == false)
        // wondershare-uniconverter quits com.google.Chrome; a renamed Chrome is google-chrome's.
        #expect(r["Chrome.app"]?.candidates == ["google-chrome"])
        #expect(r["Microsoft Teams.app"]?.candidates == ["microsoft-teams"])
    }

    // MARK: M4: another cask's quit id doesn't hide an app

    @Test func quitIDNeedsTheName() throws {
        let classifier = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false)
        var casks = try Self.casks().filter { ["chatgpt", "wondershare-uniconverter", "google-chrome"].contains($0.token) }
        for i in casks.indices { casks[i].installed = casks[i].version }
        let pkgs = casks.map { classifier.classify(cask: $0, outdated: false) }
        let chatgpt = ManagedApps(packages: pkgs.filter { $0.name == "chatgpt" }, index: nil)
        #expect(pkgs.first { $0.name == "chatgpt" }?.quitBundleIDs?.contains("com.openai.codex") == true)
        let codex = InstalledApp(path: "/Applications/Codex.app", root: "/Applications", relativePath: "Codex.app",
                                 bundleID: "com.openai.codex", shortVersion: "1.0", bundleVersion: "1")
        #expect(!chatgpt.owns(codex))
        let uni = ManagedApps(packages: pkgs.filter { $0.name == "wondershare-uniconverter" }, index: nil)
        let chrome = InstalledApp(path: "/Applications/Google Chrome.app", root: "/Applications", relativePath: "Google Chrome.app",
                                  bundleID: "com.google.Chrome", shortVersion: "142.0", bundleVersion: "142.0")
        #expect(!uni.owns(chrome))
        // google-chrome itself still owns a moved Chrome with its name.
        let gc = ManagedApps(packages: pkgs.filter { $0.name == "google-chrome" }, index: nil)
        var moved = chrome
        moved.path = "/Applications/Browsers/Google Chrome.app"
        moved.relativePath = "Browsers/Google Chrome.app"
        #expect(gc.owns(moved))
    }
}

enum AdoptGroupProbe {
    static func isReady(_ v: AdoptVerdict) -> Bool { v == .ready || v == .readyUnchecked }
}
