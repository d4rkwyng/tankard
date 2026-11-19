import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (gauntlet 26, P6): cancelling the password dialog for a pkg cask
// showed "Install finished with problems / The log below shows what brew
// printed". It now says the run was cancelled, and why.

extension AdminPasswordTests {
    func runCancelled(_ lines: [String]) async throws -> UpgradeSession {
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
        return try #require(store.upgrade)
    }

    @Test func aCancelledPasswordDialogSaysCancelled() async throws {
        // brew 7's output after Cancel (gauntlet 26, zoom).
        let session = try await runCancelled(["Sorry, try again.", "sudo: no password was provided", "sudo: 1 incorrect password attempt"])
        #expect(session.sudoOutcome == .cancelled)
        #expect(session.passwordCancelledOnly)
        #expect(session.title == "Upgrade cancelled")
        #expect(session.subtitle == "The password dialog was cancelled, so brew didn't run the step that needed it.")
    }

    @Test func aWrongPasswordIsStillAProblem() async throws {
        let session = try await runCancelled(sudoWrongPassword)
        #expect(!session.passwordCancelledOnly)
        #expect(session.title == "Upgrade finished with problems")
    }
}
