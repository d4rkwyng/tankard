import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// The sheet shows Replace's result notes in full under the result line.
// Running commentary ("Stopped.", "brew exited with status") stays in the
// log only. A paired `code` span is the command Copy uses.

struct V091SessionNoteSpanTests {
    @Test func codeSpansAreTheCopyableCommands() {
        let recovery = "Copy Weird aside first, then run `brew uninstall --cask --force 'bad name; echo hi'`, then put the app back."
        let note = SessionNote(id: 0, text: recovery)
        #expect(note.commands == ["brew uninstall --cask --force 'bad name; echo hi'"])
        #expect(note.copyText == "brew uninstall --cask --force 'bad name; echo hi'")
        // Two commands: Copy gets both, in order, one per line.
        let both = SessionNote(id: 1, text: "Run `brew update` and then `brew upgrade`.")
        #expect(both.commands == ["brew update", "brew upgrade"])
        #expect(both.copyText == "brew update\nbrew upgrade")
        // The same split the banner uses: the span is styled, the rest is text.
        let styled = NoticeText.attributed(recovery)
        let code = styled.runs.filter { $0.inlinePresentationIntent == .code }.map { String(styled[$0.range].characters) }
        #expect(code == note.commands)
    }

    @Test func anUnpairedOrEmptySpanIsNotACommand() {
        #expect(SessionNote(id: 0, text: "Stop came too late: Audacity was updated to 4.0.2. Tankard kept a copy of the old version at /tmp/b/Audacity 4.app.").copyText == nil)
        #expect(SessionNote(id: 1, text: "Homebrew reported an error and Audacity may be incomplete. Tankard kept a copy of the old version at /tmp/b/Audacity 4.app.").commands.isEmpty)
        #expect(NoticeText.codeSpans("a `b` c `d") == ["b"])
        #expect(NoticeText.codeSpans("nothing here") == [])
        #expect(NoticeText.codeSpans("empty `` span") == [])
        #expect(NoticeText.codeSpans("spaces `   ` only") == [])
        // An odd trailing backtick is shown as typed, not swallowed.
        #expect(String(NoticeText.attributed("a `b` c `d").characters) == "a b c `d")
    }
}

@MainActor
struct V091SessionNotesTests {
    /// Hangs `brew install --cask --force` until Stop Now, or fails it.
    final class Runner: StreamingCommandRunning, @unchecked Sendable {
        let inner: StreamingCommandRunning
        let hang: Bool
        init(_ inner: StreamingCommandRunning, hang: Bool) { self.inner = inner; self.hang = hang }
        func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                    output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            if arguments.contains("--force") {
                if hang {
                    try await sleepUntilCancelled()
                    return 0
                }
                output(Data("Error: install failed\n".utf8))
                return 1
            }
            return try await inner.stream(executable, arguments, environment: environment, output: output)
        }
    }

    func plan(_ name: String = "Audacity", token: String = "audacity", qualified: String = "homebrew/cask/audacity") -> ReplaceAppPlan {
        ReplaceAppPlan(token: token, qualifiedName: qualified, appName: name,
                       appPath: "/Applications/\(name).app", bundleID: "org.example.\(token)",
                       installedVersion: "1.0", caskVersion: "2.0", bundleVersion: "1")
    }

    func run(hang: Bool, outcome: @escaping @Sendable (String, Bool) -> AppReplaceSafety.Outcome,
             name: String = "Audacity", qualified: String = "homebrew/cask/audacity") async throws -> UpgradeSession {
        let info = AppReplaceSafety.BundleInfo(bundleID: "org.example.\(name.lowercased())", shortVersion: "1.0", bundleVersion: "1")
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.streamRunner = Runner(deps.streamRunner, hang: hang)
        deps.appReplaceSafety = AppReplaceSafety(
            backup: { _ in "/tmp/b/\(name).app" },
            finish: { _, backup, ok, _ in outcome(backup, ok) },
            readApp: { _ in info })
        let store = AppStore(deps: deps)
        store.settings.appManagementExplained = true
        await store.start()
        #expect(await store.startReplace(plan(name, token: name.lowercased(), qualified: qualified)))
        if hang {
            #expect(await waitUntil { store.upgrade?.current != nil })
            store.upgrade?.stopNow()
        }
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        return try #require(store.upgrade)
    }

    /// A step that fails on its own says so in the log. That line is not a
    /// result note: nothing called `addNote`.
    @Test func aFailedRunsStatusStaysInTheLog() async throws {
        let s = UpgradeSession(packages: [Package.command("walk-fail")], intelbrewMode: false, action: .upgrade,
                               queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { _, _ in 1 }),
                               makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: [p.name], environment: [:], display: p.name) },
                               logURL: nil, onFinish: { _ in })
        #expect(await waitUntil { s.isFinished })
        let lines = s.log.lines.joined(separator: "\n")
        #expect(lines.contains("tankard: brew exited with status 1"))
        #expect(s.sessionNotes.isEmpty)
    }

    @Test func stopNowRecoveryIsSurfacedWithItsCommand() async throws {
        let qualified = "bad name; echo hi"
        let session = try await run(hang: true, outcome: { _, ok in
            #expect(!ok)
            return .restored
        }, name: "Weird", qualified: qualified)
        let lines = session.log.lines.joined(separator: "\n")
        #expect(lines.contains("tankard: Stopped."))
        let recovery = "Copy Weird aside first, then run `brew uninstall --cask --force 'bad name; echo hi'`, then put the app back."
        let putBack = "brew stopped after removing Weird; Tankard put the old version back at /Applications/Weird.app."
        #expect(session.sessionNotes.map(\.text) == [putBack, recovery])
        #expect(session.sessionNotes.map(\.copyText) == [nil, "brew uninstall --cask --force 'bad name; echo hi'"])
        #expect(!session.sessionNotes.contains { $0.text.contains("Stopped") })
        #expect(lines.contains("tankard: \(recovery)"))
        #expect(lines.contains("tankard: \(putBack)"))
    }

    @Test func stopCameTooLateIsSurfacedWithoutACommand() async throws {
        let session = try await run(hang: true, outcome: { backup, ok in
            #expect(!ok)
            return .replacedDespiteError(backup: backup)
        })
        let text = "Stop came too late: Audacity was updated to 2.0. Tankard kept a copy of the old version at /tmp/b/Audacity.app."
        #expect(session.sessionNotes.map(\.text) == [text])
        #expect(session.sessionNotes.map(\.copyText) == [nil])
        #expect(session.log.lines.joined(separator: "\n").contains("tankard: \(text)"))
        #expect(session.log.lines.joined(separator: "\n").contains("tankard: Stopped."))
        #expect(!session.sessionNotes.contains { $0.text.contains("Stopped") })
    }

    @Test func aKeptCopyAndAnIncompleteAppAreSurfaced() async throws {
        let kept = try await run(hang: false, outcome: { backup, ok in
            #expect(!ok)
            return .kept(backup: backup)
        })
        let keptText = "Audacity wasn't replaced; it is as it was. Tankard kept a copy of it at /tmp/b/Audacity.app."
        #expect(kept.sessionNotes.map(\.text) == [keptText])
        #expect(kept.sessionNotes[0].copyText == nil)
        #expect(kept.log.lines.joined(separator: "\n").contains("tankard: brew exited with status 1"))
        #expect(!kept.sessionNotes.contains { $0.text.contains("brew exited") })

        let incomplete = try await run(hang: false, outcome: { backup, _ in .incomplete(backup: backup) })
        let incompleteText = "Homebrew reported an error and Audacity may be incomplete. Tankard kept a copy of the old version at /tmp/b/Audacity.app."
        #expect(incomplete.sessionNotes.map(\.text) == [incompleteText])
        #expect(incomplete.sessionNotes[0].copyText == nil)
        #expect(incomplete.log.lines.joined(separator: "\n").contains("tankard: \(incompleteText)"))
    }
}
