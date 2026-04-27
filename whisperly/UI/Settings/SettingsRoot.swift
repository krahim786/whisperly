import SwiftUI

struct SettingsRoot: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeySettingsView()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
        }
        .frame(width: 520, height: 420)
    }
}

#Preview {
    SettingsRoot()
}
