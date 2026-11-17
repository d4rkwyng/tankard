import Foundation

/// The three windows formulae.brew.sh publishes install counts for.
public enum AnalyticsPeriod: String, CaseIterable, Sendable, Identifiable {
    case days30 = "30d", days90 = "90d", days365 = "365d"

    public var id: String { rawValue }

    /// "30 days"
    public var title: String {
        switch self {
        case .days30: return String(localized: "30 days")
        case .days90: return String(localized: "90 days")
        case .days365: return String(localized: "365 days")
        }
    }

    /// The bulk file for this window: `analytics/install/30d.json` (formulae)
    /// or `analytics/cask-install/30d.json` (casks).
    public func endpoint(_ kind: PackageKind) -> String {
        "analytics/\(kind == .cask ? "cask-install" : "install")/\(rawValue).json"
    }
}

/// One package's install counts. A window the package is missing from
/// (while present in another) counts as 0: the bulk files list every
/// package with at least one install.
public struct InstallCounts: Sendable, Equatable {
    public var days30: Int
    public var days90: Int
    public var days365: Int

    public init(days30: Int = 0, days90: Int = 0, days365: Int = 0) {
        self.days30 = days30
        self.days90 = days90
        self.days365 = days365
    }

    public subscript(_ p: AnalyticsPeriod) -> Int {
        get {
            switch p {
            case .days30: return days30
            case .days90: return days90
            case .days365: return days365
            }
        }
        set {
            switch p {
            case .days30: days30 = newValue
            case .days90: days90 = newValue
            case .days365: days365 = newValue
            }
        }
    }

    /// "12,345" in the given locale ("12.345" in German).
    public static func number(_ n: Int, locale: Locale = .current) -> String {
        n.formatted(.number.locale(locale))
    }

    /// "12,345 installs in the last 30 days", "1 install in the last 30
    /// days" (the tooltip and VoiceOver). Plural forms come from the
    /// catalog's plural variations (Localizable.stringsdict); the count is
    /// grouped in `locale` ("12.345" in German).
    public static func sentence(_ n: Int, _ p: AnalyticsPeriod, locale: Locale = .current, bundle: Bundle = .main) -> String {
        switch p {
        case .days30: return String(localized: "\(n) installs in the last 30 days", bundle: bundle, locale: locale)
        case .days90: return String(localized: "\(n) installs in the last 90 days", bundle: bundle, locale: locale)
        case .days365: return String(localized: "\(n) installs in the last 365 days", bundle: bundle, locale: locale)
        }
    }
}

/// formulae.brew.sh's install analytics, keyed like `CatalogEntry.id`
/// ("formula:homebrew/core/xz", "cask:homebrew/cask/firefox").
///
/// formula.json and cask.json carry no analytics; the per-package JSON
/// does, but asking for it would tell formulae.brew.sh which package is
/// being looked at. So Discover reads the six bulk files
/// (`analytics/install/{30,90,365}d.json` and `analytics/cask-install/…`,
/// about 13 MB together) once a day instead.
public struct InstallAnalytics: Sendable {
    public var counts: [String: InstallCounts]
    /// The last day the windows cover ("2026-11-17"), from the 30-day files.
    public var endDate: String?

    public init(counts: [String: InstallCounts] = [:], endDate: String? = nil) {
        self.counts = counts
        self.endDate = endDate
    }

    public subscript(id: String) -> InstallCounts? { counts[id] }

    /// The 30-day count by id: Discover's popularity tie-break.
    public var popularity: [String: Int] {
        counts.compactMapValues { $0.days30 > 0 ? $0.days30 : nil }
    }

    /// One bulk file: `{"start_date", "end_date", "items": [{"formula"|"cask", "count": "1,234"}]}`.
    struct Document: Decodable {
        struct Item: Decodable {
            var formula: String?
            var cask: String?
            /// nil when the entry's count can't be read: that entry is
            /// skipped, the rest of the file still counts.
            var count: Int?

            enum CodingKeys: String, CodingKey { case formula, cask, count }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                formula = try? c.decodeIfPresent(String.self, forKey: .formula)
                cask = try? c.decodeIfPresent(String.self, forKey: .cask)
                // "551,467" (always a string with grouping, so far); an
                // integer is accepted too.
                if let n = try? c.decode(Int.self, forKey: .count) {
                    count = n
                } else if let s = try? c.decode(String.self, forKey: .count) {
                    let digits = s.filter { $0.isASCII && $0.isNumber }
                    // Only digits and grouping: "1,234" or "1 234", not "n/a" or "-3".
                    let rest = s.filter { !($0.isASCII && $0.isNumber) && $0 != "," && !$0.isWhitespace }
                    count = rest.isEmpty && !digits.isEmpty ? Int(digits) : nil
                } else {
                    count = nil
                }
            }
        }
        var endDate: String?
        var items: [Item]

        enum CodingKeys: String, CodingKey {
            case endDate = "end_date"
            case items
        }
    }

    /// "formula:homebrew/core/xz" for "xz"; "formula:user/tap/foo" for a
    /// tap-qualified name, as the bulk files write packages from other taps.
    public static func id(kind: PackageKind, name: String) -> String {
        let defaultTap = kind == .cask ? "homebrew/cask" : "homebrew/core"
        return "\(kind.rawValue):" + (name.contains("/") ? name : "\(defaultTap)/\(name)")
    }

    /// Decodes and merges bulk files. Each is (kind, window, data).
    public static func decode(_ files: [(PackageKind, AnalyticsPeriod, Data)]) throws -> InstallAnalytics {
        var out = InstallAnalytics()
        let decoder = JSONDecoder()
        for (kind, period, data) in files {
            let doc = try decoder.decode(Document.self, from: data)
            if period == .days30, out.endDate == nil { out.endDate = doc.endDate }
            for item in doc.items {
                guard let name = kind == .cask ? item.cask : item.formula, !name.isEmpty, let count = item.count else { continue }
                // Option variants ("hello --HEAD") count toward the package.
                let base = name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
                out.counts[id(kind: kind, name: base), default: InstallCounts()][period] += count
            }
        }
        return out
    }
}
