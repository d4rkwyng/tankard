import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4: VoiceOver and the string catalog for the sheet's download speed.
// The spoken words live in AccessibilityText (checked here); the view's
// wiring is checked in its source, as V093AccessibilityTests does (the
// helpers below are that file's, which keeps them private).
//
// The source-text tests verify wiring only: that the label, the trait and
// no announcement are in the view's code. What VoiceOver actually reads
// and announces is checked by hand with VoiceOver, not here.

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
        // A plural entry: its "other" form (what Localizable.strings gets).
        out[key] = locs.compactMapValues {
            ($0["stringUnit"] as? [String: Any])?["value"] as? String ?? pluralForms($0)["other"]
        }
    }
    return out
}

/// A localization's plural forms (category -> value), empty without any.
private func pluralForms(_ loc: [String: Any]) -> [String: String] {
    let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] ?? [:]
    return plural.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
}

/// The catalog's plural forms of `key`: lang -> category -> value.
private func catalogPlurals(_ key: String) throws -> [String: [String: String]] {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Resources/Localizable.xcstrings"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(json["strings"] as? [String: [String: Any]])
    let entry = try #require(strings[key], "\(key) is not in the catalog")
    let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
    return locs.compactMapValues { let f = pluralForms($0); return f.isEmpty ? nil : f }
}

/// `key` formatted with `args` from a shipped language's compiled tables
/// (Localizable.stringsdict first, as the app reads them).
private func compiled(_ key: String, _ lang: String, _ args: CVarArg...) throws -> String {
    let dir = packageRoot.appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj")
    let bundle = try #require(Bundle(path: dir.path))
    let format = bundle.localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, locale: Locale(identifier: lang), arguments: args)
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

struct DownloadSpeedAccessibilityTextTests {
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
                    "%@ gigabytes per second", "%@ %@",
                    // 0.9.4 (review): the spoken time left (plural; the .strings get the "other" form).
                    "about %lld seconds left", "about %lld minutes left", "about %lld hours left",
                    "about %lld hours and %@ left", "%lld minutes"]
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

// MARK: round 1 review (Sol): the time left agrees with its number

struct TimeLeftPluralTests {
    /// The visible time left ("about 1 min left") and the spoken one
    /// ("about 1 minute left").
    static let visible = ["about %lld sec left", "about %lld min left", "about %lld hr left", "about %lld hr %lld min left"]
    static let spoken = ["about %lld seconds left", "about %lld minutes left", "about %lld hours left",
                         "about %lld hours and %@ left", "%lld minutes"]
    /// Languages whose plural rules have a "one" (ja, zh-Hans and ko have only "other").
    static let withOne: Set<String> = ["en", "de", "fr", "es", "pt-BR", "it"]

    /// Every time-left key has plural variations in English and every
    /// shipped language, with the same format specifiers in every form.
    @Test func timeLeftKeysHavePluralForms() throws {
        for key in Self.visible + Self.spoken {
            let plurals = try catalogPlurals(key)
            for lang in ["en"] + shippedLanguages {
                let forms = try #require(plurals[lang], "\(lang): \(key) has no plural forms")
                #expect(forms["other"] != nil, "\(lang): \(key) has no other form")
                if Self.withOne.contains(lang) { #expect(forms["one"] != nil, "\(lang): \(key) has no one form") }
                for (cat, value) in forms {
                    #expect(formatSpecifiers(value).map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }.sorted()
                            == formatSpecifiers(key).sorted(), "\(lang) \(cat): \(key) -> \(value)")
                }
            }
        }
    }

    /// One minute reads in the singular where the language agrees with
    /// the number (Sol: "quedan unos 1 min", "faltam cerca de 1 min",
    /// "environ 1 min restantes", "circa 1 min rimanenti").
    @Test func oneMinuteIsSingular() throws {
        let one: [(String, String)] = [
            ("es", "queda alrededor de 1 min"), ("pt-BR", "falta cerca de 1 min"),
            ("fr", "environ 1 min restante"), ("it", "circa 1 min rimanente"),
            ("en", "about 1 min left"), ("de", "noch etwa 1 Min."),
        ]
        for (lang, text) in one {
            #expect(try compiled("about %lld min left", lang, 1) == text, "\(lang)")
        }
        let many: [(String, String)] = [
            ("es", "quedan unos 12 min"), ("pt-BR", "faltam cerca de 12 min"),
            ("fr", "environ 12 min restantes"), ("it", "circa 12 min rimanenti"),
        ]
        for (lang, text) in many {
            #expect(try compiled("about %lld min left", lang, 12) == text, "\(lang)")
        }
        #expect(try compiled("about %lld hr %lld min left", "es", 1, 5) == "queda alrededor de 1 h 5 min")
        #expect(try compiled("about %lld hr %lld min left", "es", 2, 5) == "quedan unas 2 h 5 min")
    }

    /// What the status line's label says for a time left (English, the
    /// test process's table): full unit names, singular for 1.
    @Test func spokenTimeLeftFromTheSeconds() {
        #expect(AccessibilityText.timeLeft(3) == "a few seconds left")
        #expect(AccessibilityText.timeLeft(20) == "about 20 seconds left")
        #expect(AccessibilityText.timeLeft(60) == "about 1 minute left")
        #expect(AccessibilityText.timeLeft(74) == "about 1 minute left")
        #expect(AccessibilityText.timeLeft(720) == "about 12 minutes left")
        #expect(AccessibilityText.timeLeft(3599) == "about 1 hour left")
        #expect(AccessibilityText.timeLeft(3660) == "about 1 hour and 1 minute left")
        #expect(AccessibilityText.timeLeft(3900) == "about 1 hour and 5 minutes left")
        #expect(AccessibilityText.timeLeft(7200) == "about 2 hours left")
        // The visible line keeps its short units.
        #expect(DownloadSpeedFormat.timeLeftText(60) == "about 1 min left")
    }

    /// VoiceOver hears the units in full, singular for 1.
    @Test func spokenTimeLeftInFullWords() throws {
        #expect(try compiled("about %lld minutes left", "en", 1) == "about 1 minute left")
        #expect(try compiled("about %lld minutes left", "en", 12) == "about 12 minutes left")
        #expect(try compiled("about %lld seconds left", "en", 20) == "about 20 seconds left")
        #expect(try compiled("about %lld hours left", "en", 1) == "about 1 hour left")
        #expect(try compiled("about %lld hours and %@ left", "en", 1, "5 minutes") == "about 1 hour and 5 minutes left")
        #expect(try compiled("%lld minutes", "en", 1) == "1 minute")
        #expect(try compiled("about %lld minutes left", "es", 1) == "queda alrededor de 1 minuto")
        #expect(try compiled("about %lld minutes left", "de", 1) == "noch etwa 1 Minute")
    }
}

// MARK: the sheet's status line

struct StatusLineAccessibilityTests {
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
            "SessionStatusText(session: session, behindBrewUpdate: store.sessionWaitsForBrewUpdate, tick: context.date)",
            "}",
            "} else {",
            "SessionStatusText(session: session, behindBrewUpdate: store.sessionWaitsForBrewUpdate, tick: nil)",
            "}",
        ].joined(separator: "\n")))
        #expect(sheet.components(separatedBy: "SessionStatusText(").count - 1 == 2)
        #expect(!sheet.contains("Text(session.statusLine("))
    }

    /// 0.9.4 (review): one time per render, the session's clock, for both
    /// the visible line and the label; the timeline's date only triggers
    /// the redraw and is never read as the time.
    @Test func oneTimePerRender() throws {
        let status = try Self.statusText()
        #expect(status.components(separatedBy: "session.now()").count - 1 == 1)
        #expect(status.contains("let at = session.now()"))
        #expect(status.components(separatedBy: "at: at").count - 1 == 2)
        #expect(!status.contains("tick ??") && !status.contains("at: tick") && !status.contains("context.date"))
    }
}
