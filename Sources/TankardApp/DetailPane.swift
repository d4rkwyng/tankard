import SwiftUI
import TankardAppModel
import TankardCore

struct DetailPane: View {
    @Bindable var store: AppStore

    var body: some View {
        if let p = store.selectedPackage {
            let _ = store.buildTimesRevision
            PackageDetail(package: p, intelbrew: store.intelbrewMode, canUpgrade: !store.isUpgrading,
                          dependents: store.dependents(of: p),
                          compileWarning: store.deps.classifier.upgradeWarning(p),
                          upgrade: { store.requestUpgrade([p]) },
                          uninstall: { store.requestUninstall(p) },
                          replaceWithBottle: { store.startReplaceWithBottle([p]) })
            .id(p.id)
            .task(id: p.id) { if store.deps.classifier.upgradeWarning(p) != nil { store.compileWarningShown() } }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.tertiary)
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
    /// Installed packages that need this one (uninstall is blocked).
    var dependents: [Package]
    var compileWarning: CompileWarning?
    var upgrade: () -> Void
    var uninstall: () -> Void
    var replaceWithBottle: () -> Void
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
                        Text(p.desc ?? (p.kind == .cask ? "Cask" : "Formula"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }

                if p.upgradeAvailable {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle").foregroundStyle(theme.upgrade)
                        (Text("Upgrade ready: ") + Text("\(p.installedVersion) → \(p.currentVersion ?? "?")")
                            .foregroundColor(theme.upgrade).fontWeight(.semibold))
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

                if BottleReplacement.isEligible(p) {
                    ReplaceWithBottleBox(package: p, intelbrew: intelbrew, enabled: canUpgrade, action: replaceWithBottle)
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    row("Installed", p.installedVersion)
                    if p.installedVersions.count > 1 {
                        row("Kegs", p.installedVersions.joined(separator: ", "))
                    }
                    row("Available", p.currentVersion ?? "–")
                    if p.kind == .formula {
                        row("Bottle tag", p.bottleTag ?? "none for this Mac", mono: p.bottleTag != nil)
                        if let origin = p.bottleOrigin {
                            row("Bottle from", originText(origin))
                        }
                        row("Installed as", p.requested ? "Requested" : "Dependency")
                    } else {
                        row("Kind", p.autoUpdates == true ? "Cask, updates itself" : "Cask")
                    }
                    if let date = p.installedAt {
                        row("Installed on", date.formatted(Self.dateFormat))
                    }
                    if let tap = p.tap { row("Tap", tap, mono: true) }
                    if p.pinned { row("Pinned", "Yes") }
                }
                .font(.system(size: 12))

                Divider()

                sourceLine(p).font(.system(size: 12))

                if p.upgradeAvailable {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Upgrade command").font(.system(size: 11)).foregroundStyle(.secondary)
                        CommandBox(command: BrewCommands.upgradeDisplay(for: p))
                        Button(action: upgrade) {
                            Label("Upgrade \(p.name)", systemImage: "arrow.up")
                        }
                        .buttonStyle(.primaryAction)
                        .disabled(!canUpgrade)
                    }
                }

                UninstallSection(package: p, dependents: dependents, enabled: canUpgrade, uninstall: uninstall)

                if let page = p.releasePageURL {
                    Link(destination: page) {
                        HStack(spacing: 3) {
                            Text("Open release page")
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
        case .other: return "Other"
        }
    }

    @ViewBuilder
    private func sourceLine(_ p: Package) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch p.status {
            case .bottle:
                Image(systemName: "checkmark.circle").foregroundStyle(theme.badge(.bottle).dot)
                if let repo = p.bottleRepository {
                    (Text("Poured from ") + Text(repo).font(.system(size: 11, design: .monospaced)) + Text(" release"))
                } else if p.bottleOrigin == .homebrew {
                    Text("Poured from a Homebrew bottle (ghcr.io)")
                } else {
                    Text("Poured from a bottle")
                }
            case .source:
                Image(systemName: "hammer").foregroundStyle(theme.badge(.source).dot)
                Text(p.currentHasBottle == true ? "Built from source; a bottle exists for the current version" : "Built from source")
            case .newer:
                Image(systemName: "arrow.up.forward.circle").foregroundStyle(theme.badge(.newer).dot)
                Text("Installed version is newer than the tap's \(p.currentVersion ?? "?"). brew won't downgrade it.")
            case .noBottle:
                Image(systemName: "exclamationmark.circle").foregroundStyle(theme.badge(.noBottle).dot)
                Text("No bottle for this Mac yet. Reinstalling or upgrading compiles from source.")
            case .cask:
                Image(systemName: "macwindow").foregroundStyle(theme.badge(.cask).dot)
                Text("Cask: installs the vendor's app; no bottles.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
            Text("Built from source, but \(package.installedVersion) has a bottle for this Mac\(package.bottleTag.map { " (\($0))" } ?? ""). Replacing it pours the bottle instead; the version stays the same.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            CommandBox(command: command)
            Button("Replace with bottle", action: action)
                .controlSize(.small)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 4)
            if dependents.isEmpty {
                Button("Uninstall \(package.name)…", role: .destructive, action: uninstall)
                    .controlSize(.small)
                    .disabled(!enabled)
                    .help(BrewCommands.display(BrewCommands.uninstallArguments(for: package)))
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Can't uninstall: needed by \(dependents.count) installed package\(dependents.count == 1 ? "" : "s")")
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
