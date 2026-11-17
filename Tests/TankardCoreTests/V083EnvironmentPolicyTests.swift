import Foundation
import Testing
@testable import TankardCore

/// 0.8.3: the user's HOMEBREW_* settings that reach brew, and the ones that don't.
struct EnvironmentPolicyTests {
    let arm = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
    let none = IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:])

    func build(process: [String: String] = ["HOME": "/h"], profile: [String: String] = [:],
               brewEnv: [String: String] = [:], intelbrew: IntelbrewDetection? = nil,
               readOnly: Bool = false) -> [String: String] {
        let sources = EnvironmentSources(process: process, shellProfiles: [("~/.zshrc", profile)],
                                         brewEnvFiles: brewEnv.isEmpty ? [] : [("~/.homebrew/brew.env", brewEnv)])
        return BrewEnvironment.build(installation: arm, sources: sources, intelbrew: intelbrew ?? none, readOnly: readOnly)
    }

    @Test(arguments: [
        ("HOMEBREW_NO_ANALYTICS", "1"),
        ("HOMEBREW_NO_INSECURE_REDIRECT", "1"),
        ("HOMEBREW_CASK_OPTS", "--require-sha"),
        ("HOMEBREW_TEMP", "/Volumes/Fast/tmp"),
        ("HOMEBREW_CURL_RETRIES", "5"),
        ("HOMEBREW_DISPLAY_INSTALL_TIMES", "1"),
        ("HOMEBREW_FORCE_BREWED_CURL", "1"),
        ("HOMEBREW_FORBIDDEN_FORMULAE", "node python"),
        ("HOMEBREW_DOWNLOAD_CONCURRENCY", "4"),
        ("HOMEBREW_NO_INSTALL_CLEANUP", "1"),
    ])
    func allowedValuesPass(key: String, value: String) {
        #expect(build(profile: [key: value])[key] == value)
    }

    @Test(arguments: [
        "HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY", "HOMEBREW_CACHE", "HOMEBREW_LOGS",
        "HOMEBREW_CORE_GIT_REMOTE", "HOMEBREW_BREW_GIT_REMOTE", "HOMEBREW_CASK_GIT_REMOTE",
        "HOMEBREW_API_DOMAIN", "HOMEBREW_BOTTLE_DOMAIN", "HOMEBREW_ARTIFACT_DOMAIN",
        "HOMEBREW_DEVELOPER", "HOMEBREW_NO_INSTALL_FROM_API", "HOMEBREW_NO_VERIFY_ATTESTATIONS",
        "HOMEBREW_NO_REQUIRE_TAP_TRUST", "HOMEBREW_GITHUB_API_TOKEN", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK",
        "HOMEBREW_SOMETHING_NEW",
    ])
    func deniedAndUnknownDontPass(key: String) {
        #expect(build(process: ["HOME": "/h", key: "x"], profile: [key: "y"])[key] == nil)
        #expect(EnvironmentPolicy.status(of: key) != .passed)
    }

    @Test func statusCategories() {
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_PREFIX") == .denied(.location))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_CACHE") == .denied(.defaultFolders))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_LOGS") == .denied(.defaultFolders))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_TEMP") == .passed)
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_API_DOMAIN") == .denied(.mirror))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_ARTIFACT_DOMAIN_NO_FALLBACK") == .denied(.mirror))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_GITHUB_API_TOKEN") == .denied(.credential))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_DEVELOPER") == .denied(.trust))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_CORE_GIT_REMOTE") == .denied(.trust))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_COLOR") == .tankard(.output))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_UPGRADE_GREEDY") == .tankard(.greedy))
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_NO_ANALYTICS") == .passed)
        #expect(EnvironmentPolicy.status(of: "HOMEBREW_FOO") == .ignored)
    }

    @Test func tankardValuesWin() {
        let env = build(profile: ["HOMEBREW_NO_COLOR": "", "HOMEBREW_COLOR": "1", "HOMEBREW_VERBOSE": "1",
                                  "HOMEBREW_DEBUG": "1", "HOMEBREW_UPGRADE_GREEDY": "1",
                                  "HOMEBREW_NO_ENV_HINTS": "0"], readOnly: true)
        #expect(env["HOMEBREW_NO_COLOR"] == "1")
        #expect(env["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(env["HOMEBREW_COLOR"] == nil)
        #expect(env["HOMEBREW_VERBOSE"] == nil)
        #expect(env["HOMEBREW_DEBUG"] == nil)
        #expect(env["HOMEBREW_UPGRADE_GREEDY"] == nil)
        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func noAutoUpdatePassesOnlyWhereTankardDoesntForceIt() {
        #expect(build(readOnly: false)["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(build(profile: ["HOMEBREW_NO_AUTO_UPDATE": "1"], readOnly: false)["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(build(readOnly: true)["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func intelbrewRemotesWinUnchanged() {
        let sources = EnvironmentSources(process: ["HOME": "/h"])
        let d = IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: sources)
        let env = build(process: ["HOME": "/h", "HOMEBREW_BREW_GIT_REMOTE": "https://github.com/Homebrew/brew"],
                        profile: ["HOMEBREW_CORE_GIT_REMOTE": "https://example.com/core",
                                  "HOMEBREW_NO_ANALYTICS": "1"], intelbrew: d)
        #expect(env["HOMEBREW_CORE_GIT_REMOTE"] == Intelbrew.coreRemote)
        #expect(env["HOMEBREW_BREW_GIT_REMOTE"] == Intelbrew.brewRemote)
        #expect(env["HOMEBREW_NO_INSTALL_FROM_API"] == "1")
        #expect(env["HOMEBREW_NO_ANALYTICS"] == "1")
    }

    @Test func environmentBeatsProfileAndEmptyIsDropped() {
        let env = build(process: ["HOME": "/h", "HOMEBREW_CURL_RETRIES": "9", "HOMEBREW_NO_EMOJI": ""],
                        profile: ["HOMEBREW_CURL_RETRIES": "3", "HOMEBREW_NO_EMOJI": "1"])
        #expect(env["HOMEBREW_CURL_RETRIES"] == "9")
        #expect(env["HOMEBREW_NO_EMOJI"] == nil)
    }

    @Test func laterProfileWins() {
        let sources = EnvironmentSources(process: [:], shellProfiles: [
            ("~/.zshenv", ["HOMEBREW_CASK_OPTS": "--appdir=/a"]),
            ("~/.zshrc", ["HOMEBREW_CASK_OPTS": "--appdir=/b"]),
        ])
        #expect(EnvironmentPolicy.passThrough(sources) == [:])   // --appdir never passes
        let langs = EnvironmentSources(process: [:], shellProfiles: [
            ("~/.zshenv", ["HOMEBREW_CURL_RETRIES": "1"]),
            ("~/.zshrc", ["HOMEBREW_CURL_RETRIES": "2"]),
        ])
        #expect(EnvironmentPolicy.passThrough(langs) == ["HOMEBREW_CURL_RETRIES": "2"])
    }

    @Test func brewEnvIsLeftToBrew() {
        // bin/brew reads brew.env itself; Tankard doesn't copy it in.
        let env = build(brewEnv: ["HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_API_DOMAIN": "https://m"])
        #expect(env["HOMEBREW_NO_ANALYTICS"] == nil)
        #expect(env["HOMEBREW_API_DOMAIN"] == nil)
    }

    @Test func entriesForTheEnvironmentView() {
        let sources = EnvironmentSources(
            process: ["HOME": "/h", "HOMEBREW_GITHUB_API_TOKEN": "ghp_secret"],
            shellProfiles: [("~/.zshrc", ["HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_API_DOMAIN": "https://mirror",
                                          "HOMEBREW_FOO": "1", "HOMEBREW_COLOR": "1"])],
            brewEnvFiles: [("~/.homebrew/brew.env", ["HOMEBREW_CASK_OPTS": "--appdir=/a"])])
        // (brew.env's CASK_OPTS is brew's own business: shown, not filtered.)
        let rows = Dictionary(uniqueKeysWithValues: EnvironmentPolicy.entries(sources: sources, intelbrew: none, readOnly: true).map { ($0.key, $0) })
        #expect(rows["HOMEBREW_NO_ANALYTICS"]?.status == .passed)
        #expect(rows["HOMEBREW_NO_ANALYTICS"]?.source == "~/.zshrc")
        #expect(rows["HOMEBREW_API_DOMAIN"]?.status == .denied(.mirror))
        #expect(rows["HOMEBREW_FOO"]?.status == .ignored)
        #expect(rows["HOMEBREW_COLOR"]?.status == .tankard(.output))
        #expect(rows["HOMEBREW_CASK_OPTS"]?.status == .brewEnv)
        #expect(rows["HOMEBREW_GITHUB_API_TOKEN"]?.value == "••••••")
        #expect(rows["HOMEBREW_GITHUB_API_TOKEN"]?.source == "environment")
        // Tankard's own, not set by the user.
        #expect(rows["HOMEBREW_NO_COLOR"]?.value == nil)
        #expect(rows["HOMEBREW_NO_COLOR"]?.tankardValue == "1")
        #expect(rows["HOMEBREW_NO_AUTO_UPDATE"]?.status == .tankard(.autoUpdate))
        #expect(rows["HOME"] == nil)
    }
}

/// 0.8.3: HOMEBREW_CASK_OPTS passes only --require-sha and --language=.
struct CaskOptionsTests {
    @Test func forceDropped() {
        let c = CaskOptions.filter("--force")
        #expect(c.passed == "")
        #expect(c.dropped.map(\.option) == ["--force"])
        #expect(c.dropped.map(\.reason) == [.confirmation])
    }

    @Test func appdirDropped() {
        let c = CaskOptions.filter("--appdir=/Users/x/Applications")
        #expect(c.passed == "")
        #expect(c.dropped.map(\.reason) == [.location])
    }

    @Test func requireShaKept() {
        #expect(CaskOptions.filter("--require-sha").passed == "--require-sha")
    }

    @Test func languageKept() {
        #expect(CaskOptions.filter("--language=de,en-GB").passed == "--language=de,en-GB")
        // The space form isn't read by brew from CASK_OPTS; a bad value is dropped.
        #expect(CaskOptions.filter("--language de").passed == "")
        #expect(CaskOptions.filter("--language=").passed == "")
    }

    @Test func mixed() {
        let c = CaskOptions.filter("--appdir=~/Applications --require-sha --fontdir=/Library/Fonts --no-quarantine --language=fr --adopt --no-binaries")
        #expect(c.passed == "--require-sha --language=fr")
        #expect(c.dropped.map(\.option) == ["--appdir=~/Applications", "--fontdir=/Library/Fonts", "--no-quarantine", "--adopt", "--no-binaries"])
        #expect(c.dropped.map(\.reason) == [.location, .location, .confirmation, .confirmation, .other])
    }

    @Test func quotingAndWhitespace() {
        let c = CaskOptions.filter("  \t--require-sha\n  --appdir='/Users/x/My Apps'  \"--language=ja\"  --colorpickerdir=/a\\ b ")
        #expect(c.passed == "--require-sha --language=ja")
        #expect(c.dropped.map(\.option) == ["--appdir=/Users/x/My Apps", "--colorpickerdir=/a b"])
        #expect(CaskOptions.filter("   ").passed == "")
        #expect(CaskOptions.filter("--require-sha --require-sha").passed == "--require-sha")
    }

    @Test func throughBrewEnvironment() {
        let arm = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
        let none = IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:])
        func env(_ v: String) -> [String: String] {
            BrewEnvironment.build(installation: arm,
                                  sources: EnvironmentSources(process: [:], shellProfiles: [("~/.zshenv", ["HOMEBREW_CASK_OPTS": v])]),
                                  intelbrew: none, readOnly: false)
        }
        #expect(env("--appdir=/a --force")["HOMEBREW_CASK_OPTS"] == nil)   // nothing survives: not set
        #expect(env("--appdir=/a --require-sha")["HOMEBREW_CASK_OPTS"] == "--require-sha")
    }

    @Test func environmentViewShowsPartlyApplied() {
        let none = IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:])
        let sources = EnvironmentSources(process: [:], shellProfiles: [("~/.zshenv", ["HOMEBREW_CASK_OPTS": "--require-sha --appdir=/a"])])
        let row = EnvironmentPolicy.entries(sources: sources, intelbrew: none).first { $0.key == "HOMEBREW_CASK_OPTS" }
        #expect(row?.status == .partial)
        #expect(row?.caskOptions?.kept == ["--require-sha"])
        #expect(row?.caskOptions?.dropped.map(\.option) == ["--appdir=/a"])
        // brew.env: brew reads it over Tankard's environment, so the unsafe
        // options apply; the row carries them for Health's warning.
        let file = EnvironmentSources(process: [:], shellProfiles: [("~/.zshenv", ["HOMEBREW_CASK_OPTS": "--require-sha"])],
                                      brewEnvFiles: [("~/.homebrew/brew.env", ["HOMEBREW_CASK_OPTS": "--appdir=/x --force"])])
        let fileRow = EnvironmentPolicy.entries(sources: file, intelbrew: none).first { $0.key == "HOMEBREW_CASK_OPTS" }
        #expect(fileRow?.status == .brewEnv)
        #expect(fileRow?.source == "~/.homebrew/brew.env")
        #expect(fileRow?.caskOptions?.dropped.map(\.option) == ["--appdir=/x", "--force"])
        let safeFile = EnvironmentSources(process: [:], brewEnvFiles: [("/etc/homebrew/brew.env", ["HOMEBREW_CASK_OPTS": "--language=de"])])
        let safeRow = EnvironmentPolicy.entries(sources: safeFile, intelbrew: none).first { $0.key == "HOMEBREW_CASK_OPTS" }
        #expect(safeRow?.status == .brewEnv)
        #expect(safeRow?.caskOptions == nil)
        // All safe: plain "passed".
        let ok = EnvironmentSources(process: [:], shellProfiles: [("~/.zshenv", ["HOMEBREW_CASK_OPTS": "--require-sha"])])
        #expect(EnvironmentPolicy.entries(sources: ok, intelbrew: none).first { $0.key == "HOMEBREW_CASK_OPTS" }?.status == .passed)
    }
}
