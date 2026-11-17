import AppKit
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
        }
        switch env["TANKARD_FILTER"]?.lowercased() {
        case "upgrades": o.filter = .upgrades
        case "source": o.filter = .source
        case "newer": o.filter = .newer
        case "bottle", "bottleavailable": o.filter = .bottleAvailable
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
        if o.discoverQuery != nil { o.tab = .discover }
        o.discoverSelect = env["TANKARD_DISCOVER_SELECT"]
        o.snapshot = SnapshotRequest(environment: env)
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
        let deps: AppStore.Dependencies
        if let hw = options.noBrew {
            deps = Demo.noBrewDependencies(hardware: hw)
        } else {
            deps = options.demo.map {
                Demo.dependencies($0, pace: options.demoPace, failAppManagement: options.demoAppManagement == "fail")
            } ?? .live()
        }
        // Demo runs never touch the real settings.
        let settings = options.isDemo || options.snapshot != nil ? AppSettings.ephemeral() : AppSettings()
        if let v = ProcessInfo.processInfo.environment["TANKARD_MENUBAR"] { settings.showMenuBarIcon = v != "0" }
        // Demo of the failure path: skip the first-use explainer so the run
        // reaches the block (and the sheet that follows it).
        if options.demoAppManagement == "fail" { settings.appManagementExplained = true }
        self.settings = settings
        store = AppStore(deps: deps, settings: settings)
        appearance = AppearanceSettings(override: options.appearance)
        notifier = SystemNotifier()
        loginItem = LoginItem()
        checker = BackgroundChecker(store: store, settings: settings, notifier: notifier)
        AppDelegate.initialTheme = appearance.theme
        AppDelegate.settings = settings
        let checker = self.checker
        AppDelegate.onLaunch = { if !options.isDemo { checker.start() } }
        appearance.onChange = { theme in applyAppearance(theme) }
        if let (theme, delay) = options.switchAppearance {
            let a = appearance
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { a.preview(theme) }
        }
    }

    var body: some Scene {
        WindowGroup(options.isDemo ? "Tankard (demo)" : "Tankard", id: "main") {
            ContentView(store: store, options: options, appearance: appearance)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Tankard") { AboutPanel.show(intelbrew: store.intelbrewMode) }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh(manual: true) } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isRefreshing)
                Button("Clean Up…") { store.openCleanup() }
                    .disabled(store.isUpgrading || store.report == nil)
                Divider()
                Button("Installed") { store.tab = .installed }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Discover") { store.tab = .discover }
                    .keyboardShortcut("2", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Tankard on GitHub") { NSWorkspace.shared.open(AboutInfo.repository) }
                Button("Report an Issue…") { NSWorkspace.shared.open(AboutInfo.newIssue) }
            }
        }

        MenuBarExtra(isInserted: Binding(get: { settings.showMenuBarIcon }, set: { settings.showMenuBarIcon = $0 })) {
            MenuBarPanel(store: store, appearance: appearance)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appearance: appearance, settings: settings, notifier: notifier, loginItem: loginItem)
        }
    }
}

/// The menu-bar panel with "Open Tankard" wired to the main window.
struct MenuBarPanel: View {
    var store: AppStore
    var appearance: AppearanceSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContent(store: store, openMain: openMain)
            .themed(Theme.of(appearance.theme))
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var initialTheme: AppTheme = .default
    @MainActor static var settings: AppSettings?
    @MainActor static var onLaunch: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Under `swift run` there is no bundle to say "regular app".
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated { applyAppearance(Self.initialTheme) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { Self.onLaunch?() }
    }

    /// With the menu-bar icon on, closing the window keeps Tankard running
    /// (the icon and background checks stay); otherwise it quits as before.
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

    /// Intelbrew mode: the Dock shows the "i" mug; otherwise the bundle's icon.
    static func updateDockIcon(intelbrew: Bool) {
        NSApp.applicationIconImage = intelbrew ? intelbrewDockIcon : nil
    }
}
