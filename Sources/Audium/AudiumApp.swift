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
        // TEMP manual test hook — see conversation, will be removed after verification.
        if let path = ProcessInfo.processInfo.environment["AUDIUM_TEST_GEMINI"] {
            Task {
                do {
                    print("[gemini] transcribing…"); fflush(stdout)
                    let start = Date()
                    var provider = GeminiTranscriptionProvider()
                    provider.onStatus = { message, fraction in
                        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                        print("[gemini] status t=\(elapsed)s fraction=\(fraction.map { "\($0)" } ?? "nil"): \(message)")
                        fflush(stdout)
                    }
                    let transcript = try await provider.transcribe(audio: URL(fileURLWithPath: path))
                    print("[gemini] \(transcript.segments.count) segment(s)")
                    for seg in transcript.segments {
                        print(String(format: "[%.1f-%.1f] speaker=%@ text=%@", seg.start, seg.end, seg.speaker ?? "nil", seg.text))
                    }
                } catch {
                    print("[gemini-error] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        if let path = ProcessInfo.processInfo.environment["AUDIUM_TEST_OPENAI"] {
            Task {
                do {
                    print("[openai] transcribing…"); fflush(stdout)
                    let audioURL = URL(fileURLWithPath: path)
                    let transcript = try await OpenAIWhisperAPIProvider().transcribe(audio: audioURL)
                    print("[openai] \(transcript.segments.count) segment(s)")
                    for seg in transcript.segments {
                        print(String(format: "[%.1f-%.1f] speaker=%@ text=%@", seg.start, seg.end, seg.speaker ?? "nil", seg.text))
                    }
                    // TEMP export smoke test — see conversation, will be removed after verification.
                    if let exportDir = ProcessInfo.processInfo.environment["AUDIUM_TEST_EXPORT_DIR"] {
                        let base = audioURL.deletingPathExtension().lastPathComponent
                        for format in ExportFormat.allCases {
                            let out = URL(fileURLWithPath: exportDir).appendingPathComponent("\(base).\(format.fileExtension)")
                            try Exporter.render(transcript, as: format).write(to: out, atomically: true, encoding: .utf8)
                            print("[export] wrote \(out.path)")
                        }
                    }
                } catch {
                    print("[openai-error] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // AUDIUM_TEST_AI_PROVIDER: "gemini" | "openai". AUDIUM_TEST_AI_PROMPT: the user prompt
        // to send. AUDIUM_TEST_AI_MODEL: optional, defaults to each vendor's rolling alias
        // (gemini-flash-latest / gpt-5.6) if unset.
        if let providerName = ProcessInfo.processInfo.environment["AUDIUM_TEST_AI_PROVIDER"] {
            Task {
                do {
                    let prompt = ProcessInfo.processInfo.environment["AUDIUM_TEST_AI_PROMPT"] ?? "Say hello in exactly 5 words."
                    let (provider, defaultModel): (AIProvider, String)
                    switch providerName {
                    case "gemini": (provider, defaultModel) = (GeminiProvider(), "gemini-flash-latest")
                    case "openai": (provider, defaultModel) = (OpenAIProvider(), "gpt-5.6")
                    default: throw NSError(domain: "AudiumTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown provider \(providerName)"])
                    }
                    let model = ProcessInfo.processInfo.environment["AUDIUM_TEST_AI_MODEL"] ?? defaultModel
                    print("[ai:\(providerName)] model=\(model) prompt=\(prompt)"); fflush(stdout)
                    let reply = try await provider.complete(messages: [Message(role: .user, content: prompt)], model: model)
                    print("[ai:\(providerName)] reply=\(reply)")
                } catch {
                    print("[ai-error:\(providerName)] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // End-to-end chat-panel smoke test: transcribes AUDIUM_TEST_CHAT_AUDIO via OpenAI
        // Whisper, then replicates AIChatPanel's "Summarize" quick action exactly (same
        // system-message transcript injection, same user-turn text) against
        // AUDIUM_TEST_CHAT_PROVIDER ("gemini" | "openai").
        if let path = ProcessInfo.processInfo.environment["AUDIUM_TEST_CHAT_AUDIO"] {
            Task {
                do {
                    let providerName = ProcessInfo.processInfo.environment["AUDIUM_TEST_CHAT_PROVIDER"] ?? "gemini"
                    let kind: AIProviderKind
                    switch providerName {
                    case "gemini": kind = .gemini
                    case "openai": kind = .openai
                    default: throw NSError(domain: "AudiumTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown provider \(providerName)"])
                    }

                    print("[chat-e2e] transcribing…"); fflush(stdout)
                    let transcript = try await OpenAIWhisperAPIProvider().transcribe(audio: URL(fileURLWithPath: path))
                    let transcriptText = transcript.segments.map(\.text).joined(separator: " ")
                    print("[chat-e2e] transcript: \(transcriptText)"); fflush(stdout)

                    let messages = [
                        Message(role: .system, content: "You are assisting with the following transcript. Use it as context for the user's requests.\n\nTranscript:\n\(transcriptText)"),
                        Message(role: .user, content: "Summarize this transcript in a few sentences."),
                    ]
                    print("[chat-e2e] provider=\(providerName) model=\(kind.defaultModel) sending…"); fflush(stdout)
                    let reply = try await kind.makeProvider().complete(messages: messages, model: kind.defaultModel)
                    print("[chat-e2e] reply=\(reply)")
                } catch {
                    print("[chat-e2e-error] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // End-to-end YouTube-URL smoke test: AUDIUM_TEST_YOUTUBE_URL downloads via the bundled
        // yt-dlp, then feeds the resulting local file into AUDIUM_TEST_YOUTUBE_PROVIDER
        // ("gemini" | "openai", default gemini) — same TranscriptionProvider each already has,
        // not a separate code path.
        if let urlString = ProcessInfo.processInfo.environment["AUDIUM_TEST_YOUTUBE_URL"] {
            Task {
                do {
                    let providerName = ProcessInfo.processInfo.environment["AUDIUM_TEST_YOUTUBE_PROVIDER"] ?? "gemini"
                    let provider: TranscriptionProvider
                    switch providerName {
                    case "gemini": provider = GeminiTranscriptionProvider()
                    case "openai": provider = OpenAIWhisperAPIProvider()
                    default: throw NSError(domain: "AudiumTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown provider \(providerName)"])
                    }

                    print("[youtube] downloading \(urlString)…"); fflush(stdout)
                    let localURL = try await YouTubeDownloader.downloadAudio(from: urlString) { progress in
                        print("[youtube] \(progress)"); fflush(stdout)
                    }
                    print("[youtube] downloaded to \(localURL.path)"); fflush(stdout)

                    print("[youtube] transcribing via \(providerName)…"); fflush(stdout)
                    let transcript = try await provider.transcribe(audio: localURL)
                    print("[youtube] \(transcript.segments.count) segment(s)")
                    for seg in transcript.segments {
                        print(String(format: "[%.1f-%.1f] speaker=%@ text=%@", seg.start, seg.end, seg.speaker ?? "nil", seg.text))
                    }
                } catch {
                    print("[youtube-error] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // Closes the one unverified claim from the transcript-editing test: export propagation
        // was confirmed structurally (save panel opened with the live edited segments) but never
        // verified by reading the saved file, since NSSavePanel's AX tree wasn't reliably
        // scriptable. This reproduces the same starting point as that real GUI test (transcribe
        // AUDIUM_TEST_EXPORT_EDITED via Gemini), applies the identical edit made live in the
        // GUI (text + speaker "Josh"), then calls Exporter.render directly — same function
        // presentSavePanel calls, just skipping its file-picker UI — and writes the result to
        // AUDIUM_TEST_EXPORT_EDITED_OUT so it can be read back.
        if let path = ProcessInfo.processInfo.environment["AUDIUM_TEST_EXPORT_EDITED"] {
            Task {
                do {
                    print("[export-edit] transcribing…"); fflush(stdout)
                    var transcript = try await GeminiTranscriptionProvider().transcribe(audio: URL(fileURLWithPath: path))
                    print("[export-edit] original segment: speaker=\(transcript.segments[0].speaker ?? "nil") text=\(transcript.segments[0].text)")

                    // The exact edit applied live in the GUI test.
                    transcript.segments[0].text = "This is the edited transcript text for testing inline editing."
                    transcript.segments[0].speaker = "Josh"
                    print("[export-edit] edited segment: speaker=\(transcript.segments[0].speaker ?? "nil") text=\(transcript.segments[0].text)"); fflush(stdout)

                    let srt = Exporter.render(transcript, as: .srt)
                    let outPath = ProcessInfo.processInfo.environment["AUDIUM_TEST_EXPORT_EDITED_OUT"] ?? "/tmp/edited_export_test.srt"
                    try srt.write(toFile: outPath, atomically: true, encoding: .utf8)
                    print("[export-edit] wrote \(outPath)")
                } catch {
                    print("[export-edit-error] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // Settings polish pass: prints what WhisperKit.recommendedModels() actually returns on
        // this device (confirming the Settings model picker isn't showing a hand-guessed list),
        // then confirms WhisperModelSettings.selectedVariant correctly overrides the variant
        // WhisperKitProvider resolves — via the "Checking model X…" status, not full execution
        // (WhisperKit is still blocked from actually running on this Intel Mac, per the known
        // SIGSEGV issue).
        if ProcessInfo.processInfo.environment["AUDIUM_TEST_WHISPER_MODELS"] != nil {
            let support = WhisperKit.recommendedModels()
            print("[whisper-models] default=\(support.default)")
            print("[whisper-models] supported=\(support.supported.sorted())")
            fflush(stdout)
            exit(0)
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // Exercises the dedicated Audium.keychain-db path directly (save/load/migration) without
        // needing to drive the Settings UI — validates the Keychain-GUI-bug fix (spec §5): no
        // password prompt should ever be needed for this keychain, and values must survive a
        // fresh process (real relaunch simulation, since each invocation is a new process).
        if let mode = ProcessInfo.processInfo.environment["AUDIUM_TEST_KEYCHAIN"] {
            Task {
                do {
                    switch mode {
                    case "save":
                        try KeychainStore.save(key: "gemini-test-key-123", for: .gemini)
                        try KeychainStore.save(key: "openai-test-key-456", for: .openai)
                        print("[keychain-test] saved gemini+openai keys")
                    case "load":
                        let gemini = try KeychainStore.load(for: .gemini)
                        let openai = try KeychainStore.load(for: .openai)
                        print("[keychain-test] gemini=\(gemini ?? "nil") openai=\(openai ?? "nil")")
                    case "migrate":
                        KeychainStore.migrateFromLoginKeychainIfNeeded()
                        // migration runs on a detached Task; give it a moment before reading back.
                        try await Task.sleep(nanoseconds: 500_000_000)
                        let gemini = try KeychainStore.load(for: .gemini)
                        let openai = try KeychainStore.load(for: .openai)
                        print("[keychain-test] after migrate: gemini=\(gemini ?? "nil") openai=\(openai ?? "nil")")
                    default:
                        print("[keychain-test] unknown mode \(mode)")
                    }
                } catch {
                    print("[keychain-test-error] \(error)")
                }
                fflush(stdout)
                exit(0)
            }
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // Dumps all three Settings-backed UserDefaults values as this process sees them — used
        // to confirm persistence across a real relaunch (run once after changing values via the
        // Settings UI or `defaults write`, run again in a fresh process, diff the two).
        if ProcessInfo.processInfo.environment["AUDIUM_TEST_SETTINGS_DUMP"] != nil {
            print("[settings] defaultTranscriptionProvider=\(TranscriptionSettings.defaultProvider.rawValue)")
            print("[settings] defaultChatProvider=\(ChatSettings.defaultProvider.rawValue)")
            print("[settings] whisperModelVariant=\(WhisperModelSettings.selectedVariant ?? "nil (uses device default)")")
            fflush(stdout)
            exit(0)
        }
        // TEMP manual test hook — see conversation, will be removed after verification.
        // Logging verification: transcribes AUDIUM_TEST_LOGGING_AUDIO via Gemini (real
        // TranscriptionProvider + SpeakerDiarizer call, both instrumented with AudiumLog), then
        // writes the result via Exporter.write (same logged write path presentSavePanel uses,
        // minus the interactive NSSavePanel) to AUDIUM_TEST_LOGGING_EXPORT_DIR. Confirms real
        // log entries land for both a transcription and an export in one pass.
        if let path = ProcessInfo.processInfo.environment["AUDIUM_TEST_LOGGING_AUDIO"] {
            Task {
                do {
                    let transcript = try await GeminiTranscriptionProvider().transcribe(audio: URL(fileURLWithPath: path))
                    print("[logging-test] transcribed \(transcript.segments.count) segment(s)")
                    if let exportDir = ProcessInfo.processInfo.environment["AUDIUM_TEST_LOGGING_EXPORT_DIR"] {
                        let out = URL(fileURLWithPath: exportDir).appendingPathComponent("logging_test.srt")
                        Exporter.write(transcript, as: .srt, to: out)
                        print("[logging-test] exported to \(out.path)")
                    }
                } catch {
                    print("[logging-test-error] \(error)")
                }
                fflush(stdout)
                // No exit(0) here (unlike the other hooks): this one is meant to seed real log
                // entries in a GUI session that stays running afterward, so the in-app Log
                // Viewer can be opened against them.
            }
        }
        if let overrideVariant = ProcessInfo.processInfo.environment["AUDIUM_TEST_WHISPER_VARIANT_OVERRIDE"] {
            WhisperModelSettings.selectedVariant = overrideVariant
            print("[whisper-variant] WhisperModelSettings.selectedVariant set to: \(overrideVariant)")
            var provider = WhisperKitProvider()
            provider.onStatus = { message, _ in
                print("[whisper-variant] status: \(message)"); fflush(stdout)
                if message.hasPrefix("Checking model") {
                    // Confirmed the resolved variant string before handing off to WhisperKit's
                    // download/init path, which is the part known-broken on Intel — stop here.
                    exit(0)
                }
            }
            Task {
                do {
                    _ = try await provider.transcribe(audio: URL(fileURLWithPath: "/dev/null"))
                } catch {
                    print("[whisper-variant] (expected past this point) \(error)")
                }
                fflush(stdout)
                exit(0)
            }
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
    }
}
