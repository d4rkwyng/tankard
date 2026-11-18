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

    /// Cask installs, adopts, upgrades and uninstalls write into
    /// /Applications (0.8.1: install and adopt too; adopt runs
    /// `brew install --cask --adopt`, which changes the user's existing app
    /// in place). Formula operations (and Replace with bottle) never
    /// trigger the flow. 0.8:
    /// nor does a cask that puts nothing in an Applications folder (a font,
    /// a CLI tool): the explainer is shown only for casks with an `app` or
    /// `suite` artifact, or a pkg installer (which can install apps).
    public static func modifiesApps(_ action: SessionAction, _ p: Package) -> Bool {
        isCaskChange(action, p) && hasApps(p)
    }

    /// A cask install, adopt, upgrade or uninstall, whatever it installs.
    /// brew's output is still checked for the block on every one of these.
    public static func isCaskChange(_ action: SessionAction, _ p: Package) -> Bool {
        p.kind == .cask && retryable(action)
    }

    /// 0.8.1: the actions Tankard can run again from a package list (after
    /// "I've done this", or after a relaunch). A restore's commands come
    /// from its plan, so it is run again from Restore Points instead.
    public static func retryable(_ action: SessionAction) -> Bool {
        [.upgrade, .install, .uninstall, .adopt].contains(action)
    }

    /// Whether the cask installs an app, a suite or a pkg. Unknown counts
    /// as yes: no artifacts read (a Discover row, brew gave none) or a
    /// report from before 0.8 (no suite/pkg fields yet).
    public static func hasApps(_ p: Package) -> Bool {
        guard let apps = p.appPaths, p.suitePaths != nil || p.installsPkg != nil else { return true }
        return !apps.isEmpty || !(p.suitePaths ?? []).isEmpty || p.installsPkg == true
    }

    /// Whether brew's output for a cask step shows macOS blocking it.
    ///
    /// Matches brew 7.0.14's own App Management messages (cask/staged.rb,
    /// install_steps.rb, cask/quarantine.rb: "does not have App Management
    /// permissions"), macOS's "was prevented from modifying apps", and
    /// "Operation not permitted" on a path in an Applications folder (what
    /// rename/rm/chown print when the move is blocked).
    public static func isPermissionBlock(_ lines: some Sequence<String>) -> Bool {
        BrewFailure.isAppManagementBlock(Array(lines))
    }

    /// 0.8.1: a brew command that writes into an Applications folder: a
    /// cask install (adopt too), reinstall, upgrade or uninstall. Used for
    /// sessions whose rows are commands (a restore's reinstall).
    public static func isCaskCommand(_ arguments: [String]) -> Bool {
        arguments.contains("--cask") && ["install", "reinstall", "upgrade", "uninstall"].contains(arguments.first ?? "")
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

// MARK: relaunch (0.8.1)

extension AppManagement {
    /// macOS applies an App Management grant to a process started after it:
    /// the system's own dialog says the app "will not be able to update or
    /// delete other applications until it is quit" (see
    /// docs/usage.md, App Management). So after "I've done this"
    /// Tankard offers to relaunch itself.
    ///
    /// The command that does it: a detached /bin/sh waits (at most ~10 s)
    /// for this process to exit, so the new one is a fresh process for TCC,
    /// then `open -n` starts the bundle again. If it is still running after
    /// the wait, nothing is opened (a second Tankard would start): the
    /// helper logs it (`logger -t Tankard`) and the user reopens it. Arguments are passed as
    /// positional parameters ($0 the bundle, $1 the pid), never spliced
    /// into the script.
    public static func relaunchCommand(bundlePath: String, pid: Int32, waitTenths: Int = 100) -> (executable: String, arguments: [String]) {
        let script = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt \(waitTenths) ]; do sleep 0.1; i=$((i+1)); done; "
            + "if kill -0 \"$1\" 2>/dev/null; then /usr/bin/logger -t Tankard \"relaunch: Tankard (pid $1) still running, not reopening\"; "
            + "echo \"still running\" >&2; exit 1; fi; exec /usr/bin/open -n \"$0\""
        return ("/bin/sh", ["-c", script, bundlePath, String(pid)])
    }

    /// Relaunch is offered only from a real app bundle (not `swift run`).
    public static func canRelaunch(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app")
    }

    /// The defaults suite prefix of scripted (e2e) runs.
    public static let e2eSuitePrefix = "net.mindtricks.tankard.e2e"

    /// A per-run e2e suite name (`net.mindtricks.tankard.e2e.<something>`),
    /// or nil: never the real settings' domain, the shared e2e suite itself
    /// or anything outside the prefix. ScriptLaunch uses the same rule.
    public static func validE2ESuite(_ requested: String?) -> String? {
        guard let r = requested, r.hasPrefix(e2eSuitePrefix + "."), r.count > e2eSuitePrefix.count + 1,
              r.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return nil }
        return r
    }

    /// What the relaunch helper (and so `open -n`, which passes its
    /// environment on to the app it starts) gives the new copy.
    public struct RelaunchEnvironment: Equatable, Sendable {
        public var environment: [String: String]
        /// Set when an e2e identity was dropped (for the relaunch log).
        public var note: String?
        /// The relaunched e2e copy's (empty) step file, to create first.
        public var scriptPath: String?
    }

    /// 0.8.4: the relaunched copy inherits no TANKARD_* variable (demo,
    /// snapshot, script, debug, update feed): before, an e2e run's new copy
    /// ran the parent's steps again and recreated its results.jsonl. Every
    /// other variable (HOMEBREW_* included) is kept as it is.
    ///
    /// A scripted e2e run (TANKARD_E2E=1, TANKARD_SCRIPT, a valid per-run
    /// TANKARD_E2E_SUITE) gets back only an isolated, idle e2e identity, so
    /// the new copy still never touches the real settings or Tankard's real
    /// files: the same suite and state folder (and self-update tap), an
    /// empty step file in <parent's out>/relaunched, which it stays open
    /// after. With TANKARD_E2E=1 but an invalid suite, nothing comes back
    /// (a normal relaunch) and `note` says why.
    public static func relaunchEnvironment(_ env: [String: String]) -> RelaunchEnvironment {
        var out = env.filter { !$0.key.hasPrefix("TANKARD_") }
        func value(_ k: String) -> String? { env[k].flatMap { $0.isEmpty ? nil : $0 } }
        guard env["TANKARD_E2E"] == "1", let script = value("TANKARD_SCRIPT") else {
            return RelaunchEnvironment(environment: out, note: nil, scriptPath: nil)
        }
        guard let suite = validE2ESuite(env["TANKARD_E2E_SUITE"]) else {
            return RelaunchEnvironment(environment: out,
                note: "relaunch: e2e identity dropped (invalid TANKARD_E2E_SUITE \(env["TANKARD_E2E_SUITE"].map { "'\($0)'" } ?? "unset")); the new copy starts as a normal app",
                scriptPath: nil)
        }
        // The parent's own defaults, as ScriptLaunch works them out.
        let parentOut = URL(fileURLWithPath: value("TANKARD_SCRIPT_OUT") ?? script + ".out", isDirectory: true)
        let state = value("TANKARD_E2E_STATE") ?? parentOut.appendingPathComponent("state", isDirectory: true).path
        let relOut = parentOut.appendingPathComponent("relaunched", isDirectory: true)
        let steps = relOut.appendingPathComponent("steps.txt").path
        out["TANKARD_E2E"] = "1"
        out["TANKARD_E2E_SUITE"] = suite
        out["TANKARD_E2E_STATE"] = state
        out["TANKARD_SCRIPT_OUT"] = relOut.path
        out["TANKARD_SCRIPT"] = steps
        out["TANKARD_SCRIPT_STAY"] = "1"
        for k in ["TANKARD_E2E_SELFUPDATE", "TANKARD_E2E_SELF_TAP"] { if let v = env[k] { out[k] = v } }
        return RelaunchEnvironment(environment: out, note: nil, scriptPath: steps)
    }

    /// Creates the relaunched e2e copy's folder and an empty step file
    /// (a missing one stops a script run with exit 2). Keeps one that exists.
    public static func prepareRelaunchScript(_ r: RelaunchEnvironment) throws {
        guard let path = r.scriptPath else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

/// 0.8.1: the operation to offer again once Tankard has relaunched, kept in
/// the defaults across the relaunch. Only for a short while: an old one is
/// dropped, never offered days later. It is never run on its own: the
/// relaunched app shows it ("Run again") and a click sends it through the
/// normal request path, with every gate.
public struct AppManagementPendingRetry: Codable, Equatable, Sendable {
    public static let maxAge: TimeInterval = 15 * 60

    public var action: String
    /// Only the targets that need App Management: casks that change apps.
    /// For an uninstall, only the package the user chose (its unused
    /// dependencies are worked out again by the normal path).
    public var packages: [Package]
    public var savedAt: Date
    /// Upgrade targets' ids that would compile when saved.
    public var compiling: [String]
    /// An adopt's self-update choices (qualified name → SelfUpdatePolicy raw value).
    public var policies: [String: String] = [:]

    public init(action: SessionAction, packages: [Package], savedAt: Date, compiling: Set<String> = []) {
        self.action = action.rawValue
        self.packages = packages
        self.savedAt = savedAt
        self.compiling = compiling.sorted()
    }

    /// What to save from a prompt's targets (nil: nothing needs saving).
    /// `root`: for an uninstall, the package the user chose.
    public static func make(action: SessionAction, targets: [Package], root: Package?, savedAt: Date,
                            compiles: (Package) -> Bool) -> AppManagementPendingRetry? {
        guard AppManagement.retryable(action) else { return nil }
        var keep = targets.filter { AppManagement.modifiesApps(action, $0) }
        if action == .uninstall {
            let chosen = root ?? targets.first
            keep = keep.filter { $0.id == chosen?.id }
        }
        guard !keep.isEmpty else { return nil }
        return AppManagementPendingRetry(action: action, packages: keep, savedAt: savedAt,
                                         compiling: Set(keep.filter(compiles).map(\.id)))
    }

    public var sessionAction: SessionAction? { SessionAction(rawValue: action) }

    /// What to offer now, against what brew says after the relaunch, and
    /// what was dropped (by name). An upgrade only if still outdated to the
    /// same version, with the same bottle-or-compile answer as when the user
    /// confirmed it; an uninstall only if still installed; an install or
    /// adopt only if still not installed. Nil: too old, not retryable, or
    /// nothing left.
    public func resolve(installed: [Package], now: Date,
                        compiles: (Package) -> Bool = { _ in false }) -> AppManagementResume? {
        guard now.timeIntervalSince(savedAt) >= 0, now.timeIntervalSince(savedAt) <= Self.maxAge,
              let a = sessionAction, AppManagement.retryable(a) else { return nil }
        let byID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var run: [Package] = []
        var dropped: [String] = []
        for saved in packages {
            let live = byID[saved.id]
            switch a {
            case .upgrade:
                if let live, live.upgradeAvailable, live.currentVersion == saved.currentVersion,
                   compiles(live) == compiling.contains(saved.id) {
                    run.append(live)
                } else {
                    dropped.append(saved.name)
                }
            case .uninstall:
                if let live { run.append(live) } else { dropped.append(saved.name) }
            default:
                if live == nil { run.append(saved) } else { dropped.append(saved.name) }
            }
        }
        guard !run.isEmpty else { return nil }
        let keys = Set(run.map(\.qualifiedName))
        return AppManagementResume(action: a, packages: run, dropped: dropped,
                                   policies: policies.filter { keys.contains($0.key) })
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> Self? { data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
}

/// 0.8.1: the "Run again" offer after a relaunch, waiting for a click.
public struct AppManagementResume: Equatable, Sendable {
    public var action: SessionAction
    public var packages: [Package]
    /// Saved targets that no longer apply (changed or already done).
    public var dropped: [String]
    /// An adopt's saved self-update choices (raw values), restored on Run again.
    public var policies: [String: String] = [:]
}

// MARK: probe (0.8.1)

/// Whether Tankard may change apps, found out the way brew does (brew's
/// cask/quarantine.rb writes its own `<app>/.homebrew-write-test` and treats
/// EPERM as "no App Management"): Tankard creates an empty
/// `.tankard-write-test` (`fileName`) at the top of a Homebrew-installed
/// app bundle and deletes it at once. Run only when the
/// user asks (Check in the welcome sheet), never at launch, and only on an
/// app from an installed cask's own artifact list: never on an app brew
/// doesn't manage. The attempt is also what makes macOS show its
/// "was prevented from modifying apps" notice and list Tankard in
/// App Management.
public enum AppManagementProbe {
    public enum Result: Equatable, Sendable { case allowed, blocked, unknown }

    public static let fileName = ".tankard-write-test"

    /// The first existing app of an installed cask (`packages`: brew's
    /// installed list; `appPaths` comes from the cask's own artifacts), in
    /// an Applications folder.
    public static func target(_ packages: [Package], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        for p in packages where p.kind == .cask {
            for path in p.appPaths ?? [] where path.hasSuffix(".app") && path.contains("/Applications/") && exists(path) {
                return path
            }
        }
        return nil
    }

    /// Writes and removes the test file. EPERM: blocked. Any other error
    /// (the app is gone, a read-only volume): unknown.
    public static func run(appPath: String) -> Result {
        let path = (appPath as NSString).appendingPathComponent(fileName)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 {
            let e = errno
            if e == EEXIST {
                // A leftover from an interrupted probe: ours, remove it.
                return unlink(path) == 0 ? .allowed : (errno == EPERM ? .blocked : .unknown)
            }
            return e == EPERM ? .blocked : .unknown
        }
        close(fd)
        unlink(path)
        return .allowed
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

    /// 0.8.1: the sheet's page. `relaunch`: after "I've done this", the
    /// offer to relaunch (macOS applies the grant to a new process).
    public enum Stage: Equatable, Sendable { case explain, relaunch }

    public var id = UUID()
    public var reason: Reason
    public var stage: Stage = .explain
    public var action: SessionAction
    /// The packages to run (firstUse) or retry (blocked).
    public var packages: [Package]

    public init(reason: Reason, action: SessionAction, packages: [Package]) {
        self.reason = reason
        self.action = action
        self.packages = packages
    }

    /// 0.8.1: whether Tankard can run it again itself (a restore can't).
    public var canRetry: Bool { AppManagement.retryable(action) && !packages.isEmpty }
}

/// The About panel and Help menu.
public enum AboutInfo {
    public static let repository = URL(string: "https://github.com/d4rkwyng/tankard")!
    public static let newIssue = URL(string: "https://github.com/d4rkwyng/tankard/issues/new")!
    /// Help ▸ Tankard Help: the user guide of this version (0.8.4), so it
    /// describes the app the user has, not what main has since changed.
    public static var help: URL { help(version: TankardVersion.string) }

    /// The guide at the release tag `v<version>` for a release version
    /// ("0.8.4", "0.8.4-rc1"); main for anything else (a dev build, an
    /// empty or unknown version), where no tag can be assumed to exist.
    /// 0.8.5: Help ▸ Homebrew Words Explained: the guide's glossary.
    public static let glossaryAnchor = "glossary-homebrew-words-explained"
    public static func glossary(version: String) -> URL {
        URL(string: help(version: version).absoluteString + "#" + glossaryAnchor)!
    }

    public static func help(version: String) -> URL {
        let ref = isReleaseVersion(version) ? "v" + version : "main"
        return URL(string: repository.absoluteString + "/blob/\(ref)/docs/usage.md")!
    }

    /// "1.2.3" or "1.2.3-rc1": digits, then at most an `-rcN` suffix.
    static func isReleaseVersion(_ v: String) -> Bool {
        v.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/) != nil
    }
    public static let intelbrew = URL(string: "https://github.com/d4rkwyng/intelbrew")!
    public static let author = String(localized: "Made by d4rkwyng")
    public static let licence = keepTogether(String(localized: "BSD-2-Clause license"))
    public static let homebrew = URL(string: "https://brew.sh")!
    /// About Homebrew, kept short enough for the About panel's width
    /// (~280 pt): "brew.sh" is the link.
    public static let homebrewLine = String(localized: "An independent app for Homebrew (brew.sh).")
    public static let homebrewCopyright = keepTogether(String(localized: "Homebrew © Homebrew contributors, BSD-2-Clause."))

    /// 0.8.4: the About panel wrapped "BSD-2-" / "Clause.". A word joiner
    /// (U+2060) after each hyphen of the licence name forbids a line break
    /// there and draws nothing, so the name stays on one line in every
    /// language (the translations keep the plain name).
    static func keepTogether(_ s: String) -> String {
        s.replacingOccurrences(of: "BSD-2-Clause", with: "BSD-\u{2060}2-\u{2060}Clause")
    }
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
