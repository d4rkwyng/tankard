import Foundation

// 0.9.4: the bottle banner's Esc and its VoiceOver announcement. The rules
// live here (tested in TankardAppModelTests); the window's key monitor and
// the announcement itself are in ContentView.swift (BottleBannerEscapeKey,
// ContentView.announceBottleNotice).

/// Whether a key press in the main window is the bottle banner's Esc (its
/// close button, `AppStore.dismissBottleNotice()`).
///
/// Esc belongs to whatever is in front of the banner first, so the banner
/// only gets a plain Esc that nothing else would take:
/// - a sheet, an alert or a popover (their own windows, or attached to the
///   main one) keeps it: Esc closes that, not the banner behind it;
/// - text editing (the toolbar search field, any text field) keeps it:
///   Esc clears the search field as it always has, and with the field
///   empty it still does nothing to the banner. Click or Tab out of the
///   field first;
/// - Esc with ⌘, ⌃, ⌥ or ⇧ is someone else's shortcut.
public enum BottleBannerEscape {
    /// The key code of Esc (kVK_Escape).
    public static let escapeKeyCode: UInt16 = 53

    public struct Press: Equatable, Sendable {
        /// The banner is on screen (`AppStore.bottleNoticeText` non-nil).
        public var bannerShown: Bool
        /// The key's code (`NSEvent.keyCode`).
        public var keyCode: UInt16
        /// ⌘, ⌃, ⌥ or ⇧ was held.
        public var hasModifiers: Bool
        /// The press went to the banner's window, and that window is key
        /// (not a sheet, an alert, a popover, Settings or the menu-bar panel).
        public var inBannerWindow: Bool
        /// The banner's window has a sheet or an alert attached, a visible
        /// child window (a popover), or the app runs a modal session.
        public var overlayOpen: Bool
        /// The window's first responder edits text (a field editor: the
        /// toolbar search field, any text field).
        public var editingText: Bool

        public init(bannerShown: Bool, keyCode: UInt16, hasModifiers: Bool, inBannerWindow: Bool,
                    overlayOpen: Bool, editingText: Bool) {
            self.bannerShown = bannerShown
            self.keyCode = keyCode
            self.hasModifiers = hasModifiers
            self.inBannerWindow = inBannerWindow
            self.overlayOpen = overlayOpen
            self.editingText = editingText
        }
    }

    /// true: close the banner and take the key; false: leave the key alone.
    public static func dismisses(_ p: Press) -> Bool {
        p.bannerShown && p.keyCode == escapeKeyCode && !p.hasModifiers
            && p.inBannerWindow && !p.overlayOpen && !p.editingText
    }
}

/// What VoiceOver hears when the bottle banner appears: its sentence, once
/// per appearance, and again only when it names a formula it hadn't named
/// (a later bottle added to it). A re-render, the same banner again, or a
/// formula leaving it (a replace started, a bottle withdrawn) says nothing;
/// once the banner goes (closed, Esc, all replaced), its next appearance is
/// announced.
///
/// It follows the formulae, not the sentence: from four formulae on the
/// sentence is only their count, so one swapped for another reads the same
/// but is still news.
///
/// News waits for the banner's window: while it's minimized, hidden or not
/// key (a background check, the app starting up), the announcement stays
/// pending, and `windowReadinessChanged(true)` speaks the banner as it is
/// then.
public struct BottleNoticeAnnouncer: Equatable, Sendable {
    /// The banner as VoiceOver should hear it: its sentence, and the
    /// formulae it names (their ids, in order).
    public struct Notice: Equatable, Sendable {
        public var text: String
        public var ids: [String]
        public init(text: String, ids: [String]) {
            self.text = text
            self.ids = ids
        }
    }

    /// The formulae VoiceOver has heard while the banner stays up.
    public private(set) var announced: Set<String> = []
    /// The banner on screen now (nil: none).
    public private(set) var current: Notice?

    public init() {}

    /// The banner has news VoiceOver hasn't heard yet (waiting for its
    /// window).
    public var isPending: Bool {
        guard let current else { return false }
        return !Set(current.ids).isSubset(of: announced)
    }

    /// The banner now shows `notice` (nil or no formulae: no banner), and
    /// its window is `windowReady` or not. Returns the sentence to
    /// announce, or nil.
    public mutating func update(_ notice: Notice?, windowReady: Bool) -> String? {
        guard let notice, !notice.ids.isEmpty else {
            announced = []
            current = nil
            return nil
        }
        current = notice
        return evaluate(windowReady: windowReady)
    }

    /// The banner's window became ready (or stopped being). Returns the
    /// pending sentence, as the banner reads now, or nil.
    public mutating func windowReadinessChanged(_ ready: Bool) -> String? {
        evaluate(windowReady: ready)
    }

    private mutating func evaluate(windowReady: Bool) -> String? {
        guard let current else { return nil }
        let ids = Set(current.ids)
        guard windowReady || ids.isSubset(of: announced) else {
            // Keep only what's still shown, so a formula that leaves and
            // comes back is news again; the rest waits.
            announced.formIntersection(ids)
            return nil
        }
        let isNew = !ids.isSubset(of: announced)
        announced = ids
        return isNew ? current.text : nil
    }
}
