import Foundation
import Testing
@testable import TankardAppModel

// 0.8.8: the package lists hold their rows back until the styler has found
// their table empty and switched it to fixed row heights. A table that kept
// automatic heights logged AppKit's "reentrant operation in its NSTableView
// delegate" on every big change to the rows (gauntlets: 12 on macOS 15, 11
// on macOS 26); one switched after its first row draws blank (B1).

struct V088RowHeightGateTests {
    @Test func noRowsUntilTheTableMeasuresNone() {
        let g = RowHeightGate()
        #expect(!g.ready)
        #expect(g.rows([1, 2, 3]).isEmpty)
        #expect(g.generation == 0)
    }

    @Test func fixedHeightsLetTheRowsIn() {
        var g = RowHeightGate()
        g.report(true)
        #expect(g.ready)
        #expect(g.rows([1, 2, 3]) == [1, 2, 3])
        #expect(g.generation == 0)
        // Told again (the styler reports once per table; a repeat is harmless).
        g.report(true)
        #expect(g.ready && g.generation == 0)
    }

    @Test func aTableFoundWithAutomaticHeightsIsReplacedByAnEmptyOne() {
        var g = RowHeightGate()
        g.report(true)
        // SwiftUI rebuilt the table and it already had rows: it keeps
        // automatic heights, so the list empties and asks for a new table.
        g.report(false)
        #expect(!g.ready)
        #expect(g.generation == 1)
        #expect(g.rows(["a"]).isEmpty)
        // The new table is found empty and switched.
        g.report(true)
        #expect(g.ready && g.generation == 1)
        #expect(g.rows(["a"]) == ["a"])
    }
}
