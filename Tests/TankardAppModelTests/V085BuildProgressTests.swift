import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: time so far and an estimate for builds from source (BuildProgress.swift).

@MainActor
struct BuildProgressTextTests {
    @Test func roundedNeverMorePreciseThanItIs() {
        #expect(BuildProgress.elapsedText(20) == "under a minute")
        #expect(BuildProgress.elapsedText(4 * 60 + 50) == "4 min")
        #expect(BuildProgress.elapsedText(65 * 60) == "1 h 5 min")
        #expect(BuildProgress.elapsedText(120 * 60) == "2 h")
        #expect(BuildProgress.estimateText(7.4 * 60) == "7 min")
        #expect(BuildProgress.estimateText(23 * 60) == "25 min")
        #expect(BuildProgress.estimateText(83 * 60) == "1 h 30 min")
        #expect(BuildProgress.estimateText(10) == "1 min")
        #expect(BuildProgress.line(elapsed: 240, estimate: nil) == "Building from source… 4 min so far")
        #expect(BuildProgress.line(elapsed: 240, estimate: 14 * 60)
                == "Building from source… 4 min so far (last time on this Mac: about 15 min)")
    }

    @Test func estimateIsTheMedianOfThisMacsLastBuilds() {
        let p = Package.command("node")
        func entry(_ args: [String], _ d: TimeInterval, built: Bool? = true, outcome: HistoryEntry.Outcome = .succeeded) -> HistoryEntry {
            var e = HistoryEntry(startedAt: Date(), duration: d, command: "brew " + args.joined(separator: " "), arguments: args, outcome: outcome)
            e.builtFromSource = built
            return e
        }
        #expect(BuildProgress.estimate(for: p, history: []) == nil)
        let history = [
            entry(["upgrade", "--formula", "homebrew/core/node"], 1200),
            entry(["upgrade", "--formula", "node"], 30, built: nil),  // a bottle: not a build
            entry(["install", "--formula", "node"], 900, outcome: .failed),  // failed: no
            entry(["upgrade", "--formula", "node", "xz"], 5000),  // several packages: no
            entry(["install", "--formula", "node"], 1500),
            entry(["upgrade", "--formula", "nodenv"], 99),  // another formula
            entry(["upgrade", "--formula", "node"], 1000),
            entry(["upgrade", "--formula", "node"], 9999),  // a fourth one: only the last three count
        ]
        #expect(BuildProgress.estimate(for: p, history: history) == 1200)
    }

    @Test func onlyFormulaeWithoutABottleBuild() {
        var p = Package.command("node")
        p.upgradeHasBottle = false
        #expect(BuildProgress.buildsFromSource(p, action: .upgrade))
        #expect(BuildProgress.buildsFromSource(p, action: .install))
        #expect(!BuildProgress.buildsFromSource(p, action: .uninstall))
        p.upgradeHasBottle = true
        #expect(!BuildProgress.buildsFromSource(p, action: .upgrade))
    }
}

@MainActor
struct BuildProgressSessionTests {
    let base = ParallelLoadTests()

    @Test func theSheetShowsTimeSoFarThenRemembersTheBuild() async throws {
        let clock = FakeClock85()
        let gate = Latch()
        let r = try await base.rig(now: { clock.now }, stream: { args, out in
            if args.first == "upgrade" {
                out(Data("==> ./configure --prefix=/usr/local/Cellar/x\n".utf8))
                await gate.wait()
            }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        var target = try #require(r.store.upgradable.first { $0.kind == .formula })
        target.upgradeHasBottle = false
        // An earlier build of it on this Mac: 14 min.
        var earlier = HistoryEntry(startedAt: clock.now.addingTimeInterval(-86400), duration: 14 * 60, command: "brew upgrade",
                                   arguments: ["upgrade", "--formula", target.fullName], outcome: .succeeded)
        earlier.builtFromSource = true
        r.store.history.record(earlier)

        r.store.startUpgrade([target])
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { s.current != nil })
        #expect(s.buildLine(at: clock.now) == "Building from source… under a minute so far (last time on this Mac: about 15 min)")
        clock.advance(4 * 60 + 10)
        #expect(s.buildLine(at: clock.now) == "Building from source… 4 min so far (last time on this Mac: about 15 min)")
        gate.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.buildLine(at: clock.now) == nil)
        // This build is in History as one, for the next estimate.
        #expect(await waitUntil { r.store.history.entries.first { $0.id == s.items[0].id }?.builtFromSource == true })
    }

    @Test func aBottlePouredAfterAllIsNoBuild() async throws {
        let gate = Latch()
        let r = try await base.rig(stream: { args, out in
            if args.first == "upgrade" {
                out(Data("==> Pouring x--1.0.sonoma.bottle.tar.gz\n".utf8))
                await gate.wait()
            }
            out(Data("ok\n".utf8))
            return 0
        })
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        var target = try #require(r.store.upgradable.first { $0.kind == .formula })
        target.upgradeHasBottle = false
        r.store.startUpgrade([target])
        let s = try #require(r.store.upgrade)
        #expect(await waitUntil { !s.pouringItems.isEmpty })
        #expect(s.buildLine(at: Date()) == nil)
        gate.release()
        #expect(await waitUntil { s.isFinished })
        #expect(await waitUntil { r.store.history.entries.contains { $0.id == s.items[0].id } })
        #expect(r.store.history.entries.first { $0.id == s.items[0].id }?.builtFromSource == nil)
    }

    @Test func aBottledUpgradeShowsNoBuildLine() async throws {
        let r = try await base.rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.start()
        await r.store.insights.waitForIdle()
        var target = try #require(r.store.upgradable.first { $0.kind == .formula })
        target.upgradeHasBottle = true
        r.store.startUpgrade([target])
        let s = try #require(r.store.upgrade)
        #expect(s.compilingItems.isEmpty)
        #expect(await waitUntil { s.isFinished })
    }
}
