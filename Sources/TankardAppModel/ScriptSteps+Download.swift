import Foundation
import TankardCore

// v0.8: the harness's download-progress step (Scripts/e2e.sh's `progress`
// scenario; UpgradeSession.download is the feature). `watch-downloads`
// makes every later session step that downloads (install, upgrade, adopt …;
// not uninstall) watch its
// sheet while it runs: the first download progress it sees is captured as
// NN-<step>-mid-download.png, and the step checks that progress was shown.

extension ScriptRunner {
    static var downloadSteps: [String: ScriptStepDef] { [
        "watch-downloads": ScriptStepDef("watch-downloads [on|off]  (later sessions must show download progress; the first is captured as -mid-download.png)") { c in
            c.runner.watchDownloads = (c.arg(0) ?? "on") != "off"
        },
    ] }
}

extension ScriptContext {
    /// Waits for `session` to finish like `waitUntil`, polling faster, and
    /// snapshots the sheet the first time it shows a download (preferring
    /// one with a known total, captured below 90 %).
    func waitWatchingDownloads(_ session: UpgradeSession, what: String, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var captured: String?
        var firstLine: String?
        var sawDeterminate = false
        var fetchLine: String?
        while !session.isFinished {
            if Date() > deadline { throw ScriptFailure("timed out after \(Int(timeout))s waiting for \(what) to finish") }
            // 0.8.3: the prefetch's combined line, "Downloading 0 of 2 · 3.1 of 24.0 MB (12%)".
            if session.isFetching, session.download?.fraction != nil, fetchLine == nil {
                fetchLine = session.statusLine
                await snapshot("prefetch", settle: 0.05)
            }
            if let d = session.download {
                if firstLine == nil { firstLine = session.statusLine }
                if d.fraction != nil { sawDeterminate = true }
                if captured == nil, let f = d.fraction, f < 0.9 {
                    captured = session.statusLine
                    await snapshot("mid-download", settle: 0.05)
                }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        if captured == nil, firstLine != nil {
            // Too fast for a determinate frame: say what was seen.
            captured = firstLine
        }
        check("\(what): download progress shown", session.downloadObservations > 0,
              captured.map { "\"\($0)\" (\(session.downloadObservations) polls)" } ?? "no download seen")
        check("\(what): download total known", sawDeterminate, captured)
        if !session.prefetch.isEmpty {
            check("\(what): combined progress shown during brew fetch", fetchLine?.contains(" · ") == true, fetchLine ?? "not seen")
        }
    }
}
