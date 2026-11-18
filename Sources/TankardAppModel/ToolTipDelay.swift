import Foundation

/// 0.8.6: tooltips on the row icons came up "too slowly" (Derek). SwiftUI's
/// `.help` is an AppKit tooltip, shown after NSToolTipManager's delay,
/// 1.5 s by default, which it reads once from the `NSInitialToolTipDelay`
/// default (milliseconds) when it is created. Tankard registers a shorter
/// one in the registration domain, which is in memory and this process's
/// only: nothing is written to Tankard's defaults or anyone else's, and a
/// value the user set (`defaults write net.mindtricks.tankard
/// NSInitialToolTipDelay -int 1500`, or globally) still wins.
/// Checked on macOS 27 (Darwin 27.2): the manager's delay reads 1.5 s
/// without it and 0.35 s with it.
public enum ToolTipDelay {
    public static let key = "NSInitialToolTipDelay"
    public static let milliseconds = 350

    /// Call at launch, before any window (the manager reads it once).
    public static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [key: milliseconds])
    }
}
