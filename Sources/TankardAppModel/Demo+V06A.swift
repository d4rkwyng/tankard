import Foundation
import TankardCore

// v0.6 (part A) demo: a deprecated package with a replacement, the
// Health sheet's doctor/config/missing, the autoremove dry run and run,
// and a seeded History. Nothing is spawned.

extension Demo {
    /// Intel demo: json-c is shown deprecated with a replacement (illustrative,
    /// not Homebrew's real data); the arm64 demo marks icu4c@78 as brew
    /// 7.0.14 really does, if that fixture has it.
    nonisolated(unsafe) static let retired: [String: [String: Any]] = [
        "json-c": ["deprecated": true, "deprecation_date": "2026-09-01", "deprecation_reason": "repo_archived",
                   "deprecation_replacement_formula": "cjson"],
        "icu4c@78": ["deprecated": true, "deprecation_date": "2026-10-30", "deprecation_reason": "versioned_formula",
                     "disable_date": "2027-10-30"],
    ]

    static func markRetired(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var formulae = root["formulae"] as? [[String: Any]] else { return data }
        for i in formulae.indices {
            if let extra = retired[formulae[i]["name"] as? String ?? ""] { formulae[i].merge(extra) { $1 } }
        }
        root["formulae"] = formulae
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// `brew doctor`, `config`, `missing` and `autoremove --dry-run`.
    static func v06aRead(_ variant: Variant, state: State, arguments: [String]) async throws -> ProcessResult? {
        func text(_ s: String, code: Int32 = 0, stderr: Bool = false) -> ProcessResult {
            stderr ? ProcessResult(exitCode: code, stdout: Data(), stderr: Data(s.utf8))
                   : ProcessResult(exitCode: code, stdout: Data(s.utf8), stderr: Data())
        }
        switch arguments {
        case HealthStore.doctorArguments:
            try await Task.sleep(for: .milliseconds(900))
            return text(fixtureText(variant == .intelbrew ? "demo-doctor" : "arm64-doctor"), code: 1, stderr: true)
        case HealthStore.configArguments:
            return text(fixtureText("arm64-config"))
        case HealthStore.missingArguments:
            return text("")
        case AutoremovePlan.dryRunArguments:
            try await Task.sleep(for: .milliseconds(500))
            if state.autoremoved.withLock({ $0 }) { return text("") }
            return text(fixtureText("demo-autoremove-n"))
        default:
            return nil
        }
    }

    /// `brew autoremove`, scripted.
    static func v06aStream(_ variant: Variant, state: State, arguments: [String],
                           say: (String, Double) async throws -> Void) async throws -> Int32? {
        // 0.8.5: Keep: `brew tab --installed-on-request --formula …`.
        if arguments.starts(with: AutoremovePlan.keepArguments([])) {
            let names = Array(arguments.dropFirst(AutoremovePlan.keepArguments([]).count))
            for n in names { try await say("==> \(n) is now marked as installed on request.\n", 100) }
            state.autoremoveKept.withLock { $0.formUnion(names) }
            return 0
        }
        guard arguments == AutoremovePlan.runArguments else { return nil }
        var plan = AutoremovePlan.parse(fixtureText("demo-autoremove-n"))
        let kept = state.autoremoveKept.withLock { $0 }
        plan.formulae.removeAll { kept.contains($0) }
        try await say("==> Autoremoving \(plan.formulae.count) unneeded formulae:\n", 300)
        for f in plan.formulae { try await say(f + "\n", 100) }
        for f in plan.formulae { try await say("Uninstalling \(f)... (64 files, 2.1MB)\n", 500) }
        state.autoremoved.withLock { $0 = true }
        return 0
    }

    /// History as a few days of use would leave it.
    @MainActor public static func seedHistory(_ log: HistoryLog, now: Date = Date()) {
        func e(_ minutesAgo: Double, _ args: [String], _ outcome: HistoryEntry.Outcome, _ seconds: Double,
               code: Int32? = 0, origin: HistoryEntry.Origin = .user, failure: BrewFailureKind? = nil, tail: [String] = []) -> HistoryEntry {
            HistoryEntry(startedAt: now.addingTimeInterval(-minutesAgo * 60), duration: seconds,
                         command: BrewCommands.display(args), arguments: args, outcome: outcome, exitCode: code,
                         origin: origin, failure: failure?.rawValue, outputTail: tail)
        }
        log.seed([
            e(4, ["upgrade", "--formula", "homebrew/core/xz"], .succeeded, 6.2),
            e(5, ["upgrade", "--formula", "homebrew/core/sqlite"], .failed, 1.1, code: 1, failure: .locked,
              tail: ["Error: Another `brew upgrade` process is already running.",
                     "Please wait for it to finish or terminate it to continue."]),
            e(31, ["pin", "--formula", "homebrew/core/python@3.15"], .succeeded, 0.8),
            e(62, ["services", "restart", "postgresql@18"], .succeeded, 2.4),
            e(180, ["install", "--formula", "homebrew/core/jq"], .failed, 31, code: 1, failure: .network,
              tail: ["==> Downloading https://ghcr.io/v2/homebrew/core/jq/blobs/sha256:…",
                     "curl: (6) Could not resolve host: ghcr.io", "Error: jq: Failed to download resource \"jq\""]),
            e(600, ["update"], .succeeded, 4.9, origin: .autoUpdate),
            e(601, ["upgrade", "--formula", "homebrew/core/openssl@4"], .succeeded, 48, origin: .autoUpdate),
            e(1500, ["cleanup"], .succeeded, 12),
            e(2900, ["uninstall", "--cask", "homebrew/cask/lm-studio"], .succeeded, 3.3),
        ])
    }
}
