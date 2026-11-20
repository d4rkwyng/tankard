import SwiftUI
import TankardCore
import TankardAppModel

/// Settings (⌘,): General (menu bar, notifications, login) and Appearance.
struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings
    @Bindable var settings: AppSettings
    var notifier: SystemNotifier
    var loginItem: LoginItem
    /// 0.4: Settings → Upgrades.
    var insightSettings: InsightSettings?
    /// 0.5: Settings → Upgrades → Automatic updates.
    var autoUpdater: AutoUpdater?
    /// 0.7: Settings → Upgrades → Keep the previous version.
    var rollbackSettings: RollbackSettings?
    /// 0.6.1: Settings → Upgrades → Scan Now.
    var store: AppStore?
    private let tab: State<String>

    /// `initialTab`: which tab shows first ("general", "appearance"; snapshots).
    init(appearance: AppearanceSettings, settings: AppSettings, notifier: SystemNotifier, loginItem: LoginItem,
         insightSettings: InsightSettings? = nil, autoUpdater: AutoUpdater? = nil, store: AppStore? = nil,
         rollbackSettings: RollbackSettings? = nil,
         initialTab: String = ProcessInfo.processInfo.environment["TANKARD_SETTINGS_TAB"] ?? "general") {
        self.store = store
        self.rollbackSettings = rollbackSettings
        self.appearance = appearance
        self.settings = settings
        self.insightSettings = insightSettings
        self.autoUpdater = autoUpdater
        self.notifier = notifier
        self.loginItem = loginItem
        tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: tab.projectedValue) {
            GeneralSettings(settings: settings, notifier: notifier, loginItem: loginItem,
                            backgroundUpdateOptOut: store?.backgroundUpdateOptOut)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            if let insightSettings {
                UpgradeSettings(settings: insightSettings, autoUpdater: autoUpdater, notifier: notifier, appSettings: settings,
                                rollbackSettings: rollbackSettings, store: store)
                    .tabItem { Label("Upgrades", systemImage: "arrow.up.circle") }
                    .tag("upgrades")
            }
            AppearanceTab(appearance: appearance)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
            .tag("appearance")
        }
        .frame(width: SettingsFit.width)
        .themed(Theme.of(appearance.theme))
    }
}

/// Settings → Appearance.
struct AppearanceTab: View {
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance.theme) {
                ForEach(AppTheme.allCases) { t in
                    Text(t.title + (t == .default ? String(localized: " (default)") : "")).tag(t)
                }
            }
            .pickerStyle(.radioGroup)
            Text(appearance.theme.help)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .settingsFitProbe("appearance")
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    var notifier: SystemNotifier
    var loginItem: LoginItem
    /// 0.8: where HOMEBREW_NO_AUTO_UPDATE is set, when it is.
    var backgroundUpdateOptOut: String?
    private let notificationNote = State<String?>(initialValue: nil)
    private let notificationsDenied = State<Bool>(initialValue: false)
    private let loginOn = State<Bool?>(initialValue: nil)
    private let loginNote = State<String?>(initialValue: nil)

    /// 0.8.8 (gauntlet 3, B3): a plain column like Settings → Upgrades,
    /// not a Form. The Form put "Check every" in a label column left of
    /// the checkboxes, past the window's edge in every language, and its
    /// rows didn't wrap: French lost the "V" of "Vérifier toutes les" and
    /// the "Off: …" line ran off the right edge.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExplainedRow(help: SettingsHelp.showMenuBarIcon) {
                Toggle("Show Tankard in the menu bar", isOn: $settings.showMenuBarIcon)
            }
            // 0.8.6: the count next to the icon.
            ExplainedRow(help: SettingsHelp.showMenuBarCount) {
                Toggle("Show the number of upgrades in the menu bar", isOn: $settings.showMenuBarCount)
                    .disabled(!settings.showMenuBarIcon)
            }
            // 0.8.1: only with the menu-bar icon (else Tankard would be unreachable).
            ExplainedRow(help: SettingsHelp.hideDockIcon) {
                Toggle("Hide Dock icon when the window is closed", isOn: $settings.hideDockIconWhenClosed)
                    .disabled(!DockIconPolicy.optionAvailable(showMenuBarIcon: settings.showMenuBarIcon))
            }

            Divider().padding(.vertical, 4)

            // 0.8.8 (gauntlet 3, B9): with HOMEBREW_NO_AUTO_UPDATE the
            // checkbox showed checked (and dimmed) under "Off: …"; it now
            // shows what happens: unchecked and dimmed. The saved choice is
            // kept for when the setting goes away.
            ExplainedRow(help: SettingsHelp.backgroundUpdate) {
                Toggle("Check for new versions in the background", isOn: Binding(
                    get: { BackgroundUpdateSetting.shownOn(saved: settings.backgroundUpdate, optOut: backgroundUpdateOptOut) },
                    set: { if backgroundUpdateOptOut == nil { settings.backgroundUpdate = $0 } }))
                    .disabled(backgroundUpdateOptOut != nil)
            }
            if let source = backgroundUpdateOptOut {
                SettingsNote(String(localized: "Off: your Homebrew settings turn this off (in \(source))."))
            }
            ExplainedRow(help: SettingsHelp.notifyNewUpgrades) {
                Toggle("Notify me about new upgrades", isOn: Binding(
                    get: { settings.notifyNewUpgrades },
                    set: { on in
                        if on {
                            // Ask macOS only now, when the user turns it on.
                            Task {
                                let ok = await notifier.requestAuthorization()
                                settings.notifyNewUpgrades = ok
                                notificationNote.wrappedValue = ok ? nil : await notifier.authorizationText()
                                notificationsDenied.wrappedValue = await notifier.isDenied()
                            }
                        } else {
                            settings.notifyNewUpgrades = false
                        }
                    }))
            }
            HStack(spacing: 6) {
                // 0.8.9 (confirm run on 26): VoiceOver read "Check every,
                // Check every": the picker's own label and its
                // accessibilityLabel, joined. The picker has no label of its
                // own now, and this text is for the eye only.
                Text("Check every").accessibilityHidden(true)
                Picker(selection: $settings.checkIntervalHours) {
                    ForEach([1, 3, 6, 12, 24, 48], id: \.self) { h in Text(String(localized: "\(h) hours", bundle: L10n.bundle)).tag(h) }
                } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text("Check every"))
                .help(SettingsHelp.checkInterval)
                InfoButton(text: SettingsHelp.checkInterval)
            }
            .disabled(!BackgroundUpdateSetting.intervalEnabled(notify: settings.notifyNewUpgrades, saved: settings.backgroundUpdate,
                                                               optOut: backgroundUpdateOptOut))
            // 0.8.2: also when it was allowed once and later turned off in
            // System Settings (the toggle stays on, but nothing would show).
            if let note = notificationNote.wrappedValue
                ?? (notificationsDenied.wrappedValue && settings.notifyNewUpgrades
                    ? String(localized: "Off for Tankard in System Settings → Notifications") : nil) {
                HStack(spacing: 8) {
                    Text(note).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if notificationsDenied.wrappedValue {
                        Button("Open Notification Settings") { SystemNotifier.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }

            Divider().padding(.vertical, 4)

            ExplainedRow(help: SettingsHelp.openAtLogin) {
                Toggle("Open Tankard at login", isOn: Binding(
                    get: { loginOn.wrappedValue ?? loginItem.isEnabled },
                    set: { on in
                        do { try loginItem.setEnabled(on) } catch {}
                        loginOn.wrappedValue = loginItem.isEnabled
                        loginNote.wrappedValue = loginItem.statusNote
                    }))
            }
            if let note = loginNote.wrappedValue ?? loginItem.statusNote {
                SettingsNote(note)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsFitProbe("general")
        .task { notificationsDenied.wrappedValue = await notifier.isDenied() }
    }
}

/// 0.8.8 (gauntlet 3, B3): whether each Settings tab fits the window's
/// width. A tab's content wider than the window (a row that can't wrap) is
/// centred and cut at both edges, which is how French lost the first
/// letters of its labels. Each tab reports its laid-out width here; the
/// snapshot hook prints it (TANKARD_SETTINGS_CHECK=1, Scripts/settings-check.sh).
@MainActor
enum SettingsFit {
    static let width: CGFloat = 460
    static var widths: [String: CGFloat] = [:]
    /// 0.8.9: each tab's height too (French Upgrades was 629 pt).
    static var heights: [String: CGFloat] = [:]

    static func report() -> String {
        var ok = !widths.isEmpty
        var lines: [String] = []
        for (tab, w) in widths.sorted(by: { $0.key < $1.key }) {
            let fits = w <= width + 0.5
            if !fits { ok = false }
            lines.append(String(format: "settings-check: tab %@ width %.1f of %.0f %@, height %.1f", tab, w, width,
                                fits ? "fits" : "OVERFLOWS", heights[tab] ?? -1))
        }
        lines.append(ok ? "settings-check: OK" : "settings-check: FAIL")
        return lines.joined(separator: "\n") + "\n"
    }
}

extension View {
    /// Reports this tab content's width to `SettingsFit` (after its
    /// padding and a `.frame(maxWidth: .infinity)`: a child too wide to
    /// fit makes it wider than the window).
    func settingsFitProbe(_ tab: String) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { SettingsFit.widths[tab] = g.size.width; SettingsFit.heights[tab] = g.size.height }
                .onChange(of: g.size) { _, s in SettingsFit.widths[tab] = s.width; SettingsFit.heights[tab] = s.height }
        })
    }
}
