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
    private let tab: State<String>

    /// `initialTab`: which tab shows first ("general", "appearance"; snapshots).
    init(appearance: AppearanceSettings, settings: AppSettings, notifier: SystemNotifier, loginItem: LoginItem,
         insightSettings: InsightSettings? = nil, initialTab: String = "general") {
        self.appearance = appearance
        self.settings = settings
        self.insightSettings = insightSettings
        self.notifier = notifier
        self.loginItem = loginItem
        tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: tab.projectedValue) {
            GeneralSettings(settings: settings, notifier: notifier, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            if let insightSettings {
                UpgradeSettings(settings: insightSettings)
                    .tabItem { Label("Upgrades", systemImage: "arrow.up.circle") }
                    .tag("upgrades")
            }
            Form {
                Picker("Appearance", selection: $appearance.theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.title + (t == .default ? " (default)" : "")).tag(t)
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
    private let notificationNote = State<String?>(initialValue: nil)
    private let loginOn = State<Bool?>(initialValue: nil)
    private let loginNote = State<String?>(initialValue: nil)

    var body: some View {
        Form {
            Toggle("Show Tankard in the menu bar", isOn: $settings.showMenuBarIcon)
            Text("A mug with the number of upgrades ready. With it on, closing the window keeps Tankard running.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

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
            Picker("Check every", selection: $settings.checkIntervalHours) {
                ForEach([1, 3, 6, 12, 24, 48], id: \.self) { h in Text("\(h) hour\(h == 1 ? "" : "s")").tag(h) }
            }
            .disabled(!settings.notifyNewUpgrades)
            .fixedSize()
            Text("Runs brew update and checks for upgrades in the background. A notification appears only when new upgrades show up. Off by default.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = notificationNote.wrappedValue {
                Text(note).font(.system(size: 11)).foregroundStyle(.orange)
            }

            Divider().padding(.vertical, 4)

            Toggle("Open Tankard at login", isOn: Binding(
                get: { loginOn.wrappedValue ?? loginItem.isEnabled },
                set: { on in
                    do { try loginItem.setEnabled(on) } catch {}
                    loginOn.wrappedValue = loginItem.isEnabled
                    loginNote.wrappedValue = loginItem.statusNote
                }))
            if let note = loginNote.wrappedValue ?? loginItem.statusNote {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
