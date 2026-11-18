import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

/// v0.8: the scripted real-run harness (Scripts/e2e.sh; the steps are in
/// TankardAppModel's ScriptRunner). Off unless BOTH are set:
///
///   TANKARD_E2E=1                 the explicit switch
///   TANKARD_SCRIPT=/path/steps    the step file
///   TANKARD_SCRIPT_OUT=/dir       PNGs, results.jsonl, summary.json
///                                 (default: <script>.out next to the file)
///   TANKARD_E2E_STATE=/dir        Tankard's own files for this run: status
///                                 cache, insights, History, restore points,
///                                 logs, the formulae.brew.sh cache (api/)
///                                 (default: <out>/state). Keep it across
///                                 the phases of one scenario; empty it for a
///                                 first launch.
///   TANKARD_SCRIPT_STAY=1         keep the app open after the script
///   TANKARD_E2E_BACKGROUND=1      start the background checker (it runs
///                                 the throttled `brew update`); the suite's
///                                 e2eBackgroundUpdateInterval (seconds)
///                                 replaces Settings' hours
///   TANKARD_E2E_SUITE=name        the defaults suite for settings (default
///                                 `net.mindtricks.tankard.e2e`); only names
///                                 under that prefix are accepted. e2e.sh
///                                 gives each run its own.
///
/// A script run never reads or writes the real settings or Tankard's real
/// files: settings live in an `net.mindtricks.tankard.e2e…` defaults suite
/// (e2e.sh deletes it for a first launch), files in TANKARD_E2E_STATE. It
/// runs the REAL brew (or the demo's, with TANKARD_DEMO), so it really
/// installs and removes what the script says. No background check and no
/// auto-update run during it, unless TANKARD_E2E_BACKGROUND=1.
///
/// 0.8.4: AppKit and SwiftUI keep keys of their own in the app's defaults
/// domain (its bundle identifier), not in the suite. The run turns off the
/// main window's frame autosave and restoration before resizing it; still,
/// a first ever launch saves a frame and the menu-bar item saves its
/// visibility there. Scripts/e2e.sh therefore launches a re-signed copy
/// with a bundle identifier of its own, so that domain is a throwaway one.
/// A hand-run script launch of the real bundle should do the same.
struct ScriptLaunch {
    static let defaultsSuite = AppManagement.e2eSuitePrefix
    /// Seconds; set by e2e.sh in the run's suite (`defaults write`).
    static let backgroundIntervalKey = "e2eBackgroundUpdateInterval"

    var scriptPath: String
    /// The settings suite: `defaultsSuite`, or a per-run one below it.
    var suiteName: String
    var outputDirectory: URL
    var stateDirectory: URL
    var stay: Bool
    /// TANKARD_E2E_BACKGROUND=1: run the background checker (the throttled
    /// `brew update`), which a script run otherwise never starts.
    var background: Bool

    init?(environment env: [String: String]) {
        guard env["TANKARD_E2E"] == "1", let s = env["TANKARD_SCRIPT"], !s.isEmpty else { return nil }
        scriptPath = s
        let out = env["TANKARD_SCRIPT_OUT"].flatMap { $0.isEmpty ? nil : $0 } ?? s + ".out"
        outputDirectory = URL(fileURLWithPath: out, isDirectory: true)
        stateDirectory = env["TANKARD_E2E_STATE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? outputDirectory.appendingPathComponent("state", isDirectory: true)
        stay = env["TANKARD_SCRIPT_STAY"] == "1"
        background = env["TANKARD_E2E_BACKGROUND"] == "1"
        suiteName = Self.suite(env["TANKARD_E2E_SUITE"])
    }

    /// A per-run suite name, never the real settings' domain or anything
    /// outside the e2e prefix.
    static func suite(_ requested: String?) -> String {
        AppManagement.validE2ESuite(requested) ?? defaultsSuite
    }

    var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    /// The live dependencies with every file Tankard keeps moved into the state folder.
    func dependencies(_ live: AppStore.Dependencies) -> AppStore.Dependencies {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        var d = live
        let s = stateDirectory
        d.cache = StatusCache(url: s.appendingPathComponent("status.json"))
        d.logURL = s.appendingPathComponent("upgrade.log")
        d.insightsCache = InsightsCache(url: s.appendingPathComponent("insights.json"))
        d.autoUpdateLogURL = s.appendingPathComponent("auto-update-log.json")
        d.historyURL = s.appendingPathComponent("history.json")
        d.restorePointsURL = s.appendingPathComponent("restore-points", isDirectory: true)
        // The background-update scenario: a tiny interval (seconds) from
        // this run's settings suite, so the update is due without touching
        // brew's FETCH_HEAD.
        let secs = defaults.double(forKey: Self.backgroundIntervalKey)
        if secs > 0 { d.backgroundUpdateInterval = secs }
        // Discover's and Adopt Apps' formulae.brew.sh cache.
        APICache.redirect(to: s.appendingPathComponent("api", isDirectory: true))
        return d
    }

    /// Runs the script once the store has started, then quits with 0 (all
    /// passed) or 1.
    @MainActor private static var started = false

    @MainActor
    func run(store: AppStore) async {
        // Once per launch, even if SwiftUI runs the window's task again.
        guard !Self.started else { return }
        Self.started = true
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("e2e: \(message)\n".utf8))
            exit(2)
        }
        guard let text = try? String(contentsOfFile: scriptPath, encoding: .utf8) else { fail("can't read \(scriptPath)") }
        let steps: [ScriptStep]
        do { steps = try ScriptParser.parse(text) } catch { fail("\(scriptPath): \(error)\nsteps:\n\(ScriptRunner.help)") }
        // One window size, so every PNG is comparable. 0.8.4: first stop
        // AppKit saving the frame ("NSWindow Frame main-AppWindow-1") and
        // the window's state: both go to the app's real defaults domain and
        // Saved Application State, which a script run never writes.
        if let w = Self.mainWindow {
            Self.isolate(w)
            w.setContentSize(NSSize(width: 1100, height: 680))
        }
        let runner = ScriptRunner(store: store, steps: steps, outputDirectory: outputDirectory,
                                  scriptName: (scriptPath as NSString).lastPathComponent) { path in
            guard let w = Self.mainWindow else {
                FileHandle.standardError.write(Data("e2e: no main window to snapshot\n".utf8))
                return false
            }
            Snapshot.write(window: w, to: path)
            return FileManager.default.fileExists(atPath: path)
        }
        let summary = await runner.run()
        if stay { return }
        // exit, not terminate: AppKit won't terminate with a sheet up.
        exit(summary.ok ? 0 : 1)
    }

    /// No frame autosave and no state restoration for this window.
    @MainActor
    static func isolate(_ w: NSWindow) {
        w.setFrameAutosaveName("")
        w.isRestorable = false
    }

    @MainActor
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && !$0.className.contains("StatusBar") && !$0.className.contains("MenuBarExtra") }
    }
}
