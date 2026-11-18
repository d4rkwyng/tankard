import Foundation

/// v0.4: disk usage per installed package, from `brew info --sizes`.
///
/// brew walks each formula's kegs and each cask's Caskroom version folder
/// (following its symlinks to the app, so an app in /Applications counts)
/// and prints a table with decimal units rounded to one place:
///
///     ==> Formulae sizes:
///     python@3.15       77.3MB
///     lua              867.1KB
///     Total            289.1MB
///     ==> Casks sizes:
///     iterm2             207.4MB
///     Total              207.4MB
///
/// Parsing brew's table rather than walking the Cellar ourselves keeps one
/// definition of "size" (brew's: hard links counted once, casks through
/// their symlinks). The rounding costs at most 0.05 of a unit per row.
public struct DiskSizes: Codable, Sendable, Equatable {
    /// Full name → bytes.
    public var formulae: [String: Int64]
    /// Cask full name (token, or tap/token outside homebrew/cask) → bytes.
    public var casks: [String: Int64]
    /// brew's own "Total" lines, when printed.
    public var formulaeTotal: Int64?
    public var casksTotal: Int64?
    public var measuredAt: Date

    public init(formulae: [String: Int64] = [:], casks: [String: Int64] = [:],
                formulaeTotal: Int64? = nil, casksTotal: Int64? = nil, measuredAt: Date) {
        self.formulae = formulae
        self.casks = casks
        self.formulaeTotal = formulaeTotal
        self.casksTotal = casksTotal
        self.measuredAt = measuredAt
    }

    public static func parse(_ text: String, measuredAt: Date = Date()) -> DiskSizes {
        var result = DiskSizes(measuredAt: measuredAt)
        enum Section { case none, formulae, casks }
        var section = Section.none
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                let title = line.lowercased()
                section = title.contains("formula") ? .formulae : title.contains("cask") ? .casks : .none
                continue
            }
            guard section != .none,
                  let split = line.lastIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let name = line[..<split].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let bytes = Self.bytes(String(line[line.index(after: split)...])) else { continue }
            // Formula and cask names are lower case; brew's total row is "Total".
            switch (section, name == "Total") {
            case (.formulae, true): result.formulaeTotal = bytes
            case (.casks, true): result.casksTotal = bytes
            case (.formulae, false): result.formulae[name] = bytes
            case (.casks, false): result.casks[name] = bytes
            case (.none, _): break
            }
        }
        return result
    }

    /// "867.1KB", "34MB", "1.2GB", "512B" (brew's decimal units) → bytes.
    public static func bytes(_ s: String) -> Int64? {
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, scale) in units where s.hasSuffix(suffix) {
            guard let n = Double(s.dropLast(suffix.count)), n >= 0 else { return nil }
            return Int64((n * scale).rounded())
        }
        return nil
    }

    /// The package's size, if brew listed it.
    public func bytes(for p: Package) -> Int64? {
        p.kind == .cask ? (casks[p.fullName] ?? casks[p.name]) : formulae[p.fullName]
    }

    /// Bytes as brew counts them, with a space: "867.1 KB", "34 MB", "1.2 GB".
    /// 0.8.6 (UI details M6): the number in the locale's style ("77,3 MB"
    /// in German), so every size in Tankard reads one way.
    public static func format(_ bytes: Int64, locale: Locale = .current) -> String {
        var size = Double(bytes)
        var unit = "B"
        for next in ["KB", "MB", "GB", "TB"] {
            guard (size * 10).rounded() / 10 >= 1000 else { break }
            size /= 1000
            unit = next
        }
        let rounded = (size * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded)) \(unit)" }
        return rounded.formatted(.number.precision(.fractionLength(1)).grouping(.never).locale(locale)) + " " + unit
    }
}
