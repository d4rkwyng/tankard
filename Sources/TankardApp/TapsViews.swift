import SwiftUI
import TankardAppModel
import TankardCore

// v0.7: Homebrew ▸ Taps…. The list from `brew tap-info --installed --json`,
// Add (brew tap), Remove (brew untap, blocked while packages from the tap
// are installed), Trust (brew trust --tap), and Show Installed.
//
//   TANKARD_DEMO_SHEET=taps          demo: open the sheet
//   TANKARD_DEMO_TAP_SELECT=<name>   demo: select a tap
//   TANKARD_DEMO_TAP_ADD=<user/repo> demo: open Add's confirmation
//   TANKARD_DEMO_TAP_REMOVE=1        demo: ask to remove the selection
//   TANKARD_DEMO_TAP_SHOW=1          demo: Show Installed for the selection

/// The Homebrew menu item. A view, so its store reads aren't tracked by App.body.
struct TapsCommands: View {
    var store: AppStore

    var body: some View {
        Button("Taps…") { store.openTaps() }
            .disabled(store.report == nil || store.menuActionsBlocked)
    }
}

/// An alert binding that writes nothing when unchanged.
@MainActor
private func pendingBinding(_ isSet: @escaping @MainActor () -> Bool, _ cancel: @escaping @MainActor () -> Void) -> Binding<Bool> {
    Binding(get: { isSet() }, set: { if !$0 && isSet() { cancel() } })
}

/// Add's confirmation: the third-party warning and the exact command.
/// Shared by the Taps sheet and the Brewfile restore plan.
struct TapAddConfirmation: ViewModifier {
    var store: AppStore
    var taps: TapsStore
    /// 0.8.5: only requests from here (Discover's banner), so two views
    /// never present the same alert.
    var only: TapAddRequest.Source? = nil

    func body(content: Content) -> some View {
        let only = only
        let mine: @MainActor () -> Bool = { taps.pendingAdd.map { only == nil || $0.source == only } ?? false }
        return content.alert(taps.pendingAdd.map { String(localized: "Add \($0.name)?") } ?? String(localized: "Add tap?"),
                      isPresented: pendingBinding(mine, { taps.cancelPending() }),
                      presenting: taps.pendingAdd) { _ in
            Button("Cancel", role: .cancel) { taps.cancelPending() }
            Button("Add Tap") { store.confirmAddTap() }
        } message: { req in
            Text(req.warning + String(localized: "\n\nTankard runs: ") + req.command)
        }
    }
}

struct TapsSheet: View {
    @Bindable var store: AppStore
    var taps: TapsStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    private let name = State(initialValue: "")
    private let url = State(initialValue: "")
    private let problem = State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(icon: "point.3.connected.trianglepath.dotted", title: String(localized: "Taps"),
                        subtitle: String(localized: "Where Homebrew gets formulae and casks. Click a tap to see what you installed from it."))
            HStack(spacing: 8) {
                ThemedSegmentedPicker(title: String(localized: "Show"), selection: Binding(get: { taps.filter }, set: { taps.setFilter($0) }),
                                      options: TapsFilter.allCases, label: \.title)
                Spacer()
                Text("\(taps.visibleTaps.count) of \(taps.taps.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            list
            if let tap = taps.selectedTap { actions(tap) }
            addRow
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help("Extra package catalogs added to Homebrew. Official ones are read online and don't need adding.")
                Text("Add, Remove and Trust go through Tankard's queue and History.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { store.closeToolSheet() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .sheetFrame(width: 720, height: 580, store: store)
        .escapeCloses { store.closeToolSheet() }
        .background(theme.window ?? .clear)
        .modifier(TapAddConfirmation(store: store, taps: taps))
        .modifier(TapsAlerts(store: store, taps: taps))
    }

    @ViewBuilder
    private var list: some View {
        switch taps.phase {
        // Each pattern needs its own `where`: on `.idle, .loading where …`
        // the condition applied to .loading only (a compiler warning).
        case .idle where taps.taps.isEmpty, .loading where taps.taps.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading taps…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where taps.taps.isEmpty:
            Text(message).font(.system(size: 12)).foregroundStyle(theme.warning(scheme).text).textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(taps.visibleTaps) { t in row(t) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.chip))
    }

    private func row(_ t: TapInfo) -> some View {
        let selected = taps.selection == t.id
        let installed = store.installedCount(from: t)
        var facts = [t.formulaCount == 1 ? String(localized: "1 formula") : String(localized: "\(t.formulaCount) formulae"), t.caskCount == 1 ? String(localized: "1 cask") : String(localized: "\(t.caskCount) casks"),
                     String(localized: "\(installed) installed from it")]
        // 0.8.6 (M1): counted above, and said apart: brew can't read them.
        let unreadable = store.unreadableCount(from: t)
        if unreadable > 0 { facts.append(String(localized: "\(unreadable) of them Homebrew can't read")) }
        if let last = t.lastCommit { facts.append(String(localized: "updated \(last)")) }
        return Button {
            taps.select(selected ? nil : t.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    chip(t.originLabel, t.official ? theme.accent : .secondary)
                    if !t.official, let trusted = t.trusted {
                        chip(trusted ? String(localized: "Trusted") : String(localized: "Not trusted"), trusted ? theme.accent : theme.warning(scheme).text)
                    }
                    if !t.tapped { chip(String(localized: "Online"), .secondary).help(String(localized: "Read online from Homebrew; nothing to download.")) }
                    if t.isPrivate { chip(String(localized: "Private"), .secondary) }
                    Spacer()
                }
                Text(t.remote ?? String(localized: "Homebrew's API (formulae.brew.sh)"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(facts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.chip : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actions(_ t: TapInfo) -> some View {
        let removal = TapRemoval.check(t, packages: store.packages)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(t.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Show Installed") { store.showInstalled(from: t) }
                    .disabled(store.installedCount(from: t) == 0)
                    .help("The Installed list, filtered to this tap (tap:\(t.name))")
                if !t.official, t.trusted != nil {
                    Button(t.trusted == true ? String(localized: "Stop Trusting…") : String(localized: "Trust…")) { taps.requestTrust(t) }
                        .disabled(store.isBusy)
                }
                Button("Remove…") { _ = taps.requestRemove(t, packages: store.packages) }
                    .disabled(!removal.isAllowed || store.isBusy)
            }
            if let reason = removal.reason {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.chip))
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("user/repo", text: name.projectedValue).frame(width: 200)
                TextField("URL (optional)", text: url.projectedValue)
                Button("Add Tap…") {
                    let p = taps.requestAdd(name: name.wrappedValue, url: url.wrappedValue)
                    problem.wrappedValue = p?.description
                    if p == nil { name.wrappedValue = ""; url.wrappedValue = "" }
                }
                .disabled(name.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || store.isBusy)
            }
            .font(.system(size: 12))
            if let p = problem.wrappedValue ?? TapInput.problem(name: name.wrappedValue, url: url.wrappedValue)
                .flatMap({ $0 == .emptyName ? nil : $0.description }) {
                Text(p).font(.system(size: 11)).foregroundStyle(theme.warning(scheme).text)
            }
        }
    }
}

/// Remove's and Trust's confirmations.
struct TapsAlerts: ViewModifier {
    var store: AppStore
    var taps: TapsStore

    func body(content: Content) -> some View {
        content
            .alert(taps.pendingRemove.map { String(localized: "Remove \($0.name)?") } ?? String(localized: "Remove tap?"),
                   isPresented: pendingBinding({ taps.pendingRemove != nil }, { taps.cancelPending() }),
               presenting: taps.pendingRemove) { _ in
            Button("Cancel", role: .cancel) { taps.cancelPending() }
            Button("Remove", role: .destructive) { store.confirmRemoveTap() }
        } message: { t in
            // 0.8.5 (L8): a third-party tap's trust goes with it.
            Text((t.official ? String(localized: "Nothing installed comes from it. brew deletes its local copy; you can add it again later.")
                  : String(localized: "Nothing installed comes from it. brew deletes its local copy and stops trusting it; if you add it again later, Tankard asks again."))
                 + "\n\n" + String(localized: "Tankard runs:") + " "
                 + TapCommands.remove(t.name, official: t.official).map(BrewCommands.display).joined(separator: "\n"))
        }
            .alert(taps.pendingTrust.map { $0.trusted == true ? String(localized: "Stop trusting \($0.name)?") : String(localized: "Trust \($0.name)?") } ?? String(localized: "Trust?"),
               isPresented: pendingBinding({ taps.pendingTrust != nil }, { taps.cancelPending() }),
               presenting: taps.pendingTrust) { t in
            Button("Cancel", role: .cancel) { taps.cancelPending() }
            Button(t.trusted == true ? String(localized: "Stop Trusting") : String(localized: "Trust")) { store.confirmTrustTap() }
        } message: { t in
            Text((t.trusted == true
                  ? String(localized: "brew no longer counts this tap as trusted (brew untrust: \"Stop trusting non-official tap formulae, casks or commands\").")
                  : String(localized: "brew trust: \"Trust non-official tap formulae, casks or commands so Homebrew may load them.\" They are its author's Ruby code. Trust only taps whose author you trust."))
                 + String(localized: "\n\nTankard runs: ") + BrewCommands.display(TapCommands.trust(t.name, t.trusted != true)))
        }
    }
}

/// 0.7 demo launch options.
@MainActor
func applyTapsLaunchOptions(store: AppStore, options: LaunchOptions) async {
    guard options.demo != nil, options.demoSheet == .taps else { return }
    let env = ProcessInfo.processInfo.environment
    // openTaps' own read is under way; wait for it (a second read would
    // supersede it).
    for _ in 0..<100 where store.taps.taps.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
    if let s = env["TANKARD_DEMO_TAP_SELECT"] { store.taps.select(s.lowercased()) }
    if let a = env["TANKARD_DEMO_TAP_ADD"] { store.taps.requestAdd(name: a) }
    if env["TANKARD_DEMO_TAP_SHOW"] == "1", let t = store.taps.selectedTap {
        // As a click would: after the sheet is up.
        try? await Task.sleep(for: .seconds(1.5))
        store.showInstalled(from: t)
    }
    if env["TANKARD_DEMO_TAP_REMOVE"] == "1", let t = store.taps.selectedTap { _ = store.taps.requestRemove(t, packages: store.packages) }
}
