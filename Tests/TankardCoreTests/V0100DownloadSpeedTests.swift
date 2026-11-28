import Foundation
import Testing
@testable import TankardCore

// 0.9.4: the sheet's download speed and time left (Derek: on a slow
// connection "2.1 of 2.3 GB (91%)" barely moves). The tracker gets every
// time from the test: polls every 250 ms, as the sheet's.

struct V0100DownloadSpeedTests {
    static let poll: TimeInterval = 0.25
    /// An arbitrary start (exact in binary, as every poll time below).
    static let t0: TimeInterval = 1000

    /// Feeds `bytes(t)` (t: seconds since t0) at each poll from `from` to `to`.
    @discardableResult
    static func feed(_ s: inout DownloadSpeed, from: TimeInterval = 0, to: TimeInterval,
                     _ bytes: (TimeInterval) -> Double) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var t = from
        while t <= to + 1e-9 {
            s.record(bytes: Int64(bytes(t)), at: t0 + t)
            times.append(t)
            t += poll
        }
        return times
    }

    static func near(_ a: Double?, _ b: Double, within: Double = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= within * b
    }

    @Test func steadyRateGivesSpeedAndTimeLeft() throws {
        var s = DownloadSpeed()
        Self.feed(&s, to: 10) { 4_200_000 * $0 }
        let now = Self.t0 + 10
        #expect(Self.near(s.speed(at: now), 4_200_000))
        #expect(s.isStable(at: now))
        let eta = try #require(s.eta(remaining: 210_000_000, at: now))
        #expect(abs(eta - 50) < 0.5)
        #expect(!s.isStalled(at: now))
    }

    @Test func noSpeedBeforeTwoSeconds() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 1.75) { 4_200_000 * $0 }
        #expect(s.speed(at: Self.t0 + 1.75) == nil)
        s.record(bytes: 8_400_000, at: Self.t0 + 2)
        #expect(Self.near(s.speed(at: Self.t0 + 2), 4_200_000))
        // A speed, but not yet a time left (under 4 s of samples).
        #expect(s.eta(remaining: 100_000_000, at: Self.t0 + 2) == nil)
    }

    /// 100 KB/s for 2 s, then 4 MB/s: the speed shows at once, the time
    /// left only once the window has caught up (the newest half within 40%).
    @Test func rampUpGivesNoTimeLeftUntilStable() {
        var s = DownloadSpeed()
        let bytes: (TimeInterval) -> Double = { 100_000 * min($0, 2) + 4_000_000 * max(0, $0 - 2) }
        for t in Self.feed(&s, to: 12, bytes) where t >= 2 {
            let eta = Self.etaAfter(bytes, t)
            if t < 7 { #expect(eta == nil, "t=\(t)") }
            if t >= 8 { #expect(eta != nil, "t=\(t)") }
        }
        #expect(Self.near(s.speed(at: Self.t0 + 12), 4_000_000))
    }

    /// The time left a fresh tracker gives at `t` after `bytes` up to `t`.
    static func etaAfter(_ bytes: (TimeInterval) -> Double, _ t: TimeInterval) -> TimeInterval? {
        var s = DownloadSpeed()
        feed(&s, to: t, bytes)
        return s.eta(remaining: 500_000_000, at: t0 + t)
    }

    /// A bursty link: 1 s at 8 MB/s, then 9 s of nothing, over and over.
    /// Almost never a time left (only when the newest half's speed sweeps
    /// past the window's), and never right after a burst or mid-gap.
    @Test func burstyRateGivesNoTimeLeft() {
        var s = DownloadSpeed()
        let bytes: (TimeInterval) -> Double = { t in
            let k = (t / 10).rounded(.down)
            return 8_000_000 * (k + min(t - k * 10, 1))
        }
        var shown = 0, polls = 0
        var t: TimeInterval = 0
        while t <= 90 {
            s.record(bytes: Int64(bytes(t)), at: Self.t0 + t)
            if t >= 10 {
                polls += 1
                if s.eta(remaining: 500_000_000, at: Self.t0 + t) != nil { shown += 1 }
                if [11, 16, 18, 21, 26, 31].contains(t) { #expect(s.eta(remaining: 500_000_000, at: Self.t0 + t) == nil, "t=\(t)") }
            }
            t += Self.poll
        }
        #expect(Double(shown) <= 0.05 * Double(polls), "\(shown) of \(polls)")
    }

    /// 8 MB/s, then 2 MB/s from 10 s: the average moves within the window
    /// (5 MB/s halfway, 2 MB/s once the window has passed the change), and
    /// the time left hides while it moves.
    @Test func slowDownMovesTheAverage() {
        var s = DownloadSpeed()
        let bytes: (TimeInterval) -> Double = { 8_000_000 * min($0, 10) + 2_000_000 * max(0, $0 - 10) }
        Self.feed(&s, to: 20, bytes)
        #expect(Self.near(s.speed(at: Self.t0 + 20), 2_000_000))
        #expect(Self.etaAfter(bytes, 10) != nil)
        #expect(Self.etaAfter(bytes, 15) == nil)
        #expect(Self.etaAfter(bytes, 19) != nil)
        var half = DownloadSpeed()
        Self.feed(&half, to: 14, bytes)
        #expect(Self.near(half.speed(at: Self.t0 + 14), 5_000_000))
    }

    @Test func stallStartsAtFiveSeconds() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 10) { 1_000_000 * $0 }
        // No growth after 10 s; polls go on. (A time before the newest
        // sample counts as that sample's, so 4.9 s is asked before the
        // poll at 5 s.)
        Self.feed(&s, from: 10.25, to: 14.75) { _ in 10_000_000 }
        #expect(!s.isStalled(at: Self.t0 + 14.9))
        s.record(bytes: 10_000_000, at: Self.t0 + 15)
        #expect(s.isStalled(at: Self.t0 + 15))
        #expect(s.eta(remaining: 1_000_000, at: Self.t0 + 15) == nil)
        // The speed falls while stalled, and never below 0.
        let speed = s.speed(at: Self.t0 + 15) ?? -1
        #expect(speed >= 0 && speed < 1_000_000)
    }

    @Test func neverGrowingStallsFromTheFirstSample() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 4.75) { _ in 3_000 }
        #expect(!s.isStalled(at: Self.t0 + 4.9))
        s.record(bytes: 3_000, at: Self.t0 + 5)
        #expect(s.isStalled(at: Self.t0 + 5))
    }

    @Test func recoversAfterAStall() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 10) { 1_000_000 * $0 }
        Self.feed(&s, from: 10.25, to: 16) { _ in 10_000_000 }
        #expect(s.isStalled(at: Self.t0 + 16))
        s.record(bytes: 10_250_000, at: Self.t0 + 16.25)
        #expect(!s.isStalled(at: Self.t0 + 16.25))
        #expect((s.speed(at: Self.t0 + 16.25) ?? 0) > 0)
        // Steady again: a time left once the window holds the new speed.
        Self.feed(&s, from: 16.5, to: 26) { 10_000_000 + 1_000_000 * ($0 - 16) }
        #expect(Self.near(s.speed(at: Self.t0 + 26), 1_000_000))
        #expect(s.eta(remaining: 30_000_000, at: Self.t0 + 26) != nil)
    }

    /// A burst more than 8 s ago no longer counts; with no new bytes the
    /// speed falls to 0 as the window slides past the last growth.
    @Test func windowSlides() {
        var s = DownloadSpeed()
        s.record(bytes: 0, at: Self.t0)
        s.record(bytes: 100_000_000, at: Self.t0 + 0.25)
        Self.feed(&s, from: 0.5, to: 20) { 100_000_000 + 1_000_000 * ($0 - 0.25) }
        #expect(Self.near(s.speed(at: Self.t0 + 20), 1_000_000))
        // No samples after 20 s: half the window is still growth at 24 s, none at 28 s.
        #expect(Self.near(s.speed(at: Self.t0 + 24), 500_000))
        #expect(s.speed(at: Self.t0 + 28) == 0)
        #expect(s.speed(at: Self.t0 + 40) == 0)
    }

    @Test func bytesGoingBackwardsResets() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 6) { 2_000_000 * $0 }
        #expect(s.speed(at: Self.t0 + 6) != nil)
        let restarted = s.record(bytes: 1_000, at: Self.t0 + 6.25)
        #expect(restarted)
        #expect(s.sampleCount == 1)
        #expect(s.speed(at: Self.t0 + 6.25) == nil)
        #expect(!s.isStalled(at: Self.t0 + 6.25))
        // Growing again from the new start: no reset.
        let again = s.record(bytes: 2_000, at: Self.t0 + 6.5)
        #expect(!again)
        s.reset()
        #expect(s.sampleCount == 0 && s.speed(at: Self.t0 + 7) == nil && !s.isStalled(at: Self.t0 + 100))
    }

    @Test func unknownTotalGivesNoTimeLeft() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 10) { 4_200_000 * $0 }
        let now = Self.t0 + 10
        #expect(s.eta(bytes: 42_000_000, total: nil, at: now) == nil)
        #expect(s.eta(bytes: 42_000_000, total: 42_000_000, at: now) == nil)
        #expect(s.eta(bytes: 42_000_000, total: 84_000_000, at: now) != nil)
        #expect(s.speed(at: now) != nil)
    }

    @Test func timeLeftOverADayIsHidden() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 10) { 1_000 * $0 }
        let now = Self.t0 + 10
        #expect(s.eta(remaining: 1_000_000_000, at: now) == nil) // ~11.6 days
        let eta = s.eta(remaining: 86_000_000, at: now)          // ~23.9 h
        #expect(eta != nil && eta! <= DownloadSpeed.longestTimeLeft)
    }

    @Test func noZeroOrNegativeTimeLeftAtTheEnd() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 10) { 4_200_000 * $0 }
        let now = Self.t0 + 10
        #expect(s.eta(remaining: 0, at: now) == nil)
        #expect(s.eta(remaining: -5, at: now) == nil)
        let last = s.eta(remaining: 1, at: now)
        #expect(last != nil && last! > 0)
        #expect(DownloadSpeedFormat.timeLeftText(last!) == "a few seconds left")
    }

    @Test func samplesStayBounded() {
        var s = DownloadSpeed()
        for i in 0..<20_000 { s.record(bytes: Int64(i) * 1_000, at: Self.t0 + Double(i) * Self.poll) }
        // One window of polls, plus the baseline.
        #expect(s.sampleCount <= Int(DownloadSpeed.window / Self.poll) + 2)
        #expect(Self.near(s.speed(at: Self.t0 + 19_999 * Self.poll), 4_000))
    }

    /// 0.9.4 (review): a drop (a partial file deleted) restarts the
    /// average but is not growth: stalled before, stalled after.
    @Test func aDropKeepsTheStallClock() {
        var s = DownloadSpeed()
        Self.feed(&s, to: 6) { _ in 30_000_000 }
        #expect(s.isStalled(at: Self.t0 + 6))
        let restarted = s.record(bytes: 10_000_000, at: Self.t0 + 6.25)
        #expect(restarted && s.sampleCount == 1)
        #expect(s.isStalled(at: Self.t0 + 6.25) && s.speed(at: Self.t0 + 6.25) == nil)
        // New bytes end it.
        s.record(bytes: 10_100_000, at: Self.t0 + 6.5)
        #expect(!s.isStalled(at: Self.t0 + 6.5))
    }

    @Test func samePollTimeUpdatesInPlace() {
        var s = DownloadSpeed()
        s.record(bytes: 0, at: Self.t0)
        s.record(bytes: 10, at: Self.t0 + 1)
        s.record(bytes: 20, at: Self.t0 + 1)
        #expect(s.sampleCount == 2)
        // A time before the last sample starts over.
        let backInTime = s.record(bytes: 30, at: Self.t0 + 0.5)
        #expect(backInTime)
    }
}

struct V0100DownloadSpeedFormatTests {
    static let us = Locale(identifier: "en_US")

    static func shown(_ bps: Double, _ locale: Locale = us) -> String {
        let p = DownloadSpeedFormat.pieces(bytesPerSecond: bps, locale: locale)
        return p.number + " " + p.unit.rawValue
    }

    @Test func speedUnitsAtTheBoundaries() {
        #expect(Self.shown(0) == "0 KB/s")
        #expect(Self.shown(999) == "0 KB/s")
        #expect(Self.shown(1_000) == "1 KB/s")
        #expect(Self.shown(820_000) == "820 KB/s")
        #expect(Self.shown(999_499) == "999 KB/s")
        #expect(Self.shown(999_500) == "1.0 MB/s")
        #expect(Self.shown(999_999) == "1.0 MB/s")
        #expect(Self.shown(1_000_000) == "1.0 MB/s")
        #expect(Self.shown(4_200_000) == "4.2 MB/s")
        #expect(Self.shown(999_949_999) == "999.9 MB/s")
        #expect(Self.shown(999_950_000) == "1.0 GB/s")
        #expect(Self.shown(1.2e9) == "1.2 GB/s")
        #expect(Self.shown(-5) == "0 KB/s")
        #expect(Self.shown(.nan) == "0 KB/s")
    }

    @Test func speedSentence() {
        #expect(DownloadSpeedFormat.speed(4_200_000, locale: Self.us) == "4.2 MB/s")
        #expect(DownloadSpeedFormat.speed(820_000, locale: Self.us) == "820 KB/s")
        #expect(DownloadSpeedFormat.speed(1.2e9, locale: Self.us) == "1.2 GB/s")
    }

    /// The decimal separator is the locale's, as in DownloadSizeFormat.
    @Test func speedUsesTheLocale() {
        let de = Locale(identifier: "de_DE")
        #expect(DownloadSpeedFormat.pieces(bytesPerSecond: 4_200_000, locale: de).number == "4,2")
        #expect(DownloadSizeFormat.pieces(4_200_000, scale: 4_200_000, locale: de).number == "4,2")
        #expect(DownloadSpeedFormat.pieces(bytesPerSecond: 4_200_000, locale: Self.us).number == "4.2")
    }

    @Test func timeLeftWords() {
        let words: [(TimeInterval, String)] = [
            (0.4, "a few seconds left"),
            (3, "a few seconds left"),
            (7.9, "a few seconds left"),
            (8, "about 10 sec left"),
            (20, "about 20 sec left"),
            (59, "about 1 min left"),
            (61, "about 1 min left"),
            (89, "about 1 min left"),
            (90, "about 2 min left"),
            (720, "about 12 min left"),
            (3599, "about 1 hr left"),
            (3900, "about 1 hr 5 min left"),
        ]
        for (seconds, text) in words {
            #expect(DownloadSpeedFormat.timeLeftText(seconds) == text, "\(seconds) s")
        }
        #expect(DownloadSpeedFormat.timeLeft(22) == .seconds(20))
        #expect(DownloadSpeedFormat.timeLeft(23) == .seconds(25))
    }
}

// MARK: round 1 review (Sol): what the watcher credits a file that is gone

/// A file that leaves the downloads folder counts with its real size when
/// brew renamed it (done), and not at all when it was deleted (a failure);
/// a retry counts once. Before, a gone file counted with its expected
/// total, so a deleted partial file read as new bytes.
struct V0100DownloadWatcherTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    static let a = "\(hashA)--aaa--1.0.sonoma.bottle.tar.gz"
    static let b = "\(hashB)--bbb--2.0.sonoma.bottle.tar.gz"

    /// A folder with the manifests for a (100 bytes) and b (300 bytes).
    func folder() -> FakeDownloadFolder {
        let dir = FakeDownloadFolder()
        dir.set("\(hashA)--aaa-1.0.bottle_manifest.json", size: 1, modified: start, data: manifestJSON([("1.0.sonoma", 100)]))
        dir.set("\(hashB)--bbb-2.0.bottle_manifest.json", size: 1, modified: start, data: manifestJSON([("2.0.sonoma", 300)]))
        return dir
    }

    /// Renamed: the finished file's real size, not the expected total.
    @Test func renamedFileCountsItsRealSize() async throws {
        let dir = folder()
        dir.set(Self.a + ".incomplete", size: 50, modified: start)
        dir.set(Self.b + ".incomplete", size: 10, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll() == DownloadProgress(name: nil, bytes: 60, total: 400, files: 2))
        dir.remove(Self.a + ".incomplete")
        dir.set(Self.a, size: 98, modified: start) // what curl wrote, a little under the manifest's size
        let p = try #require(await w.poll())
        #expect(p == DownloadProgress(name: "bbb", bytes: 108, total: 398, files: 1))
    }

    /// Deleted after a failure: its bytes no longer count, nor its total.
    @Test func deletedPartialFileCountsNothing() async throws {
        let dir = folder()
        dir.set(Self.a + ".incomplete", size: 20, modified: start)
        dir.set(Self.b + ".incomplete", size: 10, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll()?.bytes == 30)
        dir.remove(Self.a + ".incomplete")
        let p = try #require(await w.poll())
        #expect(p == DownloadProgress(name: "bbb", bytes: 10, total: 300, files: 1))
        #expect(await w.sawDownload)
        // Gone for good: still not counted later.
        dir.set(Self.b + ".incomplete", size: 20, modified: start)
        #expect(await w.poll() == DownloadProgress(name: "bbb", bytes: 20, total: 300, files: 1))
    }

    /// Deleted, then downloaded again: counted once, as running.
    @Test func retryAfterADeletionCountsOnce() async throws {
        let dir = folder()
        dir.set(Self.a + ".incomplete", size: 20, modified: start)
        dir.set(Self.b + ".incomplete", size: 10, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        _ = await w.poll()
        dir.remove(Self.a + ".incomplete")
        _ = await w.poll()
        dir.set(Self.a + ".incomplete", size: 5, modified: start)
        #expect(await w.poll() == DownloadProgress(name: nil, bytes: 15, total: 400, files: 2))
    }

    /// Finished, then downloaded again (brew fetched it once more): the
    /// running file counts, the finished one no longer.
    @Test func retryAfterARenameCountsOnce() async throws {
        let dir = folder()
        dir.set(Self.a + ".incomplete", size: 90, modified: start)
        dir.set(Self.b + ".incomplete", size: 10, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        _ = await w.poll()
        dir.remove(Self.a + ".incomplete")
        dir.set(Self.a, size: 98, modified: start)
        #expect(await w.poll()?.bytes == 108)
        dir.remove(Self.a)
        dir.set(Self.a + ".incomplete", size: 5, modified: start)
        #expect(await w.poll() == DownloadProgress(name: nil, bytes: 15, total: 400, files: 2))
    }

    /// One file done, nothing running for a poll, then the next one: the
    /// first still counts (its real size), so the bar doesn't jump back.
    @Test func emptyPollBetweenTwoFiles() async throws {
        let dir = folder()
        dir.set(Self.a + ".incomplete", size: 60, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll() == DownloadProgress(name: "aaa", bytes: 60, total: 100, files: 1))
        dir.remove(Self.a + ".incomplete")
        dir.set(Self.a, size: 98, modified: start)
        #expect(await w.poll() == nil)
        dir.set(Self.b + ".incomplete", size: 10, modified: start)
        #expect(await w.poll() == DownloadProgress(name: "bbb", bytes: 108, total: 398, files: 1))
    }
}

// MARK: round 1 review (Sol): a burst every 4 s is not a steady speed

struct V0100DownloadSpeedStabilityTests {
    typealias T = V0100DownloadSpeedTests

    /// 4 MB at t=4 and at t=8, nothing in between, polls every 250 ms: the
    /// 8 s average (1 MB/s) is shown, a time left never is. Before, the
    /// newest half (4..8 s) and the whole window (0..8 s) both read 1 MB/s,
    /// so it passed as steady.
    @Test func burstEveryFourSecondsGivesASpeedButNoTimeLeft() {
        var s = DownloadSpeed()
        let bytes: (TimeInterval) -> Double = { t in 4_000_000 * ((t >= 4 ? 1 : 0) + (t >= 8 ? 1 : 0)) }
        T.feed(&s, to: 8, bytes)
        #expect(T.near(s.speed(at: T.t0 + 8), 1_000_000))
        #expect(!s.isStable(at: T.t0 + 8))
        #expect(s.eta(remaining: 100_000_000, at: T.t0 + 8) == nil)
        // At no poll from 4 s to 11.75 s (the next burst would be at 12 s).
        for t in stride(from: 4.0, through: 11.75, by: T.poll) {
            #expect(T.etaAfter(bytes, t) == nil, "t=\(t)")
        }
    }

    /// A steady 1 MB/s still gets a time left once 4 s of samples exist.
    @Test func steadyOneMegabyteGetsATimeLeftAfterFourSeconds() {
        let bytes: (TimeInterval) -> Double = { 1_000_000 * $0 }
        #expect(T.etaAfter(bytes, 3.75) == nil)
        let eta = T.etaAfter(bytes, 4)
        #expect(eta != nil && abs(eta! - 500) < 1)
        #expect(T.etaAfter(bytes, 10) != nil)
    }
}

// MARK: round 1 review (Sol): numeric inputs that used to trap

struct V0100DownloadSpeedNumericTests {
    @Test func etaWithANegativeCountAndTheLargestTotal() {
        let s = DownloadSpeed()
        #expect(s.eta(bytes: -1, total: .max, at: 10) == nil)
        #expect(s.eta(bytes: .min, total: .max, at: 10) == nil)
    }

    /// Int64.min is rejected (a negative count is ignored), so Int64.max
    /// two seconds later is the first sample: no speed, no trap.
    @Test func smallestThenLargestCount() {
        var s = DownloadSpeed()
        s.record(bytes: .min, at: 0)
        s.record(bytes: .max, at: 2)
        #expect(s.sampleCount == 1)
        #expect(s.speed(at: 2) == nil)
        #expect(s.eta(bytes: 0, total: .max, at: 2) == nil)
        // Huge but valid counts: Double arithmetic, no trap.
        s.record(bytes: 0, at: 10) // backwards: starts over
        s.record(bytes: .max, at: 12)
        #expect((s.speed(at: 12) ?? 0) > 0)
        _ = s.isStable(at: 12)
        _ = s.eta(bytes: 0, total: .max, at: 12)
    }

    /// A time that isn't finite is ignored by record and gives nothing
    /// (no speed, no time left, not stalled) when asked.
    @Test func nonFiniteTimesAreIgnored() {
        var s = DownloadSpeed()
        for t in stride(from: 0.0, through: 6, by: 0.25) { s.record(bytes: Int64(t * 1_000_000), at: t) }
        let before = s
        for bad in [Double.nan, .infinity, -.infinity] {
            let restarted = s.record(bytes: 1, at: bad)
            #expect(!restarted)
            #expect(s == before)
            #expect(s.speed(at: bad) == nil)
            #expect(!s.isStable(at: bad))
            #expect(!s.isStalled(at: bad))
            #expect(s.eta(remaining: 1_000_000, at: bad) == nil)
            #expect(s.eta(bytes: 0, total: 1_000_000, at: bad) == nil)
        }
        let negative = s.record(bytes: -1, at: 7)
        #expect(!negative)
        #expect(s == before)
        #expect(s.speed(at: 6) != nil)
    }

    /// Bounded before it becomes an Int: the largest durations read as
    /// the formatter's longest (whole hours), not a trap.
    @Test func timeLeftOfTheLargestFiniteDuration() throws {
        #expect(DownloadSpeedFormat.timeLeft(.greatestFiniteMagnitude) == .hours(999, minutes: 0))
        #expect(DownloadSpeedFormat.timeLeft(.infinity) == .hours(999, minutes: 0))
        #expect(DownloadSpeedFormat.timeLeft(1e300) == .hours(999, minutes: 0))
        #expect(DownloadSpeedFormat.timeLeft(.nan) == .fewSeconds)
        #expect(DownloadSpeedFormat.timeLeft(-.infinity) == .fewSeconds)
        #expect(DownloadSpeedFormat.timeLeft(-5) == .fewSeconds)
        #expect(DownloadSpeedFormat.timeLeft(0) == .fewSeconds)
        #expect(DownloadSpeedFormat.timeLeftText(.greatestFiniteMagnitude) == "about 999 hr left")
        #expect(DownloadSpeedFormat.timeLeftText(.nan) == "a few seconds left")
    }
}

// MARK: round 1 review (Sol): a query time before the newest sample

/// The sheet's time can be a moment before the newest poll (a poll lands
/// between the redraw's scheduling and its rendering). Such a time counts
/// as the newest sample's: the speed and time left go with the byte count
/// on screen, never an older reading.
struct V0100DownloadSpeedQueryTimeTests {
    typealias T = V0100DownloadSpeedTests

    @Test func queryBeforeTheNewestSampleIsClampedToIt() {
        var s = DownloadSpeed()
        T.feed(&s, to: 6) { 4_200_000 * $0 }
        let newest = T.t0 + 6
        for early in [T.t0 + 5.9, T.t0 + 3, T.t0 - 100] {
            #expect(s.speed(at: early) == s.speed(at: newest), "\(early - T.t0)")
            #expect(s.isStable(at: early) == s.isStable(at: newest))
            #expect(s.isStalled(at: early) == s.isStalled(at: newest))
            #expect(s.eta(remaining: 100_000_000, at: early) == s.eta(remaining: 100_000_000, at: newest))
        }
        #expect(s.eta(remaining: 100_000_000, at: T.t0 + 3) != nil)
    }
}

// MARK: round 2 review (Sol): a final file is not proof of a rename

/// A gone partial file counts as finished only when the file under its
/// final name is that partial file, renamed. Before, any file under the
/// final name counted: an old finished download of the same file read as
/// a jump of its whole size, and cleared a stall.
struct V0100DownloadWatcherIdentityTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    typealias W = V0100DownloadWatcherTests

    /// Sol's case: an old 100 MB final A beside a 20 MB partial A and a
    /// stalled 10 MB partial B. Deleting only partial A leaves B's 10 MB,
    /// not 110 MB.
    @Test func oldFinalFileOfTheSameNameIsNotCounted() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a, size: 100_000_000, modified: start.addingTimeInterval(-3600))
        dir.set(W.a + ".incomplete", size: 20_000_000, modified: start)
        dir.set(W.b + ".incomplete", size: 10_000_000, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll()?.bytes == 30_000_000)
        #expect(await w.poll()?.bytes == 30_000_000)
        dir.remove(W.a + ".incomplete")
        let p = try #require(await w.poll())
        #expect(p.bytes == 10_000_000, "\(p)")
        #expect(p.files == 1)
        // Not later either.
        #expect(await w.poll()?.bytes == 10_000_000)
    }

    /// A real rename: the partial file goes and the final one appears in
    /// the same poll, at least as large. Its real size counts.
    @Test func renameInOnePollCountsTheRealSize() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a + ".incomplete", size: 20_000_000, modified: start)
        dir.set(W.b + ".incomplete", size: 10_000_000, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll()?.bytes == 30_000_000)
        dir.rename(W.a + ".incomplete", W.a)
        dir.set(W.a, size: 25_000_000, modified: start)
        let p = try #require(await w.poll())
        #expect(p.bytes == 35_000_000 && p.files == 1, "\(p)")
    }

    /// The partial file renamed over an old final file of the same name:
    /// the name was there before, but the file under it is the renamed
    /// partial one (the same file number), so it counts.
    @Test func renameOverAnOldFinalFileCounts() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a, size: 100_000_000, modified: start.addingTimeInterval(-3600))
        dir.set(W.a + ".incomplete", size: 20_000_000, modified: start)
        dir.set(W.b + ".incomplete", size: 10_000_000, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll()?.bytes == 30_000_000)
        dir.rename(W.a + ".incomplete", W.a)
        dir.set(W.a, size: 25_000_000, modified: start)
        let p = try #require(await w.poll())
        #expect(p.bytes == 35_000_000 && p.files == 1, "\(p)")
    }
}

/// The bytes written (`traffic`, what the speed is measured on) are each
/// file's growth: a deleted file takes its bytes off the bar's count, not
/// off this one, and an old file is never new bytes.
struct V0100DownloadWatcherTrafficTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    typealias W = V0100DownloadWatcherTests

    /// B grows 2 MB on the poll that deletes partial A: the bar's bytes
    /// fall (30 to 12 MB), the bytes written grow by B's 2 MB only.
    @Test func growthOnThePollThatDeletesAFile() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a + ".incomplete", size: 20_000_000, modified: start)
        dir.set(W.b + ".incomplete", size: 10_000_000, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        let first = await w.sample()
        #expect(first.progress?.bytes == 30_000_000)
        #expect(first.traffic == 30_000_000) // the baseline: all of it first seen
        dir.remove(W.a + ".incomplete")
        dir.set(W.b + ".incomplete", size: 12_000_000, modified: start)
        let next = await w.sample()
        #expect(next.progress?.bytes == 12_000_000 && next.progress?.files == 1)
        #expect(next.traffic - first.traffic == 2_000_000)
    }

    /// Sol's case: the old final file adds nothing to the bytes written.
    @Test func oldFinalFileIsNoTraffic() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a, size: 100_000_000, modified: start.addingTimeInterval(-3600))
        dir.set(W.a + ".incomplete", size: 20_000_000, modified: start)
        dir.set(W.b + ".incomplete", size: 10_000_000, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        let first = await w.sample()
        dir.remove(W.a + ".incomplete")
        let next = await w.sample()
        #expect(next.progress?.bytes == 10_000_000)
        #expect(next.traffic == first.traffic)
    }

    /// A rename: what curl wrote before it (25 - 20 MB) is traffic; the
    /// bytes written never fall, also when nothing runs.
    @Test func renameAddsTheRestAndTrafficNeverFalls() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a + ".incomplete", size: 20_000_000, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        let first = await w.sample()
        dir.rename(W.a + ".incomplete", W.a)
        dir.set(W.a, size: 25_000_000, modified: start)
        let done = await w.sample()
        #expect(done.progress == nil)
        #expect(done.traffic - first.traffic == 5_000_000)
        dir.remove(W.a)
        #expect(await w.sample().traffic == done.traffic)
    }

    /// On disk, a rename keeps the file number LiveDownloadFolder reads
    /// (a temporary folder with made-up bytes; not brew's).
    @Test func liveFolderFileNumberSurvivesARename() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tankard-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("x.incomplete").path
        let final = dir.appendingPathComponent("x").path
        try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: partial))
        let live = LiveDownloadFolder()
        let before = try #require(live.stat(partial)?.fileID)
        try fm.moveItem(atPath: partial, toPath: final)
        #expect(live.stat(final)?.fileID == before)
        try Data(repeating: 2, count: 10).write(to: URL(fileURLWithPath: partial))
        #expect(live.stat(partial)?.fileID != before)
    }
}

// MARK: round 2 review (Sol): sums that used to trap

/// The watcher's sums are checked: a total that can't be represented is
/// unknown (nil), and bytes stop at Int64.max. Before, the finished
/// file's real size was added unchecked and trapped.
struct V0100DownloadWatcherOverflowTests {
    let start = Date(timeIntervalSince1970: 1_000_000)
    typealias W = V0100DownloadWatcherTests

    /// Sol's case: A's total 100, B's Int64.max - 100 (the first poll's
    /// total is Int64.max), then A is renamed at 101 bytes.
    @Test func finishedFileOverTheLargestTotal() async throws {
        let dir = FakeDownloadFolder()
        dir.set("\(hashA)--aaa-1.0.bottle_manifest.json", size: 1, modified: start, data: manifestJSON([("1.0.sonoma", 100)]))
        dir.set("\(hashB)--bbb-2.0.bottle_manifest.json", size: 1, modified: start,
                data: manifestJSON([("2.0.sonoma", Int64.max - 100)]))
        dir.set(W.a + ".incomplete", size: 50, modified: start)
        dir.set(W.b + ".incomplete", size: 10, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        #expect(await w.poll() == DownloadProgress(name: nil, bytes: 60, total: .max, files: 2))
        dir.rename(W.a + ".incomplete", W.a)
        dir.set(W.a, size: 101, modified: start)
        let p = try #require(await w.poll())
        #expect(p.bytes == 111)
        #expect(p.total == nil)
        #expect(p.files == 1)
    }

    /// Two files whose sizes add up past Int64.max: the bytes stop there,
    /// the total is unknown.
    @Test func bytesOverTheLargestCount() async throws {
        let dir = FakeDownloadFolder()
        dir.set(W.a + ".incomplete", size: .max / 2 + 1, modified: start)
        dir.set(W.b + ".incomplete", size: .max / 2 + 1, modified: start)
        let w = DownloadWatcher(directory: "/d", reader: dir, since: start)
        let p = try #require(await w.poll())
        #expect(p.bytes == .max)
        #expect(p.total == nil)
        #expect(p.files == 2)
    }
}

// MARK: round 2 review (Sol): a slow link that buffers is steady

struct V0100DownloadSpeedBufferedTests {
    typealias T = V0100DownloadSpeedTests

    /// 8 KiB every 2 s (4 KiB/s), polled every 250 ms: from 4 s of samples
    /// on, a speed and a time left at every poll. Before, the 1 s buckets
    /// alternated between growth and none, so the time left stayed hidden.
    @Test func eightKilobytesEveryTwoSecondsGetsATimeLeft() throws {
        let bytes: (TimeInterval) -> Double = { 8192 * ($0 / 2).rounded(.down) }
        for t in stride(from: 4.0, through: 20, by: T.poll) {
            var s = DownloadSpeed()
            T.feed(&s, to: t, bytes)
            let speed = try #require(s.speed(at: T.t0 + t), "t=\(t)")
            #expect(speed > 2000 && speed < 6000, "t=\(t): \(speed)")
            #expect(s.eta(remaining: 1_000_000, at: T.t0 + t) != nil, "t=\(t)")
        }
        var s = DownloadSpeed()
        T.feed(&s, to: 8, bytes)
        #expect(T.near(s.speed(at: T.t0 + 8), 4096))
        let eta = try #require(s.eta(remaining: 1_000_000, at: T.t0 + 8))
        #expect(abs(eta - 1_000_000 / 4096) < 1)
    }
}
