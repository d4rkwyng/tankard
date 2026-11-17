import Foundation
import Testing
@testable import TankardCore

// v0.8: Adopt Apps, the core side: cask artifacts and bundle ids from
// cask.json, the app scan (Mac App Store receipts), version comparison,
// matching and the command.

struct V08AdoptCoreTests {
    /// Real cask.json entries (formulae.brew.sh, 2026-11-17), trimmed.
    static let caskJSON = #"""
    [
     {"token":"hiddenbar","full_token":"hiddenbar","tap":"homebrew/cask","name":["Hidden Bar"],"homepage":"https://github.com/dwarvesf/hidden/","url":"https://github.com/dwarvesf/hidden/releases/download/v1.13.0/Hidden.Bar.1.13.0.dmg","version":"1.13.0","auto_updates":null,
      "artifacts":[{"uninstall":[{"launchctl":"com.dwarvesv.LauncherApplication","quit":"com.dwarvesv.minimalbar"}]},{"app":["Hidden Bar.app"],"target":"/Applications/Hidden Bar.app"},{"zap":[{"trash":["~/Library/Containers/com.dwarvesv.minimalbar","~/Library/Preferences/com.dwarvesv.minimalbar.plist"]}]}]},
     {"token":"obsidian","full_token":"obsidian","tap":"homebrew/cask","version":"1.15.1","auto_updates":true,
      "artifacts":[{"app":["Obsidian.app"],"target":"/Applications/Obsidian.app"},{"binary":["$APPDIR/Obsidian.app/Contents/MacOS/obsidian-cli",{"target":"obsidian"}],"target":"$HOMEBREW_PREFIX/bin/obsidian"},{"zap":[{"trash":["~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/md.obsidian.sfl*","~/Library/Application Support/obsidian","~/Library/Preferences/md.obsidian.plist","~/Library/Saved Application State/md.obsidian.savedState"]}]}]},
     {"token":"firefox","full_token":"firefox","tap":"homebrew/cask","version":"160.0","auto_updates":true,
      "artifacts":[{"app":["Firefox.app"],"target":"/Applications/Firefox.app"},{"zap":[{"trash":["~/Library/Preferences/org.mozilla.firefox.plist"]}]}]},
     {"token":"firefox@beta","full_token":"firefox@beta","tap":"homebrew/cask","version":"161.0b4","auto_updates":true,
      "artifacts":[{"app":["Firefox.app"],"target":"/Applications/Firefox.app"},{"zap":[{"trash":["~/Library/Preferences/org.mozilla.firefox.plist"]}]}]},
     {"token":"kicad","full_token":"kicad","tap":"homebrew/cask","version":"10.0.8",
      "artifacts":[{"suite":["KiCad"],"target":"/Applications/KiCad"},{"binary":["$APPDIR/KiCad/KiCad.app/Contents/MacOS/kicad-cli"],"target":"$HOMEBREW_PREFIX/bin/kicad-cli"}]},
     {"token":"zoom","full_token":"zoom","tap":"homebrew/cask","version":"7.2.5.90525","auto_updates":true,
      "artifacts":[{"uninstall":[{"launchctl":["us.zoom.updater"],"signal":["KILL","us.zoom.xos"],"pkgutil":"us.zoom.pkg.videomeeting","delete":["/Applications/zoom.us.app"]}]},{"pkg":["zoomusInstallerFull.pkg"]}]},
     {"token":"impactor","full_token":"impactor","tap":"homebrew/cask","homepage":"https://github.com/khcrysalis/Impactor","version":"2.7.2",
      "artifacts":[{"app":["Impactor.app"],"target":"/Applications/Impactor.app"},{"zap":[{"trash":["~/Library/Preferences/thewonderofyou.Impactor.plist"]}]}]},
     {"token":"renamed","full_token":"renamed","tap":"homebrew/cask","version":"2.0,200",
      "artifacts":[{"app":["Some App 2.app",{"target":"Some App.app"}],"target":"/Applications/Some App.app"}]},
     {"token":"latest-thing","full_token":"latest-thing","tap":"homebrew/cask","version":"latest",
      "artifacts":[{"app":["Latest.app"],"target":"/Applications/Latest.app"}]}
    ]
    """#

    static func index() throws -> AdoptIndex { try AdoptIndex.decode(caskJSON: Data(caskJSON.utf8)) }

    static func app(_ rel: String, _ bid: String?, _ short: String?, _ build: String? = nil, root: String = "/Applications",
                    mas: Bool = false) -> InstalledApp {
        InstalledApp(path: root + "/" + rel, root: root, relativePath: rel, bundleID: bid, shortVersion: short,
                     bundleVersion: build ?? short, hasMASReceipt: mas)
    }

    // MARK: decoding

    @Test func decodesAppTargetsSuitesPkgAndBundleIDs() throws {
        let casks = try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: Data(Self.caskJSON.utf8))
        let by = Dictionary(uniqueKeysWithValues: casks.map { ($0.token, AdoptCask($0)) })
        let hb = try #require(by["hiddenbar"])
        #expect(hb.apps == [.init(source: "Hidden Bar.app", target: "/Applications/Hidden Bar.app")])
        #expect(hb.bundleIDs == ["com.dwarvesv.minimalbar", "com.dwarvesv.launcherapplication"])
        #expect(hb.web.contains("github.com/dwarvesf"))
        #expect(by["obsidian"]?.bundleIDs == ["md.obsidian"])
        #expect(by["obsidian"]?.autoUpdates == true)
        #expect(by["kicad"]?.suites == ["/Applications/KiCad"])
        #expect(by["kicad"]?.apps.isEmpty == true)
        #expect(by["zoom"]?.pkg == true)
        #expect(by["zoom"]?.bundleIDs.contains("us.zoom.xos") == true)
        #expect(by["renamed"]?.apps == [.init(source: "Some App 2.app", target: "/Applications/Some App.app")])
        // The 0.5 fields are unchanged.
        #expect(casks.first { $0.token == "hiddenbar" }?.appPaths == ["/Applications/Hidden Bar.app"])
        #expect(casks.first { $0.token == "hiddenbar" }?.quitBundleIDs == ["com.dwarvesv.minimalbar"])
    }

    @Test func bundleIDHintsRules() {
        let ids = AdoptIndex.bundleIDHints([
            "~/Library/Preferences/md.obsidian.plist",       // 2 labels with a file suffix: yes
            "md.obsidian",                                    // 2 labels bare: could be a domain, no
            "com.apple.LSSharedFileList.ApplicationRecentDocuments", // Apple's: no
            "~/Library/Caches/com.example.*",                 // wildcard inside: no
            "~/Library/Saved Application State/org.foo.Bar.savedState",
            "KILL", "~/Library/Application Support/obsidian",
            "us.zoom.xos",
        ])
        #expect(ids == ["md.obsidian", "org.foo.bar", "us.zoom.xos"])
    }

    // MARK: scanning

    @Test func scanReadsPlistsOneLevelDownAndNeedsAReceiptFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-adopt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ rel: String, _ bid: String, _ v: String, receipt: Bool? = nil) throws {
            let contents = root.appendingPathComponent(rel).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bid, "CFBundleShortVersionString": v, "CFBundleVersion": "42", "CFBundleName": "N"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            if let receipt {
                let dir = contents.appendingPathComponent("_MASReceipt")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if receipt { try Data("x".utf8).write(to: dir.appendingPathComponent("receipt")) }
            }
        }
        try make("Plain.app", "com.example.plain", "1.0")
        try make("Store.app", "com.example.store", "2.0", receipt: true)
        try make("EmptyReceiptDir.app", "com.example.tgpro", "3.0", receipt: false)
        try make("Suite/Inner.app", "com.example.inner", "4.0")
        try make("Deep/Deeper/Hidden.app", "com.example.hidden", "5.0")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("LinkedFolder"),
                                                   withDestinationURL: root.appendingPathComponent("Suite"))
        let apps = AppScanner.scan(roots: [root.path])
        #expect(apps.map(\.relativePath) == ["EmptyReceiptDir.app", "Plain.app", "Store.app", "Suite/Inner.app"])
        let by = Dictionary(uniqueKeysWithValues: apps.map { ($0.relativePath, $0) })
        #expect(by["Store.app"]?.hasMASReceipt == true)
        #expect(by["EmptyReceiptDir.app"]?.hasMASReceipt == false)
        #expect(by["Plain.app"]?.bundleID == "com.example.plain")
        #expect(by["Plain.app"]?.shortVersion == "1.0")
        #expect(by["Plain.app"]?.bundleVersion == "42")
        #expect(by["Suite/Inner.app"]?.fileName == "Inner.app")
    }

    // MARK: versions

    @Test func versionComparison() {
        let a = Self.app("X.app", "com.x.x", "1.13.0", "14")
        #expect(AdoptVersion.verdict(app: a, caskVersion: "1.13.0", autoUpdates: false) == .ready)
        #expect(AdoptVersion.verdict(app: a, caskVersion: "1.14.0", autoUpdates: false) == .needsUpdate(installed: "1.13.0", cask: "1.14.0"))
        // auto_updates: brew skips the comparison (moved.rb:102).
        #expect(AdoptVersion.verdict(app: a, caskVersion: "1.14.0", autoUpdates: true) == .ready)
        // Only the part before the comma is compared.
        #expect(AdoptVersion.verdict(app: Self.app("U.app", nil, "4.3.9", "147"), caskVersion: "4.3.9,147,1742287964", autoUpdates: false) == .ready)
        #expect(AdoptVersion.split("4.3.9,147,1742287964") == ("4.3.9", ["147", "1742287964"]))
        // A cask that carries the build number.
        #expect(AdoptVersion.verdict(app: Self.app("B.app", nil, "2.1", "2105"), caskVersion: "2105", autoUpdates: false) == .ready)
        #expect(AdoptVersion.verdict(app: a, caskVersion: "latest", autoUpdates: false) == .readyUnchecked)
        #expect(AdoptVersion.verdict(app: Self.app("N.app", nil, nil, nil), caskVersion: "1.0", autoUpdates: false) == .blocked(.noVersion))
    }

    // MARK: matching

    @Test func matchesGroupsAndConfidence() throws {
        let idx = try Self.index()
        let apps = [
            Self.app("Hidden Bar.app", "com.dwarvesv.minimalbar", "1.13.0"),
            Self.app("Obsidian.app", "md.obsidian", "1.12.4"),
            Self.app("Firefox.app", "org.mozilla.firefox", "160.0"),
            Self.app("KiCad/GerbView.app", "org.kicad.gerbview", "10.0.6"),
            Self.app("KiCad/KiCad.app", "org.kicad.kicad", "10.0.6"),
            Self.app("KiCad/PCB Editor.app", "org.kicad.pcbnew", "10.0.6"),
            Self.app("zoom.us.app", "us.zoom.xos", "7.2.0"),
            Self.app("Impactor.app", "com.saurik.Impactor", "0.9.56"),
            Self.app("Hidden Bar.app", "com.dwarvesv.minimalbar", "1.13.0", root: "/Users/you/Applications"),
            Self.app("Some App.app", "com.some.app", "2.0", "200"),
            Self.app("Acme.app", "com.example.acme", "1.0"),
            Self.app("Safari.app", "com.apple.Safari", "27.0"),
            Self.app("Things3.app", "com.culturedcode.ThingsMac", "3.21", mas: true),
            Self.app("Managed.app", "com.example.managed", "1.0"),
        ]
        let managed = ManagedApps(paths: ["/Applications/Managed.app"])
        let scan = AdoptMatcher.match(apps, index: idx, managed: managed)
        #expect(scan.skipped.apple.map(\.relativePath) == ["Safari.app"])
        #expect(scan.skipped.appStore.map(\.relativePath) == ["Things3.app"])
        #expect(scan.skipped.managed.map(\.relativePath) == ["Managed.app"])
        func row(_ path: String) throws -> AdoptRow { try #require(scan.rows.first { $0.app.path == path }) }

        let hb = try row("/Applications/Hidden Bar.app")
        #expect(hb.how == .targetPath && hb.bestToken == "hiddenbar")
        #expect(hb.confidence["hiddenbar"] == .high && hb.verdicts["hiddenbar"] == .ready)

        // Two-label bundle id from the zap's .plist name; auto_updates: any version adopts.
        let ob = try row("/Applications/Obsidian.app")
        #expect(ob.confidence["obsidian"] == .high && ob.verdicts["obsidian"] == .ready)

        // Ambiguous: the plain cask first, both corroborated.
        let ff = try row("/Applications/Firefox.app")
        #expect(ff.candidates == ["firefox", "firefox@beta"] && ff.isAmbiguous)
        #expect(ff.confidence["firefox"] == .high)

        // One row for the suite folder, the app named after it.
        #expect(scan.rows.filter { $0.how == .suite }.map(\.app.relativePath) == ["KiCad/KiCad.app"])
        let kc = try row("/Applications/KiCad/KiCad.app")
        #expect(kc.how == .suite && kc.verdicts["kicad"] == .blocked(.suite("KiCad")))

        // Found by bundle id (the pkg cask has no app artifact), blocked as pkg.
        let zm = try row("/Applications/zoom.us.app")
        #expect(zm.how == .bundleID && zm.verdicts["zoom"] == .blocked(.pkg))

        // A different product with the same name: the cask names other ids.
        let im = try row("/Applications/Impactor.app")
        #expect(im.confidence["impactor"] == .low)
        #expect(im.verdicts["impactor"] == .needsUpdate(installed: "0.9.56", cask: "2.7.2"))

        // ~/Applications: brew adopts only at the cask's target.
        let home = try row("/Users/you/Applications/Hidden Bar.app")
        #expect(home.verdicts["hiddenbar"] == .blocked(.location(expected: "/Applications/Hidden Bar.app")))

        // A renamed target (app: "Some App 2.app", target: "Some App.app").
        let rn = try row("/Applications/Some App.app")
        #expect(rn.how == .targetPath && rn.verdicts["renamed"] == .ready)
        // Name only, no ids, no vendor in the (absent) homepage: low.
        #expect(rn.confidence["renamed"] == .low)

        let none = try row("/Applications/Acme.app")
        #expect(none.candidates.isEmpty && none.how == nil)
    }

    @Test func managedAppsFromInstalledCasks() throws {
        var p = Package.command("visual-studio-code")
        p.kind = .cask
        p.appPaths = ["/Applications/Visual Studio Code.app"]
        p.quitBundleIDs = ["com.microsoft.VSCode"]
        let m = ManagedApps(packages: [p], index: nil)
        #expect(m.owns(Self.app("Visual Studio Code.app", "com.microsoft.VSCode", "1.0")))
        // Moved or renamed, still the same bundle id: brew owns it.
        #expect(m.owns(Self.app("VSCode.app", "com.microsoft.vscode", "1.0")))
        #expect(!m.owns(Self.app("Other.app", "com.other", "1.0")))
    }

    @Test func adoptCommandIsLiteralArgv() {
        #expect(AdoptCommands.arguments(qualifiedName: "homebrew/cask/hiddenbar") == ["install", "--cask", "--adopt", "homebrew/cask/hiddenbar"])
        #expect(AdoptCommands.replaceArguments(qualifiedName: "homebrew/cask/gimp") == ["install", "--cask", "--force", "homebrew/cask/gimp"])
        #expect(AdoptCask(token: "x", version: "1").qualifiedName == "homebrew/cask/x")
        #expect(AdoptCask(token: "x", tap: nil, version: "1").qualifiedName == "x")
    }

    @Test func unmarkKeepsHomebrewUpdatedCasks() {
        var a = Package.command("a"); a.kind = .cask; a.upgradeAvailable = true; a.selfUpdatingUpgrade = true
        var b = Package.command("b"); b.kind = .cask; b.upgradeAvailable = true; b.selfUpdatingUpgrade = true
        let r = StatusReport(generatedAt: Date(), host: HostInfo(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew",
                                                                 platform: .armGoldenGate, bottleTag: "arm64_golden_gate"),
                             intelbrew: IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:]),
                             fork: ForkStatus(brewRepository: "/opt/homebrew"), packages: [a, b])
        let out = SelfUpdatingCasks.unmark(r, keeping: { $0.name == "b" })
        #expect(out.packages.map(\.upgradeAvailable) == [false, true])
        #expect(SelfUpdatingCasks.unmark(r).packages.map(\.upgradeAvailable) == [false, false])
    }
}
