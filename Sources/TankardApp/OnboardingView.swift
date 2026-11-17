import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

/// 0.8.1: the first-launch welcome (Onboarding.swift). Two cards: App
/// Management (open the pane, check, relaunch) and, once the background
/// scan has found some, Adopt Apps. Done closes it for good.
struct OnboardingSheet: View {
    @Bindable var store: AppStore
    var state: OnboardingState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Tankard").font(.system(size: 17, weight: .bold))
                    Text("See what Homebrew installed, what's out of date, and upgrade it in one place.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            card(icon: "lock.shield") {
                Text("Allow App Management").font(.system(size: 13, weight: .semibold))
                Text("macOS asks before Tankard can install, update or remove apps in Applications. Turn on Tankard in Privacy & Security → App Management.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open System Settings") { AppManagementSteps.openSettings() }
                    Button("Check") { store.checkAppManagement() }
                        .disabled(state.isChecking)
                        .help(String(localized: "Tries a harmless write in an app Homebrew installed, as Homebrew does, and removes it at once"))
                    checkResult
                }
                Text("macOS may apply it only after Tankard relaunches.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.deps.relaunch != nil {
                    Button("Relaunch Tankard") { store.onboardingRelaunch() }
                        .disabled(!store.canRelaunch)
                }
            }

            if state.showsAdopt, let n = state.adoptable {
                card(icon: "square.and.arrow.down.on.square") {
                    Text("Adopt Apps").font(.system(size: 13, weight: .semibold))
                    Text("Apps you installed yourself that Homebrew can manage: \(n)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Adopt Apps…") { store.onboardingOpenAdopt() }
                }
            }

            Text("Tankard runs brew update in the background so the counts stay fresh. Settings → General turns it off.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    store.finishOnboarding()
                } label: {
                    Text("Done").fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(theme.window ?? .clear)
    }

    @ViewBuilder private var checkResult: some View {
        if state.isChecking {
            ProgressView().controlSize(.small)
        } else if let r = state.check {
            switch r {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(theme.badge(.bottle).dot)
            case .blocked:
                Label("Not allowed yet", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .unknown:
                Text(state.nothingToCheck ? String(localized: "No Homebrew app to check with yet") : String(localized: "Couldn't tell"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(theme.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6, content: content)
                .font(.system(size: 12))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.chip))
    }
}

/// The real first launch shows the welcome once; never a demo, script, e2e
/// or snapshot run. TANKARD_DEMO_ONBOARDING=1 shows it in the demo
/// (=check: with the check's "Not allowed yet").
@MainActor
func applyOnboardingLaunchOptions(store: AppStore, options: LaunchOptions) async {
    let env = ProcessInfo.processInfo.environment
    if options.demo != nil, let mode = env["TANKARD_DEMO_ONBOARDING"], mode == "1" || mode == "check" {
        store.presentOnboarding()
        if mode == "check" { store.checkAppManagement() }
        return
    }
    let real = !options.isDemo && options.snapshot == nil && options.script == nil && env["TANKARD_E2E"] == nil
    store.showOnboardingIfFirstLaunch(allowed: real)
}
