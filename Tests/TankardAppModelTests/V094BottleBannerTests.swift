import Foundation
import Testing
@testable import TankardAppModel

// 0.9.4 (PR #8 leftovers): Esc closes the bottle banner, and VoiceOver
// announces it when it appears. The rules are BottleBannerEscape and
// BottleNoticeAnnouncer (checked here); the window's key monitor and the
// announcement are SwiftUI/AppKit, so their wiring is checked in
// ContentView.swift's source, as V093BottleBannerAccessibilityTests does.

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// One declaration's source: from `start` up to the next top-level
/// declaration (or the file's end).
private func source(_ file: String, from start: String) throws -> String {
    let src = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/\(file)"), encoding: .utf8)
    let begin = try #require(src.range(of: start), "\(start) not in \(file)")
    let rest = src[begin.upperBound...]
    let ends = ["\nstruct ", "\nenum ", "\nextension ", "\n// MARK:", "\n@MainActor\n", "\nfinal class ", "\n/// "]
        .compactMap { rest.range(of: $0)?.lowerBound }
    return String(src[begin.lowerBound..<(ends.min() ?? src.endIndex)])
}

// MARK: Esc

struct V094BottleBannerEscapeTests {
    /// A plain Esc in the key main window, nothing in front, no text edited.
    static let plain = BottleBannerEscape.Press(bannerShown: true, keyCode: BottleBannerEscape.escapeKeyCode, hasModifiers: false,
                                                inBannerWindow: true, overlayOpen: false, editingText: false)

    @Test func plainEscapeClosesTheBanner() {
        #expect(BottleBannerEscape.escapeKeyCode == 53)
        #expect(BottleBannerEscape.dismisses(Self.plain))
    }

    @Test func noBannerNoEscape() {
        var p = Self.plain
        p.bannerShown = false
        #expect(!BottleBannerEscape.dismisses(p))
    }

    @Test func otherKeysAndModifiedEscapeAreLeftAlone() {
        for code: UInt16 in [36, 48, 49, 51, 76, 125] { // Return, Tab, Space, Delete, Enter, ↓
            var p = Self.plain
            p.keyCode = code
            #expect(!BottleBannerEscape.dismisses(p), "key \(code)")
        }
        var p = Self.plain
        p.hasModifiers = true
        #expect(!BottleBannerEscape.dismisses(p))
    }

    /// A sheet, an alert or a popover in front keeps Esc (it closes that).
    @Test func sheetAlertOrPopoverInFrontKeepsEscape() {
        var attached = Self.plain
        attached.overlayOpen = true
        #expect(!BottleBannerEscape.dismisses(attached))
        // Its own key window (a sheet, a popover, Settings, the menu-bar panel).
        var elsewhere = Self.plain
        elsewhere.inBannerWindow = false
        #expect(!BottleBannerEscape.dismisses(elsewhere))
    }

    /// The toolbar search field (any text field) keeps Esc: it clears the
    /// search, and with the field empty the banner still stays.
    @Test func textEditingKeepsEscape() {
        var p = Self.plain
        p.editingText = true
        #expect(!BottleBannerEscape.dismisses(p))
    }

    /// Every condition is needed: flipping any one of them leaves Esc alone.
    @Test func eachConditionIsNeeded() {
        let flips: [(inout BottleBannerEscape.Press) -> Void] = [
            { $0.bannerShown = false }, { $0.keyCode = 0 }, { $0.hasModifiers = true },
            { $0.inBannerWindow = false }, { $0.overlayOpen = true }, { $0.editingText = true },
        ]
        for (i, flip) in flips.enumerated() {
            var p = Self.plain
            flip(&p)
            #expect(!BottleBannerEscape.dismisses(p), "condition \(i)")
        }
    }

    /// Esc does what the close button does: the store's dismissBottleNotice.
    @MainActor @Test func escapeIsTheCloseButton() throws {
        let key = try source("ContentView.swift", from: "struct BottleBannerEscapeKey: NSViewRepresentable")
        #expect(key.contains("BottleBannerEscape.dismisses("))
        #expect(key.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(key.contains("NSEvent.removeMonitor("))
        #expect(key.contains("static func dismantleNSView"))
        // What it reads from the window for the rule.
        #expect(key.contains("event.window === w && w.isKeyWindow"))
        #expect(key.contains("w.attachedSheet != nil"))
        #expect(key.contains("NSApp.modalWindow != nil"))
        #expect(key.contains("childWindows"))
        #expect(key.contains("w.firstResponder is NSText"))
        #expect(key.contains("[.command, .control, .option, .shift]"))
        // A handled Esc is taken (nothing else beeps or acts on it).
        #expect(key.contains("return handled ? nil : event"))

        let main = try source("ContentView.swift", from: "private func main(_ theme: Theme) -> some View {")
        #expect(main.contains(".background(BottleBannerEscapeKey(bannerShown: store.bottleNoticeText != nil) { store.dismissBottleNotice() })"))
    }

    /// The monitor isn't in the banner, so the banner's VoiceOver group
    /// (V093BottleBannerAccessibilityTests) has only its own children.
    @Test func monitorIsOutsideTheBannersGroup() throws {
        let banner = try source("ContentView.swift", from: "struct BottleNoticeBanner: View")
        #expect(!banner.contains("BottleBannerEscapeKey"))
        #expect(!banner.contains("announcementRequested"))
    }
}

// MARK: the announcement

struct V094BottleBannerAnnouncementTests {
    static let vim = "vim gains a bottle"
    static let both = "vim and lua gain a bottle"

    @Test func announcesWhenTheBannerAppears() {
        var a = BottleNoticeAnnouncer()
        #expect(a.update(text: nil, names: []) == nil)
        #expect(a.update(text: Self.vim, names: ["vim"]) == Self.vim)
        #expect(a.announced == ["vim"])
    }

    /// A re-render with the same banner says nothing (once per appearance).
    @Test func sameBannerAgainIsSilent() {
        var a = BottleNoticeAnnouncer()
        #expect(a.update(text: Self.vim, names: ["vim"]) == Self.vim)
        for _ in 0..<3 { #expect(a.update(text: Self.vim, names: ["vim"]) == nil) }
    }

    /// A later bottle added to the banner: the new sentence, once.
    @Test func aNewNameIsAnnounced() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(text: Self.vim, names: ["vim"])
        #expect(a.update(text: Self.both, names: ["lua", "vim"]) == Self.both)
        #expect(a.update(text: Self.both, names: ["lua", "vim"]) == nil)
    }

    /// A formula leaving the banner (its replace started) is silent; if it
    /// comes back, that's news again.
    @Test func aNameLeavingIsSilent() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(text: Self.both, names: ["lua", "vim"])
        #expect(a.update(text: Self.vim, names: ["vim"]) == nil)
        #expect(a.update(text: Self.both, names: ["lua", "vim"]) == Self.both)
    }

    /// Closed (button, Esc) or emptied: the next banner is announced, even
    /// with the same words.
    @Test func eachAppearanceIsAnnounced() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(text: Self.vim, names: ["vim"])
        #expect(a.update(text: nil, names: []) == nil)
        #expect(a.announced.isEmpty)
        #expect(a.update(text: Self.vim, names: ["vim"]) == Self.vim)
        // Text without names (can't happen: no names, no text) is no banner.
        #expect(a.update(text: Self.vim, names: []) == nil)
        #expect(a.announced.isEmpty)
    }

    /// The window follows bottleNoticeText (not every render) and posts
    /// what the announcer returns, as an announcement VoiceOver speaks.
    @MainActor @Test func windowAnnouncesThroughTheAnnouncer() throws {
        let main = try source("ContentView.swift", from: "private func main(_ theme: Theme) -> some View {")
        #expect(main.contains(".onChange(of: store.bottleNoticeText, initial: true) { _, text in announceBottleNotice(text) }"))

        let content = try source("ContentView.swift", from: "struct ContentView: View")
        #expect(content.contains("@State private var bottleAnnouncer = BottleNoticeAnnouncer()"))

        let announce = try source("ContentView.swift", from: "private func announceBottleNotice(_ text: String?)")
        #expect(announce.contains("bottleAnnouncer.update(text: text, names: store.bottleNoticePackages.map(\\.name))"))
        #expect(announce.contains("BottleNoticeAnnouncement.post("))

        let post = try source("ContentView.swift", from: "enum BottleNoticeAnnouncement")
        #expect(post.contains("notification: .announcementRequested"))
        #expect(post.contains(".announcement: text"))
        #expect(post.contains(".priority: NSAccessibilityPriorityLevel.medium.rawValue"))
    }
}
