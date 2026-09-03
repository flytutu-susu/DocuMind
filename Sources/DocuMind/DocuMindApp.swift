import SwiftUI

@main
struct DocuMindApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.settingsStore)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear {
                    appState.applicationDidFinishLaunching()
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…") {
                    NotificationCenter.default.post(name: .docuMindOpenFiles, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.settingsStore)
                .environmentObject(appState.mlxManager)
                .frame(width: 660, height: 580)
        }
    }
}

extension Notification.Name {
    static let docuMindOpenFiles = Notification.Name("docuMindOpenFiles")
}
