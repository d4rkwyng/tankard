import SwiftUI
import TankardAppModel
import TankardCore

// v0.8: Homebrew ▸ Adopt Apps…. Apps installed by hand that a cask also
// installs, grouped by what `brew install --cask --adopt` would do with
// them; the ticked ones are adopted through the queue after a confirmation.
// Self-updating apps get a per-app choice of who updates them.
//
//   TANKARD_ADOPT=1             any mode: open the sheet (read-only scan)
//   TANKARD_DEMO_ADOPT=1        demo: open the sheet on the demo's apps
//   TANKARD_DEMO_ADOPT=confirm  demo: also open the confirmation
//   TANKARD_DEMO_ADOPT=run      demo: also confirm (the fake brew adopts)

/// The Homebrew menu item. A view, so its store reads aren't tracked by App.body.
struct AdoptMenuCommands: View {
    var store: AppStore

    var body: some View {
        Button("Adopt Apps…") { store.openAdopt() }
            .disabled(store.report == nil || store.menuActionsBlocked)
    }
}

/// "Who updates it": for a cask whose app updates itself.
struct SelfUpdatePolicyPicker: View {
    var policy: SelfUpdatePolicy
    /// Settings ▸ Upgrades ▸ "Include self-updating apps": what Default means.
    var includeSelfUpdating: Bool
    /// VoiceOver's name for the menu (its visible label sits beside it).
    var accessibilityName: String = String(localized: "Updates")
    var set: (SelfUpdatePolicy) -> Void

    var body: some View {
        Picker(selection: Binding(get: { policy }, set: { if $0 != policy { set($0) } })) {
            ForEach(SelfUpdatePolicy.allCases) { p in Text(p.title(includeSelfUpdating: includeSelfUpdating)).tag(p) }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help(policy.help)
        .accessibilityLabel(accessibilityName)
    }
}

struct AdoptSheet: View {
    @Bindable var store: AppStore
    var adopt: AdoptStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(icon: "square.and.arrow.down.on.square", title: String(localized: "Adopt Apps"),
                        subtitle: String(localized: "Apps you installed yourself that a Homebrew cask also installs. Adopting lets brew update them, without reinstalling."))
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 760, height: 620, alignment: .top)
        .background(theme.window ?? .clear)
        .modifier(AdoptConfirmation(store: store, adopt: adopt))
    }

    @ViewBuilder
    private var content: some View {
        switch adopt.phase {
        case .idle:
            scanning
        case .scanning where adopt.scan.rows.isEmpty:
            scanning
        case .failed(let message) where adopt.scan.rows.isEmpty:
            Text(message).font(.system(size: 12)).foregroundStyle(theme.warning(scheme).text).textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AdoptGroup.allCases) { g in
                        let rows = adopt.rows(g)
                        if !rows.isEmpty { section(g, rows) }
                    }
                    if adopt.scan.rows.isEmpty {
                        Text("No apps to adopt: everything in Applications is from Homebrew, the App Store or Apple.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var scanning: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reading your apps and Homebrew's casks…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(_ g: AdoptGroup, _ rows: [AdoptRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(g.title).font(.system(size: 13, weight: .bold))
                Text(verbatim: "\(rows.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(theme.chip))
                Spacer()
            }
            Text(g.explanation).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if g == .noCask {
                Text(rows.map(\.app.displayName).joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                ForEach(rows) { r in row(r, g) }
            }
        }
    }

    private func chip(_ text: String, _ color: Color, help: String? = nil) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.chip))
            .help(help ?? text)
    }

    private func row(_ r: AdoptRow, _ g: AdoptGroup) -> some View {
        let cask = adopt.cask(r)
        let verdict = adopt.verdict(r)
        return HStack(alignment: .top, spacing: 8) {
            if g == .ready {
                Toggle(isOn: Binding(get: { adopt.isTicked(r) }, set: { adopt.setTicked(r, $0) })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(String(localized: "Adopt \(r.app.displayName)"))
                    .disabled(store.isBusy)
            } else {
                Image(systemName: g == .needsUpdate ? "arrow.up.circle" : "nosign")
                    .foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.app.displayName).font(.system(size: 12.5, weight: .semibold))
                    Text(r.app.shortVersion ?? "?").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    if let c = adopt.confidence(r) {
                        chip(c.title, c == .low ? theme.warning(scheme).text : (c == .high ? theme.accent : .secondary), help: c.help)
                    }
                    if cask?.autoUpdates == true {
                        chip(String(localized: "Updates itself"), .secondary,
                             help: String(localized: "The cask says this app updates itself (auto_updates)."))
                    }
                    Spacer(minLength: 4)
                    caskPicker(r)
                }
                Text(r.app.path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let note = note(r, verdict, cask) {
                    Text(note).font(.system(size: 11)).foregroundStyle(g == .ready ? Color.secondary : theme.warning(scheme).text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if g == .ready, cask?.autoUpdates == true {
                    HStack(spacing: 6) {
                        Text("After adopting:").font(.system(size: 11)).foregroundStyle(.secondary)
                        SelfUpdatePolicyPicker(policy: adopt.policy(r),
                                               includeSelfUpdating: store.insights.settings.includeSelfUpdatingApps,
                                               accessibilityName: String(localized: "Who updates \(r.app.displayName)")) { adopt.setPolicy($0, for: r) }
                    }
                }
                // Replacing the app is offered only for a sure match: on a
                // weaker one it could overwrite a different app.
                if adopt.offersReplace(r), let cask {
                    HStack(spacing: 6) {
                        Text("Or have Homebrew replace it, in Terminal:").font(.system(size: 11)).foregroundStyle(.secondary)
                        let cmd = BrewCommands.display(AdoptCommands.replaceArguments(qualifiedName: cask.qualifiedName))
                        Button("Copy Command") { copyToPasteboard(cmd) }
                            .controlSize(.small)
                            .help(String(localized: "\(cmd)\nThis deletes the app that is there and installs the cask's version in its place."))
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.chip))
    }

    /// The cask: its token, or a menu when several casks install an app of
    /// this name.
    @ViewBuilder
    private func caskPicker(_ r: AdoptRow) -> some View {
        if r.isAmbiguous {
            Picker(selection: Binding(get: { adopt.token(r) ?? "" }, set: { adopt.choose($0, for: r) })) {
                ForEach(r.candidates, id: \.self) { t in Text(t).tag(t) }
            } label: { EmptyView() }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                .help("Several casks install an app with this name. Pick the one you have.")
                .accessibilityLabel(String(localized: "Cask"))
        } else if let t = adopt.token(r) {
            Text(t).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func note(_ r: AdoptRow, _ v: AdoptVerdict?, _ c: AdoptCask?) -> String? {
        guard let v, let c else { return nil }
        switch v {
        case .ready:
            if c.autoUpdates, let short = r.app.shortVersion, short != AdoptVersion.split(c.version).head {
                return String(localized: "Homebrew records it as \(c.version); brew doesn't compare versions for apps that update themselves.")
            }
            return nil
        case .readyUnchecked:
            return String(localized: "The cask always downloads the newest version, so brew compares after downloading; if they differ, it leaves the app alone.")
        case .needsUpdate(let installed, let caskVersion):
            return String(localized: "Installed \(installed); the cask installs \(caskVersion).")
        case .blocked(let b):
            return b.text
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            let line = [adopt.source, adopt.skippedLine].filter { !$0.isEmpty }.joined(separator: " · ")
            if !line.isEmpty {
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "How adopting works"))
                    .help("Tankard checks each app's version against Homebrew's. When they match, Homebrew takes over updates without moving the app.")
                Text("Adopting runs through Tankard's queue and History.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Scan Again") { Task { await adopt.load() } }
                    .disabled(adopt.phase == .scanning)
                Button("Done") { store.closeToolSheet() }
                let n = adopt.plan.count
                Button(n == 0 ? String(localized: "Adopt Apps…") : n == 1 ? String(localized: "Adopt 1 App…") : String(localized: "Adopt \(n) Apps…")) { adopt.requestAdopt() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(n == 0 || store.isBusy)
            }
        }
    }
}

/// An alert binding that writes nothing when unchanged.
@MainActor
private func adoptPendingBinding(_ adopt: AdoptStore) -> Binding<Bool> {
    Binding(get: { adopt.pendingConfirm != nil }, set: { if !$0 && adopt.pendingConfirm != nil { adopt.cancelConfirm() } })
}

/// The confirmation: what adopting does, and the commands.
struct AdoptConfirmation: ViewModifier {
    var store: AppStore
    var adopt: AdoptStore

    func body(content: Content) -> some View {
        content.alert(Self.title(adopt.pendingConfirm ?? []), isPresented: adoptPendingBinding(adopt), presenting: adopt.pendingConfirm) { _ in
            Button("Cancel", role: .cancel) { adopt.cancelConfirm() }
            Button("Adopt") { store.confirmAdopt() }
        } message: { items in
            Text(Self.message(items))
        }
    }

    static func title(_ items: [AdoptPlanItem]) -> String {
        items.count == 1 ? String(localized: "Adopt \(items[0].token)?") : String(localized: "Adopt \(items.count) apps?")
    }

    static func message(_ items: [AdoptPlanItem]) -> String {
        let list = items.prefix(8).map { "• \(($0.appPath as NSString).lastPathComponent) → \($0.token) \($0.caskVersion)" }
            + (items.count > 8 ? [String(localized: "and \(items.count - 8) more")] : [])
        return list.joined(separator: "\n") + "\n\n" + AdoptStore.confirmationText(items)
            + String(localized: "\n\nTankard runs: ") + AdoptStore.commandsText(items)
    }
}

/// 0.8 launch options: TANKARD_ADOPT=1 (any mode), TANKARD_DEMO_ADOPT (demo).
@MainActor
func applyAdoptLaunchOptions(store: AppStore, options: LaunchOptions) async {
    let env = ProcessInfo.processInfo.environment
    let demoMode = options.demo != nil ? env["TANKARD_DEMO_ADOPT"].flatMap { $0.isEmpty || $0 == "0" ? nil : $0.lowercased() } : nil
    guard env["TANKARD_ADOPT"] == "1" || demoMode != nil else { return }
    store.openAdopt()
    for _ in 0..<200 where store.adopt.phase != .ready { try? await Task.sleep(for: .milliseconds(50)) }
    guard let mode = demoMode, mode == "confirm" || mode == "run" else { return }
    store.adopt.requestAdopt()
    if mode == "run" {
        try? await Task.sleep(for: .seconds(1))
        store.confirmAdopt()
    }
}
