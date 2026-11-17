import Foundation

// v0.4: the extra reads behind the vulnerability scan, the Size column and
// "Include self-updating apps". All read-only; none goes through the
// command queue.

public enum InsightError: Error, CustomStringConvertible, Equatable {
    /// This brew has no such command (older than brew 7 for `vulns`).
    case unsupported(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return s
        }
    }
}

extension BrewClient {
    /// `brew vulns --json`: every installed formula, checked against
    /// OSV.dev by brew (brew makes the network request, not Tankard).
    public static let vulnsArguments = ["vulns", "--json"]
    /// `brew info --sizes`: every installed formula and cask.
    public static let sizesArguments = ["info", "--sizes"]
    /// `brew outdated --greedy --cask --json=v2`: casks, including ones
    /// that update themselves (`auto_updates true`) and `version :latest`.
    public static let greedyOutdatedArguments = ["outdated", "--greedy", "--cask", "--json=v2"]

    /// Runs `brew vulns --json` and reads stdout only. brew exits 1 whenever
    /// it finds anything or skips an untrusted tap, so the exit code alone
    /// means little: JSON that decodes wins.
    public func vulnerabilityScan(env: [String: String], now: Date = Date()) async throws -> VulnerabilityScan {
        let command = "brew " + Self.vulnsArguments.joined(separator: " ")
        let r = try await runner.run(installation.brewPath, Self.vulnsArguments, environment: env)
        if let json = try? BrewVulnsJSON.decode(stdout: r.stdout) {
            return VulnerabilityScan(json: json, scannedAt: now, stderr: r.stderrString)
        }
        let err = r.stderrString
        if err.contains("Unknown command") || err.contains("Invalid usage") && err.contains("vulns") {
            throw InsightError.unsupported("This brew has no `brew vulns` (it is new in Homebrew 7). Run `brew update` to get it.")
        }
        if r.exitCode != 0 {
            throw BrewClientError.commandFailed(command: command, exitCode: r.exitCode, stderr: err)
        }
        throw BrewClientError.badJSON(command: command, underlying: "no JSON on stdout")
    }

    /// Runs `brew info --sizes` and parses its table.
    public func diskSizes(env: [String: String], now: Date = Date()) async throws -> DiskSizes {
        let r = try await runner.run(installation.brewPath, Self.sizesArguments, environment: env)
        let sizes = DiskSizes.parse(r.stdoutString, measuredAt: now)
        if r.exitCode != 0 && sizes.formulae.isEmpty && sizes.casks.isEmpty {
            throw BrewClientError.commandFailed(command: "brew info --sizes", exitCode: r.exitCode, stderr: r.stderrString)
        }
        return sizes
    }

    /// Casks `brew outdated --greedy` reports.
    public func greedyOutdatedCasks(env: [String: String]) async throws -> BrewOutdatedJSON {
        try await brewJSON(BrewOutdatedJSON.self, Self.greedyOutdatedArguments, env: env).0
    }
}

/// "Include self-updating apps": casks only `--greedy` calls outdated.
public enum SelfUpdatingCasks {
    /// Marks casks in `greedy` that brew's normal `outdated` flag skipped as
    /// upgradable (`selfUpdatingUpgrade`), with the version brew would
    /// upgrade to. Names in `brew outdated` are cask tokens.
    public static func mark(_ report: StatusReport, greedy: BrewOutdatedJSON) -> StatusReport {
        let byToken = Dictionary(greedy.casks.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var r = report
        // A cask whose version is past the tap's (`newer`) is left alone:
        // that is not an upgrade.
        for i in r.packages.indices where r.packages[i].kind == .cask && !r.packages[i].upgradeAvailable
            && r.packages[i].status != .newer {
            let p = r.packages[i]
            guard let e = byToken[p.name] ?? byToken[p.fullName] else { continue }
            r.packages[i].upgradeAvailable = true
            r.packages[i].selfUpdatingUpgrade = true
            r.packages[i].currentVersion = e.currentVersion
        }
        r.summary = StatusSummary(packages: r.packages)
        return r
    }

    /// Undoes `mark` (the setting was turned off): back to brew's own flag.
    public static func unmark(_ report: StatusReport) -> StatusReport {
        guard report.packages.contains(where: { $0.selfUpdatingUpgrade == true }) else { return report }
        var r = report
        for i in r.packages.indices where r.packages[i].selfUpdatingUpgrade == true {
            r.packages[i].upgradeAvailable = false
            r.packages[i].selfUpdatingUpgrade = nil
        }
        r.summary = StatusSummary(packages: r.packages)
        return r
    }
}
