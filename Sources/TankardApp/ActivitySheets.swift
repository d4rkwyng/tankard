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
        } else if let plan = store.upgradePlan {
            UpgradePlanView(store: store, plan: plan)
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
                    Text("Upgrade \(plan.rows.count) package\(plan.rows.count == 1 ? "" : "s")?")
                        .font(.system(size: 14, weight: .bold))
                    Text("\(compiling.count) \(compiling.count == 1 ? "has" : "have") no bottle for this Mac and will compile from source, which can take a long time.")
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

            Toggle(isOn: Binding(get: { plan.skipCompiling }, set: { store.setPlanSkipCompiling($0) })) {
                Text("Skip packages that would compile (\(compiling.map(\.name).joined(separator: ", ")))")
                    .lineLimit(1).truncationMode(.tail)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .padding(.top, 12)

            HStack {
                Text("Each runs as its own brew upgrade, one at a time.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelUpgradePlan() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    store.confirmUpgradePlan()
                } label: {
                    Text(plan.startTitle).fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.toRun.isEmpty)
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 600)
        .background(theme.window ?? .clear)
        .task { store.compileWarningShown() }
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
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.system(size: 12, weight: .medium)).strikethrough(skipped)
                Text("\(p.installedVersion) → \(p.currentVersion ?? "?")" + (row.warning?.estimateText.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer()
            if let w = row.warning {
                CompileBadge(text: skipped ? "Skipped: would compile" : w.label)
            } else if p.kind == .cask {
                SourceBadge(kind: .cask, label: "Cask")
            } else {
                SourceBadge(kind: .bottle, label: intelbrew && p.bottleURL.map({ StatusClassifier.bottleOrigin(url: $0) }) == .intelbrew
                            ? "Intelbrew bottle" : "Bottle")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(skipped ? 0.55 : 1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                BrandMark(size: 64, intelbrew: store.intelbrewMode)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Tankard to update apps").font(.system(size: 15, weight: .bold))
                    Text("macOS asks before one app can update or remove other apps, so Homebrew needs this to upgrade or uninstall apps in Applications.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if prompt.reason == .blocked {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("macOS stopped \(prompt.packages.map(\.name).joined(separator: ", ")). Tankard will try once more after you allow it.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AppManagement.steps().enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)")
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

            HStack {
                Button("Not now") { store.appManagementNotNow() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open System Settings") {
                    if !NSWorkspace.shared.open(AppManagement.settingsURL) {
                        NSWorkspace.shared.open(AppManagement.privacyURL)
                    }
                }
                Button {
                    store.appManagementDone()
                } label: {
                    Text("I've done this").fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.window ?? .clear)
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
                    Text("Old versions, stale downloads and old logs. Nothing you use is removed.")
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
                Text(cleanup.cachePath.map { AppPaths.tildePath($0) } ?? "–")
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if cleanup.measuringCache {
                    ProgressView().controlSize(.mini)
                } else if let b = cleanup.cacheBytes {
                    Text(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)).fontWeight(.semibold).monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .help("brew --cache, measured with du -sk")

            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: cleanup.command)
            }

            Spacer(minLength: 0)
            HStack {
                Text("Preview from \(cleanup.dryRunCommand) (changes nothing).").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.showCleanupSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    store.startCleanup()
                } label: {
                    Text("Clean up").fontWeight(.semibold).modifier(OnAccentLabel(theme: theme))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(cleanup.phase != .ready || (cleanup.dryRun?.items.isEmpty ?? true) || store.isUpgrading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // One height for every phase: a sheet that grows after the dry run
        // answers would otherwise jump.
        .frame(width: 600, height: 480, alignment: .top)
        .background(theme.window ?? .clear)
    }

    @ViewBuilder
    private func results(_ d: CleanupDryRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(d.items.isEmpty ? "Nothing to clean up" : "Would free about \(d.totalText)")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(d.items.isEmpty ? Color.secondary : theme.accent)
            if !d.items.isEmpty {
                Text("\(d.items.count) item\(d.items.count == 1 ? "" : "s")\(d.totalIsFromBrew ? "" : " (Tankard's sum: brew printed no total)")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        if !d.items.isEmpty {
            HStack(spacing: 14) {
                kindTotal("Old versions", d.bytes(of: .oldVersion))
                kindTotal("Downloads", d.bytes(of: .download))
                kindTotal("Logs and other", d.bytes(of: .log) + d.bytes(of: .other))
            }
            .font(.system(size: 11.5))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(d.items) { item in
                        HStack(spacing: 8) {
                            Text(AppPaths.tildePath(item.path)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(item.sizeText ?? "").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .padding(10)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.logBackground))
        }
        if let problem = cleanup.problem {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
        }
        if !d.warnings.isEmpty {
            Text("brew printed \(d.warnings.count) warning\(d.warnings.count == 1 ? "" : "s") (\(d.warnings[0]))")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func kindTotal(_ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(CleanupDryRun.format(bytes: bytes)).fontWeight(.medium).monospacedDigit()
        }
    }
}

// MARK: install that compiles

/// "Install node-red from source?" before an install with no bottle here.
struct CompileInstallConfirm: View {
    /// Built in steps: one long concatenation is too much for Swift 6.0's type checker.
    static func message(_ e: CatalogEntry, intelbrew: Bool, deps: [CatalogEntry], estimate: String?) -> String {
        var m = "\(e.name) has no \(intelbrew ? "Intelbrew " : "")bottle for this Mac, so brew compiles it"
        if !deps.isEmpty {
            let names = deps.prefix(4).map(\.name).joined(separator: ", ")
            let noun = deps.count == 1 ? "dependency" : "dependencies"
            m += ", and \(deps.count) \(noun) (\(names))"
        }
        m += ". That can take a long time on older Macs."
        if let estimate { m += " It took \(estimate)." }
        return m
    }

    @Bindable var store: AppStore
    @Bindable var discover: DiscoverStore
    var entry: CatalogEntry
    @Environment(\.theme) private var theme

    var body: some View {
        let _ = store.buildTimesRevision
        let deps = discover.dependenciesThatCompile(entry, installedIDs: store.installedIDs).compiling
        let estimate = store.deps.classifier.installWarning(entry)?.estimateText
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hammer.circle.fill").font(.system(size: 34)).foregroundStyle(theme.badge(.source).dot)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install \(entry.name) from source?").font(.system(size: 14, weight: .bold))
                    Text(Self.message(entry, intelbrew: discover.isLocalTaps, deps: deps, estimate: estimate))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                CommandBox(command: entry.installDisplay)
            }
            HStack {
                Spacer()
                Button("Cancel") { discover.confirmInstall = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Install (compiles)") {
                    discover.confirmInstall = nil
                    store.startInstall(entry)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isUpgrading)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.window ?? .clear)
    }
}
