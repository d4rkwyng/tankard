import Foundation
import os
import TankardCore

// 0.8.10: Adopt Apps' "Replace with Homebrew's Version". brew's --adopt
// refuses an app whose version differs from the cask's (moved.rb: "the
// existing app is different from the one being installed"). For an app
// OLDER than the cask (`AdoptReplace`), with a sure match
// (`AdoptStore.offersReplace`), Tankard offers `brew install --cask --force
// <token>`: brew deletes the app that is there and installs the cask's
// version in its place. Nothing in ~/Library is touched.
//
// The app must be closed: Tankard asks the user to quit it and checks again
// right before starting; it never quits or kills it. brew --force deletes
// the old app before moving the new one in and, when a later step fails,
// takes the new one away again (cask/installer.rb's revert), so a failure
// past that point would leave no app at all. So Tankard first copies the
// app aside (`AppReplaceSafety`; a clone on APFS) and, when brew fails and
// the app is gone or only partly there, puts the copy back. A run that
// reaches the end deletes the `.origin` record. At the next launch, copies
// still in the cache are only listed (one notice); nothing is moved.

/// What the plan sheet shows and the run uses.
public struct ReplaceAppPlan: Sendable, Equatable, Identifiable {
    public var token: String
    public var qualifiedName: String
    public var appName: String
    public var appPath: String
    public var bundleID: String?
    public var installedVersion: String
    public var caskVersion: String
    /// The app's CFBundleVersion at the scan (nil: none).
    public var bundleVersion: String?
    public var id: String { appPath }

    public init(token: String, qualifiedName: String, appName: String, appPath: String, bundleID: String?,
                installedVersion: String, caskVersion: String, bundleVersion: String? = nil) {
        self.token = token
        self.qualifiedName = qualifiedName
        self.appName = appName
        self.appPath = appPath
        self.bundleID = bundleID
        self.installedVersion = installedVersion
        self.caskVersion = caskVersion
        self.bundleVersion = bundleVersion
    }

    /// 0.8.10: why the app on disk, read again right before the copy, is no
    /// longer the one the plan was made for (nil: it still is). `now` nil:
    /// its Info.plist can't be read.
    public func changedNote(now: AppReplaceSafety.BundleInfo?) -> String? {
        guard let now else {
            return String(localized: "Tankard couldn't read \(appName)'s version at \(appPath), so it didn't replace it.")
        }
        func same(_ a: String?, _ b: String?) -> Bool {
            (a?.trimmingCharacters(in: .whitespaces) ?? "") == (b?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        let unchanged = same(now.shortVersion, installedVersion) && same(now.bundleVersion, bundleVersion)
            && (bundleID == nil || same(now.bundleID?.lowercased(), bundleID?.lowercased()))
        let still: Bool
        if case .update = AdoptReplace.eligibility(installed: now.shortVersion ?? "", cask: caskVersion,
                                                   bundleVersion: now.bundleVersion) {
            still = true
        } else {
            still = false
        }
        if unchanged && still { return nil }
        let v = now.shortVersion ?? now.bundleVersion ?? "?"
        return String(localized: "\(appName) changed since the scan (it is now version \(v)), so Tankard didn't replace it. Scan Again to see what Homebrew can do with it.")
    }

    public var arguments: [String] { AdoptCommands.replaceArguments(qualifiedName: qualifiedName) }
    public var command: String { BrewCommands.display(arguments) }

    /// The session row: the cask, as it will be once installed.
    public func asPackage() -> Package {
        var p = Package.command(token)
        p.id = "cask:\(qualifiedName)"
        p.kind = .cask
        p.name = token
        p.fullName = token
        p.tap = qualifiedName.split(separator: "/").count == 3 ? qualifiedName.split(separator: "/").prefix(2).joined(separator: "/") : nil
        p.status = .cask
        p.desc = appPath
        p.installedVersion = installedVersion
        p.currentVersion = caskVersion
        return p
    }

    /// Whether the app is open: the same path, or the same bundle id.
    public func isRunning(in running: [RunningApp]) -> Bool {
        let path = (appPath as NSString).standardizingPath
        let id = bundleID?.lowercased()
        return running.contains { r in
            if let p = r.path, (p as NSString).standardizingPath == path { return true }
            if let id, !id.isEmpty, r.bundleID?.lowercased() == id { return true }
            return false
        }
    }

    /// The sheet's lines, in order.
    public var planLines: [String] {
        [
            String(localized: "Homebrew downloads \(token) \(caskVersion) and puts it in place of the app at \(appPath)."),
            String(localized: "Your settings and data in ~/Library are not touched."),
            String(localized: "From now on Homebrew manages this app: brew upgrade updates it, and uninstalling the cask deletes it."),
            String(localized: "If brew fails, the app is left as it was."),
        ]
    }

    /// "Quit it first", while it is open.
    public var runningNote: String {
        String(localized: "\(appName) is open. Quit it first, then click Check Again. Tankard doesn't quit it for you.")
    }
}

/// The copy of the app kept while brew replaces it.
public struct AppReplaceSafety: Sendable {
    /// What happened to the app after the run.
    public enum Outcome: Sendable, Equatable {
        /// brew finished and the app at the path is the cask's version (or
        /// brew never started): the copy is deleted.
        case discarded
        /// brew failed and the app was gone: the copy is back in its place.
        case restored
        /// brew failed and left something at the path that isn't the app
        /// (a half-deleted bundle, another app): that was moved to
        /// `partial` and the copy put back.
        case restoredMovingAside(partial: String)
        /// brew failed (or its app isn't the cask's version) and the app at
        /// the path is whole: it stays, and so does the copy, at `backup`.
        case kept(backup: String)
        /// The copy couldn't be put back; it is still at this path.
        case restoreFailed(backup: String, error: String)
    }

    /// An app's Info.plist, as far as the replace checks need it.
    public struct BundleInfo: Sendable, Equatable {
        public var bundleID: String?
        public var shortVersion: String?
        public var bundleVersion: String?
        public init(bundleID: String?, shortVersion: String?, bundleVersion: String?) {
            self.bundleID = bundleID
            self.shortVersion = shortVersion
            self.bundleVersion = bundleVersion
        }
    }

    /// Copies the app aside. Returns the copy's path.
    public var backup: @Sendable (_ appPath: String) throws -> String
    /// After the run: `succeeded` is brew's exit, `caskVersion` the version
    /// the cask installs.
    public var finish: @Sendable (_ appPath: String, _ backup: String, _ succeeded: Bool, _ caskVersion: String) -> Outcome
    /// brew never started: the copy is deleted (the app wasn't touched).
    public var discard: @Sendable (_ backup: String) -> Void
    /// Copies an earlier run left behind (Tankard quit or crashed while brew
    /// ran, or a finished run kept the copy). Only listed: never moved or
    /// deleted. Each may be the only copy of the user's app.
    public var leftovers: @Sendable () -> [String]
    /// Reads the app's Info.plist (nil: it can't be read). nil: no check
    /// (tests, demo).
    public var readApp: (@Sendable (_ appPath: String) -> BundleInfo?)?

    public init(backup: @escaping @Sendable (String) throws -> String,
                finish: @escaping @Sendable (String, String, Bool, String) -> Outcome,
                discard: @escaping @Sendable (String) -> Void = { _ in },
                leftovers: @escaping @Sendable () -> [String] = { [] },
                readApp: (@Sendable (String) -> BundleInfo?)? = nil) {
        self.backup = backup
        self.finish = finish
        self.discard = discard
        self.leftovers = leftovers
        self.readApp = readApp
    }

    /// ~/Library/Caches/net.mindtricks.tankard/replace-backup
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("net.mindtricks.tankard/replace-backup")
    }

    /// Next to each copy: the path it was copied from. Deleted when the run
    /// reaches finishLive. A crash before that leaves the file; launch may
    /// log its text and never uses it as a path.
    static let originFile = ".origin"

    /// The copies under `root` (<uuid>/<name>.app), sorted. Reads only.
    public static func leftoverCopies(root: URL) -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [String] = []
        for d in dirs where !d.hasPrefix(".") {
            let dir = root.appendingPathComponent(d)
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            found += items.filter { !$0.hasPrefix(".") }.map { dir.appendingPathComponent($0).path }
        }
        return found.sorted()
    }

    /// The real one: ~/Library/Caches/net.mindtricks.tankard/replace-backup/<uuid>/<name>.app.
    public static func live(root: URL = AppReplaceSafety.defaultRoot) -> AppReplaceSafety {
        AppReplaceSafety(
            backup: { appPath in
                let fm = FileManager.default
                let dir = root.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent((appPath as NSString).lastPathComponent)
                do {
                    // copyfile clones on APFS: quick, and no extra space until one side changes.
                    try fm.copyItem(atPath: appPath, toPath: dest.path)
                } catch {
                    try? fm.removeItem(at: dir)
                    throw error
                }
                // Written once the copy is whole: a copy cut short by a
                // crash has no origin and is never put back by itself.
                try? Data(appPath.utf8).write(to: dir.appendingPathComponent(originFile))
                return dest.path
            },
            finish: { appPath, backup, succeeded, caskVersion in
                finishLive(appPath: appPath, backup: backup, succeeded: succeeded, caskVersion: caskVersion)
            },
            discard: { backup in
                try? FileManager.default.removeItem(atPath: (backup as NSString).deletingLastPathComponent)
            },
            leftovers: { leftoverCopies(root: root) },
            readApp: { info(at: $0) })
    }

    /// What is at a path, for deciding what to do with the copy.
    enum Found: Equatable {
        /// Nothing (not even a link).
        case nothing
        /// A whole bundle: Info.plist is a regular file, CFBundleExecutable
        /// is present, and Contents/MacOS/<exe> is a regular file inside the
        /// bundle (lstat, not a symlink).
        case bundle(BundleInfo, executable: String?)
        /// Anything else: a file, a link, a symlink Info.plist, a missing or
        /// linked executable, or an executable outside the bundle.
        case broken
    }

    static func found(at path: String) -> Found {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return .nothing }
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              regularFileInside(plistPath, bundle: path),
              let d = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return .broken }
        func str(_ k: String) -> String? {
            if let s = p[k] as? String { return s.trimmingCharacters(in: .whitespaces) }
            if let n = p[k] as? NSNumber { return n.stringValue }
            return nil
        }
        // Absent, empty, or not a single file name (a slash or ".." would
        // leave Contents/MacOS): not whole.
        guard let exe = str("CFBundleExecutable"), singlePathComponent(exe) else { return .broken }
        let exePath = (path as NSString).appendingPathComponent("Contents/MacOS/\(exe)")
        guard regularFileInside(exePath, bundle: path) else { return .broken }
        return .bundle(BundleInfo(bundleID: str("CFBundleIdentifier"), shortVersion: str("CFBundleShortVersionString"),
                                  bundleVersion: str("CFBundleVersion")), executable: exe)
    }

    /// One path component: the executable's file name, not a path.
    static func singlePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// `path` is a regular file (lstat, so a symlink does not count) and its
    /// real path stays inside `bundle` (a linked Contents or MacOS does not).
    static func regularFileInside(_ path: String, bundle: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        guard let file = canonicalPath(path), let root = canonicalPath(bundle) else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return file.hasPrefix(prefix)
    }

    static func canonicalPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func info(at path: String) -> BundleInfo? {
        if case .bundle(let i, _) = found(at: path) { return i }
        return nil
    }

    /// Whether `info` is the cask's version: its short version or its
    /// build number, as text or by brew's ordering ("2.1" and "2.1.0").
    static func isVersion(_ info: BundleInfo, _ caskVersion: String) -> Bool {
        let c = caskVersion.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return false }
        return [info.shortVersion, info.bundleVersion].contains { v in
            guard let v, !v.isEmpty else { return false }
            return v == c || BrewVersion(v).compare(to: BrewVersion(c)) == 0
        }
    }

    /// After the run. The copy is deleted only when brew's exit is 0, the
    /// app is whole, and its version matches the cask. Otherwise the copy
    /// is kept, unless it has been put back:
    /// - nothing at the path: the copy goes back;
    /// - a whole bundle of the same app (the same bundle id; after brew's
    ///   exit 0, any whole bundle that is not the cask's version): it stays,
    ///   and the copy is kept;
    /// - anything else (a bundle brew stopped deleting halfway, one without
    ///   its Info.plist or executable, a symlink plist or executable,
    ///   another app): that is moved into the copy's folder as
    ///   "<name>.partial" and the copy goes back.
    /// Every outcome deletes `.origin`. Only a crash before this runs still
    /// has one.
    static func finishLive(appPath: String, backup: String, succeeded: Bool, caskVersion: String) -> Outcome {
        let fm = FileManager.default
        let dir = (backup as NSString).deletingLastPathComponent
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(originFile))
        let now = found(at: appPath)
        if succeeded, case .bundle(let i, _) = now, isVersion(i, caskVersion) {
            try? fm.removeItem(atPath: dir)
            return .discarded
        }
        var partial: String?
        switch now {
        case .nothing:
            break
        case .bundle(let i, let exe):
            // brew's exit 0 with a whole bundle, but not the cask's
            // version: both stay.
            if succeeded { return .kept(backup: backup) }
            // The copy itself isn't a whole bundle: nothing better to put back.
            guard case .bundle(let o, let oExe) = found(at: backup) else { return .kept(backup: backup) }
            if (i.bundleID ?? "").lowercased() == (o.bundleID ?? "").lowercased(), exe != nil || oExe == nil {
                return .kept(backup: backup)
            }
            fallthrough
        case .broken:
            let name = (appPath as NSString).lastPathComponent
            var dest = (dir as NSString).appendingPathComponent("\(name).partial")
            var n = 2
            while (try? fm.attributesOfItem(atPath: dest)) != nil {
                dest = (dir as NSString).appendingPathComponent("\(name).partial-\(n)")
                n += 1
            }
            do {
                try fm.moveItem(atPath: appPath, toPath: dest)
            } catch {
                return .restoreFailed(backup: backup, error: error.localizedDescription)
            }
            partial = dest
        }
        do {
            try fm.moveItem(atPath: backup, toPath: appPath)
        } catch {
            return .restoreFailed(backup: backup, error: error.localizedDescription)
        }
        if let partial { return .restoredMovingAside(partial: partial) }
        try? fm.removeItem(atPath: dir)
        return .restored
    }

    /// One leftover, for the launch log and the notice. `recordedPath` is
    /// the text of `.origin` when it reads as text. Display only: never a
    /// path for a move, a delete, or Show in Finder.
    struct DescribedLeftover: Sendable, Equatable {
        var path: String
        var appName: String
        var made: Date
        var recordedPath: String?
    }

    static func describe(_ path: String) -> DescribedLeftover {
        let fm = FileManager.default
        let base = (path as NSString).lastPathComponent
        let appName = base.lowercased().hasSuffix(".app") && base.count > 4 ? String(base.dropLast(4)) : base
        let dir = (path as NSString).deletingLastPathComponent
        let made = directoryDate(dir) ?? directoryDate(path) ?? Date()
        var recorded: String?
        if let data = fm.contents(atPath: (dir as NSString).appendingPathComponent(originFile)),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { recorded = String(trimmed.prefix(500)) }
        }
        return DescribedLeftover(path: path, appName: appName.isEmpty ? base : appName, made: made, recordedPath: recorded)
    }

    static func directoryDate(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
    }
}

/// One launch notice for safety copies an earlier Replace left behind.
/// `paths` are the copies themselves (the backup folder's listing), never
/// a path read from `.origin`.
public struct ReplaceLeftoverNotice: Equatable, Sendable {
    public var message: String
    public var paths: [String]
    public init(message: String, paths: [String]) {
        self.message = message
        self.paths = paths
    }
}

private let replaceLog = Logger(subsystem: AppPaths.bundleID, category: "replace")

extension AppStore {
    /// At launch: copies a run left behind are logged, with their paths, and
    /// one notice is shown. Nothing is moved or deleted. `.origin`, when a
    /// crash mid-run left one, is read for the log only. Returns the copy
    /// paths (tests).
    @discardableResult
    func noteReplaceLeftovers() async -> [String] {
        guard let safety = deps.appReplaceSafety else { return [] }
        let found = await Task.detached { safety.leftovers().map { AppReplaceSafety.describe($0) } }.value
        for item in found {
            if let recorded = item.recordedPath {
                replaceLog.notice("Replace with Homebrew's Version: an earlier run left a safety copy of \(item.appName, privacy: .public) at \(item.path, privacy: .public); recorded path \(recorded, privacy: .public) is display only; kept, not moved or deleted")
            } else {
                replaceLog.notice("Replace with Homebrew's Version: an earlier run left a safety copy of \(item.appName, privacy: .public) at \(item.path, privacy: .public); kept, not moved or deleted")
            }
        }
        if let newest = found.max(by: { $0.made < $1.made }) {
            let when = newest.made.formatted(date: .abbreviated, time: .shortened)
            let name = newest.appName
            replaceLeftoverNotice = ReplaceLeftoverNotice(
                message: String(localized: "Tankard kept a safety copy of \(name) from \(when)."),
                paths: found.map(\.path))
        }
        return found.map(\.path)
    }

    /// The launch notice's close. The copies stay where they are.
    public func dismissReplaceLeftoverNotice() {
        replaceLeftoverNotice = nil
    }
}

public extension AppStore {
    /// The row's "Replace with Homebrew's Version…": the plan sheet.
    func requestReplace(_ row: AdoptRow) {
        guard let plan = adopt.replacePlan(row), !isBusy else { return }
        if adopt.pendingReplace != plan { adopt.pendingReplace = plan }
        refreshReplaceRunning()
    }

    /// Whether the plan's app is open now.
    func replaceAppIsRunning(_ plan: ReplaceAppPlan) -> Bool {
        plan.isRunning(in: autoUpdate.conditions.runningApps())
    }

    /// The sheet's Check Again (and the check right before starting).
    func refreshReplaceRunning() {
        let open = adopt.pendingReplace.map(replaceAppIsRunning) ?? false
        if adopt.replaceAppOpen != open { adopt.replaceAppOpen = open }
    }

    func cancelReplace() {
        if adopt.pendingReplace != nil { adopt.pendingReplace = nil }
        if adopt.replaceAppOpen { adopt.replaceAppOpen = false }
    }

    /// The plan sheet's Replace: checks again that the app is closed, then
    /// closes the sheets, copies the app aside and runs brew through the
    /// queue and the activity sheet. Returns false when it stayed (the app
    /// is open).
    @discardableResult
    func confirmReplace() -> Bool {
        guard let plan = adopt.pendingReplace else { return false }
        refreshReplaceRunning()
        guard !adopt.replaceAppOpen else { return false }
        adopt.pendingReplace = nil
        closeToolSheet()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            await self.startReplace(plan)
        }
        return true
    }

    /// The run itself, without the sheets (scripted runs, tests). Returns
    /// false when it didn't start.
    @discardableResult
    func startReplace(_ plan: ReplaceAppPlan) async -> Bool {
        guard !isUpgrading, !autoUpdate.isRunning, report != nil else {
            showBusyNotice(Self.notStartedNotice(plan.command, running: quickAction,
                                                 upgrading: isUpgrading || autoUpdate.isRunning))
            return false
        }
        // Opened again in the meantime: don't start.
        if replaceAppIsRunning(plan) {
            showBusyNotice(plan.runningNote)
            return false
        }
        var backup: String?
        if let safety = deps.appReplaceSafety {
            // 0.8.10: the app on disk, read again: it may have updated
            // itself since the scan (the copy would then be the newer one,
            // and brew would put the older cask in its place).
            if let read = safety.readApp {
                let now = await Task.detached { read(plan.appPath) }.value
                if let note = plan.changedNote(now: now) {
                    showBusyNotice(note, seconds: 12)
                    return false
                }
            }
            do {
                backup = try await Task.detached { try safety.backup(plan.appPath) }.value
            } catch {
                showBusyNotice(String(localized: "Tankard couldn't make a safety copy of \(plan.appName), so it didn't replace it: \(error.localizedDescription)"), seconds: 12)
                return false
            }
        }
        // 0.8.10: opened while the copy was made: brew would delete a
        // running app. Checked again right before brew starts.
        if replaceAppIsRunning(plan) {
            if let backup, let safety = deps.appReplaceSafety { safety.discard(backup) }
            showBusyNotice(plan.runningNote)
            return false
        }
        // Something took brew while copying.
        guard !isUpgrading, !autoUpdate.isRunning else {
            if let backup, let safety = deps.appReplaceSafety { safety.discard(backup) }
            showBusyNotice(Self.notStartedNotice(plan.command, running: quickAction, upgrading: true))
            return false
        }
        let package = plan.asPackage()
        startSession(.replaceApp, packages: [package])
        guard isUpgrading, upgrade?.action == .replaceApp else {
            if let backup, let safety = deps.appReplaceSafety { safety.discard(backup) }
            showBusyNotice(Self.notStartedNotice(plan.command, running: quickAction, upgrading: false))
            return false
        }
        replaceBackups[package.id] = ReplaceBackup(plan: plan, backup: backup)
        return true
    }

    /// After the run: the copy is deleted, or put back when brew failed and
    /// the app is gone. The log says which.
    internal func replaceSessionFinished(_ session: UpgradeSession) {
        let pending = replaceBackups
        replaceBackups = [:]
        for item in session.items {
            guard let r = pending[item.package.id] else { continue }
            let ok = item.state == .done
            if session.failureKindByItem[item.id] == .locked {
                // Brew printed its lock error and exited. It had not changed
                // the app. The copy is kept because the run failed (below).
                session.addNote(String(localized: "Homebrew is busy; try again in a moment."))
            }
            guard let backup = r.backup, let safety = deps.appReplaceSafety else {
                if !ok { session.addNote(String(localized: "\(r.plan.appName) wasn't replaced.")) }
                continue
            }
            switch safety.finish(r.plan.appPath, backup, ok, r.plan.caskVersion) {
            case .discarded:
                if !ok { session.addNote(String(localized: "\(r.plan.appName) wasn't replaced; it is as it was.")) }
            case .restored:
                session.addNote(String(localized: "brew stopped after removing \(r.plan.appName); Tankard put the old version back at \(r.plan.appPath)."))
            case .restoredMovingAside(let partial):
                session.addNote(String(localized: "brew stopped partway through replacing \(r.plan.appName); Tankard put the old version back at \(r.plan.appPath). What brew left there is at \(partial)."))
            case .kept(let copy):
                session.addNote(ok
                    ? String(localized: "The app at \(r.plan.appPath) isn't \(r.plan.appName) \(r.plan.caskVersion), so Tankard kept the copy of the old version at \(copy).")
                    : String(localized: "\(r.plan.appName) wasn't replaced; it is as it was. Tankard kept a copy of it at \(copy)."))
            case .restoreFailed(let copy, let error):
                session.addNote(String(localized: "Tankard couldn't put \(r.plan.appName) back (\(error)). A copy of the old version is at \(copy)."))
            }
        }
    }
}

/// A running replacement's safety copy.
struct ReplaceBackup: Sendable {
    var plan: ReplaceAppPlan
    /// nil: no copy (tests, demo).
    var backup: String?
}
