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
    /// Control) and get hints; the close button keeps its label.
    @Test func buttonsHaveNamesHintsAndIdentifiers() throws {
        let b = try Self.banner()
        #expect(b.contains("Button(\"Show\")"))
        #expect(b.contains("Button(\"Replace with Bottle\")"))
        #expect(b.contains(".accessibilityHint(Text(AccessibilityText.showBottleAvailableHint))"))
        #expect(b.contains(".accessibilityHint(Text(AccessibilityText.replaceWithBottleHint))"))
        #expect(b.contains(".accessibilityLabel(Text(\"Hide this message\"))"))
        for id in ["bottleNotice", "bottleNoticeShow", "bottleNoticeReplace", "bottleNoticeClose"] {
            #expect(b.contains(".accessibilityIdentifier(AccessibilityText.ID.\(id))"), "\(id)")
        }
    }

    /// One group for VoiceOver, its children in reading order: the
    /// sentence, Show, Replace with Bottle, close (also Tab's order).
    @Test func groupedInReadingOrder() throws {
        let b = try Self.banner()
        #expect(b.contains(".accessibilityElement(children: .contain)"))
        let order = ["Text(text)", "Button(\"Show\")", "Button(\"Replace with Bottle\")", "store.dismissBottleNotice()"]
        let positions = try order.map { try #require(b.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
    }
}

// MARK: the menu-bar menu

struct V093MenuBarAccessibilityTests {
    /// The bottle notice is named by its sentence, not "Shipping box, …, Show".
    @Test func bottleMenuNoticeIsNamedBySentence() throws {
        let n = try source("InsightsViews.swift", from: "struct BottleMenuNotice: View")
        #expect(n.contains(".accessibilityLabel(Text(text))"))
        #expect(n.contains(".accessibilityHint(Text(AccessibilityText.showBottleAvailableHint))"))
        #expect(n.contains(".accessibilityIdentifier(AccessibilityText.ID.bottleMenuNotice)"))
    }

    /// The vulnerability notice: icon and trailing "Show" hidden, a hint.
    @Test func vulnerabilityMenuNoticeHidesIconAndShow() throws {
        let n = try source("InsightsViews.swift", from: "struct VulnerabilityMenuNotice: View")
        let icon = try #require(n.range(of: "Image(systemName: \"exclamationmark.triangle.fill\")"))
        #expect(n[icon.upperBound...].prefix(120).contains(".accessibilityHidden(true)"))
        let show = try #require(n.range(of: "Text(\"Show\")"))
        #expect(n[show.upperBound...].prefix(160).contains(".accessibilityHidden(true)"))
        #expect(n.contains(".accessibilityHint(Text(AccessibilityText.showVulnerableHint))"))
    }

    /// The panel's menu rows (Upgrade All, Check Now, Open Tankard, Quit):
    /// the icon isn't part of the name.
    @Test func menuRowIconIsHidden() throws {
        let row = try source("MenuBarExtra.swift", from: "struct MenuRow: View")
        #expect(row.contains("Image(systemName: systemImage).frame(width: 16).accessibilityHidden(true)"))
    }

    /// The Auto-update line's icons are decoration.
    @Test func autoUpdateMenuLineIconsAreHidden() throws {
        let line = try source("AutoUpdateViews.swift", from: "struct AutoUpdateMenuLine: View")
        for symbol in ["\"clock.arrow.circlepath\")", "Image(systemName: \"arrow.down.circle\")"] {
            let at = try #require(line.range(of: symbol), "\(symbol)")
            #expect(line[at.upperBound...].prefix(220).contains(".accessibilityHidden(true)"), "\(symbol)")
        }
    }
}

// MARK: the main window

struct V093MainWindowAccessibilityTests {
    /// The Available column's upgrade arrow and version: one element named
    /// like its tooltip.
    @Test func availableCellIsOneNamedElement() throws {
        let cell = try source("ContentView.swift", from: "struct AvailableCell: View")
        #expect(cell.contains(".help(\"Upgrade available: \\(v)\")"))
        #expect(cell.contains(".accessibilityElement(children: .ignore)"))
        #expect(cell.contains(".accessibilityLabel(Text(AccessibilityText.upgradeAvailable(v)))"))
    }

    /// The toolbar's spinner while refreshing has a name.
    @Test func refreshSpinnerIsNamed() throws {
        let view = try source("ContentView.swift", from: "struct ContentView: View")
        #expect(view.contains(".accessibilityLabel(Text(AccessibilityText.refreshing(phase: store.refreshPhase)))"))
        #expect(view.contains(".accessibilityIdentifier(AccessibilityText.ID.refreshProgress)"))
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
        let entry = try #require(try catalog()["Vulnerabilities: %@"])
        for lang in shippedLanguages {
            #expect((entry[lang] ?? "").contains("%@"), "\(lang)")
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
