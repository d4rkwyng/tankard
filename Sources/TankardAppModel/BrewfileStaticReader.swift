import CryptoKit
import Foundation

// 0.8.8 (security review #2): what a Brewfile lists, read from its text
// without running it. `brew bundle check` and `brew bundle list` run the
// file as Ruby, so opening a downloaded Brewfile "just to look" ran its
// code. The preview reads only lines that are plain literals:
//
//   brew "jq"                       cask "firefox"
//   tap "user/repo"                 tap "user/repo", "https://…"
//   mas "Xcode", id: 497799835      vscode "golang.go"
//
// with optional parentheses, a trailing `# comment`, and keyword options
// whose values are themselves literals (`restart_service: true`,
// `args: ["with-x"]`). Every other line (a variable, interpolation, an
// `if`, a method call, `;`, a backtick, a name brew wouldn't accept) is
// "not read: needs brew to evaluate", shown as text and never run. A line
// read here is only displayed: installing still goes through brew bundle
// check after the user's consent.

/// One line the preview didn't read.
public struct BrewfileUnreadLine: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int { number }
    /// 1-based line number in the file.
    public var number: Int
    /// The line as shown: control characters removed, at most 160 characters.
    public var text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

/// The static preview of a Brewfile.
public struct BrewfilePreview: Equatable, Sendable {
    public var path: String
    public var entries: [BrewfileEntry]
    public var notRead: [BrewfileUnreadLine]
    /// The file carries macOS's `com.apple.quarantine` mark (downloaded).
    public var quarantined: Bool
    /// 0.8.9 (security review F4): SHA-256 of the text shown, so brew runs
    /// only the file the user saw (`BrewfileStore.check(path:expectedDigest:)`).
    public var digest: String
    /// 0.9.0: the text calls `require`, `require_relative`, `load`, `__dir__`
    /// or `__FILE__`. A warning on the preview: the check still runs.
    public var loadsOtherFiles: Bool

    public init(path: String, entries: [BrewfileEntry], notRead: [BrewfileUnreadLine], quarantined: Bool,
                digest: String = "", loadsOtherFiles: Bool = false) {
        self.path = path
        self.entries = entries
        self.notRead = notRead
        self.quarantined = quarantined
        self.digest = digest
        self.loadsOtherFiles = loadsOtherFiles
    }

    public func names(_ kind: BrewfileKind?) -> [String] { entries.filter { $0.kind == kind }.map(\.name) }
}

public enum BrewfileStaticReader {
    /// Bigger files aren't previewed (a Brewfile is a few KB).
    public static let maxBytes = 1_000_000
    static let maxShown = 160

    public static func preview(path: String, text: String, quarantined: Bool) -> BrewfilePreview {
        var entries: [BrewfileEntry] = []
        var notRead: [BrewfileUnreadLine] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let e = entry(line) {
                entries.append(e)
            } else {
                notRead.append(BrewfileUnreadLine(number: i + 1, text: shown(line)))
            }
        }
        return BrewfilePreview(path: path, entries: entries, notRead: notRead, quarantined: quarantined,
                               digest: digest(text), loadsOtherFiles: loadsOtherFiles(text))
    }

    /// 0.9.0: `require`, `require_relative`, `load`, `__dir__` or `__FILE__`
    /// as a Ruby token, outside comments and string literals. Tankard runs
    /// a private copy, so a path relative to the Brewfile won't be found.
    /// A warning, never a refusal.
    public static func loadsOtherFiles(_ text: String) -> Bool {
        BrewfileLoadScan.contains(text)
    }

    /// 0.8.9 (F4): hex SHA-256 of the file's text (its UTF-8 bytes).
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 0.8.9 (F4): what a path names. Only a regular file (or a symlink to
    /// one) is read as a Brewfile: a FIFO or a device would block the read,
    /// or give different bytes each time.
    public enum FileKind: Equatable, Sendable { case regular, missing, other }

    public static func fileKind(_ path: String) -> FileKind {
        var st = stat()
        guard stat(path, &st) == 0 else { return .missing }
        return (st.st_mode & S_IFMT) == S_IFREG ? .regular : .other
    }

    /// The entry a plain literal line declares; nil for anything else.
    public static func entry(_ line: String) -> BrewfileEntry? {
        let keywords: [(String, BrewfileKind)] = [("brew", .formula), ("cask", .cask), ("tap", .tap),
                                                  ("mas", .mas), ("vscode", .vscode)]
        guard let (word, kind) = keywords.first(where: { line.hasPrefix($0.0) }) else { return nil }
        var rest = Substring(line.dropFirst(word.count))
        guard let first = rest.first, first == " " || first == "\t" || first == "(" else { return nil }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        let parenthesized = rest.first == "("
        if parenthesized { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        guard let (name, afterName) = BrewfileTapScanner.literal(rest), validName(name, kind) else { return nil }
        var tail = afterName
        var positional = 0
        var options: [String: String] = [:]
        while true {
            tail = tail.drop { $0 == " " || $0 == "\t" }
            guard tail.first == "," else { break }
            tail = tail.dropFirst().drop { $0 == " " || $0 == "\t" }
            // A tap's URL: one more literal before any option.
            if kind == .tap, positional == 0, options.isEmpty, let (_, after) = BrewfileTapScanner.literal(tail) {
                positional += 1
                tail = after
                continue
            }
            guard let (key, value, after) = option(tail) else { return nil }
            options[key] = value
            tail = after
        }
        tail = tail.drop { $0 == " " || $0 == "\t" }
        if parenthesized {
            guard tail.first == ")" else { return nil }
            tail = tail.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        // An App Store app is named by its id.
        if kind == .mas {
            guard let id = options["id"], !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
        }
        return BrewfileEntry(kind: kind, name: name)
    }

    /// `key: value`, with a value that is a literal: a string without
    /// escapes or interpolation, true/false/nil, a whole number, a symbol,
    /// or an array of strings and symbols. The value is returned as text.
    static func option(_ s: Substring) -> (String, String, Substring)? {
        let key = s.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        guard let k0 = key.first, k0.isLetter || k0 == "_" else { return nil }
        var rest = s.dropFirst(key.count)
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let (value, after) = scalar(rest) ?? array(rest) else { return nil }
        return (String(key), value, after)
    }

    static func scalar(_ s: Substring) -> (String, Substring)? {
        if let (v, after) = BrewfileTapScanner.literal(s) { return (v, after) }
        let word = s.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ":") }
        guard !word.isEmpty else { return nil }
        let after = s.dropFirst(word.count)
        // The next character must end the value (no `foo.bar`, `foo(…)`).
        if let next = after.first, !(next == " " || next == "\t" || next == "," || next == ")" || next == "]" || next == "#") {
            return nil
        }
        let w = String(word)
        if w == "true" || w == "false" || w == "nil" { return (w, after) }
        if w.allSatisfy(\.isNumber) { return (w, after) }
        if w.hasPrefix(":"), w.count > 1, !w.dropFirst().contains(":"),
           let c = w.dropFirst().first, c.isLetter || c == "_" {
            return (w, after)
        }
        return nil
    }

    static func array(_ s: Substring) -> (String, Substring)? {
        guard s.first == "[" else { return nil }
        var rest = s.dropFirst().drop { $0 == " " || $0 == "\t" }
        var items: [String] = []
        if rest.first == "]" { return ("[]", rest.dropFirst()) }
        while true {
            guard let (v, after) = BrewfileTapScanner.literal(rest) ?? symbol(rest) else { return nil }
            items.append(v)
            rest = after.drop { $0 == " " || $0 == "\t" }
            if rest.first == "," { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }; continue }
            guard rest.first == "]" else { return nil }
            return ("[" + items.joined(separator: ", ") + "]", rest.dropFirst())
        }
    }

    static func symbol(_ s: Substring) -> (String, Substring)? {
        guard s.first == ":", let (v, after) = scalar(s), v.hasPrefix(":") else { return nil }
        return (v, after)
    }

    /// Names brew would accept for the kind (and nothing starting with "-").
    public static func validName(_ name: String, _ kind: BrewfileKind) -> Bool {
        guard !name.hasPrefix("-"), name.count <= 200 else { return false }
        switch kind {
        case .formula, .cask:
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            return (parts.count == 1 || parts.count == 3) && parts.allSatisfy { part($0, extra: "@+_.-") }
        case .tap:
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { part($0, extra: "_.-") }
        case .vscode:
            return part(Substring(name), extra: "_.-")
        case .mas:
            // Display only (an App Store app is installed by its id, in Terminal).
            return !name.isEmpty && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }

    static func part(_ s: Substring, extra: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) }
    }

    static func shown(_ line: String) -> String {
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        return clean.count > maxShown ? String(clean.prefix(maxShown - 1)) + "…" : clean
    }

    /// macOS marked the file as downloaded (`com.apple.quarantine`).
    public static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}

/// `require` / `require_relative` / `load` / `__dir__` / `__FILE__` as Ruby
/// tokens. Comments, string and symbol literals, and percent-literals don't
/// count; `#{ }` interpolation is code and does. A word that only contains
/// one of those names (`required`, `download`) is a different token.
private enum BrewfileLoadScan {
    static let tokens: Set<String> = ["require", "require_relative", "load", "__dir__", "__FILE__"]

    static func contains(_ text: String) -> Bool {
        var scanner = Scanner(chars: Array(text))
        return scanner.scanFile()
    }

    struct Scanner {
        var chars: [Character]
        var i = 0
        /// True only at column 0. Ruby's `=begin` is a comment only there.
        var lineStart = true
        /// Heredocs opened on the current line; their bodies follow the newline.
        var heredocs: [Heredoc] = []

        struct Heredoc {
            var ident: String
            var interpolate: Bool
            var indented: Bool
        }

        mutating func scanFile() -> Bool {
            scanCode(inInterpolation: false)
        }

        mutating func scanCode(inInterpolation: Bool) -> Bool {
            var braces = 0
            while i < chars.count {
                if lineStart, skipBlockComment() { continue }
                let c = chars[i]
                if c == "\n" {
                    i += 1
                    lineStart = true
                    if !inInterpolation, drainHeredocs() { return true }
                    continue
                }
                if c == " " || c == "\t" || c == "\r" {
                    i += 1
                    lineStart = false
                    continue
                }
                lineStart = false
                if inInterpolation, braces == 0, c == "}" {
                    i += 1
                    return false
                }
                if c == "#" { skipLine(); continue }
                if c == "'" { if scanQuoted(end: "'", interpolate: false) { return true }; continue }
                if c == "\"" { if scanQuoted(end: "\"", interpolate: true) { return true }; continue }
                if c == "`" { if scanQuoted(end: "`", interpolate: true) { return true }; continue }
                if c == ":" { if scanSymbol() { return true }; continue }
                if c == "@" { skipIvar(); continue }
                if c == "$" { skipGlobal(); continue }
                if c == "?" { skipCharacterLiteral(); continue }
                if c == "%" { if scanPercent() { return true }; continue }
                if c == "<", !inInterpolation, openHeredoc() { continue }
                if c == "{" { braces += 1; i += 1; continue }
                if c == "}" {
                    if braces > 0 { braces -= 1; i += 1; continue }
                    if inInterpolation { i += 1; return false }
                    i += 1
                    continue
                }
                if isIdentStart(c) {
                    if BrewfileLoadScan.tokens.contains(readIdent()) { return true }
                    continue
                }
                i += 1
            }
            return false
        }

        mutating func skipBlockComment() -> Bool {
            guard match("=begin"), atBoundary(after: "=begin".count) else { return false }
            skipLine()
            if i < chars.count, chars[i] == "\n" { i += 1 }
            while i < chars.count {
                if match("=end"), atBoundary(after: "=end".count) {
                    skipLine()
                    if i < chars.count, chars[i] == "\n" { i += 1 }
                    lineStart = true
                    return true
                }
                skipLine()
                if i < chars.count, chars[i] == "\n" { i += 1 }
            }
            return true
        }

        /// The character `n` ahead is whitespace, a comment, or the end: `=begin`
        /// and `=end` aren't comments when more of an identifier follows.
        func atBoundary(after n: Int) -> Bool {
            let j = i + n
            guard j < chars.count else { return true }
            let c = chars[j]
            return c == " " || c == "\t" || c == "\r" || c == "\n" || c == "#"
        }

        func match(_ s: String) -> Bool {
            let want = Array(s)
            guard i + want.count <= chars.count else { return false }
            return chars[i..<(i + want.count)].elementsEqual(want)
        }

        mutating func skipLine() {
            while i < chars.count, chars[i] != "\n" { i += 1 }
        }

        mutating func scanQuoted(end: Character, interpolate: Bool) -> Bool {
            i += 1
            while i < chars.count {
                let c = chars[i]
                if c == "\\" {
                    i += 1
                    if i < chars.count { i += 1 }
                    continue
                }
                if interpolate, c == "#", peekNext("{") {
                    i += 2
                    if scanCode(inInterpolation: true) { return true }
                    continue
                }
                if c == end { i += 1; return false }
                i += 1
            }
            return false
        }

        /// `:name` and `:"..."` are symbols, not calls. `::` is scope, so the
        /// name after it is still scanned as code.
        mutating func scanSymbol() -> Bool {
            i += 1
            guard i < chars.count else { return false }
            let c = chars[i]
            if c == ":" { return false }
            if c == "'" { return scanQuoted(end: "'", interpolate: false) }
            if c == "\"" { return scanQuoted(end: "\"", interpolate: true) }
            if isIdentStart(c) { _ = readIdent(); return false }
            return false
        }

        mutating func skipIvar() {
            i += 1
            if i < chars.count, chars[i] == "@" { i += 1 }
            if i < chars.count, isIdentStart(chars[i]) { _ = readIdent() }
        }

        mutating func skipGlobal() {
            i += 1
            if i < chars.count, isIdentStart(chars[i]) { _ = readIdent() }
            else if i < chars.count { i += 1 }
        }

        /// `?a` and `?\n` are one character. A ternary's `?` is followed by
        /// space, which is left for the next token.
        mutating func skipCharacterLiteral() {
            i += 1
            guard i < chars.count else { return }
            if chars[i] == "\\" {
                i += 1
                if i < chars.count { i += 1 }
                return
            }
            if chars[i] != " " && chars[i] != "\t" && chars[i] != "\n" && chars[i] != "\r" { i += 1 }
        }

        /// `%q{}` and the other percent literals. Not `%` used as modulo.
        /// Only `#{ }` inside an interpolating literal is code.
        mutating func scanPercent() -> Bool {
            let start = i
            i += 1
            guard i < chars.count else { return false }
            var type: Character = "Q"
            if "qQwWiIsSrRxX".contains(chars[i]) {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if let next, isDelimiter(next) {
                    type = chars[i]
                    i += 1
                }
            }
            guard i < chars.count, isDelimiter(chars[i]) else {
                i = start + 1
                return false
            }
            let open = chars[i]
            i += 1
            let close = closing(open)
            let interpolate = "QWIrRx".contains(type)
            return scanDelimited(open: open, close: close, interpolate: interpolate)
        }

        func isDelimiter(_ c: Character) -> Bool {
            !(c.isLetter || c.isNumber || c == " " || c == "\t" || c == "\n" || c == "\r")
        }

        func closing(_ open: Character) -> Character {
            switch open {
            case "(": return ")"
            case "[": return "]"
            case "{": return "}"
            case "<": return ">"
            default: return open
            }
        }

        mutating func scanDelimited(open: Character, close: Character, interpolate: Bool) -> Bool {
            var depth = 1
            while i < chars.count, depth > 0 {
                let c = chars[i]
                if c == "\\" {
                    i += 1
                    if i < chars.count { i += 1 }
                    continue
                }
                if interpolate, c == "#", peekNext("{") {
                    i += 2
                    if scanCode(inInterpolation: true) { return true }
                    continue
                }
                if open != close, c == open { depth += 1; i += 1; continue }
                if c == close {
                    depth -= 1
                    i += 1
                    continue
                }
                i += 1
            }
            return false
        }

        /// `<<EOF`, `<<-EOF`, `<<~EOF`, and quoted markers. The body is the
        /// following lines; the rest of this line is still code.
        mutating func openHeredoc() -> Bool {
            guard peekNext("<") else { return false }
            var j = i + 2
            var indented = false
            if j < chars.count, chars[j] == "-" || chars[j] == "~" {
                indented = true
                j += 1
            }
            var quoted: Character?
            if j < chars.count, chars[j] == "'" || chars[j] == "\"" || chars[j] == "`" {
                quoted = chars[j]
                j += 1
            }
            guard j < chars.count, isIdentStart(chars[j]) else { return false }
            var k = j + 1
            while k < chars.count, isIdentCont(chars[k]) { k += 1 }
            if let q = quoted {
                guard k < chars.count, chars[k] == q else { return false }
                k += 1
            }
            let ident = String(chars[j..<k])
            let interpolate = quoted != "'"
            heredocs.append(Heredoc(ident: ident, interpolate: interpolate, indented: indented))
            i = k
            return true
        }

        mutating func drainHeredocs() -> Bool {
            while !heredocs.isEmpty {
                let h = heredocs[0]
                if i >= chars.count { heredocs.removeAll(); return false }
                if isHeredocEnd(h) {
                    skipLine()
                    if i < chars.count, chars[i] == "\n" { i += 1 }
                    heredocs.removeFirst()
                    lineStart = true
                    continue
                }
                if scanHeredocLine(interpolate: h.interpolate) { return true }
            }
            return false
        }

        func isHeredocEnd(_ h: Heredoc) -> Bool {
            var j = i
            if h.indented {
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            }
            let want = Array(h.ident)
            guard j + want.count <= chars.count, chars[j..<(j + want.count)].elementsEqual(want) else { return false }
            j += want.count
            while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
            return j >= chars.count || chars[j] == "\n"
        }

        mutating func scanHeredocLine(interpolate: Bool) -> Bool {
            while i < chars.count, chars[i] != "\n" {
                if chars[i] == "\\" {
                    i += 1
                    if i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if interpolate, chars[i] == "#", peekNext("{") {
                    i += 2
                    if scanCode(inInterpolation: true) { return true }
                    continue
                }
                i += 1
            }
            if i < chars.count, chars[i] == "\n" { i += 1 }
            return false
        }

        mutating func readIdent() -> String {
            let start = i
            i += 1
            while i < chars.count, isIdentCont(chars[i]) { i += 1 }
            if i < chars.count, chars[i] == "?" || chars[i] == "!" { i += 1 }
            return String(chars[start..<i])
        }

        func peekNext(_ s: Character) -> Bool { i + 1 < chars.count && chars[i + 1] == s }

        func isIdentStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
        func isIdentCont(_ c: Character) -> Bool { c == "_" || c.isLetter || ("0"..."9").contains(c) }
    }
}
