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
    var appearance: String?
    var snapshot: SnapshotRequest?

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        var o = LaunchOptions()
        o.demo = Demo.Variant(environmentValue: env["TANKARD_DEMO"])
        // Selecting a row at launch is harmless, so it works in any mode
        // (for screenshots of real data).
        o.select = env["TANKARD_SELECT"]
        if o.demo != nil {
            o.demoPace = env["TANKARD_DEMO_PACE"].flatMap(Double.init) ?? 1
            o.demoUpgrade = env["TANKARD_DEMO_UPGRADE"] == "1"
        }
        o.appearance = env["TANKARD_APPEARANCE"]
        o.snapshot = SnapshotRequest(environment: env)
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

    init() {
        let options = LaunchOptions.fromEnvironment()
        self.options = options
        let deps = options.demo.map { Demo.dependencies($0, pace: options.demoPace) } ?? .live()
        store = AppStore(deps: deps)
    }

    var body: some Scene {
        WindowGroup(options.demo == nil ? "Tankard" : "Tankard (demo)", id: "main") {
            ContentView(store: store, options: options)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh(manual: true) } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isRefreshing)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Under `swift run` there is no bundle to say "regular app".
        NSApp.setActivationPolicy(.regular)
        switch ProcessInfo.processInfo.environment["TANKARD_APPEARANCE"]?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break // follow the system
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Images shipped with the app. Inside Tankard.app the SwiftPM resource
/// bundle sits in Contents/Resources (bundle-app.sh puts it there); under
/// `swift run`, Bundle.module finds it next to the binary.
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

    static let intelbrewLogo = image("intelbrew-logo")
    static let intelbrewLogoLarge = image("intelbrew-logo-512")
}
