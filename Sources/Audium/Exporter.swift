import AppKit
import UniformTypeIdentifiers
import OSLog

/// Export formats for a completed Transcript (spec §2: "Export: TXT, SRT, VTT, JSON" — JSON
/// deferred, not requested yet).
enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, vtt

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

enum Exporter {
    static func render(_ transcript: Transcript, as format: ExportFormat) -> String {
        switch format {
        case .txt: return renderTXT(transcript)
        case .srt: return renderSRT(transcript)
        case .vtt: return renderVTT(transcript)
        }
    }

    /// Opens an NSSavePanel pre-filled with the source audio's name + the format's extension,
    /// then writes the rendered content if the user confirms.
    @MainActor
    static func presentSavePanel(for transcript: Transcript, format: ExportFormat, sourceURL: URL?) {
        let panel = NSSavePanel()
        let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            AudiumLog.export.info("Export canceled by user (\(format.displayName, privacy: .public))")
            return
        }
        write(transcript, as: format, to: url)
    }

    /// Render + write + log, split out of `presentSavePanel` so the same logged write path is
    /// reachable without driving an interactive `NSSavePanel` (same precedent as the direct
    /// `Exporter.render` call already used to verify edited-segment export propagation).
    static func write(_ transcript: Transcript, as format: ExportFormat, to url: URL) {
        AudiumLog.export.info("Export started: \(transcript.segments.count) segment(s) as \(format.displayName, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
        do {
            try render(transcript, as: format).write(to: url, atomically: true, encoding: .utf8)
            AudiumLog.export.info("Export succeeded: \(url.path, privacy: .public)")
        } catch {
            AudiumLog.export.error("Export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func label(for segment: TranscriptSegment) -> String {
        guard let speaker = segment.speaker else { return segment.text }
        return "\(speaker): \(segment.text)"
    }

    private static func renderTXT(_ transcript: Transcript) -> String {
        transcript.segments.map(label(for:)).joined(separator: "\n")
    }

    // SRT (SubRip): sequential 1-based index, "HH:MM:SS,mmm --> HH:MM:SS,mmm", text, blank line
    // between entries. No file header. Index is mandatory (unlike VTT's optional cue identifier).
    private static func renderSRT(_ transcript: Transcript) -> String {
        transcript.segments.enumerated().map { i, segment in
            "\(i + 1)\n\(timestamp(segment.start, msSeparator: ",")) --> \(timestamp(segment.end, msSeparator: ","))\n\(label(for: segment))"
        }.joined(separator: "\n\n") + "\n"
    }

    // WebVTT: mandatory "WEBVTT" header line followed by a blank line, then cues using
    // "HH:MM:SS.mmm --> HH:MM:SS.mmm" (period, not comma). Cue identifiers exist in the spec but
    // are optional free-form strings (unlike SRT's mandatory numeric index) — omitted here since
    // nothing in this app references cues by id.
    private static func renderVTT(_ transcript: Transcript) -> String {
        let cues = transcript.segments.map { segment in
            "\(timestamp(segment.start, msSeparator: ".")) --> \(timestamp(segment.end, msSeparator: "."))\n\(label(for: segment))"
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n\(cues)\n"
    }

    private static func timestamp(_ seconds: TimeInterval, msSeparator: String) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        let ms = totalMs % 1000
        let totalSeconds = totalMs / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d\(msSeparator)%03d", h, m, s, ms)
    }
}
