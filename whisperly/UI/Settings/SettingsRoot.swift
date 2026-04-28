import SwiftUI

struct SettingsRoot: View {
    let historyStore: HistoryStore?
    let snippetStore: SnippetStore
    let dictionaryStore: DictionaryStore
    @ObservedObject var updates: UpdateService

    var body: some View {
        TabView {
            GeneralSettingsView(updates: updates)
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeySettingsView()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }
            SnippetsSettingsView(store: snippetStore)
                .tabItem { Label("Snippets", systemImage: "text.append") }
            DictionarySettingsView(store: dictionaryStore)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistorySettingsView(store: historyStore)
                .tabItem { Label("History", systemImage: "clock") }
            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
        }
        .frame(width: 660, height: 500)
    }
}
