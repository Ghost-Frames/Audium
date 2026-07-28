import SwiftUI
import WhisperKit

@main
struct AudiumApp: App {
    @Environment(\.openWindow) private var openWindow

    /// Promoted from `ContentView`'s own `@StateObject` during the Paper Edit phase (spec §8) —
    /// originally so the (now-removed) separate Paper Edit window could drive the same project/
    /// playback state as the main window rather than a second copy. Stayed promoted through the
    /// later tab-based-interface pass (spec §8): the REVISED DECISION there kept playback SHARED
    /// across tabs (one `AudioPlaybackController` for whichever tab is active, not one per tab,
    /// same as a single Avid/Premiere sequence player) rather than reversing this promotion, so
    /// this `@StateObject` placement needed no change even though the Paper Edit *window* it was
    /// originally built for is gone. Injected into `WindowGroup`/`Settings` below via
    /// `.environmentObject` — `ContentView` now owns Story Editor as an internal tab rather than a
    /// second Scene, but the environment injection pattern itself is unchanged.
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
