import SwiftUI
import TankardAppModel
import TankardCore

struct DetailPane: View {
    @Bindable var store: AppStore

    var body: some View {
        if let p = store.selectedPackage {
            let _ = store.buildTimesRevision
            // 0.8.5 review: also off while the progress panel holds the
            // activity (blockedNote says so).
            PackageDetail(package: p, intelbrew: store.intelbrewMode, canUpgrade: !store.windowBrewActionsBlocked,
                          blockedNote: store.windowBrewActionsNote,
                          dependents: store.dependents(of: p),
                          // The sheet opens with "Also remove these" on: its commands.
                          uninstallCommand: AppStore.uninstallDisplay(p, orphans: store.uninstallOrphans(of: p)),
                          compileWarning: store.deps.classifier.upgradeWarning(p),
                          upgrade: { store.requestUpgrade([p]) },
                          uninstall: { store.requestUninstall(p) },
                          replaceWithBottle: { store.startReplaceWithBottle([p]) },
                          insights: store.insights, prefix: store.report?.host.prefix,
                          skipVersion: { store.setVersionSkipped(p, $0) },
                          installCounts: store.discover?.installCounts(p.id),
                          analyticsEndDate: store.discover?.analytics?.endDate,
                          selfUpdate: p.kind == .cask && p.autoUpdates == true
                              ? (store.selfUpdatePolicy(p), { store.setSelfUpdatePolicy(p, $0) }) : nil)
            .id(p.id)
            .environment(store)
            .task(id: p.id) { if store.deps.classifier.upgradeWarning(p) != nil { store.compileWarningShown() } }
        } else {
            VStack(spacing: 8) {
                // 0.8.9: decoration; VoiceOver read it as "Box".
                Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Select a package").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PackageDetail: View {
    var package: Package
    var intelbrew: Bool
    var canUpgrade: Bool
    /// 0.8.5 review: why Upgrade and Uninstall are off (the progress
    /// panel holds the activity), for their help.
    var blockedNote: String? = nil
    /// Installed packages that need this one (uninstall is blocked).
    var dependents: [Package]
    /// The uninstall's commands, as the sheet shows them (the button's tooltip).
    var uninstallCommand: String? = nil
    var compileWarning: CompileWarning?
    var upgrade: () -> Void
    var uninstall: () -> Void
    var replaceWithBottle: () -> Void
    /// 0.4: the scan behind the vulnerability list, and brew's prefix for caveats.
    var insights: InsightsStore? = nil
    var prefix: String? = nil
    /// 0.6: "Skip Version 1.1" (true) or "Don't Skip" (false).
    var skipVersion: ((Bool) -> Void)? = nil
    /// 0.8: formulae.brew.sh's install counts, when Discover has loaded
    /// them this session (the Installed tab never fetches them itself).
    var installCounts: InstallCounts? = nil
    var analyticsEndDate: String? = nil
    /// 0.8: a self-updating cask's "who updates it" choice.
    var selfUpdate: (policy: SelfUpdatePolicy, set: (SelfUpdatePolicy) -> Void)? = nil
    @Environment(\.theme) private var theme

    private static let dateFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()

    var body: some View {
        let p = package
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [Color(hex: 0x3a3a3c), Color(hex: 0x1c1c1e)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 40, height: 40)
                        .overlay(Image(systemName: p.kind == .cask ? "macwindow" : "shippingbox.fill")
                            .font(.system(size: 18)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 16, weight: .bold)).lineLimit(1).truncationMode(.middle)
                        Text(p.desc ?? (p.kind == .cask ? String(localized: "Cask") : String(localized: "Formula")))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                RetiredDetail(package: p)
                UnreadableDetail(package: p)

                if p.upgradeAvailable {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle").foregroundStyle(theme.upgrade)
                        Text(UpgradeBanner.text(p))
                            .foregroundStyle(p.isUpgradeTarget ? theme.upgrade : Color.primary)
                            .fontWeight(p.isUpgradeTarget ? .semibold : .regular)
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.upgrade.opacity(0.12)))
                    if let w = compileWarning {
                        CompileBadge(text: w.label)
                        if let est = w.estimateText {
                            Text("It took \(est); expect longer on an older Mac.")
                                .font(.system(size: 11)).foregroundStyle(theme.badge(.source).foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VulnerabilitySection(package: p, scan: insights?.vulnerabilityScan)

                if BottleReplacement.isEligible(p) {
                    ReplaceWithBottleBox(package: p, intelbrew: intelbrew, enabled: canUpgrade, action: replaceWithBottle)
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    row(String(localized: "Installed"), p.installedVersion)
                    if p.installedVersions.count > 1 {
                        row(String(localized: "Kegs"), p.installedVersions.joined(separator: ", "))
                    }
                    row(String(localized: "Available"), p.currentVersion ?? "–")
                    if p.kind == .formula {
                        row(String(localized: "Bottle tag"), p.bottleTag ?? String(localized: "none for this Mac"), mono: p.bottleTag != nil)
                        if let origin = p.bottleOrigin {
                            row(String(localized: "Bottle from"), originText(origin))
                        }
                        row(String(localized: "Installed as"), p.requested ? String(localized: "Requested") : String(localized: "Dependency"))
                    } else {
                        row(String(localized: "Kind"), p.autoUpdates == true ? String(localized: "Cask, updates itself") : String(localized: "Cask"))
                    }
                    if let date = p.installedAt {
                        row(String(localized: "Installed on"), date.formatted(Self.dateFormat))
                    }
                    if let tap = p.tap { row(String(localized: "Tap"), tap, mono: true) }
                    if p.pinned { row(String(localized: "Pinned"), String(localized: "Yes")) }
                    if let bytes = p.diskBytes { row(String(localized: "On disk"), DiskSizes.format(bytes)) }
                }
                .font(.system(size: 12))

                if let installCounts {
                    InstallCountsView(counts: installCounts, phase: .ready, endDate: analyticsEndDate)
                }

                if let selfUpdate {
                    VStack(alignment: .leading, spacing: 3) {
                        // The label never wraps or truncates ("Aggiornamen-ti"):
                        // beside the picker when both fit, else above it.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                updatesLabel
                                Spacer(minLength: 4)
                                SelfUpdatePolicyPicker(policy: selfUpdate.policy, includeSelfUpdating: insights?.settings.includeSelfUpdatingApps ?? false, set: selfUpdate.set)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                updatesLabel
                                SelfUpdatePolicyPicker(policy: selfUpdate.policy, includeSelfUpdating: insights?.settings.includeSelfUpdatingApps ?? false, set: selfUpdate.set)
                            }
                        }
                        if p.selfUpdateHeld == true, let v = p.currentVersion {
                            Text("Left to the app: \(v) isn't in Upgrade All or auto-update.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Divider()

                sourceLine(p).font(.system(size: 12))

                CaveatsSection(package: p, prefix: prefix)

                ElectronDetailSection(package: p)

                PackageRelationsSection(package: p)

                if p.upgradeAvailable {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Upgrade command").font(.system(size: 11)).foregroundStyle(.secondary)
                        let command = insights?.upgradeDisplay(for: p) ?? BrewCommands.upgradeDisplay(for: p)
                        CommandBox(command: command)
                        Button(action: upgrade) {
                            Label("Upgrade \(p.name)", systemImage: "arrow.up")
                        }
                        .buttonStyle(.primaryAction)
                        .disabled(!canUpgrade || p.isHeld)
                        .help(p.isHeld ? String(localized: "Pinned: unpin it first") : blockedNote ?? command)
                        if let skipVersion, !p.isHeld, let v = p.currentVersion {
                            SkipVersionRow(skipped: p.versionSkipped == true, version: v, toggle: skipVersion)
                        }
                    }
                }

                UninstallSection(package: p, dependents: dependents, enabled: canUpgrade, uninstall: uninstall,
                                 command: blockedNote ?? uninstallCommand ?? AppStore.uninstallDisplay(p))

                if let page = p.releasePageURL, WebURL.isWeb(page) {
                    Link(destination: page) {
                        HStack(spacing: 3) {
                            Text("Open Release Page")
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .help(page.absoluteString)
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var updatesLabel: some View {
        Text("Updates").font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize().layoutPriority(1)
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .monospacedDigit()
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    private func originText(_ o: BottleOrigin) -> String {
        switch o {
        case .intelbrew: return "Intelbrew"
        case .homebrew: return "Homebrew"
        case .other: return String(localized: "Other")
        }
    }

    @ViewBuilder
    private func sourceLine(_ p: Package) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch p.status {
            case .bottle:
                Image(systemName: "checkmark.circle").foregroundStyle(theme.badge(.bottle).dot)
                    .accessibilityHidden(true)
                if let repo = p.bottleRepository {
                    // 0.8.6 (UI L1): one sentence for the translations.
                    Text("Poured from the \(repo) release")
                } else if p.bottleOrigin == .homebrew {
                    Text("Poured from a Homebrew bottle (ghcr.io)")
                } else {
                    Text("Poured from a bottle")
                }
            case .source:
                Image(systemName: "hammer").foregroundStyle(theme.badge(.source).dot)
                Text(p.currentHasBottle == true ? String(localized: "Built from source; a bottle exists for the current version") : String(localized: "Built from source"))
            case .newer:
                Image(systemName: "arrow.up.forward.circle").foregroundStyle(theme.badge(.newer).dot)
                Text("Installed version is newer than the tap's \(p.currentVersion ?? "?"). brew won't downgrade it.")
            case .noBottle:
                Image(systemName: "exclamationmark.circle").foregroundStyle(theme.badge(.noBottle).dot)
                Text(p.noBottleDetail)
            case .cask:
                // 0.8.4: from the cask's artifacts (a font isn't an app).
                let contents = CaskContents(p)
                Image(systemName: Self.caskSymbol(contents)).foregroundStyle(theme.badge(.cask).dot)
                Text(Self.caskLine(contents))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension PackageDetail {
    static func caskSymbol(_ c: CaskContents) -> String {
        switch c {
        case .app: return "macwindow"
        case .installer: return "shippingbox"
        case .font: return "textformat"
        case .commandLineTool: return "terminal"
        case .plugin: return "puzzlepiece.extension"
        case .other: return "doc"
        }
    }

    static func caskLine(_ c: CaskContents) -> String {
        switch c {
        case .app: return String(localized: "Cask: installs the vendor's app; no bottles.")
        case .installer: return String(localized: "Cask: runs the vendor's installer package; no bottles.")
        case .font: return String(localized: "Cask: installs fonts; no bottles.")
        case .commandLineTool: return String(localized: "Cask: installs a command-line tool; no bottles.")
        case .plugin: return String(localized: "Cask: installs a plug-in; no bottles.")
        case .other: return String(localized: "Cask: installs the vendor's files; no bottles.")
        }
    }
}

/// A source build whose version has a bottle here: badge, the exact
/// command, and the button.
struct ReplaceWithBottleBox: View {
    var package: Package
    var intelbrew: Bool
    var enabled: Bool
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let label = BottleReplacement.badge(package, intelbrewMode: intelbrew)
        let command = BrewCommands.display(BrewCommands.replaceWithBottleArguments(for: package))
        VStack(alignment: .leading, spacing: 7) {
            SourceBadge(kind: .bottle, label: label)
            Text(package.bottleTag.map { String(localized: "Built from source, but \(package.installedVersion) has a bottle for this Mac (\($0)). Replacing it pours the bottle instead; the version stays the same.") }
                 ?? String(localized: "Built from source, but \(package.installedVersion) has a bottle for this Mac. Replacing it pours the bottle instead; the version stays the same."))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            CommandBox(command: command)
            Button(action: action) {
                Label("Replace with Bottle", systemImage: "shippingbox")
            }
            .buttonStyle(.primaryAction)
            .disabled(!enabled)
            .help(command)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.badge(.bottle).background.opacity(0.6)))
    }
}

/// The bottom of the Installed detail pane: Uninstall…, or why not.
struct UninstallSection: View {
    var package: Package
    var dependents: [Package]
    var enabled: Bool
    var uninstall: () -> Void
    /// What runs (the sheet's commands, HOMEBREW_NO_AUTOREMOVE=1 included).
    var command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 4)
            if dependents.isEmpty {
                Button("Uninstall \(package.name)…", role: .destructive, action: uninstall)
                    .controlSize(.small)
                    .disabled(!enabled)
                    .help(command)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Can't uninstall: needed by \(dependents.count) installed packages", bundle: L10n.bundle))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(dependents.map(\.name).joined(separator: ", "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 12))
            }
        }
        .padding(.top, 4)
    }
}
