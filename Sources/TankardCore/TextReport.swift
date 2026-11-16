import Foundation

/// Package subsets for `tankard status --filter`.
public enum StatusFilter: String, CaseIterable, Sendable {
    case upgrades, source, newer, nobottle, casks

    public func includes(_ p: Package) -> Bool {
        switch self {
        case .upgrades: return p.upgradeAvailable
        case .source: return p.status == .source
        case .newer: return p.status == .newer
        case .nobottle: return p.status == .noBottle
        case .casks: return p.kind == .cask
        }
    }
}

/// The human-readable form of a StatusReport: table, summary line, and the
/// Intelbrew fork footer.
public enum TextReport {
    static let maxVersionWidth = 20

    static func clip(_ s: String, _ width: Int) -> String {
        s.count <= width ? s : String(s.prefix(width - 1)) + "…"
    }

    public static func notes(for p: Package) -> String {
        var n: [String] = []
        if p.kind == .formula && !p.requested { n.append("dep") }
        if p.pinned { n.append("pinned") }
        if p.upgradeAvailable {
            switch (p.kind, p.upgradeHasBottle) {
            case (.cask, _): n.append("upgrade")
            case (_, true): n.append("upgrade (bottle)")
            default: n.append("upgrade (compiles)")
            }
        }
        if p.autoUpdates == true { n.append("auto-updates") }
        if p.deprecated { n.append("deprecated") }
        if p.disabled { n.append("disabled") }
        return n.joined(separator: ", ")
    }

    public static func table(_ packages: [Package]) -> String {
        let header = ["NAME", "INSTALLED", "CURRENT", "STATUS", "NOTES"]
        let rows = packages.map { p in
            [p.name + (p.kind == .cask ? " (cask)" : ""),
             clip(p.installedVersion, maxVersionWidth),
             clip(p.currentVersion ?? "-", maxVersionWidth),
             p.statusLabel,
             notes(for: p)]
        }
        var widths = header.map(\.count)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in
                i == cells.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    public static func forkFooter(_ report: StatusReport) -> String {
        let f = report.fork
        var lines = ["Intelbrew mode (\(report.intelbrew.reasons.joined(separator: "; ")))"]
        if let origin = f.coreOrigin {
            let branch = f.coreBranch.map { ", branch \($0)" } ?? ""
            lines.append("  core: \(origin)\(branch) — \(f.coreIsFork ? "Intelbrew fork" : "NOT the Intelbrew fork")")
        } else {
            lines.append("  core: no local homebrew/core tap (API mode) — not using the Intelbrew fork")
        }
        let origin = f.brewOrigin ?? "unknown origin"
        let at = f.brewVersion.map { " at \($0)" } ?? ""
        var brew = "  brew: \(origin)\(at) — "
        if !f.brewIsFork {
            brew += "NOT the d4rkwyng/brew fork"
        } else if let newest = f.brewNewestTag, let atNewest = f.brewAtNewestTag {
            let src = f.brewNewestTagSource == "remote" ? "remote" : "local"
            brew += atNewest ? "fork, on its newest tag (\(newest), \(src))" : "fork, NOT on its newest tag \(newest) (\(src))"
        } else if let newest = f.brewNewestTag {
            brew += "fork, not on a release tag (newest \(newest))"
        } else {
            brew += "fork (no release tags found)"
        }
        lines.append(brew)
        return lines.joined(separator: "\n")
    }

    public static func render(_ report: StatusReport, filter: StatusFilter?, showTimings: Bool = false) -> String {
        let shown = filter.map { f in report.packages.filter(f.includes) } ?? report.packages
        var out: [String] = []
        if shown.isEmpty {
            out.append(filter.map { "No packages match --filter \($0.rawValue)." } ?? "No packages installed.")
        } else {
            out.append(table(shown))
        }
        out.append("")
        out.append(report.summary.line)
        if report.intelbrew.detected {
            out.append("")
            out.append(forkFooter(report))
        }
        for w in report.warnings { out.append("warning: \(w)") }
        if showTimings {
            let t = report.timingsMs
            out.append("timings (ms): " + ["detect", "info", "git", "total"]
                .compactMap { k in t[k].map { "\(k) \($0)" } }.joined(separator: ", "))
        }
        return out.joined(separator: "\n")
    }
}
