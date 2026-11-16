import Foundation

/// A Swift port of Homebrew's `Version` comparison (Library/Homebrew/version.rb).
///
/// Brew splits a version string into tokens (numbers, words, and the special
/// pre-release/post-release words alpha, beta, pre, rc, p, .post) and compares
/// token by token. Shelling out to brew for every comparison would cost a Ruby
/// start-up each time, and `brew ruby` is a developer command (running one
/// switches `brew update` to the default branch), so the rules are ported.
///
/// Known differences from brew are documented in README.md ("Version comparison").
public struct BrewVersion: Comparable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }

    /// `HEAD` or `HEAD-<commit>`: brew's marker for a build from the head spec.
    public var isHead: Bool {
        raw == "HEAD" || raw.hasPrefix("HEAD-")
    }

    // MARK: Tokens

    enum Kind: Equatable {
        case null, numeric, string, alpha, beta, pre, rc, patch, post
    }

    struct Token: Equatable {
        let kind: Kind
        /// Token text as scanned ("rc1", "12", ".post3"). Empty for null.
        let value: String

        static let null = Token(kind: .null, value: "")

        var isNumeric: Bool { kind == .numeric }
        var isComposite: Bool {
            switch kind {
            case .alpha, .beta, .pre, .rc, .patch, .post: return true
            default: return false
            }
        }

        /// Numeric value with leading zeros stripped, as a digit string, so
        /// arbitrarily long digit runs (build numbers, dates) compare correctly.
        var digits: String {
            let trimmed = value.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }

        var isZero: Bool { kind == .numeric && digits == "0" }

        /// CompositeToken#rev: the first run of digits, or 0.
        var rev: Int {
            guard let range = value.range(of: "[0-9]+", options: .regularExpression) else { return 0 }
            return Int(value[range]) ?? Int.max
        }
    }

    // Same alternation order as brew's SCAN_PATTERN.
    private static let scanPattern = try! NSRegularExpression(
        pattern: "alpha[0-9]*|a[0-9]+|beta[0-9]*|b[0-9]+|pre[0-9]*|rc[0-9]*|p[0-9]*|.post[0-9]+|[0-9]+|[a-z]+",
        options: [.caseInsensitive]
    )

    // Same order as brew's Token.create.
    private static let classifiers: [(Kind, NSRegularExpression)] = {
        let table: [(Kind, String)] = [
            (.alpha, "alpha[0-9]*|a[0-9]+"),
            (.beta, "beta[0-9]*|b[0-9]+"),
            (.rc, "rc[0-9]*"),
            (.pre, "pre[0-9]*"),
            (.patch, "p[0-9]*"),
            (.post, ".post[0-9]+"),
            (.numeric, "[0-9]+"),
            (.string, "[a-z]+"),
        ]
        return table.map { kind, pattern in
            (kind, try! NSRegularExpression(pattern: "^(?:\(pattern))$", options: [.caseInsensitive]))
        }
    }()

    var tokens: [Token] {
        let ns = raw as NSString
        let matches = Self.scanPattern.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            let text = ns.substring(with: m.range)
            let full = NSRange(location: 0, length: (text as NSString).length)
            for (kind, re) in Self.classifiers where re.firstMatch(in: text, range: full) != nil {
                return Token(kind: kind, value: text)
            }
            return Token(kind: .string, value: text)
        }
    }

    // MARK: Comparison

    /// Token#<=> including the subclass overrides. nil = brew returns nil
    /// (incomparable); never happens for tokens produced by the scanner.
    static func compare(_ a: Token, _ b: Token) -> Int? {
        switch a.kind {
        case .null:
            switch b.kind {
            case .null: return 0
            case .numeric: return b.isZero ? 0 : -1
            case .alpha, .beta, .pre, .rc: return 1
            default: return -1
            }
        case .numeric:
            switch b.kind {
            case .numeric: return compareDigits(a.digits, b.digits)
            case .null: return a.isZero ? 0 : 1
            default: return 1 // every string-like token
            }
        case .string:
            return compareAsString(a, b)
        case .alpha:
            switch b.kind {
            case .alpha: return cmp(a.rev, b.rev)
            case .beta, .rc, .pre, .patch, .post: return -1
            default: return compareAsString(a, b)
            }
        case .beta:
            switch b.kind {
            case .beta: return cmp(a.rev, b.rev)
            case .alpha: return 1
            case .pre, .rc, .patch, .post: return -1
            default: return compareAsString(a, b)
            }
        case .pre:
            switch b.kind {
            case .pre: return cmp(a.rev, b.rev)
            case .alpha, .beta: return 1
            case .rc, .patch, .post: return -1
            default: return compareAsString(a, b)
            }
        case .rc:
            switch b.kind {
            case .rc: return cmp(a.rev, b.rev)
            case .alpha, .beta, .pre: return 1
            case .patch, .post: return -1
            default: return compareAsString(a, b)
            }
        case .patch:
            switch b.kind {
            case .patch: return cmp(a.rev, b.rev)
            case .alpha, .beta, .rc, .pre: return 1
            default: return compareAsString(a, b)
            }
        case .post:
            switch b.kind {
            case .post: return cmp(a.rev, b.rev)
            case .alpha, .beta, .rc, .pre: return 1
            default: return compareAsString(a, b)
            }
        }
    }

    /// StringToken#<=> (also the `super` fallback of every composite token).
    private static func compareAsString(_ a: Token, _ b: Token) -> Int? {
        switch b.kind {
        case .numeric: return -1
        case .null:
            guard let c = compare(b, a) else { return nil }
            return -c
        default:
            // Ruby String#<=>: bytewise.
            return cmp(Array(a.value.utf8), Array(b.value.utf8))
        }
    }

    private static func compareDigits(_ a: String, _ b: String) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    private static func cmp<T: Comparable>(_ a: T, _ b: T) -> Int {
        a == b ? 0 : (a < b ? -1 : 1)
    }

    private static func cmp(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return cmp(a.count, b.count)
    }

    /// Version#<=>. Returns nil only where brew would.
    public func compare(to other: BrewVersion) -> Int? {
        if raw == other.raw { return 0 }
        if isHead && !other.isHead { return 1 }
        if !isHead && other.isHead { return -1 }
        if isHead && other.isHead { return 0 }

        let lt = tokens, rt = other.tokens
        let maxCount = Swift.max(lt.count, rt.count)
        var l = 0, r = 0
        while l < maxCount || r < maxCount {
            let a = l < lt.count ? lt[l] : .null
            let b = r < rt.count ? rt[r] : .null
            if Self.compare(a, b) == 0 {
                l += 1; r += 1
                continue
            } else if a.isNumeric && !b.isNumeric {
                if Self.compare(a, .null) == 1 { return 1 }
                l += 1
            } else if !a.isNumeric && b.isNumeric {
                if Self.compare(b, .null) == 1 { return -1 }
                r += 1
            } else {
                return Self.compare(a, b)
            }
        }
        return 0
    }

    public static func < (lhs: BrewVersion, rhs: BrewVersion) -> Bool {
        lhs.compare(to: rhs) == -1
    }

    public static func == (lhs: BrewVersion, rhs: BrewVersion) -> Bool {
        lhs.compare(to: rhs) == 0
    }
}

/// Brew's `PkgVersion`: a version plus an optional `_N` formula revision.
/// "1.5.7_1" is version 1.5.7, revision 1.
public struct PkgVersion: Comparable, Sendable, CustomStringConvertible {
    public let version: BrewVersion
    public let revision: Int

    public init(version: String, revision: Int = 0) {
        self.version = BrewVersion(version)
        self.revision = revision
    }

    /// Parses "<version>[_<revision>]" with brew's regex `\A(.+?)(?:_(\d+))?\z`.
    public init(parsing string: String) {
        if let range = string.range(of: "_[0-9]+$", options: .regularExpression),
           range.lowerBound != string.startIndex {
            version = BrewVersion(String(string[..<range.lowerBound]))
            revision = Int(string[string.index(after: range.lowerBound)...]) ?? 0
        } else {
            version = BrewVersion(string)
            revision = 0
        }
    }

    public var description: String {
        revision > 0 ? "\(version.raw)_\(revision)" : version.raw
    }

    public func compare(to other: PkgVersion) -> Int? {
        guard let c = version.compare(to: other.version) else { return nil }
        if c != 0 { return c }
        return revision == other.revision ? 0 : (revision < other.revision ? -1 : 1)
    }

    public static func < (lhs: PkgVersion, rhs: PkgVersion) -> Bool {
        lhs.compare(to: rhs) == -1
    }

    public static func == (lhs: PkgVersion, rhs: PkgVersion) -> Bool {
        lhs.compare(to: rhs) == 0
    }
}
