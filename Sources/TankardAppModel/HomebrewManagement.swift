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
            case .revert: return String(localized: "Revert to Standard Homebrew…")
            case .uninstall: return String(localized: "Uninstall Homebrew…")
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
        /// 1-based numbers of removed lines that are the only command in an
        /// if / while / until / for / select / `{ }` body of a bash startup
        /// file: deleting them would leave an empty block, which bash
        /// rejects (zsh accepts one). Such a file is not edited; the sheet
        /// says to remove the lines by hand.
        public var emptiedBlockLines: [Int] = []
        /// The script backs up and edits this file.
        public var isAutomatic: Bool { emptiedBlockLines.isEmpty }
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
            let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let emptied = isZshFile(path) ? [] : emptiedBlocks(all)
            return ProfileEdit(path: path, label: tilde(path), target: target, targetLabel: tilde(target),
                               emptiedBlockLines: emptied, lines: lines)
        }
        let notes = brewEnvFiles.flatMap { (label, vars) in
            keys.filter { vars[$0] != nil }.map { "\(label): \($0)" }
        }
        return RevertPlan(edits: edits, brewEnvNotes: notes, repository: repository, brewPath: brewPath,
                          backupSuffix: HomebrewManagement.backupSuffix(date))
    }

    /// zsh's startup files (zsh runs an empty block; bash doesn't).
    static func isZshFile(_ path: String) -> Bool {
        [".zshenv", ".zprofile", ".zshrc", ".zlogin"].contains((path as NSString).lastPathComponent)
    }

    /// Line numbers (1-based) of lines `matches` would remove that are the
    /// only command in a compound command's body (`then`, `else`, `do`,
    /// `{`), so removing them leaves `then fi` or `{ }`: a bash syntax error.
    /// A line-based reading of the shell, enough for startup files: keywords
    /// count in command position, `#` starts a comment, quotes and here
    /// documents aren't parsed. `case` bodies may be empty and aren't checked.
    public static func emptiedBlocks(_ lines: [String]) -> [Int] {
        struct Segment { var body: Bool; var content = false; var removed: [Int] = [] }
        var stack: [Segment] = []   // the current segment of each open block
        var found: [Int] = []
        func finish() {
            guard let seg = stack.last, seg.body, !seg.content, !seg.removed.isEmpty else { return }
            found += seg.removed
        }
        func next(body: Bool) {
            guard !stack.isEmpty else { return }
            finish()
            stack[stack.count - 1] = Segment(body: body)
        }
        func close() {
            guard !stack.isEmpty else { return }
            finish()
            stack.removeLast()
        }
        for (i, line) in lines.enumerated() {
            if matches(line) {
                if !stack.isEmpty { stack[stack.count - 1].removed.append(i + 1) }
                continue
            }
            // Tokens: words, with ; & | ( ) as their own tokens.
            var tokens: [String] = []
            var word = ""
            for ch in line {
                if ch == " " || ch == "\t" {
                    if !word.isEmpty { tokens.append(word); word = "" }
                } else if ";&|()".contains(ch) {
                    if !word.isEmpty { tokens.append(word); word = "" }
                    tokens.append(String(ch))
                } else {
                    word.append(ch)
                }
            }
            if !word.isEmpty { tokens.append(word) }
            var commandPosition = true
            for t in tokens {
                if t.hasPrefix("#") { break }
                if ";&|()".contains(t) { commandPosition = true; continue }
                guard commandPosition else {
                    if !stack.isEmpty { stack[stack.count - 1].content = true }
                    if t == "{" { stack.append(Segment(body: true)) }   // function f {
                    continue
                }
                switch t {
                case "if", "while", "until": stack.append(Segment(body: false))
                case "for", "select", "case": stack.append(Segment(body: false)); commandPosition = false; continue
                case "then", "do", "else": next(body: true)
                case "elif": next(body: false)
                case "{": stack.append(Segment(body: true))
                case "fi", "done", "esac", "}": close()
                case "!": break
                default:
                    if !stack.isEmpty { stack[stack.count - 1].content = true }
                    commandPosition = false
                    continue
                }
                commandPosition = true
            }
        }
        return found
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
        for e in edits where e.isAutomatic {
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
        for e in edits where !e.isAutomatic {
            let where_ = "line" + (e.emptiedBlockLines.count == 1 ? " " : "s ") + e.emptiedBlockLines.map(String.init).joined(separator: ", ")
            s += "echo \(BrewCommands.shellQuoted("  Not edited: \(e.label) (\(where_) would leave an empty block). Remove its Intelbrew lines by hand."))\n"
        }
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
///
/// 0.8.8 (security review #10): each script goes in a new folder of its own
/// (`mkdtemp`, mode 0700) in the per-user temporary directory, created with
/// O_CREAT|O_EXCL|O_NOFOLLOW at mode 0700. Before, a fixed name such as
/// $TMPDIR/tankard-uninstall.command let another process of the user's
/// predict it and swap it between Tankard's write and Terminal's read. The
/// file keeps its readable name (Terminal shows it as the window title).
public enum TerminalScript {
    public enum WriteError: Error, Equatable {
        case directory(Int32)
        case file(Int32)
    }

    public static func write(_ contents: String, name: String,
                             in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try writeUnique(contents, fileName: "tankard-\(name).command", in: directory)
    }

    static func writeUnique(_ contents: String, fileName: String, in directory: URL) throws -> URL {
        var template = Array(directory.appendingPathComponent("tankard-XXXXXXXX").path.utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }).map({ String(cString: $0) }) else {
            throw WriteError.directory(errno)
        }
        let path = (dir as NSString).appendingPathComponent(fileName)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard fd >= 0 else { throw WriteError.file(errno) }
        defer { close(fd) }
        // open(2)'s mode is masked by the umask: set it exactly.
        guard fchmod(fd, 0o700) == 0 else { throw WriteError.file(errno) }
        let bytes = Array(contents.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + written, $0.count - written) }
            if n > 0 { written += n } else if n < 0 && errno == EINTR { continue } else { throw WriteError.file(errno) }
        }
        return URL(fileURLWithPath: path)
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
        // 0.8.4: demo mode doesn't resolve symlinks on this Mac's disk either.
        let demo = Self.profileReader != nil
        let resolve: (String) -> String = { path in demo ? path : RevertPlan.realPath(path) }
        return RevertPlan.make(home: process["HOME"] ?? NSHomeDirectory(), zdotdir: process["ZDOTDIR"],
                               repository: client.installation.repository, brewPath: client.installation.brewPath,
                               brewEnvFiles: client.sources.brewEnvFiles, date: date, read: read, resolve: resolve)
    }

    /// Opens a Homebrew menu sheet (revert only in Intelbrew mode).
    func requestManagement(_ kind: HomebrewManagement.Kind) {
        if kind == .revert && !intelbrewMode { return }
        managementSheet = kind
    }
}
