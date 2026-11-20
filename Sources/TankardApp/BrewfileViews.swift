import AppKit
import SwiftUI
import TankardAppModel
import TankardCore

// v0.6 (part B): Export Brewfile… and Check Brewfile… (File menu),
// and the sheet that shows the export summary, the check result and the
// restore plan. Tankard never runs a shell for the user and never
// evaluates the Brewfile itself. 0.8.8 (security review #2): Check shows
// the file's plain lines first (BrewfileStaticReader, nothing run) and
// asks before brew bundle check, which runs the file as Ruby.
//
//   TANKARD_DEMO_BREWFILE=export|check|plan   demo only: run that step on
//                                             a demo path (no panel)

/// The save and open panels.
@MainActor
enum BrewfilePanels {
    static let leftOut = String(localized: "VS Code extensions and Mac App Store apps are left out (brew bundle dump --no-vscode --no-mas).")

    static func export(store: AppStore) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Brewfile")
        panel.nameFieldStringValue = "Brewfile"
        panel.canCreateDirectories = true
        panel.message = String(localized: "VS Code extensions and App Store apps are left out.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The save panel has already asked "Replace?" when the file exists.
        let force = FileManager.default.fileExists(atPath: url.path)
        store.exportBrewfile(to: url.path, force: force)
    }

    static func check(store: AppStore) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Check a Brewfile")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.previewBrewfile(at: url.path)
    }
}

/// The Brewfile items of the File menu. A view, so its store reads are
/// tracked here and not by App.body.
struct BrewfileMenuItems: View {
    var store: AppStore

    var body: some View {
        // Opening one before exporting, as File menus order Open and Export.
        Button("Check Brewfile…") { BrewfilePanels.check(store: store) }
            .disabled(!store.canUseBrewfile || store.isSheetPresented)
            .help("Shows what a Brewfile lists, without running it")
        Button("Export Brewfile…") { BrewfilePanels.export(store: store) }
            .disabled(!store.canUseBrewfile || store.isSheetPresented)
            .help(BrewfilePanels.leftOut)
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
            case .preview(let p):
                preview(p)
            case .confirmRun(let p):
                confirmRun(p)
            case .running(let label):
                running(label)
            case .planning:
                running(String(localized: "Reading package details…"))
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
        .modifier(TapAddConfirmation(store: store, taps: store.taps))
    }

    private func header(_ icon: String, _ color: Color, _ title: String, _ subtitle: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color).frame(width: 40)
                .accessibilityHidden(true)
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
            header("checkmark.circle.fill", .green, String(localized: "Brewfile saved"), s.path)
            HStack(spacing: 10) {
                count(s.taps, String(localized: "Taps"))
                count(s.formulae, String(localized: "Formulae"))
                count(s.casks, String(localized: "Casks"))
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("VS Code extensions and App Store apps are left out.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .help(String(localized: "VS Code extensions and Mac App Store apps are left out."))
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
            Text(verbatim: "\(n)").font(.system(size: 22, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.chip))
    }

    private static let groups: [(BrewfileKind?, String)] = [(.tap, String(localized: "Taps")), (.formula, String(localized: "Formulae")), (.cask, String(localized: "Casks")),
                                                            (.mas, String(localized: "App Store apps")), (.vscode, String(localized: "VS Code extensions")), (nil, String(localized: "Other"))]

    private func checked(_ r: BrewfileCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if r.isSatisfied {
                header("checkmark.circle.fill", .green, String(localized: "Everything in this Brewfile is installed"), r.path)
            } else {
                header("shippingbox", theme.accent, String(localized: "\(r.missing.count) missing from this Mac"), r.path)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.groups, id: \.1) { kind, title in
                            let names = r.names(kind)
                            if !names.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: "\(title) (\(names.count))").font(.system(size: 12, weight: .semibold))
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

    /// 0.8.8: the plain lines, read without running the file.
    private func preview(_ p: BrewfilePreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header("doc.text.magnifyingglass", theme.accent, String(localized: "What this Brewfile lists"), p.path)
            Text("Read from the file's text. Nothing in it has run.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            if p.quarantined {
                Label("Downloaded from the internet", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.groups.filter { $0.0 != nil }, id: \.1) { kind, title in
                        let names = p.names(kind)
                        if !names.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: "\(title) (\(names.count))").font(.system(size: 12, weight: .semibold))
                                ForEach(Array(names.enumerated()), id: \.offset) { _, n in
                                    Text(verbatim: n).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !p.notRead.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: String(localized: "Not read: needs brew to evaluate") + " (\(p.notRead.count))")
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(p.notRead) { line in
                                Text(verbatim: "\(line.number): \(line.text)")
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                            }
                        }
                    }
                    if p.entries.isEmpty && p.notRead.isEmpty {
                        Text("No packages listed.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(p.entries.count + p.notRead.count) * 19 + 5 * 30, 300))
            HStack {
                Spacer()
                Button("Close") { brewfile.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Check with brew…") { brewfile.requestBrewCheck() }
                    .disabled(!store.canUseBrewfile)
                    .help("Runs brew bundle check, which runs this file's code, after you confirm")
            }
        }
    }

    /// 0.8.8: before brew bundle check runs the file.
    private func confirmRun(_ p: BrewfilePreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(p.quarantined ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                   p.quarantined ? .red : .orange, String(localized: "Run this Brewfile's code?"), p.path)
            ForEach(Array(BrewfileStore.runWarning(quarantined: p.quarantined).enumerated()), id: \.offset) { i, text in
                Text(verbatim: text)
                    .font(.system(size: 12, weight: p.quarantined && i == 0 ? .semibold : .regular))
                    .foregroundStyle(p.quarantined && i == 0 ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Back") { brewfile.cancelBrewCheck() }.keyboardShortcut(.cancelAction)
                Button("Run brew bundle check") { store.confirmBrewfileCheck() }
                    .disabled(!store.canUseBrewfile)
            }
        }
    }

    private func plan(_ p: BrewfileRestorePlan, note: String?) -> some View {
        let result = BrewfileCheckResult(path: p.path, missing: p.items.map(\.entry))
        return VStack(alignment: .leading, spacing: 12) {
            header("list.bullet.clipboard", theme.accent, String(localized: "Restore plan"), p.path)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(p.items) { item in planRow(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(p.items.count) * 27, 270))
            // These notes wrap rather than cut off: German and French run a
            // third longer than English and the sheet doesn't widen. The
            // tooltip has the full sentence too.
            if !p.compiling.isEmpty {
                let text = String(localized: "\(p.compiling.count) would compile from source: no bottle for this Mac. That can take a long time.", bundle: L10n.bundle)
                Label(text, systemImage: "hammer.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
                    .lineLimit(2...3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(text)
            }
            if !p.adminCasks.isEmpty {
                let text = String(localized: "\(p.adminCasks.count) casks run a pkg installer: macOS asks for an administrator password.", bundle: L10n.bundle)
                Label(text, systemImage: "lock.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2...3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(text + "\n" + String(localized: "Marked from the cask's pkg artifact. Other casks may still ask for a password."))
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if !p.missingTaps.isEmpty && !p.queued.isEmpty {
                Label("Add the taps first (Add Tap…), then check the Brewfile again to install the rest.", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(2...3)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button(showTerminal ? String(localized: "Hide Terminal Command") : String(localized: "Show Terminal Command")) { showTerminal.toggle() }
                    .help("A Terminal command you can copy to install everything in this Brewfile. Tankard doesn't run it.")
                Button("Install with Tankard") { store.installBrewfilePlan(p) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!p.canInstallWithTankard || store.isBusy)
                    .help("Installs each missing package, one at a time. Add any extra catalogs (taps) first with Add Tap….")
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
            if item.isBuiltInTap {
                // 0.8.9: homebrew/core and homebrew/cask need no tap.
                Text("Built into Homebrew").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .help("Homebrew installs from this catalog without adding it. Nothing to do.")
            } else if e.kind == .tap {
                // 0.7: Add Tap… asks first (the third-party warning), then
                // runs brew tap through the queue and the live log.
                // 0.8.5 (M3): with the Brewfile's URL, shown here and in the
                // confirmation. A tap line Tankard can't read is Terminal only.
                if item.canAddTap {
                    if let url = item.tapURL {
                        Text(verbatim: url).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Button("Add Tap…") { store.taps.requestAdd(name: e.name, url: item.tapURL ?? "", source: .brewfile) }
                        .controlSize(.small)
                        .disabled(store.isBusy || TapInput.problem(name: e.name, url: item.tapURL ?? "") != nil)
                        .help(BrewfileCommands.tapDisplay(e.name, url: item.tapURL) + String(localized: ", after you confirm"))
                } else {
                    Text("Terminal only").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .help("Tankard couldn't read where this tap comes from in the Brewfile. Use the Terminal command below.")
                }
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
            header("exclamationmark.triangle.fill", .orange, String(localized: "Brewfile"), nil)
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
