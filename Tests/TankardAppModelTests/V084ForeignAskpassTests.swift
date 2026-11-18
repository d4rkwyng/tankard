import AskpassSupport
import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4: a SUDO_ASKPASS in brew.env that isn't Tankard's own helper. brew
// would run `sudo -A` with it (brew.env beats the environment Tankard passes),
// so Tankard's password dialog is never offered for such a step: it runs with
// HOMEBREW_NO_SUDO=1, or is refused when that can't hold, and the sheet shows
// the Terminal command. No real sudo or password here.

/// A streaming runner that records each command's arguments and environment.
final class EnvRecordingRunner: StreamingCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(args: [String], env: [String: String])] = []
    let behaviour: @Sendable ([String], @escaping @Sendable (Data) -> Void) async -> Int32
    init(_ behaviour: @escaping @Sendable ([String], @escaping @Sendable (Data) -> Void) async -> Int32 = { _, _ in 0 }) {
        self.behaviour = behaviour
    }
    var calls: [(args: [String], env: [String: String])] { lock.withLock { _calls } }
    func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        lock.withLock { _calls.append((arguments, environment)) }
        return await behaviour(arguments, output)
    }
}

/// brew.env as the app would read it right now (changeable mid-session).
final class BrewEnvBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [(String, [String: String])]
    init(_ files: [(String, [String: String])] = []) { _files = files }
    var files: [(String, [String: String])] {
        get { lock.withLock { _files } }
        set { lock.withLock { _files = newValue } }
    }
}

struct ForeignAskpassDetectTests {
    let own = "/Applications/Tankard.app/Contents/MacOS/tankard-askpass"
    func files(_ vars: [String: String]) -> [(String, [String: String])] { [("~/.homebrew/brew.env", vars)] }

    @Test func unsetEmptyOrOwnIsNotForeign() {
        #expect(ForeignAskpass.detect(brewEnvFiles: [], own: own) == nil)
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": ""]), own: own) == nil)
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": own]), own: own) == nil)
    }

    @Test func ownHelperThroughASymlinkIsOurs() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("tankard-askpass")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        let link = dir.appendingPathComponent("link-askpass")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": link.path]), own: real.path) == nil)
    }

    @Test func anythingElseIsForeign() {
        let f = ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": "/Users/me/.local/bin/pw"]), own: own)
        #expect(f == ForeignAskpass(helper: "/Users/me/.local/bin/pw", source: "~/.homebrew/brew.env", unstoppable: false))
        // No helper of our own (swift run): any helper is foreign.
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": own]), own: nil) != nil)
        // bin/brew exports the value literally: quotes make it another path.
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": "\"\(own)\""]), own: own) != nil)
        // The last brew.env wins, as in bin/brew.
        let layered = [("/etc/homebrew/brew.env", ["SUDO_ASKPASS": own]), ("~/.homebrew/brew.env", ["SUDO_ASKPASS": "/x"])]
        #expect(ForeignAskpass.detect(brewEnvFiles: layered, own: own)?.helper == "/x")
    }

    @Test func unstoppableWhenBrewEnvClearsNoSudo() {
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": "/x", "HOMEBREW_NO_SUDO": ""]), own: own)?.unstoppable == true)
        #expect(ForeignAskpass.detect(brewEnvFiles: files(["SUDO_ASKPASS": "/x", "HOMEBREW_NO_SUDO": "1"]), own: own)?.unstoppable == false)
    }

    @Test func message() {
        let f = ForeignAskpass(helper: "/x/pw", source: "~/.homebrew/brew.env", unstoppable: false)
        #expect(f.message == "brew.env sets its own password helper (/x/pw); run this step in Terminal:")
        #expect(SudoOutcome.foreignHelper("/x/pw").message == f.message)
        #expect(UpgradeSession.foreignHelper(in: f.message)?.helper == "/x/pw")
        #expect(UpgradeSession.foreignHelper(in: "Couldn't find keg") == nil)
    }
}

@MainActor
struct AdminPasswordForeignTests {
    let own = "/Applications/Tankard.app/Contents/MacOS/tankard-askpass"
    let foreign = ForeignAskpass(helper: "/x/pw", source: "~/.homebrew/brew.env", unstoppable: false)
    let caskArgs = ["upgrade", "--cask", "google-chrome"]

    @Test func environmentNeverCarriesOurHelperWithAForeignOne() {
        let env = AdminPassword.environment(helper: own, arguments: caskArgs, package: nil, display: "d", foreign: foreign)
        #expect(env == [Askpass.noSudoKey: "1"])
        #expect(AdminPassword.environment(helper: own, arguments: caskArgs, package: nil, display: "d")[Askpass.askpassKey] == own)
        #expect(AdminPassword.environment(helper: own, arguments: ["upgrade", "xz"], package: nil, display: "d", foreign: foreign).isEmpty)
    }

    @Test func refusalRules() {
        let noSudo = [Askpass.noSudoKey: "1"]
        // Unset or ours: allowed.
        #expect(AdminPassword.refusal(arguments: caskArgs, package: nil, environment: [Askpass.askpassKey: own], foreign: nil) == nil)
        // Foreign, the step runs without sudo: allowed.
        #expect(AdminPassword.refusal(arguments: caskArgs, package: nil, environment: noSudo, foreign: foreign) == nil)
        // Foreign and the step was built with Tankard's helper, or with nothing: brew would run sudo -A with it.
        #expect(AdminPassword.refusal(arguments: caskArgs, package: nil, environment: [Askpass.askpassKey: own], foreign: foreign) == foreign.message)
        #expect(AdminPassword.refusal(arguments: caskArgs, package: nil, environment: [:], foreign: foreign) == foreign.message)
        // brew.env clears HOMEBREW_NO_SUDO: nothing stops sudo.
        var clearing = foreign
        clearing.unstoppable = true
        #expect(AdminPassword.refusal(arguments: caskArgs, package: nil, environment: noSudo, foreign: clearing) == foreign.message)
        // A pkg cask needs sudo: refused rather than run to fail.
        var chrome = Package.placeholder(kind: .cask, name: "google-chrome")
        chrome.installsPkg = true
        #expect(AdminPassword.refusal(arguments: caskArgs, package: chrome, environment: noSudo, foreign: foreign) == foreign.message)
        // Formulae never run sudo through Tankard.
        #expect(AdminPassword.refusal(arguments: ["upgrade", "xz"], package: nil, environment: [:], foreign: foreign) == nil)
    }
}

@MainActor
struct ForeignAskpassSessionTests {
    static let own = "/Applications/Tankard.app/Contents/MacOS/tankard-askpass"
    static let helper = "/Users/me/.local/bin/not-tankard-askpass"

    func store(_ box: BrewEnvBox, runner: EnvRecordingRunner) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = Self.own
        deps.streamRunner = runner
        deps.brewEnvFiles = { _ in box.files }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        return store
    }

    func upgradeChrome(_ store: AppStore, pkg: Bool) throws {
        if pkg { store.demoRequirePassword("google-chrome") }
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        if store.upgradePlan != nil { store.confirmUpgradePlan() }
    }

    func upgrades(_ r: EnvRecordingRunner) -> [(args: [String], env: [String: String])] {
        r.calls.filter { $0.args.first == "upgrade" }
    }

    @Test func foreignHelperRefusesAPkgCaskAndShowsTheCommand() async throws {
        let box = BrewEnvBox([("~/.homebrew/brew.env", ["SUDO_ASKPASS": Self.helper])])
        let runner = EnvRecordingRunner()
        let store = await store(box, runner: runner)
        #expect(store.foreignAskpass()?.helper == Self.helper)
        try upgradeChrome(store, pkg: true)
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        #expect(upgrades(runner).isEmpty)   // brew never started
        #expect(session.items.first?.state == .failed(-1))
        #expect(session.sudoOutcome == .foreignHelper(Self.helper))
        #expect(session.sudoOutcome?.message == "brew.env sets its own password helper (\(Self.helper)); run this step in Terminal:")
        #expect(session.sudoCommand == session.items.first?.command.display)
        #expect(session.sudoCommand?.hasPrefix("brew upgrade --cask") == true)
        #expect(session.items.first?.command.environment[Askpass.askpassKey] == nil)
        #expect(!session.log.lines.contains { $0.contains("Tankard will ask for your administrator password") })
    }

    @Test func foreignHelperRunsAnOrdinaryCaskWithoutSudo() async throws {
        let box = BrewEnvBox([("~/.homebrew/brew.env", ["SUDO_ASKPASS": Self.helper])])
        // As brew 7.0.14 does when a step turns out to need sudo under HOMEBREW_NO_SUDO.
        let runner = EnvRecordingRunner { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("Error: Failure while executing; `/usr/bin/true` exited with 1. Here's the output:\nsudo is disabled by HOMEBREW_NO_SUDO.\n".utf8))
            return 1
        }
        let store = await store(box, runner: runner)
        try upgradeChrome(store, pkg: false)
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        let call = try #require(upgrades(runner).first)
        #expect(call.env[Askpass.askpassKey] == nil)
        #expect(call.env[Askpass.contextKey] == nil)
        #expect(call.env[Askpass.noSudoKey] == "1")
        #expect(session.sudoOutcome == .foreignHelper(Self.helper))
        #expect(session.log.lines.contains { $0.contains("brew.env sets its own password helper (\(Self.helper)") })
    }

    @Test func unstoppableForeignHelperRefusesEveryCaskStep() async throws {
        let box = BrewEnvBox([("~/.homebrew/brew.env", ["SUDO_ASKPASS": Self.helper, "HOMEBREW_NO_SUDO": ""])])
        let runner = EnvRecordingRunner()
        let store = await store(box, runner: runner)
        try upgradeChrome(store, pkg: false)
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        #expect(upgrades(runner).isEmpty)
        #expect(store.upgrade?.sudoOutcome == .foreignHelper(Self.helper))
    }

    @Test func helperAppearingAfterTheSheetStartedIsCaughtBeforeTheStep() async throws {
        let box = BrewEnvBox()
        let hold = Latch()
        // The formula's upgrade holds the queue until the helper is planted.
        let runner = EnvRecordingRunner { args, _ in
            if args.first == "upgrade", args.contains("--formula") { await hold.wait() }
            return 0
        }
        let store = await store(box, runner: runner)
        let xz = try #require(store.packages.first { $0.kind == .formula && $0.upgradeAvailable && $0.upgradeHasBottle != false })
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([xz, chrome])
        if store.upgradePlan != nil { store.confirmUpgradePlan() }
        let session = try #require(store.upgrade)
        #expect(session.items.last?.command.environment[Askpass.askpassKey] == Self.own)   // built with our dialog
        box.files = [("~/.homebrew/brew.env", ["SUDO_ASKPASS": Self.helper])]
        hold.release()
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        #expect(!upgrades(runner).contains { $0.args.contains { $0.hasSuffix("google-chrome") } })
        #expect(session.items.first?.state == .done)
        #expect(session.sudoOutcome == .foreignHelper(Self.helper))
        #expect(session.sudoCommand == session.items.last?.command.display)
    }

    @Test func ownHelperInBrewEnvIsAllowed() async throws {
        let box = BrewEnvBox([("~/.homebrew/brew.env", ["SUDO_ASKPASS": Self.own])])
        let runner = EnvRecordingRunner()
        let store = await store(box, runner: runner)
        #expect(store.foreignAskpass() == nil)
        try upgradeChrome(store, pkg: true)
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let call = try #require(upgrades(runner).first)
        #expect(call.env[Askpass.askpassKey] == Self.own)
        #expect(call.env[Askpass.noSudoKey] == nil)
        #expect(store.upgrade?.items.first?.state == .done)
    }

    @Test func unsetIsAllowed() async throws {
        let runner = EnvRecordingRunner()
        let store = await store(BrewEnvBox(), runner: runner)
        try upgradeChrome(store, pkg: true)
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let call = try #require(upgrades(runner).first)
        #expect(call.env[Askpass.askpassKey] == Self.own)
        #expect(store.upgrade?.items.first?.state == .done)
        #expect(store.upgrade?.sudoOutcome == nil)
    }

    @Test func healthFlagsOnlyAForeignHelper() {
        let none = IntelbrewDetector.detect(coreOrigin: nil, sources: EnvironmentSources(process: [:]))
        func row(_ v: String) -> EnvironmentPolicy.Entry? {
            let s = EnvironmentSources(process: [:], brewEnvFiles: [("~/.homebrew/brew.env", ["SUDO_ASKPASS": v])])
            return EnvironmentPolicy.entries(sources: s, intelbrew: none, ownAskpass: Self.own).first { $0.key == "SUDO_ASKPASS" }
        }
        #expect(row(Self.helper)?.conflict == .askpass)
        #expect(row(Self.own)?.conflict == nil)
    }
}

/// 0.8.4: a proxy's user:password never reaches upgrade.log or History,
/// even if brew, git or curl printed it.
@MainActor
struct ProxyCredentialLoggingTests {
    @Test func upgradeLogMasksURLCredentials() throws {
        let url = try tempDir().appendingPathComponent("upgrade.log")
        let log = LogFile(url: url)
        log.append(["fatal: unable to access 'https://bob:hunter2@proxy.corp:8080/x': timeout", "plain line"])
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("https://•••@proxy.corp:8080/x"))
        #expect(text.contains("plain line"))
    }

    @Test func sessionCommandsAndLogNeverCarryTheProxy() async throws {
        // A profile proxy with credentials: in the brew process env only.
        let proxy = "http://alice:s3cret@proxy.corp:8080"
        let runner = EnvRecordingRunner { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("curl: (7) Failed to connect via \(proxy)\n".utf8))
            return 1
        }
        let logURL = try tempDir().appendingPathComponent("upgrade.log")
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = runner
        deps.logURL = logURL
        deps.historyURL = logURL.deletingLastPathComponent().appendingPathComponent("history.json")
        let base = deps.makeClient
        deps.makeClient = {
            var c = try base()
            c.sources.shellProfiles = [("~/.zshrc", ["http_proxy": proxy, "https_proxy": proxy])]
            return c
        }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        let xz = try #require(store.packages.first { $0.kind == .formula && $0.upgradeAvailable && $0.upgradeHasBottle != false })
        store.startUpgrade([xz])
        if store.upgradePlan != nil { store.confirmUpgradePlan() }
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        let call = try #require(runner.calls.first { $0.args.first == "upgrade" })
        #expect(call.env["http_proxy"] == proxy)                       // brew gets it
        let shown = session.items.map(\.command.display).joined() + (session.sudoCommand ?? "")
        #expect(!shown.contains("s3cret"))
        let file = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!file.contains("s3cret"))
        await #expect(waitUntil { store.history.entries.contains { $0.arguments.first == "upgrade" } })
        let entry = try #require(store.history.entries.first { $0.arguments.first == "upgrade" })
        #expect(!entry.command.contains("s3cret"))
        #expect(!entry.outputTail.joined().contains("s3cret"))
        #expect(entry.outputTail.joined().contains("•••@proxy.corp"))
    }
}
