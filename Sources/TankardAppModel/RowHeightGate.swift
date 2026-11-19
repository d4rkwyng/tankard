import Foundation

/// 0.8.8: a package list holds its rows back until its table measures no
/// row.
///
/// A table with automatic row heights measures its rows on every big
/// change (a search narrowed or widened, a filter, a sort), and AppKit's
/// row-height cache then re-enters itself while SwiftUI inserts or removes
/// rows: "Application performed a reentrant operation in its NSTableView
/// delegate. This warning will become an assert in the future." (0.8.8
/// gauntlets: 12 on macOS 15, 11 on macOS 26). Fixed heights avoid it, but
/// a table can only be switched to them while it has never had a row
/// (B1: one switched later draws blank rows on macOS 15). So a list shows
/// no rows until the styler has found its table empty and switched it
/// (`report(true)`); a table found with rows and automatic heights
/// (`report(false)`, a table SwiftUI rebuilt) is replaced by a new, empty
/// one (`generation`, the table's identity).
public struct RowHeightGate: Equatable, Sendable {
    /// The table measures no row: it may have its rows.
    public private(set) var ready = false
    /// The table's identity; a new value makes a new table.
    public private(set) var generation = 0

    public init() {}

    /// What the styler found: true, fixed heights; false, automatic
    /// heights with rows (that table keeps them).
    public mutating func report(_ fixedHeights: Bool) {
        if fixedHeights {
            ready = true
        } else {
            ready = false
            generation += 1
        }
    }

    /// The rows to give the table now: none until it is ready.
    public func rows<T>(_ all: [T]) -> [T] { ready ? all : [] }
}
