import AppKit
import UniformTypeIdentifiers
import OSLog

/// Export formats for a completed Transcript (spec §2: "Export: TXT, SRT, VTT, JSON" — JSON
/// deferred, not requested yet; §9 ScriptFixer integration adds `scriptSync`; `.docx` is the last
/// original v2 export requirement).
enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, vtt, scriptSync, docx

    var id: String { rawValue }

    /// `scriptSync` is still plain text on disk — Avid ScriptSync/PhraseFind import a `.txt`
    /// file, not a distinct container format.
    var fileExtension: String {
        self == .scriptSync ? "txt" : rawValue
    }

    var displayName: String {
        self == .scriptSync ? "ScriptSync" : rawValue.uppercased()
    }
}

enum Exporter {
    /// `headingName` is only used by `.scriptSync`/`.docx` (a title banner ahead of the content —
    /// ScriptFixer's per-file scene heading convention for the former, a bold document title for
    /// the latter) — ignored by every other format.
    static func render(_ transcript: Transcript, as format: ExportFormat, headingName: String? = nil) -> String {
        switch format {
        case .txt: return renderTXT(transcript)
        case .srt: return renderSRT(transcript)
        case .vtt: return renderVTT(transcript)
        case .scriptSync: return renderScriptSync(transcript, headingName: headingName)
        case .docx: return "" // binary format — see the `.docx` branch in `write()` instead
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
        write(transcript, as: format, to: url, headingName: baseName)
    }

    /// Render + write + log, split out of `presentSavePanel` so the same logged write path is
    /// reachable without driving an interactive `NSSavePanel` (same precedent as the direct
    /// `Exporter.render` call already used to verify edited-segment export propagation).
    static func write(_ transcript: Transcript, as format: ExportFormat, to url: URL, headingName: String? = nil) {
        AudiumLog.export.info("Export started: \(transcript.segments.count) segment(s) as \(format.displayName, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
        if format == .docx {
            do {
                try DocxExporter.write(paragraphs: renderTranscriptDocxParagraphs(transcript, headingName: headingName), to: url)
                AudiumLog.export.info("Export succeeded: \(url.path, privacy: .public)")
            } catch {
                AudiumLog.export.error("Export failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        let rendered = render(transcript, as: format, headingName: headingName)
        do {
            if format == .scriptSync {
                // Avid's script import expects ASCII text with CR/LF line endings (matches
                // ScriptFixer's own export convention — ghost-frames/ScriptFixer,
                // ScriptExporter.write). Lossy ASCII conversion substitutes '?' for anything
                // sanitizeASCII didn't already map, same as ScriptFixer relies on.
                let crlf = rendered.components(separatedBy: "\n").joined(separator: "\r\n")
                guard let data = crlf.data(using: .ascii, allowLossyConversion: true) else {
                    AudiumLog.export.error("Export failed: could not encode ScriptSync text as ASCII")
                    return
                }
                try data.write(to: url)
            } else {
                try rendered.write(to: url, atomically: true, encoding: .utf8)
            }
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

    // MARK: - ScriptSync (Avid ScriptSync/PhraseFind plain text)
    //
    // Conventions verified against ghost-frames/ScriptFixer's actual source (not memory) —
    // ScriptFormatter.swift + ScriptExporter.swift + InterviewParser.swift, interview-transcript
    // mode's locked `ExportSettings` defaults: flush-left (0-indent, not 18), 45-char hard-wrap
    // width (not 52), bare uppercase speaker cue on its own line with no trailing colon or "OS"
    // suffix (ScriptFixer's README describes a planned `SPEAKER (O.S.)` tag but it isn't
    // implemented in the actual InterviewParser code, so it's not replicated here either), CR/LF
    // line endings, ASCII encoding with lossy substitution for anything the sanitize map misses.
    // A full Daily's transcript exports as one scene (no multi-file scene-heading dividers —
    // those exist in ScriptFixer to separate multiple combined interview files, which doesn't
    // apply to a single Daily), preceded by a heading built from the Daily's own name so the
    // resulting text still identifies its source once it's living inside an Avid script bin.

    private static let scriptSyncASCIIMap: [(Character, String)] = [
        ("\u{201C}", "\""), ("\u{201D}", "\""),   // curly double quotes
        ("\u{2018}", "'"),  ("\u{2019}", "'"),    // curly single quotes / apostrophe
        ("\u{2013}", "-"),  ("\u{2014}", "--"),   // en/em dash
        ("\u{2026}", "..."),                       // ellipsis
        ("\u{00A0}", " "),                         // non-breaking space
    ]

    private static func scriptSyncSanitizeASCII(_ text: String) -> String {
        var result = text
        for (original, replacement) in scriptSyncASCIIMap {
            result = result.replacingOccurrences(of: String(original), with: replacement)
        }
        return result
    }

    private static func scriptSyncHardWrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > width && !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    private struct ScriptSyncTurn {
        var speaker: String?
        var text: String
    }

    /// Merges consecutive same-speaker segments into one turn — a ScriptSync "turn" is the sync
    /// unit, not each individual Whisper/WhisperKit segment fragment.
    private static func scriptSyncTurns(_ segments: [TranscriptSegment]) -> [ScriptSyncTurn] {
        var turns: [ScriptSyncTurn] = []
        for segment in segments {
            if turns.indices.last.map({ turns[$0].speaker == segment.speaker }) == true {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append(ScriptSyncTurn(speaker: segment.speaker, text: segment.text))
            }
        }
        return turns
    }

    private static func renderScriptSync(_ transcript: Transcript, headingName: String? = nil) -> String {
        var lines: [String] = []
        if let headingName {
            let divider = String(repeating: "=", count: 64)
            lines.append(divider)
            lines.append(scriptSyncSanitizeASCII(headingName))
            lines.append(divider)
            lines.append("")
        }
        for turn in scriptSyncTurns(transcript.segments) {
            if let speaker = turn.speaker, !speaker.isEmpty {
                lines.append(scriptSyncSanitizeASCII(speaker.uppercased()))
            }
            let clean = scriptSyncSanitizeASCII(turn.text.trimmingCharacters(in: .whitespaces))
            lines.append(contentsOf: scriptSyncHardWrap(clean, width: 45))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Docx (formatted transcript)
    //
    // Speaker labels bolded, timestamp as a subtle (small/gray/italic) prefix, a bold title
    // banner, and paragraph-after spacing between segments — a real formatted document, not
    // plain text poured into a docx wrapper. See DocxExporter for the underlying OOXML/zip work.

    private static func renderTranscriptDocxParagraphs(_ transcript: Transcript, headingName: String?) -> [DocxExporter.Paragraph] {
        var paragraphs: [DocxExporter.Paragraph] = []
        if let headingName {
            paragraphs.append(DocxExporter.Paragraph(
                [DocxExporter.Run(text: headingName, bold: true, sizeHalfPoints: 32)],
                spacingAfterTwips: 300
            ))
        }
        for segment in transcript.segments {
            var runs: [DocxExporter.Run] = [
                DocxExporter.Run(text: "[\(formatTime(segment.start))] ", italic: true, color: "808080", sizeHalfPoints: 18)
            ]
            if let speaker = segment.speaker, !speaker.isEmpty {
                runs.append(DocxExporter.Run(text: speaker, bold: true))
                runs.append(DocxExporter.Run(text: ": "))
            }
            runs.append(DocxExporter.Run(text: segment.text))
            paragraphs.append(DocxExporter.Paragraph(runs))
        }
        return paragraphs
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
