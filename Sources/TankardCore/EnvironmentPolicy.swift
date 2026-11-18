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
/// 0.8.4: the proxy variables (`ProxySettings`) and XDG_CONFIG_HOME pass
/// the same way, so brew works behind a proxy and reads the same user
/// brew.env Tankard shows. brew.env settings that undo one of Tankard's
/// own values, or one it denies, get a warning (`brewEnvConflict`).
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
        // 0.8.4: picks the user brew.env (bin/brew's fallback when
        // XDG_CONFIG_HOME is unset); see configHomeKeys.
        "HOMEBREW_XDG_CONFIG_HOME",
    ]

    /// 0.8.4: the variables bin/brew picks the user brew.env with. Passed
    /// like the allowed settings, and `EnvironmentSources.load` reads the
    /// brew.env they point to, so Tankard and its brew agree on the file.
    public static let configHomeKeys: Set<String> = [EnvFileParser.xdgConfigHomeKey, "HOMEBREW_XDG_CONFIG_HOME"]

    /// 0.8.4: the non-HOMEBREW_* names that pass from the app's environment
    /// and shell profiles: the proxies bin/brew keeps, and XDG_CONFIG_HOME.
    public static let otherAllowed: Set<String> = ProxySettings.passedByBrew.union([EnvFileParser.xdgConfigHomeKey])

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
        /// 0.8.4: HTTP_PROXY or NO_PROXY: bin/brew drops the upper-case
        /// form itself (only the lower-case one reaches curl and git), so
        /// Tankard doesn't pass it either.
        case droppedByBrew
    }

    public static func status(of key: String) -> Status {
        if ProxySettings.droppedByBrew.contains(key) { return .droppedByBrew }
        if otherAllowed.contains(key) { return .passed }
        if !key.hasPrefix("HOMEBREW_") { return .ignored }
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

    /// Every HOMEBREW_* name (and, 0.8.4, proxy variable and
    /// XDG_CONFIG_HOME) the user set in the app's environment or a shell profile.
    static func shellKeys(_ sources: EnvironmentSources) -> Set<String> {
        let wanted = { (k: String) in k.hasPrefix("HOMEBREW_") || EnvFileParser.shellExtraNames.contains(k) }
        var keys = Set(sources.process.keys.filter(wanted))
        for (_, vars) in sources.shellProfiles { keys.formUnion(vars.keys.filter(wanted)) }
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
        /// 0.8.4: a brew.env value that undoes one of Tankard's own values
        /// or one it denies, and why (Health warns on the row).
        public var conflict: BrewEnvConflict?
        public var id: String { key }
    }

    /// Every HOMEBREW_* setting the user made (environment, shell profiles,
    /// brew.env), plus the ones Tankard sets, sorted by name.
    /// `ownAskpass`: Tankard's own password helper; a brew.env SUDO_ASKPASS
    /// pointing at it doesn't warn (0.8.4).
    public static func entries(sources: EnvironmentSources, intelbrew: IntelbrewDetection,
                               readOnly: Bool = false, ownAskpass: String? = nil) -> [Entry] {
        var keys = shellKeys(sources)
        for (_, vars) in sources.brewEnvFiles { keys.formUnion(vars.keys) }   // parseBrewEnv's names only
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
            if let brewEnv {
                entry.conflict = brewEnvConflict(key, brewEnv.value, intelbrew: intelbrew, ownAskpass: ownAskpass)
            }
            return entry
        }
    }

    /// Tokens and passwords are never shown; 0.8.4: nor a proxy's
    /// user:password (`http://•••@proxy:8080`).
    public static func mask(_ key: String, _ value: String) -> String {
        if ProxySettings.names.contains(key) { return ProxySettings.mask(value) }
        return denial(key) == .credential && !value.isEmpty ? "••••••" : value
    }

    // MARK: brew.env conflicts (0.8.4)

    /// brew settings whose `boolean: true` form is off for 0, false, no, off
    /// and nil (env_config.rb, brew 7.0.14). Every other boolean Tankard
    /// checks is `boolean: :set`: any non-empty value turns it on.
    static let trueBooleans: Set<String> = [
        "HOMEBREW_VERBOSE_USING_DOTS", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK",
        "HOMEBREW_UPGRADE_GREEDY", "HOMEBREW_NO_AUTOREMOVE",
    ]

    /// Whether brew treats `value` as turning boolean setting `key` on.
    static func brewOn(_ key: String, _ value: String) -> Bool {
        trueBooleans.contains(key) ? BrewBoolean.isSet(value)
            : !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Why a brew.env setting gets a warning in Health ▸ Environment.
    /// bin/brew `export`s every brew.env line over the environment Tankard
    /// passes (7.0.14 bin/brew l.128-181), so these reach Tankard's brew.
    ///
    /// No brew 7.0.14 command-line flag undoes any of them for the commands
    /// Tankard runs: `--greedy` is a switch with no `--no-greedy`
    /// (cmd/upgrade.rb, cmd/outdated.rb); `uninstall` has no flag against
    /// autoremove (cmd/uninstall.rb reads only HOMEBREW_NO_AUTOREMOVE);
    /// `--verbose`/`--debug` have no negation; utils/tty.sh colours when
    /// HOMEBREW_COLOR is set whatever HOMEBREW_NO_COLOR says. Only the cask
    /// `--*dir=`/`--[no-]binaries` options have explicit flags that beat
    /// HOMEBREW_CASK_OPTS (cask/config.rb `explicit`); Tankard doesn't pass
    /// them, as forcing /Applications would undo a choice the user made on
    /// purpose in brew.env.
    public enum BrewEnvConflict: String, Sendable, Codable, Equatable {
        /// HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK: automatic updates pause.
        case dependentsCheck
        /// UPGRADE_GREEDY, UPGRADE_GREEDY_CASKS, NO_UPGRADE_AUTO_UPDATES_CASKS:
        /// overrides the per-app self-updating apps choice.
        case greedy
        /// Intelbrew mode: a remote other than the fork's, or the API back on.
        case intelbrew
        /// NO_AUTOREMOVE off: Uninstall would also autoremove.
        case autoremove
        /// COLOR, VERBOSE, DEBUG, or Tankard's NO_COLOR / NO_ENV_HINTS emptied.
        case output
        /// CASK_OPTS with options Tankard would drop.
        case caskOptions
        /// SUDO_ASKPASS, unless it is Tankard's own helper: brew would run
        /// sudo with it, so Tankard offers no password dialog and sudo steps
        /// go to Terminal (TankardAppModel's ForeignAskpass).
        case askpass
        /// CELLAR: where brew keeps its files.
        case location
        /// CACHE, LOGS: download progress and Clean Up assume the defaults.
        case defaultFolders
        /// Where brew gets code from or what it trusts (*_GIT_REMOTE outside
        /// Intelbrew mode, DEVELOPER, NO_VERIFY_ATTESTATIONS...).
        case trust
        /// A *_DOMAIN mirror: brew uses it; Discover and the tap index don't.
        case mirror
    }

    /// The warning for brew.env setting `key=value`, or nil when it doesn't
    /// conflict. Tokens (brew.env is a fine place for them) and the names
    /// bin/brew ignores in brew.env never warn.
    public static func brewEnvConflict(_ key: String, _ value: String,
                                       intelbrew: IntelbrewDetection, ownAskpass: String? = nil) -> BrewEnvConflict? {
        switch key {
        case "SUDO_ASKPASS":
            if value.isEmpty { return nil }
            if let own = ownAskpass, !own.isEmpty,
               URL(fileURLWithPath: value).resolvingSymlinksInPath().path == URL(fileURLWithPath: own).resolvingSymlinksInPath().path {
                return nil
            }
            return .askpass
        case "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK":
            return brewOn(key, value) ? .dependentsCheck : nil
        case "HOMEBREW_UPGRADE_GREEDY", "HOMEBREW_UPGRADE_GREEDY_CASKS", "HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS":
            return brewOn(key, value) ? .greedy : nil
        case "HOMEBREW_NO_AUTOREMOVE":
            // Tankard's uninstall sets it to 1; an off value here undoes that.
            return brewOn(key, value) ? nil : .autoremove
        case CaskOptions.key:
            return CaskOptions.filter(value).dropped.isEmpty ? nil : .caskOptions
        case "HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY", "HOMEBREW_XDG_CONFIG_HOME":
            return nil
        default:
            break
        }
        if intelbrew.detected, let mine = intelbrew.env[key] {
            if key == Intelbrew.noAPIKey { return brewOn(key, value) ? nil : .intelbrew }
            return Intelbrew.normalize(remote: value) == Intelbrew.normalize(remote: mine) ? nil : .intelbrew
        }
        if let c = tankardControlled[key] {
            switch c.why {
            case .output:
                // Forced on (NO_COLOR, NO_ENV_HINTS): only emptying it undoes it.
                return c.value != nil ? (brewOn(key, value) ? nil : .output) : (brewOn(key, value) ? .output : nil)
            case .greedy: return brewOn(key, value) ? .greedy : nil
            case .autoUpdate, .intelbrew: return nil
            }
        }
        switch denial(key) {
        case .location: return .location
        case .defaultFolders: return .defaultFolders
        case .trust:
            // The Intelbrew remotes outside Intelbrew mode: only when they
            // point somewhere other than the fork (a fork remote there turns
            // Intelbrew mode on).
            if key == Intelbrew.coreRemoteKey, Intelbrew.isCoreFork(value) { return nil }
            if key == Intelbrew.brewRemoteKey, Intelbrew.isBrewFork(value) { return nil }
            return .trust
        case .mirror: return .mirror
        case .dependentsCheck: return brewOn(key, value) ? .dependentsCheck : nil
        case .credential, nil: return nil
        }
    }

    /// Every brew.env setting that conflicts, with its file, as brew reads
    /// them (the last file wins; values masked).
    public static func brewEnvConflicts(sources: EnvironmentSources, intelbrew: IntelbrewDetection,
                                        ownAskpass: String? = nil) -> [Entry] {
        entries(sources: sources, intelbrew: intelbrew, ownAskpass: ownAskpass).filter { $0.conflict != nil }
    }
}

/// 0.8.4: proxy variables. bin/brew keeps http_proxy, https_proxy, ftp_proxy,
/// no_proxy, all_proxy, HTTPS_PROXY, FTP_PROXY and ALL_PROXY when it filters
/// its environment (bin/brew ENV_VAR_NAMES, brew 7.0.14), and curl and git
/// use them. It drops HTTP_PROXY (curl ignores it too, httpoxy) and NO_PROXY.
/// A brew.env file can set only the lower-case ones.
///
/// Tankard reads them from the app's environment and the shell profiles,
/// the app's environment first, and passes the ones bin/brew keeps.
/// Tankard's own URLSession requests (Discover's catalog, install counts,
/// the update check) don't use them: URLSession follows the system proxy
/// settings (System Settings ▸ Network ▸ Proxies, PAC files included), which
/// is how other Mac apps behave, and a proxy the user sets only in a shell
/// profile is for command-line tools.
public enum ProxySettings {
    public static let passedByBrew: Set<String> = [
        "http_proxy", "https_proxy", "ftp_proxy", "all_proxy", "no_proxy",
        "HTTPS_PROXY", "FTP_PROXY", "ALL_PROXY",
    ]
    public static let droppedByBrew: Set<String> = ["HTTP_PROXY", "NO_PROXY"]
    public static let names: Set<String> = passedByBrew.union(droppedByBrew)
    /// What bin/brew accepts from brew.env.
    public static let brewEnvNames: Set<String> = ["http_proxy", "https_proxy", "ftp_proxy", "all_proxy", "no_proxy"]

    public static let masked = "•••"

    /// The value with each URL's user:password replaced by •••
    /// (`http://user:pass@proxy:8080` -> `http://•••@proxy:8080`, also
    /// without a scheme). Comma-separated lists are masked item by item.
    public static func mask(_ value: String) -> String {
        value.split(separator: ",", omittingEmptySubsequences: false).map { item -> String in
            let s = String(item)
            let start = s.range(of: "://")?.upperBound ?? s.startIndex
            let hostEnd = s[start...].firstIndex(of: "/") ?? s.endIndex
            guard let at = s[start..<hostEnd].lastIndex(of: "@") else { return s }
            let lead = s[s.startIndex..<start].prefix { $0 == " " }
            let scheme = start == s.startIndex ? String(lead) : String(s[..<start])
            return scheme + masked + s[at...]
        }.joined(separator: ",")
    }

    /// Text (brew config, brew doctor) with every `scheme://user:pass@`
    /// masked: brew config prints proxy variables as they are.
    public static func maskText(_ text: String) -> String {
        text.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]*(?:@[^/\s@]*)*@"#,
                                  with: "$1" + masked + "@", options: .regularExpression)
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
