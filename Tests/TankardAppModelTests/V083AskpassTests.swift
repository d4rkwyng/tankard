import AskpassSupport
import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3: brew's sudo asks through Tankard's password dialog
// (SUDO_ASKPASS = Tankard.app/Contents/MacOS/tankard-askpass), only for cask
// changes, never for automatic updates. No real password anywhere here.

/// sudo 1.9's output, as printed on this Mac (macOS 27) by `sudo -A -k true`
/// with a helper that exits 1, and with one that prints a wrong password.
let sudoCancelled = ["sudo: no password was provided", "sudo: a password is required"]
let sudoWrongPassword = ["Sorry, try again.", "Sorry, try again.", "sudo: 3 incorrect password attempts"]

struct AskpassSupportTests {
    @Test func environmentOnlyWithAHelper() {
        #expect(Askpass.environment(helper: nil, context: "x").isEmpty)
        #expect(Askpass.environment(helper: "", context: "x").isEmpty)
        let env = Askpass.environment(helper: "/Applications/Tankard.app/Contents/MacOS/tankard-askpass", context: "To run the installer for windows-app: brew upgrade --cask windows-app")
        #expect(env == ["SUDO_ASKPASS": "/Applications/Tankard.app/Contents/MacOS/tankard-askpass",
                        "HOMEBREW_TANKARD_ASKPASS_CONTEXT": "To run the installer for windows-app: brew upgrade --cask windows-app"])
        // bin/brew keeps SUDO_ASKPASS and HOMEBREW_*; any other name would be dropped.
        #expect(Askpass.contextKey.hasPrefix("HOMEBREW_"))
    }

    @Test func contextIsOneShortCleanLine() {
        let env = Askpass.environment(helper: "/h", context: "a\nb\r\tc\u{1b}[31m  d\u{7}")
        #expect(env[Askpass.contextKey] == "a b c [31m d")
        let long = Askpass.sanitize(String(repeating: "x", count: 1000), limit: Askpass.maxContextLength)
        #expect(long.count == Askpass.maxContextLength)
        #expect(long.hasSuffix("…"))
    }

    @Test func requestFromArgvAndEnvironment() {
        let r = Askpass.request(arguments: ["tankard-askpass", "Password:"],
                                environment: [Askpass.contextKey: "For this step of iterm2: brew upgrade --cask iterm2"],
                                parentAge: 0.2)
        #expect(r == Askpass.Request(prompt: "Password:", context: "For this step of iterm2: brew upgrade --cask iterm2", isRetry: false))
        // HOMEBREW_SUDO_THROUGH_SUDO_USER: brew's own prompt is kept.
        #expect(Askpass.request(arguments: ["a", "Password for derek:"], environment: [:]).prompt == "Password for derek:")
        // No prompt, no context: defaults, never a crash.
        let bare = Askpass.request(arguments: ["a"], environment: [:])
        #expect(bare.prompt == "Password:")
        #expect(bare.context == nil)
        #expect(Askpass.request(arguments: ["a", "  "], environment: [Askpass.contextKey: " \n "]).context == nil)
        // A control sequence in the prompt can't add lines.
        #expect(Askpass.request(arguments: ["a", "Pass\nOK\u{1b}"], environment: [:]).prompt == "Pass OK")
    }

    @Test func retryWhenTheCallingSudoHasBeenRunningAWhile() {
        #expect(!Askpass.request(arguments: ["a"], environment: [:], parentAge: 0.4).isRetry)
        #expect(Askpass.request(arguments: ["a"], environment: [:], parentAge: 6).isRetry)
        #expect(!Askpass.request(arguments: ["a"], environment: [:], parentAge: nil).isRetry)
        #expect(Askpass.request(arguments: ["a"], environment: [Askpass.retryKey: "1"]).isRetry)
    }

    @Test func dialogTextNamesTheStep() {
        let r = Askpass.Request(prompt: "Password:", context: "To run the installer for windows-app: brew upgrade --cask windows-app", isRetry: false)
        let text = AskpassText.describe(r)
        #expect(text.contains("Tankard needs your administrator password"))
        #expect(text.contains("windows-app: brew upgrade --cask windows-app"))
        #expect(text.contains("[Cancel]"))
        #expect(AskpassText.describe(Askpass.Request(prompt: "Password:", context: nil, isRetry: true))
            .hasPrefix("The password was incorrect. Try again."))
    }

    @Test func helperPathOnlyInsideAnAppAndExecutable() throws {
        let dir = try tempDir()
        let app = dir.appendingPathComponent("Tankard.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let helper = macOS.appendingPathComponent("tankard-askpass")
        #expect(Askpass.helperPath(appBundle: app) == nil)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: helper)
        #expect(Askpass.helperPath(appBundle: app) == nil) // not executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(Askpass.helperPath(appBundle: app) == helper.path)
        // `swift run` / tests: the bin directory is not an app.
        #expect(Askpass.helperPath(appBundle: macOS) == nil)
    }
}

/// The built helper, when this build has it (`swift build` builds every
/// product; `swift test` normally does too).
private func builtHelper() -> String? {
    var dir = URL(fileURLWithPath: #filePath)
    while dir.path != "/" {
        dir.deleteLastPathComponent()
        let p = dir.appendingPathComponent(".build/debug/tankard-askpass").path
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

struct AskpassHelperProcessTests {
    /// The real helper binary, run by this test process (not sudo, no
    /// Tankard above it): refused before anything is drawn, even with the
    /// describe hook, and nothing on stdout (the password channel).
    @Test(.enabled(if: builtHelper() != nil)) func refusesWhenNotRunBySudoForTankard() async throws {
        let helper = try #require(builtHelper())
        let r = try await ProcessRunner().run(helper, ["Password:"], environment: [
            Askpass.describeKey: "1",
            Askpass.contextKey: "To run the installer for windows-app: brew upgrade --cask windows-app",
        ])
        #expect(r.exitCode == 1)
        #expect(r.stdout.isEmpty)
        #expect(r.stderrString.contains("refused: parent is not /usr/bin/sudo"))
        #expect(!r.stderrString.contains("windows-app"))
    }
}

struct AskpassGateTests {
    static let helper = "/Applications/Tankard.app/Contents/MacOS/tankard-askpass"
    static let tankard = "/Applications/Tankard.app/Contents/MacOS/Tankard"
    static let ruby = "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"

    @Test func realSudoWithTankardAboveIsAllowed() {
        #expect(AskpassGate.expectedTankard(helperPath: Self.helper) == Self.tankard)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.ruby, Self.tankard],
                                   helperPath: Self.helper) == .allow)
        // brew's bash in between, or ruby straight under Tankard.
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.ruby, "/bin/bash", Self.tankard, "/sbin/launchd"],
                                   helperPath: Self.helper) == .allow)
    }

    @Test func aParentThatIsNotTheRealSudoIsDenied() {
        for parent in ["/bin/zsh", "/usr/bin/cat", "/tmp/sudo", "/usr/local/bin/sudo", nil] {
            #expect(AskpassGate.decide(parentPath: parent, ancestorPaths: [Self.tankard], helperPath: Self.helper) != .allow,
                    "\(parent ?? "nil")")
        }
    }

    @Test func sudoWithoutTankardAboveIsDenied() {
        // Terminal: zsh, login, Terminal.app.
        let terminal = ["/bin/zsh", "/usr/bin/login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "/sbin/launchd"]
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: terminal, helperPath: Self.helper) != .allow)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [], helperPath: Self.helper) != .allow)
        // Another copy of Tankard is not this helper's Tankard.
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/Users/me/Downloads/Tankard.app/Contents/MacOS/Tankard"],
                                   helperPath: Self.helper) != .allow)
    }

    @Test func aCopiedOrSymlinkedHelperIsDenied() {
        // Copied out of the bundle: no bundle, no Tankard of its own.
        #expect(AskpassGate.expectedTankard(helperPath: "/tmp/tankard-askpass") == nil)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.tankard],
                                   helperPath: "/tmp/tankard-askpass") != .allow)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.tankard],
                                   helperPath: "/tmp/x/Contents/MacOS/tankard-askpass") != .allow)
        // Copied into a home-made bundle: its "Tankard" is that bundle's, not
        // the real one above sudo.
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.tankard],
                                   helperPath: "/tmp/Evil.app/Contents/MacOS/tankard-askpass") != .allow)
        // ...and with a program called Tankard in it running above sudo: a
        // signed release requires the same team (nil: unsigned or invalid).
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/tmp/Evil.app/Contents/MacOS/Tankard"],
                                   helperPath: "/tmp/Evil.app/Contents/MacOS/tankard-askpass",
                                   helperTeam: "ABCDE12345", tankardTeam: nil) != .allow)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: ["/tmp/Evil.app/Contents/MacOS/Tankard"],
                                   helperPath: "/tmp/Evil.app/Contents/MacOS/tankard-askpass",
                                   helperTeam: "ABCDE12345", tankardTeam: "ZZZZZ99999") != .allow)
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.ruby, Self.tankard], helperPath: Self.helper,
                                   helperTeam: "ABCDE12345", tankardTeam: "ABCDE12345") == .allow)
        // A symlink to the helper: the kernel reports the target's path, so
        // the symlink's own location never counts.
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: [Self.tankard],
                                   helperPath: "/tmp/link/tankard-askpass") != .allow)
    }

    @Test func theWalkIsCapped() {
        let deep = Array(repeating: "/bin/bash", count: AskpassGate.maxAncestors) + [Self.tankard]
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: deep, helperPath: Self.helper) != .allow)
        let justInside = Array(repeating: "/bin/bash", count: AskpassGate.maxAncestors - 1) + [Self.tankard]
        #expect(AskpassGate.decide(parentPath: "/usr/bin/sudo", ancestorPaths: justInside, helperPath: Self.helper) == .allow)
    }
}

@MainActor
struct AdminPasswordTests {
    static let helper = "/Applications/Tankard.app/Contents/MacOS/tankard-askpass"

    @Test func onlyCaskChangesMayRunSudo() {
        for args in [["upgrade", "--cask", "homebrew/cask/windows-app"], ["install", "--cask", "homebrew/cask/x"],
                     ["install", "--cask", "--adopt", "homebrew/cask/x"], ["reinstall", "--cask", "x"],
                     ["uninstall", "--cask", "x"]] {
            #expect(AdminPassword.mayNeedSudo(args), "\(args)")
        }
        for args in [["upgrade", "--formula", "homebrew/core/xz"], ["update"], ["cleanup"], ["autoremove"],
                     ["tap", "a/b"], ["info", "--json=v2", "--installed"], ["outdated", "--cask"],
                     ["pin", "xz"], ["services", "stop", "x"], ["reinstall", "--force-bottle", "--formula", "vim"]] {
            #expect(!AdminPassword.mayNeedSudo(args), "\(args)")
            #expect(AdminPassword.environment(helper: Self.helper, arguments: args, package: nil, display: "brew").isEmpty)
        }
    }

    @Test func requiredForPkgAndSudoInstallers() {
        var p = pkg("windows-app", kind: .cask)
        #expect(!AdminPassword.required(p))
        p.installsPkg = true
        #expect(AdminPassword.required(p))
        var q = pkg("x", kind: .cask)
        q.sudoInstaller = true
        #expect(AdminPassword.required(q))
        var f = pkg("xz")
        f.installsPkg = true // never for a formula
        #expect(!AdminPassword.required(f))
        #expect(AdminPassword.context(p, display: "brew upgrade --cask windows-app")
                == "To run the installer for windows-app: brew upgrade --cask windows-app")
        #expect(AdminPassword.context(pkg("iterm2", kind: .cask), display: "brew upgrade --cask iterm2")
                == "For this step of iterm2: brew upgrade --cask iterm2")
    }

    func store(helper: String? = Self.helper, runner: StreamingCommandRunning? = nil) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = helper
        if let runner { deps.streamRunner = runner }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        return store
    }

    @Test func aCaskUpgradeGetsTheDialogAFormulaDoesNot() async throws {
        let store = await store()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let cmd = try #require(store.upgrade?.items.first?.command)
        #expect(cmd.environment["SUDO_ASKPASS"] == Self.helper)
        #expect(cmd.environment["HOMEBREW_TANKARD_ASKPASS_CONTEXT"] == "For this step of google-chrome: \(cmd.display)")
        // Not in what is shown or copied for Terminal.
        #expect(!cmd.display.contains("SUDO_ASKPASS"))
        #expect(cmd.display.hasPrefix("brew upgrade --cask"))
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        store.closeUpgrade()
        await #expect(waitUntil { !store.isRefreshing })

        let formula = try #require(store.packages.first { $0.kind == .formula && $0.isManualUpgradeTarget })
        store.startUpgrade([formula])
        let fcmd = try #require(store.upgrade?.items.first?.command)
        #expect(fcmd.environment["SUDO_ASKPASS"] == nil)
        #expect(fcmd.environment["HOMEBREW_TANKARD_ASKPASS_CONTEXT"] == nil)
    }

    @Test func noHelperNoVariable() async throws {
        let store = await store(helper: nil)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        #expect(store.upgrade?.items.first?.command.environment["SUDO_ASKPASS"] == nil)
    }

    @Test func pkgCaskUpgradeIsConfirmedFirst() async throws {
        let store = await store()
        store.demoRequirePassword("google-chrome")
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        #expect(chrome.installsPkg == true)
        store.requestUpgrade([chrome])
        let plan = try #require(store.upgradePlan)
        #expect(plan.needingPassword.map(\.name) == ["google-chrome"])
        #expect(plan.needsConfirmation)
        #expect(store.upgrade == nil)
        store.confirmUpgradePlan()
        let cmd = try #require(store.upgrade?.items.first?.command)
        #expect(cmd.environment["HOMEBREW_TANKARD_ASKPASS_CONTEXT"] == "To run the installer for google-chrome: \(cmd.display)")
    }

    @Test func restoreCaskStepsGetItFormulaStepsDoNot() {
        let cask = RestoreStep(kind: .reinstall, package: "windows-app", arguments: ["reinstall", "--cask", "windows-app"], environment: [:])
        let formula = RestoreStep(kind: .reinstall, package: "xz", arguments: ["reinstall", "--formula", "xz"], environment: [:])
        let c = AppStore.restoreCommand(cask, brew: "/opt/homebrew/bin/brew", base: [:], askpass: Self.helper)
        let f = AppStore.restoreCommand(formula, brew: "/opt/homebrew/bin/brew", base: [:], askpass: Self.helper)
        #expect(c.environment["SUDO_ASKPASS"] == Self.helper)
        #expect(c.environment["HOMEBREW_TANKARD_ASKPASS_CONTEXT"] == "For this step: brew reinstall --cask windows-app")
        #expect(f.environment["SUDO_ASKPASS"] == nil)
    }

    @Test func cancelledAndWrongPasswordAreClassified() {
        #expect(SudoOutcome.classify(sudoCancelled) == .cancelled)
        #expect(SudoOutcome.classify(sudoWrongPassword) == .wrongPassword)
        // Real output of Cancel after one wrong password (sudo -A, macOS 27).
        #expect(SudoOutcome.classify(["Sorry, try again.", "sudo: no password was provided", "sudo: 1 incorrect password attempt"]) == .cancelled)
        #expect(SudoOutcome.classify(["Error: windows-app: The pkg artifact requires sudo, but HOMEBREW_NO_SUDO is set."]) == .sudoDisabled)
        #expect(SudoOutcome.classify(["sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper"]) == .noPrompt)
        #expect(SudoOutcome.classify(["Error: boom"]) == nil)
        for lines in [sudoCancelled, sudoWrongPassword, ["sudo is disabled by HOMEBREW_NO_SUDO."]] {
            #expect(SudoDetector.needsSudo(lines))
        }
        #expect(SudoOutcome.cancelled.message != SudoOutcome.noPrompt.message)
    }

    /// The step fails as brew does after Cancel: the sheet keeps the
    /// command for Terminal and says the dialog was cancelled.
    @Test(arguments: [(sudoCancelled, SudoOutcome.cancelled), (sudoWrongPassword, .wrongPassword)])
    func aFailedPromptFallsBackToTerminal(lines: [String], outcome: SudoOutcome) async throws {
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "upgrade" else { return 0 }
            let all = ["==> Running installer for google-chrome with `sudo` (which may request your password)..."] + lines
                + ["Error: Failure while executing; `/usr/bin/sudo -u root -A -E -- /usr/sbin/installer` exited with 1."]
            out(Data((all.joined(separator: "\n") + "\n").utf8))
            return 1
        }
        let store = await store(runner: runner)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        await #expect(waitUntil { store.upgrade?.isFinished == true })
        let session = try #require(store.upgrade)
        #expect(session.sudoOutcome == outcome)
        #expect(session.sudoCommand == session.items.first?.command.display)
        #expect(session.items.first?.state == .failed(1))
        #expect(session.log.lines.contains { $0.contains("Tankard will ask for your administrator password in a dialog") })
    }
}

@MainActor
struct AutoUpdateNeverPromptsTests {
    @Test func safeModeSkipsPkgCasks() {
        var windows = pkg("windows-app", kind: .cask, apps: [], quit: [])
        windows.installsPkg = true
        let iterm = pkg("iterm2", kind: .cask, apps: ["/Applications/iTerm.app"], quit: [])
        let r = AutoUpdateSafeMode.plan([windows, iterm], classifier: CompileClassifier(), running: [], dontQuitApps: false)
        #expect(r.run.map(\.name) == ["iterm2"])
        #expect(r.skipped.map(\.package.name) == ["windows-app"])
        #expect(r.skipped.first?.reason == .needsPassword)
        #expect(AutoUpdateSkip.needsPassword.text.contains("administrator password"))
    }

    @Test func unattendedEnvironmentHasNoAskpassAndNoSudo() {
        let env = AutoUpdateSafeMode.unattended(["SUDO_ASKPASS": "/x", Askpass.contextKey: "y", "HOME": "/Users/me"])
        #expect(env["SUDO_ASKPASS"] == nil)
        #expect(env[Askpass.contextKey] == nil)
        #expect(env["HOMEBREW_NO_SUDO"] == "1")
        #expect(env["HOME"] == "/Users/me")
    }

    /// A real run through the queue, with the helper configured: no
    /// command it runs carries SUDO_ASKPASS, every upgrade has HOMEBREW_NO_SUDO.
    @Test func aRunNeverCarriesTheHelper() async throws {
        var deps = Demo.dependencies(.intelbrew, pace: 0, pinned: ["ruby"])
        deps.askpassHelper = AdminPasswordTests.helper
        let envs = EnvLog()
        deps.streamRunner = RecordingRunner(inner: deps.streamRunner, log: envs)
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        store.autoUpdate.calendar = utc
        store.autoUpdate.settings.enabled = true
        _ = try #require(await store.autoUpdate.run(store: store, notifier: FakeNotifier()))
        let upgrades = envs.calls.filter { $0.0.first == "upgrade" }
        #expect(!upgrades.isEmpty)
        #expect(envs.calls.allSatisfy { $0.1["SUDO_ASKPASS"] == nil && $0.1[Askpass.contextKey] == nil })
        #expect(upgrades.allSatisfy { $0.1["HOMEBREW_NO_SUDO"] == "1" })
    }
}

struct SudoInstallerDecodingTests {
    func cask(_ artifacts: String) throws -> BrewInfoJSON.Cask {
        let json = #"{"formulae": [], "casks": [{"token": "x", "full_token": "x", "version": "1", "artifacts": \#(artifacts)}]}"#
        return try #require(try JSONDecoder().decode(BrewInfoJSON.self, from: Data(json.utf8)).casks.first)
    }

    @Test func installerScriptWithSudo() throws {
        #expect(try cask(#"[{"installer": [{"script": {"executable": "x/install.sh", "args": ["--silent"], "sudo": true}}]}]"#).sudoInstaller == true)
        #expect(try cask(#"[{"installer": [{"script": "x/install.sh", "sudo": true}]}]"#).sudoInstaller == true)
        #expect(try cask(#"[{"installer": [{"script": {"executable": "x/install.sh"}}]}]"#).sudoInstaller == false)
        #expect(try cask(#"[{"installer": [{"manual": "Install.app"}]}]"#).sudoInstaller == false)
        // windows-app's real artifacts (brew info --json=v2 --cask windows-app, 11.4.5).
        let w = try cask(#"[{"uninstall": [{"pkgutil": "com.microsoft.rdc.macos"}]}, {"pkg": ["Windows_App_11.4.5_installer.pkg", {"choices": [{"choiceIdentifier": "com.microsoft.autoupdate", "choiceAttribute": "selected", "attributeSetting": 0}]}]}, {"zap": [{"trash": ["~/Library/Containers/com.microsoft.rdc.macos"]}]}]"#)
        #expect(w.installsPkg == true)
        #expect(w.sudoInstaller == false)
        #expect(try cask("[]").sudoInstaller == false)
    }
}

/// 0.8.3: while the helper is up, the session says so (the sheet keeps the
/// Terminal route in view) and Tankard yields focus to it once per helper.
@MainActor
struct AwaitingPasswordTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _pid: pid_t?
        private var _finds = 0
        var pid: pid_t? { get { lock.withLock { _pid } } set { lock.withLock { _pid = newValue } } }
        var finds: Int { lock.withLock { _finds } }
        func find() -> pid_t? { lock.withLock { _finds += 1; return _pid } }
    }

    func rig(_ box: Box, yields: @escaping @MainActor @Sendable (pid_t) -> Void) async -> (AppStore, Latch) {
        let latch = Latch()
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = AdminPasswordTests.helper
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, _ in
            if args.first == "upgrade" { await latch.wait() }
            return 0
        }
        deps.askpassFocus = AskpassFocus(find: { box.find() }, yield: yields, interval: .milliseconds(20))
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        return (store, latch)
    }

    @Test func helperUpMeansAwaitingAndOneYieldPerHelper() async throws {
        let box = Box()
        var yielded: [pid_t] = []
        let (store, latch) = await rig(box) { yielded.append($0) }
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let session = try #require(store.upgrade)
        await #expect(waitUntil { session.current != nil && box.finds > 1 })
        #expect(!session.awaitingPassword)
        box.pid = 4242
        await #expect(waitUntil { session.awaitingPassword })
        try await Task.sleep(for: .milliseconds(100))
        #expect(yielded == [4242])          // once, not every poll
        box.pid = nil                         // dialog answered or cancelled
        await #expect(waitUntil { !session.awaitingPassword })
        box.pid = 4243                        // sudo asks again (wrong password)
        await #expect(waitUntil { session.awaitingPassword })
        #expect(yielded == [4242, 4243])
        latch.release()
        await #expect(waitUntil { session.isFinished })
        #expect(!session.awaitingPassword)
        let after = box.finds
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.finds == after)           // watching stopped with the command
    }

    @Test func aFormulaUpgradeNeverWatches() async throws {
        let box = Box()
        box.pid = 4242
        var yielded: [pid_t] = []
        let (store, latch) = await rig(box) { yielded.append($0) }
        let formula = try #require(store.packages.first { $0.kind == .formula && $0.isManualUpgradeTarget })
        store.startUpgrade([formula])
        let session = try #require(store.upgrade)
        await #expect(waitUntil { session.current != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.finds == 0)
        #expect(!session.awaitingPassword)
        #expect(yielded.isEmpty)
        latch.release()
        await #expect(waitUntil { session.isFinished })
    }

    @Test func liveFindIgnoresProcessesNotUnderTankard() {
        // This test process runs no helper: nothing found, and the lookup
        // itself works on the real process table.
        #expect(AskpassProcess.find(helperPath: AdminPasswordTests.helper, below: getpid()) == nil)
        #expect(AskpassProcess.path(getpid()) != nil)
        #expect(AskpassProcess.descends(getpid(), from: getppid(), maxDepth: 3))
        #expect(!AskpassProcess.descends(getppid(), from: getpid(), maxDepth: 3))
    }
}
