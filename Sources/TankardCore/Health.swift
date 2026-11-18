import Foundation

// v0.6 (part A): deprecated/disabled data, `brew doctor` warnings, brew's
// failure messages, and the `brew autoremove --dry-run` plan. All parsing,
// no process: shapes taken from brew 7.0.14 (arm64 Mac, read-only runs and
// the Library/Homebrew sources: deprecate_disable.rb, cmd/doctor.rb,
// cleanup.rb, exceptions.rb, utils/lock.sh).

/// brew's deprecation and disable data for a formula or cask, from
/// `brew info --json=v2`: `deprecation_date`, `deprecation_reason`,
/// `deprecation_replacement_formula`, `deprecation_replacement_cask`, and
/// the same four for `disable_`. A date can be set in the future while the
/// flag is still false (openssl@3: deprecated 2030), so the flags in
/// `Package` decide; this only explains them.
public struct PackageLifecycle: Codable, Sendable, Equatable {
    public var deprecationDate: String?
    public var deprecationReason: String?
    public var deprecationReplacementFormula: String?
    public var deprecationReplacementCask: String?
    public var disableDate: String?
    public var disableReason: String?
    public var disableReplacementFormula: String?
    public var disableReplacementCask: String?

    public init(deprecationDate: String? = nil, deprecationReason: String? = nil,
                deprecationReplacementFormula: String? = nil, deprecationReplacementCask: String? = nil,
                disableDate: String? = nil, disableReason: String? = nil,
                disableReplacementFormula: String? = nil, disableReplacementCask: String? = nil) {
        self.deprecationDate = deprecationDate
        self.deprecationReason = deprecationReason
        self.deprecationReplacementFormula = deprecationReplacementFormula
        self.deprecationReplacementCask = deprecationReplacementCask
        self.disableDate = disableDate
        self.disableReason = disableReason
        self.disableReplacementFormula = disableReplacementFormula
        self.disableReplacementCask = disableReplacementCask
    }

    enum JSONKeys: String, CodingKey {
        case deprecationDate = "deprecation_date"
        case deprecationReason = "deprecation_reason"
        case deprecationReplacementFormula = "deprecation_replacement_formula"
        case deprecationReplacementCask = "deprecation_replacement_cask"
        case disableDate = "disable_date"
        case disableReason = "disable_reason"
        case disableReplacementFormula = "disable_replacement_formula"
        case disableReplacementCask = "disable_replacement_cask"
    }

    /// From a formula or cask object of `brew info --json=v2`. nil when
    /// none of the fields is set.
    static func decodeBrew(from decoder: Decoder) -> PackageLifecycle? {
        guard let c = try? decoder.container(keyedBy: JSONKeys.self) else { return nil }
        func s(_ k: JSONKeys) -> String? {
            guard let v = (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil, !v.isEmpty else { return nil }
            return v
        }
        let l = PackageLifecycle(deprecationDate: s(.deprecationDate), deprecationReason: s(.deprecationReason),
                                 deprecationReplacementFormula: s(.deprecationReplacementFormula),
                                 deprecationReplacementCask: s(.deprecationReplacementCask),
                                 disableDate: s(.disableDate), disableReason: s(.disableReason),
                                 disableReplacementFormula: s(.disableReplacementFormula),
                                 disableReplacementCask: s(.disableReplacementCask))
        return l == PackageLifecycle() ? nil : l
    }

    /// brew's reason symbols in words (DeprecateDisable's two tables, brew
    /// 7.0.14). Anything else is brew's own free text and shown as is.
    public static let reasonText: [String: String] = [
        "does_not_build": String(localized: "does not build"),
        "no_license": String(localized: "has no license"),
        "repo_archived": String(localized: "has an archived upstream repository"),
        "repo_removed": String(localized: "has a removed upstream repository"),
        "unmaintained": String(localized: "is not maintained upstream"),
        "unreachable": String(localized: "is no longer reliably reachable upstream"),
        "unsupported": String(localized: "is not supported upstream"),
        "deprecated_upstream": String(localized: "is deprecated upstream"),
        "versioned_formula": String(localized: "is a versioned formula"),
        "checksum_mismatch": String(localized: "was built from a source file whose checksum changed upstream"),
        "discontinued": String(localized: "is discontinued upstream"),
        "moved_to_mas": String(localized: "is now only on the Mac App Store"),
        "no_longer_available": String(localized: "is no longer available upstream"),
        "no_longer_meets_criteria": String(localized: "no longer meets the criteria for casks"),
        "fails_gatekeeper_check": String(localized: "does not pass the macOS Gatekeeper check"),
    ]

    public static func describe(reason: String?) -> String? {
        guard let r = reason?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        let key = r.hasPrefix(":") ? String(r.dropFirst()) : r
        return reasonText[key] ?? r
    }
}

/// A replacement brew names for a deprecated or disabled package.
public struct PackageReplacement: Equatable, Sendable {
    public var name: String
    public var kind: PackageKind
    public init(name: String, kind: PackageKind) {
        self.name = name
        self.kind = kind
    }
}

// MARK: - brew's failures

/// Why a brew command failed, when its output says so in a way Tankard
/// recognises. The raw output is always shown too.
public enum BrewFailureKind: String, Sendable, Equatable, CaseIterable {
    /// brew's lock: another brew is running (utils/lock.sh, or
    /// OperationInProgressError in exceptions.rb).
    case locked
    case network
    case diskFull
    case permissions
    /// 0.8.1: macOS's App Management permission stopped a change to an app
    /// in an Applications folder (Privacy & Security → App Management).
    case appManagement
    /// 0.8.3: a download didn't match the checksum brew expected
    /// (exceptions.rb ChecksumMismatchError: "SHA-256 mismatch").
    case checksum
    /// 0.8.6 (walkthrough L1): the download isn't on the server (HTTP 404):
    /// retrying the same address fails the same way.
    case notFound
    /// 0.8.6 (walkthrough L1): building from source failed.
    case buildFailed

    public var title: String {
        switch self {
        case .appManagement: return String(localized: "macOS blocked changing an app")
        case .locked: return String(localized: "Another Homebrew command is running")
        case .network: return String(localized: "Homebrew couldn't reach the network")
        case .diskFull: return String(localized: "The disk is full")
        case .permissions: return String(localized: "Homebrew couldn't write to its folders")
        case .checksum: return String(localized: "A download didn't match its checksum")
        case .notFound: return String(localized: "The download isn't on the server")
        case .buildFailed: return String(localized: "The build from source failed")
        }
    }

    public var explanation: String {
        switch self {
        case .appManagement:
            return String(localized: "Tankard needs App Management permission. Allow it in System Settings → Privacy & Security → App Management, relaunch Tankard, then try again.")
        case .locked:
            return String(localized: "brew allows one command at a time. Wait for the other one (in Terminal, or another app) to finish, then retry.")
        case .network:
            return String(localized: "A download failed. Check the internet connection (or a VPN or proxy), then retry.")
        case .diskFull:
            return String(localized: "There's no space left to download or unpack. Free some space (Clean Up helps), then retry.")
        case .permissions:
            return String(localized: "The Homebrew folders aren't writable by this user. `brew doctor` (Homebrew ▸ Health) usually says which, and the command to fix it.")
        case .checksum:
            return String(localized: "The file brew downloaded isn't the one it expected: often an interrupted download, or a package that changed since brew last updated. Refresh (it runs brew update), then retry.")
        case .notFound:
            return String(localized: "The server answered 404 (not found) for the package's download. Trying the same address again fails the same way; brew update may bring a new one.")
        case .buildFailed:
            return String(localized: "brew couldn't build it on this Mac. The log below shows where it stopped; a newer version after brew update may build.")
        }
    }
}

public enum BrewFailure {
    /// The first kind the lines match, most specific first (a lock message
    /// also says "process", a disk-full error can mention a path).
    public static func classify<S: Sequence>(_ lines: S) -> BrewFailureKind? where S.Element == String {
        let text = lines.joined(separator: "\n").lowercased()
        if text.contains("process is already running") || text.contains("process has already locked")
            || text.contains("another active homebrew") || text.contains("operationinprogresserror")
            || (text.contains("flock") && text.contains("lock")) {
            return .locked
        }
        if isAppManagementBlock(lines.map { $0 }) { return .appManagement }
        if text.contains("sha-256 mismatch") || text.contains("sha256 mismatch") || text.contains("checksum mismatch") {
            return .checksum
        }
        // 0.8.6 (L1): before the network check (curl's 22 is an HTTP error, not a lost connection).
        if text.contains("returned error: 404") || text.contains("404 not found") {
            return .notFound
        }
        if text.contains("no space left on device") || text.contains("disk full") || text.contains("enospc") {
            return .diskFull
        }
        if text.contains("could not resolve host") || text.contains("failed to connect to")
            || text.contains("network is unreachable") || text.contains("connection timed out")
            || text.contains("operation timed out") || text.contains("curl: (6)") || text.contains("curl: (7)")
            || text.contains("curl: (28)") || text.contains("curl: (35)") || text.contains("temporary failure in name resolution") {
            return .network
        }
        if text.contains("an exception occurred within a child process") || text.contains("failed executing:")
            || text.contains("builderror") || text.contains("/library/logs/homebrew/") {
            return .buildFailed
        }
        if text.contains("permission denied") || text.contains("operation not permitted")
            || text.contains("is not writable") || text.contains("eacces") {
            return .permissions
        }
        return nil
    }

    /// 0.8.1: brew's output shows macOS's App Management permission
    /// blocking a change to an app. Matches brew 7's own messages
    /// (cask/staged.rb, install_steps.rb: "... because your terminal does
    /// not have App Management permissions."; cask/quarantine.rb: "Your
    /// terminal does not have App Management permissions"), macOS's
    /// "was prevented from modifying apps", and "Operation not permitted" on
    /// a path in an Applications folder (what touch/rm/mv/chown print when
    /// TCC refuses: brew's own write test prints
    /// "touch: <app>/.homebrew-write-test: Operation not permitted").
    public static func isAppManagementBlock<S: Sequence>(_ lines: S) -> Bool where S.Element == String {
        lines.contains { line in
            let l = line.lowercased()
            if l.contains("app management permission") { return true }
            if l.contains("prevented from modifying apps") { return true }
            if l.contains("operation not permitted"), l.contains("/applications/") { return true }
            return false
        }
    }
}

/// 0.8: brew commands that refuse and still exit 0. brew 7.0.14's
/// uninstall.rb and cask/uninstall.rb (and reinstall) print
/// "Error: <name> is pinned. You must unpin it to uninstall." with `onoe`,
/// which doesn't set a failing exit status, so the queue would see success
/// while nothing changed.
public enum BrewRefusal {
    /// 0.8.6 (walkthrough M3): brew had nothing to do. `brew upgrade x`
    /// after another brew (Terminal) upgraded it prints "Warning:
    /// <tap>/x 1.2 already installed" and exits 0. Only when nothing was
    /// upgraded, poured or built in the same output.
    public static func alreadyInstalled<S: Sequence>(_ lines: S) -> Bool where S.Element == String {
        var already = false
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("==> Upgrading") || l.hasPrefix("==> Pouring") || l.hasPrefix("==> Installing")
                || l.hasPrefix("==> Summary") || l.hasPrefix("==> Moving App") || l.hasPrefix("==> Downloading") {
                return false
            }
            if l.hasPrefix("Warning: "), l.hasSuffix(" already installed") || l.hasSuffix(" already installed.") { already = true }
        }
        return already
    }

    public static func pinned<S: Sequence>(_ lines: S) -> Bool where S.Element == String {
        lines.contains { $0.contains(" is pinned. You must unpin it to ") }
    }

    /// 0.8.4: plain `brew uninstall` removes one keg; with more installed it
    /// prints "hello 1.0 is still installed." (or "hello 1.0 and 1.1 are
    /// still installed.") and exits 0 (brew 7.0.14 uninstall.rb:86). The
    /// versions it names for `name`, or nil when it printed no such line.
    public static func stillInstalled<S: Sequence>(_ lines: S, name: String) -> [String]? where S.Element == String {
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix(name + " ") else { continue }
            var rest = l.dropFirst(name.count + 1)
            if rest.hasSuffix(" is still installed.") {
                rest = rest.dropLast(" is still installed.".count)
            } else if rest.hasSuffix(" are still installed.") {
                rest = rest.dropLast(" are still installed.".count)
            } else {
                continue
            }
            // Utils::Text.to_sentence: "a", "a and b", "a, b, and c".
            let versions = rest.replacingOccurrences(of: ", and ", with: ", ")
                .replacingOccurrences(of: " and ", with: ", ")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return versions
        }
        return nil
    }
}

// MARK: - brew doctor

/// One `Warning:` block of `brew doctor`.
public struct DoctorWarning: Equatable, Sendable, Identifiable {
    public var id: Int
    /// brew's first line, without "Warning: ".
    public var headline: String
    /// The whole block as brew printed it (headline included).
    public var raw: String
    public var kind: DoctorWarningKind?

    /// A plain-English title (brew's headline when the kind isn't known).
    public var title: String { kind?.title ?? headline }
    /// 0.8.5 (newbie review H5): a note that rarely matters in practice:
    /// shown as neutral information, not a warning. Unknown ones aren't.
    public var isHarmless: Bool { kind?.isHarmless ?? false }
    /// 0.8.5: what Tankard can do about it itself, instead of a command.
    public var action: DoctorFixAction? { kind?.action }
    public var explanation: String? { kind?.explanation }

    /// The command to fix it, shown and never run: the first indented
    /// command line in brew's block, else the kind's own.
    public var fixCommand: String? {
        let found = firstCommand
        // brew's fallback for broken CLT is `sudo rm -rf …`; lead with the
        // safe step and leave the destructive one in brew's text.
        if let found, found.contains("rm -rf"), let safe = kind?.defaultCommand { return safe }
        return found ?? kind?.defaultCommand
    }

    private var firstCommand: String? {
        for line in raw.split(separator: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("  "), !t.isEmpty else { continue }
            if t.hasPrefix("brew ") || t.hasPrefix("sudo ") || t.hasPrefix("printf ") || t.hasPrefix("echo ")
                || t.hasPrefix("export ") || t.hasPrefix("xcode-select") || t.hasPrefix("git ")
                || t.hasPrefix("rm ") || t.hasPrefix("chown ") || t.hasPrefix("softwareupdate") {
                return t
            }
        }
        return nil
    }
}

/// The doctor warnings Tankard explains. Matched on brew 7.0.14's wording
/// (Library/Homebrew/diagnostic.rb and extend/os/mac/diagnostic.rb).
public enum DoctorWarningKind: String, Sendable, Equatable, CaseIterable {
    case deprecatedDisabled
    case pathOrder
    case sbinNotInPath
    case unlinkedKegs
    case brokenSymlinks
    case strayFiles
    case outdatedCLT
    case outdatedXcode
    case unsupportedMacOS
    case missingDependencies
    case untrustedTaps
    case gitDirty
    case notWritable

    static func match(_ headline: String) -> DoctorWarningKind? {
        let h = headline.lowercased()
        if h.contains("deprecated or disabled") { return .deprecatedDisabled }
        if h.contains("\"sbin\" was not found in your path") { return .sbinNotInPath }
        if h.contains("/usr/bin occurs before") || h.contains("is not in your path") { return .pathOrder }
        if h.contains("unlinked kegs") { return .unlinkedKegs }
        if h.contains("broken symlinks") { return .brokenSymlinks }
        if h.contains("unbrewed") { return .strayFiles }
        if h.contains("command line tools") && (h.contains("outdated") || h.contains("too old") || h.contains("newer")) { return .outdatedCLT }
        if h.contains("xcode") && (h.contains("outdated") || h.contains("too old")) { return .outdatedXcode }
        if h.contains("you are using macos") || h.contains("unsupported") { return .unsupportedMacOS }
        if h.contains("missing dependencies") { return .missingDependencies }
        if h.contains("untrusted") { return .untrustedTaps }
        if h.contains("uncommitted modifications") || h.contains("not on the main branch") { return .gitDirty }
        if h.contains("not writable") { return .notWritable }
        return nil
    }

    public var title: String {
        switch self {
        case .deprecatedDisabled: return String(localized: "Some packages are deprecated or disabled")
        case .pathOrder: return String(localized: "Your PATH finds other tools before Homebrew's")
        case .sbinNotInPath: return String(localized: "Homebrew's sbin folder isn't in your PATH")
        case .unlinkedKegs: return String(localized: "Some packages are installed but not linked")
        case .brokenSymlinks: return String(localized: "There are broken links in Homebrew's folders")
        case .strayFiles: return String(localized: "Files Homebrew didn't install are in its folders")
        case .outdatedCLT: return String(localized: "The Command Line Tools are out of date")
        case .outdatedXcode: return String(localized: "Xcode is out of date")
        case .unsupportedMacOS: return String(localized: "This macOS version isn't supported by Homebrew")
        case .missingDependencies: return String(localized: "Some packages are missing dependencies")
        case .untrustedTaps: return String(localized: "Some taps aren't trusted")
        case .gitDirty: return String(localized: "Homebrew's own files have local changes")
        case .notWritable: return String(localized: "Some Homebrew folders aren't writable")
        }
    }

    public var explanation: String {
        switch self {
        case .deprecatedDisabled:
            return String(localized: "Homebrew no longer maintains them, or soon won't. The Deprecated filter lists them, with the replacement when brew names one.")
        case .pathOrder:
            return String(localized: "Commands in your shell may run the system's copy instead of Homebrew's. Only your shell profile changes this.")
        case .sbinNotInPath:
            return String(localized: "Some installed tools put commands in sbin; your shell won't find them by name until it's in PATH.")
        case .unlinkedKegs:
            return String(localized: "Their commands and libraries aren't in Homebrew's prefix. Usually an install or upgrade was interrupted.")
        case .brokenSymlinks:
            return String(localized: "Leftover links point at files that are gone. Usually harmless; brew cleanup removes most of them.")
        case .strayFiles:
            return String(localized: "Another installer put files in Homebrew's prefix. They can confuse builds from source.")
        case .outdatedCLT:
            return String(localized: "Formulae that build from source may fail. Software Update installs the new version.")
        case .outdatedXcode:
            return String(localized: "Formulae that build from source may fail. The App Store updates Xcode.")
        case .unsupportedMacOS:
            return String(localized: "Bottles may be missing and Homebrew won't help with issues. Things often still work.")
        case .missingDependencies:
            return String(localized: "A package needs something that isn't installed. Installing the missing ones fixes it.")
        case .untrustedTaps:
            return String(localized: "brew won't load formulae from third-party taps until you trust them.")
        case .gitDirty:
            return String(localized: "Edits in Homebrew's checkout can stop brew update. Resetting it discards them.")
        case .notWritable:
            return String(localized: "brew can't update or install while it can't write there.")
        }
    }

    /// 0.8.5: notes that don't stop anything from working for most people
    /// (brew's own doctor text says "if everything works, ignore them").
    public var isHarmless: Bool {
        switch self {
        case .strayFiles, .outdatedCLT, .outdatedXcode, .unsupportedMacOS, .brokenSymlinks,
             .sbinNotInPath, .deprecatedDisabled, .untrustedTaps:
            return true
        case .pathOrder, .unlinkedKegs, .missingDependencies, .gitDirty, .notWritable:
            return false
        }
    }

    /// 0.8.5: Tankard's own button for it, where it has one.
    public var action: DoctorFixAction? {
        switch self {
        case .brokenSymlinks: return .cleanUp
        case .outdatedCLT: return .softwareUpdate
        default: return nil
        }
    }

    /// A command when brew's block gives none.
    public var defaultCommand: String? {
        switch self {
        case .brokenSymlinks: return "brew cleanup"
        case .missingDependencies: return "brew missing"
        case .outdatedCLT: return "softwareupdate --list"
        default: return nil
        }
    }
}

/// 0.8.5: a button the Health sheet offers instead of a Terminal command.
public enum DoctorFixAction: String, Sendable, Equatable {
    /// Tankard's Clean Up… (the same `brew cleanup`).
    case cleanUp
    /// System Settings ▸ Software Update (the Command Line Tools update).
    case softwareUpdate
}

public struct DoctorReport: Equatable, Sendable {
    public var warnings: [DoctorWarning]
    /// brew's note that the warnings are for Homebrew maintainers.
    public var maintainersNote: Bool
    /// `Your system is ready to brew.`
    public var ready: Bool

    public static let maintainersMarker = "these warnings are just used to help the Homebrew maintainers"

    /// Parses the merged stdout and stderr of `brew doctor` (it exits 1
    /// whenever it warns; that's normal).
    public static func parse(_ text: String) -> DoctorReport {
        var warnings: [DoctorWarning] = []
        var current: [String]?
        func close() {
            guard var block = current else { return }
            while let last = block.last, last.trimmingCharacters(in: .whitespaces).isEmpty { block.removeLast() }
            let headline = String(block.first?.dropFirst("Warning: ".count) ?? "")
            warnings.append(DoctorWarning(id: warnings.count, headline: headline,
                                          raw: block.joined(separator: "\n"), kind: DoctorWarningKind.match(headline)))
            current = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("Warning: ") {
                close()
                current = [line]
            } else if current != nil {
                current?.append(line)
            }
        }
        close()
        // brew's headline can wrap onto the next line; take the first sentence's lines.
        for i in warnings.indices where warnings[i].kind == nil {
            let joined = warnings[i].raw.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: " ")
            if let k = DoctorWarningKind.match(joined) { warnings[i].kind = k }
        }
        return DoctorReport(warnings: warnings,
                            maintainersNote: text.contains(maintainersMarker),
                            ready: text.contains("Your system is ready to brew"))
    }
}

/// `brew missing`: "<formula>: <missing> <missing>" lines.
public enum MissingDependencies {
    public static func parse(_ text: String) -> [(formula: String, missing: [String])] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let missing = parts[1].split(separator: " ").map(String.init)
            guard !missing.isEmpty else { return nil }
            return (String(parts[0]).trimmingCharacters(in: .whitespaces), missing)
        }
    }
}

// MARK: - brew autoremove

/// What `brew autoremove --dry-run` would uninstall. brew 7.0.14
/// (cleanup.rb) prints `==> Would autoremove N unneeded formula(e):` and
/// then one full name per line; nothing at all when there is nothing.
public struct AutoremovePlan: Equatable, Sendable {
    public var formulae: [String]

    public init(formulae: [String]) { self.formulae = formulae }

    public static let dryRunArguments = ["autoremove", "--dry-run"]
    public static let runArguments = ["autoremove"]

    public static func parse(_ text: String) -> AutoremovePlan {
        var names: [String] = []
        var inList = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                inList = line.lowercased().contains("would autoremove")
                continue
            }
            guard inList else { continue }
            if line.isEmpty { inList = false; continue }
            if line.hasPrefix("Warning:") || line.hasPrefix("Error:") { inList = false; continue }
            names.append(line)
        }
        return AutoremovePlan(formulae: names)
    }

    /// The command that keeps one of them: mark it installed on request.
    public static func keepCommand(_ name: String) -> String {
        "brew tab --installed-on-request \(name)"
    }

    /// 0.8.5: `brew tab --installed-on-request --formula a b`: marks them as
    /// installed by you, which is brew's own way to keep a formula out of
    /// every later `brew autoremove` (and what it needs with it).
    public static func keepArguments(_ names: [String]) -> [String] {
        ["tab", "--installed-on-request", "--formula"] + names
    }

    /// 0.8.5: formulae people often use directly in Terminal (python3, node,
    /// ruby…) although Homebrew installed them only for something else.
    /// Removing one breaks the command, so the sheet flags them.
    public static func oftenUsedDirectly(_ name: String) -> Bool {
        let short = name.split(separator: "/").last.map(String.init) ?? name
        let base = short.split(separator: "@").first.map(String.init) ?? short
        return directUseNames.contains(base)
    }

    static let directUseNames: Set<String> = [
        "python", "node", "ruby", "perl", "php", "go", "rust", "openjdk", "lua", "deno", "bun",
        "git", "curl", "wget", "sqlite", "postgresql", "mysql", "redis", "gcc", "llvm", "cmake",
        "imagemagick", "ffmpeg", "pandoc", "jq", "yarn", "pnpm", "erlang", "elixir", "ghc", "dotnet",
    ]
}
