import Foundation
import AVFoundation
import WhisperKit
import OSLog

/// One word within a segment, with its own timing (spec §8 Stage 1 — word-level timestamps).
/// Populated only by providers that actually expose per-word timing (WhisperKit with
/// `DecodingOptions(wordTimestamps: true)`, whisper.cpp with `-ojf -sow`, OpenAI's whisper-1 with
/// `timestamp_granularities: ["word"]`) — see each provider's `transcribe(audio:)` for the
/// real-source citation of its own format. `start`/`end` are in the same absolute (whole-file)
/// timeline as `TranscriptSegment.start`/`end`, not segment-relative — confirmed for all three
/// providers before assuming it (WhisperKit/whisper.cpp derive both from the same seek-offset
/// decode pipeline that already produces absolute segment timestamps; OpenAI's docs example shows
/// word timestamps in the same units/origin as its segment timestamps).
struct TranscriptWord: Codable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct TranscriptSegment: Identifiable, Codable {
    // SwiftUI/ForEach identity only, not persisted (see CodingKeys below) — nothing keys off a
    // segment's id across a save/reload, a Daily's transcript is replaced whole-array on update.
    let id = UUID()
    // Editable in place (spec §2, "Transcript editing"). `start`/`end` stay fixed to whatever
    // transcription produced.
    var text: String
    let start: TimeInterval
    let end: TimeInterval
    var speaker: String?
    /// Word-level timing within this segment (spec §8 Stage 1), nil when the provider doesn't
    /// expose it (Gemini — no internal timestamp structure at all, confirmed against its docs
    /// during the original Gemini provider work — or a pre-Stage-1 transcript saved before this
    /// field existed, which Codable's missing-key-on-Optional handling covers for free, same as
    /// `Daily.frameRate`). Callers needing sub-segment precision (arbitrary text-selection
    /// highlighting, Stage 2) must handle `nil` by falling back to this segment's own `start`/`end`
    /// — never assume this is populated.
    var words: [TranscriptWord]?

    init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil, words: [TranscriptWord]? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.words = words
    }

    private enum CodingKeys: String, CodingKey { case text, start, end, speaker, words }
}

// Codable (spec §8) so a Daily's Transcript can be persisted inline in a Project's single JSON
// metadata file — no separate transcript sidecar files, see Project.swift's doc comment.
struct Transcript: Codable {
    var segments: [TranscriptSegment]

    /// The spoken text between `start` and `end` (spec §8 Stage 2 — resolving a sub-segment
    /// Highlight's range back to text for display). Word-precise when a touched segment has
    /// `words` (only the words actually overlapping the range are included); falls back to that
    /// segment's whole `text` when it doesn't (Gemini transcripts, or pre-Stage-1 legacy data) —
    /// the same graceful-degradation rule Stage 2's selection resolution uses.
    func text(from start: TimeInterval, to end: TimeInterval) -> String {
        var parts: [String] = []
        for segment in segments where segment.end > start && segment.start < end {
            if let words = segment.words {
                let matched = words.filter { $0.end > start && $0.start < end }
                if !matched.isEmpty {
                    parts.append(Self.joinWords(matched))
                    continue
                }
            }
            parts.append(segment.text)
        }
        return parts.joined(separator: " ")
    }

    /// Reassembles word tokens into readable text — a plain `joined(separator: " ")` puts a
    /// space before every token, including punctuation-only ones (`,`/`.`/`?`/etc.), producing
    /// "silence , Can you see" instead of "silence, Can you see" (caught via real GUI testing:
    /// visible the moment a Highlight's underlying segment had real word data to reassemble from).
    /// Punctuation-only tokens attach to the previous word with no leading space instead.
    private static func joinWords(_ words: [TranscriptWord]) -> String {
        var result = ""
        for word in words {
            guard let first = word.text.first else { continue }
            // Punctuation-only tokens (`,`/`.`/`?`) and contraction continuations split onto
            // their own token by whisper.cpp's `-sow` word-splitting (`I` + `'m`, confirmed via
            // real GUI testing — a real transcript's word list really does split "I'm" this way)
            // both attach to the previous word with no leading space.
            let attachesToPrevious = (word.text.allSatisfy { $0.isPunctuation || $0.isSymbol }) || first == "'"
            if !result.isEmpty && !attachesToPrevious { result += " " }
            result += word.text
        }
        return result
    }
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
        // Safety net (spec §5, Known Issues): WhisperKit SIGSEGVs on Intel before compute-unit
        // dispatch, so this can't be caught with a do/catch — it must never be reached at all.
        // Guarded here rather than in each caller since every path that can construct a
        // WhisperKitProvider (the real GUI's default-provider switch, and the dev test hooks in
        // AudiumApp.swift that build one directly) routes through this one function.
        guard HardwareCapability.hasNeuralEngine else {
            AudiumLog.transcription.error("WhisperKit blocked: no Neural Engine on this Mac (known SIGSEGV, spec §5)")
            throw TranscriptionError.unsupportedOnThisHardware
        }
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
            // wordTimestamps: true (spec §8 Stage 1) — WhisperKit only populates
            // `TranscriptionSegment.words` when explicitly asked (default false, confirmed in
            // WhisperKit's own Configurations.swift); off by default because it costs an extra
            // decode pass per TranscribeTask.swift, but this app always wants it now that
            // word-level highlighting depends on it.
            let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: DecodingOptions(wordTimestamps: true), callback: { _ in
                let fraction = pipeRef.progress.fractionCompleted
                onStatus?("Transcribing: \(Int(fraction * 100))%", fraction)
                return true
            })

            let segments = results.flatMap(\.segments).map { segment in
                TranscriptSegment(
                    text: segment.text.trimmingSpecialTokenCharacters(),
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    speaker: nil,
                    words: segment.words?.map {
                        TranscriptWord(text: $0.word.trimmingSpecialTokenCharacters(), start: TimeInterval($0.start), end: TimeInterval($0.end))
                    }
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
    case emptyResponse
    case unsupportedOnThisHardware

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key saved for \(provider.rawValue). Add one in Settings."
        case .unsupportedAudioFormat(let ext):
            return "Unsupported audio format: .\(ext)"
        case .emptyResponse:
            return "Empty transcription response"
        case .unsupportedOnThisHardware:
            return "WhisperKit isn't supported on this Mac yet — an upstream crash affects Intel Macs without a Neural Engine (see docs/spec.md Known Issues). Switch to Gemini or OpenAI in Settings."
        }
    }
}

// `validateHTTP`/`HTTPValidationError` now live in AIProvider.swift, shared by both files —
// same non-2xx-response shape against a different vendor API. See that file's doc comment.

private func audioDurationSeconds(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
}

/// Video dailies (spec §8, video playback) are transcribed the same way audio ones are — every
/// `TranscriptionProvider` and `SpeakerDiarizer` reads its input as an audio file (`AVAudioFile`
/// under the hood for WhisperKit/diarization, raw `Data` for the cloud APIs), which can't open a
/// multiplexed video container directly. Called once up front in `ContentView.runTranscription`
/// so every provider gets a plain `.m4a` regardless of backend.
///
/// `@MainActor` isn't for UI safety here — `AVAssetExportSession.init` itself is thread-agnostic.
/// It's required to avoid a real crash (spec §5, Known Issues): a plain non-actor-isolated async
/// function called from `@MainActor` code runs its body on the global concurrent executor, not on
/// the calling actor's thread. That put this init on a background thread at the exact moment
/// `runTranscription`'s prior `playback.load(url:)` call was making SwiftUI's `VideoPlayer` touch
/// AVKit/AVFoundation's Swift generic metadata for the first time on the main thread — two
/// threads racing to instantiate overlapping generic metadata, which crashed with SIGABRT deep in
/// the Swift runtime. Pinning this function to `@MainActor` serializes both first-touches onto
/// one thread; the actual encode still runs on AVFoundation's own queue after
/// `exportAsynchronously` is called; that queue doesn't touch AVKit-SwiftUI metadata.
@MainActor
func extractedAudioURL(from url: URL) async throws -> URL {
    guard AudioPlaybackController.videoExtensions.contains(url.pathExtension.lowercased()) else { return url }
    let asset = AVURLAsset(url: url)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw TranscriptionError.unsupportedAudioFormat(url.pathExtension)
    }
    // Derived file, not system temp — writes into the configured global cache location (spec §8,
    // "one global cache/render location", same conceptual model as Avid's Media Cache setting).
    let outputURL = try CacheSettings.freshWorkDirectory().appendingPathComponent("audio.m4a")
    export.outputURL = outputURL
    export.outputFileType = .m4a
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        export.exportAsynchronously {
            switch export.status {
            case .completed: continuation.resume()
            case .failed, .cancelled: continuation.resume(throwing: export.error ?? TranscriptionError.emptyResponse)
            default: continuation.resume(throwing: TranscriptionError.emptyResponse)
            }
        }
    }
    return outputURL
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
            guard let apiKey = try KeychainStore.load(for: .gemini), !apiKey.isEmpty else {
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
        guard let apiKey = try KeychainStore.load(for: .openai), !apiKey.isEmpty else {
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
        // Repeated multipart field, one value per array element (confirmed against OpenAI's own
        // docs/community examples, spec §8 Stage 1 citation) — requesting both "segment" and
        // "word" keeps the existing `segments` array in the response *and* adds a top-level
        // `words` array; requesting "word" alone was not verified to keep `segments` present, so
        // both are sent rather than risk losing the array this parser already depends on.
        appendField("timestamp_granularities[]", "segment")
        appendField("timestamp_granularities[]", "word")

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
            // Top-level, sibling of `segments` — NOT nested inside each segment (spec §8 Stage 1
            // citation: confirmed via OpenAI's own documented example response shape). Paired back
            // to its containing segment below by time-range overlap, since the API doesn't do that
            // pairing itself.
            struct Word: Decodable {
                let word: String
                let start: Double
                let end: Double
            }
            let segments: [Segment]?
            let words: [Word]?
            let text: String?
        }
        let decoded = try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)

        let segments: [TranscriptSegment]
        if let apiSegments = decoded.segments, !apiSegments.isEmpty {
            segments = apiSegments.map { segment in
                // A small epsilon tolerates float rounding between a word's timestamp and its
                // segment's boundary — without it, a word landing exactly on `segment.end` (or a
                // hair past it due to rounding) could be silently dropped from every segment.
                let epsilon = 0.05
                let words = decoded.words?
                    .filter { $0.start >= segment.start - epsilon && $0.end <= segment.end + epsilon }
                    .map { TranscriptWord(text: $0.word, start: $0.start, end: $0.end) }
                return TranscriptSegment(
                    text: segment.text.trimmingCharacters(in: .whitespaces),
                    start: segment.start,
                    end: segment.end,
                    speaker: nil,
                    words: (words?.isEmpty ?? true) ? nil : words
                )
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
    case whisperKit, whisperCpp, gemini, openAI
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
