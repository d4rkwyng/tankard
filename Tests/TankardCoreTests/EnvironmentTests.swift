import Foundation
import Testing
@testable import TankardCore

struct EnvFileParserTests {
    @Test func shellProfile() {
        let text = """
        # >>> intelbrew >>>
        export HOMEBREW_NO_INSTALL_FROM_API=1
        export HOMEBREW_CORE_GIT_REMOTE="https://github.com/d4rkwyng/intelbrew-core"
          export HOMEBREW_BREW_GIT_REMOTE='https://github.com/d4rkwyng/brew'  # brew fork
        # <<< intelbrew <<<
        HOMEBREW_NO_ANALYTICS=1;
        export HOMEBREW_CASK_OPTS="--appdir=$HOME/Apps"
        export HOMEBREW_A=1 HOMEBREW_B=2
        PATH=/opt/homebrew/bin:$PATH
        # export HOMEBREW_COMMENTED=1
        """
        let vars = EnvFileParser.parseShell(text)
        #expect(vars["HOMEBREW_NO_INSTALL_FROM_API"] == "1")
        #expect(vars["HOMEBREW_CORE_GIT_REMOTE"] == "https://github.com/d4rkwyng/intelbrew-core")
        #expect(vars["HOMEBREW_BREW_GIT_REMOTE"] == "https://github.com/d4rkwyng/brew")
        #expect(vars["HOMEBREW_NO_ANALYTICS"] == "1")
        #expect(vars["HOMEBREW_CASK_OPTS"] == nil)   // needs shell expansion: skipped
        #expect(vars["HOMEBREW_A"] == nil)           // several assignments on one line: skipped
        #expect(vars["HOMEBREW_COMMENTED"] == nil)
        #expect(vars["PATH"] == nil)
    }

    @Test func laterLinesWin() {
        let vars = EnvFileParser.parseShell("export HOMEBREW_X=1\nexport HOMEBREW_X=2\n")
        #expect(vars["HOMEBREW_X"] == "2")
    }

    @Test func brewEnvKeepsQuotesLiterally() {
        let vars = EnvFileParser.parseBrewEnv("HOMEBREW_CORE_GIT_REMOTE=\"https://x\"\nOTHER=1\n")
        #expect(vars["HOMEBREW_CORE_GIT_REMOTE"] == "\"https://x\"")
        #expect(vars["OTHER"] == nil)
    }
}

struct IntelbrewDetectionTests {
    @Test(arguments: [
        "https://github.com/d4rkwyng/intelbrew-core",
        "https://github.com/d4rkwyng/intelbrew-core.git",
        "https://github.com/D4rkwyng/Intelbrew-Core/",
        "git@github.com:d4rkwyng/intelbrew-core.git",
        "ssh://git@github.com/d4rkwyng/intelbrew-core",
        "http://github.com/d4rkwyng/intelbrew-core",
    ])
    func coreForkSpellings(remote: String) {
        #expect(Intelbrew.isCoreFork(remote))
    }

    @Test func notForks() {
        #expect(!Intelbrew.isCoreFork("https://github.com/Homebrew/homebrew-core"))
        #expect(!Intelbrew.isCoreFork("https://github.com/d4rkwyng/intelbrew-core-old"))
        #expect(!Intelbrew.isBrewFork("https://github.com/Homebrew/brew"))
        #expect(Intelbrew.isBrewFork("https://github.com/d4rkwyng/brew.git"))
    }

    @Test func detectedByCoreOrigin() {
        // The VM: core is the fork, but no shell profile sets anything.
        let d = IntelbrewDetector.detect(coreOrigin: "https://github.com/d4rkwyng/intelbrew-core",
                                         sources: EnvironmentSources(process: ["HOME": "/Users/x"]))
        #expect(d.detected)
        #expect(d.env == [
            "HOMEBREW_NO_INSTALL_FROM_API": "1",
            "HOMEBREW_CORE_GIT_REMOTE": Intelbrew.coreRemote,
            "HOMEBREW_BREW_GIT_REMOTE": Intelbrew.brewRemote,
        ])
    }

    @Test func detectedByProfileInAPIMode() {
        // A GUI app: no core tap yet, settings only in ~/.zshenv.
        let sources = EnvironmentSources(
            process: ["HOME": "/Users/x"],
            shellProfiles: [("~/.zshenv", [
                "HOMEBREW_CORE_GIT_REMOTE": "https://github.com/d4rkwyng/intelbrew-core",
                "HOMEBREW_BREW_GIT_REMOTE": "git@github.com:d4rkwyng/brew.git",
            ])]
        )
        let d = IntelbrewDetector.detect(coreOrigin: nil, sources: sources)
        #expect(d.detected)
        #expect(d.reasons == ["HOMEBREW_CORE_GIT_REMOTE set in ~/.zshenv"])
        #expect(d.found["HOMEBREW_CORE_GIT_REMOTE"]?.source == "~/.zshenv")
        #expect(d.env["HOMEBREW_BREW_GIT_REMOTE"] == "git@github.com:d4rkwyng/brew.git") // user's spelling kept
    }

    @Test func notDetected() {
        let d = IntelbrewDetector.detect(coreOrigin: "https://github.com/Homebrew/homebrew-core",
                                         sources: EnvironmentSources(process: [:]))
        #expect(!d.detected)
        #expect(d.env.isEmpty)
    }

    @Test func precedence() {
        // brew.env > process environment > shell profile.
        let key = "HOMEBREW_CORE_GIT_REMOTE"
        var s = EnvironmentSources(process: [key: "env"], shellProfiles: [("~/.zshenv", [key: "profile"])])
        #expect(s.effective(key) == EnvSetting(value: "env", source: "environment"))
        s.brewEnvFiles = [("~/.homebrew/brew.env", [key: "brewenv"])]
        #expect(s.effective(key)?.value == "brewenv")
        s = EnvironmentSources(process: [:], shellProfiles: [("~/.zshenv", [key: "a"]), ("~/.zshrc", [key: "b"])])
        #expect(s.effective(key)?.value == "b")
    }

    @Test func profilePaths() {
        #expect(EnvironmentSources.profilePaths(home: "/h", shell: "/bin/zsh", zdotdir: nil)
                == ["/h/.zshenv", "/h/.zprofile", "/h/.zshrc", "/h/.zlogin"])
        #expect(EnvironmentSources.profilePaths(home: "/h", shell: "/bin/zsh", zdotdir: "/h/.config/zsh")
                == ["/h/.zshenv", "/h/.config/zsh/.zshenv", "/h/.config/zsh/.zprofile", "/h/.config/zsh/.zshrc", "/h/.config/zsh/.zlogin"])
        #expect(EnvironmentSources.brewEnvPaths(prefix: "/usr/local", home: "/h", env: [:])
                == ["/etc/homebrew/brew.env", "/usr/local/etc/homebrew/brew.env", "/h/.homebrew/brew.env"])
        #expect(EnvironmentSources.brewEnvPaths(prefix: "/usr/local", home: "/h", env: ["XDG_CONFIG_HOME": "/x"]).last
                == "/x/homebrew/brew.env")
    }
}

struct BrewEnvironmentTests {
    let intel = BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew")
    let intelbrew = IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: EnvironmentSources(process: [:]))

    @Test func cleanEnvironment() {
        // What launchd hands a GUI app, plus junk a terminal might carry.
        let sources = EnvironmentSources(
            process: ["HOME": "/Users/x", "USER": "x", "PATH": "/usr/bin:/bin", "__CFBundleIdentifier": "app",
                      "TMPDIR": "/var/folders/t", "HOMEBREW_GITHUB_API_TOKEN": "secret", "RUBYOPT": "-w",
                      "LANG": "de_DE.ISO8859-1"],
            shellProfiles: [("~/.zshenv", ["HOMEBREW_NO_ANALYTICS": "1"])]
        )
        let env = BrewEnvironment.build(installation: intel, sources: sources, intelbrew: intelbrew, readOnly: true)
        #expect(env == [
            "HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "TMPDIR": "/var/folders/t",
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/local/bin:/usr/local/sbin:/usr/bin:/bin",
            "HOMEBREW_NO_INSTALL_FROM_API": "1",
            "HOMEBREW_CORE_GIT_REMOTE": Intelbrew.coreRemote,
            "HOMEBREW_BREW_GIT_REMOTE": Intelbrew.brewRemote,
            "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1", "HOMEBREW_NO_AUTO_UPDATE": "1",
        ])
    }

    @Test func notIntelbrew() {
        let sources = EnvironmentSources(process: [:])
        let none = IntelbrewDetector.detect(coreOrigin: nil, sources: sources)
        let arm = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
        let env = BrewEnvironment.build(installation: arm, sources: sources, intelbrew: none, readOnly: false)
        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(env["HOMEBREW_CORE_GIT_REMOTE"] == nil)
        #expect(env["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin")
        #expect(env["HOME"]?.isEmpty == false && env["USER"]?.isEmpty == false && env["TMPDIR"]?.isEmpty == false)
    }

    @Test func intelbrewOverridesStaleValue() {
        // A stale upstream remote in a terminal's environment never reaches brew.
        let sources = EnvironmentSources(process: ["HOME": "/h", "HOMEBREW_BREW_GIT_REMOTE": "https://github.com/Homebrew/brew"])
        let d = IntelbrewDetector.detect(coreOrigin: Intelbrew.coreRemote, sources: sources)
        let env = BrewEnvironment.build(installation: intel, sources: sources, intelbrew: d, readOnly: true)
        #expect(env["HOMEBREW_BREW_GIT_REMOTE"] == Intelbrew.brewRemote)
    }

    @Test func installation() {
        let i = BrewInstallation.from(brewPath: "/opt/homebrew/bin/brew")
        #expect(i.prefix == "/opt/homebrew")
        #expect(i.coreTapPath.hasSuffix("/Library/Taps/homebrew/homebrew-core"))
        #expect(BrewInstallation.candidates == ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"])
    }
}
