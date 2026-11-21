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

    public init(path: String, entries: [BrewfileEntry], notRead: [BrewfileUnreadLine], quarantined: Bool,
                digest: String = "") {
        self.path = path
        self.entries = entries
        self.notRead = notRead
        self.quarantined = quarantined
        self.digest = digest
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
                               digest: digest(text))
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
