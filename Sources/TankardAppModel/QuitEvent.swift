import Foundation

// 0.8.8 (final gauntlet, bug 1): a quit from outside Tankard (the Dock's
// Quit, AppleScript's `quit`, a logout, restart or shutdown) arrives as the
// quit Apple Event (kCoreEventClass/kAEQuitApplication). AppKit's own
// handler calls `terminate:`, which AppKit refuses while a sheet is attached
// ("App termination blocked by modal sheet") before it asks
// applicationShouldTerminate, and the sender got -128 "User canceled": the
// app stayed, and a logout was likely cancelled the same way. Tankard
// handles the event itself (QuitGuardViews.swift) and takes ⌘Q's path:
// with brew running, ⌘Q's question; otherwise every sheet closed, then quit.

/// Why the quit event came: its kAEQuitReason attribute.
public enum QuitEventReason: Equatable, Sendable, CaseIterable {
    /// No reason: the Dock's Quit, AppleScript's `quit`, Activity Monitor.
    case user
    /// kAELogOut ('logo'), kAEReallyLogOut ('rlgo').
    case logOut
    /// kAEShowRestartDialog ('rrst'), kAERestart ('rest').
    case restart
    /// kAEShowShutdownDialog ('rsdn'), kAEShutDown ('shut').
    case shutDown

    /// From the attribute's four-character code (nil: no attribute).
    public init(code: UInt32?) {
        switch code {
        case Self.fourCC("logo"), Self.fourCC("rlgo"): self = .logOut
        case Self.fourCC("rrst"), Self.fourCC("rest"): self = .restart
        case Self.fourCC("rsdn"), Self.fourCC("shut"): self = .shutDown
        default: self = .user
        }
    }

    /// The system is logging out, restarting or shutting down.
    public var isSystem: Bool { self != .user }

    public var logName: String {
        switch self {
        case .user: return "user"
        case .logOut: return "log out"
        case .restart: return "restart"
        case .shutDown: return "shut down"
        }
    }

    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// Where a quit came from.
public enum QuitSource: Equatable, Sendable {
    /// Tankard ▸ Quit Tankard (⌘Q), the menu-bar panel's Quit.
    case menu
    /// The quit Apple Event.
    case appleEvent(QuitEventReason)
}

/// What a quit does, from wherever it came.
public enum QuitDecision: Equatable, Sendable {
    /// brew is running: "Homebrew is still working… Quit anyway?" first
    /// (Keep Running cancels the quit; a logout, restart or shutdown is
    /// then cancelled too, as macOS does for any app that says no).
    /// `bringForward`: the question comes from outside, so Tankard comes
    /// to the front to ask it.
    case ask(QuitPrompt, bringForward: Bool)
    /// Nothing running: close every sheet, then quit (a logout is never
    /// held up by a sheet nobody asked about).
    case closeSheetsAndQuit

    /// `step`: the store's `quitStep` (nil: no store, or a quit already
    /// agreed to, such as the App Management relaunch). An open sheet
    /// changes nothing: closing it is part of quitting. (Before 0.8.8 a
    /// sheet made AppKit refuse an outside quit outright.)
    public static func decide(_ source: QuitSource, step: AppStore.QuitStep?, sheetOpen: Bool) -> QuitDecision {
        switch step {
        case .ask(let prompt)?:
            if case .appleEvent = source { return .ask(prompt, bringForward: true) }
            return .ask(prompt, bringForward: false)
        case .closeSheetsAndQuit?, nil:
            return .closeSheetsAndQuit
        }
    }

    /// The quit event's reply when the user keeps Tankard running:
    /// userCanceledErr, what AppKit answers when an app cancels a quit
    /// (AppleScript: "User canceled"; a logout says Tankard cancelled it).
    public static let cancelledReplyError: Int32 = -128
}
