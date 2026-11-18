import SwiftUI
import TankardAppModel
import TankardCore

/// 0.8.5: marks an installed cask whose app is an Electron app, on a Mac
/// Pro (Late 2013) running a newer macOS (ElectronGPU.swift). In the
/// Package column's trailing area.
struct ElectronMark: View {
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = prominence == .increased && !theme.isCustom
        Image(systemName: "info.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(Color.orange))
            .frame(width: PackageRow.trailingBadge, height: PackageRow.trailingBadge)
            .fixedSize()
            .help("Electron app: may draw incorrectly on this Mac's graphics card")
            .accessibilityElement()
            .accessibilityLabel(Text("Electron app"))
            .accessibilityHint(Text("Electron app: may draw incorrectly on this Mac's graphics card"))
    }
}

/// 0.8.5: the cask detail's explanation, with the app's Chromium version
/// (read when shown, off the main thread, and cached).
struct ElectronDetailSection: View {
    var package: Package
    @Environment(AppStore.self) private var store: AppStore?

    var body: some View {
        if let electron = store?.electron, electron.isElectron(package) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Electron app", systemImage: "info.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("This app is built with Electron. On this Mac's graphics card, with a newer macOS installed by OpenCore Legacy Patcher, apps like it may draw incorrectly: blank, black or flickering windows, or garbled text. Tankard doesn't change the app.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    switch electron.chromiumState(for: package) {
                    case .version(let v)?:
                        Text("Chromium version: \(v)")
                    case .unknown?:
                        Text("Chromium version: unknown")
                    case .reading?, nil:
                        Text("Chromium version: reading…")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
            .task(id: package.installedVersion) { electron.loadChromium(for: package) }
        }
    }
}
