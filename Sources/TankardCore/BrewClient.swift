import Foundation

public enum BrewClientError: Error, CustomStringConvertible {
    case brewNotFound(searched: [String])
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case badJSON(command: String, underlying: String)

    public var description: String {
        switch self {
        case .brewNotFound(let searched):
            let list = searched.joined(separator: ", ")
            return String(localized: "brew not found (looked in \(list)). Set TANKARD_BREW or pass --brew.")
        case .commandFailed(let command, let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
            let exit = Int(code)
            return tail.isEmpty
                ? String(localized: "\(command) exited \(exit)")
                : String(localized: "\(command) exited \(exit):\n\(tail)")
        case .badJSON(let command, let underlying):
            return String(localized: "\(command) printed JSON Tankard couldn't read: \(underlying)")
        }
    }
}

/// Talks to brew. Read-only in step 1: it never installs, upgrades or
/// updates anything (HOMEBREW_NO_AUTO_UPDATE=1 is always set).
///
/// Shaped for the app: Sendable, async, an injectable command runner, and
/// one `status()` call returning a Codable `StatusReport`.
public struct BrewClient: Sendable {
    public var installation: BrewInstallation
    public var platform: BottlePlatform
    public var runner: CommandRunning
    /// Defaults to EnvironmentSources.load for the installation's prefix.
    public var sources: EnvironmentSources
    public var gitPath: String
    /// Checks whether a path exists (the core tap's .git). Injectable so a
    /// fake installation (tests, demo mode) can claim a tap checkout.
    public var fileExists: @Sendable (String) -> Bool
    /// 0.8.4: a cask's install folder's modification time, from
    /// `<prefix>/Caskroom` (StatusClassifier.folderTime). Demo mode sets
    /// nil: its dates come from the fixtures only, never this Mac's disk.
    public var caskFolderTime: (@Sendable (_ token: String, _ version: String) -> Date?)?
    /// 0.8.6 (M1): installed packages brew's JSON leaves out (it can't
    /// load them), from the Cellar and Caskroom (`UnreadableKegs.find`).
    /// Demo mode sets nil: it never reads this Mac's disk.
    public var unreadableScan: (@Sendable (BrewInfoJSON) -> [Package])?

    public init(installation: BrewInstallation,
                platform: BottlePlatform? = nil,
                runner: CommandRunning = ProcessRunner(),
                sources: EnvironmentSources? = nil,
                gitPath: String = "/usr/bin/git",
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.installation = installation
        self.platform = platform ?? BottlePlatform.current(prefix: installation.prefix)
        self.runner = runner
        self.sources = sources ?? EnvironmentSources.load(prefix: installation.prefix)
        self.gitPath = gitPath
        self.fileExists = fileExists
        let caskroom = installation.prefix + "/Caskroom"
        self.caskFolderTime = { CaskInstallTime.folderTime(caskroom: caskroom, token: $0, version: $1) }
        let cellar = self.platform.cellar
        self.unreadableScan = { UnreadableKegs.find(cellar: cellar, caskroom: caskroom, info: $0) }
    }

    /// Locates brew (override path, else the standard locations).
    public static func locate(override: String? = nil) throws -> BrewClient {
        guard let installation = BrewInstallation.locate(override: override) else {
            let searched = override.map { [$0] } ?? BrewInstallation.candidates
            throw BrewClientError.brewNotFound(searched: searched)
        }
        return BrewClient(installation: installation)
    }

    // MARK: git probes (no brew start-up cost)

    private var gitEnv: [String: String] {
        var env = BrewEnvironment.build(installation: installation, sources: EnvironmentSources(process: sources.process),
                                        intelbrew: IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:]),
                                        readOnly: true)
        env["GIT_TERMINAL_PROMPT"] = "0"
        // 0.8.4: `forkStatus(checkRemote:)` runs `git ls-remote`, which needs
        // the proxy a shell profile sets too (git reads http_proxy and co.).
        env.merge(EnvironmentPolicy.passThrough(sources).filter { ProxySettings.passedByBrew.contains($0.key) }) { $1 }
        return env
    }

    func git(_ repo: String, _ args: String...) async -> String? {
        guard let r = try? await runner.run(gitPath, ["-C", repo] + args, environment: gitEnv), r.exitCode == 0 else {
            return nil
        }
        let s = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// homebrew/core's configured origin URL, or nil in API mode.
    public func coreOrigin() async -> String? {
        guard fileExists(installation.coreTapPath + "/.git") else { return nil }
        return await git(installation.coreTapPath, "config", "--get", "remote.origin.url")
    }

    public func detectIntelbrew() async -> IntelbrewDetection {
        IntelbrewDetector.detect(coreOrigin: await coreOrigin(), sources: sources)
    }

    /// HOMEBREW_CELLAR, by brew.sh's own rule: the repository's Cellar when
    /// one exists there, otherwise the prefix's.
    public var cellar: String {
        let inRepository = installation.repository + "/Cellar"
        return fileExists(inRepository) ? inRepository : installation.prefix + "/Cellar"
    }

    /// The keg directory of `name` at `version` (`<Cellar>/xz/5.8.2`).
    public func kegPath(_ name: String, _ version: String) -> String {
        "\(cellar)/\(name)/\(version)"
    }

    /// 0.8: when `brew update` last fetched, from anywhere (Tankard, Terminal,
    /// brew's own auto-update): the mtime of the brew repository's
    /// .git/FETCH_HEAD, the file brew's auto-update throttle checks
    /// (Library/Homebrew/utils/auto-update.sh). nil when there is none.
    public func lastFetch() -> Date? {
        let path = installation.repository + "/.git/FETCH_HEAD"
        guard fileExists(path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The environment brew is run with for a given detection.
    public func environment(for detection: IntelbrewDetection, readOnly: Bool = true) -> [String: String] {
        BrewEnvironment.build(installation: installation, sources: sources, intelbrew: detection, readOnly: readOnly)
    }

    static func newestReleaseTag(_ tags: some Sequence<String>) -> String? {
        tags.filter { $0.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil }
            .max { BrewVersion($0) < BrewVersion($1) }
    }

    /// Fork status from the git checkouts. `checkRemote` asks the brew
    /// remote for its tags (`git ls-remote`, a network call) instead of
    /// trusting the local tag list.
    public func forkStatus(checkRemote: Bool = false) async -> ForkStatus {
        let core = installation.coreTapPath
        let repo = installation.repository
        let hasCore = fileExists(core + "/.git")

        async let coreOrigin = hasCore ? git(core, "config", "--get", "remote.origin.url") : nil
        async let coreBranch = hasCore ? git(core, "rev-parse", "--abbrev-ref", "HEAD") : nil
        async let brewOrigin = git(repo, "config", "--get", "remote.origin.url")
        async let brewVersion = git(repo, "describe", "--tags")
        async let brewTag = git(repo, "describe", "--tags", "--exact-match", "HEAD")
        async let localTags = git(repo, "tag", "--list")

        var status = ForkStatus(brewRepository: repo)
        status.coreTapPath = hasCore ? core : nil
        status.coreOrigin = await coreOrigin
        status.coreBranch = await coreBranch
        status.coreIsFork = Intelbrew.isCoreFork(status.coreOrigin)
        status.brewOrigin = await brewOrigin
        status.brewIsFork = Intelbrew.isBrewFork(status.brewOrigin)
        status.brewVersion = await brewVersion
        status.brewTag = await brewTag

        if checkRemote, let origin = status.brewOrigin,
           let out = await git(repo, "ls-remote", "--tags", origin) {
            let names = out.split(separator: "\n").compactMap { line -> String? in
                guard let ref = line.split(separator: "\t").last else { return nil }
                return ref.replacingOccurrences(of: "refs/tags/", with: "").replacingOccurrences(of: "^{}", with: "")
            }
            status.brewNewestTag = Self.newestReleaseTag(names)
            status.brewNewestTagSource = "remote"
        } else if let tags = await localTags {
            status.brewNewestTag = Self.newestReleaseTag(tags.split(separator: "\n").map(String.init))
            status.brewNewestTagSource = "local"
        }
        if let tag = status.brewTag, let newest = status.brewNewestTag {
            status.brewAtNewestTag = tag == newest
        }
        return status
    }

    // MARK: brew JSON

    func brewJSON<T: Decodable>(_ type: T.Type, _ args: [String], env: [String: String]) async throws -> (T, Double) {
        let command = "brew " + args.joined(separator: " ")
        let result = try await runner.run(installation.brewPath, args, environment: env)
        // brew can exit non-zero yet still print valid JSON (e.g. one
        // unreadable formula); prefer the data when it decodes.
        do {
            let value = try JSONDecoder().decode(T.self, from: result.stdout)
            return (value, result.seconds)
        } catch {
            if result.exitCode != 0 {
                throw BrewClientError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderrString)
            }
            throw BrewClientError.badJSON(command: command, underlying: String(describing: error))
        }
    }

    public func installedInfo(env: [String: String]) async throws -> BrewInfoJSON {
        try await brewJSON(BrewInfoJSON.self, ["info", "--json=v2", "--installed"], env: env).0
    }

    /// `brew info --json=v2 --formula|--cask <names…>`: details for
    /// packages that may not be installed (Discover in Intelbrew mode).
    public func info(_ names: [String], kind: PackageKind, env: [String: String]) async throws -> BrewInfoJSON {
        try await brewJSON(BrewInfoJSON.self, Self.infoArguments(names, kind: kind), env: env).0
    }

    public static func infoArguments(_ names: [String], kind: PackageKind) -> [String] {
        ["info", "--json=v2", kind == .cask ? "--cask" : "--formula"] + names
    }

    public func outdated(env: [String: String]) async throws -> BrewOutdatedJSON {
        try await brewJSON(BrewOutdatedJSON.self, ["outdated", "--json=v2"], env: env).0
    }

    /// The full status report. Detection first (it decides brew's
    /// environment), then `brew info` and the git probes concurrently.
    /// Upgrade-available is brew's own `outdated` flag from `brew info`
    /// (identical to `brew outdated --json=v2` on real data, one brew launch
    /// cheaper); Tankard never decides "outdated" by comparing versions.
    ///
    /// 0.8: `detection`, when the caller already has it (the app detects
    /// first so it can start `brew info --sizes` beside this read).
    public func status(checkRemote: Bool = false, detection known: IntelbrewDetection? = nil) async throws -> StatusReport {
        let clock = ContinuousClock()
        let t0 = clock.now
        func ms(_ d: Duration) -> Int {
            let c = d.components
            return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
        }

        let detection: IntelbrewDetection
        if let known { detection = known } else { detection = await detectIntelbrew() }
        let env = environment(for: detection)
        let tDetect = clock.now

        async let infoTask = timedThrowing { try await brewJSON(BrewInfoJSON.self, ["info", "--json=v2", "--installed"], env: env) }
        async let forkTask = timed { await forkStatus(checkRemote: checkRemote) }

        var warnings: [String] = []
        let (infoResult, infoTime) = await infoTask
        let info = try infoResult.get().0
        let (fork, gitTime) = await forkTask

        let classifier = StatusClassifier(platform: platform, intelbrewMode: detection.detected,
                                          folderTime: caskFolderTime)
        var packages = classifier.classify(info: info)
        // 0.8.6 (M1): what brew can't read, with brew's reason for the first few.
        if let scan = unreadableScan {
            packages += await withUnreadableReasons(scan(info), env: env)
        }

        if detection.detected && !fork.coreIsFork {
            warnings.append(fork.coreTapPath == nil
                ? String(localized: "Intelbrew settings found but there is no local homebrew/core tap (API mode): run `brew tap homebrew/core` and `brew update`.")
                : String(localized: "Intelbrew settings found but homebrew/core's origin is \(fork.coreOrigin ?? "unset"): run `brew update` to switch it."))
        }

        let host = HostInfo(brewPath: installation.brewPath, prefix: installation.prefix,
                            repository: installation.repository, platform: platform,
                            bottleTag: platform.bottleTag)
        return StatusReport(
            generatedAt: Date(), host: host, intelbrew: detection, fork: fork, packages: packages,
            timingsMs: [
                "detect": ms(tDetect - t0),
                "info": ms(infoTime),
                "git": ms(gitTime),
                "total": ms(clock.now - t0),
            ],
            warnings: warnings
        )
    }
}

extension BrewClient {
    /// Asks brew why it can't read each package (`brew info --json=v2`
    /// on the name, which fails with the reason), at most `limit` of them.
    func withUnreadableReasons(_ rows: [Package], env: [String: String], limit: Int = 5) async -> [Package] {
        guard !rows.isEmpty else { return rows }
        var out: [Package?] = rows
        await withTaskGroup(of: (Int, ProcessResult?).self) { group in
            for (i, p) in rows.enumerated().prefix(limit) {
                group.addTask {
                    let args = ["info", "--json=v2", p.kind == .cask ? "--cask" : "--formula", p.name]
                    return (i, try? await runner.run(installation.brewPath, args, environment: env))
                }
            }
            for await (i, r) in group {
                guard let r else { continue }
                // brew read it after all (a folder brew's JSON names some
                // other way): not Tankard's to second-guess.
                if r.exitCode == 0 { out[i] = nil; continue }
                if let why = UnreadableKegs.reason(stderr: r.stderrString) { out[i]?.unreadable = why }
            }
        }
        return out.compactMap { $0 }
    }
}

private func timedThrowing<T: Sendable>(_ body: @Sendable () async throws -> T) async -> (Result<T, Error>, Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let v = try await body()
        return (.success(v), clock.now - start)
    } catch {
        return (.failure(error), clock.now - start)
    }
}

private func timed<T: Sendable>(_ body: @Sendable () async -> T) async -> (T, Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let v = await body()
    return (v, clock.now - start)
}
