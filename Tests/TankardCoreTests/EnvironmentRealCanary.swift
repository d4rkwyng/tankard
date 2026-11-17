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
}
