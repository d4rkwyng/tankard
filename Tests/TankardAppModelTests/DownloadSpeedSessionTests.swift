import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4: the sheet's download speed and time left (Derek: on a slow
// connection "2.1 of 2.3 GB (91%)" barely moves, and he couldn't tell
// whether it was still working). brew is a fake; the download is a fake
// file in a fake folder; the session's clock is the test's, moved by hand.
// 0.9.4 (review): polls are delivered by the test, not by the session's
// poll loop: the session watches nothing here (no DownloadMonitor), and
// the test hands each poll of a real DownloadWatcher over the fake folder
// to `showDownload`, the method the loop calls. No poll cadence and no
// timeout in any check; waitUntil only waits for brew's (fake) command to
// start or end. Every test opens brew's latch in a `defer`, so a failed
// #require can't leave the command (and the suite) waiting. The loop
// itself is covered by DownloadProgressSessionTests.

/// A downloads folder in memory (as GrowingFolder), from which a file can
/// also be removed (brew deletes a partial file after a failure). A new
/// name gets a new file number; growing and a rename keep it.
final class SpeedFolder: DownloadFolderReading, @unchecked Sendable {
    /// Runs after a listing was taken (a change between two reads of one poll).
    var afterListing: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var files: [String: Int64] = [:]
    private var ids: [String: DownloadFileID] = [:]
    private var nextID: UInt64 = 1
    private var contents: [String: Data] = [:]
    let modified: Date

    init(modified: Date) { self.modified = modified }

    func set(_ name: String, size: Int64, data: Data? = nil) {
        lock.withLock {
            files[name] = size
            contents[name] = data
            if ids[name] == nil {
                ids[name] = DownloadFileID(device: 1, inode: nextID)
                nextID += 1
            }
        }
    }
    func remove(_ name: String) {
        lock.withLock {
            _ = files.removeValue(forKey: name)
            _ = ids.removeValue(forKey: name)
        }
    }
    func rename(_ from: String, _ to: String) {
        lock.withLock {
            if let f = files.removeValue(forKey: from) {
                files[to] = f
                ids[to] = ids.removeValue(forKey: from)
            }
        }
    }
    func files(in directory: String) -> [String] {
        let names = lock.withLock { Array(files.keys) }
        afterListing?()
        return names
    }
    func stat(_ path: String) -> (size: Int64, modified: Date, fileID: DownloadFileID?)? {
        let n = (path as NSString).lastPathComponent
        return lock.withLock { files[n].map { ($0, modified, ids[n]) } }
    }
    func read(_ path: String) -> Data? {
        let n = (path as NSString).lastPathComponent
        return lock.withLock { contents[n] }
    }
}

/// A clock the test moves.
final class SteppedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ time: TimeInterval) { self.time = time }
    var date: Date { lock.withLock { Date(timeIntervalSinceReferenceDate: time) } }
    func set(_ t: TimeInterval) { lock.withLock { time = t } }
}

@MainActor
struct DownloadSpeedSessionTests {
    /// font-inter's download, a bottle: its total comes from the manifest
    /// beside it at once (a cask's would wait on a HEAD request's task).
    nonisolated static let done = String(repeating: "a", count: 64) + "--font-inter--4.1.sonoma.bottle.tar.gz"
    nonisolated static let file = done + ".incomplete"
    nonisolated static let manifest = String(repeating: "b", count: 64) + "--font-inter-4.1.bottle_manifest.json"
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
        var folder: SpeedFolder
        var watcher: DownloadWatcher
        var clock: SteppedClock
        var finish: Latch
    }

    /// An install of font-inter (or, with `prefetch`, an upgrade of two
    /// casks that `brew fetch` downloads first), its command running when
    /// this returns. brew waits for `finish` (open it in a `defer`).
    func start(total: Int64? = total, prefetch: Bool = false) async -> Run {
        let folder = SpeedFolder(modified: Date())
        if let total {
            let entry = ["annotations": ["org.opencontainers.image.ref.name": "4.1.sonoma", "sh.brew.bottle.size": String(total)]]
            folder.set(Self.manifest, size: 1, data: try! JSONSerialization.data(withJSONObject: ["manifests": [entry]]))
        }
        let clock = SteppedClock(Self.base)
        let finish = Latch()
        let runner = FakeStreamRunner(log: CallLog()) { _, _ in
            await finish.wait()
            return 0
        }
        let packages = prefetch ? [cask("font-inter"), cask("font-hack")] : [cask("font-inter")]
        let s = UpgradeSession(packages: packages, intelbrewMode: false, action: prefetch ? .upgrade : .install,
                               queue: CommandQueue(runner: runner),
                               makeCommand: { p in Self.command(["install", "--cask", p.name]) }, logURL: nil,
                               downloads: nil,
                               prefetch: prefetch ? Prefetch.steps(.upgrade, packages, make: Self.command) : [],
                               onFinish: { _ in })
        s.now = { clock.date }
        let watcher = DownloadWatcher(directory: "/cache/downloads", reader: folder, since: folder.modified)
        #expect(await waitUntil { prefetch ? s.isFetching : s.current != nil })
        return Run(session: s, folder: folder, watcher: watcher, clock: clock, finish: finish)
    }

    /// Moves the clock to `t` seconds and delivers one poll of the folder
    /// as it is now (what the session's poll loop does every 250 ms).
    func poll(_ r: Run, at t: TimeInterval) async {
        r.clock.set(Self.base + t)
        r.session.showDownload(await r.watcher.sample())
    }

    /// Moves the clock to `t` seconds and the file to `bytes`, and waits
    /// until the session has polled both.
    func step(_ r: Run, _ t: TimeInterval, _ bytes: Int64, sourceLocation: SourceLocation = #_sourceLocation) async {
        r.folder.set(Self.file, size: bytes)
        await poll(r, at: t)
        #expect(r.session.download?.bytes == bytes, sourceLocation: sourceLocation)
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
        r.folder.rename(Self.file, Self.done)
        r.finish.release()
        #expect(await waitUntil { r.session.isFinished })
    }

    @Test func speedThenTimeLeftWithAKnownTotal() async throws {
        let r = await start()
        defer { r.finish.release() }
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
        let r = await start(total: nil)
        defer { r.finish.release() }
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
        let r = await start()
        defer { r.finish.release() }
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
        let r = await start(prefetch: true)
        defer { r.finish.release() }
        let s = r.session
        await steady(r, to: 6)
        #expect(s.isFetching)
        #expect(s.statusLine == "Downloading 0 of 2 · 26.2 of 336.0 MB (7%) · 4.2 MB/s · about 1 min left")
        #expect(s.statusAccessibilityLabel(behindBrewUpdate: false, at: r.clock.date)
                == "Downloading 0 of 2, 26.2 of 336.0 MB, 7 percent, 4.2 megabytes per second, about 1 minute left")
        await end(r)
    }

    @Test func spokenLineForOneCommand() async throws {
        let r = await start()
        defer { r.finish.release() }
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
        let r = await start()
        defer { r.finish.release() }
        let s = r.session
        await poll(r, at: 0)
        #expect(s.download == nil)
        let later = Date(timeIntervalSinceReferenceDate: Self.base + 100)
        #expect(s.statusLine == "Installing font-inter…")
        #expect(s.statusLine(behindBrewUpdate: false, at: later) == "Installing font-inter…")
        #expect(s.statusAccessibilityLabel(behindBrewUpdate: false, at: later) == "Installing font-inter…")
        #expect(s.downloadRate(at: later) == .none)
        await steady(r, to: 6)
        #expect(s.statusLine.contains("MB/s"))
        // Done downloading: the action again, and the tracker is reset.
        r.folder.rename(Self.file, Self.done)
        await poll(r, at: 6.5)
        #expect(s.download == nil)
        #expect(s.statusLine == "Installing font-inter…")
        #expect(s.statusLine(behindBrewUpdate: false, at: later) == "Installing font-inter…")
        #expect(s.downloadSpeed.sampleCount == 0)
        r.finish.release()
        #expect(await waitUntil { s.isFinished })
        #expect(s.statusLine == "1 installed")
        #expect(s.statusLine(behindBrewUpdate: false, at: later) == "1 installed")
    }

    // MARK: round 1 review (Sol)

    /// A partial file that brew deletes (a failed download) is not new
    /// bytes: a stalled line stays "Waiting for data…" with no speed.
    /// Before, the watcher credited the deleted file with its expected
    /// total, a jump the tracker read as growth.
    @Test func deletedPartialFileKeepsTheStallAndShowsNoSpeed() async throws {
        let r = await start()
        defer { r.finish.release() }
        let s = r.session
        // font-inter's file (its total known, 336 MB) and another one.
        r.folder.set(Self.otherFile, size: 10_000_000)
        r.folder.set(Self.file, size: 20_000_000)
        var t: TimeInterval = 0
        while t <= 6 {
            await poll(r, at: t)
            t += 0.5
        }
        #expect(s.download?.bytes == 30_000_000)
        #expect(s.downloadRate(at: r.clock.date) == .stalled)
        r.folder.remove(Self.file)
        await poll(r, at: 6.25)
        await poll(r, at: 6.5)
        #expect(s.download?.bytes == 10_000_000 && s.download?.files == 1)
        #expect(s.downloadRate(at: r.clock.date) == .stalled)
        #expect(s.statusLine.hasSuffix(" · Waiting for data…"), "\(s.statusLine)")
        #expect(!s.statusLine.contains("/s"))
    }

    /// A poll that lands after the sheet's date: the rate at that earlier
    /// date is the rate at the newest poll (DownloadSpeed clamps a query
    /// time to its newest sample), so the speed and time left go with the
    /// byte count on screen. Before, the earlier date gave the reading of
    /// three seconds ago (a speed, no time left) next to the newest bytes.
    @Test func pollAfterTheQueryDateGivesTheNewestRate() async throws {
        let r = await start()
        defer { r.finish.release() }
        let s = r.session
        await steady(r, to: 6)
        let earlier = Date(timeIntervalSinceReferenceDate: Self.base + 3)
        let newest = r.clock.date
        #expect(s.downloadRate(at: earlier) == s.downloadRate(at: newest))
        #expect(s.statusLine(behindBrewUpdate: false, at: earlier) == s.statusLine(behindBrewUpdate: false, at: newest))
        guard case .rate(let bps, let eta?) = s.downloadRate(at: earlier) else {
            Issue.record("\(s.downloadRate(at: earlier))")
            return
        }
        #expect(abs(bps - 4_200_000) < 1_000 && eta > 0 && eta < 100)
        #expect(s.statusLine(behindBrewUpdate: false, at: earlier)
                == "Downloading font-inter… 26.2 of 336.0 MB (7%) · 4.2 MB/s · about 1 min left")
    }

    // MARK: round 2 review (Sol)

    /// 20 MB of font-inter's file and a stalled 10 MB other file, beside an
    /// old finished font-inter file of 100 MB. Delete font-inter's partial
    /// file: 10 MB, still "Waiting for data…". Before, the old file read as
    /// the partial one renamed: 110 MB, a jump that cleared the stall.
    @Test func oldFinalFileOfTheSameNameKeepsTheStall() async throws {
        let r = await start()
        defer { r.finish.release() }
        let s = r.session
        r.folder.set(Self.done, size: 100_000_000)
        r.folder.set(Self.otherFile, size: 10_000_000)
        r.folder.set(Self.file, size: 20_000_000)
        var t: TimeInterval = 0
        while t <= 6 {
            await poll(r, at: t)
            t += 0.5
        }
        #expect(s.download?.bytes == 30_000_000)
        #expect(s.downloadRate(at: r.clock.date) == .stalled)
        r.folder.remove(Self.file)
        await poll(r, at: 6.25)
        await poll(r, at: 6.5)
        #expect(s.download?.bytes == 10_000_000 && s.download?.files == 1, "\(String(describing: s.download))")
        #expect(s.downloadRate(at: r.clock.date) == .stalled)
        #expect(s.statusLine.hasSuffix(" · Waiting for data…"), "\(s.statusLine)")
        #expect(!s.statusLine.contains("/s"))
    }

    /// The other file grows 2.1 MB on the poll that deletes font-inter's
    /// partial file: the line's bytes fall (30 MB to 12.1 MB), but the
    /// stall is over and the speed is the other file's 2.1 MB over the
    /// 6.25 s the samples cover. Before, the fall restarted the tracker
    /// and kept the stall.
    @Test func growthOnThePollThatDeletesAFileEndsTheStall() async throws {
        let r = await start()
        defer { r.finish.release() }
        let s = r.session
        r.folder.set(Self.otherFile, size: 10_000_000)
        r.folder.set(Self.file, size: 20_000_000)
        var t: TimeInterval = 0
        while t <= 6 {
            await poll(r, at: t)
            t += 0.5
        }
        #expect(s.downloadRate(at: r.clock.date) == .stalled)
        r.folder.remove(Self.file)
        r.folder.set(Self.otherFile, size: 12_100_000)
        await poll(r, at: 6.25)
        #expect(s.download?.bytes == 12_100_000 && s.download?.files == 1)
        let rate = s.downloadRate(at: r.clock.date)
        let bps: Double
        switch rate {
        case .measuring(let b), .rate(let b, _): bps = b
        default:
            Issue.record("\(rate)")
            return
        }
        #expect(abs(bps - 2_100_000 / 6.25) < 1_000, "\(bps)")
        #expect(s.statusLine.hasSuffix(" · 336 KB/s"), "\(s.statusLine)")
    }

    nonisolated static let otherFile = String(repeating: "c", count: 64) + "--Other-1.0.zip.incomplete"
}

/// The CHANGELOG's example is what the formatter says: 2.1 of 2.3 GB at
/// 4.2 MB/s leaves 200 MB, about 48 s ("about 50 sec left").
struct ChangelogExampleTests {
    @Test func changelogExampleMatchesTheFormatter() throws {
        var speed = DownloadSpeed()
        let bytes: Int64 = 2_100_000_000
        for i in 0...40 {
            let t = Double(i) * 0.25
            speed.record(bytes: bytes - Int64(4_200_000 * (10 - t)), at: t)
        }
        let d = DownloadProgress(name: nil, bytes: bytes, total: 2_300_000_000)
        let eta = try #require(speed.eta(bytes: d.bytes, total: d.total, at: 10))
        let us = Locale(identifier: "en_US")
        let line = "Downloading 10 of 11 · " + d.detail + " · " + DownloadSpeedFormat.speed(speed.speed(at: 10)!, locale: us)
            + " · " + DownloadSpeedFormat.timeLeftText(eta)
        #expect(line == "Downloading 10 of 11 · 2.1 of 2.3 GB (91%) · 4.2 MB/s · about 50 sec left")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let unreleased = try #require(changelog.components(separatedBy: "\n## [").dropFirst().first)
        #expect(unreleased.contains("\"\(line)\""))
    }
}

/// The demo's "slow" download (the screenshot) is steady: polled every
/// 250 ms it still gets a time left under the stricter stability rule
/// (round 1 review), and the "stall" one never does.
struct DemoDownloadTests {
    func rate(_ scenario: Demo.DownloadScenario, until: TimeInterval) -> (speed: Double?, eta: TimeInterval?) {
        let fake = Demo.FakeDownload(scenario: scenario)
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        fake.start(t0)
        var tracker = DownloadSpeed()
        var t: TimeInterval = 0
        while t <= until {
            tracker.record(bytes: fake.size(at: t0 + t) ?? 0, at: t0 + t)
            t += 0.25
        }
        let now = t0 + until
        let bytes = fake.size(at: now) ?? 0
        return (tracker.speed(at: now), tracker.eta(bytes: bytes, total: Demo.FakeDownload.total, at: now))
    }

    @Test func slowDemoShowsASpeedAndATimeLeft() throws {
        let r = rate(.slow, until: 6)
        #expect(DownloadSpeedFormat.speed(try #require(r.speed), locale: Locale(identifier: "en_US")) == "4.2 MB/s")
        let eta = try #require(r.eta)
        #expect(DownloadSpeedFormat.timeLeftText(eta) == "about 45 sec left")
    }

    @Test func stallDemoShowsNoTimeLeft() {
        #expect(rate(.stall, until: 9).eta == nil)
    }
}
