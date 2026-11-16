import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

/// Shown instead of the main window when there is no working brew: what
/// Homebrew is, how to install it (in Terminal, never inside the app), and
/// Check again.
struct WelcomeView: View {
    @Bindable var store: AppStore
    var isDemo: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let options = HomebrewInstaller.options(for: store.deps.hardware)
        ScrollView {
            VStack(spacing: 18) {
                BrandMark(size: 128, intelbrew: store.deps.hardware.isIntel)
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    Text("Homebrew is the package manager for macOS: it installs command-line tools and apps and keeps them up to date. Tankard is a window onto it, so it needs Homebrew first.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                if case .broken(let path, let detail) = store.homebrewState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(path) is there but doesn't run. It said:")
                            .font(.system(size: 12, weight: .medium))
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.chip))
                        Text("Reinstalling usually fixes this:").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 560)
                }

                VStack(spacing: 12) {
                    ForEach(Array(options.enumerated()), id: \.element) { i, installer in
                        InstallerCard(installer: installer, primary: i == 0, isDemo: isDemo)
                    }
                }
                .frame(maxWidth: 560)

                VStack(spacing: 6) {
                    Button {
                        Task { await store.checkAgain() }
                    } label: {
                        if store.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Check again", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.large)
                    .disabled(store.isRefreshing)
                    Text("Tankard looks for brew at \(BrewInstallation.candidates.joined(separator: " and ")), or TANKARD_BREW.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.window ?? .clear)
    }

    private var title: String {
        if case .broken = store.homebrewState { return "Homebrew isn't working" }
        return "Homebrew isn't installed"
    }
}

struct InstallerCard: View {
    var installer: HomebrewInstaller
    var primary: Bool
    var isDemo: Bool
    @Environment(\.theme) private var theme
    private let failure = State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(installer.title).font(.system(size: 14, weight: .semibold))
            Text(installer.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CommandBox(command: installer.command)
            HStack(spacing: 8) {
                if primary {
                    Button("Open in Terminal", action: open)
                        .buttonStyle(.borderedProminent)
                        .modifier(OnAccentLabel(theme: theme))
                } else {
                    Button("Open in Terminal", action: open)
                }
                Button("Copy command") { copyToPasteboard(installer.command) }
                Spacer()
                if let f = failure.wrappedValue {
                    Text(f).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            .controlSize(.regular)
            Text("The installer asks for your password and runs in Terminal. When it finishes, come back and click Check again.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(primary ? theme.accent.opacity(0.10) : theme.chip))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? theme.accent.opacity(0.45) : Color.clear, lineWidth: 1))
    }

    /// Writes the one-liner to a temporary .command file and opens it, which
    /// starts Terminal. Demo mode never opens anything.
    private func open() {
        if isDemo {
            failure.wrappedValue = "Demo mode: Terminal not opened."
            return
        }
        do {
            let url = try installer.writeScript()
            if !NSWorkspace.shared.open(url) { failure.wrappedValue = "Couldn't open Terminal. Copy the command instead." }
        } catch {
            failure.wrappedValue = "Couldn't write the script: \(error.localizedDescription)"
        }
    }
}
