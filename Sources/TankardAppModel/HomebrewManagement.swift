import Foundation
import TankardCore

/// 0.4 (part A): the Homebrew menu. "Revert to standard Homebrew…"
/// (Intelbrew mode only) and "Uninstall Homebrew…". Both open Terminal with
/// a `.command` script after a sheet that shows every command and a typed
/// confirmation. Neither ever runs inside the app.
public enum HomebrewManagement {
    public enum Kind: String, Sendable, Identifiable, CaseIterable {
        case revert, uninstall
        public var id: String { rawValue }

        /// What the user types to enable the button.
        public var confirmationWord: String { rawValue }

        public var title: String {
            switch self {
            case .revert: return "Revert to Standard Homebrew…"
            case .uninstall: return "Uninstall Homebrew…"
            }
        }
    }

    /// Exact match after trimming, ignoring case ("Revert" counts; "rev" doesn't).
    public static func isConfirmed(_ typed: String, for kind: Kind) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == kind.confirmationWord
    }

    /// Homebrew's official uninstaller, verbatim from the Homebrew/install
    /// README ("Uninstall Homebrew"). It asks again before removing anything.
    /// On its own it picks the prefix itself (/opt/homebrew first on Apple
    /// silicon), so Tankard always runs `uninstallCommand(prefix:)` instead.
    public static let officialUninstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)""#

    /// The official uninstaller pinned to the prefix Tankard detected, with
    /// uninstall.sh's own `--path=PATH` option ("Sets Homebrew prefix"; the
    /// README's "uninstall Homebrew from a specific prefix"). Under `bash -c`
    /// the first argument after the script is `$0`, so "uninstall.sh" fills
    /// it and `--path` arrives as `$1`. Without it, a Mac with both
    /// /usr/local and /opt/homebrew would lose /opt/homebrew even though the
    /// sheet named /usr/local.
    public static func uninstallCommand(prefix: String) -> String {
        officialUninstallCommand + " uninstall.sh --path=" + singleQuoted(prefix)
    }

    /// Always single-quoted (unlike `BrewCommands.shellQuoted`), embedded
    /// single quotes as '\''.
    public static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Upstream Homebrew/brew, as in d4rkwyng/intelbrew's README ("How do I
    /// go back to upstream Homebrew?").
    public static let upstreamBrewRemote = "https://github.com/Homebrew/brew"

    /// "tankard-backup-20261116-183000"
    public static func backupSuffix(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "tankard-backup-" + f.string(from: date)
    }

    /// The uninstall `.command` script: says what it runs, waits for
    /// Return, then runs the official uninstaller (which asks again) on
    /// `prefix` only.
    public static func uninstallScript(prefix: String) -> String {
        let command = uninstallCommand(prefix: prefix)
        return """
        #!/bin/bash
        # Written by Tankard. Runs Homebrew's official uninstaller in Terminal.
        echo \(BrewCommands.shellQuoted("Tankard: this runs Homebrew's official uninstaller on " + prefix + ":"))
        echo
        echo \(BrewCommands.shellQuoted("  " + command))
        echo
        echo "It removes that Homebrew and every package installed with it."
        read -r -p "Press Return to continue, or close this window to cancel. "
        \(command)
        echo
        echo "When it finishes, quit Tankard."

        """
    }
}

/// The steps from d4rkwyng/intelbrew's README ("How do I go back to
/// upstream Homebrew?"), as a script:
///
/// 1. Remove the three `export` lines from the shell profile files. The
///    installer writes them to `~/.zshenv` (and `$ZDOTDIR/.zshenv`), or
///    `~/.bash_profile` (or `.bash_login` / `.profile`) and `~/.bashrc`, and
///    rewrites existing assignments in any zsh or bash startup file
///    (docs/installer.md, "Shell profile"). Each file that has one is backed
///    up first, next to itself. A profile that is a symlink (a dotfiles
///    repo) is edited and backed up at its real path: BSD `sed -i` refuses
///    symlinks ("in-place editing only works for regular files").
/// 2. Point Homebrew/brew's origin back at upstream:
///    `git -C "$(brew --repository)" remote set-url origin https://github.com/Homebrew/brew`.
/// 3. `brew update`.
///
/// The README says to open a new terminal between 1 and 2, so brew no longer
/// sees the variables; the script unsets them instead, because it runs in a
/// shell that read the old profile. brew.env files are only reported, not
/// edited: the installer never writes them. The optional
/// `brew untap homebrew/core` is mentioned, not run.
public struct RevertPlan: Equatable, Sendable {
    public struct ProfileEdit: Equatable, Sendable, Identifiable {
        /// Absolute path of the startup file the shell reads.
        public var path: String
        /// "~/.zshenv"
        public var label: String
        /// `path` with symlinks resolved: the regular file that is backed
        /// up and edited. Equal to `path` unless the profile is a symlink.
        public var target: String
        /// "~/dotfiles/zshenv"
        public var targetLabel: String
        public var isSymlink: Bool { target != path }
        /// The lines that will be removed, exactly as they are in the file.
        public var lines: [String]
        public var id: String { path }
    }

    public var edits: [ProfileEdit]
    /// brew.env files that set an Intelbrew variable: "~/.homebrew/brew.env: HOMEBREW_CORE_GIT_REMOTE".
    public var brewEnvNotes: [String]
    public var repository: String
    public var brewPath: String
    public var backupSuffix: String

    /// The variables the installer adds.
    public static let keys = Intelbrew.keys

    /// sed's pattern (POSIX ERE, BSD sed) for those assignment lines. Swift
    /// matches the same lines with `matches(_:)`, so the sheet lists exactly
    /// what sed deletes.
    public static let sedPattern = "^[[:blank:]]*(export[[:blank:]]+)?(" + keys.joined(separator: "|") + ")="

    public static func matches(_ line: String) -> Bool {
        var rest = Substring(line)
        rest = rest.drop { $0 == " " || $0 == "\t" }
        if rest.hasPrefix("export"), let next = rest.dropFirst("export".count).first, next == " " || next == "\t" {
            rest = rest.dropFirst("export".count).drop { $0 == " " || $0 == "\t" }
        }
        return keys.contains { rest.hasPrefix($0 + "=") }
    }

    /// Every zsh and bash startup file the installer may have written or
    /// rewritten, whichever shell is the login shell now.
    public static func candidatePaths(home: String, zdotdir: String?) -> [String] {
        let zdot = (zdotdir?.isEmpty == false ? zdotdir! : home)
        var paths = ["\(home)/.zshenv", "\(zdot)/.zshenv"]
        paths += [".zprofile", ".zshrc", ".zlogin"].map { "\(zdot)/\($0)" }
        paths += [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { "\(home)/\($0)" }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public static func make(home: String, zdotdir: String?, repository: String, brewPath: String,
                            brewEnvFiles: [(String, [String: String])], date: Date = Date(),
                            read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                            resolve: (String) -> String = RevertPlan.realPath) -> RevertPlan {
        let tilde = { (p: String) -> String in p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p }
        var seenTargets = Set<String>()
        let edits: [ProfileEdit] = candidatePaths(home: home, zdotdir: zdotdir).compactMap { path -> ProfileEdit? in
            guard let text = read(path) else { return nil }
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init).filter(matches)
            guard !lines.isEmpty else { return nil }
            // Two profiles linked to one file: edit it once.
            let target = resolve(path)
            guard seenTargets.insert(target).inserted else { return nil }
            return ProfileEdit(path: path, label: tilde(path), target: target, targetLabel: tilde(target), lines: lines)
        }
        let notes = brewEnvFiles.flatMap { (label, vars) in
            keys.filter { vars[$0] != nil }.map { "\(label): \($0)" }
        }
        return RevertPlan(edits: edits, brewEnvNotes: notes, repository: repository, brewPath: brewPath,
                          backupSuffix: HomebrewManagement.backupSuffix(date))
    }

    /// When `path` itself is a symlink, the file it finally points to
    /// (realpath(3)); otherwise `path` unchanged (a symlinked parent such as
    /// /var doesn't matter to sed, and a missing file stays as it is).
    public static func realPath(_ path: String) -> String {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK, let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Every command the script runs, in order, as shown in the sheet.
    public var commands: [String] {
        let q = BrewCommands.shellQuoted
        var out: [String] = []
        for e in edits {
            out.append("cp -p \(q(e.target)) \(q(e.target + "." + backupSuffix))")
            out.append("/usr/bin/sed -i '' -E \(q("/" + Self.sedPattern + "/d")) \(q(e.target))")
        }
        out.append("unset " + Self.keys.joined(separator: " "))
        out.append("git -C \(q(repository)) remote set-url origin \(HomebrewManagement.upstreamBrewRemote)")
        out.append("\(q(brewPath)) update")
        return out
    }

    /// The `.command` script: the plan, a pause, then each command echoed
    /// and run, stopping at the first failure.
    public var script: String {
        var s = """
        #!/bin/bash
        # Written by Tankard. Reverts this Mac from Intelbrew to standard Homebrew,
        # following d4rkwyng/intelbrew's README ("How do I go back to upstream Homebrew?").
        set -e
        echo "Tankard: reverting to standard Homebrew. These commands will run:"
        echo

        """
        for c in commands { s += "echo \(BrewCommands.shellQuoted("  " + c))\n" }
        s += """
        echo
        read -r -p "Press Return to continue, or close this window to cancel. "

        """
        for c in commands {
            s += "echo \(BrewCommands.shellQuoted("$ " + c))\n\(c)\n"
        }
        s += """
        echo
        echo "Done. Open a new terminal window: windows that were already open keep the old settings."
        echo "Optionally, delete the core clone: brew untap homebrew/core"
        echo "Then return to Tankard and click Refresh."

        """
        return s
    }
}

/// Writes a `.command` file Terminal can open (the installers and the
/// Homebrew menu use these: the scripts ask questions and wait for Return).
public enum TerminalScript {
    public static func write(_ contents: String, name: String,
                             in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("tankard-\(name).command")
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

public extension AppStore {
    /// Demo mode reads made-up profile files instead of the real ones.
    @MainActor static var profileReader: ((String) -> String?)?

    /// The revert plan for this Mac (reads the profile files; changes
    /// nothing). nil outside Intelbrew mode.
    func revertPlan(date: Date = Date()) -> RevertPlan? {
        guard intelbrewMode, let client = try? resolvedClient() else { return nil }
        let process = client.sources.process
        let read = Self.profileReader ?? { try? String(contentsOfFile: $0, encoding: .utf8) }
        return RevertPlan.make(home: process["HOME"] ?? NSHomeDirectory(), zdotdir: process["ZDOTDIR"],
                               repository: client.installation.repository, brewPath: client.installation.brewPath,
                               brewEnvFiles: client.sources.brewEnvFiles, date: date, read: read)
    }

    /// Opens a Homebrew menu sheet (revert only in Intelbrew mode).
    func requestManagement(_ kind: HomebrewManagement.Kind) {
        if kind == .revert && !intelbrewMode { return }
        managementSheet = kind
    }
}
