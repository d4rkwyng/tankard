import Foundation
import Testing
@testable import TankardAppModel

// 0.9.3: the accessibility and localization pass over the main window, the
// bottle notice (window banner and menu-bar notice), the menu-bar menu and
// Settings. The words live in AccessibilityText (checked here); a SwiftUI
// view can't be inspected from this target, so the wiring is checked in
// the views' source, as V085KeepOldVersionsBannerToneTests does.

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

struct V093AccessibilityTextTests {
    /// The banner's Show and the menu-bar notice say where they go.
    @Test func showBottleAvailableHintNamesTheList() {
        #expect(AccessibilityText.showBottleAvailableHint == "Shows the Bottle available list")
    }

    /// Replace with Bottle's hint is the Bottle available list's Replace
    /// all tooltip, word for word (no new wording).
    @Test func replaceWithBottleHintIsReplaceAllsHelp() throws {
        #expect(AccessibilityText.replaceWithBottleHint == "Reinstall each one from a ready-made download instead of building it")
        let filterActions = try source("ContentView.swift", from: "struct FilterActions: View")
        #expect(filterActions.contains(".help(\"\(AccessibilityText.replaceWithBottleHint)\")"))
    }

    /// The vulnerability notice's hint is the panel's scan-line label.
    @Test func showVulnerableHintIsThePanelsLinkLabel() throws {
        #expect(AccessibilityText.showVulnerableHint == "Show vulnerable packages in Tankard")
        let panel = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/MenuBarExtra.swift"), encoding: .utf8)
        #expect(panel.contains("String(localized: \"\(AccessibilityText.showVulnerableHint)\")"))
    }

    /// The Available column's arrow and version: the tooltip's words.
    @Test func upgradeAvailableReadsLikeTheTooltip() {
        #expect(AccessibilityText.upgradeAvailable("2.1.0") == "Upgrade available: 2.1.0")
    }

    /// The toolbar spinner: the refresh's phase, else "Refreshing".
    @Test func refreshingUsesThePhase() {
        #expect(AccessibilityText.refreshing(phase: nil) == "Refreshing")
        #expect(AccessibilityText.refreshing(phase: "Reading installed packages…") == "Reading installed packages…")
    }

    @Test func identifiersAreDistinctAndNotEmpty() {
        let ids = [AccessibilityText.ID.bottleNotice, AccessibilityText.ID.bottleNoticeShow, AccessibilityText.ID.bottleNoticeReplace,
                   AccessibilityText.ID.bottleNoticeClose, AccessibilityText.ID.bottleMenuNotice,
                   AccessibilityText.ID.vulnerabilityMenuNotice, AccessibilityText.ID.refreshProgress]
        #expect(ids.allSatisfy { !$0.isEmpty })
        #expect(Set(ids).count == ids.count)
    }

    /// Every word VoiceOver gets from AccessibilityText is in the catalog,
    /// translated into every shipped language.
    @Test func everyAccessibilityStringIsTranslated() throws {
        let cat = try catalog()
        let keys = [AccessibilityText.showBottleAvailableHint, AccessibilityText.replaceWithBottleHint,
                    AccessibilityText.showVulnerableHint, "Upgrade available: %@", "Refreshing", "Hide this message"]
        for key in keys {
            let entry = try #require(cat[key], "\(key) is not in the catalog")
            for lang in shippedLanguages {
                #expect(!(entry[lang] ?? "").isEmpty, "\(lang): \(key)")
            }
        }
    }
}

// MARK: the window's bottle banner

struct V093BottleBannerAccessibilityTests {
    static func banner() throws -> String { try source("ContentView.swift", from: "struct BottleNoticeBanner: View") }

    /// The shipping box is decoration.
    @Test func iconIsHidden() throws {
        let b = try Self.banner()
        let icon = try #require(b.range(of: "Image(systemName: \"shippingbox\")"))
        let text = try #require(b.range(of: "Text(text)"))
        #expect(b[icon.upperBound..<text.lowerBound].contains(".accessibilityHidden(true)"))
    }

    /// Show and Replace with Bottle keep their visible names (Voice
    /// Control) and get hints; the close button keeps its label. Each on
    /// its own button's modifiers (swapping them would mislead VoiceOver).
    @Test func buttonsHaveNamesHintsAndIdentifiers() throws {
        let b = try Self.banner()
        let showHint = ".accessibilityHint(Text(AccessibilityText.showBottleAvailableHint))"
        let replaceHint = ".accessibilityHint(Text(AccessibilityText.replaceWithBottleHint))"
        let id = { (name: String) in ".accessibilityIdentifier(AccessibilityText.ID.\(name))" }

        let show = try chain("Button(\"Show\")", in: b).modifiers
        #expect(show.contains(showHint))
        #expect(show.contains(id("bottleNoticeShow")))
        #expect(!show.contains(replaceHint))
        #expect(!show.contains("accessibilityLabel"))

        let replace = try chain("Button(\"Replace with Bottle\")", in: b).modifiers
        #expect(replace.contains(replaceHint))
        #expect(replace.contains(id("bottleNoticeReplace")))
        #expect(!replace.contains(showHint))
        #expect(!replace.contains("accessibilityLabel"))

        let close = try chain("Button {", containing: "store.dismissBottleNotice()", in: b).modifiers
        #expect(close.contains(".accessibilityLabel(Text(\"Hide this message\"))"))
        #expect(close.contains(id("bottleNoticeClose")))
        #expect(!close.contains("accessibilityHint"))

        let banner = try chain("HStack(alignment: .center, spacing: 10) {", in: b).modifiers
        #expect(banner.contains(id("bottleNotice")))
    }

    /// One group for VoiceOver, its children in reading order: the
    /// sentence, Show, Replace with Bottle, close (also Tab's order). The
    /// group is the banner's own HStack, not one of its children.
    @Test func groupedInReadingOrder() throws {
        let b = try Self.banner()
        let banner = try chain("HStack(alignment: .center, spacing: 10) {", in: b)
        #expect(b.contains("var body: some View {\n        HStack(alignment: .center, spacing: 10) {"))
        #expect(banner.modifiers.contains(".accessibilityElement(children: .contain)"))
        #expect(!banner.head.contains(".accessibilityElement("))
        let order = ["Text(text)", "Button(\"Show\")", "Button(\"Replace with Bottle\")", "store.dismissBottleNotice()"]
        let positions = try order.map { try #require(b.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
    }
}

// MARK: the menu-bar menu

struct V093MenuBarAccessibilityTests {
    /// The bottle notice is named by its sentence, not "Shipping box, …, Show".
    /// On the notice's button itself (not the Divider above it).
    @Test func bottleMenuNoticeIsNamedBySentence() throws {
        let n = try source("InsightsViews.swift", from: "struct BottleMenuNotice: View")
        let button = try chain("Button {", containing: "store.showBottleAvailable()", in: n).modifiers
        #expect(button.contains(".accessibilityLabel(Text(text))"))
        #expect(button.contains(".accessibilityHint(Text(AccessibilityText.showBottleAvailableHint))"))
        #expect(button.contains(".accessibilityIdentifier(AccessibilityText.ID.bottleMenuNotice)"))
        #expect(try chain("Divider()", in: n).modifiers.isEmpty)
    }

    /// The vulnerability notice: icon and trailing "Show" hidden, a hint.
    @Test func vulnerabilityMenuNoticeHidesIconAndShow() throws {
        let n = try source("InsightsViews.swift", from: "struct VulnerabilityMenuNotice: View")
        #expect(try chain("Image(systemName: \"exclamationmark.triangle.fill\")", in: n).whole.contains(".accessibilityHidden(true)"))
        #expect(try chain("Text(\"Show\")", in: n).whole.contains(".accessibilityHidden(true)"))
        // The title and the names stay readable.
        #expect(!(try chain("Text(\"New vulnerabilities\")", in: n).whole.contains("accessibilityHidden")))
        let button = try chain("Button {", containing: "store.showVulnerable()", in: n).modifiers
        #expect(button.contains(".accessibilityHint(Text(AccessibilityText.showVulnerableHint))"))
        #expect(button.contains(".accessibilityIdentifier(AccessibilityText.ID.vulnerabilityMenuNotice)"))
        #expect(try chain("Divider()", in: n).modifiers.isEmpty)
    }

    /// The panel's menu rows (Upgrade All, Check Now, Open Tankard, Quit):
    /// the icon isn't part of the name.
    @Test func menuRowIconIsHidden() throws {
        let row = try source("MenuBarExtra.swift", from: "struct MenuRow: View")
        #expect(row.contains("Image(systemName: systemImage).frame(width: 16).accessibilityHidden(true)"))
    }

    /// The Auto-update line's icons are decoration; the status and the
    /// version beside them are not.
    @Test func autoUpdateMenuLineIconsAreHidden() throws {
        let line = try source("AutoUpdateViews.swift", from: "struct AutoUpdateMenuLine: View")
        for icon in ["Image(systemName: updater.isRunning ? \"arrow.triangle.2.circlepath\" : \"clock.arrow.circlepath\")",
                     "Image(systemName: \"arrow.down.circle\")"] {
            #expect(try chain(icon, in: line).whole.contains(".accessibilityHidden(true)"), "\(icon)")
        }
        for text in ["Text(line)", "Text(selfUpdate)"] {
            #expect(!(try chain(text, in: line).whole.contains("accessibilityHidden")), "\(text)")
        }
    }
}

// MARK: the main window

struct V093MainWindowAccessibilityTests {
    /// The Available column's upgrade arrow and version: one element named
    /// like its tooltip.
    /// The modifiers sit on the upgrading branch's HStack (arrow and
    /// version together), not on the arrow alone or the unchanged branch.
    @Test func availableCellIsOneNamedElement() throws {
        let cell = try source("ContentView.swift", from: "struct AvailableCell: View")
        let upgrading = try #require(cell.range(of: "if package.upgradeAvailable {"))
        let otherwise = try #require(cell.range(of: "} else {", range: upgrading.upperBound..<cell.endIndex))
        let branch = String(cell[upgrading.upperBound..<otherwise.lowerBound])
        let stack = try chain("HStack(spacing: 3) {", in: branch)
        #expect(stack.head.contains("Image(systemName: \"arrow.up\")"))
        #expect(stack.head.contains("Text(v)"))
        #expect(!stack.head.contains("accessibility"))
        #expect(stack.modifiers.contains(".help(\"Upgrade available: \\(v)\")"))
        #expect(stack.modifiers.contains(".accessibilityElement(children: .ignore)"))
        #expect(stack.modifiers.contains(".accessibilityLabel(Text(AccessibilityText.upgradeAvailable(v)))"))
        // An unchanged package says nothing about an upgrade.
        #expect(!cell[otherwise.upperBound...].contains("accessibility"))
    }

    /// The toolbar's spinner while refreshing has a name (on the spinner,
    /// not the idle Refresh button, which is named by its Label).
    @Test func refreshSpinnerIsNamed() throws {
        let view = try source("ContentView.swift", from: "struct ContentView: View")
        let spinner = try chain("ProgressView().controlSize(.small)", in: view).modifiers
        #expect(spinner.contains(".accessibilityLabel(Text(AccessibilityText.refreshing(phase: store.refreshPhase)))"))
        #expect(spinner.contains(".accessibilityIdentifier(AccessibilityText.ID.refreshProgress)"))
        let refresh = try chain("Button {", containing: "store.refreshFromUser", in: view).modifiers
        #expect(!refresh.contains("accessibility"))
    }

    /// The status bar's "·" separators and the busy notice's hourglass are
    /// for the eye only.
    @Test func statusBarDecorationIsHidden() throws {
        let bar = try source("StatusBar.swift", from: "struct StatusBar: View")
        #expect(bar.contains("Text(verbatim: \"·\").foregroundStyle(.tertiary).accessibilityHidden(true)"))
        let hourglass = try #require(bar.range(of: "Image(systemName: \"hourglass\")"))
        #expect(bar[hourglass.upperBound...].prefix(120).contains(".accessibilityHidden(true)"))
        // 0.8.8 (B7): the Upgrade button's icons stay hidden.
        #expect(bar.contains("Image(systemName: \"checkmark\").accessibilityHidden(true)"))
        #expect(bar.contains("Image(systemName: \"arrow.up\").accessibilityHidden(true)"))
    }
}

// MARK: Settings

struct V093SettingsLocalizationTests {
    /// Settings ▸ Upgrades' last scan line was English in every language
    /// ("Vulnerabilities: " joined to the line). It is a catalog key now.
    @Test func lastScanLineIsLocalized() throws {
        let settings = try source("InsightsViews.swift", from: "struct UpgradeSettings: View")
        #expect(!settings.contains("Text(\"Vulnerabilities: \" +"))
        #expect(settings.contains("Text(\"Vulnerabilities: \\(VulnerabilityText.scanLine(scan))\")"))
        // The view passes one argument: every translation takes exactly one
        // object, in the catalog and in each shipped Localizable.strings.
        let takesOne = { (value: String?) in
            guard let value else { return false }
            let specs = formatSpecifiers(value)
            return specs.count == 1 && specs[0].hasSuffix("@")
        }
        let entry = try #require(try catalog()["Vulnerabilities: %@"])
        for lang in shippedLanguages {
            #expect(takesOne(entry[lang]), "catalog \(lang): \(entry[lang] ?? "missing")")
        }
        let hint = AccessibilityText.showBottleAvailableHint
        for lang in ["en"] + shippedLanguages {
            let strings = try shippedStrings(lang)
            #expect(takesOne(strings["Vulnerabilities: %@"]), "\(lang).lproj: \(strings["Vulnerabilities: %@"] ?? "missing")")
            #expect(!(strings[hint] ?? "").isEmpty, "\(lang).lproj: \(hint) missing")
            #expect(formatSpecifiers(strings[hint] ?? "").isEmpty, "\(lang).lproj: \(hint)")
            if lang == "en" {
                #expect(strings["Vulnerabilities: %@"] == "Vulnerabilities: %@")
                #expect(strings[hint] == hint)
            }
        }
    }

    /// 0.8.9's "Check every" fix stays: the picker has no label of its own
    /// and the visible text is hidden, so VoiceOver says it once.
    @Test func checkEveryIsReadOnce() throws {
        let general = try source("SettingsView.swift", from: "struct GeneralSettings: View")
        #expect(general.contains("Text(\"Check every\").accessibilityHidden(true)"))
        #expect(general.contains(".accessibilityLabel(Text(\"Check every\"))"))
        #expect(general.contains("} label: { EmptyView() }"))
    }
}
