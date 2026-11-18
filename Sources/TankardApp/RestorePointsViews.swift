import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.7: Homebrew → Restore Points…: the saved snapshots, what changed since
// one, and the restore (only what brew can actually do). Colours only from
// Theme tokens; no theme-specific geometry.

struct RestorePointsMenuItem: View {
    var store: AppStore

    var body: some View {
        Button("Restore Points…") { store.openRestorePoints() }
            .disabled(store.report == nil || store.menuActionsBlocked)
    }
}

struct RestorePointsSheet: View {
    @Bindable var store: AppStore
    var points: RestorePointStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    // `State(...)`, not `@State`: see CommandBox (the macro needs Xcode).
    private let pinAfterState = State(initialValue: true)

    static func binding(_ points: RestorePointStore) -> Binding<Bool> {
        Binding(get: { points.isShowing }, set: { if points.isShowing != $0 { points.isShowing = $0 } })
    }

    private var selection: Binding<RestorePoint.ID?> {
        Binding(get: { points.selected?.id }, set: { v in if points.selection != v { points.selection = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore Points").font(.system(size: 14, weight: .bold))
                    Text("Saved before each upgrade and auto-update run. The last \(RestorePointStore.maxPoints) are kept.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            // 0.8.5: say up front why upgrades can't be rolled back.
            if points.showsKeepOldVersionsBanner {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(theme.warning(scheme).text)
                    Text("Rolling back needs the old version, and Tankard isn't keeping old versions after upgrades.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Keep Old Versions") { points.keepOldVersions() }
                        .help("Turns on \"Keep the previous version after upgrades\" (Settings ▸ Upgrades). Upgrades from now on can be rolled back.")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip.opacity(0.8)))
            }
            if points.points.isEmpty {
                Text("No restore points yet. One is saved before the next upgrade.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    List(points.points, selection: selection) { p in
                        RestorePointRow(point: p).tag(p.id)
                    }
                    .frame(width: 220)
                    if let plan = points.pendingPlan {
                        RestoreConfirmView(store: store, plan: plan)
                    } else if let p = points.selected {
                        RestoreDiffView(store: store, point: p, diff: store.restoreDiff(p), pinAfter: pinAfterState.projectedValue)
                    }
                }
            }
            HStack {
                Button("Save Now") { store.saveRestorePoint(.manual) }
                    .disabled(store.report == nil)
                    .help("Saves what is installed now as a restore point")
                Spacer()
                Button("Done") { points.isShowing = false; store.cancelRestore() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 760, height: 520, alignment: .top)
        .background(theme.window ?? .clear)
    }
}

struct RestorePointRow: View {
    var point: RestorePoint

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(point.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 12, weight: .semibold))
            Text(point.reason.title + (point.note.map { ": \($0)" } ?? ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct RestoreDiffView: View {
    @Bindable var store: AppStore
    var point: RestorePoint
    var diff: RestoreDiff
    @Binding var pinAfter: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let plan = RestorePlan.make(diff, installed: store.packages, pinAfter: pinAfter)
        VStack(alignment: .leading, spacing: 8) {
            Text(diff.isEmpty ? String(localized: "Nothing changed since then") : String(localized: "Changes since then"))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(diff.isEmpty ? Color.secondary : theme.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !diff.upgraded.isEmpty {
                        DiffSection(title: String(localized: "Upgraded (\(diff.upgraded.count))")) {
                            ForEach(diff.upgraded) { c in
                                UpgradedRow(change: c, eligibility: RollbackPolicy.eligibility(c, installed: store.packages),
                                            keepPrevious: store.restorePoints.settings.keepPreviousVersion)
                            }
                        }
                    }
                    if !diff.removed.isEmpty {
                        DiffSection(title: String(localized: "Removed (\(diff.removed.count))")) {
                            ForEach(diff.removed, id: \.id) { r in
                                PlainDiffRow(name: r.name, detail: r.version, note: String(localized: "Reinstall"))
                                    .help("brew install gets the version Homebrew has now, which may be newer than \(r.version).")
                            }
                        }
                    }
                    if !diff.added.isEmpty {
                        DiffSection(title: String(localized: "Added (\(diff.added.count))")) {
                            ForEach(diff.added) { p in
                                PlainDiffRow(name: p.name, detail: p.installedVersion, note: String(localized: "Kept"))
                                    .help("Restore never uninstalls what was added. Uninstall it from its details if you don't want it.")
                            }
                        }
                    }
                    if !diff.downgraded.isEmpty {
                        DiffSection(title: String(localized: "Older now (\(diff.downgraded.count))")) {
                            ForEach(diff.downgraded) { c in
                                PlainDiffRow(name: c.now.name, detail: "\(c.then.version) → \(c.now.installedVersion)", note: "")
                            }
                        }
                    }
                    if !diff.tapsAdded.isEmpty || !diff.tapsRemoved.isEmpty || !diff.pinsChanged.isEmpty {
                        DiffSection(title: String(localized: "Taps and pins")) {
                            ForEach(diff.tapsAdded, id: \.self) { PlainDiffRow(name: $0, detail: String(localized: "tap added"), note: "") }
                            ForEach(diff.tapsRemoved, id: \.self) { PlainDiffRow(name: $0, detail: String(localized: "tap removed"), note: "") }
                            ForEach(diff.pinsChanged, id: \.self) { PlainDiffRow(name: $0, detail: String(localized: "pin changed"), note: "") }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Toggle("Pin rolled-back formulae", isOn: $pinAfter)
                    .font(.system(size: 11.5))
                    .help("So the next upgrade or auto-update doesn't upgrade them again. Unpin later to get updates.")
                Spacer()
                Button("Copy Brewfile") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(point.brewfile, forType: .string)
                }
                .help("This restore point's taps, formulae and casks as a Brewfile (no versions: Brewfiles have none)")
                Button("Restore…") { store.requestRestore(point, pinAfter: pinAfter) }
                    .buttonStyle(.primaryAction)
                    .disabled(plan.steps.isEmpty || store.isBusy)
                    .help(plan.steps.isEmpty ? plan.nothingToRestoreReason : String(localized: "Shows the brew commands first"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiffSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct PlainDiffRow: View {
    var name: String
    var detail: String
    var note: String

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct UpgradedRow: View {
    var change: RestoreDiff.Change
    var eligibility: RollbackEligibility
    var keepPrevious = false
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(change.now.name).font(.system(size: 12, weight: .medium))
                Text(verbatim: "\(change.then.version) → \(change.now.installedVersion)")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                switch eligibility {
                case .automatic:
                    Text("Can roll back").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent)
                        .help("The old version is still installed. brew uninstall removes the new one, then brew link links the old one.")
                case .manual(let block):
                    Text(block.title).font(.system(size: 11)).foregroundStyle(theme.warning(scheme).text)
                        .help("Can't roll back automatically. " + block.explanation(keepPrevious: keepPrevious))
                }
            }
            if case .manual(let block) = eligibility {
                let cmds = RollbackPolicy.manualCommands(change, block: block)
                if !cmds.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(cmds, id: \.self) { CommandBox(command: $0) }
                    }
                        .help(block == .cleanedUp
                              ? String(localized: "Run in Terminal if you need this version. brew version-install puts it in your own tap, and you maintain it from then on.")
                              : block.explanation(keepPrevious: keepPrevious))
                }
            }
        }
    }
}

struct RestoreConfirmView: View {
    @Bindable var store: AppStore
    var plan: RestorePlan
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 0.8.5 (L6): with nothing to run, why (not "Run 0 brew commands?").
            Text(plan.confirmTitle)
                .font(.system(size: 16, weight: .bold))
            Text(plan.confirmSubtitle)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = plan.notice {
                // The plan changed since it was shown (an old keg was cleaned up).
                Text(notice)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.warning(scheme).text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.steps) { s in CommandBox(command: s.display) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notIncluded = plan.notIncludedText, !plan.steps.isEmpty {
                Text(notIncluded)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Back") { store.cancelRestore() }
                Button("Restore") { store.confirmRestore() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isBusy || plan.steps.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings → Upgrades.
struct KeepPreviousVersionToggle: View {
    var settings: RollbackSettings

    var body: some View {
        ExplainedRow(help: SettingsHelp.keepPreviousVersion) {
            Toggle("Keep the previous version after upgrades", isOn: Binding(
                get: { settings.keepPreviousVersion },
                set: { if settings.keepPreviousVersion != $0 { settings.keepPreviousVersion = $0 } }))
        }
        SettingsNote(String(localized: "Uses disk space until Clean Up removes old versions."))
    }
}
