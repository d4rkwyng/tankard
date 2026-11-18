import Foundation

/// 0.8.5 (bug hunt M5): which existing window "Open Tankard" brings back.
/// The menu bar's Open Tankard looked only for a visible main window, and a
/// minimized one isn't visible (AppKit: `isVisible == false`,
/// `isMiniaturized == true`), so it opened a second main window. The
/// notification path already counted a minimized window; both use this now.
public enum MainWindowPick {
    public struct Candidate: Equatable, Sendable {
        public var identifier: String?
        public var isVisible: Bool
        public var isMiniaturized: Bool
        public init(identifier: String?, isVisible: Bool, isMiniaturized: Bool) {
            self.identifier = identifier
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }
    }

    /// The WindowGroup's id is "main" (its windows: "main-AppWindow-1").
    public static func isMain(_ identifier: String?) -> Bool { identifier?.hasPrefix("main") == true }

    /// The index of the main window to bring back (a visible one first,
    /// else a minimized one), or nil: open a new one.
    public static func pick(_ windows: [Candidate]) -> Int? {
        windows.firstIndex { isMain($0.identifier) && $0.isVisible }
            ?? windows.firstIndex { isMain($0.identifier) && $0.isMiniaturized }
    }
}
