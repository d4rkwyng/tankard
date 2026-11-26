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
/// (a later bottle added to it). A re-render, the same sentence again, or
/// a formula leaving it (a replace started, a bottle withdrawn) says
/// nothing; once the banner goes (closed, Esc, all replaced), its next
/// appearance is announced.
public struct BottleNoticeAnnouncer: Equatable, Sendable {
    /// The formulae of the last announcement while the banner stays up.
    public private(set) var announced: Set<String> = []

    public init() {}

    /// The banner now shows `text` naming `names` (nil or no names: no
    /// banner). Returns the sentence to announce, or nil.
    public mutating func update(text: String?, names: [String]) -> String? {
        guard let text, !names.isEmpty else {
            announced = []
            return nil
        }
        let current = Set(names)
        let isNew = !current.isSubset(of: announced)
        // What's on the banner now, so a name that leaves and comes back
        // is announced again.
        announced = current
        return isNew ? text : nil
    }
}
