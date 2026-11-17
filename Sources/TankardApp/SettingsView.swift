import SwiftUI
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
            }
            .padding(20)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
            .tag("appearance")
        }
        .frame(width: 460)
        .themed(Theme.of(appearance.theme))
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    var notifier: SystemNotifier
    var loginItem: LoginItem
    /// 0.8: where HOMEBREW_NO_AUTO_UPDATE is set, when it is.
    var backgroundUpdateOptOut: String?
    private let notificationNote = State<String?>(initialValue: nil)
    private let loginOn = State<Bool?>(initialValue: nil)
    private let loginNote = State<String?>(initialValue: nil)

    var body: some View {
        Form {
            ExplainedRow(help: SettingsHelp.showMenuBarIcon) {
                Toggle("Show Tankard in the menu bar", isOn: $settings.showMenuBarIcon)
            }
            // 0.8.1: only with the menu-bar icon (else Tankard would be unreachable).
            ExplainedRow(help: SettingsHelp.hideDockIcon) {
                Toggle("Hide Dock icon when the window is closed", isOn: $settings.hideDockIconWhenClosed)
                    .disabled(!DockIconPolicy.optionAvailable(showMenuBarIcon: settings.showMenuBarIcon))
            }

            Divider().padding(.vertical, 4)

            ExplainedRow(help: SettingsHelp.backgroundUpdate) {
                Toggle("Check for new versions in the background", isOn: $settings.backgroundUpdate)
                    .disabled(backgroundUpdateOptOut != nil)
            }
            if let source = backgroundUpdateOptOut {
                Text("Off: HOMEBREW_NO_AUTO_UPDATE is set (\(source)).").font(.system(size: 11)).foregroundStyle(.secondary)
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
                            }
                        } else {
                            settings.notifyNewUpgrades = false
                        }
                    }))
            }
            HStack(spacing: 6) {
                Picker("Check every", selection: $settings.checkIntervalHours) {
                    ForEach([1, 3, 6, 12, 24, 48], id: \.self) { h in Text(h == 1 ? String(localized: "1 hour") : String(localized: "\(h) hours")).tag(h) }
                }
                .disabled(!settings.notifyNewUpgrades && !settings.backgroundUpdate)
                .fixedSize()
                .help(SettingsHelp.checkInterval)
                InfoButton(text: SettingsHelp.checkInterval)
            }
            if let note = notificationNote.wrappedValue {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
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
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
