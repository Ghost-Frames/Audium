import Foundation
import OSLog

enum YouTubeDownloadError: LocalizedError {
    case invalidURL
    case toolNotFound(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid URL."
        case .toolNotFound(let tool): return "\(tool) is missing from the app bundle."
        case .downloadFailed(let reason): return "Download failed: \(reason)"
        }
    }
}

/// Not `private` — reused by `WhisperCppProvider` for its own subprocess stderr capture (same
/// readabilityHandler-drained pattern, shared instead of duplicated).
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ s: String) {
        lock.lock()
        text += s
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

/// Downloads audio from a YouTube URL via the bundled yt-dlp binary (spec §2). This type's only
/// job is "URL in, local audio file URL out" — the caller feeds the result into the exact same
/// TranscriptionProvider pipeline drag-and-drop already uses; no transcription logic lives here.
enum YouTubeDownloader {
    /// Bundled at Contents/Resources/bin/<tool> in the shipped .app, same convention QCheck uses
    /// for ffmpeg/ffprobe (Resources/bin/<tool>, copied+signed by build.sh). Falls back to the
    /// repo-relative copy so `swift run` works during dev without a full .app build. Not
    /// `private` — `WhisperCppProvider` reuses this same lookup for its own bundled binaries
    /// (`ffmpeg`, `whisper-cli`) rather than duplicating it.
    static func resourceBinPath(_ tool: String) -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(tool)").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        let devFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/Audium
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Resources/bin/\(tool)").path
        return FileManager.default.fileExists(atPath: devFallback) ? devFallback : nil
    }

    /// Downloads best-available audio as m4a/AAC — the same container WhisperKit/AVFoundation
    /// and both cloud transcription providers already accept for drag-and-drop, so no new format
    /// decision is needed.
    static func downloadAudio(from urlString: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        AudiumLog.youtube.info("YouTube download started: \(urlString, privacy: .public)")
        do {
            return try await downloadAudioInner(from: urlString, onProgress: onProgress)
        } catch {
            AudiumLog.youtube.error("YouTube download failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func downloadAudioInner(from urlString: String, onProgress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            throw YouTubeDownloadError.invalidURL
        }
        guard let ytdlp = resourceBinPath("yt-dlp") else {
            throw YouTubeDownloadError.toolNotFound("yt-dlp")
        }
        // -x/--audio-format needs ffmpeg to actually do the extraction/remux. Pointed at
        // explicitly (--ffmpeg-location) rather than left to PATH — a clean user Mac has no
        // system ffmpeg, only what we bundle.
        guard let ffmpeg = resourceBinPath("ffmpeg") else {
            throw YouTubeDownloadError.toolNotFound("ffmpeg")
        }

        // Derived file, not system temp — writes into the configured global cache location (spec
        // §8, "one global cache/render location", same conceptual model as Avid's Media Cache).
        let workDir = try CacheSettings.freshWorkDirectory()
        let outputTemplate = workDir.appendingPathComponent("audio.%(ext)s").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "--newline", "--no-playlist",
            "-f", "bestaudio/best",
            "-x", "--audio-format", "m4a",
            "--ffmpeg-location", ffmpeg,
            "-o", outputTemplate,
            url.absoluteString,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // readabilityHandler fires on a GCD-managed queue, not the caller's — needs a lock, not
        // a bare `var`, to accumulate across concurrent invocations without a data race.
        let stderrBuffer = OutputBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(text)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                if let percent = parsePercent(String(line)) {
                    onProgress?("Downloading: \(percent)")
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw YouTubeDownloadError.downloadFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let reason = stderrBuffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
            throw YouTubeDownloadError.downloadFailed(reason.isEmpty ? "yt-dlp exited with status \(process.terminationStatus)" : reason)
        }

        let downloaded = workDir.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: downloaded.path) else {
            throw YouTubeDownloadError.downloadFailed("Downloaded file not found")
        }
        AudiumLog.youtube.info("YouTube download succeeded: \(downloaded.lastPathComponent, privacy: .public)")
        return downloaded
    }

    // yt-dlp --newline progress lines look like: "[download]  45.2% of 3.45MiB at 1.23MiB/s ETA 00:02"
    private static func parsePercent(_ line: String) -> String? {
        guard line.contains("[download]"), let percentRange = line.range(of: "%") else { return nil }
        let prefix = line[..<percentRange.lowerBound]
        guard let lastSpace = prefix.lastIndex(of: " ") else { return nil }
        let numberPart = prefix[prefix.index(after: lastSpace)...]
        return Double(numberPart) != nil ? "\(numberPart)%" : nil
    }
}
