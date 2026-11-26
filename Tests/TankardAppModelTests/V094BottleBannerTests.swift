import AppKit
import Foundation
import Testing
@testable import TankardAppModel
@testable import TankardCore

// 0.9.4 (PR #8 leftovers): Esc closes the bottle banner, and VoiceOver
// announces it when it appears. The rules are BottleBannerEscape and
// BottleNoticeAnnouncer; the key monitor (BottleBannerEscapeMonitor) and
// the announcement (BottleNoticeAnnouncementCoordinator) are driven here
// with real NSEvents and a real NSWindow, their AppKit hooks (installing
// the monitor, posting to VoiceOver) swapped for recorders.

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

    /// The monitor isn't in the banner, so the banner's VoiceOver group
    /// (V093BottleBannerAccessibilityTests) has only its own children.
    @Test func monitorIsOutsideTheBannersGroup() throws {
        let banner = try source("ContentView.swift", from: "struct BottleNoticeBanner: View")
        #expect(!banner.contains("BottleBannerEscapeKey"))
        #expect(!banner.contains("announcementRequested"))
    }
}

// MARK: the Esc monitor (behavior)

/// A key-down event as AppKit delivers it (no window: the tests give the
/// window's side through `readWindow`).
@MainActor
private func keyDown(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    let ch = code == BottleBannerEscape.escapeKeyCode ? "\u{1b}" : "a"
    return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: ch,
                                         charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code))
}

/// A BottleBannerEscapeMonitor whose monitor is recorded, not installed.
@MainActor
private final class EscapeRig {
    var handlers: [@MainActor (NSEvent) -> NSEvent?] = []
    var removed: [Int] = []
    var dismissed = 0
    var window: BottleBannerEscapeMonitor.WindowState? = .init(inBannerWindow: true, overlayOpen: false, editingText: false)
    let monitor: BottleBannerEscapeMonitor

    init(bannerShown: Bool = true) {
        var install: BottleBannerEscapeMonitor.Install = { _ in nil }
        var remove: @MainActor (Any) -> Void = { _ in }
        monitor = BottleBannerEscapeMonitor(install: { install($0) }, remove: { remove($0) })
        install = { [unowned self] h in self.handlers.append(h); return self.handlers.count }
        remove = { [unowned self] token in self.removed.append(token as! Int) }
        monitor.bannerShown = bannerShown
        monitor.dismiss = { [unowned self] in self.dismissed += 1 }
        monitor.readWindow = { [unowned self] _, _ in self.window }
    }
}

@MainActor
struct V094BottleBannerEscapeMonitorTests {
    /// A plain Esc through the installed monitor closes the banner and is
    /// taken (nil: nothing else sees it, nothing beeps).
    @Test func escapeIsTakenAndDismisses() throws {
        let rig = EscapeRig()
        rig.monitor.attach()
        #expect(rig.handlers.count == 1)
        #expect(rig.monitor.monitor != nil)
        #expect(rig.handlers[0](try keyDown(53)) == nil)
        #expect(rig.dismissed == 1)
        #expect(rig.monitor.handle(try keyDown(53)) == nil)
        #expect(rig.dismissed == 2)
    }

    /// Anything the rule doesn't give the banner goes on untouched, and the
    /// banner stays.
    @Test func otherPressesPassThrough() throws {
        let rig = EscapeRig()
        rig.monitor.attach()
        let other = try keyDown(36)
        #expect(rig.handlers[0](other) === other)
        let shifted = try keyDown(53, .shift)
        #expect(rig.monitor.handle(shifted) === shifted)
        let commanded = try keyDown(53, .command)
        #expect(rig.monitor.handle(commanded) === commanded)

        rig.window = .init(inBannerWindow: true, overlayOpen: true, editingText: false)
        let overlay = try keyDown(53)
        #expect(rig.monitor.handle(overlay) === overlay)
        rig.window = .init(inBannerWindow: true, overlayOpen: false, editingText: true)
        let editing = try keyDown(53)
        #expect(rig.monitor.handle(editing) === editing)
        rig.window = .init(inBannerWindow: false, overlayOpen: false, editingText: false)
        let elsewhere = try keyDown(53)
        #expect(rig.monitor.handle(elsewhere) === elsewhere)
        rig.window = nil // not in a window yet
        let nowhere = try keyDown(53)
        #expect(rig.monitor.handle(nowhere) === nowhere)

        rig.window = .init(inBannerWindow: true, overlayOpen: false, editingText: false)
        rig.monitor.bannerShown = false
        let noBanner = try keyDown(53)
        #expect(rig.monitor.handle(noBanner) === noBanner)
        #expect(rig.dismissed == 0)
    }

    /// Without a window the default reader leaves every key alone.
    @Test func defaultReaderNeedsAWindow() throws {
        #expect(BottleBannerEscapeMonitor.windowState(try keyDown(53), nil) == nil)
        #expect(BottleBannerEscapeMonitor.windowState(try keyDown(53), NSView(frame: .zero)) == nil)
    }

    /// Tearing the view down (dismantleNSView calls detach) removes the
    /// monitor it installed, once; attaching again replaces the old one.
    @Test func dismantleRemovesTheMonitor() throws {
        let rig = EscapeRig()
        rig.monitor.attach()
        rig.monitor.attach()
        #expect(rig.removed == [1])
        rig.monitor.detach()
        #expect(rig.removed == [1, 2])
        #expect(rig.monitor.monitor == nil)
        rig.monitor.detach()
        #expect(rig.removed == [1, 2])
    }

    /// The monitor's handler doesn't keep the coordinator alive; once it's
    /// gone, keys pass.
    @Test func handlerDoesNotOwnTheMonitor() throws {
        var handler: (@MainActor (NSEvent) -> NSEvent?)?
        do {
            let m = BottleBannerEscapeMonitor(install: { handler = $0; return 1 }, remove: { _ in })
            m.bannerShown = true
            m.readWindow = { _, _ in .init(inBannerWindow: true, overlayOpen: false, editingText: false) }
            m.attach()
        }
        let esc = try keyDown(53)
        let h = try #require(handler)
        let out = h(esc)
        #expect(out === esc)
    }
}

// MARK: the announcement (rules)

struct V094BottleBannerAnnouncementTests {
    static let vim = BottleNoticeAnnouncer.Notice(text: "vim gains a bottle", ids: ["vim"])
    static let both = BottleNoticeAnnouncer.Notice(text: "vim and lua gain a bottle", ids: ["lua", "vim"])
    static let four = BottleNoticeAnnouncer.Notice(text: "4 formulae you built from source now have a bottle", ids: ["a", "b", "c", "d"])
    static let swapped = BottleNoticeAnnouncer.Notice(text: four.text, ids: ["a", "b", "c", "e"])

    @Test func announcesWhenTheBannerAppears() {
        var a = BottleNoticeAnnouncer()
        #expect(a.update(nil, windowReady: true) == nil)
        #expect(a.update(Self.vim, windowReady: true) == Self.vim.text)
        #expect(a.announced == ["vim"])
        #expect(!a.isPending)
    }

    /// A re-render with the same banner says nothing (once per appearance).
    @Test func sameBannerAgainIsSilent() {
        var a = BottleNoticeAnnouncer()
        #expect(a.update(Self.vim, windowReady: true) == Self.vim.text)
        for _ in 0..<3 { #expect(a.update(Self.vim, windowReady: true) == nil) }
        #expect(a.windowReadinessChanged(true) == nil)
    }

    /// A later bottle added to the banner: the new sentence, once.
    @Test func aNewNameIsAnnounced() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(Self.vim, windowReady: true)
        #expect(a.update(Self.both, windowReady: true) == Self.both.text)
        #expect(a.update(Self.both, windowReady: true) == nil)
    }

    /// A formula leaving the banner (its replace started) is silent; if it
    /// comes back, that's news again.
    @Test func aNameLeavingIsSilent() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(Self.both, windowReady: true)
        #expect(a.update(Self.vim, windowReady: true) == nil)
        #expect(a.update(Self.both, windowReady: true) == Self.both.text)
    }

    /// Closed (button, Esc) or emptied: the next banner is announced, even
    /// with the same words.
    @Test func eachAppearanceIsAnnounced() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(Self.vim, windowReady: true)
        #expect(a.update(nil, windowReady: true) == nil)
        #expect(a.announced.isEmpty)
        #expect(a.update(Self.vim, windowReady: true) == Self.vim.text)
        // A notice without formulae is no banner.
        #expect(a.update(.init(text: Self.vim.text, ids: []), windowReady: true) == nil)
        #expect(a.announced.isEmpty)
        #expect(a.current == nil)
    }

    /// Four or more: the sentence is just the count, so one formula swapped
    /// for another reads the same, and is still news.
    @Test func aSwapAtFourIsNewsWithTheSameSentence() {
        var a = BottleNoticeAnnouncer()
        #expect(Self.four.text == Self.swapped.text)
        #expect(a.update(Self.four, windowReady: true) == Self.four.text)
        #expect(a.update(Self.swapped, windowReady: true) == Self.swapped.text)
        #expect(a.update(Self.swapped, windowReady: true) == nil)
    }

    /// The window isn't ready (minimized, starting up, not key): nothing is
    /// spoken or marked heard; once it is, the banner as it is then.
    @Test func waitsForTheWindow() {
        var a = BottleNoticeAnnouncer()
        #expect(a.update(Self.vim, windowReady: false) == nil)
        #expect(a.isPending)
        #expect(a.announced.isEmpty)
        #expect(a.windowReadinessChanged(false) == nil)
        // It grew meanwhile: the latest sentence, once.
        #expect(a.update(Self.both, windowReady: false) == nil)
        #expect(a.windowReadinessChanged(true) == Self.both.text)
        #expect(!a.isPending)
        #expect(a.windowReadinessChanged(true) == nil)
    }

    /// News that went away before the window was ready isn't spoken.
    @Test func newsGoneBeforeTheWindowIsSilent() {
        var a = BottleNoticeAnnouncer()
        _ = a.update(Self.vim, windowReady: true)
        #expect(a.update(Self.both, windowReady: false) == nil)
        #expect(a.isPending)
        #expect(a.update(Self.vim, windowReady: false) == nil)
        #expect(!a.isPending)
        #expect(a.windowReadinessChanged(true) == nil)
        // Closed while the window was away: nothing pending either.
        _ = a.update(Self.both, windowReady: false)
        _ = a.update(nil, windowReady: false)
        #expect(a.windowReadinessChanged(true) == nil)
    }
}

// MARK: the announcement (window)

/// A coordinator with a real window, its own notification center, and its
/// readiness and VoiceOver post recorded.
@MainActor
private final class AnnouncementRig {
    let center = NotificationCenter()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                          backing: .buffered, defer: true)
    var ready = false
    /// The window that can be ready (nil: `window`).
    var readyWindow: NSWindow?
    var posts: [(String, NSWindow)] = []
    let coordinator: BottleNoticeAnnouncementCoordinator

    init() {
        window.isReleasedWhenClosed = false
        var isReady: @MainActor (NSWindow) -> Bool = { _ in false }
        var post: @MainActor (String, NSWindow) -> Void = { _, _ in }
        coordinator = BottleNoticeAnnouncementCoordinator(center: center, isReady: { isReady($0) }, post: { post($0, $1) })
        isReady = { [unowned self] w in w === (self.readyWindow ?? self.window) && self.ready }
        post = { [unowned self] in self.posts.append(($0, $1)) }
    }

    var spoken: [String] { posts.map(\.0) }

    func becomes(_ name: Notification.Name, ready: Bool = true) {
        self.ready = ready
        center.post(name: name, object: window)
    }
}

@MainActor
struct V094BottleNoticeAnnouncementWindowTests {
    typealias T = V094BottleBannerAnnouncementTests

    /// A background check while the window is minimized: pending, then
    /// spoken from that window when it comes back from the Dock.
    @Test func minimizedThenDeminiaturized() {
        let rig = AnnouncementRig()
        rig.coordinator.windowChanged(rig.window)
        #expect(rig.coordinator.isObserving)
        rig.coordinator.noticeChanged(T.vim)
        #expect(rig.posts.isEmpty)
        #expect(rig.coordinator.announcer.isPending)
        rig.becomes(NSWindow.didDeminiaturizeNotification)
        #expect(rig.spoken == [T.vim.text])
        #expect(rig.posts.first?.1 === rig.window)
        // Becoming key afterwards says nothing new.
        rig.becomes(NSWindow.didBecomeKeyNotification)
        #expect(rig.spoken == [T.vim.text])
    }

    /// At startup the banner can come before the window: spoken once the
    /// view is in it and the window is key.
    @Test func startupWaitsForTheWindowToBecomeKey() {
        let rig = AnnouncementRig()
        rig.coordinator.noticeChanged(T.vim)
        #expect(rig.posts.isEmpty)
        rig.coordinator.windowChanged(rig.window) // attached, not key yet
        #expect(rig.posts.isEmpty)
        rig.becomes(NSWindow.didBecomeKeyNotification, ready: false)
        #expect(rig.posts.isEmpty)
        rig.becomes(NSWindow.didBecomeKeyNotification)
        #expect(rig.spoken == [T.vim.text])
    }

    /// Attached to a window that's already ready: spoken right away.
    @Test func attachedToAReadyWindow() {
        let rig = AnnouncementRig()
        rig.ready = true
        rig.coordinator.noticeChanged(T.both)
        rig.coordinator.windowChanged(rig.window)
        #expect(rig.spoken == [T.both.text])
    }

    /// Another window's notifications don't count.
    @Test func onlyItsOwnWindow() {
        let rig = AnnouncementRig()
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        rig.coordinator.windowChanged(rig.window)
        rig.coordinator.noticeChanged(T.vim)
        rig.ready = true
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(rig.posts.isEmpty)
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
        #expect(rig.spoken == [T.vim.text])
    }

    /// Four or more formulae, one swapped: same sentence, announced again;
    /// SwiftUI's repeated updates with the same banner say nothing.
    @Test func swapAtFourIsAnnouncedAgain() {
        let rig = AnnouncementRig()
        rig.ready = true
        rig.coordinator.windowChanged(rig.window)
        rig.coordinator.noticeChanged(T.four)
        rig.coordinator.noticeChanged(T.four)
        rig.coordinator.noticeChanged(T.swapped)
        rig.coordinator.noticeChanged(T.swapped)
        #expect(rig.spoken == [T.four.text, T.four.text])
    }

    /// The view's window changes reach the coordinator (makeNSView calls
    /// attach(to:)): joining a window observes it, leaving stops.
    @Test func attachedViewDrivesTheCoordinator() throws {
        let rig = AnnouncementRig()
        let view = WindowWatchingView(frame: .zero)
        rig.coordinator.attach(to: view)
        rig.coordinator.noticeChanged(T.vim)
        try #require(rig.window.contentView).addSubview(view)
        #expect(rig.coordinator.window === rig.window)
        #expect(rig.coordinator.isObserving)
        rig.becomes(NSWindow.didBecomeKeyNotification)
        #expect(rig.spoken == [T.vim.text])
        view.removeFromSuperview()
        #expect(rig.coordinator.window == nil)
        #expect(!rig.coordinator.isObserving)
    }

    /// A pending banner follows the view to another window: the old
    /// window's notifications no longer count, the new one's do, and it's
    /// spoken from the new window.
    @Test func pendingMovesToTheNewWindow() {
        let rig = AnnouncementRig()
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        rig.coordinator.windowChanged(rig.window)
        rig.coordinator.noticeChanged(T.vim)
        #expect(rig.coordinator.announcer.isPending)
        rig.coordinator.windowChanged(nil)
        #expect(!rig.coordinator.isObserving)
        rig.coordinator.windowChanged(other)
        #expect(rig.coordinator.window === other)
        #expect(rig.coordinator.isObserving)
        rig.readyWindow = other
        rig.becomes(NSWindow.didBecomeKeyNotification) // the old window
        #expect(rig.posts.isEmpty)
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(rig.spoken == [T.vim.text])
        #expect(rig.posts.first?.1 === other)
    }

    /// Out of a window after the old one was freed (the weak reference is
    /// already nil): windowChanged(nil) still drops its observers.
    @Test func noWindowClearsObserversAfterTheWindowIsFreed() {
        let rig = AnnouncementRig()
        weak var freed: NSWindow?
        autoreleasepool {
            let w = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            freed = w
            rig.coordinator.windowChanged(w)
        }
        #expect(freed == nil)
        #expect(rig.coordinator.window == nil)
        #expect(rig.coordinator.isObserving)
        rig.coordinator.noticeChanged(T.vim)
        rig.coordinator.windowChanged(nil)
        #expect(!rig.coordinator.isObserving)
        #expect(rig.coordinator.announcer.isPending)
        // Into a window again: pending, spoken once it's ready.
        rig.ready = true
        rig.coordinator.windowChanged(rig.window)
        #expect(rig.spoken == [T.vim.text])
    }

    /// Torn down (dismantleNSView calls detach(from:)): no more observing,
    /// nothing spoken.
    @Test func dismantleStopsObserving() {
        let rig = AnnouncementRig()
        let view = WindowWatchingView(frame: .zero)
        rig.coordinator.attach(to: view)
        #expect(view.onWindowChange != nil)
        rig.coordinator.windowChanged(rig.window)
        rig.coordinator.noticeChanged(T.vim)
        rig.coordinator.detach(from: view)
        #expect(!rig.coordinator.isObserving)
        #expect(rig.coordinator.window == nil)
        #expect(view.onWindowChange == nil)
        rig.becomes(NSWindow.didBecomeKeyNotification)
        #expect(rig.posts.isEmpty)
    }

    /// The view reports joining a window.
    @Test func watchingViewReportsItsWindow() throws {
        let rig = AnnouncementRig()
        let view = WindowWatchingView(frame: .zero)
        var seen: [NSWindow?] = []
        view.onWindowChange = { seen.append($0) }
        let content = try #require(rig.window.contentView)
        content.addSubview(view)
        view.removeFromSuperview()
        #expect(seen.count == 2)
        #expect(seen.first! === rig.window)
        #expect(seen.last! == nil)
    }

    /// What counts as ready: visible, not minimized, key. A window that
    /// was never shown isn't.
    @Test func readinessNeedsAVisibleKeyWindow() {
        let w = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        #expect(!BottleNoticeAnnouncementCoordinator.windowIsReady(w))
        #expect(BottleNoticeAnnouncementCoordinator.readinessNotifications.contains(NSWindow.didBecomeKeyNotification))
        #expect(BottleNoticeAnnouncementCoordinator.readinessNotifications.contains(NSWindow.didDeminiaturizeNotification))
    }
}

// MARK: the store's side

struct V094BottleNoticeAnnouncementStoreTests {
    /// The store's notice for VoiceOver names the formulae, so a swap at
    /// four reads the same sentence but is a different notice.
    @MainActor @Test func noticeFollowsTheFormulae() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let make = { (name: String) in BottleNoticeDiffTests().source(name) }
        let all = ["a1", "a2", "a3", "a4", "a5"].map(make)
        var report = try #require(store.report)
        report.packages += all
        store.report = report
        store.bottleNotice = BottleNotice(keys: Set(all.prefix(4).map(BottleAvailableNotificationDiff.key)))
        let first = try #require(store.bottleNoticeAnnouncement)
        #expect(first.text == store.bottleNoticeText)
        #expect(first.ids == all.prefix(4).map(\.id).sorted())
        store.bottleNotice = BottleNotice(keys: Set((all.prefix(3) + [all[4]]).map(BottleAvailableNotificationDiff.key)))
        let second = try #require(store.bottleNoticeAnnouncement)
        #expect(second.text == first.text)
        #expect(second != first)
        store.dismissBottleNotice()
        #expect(store.bottleNoticeAnnouncement == nil)
    }
}

// MARK: wiring

/// The window uses both bridges (single names, so wrapping the call
/// doesn't matter); what they do is tested above.
struct V094BottleBannerWiringTests {
    @Test func contentViewUsesTheBridges() throws {
        let src = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/ContentView.swift"), encoding: .utf8)
        #expect(src.contains("BottleBannerEscapeKey("))
        #expect(src.contains("store.dismissBottleNotice()"))
        #expect(src.contains("BottleNoticeAnnouncementKey("))
        #expect(src.contains("store.bottleNoticeAnnouncement"))
        #expect(!src.contains("onChange(of: store.bottleNoticeText"))
    }

    /// The SwiftUI wrappers are TankardApp's; TankardAppModel stays free
    /// of SwiftUI (Package.swift, docs/architecture.md).
    @Test func wrappersAreInTheApp() throws {
        let views = try String(contentsOf: packageRoot.appendingPathComponent("Sources/TankardApp/BottleBannerViews.swift"), encoding: .utf8)
        #expect(views.contains("struct BottleBannerEscapeKey: NSViewRepresentable"))
        #expect(views.contains("struct BottleNoticeAnnouncementKey: NSViewRepresentable"))
        #expect(views.contains("coordinator.attach(to: view)"))
        #expect(views.contains("coordinator.detach(from: view)"))
        #expect(views.contains("coordinator.detach()"))
        let dir = packageRoot.appendingPathComponent("Sources/TankardAppModel")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            #expect(!src.contains("import SwiftUI"), "\(f.lastPathComponent)")
            #expect(!src.contains("NSViewRepresentable {"), "\(f.lastPathComponent)")
        }
    }
}
