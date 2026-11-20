import Foundation
import TankardCore

// 0.8.3: one `brew fetch` before a multi-package upgrade or install.
//
// brew 7's `brew fetch` puts every named package on its download queue
// (cmd/fetch.rb, download_queue.rb), which downloads them in parallel,
// HOMEBREW_DOWNLOAD_CONCURRENCY at a time (default `auto`: twice the CPU
// cores; `1`: one at a time). It does so without a terminal too: checked on
// a Mac mini, 4 bottles from a pipe ran as 4 curls at once. The upgrades
// that follow, one at a time as before, then pour from brew's cache.
//
// What goes into the fetch:
//   - formulae whose upgrade pours a bottle. One that builds from source
//     would fetch its source (and, for a formula from the API, its Ruby
//     file) instead; its own step does that, as before;
//   - casks, except `version :latest` ones (no checksum: brew downloads
//     them again on upgrade anyway);
//   - not pinned formulae (brew won't upgrade them).
// `--formula` and `--cask` can't be combined (cmd/fetch.rb's `conflicts`),
// so it is one `brew fetch` per kind, and only for a kind with at least two
// packages: one alone gains nothing from a queue of its own.
//
// Already downloaded files cost nothing (brew checks the cache and prints
// the ✔︎ line at once). A failed download (a 404) fails only that package:
// brew downloads the others, prints `✘ Cask x` and the error, and exits 1.
// That package's own step then tries again and fails with brew's own error.

/// One `brew fetch` command and the packages it downloads.
public struct PrefetchStep: Sendable, Equatable {
    public var command: QueuedCommand
    public var targets: [Package]

    public init(command: QueuedCommand, targets: [Package]) {
        self.command = command
        self.targets = targets
    }
}

public enum Prefetch {
    /// brew's own setting for parallel downloads; Tankard passes the user's
    /// value through (a shell profile's export doesn't reach brew otherwise).
    public static let concurrencyKey = "HOMEBREW_DOWNLOAD_CONCURRENCY"

    /// The sheet runs that prefetch: upgrades and installs (Upgrade All, a
    /// selection, a Brewfile's missing packages).
    public static func applies(_ action: SessionAction) -> Bool {
        action == .upgrade || action == .install
    }

    /// Whether `p`'s download belongs in the fetch.
    public static func fetchable(_ p: Package) -> Bool {
        if p.id.hasPrefix("command:") { return false }
        switch p.kind {
        case .formula: return p.upgradeHasBottle == true && !p.pinned
        case .cask: return p.currentVersion != "latest"
        }
    }

    /// `["fetch", "--formula", "homebrew/core/xz", ...]` per kind with at
    /// least two packages to download, formulae first; empty when none has.
    public static func plan(_ action: SessionAction, _ packages: [Package]) -> [(arguments: [String], targets: [Package])] {
        guard applies(action) else { return [] }
        var out: [(arguments: [String], targets: [Package])] = []
        for kind in [PackageKind.formula, .cask] {
            var seen = Set<String>()
            let targets = packages.filter { $0.kind == kind && fetchable($0) && seen.insert($0.qualifiedName).inserted }
            guard targets.count >= 2 else { continue }
            out.append((arguments(kind, targets), targets))
        }
        return out
    }

    public static func arguments(_ kind: PackageKind, _ targets: [Package]) -> [String] {
        ["fetch", kind == .cask ? "--cask" : "--formula"] + BrewOperand.list(targets.map(\.qualifiedName))
    }

    /// The user's HOMEBREW_DOWNLOAD_CONCURRENCY (brew.env, Tankard's own
    /// environment or a shell profile), to pass on; empty when not set.
    public static func environment(_ sources: EnvironmentSources?) -> [String: String] {
        guard let s = sources?.effective(concurrencyKey), !s.value.isEmpty else { return [:] }
        return [concurrencyKey: s.value]
    }

    /// The steps for a session: `make` turns arguments into the command
    /// (environment, display).
    public static func steps(_ action: SessionAction, _ packages: [Package],
                             make: ([String]) -> QueuedCommand) -> [PrefetchStep] {
        plan(action, packages).map { PrefetchStep(command: make($0.arguments), targets: $0.targets) }
    }
}

/// Counts the packages a `brew fetch` has finished, from its output.
///
/// With parallel downloads and no terminal, brew prints one line per file
/// when it's done (download_queue.rb, on stderr): "✔︎ Bottle hello (2.12.3)",
/// "✔︎ Cask rectangle (2.0.4)", "✔︎ Formula x (1.0)" (a source download),
/// or "✘ Cask x (1.0)" when it failed, and a "Bottle Manifest" line before
/// each bottle. Already downloaded files print the same line at once.
/// With HOMEBREW_DOWNLOAD_CONCURRENCY=1 there are no such lines: each new
/// download ends with "Downloaded to: <path>" (cached ones print nothing).
public enum FetchOutput {
    public static func finished(_ lines: some Sequence<String>) -> Int {
        var n = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("✔︎ ") || line.hasPrefix("✘ ") || line.hasPrefix("✔ ") {
                let rest = line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("Bottle Manifest ") { continue }
                if rest.hasPrefix("Bottle ") || rest.hasPrefix("Cask ") || rest.hasPrefix("Formula ") { n += 1 }
            } else if line.hasPrefix("Downloaded to: "), !line.hasSuffix(".bottle_manifest.json") {
                n += 1
            }
        }
        return n
    }
}
