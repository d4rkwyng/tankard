import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.10: VoiceOver and the string catalog for the sheet's download speed.
// The spoken words live in AccessibilityText (checked here); the view's
// wiring is checked in its source, as V093AccessibilityTests does (the
// helpers below are that file's, which keeps them private).

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// One declaration's source: from `start` up to the next top-level
/// `struct`/`enum`/`extension`/`// MARK:` (or the file's end).
private func source(_ file: String, from start: String) throws -> String {
    let src = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/\(file)"), encoding: .utf8)
    let begin = try #require(src.range(of: start), "\(start) not in \(file)")
    let rest = src[begin.upperBound...]
    let ends = ["\nstruct ", "\nenum ", "\nextension ", "\n// MARK:", "\n@MainActor\n", "\nfinal class "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(src[begin.lowerBound..<(ends.min() ?? src.endIndex)])
}

/// The catalog's live keys and their translations (lang -> value).
private func catalog() throws -> [String: [String: String]] {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Resources/Localizable.xcstrings"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(json["strings"] as? [String: [String: Any]])
    var out: [String: [String: String]] = [:]
    for (key, entry) in strings where entry["extractionState"] as? String != "stale" {
        let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
        out[key] = locs.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
    }
    return out
}

private let shippedLanguages = ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"]

/// One view expression in a view's source: `head` is the view from its
/// first character to the end of that line's expression (closures and
/// same-line modifiers included); `modifiers` are the lines after it that
/// start with `.` (comment lines skipped), i.e. the modifiers applied to
/// that view and not to a sibling or a child. Checking a modifier here,
/// not anywhere in the declaration, is what pins it to the right control.
private struct ViewChain {
    var head: String
    var modifiers: String
    var whole: String { head + modifiers }
}

/// The index of the newline that ends the expression starting at `start`
/// (brackets balanced; strings, interpolations and `//` comments skipped).
private func expressionEnd(_ c: [Character], from start: Int) -> Int {
    var stack: [Character] = [] // open brackets, and `"` for a string
    var i = start
    while i < c.count {
        let ch = c[i], next: Character? = i + 1 < c.count ? c[i + 1] : nil
        if stack.last == "\"" {
            if ch == "\\" {
                if next == "(" { stack.append("(") }
                i += 2
                continue
            }
            if ch == "\"" { stack.removeLast() }
            i += 1
            continue
        }
        if ch == "/", next == "/" {
            while i < c.count, c[i] != "\n" { i += 1 }
            continue
        }
        switch ch {
        case "\"", "(", "{", "[": stack.append(ch)
        case ")", "}", "]": if !stack.isEmpty { stack.removeLast() }
        case "\n" where stack.isEmpty: return i
        default: break
        }
        i += 1
    }
    return c.count
}

/// Every view in `src` that starts with `anchor`, with its modifiers.
private func chains(_ anchor: String, in src: String) -> [ViewChain] {
    let c = Array(src)
    var out: [ViewChain] = []
    var from = src.startIndex
    while let r = src.range(of: anchor, range: from..<src.endIndex) {
        let start = src.distance(from: src.startIndex, to: r.lowerBound)
        let headEnd = expressionEnd(c, from: start)
        var mods = ""
        var j = headEnd
        while j < c.count {
            var k = j + 1
            while k < c.count, c[k] == " " || c[k] == "\t" { k += 1 }
            if k < c.count, c[k] == "." {
                j = expressionEnd(c, from: k)
                mods += String(c[k..<j]) + "\n"
            } else if k + 1 < c.count, c[k] == "/", c[k + 1] == "/" {
                j = k
                while j < c.count, c[j] != "\n" { j += 1 }
            } else {
                break
            }
        }
        out.append(ViewChain(head: String(c[start..<headEnd]), modifiers: mods))
        from = r.upperBound
    }
    return out
}

/// The one view starting with `anchor` whose head contains `containing`.
private func chain(_ anchor: String, containing: String? = nil, in src: String,
                   sourceLocation: SourceLocation = #_sourceLocation) throws -> ViewChain {
    let found = chains(anchor, in: src).filter { containing.map($0.head.contains) ?? true }
    try #require(found.count == 1, "\(found.count) views start with \(anchor)", sourceLocation: sourceLocation)
    return found[0]
}

/// The format specifiers in a translation (`%@`, `%1$@`, `%d`, …; not `%%`).
private func formatSpecifiers(_ s: String) -> [String] {
    let re = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:l{0,2})[@dDiuUxXoOfFeEgGcCsSpaA%]")
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
        .map { String(s[Range($0.range, in: s)!]) }
        .filter { $0 != "%%" }
}

/// A shipped language's generated Localizable.strings (key -> value).
private func shippedStrings(_ lang: String) throws -> [String: String] {
    let url = packageRoot.appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj/Localizable.strings")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(plist as? [String: String], "\(lang).lproj/Localizable.strings")
}

// MARK: the words

struct V0100DownloadSpeedAccessibilityTextTests {
    static let us = Locale(identifier: "en_US")

    @Test func speedIsReadInWords() {
        #expect(AccessibilityText.speed(4_200_000, locale: Self.us) == "4.2 megabytes per second")
        #expect(AccessibilityText.speed(820_000, locale: Self.us) == "820 kilobytes per second")
        #expect(AccessibilityText.speed(1.2e9, locale: Self.us) == "1.2 gigabytes per second")
        // The number is the visible one (the same rounding and unit).
        #expect(AccessibilityText.speed(999_999, locale: Self.us) == "1.0 megabytes per second")
    }

    @Test func percentAndSizeAreReadWithoutBrackets() {
        #expect(AccessibilityText.percent(91) == "91 percent")
        let d = DownloadProgress(name: nil, bytes: 2_100_000_000, total: 2_300_000_000)
        #expect(d.detail == "2.1 of 2.3 GB (91%)")
        #expect(AccessibilityText.downloadSize(d) == ["2.1 of 2.3 GB", "91 percent"])
        let unknown = DownloadProgress(name: nil, bytes: 12_300_000, total: nil)
        #expect(AccessibilityText.downloadSize(unknown) == ["12.3 MB so far"])
    }

    @Test func piecesAreJoinedWithCommas() {
        #expect(AccessibilityText.downloading("font-inter") == "Downloading font-inter")
        #expect(AccessibilityText.joined(["Downloading 10 of 11", "2.1 of 2.3 GB", "91 percent",
                                          "4.2 megabytes per second", "about 1 min left"])
                == "Downloading 10 of 11, 2.1 of 2.3 GB, 91 percent, 4.2 megabytes per second, about 1 min left")
        #expect(!AccessibilityText.joined(["a", "b"]).contains("·"))
    }

    /// Every new word is in the catalog, translated into every shipped
    /// language, and in each shipped Localizable.strings with the same
    /// format specifiers.
    @Test func everyNewStringIsTranslated() throws {
        let cat = try catalog()
        let keys = ["KB/s", "MB/s", "GB/s", "a few seconds left", "about %lld sec left", "about %lld min left",
                    "about %lld hr left", "about %lld hr %lld min left", "Waiting for data…", "Downloading %@",
                    "%@ of %@ %@", "%lld percent", "%@ kilobytes per second", "%@ megabytes per second",
                    "%@ gigabytes per second", "%@ %@"]
        for lang in shippedLanguages {
            let strings = try shippedStrings(lang)
            for key in keys {
                let entry = try #require(cat[key], "\(key) is not in the catalog")
                let value = entry[lang] ?? ""
                #expect(!value.isEmpty, "catalog \(lang): \(key)")
                #expect(formatSpecifiers(value).map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }.sorted()
                        == formatSpecifiers(key).sorted(), "catalog \(lang): \(key) -> \(value)")
                #expect(strings[key] == value, "\(lang).lproj: \(key)")
            }
        }
    }
}

// MARK: the sheet's status line

struct V0100StatusLineAccessibilityTests {
    static func statusText() throws -> String { try source("UpgradeSheet.swift", from: "struct SessionStatusText: View") }

    /// The label and the trait are on the status Text itself, with the
    /// look it had (monospaced digits, one line, cut in the middle) and no
    /// font or color of its own (the row's 12 pt).
    @Test func statusTextIsLabelledAndUpdatesFrequently() throws {
        let src = try Self.statusText()
        let text = try chain("Text(session.statusLine(", in: src)
        #expect(text.head == "Text(session.statusLine(behindBrewUpdate: behindBrewUpdate, at: at))")
        let m = text.modifiers
        #expect(m.contains(".accessibilityLabel(Text(session.statusAccessibilityLabel(behindBrewUpdate: behindBrewUpdate, at: at)))"))
        #expect(m.contains(".accessibilityAddTraits(.updatesFrequently)"))
        #expect(m.contains(".monospacedDigit()") && m.contains(".lineLimit(1)") && m.contains(".truncationMode(.middle)"))
        #expect(!src.contains(".font(") && !src.contains(".foregroundStyle("))
    }

    /// Nothing is announced each second: no posted notifications.
    @Test func noAnnouncements() throws {
        let sheet = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/UpgradeSheet.swift"), encoding: .utf8)
        #expect(!sheet.contains("AccessibilityNotification"))
        #expect(!sheet.contains("NSAccessibility.post"))
        #expect(!sheet.contains("accessibilityLiveRegion"))
    }

    /// The once-a-second redraw is there only while a download runs; the
    /// rest of the time the line is drawn as before, from the session.
    @Test func timelineOnlyWhileDownloading() throws {
        let sheet = try source("UpgradeSheet.swift", from: "struct UpgradeSheet: View")
        // Lines compared without their indentation.
        let flat = sheet.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        #expect(flat.contains([
            "if session.download != nil {",
            "TimelineView(.periodic(from: .now, by: 1)) { context in",
            "SessionStatusText(session: session, behindBrewUpdate: store.sessionWaitsForBrewUpdate, date: context.date)",
            "}",
            "} else {",
            "SessionStatusText(session: session, behindBrewUpdate: store.sessionWaitsForBrewUpdate, date: nil)",
            "}",
        ].joined(separator: "\n")))
        #expect(sheet.components(separatedBy: "SessionStatusText(").count - 1 == 2)
        #expect(!sheet.contains("Text(session.statusLine("))
        let status = try Self.statusText()
        #expect(status.contains("let at = date ?? session.now()"))
    }
}
