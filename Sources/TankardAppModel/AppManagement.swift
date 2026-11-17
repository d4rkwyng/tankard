import Foundation
import TankardCore

/// macOS 13+ asks before one app can update or delete another
/// (System Settings → Privacy & Security → App Management,
/// kTCCServiceSystemPolicyAppBundles). Without it, a cask upgrade or
/// uninstall that touches /Applications fails. There is no public API to
/// ask whether Tankard has it, so the app explains it once before the first
/// cask change, and again whenever brew's output shows the block.
public enum AppManagement {
    /// The App Management pane. On this Mac's System Settings the
    /// Privacy & Security extension (legacy id com.apple.preference.security)
    /// lists `revealElementKeyName` "Privacy_AppBundles" for
    /// kTCCServiceSystemPolicyAppBundles and allows the
    /// x-apple.systempreferences scheme.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    /// Fallback: Privacy & Security itself.
    public static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// Only cask upgrades and uninstalls replace or remove apps. Formula
    /// operations (and Replace with bottle) never trigger the flow.
    public static func modifiesApps(_ action: SessionAction, _ p: Package) -> Bool {
        p.kind == .cask && (action == .upgrade || action == .uninstall)
    }

    /// Whether brew's output for a cask step shows macOS blocking it.
    ///
    /// Matches brew 7.0.14's own App Management messages (cask/staged.rb,
    /// install_steps.rb, cask/quarantine.rb: "does not have App Management
    /// permissions"), macOS's "was prevented from modifying apps", and
    /// "Operation not permitted" on a path in an Applications folder (what
    /// rename/rm/chown print when the move is blocked).
    public static func isPermissionBlock(_ lines: some Sequence<String>) -> Bool {
        lines.contains { line in
            let l = line.lowercased()
            if l.contains("app management permission") { return true }
            if l.contains("prevented from modifying apps") { return true }
            if l.contains("operation not permitted"), l.contains("/applications/") { return true }
            return false
        }
    }

    /// The sheet's steps. `anchored`: the deep link opens App Management
    /// itself (false: it opens Privacy & Security, so step 1 says where to go).
    public static func steps(anchored: Bool = true) -> [String] {
        [
            anchored ? String(localized: "Click Open System Settings. It opens Privacy & Security → App Management.")
                : String(localized: "Click Open System Settings, then choose Privacy & Security → App Management."),
            String(localized: "Turn on Tankard. If it isn't listed, click + and choose Tankard in Applications."),
            String(localized: "Come back and click I've done this."),
        ]
    }
}

/// Why the App Management sheet is up, and what to do after it.
public struct AppManagementPrompt: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// Before the first cask change: explain once, then start.
        case firstUse
        /// A cask step failed with the permission block: retry once after.
        case blocked
    }

    public var id = UUID()
    public var reason: Reason
    public var action: SessionAction
    /// The packages to run (firstUse) or retry (blocked).
    public var packages: [Package]

    public init(reason: Reason, action: SessionAction, packages: [Package]) {
        self.reason = reason
        self.action = action
        self.packages = packages
    }
}

/// The About panel and Help menu.
public enum AboutInfo {
    public static let repository = URL(string: "https://github.com/d4rkwyng/tankard")!
    public static let newIssue = URL(string: "https://github.com/d4rkwyng/tankard/issues/new")!
    public static let intelbrew = URL(string: "https://github.com/d4rkwyng/intelbrew")!
    public static let author = String(localized: "Made by d4rkwyng")
    public static let licence = String(localized: "BSD-2-Clause licence")
    public static let homebrew = URL(string: "https://brew.sh")!
    /// About Homebrew, kept short enough for the About panel's width
    /// (~280 pt): "brew.sh" is the link.
    public static let homebrewLine = String(localized: "An independent app for Homebrew (brew.sh).")
    public static let homebrewCopyright = String(localized: "Homebrew © Homebrew contributors, BSD-2-Clause.")
    public static let notAffiliated = String(localized: "Not affiliated with or endorsed by the Homebrew project.")
    /// Intelbrew mode: replaces the plain Intelbrew link line.
    public static let intelbrewBottlesLine = String(localized: "Intelbrew bottles from d4rkwyng/intelbrew")
    /// The About panel's copyright line, in the owner's name as First
    /// Light's LICENSE ("Copyright (c) 2026 d4rkwyng") and both apps'
    /// "Made by d4rkwyng" credit. LICENSE keeps "Tankard contributors".
    public static let copyright = "© 2026 d4rkwyng"

    /// The About panel's version line: "Version 0.3.0". The build number is
    /// never shown (the bundle sets CFBundleVersion to the same string, and
    /// the panel is given an empty build so AppKit adds no "(N)").
    public static func versionLine(short: String?, build: String?) -> String {
        String(localized: "Version \(versionString(short: short, build: build))")
    }

    /// The version alone ("0.3.0"): short, else build, else TankardVersion.
    static func versionString(short: String?, build: String?) -> String {
        (short?.isEmpty == false ? short : nil) ?? (build?.isEmpty == false ? build : nil) ?? TankardVersion.string
    }

    /// What goes in the panel's application-version slot ("0.3.0") and
    /// the build slot (always empty).
    public static func panelVersions(bundle: [String: Any]?) -> (application: String, build: String) {
        let short = bundle?["CFBundleShortVersionString"] as? String
        let build = bundle?["CFBundleVersion"] as? String
        return (versionString(short: short, build: build), "")
    }
}
