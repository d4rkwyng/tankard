import Foundation
import Testing
@testable import TankardAppModel

struct LineAssemblerTests {
    @Test func plainLines() {
        var a = LineAssembler()
        #expect(a.feed("==> Upgrading xz\n🍺  done\npartial") == ["==> Upgrading xz", "🍺  done"])
        #expect(a.current == "partial")
        #expect(a.displayLines == ["==> Upgrading xz", "🍺  done", "partial"])
        #expect(a.finish() == ["partial"])
        #expect(a.current.isEmpty)
    }

    @Test func carriageReturnRedrawsTheLine() {
        // curl's progress bar: one line, redrawn many times, then a newline.
        var a = LineAssembler()
        a.feed("==> Downloading x\n")
        a.feed("\r###     10.0%")
        #expect(a.current == "###     10.0%")
        a.feed("\r######  50.0%\r########100.0%")
        #expect(a.current == "########100.0%")
        #expect(a.feed("\n") == ["########100.0%"])
        #expect(a.lines == ["==> Downloading x", "########100.0%"])
    }

    @Test func crlfIsOneNewline() {
        var a = LineAssembler()
        #expect(a.feed("one\r\ntwo\r\n") == ["one", "two"])
        #expect(a.current.isEmpty)
    }

    @Test func crlfSplitAcrossChunks() {
        // The \r arrives at the end of one read and the \n starts the next:
        // that's a line ending, not a redraw.
        var a = LineAssembler()
        #expect(a.feed("line\r").isEmpty)
        #expect(a.current == "line") // held, not cleared yet
        #expect(a.feed("\nnext") == ["line"])
        #expect(a.current == "next")
    }

    @Test func crSplitAcrossChunksThenText() {
        var a = LineAssembler()
        a.feed("50%\r")
        a.feed("75%")
        #expect(a.current == "75%")
        #expect(a.lines.isEmpty)
    }

    @Test func utf8SplitAcrossChunks() {
        let beer = Array("🍺 poured\n".utf8)
        var a = LineAssembler()
        #expect(a.feed(Data(beer[0..<2])).isEmpty)
        #expect(a.feed(Data(beer[2...])) == ["🍺 poured"])
    }

    @Test func ansiIsStripped() {
        var a = LineAssembler()
        #expect(a.feed("\u{1B}[34m==>\u{1B}[0m \u{1B}[1mPouring\u{1B}[0m x\n") == ["==> Pouring x"])
        #expect(a.feed("\u{1B}]0;title\u{07}text\n") == ["text"])
    }

    @Test func limitDropsOldestLines() {
        var a = LineAssembler(limit: 3)
        a.feed("1\n2\n3\n4\n5\n")
        #expect(a.lines == ["3", "4", "5"])
        #expect(a.droppedCount == 2)
    }

    @Test func finishWithHeldCR() {
        var a = LineAssembler()
        a.feed("done\r")
        #expect(a.finish() == ["done"])
    }
}
