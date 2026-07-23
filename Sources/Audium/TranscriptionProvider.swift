import Foundation
import AVFoundation
import WhisperKit
import OSLog

struct TranscriptSegment: Identifiable {
    let id = UUID()
    // Editable in place (spec §2, "Transcript editing"). `start`/`end` stay fixed to whatever
    // transcription produced — v1 is text-only correction, no word-level timestamp resync
    // (spec §5, resolved: deferred, not needed now).
    var text: String
    let start: TimeInterval
    let end: TimeInterval
    var speaker: String?
}

struct Transcript {
    var segments: [TranscriptSegment]
}

/// Fires with human-readable phase/progress text plus a determinate fraction (0...1) when the
/// underlying provider actually exposes one (model download, WhisperKit decode windows, SpeakerKit
/// diarization chunks) — `nil` when there's no real percentage to report (cloud API calls), so the
/// UI can tell "determinate" from "still working, no signal" (spec §2, transcription progress).
typealias TranscriptionStatusHandler = @Sendable (_ message: String, _ fraction: Double?) -> Void

/// Common surface for the three transcription backends (spec §3, Transcription).
/// Claude is not a conformer here — the Messages API has no audio input modality.
protocol TranscriptionProvider {
    func transcribe(audio: URL) async throws -> Transcript
}

/// Local, on-device, default out of the box. Wraps the already-imported WhisperKit module.
struct WhisperKitProvider: TranscriptionProvider {
    /// Not part of the protocol — only WhisperKit has a local download+load+decode phase worth
    /// surfacing; the cloud providers get their own copy of this property instead.
    var onStatus: TranscriptionStatusHandler?

    func transcribe(audio: URL) async throws -> Transcript {
        AudiumLog.transcription.info("WhisperKit transcription started: \(audio.lastPathComponent, privacy: .public)")
        do {
            let variant = WhisperModelSettings.selectedVariant ?? WhisperKit.recommendedModels().default

            onStatus?("Checking model \(variant)…", nil)
            AudiumLog.transcription.info("Phase: checking model \(variant, privacy: .public)")
            _ = try await WhisperKit.download(variant: variant) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                onStatus?("Downloading \(variant): \(percent)%", progress.fractionCompleted)
            }

            onStatus?("Loading model…", nil)
            AudiumLog.transcription.info("Phase: loading model")
            let pipe = try await WhisperKit(model: variant)

            onStatus?("Transcribing…", nil)
            AudiumLog.transcription.info("Phase: transcribing")
            // WhisperKit updates `pipe.progress` (real Foundation Progress, one unit per audio
            // sample processed) once per decode window; reading it inside the per-token callback
            // gives a real percent-complete signal, not just a phase label. `nonisolated(unsafe)`
            // is safe here: the callback only ever runs serially on this same transcribe() call.
            nonisolated(unsafe) let pipeRef = pipe
            let results = try await pipe.transcribe(audioPath: audio.path, callback: { _ in
                let fraction = pipeRef.progress.fractionCompleted
                onStatus?("Transcribing: \(Int(fraction * 100))%", fraction)
                return true
            })

            let segments = results.flatMap(\.segments).map {
                TranscriptSegment(
                    text: $0.text.trimmingSpecialTokenCharacters(),
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    speaker: nil
                )
            }

            let transcript = try await SpeakerDiarizer().labelSpeakers(in: Transcript(segments: segments), audio: audio, onStatus: onStatus)
            AudiumLog.transcription.info("WhisperKit transcription succeeded: \(transcript.segments.count) segment(s), model \(variant, privacy: .public)")
            return transcript
        } catch {
            AudiumLog.transcription.error("WhisperKit transcription failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

enum TranscriptionError: LocalizedError {
    case missingAPIKey(KeychainStore.Provider)
    case unsupportedAudioFormat(String)
    case httpError(status: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key saved for \(provider.rawValue). Add one in Settings."
        case .unsupportedAudioFormat(let ext):
            return "Unsupported audio format: .\(ext)"
        case .httpError(let status, let body):
            return "HTTP \(status): \(body)"
        case .emptyResponse:
            return "Empty transcription response"
        }
    }
}

private func validateHTTP(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200...299).contains(http.statusCode) else {
        throw TranscriptionError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
    }
}

private func audioDurationSeconds(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
}

/// Cloud, via Gemini's native multimodal audio input. Reads its key from the same
/// Keychain entry (.gemini) that GeminiProvider (AIProvider) uses.
///
/// Gemini's generateContent only returns a plain-text transcript — no structured segment
/// timestamps (confirmed against current docs, not assumed). So unlike WhisperKit/OpenAI,
/// this maps to a single TranscriptSegment spanning the whole clip, not per-utterance
/// segments. SpeakerKit diarization still runs afterward same as WhisperKit's flow, since
/// diarization is audio-based and independent of which transcription backend ran.
struct GeminiTranscriptionProvider: TranscriptionProvider {
    // "-latest" alias auto-rotates to the current Flash release, avoiding breakage when Google
    // retires pinned model versions (e.g. gemini-2.5-flash 404s as of July 2026). Google's docs
    // note prod apps should normally pin a stable version instead — this trades that stability
    // for not needing a manual bump on every retirement.
    static let model = "gemini-flash-latest"
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

    private static let mimeTypes = [
        "wav": "audio/wav", "aiff": "audio/aiff", "aif": "audio/aiff",
        "mp3": "audio/mp3", "aac": "audio/aac", "m4a": "audio/aac",
        "ogg": "audio/ogg", "flac": "audio/flac",
    ]

    /// No granular progress from a single `generateContent` call — the UI falls back to an
    /// elapsed-time display when `fraction` is nil (spec §2).
    var onStatus: TranscriptionStatusHandler?

    func transcribe(audio: URL) async throws -> Transcript {
        AudiumLog.transcription.info("Gemini transcription started: \(audio.lastPathComponent, privacy: .public)")
        onStatus?("Transcribing via Gemini…", nil)
        do {
            guard let apiKey = try KeychainStore.loadForTesting(for: .gemini, envOverride: "AUDIUM_GEMINI_KEY_OVERRIDE"), !apiKey.isEmpty else {
                throw TranscriptionError.missingAPIKey(.gemini)
            }
            guard let mimeType = Self.mimeTypes[audio.pathExtension.lowercased()] else {
                throw TranscriptionError.unsupportedAudioFormat(audio.pathExtension)
            }

            let audioData = try Data(contentsOf: audio)
            let body: [String: Any] = [
                "contents": [[
                    "role": "user",
                    "parts": [
                        ["text": "Transcribe this audio verbatim. Reply with only the transcript text, no commentary."],
                        ["inlineData": ["mimeType": mimeType, "data": audioData.base64EncodedString()]],
                    ],
                ]],
            ]

            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTP(response, data: data)

            struct GeminiResponse: Decodable {
                struct Candidate: Decodable {
                    struct Content: Decodable {
                        struct Part: Decodable { let text: String? }
                        let parts: [Part]?
                    }
                    let content: Content?
                }
                let candidates: [Candidate]?
            }
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
                throw TranscriptionError.emptyResponse
            }

            let duration = try await audioDurationSeconds(audio)
            let transcript = Transcript(segments: [
                TranscriptSegment(text: text.trimmingCharacters(in: .whitespacesAndNewlines), start: 0, end: duration, speaker: nil),
            ])
            let labeled = try await SpeakerDiarizer().labelSpeakers(in: transcript, audio: audio, onStatus: onStatus)
            AudiumLog.transcription.info("Gemini transcription succeeded: \(labeled.segments.count) segment(s)")
            return labeled
        } catch {
            AudiumLog.transcription.error("Gemini transcription failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

/// Cloud, via OpenAI's /v1/audio/transcriptions endpoint (whisper-1, verbose_json — the only
/// current model/format combination that returns real per-segment timestamps; gpt-4o-transcribe
/// only supports json/text). Reads its key from the same Keychain entry (.openai) that
/// OpenAIProvider (AIProvider) uses.
struct OpenAIWhisperAPIProvider: TranscriptionProvider {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let model = "whisper-1"

    /// No granular progress from a single HTTP call — the UI falls back to an elapsed-time
    /// display when `fraction` is nil (spec §2).
    var onStatus: TranscriptionStatusHandler?

    func transcribe(audio: URL) async throws -> Transcript {
        AudiumLog.transcription.info("OpenAI transcription started: \(audio.lastPathComponent, privacy: .public)")
        onStatus?("Transcribing via OpenAI…", nil)
        do {
            return try await transcribeInner(audio: audio)
        } catch {
            AudiumLog.transcription.error("OpenAI transcription failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func transcribeInner(audio: URL) async throws -> Transcript {
        guard let apiKey = try KeychainStore.loadForTesting(for: .openai, envOverride: "AUDIUM_OPENAI_KEY_OVERRIDE"), !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey(.openai)
        }

        let audioData = try Data(contentsOf: audio)
        let boundary = "AudiumBoundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", Self.model)
        appendField("response_format", "verbose_json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)

        struct WhisperVerboseResponse: Decodable {
            struct Segment: Decodable {
                let start: Double
                let end: Double
                let text: String
            }
            let segments: [Segment]?
            let text: String?
        }
        let decoded = try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)

        let segments: [TranscriptSegment]
        if let apiSegments = decoded.segments, !apiSegments.isEmpty {
            segments = apiSegments.map {
                TranscriptSegment(text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end, speaker: nil)
            }
        } else {
            let duration = try await audioDurationSeconds(audio)
            segments = [TranscriptSegment(text: decoded.text ?? "", start: 0, end: duration, speaker: nil)]
        }
        let labeled = try await SpeakerDiarizer().labelSpeakers(in: Transcript(segments: segments), audio: audio, onStatus: onStatus)
        AudiumLog.transcription.info("OpenAI transcription succeeded: \(labeled.segments.count) segment(s)")
        return labeled
    }
}

enum TranscriptionProviderKind: String {
    case whisperKit, gemini, openAI
}

/// Persists the user's default transcription provider (spec §5) — separate from
/// AIProvider's default selection, since transcription and text-completion are
/// independent choices. No hardcoded bias: WhisperKit is only the out-of-box fallback
/// when nothing has been chosen yet, not a preference the user can't override.
enum TranscriptionSettings {
    private static let defaultProviderKey = "com.postproduction.Audium.defaultTranscriptionProvider"

    static var defaultProvider: TranscriptionProviderKind {
        get {
            UserDefaults.standard.string(forKey: defaultProviderKey)
                .flatMap(TranscriptionProviderKind.init(rawValue:)) ?? .whisperKit
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultProviderKey)
        }
    }
}

/// Persists the user's WhisperKit model-size choice (spec §2: "Model size selection"). Stores
/// the raw variant string WhisperKit itself reports via `recommendedModels()` — not a hand-picked
/// MacWhisper-style enum, since the two lists don't map 1:1 (this WhisperKit version has no
/// "medium" variant at all, confirmed by inspecting its fallback model-support config rather than
/// assuming). `nil` means "no override" — `WhisperKitProvider` falls back to
/// `WhisperKit.recommendedModels().default` for the current device.
enum WhisperModelSettings {
    private static let variantKey = "com.postproduction.Audium.whisperModelVariant"

    // Empty string is treated the same as unset: WhisperKit's own `download(variant:)` builds
    // its HuggingFace search glob as "*\(variant)/*" — an empty variant collapses that to "*/*",
    // matching every model folder in the repo, which WhisperKit then reports as "Multiple models
    // found matching...". `UserDefaults.string(forKey:)` returns "" as a non-nil value if the key
    // was ever written with an empty string, which would otherwise skip the `??
    // recommendedModels().default` fallback entirely and feed that empty string straight into
    // WhisperKit's glob.
    static var selectedVariant: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: variantKey)
            return (stored?.isEmpty ?? true) ? nil : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: variantKey) }
    }
}
