import Foundation
import Observation
import TankardCore

// 0.8.1: the first-launch welcome sheet (Homebrew ▸ … stays where it was).
// Shown once, on the real app's first launch with a working brew, never in
// demo, script or e2e runs (the app decides that; `TANKARD_DEMO_ONBOARDING`
// shows it in a demo). Done closes it for good. The no-brew WelcomeView is
// a different screen: it replaces the window until brew runs; this sheet
// comes after, over the package list.

/// What the welcome sheet shows besides its fixed text.
@Observable @MainActor
public final class OnboardingState {
    /// Apps the background Adopt scan found ready to adopt. Nil while it
    /// runs, and when it failed (the card stays hidden either way).
    public internal(set) var adoptable: Int?
    /// The App Management check's answer (nil: not checked yet).
    public internal(set) var check: AppManagementProbe.Result?
    /// True when there was no Homebrew app to check with.
    public internal(set) var nothingToCheck = false
    public internal(set) var isChecking = false

    public init() {}

    /// The Adopt card shows only for a finished scan that found something.
    public var showsAdopt: Bool { (adoptable ?? 0) > 0 }
}

public extension AppStore {
    /// The app, after the first status read: show the welcome sheet if it
    /// was never closed. `allowed`: a real launch (not demo, script, e2e
    /// or snapshot). Starts the Adopt scan in the background; the sheet
    /// never waits for it.
    func showOnboardingIfFirstLaunch(allowed: Bool) {
        guard allowed, !settings.onboardingDone else { return }
        presentOnboarding()
    }

    /// Shows it regardless (TANKARD_DEMO_ONBOARDING).
    func presentOnboarding() {
        guard homebrewState == .ready, report != nil, toolSheet == nil else { return }
        let state = OnboardingState()
        onboarding = state
        toolSheet = .welcome
        guard prepareAdopt() else { return }
        let adopt = self.adopt
        Task { @MainActor in
            await adopt.load()
            state.adoptable = adopt.phase == .ready ? adopt.rows(.ready).count : nil
        }
    }

    /// Done: closes it for good.
    func finishOnboarding() {
        settings.onboardingDone = true
        if toolSheet == .welcome { toolSheet = nil }
    }

    /// "Adopt Apps…": the welcome is done; the Adopt sheet takes its place.
    func onboardingOpenAdopt() {
        settings.onboardingDone = true
        openAdopt()
    }

    /// "Relaunch Tankard" (after allowing App Management): done, then
    /// relaunch. Nothing is pending.
    func onboardingRelaunch() {
        guard canRelaunch, let relaunch = deps.relaunch else { return }
        settings.onboardingDone = true
        settings.appManagementExplained = true
        if !relaunch() {
            error = StoreError(title: String(localized: "Couldn't relaunch Tankard"),
                               detail: String(localized: "Quit Tankard and open it again, then run it again."))
        }
    }

    /// "Check": brew's own write test on an installed cask's app (never an
    /// app brew doesn't manage), off the main thread. The attempt is also
    /// what makes macOS list Tankard in App Management and show its notice.
    func checkAppManagement() {
        guard let state = onboarding, !state.isChecking else { return }
        guard let path = AppManagementProbe.target(packages, exists: deps.appManagementProbeExists) else {
            state.nothingToCheck = true
            state.check = .unknown
            return
        }
        state.isChecking = true
        let probe = deps.appManagementProbe
        Task { @MainActor in
            let result = await Task.detached { probe(path) }.value
            state.check = result
            state.isChecking = false
            if result == .allowed { self.settings.appManagementExplained = true }
        }
    }
}
