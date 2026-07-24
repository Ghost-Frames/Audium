import SwiftUI

/// Real About panel (toolbar reorg, spec §7 placeholder-item pattern) — app name/version/build
/// info now, same as the DMG-packaging placeholder in build.sh. A full auto-update mechanism
/// (Sparkle or similar) is a separate, much bigger feature — this "Check for Updates" button is
/// a labeled placeholder, not a stub pretending to work, so the roadmap gap is visible in the UI
/// rather than silently absent.
struct AboutView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Audium"
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text(appName)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Version \(shortVersion) (\(buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Native macOS transcription and story-editing tool — WhisperKit/Gemini/OpenAI transcription, SpeakerKit diarization, and multi-provider AI chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Button("Check for Updates…") {}
                .buttonStyle(.accent)
                .disabled(true)
                .help("Not yet implemented — auto-update is a planned future feature (see docs/spec.md).")
        }
        .padding(24)
        .frame(width: 320, height: 320)
        .background(Theme.background)
    }
}
