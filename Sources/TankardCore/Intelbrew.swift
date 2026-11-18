import Foundation

public enum Intelbrew {
    public static let coreRemote = "https://github.com/d4rkwyng/intelbrew-core"
    public static let brewRemote = "https://github.com/d4rkwyng/brew"

    public static let coreRemoteKey = "HOMEBREW_CORE_GIT_REMOTE"
    public static let brewRemoteKey = "HOMEBREW_BREW_GIT_REMOTE"
    public static let noAPIKey = "HOMEBREW_NO_INSTALL_FROM_API"
    public static let keys = [noAPIKey, coreRemoteKey, brewRemoteKey]

    /// Canonical form for comparing git remotes: https, lowercase, no
    /// trailing ".git" or "/". Handles scp-style (git@github.com:o/r) and
    /// ssh:// URLs.
    public static func normalize(remote: String) -> String {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast())
        }
        s = s.lowercased()
        if s.hasPrefix("git@") , let colon = s.firstIndex(of: ":") {
            let host = s[s.index(s.startIndex, offsetBy: 4)..<colon]
            s = "https://\(host)/\(s[s.index(after: colon)...])"
        } else if s.hasPrefix("ssh://") {
            s = String(s.dropFirst("ssh://".count))
            if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
            s = "https://" + s
        } else if s.hasPrefix("git://") {
            s = "https://" + s.dropFirst("git://".count)
        } else if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    public static func isCoreFork(_ remote: String?) -> Bool {
        guard let remote else { return false }
        return normalize(remote: remote) == coreRemote
    }

    public static func isBrewFork(_ remote: String?) -> Bool {
        guard let remote else { return false }
        return normalize(remote: remote) == brewRemote
    }
}

/// A HOMEBREW_* value and the file (or "environment") it came from.
public struct EnvSetting: Codable, Sendable, Equatable {
    public var value: String
    public var source: String
}

/// Result of Intelbrew detection, plus the HOMEBREW_* values Tankard passes
/// to brew because of it.
public struct IntelbrewDetection: Codable, Sendable, Equatable {
    public var detected: Bool
    /// Why: "core tap origin is the fork", "HOMEBREW_CORE_GIT_REMOTE in ~/.zshenv", ...
    public var reasons: [String]
    /// The three Intelbrew variables as Tankard passes them to brew (empty when not detected).
    public var env: [String: String]
    /// Where each Intelbrew variable was found, if anywhere.
    public var found: [String: EnvSetting]
}

/// Reads HOMEBREW_* assignments the way a user's shell or brew would see them.
public enum EnvFileParser {
    /// Shell startup files, `export NAME=value` / `NAME=value` lines only.
    /// Mirrors the Intelbrew installer's matcher: a single assignment,
    /// optionally exported, value unquoted or in matching quotes, optional
    /// trailing `;` and comment. Values containing `$` or backticks are
    /// skipped (Tankard does not evaluate shell). Later lines win.
    ///
    /// 0.8.4: besides HOMEBREW_* names, the proxy variables
    /// (`ProxySettings.names`) and XDG_CONFIG_HOME are read too. Two common
    /// forms that need expansion are understood, and nothing else: a proxy
    /// set to another proxy variable assigned earlier in the same file
    /// (`export https_proxy=$http_proxy`), and an XDG_CONFIG_HOME starting
    /// with `$HOME`, `${HOME}` or `~/` (expanded with `home`; skipped
    /// without one).
    public static func parseShell(_ text: String, home: String? = nil) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            guard name.hasPrefix("HOMEBREW_") || shellExtraNames.contains(name) else { continue }
            guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var rhs = String(line[line.index(after: eq)...])
            if ProxySettings.names.contains(name), let ref = proxyReference(rhs) {
                // `https_proxy=$http_proxy`: the earlier value in this file, if any.
                guard let v = out[ref.name] else { continue }
                rhs = ref.quote + v + ref.quote + ref.rest
            } else if name == xdgConfigHomeKey {
                guard let expanded = expandHome(rhs, home: home) else { continue }
                rhs = expanded
            }
            guard let value = parseShellWord(rhs) else { continue }
            out[name] = value
        }
        return out
    }

    /// The non-HOMEBREW_* names parseShell reads (0.8.4).
    public static let shellExtraNames: Set<String> = ProxySettings.names.union([xdgConfigHomeKey])
    public static let xdgConfigHomeKey = "XDG_CONFIG_HOME"

    /// `$name`, `${name}` or `"$name"` (one proxy variable, nothing else in
    /// the word): the name, the quote used and what follows the word.
    static func proxyReference(_ s: String) -> (name: String, quote: String, rest: String)? {
        var rest = Substring(s)
        var quote = ""
        if rest.first == "\"" { quote = "\""; rest = rest.dropFirst() }
        guard rest.first == "$" else { return nil }
        rest = rest.dropFirst()
        var name: Substring
        if rest.first == "{" {
            guard let close = rest.firstIndex(of: "}") else { return nil }
            name = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
        } else {
            let end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? rest.endIndex
            name = rest[..<end]
            rest = rest[end...]
        }
        guard ProxySettings.names.contains(String(name)) else { return nil }
        if !quote.isEmpty {
            guard rest.first == "\"" else { return nil }
            rest = rest.dropFirst()
        }
        return (String(name), quote, String(rest))
    }

    /// XDG_CONFIG_HOME's value with a leading `$HOME`, `${HOME}` (optionally
    /// in double quotes) or unquoted `~` replaced by `home`. nil when it
    /// needs expansion and there is no home; unchanged when it needs none.
    static func expandHome(_ s: String, home: String?) -> String? {
        var rest = Substring(s)
        var quote = ""
        if rest.first == "\"" { quote = "\""; rest = rest.dropFirst() }
        for token in ["${HOME}", "$HOME"] where rest.hasPrefix(token) {
            let after = rest.dropFirst(token.count)
            // `$HOMEDIR` is another variable.
            if let c = after.first, c.isLetter || c.isNumber || c == "_" { return s }
            guard let home else { return nil }
            return quote + home + after
        }
        if quote.isEmpty, rest == "~" || rest.hasPrefix("~/") {
            guard let home else { return nil }
            return home + rest.dropFirst()
        }
        return s
    }

    /// One shell word followed by nothing but an optional `;` and comment.
    static func parseShellWord(_ s: String) -> String? {
        var rest = Substring(s)
        var value: String
        if let q = rest.first, q == "\"" || q == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: q) else { return nil }
            value = String(rest[..<end])
            rest = rest[rest.index(after: end)...]
            if q == "\"" && (value.contains("$") || value.contains("`")) { return nil }
        } else {
            let end = rest.firstIndex { " \t;&|#\"'`".contains($0) } ?? rest.endIndex
            value = String(rest[..<end])
            rest = rest[end...]
            if value.contains("$") { return nil }
        }
        var tail = rest.trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix(";") { tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        return value
    }

    /// brew.env: brew's own parser (bin/brew export_homebrew_env_file) keeps
    /// the value literally after the first `=`, quotes included. It accepts
    /// HOMEBREW_* names, SUDO_ASKPASS and the lower-case proxy variables
    /// (`^(HOMEBREW_|SUDO_ASKPASS=|(all|no|ftp|https?)_proxy=)` in brew
    /// 7.0.14; 0.8.3 read only HOMEBREW_*), and skips the names bin/brew sets
    /// itself (`brewEnvIgnored`).
    public static func parseBrewEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            guard name.hasPrefix("HOMEBREW_") || brewEnvExtraNames.contains(name),
                  !brewEnvIgnored.contains(name) else { continue }
            out[name] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// The non-HOMEBREW_* names bin/brew takes from a brew.env file.
    public static let brewEnvExtraNames: Set<String> = ProxySettings.brewEnvNames.union(["SUDO_ASKPASS"])

    /// bin/brew's BIN_BREW_EXPORTED_VARS: set by bin/brew itself, and a
    /// brew.env line for one of them is skipped.
    public static let brewEnvIgnored: Set<String> = [
        "HOMEBREW_BREW_FILE", "HOMEBREW_PREFIX", "HOMEBREW_REPOSITORY", "HOMEBREW_LIBRARY", "HOMEBREW_USER_CONFIG_HOME",
    ]
}

/// Inputs for detection and environment construction, gathered from the
/// filesystem. Separate from the logic so tests can supply them.
public struct EnvironmentSources: Sendable {
    /// The process's own environment (a GUI app's is nearly empty).
    public var process: [String: String]
    /// Ordered lowest to highest precedence: (label, HOMEBREW_* values).
    public var shellProfiles: [(String, [String: String])]
    /// brew.env files, lowest to highest precedence.
    public var brewEnvFiles: [(String, [String: String])]

    public init(process: [String: String],
                shellProfiles: [(String, [String: String])] = [],
                brewEnvFiles: [(String, [String: String])] = []) {
        self.process = process
        self.shellProfiles = shellProfiles
        self.brewEnvFiles = brewEnvFiles
    }

    /// Shell startup files a new terminal would read, in read order.
    /// zsh: .zshenv, .zprofile, .zshrc, .zlogin (in $ZDOTDIR if set, with
    /// ~/.zshenv first). bash: the first of .bash_profile/.bash_login/.profile,
    /// then .bashrc.
    public static func profilePaths(home: String, shell: String?, zdotdir: String?) -> [String] {
        let shellName = (shell as NSString?)?.lastPathComponent ?? "zsh"
        if shellName == "bash" {
            let fm = FileManager.default
            let login = [".bash_profile", ".bash_login", ".profile"]
                .map { "\(home)/\($0)" }
                .first { fm.fileExists(atPath: $0) }
            return [login, "\(home)/.bashrc"].compactMap { $0 }
        }
        let zdot = zdotdir ?? home
        var paths = ["\(home)/.zshenv"]
        if zdot != home { paths.append("\(zdot)/.zshenv") }
        paths += [".zprofile", ".zshrc", ".zlogin"].map { "\(zdot)/\($0)" }
        return paths
    }

    /// brew.env files in bin/brew's order: system, prefix, user. `env` is
    /// the environment brew gets: the user file is in XDG_CONFIG_HOME, else
    /// HOMEBREW_XDG_CONFIG_HOME, else ~/.homebrew (bin/brew's rule). `load`
    /// passes `configHomeEnvironment()`, the same values BrewEnvironment
    /// gives brew, so Tankard reads the file brew will read.
    public static func brewEnvPaths(prefix: String, home: String, env: [String: String]) -> [String] {
        let user: String
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty {
            user = "\(x)/homebrew/brew.env"
        } else if let x = env["HOMEBREW_XDG_CONFIG_HOME"], !x.isEmpty {
            user = "\(x)/homebrew/brew.env"
        } else {
            user = "\(home)/.homebrew/brew.env"
        }
        return ["/etc/homebrew/brew.env", "\(prefix)/etc/homebrew/brew.env", user]
    }

    /// Reads the real files for a brew at `prefix`.
    public static func load(prefix: String, process: [String: String] = ProcessInfo.processInfo.environment) -> EnvironmentSources {
        let home = process["HOME"] ?? NSHomeDirectory()
        let shell = process["SHELL"] ?? loginShell()
        let read = { (path: String) -> String? in try? String(contentsOfFile: path, encoding: .utf8) }
        let tilde = { (path: String) -> String in
            path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        let profiles = profilePaths(home: home, shell: shell, zdotdir: process["ZDOTDIR"])
            .compactMap { p in read(p).map { (tilde(p), EnvFileParser.parseShell($0, home: home)) } }
        // 0.8.4: the user brew.env that the brew Tankard runs will read. Before,
        // this used Tankard's own XDG_CONFIG_HOME, which brew never got.
        let configHome = EnvironmentSources(process: process, shellProfiles: profiles).configHomeEnvironment()
        let brewEnvs = brewEnvPaths(prefix: prefix, home: home, env: configHome)
            .compactMap { p in read(p).map { (tilde(p), EnvFileParser.parseBrewEnv($0)) } }
        return EnvironmentSources(process: process, shellProfiles: profiles, brewEnvFiles: brewEnvs)
    }

    static func loginShell() -> String? {
        guard let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell else { return nil }
        return String(cString: sh)
    }

    /// The value brew would see for `key` if run from a fresh terminal:
    /// brew.env beats the shell environment (bin/brew exports it over the
    /// top); the live process environment beats profile files (it already
    /// reflects them when Tankard runs from a terminal).
    public func effective(_ key: String) -> EnvSetting? {
        if let s = brewEnvSetting(key) { return s }
        if let v = process[key] { return EnvSetting(value: v, source: "environment") }
        for (label, vars) in shellProfiles.reversed() {
            if let v = vars[key] { return EnvSetting(value: v, source: label) }
        }
        return nil
    }
}

extension EnvironmentSources {
    /// 0.8.4: XDG_CONFIG_HOME and HOMEBREW_XDG_CONFIG_HOME as Tankard passes
    /// them to brew (EnvironmentPolicy.passThrough: the app's environment,
    /// else the last shell profile; empty means unset). bin/brew picks the
    /// user brew.env with them, so `load` looks there too.
    public func configHomeEnvironment() -> [String: String] {
        EnvironmentPolicy.passThrough(self).filter { EnvironmentPolicy.configHomeKeys.contains($0.key) }
    }

    /// The system brew.env, which HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY puts last.
    public static let systemBrewEnv = "/etc/homebrew/brew.env"

    /// 0.8.3: the value brew takes from its brew.env files, by bin/brew's
    /// rule: it `export`s each file's lines over the environment in order
    /// (/etc, the prefix's, the user's), so the last file that sets `key`
    /// wins; but when HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY is non-empty right
    /// after the /etc file is read (Tankard never passes it, so only the /etc
    /// file can set it), /etc is read again last and wins. nil: no file sets it.
    public func brewEnvSetting(_ key: String) -> EnvSetting? {
        Self.brewEnvSetting(key, files: brewEnvFiles)
    }

    public static func brewEnvSetting(_ key: String, files: [(String, [String: String])]) -> EnvSetting? {
        let system = files.first { $0.0 == systemBrewEnv }
        if let system, let p = system.1["HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY"], !p.isEmpty, let v = system.1[key] {
            return EnvSetting(value: v, source: system.0)
        }
        for (label, vars) in files.reversed() {
            if let v = vars[key] { return EnvSetting(value: v, source: label) }
        }
        return nil
    }
}

/// brew's `boolean: true` environment variables (env_config.rb): set when
/// the value isn't blank and isn't false, no, off, nil or 0 (any case).
public enum BrewBoolean {
    public static let falsy: Set<String> = ["false", "no", "off", "nil", "0"]

    public static func isSet(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !falsy.contains(value.lowercased())
    }
}

public enum IntelbrewDetector {
    /// Intelbrew mode when homebrew/core's origin is the fork, or
    /// HOMEBREW_CORE_GIT_REMOTE (environment, shell profile or brew.env)
    /// points at it.
    public static func detect(coreOrigin: String?, sources: EnvironmentSources) -> IntelbrewDetection {
        var reasons: [String] = []
        var found: [String: EnvSetting] = [:]
        for key in Intelbrew.keys {
            if let s = sources.effective(key) { found[key] = s }
        }
        if Intelbrew.isCoreFork(coreOrigin) {
            reasons.append("homebrew/core origin is \(Intelbrew.coreRemote)")
        }
        if let s = found[Intelbrew.coreRemoteKey], Intelbrew.isCoreFork(s.value) {
            reasons.append("\(Intelbrew.coreRemoteKey) set in \(s.source)")
        }
        let detected = !reasons.isEmpty
        var env: [String: String] = [:]
        if detected {
            env[Intelbrew.noAPIKey] = "1"
            env[Intelbrew.coreRemoteKey] = Intelbrew.coreRemote
            // Keep the user's own spelling of the brew fork remote if it is the
            // fork (e.g. an ssh URL); otherwise use the canonical one.
            if let s = found[Intelbrew.brewRemoteKey], Intelbrew.isBrewFork(s.value) {
                env[Intelbrew.brewRemoteKey] = s.value
            } else {
                env[Intelbrew.brewRemoteKey] = Intelbrew.brewRemote
            }
            if let s = found[Intelbrew.coreRemoteKey], Intelbrew.isCoreFork(s.value) {
                env[Intelbrew.coreRemoteKey] = s.value
            }
        }
        return IntelbrewDetection(detected: detected, reasons: reasons, env: env, found: found)
    }
}

/// Builds brew's environment from scratch (like `/usr/bin/env -i`): a GUI
/// app inherits almost nothing useful from launchd, and a terminal's
/// environment varies, so neither is passed through wholesale; only the
/// HOMEBREW_* settings EnvironmentPolicy allows.
public enum BrewEnvironment {
    /// - HOME, USER, LOGNAME, TMPDIR from this process (or the passwd
    ///   entry / Foundation defaults), LANG=en_US.UTF-8.
    /// - PATH=<brew's bin dir>:<prefix>/sbin:/usr/bin:/bin.
    /// - 0.8.3: the user's own HOMEBREW_* settings from the app's
    ///   environment and shell profiles that EnvironmentPolicy allows
    ///   (HOMEBREW_NO_ANALYTICS, HOMEBREW_CASK_OPTS, ...). Before 0.8.3
    ///   none were passed. 0.8.4: also the proxy variables bin/brew keeps
    ///   (ProxySettings) and XDG_CONFIG_HOME / HOMEBREW_XDG_CONFIG_HOME, so
    ///   brew reads the user brew.env Tankard shows.
    /// - In Intelbrew mode, the three Intelbrew variables (they win).
    /// - Tankard's own (EnvironmentPolicy.tankardControlled, they win):
    ///   HOMEBREW_NO_ENV_HINTS=1, HOMEBREW_NO_COLOR=1, no HOMEBREW_COLOR,
    ///   VERBOSE, DEBUG or GREEDY, and for read-only queries
    ///   HOMEBREW_NO_AUTO_UPDATE=1 so a status query never runs
    ///   `brew update` behind the user's back.
    /// brew.env files (/etc/homebrew/brew.env, <prefix>/etc/homebrew/brew.env,
    /// ~/.homebrew/brew.env) are read by bin/brew itself, over the top of
    /// this environment.
    public static func build(installation: BrewInstallation, sources: EnvironmentSources,
                             intelbrew: IntelbrewDetection, readOnly: Bool) -> [String: String] {
        let p = sources.process
        var env: [String: String] = [:]
        env["HOME"] = p["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let user = p["USER"] ?? p["LOGNAME"] ?? NSUserName()
        env["USER"] = user
        env["LOGNAME"] = p["LOGNAME"] ?? user
        env["TMPDIR"] = p["TMPDIR"] ?? NSTemporaryDirectory()
        env["LANG"] = "en_US.UTF-8"
        let binDir = (installation.brewPath as NSString).deletingLastPathComponent
        env["PATH"] = "\(binDir):\(installation.prefix)/sbin:/usr/bin:/bin"
        env.merge(EnvironmentPolicy.passThrough(sources)) { $1 }
        for (k, v) in intelbrew.env {
            env[k] = v
        }
        EnvironmentPolicy.applyControlled(&env, readOnly: readOnly)
        return env
    }
}
