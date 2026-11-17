import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

/// 0.8.3: brew.env's HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK pauses automatic updates.
extension AutoUpdateRunTests {
    @Test func dependentsCheckOffInBrewEnvSkipsTheRun() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("upgrade.log")
        let (store, envs, notifier) = await rig(logURL: logURL)
        store.autoUpdate.brewEnvFiles = { _ in [("~/.homebrew/brew.env", ["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1"])] }
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(envs.calls.isEmpty)                  // not even brew update
        #expect(run.upgraded.isEmpty && run.failed.isEmpty && run.skipped.isEmpty)
        #expect(run.note == AutoUpdater.pausedText)
        #expect(store.autoUpdate.log.latest == run)
        #expect(store.autoUpdate.pausedReason == AutoUpdater.pausedText)
        #expect(store.autoUpdate.settings.lastRun == run.startedAt)   // the slot counts as done
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("skipped: HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 in ~/.homebrew/brew.env"))
        #expect(notifier.posted.first?.body.contains(AutoUpdater.pausedText) == true)

        // Manual upgrades are unaffected.
        let target = try #require(store.upgradable.first)
        store.startSession(.upgrade, packages: [target])
        #expect(store.upgrade != nil)
    }

    @Test func dependentsCheckOnRuns() async throws {
        let (store, envs, notifier) = await rig()
        // "0" and the other falsy values leave the check on (env_config.rb `boolean: true`).
        store.autoUpdate.brewEnvFiles = { _ in [("~/.homebrew/brew.env", ["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "0"])] }
        store.autoUpdate.settings.enabled = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: notifier))
        #expect(envs.calls.first?.0 == ["update"])
        #expect(run.upgraded.count == 4)
        #expect(store.autoUpdate.pausedReason == nil)
    }

    @Test func pauseClearsWhenTheSettingGoes() async throws {
        let (store, _, _) = await rig()
        var files: [(String, [String: String])] = [("/etc/homebrew/brew.env", ["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "yes"])]
        store.autoUpdate.brewEnvFiles = { _ in files }
        #expect(store.autoUpdate.checkPause(store: store)?.source == "/etc/homebrew/brew.env")
        #expect(store.autoUpdate.pausedReason != nil)
        files = []
        #expect(store.autoUpdate.checkPause(store: store) == nil)
        #expect(store.autoUpdate.pausedReason == nil)
    }
}

struct DependentsCheckPrecedenceTests {
    let key = AutoUpdater.dependentsCheckKey

    @Test(arguments: [("1", true), ("true", true), ("yes", true), ("anything", true), ("\"0\"", true),
                      ("0", false), ("false", false), ("FALSE", false), ("no", false), ("off", false),
                      ("nil", false), ("", false), ("  ", false)])
    func brewBooleanRule(value: String, off: Bool) {
        #expect((AutoUpdater.dependentsCheckOff([("~/.homebrew/brew.env", [key: value])]) != nil) == off)
    }

    @Test func laterFileWins() {
        // /etc, prefix, user: the user's "0" turns it back on.
        let files: [(String, [String: String])] = [
            ("/etc/homebrew/brew.env", [key: "1"]),
            ("/opt/homebrew/etc/homebrew/brew.env", [key: "1"]),
            ("~/.homebrew/brew.env", [key: "0"]),
        ]
        #expect(AutoUpdater.dependentsCheckOff(files) == nil)
        #expect(AutoUpdater.dependentsCheckOff(Array(files.prefix(2)))?.source == "/opt/homebrew/etc/homebrew/brew.env")
    }

    @Test func systemTakesPriority() {
        let files: [(String, [String: String])] = [
            ("/etc/homebrew/brew.env", [key: "1", "HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY": "1"]),
            ("~/.homebrew/brew.env", [key: "0"]),
        ]
        #expect(AutoUpdater.dependentsCheckOff(files)?.source == "/etc/homebrew/brew.env")
        // Only the /etc file's own HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY counts (bin/brew checks it right after reading /etc).
        let fromUser: [(String, [String: String])] = [
            ("/etc/homebrew/brew.env", [key: "1"]),
            ("~/.homebrew/brew.env", [key: "0", "HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY": "1"]),
        ]
        #expect(AutoUpdater.dependentsCheckOff(fromUser) == nil)
    }

    @Test func unsetMeansOn() {
        #expect(AutoUpdater.dependentsCheckOff([]) == nil)
        #expect(AutoUpdater.dependentsCheckOff([("~/.homebrew/brew.env", ["HOMEBREW_NO_ANALYTICS": "1"])]) == nil)
    }
}
