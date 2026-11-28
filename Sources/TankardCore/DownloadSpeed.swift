import Foundation

// 0.10: download speed and time left for the install/upgrade sheet (Derek:
// on a slow connection "2.1 of 2.3 GB (91%)" barely moves, and nothing
// says whether it is still working).
//
// The sheet polls brew's downloads folder about every 250 ms
// (DownloadWatcher) and feeds each byte count here. Everything takes the
// time as an argument: no clock is read inside, so tests drive it with
// made-up times.

/// A rolling average of a download's speed, over the last `window` seconds.
public struct DownloadSpeed: Sendable, Equatable {
    /// How far back the average looks.
    public static let window: TimeInterval = 8
    /// No speed until the samples cover this long (one poll's jump would
    /// read as a wild speed).
    public static let minimumSpan: TimeInterval = 2
    /// No time left until the samples cover this long.
    public static let stableSpan: TimeInterval = 4
    /// The speed is "stable" when the speed over the newest half of the
    /// window is within this fraction of the speed over the whole window
    /// (0.4: within +/-40%), and so is each of the newest buckets' speed of
    /// their mean.
    public static let stableTolerance = 0.4
    /// The newest `stableSpan` is cut into this many buckets of
    /// `stableSpan / bucketCount` (1 s) for the stability check.
    public static let bucketCount = 4
    /// No new bytes for this long: stalled.
    public static let stallAfter: TimeInterval = 5
    /// A time left longer than this isn't shown (it says nothing useful).
    public static let longestTimeLeft: TimeInterval = 24 * 60 * 60

    struct Sample: Sendable, Equatable {
        var time: TimeInterval
        var bytes: Int64
    }

    /// Oldest first. Holds the samples inside the window ending at the
    /// newest one, plus one at or before the window's start (the baseline).
    private(set) var samples: [Sample] = []
    /// When tracking (re)started: the first sample's time.
    private var startedAt: TimeInterval?
    /// When the byte count last grew (the first sample's time if it never did).
    private var lastGrowth: TimeInterval?

    public init() {}

    /// How many samples are kept (tests: memory stays bounded).
    public var sampleCount: Int { samples.count }

    public mutating func reset() {
        samples = []
        startedAt = nil
        lastGrowth = nil
    }

    /// Adds one poll's byte count. A count that goes backwards (a new
    /// download started, a file was removed after a failure) or a time
    /// before the last sample starts over from this sample; then it
    /// returns true. A drop is not growth: the stall clock keeps running
    /// across it (a partial file deleted while the rest is stalled still
    /// reads as stalled). A negative count or a time that isn't finite is
    /// ignored (returns false, nothing changes).
    @discardableResult
    public mutating func record(bytes: Int64, at time: TimeInterval) -> Bool {
        guard bytes >= 0, time.isFinite else { return false }
        var restarted = false
        if let last = samples.last {
            if bytes < last.bytes || time < last.time {
                let grew = time < last.time ? nil : lastGrowth
                reset()
                lastGrowth = grew
                restarted = true
            } else if time == last.time {
                if bytes > last.bytes { lastGrowth = time }
                samples[samples.count - 1].bytes = bytes
                return false
            } else if bytes > last.bytes {
                lastGrowth = time
            }
        }
        if samples.isEmpty {
            startedAt = time
            if lastGrowth == nil { lastGrowth = time }
        }
        samples.append(Sample(time: time, bytes: bytes))
        // Keep one sample at or before the window's start, drop the older ones.
        let windowStart = time - Self.window
        while samples.count >= 2, samples[1].time <= windowStart { samples.removeFirst() }
        return restarted
    }

    @discardableResult
    public mutating func record(bytes: Int64, at date: Date) -> Bool {
        record(bytes: bytes, at: date.timeIntervalSinceReferenceDate)
    }

    /// Bytes per second over the window ending at `time`, or nil before
    /// `minimumSpan` of samples exist. Falls toward 0 when bytes stop
    /// arriving (the window slides past the last growth); never negative.
    public func speed(at time: TimeInterval) -> Double? {
        guard let time = queryTime(time), let span = span(at: time), span >= Self.minimumSpan else { return nil }
        return rate(over: Self.window, endingAt: time)
    }

    public func speed(at date: Date) -> Double? { speed(at: date.timeIntervalSinceReferenceDate) }

    /// No growth in the byte count for `stallAfter` seconds or more.
    public func isStalled(at time: TimeInterval) -> Bool {
        guard let time = queryTime(time), let lastGrowth else { return false }
        return time - lastGrowth >= Self.stallAfter
    }

    public func isStalled(at date: Date) -> Bool { isStalled(at: date.timeIntervalSinceReferenceDate) }

    /// Whether the speed is steady enough for a time left:
    ///  1. at least `stableSpan` of samples;
    ///  2. the speed over the newest half of the window within
    ///     `stableTolerance` (+/-40%) of the speed over the whole window
    ///     (until the samples fill the window, "the window" is the part they
    ///     cover). A ramp-up or a slow-down fails this until the window has
    ///     caught up with it;
    ///  3. the newest `stableSpan` (4 s), cut into `bucketCount` buckets of
    ///     1 s: every bucket grew, and each bucket's speed is within
    ///     +/-40% of their mean. Why: the 8 s and 4 s averages of a link
    ///     that sends a burst every 4 s and nothing in between are equal
    ///     (Sol's review: 4 MB at 4 s and at 8 s), so 2. alone took it for
    ///     steady and showed a time left that the next idle seconds belie.
    public func isStable(at time: TimeInterval) -> Bool {
        guard let time = queryTime(time), let span = span(at: time), span >= Self.stableSpan,
              let first = samples.first,
              let whole = rate(over: Self.window, endingAt: time), whole > 0 else { return false }
        let covered = time - max(time - Self.window, first.time)
        guard let newest = rate(over: covered / 2, endingAt: time),
              abs(newest - whole) <= Self.stableTolerance * whole else { return false }
        let bucket = Self.stableSpan / Double(Self.bucketCount)
        var rates: [Double] = []
        for i in 0..<Self.bucketCount {
            let end = time - Double(Self.bucketCount - 1 - i) * bucket
            guard let r = rate(over: bucket, endingAt: end), r > 0 else { return false }
            rates.append(r)
        }
        let mean = rates.reduce(0, +) / Double(rates.count)
        return rates.allSatisfy { abs($0 - mean) <= Self.stableTolerance * mean }
    }

    public func isStable(at date: Date) -> Bool { isStable(at: date.timeIntervalSinceReferenceDate) }

    /// Seconds until `remaining` more bytes arrive at the current speed;
    /// nil when there is nothing left, when stalled, when the speed isn't
    /// stable, or beyond `longestTimeLeft`. Never 0 or negative.
    public func eta(remaining: Int64, at time: TimeInterval) -> TimeInterval? {
        guard remaining > 0, time.isFinite, !isStalled(at: time), isStable(at: time),
              let speed = speed(at: time), speed > 0, speed.isFinite else { return nil }
        let eta = Double(remaining) / speed
        guard eta.isFinite, eta > 0, eta <= Self.longestTimeLeft else { return nil }
        return eta
    }

    public func eta(remaining: Int64, at date: Date) -> TimeInterval? {
        eta(remaining: remaining, at: date.timeIntervalSinceReferenceDate)
    }

    /// The time left for a download at `bytes` of `total`; nil when the
    /// total is unknown (or reached), when either count is negative, and
    /// as `eta(remaining:at:)`.
    public func eta(bytes: Int64, total: Int64?, at time: TimeInterval) -> TimeInterval? {
        guard let total, bytes >= 0, total >= 0, bytes < total else { return nil }
        let (remaining, overflow) = total.subtractingReportingOverflow(bytes)
        guard !overflow else { return nil }
        return eta(remaining: remaining, at: time)
    }

    public func eta(bytes: Int64, total: Int64?, at date: Date) -> TimeInterval? {
        eta(bytes: bytes, total: total, at: date.timeIntervalSinceReferenceDate)
    }

    // MARK: inside

    /// The time a question is answered at: nil when it isn't finite; a
    /// time before the newest sample counts as that sample's time (the
    /// sheet's redraw date can be a moment older than the newest poll,
    /// whose byte count is on screen: the rate goes with it).
    private func queryTime(_ time: TimeInterval) -> TimeInterval? {
        guard time.isFinite else { return nil }
        guard let last = samples.last else { return time }
        return max(time, last.time)
    }

    /// How long the samples cover, up to `time`.
    private func span(at time: TimeInterval) -> TimeInterval? {
        guard let startedAt, let last = samples.last else { return nil }
        return min(time, last.time) - startedAt
    }

    /// The byte count at `time`: linear between samples, the last count
    /// after the last sample (nothing arrived since), nil before the first.
    private func bytes(at time: TimeInterval) -> Double? {
        guard let first = samples.first, time >= first.time else { return nil }
        var previous = first
        for s in samples.dropFirst() {
            if s.time >= time {
                let f = s.time > previous.time ? (time - previous.time) / (s.time - previous.time) : 1
                // In Double: no Int64 difference to overflow.
                return Double(previous.bytes) + f * (Double(s.bytes) - Double(previous.bytes))
            }
            previous = s
        }
        return Double(previous.bytes)
    }

    /// Bytes per second over `length` seconds ending at `time`, or over the
    /// part of it the samples cover.
    private func rate(over length: TimeInterval, endingAt time: TimeInterval) -> Double? {
        guard let first = samples.first, time > first.time else { return nil }
        let start = max(time - length, first.time)
        let elapsed = time - start
        guard elapsed > 0, let end = bytes(at: time), let begin = bytes(at: start) else { return nil }
        return max(0, (end - begin) / elapsed)
    }
}

/// Formats a download speed ("820 KB/s", "4.2 MB/s") and the time left
/// ("about 1 min left"): decimal units, like DownloadSizeFormat. The unit
/// words are localized.
public enum DownloadSpeedFormat {
    /// Under this many seconds left: "a few seconds left".
    public static let fewSeconds: TimeInterval = 8

    /// The unit of a speed.
    public enum Unit: String, Sendable {
        case kilobytes = "KB/s", megabytes = "MB/s", gigabytes = "GB/s"
    }

    /// The number and unit for a speed: no decimals for KB/s, one for MB/s
    /// and GB/s; below 1 KB/s, "0" KB/s. A value that would round up to
    /// 1000 of a unit is shown in the next one ("1.0 MB/s", not "1000 KB/s").
    public static func pieces(bytesPerSecond: Double, locale: Locale = .current) -> (number: String, unit: Unit) {
        let bps = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.roundingMode = .halfUp
        let kb = bps < 1000 ? 0 : (bps / 1e3).rounded(.toNearestOrAwayFromZero)
        if kb < 1000 {
            f.maximumFractionDigits = 0
            return (f.string(from: NSNumber(value: kb)) ?? "\(Int(kb))", .kilobytes)
        }
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        let mb = (bps / 1e5).rounded(.toNearestOrAwayFromZero) / 10
        if mb < 1000 {
            return (f.string(from: NSNumber(value: mb)) ?? "\(mb)", .megabytes)
        }
        let gb = (bps / 1e8).rounded(.toNearestOrAwayFromZero) / 10
        return (f.string(from: NSNumber(value: gb)) ?? "\(gb)", .gigabytes)
    }

    /// "4.2 MB/s"
    public static func speed(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let p = pieces(bytesPerSecond: bytesPerSecond, locale: locale)
        let unit = unitName(p.unit)
        return String(localized: "\(p.number) \(unit)")
    }

    public static func unitName(_ u: Unit) -> String {
        switch u {
        case .kilobytes: return String(localized: "KB/s")
        case .megabytes: return String(localized: "MB/s")
        case .gigabytes: return String(localized: "GB/s")
        }
    }

    /// What the time left reads as, before it becomes words.
    public enum TimeLeft: Equatable, Sendable {
        case fewSeconds
        case seconds(Int)
        case minutes(Int)
        case hours(Int, minutes: Int)
    }

    /// The longest time left this formats; anything longer (infinity
    /// included) reads as this, so the conversion to Int can't trap. The
    /// tracker hides a time left over 24 hours before it gets here.
    public static let longestTimeLeft: TimeInterval = 999 * 60 * 60

    /// Under `fewSeconds` (or NaN): a few seconds. Under a minute: 5-second
    /// steps. Above: whole minutes (1 hr 5 min past an hour), at most
    /// `longestTimeLeft`.
    public static func timeLeft(_ seconds: TimeInterval) -> TimeLeft {
        guard !seconds.isNaN, seconds >= fewSeconds else { return .fewSeconds }
        let seconds = min(seconds, longestTimeLeft)
        let steps = Int((seconds / 5).rounded(.toNearestOrAwayFromZero)) * 5
        if steps < 60 { return .seconds(steps) }
        let minutes = max(1, Int((seconds / 60).rounded(.toNearestOrAwayFromZero)))
        if minutes < 60 { return .minutes(minutes) }
        return .hours(minutes / 60, minutes: minutes % 60)
    }

    /// "about 20 sec left", "about 1 hr 5 min left", "a few seconds left".
    /// 0.10 (review): plural variations (L10n.bundle's stringsdict), so a
    /// language that agrees with the number says 1 in the singular
    /// (Spanish "queda alrededor de 1 min", "quedan unos 12 min").
    public static func timeLeftText(_ seconds: TimeInterval) -> String {
        switch timeLeft(seconds) {
        case .fewSeconds: return String(localized: "a few seconds left")
        case .seconds(let s): return String(localized: "about \(s) sec left", bundle: L10n.bundle)
        case .minutes(let m): return String(localized: "about \(m) min left", bundle: L10n.bundle)
        case .hours(let h, 0): return String(localized: "about \(h) hr left", bundle: L10n.bundle)
        case .hours(let h, let m): return String(localized: "about \(h) hr \(m) min left", bundle: L10n.bundle)
        }
    }
}
