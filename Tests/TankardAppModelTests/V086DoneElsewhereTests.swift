import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (walkthrough M3): Terminal upgraded walk-slow while Tankard waited
// for brew's lock; Tankard's rerun got "already installed" (exit 0) and
// said "Upgrade complete · 1 build from source (walk-slow)", History
// "succeeded". It now says it was already up to date, done elsewhere.
@MainActor
struct V086DoneElsewhereTests {
    nonisolated static let already = "Warning: walktest/probe/walk-slow 1.2 already installed\n"

    func formula(_ name: String) -> Package {
        var p = Package.command(name)
        p.id = "formula:walktest/probe/\(name)"
        p.upgradeAvailable = true
        p.upgradeHasBottle = false
        return p
    }

    func session(_ packages: [Package], output: @escaping @Sendable ([String]) -> String) -> UpgradeSession {
        UpgradeSession(packages: packages, intelbrewMode: false, action: .upgrade,
                       queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { args, out in
                           out(Data(output(args).utf8)); return 0
                       }),
                       makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: ["upgrade", p.name], environment: [:], display: "brew upgrade \(p.name)") },
                       logURL: nil, onFinish: { _ in })
    }

    @Test func detectsBrewsAlreadyInstalled() {
        #expect(BrewRefusal.alreadyInstalled([Self.already.trimmingCharacters(in: .newlines)]))
        #expect(!BrewRefusal.alreadyInstalled(["==> Upgrading walktest/probe/walk-slow", "  1.1 -> 1.2", "==> Pouring walk-slow--1.2.tar.gz"]))
        #expect(!BrewRefusal.alreadyInstalled(["Warning: walk-a 1.2 already installed", "==> Upgrading walk-b"]))
    }

    @Test func aRunWhereBrewDidNothingSaysSo() async {
        let s = session([formula("walk-slow")]) { _ in Self.already }
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .done)
        #expect(s.doneElsewhere.contains(s.items[0].id))
        #expect(s.title == "Already up to date (done elsewhere)")
        #expect(!s.subtitle.contains("build from source"))
        #expect(s.subtitle == "1 already up to date")
        #expect(s.statusLine == "0 upgraded, 1 already up to date")
        #expect(s.log.lines.contains { $0.contains("Tankard changed nothing") })
    }

    @Test func aMixedRunCountsBoth() async {
        let s = session([formula("walk-slow"), formula("walk-a")]) { args in
            args.last == "walk-slow" ? Self.already : "==> Upgrading walk-a\n==> Pouring walk-a--1.2.tar.gz\n"
        }
        #expect(await waitUntil { s.isFinished })
        #expect(s.title == "Upgrade complete")
        #expect(s.subtitle == "1 build from source (walk-a) · 1 already up to date")
        #expect(s.statusLine == "1 upgraded, 1 already up to date")
    }

    @Test func historySaysNoChange() async {
        let recorder = HistoryRecorder()
        let got = Box<[HistoryEntry]>([])
        recorder.setSink { got.value.append($0) }
        let cmd = QueuedCommand(executable: "/x/brew", arguments: ["upgrade", "walk-slow"], environment: [:], display: "brew upgrade walk-slow")
        let id = UUID()
        recorder.observe(id, cmd, .started)
        recorder.observe(id, cmd, .output(Data("Error: Another `brew upgrade` process is already running.\n".utf8)))
        recorder.observe(id, cmd, .lockWait("4312 brew upgrade walk-slow"))
        recorder.observe(id, cmd, .lockWait(nil))
        recorder.observe(id, cmd, .output(Data(Self.already.utf8)))
        recorder.observe(id, cmd, .finished(exitCode: 0))
        #expect(await waitUntil { got.value.count == 1 })
        #expect(got.value[0].outcome == .noChange)
        #expect(got.value[0].resultText == "no change (already up to date)")
    }
}
