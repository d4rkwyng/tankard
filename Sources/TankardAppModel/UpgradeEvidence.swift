import Foundation
import TankardCore

/// 0.8.6 (HK-47 review): what a fresh read says about a package after an
/// upgrade step brew exited non-zero for.
public struct InstalledNow: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The newest installed version (formulae: the newest keg).
    public var version: String
    /// Formulae: the keg linked into the prefix (`linked_keg`), nil when
    /// none is. Casks have no link: their version.
    public var linkedVersion: String?
    /// Formulae: keg-only (brew doesn't link it).
    public var kegOnly: Bool

    public init(version: String, linkedVersion: String?, kegOnly: Bool) {
        self.version = version
        self.linkedVersion = linkedVersion
        self.kegOnly = kegOnly
    }

    /// Installed and linked at that version.
    public init(stringLiteral value: String) {
        self.init(version: value, linkedVersion: value, kegOnly: false)
    }
}

/// 0.8.6 (HK-47 review): reads a failed upgrade step's output. brew can
/// pour a package's new keg and then fail on that same package (`brew link`
/// over a conflicting file, or its post-install step) and exit 1; a newer
/// keg alone doesn't show that the upgrade worked.
enum UpgradeEvidence {
    /// The packages brew's link or post-install step failed for, in the
    /// order they failed; nil for a failure the output doesn't tie to a
    /// package. A failure belongs to the package of the last
    /// `==> Pouring <name>--…`, `==> Installing …` or `==> Upgrading <name>`
    /// line before it, or to the one brew's "try again" hint names
    /// (`brew link <name>`, `brew postinstall <full name>`).
    static func linkOrPostInstallFailures(_ lines: [String]) -> [String?] {
        var current: String?
        var failures: [String?] = []
        var lastFailureLine: Int?
        for (n, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let name = section(line) {
                current = name
                lastFailureLine = nil
            } else if line.contains("The `brew link` step did not complete successfully")
                        || line.contains("An unexpected error occurred during the `brew link` step")
                        || line.contains("The post-install step did not complete successfully") {
                failures.append(current)
                lastFailureLine = n
            } else if let at = lastFailureLine, n - at <= 30, let name = hintName(line) {
                failures[failures.count - 1] = name
                lastFailureLine = nil
            }
        }
        return failures
    }

    /// The package a `==>` line starts on, if it starts one.
    static func section(_ line: String) -> String? {
        guard line.hasPrefix("==> ") else { return nil }
        let words = line.dropFirst(4).split(separator: " ").map(String.init)
        guard let verb = words.first else { return nil }
        switch verb {
        case "Pouring":
            guard words.count == 2, let r = words[1].range(of: "--") else { return nil }
            return String(words[1][..<r.lowerBound])
        case "Upgrading", "Installing":
            // "==> Installing foo dependency: bar"
            if words.count == 4, words[2] == "dependency:" { return words[3] }
            // "==> Upgrading foo" (not "==> Upgrading 3 outdated packages:")
            if words.count == 2, !words[1].hasSuffix(":") { return words[1] }
            return nil
        default:
            return nil
        }
    }

    /// `brew link foo`, `brew link --overwrite foo`, `brew postinstall foo`.
    static func hintName(_ line: String) -> String? {
        let words = line.split(separator: " ").map(String.init)
        guard words.count >= 3, words[0] == "brew", words[1] == "link" || words[1] == "postinstall",
              let last = words.last, !last.hasPrefix("-") else { return nil }
        return last
    }

    /// `name` is `p` (its name, full name, or full name's last part).
    static func names(_ name: String, _ p: Package) -> Bool {
        name == p.name || name == p.fullName || name == p.fullName.split(separator: "/").last.map(String.init)
    }

    /// brew's error names a package other than `p`: an `Error: <name>: …`
    /// line, or a link or post-install failure tied to another package.
    static func namesAnotherPackage(_ lines: [String], _ p: Package) -> Bool {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Error: ") else { continue }
            let rest = line.dropFirst("Error: ".count)
            guard let colon = rest.range(of: ": ") else { continue }
            let token = String(rest[..<colon.lowerBound])
            guard !token.isEmpty, !token.contains(" "), token.allSatisfy(isNameCharacter) else { continue }
            if !names(token, p) { return true }
        }
        return linkOrPostInstallFailures(lines).contains { name in name.map { !names($0, p) } ?? false }
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "@+._/-".contains(c)
    }
}
