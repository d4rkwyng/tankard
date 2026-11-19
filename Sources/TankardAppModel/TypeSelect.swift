import Foundation

/// 0.8.7: keyboard type-select in the package lists (Installed, Discover):
/// typing letters with the table focused selects the first row whose
/// package name starts with them.
///
/// SwiftUI's `Table` gives AppKit no type-select string per row (its
/// NSTableView delegate doesn't implement `tableView(_:typeSelectStringFor:row:)`),
/// so AppKit fell back to matching text it found in the row's views. That
/// included a row's note and badges: "b" jumped to a row whose note read
/// "No bottle: …", not to a name starting with "b". The app now turns
/// AppKit's type-select off on those tables and matches the names here.
public struct TypeSelect: Sendable, Equatable {
    /// Keys further apart than this start a new search (AppKit's
    /// type-select waits about as long).
    public static let timeout: TimeInterval = 1.0

    /// What has been typed in the current search.
    public private(set) var buffer = ""
    private var lastKey: TimeInterval?

    public init() {}

    /// Adds typed `characters` at time `now` (seconds, any monotonic clock)
    /// and returns the search string to match.
    public mutating func type(_ characters: String, at now: TimeInterval) -> String {
        if let last = lastKey, now - last > Self.timeout { buffer = "" }
        lastKey = now
        buffer += characters
        return buffer
    }

    /// A key typed at `now`: the index in `names` (the rows in the order
    /// shown) to select, or nil when nothing matches. A new search finds
    /// the first match from the top; more letters typed in time refine it
    /// from the selected row.
    public mutating func select(_ characters: String, at now: TimeInterval, names: [String], selected: Int?) -> Int? {
        let search = type(characters, at: now)
        return Self.match(search, in: names, selected: search.count > characters.count ? selected : nil)
    }

    public mutating func reset() {
        buffer = ""
        lastKey = nil
    }

    /// Whether `name` starts with `prefix`, ignoring case and diacritics.
    public static func matches(_ name: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The index in `names` (the rows in the order shown) of the row to
    /// select for `prefix`: the selected row if it still matches (typing
    /// more letters refines the search), else the first match after it,
    /// wrapping round to the top. nil when no name matches.
    public static func match(_ prefix: String, in names: [String], selected: Int?) -> Int? {
        guard !prefix.isEmpty, !names.isEmpty else { return nil }
        let start = selected.flatMap { names.indices.contains($0) ? $0 : nil } ?? 0
        for offset in 0..<names.count {
            let i = (start + offset) % names.count
            if matches(names[i], prefix: prefix) { return i }
        }
        return nil
    }

    /// Whether a key's `characters` take part in type-select: printable
    /// text, not a control or function key, and no leading space (Space
    /// with nothing typed yet stays the table's).
    public static func isTypeSelectInput(_ characters: String, bufferEmpty: Bool) -> Bool {
        guard !characters.isEmpty else { return false }
        if bufferEmpty && characters.first?.isWhitespace == true { return false }
        for scalar in characters.unicodeScalars {
            // AppKit's function keys (arrows, F-keys, Home, …) are in the
            // private-use range U+F700–U+F8FF.
            if (0xF700...0xF8FF).contains(scalar.value) { return false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if scalar.properties.generalCategory == .format { return false }
        }
        return true
    }
}
