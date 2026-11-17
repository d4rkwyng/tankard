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
        return true
    }

    /// The menu items grey out while brew is busy or before the first status.
    public var canUseBrewfile: Bool { !isBusy && report != nil }

    public func exportBrewfile(to path: String, force: Bool) {
        prepareBrewfile()
        brewfile.export(to: path, force: force)
    }

    public func checkBrewfile(at path: String) {
        prepareBrewfile()
        brewfile.check(path: path)
    }

    /// Option (a): the missing formulae and casks, one `brew install` each,
    /// through the queue and the activity sheet. Taps are not added here
    /// (the plan shows their `brew tap` commands). The Brewfile sheet
    /// closes first; the activity sheet opens once it has gone.
    public func installBrewfilePlan(_ plan: BrewfileRestorePlan) {
        let packages = plan.packages().filter { !installedIDs.contains($0.id) }
        brewfile.dismiss()
        guard !packages.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.startSession(.install, packages: packages)
        }
    }
}
