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

    /// What the demo has changed (shared by both fake runners).
    final class State: Sendable {
        let upgraded = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        /// Installed from Discover: short name → kind and catalog JSON.
        let installed = OSAllocatedUnfairLock<[String: (PackageKind, Data)]>(initialState: [:])
        let removed = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        /// 0.3: reinstalled from a bottle (were source builds).
        let replaced = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        /// 0.3: TANKARD_DEMO_APPMGMT=fail: cask steps fail once with the
        /// App Management block (these already failed and will succeed).
        let appManagementFailed = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        let failAppManagement: Bool
        /// 0.4a: pins and services (Demo+V04A.swift).
        let v04a: V04AState

        init(failAppManagement: Bool = false, pinned: Set<String> = []) {
            self.failAppManagement = failAppManagement
            self.v04a = V04AState(pinned: pinned)
        }

        func info(_ variant: Variant, base: Data) -> Data {
            Demo.addCaskApps(Demo.applyPins(Demo.currentInfo(variant, base: base, upgraded: upgraded.withLock { $0 },
                                            installed: installed.withLock { $0 }, removed: removed.withLock { $0 },
                                            replaced: replaced.withLock { $0 }),
                           pinned: v04a.pinned.withLock { $0 }, variant: variant))
        }
    }

    /// 0.5: the captured fixtures predate Tankard reading cask artifacts;
    /// give each cask the app brew lists for it (as `brew info` prints
    /// `artifacts`), so auto-update's running-app check has something to match.
    static let demoCaskApps: [String: (app: String, bundleID: String)] = [
        "google-chrome": ("Google Chrome.app", "com.google.Chrome"),
        "iterm2": ("iTerm.app", "com.googlecode.iterm2"),
        "lm-studio": ("LM Studio.app", "ai.elementlabs.lmstudio"),
        "tailscale-app": ("Tailscale.app", "io.tailscale.ipn.macsys"),
        "visual-studio-code": ("Visual Studio Code.app", "com.microsoft.VSCode"),
    ]

    static func addCaskApps(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var casks = root["casks"] as? [[String: Any]], !casks.isEmpty else { return data }
        for i in casks.indices where casks[i]["artifacts"] == nil {
            let token = casks[i]["token"] as? String ?? ""
            let name = (casks[i]["name"] as? [String])?.first ?? token
            let app = demoCaskApps[token] ?? (name + ".app", "com.example." + token)
            casks[i]["artifacts"] = [["app": [app.app], "target": "/Applications/" + app.app],
                                     ["uninstall": [["quit": app.bundleID]]]]
        }
        root["casks"] = casks
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// The welcome screen with no brew found, on the given Mac.
    public static func noBrewDependencies(hardware: MacHardware) -> AppStore.Dependencies {
        AppStore.Dependencies(makeClient: { throw BrewClientError.brewNotFound(searched: BrewInstallation.candidates) },
                              streamRunner: ScriptRunner(variant: .intelbrew, state: State(), info: Data(), pace: 1),
                              cache: nil, logURL: nil, hardware: hardware)
    }

    public static func dependencies(_ variant: Variant, pace: Double = 1, hardware: MacHardware? = nil,
                                    failAppManagement: Bool = false, pinned: Set<String> = []) -> AppStore.Dependencies {
        let state = State(failAppManagement: failAppManagement, pinned: pinned)
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
                                // The demo's own user (0.4: services and the revert sheet
                                // show it, never this Mac's).
                                sources: EnvironmentSources(process: variant == .intelbrew ? ["HOME": "/Users/demo", "USER": "demo"]
                                                                                          : ["HOME": "/Users/you", "USER": "you"]),
                                fileExists: { path in variant == .intelbrew && path.hasSuffix("homebrew-core/.git") })
        var deps = AppStore.Dependencies(
            makeClient: { client },
            streamRunner: ScriptRunner(variant: variant, state: state, info: fixtureInfo(variant), pace: pace),
            cache: nil,
            logURL: nil,
            makeCatalog: { client, detection in
                switch variant {
                case .intelbrew:
                    return TapCatalog(client: client, detection: detection, indexer: FixtureTapIndexer())
                case .arm64:
                    return FixtureAPICatalog(platform: client.platform)
                }
            },
            hardware: hardware ?? (variant == .intelbrew ? .intel : .appleSilicon)
        )
        deps.appManagementGate = true
        if variant == .intelbrew {
            // Illustrative build times from a bundled file; nothing is fetched.
            let times = BuildTimeSource(fetch: { (Demo.fixtureData("demo-build-times"), 200) }, cacheURL: nil)
            deps.buildTimes = times
            deps.classifier = CompileClassifier(estimator: times)
        }
        return deps
    }

    /// Intelbrew demo: the tap "listing" is the names and descriptions in
    /// the captured `brew info` fixture (VM, read-only), with no cask tap.
    struct FixtureTapIndexer: TapIndexing {
        func index() -> TapIndex {
            let info = (try? JSONDecoder().decode(BrewInfoJSON.self, from: Demo.fixtureData("discover-intelbrew-info")))
            // The bottle block and depends_on as the real indexer reads them
            // from the formula files (here: from the same brew info capture).
            let entries = (info?.formulae ?? []).map {
                TapIndexEntry(kind: .formula, name: $0.name, tap: $0.tap ?? "homebrew/core", desc: $0.desc, otherNames: $0.aliases ?? [],
                              bottle: $0.bottle["stable"] ?? BrewInfoJSON.BottleSpec(rootURL: nil, files: [:]),
                              dependencies: $0.dependencies ?? [], buildDependencies: $0.buildDependencies ?? [])
            }
            return TapIndex(entries: entries, taps: ["homebrew/core"])
        }
    }

    /// Normal-mode demo: a slice of formulae.brew.sh's formula.json and
    /// cask.json, decoded the same way, with no network.
    struct FixtureAPICatalog: CatalogProviding {
        var platform: BottlePlatform
        var isLocalTaps: Bool { false }

        func load() async throws -> CatalogLoad {
            try await Task.sleep(for: .milliseconds(300))
            var load = try APICatalog.build(formulaJSON: Demo.fixtureData("discover-api-formula"),
                                            caskJSON: Demo.fixtureData("discover-api-cask"),
                                            builder: CatalogBuilder(platform: platform, intelbrewMode: false))
            load.source = "formulae.brew.sh (demo slice) · " + load.source.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
            load.fetchedAt = Date().addingTimeInterval(-180)
            return load
        }

        func details(_ entries: [CatalogEntry]) async -> [CatalogEntry] { entries }
    }

    /// The catalog JSON of one package from the Discover fixtures (for a
    /// demo install).
    static func catalogJSON(_ variant: Variant, kind: PackageKind, name: String) -> Data? {
        let file: String
        switch (variant, kind) {
        case (.intelbrew, .formula): file = "discover-intelbrew-info"
        case (.intelbrew, .cask): return nil
        case (.arm64, .formula): file = "discover-api-formula"
        case (.arm64, .cask): file = "discover-api-cask"
        }
        let root = try? JSONSerialization.jsonObject(with: fixtureData(file))
        let list = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["formulae"] as? [[String: Any]]) ?? []
        let key = kind == .cask ? "token" : "name"
        guard let e = list.first(where: { $0[key] as? String == name }) else { return nil }
        return try? JSONSerialization.data(withJSONObject: e)
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

    static func fixtureText(_ name: String) -> String {
        guard let url = resources.url(forResource: name, withExtension: "txt", subdirectory: "Demo"),
              let d = try? Data(contentsOf: url) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// `brew cleanup -n` as the demo prints it: Intel, illustrative; arm64,
    /// the capture from the arm64 Mac (home directory renamed).
    static func cleanupText(_ variant: Variant) -> String {
        fixtureText(variant == .intelbrew ? "demo-intelbrew-cleanup-n" : "arm64-cleanup-n")
    }

    static func cachePath(_ variant: Variant) -> String {
        variant == .intelbrew ? "/Users/demo/Library/Caches/Homebrew" : "/Users/you/Library/Caches/Homebrew"
    }

    static func fixtureInfo(_ variant: Variant) -> Data {
        fixtureData(variant == .intelbrew ? "sonoma-intelbrew-info" : "arm64-api-info")
    }

    /// The `brew info` JSON as the demo shows it now: fixture, plus the
    /// Intel tweaks, minus whatever was "upgraded" (back to current), plus
    /// demo installs, minus demo uninstalls.
    static func currentInfo(_ variant: Variant, base: Data, upgraded: Set<String>,
                            installed: [String: (PackageKind, Data)] = [:], removed: Set<String> = [],
                            replaced: Set<String> = []) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return base }
        var formulae = root["formulae"] as? [[String: Any]] ?? []
        var extraCasks: [[String: Any]] = []
        for (name, (kind, json)) in installed.sorted(by: { $0.key < $1.key }) {
            guard var e = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { continue }
            if kind == .formula {
                let stable = (e["versions"] as? [String: Any])?["stable"] as? String ?? "1.0"
                let rev = e["revision"] as? Int ?? 0
                e["installed"] = [["version": rev > 0 ? "\(stable)_\(rev)" : stable, "poured_from_bottle": true,
                                   "installed_on_request": true, "time": Date().timeIntervalSince1970,
                                   "runtime_dependencies": (e["dependencies"] as? [String] ?? []).map { ["full_name": $0] }]]
                e["outdated"] = false
                e["pinned"] = false
                e["keg_only"] = false
                formulae.removeAll { $0["name"] as? String == name }
                formulae.append(e)
            } else {
                e["installed"] = e["version"]
                e["installed_time"] = Date().timeIntervalSince1970
                e["outdated"] = false
                extraCasks.append(e)
            }
        }
        formulae.removeAll { removed.contains($0["name"] as? String ?? "") }
        for i in formulae.indices {
            let name = formulae[i]["name"] as? String ?? ""
            let stable = (formulae[i]["versions"] as? [String: Any])?["stable"] as? String ?? ""
            let revision = formulae[i]["revision"] as? Int ?? 0
            let current = revision > 0 ? "\(stable)_\(revision)" : stable
            if replaced.contains(name), var kegs = formulae[i]["installed"] as? [[String: Any]], !kegs.isEmpty {
                kegs[0]["poured_from_bottle"] = true
                formulae[i]["installed"] = kegs
            }
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
        var casks = (root["casks"] as? [[String: Any]] ?? []) + extraCasks
        casks.removeAll { removed.contains($0["token"] as? String ?? "") }
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
                if arguments.first == "--version" {
                    return ProcessResult(exitCode: 0, stdout: Data("Homebrew 7.0.14\n".utf8), stderr: Data())
                }
                if arguments == ["--cache"] {
                    return ProcessResult(exitCode: 0, stdout: Data((Demo.cachePath(variant) + "\n").utf8), stderr: Data())
                }
                if arguments == ["cleanup", "-n"] {
                    try await Task.sleep(for: .milliseconds(500))
                    return ProcessResult(exitCode: 0, stdout: Data(Demo.cleanupText(variant).utf8), stderr: Data())
                }
                if let r = Demo.v04aRead(variant, state: state, arguments: arguments) { return r }
                if let r = try await Demo.insight(variant, state: state, arguments: arguments) { return r }
                guard arguments.first == "info" else { return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data()) }
                if arguments.contains("--installed") {
                    return ProcessResult(exitCode: 0, stdout: state.info(variant, base: info), stderr: Data())
                }
                return Demo.catalogInfo(variant, arguments: arguments)
            }
            if executable.hasSuffix("/du"), let path = arguments.last {
                // `du -sk`: KiB
                let kb = variant == .intelbrew ? 412_388 : 5_196_676
                return ProcessResult(exitCode: 0, stdout: Data("\(kb)\t\(path)\n".utf8), stderr: Data())
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

    /// 0.4: `brew vulns --json`, `brew info --sizes` and `brew outdated
    /// --greedy --cask --json=v2`, captured read-only (the Intel VM and the
    /// arm64 Mac). The Intel demo's older versions (`intelTweaks`) are
    /// carried into the scan's checked versions, as brew would report them;
    /// upgraded casks leave the greedy list. nil: not one of these.
    static func insight(_ variant: Variant, state: State, arguments: [String]) async throws -> ProcessResult? {
        let prefix = variant == .intelbrew ? "sonoma-intelbrew" : "arm64"
        switch arguments {
        case BrewClient.vulnsArguments:
            try await Task.sleep(for: .milliseconds(1200)) // brew asks OSV.dev; never instant
            var data = fixtureData("\(prefix)-vulns")
            let upgraded = state.upgraded.withLock { $0 }
            if variant == .intelbrew, var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               var findings = root["findings"] as? [[String: Any]] {
                for i in findings.indices {
                    let name = findings[i]["formula"] as? String ?? ""
                    if let t = intelTweaks[name], !upgraded.contains(name) { findings[i]["version"] = t.installed }
                }
                root["findings"] = findings
                data = (try? JSONSerialization.data(withJSONObject: root)) ?? data
            }
            // brew exits 1 when it finds anything; warnings go to stderr.
            return ProcessResult(exitCode: 1, stdout: data, stderr: Data(fixtureText("\(prefix)-vulns-stderr").utf8))
        case BrewClient.sizesArguments:
            try await Task.sleep(for: .milliseconds(600))
            return ProcessResult(exitCode: 0, stdout: Data(fixtureText("\(prefix)-sizes").utf8), stderr: Data())
        case BrewClient.greedyOutdatedArguments:
            let upgraded = state.upgraded.withLock { $0 }
            var out = (try? JSONDecoder().decode(BrewOutdatedJSON.self, from: fixtureData("\(prefix)-outdated-greedy"))) ?? BrewOutdatedJSON()
            out.casks.removeAll { upgraded.contains($0.name) }
            let casks = out.casks.map { ["name": $0.name, "installed_versions": $0.installedVersions, "current_version": $0.currentVersion] as [String: Any] }
            let json = (try? JSONSerialization.data(withJSONObject: ["formulae": [Any](), "casks": casks])) ?? Data()
            return ProcessResult(exitCode: 0, stdout: json, stderr: Data())
        default:
            return nil
        }
    }

    /// `brew info --json=v2 --formula|--cask <names>` from the Discover
    /// fixture; like brew, an unknown name fails the whole call.
    static func catalogInfo(_ variant: Variant, arguments: [String]) -> ProcessResult {
        let kind: PackageKind = arguments.contains("--cask") ? .cask : .formula
        var formulae: [Any] = [], casks: [Any] = []
        for q in arguments.dropFirst() where !q.hasPrefix("--") {
            let name = q.split(separator: "/").last.map(String.init) ?? q
            guard let d = catalogJSON(variant, kind: kind, name: name), let e = try? JSONSerialization.jsonObject(with: d) else {
                return ProcessResult(exitCode: 1, stdout: Data(),
                                     stderr: Data("Error: No available \(kind.rawValue) with the name \"\(q)\".\n".utf8))
            }
            if kind == .formula { formulae.append(e) } else { casks.append(e) }
        }
        let out = (try? JSONSerialization.data(withJSONObject: ["formulae": formulae, "casks": casks])) ?? Data()
        return ProcessResult(exitCode: 0, stdout: out, stderr: Data())
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
            if let code = try await Demo.v04aStream(variant, state: state, arguments: arguments, say: say) { return code }
            if arguments.first == "update" {
                try await say("==> Updating Homebrew...\n", 900)
                try await say("Already up-to-date.\n", 50)
                return 0
            }
            let cellar = variant == .intelbrew ? "/usr/local/Cellar" : "/opt/homebrew/Cellar"
            if arguments == ["cleanup"] {
                for line in Demo.cleanupText(variant).split(separator: "\n") {
                    let l = line.replacingOccurrences(of: "Would remove: ", with: "Removing: ")
                        .replacingOccurrences(of: " (", with: "... (")
                        .replacingOccurrences(of: "would free", with: "has freed")
                    try await say(l + "\n", 180)
                }
                return 0
            }
            if arguments.first == "reinstall", let qualified = arguments.last {
                let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
                let entry = Demo.entry(named: name, in: state.info(variant, base: info))
                try await say("==> Fetching downloads for: \(name)\n", 400)
                try await say("==> Downloading \(entry.bottleURL ?? name)\n", 200)
                try await progress(output)
                try await say("==> Reinstalling \(name)\n", 300)
                let tag = variant == .intelbrew ? "sonoma" : "arm64_golden_gate"
                try await say("==> Pouring \(name)--\(entry.current).\(tag).bottle.tar.gz\n", 1000)
                try await say("🍺  \(cellar)/\(name)/\(entry.current): 2,201 files, 39.9MB\n", 400)
                state.replaced.withLock { _ = $0.insert(name) }
                return 0
            }
            if state.failAppManagement, arguments.contains("--cask"), arguments.first == "upgrade" || arguments.first == "uninstall",
               let qualified = arguments.last {
                let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
                let first = state.appManagementFailed.withLock { $0.insert(name).inserted }
                if first {
                    // Shaped like brew 7.0.14's cask/staged.rb message.
                    try await say("==> Upgrading \(name)\n", 400)
                    try await say("Error: Cannot change the ownership of '/Applications/\(name).app' because your terminal does not have App Management permissions.\n", 100)
                    try await say("macOS prevents modifying apps without these permissions, even when using `sudo`.\n", 100)
                    return 1
                }
            }
            if arguments.first == "install", let qualified = arguments.last {
                return try await install(qualified, cask: arguments.contains("--cask"), cellar: cellar, say: say, output: output)
            }
            if arguments.first == "uninstall", let qualified = arguments.last {
                let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
                let entry = Demo.entry(named: name, in: state.info(variant, base: info))
                if entry.cask {
                    try await say("==> Uninstalling Cask \(name)\n", 500)
                    try await say("==> Removing App '/Applications/\(name).app'\n", 600)
                } else {
                    try await say("Uninstalling \(cellar)/\(name)/\(entry.installed)... (412 files, 9.6MB)\n", 900)
                }
                state.removed.withLock { _ = $0.insert(name) }
                state.installed.withLock { _ = $0.removeValue(forKey: name) }
                return 0
            }
            guard arguments.first == "upgrade", let qualified = arguments.last else { return 1 }
            let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
            let data = state.info(variant, base: info)
            let entry = Demo.entry(named: name, in: data)

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

        func install(_ qualified: String, cask: Bool, cellar: String,
                     say: (String, Double) async throws -> Void,
                     output: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
            let name = qualified.split(separator: "/").last.map(String.init) ?? qualified
            let kind: PackageKind = cask ? .cask : .formula
            guard let json = Demo.catalogJSON(variant, kind: kind, name: name),
                  let e = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
                try await say("Error: No available \(kind.rawValue) with the name \"\(qualified)\".\n", 200)
                return 1
            }
            try await say("==> Fetching downloads for: \(name)\n", 400)
            if cask {
                let version = e["version"] as? String ?? "?"
                try await say("==> Downloading \(name) \(version)\n", 200)
                try await progress(output)
                try await say("==> Installing Cask \(name)\n", 500)
                try await say("==> Moving App to '/Applications'\n", 500)
                try await say("🍺  \(name) was successfully installed!\n", 400)
            } else {
                let stable = (e["versions"] as? [String: Any])?["stable"] as? String ?? "?"
                let rev = e["revision"] as? Int ?? 0
                let version = rev > 0 ? "\(stable)_\(rev)" : stable
                let deps = e["dependencies"] as? [String] ?? []
                if !deps.isEmpty {
                    try await say("==> Installing dependencies for \(name): \(deps.joined(separator: ", "))\n", 300)
                }
                let files = ((e["bottle"] as? [String: Any])?["stable"] as? [String: Any])?["files"] as? [String: Any]
                let url = files?.values.compactMap { ($0 as? [String: Any])?["url"] as? String }.first ?? "\(name)-\(version).tar.gz"
                try await say("==> Downloading \(url)\n", 200)
                try await progress(output)
                try await say("==> Installing \(name)\n", 300)
                let tag = variant == .intelbrew ? "sonoma" : "arm64_golden_gate"
                try await say("==> Pouring \(name)--\(version).\(tag).bottle.tar.gz\n", 1000)
                try await say("🍺  \(cellar)/\(name)/\(version): 312 files, 6.1MB\n", 400)
            }
            state.removed.withLock { _ = $0.remove(name) }
            state.installed.withLock { $0[name] = (kind, json) }
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
