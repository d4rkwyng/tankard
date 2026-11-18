import Foundation
import Testing
@testable import TankardCore

// 0.8.5: Adopt Apps listed Microsoft apps that brew already installed
// (microsoft-word, -excel, -outlook, -powerpoint, -teams, windows-app) and
// said it couldn't adopt them: they are pkg casks, `brew info` lists no
// `app` for them, so nothing tied the app on disk to the installed cask.
// The fixture is real `brew info --cask --json=v2` output (2026-11-18).

struct V085AdoptPkgCaskTests {
    static func app(_ rel: String, _ bid: String?, _ short: String? = "16.115", display: String? = nil) -> InstalledApp {
        InstalledApp(path: "/Applications/" + rel, root: "/Applications", relativePath: rel, bundleID: bid,
                     shortVersion: short, bundleVersion: short, displayName: display)
    }

    /// The fixture's casks, as installed ones (the capture was made where
    /// they aren't installed), keeping only `only` when given.
    static func installed(_ only: Set<String>? = nil) throws -> (casks: [BrewInfoJSON.Cask], packages: [Package]) {
        var casks = try Fixture.info("microsoft-pkg-casks-info").casks
        if let only { casks = casks.filter { only.contains($0.token) } }
        for i in casks.indices { casks[i].installed = casks[i].version }
        let classifier = StatusClassifier(platform: .armGoldenGate, intelbrewMode: false)
        return (casks, casks.map { classifier.classify(cask: $0, outdated: false) })
    }

    static let microsoftApps: [InstalledApp] = [
        app("Microsoft Word.app", "com.microsoft.Word"),
        app("Microsoft Excel.app", "com.microsoft.Excel"),
        app("Microsoft Outlook.app", "com.microsoft.Outlook"),
        app("Microsoft PowerPoint.app", "com.microsoft.Powerpoint"),
        app("Microsoft Teams.app", "com.microsoft.teams2"),
        app("Windows App.app", "com.microsoft.rdc.macos", "11.4.5"),
    ]

    @Test func decodesReceiptsDeletePathsAndHints() throws {
        let (casks, packages) = try Self.installed()
        let byToken = Dictionary(uniqueKeysWithValues: casks.map { ($0.token, $0) })
        // The premise: no app stanza, so no app path from brew.
        for c in casks {
            #expect(c.appPaths == [], "\(c.token)")
            #expect(c.installsPkg == true, "\(c.token)")
        }
        let word = try #require(byToken["microsoft-word"]?.ownership)
        #expect(word.names == ["Microsoft Word"])
        #expect(word.receiptIDs == ["com.microsoft.package.Microsoft_Word.app", "com.microsoft.pkg.licensing",
                                    "com.microsoft.pkg.licensing.v3"])
        #expect(word.appPaths.isEmpty)
        #expect(word.bundleIDHints.contains("com.microsoft.word"))
        #expect(byToken["microsoft-powerpoint"]?.ownership?.appPaths == ["/Applications/Microsoft PowerPoint.app"])
        #expect(byToken["microsoft-teams"]?.ownership?.appPaths == ["/Applications/Microsoft Teams.app"])
        #expect(byToken["windows-app"]?.ownership?.receiptIDs == ["com.microsoft.rdc.macos"])
        // And it reaches the Package (what ManagedApps reads).
        #expect(packages.first { $0.name == "microsoft-word" }?.caskOwnership == word)
    }

    @Test func installedPkgCasksOwnTheirApps() throws {
        let (casks, packages) = try Self.installed()
        let managed = ManagedApps(packages: packages, index: nil)
        for a in Self.microsoftApps {
            #expect(managed.owns(a), "\(a.fileName)")
        }
        // The Adopt scan leaves them out as "already from Homebrew".
        let index = AdoptIndex(casks: casks.map(AdoptCask.init))
        let scan = AdoptMatcher.match(Self.microsoftApps, index: index, managed: managed)
        #expect(scan.rows.isEmpty)
        #expect(scan.skipped.managed.count == Self.microsoftApps.count)
    }

    @Test func pkgCaskHintsDontHideOtherApps() throws {
        let (_, packages) = try Self.installed(["microsoft-word"])
        let managed = ManagedApps(packages: packages, index: nil)
        #expect(managed.owns(Self.app("Microsoft Word.app", "com.microsoft.Word")))
        // Excel installed by hand while only Word is brew's: still adoptable.
        #expect(!managed.owns(Self.app("Microsoft Excel.app", "com.microsoft.Excel")))
        // A cask's hint needs the cask's name: another app that happens to
        // carry the id (or one only zap names) is not Homebrew's.
        #expect(!managed.owns(Self.app("Word Helper.app", "com.microsoft.Word")))
        #expect(!managed.owns(Self.app("OneDrive.app", "com.microsoft.OneDrive")))
        // The licensing receipt ids are not app ids anyone has, and
        // com.microsoft.autoupdate2 (what uninstall quits) is Microsoft
        // AutoUpdate, which the Word pkg installs too: owning it is right.
        #expect(managed.owns(Self.app("Microsoft AutoUpdate.app", "com.microsoft.autoupdate2")))
    }

    @Test func receiptsGiveTheAppPath() throws {
        let (_, packages) = try Self.installed(["microsoft-word"])
        // Renamed by the user and no bundle id read: only the receipt ties it.
        let renamed = Self.app("Word.app", nil)
        let base = ManagedApps(packages: packages, index: nil)
        #expect(base.receiptIDs.contains("com.microsoft.package.Microsoft_Word.app"))
        #expect(!base.owns(renamed))
        let withReceipts = base.adding(receiptApps: ["com.microsoft.package.Microsoft_Word.app": ["/Applications/Word.app"],
                                                      "com.other.pkg": ["/Applications/Other.app"]])
        #expect(withReceipts.owns(renamed))
        // A receipt of no installed cask adds nothing.
        #expect(!withReceipts.owns(Self.app("Other.app", nil)))
    }

    @Test func receiptDirectoryListToAppPaths() {
        let dirs = ["Microsoft Word.app", "Microsoft Word.app/Contents", "Microsoft Word.app/Contents/Helpers/Inner.app",
                    "Utilities/Tool.app", "Library", "./Other.app"]
        #expect(PkgReceipts.appPaths(volume: "/", installLocation: "Applications", dirs: dirs)
                == ["/Applications/Microsoft Word.app", "/Applications/Utilities/Tool.app", "/Applications/Other.app"])
        #expect(PkgReceipts.appPaths(volume: "/", installLocation: "", dirs: ["Applications/Foo.app", "Applications/Foo.app/Contents"])
                == ["/Applications/Foo.app"])
    }

    @Test func patternReceiptIDsAreNotBundleIDs() {
        let o = CaskAppOwnership(names: ["X"], receiptIDs: ["com.example.*", "com.example.app", "com\\.foo\\..*"],
                                 deletePaths: ["/Applications/X.app", "/Library/X", "/Applications/Y*.app"], idStrings: [])
        #expect(o.plainReceiptIDs == ["com.example.app"])
        #expect(o.appPaths == ["/Applications/X.app"])
    }
}
