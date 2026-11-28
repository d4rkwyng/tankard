import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.10: the sheet's download speed and time left (Derek: on a slow
// connection "2.1 of 2.3 GB (91%)" barely moves, and he couldn't tell
// whether it was still working). brew is a fake; the download is a fake
// file in a fake folder (GrowingFolder, V08DownloadProgressTests.swift);
// the session's clock is the test's, moved by hand. No real waiting in the
// checks: waitUntil only waits for the session's poll to have seen a step.

/// A clock the test moves.
final class SteppedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ time: TimeInterval) { self.time = time }
    var date: Date { lock.withLock { Date(timeIntervalSinceReferenceDate: time) } }
    func set(_ t: TimeInterval) { lock.withLock { time = t } }
}

@MainActor
struct V0100DownloadSpeedSessionTests {
    nonisolated static let url = DownloadProgressSessionTests.url
    nonisolated static let file = DownloadProgressSessionTests.file + ".incomplete"
    /// The test clock's start (exact in binary, as every step below).
    nonisolated static let base: TimeInterval = 900_000_000
    nonisolated static let total: Int64 = 336_000_000

    func cask(_ name: String) -> Package {
        var p = Package.command(name)
        p.id = "cask:homebrew/cask/\(name)"
        p.kind = .cask
        p.fullName = name
        p.tap = "homebrew/cask"
        p.currentVersion = "4.1"
        return p
    }

    nonisolated static func command(_ args: [String]) -> QueuedCommand {
        QueuedCommand(executable: "/opt/homebrew/bin/brew", arguments: args, environment: [:], display: args.joined(separator: " "))
    }

    struct Run {
        var session: UpgradeSession
        var folder: GrowingFolder
        var clock: SteppedClock
        var finish: Latch
    }

    /// An install of font-inter (or, with `prefetch`, an upgrade of two
    /// casks that `brew fetch` downloads first). brew waits for `finish`.
    func start(total: Int64? = total, prefetch: Bool = false) -> Run {
        let folder = GrowingFolder(modified: Date())
        let clock = SteppedClock(Self.base)
        let finish = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            await finish.wait()
            return 0
        }
        let monitor = DownloadMonitor(directory: { "/cache/downloads" }, urls: { _ in [Self.url] },
                                      reader: folder, lengths: StaticLengths(sizes: total.map { [Self.url: $0] } ?? [:]),
                                      interval: .milliseconds(5), now: { folder.modified })
        let packages = prefetch ? [cask("font-inter"), cask("font-hack")] : [cask("font-inter")]
        let s = UpgradeSession(packages: packages, intelbrewMode: false, action: prefetch ? .upgrade : .install,
                               queue: CommandQueue(runner: runner),
                               makeCommand: { p in Self.command(["install", "--cask", p.name]) }, logURL: nil,
                               downloads: monitor,
                               prefetch: prefetch ? Prefetch.steps(.upgrade, packages, make: Self.command) : [],
                               onFinish: { _ in })
        // Set before any download exists (the file appears at the first step).
        s.now = { clock.date }
        return Run(session: s, folder: folder, clock: clock, finish: finish)
    }

    /// Moves the clock to `t` seconds and the file to `bytes`, and waits
    /// until the session has polled both.
    func step(_ r: Run, _ t: TimeInterval, _ bytes: Int64, sourceLocation: SourceLocation = #_sourceLocation) async {
        r.clock.set(Self.base + t)
        r.folder.set(Self.file, size: bytes)
        let seen = r.session.downloadObservations
        #expect(await waitUntil { r.session.downloadObservations >= seen + 2 && r.session.download?.bytes == bytes },
                sourceLocation: sourceLocation)
    }

    /// 4.2 MB/s from 1 MB, a step every half second up to `to`.
    func steady(_ r: Run, from: TimeInterval = 0, to: TimeInterval) async {
        var t = from
        while t <= to {
            await step(r, t, Self.bytes(t))
            t += 0.5
        }
    }

    nonisolated static func bytes(_ t: TimeInterval) -> Int64 { 1_000_000 + Int64(4_200_000 * t) }

    func end(_ r: Run) async {
        r.folder.rename(Self.file, DownloadProgressSessionTests.file)
        r.finish.release()
        #expect(await waitUntil { r.session.isFinished })
    }

    @Test func speedThenTimeLeftWithAKnownTotal() async throws {
        let r = start()
        let s = r.session
        await steady(r, to: 1)
        // Under 2 s of samples: the line as before.
        var d = try #require(s.download)
        #expect(s.downloadRate(at: r.clock.date) == .none)
        #expect(s.statusLine == "Downloading font-inter… " + d.detail)
        await steady(r, from: 1.5, to: 3)
        // A speed, not yet steady enough for a time left.
        d = try #require(s.download)
        guard case .measuring(let bps) = s.downloadRate(at: r.clock.date) else {
            Issue.record("\(s.downloadRate(at: r.clock.date))")
            return
        }
        #expect(abs(bps - 4_200_000) < 1_000)
        #expect(s.statusLine == "Downloading font-inter… " + d.detail + " · 4.2 MB/s")
        await steady(r, from: 3.5, to: 6)
        d = try #require(s.download)
        #expect(d.detail == "26.2 of 336.0 MB (7%)")
        // 309.8 MB left at 4.2 MB/s: 74 s.
        #expect(s.statusLine == "Downloading font-inter… 26.2 of 336.0 MB (7%) · 4.2 MB/s · about 1 min left")
        // The sheet passes its TimelineView's date; the same line.
        #expect(s.statusLine(behindBrewUpdate: false, at: r.clock.date) == s.statusLine)
        guard case .rate(_, let eta?) = s.downloadRate(at: r.clock.date) else {
            Issue.record("no time left: \(s.downloadRate(at: r.clock.date))")
            return
        }
        #expect(abs(eta - 73.76) < 0.5)
        await end(r)
    }

    @Test func unknownTotalShowsTheSpeedButNoTimeLeft() async throws {
        let r = start(total: nil)
        let s = r.session
        await steady(r, to: 8)
        let d = try #require(s.download)
        #expect(d.total == nil)
        #expect(s.statusLine == "Downloading font-inter… " + d.detail + " · 4.2 MB/s")
        #expect(s.statusLine.hasSuffix("so far · 4.2 MB/s"))
        guard case .rate(_, nil) = s.downloadRate(at: r.clock.date) else {
            Issue.record("\(s.downloadRate(at: r.clock.date))")
            return
        }
        await end(r)
    }

    @Test func fiveSecondsWithoutBytesSaysWaitingThenRecovers() async throws {
        let r = start()
        let s = r.session
        await steady(r, to: 6)
        let d = try #require(s.download)
        let head = "Downloading font-inter… " + d.detail
        // No new bytes since 6 s: still a speed at 10.9 s, waiting at 11 s.
        let at109 = s.statusLine(behindBrewUpdate: false, at: Date(timeIntervalSinceReferenceDate: Self.base + 10.9))
        #expect(at109.hasPrefix(head + " · ") && at109.contains("MB/s"))
        #expect(s.statusLine(behindBrewUpdate: false, at: Date(timeIntervalSinceReferenceDate: Self.base + 11))
                == head + " · Waiting for data…")
        // The same through the session's clock, with polls going on.
        await step(r, 8, Self.bytes(6))
        await step(r, 11, Self.bytes(6))
        #expect(s.downloadRate(at: r.clock.date) == .stalled)
        #expect(s.statusLine == head + " · Waiting for data…")
        #expect(!s.statusLine.contains("MB/s") && !s.statusLine.contains("left"))
        // Bytes again: a speed again.
        await step(r, 11.5, Self.bytes(6) + 2_100_000)
        #expect(!s.statusLine.contains("Waiting"))
        #expect(s.statusLine.contains(" MB/s"))
        await end(r)
    }

    @Test func prefetchLineGetsTheSpeedToo() async throws {
        let r = start(prefetch: true)
        let s = r.session
        #expect(await waitUntil { s.isFetching })
        await steady(r, to: 6)
        #expect(s.isFetching)
        #expect(s.statusLine == "Downloading 0 of 2 · 26.2 of 336.0 MB (7%) · 4.2 MB/s · about 1 min left")
        #expect(s.statusAccessibilityLabel(behindBrewUpdate: false, at: r.clock.date)
                == "Downloading 0 of 2, 26.2 of 336.0 MB, 7 percent, 4.2 megabytes per second, about 1 minute left")
        await end(r)
    }

    @Test func spokenLineForOneCommand() async throws {
        let r = start()
        let s = r.session
        await steady(r, to: 6)
        #expect(s.statusAccessibilityLabel(behindBrewUpdate: false, at: r.clock.date)
                == "Downloading font-inter, 26.2 of 336.0 MB, 7 percent, 4.2 megabytes per second, about 1 minute left")
        // Stalled: "Waiting for data…" stays as it is.
        #expect(s.statusAccessibilityLabel(behindBrewUpdate: false, at: Date(timeIntervalSinceReferenceDate: Self.base + 11))
                == "Downloading font-inter, 26.2 of 336.0 MB, 7 percent, Waiting for data…")
        await end(r)
    }

    /// Without a download every line is what it was, at any time.
    @Test func noDownloadLeavesTheLineAsItWas() async throws {
        let r = start()
        let s = r.session
        #expect(await waitUntil { s.current != nil })
        #expect(s.download == nil)
        let later = Date(timeIntervalSinceReferenceDate: Self.base + 100)
        #expect(s.statusLine == "Installing font-inter…")
        #expect(s.statusLine(behindBrewUpdate: false, at: later) == "Installing font-inter…")
        #expect(s.statusAccessibilityLabel(behindBrewUpdate: false, at: later) == "Installing font-inter…")
        #expect(s.downloadRate(at: later) == .none)
        await steady(r, to: 6)
        #expect(s.statusLine.contains("MB/s"))
        // Done downloading: the action again, and the tracker is reset.
        r.folder.rename(Self.file, DownloadProgressSessionTests.file)
        #expect(await waitUntil { s.download == nil })
        #expect(s.statusLine == "Installing font-inter…")
        #expect(s.statusLine(behindBrewUpdate: false, at: later) == "Installing font-inter…")
        #expect(s.downloadSpeed.sampleCount == 0)
        r.finish.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.statusLine == "1 installed")
        #expect(s.statusLine(behindBrewUpdate: false, at: later) == "1 installed")
    }
}
