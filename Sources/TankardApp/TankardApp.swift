import AppKit
import os
import SwiftUI
import TankardAppModel
import TankardCore

/// Launch options read from the environment. Demo and snapshot switches
/// exist for screenshots and testing; a normal launch sets none of them.
struct LaunchOptions {
    var demo: Demo.Variant?
    var demoPace: Double = 1
    var select: String?
    var demoUpgrade = false
    var appearance: AppTheme?
    var snapshot: SnapshotRequest?
    /// TANKARD_TAB=discover: open on Discover.
    var tab: MainTab = .installed
    /// TANKARD_DISCOVER=<query>: search Discover on launch.
    var discoverQuery: String?
    /// 0.8.3: TANKARD_SEARCH: the Installed search field's text at launch
    /// (shots of the "Search Discover for" empty state).
    var search: String?
    /// TANKARD_DISCOVER_SELECT=<name>: select a Discover row.
    var discoverSelect: String?
    /// Demo only: TANKARD_DEMO_INSTALL=1 installs the Discover selection.
    var demoInstall = false
    /// Demo only: TANKARD_DEMO_UNINSTALL=<name> opens the uninstall confirmation.
    var demoUninstall: String?
    /// TANKARD_DEMO_NOBREW=intel|arm64: the welcome screen, as on that Mac.
    var noBrew: MacHardware?
    /// 0.3, demo only: TANKARD_DEMO_UPGRADE=plan opens the upgrade sheet on
    /// its plan page (compile warnings); =1 still starts at once.
    var demoPlan = false
    /// 0.3: TANKARD_FILTER=upgrades|source|newer|bottle: the Installed filter.
    var filter: PackageFilter?
    /// 0.3, demo only: TANKARD_DEMO_CLEANUP=1 opens the Cleanup sheet;
    /// TANKARD_DEMO_CLEANUP_RUN=1 then clicks Clean up.
    var demoCleanup = false
    var demoCleanupRun = false
    /// 0.3, demo only: TANKARD_DEMO_APPMGMT=1 shows the App Management
    /// sheet; =fail makes cask upgrades and uninstalls fail once with the block.
    var demoAppManagement: String?
    /// 0.3, demo only: TANKARD_DEMO_REPLACE=1 replaces the selection with a bottle.
    var demoReplace = false
    /// 0.3: TANKARD_DISCOVER_ALL=1 turns the Discover bottle chip off.
    var discoverAll = false
    /// 0.3, demo only: TANKARD_DEMO_INSTALL_CONFIRM=1 opens the "Install
    /// (compiles)" confirmation for the Discover selection.
    var demoInstallConfirm = false
    /// TANKARD_SWITCH_APPEARANCE=<theme>@<seconds>: switch theme at runtime,
    /// as Settings does (not saved), to test a live switch.
    var switchAppearance: (AppTheme, Double)?
    /// TANKARD_RESELECT=<name>@<seconds>: select another row later, as a click would.
    var reselect: (String, Double)?
    /// 0.4, demo only: TANKARD_DEMO_NOTES=1 upgrades everything, closes the
    /// finished sheet, and the post-install notes follow.
    var demoNotes = false
    /// 0.4, demo only: TANKARD_DEMO_VULN_NOTICE=1 turns the menu-bar
    /// vulnerability notice on with an empty baseline (everything is new).
    var demoVulnNotice = false
    /// 0.4, demo only: TANKARD_SELF_UPDATING=1 turns "Include self-updating apps" on.
    var demoSelfUpdating = false
    /// 0.5, demo only: TANKARD_DEMO_AUTOUPDATE=1 turns auto-update on with
    /// sample runs in its log; =run also runs it once through the fake brew.
    var demoAutoUpdate: String?
    /// 0.6, demo only: TANKARD_DEMO_SHEET=health|history|autoremove opens that sheet.
    var demoSheet: ToolSheet?
    /// 0.8.3, demo only: TANKARD_DEMO_MENUBAR_SHOW=<package>|upgrades|vulnerable:
    /// after launch, what a click on that menu-bar panel line does.
    var demoMenuBarShow: String?
    /// 0.8: TANKARD_E2E=1 + TANKARD_SCRIPT=<file>: run a scripted session
    /// (ScriptLaunch.swift, Scripts/e2e.sh).
    var script: ScriptLaunch?

    var isDemo: Bool { demo != nil || noBrew != nil }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        var o = LaunchOptions()
        o.demo = Demo.Variant(environmentValue: env["TANKARD_DEMO"])
        // Selecting a row at launch is harmless, so it works in any mode
        // (for screenshots of real data).
        o.select = env["TANKARD_SELECT"]
        if o.demo != nil {
            o.demoPace = env["TANKARD_DEMO_PACE"].flatMap(Double.init) ?? 1
            o.demoUpgrade = env["TANKARD_DEMO_UPGRADE"] == "1"
            o.demoInstall = env["TANKARD_DEMO_INSTALL"] == "1"
            o.demoUninstall = env["TANKARD_DEMO_UNINSTALL"].flatMap { $0.isEmpty ? nil : $0 }
            o.demoPlan = env["TANKARD_DEMO_UPGRADE"] == "plan"
            o.demoCleanup = env["TANKARD_DEMO_CLEANUP"] == "1"
            o.demoCleanupRun = env["TANKARD_DEMO_CLEANUP_RUN"] == "1"
            o.demoAppManagement = env["TANKARD_DEMO_APPMGMT"].flatMap { $0.isEmpty ? nil : $0 }
            o.demoReplace = env["TANKARD_DEMO_REPLACE"] == "1"
            o.demoInstallConfirm = env["TANKARD_DEMO_INSTALL_CONFIRM"] == "1"
            o.demoNotes = env["TANKARD_DEMO_NOTES"] == "1"
            o.demoVulnNotice = env["TANKARD_DEMO_VULN_NOTICE"] == "1"
            o.demoSelfUpdating = env["TANKARD_SELF_UPDATING"] == "1"
            o.demoSheet = env["TANKARD_DEMO_SHEET"].flatMap { ToolSheet(rawValue: $0.lowercased()) }
            o.demoMenuBarShow = env["TANKARD_DEMO_MENUBAR_SHOW"].flatMap { $0.isEmpty ? nil : $0 }
            o.demoAutoUpdate = env["TANKARD_DEMO_AUTOUPDATE"].flatMap { $0.isEmpty || $0 == "0" ? nil : $0.lowercased() }
        }
        switch env["TANKARD_FILTER"]?.lowercased() {
        case "upgrades": o.filter = .upgrades
        case "source": o.filter = .source
        case "newer": o.filter = .newer
        case "bottle", "bottleavailable": o.filter = .bottleAvailable
        case "vulnerable": o.filter = .vulnerable
        case "notes", "hasnotes": o.filter = .hasNotes
        case "deprecated": o.filter = .deprecated
        default: break
        }
        o.discoverAll = env["TANKARD_DISCOVER_ALL"] == "1"
        switch env["TANKARD_DEMO_NOBREW"]?.lowercased() {
        case "intel": o.noBrew = .intel
        case "arm64", "applesilicon": o.noBrew = .appleSilicon
        default: break
        }
        o.appearance = AppTheme(name: env["TANKARD_APPEARANCE"])
        o.tab = env["TANKARD_TAB"]?.lowercased() == "discover" ? .discover : .installed
        o.discoverQuery = env["TANKARD_DISCOVER"].flatMap { $0.isEmpty ? nil : $0 }
        o.search = env["TANKARD_SEARCH"].flatMap { $0.isEmpty ? nil : $0 }
        if o.discoverQuery != nil { o.tab = .discover }
        o.discoverSelect = env["TANKARD_DISCOVER_SELECT"]
        o.snapshot = SnapshotRequest(environment: env)
        o.script = ScriptLaunch(environment: env)
        func timed(_ v: String?) -> (String, Double)? {
            guard let parts = v?.split(separator: "@"), parts.count == 2, let t = Double(parts[1]) else { return nil }
            return (String(parts[0]), t)
        }
        // Test hooks for layout-check.sh: only in demo or snapshot runs, never in a
        // real session.
        if o.isDemo || o.snapshot != nil {
            if let (name, t) = timed(env["TANKARD_SWITCH_APPEARANCE"]), let theme = AppTheme(name: name) {
                o.switchAppearance = (theme, t)
            }
            o.reselect = timed(env["TANKARD_RESELECT"])
        }
        return o
    }
}

@main
struct TankardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // One store for the app's life. A plain `let`: `@State` is a macro in
    // the macOS 27 SDK and its plugin isn't in the Command Line Tools, and
    // SwiftUI creates the App struct once.
    private let store: AppStore
    private let options: LaunchOptions
    private let appearance: AppearanceSettings
    private let settings: AppSettings
    private let notifier: SystemNotifier
    private let loginItem: LoginItem
    private let checker: BackgroundChecker

    init() {
        let options = LaunchOptions.fromEnvironment()
        self.options = options
        let env = ProcessInfo.processInfo.environment
        // 0.8.3: one Tankard at a time (a demo, snapshot or script run is a
        // dev instance tests run side by side: no guard, and never counted).
        // A same-build second launch quits here, before any window.
        if !SingleInstance.isDevRun(environment: env) { InstanceGuard.check() }
        // The self-update e2e: its throwaway tap's cask counts as Tankard's own.
        if options.script != nil { SelfInstall.e2eTap = SelfInstall.validE2ETap(env["TANKARD_E2E_SELF_TAP"]) }
        var deps: AppStore.Dependencies
        if let hw = options.noBrew {
            deps = Demo.noBrewDependencies(hardware: hw)
        } else {
            deps = options.demo.map {
                Demo.dependencies($0, pace: options.demoPace, failAppManagement: options.demoAppManagement == "fail",
                                  pinned: V04ALaunch.demoPinned(), replaced: V04ALaunch.demoReplaced())
            } ?? options.script.map { $0.dependencies(.live()) } ?? .live()
            if options.demo != nil { AppStore.profileReader = Demo.demoProfile }
        }
        // 0.8.1: Relaunch Tankard (App Management): the real app only, from
        // its bundle. The demo of the relaunch page gets a button that does nothing.
        // 0.8.3: also the "Tankard was upgraded" alert's Relaunch; and the
        // self-update e2e (a script run that acts as the real app).
        if !SingleInstance.isDevRun(environment: env) && options.noBrew == nil
            && AppManagement.canRelaunch(bundlePath: Bundle.main.bundlePath) {
            deps.relaunch = { Relauncher.relaunch() }
        } else if options.demoAppManagement == "relaunch" {
            deps.relaunch = { false }
        }
        // 0.8: no background brew update in a snapshot run (a shot of real
        // data must not change under it). Demo dependencies never have it.
        if options.snapshot != nil { deps.backgroundUpdates = false }
        // Check for Tankard Updates…: a file instead of GitHub (e2e, shots);
        // demo mode has no feed otherwise, so the item is disabled there.
        if let feed = env["TANKARD_UPDATE_FEED"], !feed.isEmpty { deps.updateFeed = .file(feed) }
        if options.demo != nil, env["TANKARD_UPDATE_BREW"] == "1" {
            deps.selfCaskOverride = AppStore.demoTankardCask(bundlePath: Bundle.main.bundlePath)
        }
        // Demo runs never touch the real settings.
        // A script run keeps its own settings suite (ScriptLaunch.swift).
        let settings = options.isDemo || options.snapshot != nil ? AppSettings.ephemeral()
            : options.script.map { AppSettings(defaults: $0.defaults) } ?? AppSettings()
        if let v = ProcessInfo.processInfo.environment["TANKARD_MENUBAR"] { settings.showMenuBarIcon = v != "0" }
        // Demo of the failure path: skip the first-use explainer so the run
        // reaches the block (and the sheet that follows it).
        if options.demoAppManagement == "fail" { settings.appManagementExplained = true }
        self.settings = settings
        store = AppStore(deps: deps, settings: settings)
        let relaunchStore = store
        Relauncher.onGaveUp = { relaunchStore.relaunchGaveUp() }
        if options.demoSelfUpdating { store.insights.settings.includeSelfUpdatingApps = true }
        // 0.5: the real power, idle and running-app checks. Demo runs keep
        // the default (never on AC), so nothing runs unless asked for.
        if !options.isDemo && options.snapshot == nil && options.script == nil {
            store.autoUpdate.conditions = SystemConditions()
            // 0.8.3: re-read the real brew.env files at each check (the pause rule).
            store.autoUpdate.brewEnvFiles = { EnvironmentSources.load(prefix: $0.installation.prefix).brewEnvFiles }
        }
        // The demo's scan is a fixture (no network), so it shows what a scan
        // finds; a real session scans on refresh only once the user opts in.
        // TANKARD_DEMO_SCAN=off: no scan at all, to show "not scanned yet".
        if options.demo != nil && ProcessInfo.processInfo.environment["TANKARD_DEMO_SCAN"] != "off" {
            store.insights.settings.scanVulnerabilitiesOnRefresh = true
        }
        appearance = AppearanceSettings(defaults: options.script.map { $0.defaults } ?? .standard, override: options.appearance)
        notifier = SystemNotifier()
        loginItem = LoginItem()
        checker = BackgroundChecker(store: store, settings: settings, notifier: notifier)
        store.notifier = notifier
        NotificationActions.store = store
        SystemNotifier.install()
        AppDelegate.initialTheme = appearance.theme
        AppDelegate.settings = settings
        QuitGuard.store = store
        AppDelegate.dock = DockIconController(settings: settings)
        let checker = self.checker
        AppDelegate.onLaunch = { if !options.isDemo && (options.script == nil || options.script?.background == true) { checker.start() } }
        appearance.onChange = { theme in applyAppearance(theme) }
        if let (theme, delay) = options.switchAppearance {
            let a = appearance
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { a.preview(theme) }
        }
    }

    // App.body must stay pure: it reads no @Observable state that changes
    // (store, settings) and writes none. Anything it reads is tracked, and a
    // change re-runs it and rebuilds every scene, so the menu items that
    // follow the store live in views (ViewCommands below), and the menu-bar
    // binding never writes an unchanged value (see AppSettings.showMenuBarIcon).
    // 0.3.0 broke this and crashed at launch; Scripts/launch-check.sh guards it.
    var body: some Scene {
        WindowGroup(options.isDemo ? String(localized: "Tankard (demo)") : "Tankard", id: "main") {
            ContentView(store: store, options: options, appearance: appearance)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Tankard") { AboutPanel.show(intelbrew: store.intelbrewMode) }
                CheckForUpdatesMenuItem(store: store)
            }
            // File: Tankard's files are Brewfiles (export one, check one).
            // No New Window: Tankard has one main window.
            CommandGroup(replacing: .newItem) {
                BrewfileMenuItems(store: store)
            }
            // View: only what changes how the window shows content (the
            // tabs). Actions that run brew are in the Homebrew menu.
            CommandGroup(before: .toolbar) {
                ViewCommands(store: store)
            }
            CommandMenu("Homebrew") {
                HomebrewCommands(store: store)
            }
            CommandGroup(replacing: .help) {
                Button("Tankard Help") { NSWorkspace.shared.open(AboutInfo.help) }
                Divider()
                Button("Tankard on GitHub") { NSWorkspace.shared.open(AboutInfo.repository) }
                Button("Report an Issue…") { NSWorkspace.shared.open(AboutInfo.newIssue) }
            }
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarPanel(store: store, appearance: appearance)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appearance: appearance, settings: settings, notifier: notifier, loginItem: loginItem,
                         insightSettings: store.insights.settings, autoUpdater: store.autoUpdate, store: store,
                         rollbackSettings: store.restorePoints.settings)
        }
    }
}

extension TankardApp {
    /// SwiftUI writes this binding back while it builds the scenes, often
    /// with the value it already has; only a real change reaches the setting.
    private var menuBarInserted: Binding<Bool> {
        let settings = settings
        return Binding(get: { settings.showMenuBarIcon },
                       set: { if settings.showMenuBarIcon != $0 { settings.showMenuBarIcon = $0 } })
    }
}

/// View menu items: the tabs. A view, so the store reads are tracked here
/// and not in App.body.
struct ViewCommands: View {
    var store: AppStore

    var body: some View {
        Button("Installed") { store.tab = .installed }
            .keyboardShortcut("1", modifiers: .command)
        Button("Discover") { store.tab = .discover }
            .keyboardShortcut("2", modifiers: .command)
        Button("Services") { store.tab = .services }
            .keyboardShortcut("3", modifiers: .command)
    }
}

/// The Homebrew menu, in groups from most to least used, Revert and
/// Uninstall Homebrew last. A view for the same reason as ViewCommands:
/// items grey out while brew runs and Revert shows only in Intelbrew mode,
/// and those store reads must not be tracked by App.body.
struct HomebrewCommands: View {
    var store: AppStore

    var body: some View {
        // Check: the toolbar's Refresh, and the scan on demand (0.6.1).
        Button("Refresh") { Task { await store.refreshFromUser(windowInFront: { MainWindowState.inFront }) } }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || store.isUpgrading)
        Button("Scan for Vulnerabilities") { store.scanVulnerabilitiesNow() }
            .disabled(store.insights.scanState == .running || store.report == nil)
        Divider()
        // Look: what brew says about this Mac, and what Tankard ran.
        HealthCommands(store: store)
        Divider()
        // Free space: old versions and caches, then unused dependencies.
        Button("Clean Up…") { store.openCleanup() }
            .disabled(store.isBusy || store.report == nil)
        Button("Remove Unused Dependencies…") { store.openAutoremove() }
            .disabled(store.isBusy || store.report == nil)
        Divider()
        // Manage: where packages come from, adopting apps, rolling back.
        TapsCommands(store: store)
        AdoptMenuCommands(store: store)
        RestorePointsMenuItem(store: store)
        Divider()
        // Revert exists only in Intelbrew mode.
        if store.intelbrewMode {
            Button(HomebrewManagement.Kind.revert.title) { store.requestManagement(.revert) }
                .disabled(store.isBusy || store.report == nil)
        }
        Button(HomebrewManagement.Kind.uninstall.title) { store.requestManagement(.uninstall) }
            .disabled(store.isBusy || store.report == nil)
    }
}

/// The menu-bar panel with "Open Tankard" wired to the main window.
struct MenuBarPanel: View {
    var store: AppStore
    var appearance: AppearanceSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContent(store: store, openMain: openMain, openAutoUpdateLog: {
            openMain()
            store.showAutoUpdateLog = true
        })
            .themed(Theme.of(appearance.theme))
    }

    private func openMain() {
        // 0.8.1: back to a Dock icon before the window shows.
        AppDelegate.dock?.prepareToShowWindow()
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// 0.8.1: quit and start again (App Management applies to a new process).
/// 0.8.3: also the self-upgrade's Relaunch (it replaces 0.8.2's
/// `Relaunch.now()`, which opened the new copy first, then quit in an
/// NSWorkspace completion handler: that closure was main-actor isolated,
/// LaunchServices calls it on its own queue, and Swift's runtime isolation
/// check trapped, so the old copy crashed with the new one already open).
/// RelaunchSequence (TankardAppModel/SingleInstance.swift) is the order.
@MainActor
enum Relauncher {
    private static let log = Logger(subsystem: AppPaths.bundleID, category: "relaunch")
    /// Still running after the retry: the store says to quit and reopen.
    static var onGaveUp: (@MainActor () -> Void)?

    /// Starts the helper, closes every sheet, then quits on the next turn
    /// of the run loop (so the caller can save first). False: the helper
    /// didn't start; Tankard keeps running.
    static func relaunch() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sequence = RelaunchSequence(
            startHelper: { startHelper(pid: pid) },
            closeSheets: closeSheets,
            terminate: {
                log.notice("relaunch: terminate pid \(pid, privacy: .public)")
                QuitGuard.exempt = true
                NSApp.terminate(nil)
            },
            after: { delay, work in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    work()
                }
            },
            gaveUp: {
                log.error("relaunch: pid \(pid, privacy: .public) is still running after two terminate attempts; the helper opens nothing")
                FileHandle.standardError.write(Data("relaunch: gave up, still running\n".utf8))
                onGaveUp?()
            })
        return sequence.run()
    }

    private static func startHelper(pid: Int32) -> Bool {
        let c = AppManagement.relaunchCommand(bundlePath: Bundle.main.bundlePath, pid: pid)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.executable)
        p.arguments = c.arguments
        do {
            try p.run()
        } catch {
            log.error("relaunch: helper didn't start: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return false
        }
        log.notice("relaunch: helper \(p.processIdentifier, privacy: .public) waits for pid \(pid, privacy: .public)")
        return true
    }

    /// AppKit won't terminate while a sheet is up ("App termination blocked
    /// by modal sheet"): end every window's sheets, and any modal session.
    static func closeSheets() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        for w in NSApp.windows {
            var n = 0
            while let sheet = w.attachedSheet, n < 8 {
                w.endSheet(sheet)
                sheet.orderOut(nil)
                n += 1
            }
        }
    }
}

/// 0.8.3: one Tankard at a time (SingleInstance in TankardAppModel decides).
/// A same-build second launch (`open -n`, a second copy of the bundle)
/// brings the running one forward and quits. A copy that launched before
/// this app's executable was written runs a bundle Homebrew has replaced
/// (0.8.2's Relaunch opened the new copy before quitting): it is asked to
/// quit, never forced (it may be in the middle of a brew command), and this
/// copy carries on. The relaunch helper opens the new copy only after the
/// old pid has exited, so it never meets the guard.
@MainActor
enum InstanceGuard {
    private static let log = Logger(subsystem: AppPaths.bundleID, category: "instance")
    private static var stale: [NSRunningApplication] = []

    static func note(_ s: String) {
        log.notice("\(s, privacy: .public)")
        FileHandle.standardError.write(Data("instance: \(s)\n".utf8))
    }

    static func check() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard !apps.isEmpty else { return }
        let others = apps.map { a in
            SingleInstance.Other(pid: a.processIdentifier,
                                 launchDate: a.launchDate ?? SingleInstance.startDate(pid: a.processIdentifier),
                                 isDevRun: SingleInstance.environment(pid: a.processIdentifier).map(SingleInstance.isDevRun) ?? false,
                                 samePath: SingleInstance.samePath(a.bundleURL, Bundle.main.bundleURL))
        }
        let written = Bundle.main.executablePath.flatMap(SingleInstance.writtenDate)
        let decision = SingleInstance.decide(others: others, executableWritten: written)
        note("pid \(me): others \(others.map { "\($0.pid)\($0.isDevRun ? "(dev)" : "")\($0.samePath ? "" : "(other path)") launched \($0.launchDate.map { "\($0)" } ?? "?")" }.joined(separator: ", ")); executable written \(written.map { "\($0)" } ?? "?"); \(decision)")
        switch decision {
        case .proceed:
            return
        case .yield(let pid):
            if let a = apps.first(where: { $0.processIdentifier == pid }) {
                a.unhide()
                a.activate(options: [.activateAllWindows])
            }
            exit(0)
        case .replaceStale(let pids):
            stale = apps.filter { pids.contains($0.processIdentifier) }
            for a in stale { _ = a.terminate() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(SingleInstance.staleGrace))
                alertIfStillRunning()
            }
        }
    }

    /// One alert while a stale copy refuses to quit (a sheet is up in it).
    /// It closes itself once every stale copy has gone; its button asks
    /// them to quit again and brings them forward so the user can close the sheet.
    private static func alertIfStillRunning() {
        let left = stale.filter { !$0.isTerminated }
        guard !left.isEmpty else {
            note("stale copies quit: \(stale.map(\.processIdentifier))")
            return
        }
        note("stale copies still running after \(Int(SingleInstance.staleGrace)) s: \(left.map(\.processIdentifier)); alert")
        let alert = NSAlert()
        alert.messageText = SingleInstance.staleAlertMessage
        alert.addButton(withTitle: SingleInstance.staleAlertButton)
        // Fires on the main run loop (modal panel mode), so assumeIsolated
        // holds; the closure itself is @Sendable, never main-actor isolated.
        let timer = Timer(timeInterval: 0.5, repeats: true) { @Sendable _ in
            MainActor.assumeIsolated {
                if stale.allSatisfy(\.isTerminated) { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        if response == .alertFirstButtonReturn {
            note("alert: Show Older Copy")
            for a in stale where !a.isTerminated {
                _ = a.terminate()
                a.activate(options: [.activateAllWindows])
            }
        } else {
            note("alert closed: stale copies quit")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var initialTheme: AppTheme = .default
    @MainActor static var settings: AppSettings?
    @MainActor static var onLaunch: (() -> Void)?
    /// 0.8.1: Hide Dock icon when the window is closed.
    @MainActor static var dock: DockIconController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Under `swift run` there is no bundle to say "regular app".
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated { applyAppearance(Self.initialTheme) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            Self.onLaunch?()
            MenuDump.scheduleIfRequested()
            Self.dock?.start()
        }
    }

    /// Reopen (Finder, Spotlight, a notification click) while the Dock icon
    /// is hidden: `.regular` first, then SwiftUI opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.dock?.prepareToShowWindow() }
        return true
    }

    /// With the menu-bar icon on, closing the window keeps Tankard running
    /// (the icon and background checks stay); otherwise it quits as before.
    /// 0.8.3: quitting while brew runs asks first (QuitGuardViews.swift).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { QuitGuard.shouldTerminate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(Self.settings?.showMenuBarIcon ?? false) }
    }
}

/// Images shipped with the app. Inside Tankard.app the SwiftPM resource
/// bundle sits in Contents/Resources (bundle-app.sh puts it there); under
/// `swift run`, Bundle.module finds it next to the binary.
@MainActor
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("tankard_TankardApp.bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return Bundle.module
    }()

    static func image(_ name: String) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// The Intelbrew "i" mug (128x128 pixel art), shown in Intelbrew mode.
    static let intelbrewMug = image("intelbrew-mug")
    /// Tankard's own mark (128x128 pixel art), shown otherwise.
    static let tankardMark = image("tankard-mark")

    /// The Dock icon for Intelbrew mode: the "i" mug on the app icon's
    /// purple plate, scaled 3x with nearest neighbour onto 512 px (the same
    /// layout as Scripts/make-icon.sh). nil if the art is missing.
    static let intelbrewDockIcon: NSImage? = {
        guard let mug = intelbrewMug?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 512
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ v: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        let size = CGFloat(n)
        let side = (size * 824 / 1024).rounded()
        let inset = ((size - side) / 2).rounded()
        let plate = CGRect(x: inset, y: inset, width: side, height: side)
        let path = CGPath(roundedRect: plate, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.02, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setFillColor(color(TankardPalette.iconWindow))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [color(TankardPalette.iconPlate), color(TankardPalette.iconWindow)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
        ctx.restoreGState()
        ctx.interpolationQuality = .none
        let m = 384 // 3 x 128, whole pixels
        ctx.draw(mug, in: CGRect(x: (n - m) / 2, y: (n - m) / 2, width: m, height: m))
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: n, height: n))
    }()

    private static var dockShowsIntelbrew = false

    /// 0.8.1: after an .accessory → .regular switch, set the Intelbrew Dock
    /// image again (the bundle's icon needs nothing).
    static func reapplyDockIcon() {
        if dockShowsIntelbrew { NSApp.applicationIconImage = intelbrewDockIcon }
    }

    /// Intelbrew mode: the Dock shows the "i" mug; otherwise the bundle's icon.
    /// Only a real change touches NSApp, and never inside a view update (it
    /// is called from onChange): the write is deferred to the next turn.
    static func updateDockIcon(intelbrew: Bool) {
        guard intelbrew != dockShowsIntelbrew else { return }
        dockShowsIntelbrew = intelbrew
        DispatchQueue.main.async {
            NSApp.applicationIconImage = intelbrew ? intelbrewDockIcon : nil
        }
    }
}
