import Foundation
import os
import TankardCore

/// Demo mode (`TANKARD_DEMO=1`, or `=arm64`): the app runs against fake
/// runners fed by the test fixtures, so it can be shown and screenshotted
/// without touching Homebrew. Nothing is spawned; no brew, no git.
///
/// - `intelbrew` (the default): the Intel VM fixture (20 formulae, core on
///   the Intelbrew fork). That machine had nothing to upgrade, so demo mode
///   makes a few versions older (marked below) to have something to show.
/// - `arm64`: the arm64 fixture as captured (API mode, real outdated
///   formulae and casks).
///
/// Upgrades print a scripted brew log (with curl-style `\r` progress
/// redraws) and then report the package as current.
public enum Demo {
    public enum Variant: String, Sendable {
        case intelbrew, arm64

        public init?(environmentValue v: String?) {
            guard let v, !v.isEmpty, v != "0" else { return nil }
            self = v.lowercased() == "arm64" ? .arm64 : .intelbrew
        }
    }

    /// Edits applied to the Intel fixture in demo mode: name → installed
    /// version, outdated flag, drop the bottle (upgrade compiles).
    struct Tweak {
        var installed: String
        var outdated: Bool
        var dropBottle = false
    }

    static let intelTweaks: [String: Tweak] = [
        "python@3.15": Tweak(installed: "3.15.1", outdated: true),
        "openssl@4": Tweak(installed: "4.0.4", outdated: true),
        "sqlite": Tweak(installed: "3.54.0", outdated: true),
        "xz": Tweak(installed: "5.8.3", outdated: true),
        "ruby": Tweak(installed: "4.0.8", outdated: true, dropBottle: true),
        "zstd": Tweak(installed: "1.5.8", outdated: false), // newer than the tap
    ]

    /// Packages the demo has "upgraded" (shared by both fake runners).
    final class State: Sendable {
        let upgraded = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    }

    public static func dependencies(_ variant: Variant, pace: Double = 1) -> AppStore.Dependencies {
        let state = State()
        let installation: BrewInstallation
        let platform: BottlePlatform
        switch variant {
        case .intelbrew:
            installation = BrewInstallation(brewPath: "/usr/local/bin/brew", prefix: "/usr/local", repository: "/usr/local/Homebrew")
            platform = BottlePlatform(arch: .x86_64, macOSVersion: "14", cellar: "/usr/local/Cellar")
        case .arm64:
            installation = BrewInstallation(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew")
            platform = BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar")
        }
        let runner = InfoRunner(variant: variant, state: state, info: fixtureInfo(variant))
        let client = BrewClient(installation: installation, platform: platform, runner: runner,
                                sources: EnvironmentSources(process: ["HOME": NSHomeDirectory(), "USER": NSUserName()]),
                                fileExists: { path in variant == .intelbrew && path.hasSuffix("homebrew-core/.git") })
        return AppStore.Dependencies(
            makeClient: { client },
            streamRunner: ScriptRunner(variant: variant, state: state, info: fixtureInfo(variant), pace: pace),
            cache: nil,
            logURL: nil
        )
    }

    /// The demo resources bundle. Inside Tankard.app it is copied to
    /// Contents/Resources; under `swift run` / tests, Bundle.module finds it.
    static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("tankard_TankardAppModel.bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return Bundle.module
    }

    static func fixtureData(_ name: String) -> Data {
        guard let url = resources.url(forResource: name, withExtension: "json", subdirectory: "Demo"),
              let d = try? Data(contentsOf: url) else {
            return Data(#"{"formulae":[],"casks":[]}"#.utf8)
        }
        return d
    }

    static func fixtureInfo(_ variant: Variant) -> Data {
        fixtureData(variant == .intelbrew ? "sonoma-intelbrew-info" : "arm64-api-info")
    }

    /// The `brew info` JSON as the demo shows it now: fixture, plus the
    /// Intel tweaks, minus whatever was "upgraded" (back to current).
    static func currentInfo(_ variant: Variant, base: Data, upgraded: Set<String>) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return base }
        var formulae = root["formulae"] as? [[String: Any]] ?? []
        for i in formulae.indices {
            let name = formulae[i]["name"] as? String ?? ""
            let stable = (formulae[i]["versions"] as? [String: Any])?["stable"] as? String ?? ""
            let revision = formulae[i]["revision"] as? Int ?? 0
            let current = revision > 0 ? "\(stable)_\(revision)" : stable
            if upgraded.contains(name) {
                setInstalled(&formulae[i], version: current)
                formulae[i]["outdated"] = false
                continue
            }
            guard variant == .intelbrew, let t = intelTweaks[name] else { continue }
            setInstalled(&formulae[i], version: t.installed)
            formulae[i]["outdated"] = t.outdated
            if t.dropBottle { formulae[i]["bottle"] = [String: Any]() }
        }
        var casks = root["casks"] as? [[String: Any]] ?? []
        for i in casks.indices where upgraded.contains(casks[i]["token"] as? String ?? "") {
            casks[i]["installed"] = casks[i]["version"]
            casks[i]["outdated"] = false
        }
        root["formulae"] = formulae
        root["casks"] = casks
        return (try? JSONSerialization.data(withJSONObject: root)) ?? base
    }

    static func setInstalled(_ f: inout [String: Any], version: String) {
        guard var kegs = f["installed"] as? [[String: Any]], !kegs.isEmpty else { return }
        kegs[0]["version"] = version
        f["installed"] = Array(kegs.prefix(1))
    }

    /// Answers `brew info` and the git probes.
    struct InfoRunner: CommandRunning {
        var variant: Variant
        var state: State
        var info: Data

        func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
            if executable.hasSuffix("/brew") {
                try await Task.sleep(for: .milliseconds(350)) // brew is never instant
                guard arguments.first == "info" else { return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data()) }
                let upgraded = state.upgraded.withLock { $0 }
                return ProcessResult(exitCode: 0, stdout: Demo.currentInfo(variant, base: info, upgraded: upgraded), stderr: Data())
            }
            let isCore = arguments.count > 1 && arguments[1].hasSuffix("homebrew-core")
            let rest = Array(arguments.dropFirst(2))
            func out(_ s: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data((s + "\n").utf8), stderr: Data()) }
            switch (variant, rest) {
            case (.intelbrew, ["config", "--get", "remote.origin.url"]):
                return out(isCore ? Intelbrew.coreRemote : Intelbrew.brewRemote)
            case (.arm64, ["config", "--get", "remote.origin.url"]):
                return out("https://github.com/Homebrew/brew")
            case (_, ["rev-parse", "--abbrev-ref", "HEAD"]):
                return out("main")
            case (_, ["describe", "--tags"]), (_, ["describe", "--tags", "--exact-match", "HEAD"]):
                return out("7.0.14")
            case (_, ["tag", "--list"]):
                return out("7.0.12\n7.0.13\n7.0.14")
            default:
                return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data())
            }
        }
    }

    /// Plays a scripted `brew update` / `brew upgrade` log.
    struct ScriptRunner: StreamingCommandRunning {
        var variant: Variant
        var state: State
        var info: Data
        var pace: Double

        func stream(_ executable: String, _ arguments: [String], environment: [String: String],
                    output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            func say(_ s: String, _ ms: Double = 120) async throws {
                output(Data(s.utf8))
                try await Task.sleep(for: .milliseconds(Int(ms * pace)))
            }
            if arguments.first == "update" {
                try await say("==> Updating Homebrew...\n", 900)
                try await say("Already up-to-date.\n", 50)
                return 0
            }
            guard arguments.first == "upgrade", let qualified = arguments.last else { return 1 }
            let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
            let upgraded = state.upgraded.withLock { $0 }
            let data = Demo.currentInfo(variant, base: info, upgraded: upgraded)
            let entry = Demo.entry(named: name, in: data)

            let cellar = variant == .intelbrew ? "/usr/local/Cellar" : "/opt/homebrew/Cellar"
            try await say("==> Fetching downloads for: \(name)\n", 400)
            if entry.cask {
                try await say("==> Downloading \(name) \(entry.current)\n", 200)
                try await progress(output)
                try await say("==> Upgrading 1 outdated package:\n")
                try await say("\(name) \(entry.installed) -> \(entry.current)\n", 300)
                try await say("==> Upgrading \(name)\n", 400)
                try await say("==> Backing App '\(name)' up to '/opt/homebrew/Caskroom/\(name)/\(entry.installed)'\n", 300)
                try await say("==> Moving App '\(name)' to '/Applications'\n", 500)
                try await say("🍺  \(name) was successfully upgraded!\n", 400)
            } else if let bottle = entry.bottleURL {
                try await say("==> Downloading \(bottle)\n", 200)
                try await progress(output)
                try await say("==> Upgrading \(name)\n  \(entry.installed) -> \(entry.current)\n", 400)
                let tag = variant == .intelbrew ? "sonoma" : "arm64_golden_gate"
                try await say("==> Pouring \(name)--\(entry.current).\(tag).bottle.tar.gz\n", 1200)
                try await say("🍺  \(cellar)/\(name)/\(entry.current): 1,204 files, 38.2MB\n", 400)
                try await say("==> Running `brew cleanup \(name)`...\n", 500)
                try await say("Removing: \(cellar)/\(name)/\(entry.installed)... (1,198 files, 38.0MB)\n", 400)
            } else {
                try await say("==> Downloading \(name)-\(entry.current).tar.gz\n", 200)
                try await progress(output)
                try await say("==> Upgrading \(name)\n  \(entry.installed) -> \(entry.current)\n", 300)
                try await say("==> ./configure --prefix=\(cellar)/\(name)/\(entry.current)\n", 2200)
                try await say("==> make\n", 3500)
                try await say("==> make install\n", 900)
                try await say("🍺  \(cellar)/\(name)/\(entry.current): 9,881 files, 61.4MB, built in 2 minutes 4 seconds\n", 400)
            }
            state.upgraded.withLock { _ = $0.insert(name) }
            return 0
        }

        /// curl's progress bar: one line redrawn with `\r`.
        func progress(_ output: @escaping @Sendable (Data) -> Void) async throws {
            for pct in stride(from: 0.0, through: 100.0, by: 12.5) {
                let bar = String(repeating: "#", count: Int(pct * 0.72))
                let line = "\r" + bar.padding(toLength: 72, withPad: " ", startingAt: 0) + String(format: " %5.1f%%", pct)
                output(Data(line.utf8))
                try await Task.sleep(for: .milliseconds(Int(110 * pace)))
            }
            output(Data("\n".utf8))
        }
    }

    struct Entry {
        var installed = "?"
        var current = "?"
        var bottleURL: String?
        var cask = false
    }

    static func entry(named name: String, in data: Data) -> Entry {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Entry() }
        if let f = (root["formulae"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }) {
            let stable = (f["versions"] as? [String: Any])?["stable"] as? String ?? "?"
            let rev = f["revision"] as? Int ?? 0
            let installed = ((f["installed"] as? [[String: Any]])?.first?["version"] as? String) ?? "?"
            let files = ((f["bottle"] as? [String: Any])?["stable"] as? [String: Any])?["files"] as? [String: Any]
            let url = files?.values.compactMap { ($0 as? [String: Any])?["url"] as? String }.first
            return Entry(installed: installed, current: rev > 0 ? "\(stable)_\(rev)" : stable, bottleURL: url)
        }
        if let c = (root["casks"] as? [[String: Any]])?.first(where: { $0["token"] as? String == name }) {
            return Entry(installed: c["installed"] as? String ?? "?", current: c["version"] as? String ?? "?", cask: true)
        }
        return Entry()
    }
}
