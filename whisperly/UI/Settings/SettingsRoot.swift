import SwiftUI

struct SettingsRoot: View {
    let historyStore: HistoryStore?

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeySettingsView()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            HistorySettingsView(store: historyStore)
                .tabItem { Label("History", systemImage: "clock") }
            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
        }
        .frame(width: 520, height: 460)
    }
}
