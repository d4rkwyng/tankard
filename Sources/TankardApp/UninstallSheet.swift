import SwiftUI
import TankardAppModel
import TankardCore

/// "Uninstall xz?" with the exact command. When installed packages still
/// need it, the sheet lists them and offers no Uninstall button. 0.8: a
/// pinned package (brew refuses it and still exits 0) offers Unpin and
/// Uninstall instead.
struct UninstallSheet: View {
    @Bindable var store: AppStore
    var package: Package
    @Environment(\.theme) private var theme

    var body: some View {
        let dependents = store.dependents(of: package)
        let pinned = dependents.isEmpty && package.pinned
        // 0.8: what nothing would need any more (only this package's own dependencies).
        let orphans = dependents.isEmpty ? store.uninstallOrphans(of: package) : []
        let command = AppStore.uninstallDisplay(package)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: pinned ? "pin.fill" : dependents.isEmpty ? "trash" : "lock.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(dependents.isEmpty && !pinned ? Color.red : Color.orange)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pinned ? String(localized: "\(package.name) is pinned")
                         : dependents.isEmpty ? String(localized: "Uninstall \(package.name)?") : String(localized: "\(package.name) can't be uninstalled"))
                        .font(.system(size: 14, weight: .bold))
                    Text(pinned
                         ? String(localized: "Homebrew doesn't uninstall pinned packages. Unpin \(package.name) first, or keep it.")
                         : dependents.isEmpty
                         ? AppStore.uninstallSummary(package, dependenciesStay: orphans.isEmpty)
                         : String(localized: "These installed packages need it. Uninstall them first, or keep \(package.name)."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if dependents.isEmpty {
                if !orphans.isEmpty { orphanSection(orphans) }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Command").font(.system(size: 11)).foregroundStyle(.secondary)
                    if pinned { CommandBox(command: PinCommands.display(pin: false, for: package)) }
                    CommandBox(command: command)
                    if store.uninstallRemovesOrphans, !orphans.isEmpty {
                        CommandBox(command: orphans.map { AppStore.uninstallDisplay($0) }.joined(separator: "\n"))
                    }
                }
                // 0.8.3: a pkg cask's uninstall runs sudo (pkgutil, its files).
                if AdminPassword.required(package) {
                    AdminPasswordNote(names: [package.name], helper: store.deps.askpassHelper != nil, uninstall: true,
                                      foreign: store.foreignAskpass())
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
                    if pinned {
                        Button("Unpin and Uninstall", role: .destructive) { store.unpinAndUninstall(package) }
                            .disabled(store.isBusy)
                    } else {
                        Button("Uninstall", role: .destructive) { store.startUninstall(package) }
                            .disabled(store.isUpgrading)
                    }
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

    /// "No longer needed by anything: a, b" with "Also remove these".
    private func orphanSection(_ orphans: [Package]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "No longer needed by anything: \(orphans.map(\.name).sorted().joined(separator: ", "))"))
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also remove these", isOn: $store.uninstallRemovesOrphans)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Text(String(localized: "Only what \(package.name) needed. Dependencies that were already unused stay installed."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip))
    }
}
