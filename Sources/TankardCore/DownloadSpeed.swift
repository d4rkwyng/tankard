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
    /// (0.4: within +/-40%).
    public static let stableTolerance = 0.4
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
    /// returns true.
    @discardableResult
    public mutating func record(bytes: Int64, at time: TimeInterval) -> Bool {
        var restarted = false
        if let last = samples.last {
            if bytes < last.bytes || time < last.time {
                reset()
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
            lastGrowth = time
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
        guard let span = span(at: time), span >= Self.minimumSpan else { return nil }
        return rate(over: Self.window, endingAt: time)
    }

    public func speed(at date: Date) -> Double? { speed(at: date.timeIntervalSinceReferenceDate) }

    /// No growth in the byte count for `stallAfter` seconds or more.
    public func isStalled(at time: TimeInterval) -> Bool {
        guard let lastGrowth else { return false }
        return time - lastGrowth >= Self.stallAfter
    }

    public func isStalled(at date: Date) -> Bool { isStalled(at: date.timeIntervalSinceReferenceDate) }

    /// Whether the speed is steady enough for a time left: at least
    /// `stableSpan` of samples, and the speed over the newest half of the
    /// window within `stableTolerance` (+/-40%) of the speed over the whole
    /// window. Until the samples fill the window, "the window" is the part
    /// they cover (so its newest half is never the whole of it). A ramp-up,
    /// a slow-down or a bursty link fails the second test until the window
    /// has caught up with it.
    public func isStable(at time: TimeInterval) -> Bool {
        guard let span = span(at: time), span >= Self.stableSpan, let first = samples.first,
              let whole = rate(over: Self.window, endingAt: time), whole > 0 else { return false }
        let covered = time - max(time - Self.window, first.time)
        guard let newest = rate(over: covered / 2, endingAt: time) else { return false }
        return abs(newest - whole) <= Self.stableTolerance * whole
    }

    public func isStable(at date: Date) -> Bool { isStable(at: date.timeIntervalSinceReferenceDate) }

    /// Seconds until `remaining` more bytes arrive at the current speed;
    /// nil when there is nothing left, when stalled, when the speed isn't
    /// stable, or beyond `longestTimeLeft`. Never 0 or negative.
    public func eta(remaining: Int64, at time: TimeInterval) -> TimeInterval? {
        guard remaining > 0, !isStalled(at: time), isStable(at: time),
              let speed = speed(at: time), speed > 0 else { return nil }
        let eta = Double(remaining) / speed
        guard eta > 0, eta <= Self.longestTimeLeft else { return nil }
        return eta
    }

    public func eta(remaining: Int64, at date: Date) -> TimeInterval? {
        eta(remaining: remaining, at: date.timeIntervalSinceReferenceDate)
    }

    /// The time left for a download at `bytes` of `total`; nil when the
    /// total is unknown (or reached), and as `eta(remaining:at:)`.
    public func eta(bytes: Int64, total: Int64?, at time: TimeInterval) -> TimeInterval? {
        guard let total, bytes < total else { return nil }
        return eta(remaining: total - bytes, at: time)
    }

    public func eta(bytes: Int64, total: Int64?, at date: Date) -> TimeInterval? {
        eta(bytes: bytes, total: total, at: date.timeIntervalSinceReferenceDate)
    }

    // MARK: inside

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
                return Double(previous.bytes) + f * Double(s.bytes - previous.bytes)
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

    /// Under `fewSeconds`: a few seconds. Under a minute: 5-second steps.
    /// Above: whole minutes (1 hr 5 min past an hour).
    public static func timeLeft(_ seconds: TimeInterval) -> TimeLeft {
        guard seconds.isFinite, seconds >= fewSeconds else { return .fewSeconds }
        let steps = Int((seconds / 5).rounded(.toNearestOrAwayFromZero)) * 5
        if steps < 60 { return .seconds(steps) }
        let minutes = max(1, Int((seconds / 60).rounded(.toNearestOrAwayFromZero)))
        if minutes < 60 { return .minutes(minutes) }
        return .hours(minutes / 60, minutes: minutes % 60)
    }

    /// "about 20 sec left", "about 1 hr 5 min left", "a few seconds left"
    public static func timeLeftText(_ seconds: TimeInterval) -> String {
        switch timeLeft(seconds) {
        case .fewSeconds: return String(localized: "a few seconds left")
        case .seconds(let s): return String(localized: "about \(s) sec left")
        case .minutes(let m): return String(localized: "about \(m) min left")
        case .hours(let h, 0): return String(localized: "about \(h) hr left")
        case .hours(let h, let m): return String(localized: "about \(h) hr \(m) min left")
        }
    }
}
