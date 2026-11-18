import Foundation
import Testing
@testable import TankardCore

/// 0.8.3: a live check that a shell profile's HOMEBREW_NO_ANALYTICS reaches
/// the real brew through Tankard's own code path (EnvironmentSources.load,
/// BrewClient.environment, the runner). Off by default; read-only
/// (`brew config`, `brew analytics state`). The profile is a temporary
/// ~/.zshrc in a throwaway HOME; brew itself runs with the real HOME.
///
///   TANKARD_REAL_ENV=1 Scripts/test.sh --filter EnvironmentRealCanary
struct EnvironmentRealCanary {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANKARD_REAL_ENV"] != nil))
    func analyticsOptOutReachesBrew() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("tankard-env-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        try "export HOMEBREW_NO_ANALYTICS=1\nexport HOMEBREW_API_DOMAIN=https://mirror.invalid/api\n"
            .write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)

        let installation = try #require(BrewInstallation.locate(override: ProcessInfo.processInfo.environment["TANKARD_BREW"]))
        var sources = EnvironmentSources.load(prefix: installation.prefix,
                                              process: ["HOME": home, "SHELL": "/bin/zsh", "USER": NSUserName()])
        sources.process["HOME"] = NSHomeDirectory()
        let client = BrewClient(installation: installation, sources: sources)
        let env = client.environment(for: await client.detectIntelbrew())
        for args in [["config"], ["analytics", "state"]] {
            let r = try await client.runner.run(installation.brewPath, args, environment: env)
            let out = (r.stdoutString + r.stderrString)
                .split(separator: "\n").filter { $0.contains("HOMEBREW_") || $0.contains("nalytics") }
            print("brew \(args.joined(separator: " ")):\n  " + out.joined(separator: "\n  "))
            if args == ["config"] {
                #expect(out.contains("HOMEBREW_NO_ANALYTICS: set"))
                #expect(!out.contains { $0.hasPrefix("HOMEBREW_API_DOMAIN") })
            } else {
                #expect(out.contains { $0.contains("analytics are disabled") })
            }
        }
    }

    /// 0.8.4: a profile's http_proxy (with user:password) and XDG_CONFIG_HOME
    /// reach the real brew through Tankard's environment; Health shows the
    /// proxy masked. No proxy is used: `brew config` makes no request, and
    /// the proxy is 127.0.0.1:9 (discard). The XDG brew.env sets
    /// HOMEBREW_DISPLAY_INSTALL_TIMES, which only reaches brew if bin/brew
    /// reads the file Tankard picked.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANKARD_REAL_ENV"] != nil))
    func proxyAndXDGReachBrew() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("tankard-proxy-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: home + "/.config/homebrew", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        try """
        export http_proxy=http://tankuser:tankpass@127.0.0.1:9
        export https_proxy=$http_proxy
        export no_proxy=localhost
        export XDG_CONFIG_HOME="$HOME/.config"
        """.write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        try "HOMEBREW_DISPLAY_INSTALL_TIMES=1\n".write(toFile: home + "/.config/homebrew/brew.env", atomically: true, encoding: .utf8)

        let installation = try #require(BrewInstallation.locate(override: ProcessInfo.processInfo.environment["TANKARD_BREW"]))
        var sources = EnvironmentSources.load(prefix: installation.prefix,
                                              process: ["HOME": home, "SHELL": "/bin/zsh", "USER": NSUserName()])
        #expect(sources.brewEnvFiles.last?.0 == "~/.config/homebrew/brew.env")
        sources.process["HOME"] = NSHomeDirectory()
        let client = BrewClient(installation: installation, sources: sources)
        let detection = await client.detectIntelbrew()
        let env = client.environment(for: detection)
        let r = try await client.runner.run(installation.brewPath, ["config"], environment: env)
        let raw = r.stdoutString + r.stderrString
        let lines = raw.split(separator: "\n").map(String.init)
            .filter { $0.contains("proxy") || $0.contains("INSTALL_TIMES") }
        print("brew config (masked):\n  " + ProxySettings.maskText(lines.joined(separator: "\n  ")))
        #expect(lines.contains("http_proxy: http://tankuser:tankpass@127.0.0.1:9"))   // brew got the real value
        #expect(lines.contains("https_proxy: http://tankuser:tankpass@127.0.0.1:9"))
        #expect(lines.contains("no_proxy: localhost"))
        #expect(lines.contains("HOMEBREW_DISPLAY_INSTALL_TIMES: set"))   // the XDG brew.env was read
        #expect(!ProxySettings.maskText(raw).contains("tankpass"))
        let rows = EnvironmentPolicy.entries(sources: sources, intelbrew: detection, readOnly: true)
        let row = rows.first { $0.key == "http_proxy" }
        print("Health row: \(row?.key ?? "-")=\(row?.value ?? "-")  (\(row?.source ?? "-"))")
        #expect(row?.value == "http://•••@127.0.0.1:9")
        #expect(row?.source == "~/.zshrc")
        #expect(rows.allSatisfy { !($0.value ?? "").contains("tankpass") })
    }
}
