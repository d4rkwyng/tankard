import AppKit
import SwiftUI

// 0.9.4: the bottle banner's window plumbing: its Esc key monitor and its
// VoiceOver announcement. They live here, not in TankardApp, so the tests
// can drive them (TankardAppModelTests links this target only). Two small
// NSViewRepresentables, no visible views; the rules they follow are
// BottleBannerEscape and BottleNoticeAnnouncer (BottleBannerKeys.swift).

// MARK: Esc

/// Esc in the main window closes the bottle banner. A key monitor (as
/// TableSelection's type-select), not a `.cancelAction` button: a SwiftUI
/// shortcut is a key equivalent, which the window handles before its first
/// responder, so it would take Esc from the toolbar search field (Esc
/// clears it). The monitor sees every key press first and takes only the
/// ones BottleBannerEscape gives the banner; the rest go on as before. A
/// sheet, alert or popover is its own key window (or attached to this one),
/// so its Esc is left to it.
public struct BottleBannerEscapeKey: NSViewRepresentable {
    public var bannerShown: Bool
    public var dismiss: @MainActor () -> Void

    public init(bannerShown: Bool, dismiss: @escaping @MainActor () -> Void) {
        self.bannerShown = bannerShown
        self.dismiss = dismiss
    }

    public func makeCoordinator() -> BottleBannerEscapeMonitor { BottleBannerEscapeMonitor() }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let c = context.coordinator
        c.view = view
        c.bannerShown = bannerShown
        c.dismiss = dismiss
        c.attach()
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.bannerShown = bannerShown
        context.coordinator.dismiss = dismiss
    }

    public static func dismantleNSView(_ view: NSView, coordinator: BottleBannerEscapeMonitor) {
        coordinator.detach()
    }
}

/// BottleBannerEscapeKey's coordinator: installs the key monitor and
/// decides each key press.
@MainActor
public final class BottleBannerEscapeMonitor {
    /// What the banner's window says about a key press (nil: no window).
    public struct WindowState: Equatable, Sendable {
        public var inBannerWindow: Bool
        public var overlayOpen: Bool
        public var editingText: Bool
        public init(inBannerWindow: Bool, overlayOpen: Bool, editingText: Bool) {
            self.inBannerWindow = inBannerWindow
            self.overlayOpen = overlayOpen
            self.editingText = editingText
        }
    }

    /// Installs `handler` as a key-down monitor; returns its token.
    public typealias Install = @MainActor (@escaping @MainActor (NSEvent) -> NSEvent?) -> Any?

    public weak var view: NSView?
    public var bannerShown = false
    public var dismiss: @MainActor () -> Void = {}
    /// The window's side of BottleBannerEscape.Press.
    public var readWindow: @MainActor (NSEvent, NSView?) -> WindowState? = BottleBannerEscapeMonitor.windowState

    private let install: Install
    private let remove: @MainActor (Any) -> Void
    /// The installed monitor's token (nil: none).
    public private(set) var monitor: Any?

    public init(install: @escaping Install = BottleBannerEscapeMonitor.localKeyDownMonitor,
                remove: @escaping @MainActor (Any) -> Void = { NSEvent.removeMonitor($0) }) {
        self.install = install
        self.remove = remove
    }

    public func attach() {
        detach()
        monitor = install { [weak self] event in
            // Not `self?.handle(event) ?? event`: that turns a taken key
            // (nil) back into the event.
            guard let self else { return event }
            return self.handle(event)
        }
    }

    public func detach() {
        if let m = monitor { remove(m) }
        monitor = nil
    }

    /// nil: the banner closed and the key is taken; otherwise the key goes
    /// on untouched.
    public func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown, let w = readWindow(event, view) else { return event }
        let press = BottleBannerEscape.Press(
            bannerShown: bannerShown,
            keyCode: event.keyCode,
            hasModifiers: !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            inBannerWindow: w.inBannerWindow,
            overlayOpen: w.overlayOpen,
            editingText: w.editingText)
        guard BottleBannerEscape.dismisses(press) else { return event }
        dismiss()
        return nil
    }

    /// The banner's window as the rule needs it: the press went to it and
    /// it's key; a sheet, alert, modal session or visible child window
    /// (a popover) is in front; the first responder edits text (the field
    /// editor, an NSTextView, of the search field or any text field).
    public static func windowState(_ event: NSEvent, _ view: NSView?) -> WindowState? {
        guard let w = view?.window else { return nil }
        return WindowState(
            inBannerWindow: event.window === w && w.isKeyWindow,
            overlayOpen: w.attachedSheet != nil || NSApp.modalWindow != nil
                || (w.childWindows ?? []).contains(where: \.isVisible),
            editingText: w.firstResponder is NSText)
    }

    public static func localKeyDownMonitor(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Key events arrive on the main thread.
            nonisolated(unsafe) let e = event
            let taken = MainActor.assumeIsolated { handler(e) == nil }
            return taken ? nil : event
        }
    }
}

// MARK: the announcement

/// VoiceOver speaks the bottle banner's sentence when it appears (a banner
/// shows up without taking the focus, so it went unheard), once its own
/// window is on screen and key. It follows the banner's formulae, not only
/// its sentence (BottleNoticeAnnouncer).
public struct BottleNoticeAnnouncementKey: NSViewRepresentable {
    public var notice: BottleNoticeAnnouncer.Notice?

    public init(notice: BottleNoticeAnnouncer.Notice?) { self.notice = notice }

    public func makeCoordinator() -> BottleNoticeAnnouncementCoordinator { BottleNoticeAnnouncementCoordinator() }

    public func makeNSView(context: Context) -> WindowWatchingView {
        let view = WindowWatchingView(frame: .zero)
        let c = context.coordinator
        view.onWindowChange = { [weak c] in c?.windowChanged($0) }
        c.noticeChanged(notice)
        return view
    }

    public func updateNSView(_ view: WindowWatchingView, context: Context) {
        context.coordinator.noticeChanged(notice)
    }

    public static func dismantleNSView(_ view: WindowWatchingView, coordinator: BottleNoticeAnnouncementCoordinator) {
        view.onWindowChange = nil
        coordinator.detach()
    }
}

/// An empty view that says when it joins or leaves a window.
public final class WindowWatchingView: NSView {
    public var onWindowChange: ((NSWindow?) -> Void)?

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// BottleNoticeAnnouncementKey's coordinator: feeds the banner and its
/// window's readiness to a BottleNoticeAnnouncer, and posts what it
/// returns to that window.
@MainActor
public final class BottleNoticeAnnouncementCoordinator {
    public private(set) var announcer = BottleNoticeAnnouncer()
    /// The banner's window (nil: not in one yet).
    public private(set) weak var window: NSWindow?
    public var isReady: @MainActor (NSWindow) -> Bool
    public var post: @MainActor (String, NSWindow) -> Void

    /// What makes a window ready again: key, back from the Dock, visible.
    public static let readinessNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
    ]

    private let center: NotificationCenter
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var notice: BottleNoticeAnnouncer.Notice?
    private var started = false

    public init(center: NotificationCenter = .default,
                isReady: @escaping @MainActor (NSWindow) -> Bool = BottleNoticeAnnouncementCoordinator.windowIsReady,
                post: @escaping @MainActor (String, NSWindow) -> Void = BottleNoticeAnnouncement.post(_:from:)) {
        self.center = center
        self.isReady = isReady
        self.post = post
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }

    /// On screen, not in the Dock, and key: where VoiceOver is.
    public static func windowIsReady(_ w: NSWindow) -> Bool {
        w.isVisible && !w.isMiniaturized && w.isKeyWindow
    }

    /// Observes the window's readiness notifications, if it has one.
    public var isObserving: Bool { !observers.isEmpty }

    /// The banner (from SwiftUI's update): announced if it's news and the
    /// window is ready, pending if not. The same banner again does nothing.
    public func noticeChanged(_ notice: BottleNoticeAnnouncer.Notice?) {
        if started && notice == self.notice { return }
        started = true
        self.notice = notice
        speak(announcer.update(notice, windowReady: ready))
    }

    /// The view joined (or left) a window.
    public func windowChanged(_ w: NSWindow?) {
        if w === window && (w == nil || isObserving) { return }
        stopObserving()
        window = w
        if let w {
            observers = Self.readinessNotifications.map { name in
                center.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readinessChanged() }
                }
            }
        }
        readinessChanged()
    }

    /// The window may be ready now: speak what's pending.
    public func readinessChanged() {
        speak(announcer.windowReadinessChanged(ready))
    }

    public func detach() {
        stopObserving()
        window = nil
    }

    private var ready: Bool { window.map(isReady) ?? false }

    private func speak(_ sentence: String?) {
        guard let sentence, let w = window else { return }
        post(sentence, w)
    }

    private func stopObserving() {
        for o in observers { center.removeObserver(o) }
        observers = []
    }
}

/// Posts the bottle banner's sentence as an announcement VoiceOver speaks,
/// from the banner's own window.
@MainActor
public enum BottleNoticeAnnouncement {
    public static func post(_ text: String, from window: NSWindow) {
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
