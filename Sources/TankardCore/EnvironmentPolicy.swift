import Foundation

/// 0.8.3: which of the user's own HOMEBREW_* settings Tankard passes to brew.
///
/// Before 0.8.3 brew ran with none of them (only the Intelbrew three), so a
/// `HOMEBREW_NO_ANALYTICS=1` in ~/.zshrc was dropped and installs from
/// Tankard sent analytics the user had turned off. Now the settings in the
/// app's environment and the shell profiles Tankard already parses go
/// through, but only those on an explicit allow list. Everything else is
/// reported, not passed:
///
/// - **Allowed**: privacy and behaviour preferences (`allowed`, each
///   checked against `man brew` for Homebrew 7.0).
/// - **Tankard's own**: settings Tankard sets or removes for correctness
///   (`tankardControlled`); the user's value never wins.
/// - **Denied**: anything that changes where brew installs, where it gets
///   packages from, or what it trusts; mirrors; credentials (`denial`).
///   Intelbrew mode's own remotes still win, unchanged.
/// - **Ignored**: any other HOMEBREW_* name. Unknown means not passed.
///
/// brew.env files are separate: bin/brew reads them itself and exports them
/// over the environment Tankard hands it, so a setting there reaches brew
/// whatever this list says (Tankard just shows it).
///
/// Not read in 0.8.3: proxy settings (http_proxy, https_proxy, all_proxy,
/// no_proxy and their upper-case forms) in shell profiles. bin/brew honours
/// them from its environment and from brew.env; EnvFileParser.parseShell only
/// reads HOMEBREW_* lines. Next release: parse and pass them too.
public enum EnvironmentPolicy {
    /// Passed through from the app's environment and shell profiles.
    public static let allowed: Set<String> = [
        // Privacy and network safety.
        "HOMEBREW_NO_ANALYTICS",
        "HOMEBREW_NO_INSECURE_REDIRECT",
        "HOMEBREW_NO_GITHUB_API",
        "HOMEBREW_CURL_RETRIES",
        "HOMEBREW_FORCE_BREWED_CURL",
        "HOMEBREW_VERIFY_ATTESTATIONS",
        // Restrictions the user put on themselves.
        "HOMEBREW_FORBIDDEN_FORMULAE",
        "HOMEBREW_FORBIDDEN_CASKS",
        "HOMEBREW_FORBIDDEN_LICENSES",
        "HOMEBREW_FORBIDDEN_TAPS",
        "HOMEBREW_FORBIDDEN_OWNER",
        "HOMEBREW_FORBIDDEN_OWNER_CONTACT",
        "HOMEBREW_FORBID_PACKAGES_FROM_PATHS",
        // Behaviour preferences. HOMEBREW_CASK_OPTS passes filtered
        // (CaskOptions): only --require-sha and --language=.
        "HOMEBREW_CASK_OPTS",
        "HOMEBREW_TEMP",
        "HOMEBREW_DISPLAY_INSTALL_TIMES",
        "HOMEBREW_NO_EMOJI",
        "HOMEBREW_INSTALL_BADGE",
        "HOMEBREW_NO_INSTALL_CLEANUP",
        "HOMEBREW_CLEANUP_MAX_AGE_DAYS",
        "HOMEBREW_CLEANUP_PERIODIC_FULL_DAYS",
        "HOMEBREW_NO_CLEANUP_FORMULAE",
        "HOMEBREW_NO_AUTOREMOVE",
        "HOMEBREW_NO_INSTALL_UPGRADE",
        "HOMEBREW_NO_UPGRADE_QUIT_CASKS",
        "HOMEBREW_NO_UPDATE_REPORT_NEW",
        "HOMEBREW_NO_AUTO_UPDATE",
        "HOMEBREW_AUTO_UPDATE_SECS",
        "HOMEBREW_API_AUTO_UPDATE_SECS",
        "HOMEBREW_AUTO_UPDATE_QUIET",
        "HOMEBREW_DOWNLOAD_CONCURRENCY",
        "HOMEBREW_MAKE_JOBS",
        "HOMEBREW_FAIL_LOG_LINES",
    ]

    /// Why Tankard sets (or removes) a setting itself.
    public enum Control: String, Sendable, Codable, Equatable {
        /// Tankard reads brew's output.
        case output
        /// Tankard decides when `brew update` runs.
        case autoUpdate
        /// Tankard's per-app self-updating-apps choice.
        case greedy
        /// Intelbrew mode's own value.
        case intelbrew
    }

    /// Settings Tankard owns: the forced value (nil: removed) and why.
    /// HOMEBREW_NO_AUTO_UPDATE is forced only for read-only queries (and by
    /// the callers for upgrades); otherwise the user's value passes.
    public static let tankardControlled: [String: (value: String?, why: Control)] = [
        "HOMEBREW_NO_COLOR": ("1", .output),
        "HOMEBREW_COLOR": (nil, .output),
        "HOMEBREW_NO_ENV_HINTS": ("1", .output),
        "HOMEBREW_VERBOSE": (nil, .output),
        "HOMEBREW_VERBOSE_USING_DOTS": (nil, .output),
        "HOMEBREW_DEBUG": (nil, .output),
        "HOMEBREW_UPGRADE_GREEDY": (nil, .greedy),
        "HOMEBREW_UPGRADE_GREEDY_CASKS": (nil, .greedy),
        "HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS": (nil, .greedy),
    ]

    /// Why a setting is never passed from the shell.
    public enum Denial: String, Sendable, Codable, Equatable {
        /// Where brew lives and installs: bin/brew works it out itself.
        case location
        /// Where brew gets packages and code from, or what it trusts.
        case trust
        /// A download mirror: not applied by Tankard for now.
        case mirror
        /// A token or password.
        case credential
        /// Auto-update's safe mode relies on brew's dependents check.
        case dependentsCheck
        /// Download progress and Clean Up assume brew's default folders.
        case defaultFolders
    }

    static let locationKeys: Set<String> = [
        "HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY", "HOMEBREW_LIBRARY",
        "HOMEBREW_BREW_FILE", "HOMEBREW_USER_CONFIG_HOME",
    ]
    static let trustKeys: Set<String> = [
        "HOMEBREW_NO_INSTALL_FROM_API", "HOMEBREW_DEVELOPER", "HOMEBREW_NO_VERIFY_ATTESTATIONS",
        "HOMEBREW_UPDATE_TO_TAG", "HOMEBREW_PIP_INDEX_URL", "HOMEBREW_CURL_PATH", "HOMEBREW_GIT_PATH",
        "HOMEBREW_CURLRC", "HOMEBREW_SSH_CONFIG_PATH", "HOMEBREW_FORCE_VENDOR_RUBY",
        "HOMEBREW_FORCE_BREWED_CA_CERTIFICATES", "HOMEBREW_FORCE_BREWED_GIT", "HOMEBREW_SKIP_OR_LATER_BOTTLES",
        "HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY", "HOMEBREW_DISABLE_LOAD_FORMULA", "HOMEBREW_SIMULATE_MACOS_ON_LINUX",
        "HOMEBREW_FORCE_API_AUTO_UPDATE", "HOMEBREW_USER_SET_VARS",
    ]

    public static func denial(_ key: String) -> Denial? {
        if locationKeys.contains(key) { return .location }
        if key == "HOMEBREW_CACHE" || key == "HOMEBREW_LOGS" { return .defaultFolders }
        if key.hasSuffix("_DOMAIN") || key == "HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK" { return .mirror }
        if key.contains("TOKEN") || key.contains("PASSWORD") || key.contains("SECRET")
            || key == "HOMEBREW_GITHUB_PACKAGES_USER" || key.hasPrefix("HOMEBREW_DOCKER_REGISTRY_") { return .credential }
        if key == "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" { return .dependentsCheck }
        if trustKeys.contains(key) || key.hasSuffix("_GIT_REMOTE") || key.contains("TRUST") { return .trust }
        return nil
    }

    /// What happens to one HOMEBREW_* name.
    public enum Status: Sendable, Equatable {
        case passed
        /// HOMEBREW_CASK_OPTS: some options passed, the rest dropped
        /// (the entry's `caskOptions` says which).
        case partial
        case tankard(Control)
        case denied(Denial)
        case ignored
        /// From a brew.env file: brew reads it itself.
        case brewEnv
    }

    public static func status(of key: String) -> Status {
        if Intelbrew.keys.contains(key) { return .denied(.trust) }
        if let c = tankardControlled[key] { return .tankard(c.why) }
        if let d = denial(key) { return .denied(d) }
        return allowed.contains(key) ? .passed : .ignored
    }

    /// The user's value for `key` outside brew.env: the app's environment
    /// first (from a terminal it already reflects the profiles), then the
    /// last shell profile that sets it.
    static func shellSetting(_ key: String, _ sources: EnvironmentSources) -> EnvSetting? {
        if let v = sources.process[key] { return EnvSetting(value: v, source: "environment") }
        for (label, vars) in sources.shellProfiles.reversed() {
            if let v = vars[key] { return EnvSetting(value: v, source: label) }
        }
        return nil
    }

    /// Every HOMEBREW_* name the user set in the app's environment or a shell profile.
    static func shellKeys(_ sources: EnvironmentSources) -> Set<String> {
        var keys = Set(sources.process.keys.filter { $0.hasPrefix("HOMEBREW_") })
        for (_, vars) in sources.shellProfiles { keys.formUnion(vars.keys) }
        return keys
    }

    /// The user's allowed settings, as passed to brew. Empty values are
    /// dropped (bin/brew skips them too).
    public static func passThrough(_ sources: EnvironmentSources) -> [String: String] {
        var out: [String: String] = [:]
        for key in shellKeys(sources) where status(of: key) == .passed {
            guard let s = shellSetting(key, sources), !s.value.isEmpty else { continue }
            if key == CaskOptions.key {
                let kept = CaskOptions.filter(s.value).passed
                if !kept.isEmpty { out[key] = kept }
            } else {
                out[key] = s.value
            }
        }
        return out
    }

    /// Applies Tankard's own values over `env` (removing the ones it unsets).
    public static func applyControlled(_ env: inout [String: String], readOnly: Bool) {
        for (k, c) in tankardControlled {
            env[k] = c.value
        }
        if readOnly { env["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
    }

    // MARK: the Environment view

    /// One row of Health ▸ Environment.
    public struct Entry: Sendable, Equatable, Identifiable {
        public var key: String
        /// As shown: tokens masked; nil when the user didn't set it.
        public var value: String?
        /// "~/.zshrc", "environment", "/etc/homebrew/brew.env", or nil.
        public var source: String?
        public var status: Status
        /// What brew gets from Tankard, when Tankard sets it ("1"), else nil.
        public var tankardValue: String?
        /// HOMEBREW_CASK_OPTS from the shell: what passed and what didn't.
        /// From a brew.env file: set only when it has options Tankard would
        /// drop, which then apply anyway (see `entries`).
        public var caskOptions: CaskOptions?
        public var id: String { key }
    }

    /// Every HOMEBREW_* setting the user made (environment, shell profiles,
    /// brew.env), plus the ones Tankard sets, sorted by name.
    public static func entries(sources: EnvironmentSources, intelbrew: IntelbrewDetection,
                               readOnly: Bool = false) -> [Entry] {
        var keys = shellKeys(sources)
        for (_, vars) in sources.brewEnvFiles { keys.formUnion(vars.keys) }
        keys.formUnion(tankardControlled.compactMap { $0.value.value == nil ? nil : $0.key })
        keys.formUnion(intelbrew.env.keys)
        if readOnly { keys.insert("HOMEBREW_NO_AUTO_UPDATE") }

        var forced: [String: String] = [:]
        applyControlled(&forced, readOnly: readOnly)
        return keys.sorted().compactMap { key in
            let brewEnv = sources.brewEnvSetting(key)
            let user = brewEnv ?? shellSetting(key, sources)
            let tankard = intelbrew.env[key] ?? forced[key]
            let status: Status
            if brewEnv != nil {
                status = .brewEnv
            } else if intelbrew.env[key] != nil {
                status = .tankard(.intelbrew)
            } else if key == "HOMEBREW_NO_AUTO_UPDATE" {
                status = user != nil && !readOnly ? .passed : .tankard(.autoUpdate)
            } else {
                status = Self.status(of: key)
            }
            if user == nil && tankard == nil { return nil }
            var entry = Entry(key: key, value: user.map { mask(key, $0.value) }, source: user?.source,
                              status: status, tankardValue: tankard)
            if key == CaskOptions.key, status == .passed, let v = user?.value {
                let c = CaskOptions.filter(v)
                if !c.dropped.isEmpty {
                    entry.status = .partial
                    entry.caskOptions = c
                }
            }
            // brew.env wins over the environment Tankard passes: bin/brew
            // `export`s each line unconditionally (system, prefix, then user
            // file; HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY re-reads the system one
            // last). Checked on brew 7.0.14: HOMEBREW_CASK_OPTS=--require-sha
            // in the environment, --appdir=/x --force in ~/.homebrew/brew.env
            // -> brew config shows ["--appdir=/x", "--force"] and
            // Cask::Config appdir is /x; an empty value in the environment
            // doesn't help either. Tankard can't filter it, so Health warns.
            if key == CaskOptions.key, status == .brewEnv, let v = brewEnv?.value {
                let c = CaskOptions.filter(v)
                if !c.dropped.isEmpty { entry.caskOptions = c }
            }
            return entry
        }
    }

    /// Tokens and passwords are never shown.
    public static func mask(_ key: String, _ value: String) -> String {
        denial(key) == .credential && !value.isEmpty ? "••••••" : value
    }
}

/// HOMEBREW_CASK_OPTS, filtered (0.8.3). Passed whole, the `--*dir` options
/// would move where casks install, which Adopt's location verdicts and the
/// App Management probe (/Applications) rely on, and flags like `--force`
/// or `--adopt` would apply to every cask without Tankard's confirmation.
///
/// brew 7 splits the value with Shellwords (env_config.rb `cask_opts`) and
/// reads only `--flag=value` options (cask/config.rb `env`), `--require-sha`
/// and `--binaries`/`--no-binaries`. Kept: `--require-sha` (stricter) and
/// `--language=codes` (which localized download a cask picks). Considered and
/// dropped: every `--*dir=` (location), `--no-binaries`/`--binaries` (changes
/// which command-line links a cask install makes), and `--force`, `--adopt`,
/// `--no-quarantine` (brew 7 ignores them here, but they are dropped and
/// named so a user sees they don't apply). Anything else is dropped.
public struct CaskOptions: Sendable, Equatable {
    public static let key = "HOMEBREW_CASK_OPTS"

    public enum Reason: String, Sendable, Equatable, Codable {
        /// A `--*dir` option: changes where apps go.
        case location
        /// `--force`, `--adopt`, `--no-quarantine`: acts without confirmation.
        case confirmation
        /// Not on Tankard's list.
        case other
    }

    /// The value passed to brew: the kept options joined by spaces ("" when none).
    public var passed: String
    public var kept: [String]
    public var dropped: [(option: String, reason: Reason)]

    public static func == (a: CaskOptions, b: CaskOptions) -> Bool {
        a.passed == b.passed && a.kept == b.kept
            && a.dropped.map(\.option) == b.dropped.map(\.option)
            && a.dropped.map(\.reason) == b.dropped.map(\.reason)
    }

    public static func filter(_ value: String) -> CaskOptions {
        var kept: [String] = []
        var dropped: [(String, Reason)] = []
        for word in shellSplit(value) {
            if word == "--require-sha" {
                if !kept.contains(word) { kept.append(word) }
            } else if word.hasPrefix("--language="),
                      word.dropFirst("--language=".count).range(of: #"^[A-Za-z0-9_,-]+$"#, options: .regularExpression) != nil {
                kept.removeAll { $0.hasPrefix("--language=") }   // the last one wins, as in brew
                kept.append(word)
            } else {
                let flag = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
                let reason: Reason = flag.hasSuffix("dir") ? .location
                    : ["--force", "--adopt", "--no-quarantine"].contains(flag) ? .confirmation : .other
                dropped.append((word, reason))
            }
        }
        return CaskOptions(passed: kept.joined(separator: " "), kept: kept, dropped: dropped)
    }

    /// Ruby's Shellwords.shellsplit, enough for option lists: whitespace
    /// separates words; single quotes are literal; double quotes and
    /// backslashes escape. An unterminated quote ends the word.
    static func shellSplit(_ s: String) -> [String] {
        var words: [String] = []
        var cur = ""
        var inWord = false
        var it = s.makeIterator()
        while let c = it.next() {
            switch c {
            case " ", "\t", "\n":
                if inWord { words.append(cur); cur = ""; inWord = false }
            case "'":
                inWord = true
                while let d = it.next(), d != "'" { cur.append(d) }
            case "\"":
                inWord = true
                while let d = it.next(), d != "\"" {
                    if d == "\\", let e = it.next() { cur.append(e) } else { cur.append(d) }
                }
            case "\\":
                inWord = true
                if let e = it.next() { cur.append(e) }
            default:
                inWord = true
                cur.append(c)
            }
        }
        if inWord { words.append(cur) }
        return words
    }
}
