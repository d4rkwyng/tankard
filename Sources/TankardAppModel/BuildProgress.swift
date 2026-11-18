import Foundation
import TankardCore

// 0.8.5: progress for a long build from source. brew prints no duration
// or estimate of its own for a build (it shows only the build commands as
// they run), so the estimate is this Mac's own History: how long the last
// builds from source of the same formula took here. With none, the sheet
// shows the time so far only ("Building from source… 4 min so far").

public enum BuildProgress {
    /// The step builds `p` from source, as the plan says (no bottle).
    public static func buildsFromSource(_ p: Package, action: SessionAction) -> Bool {
        guard p.kind == .formula else { return false }
        switch action {
        case .upgrade, .install: return p.upgradeHasBottle != true
        default: return false
        }
    }

    /// The median of the last (up to) three successful builds from source
    /// of this formula on this Mac, nil with none. Only single-package
    /// steps count (Tankard runs one package per step).
    public static func estimate(for p: Package, history: [HistoryEntry]) -> TimeInterval? {
        let runs = history.lazy.filter { e in
            guard e.builtFromSource == true, e.outcome == .succeeded, e.duration > 0,
                  e.category == .upgrade || e.category == .install else { return false }
            let named = e.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            guard named.count == 1, let n = named.first else { return false }
            return n == p.fullName || n == p.name || n.split(separator: "/").last.map(String.init) == p.name
        }.prefix(3).map(\.duration).sorted()
        guard !runs.isEmpty else { return nil }
        return runs[runs.count / 2]
    }

    /// "under a minute", "4 min", "1 h 5 min".
    public static func elapsedText(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 60 else { return String(localized: "under a minute") }
        let m = Int(s / 60)
        return hoursMinutes(m)
    }

    /// Rounded so it never looks more precise than it is: to the minute
    /// under 10 min, to 5 min under an hour, to 15 min above.
    public static func estimateText(_ s: TimeInterval) -> String {
        guard s.isFinite, s > 0 else { return String(localized: "under a minute") }
        let m = s / 60
        let rounded: Int
        if m < 10 { rounded = max(1, Int(m.rounded())) } else if m < 60 { rounded = Int((m / 5).rounded()) * 5 } else { rounded = Int((m / 15).rounded()) * 15 }
        return hoursMinutes(rounded)
    }

    static func hoursMinutes(_ m: Int) -> String {
        if m < 60 { return String(localized: "\(m) min") }
        let h = m / 60, r = m % 60
        return r == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(r) min")
    }

    /// "Building from source… 4 min so far" or, with an estimate,
    /// "Building from source… 4 min so far (last time on this Mac: about 15 min)".
    public static func line(elapsed: TimeInterval, estimate: TimeInterval?) -> String {
        let so = elapsedText(elapsed)
        guard let estimate else { return String(localized: "Building from source… \(so) so far") }
        return String(localized: "Building from source… \(so) so far (last time on this Mac: about \(estimateText(estimate)))")
    }
}

extension UpgradeSession {
    /// The build line for the running step, or nil when it isn't building
    /// from source (or is downloading, waiting, stopping, or brew poured a
    /// bottle after all).
    public func buildLine(at now: Date) -> String? {
        guard let c = current, compilingItems.contains(c.id), !pouringItems.contains(c.id),
              download == nil, lockWait == nil, !stoppingNow, let started = itemStartedAt[c.id] else { return nil }
        return BuildProgress.line(elapsed: now.timeIntervalSince(started), estimate: buildEstimates[c.id])
    }
}

extension AppStore {
    /// Marks a session's compile steps (and their estimates) when it starts.
    func configureBuildProgress(_ session: UpgradeSession) {
        let compiling = session.items.filter { BuildProgress.buildsFromSource($0.package, action: session.action) }
        guard !compiling.isEmpty else { return }
        var estimates: [UUID: TimeInterval] = [:]
        for item in compiling {
            estimates[item.id] = BuildProgress.estimate(for: item.package, history: history.entries)
        }
        session.setBuildProgress(compiling: Set(compiling.map(\.id)), estimates: estimates)
    }

    /// A finished session's builds from source go into History as such
    /// (the next build's estimate).
    func recordBuilds(_ session: UpgradeSession) {
        for item in session.items where item.state == .done
            && session.compilingItems.contains(item.id) && !session.pouringItems.contains(item.id) {
            if !history.markBuiltFromSource(item.id) { pendingBuilt.insert(item.id) }
        }
    }
}

public extension HistoryLog {
    /// false: no such entry (yet).
    @discardableResult
    func markBuiltFromSource(_ id: UUID) -> Bool {
        guard var e = entries.first(where: { $0.id == id }) else { return false }
        e.builtFromSource = true
        replace(removing: [id], with: e)
        return true
    }
}
