import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

/// The window's one sheet for brew work: the App Management explainer when
/// it is up, else the upgrade plan (when something would compile), else the
/// running or finished session.
struct ActivitySheet: View {
    @Bindable var store: AppStore

    var body: some View {
        if let prompt = store.appManagementPrompt {
            AppManagementSheet(store: store, prompt: prompt)
        } else if let resume = store.appManagementResume {
            AppManagementResumeSheet(store: store, resume: resume)
        } else if let offer = store.interruptedRun {
            InterruptedRunSheet(store: store, offer: offer)
        } else if let notes = store.progressPanelNotes {
            // 0.8.5 review: a progress-panel run's post-install notes.
            PostInstallNotesSheet(notes: notes) { store.closeProgressPanelNotes() }
        } else if let plan = store.upgradePlan {
            UpgradePlanView(store: store, plan: plan)
                .background(KeyWindowOnAppear())
        } else if let session = store.upgrade {
            UpgradeSheet(session: session, store: store)
        }
    }
}

// MARK: upgrade plan (compile warnings)

struct UpgradePlanView: View {
    @Bindable var store: AppStore
    var plan: UpgradePlan
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = store.buildTimesRevision
        let compiling = plan.compiling
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Upgrade \(plan.rows.count) packages?", bundle: L10n.bundle))
                        .font(.system(size: 14, weight: .bold))
                    // 0.8.3: a notification's Upgrade All… shows the plan
                    // even when nothing compiles.
                    Group {
                        if compiling.isEmpty {
                            Text("Nothing will compile from source.")
                        } else {
                            // 0.8.6 (UI M4): one whole sentence per count, no English verb in a placeholder.
                            Text(PlanText.compiles(compiling.count))
                        }
                    }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.rows) { r in
                        let row = UpgradePlan.Row(package: r.package, warning: store.deps.classifier.upgradeWarning(r.package))
                        PlanRow(row: row, skipped: plan.skipCompiling && row.warning != nil, intelbrew: store.intelbrewMode)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(height: min(CGFloat(plan.rows.count) * 38 + 4, 240))
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip.opacity(0.6)))

            if !compiling.isEmpty {
                Toggle(isOn: Binding(get: { plan.skipCompiling }, set: { store.setPlanSkipCompiling($0) })) {
                    Text("Skip packages that would compile (\(compiling.map(\.name).joined(separator: ", ")))")
                        .lineLimit(1).truncationMode(.tail)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.top, 12)
            }
            // 0.9.4 (bug hunt R1 review): a read while it was open changed it.
            if let note = plan.changedNote {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.top, 12)
            }
            // 0.8.5: say before starting that brew closes open apps.
            if let note = plan.runningAppsNote {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 12))
                .padding(.top, 12)
            }
            // 0.8.9: Tankard's own cask: it stays open, then offers to relaunch.
            if let note = plan.selfUpgradeNote {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.top, 12)
            }
            // 0.8.3: say before starting that brew's sudo will ask.
            let password = plan.needingPassword
            if !password.isEmpty {
                AdminPasswordNote(names: password.map(\.name), helper: store.deps.askpassHelper != nil,
                                  removal: password.allSatisfy(AdminPassword.onlyRemovalNeedsSudo),
                                  foreign: store.foreignAskpass(),
                                  commands: password.map { BrewCommands.display(BrewCommands.arguments(.upgrade, for: $0)) })
                    .padding(.top, 12)
            }

            // 0.9.4 (bug hunt R4): Upgrade waits for a fresh read, and the
            // sheet turns the menu's Refresh off: the way to it is here.
            if store.statusStale {
                StaleStatusNote(store: store).padding(.top, 12)
            }

            HStack {
                Text("Each runs as its own brew upgrade, one at a time.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelUpgradePlan() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    store.confirmUpgradePlan()
                } label: {
                    Text(plan.startTitle)
                }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                // 0.9.4 (bug hunt): an automatic update has the queue.
                // 0.9.4 (bug hunt R3): and until a read after its upgrades.
                .disabled(plan.toRun.isEmpty || store.autoUpdate.isRunning || store.statusStale)
            }
            .panelButtonRow("plan.buttons")
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 600)
        .background(theme.window ?? .clear)
        .task { store.compileWarningShown() }
    }
}

/// 0.9.4 (bug hunt R4): the status is older than brew's last change: the
/// sheet's confirmation is off until a fresh read, and this asks for one.
struct StaleStatusNote: View {
    @Bindable var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Homebrew changed packages after this list was read. Refresh it before continuing.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
            }
            .font(.system(size: 12))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { store.refreshStaleStatus() }
                .disabled(store.isRefreshing)
        }
    }
}

struct PlanRow: View {
    var row: UpgradePlan.Row
    var skipped: Bool
    var intelbrew: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let p = row.package
        HStack(spacing: 8) {
            Image(systemName: p.kind == .cask ? "macwindow" : "shippingbox")
                .foregroundStyle(.secondary).frame(width: 16)
                .accessibilityLabel(String(localized: p.kind == .cask ? "Cask" : "Formula"))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.system(size: 12, weight: .medium)).strikethrough(skipped)
                Text("\(p.installedVersion) → \(p.currentVersion ?? "?")" + (row.warning?.estimateText.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            if AdminPassword.required(p) { PasswordLockBadge() }
            if let w = row.warning {
                CompileBadge(text: skipped ? String(localized: "Skipped: would compile") : w.label)
            } else if p.kind == .cask {
                SourceBadge(kind: .cask, label: String(localized: "Cask"))
            } else {
                SourceBadge(kind: .bottle, label: intelbrew && p.bottleURL.map({ StatusClassifier.bottleOrigin(url: $0) }) == .intelbrew
                            ? String(localized: "Intelbrew bottle") : String(localized: "Bottle"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(skipped ? 0.55 : 1)
    }
}

/// 0.8.5: a small lock on a cask whose upgrade asks for the administrator
/// password (a `.pkg` installer or a sudo installer script), in the
/// package list, the upgrade plan and the run's chips.
struct PasswordLockBadge: View {
    var size: CGFloat = 9.5
    var help: String = AdminPassword.badgeHelp
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = prominence == .increased && !theme.isCustom
        Image(systemName: "lock.fill")
            .font(.system(size: size))
            .foregroundStyle(selected ? Color.white : Color.orange)
            .fixedSize()
            .help(help)
            .accessibilityLabel(Text(help))
    }
}

/// 0.8.3: "This needs your administrator password" before a cask change
/// whose installer brew runs with sudo.
struct AdminPasswordNote: View {
    var names: [String]
    /// false: no dialog in this build (`swift run`, demo): the Terminal way.
    var helper: Bool
    /// Uninstall: brew removes what the installer put in place.
    var uninstall = false
    /// 0.8.8: every one needs it only to remove a background service or
    /// system files (hiddenbar's launchctl service).
    var removal = false
    /// 0.8.4: brew.env sets another password helper: no dialog, these steps
    /// are refused, and `commands` are shown for Terminal.
    var foreign: ForeignAskpass? = nil
    var commands: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(names.count == 1 ? String(localized: "\(names[0]) needs your administrator password")
                     : String(localized: "These need your administrator password: \(names.joined(separator: ", "))"))
                    .font(.system(size: 12, weight: .semibold))
                if let foreign {
                    Text(foreign.message)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !commands.isEmpty { CommandBox(command: commands.joined(separator: "\n")) }
                } else {
                    // 0.8.5 (final pass L2): plain words; brew, sudo and
                    // the commands under Details.
                    let text = AdminPassword.noteText(helper: helper, uninstall: uninstall, removal: removal)
                    Text(text.plain)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(text.details)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !commands.isEmpty { CommandBox(command: commands.joined(separator: "\n")) }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("Details").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    // 0.8.9 (0.8.8 confirm run on 15, polish): with Full
                    // Keyboard Access the system style's ring sat left of
                    // "Details"; CommandDisclosureStyle's follows the button.
                    .disclosureGroupStyle(CommandDisclosureStyle())
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }
}

/// The orange "No bottle: will compile from source" mark.
struct CompileBadge: View {
    var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hammer.fill").font(.system(size: 9))
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.badge(.source).foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.badge(.source).background))
        .overlay(Capsule().stroke(theme.badge(.source).dot.opacity(0.6), lineWidth: 0.75))
        .fixedSize()
    }
}

// MARK: App Management

struct AppManagementSheet: View {
    @Bindable var store: AppStore
    var prompt: AppManagementPrompt
    @Environment(\.theme) private var theme

    /// 0.9.4 (bug hunt R1 review): the buttons that would start brew now
    /// wait while an automatic update runs; the prompt stays.
    private var runBlocked: Bool { prompt.canRetry && store.appManagementRunsBlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if prompt.stage == .relaunch { relaunchPage } else { explainPage }
            if runBlocked {
                Text("Homebrew is busy with an automatic update. This can run once it finishes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.window ?? .clear)
    }

    private var explainPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Tankard to update apps").font(.system(size: 15, weight: .bold))
                    Text("macOS asks before one app can change other apps, so Homebrew needs this to install, update or remove apps in Applications.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if prompt.reason == .blocked {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Group {
                        if prompt.canRetry {
                            Text("macOS stopped \(prompt.packages.map(\.name).joined(separator: ", ")). Tankard will try once more after you allow it.")
                        } else {
                            Text("macOS stopped a step that changes an app. Allow it, then run it again.")
                        }
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            AppManagementSteps()

            HStack {
                // 0.8.6 (M2): Cancel runs nothing ("Not now" used to start
                // the run); Close after a block.
                Button(prompt.reason == .blocked ? String(localized: "Close") : String(localized: "Cancel")) {
                    store.appManagementCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open System Settings") { AppManagementSteps.openSettings() }
                Button {
                    store.appManagementDone()
                } label: {
                    Text("I've done this").fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // 0.9.4 (bug hunt R1 review): it would run now; brew is busy.
                .disabled(store.deps.relaunch == nil && runBlocked)
            }
            if prompt.reason == .firstUse, prompt.canRetry {
                // Without the permission: the rest only, or everything
                // (macOS may stop the app steps; Tankard then says so).
                HStack {
                    Spacer()
                    if prompt.action == .upgrade, !prompt.others.isEmpty {
                        Button(AppManagementPrompt.skipAppsTitle(prompt.others.count)) { store.appManagementSkipApps() }
                            .help(String(localized: "Upgrades the packages that don't change apps; the apps wait until next time"))
                    }
                    Button(AppManagementPrompt.continueTitle) { store.appManagementNotNow() }
                        .help(String(localized: "Starts now without the permission. macOS may stop the steps that change apps; Tankard then says so."))
                }
                .controlSize(.small)
                // 0.9.4 (bug hunt R1 review): an automatic update has the queue.
                .disabled(runBlocked)
            }
        }
    }

    /// 0.8.1: macOS applies the grant to a process started after it.
    private var relaunchPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Relaunch Tankard").font(.system(size: 15, weight: .bold))
                    Text("macOS applies App Management the next time Tankard starts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        if prompt.canRetry {
                            Text("After the relaunch, Tankard offers to run it again: \(prompt.action.verb) \(prompt.packages.map(\.name).joined(separator: ", ")).")
                        } else {
                            Text("Nothing runs on its own after the relaunch.")
                        }
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }
            HStack {
                // Esc closes and runs nothing; continuing is a deliberate click.
                Button("Cancel") { store.appManagementCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue without relaunching") { store.appManagementContinue() }
                    .disabled(runBlocked)
                Button {
                    store.appManagementRelaunch()
                } label: {
                    Text("Relaunch Tankard").fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canRelaunch)
            }
        }
    }
}

/// 0.8.1: after the relaunch, the operation it was for, waiting for a click.
struct AppManagementResumeSheet: View {
    @Bindable var store: AppStore
    var resume: AppManagementResume
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run again: \(resume.action.verb) \(resume.packages.map(\.name).joined(separator: ", "))")
                        .font(.system(size: 15, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tankard relaunched so macOS applies App Management. Nothing runs until you click Run Again.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !resume.dropped.isEmpty {
                        Text("Left out, changed or done since: \(resume.dropped.joined(separator: ", "))")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }
            HStack {
                Button("Cancel") { store.appManagementResumeCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    store.appManagementResumeConfirm()
                } label: {
                    Text("Run Again").fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // 0.9.4 (bug hunt R1 review): the offer waits while brew runs.
                .disabled(store.appManagementRunsBlocked)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.window ?? .clear)
    }
}

/// The numbered App Management steps (the sheet and the first-launch
/// welcome).
struct AppManagementSteps: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AppManagement.steps().enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(i + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(theme.accent))
                    Text(step).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip))
    }

    static func openSettings() {
        if !NSWorkspace.shared.open(AppManagement.settingsURL) {
            NSWorkspace.shared.open(AppManagement.privacyURL)
        }
    }
}

// MARK: cleanup

struct CleanupSheet: View {
    @Bindable var store: AppStore
    var cleanup: CleanupStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 28)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up Homebrew").font(.system(size: 14, weight: .bold))
                    Text("Old versions, stale downloads and old logs. The versions you use now stay installed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            switch cleanup.phase {
            case .idle, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running \(cleanup.dryRunCommand)…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            case .ready:
                if let d = cleanup.dryRun { results(d) }
            }

            HStack(spacing: 6) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                Text("Download cache").foregroundStyle(.secondary)
                Text(verbatim: cleanup.cachePath.map { AppPaths.tildePath($0) } ?? "–")
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if cleanup.measuringCache {
                    ProgressView().controlSize(.mini)
                } else if let b = cleanup.cacheBytes {
                    Text(DiskSizes.format(b)).fontWeight(.semibold).monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .help("Space used by Homebrew's downloaded files")

            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: cleanup.command)
            }

            Spacer(minLength: 0)
            // 0.9.4 (bug hunt R4): Clean Up waits for a fresh read; the way to it.
            if store.statusStale {
                StaleStatusNote(store: store)
            }
            HStack {
                Text("Preview from \(cleanup.dryRunCommand) (changes nothing).").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.showCleanupSheet = false }
                    .keyboardShortcut(.cancelAction)
                // 0.8.5 (M1): not the Return default while it would remove
                // versions Restore Points could roll back to.
                if cleanup.cleanUpIsDefault {
                    Button {
                        store.startCleanup()
                    } label: {
                        Text("Clean Up")
                    }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanup.phase != .ready || store.statusStale || store.inventoryUnsettled || (cleanup.dryRun?.items.isEmpty ?? true) || store.newRunBlocked)
                } else {
                    Button {
                        store.startCleanup()
                    } label: {
                        Text("Clean Up")
                    }
                    .disabled(cleanup.phase != .ready || store.statusStale || store.inventoryUnsettled || (cleanup.dryRun?.items.isEmpty ?? true) || store.newRunBlocked)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // One height for every phase: a sheet that grows after the dry run
        // answers would otherwise jump.
        .sheetFrame(width: 600, height: 480, store: store)
        .background(theme.window ?? .clear)
    }

    @ViewBuilder
    private func results(_ d: CleanupDryRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(d.items.isEmpty ? String(localized: "Nothing to clean up") : String(localized: "Would free about \(d.totalDisplay)"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(d.items.isEmpty ? Color.secondary : theme.accent)
            if !d.items.isEmpty {
                Text(verbatim: (String(localized: "\(d.items.count) items", bundle: L10n.bundle))
                     + (d.totalIsFromBrew ? "" : " " + String(localized: "(Tankard's sum: brew printed no total)")))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        if !d.items.isEmpty {
            HStack(spacing: 14) {
                kindTotal(String(localized: "Old versions"), d.bytes(of: .oldVersion))
                kindTotal(String(localized: "Downloads"), d.bytes(of: .download))
                kindTotal(String(localized: "Logs and other"), d.bytes(of: .log) + d.bytes(of: .other))
            }
            .font(.system(size: 11.5))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(d.items) { item in
                        HStack(spacing: 8) {
                            Text(AppPaths.tildePath(item.path)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(item.sizeDisplay ?? "").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(10)
            }
            .frame(height: cleanup.removesRollbackVersions.isEmpty && cleanup.keptNote == nil ? 150 : 110)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.logBackground))
        }
        // 0.8.5 (M1): what Restore Points loses, said before it happens.
        let atRisk = cleanup.removesRollbackVersions
        if !atRisk.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Removes old versions you could roll back to").font(.system(size: 12, weight: .semibold))
                    Text(verbatim: atRisk.prefix(6).joined(separator: ", ")
                         + (atRisk.count > 6 ? String(localized: " and \(atRisk.count - 6) more") : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Text(cleanup.keepPrevious ? String(localized: "Restore Points can't roll back to these after Clean Up.")
                         : String(localized: "Restore Points can't roll back to these after Clean Up. To keep old versions, turn on “Keep the previous version after upgrades” in Restore Points."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let note = cleanup.keptNote {
            Label(note, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        if let problem = cleanup.problem {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
        if !d.warnings.isEmpty {
            Text(String(localized: "brew printed \(d.warnings.count) warnings (\(d.warnings[0]))", bundle: L10n.bundle))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func kindTotal(_ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(DiskSizes.format(bytes)).fontWeight(.medium).monospacedDigit()
        }
    }
}

// MARK: install that compiles

/// "Install node-red from source?" before an install with no bottle here.
struct CompileInstallConfirm: View {
    /// Built in steps: one long concatenation is too much for Swift 6.0's type checker.
    /// 0.8.6 (UI details L1): whole sentences per case (four glued
    /// fragments read "…brewがコンパイルします、および1個の依存関係" in Japanese).
    static func message(_ e: CatalogEntry, intelbrew: Bool, deps: [CatalogEntry], estimate: String?) -> String {
        InstallCompileText.message(name: e.name, intelbrew: intelbrew, deps: deps.map(\.name), estimate: estimate)
    }

    @Bindable var store: AppStore
    @Bindable var discover: DiscoverStore
    var entry: CatalogEntry
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = store.buildTimesRevision
        let deps = discover.dependenciesThatCompile(entry, installedIDs: store.installedIDs).compiling
        let warning = store.deps.classifier.installWarning(entry)
        let estimate = warning?.estimateText
        // 0.9.4 (bug hunt R4): asked only because the bottle is unknown:
        // the copy says it may compile, not that it will.
        let unverified = ContextMenus.bottleUnverified(entry, compileWarning: warning)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hammer.circle.fill").font(.system(size: 34)).foregroundStyle(theme.badge(.source).dot)
                VStack(alignment: .leading, spacing: 4) {
                    Text(unverified ? String(localized: "Install \(entry.name)? It may compile.")
                                    : String(localized: "Install \(entry.name) from source?"))
                        .font(.system(size: 14, weight: .bold))
                    Text(unverified
                         ? InstallCompileText.unverifiedMessage(name: entry.name, intelbrew: discover.isLocalTaps)
                         : Self.message(entry, intelbrew: discover.isLocalTaps, deps: deps, estimate: estimate))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: entry.installDisplay)
                if let trust = store.discoverTrustNote(entry) {
                    Label(trust, systemImage: "checkmark.shield")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { discover.confirmInstall = nil }
                    .keyboardShortcut(.cancelAction)
                Button(unverified ? String(localized: "Install (may compile)") : String(localized: "Install (compiles)")) {
                    store.confirmCompileInstall(entry)
                }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                // 0.9.4 (bug hunt R1 review): and while an automatic update runs.
                .disabled(store.newRunBlocked)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.window ?? .clear)
    }
}
