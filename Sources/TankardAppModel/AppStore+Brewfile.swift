import Foundation
import TankardCore

// v0.6 (part B): the Homebrew menu's Export Brewfile… and Check a
// Brewfile…, and the restore plan's "Install with Tankard".

extension AppStore {
    /// Points the Brewfile store at this brew (read-only environment).
    /// false: brew isn't ready (no status yet).
    @discardableResult
    func prepareBrewfile() -> Bool {
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return false }
        var env = client.environment(for: detection, readOnly: true)
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let brew = client.installation.brewPath
        let runner = client.runner
        brewfile.run = { [env] args in try await runner.run(brew, args, environment: env) }
        brewfile.platform = client.platform
        brewfile.readFile = deps.readBrewfile
        return true
    }

    /// The menu items grey out while brew is busy or before the first status.
    public var canUseBrewfile: Bool { !isBusy && report != nil }

    public func exportBrewfile(to path: String, force: Bool) {
        prepareBrewfile()
        brewfile.export(to: path, force: force)
    }

    /// 0.8.8 (security review #2): Check Brewfile… opens the static
    /// preview; nothing runs until `confirmBrewfileCheck()`.
    public func previewBrewfile(at path: String) {
        brewfile.readFile = deps.readBrewfile
        brewfile.preview(path: path)
    }

    /// The user confirmed that brew may run the previewed Brewfile.
    public func confirmBrewfileCheck() {
        guard case .confirmRun(let p) = brewfile.page else { return }
        // 0.8.9 (F4): only the file the preview showed.
        brewfile.readFile = deps.readBrewfile
        guard brewfile.verifyUnchanged(p) else { return }
        checkBrewfile(at: p.path)
    }

    /// Runs `brew bundle check` on the file, which runs it as Ruby. Only
    /// after the confirmation (and the demo's fixture).
    public func checkBrewfile(at path: String) {
        prepareBrewfile()
        brewfile.check(path: path)
    }

    /// Option (a): the missing formulae and casks, one `brew install` each,
    /// through the queue and the activity sheet. Taps are not added here:
    /// each has Add Tap… (with the Brewfile's URL), and this waits for them. The Brewfile sheet
    /// closes first; the activity sheet opens once it has gone.
    public func installBrewfilePlan(_ plan: BrewfileRestorePlan) {
        // 0.8.5 (M3): not while a tap it needs is missing (the button is off too).
        guard plan.missingTaps.isEmpty else { return }
        let packages = plan.packages().filter { !installedIDs.contains($0.id) }
        brewfile.dismiss()
        guard !packages.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.startSession(.install, packages: packages)
        }
    }
}
