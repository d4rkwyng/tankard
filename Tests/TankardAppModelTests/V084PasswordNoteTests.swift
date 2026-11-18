import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4: the orange "Tankard will ask for your administrator password"
// line only for a cask that needs it (AdminPassword.required, as the plan
// and the dialog decide), or once brew's output says it runs sudo. Every
// cask upgrade used to log it.
@MainActor
struct V084PasswordNoteTests {
    func store(runner: StreamingCommandRunning? = nil) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = AdminPasswordTests.helper
        if let runner { deps.streamRunner = runner }
        let store = AppStore(deps: deps, settings: testSettings())
        await store.start()
        return store
    }

    func notes(_ s: UpgradeSession) -> [String] {
        s.log.lines.filter { $0.hasPrefix("tankard: ") && $0.contains("administrator password") }
    }

    @Test func plainCaskUpgradeHasNoPasswordLine() async throws {
        let store = await store()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        #expect(!AdminPassword.required(chrome))
        store.startUpgrade([chrome])
        let s = try #require(store.upgrade)
        #expect(s.items.first?.command.environment["SUDO_ASKPASS"] != nil) // the helper is still there
        await #expect(waitUntil { s.isFinished })
        #expect(notes(s).isEmpty)
    }

    @Test func pkgCaskSaysSoUpFront() async throws {
        let store = await store()
        store.demoRequirePassword("google-chrome")
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let s = try #require(store.upgrade)
        await #expect(waitUntil { s.isFinished })
        #expect(notes(s) == ["tankard: brew runs this installer with sudo: Tankard will ask for your administrator password in a dialog (SUDO_ASKPASS)."])
    }

    @Test func anUnflaggedCaskGetsItOnceBrewRunsSudo() async throws {
        let runner = FakeStreamRunner(log: CallLog()) { args, out in
            guard args.first == "upgrade" else { return 0 }
            out(Data("==> Running installer for google-chrome with `sudo` (which may request your password)...\n".utf8))
            out(Data("==> /usr/bin/sudo -u root -A -E -- /usr/sbin/installer -pkg x.pkg -target /\n".utf8))
            return 0
        }
        let store = await store(runner: runner)
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        store.startUpgrade([chrome])
        let s = try #require(store.upgrade)
        await #expect(waitUntil { s.isFinished })
        #expect(notes(s) == ["tankard: brew runs sudo for this step: Tankard will ask for your administrator password in a dialog (SUDO_ASKPASS)."])
    }

    @Test func announcesSudo() {
        #expect(AdminPassword.announcesSudo(["==> Running installer for x with `sudo` (which may request your password)..."]))
        #expect(AdminPassword.announcesSudo(["==> /usr/bin/sudo -u root -E -- /usr/sbin/pkgutil --forget x"]))
        #expect(!AdminPassword.announcesSudo(["==> Upgrading 1 outdated package:", "🍺  maccy was successfully upgraded!"]))
    }
}
