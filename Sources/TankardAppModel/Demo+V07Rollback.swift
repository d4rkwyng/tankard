import Foundation
import TankardCore

// v0.7 demo: restore points over the demo packages, with one upgrade of each
// kind (can roll back, cleaned up, cask, needed by others), a removed and an
// added package. Memory only; nothing runs until Restore is confirmed, and
// then only through the demo's fake brew.

extension Demo {
    /// "5.8.3" → "5.8.2" (a plausible older version for the demo).
    nonisolated static func olderVersion(_ v: String) -> String {
        var parts = v.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices.reversed() {
            let digits = parts[i].prefix { $0.isNumber }
            if let n = Int(digits), n > 0 {
                parts[i] = String(n - 1) + parts[i].dropFirst(digits.count)
                return parts.joined(separator: ".")
            }
        }
        return v + "-old"
    }

    @MainActor public static func seedRestorePoints(_ store: AppStore, now: Date = Date()) {
        guard var report = store.report else { return }
        let pkgs = report.packages
        let leaves = pkgs.filter { p in
            p.kind == .formula && !p.pinned && p.kegOnly != true && !p.installedVersion.hasPrefix("HEAD")
                && Dependents.of(p, among: pkgs).isEmpty
        }
        let rollBack = leaves.first
        let cleaned = leaves.dropFirst().first
        let cask = pkgs.first { $0.kind == .cask }
        let needed = pkgs.first { $0.kind == .formula && !Dependents.of($0, among: pkgs).isEmpty }
        let added = leaves.dropFirst(2).first

        // The kept old keg (as if "Keep the previous version" was on).
        if let r = rollBack, let i = report.packages.firstIndex(where: { $0.id == r.id }) {
            report.packages[i].installedVersions = [olderVersion(r.installedVersion), r.installedVersion]
            store.report = report
        }

        var point = RestorePoint.capture(pkgs, at: now.addingTimeInterval(-2 * 3600), reason: .upgrade,
                                         note: [rollBack, cleaned, cask, needed].compactMap { $0?.name }.joined(separator: ", "))
        for target in [rollBack, cleaned, cask, needed].compactMap({ $0 }) {
            if let i = point.packages.firstIndex(where: { $0.id == target.id }) {
                point.packages[i].version = olderVersion(target.installedVersion)
            }
        }
        if let a = added { point.packages.removeAll { $0.id == a.id } }
        point.packages.append(RestorePointPackage(id: "formula:homebrew/core/wget", name: "wget", fullName: "wget",
                                                  tap: "homebrew/core", kind: .formula, version: "1.25.0",
                                                  pinned: false, requested: true))
        let older = RestorePoint.capture(pkgs, at: now.addingTimeInterval(-3 * 86400), reason: .autoUpdate, note: "git, sqlite")
        let manual = RestorePoint.capture(pkgs, at: now.addingTimeInterval(-9 * 86400), reason: .manual)
        store.restorePoints.seed([point, older, manual])
    }
}
