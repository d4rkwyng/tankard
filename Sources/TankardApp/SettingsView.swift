import SwiftUI
import TankardAppModel

/// Settings (⌘,) → Appearance.
struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        TabView {
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
        }
        .frame(width: 380)
        .themed(Theme.of(appearance.theme))
    }
}
