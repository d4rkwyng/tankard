import Foundation
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
// the app is gone, puts the copy back.

/// What the plan sheet shows and the run uses.
public struct ReplaceAppPlan: Sendable, Equatable, Identifiable {
    public var token: String
    public var qualifiedName: String
    public var appName: String
    public var appPath: String
    public var bundleID: String?
    public var installedVersion: String
    public var caskVersion: String
    public var id: String { appPath }

    public init(token: String, qualifiedName: String, appName: String, appPath: String, bundleID: String?,
                installedVersion: String, caskVersion: String) {
        self.token = token
        self.qualifiedName = qualifiedName
        self.appName = appName
        self.appPath = appPath
        self.bundleID = bundleID
        self.installedVersion = installedVersion
        self.caskVersion = caskVersion
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
        /// brew finished, or failed before touching the app: the copy is deleted.
        case discarded
        /// brew failed and the app was gone: the copy is back in its place.
        case restored
        /// The copy couldn't be put back; it is still at this path.
        case restoreFailed(backup: String, error: String)
    }

    /// Copies the app aside. Returns the copy's path.
    public var backup: @Sendable (_ appPath: String) throws -> String
    /// After the run: `succeeded` is brew's exit.
    public var finish: @Sendable (_ appPath: String, _ backup: String, _ succeeded: Bool) -> Outcome

    public init(backup: @escaping @Sendable (String) throws -> String,
                finish: @escaping @Sendable (String, String, Bool) -> Outcome) {
        self.backup = backup
        self.finish = finish
    }

    /// The real one: ~/Library/Caches/net.mindtricks.tankard/replace-backup/<uuid>/<name>.app.
    public static func live(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("net.mindtricks.tankard/replace-backup")) -> AppReplaceSafety {
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
                return dest.path
            },
            finish: { appPath, backup, succeeded in
                finishLive(appPath: appPath, backup: backup, succeeded: succeeded)
            })
    }

    static func finishLive(appPath: String, backup: String, succeeded: Bool) -> Outcome {
        let fm = FileManager.default
        let dir = (backup as NSString).deletingLastPathComponent
        func pathOccupied(_ p: String) -> Bool { (try? fm.attributesOfItem(atPath: p)) != nil }
        if succeeded || pathOccupied(appPath) {
            try? fm.removeItem(atPath: dir)
            return .discarded
        }
        do {
            try fm.moveItem(atPath: backup, toPath: appPath)
            try? fm.removeItem(atPath: dir)
            return .restored
        } catch {
            return .restoreFailed(backup: backup, error: error.localizedDescription)
        }
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
            do {
                backup = try await Task.detached { try safety.backup(plan.appPath) }.value
            } catch {
                showBusyNotice(String(localized: "Tankard couldn't make a safety copy of \(plan.appName), so it didn't replace it: \(error.localizedDescription)"), seconds: 12)
                return false
            }
        }
        // Something took brew while copying.
        guard !isUpgrading, !autoUpdate.isRunning else {
            if let backup, let safety = deps.appReplaceSafety { _ = safety.finish(plan.appPath, backup, true) }
            showBusyNotice(Self.notStartedNotice(plan.command, running: quickAction, upgrading: true))
            return false
        }
        let package = plan.asPackage()
        startSession(.replaceApp, packages: [package])
        guard isUpgrading, upgrade?.action == .replaceApp else {
            if let backup, let safety = deps.appReplaceSafety { _ = safety.finish(plan.appPath, backup, true) }
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
            guard let backup = r.backup, let safety = deps.appReplaceSafety else {
                if !ok { session.addNote(String(localized: "\(r.plan.appName) wasn't replaced.")) }
                continue
            }
            switch safety.finish(r.plan.appPath, backup, ok) {
            case .discarded:
                if !ok { session.addNote(String(localized: "\(r.plan.appName) wasn't replaced; it is as it was.")) }
            case .restored:
                session.addNote(String(localized: "brew stopped after removing \(r.plan.appName); Tankard put the old version back at \(r.plan.appPath)."))
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
