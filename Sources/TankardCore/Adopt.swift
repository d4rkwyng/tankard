import Foundation

// v0.8: Adopt Apps. Apps installed by hand (a drag from a .dmg, the
// vendor's installer) that a Homebrew cask also installs can be handed to
// brew with `brew install --cask --adopt <token>`: brew downloads the cask,
// checks the download's app against the one already there and, when they
// are the same version, records the cask as installed without replacing
// the app. Everything here is read-only: it scans app bundles' Info.plist
// files and matches them against the cask index Discover already caches.
//
// What brew 7.0.14 does (Library/Homebrew, read 2026-11-17):
// - --adopt still downloads and stages the cask (cask/artifact/moved.rb:84-86).
// - It adopts only when the download's CFBundleShortVersionString AND
//   CFBundleVersion equal the installed app's (moved.rb:99-118,
//   bundle_version.rb:14-25), else a `diff -r`, else it fails.
// - Casks with `auto_updates true` skip that check: any version adopts (moved.rb:102).
// - A failed install never deletes the adopted app (cask/installer.rb:384).
// - pkg casks ignore --adopt and re-run the installer (cask/artifact/pkg.rb:60-63).
// - Only the cask's own target path adopts; a copy elsewhere is a second install.

/// One app bundle found on disk.
public struct InstalledApp: Sendable, Equatable, Identifiable, Codable {
    /// "/Applications/Foo.app"
    public var path: String
    /// The folder scanned ("/Applications" or "~/Applications", expanded).
    public var root: String
    /// The path below `root`: "Foo.app" or "Utilities/Foo.app".
    public var relativePath: String
    public var bundleID: String?
    public var shortVersion: String?
    public var bundleVersion: String?
    /// The display name (CFBundleName or the file name without ".app").
    public var displayName: String
    /// A Mac App Store receipt *file* (Contents/_MASReceipt/receipt). Some
    /// apps from elsewhere ship an empty _MASReceipt folder, so the folder
    /// alone doesn't count.
    public var hasMASReceipt: Bool
    public var isSymlink: Bool

    public var id: String { path }
    /// "Foo.app"
    public var fileName: String { (relativePath as NSString).lastPathComponent }
    public var isInApplications: Bool { root == AppScanner.systemApplications }

    public init(path: String, root: String, relativePath: String, bundleID: String?, shortVersion: String?,
                bundleVersion: String?, displayName: String? = nil, hasMASReceipt: Bool = false, isSymlink: Bool = false) {
        self.path = path
        self.root = root
        self.relativePath = relativePath
        self.bundleID = bundleID
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.displayName = displayName ?? ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        self.hasMASReceipt = hasMASReceipt
        self.isSymlink = isSymlink
    }
}

/// Finds app bundles in /Applications (and one folder level below it) and
/// ~/Applications, and reads their Info.plist.
public enum AppScanner {
    public static let systemApplications = "/Applications"
    public static var userApplications: String { (NSHomeDirectory() as NSString).appendingPathComponent("Applications") }

    public static func scan(roots: [String] = [systemApplications, userApplications],
                            fileManager: FileManager = .default) -> [InstalledApp] {
        var out: [InstalledApp] = []
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for e in entries.sorted() where !e.hasPrefix(".") {
                let p = (root as NSString).appendingPathComponent(e)
                if e.hasSuffix(".app") {
                    if let a = read(path: p, root: root, relativePath: e, fileManager: fileManager) { out.append(a) }
                } else if isPlainDirectory(p, fileManager) {
                    guard let inner = try? fileManager.contentsOfDirectory(atPath: p) else { continue }
                    for e2 in inner.sorted() where e2.hasSuffix(".app") {
                        let rel = (e as NSString).appendingPathComponent(e2)
                        if let a = read(path: (p as NSString).appendingPathComponent(e2), root: root, relativePath: rel,
                                        fileManager: fileManager) { out.append(a) }
                    }
                }
            }
        }
        return out
    }

    static func isPlainDirectory(_ p: String, _ fm: FileManager) -> Bool {
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { return false }
        let type = (try? fm.attributesOfItem(atPath: p))?[.type] as? FileAttributeType
        return type != .typeSymbolicLink
    }

    /// One bundle. nil when it isn't a directory.
    public static func read(path: String, root: String, relativePath: String, fileManager fm: FileManager = .default) -> InstalledApp? {
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { return nil }
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        var info: [String: Any] = [:]
        if let d = try? Data(contentsOf: plistURL),
           let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
            info = p
        }
        func str(_ k: String) -> String? {
            if let s = info[k] as? String { return s.trimmingCharacters(in: .whitespaces) }
            if let n = info[k] as? NSNumber { return n.stringValue }
            return nil
        }
        var receiptIsFile: ObjCBool = true
        let receipt = (path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")
        let mas = fm.fileExists(atPath: receipt, isDirectory: &receiptIsFile) && !receiptIsFile.boolValue
        let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        let name = str("CFBundleDisplayName") ?? str("CFBundleName")
        return InstalledApp(path: path, root: root, relativePath: relativePath, bundleID: str("CFBundleIdentifier"),
                            shortVersion: str("CFBundleShortVersionString"), bundleVersion: str("CFBundleVersion"),
                            displayName: name?.isEmpty == false ? name : nil,
                            hasMASReceipt: mas, isSymlink: type == .typeSymbolicLink)
    }
}

/// A cask as Adopt Apps sees it.
public struct AdoptCask: Sendable, Equatable {
    public var token: String
    public var fullToken: String
    public var tap: String?
    public var version: String
    public var autoUpdates: Bool
    public var names: [String]
    /// The homepage and the download URL, for the vendor check.
    public var web: String
    public var apps: [BrewInfoJSON.Cask.AdoptArtifacts.App]
    public var suites: [String]
    public var pkg: Bool
    /// Bundle-id-like strings from `uninstall` and `zap`, lower-cased.
    public var bundleIDs: Set<String>
    /// 0.8.6: those from `uninstall`'s quit, launchctl, signal, pkgutil and
    /// login_item only (the cask's own app), for finding a renamed app by
    /// its ID. Defaults to `bundleIDs`.
    public var ownBundleIDs: Set<String>
    public var deprecated: Bool
    public var disabled: Bool

    public init(token: String, fullToken: String? = nil, tap: String? = "homebrew/cask", version: String,
                autoUpdates: Bool = false, names: [String] = [], web: String = "",
                apps: [BrewInfoJSON.Cask.AdoptArtifacts.App] = [], suites: [String] = [], pkg: Bool = false,
                bundleIDs: Set<String> = [], ownBundleIDs: Set<String>? = nil, deprecated: Bool = false, disabled: Bool = false) {
        self.token = token
        self.fullToken = fullToken ?? token
        self.tap = tap
        self.version = version
        self.autoUpdates = autoUpdates
        self.names = names
        self.web = web
        self.apps = apps
        self.suites = suites
        self.pkg = pkg
        self.bundleIDs = bundleIDs
        self.ownBundleIDs = ownBundleIDs ?? bundleIDs
        self.deprecated = deprecated
        self.disabled = disabled
    }

    public init(_ c: BrewInfoJSON.Cask) {
        let a = c.adoptArtifacts ?? .init()
        self.init(token: c.token, fullToken: c.fullToken, tap: c.tap, version: c.version, autoUpdates: c.autoUpdates ?? false,
                  names: c.name ?? [], web: [c.homepage ?? "", c.url ?? ""].joined(separator: " "),
                  apps: a.apps, suites: a.suites, pkg: a.pkg, bundleIDs: AdoptIndex.bundleIDHints(a.idStrings),
                  ownBundleIDs: AdoptIndex.bundleIDHints(a.ownIDStrings), deprecated: c.deprecated ?? false, disabled: c.disabled ?? false)
    }

    /// "homebrew/cask/firefox": what install is given (as Discover does).
    public var qualifiedName: String {
        guard let tap, !tap.isEmpty else { return fullToken }
        return fullToken.contains("/") ? fullToken : "\(tap)/\(token)"
    }

    public var isVariant: Bool { token.contains("@") }
}

/// The cask index, by app file name, target path, suite folder and bundle id.
public struct AdoptIndex: Sendable {
    public private(set) var byToken: [String: AdoptCask] = [:]
    var byName: [String: Set<String>] = [:]
    var byRelative: [String: Set<String>] = [:]
    var suiteByDir: [String: Set<String>] = [:]
    var byBundleID: [String: Set<String>] = [:]

    public var count: Int { byToken.count }

    public init(casks: [AdoptCask]) {
        for c in casks {
            byToken[c.token] = c
            for a in c.apps {
                byName[(a.target as NSString).lastPathComponent.lowercased(), default: []].insert(c.token)
                if let rel = Self.relativeToApplications(a.target) { byRelative[rel.lowercased(), default: []].insert(c.token) }
            }
            for s in c.suites {
                suiteByDir[(s as NSString).lastPathComponent.lowercased(), default: []].insert(c.token)
            }
            // 0.8.6: only the cask's own app's ids (a zap's cleanup list
            // names other apps: bookends' names Microsoft Word's).
            for b in c.ownBundleIDs { byBundleID[b, default: []].insert(c.token) }
        }
    }

    /// formulae.brew.sh's cask.json (a top-level array). Casks that don't
    /// decode are skipped by the decoder as a whole failing, so this
    /// throws only on a broken file.
    public static func decode(caskJSON: Data) throws -> AdoptIndex {
        let casks = try JSONDecoder().decode([BrewInfoJSON.Cask].self, from: caskJSON)
        return AdoptIndex(casks: casks.map(AdoptCask.init))
    }

    /// "/Applications/Foo.app" → "Foo.app"; "/Applications/Sub/Foo.app" →
    /// "Sub/Foo.app"; anything outside /Applications → nil.
    public static func relativeToApplications(_ target: String) -> String? {
        let prefix = AppScanner.systemApplications + "/"
        if target.hasPrefix(prefix) { return String(target.dropFirst(prefix.count)) }
        if !target.hasPrefix("/") && !target.hasPrefix("~") && !target.hasPrefix("$") { return target }
        return nil
    }

    // MARK: bundle ids in uninstall/zap

    nonisolated(unsafe) static let threeLabels = /^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+){2,}$/
    nonisolated(unsafe) static let twoLabels = /^[A-Za-z][A-Za-z0-9-]*\.[A-Za-z][A-Za-z0-9_-]+$/
    static let fileSuffixes = [".plist", ".savedstate", ".binarycookies", ".sfl2", ".sfl3", ".sfl"]

    /// Bundle-id-like strings in `uninstall`/`zap`: quit, signal,
    /// launchctl, pkgutil, login item ids, and path parts such as
    /// Preferences/<id>.plist. A two-label id (md.obsidian) counts only as
    /// a <id>.plist / .savedState name, where it can't be a domain.
    public static func bundleIDHints(_ strings: [String]) -> Set<String> {
        var out = Set<String>()
        for s in strings {
            for part in s.split(separator: "/") {
                var p = String(part)
                while p.hasSuffix("*") { p.removeLast() }
                var hadSuffix = false
                for suf in fileSuffixes where p.lowercased().hasSuffix(suf) {
                    p = String(p.dropLast(suf.count))
                    hadSuffix = true
                    break
                }
                guard !p.contains("*"), !p.isEmpty else { continue }
                let ok = p.wholeMatch(of: threeLabels) != nil || (hadSuffix && p.wholeMatch(of: twoLabels) != nil)
                if ok, !p.lowercased().hasPrefix("com.apple.") { out.insert(p.lowercased()) }
            }
        }
        return out
    }
}

// MARK: matching

public enum AdoptConfidence: String, Sendable, Comparable, Codable {
    case low, medium, high
    public static func < (a: Self, b: Self) -> Bool {
        let order: [Self] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// How the cask was found.
public enum AdoptMatchKind: String, Sendable, Codable {
    /// The cask's target is exactly this path below /Applications.
    case targetPath
    /// Same app file name, somewhere else.
    case name
    /// The app sits in a folder that is a cask's suite.
    case suite
    /// Only the bundle id matched (a renamed app).
    case bundleID
}

/// Why an app can't be adopted.
public enum AdoptBlock: Sendable, Equatable, Codable {
    /// The cask runs an installer package: brew ignores --adopt and re-runs it.
    case pkg
    /// The app isn't where the cask puts it.
    case location(expected: String)
    /// The app belongs to a suite folder (brew compares the whole folder).
    case suite(String)
    /// The cask is disabled.
    case disabled
    /// The app has no version brew can compare.
    case noVersion
    /// The app is a symbolic link: Tankard doesn't hand links to brew
    /// (what a later upgrade or uninstall does to the link's target is
    /// not something it has checked).
    case symlink
    /// 0.8.6: the cask's app updates itself, so brew adopts without
    /// comparing anything, and the app's ID isn't one the cask names.
    case unverifiedSelfUpdating
}

/// What adopting would do.
public enum AdoptVerdict: Sendable, Equatable, Codable {
    /// Same version (or the cask updates itself, so brew doesn't compare).
    case ready
    /// The version can't be compared before the download (`version :latest`).
    case readyUnchecked
    /// The installed version differs from the cask's: brew would refuse.
    case needsUpdate(installed: String, cask: String)
    case blocked(AdoptBlock)
}

/// The cask version's comparable part: before the first comma
/// ("1.2.3,456" → "1.2.3"), and the comma parts.
public enum AdoptVersion {
    public static func split(_ v: String) -> (head: String, tail: [String]) {
        guard let i = v.firstIndex(of: ",") else { return (v, []) }
        return (String(v[..<i]), v[v.index(after: i)...].split(separator: ",").map(String.init))
    }

    /// What brew would make of this app and cask version. brew's real check
    /// compares the download's Info.plist (short version AND
    /// CFBundleVersion) with the installed one; the cask's version string is
    /// the best prediction there is before downloading. auto_updates casks
    /// skip the check, so any version adopts.
    public static func verdict(app: InstalledApp, caskVersion: String, autoUpdates: Bool) -> AdoptVerdict {
        if autoUpdates { return .ready }
        if caskVersion == "latest" { return .readyUnchecked }
        let (head, _) = split(caskVersion)
        guard let short = app.shortVersion, !short.isEmpty else {
            if let b = app.bundleVersion, b == head { return .ready }
            return .blocked(.noVersion)
        }
        if short == head { return .ready }
        // Some casks carry the build number as their version.
        if let b = app.bundleVersion, b == head { return .ready }
        return .needsUpdate(installed: short, cask: head)
    }
}

/// One scanned app and what Adopt Apps can do with it.
public struct AdoptRow: Sendable, Equatable, Identifiable {
    public var app: InstalledApp
    /// Matching casks, best first. Empty: no cask.
    public var candidates: [String]
    public var how: AdoptMatchKind?
    /// Per candidate (same order): confidence and verdict.
    public var confidence: [String: AdoptConfidence]
    public var verdicts: [String: AdoptVerdict]
    /// 0.8.6: casks found by the app's name (or folder) that name app IDs,
    /// none of them this app's: possibly a different app with the same
    /// name, so not offered (copilot-money's Copilot.app vs another
    /// Copilot). Shown under "No cask" with the reason.
    public var rejected: [String]
    /// 0.8.6: per candidate, what its app IDs say about this app.
    public var evidence: [String: AdoptMatcher.IDEvidence]

    public var id: String { app.id }
    public var bestToken: String? { candidates.first }
    public var isAmbiguous: Bool { candidates.count > 1 }

    public init(app: InstalledApp, candidates: [String] = [], how: AdoptMatchKind? = nil,
                confidence: [String: AdoptConfidence] = [:], verdicts: [String: AdoptVerdict] = [:],
                rejected: [String] = [], evidence: [String: AdoptMatcher.IDEvidence] = [:]) {
        self.app = app
        self.candidates = candidates
        self.how = how
        self.confidence = confidence
        self.verdicts = verdicts
        self.rejected = rejected
        self.evidence = evidence
    }
}

/// Apps left out before matching.
public struct AdoptSkipped: Sendable, Equatable {
    public var apple: [InstalledApp] = []
    public var appStore: [InstalledApp] = []
    public var managed: [InstalledApp] = []
    public init() {}
}

public struct AdoptScan: Sendable, Equatable {
    public var rows: [AdoptRow]
    public var skipped: AdoptSkipped
    public init(rows: [AdoptRow] = [], skipped: AdoptSkipped = AdoptSkipped()) {
        self.rows = rows
        self.skipped = skipped
    }
}

/// 0.8.5: what ties an app on disk to an installed cask that has no `app`
/// stanza. pkg casks (microsoft-word, microsoft-teams, windows-app, ...)
/// install their app through an installer package, so `brew info` lists no
/// app for them and Adopt Apps offered them although brew already has them.
/// From `uninstall`: the receipt ids (`pkgutil`) and the `.app` paths it
/// deletes; from `uninstall` and `zap`: bundle-id-like strings, which count
/// only together with the cask's name (`AdoptIndex.bundleIDHints`).
public struct CaskAppOwnership: Sendable, Equatable, Codable {
    /// The cask's names ("Microsoft Word").
    public var names: [String]
    /// `uninstall` → `pkgutil`, as brew gives them (some are patterns).
    public var receiptIDs: [String]
    /// `uninstall` → `delete` paths that are app bundles.
    public var appPaths: [String]
    /// Bundle-id-like strings from `uninstall` and `zap`, lower-cased.
    public var bundleIDHints: [String]

    public init(names: [String] = [], receiptIDs: [String] = [], appPaths: [String] = [], bundleIDHints: [String] = []) {
        self.names = names
        self.receiptIDs = receiptIDs
        self.appPaths = appPaths
        self.bundleIDHints = bundleIDHints
    }

    /// From the decoded stanzas: `deletePaths` keeps the ones ending in
    /// ".app", `idStrings` becomes bundle-id hints.
    public init(names: [String], receiptIDs: [String], deletePaths: [String], idStrings: [String]) {
        self.init(names: names, receiptIDs: receiptIDs,
                  appPaths: deletePaths.filter { $0.lowercased().hasSuffix(".app") && !$0.contains("*") },
                  bundleIDHints: AdoptIndex.bundleIDHints(idStrings).sorted())
    }

    /// The receipt ids that are plain ids (brew also takes regular
    /// expressions there: "com.example.*").
    public var plainReceiptIDs: [String] {
        receiptIDs.filter { id in !id.isEmpty && !id.contains(where: { "*\\[](){}^$|+?".contains($0) }) }
    }
}

/// 0.8.5: the app bundles an installer package receipt put on disk
/// (`pkgutil --pkg-info-plist` and `pkgutil --only-dirs --files`).
public enum PkgReceipts {
    public static let pkgutil = "/usr/sbin/pkgutil"

    /// The top-level bundles in a receipt's directory list: "Foo.app",
    /// "Sub/Foo.app", not anything inside a bundle. `volume` and
    /// `installLocation` are the receipt's ("/" and "Applications").
    public static func appPaths(volume: String, installLocation: String, dirs: [String]) -> [String] {
        var base = volume.isEmpty ? "/" : volume
        if !installLocation.isEmpty { base = (base as NSString).appendingPathComponent(installLocation) }
        var out: [String] = []
        for raw in dirs {
            var d = raw.trimmingCharacters(in: .whitespaces)
            if d.hasPrefix("./") { d.removeFirst(2) }
            guard d.lowercased().hasSuffix(".app") else { continue }
            let parts = d.split(separator: "/")
            // Only the bundle itself (no ".app" folder above it).
            guard !parts.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) else { continue }
            out.append(((base as NSString).appendingPathComponent(d) as NSString).standardizingPath)
        }
        return out
    }

    /// Reads the receipts of `ids` (missing receipts are skipped). Only
    /// apps in an Applications folder are kept.
    public static func live(ids: [String], runner: CommandRunning = ProcessRunner()) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for id in Set(ids) {
            guard let info = try? await runner.run(pkgutil, ["--pkg-info-plist", id], environment: [:]), info.exitCode == 0,
                  let plist = try? PropertyListSerialization.propertyList(from: info.stdout, format: nil) as? [String: Any],
                  let files = try? await runner.run(pkgutil, ["--only-dirs", "--files", id], environment: [:]), files.exitCode == 0
            else { continue }
            let apps = appPaths(volume: plist["volume"] as? String ?? "/",
                                installLocation: plist["install-location"] as? String ?? "",
                                dirs: files.stdoutString.split(separator: "\n").map(String.init))
                .filter { $0.contains("/Applications/") }
            if !apps.isEmpty { out[id] = apps }
        }
        return out
    }
}

/// What brew already owns: the installed casks' app paths and bundle ids.
public struct ManagedApps: Sendable {
    public var paths: Set<String>
    public var bundleIDs: Set<String>
    public var tokens: Set<String>
    /// 0.8.5: installed casks' receipt ids (`adding(receiptApps:)` turns
    /// them into paths).
    public var receiptIDs: Set<String> = []
    /// 0.8.5: casks without an `app` stanza: a bundle id they name counts
    /// only for an app with the cask's name (microsoft-office's zap names
    /// OneDrive's id; a hand-installed OneDrive is not Homebrew's).
    public var namedHints: [NamedHint] = []

    public struct NamedHint: Sendable, Equatable {
        public var names: Set<String>
        public var bundleIDs: Set<String>
        public init(names: Set<String>, bundleIDs: Set<String>) {
            self.names = Set(names.map { $0.lowercased() })
            self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        }
    }

    public init(paths: Set<String> = [], bundleIDs: Set<String> = [], tokens: Set<String> = []) {
        self.paths = Set(paths.map { Self.normalize($0) })
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        self.tokens = tokens
    }

    static func normalize(_ p: String) -> String {
        ((p as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// From the installed casks Tankard already read (`brew info`): their
    /// app paths, and the bundle ids their `uninstall` quits (the apps
    /// themselves; 0.8.6: only for an app with the cask's or its app's name). Not the ids in `zap` or the rest of `uninstall` on
    /// their own: those name other apps too (choosy's zap lists Opera's,
    /// tidgi's VS Code's, microsoft-office's OneDrive's in cask.json,
    /// 2026-11-17), and an app installed by hand would be hidden as
    /// "already from Homebrew".
    ///
    /// 0.8.5: pkg casks list no app, so also: the `.app` paths `uninstall`
    /// deletes, the receipt ids (some are the app's bundle id: teams2,
    /// rdc.macos), the receipts' apps (`adding(receiptApps:)`), and for
    /// casks without an app stanza a uninstall/zap bundle id together with
    /// the cask's name. `index` is kept for the call sites; it adds nothing.
    public init(packages: [Package], index: AdoptIndex?) {
        let casks = packages.filter { $0.kind == .cask }
        let own = casks.compactMap(\.caskOwnership)
        // Casks without an app stanza (pkg installers): their quit ids are
        // what the installer put on disk (microsoft-word quits Microsoft
        // AutoUpdate, which its pkg installs), as in 0.8.5.
        let pkgQuit = casks.filter { ($0.appPaths ?? []).isEmpty }.flatMap { $0.quitBundleIDs ?? [] }
        let ids = Set(own.flatMap(\.plainReceiptIDs)).union(pkgQuit)
        let paths = Set(casks.flatMap { $0.appPaths ?? [] }).union(own.flatMap(\.appPaths))
        self.init(paths: paths, bundleIDs: ids, tokens: Set(casks.map(\.name)))
        receiptIDs = Set(own.flatMap(\.plainReceiptIDs))
        for c in casks {
            // 0.8.6: a quit id counts only with the cask's name or its
            // app's name: chatgpt's uninstall quits com.openai.codex, and
            // wondershare-uniconverter's quits com.google.Chrome, which
            // hid a hand-installed Codex or Chrome as "already from Homebrew".
            let appNames = (c.appPaths ?? []).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            let names = Set((c.caskOwnership?.names ?? []) + appNames + [c.name])
            if !(c.appPaths ?? []).isEmpty, let quit = c.quitBundleIDs, !quit.isEmpty {
                namedHints.append(NamedHint(names: names, bundleIDs: Set(quit)))
            }
            if (c.appPaths ?? []).isEmpty, let o = c.caskOwnership, !o.bundleIDHints.isEmpty {
                namedHints.append(NamedHint(names: names, bundleIDs: Set(o.bundleIDHints)))
            }
        }
    }

    /// The receipts' apps (receipt id → app paths, `PkgReceipts.live`),
    /// for this list's receipt ids.
    public func adding(receiptApps: [String: [String]]) -> ManagedApps {
        var m = self
        for (id, apps) in receiptApps where receiptIDs.contains(id) {
            m.paths.formUnion(apps.map { Self.normalize($0) })
        }
        return m
    }

    public func owns(_ app: InstalledApp) -> Bool {
        let p = (app.path as NSString).standardizingPath
        let real = (p as NSString).resolvingSymlinksInPath
        if paths.contains(p) || paths.contains(real) { return true }
        if paths.contains(where: { p.hasPrefix($0 + "/") }) { return true }
        guard let b = app.bundleID?.lowercased() else { return false }
        if bundleIDs.contains(b) { return true }
        let names: Set<String> = [app.displayName.lowercased(), (app.fileName as NSString).deletingPathExtension.lowercased()]
        // 0.8.6: the name, or the name and more words ("Choosy Moved").
        func fits(_ n: String) -> Bool {
            names.contains { a in
                a == n || (a.hasPrefix(n + " ") && !n.isEmpty)
            }
        }
        return namedHints.contains { $0.bundleIDs.contains(b) && $0.names.contains(where: fits) }
    }
}

public enum AdoptMatcher {
    /// Scans `apps` against the index. Apple's own apps, Mac App Store apps
    /// and apps brew already owns are left out (and counted).
    public static func match(_ apps: [InstalledApp], index: AdoptIndex, managed: ManagedApps) -> AdoptScan {
        var scan = AdoptScan()
        for a in apps {
            let bid = a.bundleID?.lowercased() ?? ""
            if bid.hasPrefix("com.apple.") { scan.skipped.apple.append(a); continue }
            if managed.owns(a) { scan.skipped.managed.append(a); continue }
            if a.hasMASReceipt { scan.skipped.appStore.append(a); continue }
            let r = row(for: a, index: index)
            // A suite is one cask for the whole folder: one row for it (the
            // app named after the folder when there is one).
            if r.how == .suite, let folder = r.app.relativePath.split(separator: "/").first.map(String.init),
               let i = scan.rows.firstIndex(where: { $0.how == .suite && $0.app.relativePath.hasPrefix(folder + "/") }) {
                if r.app.fileName.lowercased() == folder.lowercased() + ".app" { scan.rows[i] = r }
                continue
            }
            scan.rows.append(r)
        }
        return scan
    }

    public static func row(for a: InstalledApp, index: AdoptIndex) -> AdoptRow {
        let bid = a.bundleID?.lowercased() ?? ""
        var how: AdoptMatchKind?
        var cands = Set<String>()
        let rel = a.relativePath.lowercased()
        if a.isInApplications, let t = index.byRelative[rel], !t.isEmpty {
            how = .targetPath; cands = t
        } else if let t = index.byName[a.fileName.lowercased()], !t.isEmpty {
            how = .name; cands = t
        } else if a.relativePath.contains("/"),
                  let t = index.suiteByDir[String(rel.split(separator: "/")[0])], !t.isEmpty {
            how = .suite; cands = t
        } else if !bid.isEmpty, let t = index.byBundleID[bid], !t.isEmpty {
            how = .bundleID; cands = t
        }
        guard let how else { return AdoptRow(app: a) }
        var all = cands.compactMap { index.byToken[$0] }
        if how == .bundleID { all = renamedAppCandidates(bid, all) }
        // 0.8.6: a cask that names app IDs must name this app's (or its
        // developer's prefix). The same file name is not enough
        // (copilot-money installs a "Copilot.app" whose ID is
        // com.copilot.production; Microsoft's Copilot.app is not it), and
        // adopting a wrong match hands someone else's app to brew upgrade
        // and uninstall.
        var ev: [String: IDEvidence] = [:]
        for c in all { ev[c.token] = idEvidence(app: a, cask: c) }
        let rejected = all.filter { ev[$0.token] == .mismatch }.map(\.token).sorted()
        let ordered = all.filter { ev[$0.token] != .mismatch }.sorted { better($0, than: $1, app: a, evidence: ev) }
        guard !ordered.isEmpty else { return AdoptRow(app: a, rejected: rejected) }
        var conf: [String: AdoptConfidence] = [:]
        var verdicts: [String: AdoptVerdict] = [:]
        for c in ordered {
            conf[c.token] = confidence(app: a, cask: c, ambiguous: ordered.count > 1)
            verdicts[c.token] = verdict(app: a, cask: c, how: how)
        }
        return AdoptRow(app: a, candidates: ordered.map(\.token), how: how, confidence: conf, verdicts: verdicts,
                        rejected: rejected, evidence: ev.filter { e in ordered.contains { $0.token == e.key } })
    }

    /// 0.8.6: an app found by its ID alone (renamed: Chrome.app). Several
    /// casks can quit that ID (wondershare-uniconverter quits Google
    /// Chrome's); keep those whose token or app name has a word of the ID
    /// below its developer prefix ("chrome" in google-chrome), when any does.
    static func renamedAppCandidates(_ bid: String, _ casks: [AdoptCask]) -> [AdoptCask] {
        guard casks.count > 1 else { return casks }
        let labels = bid.split(separator: ".").map(String.init)
        let words = labels.dropFirst(AdoptVendor.vendorLabelCount(labels)).filter { $0.count >= 3 }
        guard !words.isEmpty else { return casks }
        let kept = casks.filter { c in
            let names = ([c.token] + c.names + c.apps.map { ($0.target as NSString).lastPathComponent })
                .joined(separator: " ").lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
            return words.contains { w in names.contains { n in w.contains(n) || n.contains(w) } }
        }
        return kept.isEmpty ? casks : kept
    }

    /// What the cask's app IDs say about this app.
    public enum IDEvidence: String, Sendable, Equatable, Codable {
        /// The cask names this app's ID.
        case match
        /// The cask names an ID with this app's developer prefix
        /// (org.scummvm.app vs org.scummvm.scummvm), not this app's.
        case vendor
        /// The cask names app IDs, none of them this app's or its
        /// developer's (or the app has no ID to compare).
        case mismatch
        /// The cask names no app IDs: only the name can be compared.
        case none
    }

    /// 0.8.6. The IDs a cask names are the bundle-id-looking strings in its
    /// `uninstall` and `zap` (quit, signal, launchctl, pkgutil, login items,
    /// and path parts: Containers/<id>, Group Containers/group.<id>,
    /// Application Scripts/<id>, Preferences/<id>.plist, Caches/<id>, ...;
    /// `AdoptIndex.bundleIDHints`). `.match`: the app's CFBundleIdentifier
    /// is one of them, or (for an ID of three labels or more) one is the
    /// app's ID with a prefix or suffix label: group.<id>, <TEAMID>.<id>,
    /// <id>.helper. `.vendor`: one shares the app ID's developer prefix
    /// (`AdoptVendor.vendorLabelCount`: two labels, three under a shared
    /// namespace such as com.electron or uk.co). Case is ignored.
    public static func idEvidence(app: InstalledApp, cask c: AdoptCask) -> IDEvidence {
        guard !c.bundleIDs.isEmpty else { return .none }
        let bid = app.bundleID?.lowercased() ?? ""
        guard !bid.isEmpty else { return .mismatch }
        if names(bid, c.bundleIDs) { return .match }
        return sameVendor(bid, c.bundleIDs) ? .vendor : .mismatch
    }

    /// Whether `ids` (lower-cased) name the app ID `bid` (lower-cased).
    static func names(_ bid: String, _ ids: Set<String>) -> Bool {
        if ids.contains(bid) { return true }
        guard bid.split(separator: ".").count >= 3 else { return false }
        return ids.contains { $0.hasPrefix(bid + ".") || $0.hasSuffix("." + bid) }
    }

    /// Whether one of `ids` has the developer prefix of `bid` (both
    /// lower-cased), after dropping a leading "group." or Team ID label.
    static func sameVendor(_ bid: String, _ ids: Set<String>) -> Bool {
        let labels = bid.split(separator: ".").map(String.init)
        let n = AdoptVendor.vendorLabelCount(labels)
        guard labels.count > n else { return false }
        let prefix = Array(labels.prefix(n))
        return ids.contains { id in
            var l = id.split(separator: ".").map(String.init)
            if l.first == "group" || l.first.map(isTeamID) == true { l.removeFirst() }
            return l.count > n && Array(l.prefix(n)) == prefix
        }
    }

    /// "2bua8c4s2c": ten letters and digits, with a digit.
    static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && s.contains(where: \.isNumber)
    }

    /// 0.8.6: how well the app's version fits the cask's, for picking among
    /// release lines (firefox, firefox@esr, parallels@18): 3 the same
    /// version, 2 the same with a suffix ("8.12.48" and "8.12.48-24.BETA",
    /// "153.7.0esr"), 1 the same major version, 0 otherwise.
    public static func versionFit(app a: InstalledApp, cask c: AdoptCask) -> Int {
        let head = AdoptVersion.split(c.version).head.lowercased()
        guard head != "latest" else { return 0 }
        let short = a.shortVersion?.lowercased() ?? "", build = a.bundleVersion?.lowercased() ?? ""
        if (!short.isEmpty && head == short) || (!build.isEmpty && head == build) { return 3 }
        func extends(_ long: String, _ base: String) -> Bool {
            guard !base.isEmpty, long.count > base.count, long.hasPrefix(base) else { return false }
            return !long[long.index(long.startIndex, offsetBy: base.count)].isNumber
        }
        if extends(head, short) || extends(short, head) { return 2 }
        func major(_ v: String) -> String { String(v.prefix { $0.isNumber }) }
        if !major(head).isEmpty, major(head) == major(short) { return 1 }
        return 0
    }

    /// Best first: backed by the app's ID, then the version that fits the
    /// app (0.8.6: firefox@esr for Firefox 153 ESR, parallels@18 for
    /// Parallels 18), then the plain cask (not "@beta"), not disabled, the
    /// shorter token, then by token in natural order (parallels@18 before
    /// parallels@19).
    static func better(_ x: AdoptCask, than y: AdoptCask, app: InstalledApp, evidence ev: [String: IDEvidence]) -> Bool {
        func strength(_ c: AdoptCask) -> Int {
            switch ev[c.token] ?? .none { case .match: return 3; case .vendor: return 2; case .none: return 1; case .mismatch: return 0 }
        }
        // Among casks the app's ID backs (match or developer), the version
        // decides first: little-snitch@5 for Little Snitch 5.8 although
        // only little-snitch names its exact ID.
        func backed(_ c: AdoptCask) -> Int { strength(c) >= 2 ? 1 : 0 }
        let kx = (backed(x), versionFit(app: app, cask: x), strength(x), x.isVariant ? 0 : 1, x.disabled ? 0 : 1, -x.token.count)
        let ky = (backed(y), versionFit(app: app, cask: y), strength(y), y.isVariant ? 0 : 1, y.disabled ? 0 : 1, -y.token.count)
        if kx != ky { return kx > ky }
        return x.token.localizedStandardCompare(y.token) == .orderedAscending
    }

    /// 0.8.6, from the evidence (`row(for:)` has already left out casks
    /// whose IDs don't fit). high: the cask names the app's ID ("Matched by
    /// app ID"). medium: an ID with the app's developer prefix ("Matched by
    /// name and developer"), or the cask names no IDs and a label of the
    /// app's ID is the vendor of the cask's homepage or download URL
    /// ("Matched by name and website"). low: the name and nothing else
    /// ("Matched by name only"). Only high is ticked by default, and only
    /// high can adopt a cask whose app updates itself.
    public static func confidence(app: InstalledApp, cask c: AdoptCask, ambiguous: Bool) -> AdoptConfidence {
        switch idEvidence(app: app, cask: c) {
        case .match: return .high
        case .vendor: return .medium
        case .mismatch: return .low
        case .none: return vendorInWeb(app.bundleID?.lowercased() ?? "", c.web) ? .medium : .low
        }
    }

    /// A label of the bundle id ("saurik" in com.saurik.Impactor) that is
    /// the vendor of the cask's homepage or download URL: the registrable
    /// domain's label (saurik.com), or, on a code host (github.com,
    /// sourceforge.net, ...), the owner (github.com/saurik/...). A label
    /// merely somewhere in the URL doesn't count: io.github.alice.Foo
    /// against github.com/bob/foo is not the same vendor.
    static func vendorInWeb(_ bid: String, _ web: String) -> Bool {
        let labels = bid.lowercased().split(separator: ".").dropLast().map(String.init)
            .filter { $0.count > 3 && !AdoptVendor.skip.contains($0) }
        guard !labels.isEmpty else { return false }
        let vendors = Set(web.split(whereSeparator: \.isWhitespace).flatMap { AdoptVendor.vendors(of: String($0)) })
        return labels.contains { l in vendors.contains(l) || vendors.contains(l.replacingOccurrences(of: "-", with: "")) }
    }

    public static func verdict(app a: InstalledApp, cask c: AdoptCask, how: AdoptMatchKind) -> AdoptVerdict {
        if c.disabled { return .blocked(.disabled) }
        if a.isSymlink { return .blocked(.symlink) }
        if c.pkg && c.apps.isEmpty && c.suites.isEmpty { return .blocked(.pkg) }
        if how == .suite {
            return .blocked(.suite(String(a.relativePath.split(separator: "/")[0])))
        }
        // --adopt looks only at the cask's target path.
        // An app outside /Applications never matches (a nil `here` must not
        // equal a cask target that is outside it too: "~/..." or "$APPDIR/...").
        let here = a.isInApplications ? a.relativePath.lowercased() : nil
        let target = here.flatMap { h in c.apps.first { AdoptIndex.relativeToApplications($0.target)?.lowercased() == h } }
        if target == nil {
            let expected = c.apps.first?.target ?? c.suites.first ?? AppScanner.systemApplications
            return .blocked(.location(expected: expected))
        }
        if c.pkg { return .blocked(.pkg) }
        // 0.8.6: brew adopts a self-updating cask's app without comparing
        // it with the download (moved.rb:102): the app's ID is the only check.
        if c.autoUpdates && idEvidence(app: a, cask: c) != .match { return .blocked(.unverifiedSelfUpdating) }
        return AdoptVersion.verdict(app: a, caskVersion: c.version, autoUpdates: c.autoUpdates)
    }
}

/// Who a URL belongs to, for the vendor check.
public enum AdoptVendor {
    /// Bundle-id labels that say nothing about the vendor: TLDs, generic
    /// words, and code hosts (everyone hosted there shares them).
    static let skip: Set<String> = Set(["com", "org", "net", "io", "app", "www", "apps", "mac", "macos", "osx",
                                        "electron", "todesktop", "yourcompany", "example", "group", "application"])
        .union(hostLabels)

    /// Code hosts' names as bundle-id labels (io.github.alice).
    static let hostLabels: Set<String> = [
        "github", "gitlab", "sourceforge", "bitbucket", "codeberg", "googlecode",
        "githubusercontent", "launchpad", "sourcehut", "gitee", "framagit",
    ]

    /// Registrable domains where the first path segment (or the
    /// subdomain, for pages hosts) is the owner, not the domain.
    static let codeHosts: Set<String> = [
        "github.com", "githubusercontent.com", "github.io", "gitlab.com", "gitlab.io",
        "sourceforge.net", "sourceforge.io", "sf.net", "bitbucket.org", "bitbucket.io",
        "codeberg.org", "codeberg.page", "googlecode.com", "code.google.com", "sr.ht",
        "launchpad.net", "gitee.com", "framagit.org",
    ]

    /// io.github.alice, com.github.alice, net.sourceforge.foo, ...: the
    /// first two labels name a code host, not a vendor.
    static func isHostNamespace(_ labels: [String]) -> Bool {
        labels.count >= 2 && hostLabels.contains(labels[1])
    }

    /// 0.8.6: two-label prefixes many unrelated developers share: app
    /// frameworks' and templates' defaults (com.electron.<app> from
    /// electron-builder, com.todesktop.<id>, com.yourcompany), crash
    /// reporters a zap names, and placeholders.
    static let sharedPrefixes: Set<String> = [
        "com.electron", "com.todesktop", "com.yourcompany", "com.example", "org.example", "com.mycompany",
        "org.qt-project", "com.plausiblelabs", "com.crashlytics", "io.fabric", "com.install4j", "com.squirrel",
        "com.trolltech", "org.pythonmac", "com.tauri", "org.tauri",
    ]

    /// 0.8.6: how many leading labels name the developer: 2 (org.scummvm),
    /// or 3 where the first two are shared by many (io.github.alice,
    /// com.electron.foo, uk.co.vendor, jp.co.vendor, co.jp.vendor).
    static func vendorLabelCount(_ labels: [String]) -> Int {
        guard labels.count >= 2 else { return labels.count }
        let first = labels[0], second = labels[1]
        if isHostNamespace(labels) || sharedPrefixes.contains(first + "." + second) { return 3 }
        // A country's second level: uk.co, jp.co, au.com, nz.org; co.jp, com.au.
        if first.count == 2 && secondLevel.contains(second) { return 3 }
        if secondLevel.contains(first) && second.count == 2 { return 3 }
        return 2
    }

    /// Two-letter country codes whose sites sit one level lower
    /// (example.co.uk, example.com.au).
    static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go"]

    /// The registrable domain of a host: "dl.saurik.com" → "saurik.com",
    /// "www.example.co.uk" → "example.co.uk".
    static func registrableDomain(_ host: String) -> [String] {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return parts }
        let n = parts.count >= 3 && parts.last!.count == 2 && secondLevel.contains(parts[parts.count - 2]) ? 3 : 2
        return Array(parts.suffix(n))
    }

    /// The vendor names a URL stands for, lower-cased: the registrable
    /// domain's label ("saurik"), or on a code host the owner ("bob" in
    /// github.com/bob/foo, bob.github.io, sourceforge.net/projects/bob,
    /// bob.sourceforge.net, git.sr.ht/~bob). A code host itself is never a
    /// vendor.
    public static func vendors(of url: String) -> [String] {
        guard let u = URL(string: url), let host = u.host?.lowercased(), !host.isEmpty else { return [] }
        let hostParts = host.split(separator: ".").map(String.init)
        let reg = registrableDomain(host)
        let regName = reg.joined(separator: ".")
        let path = u.path.split(separator: "/").map { String($0).lowercased() }
        func owner(_ s: String?) -> [String] {
            guard var s, !s.isEmpty else { return [] }
            if s.hasPrefix("~") { s.removeFirst() }
            return s.isEmpty ? [] : [s]
        }
        // code.google.com/p/<project>
        if host == "code.google.com" { return path.first == "p" ? owner(path.dropFirst().first) : [] }
        guard codeHosts.contains(regName) else {
            return reg.first.map { [$0] } ?? []
        }
        // A subdomain names the owner on pages hosts and
        // <project>.sourceforge.net / <project>.googlecode.com.
        let sub = hostParts.count > reg.count ? hostParts[hostParts.count - reg.count - 1] : nil
        let generic: Set<String> = ["www", "api", "raw", "objects", "codeload", "downloads", "download", "dl", "git",
                                    "release-assets", "github-releases", "media", "gist", "pages", "master", "svn"]
        switch regName {
        case "sourceforge.net", "sourceforge.io", "sf.net":
            if let s = sub, !generic.contains(s) { return [s] }
            // sourceforge.net/projects/<p>/..., downloads.sourceforge.net/project/<p>/...
            if let i = path.firstIndex(where: { $0 == "projects" || $0 == "project" || $0 == "p" }) {
                return owner(path.dropFirst(i + 1).first)
            }
            return []
        case "github.io", "gitlab.io", "bitbucket.io", "codeberg.page", "googlecode.com":
            if let s = sub, !generic.contains(s) { return [s] }
            return []
        case "githubusercontent.com":
            // raw.githubusercontent.com/<owner>/...; the release-asset hosts carry no owner.
            return sub == "raw" ? owner(path.first) : []
        default:
            if let s = sub, !generic.contains(s) { return [] }
            return owner(path.first)
        }
    }
}

/// `brew install --cask --adopt homebrew/cask/foo`.
public enum AdoptCommands {
    public static func arguments(qualifiedName: String) -> [String] {
        ["install", "--cask", "--adopt"] + BrewOperand.one(qualifiedName)
    }

    /// For "needs update first": what replacing the app with the cask's
    /// version would take. Shown to copy, never run by Tankard: it
    /// overwrites the app that is there.
    public static func replaceArguments(qualifiedName: String) -> [String] {
        ["install", "--cask", "--force"] + BrewOperand.one(qualifiedName)
    }
}
