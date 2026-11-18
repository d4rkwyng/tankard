import Foundation

/// 0.8.6 (walkthrough M1): installed packages that `brew info --json=v2
/// --installed` leaves out because brew can't load them, such as a formula
/// from an untrusted tap, or one its tap renamed (`obsidian-cli`, now
/// `yakitrak/yakitrak/notesmd-cli`: "Refusing to load formula … from
/// untrusted tap"). brew list still shows them, so Tankard does too: a
/// Cellar or Caskroom folder with a version inside that no package in the
/// JSON accounts for becomes a row marked `unreadable`.
public enum UnreadableKegs {
    /// The names a package in brew's JSON accounts for in the Cellar
    /// (name and old names) and the Caskroom (token).
    static func known(_ info: BrewInfoJSON) -> (formulae: Set<String>, casks: Set<String>) {
        var f = Set<String>()
        for x in info.formulae {
            f.insert(x.name)
            for o in x.oldnames ?? [] { f.insert(o) }
        }
        return (f, Set(info.casks.map(\.token)))
    }

    /// Folder names with at least one non-hidden folder inside (a version).
    static func racks(_ dir: String) -> [(name: String, versions: [String])] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let versions = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { v in
                var d: ObjCBool = false
                return !v.hasPrefix(".") && fm.fileExists(atPath: path + "/" + v, isDirectory: &d) && d.boolValue
            }
            return versions.isEmpty ? nil : (name, versions.sorted { PkgVersion(parsing: $0) < PkgVersion(parsing: $1) })
        }
    }

    struct Receipt: Decodable {
        struct Source: Decodable { var tap: String? }
        var source: Source?
        var installedOnRequest: Bool?
        var pouredFromBottle: Bool?
        var time: Double?
        enum CodingKeys: String, CodingKey {
            case source, time
            case installedOnRequest = "installed_on_request"
            case pouredFromBottle = "poured_from_bottle"
        }
    }

    static func receipt(_ path: String) -> Receipt? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    /// The rows for kegs and casks the JSON doesn't account for. `reason`
    /// is filled in later (`BrewClient.status`, from brew's own words).
    public static func find(cellar: String, caskroom: String, info: BrewInfoJSON) -> [Package] {
        let known = known(info)
        var out: [Package] = []
        for (name, versions) in racks(cellar) where !known.formulae.contains(name) {
            let latest = versions.last ?? ""
            let r = receipt("\(cellar)/\(name)/\(latest)/INSTALL_RECEIPT.json")
            out.append(row(kind: .formula, name: name, tap: r?.source?.tap, versions: versions,
                           requested: r?.installedOnRequest ?? true, poured: r?.pouredFromBottle,
                           time: r?.time))
        }
        for (token, versions) in racks(caskroom) where !known.casks.contains(token) {
            let r = receipt("\(caskroom)/\(token)/.metadata/INSTALL_RECEIPT.json")
            out.append(row(kind: .cask, name: token, tap: r?.source?.tap, versions: versions,
                           requested: true, poured: nil, time: r?.time))
        }
        return out
    }

    static func row(kind: PackageKind, name: String, tap: String?, versions: [String], requested: Bool,
                    poured: Bool?, time: Double?) -> Package {
        var p = Package.command(name)
        p.kind = kind
        p.id = "\(kind.rawValue):" + StatusClassifier.qualified(tap: tap, name: name)
        p.fullName = StatusClassifier.qualified(tap: tap, name: name)
        p.tap = tap
        p.status = kind == .cask ? .cask : (poured == false ? .source : .bottle)
        p.statusLabel = String(localized: "can't be read")
        p.installedVersion = versions.last ?? ""
        p.installedVersions = versions
        p.requested = requested
        p.pouredFromBottle = kind == .formula ? poured : nil
        p.upgradeHasBottle = nil
        p.installedAt = time.map { Date(timeIntervalSince1970: $0) }
        p.unreadable = ""
        return p
    }

    /// brew's own reason, from the stderr of `brew info` on the name: the
    /// "Error: " line without the prefix, and brew's advice on the lines
    /// right after it ("Refusing to load formula yakitrak/yakitrak/
    /// notesmd-cli from untrusted tap yakitrak/yakitrak. Run `brew trust …`
    /// to trust it.").
    public static func reason(stderr: String) -> String? {
        let lines = stderr.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(where: { $0.hasPrefix("Error: ") }) else { return nil }
        var parts = [String(lines[i].dropFirst("Error: ".count))]
        for line in lines[(i + 1)...].prefix(2) {
            if line.isEmpty || line.hasPrefix("Error:") || line.hasPrefix("Warning:") || line.hasPrefix("==>") { break }
            parts.append(line)
        }
        return parts.joined(separator: " ")
    }
}

public extension Package {
    /// 0.8.6 (M1): brew can't read this installed package (it is missing
    /// from `brew info --installed`), so brew won't upgrade it either.
    var isUnreadable: Bool { unreadable != nil }

    /// "brew can't read it: Refusing to load …" for the detail pane, Health
    /// and the tooltip.
    var unreadableDetail: String? {
        guard let why = unreadable else { return nil }
        let from = tap.map { String(localized: "Installed from \($0).") }
        let head = why.isEmpty
            ? String(localized: "Homebrew can't read this package any more, so it won't upgrade it.")
            : String(localized: "Homebrew can't read this package any more, so it won't upgrade it. brew says: \(why)")
        return [head, from].compactMap { $0 }.joined(separator: " ")
    }
}

/// 0.8.6 (walkthrough M4): when brew last changed what is installed, by
/// the folders an install, upgrade or uninstall always touches (a folder's
/// modification time changes when an entry is added or removed).
public enum HomebrewChanges {
    public static func paths(client: BrewClient) -> [String] {
        let prefix = client.installation.prefix
        return [client.platform.cellar, prefix + "/Caskroom", prefix + "/opt", prefix + "/var/homebrew/linked"]
    }

    public static func latest(client: BrewClient) -> Date? { latest(paths: paths(client: client)) }

    /// The newest modification time of those that exist; nil when none do.
    public static func latest(paths: [String]) -> Date? {
        paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }
}
