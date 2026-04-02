import SwiftUI
import SneekLib

@main
struct SneekApp: App {
    @StateObject private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        MenuBarExtra("Sneek", systemImage: "network.badge.shield.half.filled") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Sneek — Commands", id: "main") {
            CommandEditorView()
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}
