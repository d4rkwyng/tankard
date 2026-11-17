import Foundation

/// 0.8.3: Tankard's sudo password dialog ("askpass" helper).
///
/// brew runs some cask steps with sudo (a `.pkg` installer, `pkgutil
/// --forget`, removing root-owned files). Tankard runs brew with stdin
/// /dev/null and no terminal, so sudo can't read a password and the step
/// failed. Homebrew passes `-A` to /usr/bin/sudo when `SUDO_ASKPASS` is set
/// (system_command.rb, env_config.rb), and bin/brew keeps `SUDO_ASKPASS`
/// and every `HOMEBREW_*` variable when it rebuilds its environment. With
/// `-A`, sudo runs the helper as the user, with its prompt as argv[1], and
/// reads the password from the helper's stdout. Exiting non-zero (Cancel)
/// makes sudo fail ("no password was provided").
///
/// The helper is `Tankard.app/Contents/MacOS/tankard-askpass`
/// (Sources/tankard-askpass). This file holds what it and the app share:
/// the variable names, reading the request, and the dialog's words. No
/// password ever passes through here.
public enum Askpass {
    /// The variable Homebrew reads; its value is the helper's path.
    public static let askpassKey = "SUDO_ASKPASS"
    /// What the dialog says the step is for, in the user's language, set by
    /// Tankard per command. A `HOMEBREW_` name because bin/brew drops every
    /// other variable it doesn't know (it keeps `HOMEBREW_*`); sudo then
    /// hands its own environment to the helper.
    public static let contextKey = "HOMEBREW_TANKARD_ASKPASS_CONTEXT"
    /// Homebrew's switch that makes it never run sudo (env_config.rb). Set
    /// for automatic updates, which must never ask for a password.
    public static let noSudoKey = "HOMEBREW_NO_SUDO"
    /// The helper's file name inside Tankard.app/Contents/MacOS.
    public static let helperName = "tankard-askpass"

    /// Debug hooks of the helper (never set by Tankard):
    /// - describe: write the dialog's text to stderr and exit 1, no window;
    /// - snapshot: show the dialog, write it as a PNG to this path, exit 1.
    /// Neither reads or prints a password.
    public static let describeKey = "TANKARD_ASKPASS_DESCRIBE"
    public static let snapshotKey = "TANKARD_ASKPASS_SNAPSHOT"
    /// Test hook for the retry wording ("1": show it).
    public static let retryKey = "TANKARD_ASKPASS_RETRY"

    public static let maxContextLength = 400
    public static let maxPromptLength = 120
    /// The dialog gives up (exit 1, as Cancel) after this long, so a
    /// forgotten dialog doesn't hold brew and the queue forever.
    public static let timeout: TimeInterval = 300
    /// sudo calls the helper again after a wrong password, from the same
    /// sudo process. If that sudo has been running longer than this when
    /// the helper starts, the dialog says the last password was wrong. The
    /// first call comes well under a second after sudo starts; a retry
    /// comes after sudo's ~2 s failure delay (measured: 2 s even when the
    /// wrong answer is instant) plus the user's typing.
    public static let retryThreshold: TimeInterval = 1.5

    /// The environment for one brew command that may run sudo: the helper
    /// and the dialog's context. Empty without a helper.
    public static func environment(helper: String?, context: String) -> [String: String] {
        guard let helper, !helper.isEmpty else { return [:] }
        return [askpassKey: helper, contextKey: sanitize(context, limit: maxContextLength)]
    }

    /// Single line, no control characters (a newline or escape can't fake a
    /// second paragraph or button text), at most `limit` characters.
    public static func sanitize(_ s: String, limit: Int) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : scalar
        }))
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    /// What the helper was asked, read from its argv and environment.
    public struct Request: Equatable, Sendable {
        /// sudo's prompt ("Password:", or "Password for derek:" when brew
        /// asks for another user), cleaned.
        public var prompt: String
        /// Tankard's sentence about the step; nil when not set (the helper
        /// run some other way) or empty.
        public var context: String?
        public var isRetry: Bool

        public init(prompt: String, context: String?, isRetry: Bool) {
            self.prompt = prompt
            self.context = context
            self.isRetry = isRetry
        }
    }

    /// `arguments` is the full argv (argv[0] first). `parentAge`: how long
    /// the calling sudo has been running, when known.
    public static func request(arguments: [String], environment: [String: String],
                               parentAge: TimeInterval? = nil) -> Request {
        let raw = arguments.count > 1 ? arguments[1] : ""
        var prompt = sanitize(raw, limit: maxPromptLength)
        if prompt.isEmpty { prompt = "Password:" }
        let context = environment[contextKey].map { sanitize($0, limit: maxContextLength) }.flatMap { $0.isEmpty ? nil : $0 }
        let retry = environment[retryKey] == "1" || (parentAge.map { $0 > retryThreshold } ?? false)
        return Request(prompt: prompt, context: context, isRetry: retry)
    }

    /// The helper inside an app bundle, when it is there and executable.
    public static func helperPath(appBundle: URL, fileManager: FileManager = .default) -> String? {
        guard appBundle.pathExtension == "app" else { return nil }
        let path = appBundle.appendingPathComponent("Contents/MacOS/\(helperName)").path
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }
}

/// The dialog's words. In the app's string catalog: the helper's main
/// bundle is Tankard.app (it lives in Contents/MacOS), so it reads the same
/// Localizable.strings as the app.
public enum AskpassText {
    public static var title: String { String(localized: "Tankard needs your administrator password") }
    public static var retryTitle: String { String(localized: "The password was incorrect. Try again.") }
    /// Shown when no context came with the request.
    public static var genericContext: String { String(localized: "brew is running a step that needs administrator rights (sudo).") }
    public static var explanation: String {
        String(localized: "brew asked sudo for administrator rights for this step. Your password goes straight to sudo; Tankard doesn't store it. Cancel stops this step.")
    }
    public static var ok: String { String(localized: "OK") }
    public static var cancel: String { String(localized: "Cancel") }
    /// sudo's usual prompt in the user's language; any other prompt
    /// ("Password for derek:") is shown as sudo wrote it.
    public static func promptLabel(_ prompt: String) -> String {
        prompt == "Password:" ? String(localized: "Password:") : prompt
    }

    /// The text under the title.
    public static func body(_ r: Askpass.Request) -> String {
        (r.context ?? genericContext) + "\n\n" + explanation
    }

    /// The describe hook's output: every visible string, one per line.
    public static func describe(_ r: Askpass.Request) -> String {
        [r.isRetry ? retryTitle : title, body(r), promptLabel(r.prompt) + " [secure text field]",
         "[\(ok)] [\(cancel)]"].joined(separator: "\n") + "\n"
    }
}

/// 0.8.3 (security review): the helper answers only Tankard's own brew run.
/// Without this, any process could run
/// `SUDO_ASKPASS=…/tankard-askpass sudo -A <anything>` with friendly
/// context text and get a signed, Tankard-branded password dialog, or run
/// the helper with its stdout on a pipe and read the password.
///
/// The helper allows a request only when
/// 1. its parent is the real sudo: the kernel's path of the parent process
///    (proc_pidpath, symlinks resolved) is `/usr/bin/sudo`, which SIP
///    protects. A process name (p_comm) is not enough: anyone can name a
///    program "sudo". Any other parent (a shell, `| cat`, a file) is refused.
/// 2. walking up from sudo's parent (brew's Ruby, bash, …), at most
///    `maxAncestors` steps, it finds the Tankard executable of the helper's
///    own bundle: `<bundle>/Contents/MacOS/Tankard`, from the helper's own
///    kernel path (so a symlink to the helper resolves to the real one),
///    and the helper must itself sit at `<bundle>.app/Contents/MacOS/tankard-askpass`.
///    A helper copied elsewhere has no Tankard of its own above it.
/// 3. when the helper is signed with a Team ID (a Developer ID release),
///    that Tankard process is validly signed by the same team. This stops a
///    copy of the helper placed in a home-made bundle next to a program
///    called "Tankard". Ad-hoc builds have no Team ID; there only 1 and 2 apply.
///
/// The decision is this pure function; `tankard-askpass/main.swift` gathers
/// its inputs from the kernel and Security.framework.
public enum AskpassGate {
    public static let sudoPath = "/usr/bin/sudo"
    public static let maxAncestors = 10
    static let helperSuffix = ".app/Contents/MacOS/" + Askpass.helperName

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(String)
    }

    /// The Tankard executable that must be above sudo, from the helper's
    /// own resolved path; nil when the helper isn't inside an app bundle.
    public static func expectedTankard(helperPath: String) -> String? {
        guard helperPath.hasPrefix("/"), helperPath.hasSuffix(helperSuffix) else { return nil }
        return String(helperPath.dropLast(Askpass.helperName.count)) + "Tankard"
    }

    /// - parentPath: the parent process's resolved executable path (nil: unknown).
    /// - ancestorPaths: resolved paths of sudo's parent, its parent, … in
    ///   order, as far as they could be read (nil entries: unreadable).
    /// - helperPath: the helper's own resolved path.
    /// - helperTeam / tankardTeam: Team IDs (nil: none, or the Tankard
    ///   process's signature didn't check out).
    public static func decide(parentPath: String?, ancestorPaths: [String?], helperPath: String,
                              helperTeam: String? = nil, tankardTeam: String? = nil) -> Decision {
        guard parentPath == sudoPath else {
            return .deny("parent is not \(sudoPath) (\(parentPath ?? "unknown"))")
        }
        guard let expected = expectedTankard(helperPath: helperPath) else {
            return .deny("helper is not inside an app bundle (\(helperPath))")
        }
        guard ancestorPaths.prefix(maxAncestors).contains(where: { $0 == expected }) else {
            return .deny("no \(expected) above sudo within \(maxAncestors) processes")
        }
        if let helperTeam, helperTeam != tankardTeam {
            return .deny("Tankard process is not signed by team \(helperTeam)")
        }
        return .allow
    }
}
