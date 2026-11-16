import Foundation

/// Turns a byte stream from brew into display lines, the way a terminal
/// would show them.
///
/// - `\n` (and `\r\n`) ends a line.
/// - A lone `\r` returns to the start of the line: what follows replaces the
///   line being drawn. curl's `###### 45.0%` progress and brew's spinners
///   redraw this way, so the log shows one progress line, not hundreds.
///   (A terminal overwrites character by character; progress output always
///   redraws the whole line, so replacing it gives the same picture.)
/// - A `\r` at the very end of a chunk is held until the next chunk shows
///   whether it starts a `\r\n`.
/// - Bytes are kept until a line is complete, so a UTF-8 character split
///   across two reads (🍺 is four bytes) decodes intact.
/// - ANSI escape sequences (colour, cursor movement) are removed.
public struct LineAssembler: Sendable {
    /// Finished lines, oldest first.
    public private(set) var lines: [String] = []
    /// The line still being drawn (no newline yet). Empty when none.
    public var current: String { Self.decode(pending) }
    /// How many finished lines `lines` keeps; older ones are dropped
    /// (`droppedCount` counts them). The full log goes to the log file.
    public var limit: Int
    public private(set) var droppedCount = 0

    private var pending: [UInt8] = []
    private var heldCR = false

    public init(limit: Int = 5000) {
        self.limit = limit
    }

    /// Adds a chunk. Returns the lines this chunk finished, in order.
    @discardableResult
    public mutating func feed(_ data: Data) -> [String] {
        var finished: [String] = []
        for byte in data {
            if heldCR {
                heldCR = false
                if byte == 0x0A {
                    finished.append(commit())
                    continue
                }
                pending.removeAll(keepingCapacity: true) // carriage return: redraw
            }
            switch byte {
            case 0x0A: finished.append(commit())
            case 0x0D: heldCR = true
            default: pending.append(byte)
            }
        }
        return finished
    }

    @discardableResult
    public mutating func feed(_ string: String) -> [String] {
        feed(Data(string.utf8))
    }

    /// Ends the stream: a held `\r` and any unfinished line are finished.
    @discardableResult
    public mutating func finish() -> [String] {
        heldCR = false
        guard !pending.isEmpty else { return [] }
        return [commit()]
    }

    /// Every line including the one being drawn, for display.
    public var displayLines: [String] {
        let c = current
        return c.isEmpty ? lines : lines + [c]
    }

    private mutating func commit() -> String {
        let line = Self.decode(pending)
        pending.removeAll(keepingCapacity: true)
        lines.append(line)
        if lines.count > limit {
            let extra = lines.count - limit
            lines.removeFirst(extra)
            droppedCount += extra
        }
        return line
    }

    static func decode(_ bytes: [UInt8]) -> String {
        let s = String(decoding: bytes, as: UTF8.self)
        guard s.contains("\u{1B}") else { return s }
        return stripANSI(s)
    }

    /// Removes CSI (`ESC [ ... final`) and two-byte `ESC x` sequences.
    static func stripANSI(_ s: String) -> String {
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\u{1B}" else { out.unicodeScalars.append(c); continue }
            guard let next = it.next() else { break }
            if next == "[" {
                // Parameters and intermediates until a final byte 0x40-0x7E.
                while let p = it.next() {
                    if (0x40...0x7E).contains(p.value) { break }
                }
            } else if next == "]" {
                // OSC: until BEL or ESC \.
                while let p = it.next() {
                    if p == "\u{07}" { break }
                    if p == "\u{1B}" { _ = it.next(); break }
                }
            }
        }
        return out
    }
}
