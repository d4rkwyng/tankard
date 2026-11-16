import SwiftUI
import TankardAppModel
import TankardCore

struct DetailPane: View {
    @Bindable var store: AppStore

    var body: some View {
        if let p = store.selectedPackage {
            PackageDetail(package: p, intelbrew: store.intelbrewMode, canUpgrade: !store.isUpgrading) {
                store.startUpgrade([p])
            }
            .id(p.id)
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
    var upgrade: () -> Void

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
                        Image(systemName: "arrow.up.circle").foregroundStyle(Color.accentColor)
                        (Text("Upgrade ready: ") + Text("\(p.installedVersion) → \(p.currentVersion ?? "?")")
                            .foregroundColor(.accentColor).fontWeight(.semibold))
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
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
                        Button("Upgrade \(p.name)", action: upgrade)
                            .controlSize(.small)
                            .disabled(!canUpgrade)
                    }
                }

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
                Image(systemName: "checkmark.circle").foregroundStyle(BadgePalette.of(.bottle).dot)
                if let repo = p.bottleRepository {
                    (Text("Poured from ") + Text(repo).font(.system(size: 11, design: .monospaced)) + Text(" release"))
                } else if p.bottleOrigin == .homebrew {
                    Text("Poured from a Homebrew bottle (ghcr.io)")
                } else {
                    Text("Poured from a bottle")
                }
            case .source:
                Image(systemName: "hammer").foregroundStyle(BadgePalette.of(.source).dot)
                Text(p.currentHasBottle == true ? "Built from source; a bottle exists for the current version" : "Built from source")
            case .newer:
                Image(systemName: "arrow.up.forward.circle").foregroundStyle(BadgePalette.of(.newer).dot)
                Text("Installed version is newer than the tap's \(p.currentVersion ?? "?"). brew won't downgrade it.")
            case .noBottle:
                Image(systemName: "exclamationmark.circle").foregroundStyle(BadgePalette.of(.noBottle).dot)
                Text("No bottle for this Mac yet. Reinstalling or upgrading compiles from source.")
            case .cask:
                Image(systemName: "macwindow").foregroundStyle(BadgePalette.of(.cask).dot)
                Text("Cask: installs the vendor's app; no bottles.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
