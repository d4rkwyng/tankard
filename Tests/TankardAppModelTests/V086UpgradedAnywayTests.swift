import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (VM test M1): with lz4 pinned, `brew upgrade aws-c-auth` upgraded
// aws-c-auth, then refused a dependent that needs a newer lz4 and exited 1.
// Tankard said "6 failed" and History "failed (exit 1)" for four packages
// that were upgraded; Retry Failed then found only 2 to retry. A step's
// result now comes from the installed versions read after the run.
@MainActor
struct V086UpgradedAnywayTests {
    func formula(_ name: String, _ version: String = "1.0") -> Package {
        var p = Package.command(name)
        p.id = "formula:\(name)"
        p.installedVersion = version
        p.installedVersions = [version]
        p.currentVersion = "1.1"
        p.upgradeAvailable = true
        p.upgradeHasBottle = true
        return p
    }

    func session(_ packages: [Package], exit: @escaping @Sendable (String) -> Int32,
                 check: (@Sendable ([Package]) async -> [String: InstalledNow]?)?,
                 finished: Box<Int>? = nil) -> UpgradeSession {
        UpgradeSession(packages: packages, intelbrewMode: false, action: .upgrade,
                       queue: CommandQueue(runner: FakeStreamRunner(log: CallLog()) { args, out in
                           let name = args.last ?? ""
                           out(Data("==> Upgrading \(name)\n  1.0 -> 1.1\n".utf8))
                           if exit(name) != 0 { out(Data("Error: awscli: the dependency lz4 is pinned\n".utf8)) }
                           return exit(name)
                       }),
                       makeCommand: { p in QueuedCommand(executable: "/x/brew", arguments: ["upgrade", p.name], environment: [:], display: "brew upgrade \(p.name)") },
                       logURL: nil, upgradeCheck: check, onFinish: { _ in finished?.value += 1 })
    }

    @Test func aStepThatUpgradedCountsAsUpgradedDespiteExit1() async {
        let finished = Box(0)
        let s = session([formula("aws-c-auth"), formula("awscli"), formula("xz")],
                        exit: { $0 == "xz" ? 0 : 1 },
                        check: { _ in ["formula:aws-c-auth": "1.1", "formula:awscli": "1.0", "formula:xz": "1.1"] },
                        finished: finished)
        #expect(await waitUntil { s.isFinished })
        #expect(finished.value == 1)
        #expect(s.items[0].state == .done)
        #expect(s.upgradedAnyway == [s.items[0].id])
        #expect(s.items[1].state == .failed(1))
        #expect(s.items[2].state == .done)
        #expect(s.failedItems.map(\.package.name) == ["awscli"])
        #expect(s.retryableItems.map(\.package.name) == ["awscli"])
        #expect(s.statusLine == "2 upgraded, 1 failed")
        #expect(s.log.lines.contains { $0.contains("aws-c-auth is now 1.1") })
    }

    @Test func notFinishedUntilTheCheckAnswers() async {
        let gate = Latch()
        let s = session([formula("aws-c-auth")], exit: { _ in 1 }, check: { _ in
            await gate.wait()
            return ["formula:aws-c-auth": "1.1"]
        })
        #expect(await waitUntil { s.checkingUpgraded })
        #expect(!s.isFinished)
        #expect(s.statusLine == "Checking what brew upgraded…")
        gate.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .done)
        #expect(!s.checkingUpgraded)
        #expect(s.title == "Upgrade complete")
    }

    @Test func aFailedReadKeepsTheExitCodesResult() async {
        let s = session([formula("aws-c-auth")], exit: { _ in 1 }, check: { _ in nil })
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .failed(1))
        #expect(s.upgradedAnyway.isEmpty)
    }

    @Test func noCheckWhenNothingFailed() async {
        let asked = Box(0)
        let s = session([formula("xz")], exit: { _ in 0 }, check: { _ in
            await MainActor.run { asked.value += 1 }
            return [:]
        })
        #expect(await waitUntil { s.isFinished })
        #expect(asked.value == 0)
    }

    @Test func historyEntryBecomesUpgraded() {
        let log = HistoryLog(url: nil)
        let id = UUID()
        log.record(HistoryEntry(id: id, startedAt: Date(), duration: 3, command: "brew upgrade aws-c-auth",
                                arguments: ["upgrade", "aws-c-auth"], outcome: .failed, exitCode: 1,
                                outputTail: ["Error: awscli: the dependency lz4 is pinned"]))
        #expect(log.markUpgradedAnyway(id, overAnotherPackage: true))
        let e = log.entries[0]
        #expect(e.outcome == .succeeded)
        #expect(!e.isFailure)
        #expect(!e.canRetry)
        #expect(e.resultText == "upgraded (brew then exited 1 over another package)")
        #expect(!log.markUpgradedAnyway(UUID(), overAnotherPackage: true))
    }
}
