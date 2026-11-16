import SwiftUI
import TankardAppModel
import TankardCore

/// "Uninstall xz?" with the exact command. When installed packages still
/// need it, the sheet lists them and offers no Uninstall button.
struct UninstallSheet: View {
    @Bindable var store: AppStore
    var package: Package
    @Environment(\.theme) private var theme

    var body: some View {
        let dependents = store.dependents(of: package)
        let command = BrewCommands.display(BrewCommands.uninstallArguments(for: package))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: dependents.isEmpty ? "trash" : "lock.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(dependents.isEmpty ? Color.red : Color.orange)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(dependents.isEmpty ? "Uninstall \(package.name)?" : "\(package.name) can't be uninstalled")
                        .font(.system(size: 14, weight: .bold))
                    Text(dependents.isEmpty
                         ? "Removes \(package.name) \(package.installedVersion). Its dependencies stay installed."
                         : "These installed packages need it. Uninstall them first, or keep \(package.name).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if dependents.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                    CommandBox(command: command)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(dependents) { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.kind == .cask ? "macwindow" : "shippingbox").foregroundStyle(.secondary)
                            Text(d.name).font(.system(size: 12, weight: .medium))
                            if !d.requested {
                                Text("dependency").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip))
            }
            HStack {
                Spacer()
                if dependents.isEmpty {
                    Button("Cancel") { store.uninstallCandidate = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Uninstall", role: .destructive) { store.startUninstall(package) }
                        .disabled(store.isUpgrading)
                } else {
                    Button("OK") { store.uninstallCandidate = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(theme.window ?? .clear)
    }
}
