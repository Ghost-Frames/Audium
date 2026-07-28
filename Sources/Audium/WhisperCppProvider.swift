import Foundation
import OSLog

/// Local, on-device, CPU-only transcription via a bundled `whisper.cpp` binary (spec §3/§5) —
/// the working local option on Intel Macs, where `WhisperKitProvider`'s CoreML pipeline SIGSEGVs
/// before compute-unit dispatch even happens (spec §5, Known Issues). Deliberately named
/// `WhisperCppProvider`, distinct from `WhisperKitProvider` — different engine, different model
/// format, different failure mode, not a variant of the same thing.
///
/// Architecture decision (spec §3): bundled as a static binary at `Resources/bin/whisper-cli`,
/// same pattern as `ffmpeg`/`yt-dlp` — **not** WhisperX/Python. Keeps the zero-dependency/
/// no-Python principle intact (the whole reason `WhisperKitProvider`'s doc comment calls it a
/// CoreML replacement for "WhisperX/Python entirely") rather than reversing it just because this
/// one provider needed a CPU fallback.
enum WhisperCppError: LocalizedError {
    case toolNotFound(String)
    case conversionFailed(String)
    case transcriptionFailed(String)
    case modelDownloadFailed(String)
    case outputNotFound

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): return "\(tool) is missing from the app bundle."
        case .conversionFailed(let reason): return "Audio conversion failed: \(reason)"
        case .transcriptionFailed(let reason): return "whisper.cpp failed: \(reason)"
        case .modelDownloadFailed(let reason): return "Model download failed: \(reason)"
        case .outputNotFound: return "whisper.cpp produced no output file"
        }
    }
}

/// GGML model variants whisper.cpp publishes at huggingface.co/ggerganov/whisper.cpp (confirmed
/// via that repo's own `models/download-ggml-model.sh`, not assumed — see docs/spec.md §3 for the
/// full research citation). Quantized variants (`-q5_0` etc.) are left out for this pass — not
/// requested, and the full-precision set already covers the size/speed tradeoff the picker needs.
enum WhisperCppModel: String, CaseIterable, Identifiable {
    case tinyEn = "tiny.en", tiny
    case baseEn = "base.en", base
    case smallEn = "small.en", small
    case mediumEn = "medium.en", medium
    case largeV1 = "large-v1", largeV2 = "large-v2", largeV3 = "large-v3", largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    /// "base.en" -> "Base (English)", "large-v3-turbo" -> "Large V3 Turbo". Capitalize first,
    /// then append the "(English)" parenthetical — appending it before capitalizing lowercases
    /// it (`\.capitalized` only preserves the first letter of each word), which needed a second
    /// patch-up `.replacingOccurrences` pass to fix; this way there's nothing to patch.
    var displayName: String {
        let isEnglishOnly = rawValue.hasSuffix(".en")
        let base = rawValue.replacingOccurrences(of: ".en", with: "")
            .split(separator: "-").map(\.capitalized).joined(separator: " ")
        return isEnglishOnly ? "\(base) (English)" : base
    }

    var filename: String { "ggml-\(rawValue).bin" }
}

/// Persists the user's whisper.cpp model-size choice, same pattern as `WhisperModelSettings`
/// (WhisperKit's equivalent) — separate key since the two engines' model formats aren't
/// interchangeable. `base.en` default: a reasonable speed/accuracy balance for CPU-only inference
/// (spec §5) — the bigger multilingual/large variants are usable but meaningfully slower with no
/// GPU/ANE acceleration in this build (Metal/CoreML both compiled out, see spec §3).
enum WhisperCppSettings {
    private static let variantKey = "com.postproduction.Audium.whisperCppModelVariant"

    static var selectedVariant: WhisperCppModel {
        get { UserDefaults.standard.string(forKey: variantKey).flatMap(WhisperCppModel.init(rawValue:)) ?? .baseEn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: variantKey) }
    }
}

/// Downloads GGML model files on first use, same "not bundled in the .app" principle as
/// WhisperKit's CoreML models (spec §5, Resolved Decisions) — these run 75MB (tiny) to ~3GB
/// (large), bundling any of them would balloon the DMG for no benefit over a one-time download.
enum WhisperCppModelManager {
    private static let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Audium/whisper-cpp-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localURL(for model: WhisperCppModel) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    static func isDownloaded(_ model: WhisperCppModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    /// Plain `URLSession.download(from:)`, no byte-level progress — a real progress bar would
    /// need a `URLSessionDownloadDelegate` for what's otherwise a one-time, bounded download;
    /// `onStatus`'s existing indeterminate-fraction fallback (elapsed-time display, same path the
    /// cloud providers already use for their single-call requests) already covers this UX case
    /// without the extra class.
    static func ensureDownloaded(_ model: WhisperCppModel, onStatus: TranscriptionStatusHandler?) async throws -> URL {
        let dest = localURL(for: model)
        if isDownloaded(model) { return dest }
        onStatus?("Downloading \(model.displayName) model…", nil)
        AudiumLog.transcription.info("whisper.cpp model download started: \(model.rawValue, privacy: .public)")
        let remote = baseURL.appendingPathComponent(model.filename)
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remote)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw WhisperCppError.modelDownloadFailed("Unexpected response downloading \(model.filename)")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            AudiumLog.transcription.info("whisper.cpp model download succeeded: \(model.rawValue, privacy: .public)")
            return dest
        } catch {
            AudiumLog.transcription.error("whisper.cpp model download failed: \(error.localizedDescription, privacy: .public)")
            throw WhisperCppError.modelDownloadFailed(error.localizedDescription)
        }
    }
}

struct WhisperCppProvider: TranscriptionProvider {
    var onStatus: TranscriptionStatusHandler?

    func transcribe(audio: URL) async throws -> Transcript {
        AudiumLog.transcription.info("whisper.cpp transcription started: \(audio.lastPathComponent, privacy: .public)")
        do {
            let model = WhisperCppSettings.selectedVariant
            onStatus?("Checking model \(model.displayName)…", nil)
            let modelURL = try await WhisperCppModelManager.ensureDownloaded(model, onStatus: onStatus)

            // whisper.cpp's built-in decoder (miniaudio) reads flac/mp3/ogg/wav natively — not
            // the AIFF/M4A this app actually produces (drag-and-drop copies, `extractedAudioURL`'s
            // video exports). Confirmed by testing directly against a real .aiff file before
            // writing this: `read_audio_data: failed to read audio data` (spec §3 citation).
            // Pre-converting to 16kHz mono WAV via the already-bundled `ffmpeg` (same binary
            // `YouTubeDownloader` uses) sidesteps that entirely rather than needing a second
            // audio-decoding dependency.
            onStatus?("Converting audio…", nil)
            let wavURL = try await convertToWAV(audio)
            defer { try? FileManager.default.removeItem(at: wavURL.deletingLastPathComponent()) }

            onStatus?("Transcribing…", nil)
            let segments = try await runWhisperCLI(audio: wavURL, model: modelURL)

            let transcript = try await SpeakerDiarizer().labelSpeakers(in: Transcript(segments: segments), audio: audio, onStatus: onStatus)
            AudiumLog.transcription.info("whisper.cpp transcription succeeded: \(transcript.segments.count) segment(s), model \(model.rawValue, privacy: .public)")
            return transcript
        } catch {
            AudiumLog.transcription.error("whisper.cpp transcription failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func convertToWAV(_ input: URL) async throws -> URL {
        guard let ffmpeg = YouTubeDownloader.resourceBinPath("ffmpeg") else {
            throw WhisperCppError.toolNotFound("ffmpeg")
        }
        // Derived file, not system temp — writes into the configured global cache location (spec
        // §8, "one global cache/render location", same conceptual model as Avid's Media Cache).
        let workDir = try CacheSettings.freshWorkDirectory()
        let outputURL = workDir.appendingPathComponent("audio.wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-i", input.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outputURL.path]

        try await runProcess(process) { status, stderr in
            throw WhisperCppError.conversionFailed(stderr.isEmpty ? "ffmpeg exited with status \(status)" : stderr)
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw WhisperCppError.conversionFailed("Converted WAV not found")
        }
        return outputURL
    }

    /// `-ojf` (full JSON, upgraded from plain `-oj` for spec §8 Stage 1 word-level timestamps) +
    /// `-sow` (split-on-word) writes `<outputBase>.json` with a
    /// `transcription: [{ offsets: { from, to }, text, tokens: [{ text, offsets: { from, to } }] }]`
    /// shape (all offsets in milliseconds) — confirmed against whisper.cpp's own
    /// `examples/cli/cli.cpp` `output_json` function directly (not assumed): `-sow` makes the
    /// decoder merge sub-word BPE tokens on word boundaries before `-ojf` writes them out, so each
    /// segment's `tokens` array becomes real per-word timing rather than raw sub-word pieces (spec
    /// §3/§8 citation). `-np` suppresses the human-readable transcript it'd otherwise print to
    /// stdout, keeping the process's own output limited to what we're not even reading.
    private func runWhisperCLI(audio: URL, model: URL) async throws -> [TranscriptSegment] {
        guard let whisperCli = YouTubeDownloader.resourceBinPath("whisper-cli") else {
            throw WhisperCppError.toolNotFound("whisper-cli")
        }
        // Derived file, not system temp — writes into the configured global cache location (spec
        // §8, "one global cache/render location", same conceptual model as Avid's Media Cache).
        let workDir = try CacheSettings.freshWorkDirectory()
        let outputBase = workDir.appendingPathComponent("output")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperCli)
        process.arguments = [
            "-m", model.path, "-f", audio.path,
            "-ojf", "-sow", "-of", outputBase.path,
            "-np", "-l", "auto",
        ]
        try await runProcess(process) { status, stderr in
            throw WhisperCppError.transcriptionFailed(stderr.isEmpty ? "whisper-cli exited with status \(status)" : stderr)
        }

        let jsonURL = outputBase.appendingPathExtension("json")
        guard let data = try? Data(contentsOf: jsonURL) else {
            throw WhisperCppError.outputNotFound
        }
        struct WhisperCppOutput: Decodable {
            struct Segment: Decodable {
                struct Offsets: Decodable { let from: Double; let to: Double }
                struct Token: Decodable {
                    let text: String
                    // Only present when the token has real per-token timestamps (cli.cpp's
                    // `output_json` only writes this object when `mt.data.t0 > -1 && mt.t1 > -1`)
                    // — absent for e.g. the end-of-segment marker token.
                    let offsets: Offsets?
                }
                let offsets: Offsets
                let text: String
                let tokens: [Token]?
            }
            let transcription: [Segment]
        }
        let decoded = try JSONDecoder().decode(WhisperCppOutput.self, from: data)
        return decoded.transcription.map { segment in
            let words: [TranscriptWord]? = segment.tokens?.compactMap { token in
                guard let offsets = token.offsets else { return nil }
                let text = token.text.trimmingCharacters(in: .whitespaces)
                // Special tokens (`[_BEG_]`, `[_TT_50363]`, `[_EOT_]`, etc. — whisper.cpp's own
                // vocab names every special token with a leading underscore inside the brackets)
                // carry real offsets too — cli.cpp writes them into the same `tokens` array as
                // actual words (confirmed by real GUI testing: `[_BEG_]` showed up as the first
                // "word" in every segment's word list before this filter existed). Matching on
                // `[_` specifically (not bracket-wrapped text generally) matters — this bundled
                // model's own sound annotations use parens, not brackets (confirmed live:
                // "(eerie music)"), but a broader `[...]` match would still wrongly strip a
                // legitimate bracketed annotation from another model/language (caught via
                // adversarial review, not live) — `[_` is specific to whisper.cpp's internal
                // tokens and won't collide with real transcript text.
                guard !text.isEmpty, !(text.hasPrefix("[_") && text.hasSuffix("]")) else { return nil }
                return TranscriptWord(text: text, start: offsets.from / 1000, end: offsets.to / 1000)
            }
            return TranscriptSegment(
                text: segment.text.trimmingCharacters(in: .whitespaces),
                start: segment.offsets.from / 1000,
                end: segment.offsets.to / 1000,
                speaker: nil,
                words: (words?.isEmpty ?? true) ? nil : words
            )
        }
    }

    /// Owns stderr capture itself (a `readabilityHandler`-drained `OutputBuffer`, same class
    /// `YouTubeDownloader` uses for its own subprocess output — shared, not duplicated) rather
    /// than leaving the caller to read the pipe only after the process exits — both `ffmpeg` and
    /// `whisper-cli` write enough to stderr (confirmed directly: ffmpeg's banner/progress output
    /// alone is several KB) that reading only post-exit risks the classic `Process`/`Pipe`
    /// deadlock, where the child blocks on a full pipe buffer that nothing is draining yet.
    /// `stdout` is left unset by callers (`FileHandle.nullDevice`) since neither tool's stdout is
    /// read.
    private func runProcess(_ process: Process, onFailure: (Int32, String) throws -> Void) async throws {
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stderrBuffer = OutputBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(text)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            try onFailure(process.terminationStatus, stderrBuffer.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
