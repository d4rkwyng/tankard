import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.6 (part B): Export Brewfile… and Check a Brewfile… (Homebrew menu),
// and the sheet that shows the export summary, the check result and the
// restore plan. Tankard never runs a shell for the user and never reads
// or evaluates the Brewfile itself: brew bundle does.
//
//   TANKARD_DEMO_BREWFILE=export|check|plan   demo only: run that step on
//                                             a demo path (no panel)

/// The save and open panels.
@MainActor
enum BrewfilePanels {
    static let leftOut = "VS Code extensions and Mac App Store apps are left out (brew bundle dump --no-vscode --no-mas)."

    static func export(store: AppStore) {
        let panel = NSSavePanel()
        panel.title = "Export Brewfile"
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        panel.message = "VS Code extensions and App Store apps are left out."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The save panel has already asked "Replace?" when the file exists.
        let force = FileManager.default.fileExists(atPath: url.path)
        store.exportBrewfile(to: url.path, force: force)
    }

    static func check(store: AppStore) {
        let panel = NSOpenPanel()
        panel.title = "Check a Brewfile"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.checkBrewfile(at: url.path)
    }
}

/// The Brewfile items of the Homebrew menu. A view, so its store reads are
/// tracked here and not by App.body.
struct BrewfileMenuItems: View {
    var store: AppStore

    var body: some View {
        Button("Export Brewfile…") { BrewfilePanels.export(store: store) }
            .disabled(!store.canUseBrewfile)
            .help(BrewfilePanels.leftOut)
        Button("Check a Brewfile…") { BrewfilePanels.check(store: store) }
            .disabled(!store.canUseBrewfile)
            .help("Lists what a Brewfile needs that this Mac doesn't have (brew bundle check)")
    }
}

struct BrewfileSheet: View {
    var store: AppStore
    var brewfile: BrewfileStore
    @Environment(\.theme) private var theme

    private let terminalState = State(initialValue: false)
    private var showTerminal: Bool {
        get { terminalState.wrappedValue }
        nonmutating set { terminalState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch brewfile.page {
            case .idle:
                EmptyView()
            case .running(let label):
                running(label)
            case .planning:
                running("Reading package details…")
            case .exported(let s):
                exported(s)
            case .checked(let r):
                checked(r)
            case .plan(let p, let note):
                plan(p, note: note)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(theme.window ?? .clear)
    }

    private func header(_ icon: String, _ color: Color, _ title: String, _ subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color).frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .bold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }

    private func running(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(label).font(.system(size: 13))
            }
            Text("Stops by itself after 60 seconds.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { brewfile.dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func exported(_ s: BrewfileSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("checkmark.circle.fill", .green, "Brewfile saved", s.path)
            HStack(spacing: 10) {
                count(s.taps, "Taps")
                count(s.formulae, "Formulae")
                count(s.casks, "Casks")
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("VS Code extensions and App Store apps are left out.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .help(BrewfilePanels.leftOut + " Asking VS Code for its extensions can hang brew bundle dump.")
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)])
                }
                Spacer()
                Button("Done") { brewfile.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func count(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip))
    }

    private static let groups: [(BrewfileKind?, String)] = [(.tap, "Taps"), (.formula, "Formulae"), (.cask, "Casks"),
                                                            (.mas, "App Store apps"), (.vscode, "VS Code extensions"), (nil, "Other")]

    private func checked(_ r: BrewfileCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if r.isSatisfied {
                header("checkmark.circle.fill", .green, "Everything in this Brewfile is installed", r.path)
            } else {
                header("shippingbox", theme.accent, "\(r.missing.count) missing from this Mac", r.path)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.groups, id: \.1) { kind, title in
                            let names = r.names(kind)
                            if !names.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(title) (\(names.count))").font(.system(size: 12, weight: .semibold))
                                    ForEach(names, id: \.self) { n in
                                        Text(n).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A ScrollView in a sheet has no height of its own: size it to the list.
                .frame(height: min(CGFloat(r.missing.count) * 19 + CGFloat(Set(r.missing.map(\.kind)).count) * 30, 300))
            }
            HStack {
                Spacer()
                if r.isSatisfied {
                    Button("Done") { brewfile.dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { brewfile.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Restore Plan…") { brewfile.planRestore(r) }
                        .keyboardShortcut(.defaultAction)
                        .help("What installing the missing items would do, before anything runs")
                }
            }
        }
    }

    private func plan(_ p: BrewfileRestorePlan, note: String?) -> some View {
        let result = BrewfileCheckResult(path: p.path, missing: p.items.map(\.entry))
        return VStack(alignment: .leading, spacing: 12) {
            header("list.bullet.clipboard", theme.accent, "Restore plan", p.path)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(p.items) { item in planRow(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(p.items.count) * 27, 270))
            if !p.compiling.isEmpty {
                Label("\(p.compiling.count) would compile from source: no bottle for this Mac. That can take a long time.",
                      systemImage: "hammer.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if !p.adminCasks.isEmpty {
                Label("\(p.adminCasks.count) \(p.adminCasks.count == 1 ? "cask runs" : "casks run") a pkg installer: macOS asks for an administrator password.",
                      systemImage: "lock.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .help("Marked from the cask's pkg artifact. Other casks may still ask for a password.")
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if showTerminal {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run it yourself in Terminal:").font(.system(size: 11.5))
                    CommandBox(command: p.terminalCommand)
                }
            }
            HStack {
                Button("Back") { brewfile.back(to: result) }
                Spacer()
                Button(showTerminal ? "Hide Terminal Command" : "Show Terminal Command") { showTerminal.toggle() }
                    .help("brew bundle install with --no-upgrade, to copy. Tankard doesn't run it.")
                Button("Install with Tankard") { store.installBrewfilePlan(p) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(p.queued.isEmpty || store.isBusy)
                    .help("One brew install per formula and cask, through Tankard's queue and log. Taps aren't added.")
            }
        }
    }

    @ViewBuilder
    private func planRow(_ item: BrewfileRestorePlan.Item) -> some View {
        let e = item.entry
        HStack(spacing: 8) {
            Image(systemName: icon(e.kind)).foregroundStyle(.secondary).frame(width: 16)
            Text(e.name).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            if item.compiles == true {
                Label("Compiles", systemImage: "hammer.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange)
            }
            if item.needsAdmin {
                Label("Admin password", systemImage: "lock.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if e.kind == .tap {
                CommandBox(command: BrewfileCommands.tapDisplay(e.name)).frame(maxWidth: 250)
                    .help("Tankard doesn't add taps. Run this in Terminal first, or use the Terminal command below.")
            } else if !item.throughQueue {
                Text("Terminal only").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ k: BrewfileKind?) -> String {
        switch k {
        case .tap: return "point.3.connected.trianglepath.dotted"
        case .formula: return "terminal"
        case .cask: return "macwindow"
        default: return "questionmark.square.dashed"
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("exclamationmark.triangle.fill", .orange, "Brewfile", nil)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Done") { brewfile.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension BrewfileSheet {
    /// The sheet binding: a close from SwiftUI dismisses; an unchanged value
    /// writes nothing.
    @MainActor
    static func binding(_ brewfile: BrewfileStore) -> Binding<Bool> {
        Binding(get: { brewfile.isPresented }, set: { if !$0 && brewfile.isPresented { brewfile.dismiss() } })
    }
}

/// TANKARD_DEMO_BREWFILE (demo only).
@MainActor
func applyBrewfileLaunchOption(store: AppStore, options: LaunchOptions) async {
    guard options.demo != nil, let mode = ProcessInfo.processInfo.environment["TANKARD_DEMO_BREWFILE"]?.lowercased() else { return }
    let home = store.report?.host.prefix == "/usr/local" ? "/Users/demo" : "/Users/you"
    switch mode {
    case "export":
        store.exportBrewfile(to: home + "/Brewfile", force: false)
    case "check", "plan":
        store.checkBrewfile(at: home + "/Desktop/Brewfile")
        guard mode == "plan" else { return }
        await store.brewfile.waitForIdle()
        if case .checked(let r) = store.brewfile.page { store.brewfile.planRestore(r) }
    default:
        break
    }
}
