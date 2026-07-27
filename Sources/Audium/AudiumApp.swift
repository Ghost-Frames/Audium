import SwiftUI
import WhisperKit

@main
struct AudiumApp: App {
    @Environment(\.openWindow) private var openWindow

    /// Promoted from `ContentView`'s own `@StateObject` (spec §8, Paper Edit) so the separate
    /// Paper Edit window can drive the *same* project/playback state rather than a second copy —
    /// clicking a Paper Edit entry loads/seeks/plays through this one shared
    /// `AudioPlaybackController`, reusing the existing playback wiring instead of duplicating it.
    /// Injected into each Scene below via `.environmentObject`, since SwiftUI's environment
    /// doesn't cross Scene boundaries on its own.
    @StateObject private var project = ProjectController()
    @StateObject private var playback = AudioPlaybackController()

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
                .frame(minWidth: 1320, idealWidth: 1600, minHeight: 700, idealHeight: 860)
                .environmentObject(project)
                .environmentObject(playback)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Show Logs") { openWindow(id: "logs") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Paper Edit") { openWindow(id: "paperEdit") }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
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

        Window("Paper Edit", id: "paperEdit") {
            PaperEditView()
                .environmentObject(project)
                .environmentObject(playback)
        }
        .defaultSize(width: 520, height: 600)
    }
}
