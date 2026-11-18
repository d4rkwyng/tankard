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
    /// The brew command the password is for, as Tankard shows it
    /// ("brew upgrade --cask windows-app"), set per command. 0.8.4: the
    /// dialog derives its one-line purpose from it ("To upgrade
    /// windows-app.") and shows the command itself under Details. A
    /// `HOMEBREW_` name because bin/brew drops every other variable it
    /// doesn't know (it keeps `HOMEBREW_*`); sudo then hands its own
    /// environment to the helper.
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
    /// Snapshot hook (0.8.4): "1" opens Details before the picture.
    public static let detailsKey = "TANKARD_ASKPASS_DETAILS"

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

    /// What a brew command does, for the dialog's one line (0.8.4).
    public struct Step: Equatable, Sendable {
        public enum Action: String, Sendable { case install, reinstall, upgrade, uninstall }
        public var action: Action
        /// The package names, without a tap ("homebrew/cask/x" is "x").
        public var names: [String]

        public init(action: Action, names: [String]) {
            self.action = action
            self.names = names
        }
    }

    /// Reads a command as Tankard displays it: optional `NAME=value`
    /// settings, `brew` (or a path ending in /brew), the verb, then options
    /// and package names. nil for anything else. Text only: nothing is run.
    public static func step(command: String) -> Step? {
        var words = command.split(separator: " ").map(String.init)
        while let w = words.first, w.contains("="), !w.hasPrefix("-") { words.removeFirst() }
        guard words.count >= 3, words[0] == "brew" || words[0].hasSuffix("/brew"),
              let action = Step.Action(rawValue: words[1]) else { return nil }
        let names = words.dropFirst(2).filter { !$0.hasPrefix("-") }.map { word -> String in
            let unquoted = word.count >= 2 && word.hasPrefix("'") && word.hasSuffix("'") ? String(word.dropFirst().dropLast()) : word
            return unquoted.split(separator: "/").last.map(String.init) ?? unquoted
        }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : Step(action: action, names: names)
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
///
/// 0.8.4: short. A title, one line for what the password is for, one line
/// on where it goes; the brew command itself under a collapsed Details.
public enum AskpassText {
    public static var title: String { String(localized: "Tankard needs your password") }
    public static var retryTitle: String { String(localized: "Wrong password, try again.") }
    /// Where the password goes.
    public static var promise: String { String(localized: "Goes only to sudo, never stored.") }
    /// The disclosure that shows the command.
    public static var details: String { String(localized: "Details") }
    public static var ok: String { String(localized: "OK") }
    public static var cancel: String { String(localized: "Cancel") }
    /// sudo's usual prompt in the user's language; any other prompt
    /// ("Password for derek:") is shown as sudo wrote it.
    public static func promptLabel(_ prompt: String) -> String {
        prompt == "Password:" ? String(localized: "Password:") : prompt
    }

    /// "To upgrade windows-app." from the command in the context; a
    /// generic line when there is no context or it isn't a brew install,
    /// reinstall, upgrade or uninstall.
    public static func purpose(_ r: Askpass.Request) -> String {
        guard let step = r.context.flatMap(Askpass.step(command:)) else {
            return String(localized: "For a brew step that needs administrator rights.")
        }
        let names = step.names.joined(separator: ", ")
        switch step.action {
        case .install: return String(localized: "To install \(names).")
        case .reinstall: return String(localized: "To reinstall \(names).")
        case .upgrade: return String(localized: "To upgrade \(names).")
        case .uninstall: return String(localized: "To uninstall \(names).")
        }
    }

    /// The text under the title: two short lines.
    public static func body(_ r: Askpass.Request) -> String {
        purpose(r) + "\n" + promise
    }

    /// What Details shows: the command, as Tankard displays it; nil without one.
    public static func command(_ r: Askpass.Request) -> String? { r.context }

    /// The describe hook's output: every visible string, one per line.
    public static func describe(_ r: Askpass.Request) -> String {
        var lines = [r.isRetry ? retryTitle : title, body(r), promptLabel(r.prompt) + " [secure text field]"]
        if let c = command(r) { lines.append("[▸ \(details)] \(c)") }
        lines.append("[\(ok)] [\(cancel)]")
        return lines.joined(separator: "\n") + "\n"
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
