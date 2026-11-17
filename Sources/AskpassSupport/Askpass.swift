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
