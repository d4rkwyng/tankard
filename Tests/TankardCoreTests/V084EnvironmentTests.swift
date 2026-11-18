import Foundation
import Testing
@testable import TankardCore

/// 0.8.4: proxy variables reach brew, masked in Health.
struct ProxySettingsTests {
    let arm = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
    let none = IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:])

    func build(process: [String: String] = ["HOME": "/h"], profile: [String: String] = [:],
               brewEnv: [String: String] = [:]) -> [String: String] {
        let sources = EnvironmentSources(process: process, shellProfiles: [("~/.zshrc", profile)],
                                         brewEnvFiles: brewEnv.isEmpty ? [] : [("~/.homebrew/brew.env", brewEnv)])
        return BrewEnvironment.build(installation: arm, sources: sources, intelbrew: none, readOnly: true)
    }

    @Test func profileParsing() {
        let text = """
        export http_proxy=http://user:pa55@proxy.corp:8080
        export https_proxy=$http_proxy
        export HTTPS_PROXY="${https_proxy}"
        all_proxy='socks5://proxy.corp:1080'   # socks
        export no_proxy=localhost,127.0.0.1,.corp
        export ftp_proxy=$UNKNOWN_PROXY
        export FTP_PROXY=$http_proxy$https_proxy
        export PROXY_PASSWORD=x
        """
        let v = EnvFileParser.parseShell(text)
        #expect(v["http_proxy"] == "http://user:pa55@proxy.corp:8080")
        #expect(v["https_proxy"] == "http://user:pa55@proxy.corp:8080")
        #expect(v["HTTPS_PROXY"] == "http://user:pa55@proxy.corp:8080")
        #expect(v["all_proxy"] == "socks5://proxy.corp:1080")
        #expect(v["no_proxy"] == "localhost,127.0.0.1,.corp")
        #expect(v["ftp_proxy"] == nil)          // not one Tankard can resolve
        #expect(v["FTP_PROXY"] == nil)          // more than one reference
        #expect(v["PROXY_PASSWORD"] == nil)
        // A reference to a proxy set later (or in another file) isn't resolved.
        #expect(EnvFileParser.parseShell("export https_proxy=$http_proxy\nexport http_proxy=http://p:1\n")["https_proxy"] == nil)
    }

    @Test func passedToBrew() {
        let env = build(profile: ["http_proxy": "http://u:p@proxy:8080", "https_proxy": "http://proxy:8080",
                                  "no_proxy": "localhost", "all_proxy": "socks5://proxy:1080",
                                  "HTTPS_PROXY": "http://proxy:8080", "ALL_PROXY": "socks5://proxy:1080",
                                  "ftp_proxy": "http://proxy:21", "FTP_PROXY": "http://proxy:21"])
        #expect(env["http_proxy"] == "http://u:p@proxy:8080")   // brew gets the real value
        #expect(env["https_proxy"] == "http://proxy:8080")
        #expect(env["no_proxy"] == "localhost")
        #expect(env["all_proxy"] == "socks5://proxy:1080")
        #expect(env["HTTPS_PROXY"] == "http://proxy:8080")
        #expect(env["ALL_PROXY"] == "socks5://proxy:1080")
        #expect(env["ftp_proxy"] == "http://proxy:21")
        #expect(env["FTP_PROXY"] == "http://proxy:21")
    }

    @Test func upperCaseFormsBrewDropsArentPassed() {
        let env = build(profile: ["HTTP_PROXY": "http://proxy:8080", "NO_PROXY": "localhost"])
        #expect(env["HTTP_PROXY"] == nil)
        #expect(env["NO_PROXY"] == nil)
        #expect(EnvironmentPolicy.status(of: "HTTP_PROXY") == .droppedByBrew)
        #expect(EnvironmentPolicy.status(of: "NO_PROXY") == .droppedByBrew)
        #expect(EnvironmentPolicy.status(of: "http_proxy") == .passed)
        #expect(EnvironmentPolicy.status(of: "PATH") == .ignored)
    }

    @Test func appEnvironmentBeatsProfilesAndEmptyIsDropped() {
        let env = build(process: ["HOME": "/h", "http_proxy": "http://app:1", "https_proxy": ""],
                        profile: ["http_proxy": "http://profile:2", "https_proxy": "http://profile:3"])
        #expect(env["http_proxy"] == "http://app:1")
        #expect(env["https_proxy"] == nil)
        let later = EnvironmentSources(process: [:], shellProfiles: [("~/.zshenv", ["http_proxy": "http://a:1"]),
                                                                     ("~/.zshrc", ["http_proxy": "http://b:2"])])
        #expect(EnvironmentPolicy.passThrough(later)["http_proxy"] == "http://b:2")
    }

    @Test func brewEnvProxiesAreLeftToBrew() {
        // bin/brew exports brew.env's lower-case proxies itself.
        #expect(build(brewEnv: ["http_proxy": "http://p:1"])["http_proxy"] == nil)
    }

    @Test func otherVariablesStayOut() {
        let env = build(process: ["HOME": "/h", "SSH_AUTH_SOCK": "/s", "SUDO_ASKPASS": "/x", "EDITOR": "vi"])
        #expect(env["SSH_AUTH_SOCK"] == nil && env["SUDO_ASKPASS"] == nil && env["EDITOR"] == nil)
    }

    @Test(arguments: [
        ("http://user:pass@proxy:8080", "http://•••@proxy:8080"),
        ("http://user:pass@proxy:8080/", "http://•••@proxy:8080/"),
        ("https://u%40corp:p%3Ass@proxy.corp", "https://•••@proxy.corp"),
        ("http://user:p@ss@proxy:8080", "http://•••@proxy:8080"),
        ("user:pass@proxy:8080", "•••@proxy:8080"),
        ("socks5h://alice@proxy:1080", "socks5h://•••@proxy:1080"),
        ("http://proxy:8080", "http://proxy:8080"),
        ("http://proxy:8080/path@x", "http://proxy:8080/path@x"),
        ("localhost,.corp,10.0.0.0/8", "localhost,.corp,10.0.0.0/8"),
        ("", ""),
    ])
    func masking(value: String, shown: String) {
        #expect(ProxySettings.mask(value) == shown)
        #expect(!ProxySettings.mask(value).contains("pass"))
    }

    @Test func textMasking() {
        let config = """
        HOMEBREW_PREFIX: /opt/homebrew
        http_proxy: http://user:secret@proxy.corp:8080
        all_proxy: socks5://a:b@c@proxy:1080
        HOMEBREW_CORE_GIT_REMOTE: https://github.com/d4rkwyng/intelbrew-core
        Core tap origin: git@github.com:o/r.git
        """
        let m = ProxySettings.maskText(config)
        #expect(m.contains("http_proxy: http://•••@proxy.corp:8080"))
        #expect(m.contains("all_proxy: socks5://•••@proxy:1080"))
        #expect(!m.contains("secret"))
        #expect(m.contains("https://github.com/d4rkwyng/intelbrew-core"))
        #expect(m.contains("git@github.com:o/r.git"))
    }

    @Test func environmentViewMasksAndLabels() {
        let sources = EnvironmentSources(
            process: ["HOME": "/h", "https_proxy": "http://bob:hunter2@proxy:3128"],
            shellProfiles: [("~/.zshrc", ["http_proxy": "http://alice:s3cret@proxy:8080", "HTTP_PROXY": "http://x:y@proxy:8080",
                                          "no_proxy": "localhost"])],
            brewEnvFiles: [("~/.homebrew/brew.env", ["all_proxy": "socks5://carol:pw@proxy:1080"])])
        let entries = EnvironmentPolicy.entries(sources: sources, intelbrew: none, readOnly: true)
        let rows = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        #expect(rows["http_proxy"]?.value == "http://•••@proxy:8080")
        #expect(rows["http_proxy"]?.source == "~/.zshrc")
        #expect(rows["http_proxy"]?.status == .passed)
        #expect(rows["https_proxy"]?.value == "http://•••@proxy:3128")
        #expect(rows["https_proxy"]?.source == "environment")
        #expect(rows["HTTP_PROXY"]?.status == .droppedByBrew)
        #expect(rows["HTTP_PROXY"]?.value == "http://•••@proxy:8080")
        #expect(rows["no_proxy"]?.value == "localhost")
        #expect(rows["all_proxy"]?.status == .brewEnv)
        #expect(rows["all_proxy"]?.value == "socks5://•••@proxy:1080")
        #expect(rows["all_proxy"]?.conflict == nil)
        for e in entries {
            for secret in ["s3cret", "hunter2", ":pw@", "x:y"] { #expect(!(e.value ?? "").contains(secret)) }
        }
    }

    @Test func brewEnvParserMatchesBinBrew() {
        let v = EnvFileParser.parseBrewEnv("""
        http_proxy=http://p:1
        https_proxy=http://p:2
        all_proxy=socks5://p:3
        no_proxy=localhost
        ftp_proxy=http://p:4
        HTTPS_PROXY=http://p:5
        HTTP_PROXY=http://p:6
        SUDO_ASKPASS=/usr/local/bin/askpass
        HOMEBREW_PREFIX=/x
        HOMEBREW_USER_CONFIG_HOME=/y
        HOMEBREW_CELLAR=/z
        PATH=/bin
        """)
        #expect(v["http_proxy"] == "http://p:1" && v["https_proxy"] == "http://p:2" && v["all_proxy"] == "socks5://p:3")
        #expect(v["no_proxy"] == "localhost" && v["ftp_proxy"] == "http://p:4")
        #expect(v["HTTPS_PROXY"] == nil && v["HTTP_PROXY"] == nil)   // bin/brew: lower case only
        #expect(v["SUDO_ASKPASS"] == "/usr/local/bin/askpass")
        #expect(v["HOMEBREW_PREFIX"] == nil && v["HOMEBREW_USER_CONFIG_HOME"] == nil)   // BIN_BREW_EXPORTED_VARS
        #expect(v["HOMEBREW_CELLAR"] == "/z")
        #expect(v["PATH"] == nil)
    }

    @Test func gitProbesGetTheProfileProxy() async {
        let runner = FakeRunner { _, _ in ok("") }
        let sources = EnvironmentSources(process: ["HOME": "/h"],
                                         shellProfiles: [("~/.zshrc", ["https_proxy": "http://proxy:8080",
                                                                       "HOMEBREW_NO_ANALYTICS": "1"])])
        let client = BrewClient(installation: arm, runner: runner, sources: sources, fileExists: { _ in true })
        _ = await client.git("/r", "ls-remote", "--tags", "origin")
        let env = runner.calls.first?.environment ?? [:]
        #expect(env["https_proxy"] == "http://proxy:8080")
        #expect(env["HOMEBREW_NO_ANALYTICS"] == nil)   // git probes still get no profile HOMEBREW_* settings
    }
}

/// 0.8.4: brew.env settings that undo Tankard's own values or ones it denies.
struct BrewEnvConflictTests {
    let none = IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:])
    var intelbrew: IntelbrewDetection {
        IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: EnvironmentSources(process: [:]))
    }

    func conflict(_ key: String, _ value: String, _ d: IntelbrewDetection? = nil) -> EnvironmentPolicy.BrewEnvConflict? {
        EnvironmentPolicy.brewEnvConflict(key, value, intelbrew: d ?? none)
    }

    @Test func dependentsCheck() {
        #expect(conflict("HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "1") == .dependentsCheck)
        #expect(conflict("HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "0") == nil)
        #expect(conflict("HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "") == nil)
    }

    @Test func greedy() {
        #expect(conflict("HOMEBREW_UPGRADE_GREEDY", "1") == .greedy)
        #expect(conflict("HOMEBREW_UPGRADE_GREEDY", "false") == nil)       // boolean: true
        #expect(conflict("HOMEBREW_UPGRADE_GREEDY_CASKS", "firefox zoom") == .greedy)
        #expect(conflict("HOMEBREW_UPGRADE_GREEDY_CASKS", " ") == nil)
        #expect(conflict("HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS", "1") == .greedy)
        #expect(conflict("HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS", "0") == .greedy)   // boolean: :set
    }

    @Test func intelbrewRemotes() {
        let d = intelbrew
        #expect(conflict("HOMEBREW_CORE_GIT_REMOTE", "https://github.com/Homebrew/homebrew-core", d) == .intelbrew)
        #expect(conflict("HOMEBREW_BREW_GIT_REMOTE", "https://github.com/Homebrew/brew", d) == .intelbrew)
        #expect(conflict("HOMEBREW_CORE_GIT_REMOTE", "git@github.com:d4rkwyng/intelbrew-core.git", d) == nil)
        #expect(conflict("HOMEBREW_BREW_GIT_REMOTE", Intelbrew.brewRemote, d) == nil)
        #expect(conflict("HOMEBREW_NO_INSTALL_FROM_API", "", d) == .intelbrew)
        #expect(conflict("HOMEBREW_NO_INSTALL_FROM_API", "1", d) == nil)
        // Outside Intelbrew mode: another remote is a trust warning; the fork's is how Intelbrew is set up.
        #expect(conflict("HOMEBREW_CORE_GIT_REMOTE", "https://example.com/core") == .trust)
        #expect(conflict("HOMEBREW_CORE_GIT_REMOTE", Intelbrew.coreRemote) == nil)
        #expect(conflict("HOMEBREW_CASK_GIT_REMOTE", "https://example.com/cask", d) == .trust)
    }

    @Test func autoremove() {
        #expect(conflict("HOMEBREW_NO_AUTOREMOVE", "0") == .autoremove)
        #expect(conflict("HOMEBREW_NO_AUTOREMOVE", "") == .autoremove)
        #expect(conflict("HOMEBREW_NO_AUTOREMOVE", "off") == .autoremove)
        #expect(conflict("HOMEBREW_NO_AUTOREMOVE", "1") == nil)
    }

    @Test func output() {
        for key in ["HOMEBREW_COLOR", "HOMEBREW_VERBOSE", "HOMEBREW_DEBUG", "HOMEBREW_VERBOSE_USING_DOTS"] {
            #expect(conflict(key, "1") == .output)
        }
        #expect(conflict("HOMEBREW_VERBOSE", "0") == .output)            // boolean: :set
        #expect(conflict("HOMEBREW_VERBOSE_USING_DOTS", "0") == nil)     // boolean: true
        #expect(conflict("HOMEBREW_COLOR", "") == nil)
        #expect(conflict("HOMEBREW_NO_COLOR", "") == .output)            // empties Tankard's 1
        #expect(conflict("HOMEBREW_NO_COLOR", "1") == nil)
        #expect(conflict("HOMEBREW_NO_ENV_HINTS", "") == .output)
    }

    @Test func caskOptionsAndAskpass() {
        #expect(conflict("HOMEBREW_CASK_OPTS", "--appdir=/x") == .caskOptions)
        #expect(conflict("HOMEBREW_CASK_OPTS", "--require-sha --language=de") == nil)
        #expect(conflict("SUDO_ASKPASS", "/usr/local/bin/my-askpass") == .askpass)
    }

    @Test func deniedCategories() {
        #expect(conflict("HOMEBREW_CELLAR", "/x") == .location)
        #expect(conflict("HOMEBREW_CACHE", "/x") == .defaultFolders)
        #expect(conflict("HOMEBREW_LOGS", "/x") == .defaultFolders)
        #expect(conflict("HOMEBREW_DEVELOPER", "1") == .trust)
        #expect(conflict("HOMEBREW_NO_VERIFY_ATTESTATIONS", "1") == .trust)
        #expect(conflict("HOMEBREW_API_DOMAIN", "https://mirror") == .mirror)
        #expect(conflict("HOMEBREW_BOTTLE_DOMAIN", "https://mirror") == .mirror)
    }

    @Test func noWarning() {
        #expect(conflict("HOMEBREW_GITHUB_API_TOKEN", "ghp_x") == nil)    // brew.env is a fine place for a token
        #expect(conflict("HOMEBREW_NO_ANALYTICS", "1") == nil)
        #expect(conflict("HOMEBREW_NO_AUTO_UPDATE", "1") == nil)
        #expect(conflict("HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY", "1") == nil)
        #expect(conflict("http_proxy", "http://p:1") == nil)
        #expect(conflict("HOMEBREW_FOO", "1") == nil)
    }

    @Test func rowsCarryTheConflictAsBrewReadsIt() {
        // The last file wins: the user file's NO_AUTOREMOVE=1 undoes the prefix file's 0.
        let sources = EnvironmentSources(process: [:], brewEnvFiles: [
            ("/opt/homebrew/etc/homebrew/brew.env", ["HOMEBREW_NO_AUTOREMOVE": "0", "HOMEBREW_UPGRADE_GREEDY": "1"]),
            ("~/.homebrew/brew.env", ["HOMEBREW_NO_AUTOREMOVE": "1", "SUDO_ASKPASS": "/a",
                                      "HOMEBREW_GITHUB_API_TOKEN": "ghp_secret"]),
        ])
        let rows = Dictionary(uniqueKeysWithValues: EnvironmentPolicy.entries(sources: sources, intelbrew: none).map { ($0.key, $0) })
        #expect(rows["HOMEBREW_NO_AUTOREMOVE"]?.conflict == nil)
        #expect(rows["HOMEBREW_UPGRADE_GREEDY"]?.conflict == .greedy)
        #expect(rows["HOMEBREW_UPGRADE_GREEDY"]?.source == "/opt/homebrew/etc/homebrew/brew.env")
        #expect(rows["SUDO_ASKPASS"]?.conflict == .askpass)
        #expect(rows["SUDO_ASKPASS"]?.status == .brewEnv)
        #expect(rows["HOMEBREW_GITHUB_API_TOKEN"]?.value == "••••••")
        #expect(rows["HOMEBREW_GITHUB_API_TOKEN"]?.conflict == nil)
        let warned = EnvironmentPolicy.brewEnvConflicts(sources: sources, intelbrew: none).map(\.key)
        #expect(warned == ["HOMEBREW_UPGRADE_GREEDY", "SUDO_ASKPASS"])
        // A shell profile's setting never warns (Tankard filters it).
        let shell = EnvironmentSources(process: [:], shellProfiles: [("~/.zshrc", ["HOMEBREW_UPGRADE_GREEDY": "1"])])
        #expect(EnvironmentPolicy.brewEnvConflicts(sources: shell, intelbrew: none).isEmpty)
    }

    @Test func intelbrewRowFromBrewEnv() {
        let sources = EnvironmentSources(process: [:], brewEnvFiles: [
            ("~/.homebrew/brew.env", ["HOMEBREW_BREW_GIT_REMOTE": "https://github.com/Homebrew/brew"]),
        ])
        let row = EnvironmentPolicy.entries(sources: sources, intelbrew: intelbrew).first { $0.key == "HOMEBREW_BREW_GIT_REMOTE" }
        #expect(row?.status == .brewEnv)
        #expect(row?.conflict == .intelbrew)
    }
}

/// 0.8.4: Tankard and the brew it runs read the same user brew.env.
struct ConfigHomeTests {
    let arm = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
    let none = IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:])

    @Test func xdgParsing() {
        let p = { (s: String) in EnvFileParser.parseShell(s, home: "/Users/x")["XDG_CONFIG_HOME"] }
        #expect(p("export XDG_CONFIG_HOME=\"$HOME/.config\"") == "/Users/x/.config")
        #expect(p("export XDG_CONFIG_HOME=${HOME}/.config") == "/Users/x/.config")
        #expect(p("export XDG_CONFIG_HOME=~/.config") == "/Users/x/.config")
        #expect(p("export XDG_CONFIG_HOME=/opt/cfg") == "/opt/cfg")
        #expect(p("export XDG_CONFIG_HOME=$HOMEDIR/.config") == nil)
        #expect(p("export XDG_CONFIG_HOME=\"${XDG_CONFIG_HOME:-$HOME/.config}\"") == nil)
        #expect(p("export XDG_CONFIG_HOME='~/.config'") == "~/.config")   // single quotes: literal, as in the shell
        #expect(EnvFileParser.parseShell("export XDG_CONFIG_HOME=$HOME/.config")["XDG_CONFIG_HOME"] == nil)   // no home given
    }

    @Test func passedToBrew() {
        func env(_ process: [String: String], _ profile: [String: String]) -> [String: String] {
            BrewEnvironment.build(installation: arm,
                                  sources: EnvironmentSources(process: process, shellProfiles: [("~/.zshrc", profile)]),
                                  intelbrew: none, readOnly: true)
        }
        #expect(env(["HOME": "/h", "XDG_CONFIG_HOME": "/app"], ["XDG_CONFIG_HOME": "/prof"])["XDG_CONFIG_HOME"] == "/app")
        #expect(env(["HOME": "/h"], ["XDG_CONFIG_HOME": "/prof"])["XDG_CONFIG_HOME"] == "/prof")
        #expect(env(["HOME": "/h"], ["HOMEBREW_XDG_CONFIG_HOME": "/hb"])["HOMEBREW_XDG_CONFIG_HOME"] == "/hb")
        #expect(env(["HOME": "/h"], [:])["XDG_CONFIG_HOME"] == nil)
        #expect(env(["HOME": "/h", "XDG_CONFIG_HOME": ""], ["XDG_CONFIG_HOME": "/prof"])["XDG_CONFIG_HOME"] == nil)
        #expect(EnvironmentPolicy.status(of: "XDG_CONFIG_HOME") == .passed)
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_XDG_CONFIG_HOME") == .passed)
    }

    /// A throwaway HOME with a brew.env in both places brew could look.
    struct Home {
        let path: String
        init() throws {
            path = FileManager.default.temporaryDirectory.appendingPathComponent("tankard-xdg-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: path + "/.homebrew", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: path + "/.config/homebrew", withIntermediateDirectories: true)
            try "HOMEBREW_CORE_GIT_REMOTE=https://example.com/home-file\n"
                .write(toFile: path + "/.homebrew/brew.env", atomically: true, encoding: .utf8)
            try "HOMEBREW_CORE_GIT_REMOTE=\(Intelbrew.coreRemote)\n"
                .write(toFile: path + "/.config/homebrew/brew.env", atomically: true, encoding: .utf8)
        }
        func profile(_ text: String) throws {
            try text.write(toFile: path + "/.zshrc", atomically: true, encoding: .utf8)
        }
        func remove() { try? FileManager.default.removeItem(atPath: path) }
    }

    func load(_ h: Home, _ extra: [String: String] = [:]) -> EnvironmentSources {
        EnvironmentSources.load(prefix: "/nonexistent-prefix", process: ["HOME": h.path, "SHELL": "/bin/zsh"].merging(extra) { $1 })
    }

    @Test func profileXDGPicksTheSameFileBrewWillRead() throws {
        let h = try Home(); defer { h.remove() }
        try h.profile("export XDG_CONFIG_HOME=\"$HOME/.config\"\n")
        let s = load(h)
        #expect(s.brewEnvFiles.map(\.0).last == "~/.config/homebrew/brew.env")
        let env = BrewEnvironment.build(installation: arm, sources: s, intelbrew: none, readOnly: true)
        #expect(env["XDG_CONFIG_HOME"] == h.path + "/.config")
        // What bin/brew does with that environment picks the same file.
        #expect(EnvironmentSources.brewEnvPaths(prefix: arm.prefix, home: env["HOME"]!, env: env).last
                == h.path + "/.config/homebrew/brew.env")
        // Intelbrew detection reads that file too.
        let d = IntelbrewDetector.detect(coreOrigin: nil, sources: s)
        #expect(d.detected)
        #expect(d.found[Intelbrew.coreRemoteKey]?.source == "~/.config/homebrew/brew.env")
    }

    @Test func appXDGPassesThroughAndPicksTheSameFile() throws {
        let h = try Home(); defer { h.remove() }
        let s = load(h, ["XDG_CONFIG_HOME": h.path + "/.config"])
        #expect(s.brewEnvFiles.map(\.0).last == "~/.config/homebrew/brew.env")
        let env = BrewEnvironment.build(installation: arm, sources: s, intelbrew: none, readOnly: true)
        #expect(env["XDG_CONFIG_HOME"] == h.path + "/.config")
    }

    @Test func noXDGBothUseDotHomebrew() throws {
        let h = try Home(); defer { h.remove() }
        try h.profile("export HOMEBREW_NO_ANALYTICS=1\n")
        let s = load(h)
        #expect(s.brewEnvFiles.map(\.0).last == "~/.homebrew/brew.env")
        let env = BrewEnvironment.build(installation: arm, sources: s, intelbrew: none, readOnly: true)
        #expect(env["XDG_CONFIG_HOME"] == nil && env["HOMEBREW_XDG_CONFIG_HOME"] == nil)
        let d = IntelbrewDetector.detect(coreOrigin: nil, sources: s)
        #expect(!d.detected)   // ~/.homebrew/brew.env points elsewhere
        #expect(d.found[Intelbrew.coreRemoteKey]?.source == "~/.homebrew/brew.env")
    }

    @Test func emptyAppXDGIsUnsetForBoth() throws {
        // Tankard passes nothing for an empty value, and bin/brew falls back to ~/.homebrew.
        let h = try Home(); defer { h.remove() }
        try h.profile("export XDG_CONFIG_HOME=\"$HOME/.config\"\n")
        let s = load(h, ["XDG_CONFIG_HOME": ""])
        #expect(s.brewEnvFiles.map(\.0).last == "~/.homebrew/brew.env")
        #expect(BrewEnvironment.build(installation: arm, sources: s, intelbrew: none, readOnly: true)["XDG_CONFIG_HOME"] == nil)
    }

    @Test func homebrewXDGFallback() throws {
        let h = try Home(); defer { h.remove() }
        try h.profile("export HOMEBREW_XDG_CONFIG_HOME=\(h.path)/.config\n")
        let s = load(h)
        #expect(s.brewEnvFiles.map(\.0).last == "~/.config/homebrew/brew.env")
        let env = BrewEnvironment.build(installation: arm, sources: s, intelbrew: none, readOnly: true)
        #expect(env["HOMEBREW_XDG_CONFIG_HOME"] == h.path + "/.config")
        #expect(EnvironmentSources.brewEnvPaths(prefix: arm.prefix, home: env["HOME"]!, env: env).last
                == h.path + "/.config/homebrew/brew.env")
    }

    @Test func environmentViewRow() {
        let s = EnvironmentSources(process: [:], shellProfiles: [("~/.zshrc", ["XDG_CONFIG_HOME": "/cfg"])])
        let row = EnvironmentPolicy.entries(sources: s, intelbrew: none).first { $0.key == "XDG_CONFIG_HOME" }
        #expect(row?.status == .passed)
        #expect(row?.value == "/cfg")
    }
}
