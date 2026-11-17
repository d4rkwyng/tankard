import Foundation
import Testing

// 0.7: the string catalog (Resources/Localizable.xcstrings) and the
// Localizable.strings files Scripts/l10n.py compiles from it.

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The languages Tankard ships besides English. Keep in step with LANGS in Scripts/l10n.py.
private let shippedLanguages = ["de", "fr", "es", "ja", "zh-Hans", "pt-BR", "it", "ko"]

private struct CatalogEntry {
    let key: String
    let translations: [String: String]
}

private func loadCatalog() throws -> [CatalogEntry] {
    let data = try Data(contentsOf: packageRoot.appendingPathComponent("Resources/Localizable.xcstrings"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["sourceLanguage"] as? String == "en")
    let strings = try #require(json["strings"] as? [String: [String: Any]])
    return strings.compactMap { key, entry in
        if entry["extractionState"] as? String == "stale" { return nil }
        let locs = entry["localizations"] as? [String: [String: Any]] ?? [:]
        var out: [String: String] = [:]
        for (lang, loc) in locs {
            if let unit = loc["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                out[lang] = value
            }
        }
        return CatalogEntry(key: key, translations: out)
    }
}

/// %@, %lld, %1$@ … in s, with positions dropped so reordering is allowed.
private func formatSpecifiers(_ s: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|t|j|L|q)?[@dDiuUxXoOfeEgGcCsSpaA]"#)
    let text = s.replacingOccurrences(of: "%%", with: "")
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
        ns.substring(with: $0.range).replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression)
    }.sorted()
}

struct LocalizationCatalogTests {
    @Test func catalogIsNotEmpty() throws {
        #expect(try loadCatalog().count > 300)
    }

    @Test func everyKeyHasEveryShippedLanguage() throws {
        var missing: [String] = []
        for entry in try loadCatalog() {
            for lang in shippedLanguages {
                let value = entry.translations[lang] ?? ""
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !entry.key.trimmingCharacters(in: .whitespaces).isEmpty {
                    missing.append("\(lang): \(entry.key)")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count) missing translations, e.g. \(missing.prefix(10))")
    }

    /// A translation that reorders arguments must say so with positions
    /// (%2$@ … %1$lld): read in the source's order, a swapped %lld and %@
    /// would misformat or crash.
    @Test func reorderedArgumentsArePositional() throws {
        let regex = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|z|t|j|L|q)?[@dDiuUxXoOfeEgGcCsSpaA]"#)
        func specs(_ s: String) -> [String] {
            let t = s.replacingOccurrences(of: "%%", with: "") as NSString
            return regex.matches(in: t as String, range: NSRange(location: 0, length: t.length)).map { t.substring(with: $0.range) }
        }
        var bad: [String] = []
        for entry in try loadCatalog() {
            let source = specs(entry.key)
            for (lang, value) in entry.translations {
                let got = specs(value)
                if got.contains(where: { $0.contains("$") }) {
                    for spec in got {
                        guard let m = spec.firstMatch(of: /^%(\d+)\$/), let i = Int(m.1), i >= 1, i <= source.count,
                              spec.replacing(/^%\d+\$/, with: "%") == source[i - 1] else {
                            bad.append("\(lang): \(entry.key) -> \(value)"); break
                        }
                    }
                } else if got != source {
                    bad.append("\(lang): \(entry.key) -> \(value)")
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.prefix(10))")
    }

    @Test func translationsKeepTheFormatSpecifiers() throws {
        var bad: [String] = []
        for entry in try loadCatalog() {
            let want = formatSpecifiers(entry.key)
            for (lang, value) in entry.translations where formatSpecifiers(value) != want {
                bad.append("\(lang): \(entry.key) -> \(value)")
            }
        }
        #expect(bad.isEmpty, "\(bad.prefix(10))")
    }

    /// The compiled .strings files are what the app loads; they must match the catalog.
    @Test func compiledStringsMatchTheCatalog() throws {
        let catalog = try loadCatalog()
        for lang in ["en"] + shippedLanguages {
            let url = packageRoot.appendingPathComponent("Sources/TankardApp/Resources/Localizations/\(lang).lproj/Localizable.strings")
            let dict = try #require(NSDictionary(contentsOf: url) as? [String: String], "unreadable \(lang).lproj")
            #expect(dict.count == catalog.count, "\(lang): \(dict.count) strings, catalog has \(catalog.count); run Scripts/l10n.py compile")
            for entry in catalog {
                let want = lang == "en" ? entry.key : entry.translations[lang]
                if dict[entry.key] != want {
                    Issue.record("\(lang): \(entry.key) is stale; run Scripts/l10n.py compile")
                    break
                }
            }
        }
    }

    /// Brew command text stays untranslated: no key is a bare command
    /// ("brew config", "brew deps --tree --installed %@"). Sentences that
    /// start with "brew" are fine.
    @Test func noBrewCommandsInTheCatalog() throws {
        let command = try NSRegularExpression(pattern: #"^brew [a-z-]+( --?[a-z-]+| %@)*$"#)
        let commands = try loadCatalog().map(\.key).filter {
            command.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
        }
        #expect(commands.isEmpty, "\(commands)")
    }
}
