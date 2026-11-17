import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.4 (part A): the Homebrew menu's sheets. Each shows every command
// first, asks for a typed word, then writes a `.command` script and opens
// it in Terminal. Nothing runs inside the app. Demo mode opens nothing.

struct HomebrewManagementSheet: View {
    @Bindable var store: AppStore
    var kind: HomebrewManagement.Kind
    var isDemo: Bool
    @Environment(\.theme) private var theme

    private let typedState: State<String>
    private let openedState = State(initialValue: false)
    private let failureState = State(initialValue: String?.none)
    private let planState: State<RevertPlan?>

    init(store: AppStore, kind: HomebrewManagement.Kind, isDemo: Bool) {
        self.store = store
        self.kind = kind
        self.isDemo = isDemo
        let prefill = isDemo ? ProcessInfo.processInfo.environment["TANKARD_DEMO_TYPED"] : nil
        typedState = State(initialValue: prefill ?? "")
        planState = State(initialValue: store.revertPlan())
    }

    private var typed: Binding<String> {
        Binding(get: { typedState.wrappedValue }, set: { typedState.wrappedValue = $0 })
    }

    var body: some View {
        let plan = planState.wrappedValue
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch kind {
                    case .revert: revertBody(plan)
                    case .uninstall: uninstallBody(plan)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            if openedState.wrappedValue {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    Text(kind == .revert
                         ? "Opened in Terminal. It lists the commands again and waits for Return. When it finishes, open a new terminal window and click Refresh here."
                         : "Opened in Terminal. It waits for Return, then Homebrew's uninstaller asks once more. When it finishes, quit Tankard.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                confirmation
            }
            if let f = failureState.wrappedValue {
                Text(f).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            buttons(plan)
        }
        .padding(20)
        .frame(width: 560)
        .background(theme.window ?? .clear)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .revert ? "arrow.uturn.backward.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(kind == .revert ? Color.orange : Color.red)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .revert ? "Revert to standard Homebrew?" : "Uninstall Homebrew?")
                    .font(.system(size: 14, weight: .bold))
                Text(kind == .revert
                     ? "Takes this Mac off Intelbrew: brew goes back to Homebrew's own repository and its API. Your installed packages stay as they are."
                     : "Removes Homebrew and every package installed with it: \(store.packages.filter { $0.kind == .formula }.count) formulae and \(store.packages.filter { $0.kind == .cask }.count) casks. This can't be undone.")
                    .font(.system(size: 12))
                    .foregroundStyle(kind == .revert ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func revertBody(_ plan: RevertPlan?) -> some View {
        if let plan {
            step("1. Remove the Intelbrew lines from your shell profile",
                 plan.edits.isEmpty
                 ? "None of your zsh or bash startup files sets them, so nothing is edited."
                 : "Each file is backed up first, next to itself (….\(plan.backupSuffix)). These lines are removed:")
            ForEach(plan.edits) { e in
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.label).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    ForEach(Array(e.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.chip))
            }
            if !plan.brewEnvNotes.isEmpty {
                note("A brew.env file also sets an Intelbrew variable. Tankard doesn't edit brew.env; remove it by hand, or brew keeps using the fork:\n" + plan.brewEnvNotes.joined(separator: "\n"))
            }
            step("2. Point Homebrew/brew back at upstream, then 3. brew update",
                 "The variables are unset first, so this brew update doesn't put the fork back.")
            commandList(plan.commands)
            note("Optional, not run: delete the core clone with brew untap homebrew/core. Terminal windows that were already open keep the old settings until reopened. From d4rkwyng/intelbrew's README, \"How do I go back to upstream Homebrew?\".")
        } else {
            Text("Not in Intelbrew mode: nothing to revert.").font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func uninstallBody(_ plan: RevertPlan?) -> some View {
        step("Homebrew's official uninstaller", "From the Homebrew/install README (\"Uninstall Homebrew\"), with its --path option so it removes only the Homebrew Tankard is showing. It runs in Terminal and asks once more before removing anything.")
        if let prefix = store.report?.host.prefix {
            CommandBox(command: HomebrewManagement.uninstallCommand(prefix: prefix))
            note("It deletes \(prefix)'s Homebrew files and every installed formula and cask, including apps installed as casks in /Applications. Another Homebrew on this Mac (in a different prefix) is left alone. It may ask for your password.")
        } else {
            note("Tankard hasn't read this Mac's Homebrew prefix yet. Refresh first.")
        }
        if let plan, !plan.edits.isEmpty {
            note("Intelbrew's lines stay in your shell profile (\(plan.edits.map(\.label).joined(separator: ", "))); remove them by hand afterwards, or use Revert to Standard Homebrew first.")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 5) {
            (Text("Type ") + Text(kind.confirmationWord).font(.system(size: 12, weight: .bold, design: .monospaced)) + Text(" to confirm"))
                .font(.system(size: 12))
            TextField(kind.confirmationWord, text: typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: 220)
                .onSubmit { if confirmed { open() } }
        }
    }

    private var confirmed: Bool { HomebrewManagement.isConfirmed(typedState.wrappedValue, for: kind) }

    private func buttons(_ plan: RevertPlan?) -> some View {
        HStack {
            Spacer()
            if openedState.wrappedValue {
                Button("Done") { store.managementSheet = nil }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { store.managementSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    open()
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .disabled(!confirmed || (kind == .revert && plan == nil) || (kind == .uninstall && store.report == nil))
                .help("Writes a .command script with exactly these commands and opens it in Terminal")
            }
        }
    }

    private func open() {
        guard confirmed else { return }
        let script: String
        switch kind {
        case .revert:
            guard let plan = planState.wrappedValue else { return }
            script = plan.script
        case .uninstall:
            guard let prefix = store.report?.host.prefix else { return }
            script = HomebrewManagement.uninstallScript(prefix: prefix)
        }
        if isDemo {
            failureState.wrappedValue = "Demo mode: Terminal not opened."
            return
        }
        do {
            let url = try TerminalScript.write(script, name: kind.rawValue)
            if NSWorkspace.shared.open(url) {
                openedState.wrappedValue = true
            } else {
                failureState.wrappedValue = "Couldn't open Terminal. Copy the commands instead."
            }
        } catch {
            failureState.wrappedValue = "Couldn't write the script: \(error.localizedDescription)"
        }
    }

    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func commandList(_ commands: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(commands.enumerated()), id: \.offset) { _, c in
                    Text(c).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copyToPasteboard(commands.joined(separator: "\n"))
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help("Copy the commands")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.chip))
    }
}
