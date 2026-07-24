import SwiftUI
import WhisperKit

@main
struct AudiumApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        // Off the main thread: a read against the old login keychain during migration can hit
        // the same broken GUI prompt this move to a dedicated keychain exists to escape, and
        // must never block app startup (spec §5).
        Task.detached(priority: .utility) {
            KeychainStore.migrateFromLoginKeychainIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, idealWidth: 1400, minHeight: 700, idealHeight: 860)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Show Logs") { openWindow(id: "logs") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }

        Window("Logs", id: "logs") {
            LogViewerView()
        }
        .defaultSize(width: 640, height: 480)

        Window("About Audium", id: "about") {
            AboutView()
        }
        .defaultSize(width: 320, height: 320)
        .windowResizability(.contentSize)
    }
}
