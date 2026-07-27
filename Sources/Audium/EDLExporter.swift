import AppKit
import UniformTypeIdentifiers

/// CMX3600 EDL export for a Paper Edit (spec §8/§9 — the actual deliverable this tool exists to
/// produce) — mirrors `Exporter.swift`'s render/write/`NSSavePanel` pattern, kept in its own file
/// since the CMX3600 domain (timecode/frame-rate/drop-frame math, reel-name allocation) is
/// substantial and unrelated to Transcript export formats.
///
/// Format researched against real sources rather than assumed (full citations in docs/spec.md
/// §8): event-line layout and the "* FROM CLIP NAME:" comment convention cross-checked against
/// OpenTimelineIO's `otio-cmx3600-adapter` (a maintained, industry-used reference writer) and
/// edlmax.com's EDL guide; the drop-frame conversion algorithm is Andrew Duncan's, as published
/// by David Heidelberger.
enum EDLExporter {
    /// Everything CMX3600 needs for one event — resolved once by the caller (`PaperEditView`,
    /// which already walks `ProjectController.metadata` to resolve each `PaperEditEntry`) rather
    /// than duplicating that folder/daily/highlight lookup here.
    struct Entry {
        /// Identifies which Daily this event came from — lets the reel-name allocator reuse the
        /// same reel name every time the same Daily appears across multiple events (a Paper Edit
        /// commonly pulls several highlights from one Daily). Keying by `dailyDisplayName` alone
        /// would work for that case too, but a stable ID is the more correct/robust identity to
        /// dedupe against.
        let dailyID: UUID
        let dailyDisplayName: String
        /// Original filename including extension (not the on-disk UUID-named copy) — this is
        /// what goes in the "* FROM CLIP NAME:" comment, the traceability path back to source
        /// once the reel name below has been truncated to 8 characters.
        let clipName: String
        /// nil for an audio-only Daily. Also doubles as the CMX3600 track-type signal (below).
        let frameRate: Double?
        let start: TimeInterval
        let end: TimeInterval
        let highlightText: String
    }

    /// EDL timecode has no numeric frame-rate field to fall back to — used only for entries
    /// whose Daily has no captured `frameRate` (audio-only, or a video Daily added before frame
    /// rate capture existed). 30fps non-drop is the conventional safe default for audio-only EDL
    /// content (see docs/spec.md §8).
    private static let fallbackRate: Double = 30

    @MainActor
    static func presentSavePanel(paperEditName: String, entries: [Entry]) {
        let panel = NSSavePanel()
        // Base name only, no `.edl` appended here — `allowedContentTypes` already makes
        // `NSSavePanel` append the extension itself; pre-appending it too produced a real
        // "Paper Edit 1.edl.edl" double-extension bug, caught during live testing.
        panel.nameFieldStringValue = sanitizedFileBaseName(paperEditName)
        panel.allowedContentTypes = [UTType(filenameExtension: "edl") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else {
            AudiumLog.export.info("EDL export canceled by user")
            return
        }
        write(paperEditName: paperEditName, entries: entries, to: url)
    }

    static func write(paperEditName: String, entries: [Entry], to url: URL) {
        AudiumLog.export.info("EDL export started: \(entries.count) event(s) to \(url.lastPathComponent, privacy: .public)")
        do {
            try render(title: paperEditName, entries: entries).write(to: url, atomically: true, encoding: .utf8)
            AudiumLog.export.info("EDL export succeeded: \(url.path, privacy: .public)")
        } catch {
            AudiumLog.export.error("EDL export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sanitizedFileBaseName(_ name: String) -> String {
        name.isEmpty ? "Paper Edit" : name
    }

    // MARK: - Render

    static func render(title: String, entries: [Entry]) -> String {
        var lines: [String] = ["TITLE: \(title)", ""]

        var recordCursor: TimeInterval = 0
        var currentFCM: Bool?
        let reelNames = ReelNameAllocator()

        for (index, entry) in entries.enumerated() {
            let duration = max(0, entry.end - entry.start)
            let recordIn = recordCursor
            let recordOut = recordCursor + duration
            recordCursor = recordOut

            // Each event's own rate governs *both* its source and record columns (not one
            // sequence-wide rate) — CMX3600's `FCM:` flag applies to whatever follows it, so
            // keeping one event line internally consistent means both timecodes on that line
            // share the same drop/non-drop interpretation. Real elapsed record time (tracked in
            // seconds above) still lines up exactly at cut points between differently-rated
            // entries; only the frame-number digits differ, which is exactly how a real mixed-rate
            // EDL looks (see docs/spec.md §8's design-decision note).
            let rate = entry.frameRate ?? fallbackRate
            let isDropFrame = Self.isDropFrame(rate: rate)
            if currentFCM != isDropFrame {
                lines.append(isDropFrame ? "FCM: DROP FRAME" : "FCM: NON-DROP FRAME")
                currentFCM = isDropFrame
            }

            let reel = reelNames.allocate(for: entry.dailyID, displayName: entry.dailyDisplayName)
            // Audio-only Daily -> "A" (single audio channel); video Daily -> "B" (video + audio1,
            // the standard CMX3600 code for a straightforward synced video+audio cut — see
            // docs/spec.md §8 citations). No video-only "V" case: every Daily this app produces
            // either has audio only, or is a video file with its own embedded audio track.
            let kind = entry.frameRate == nil ? "A" : "B"
            let eventNumber = String(format: "%03d", index + 1)
            let reelField = reel.padding(toLength: 8, withPad: " ", startingAt: 0)
            let kindField = kind.padding(toLength: 5, withPad: " ", startingAt: 0)

            let srcIn = timecodeString(seconds: entry.start, rate: rate)
            let srcOut = timecodeString(seconds: entry.end, rate: rate)
            let recIn = timecodeString(seconds: recordIn, rate: rate)
            let recOut = timecodeString(seconds: recordOut, rate: rate)

            lines.append("\(eventNumber)  \(reelField) \(kindField) C        \(srcIn) \(srcOut) \(recIn) \(recOut)")
            lines.append("* FROM CLIP NAME:  \(entry.clipName)")
            if !entry.highlightText.isEmpty {
                lines.append("* \(entry.highlightText)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Reel names

    /// 8-char max, A-Z0-9 only (CMX3600 reel-name constraint, a holdover from tape-reel labeling
    /// — see docs/spec.md §8 citations). Two concerns, handled separately:
    /// - **Same Daily, multiple events** (a Paper Edit commonly pulls several highlights from one
    ///   Daily) must get the *same* reel name every time — that's the whole point of a reel name,
    ///   identifying which source to relink against. Memoized by `dailyID` below; found as a real
    ///   bug during live testing (two highlights from one Daily were getting different reel names
    ///   before this fix).
    /// - **Different Dailies whose names collide after truncation** (e.g. "Scene 1 - INT Kitchen"
    ///   vs "Scene 2 - INT Kitchen" both starting "SCENE1"/"SCENE2"... common enough on real
    ///   project naming to guard) get a numeric suffix instead of silently aliasing to each other.
    private final class ReelNameAllocator {
        private var assigned: [UUID: String] = [:]
        private var used: Set<String> = []

        func allocate(for dailyID: UUID, displayName: String) -> String {
            if let existing = assigned[dailyID] { return existing }
            let base = Self.sanitize(displayName)
            let name: String
            if used.insert(base).inserted {
                name = base
            } else {
                name = Self.disambiguate(base, avoiding: &used)
            }
            assigned[dailyID] = name
            return name
        }

        private static func disambiguate(_ base: String, avoiding used: inout Set<String>) -> String {
            for counter in 1...99 {
                let suffix = String(format: "%02d", counter)
                let candidate = String(base.prefix(max(0, 8 - suffix.count))) + suffix
                if used.insert(candidate).inserted { return candidate }
            }
            return base
        }

        /// "AX" is the documented CMX3600 convention for a clip with no usable reel name (a file
        /// rather than a tape/camera reel) — used here as the fallback when a Daily's display
        /// name has no ASCII-alphanumeric characters at all.
        private static func sanitize(_ name: String) -> String {
            let letters = name.uppercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            let truncated = String(String.UnicodeScalarView(letters)).prefix(8)
            return truncated.isEmpty ? "AX" : String(truncated)
        }
    }

    // MARK: - Timecode

    /// Drop-frame applies only to the 29.97/59.94 NTSC family — every other rate (23.976, 24, 25,
    /// 30 exact, 50, 60 exact) is non-drop. Tolerance must stay tight: exact 30/60 differ from
    /// 29.97/59.94 by 0.03/0.06, so anything looser than that misclassifies a valid non-drop
    /// 30fps/60fps rate as drop-frame (caught by the standalone render test against synthetic
    /// entries before this ever reached a real GUI test — see docs/spec.md §8). 0.01 still safely
    /// catches AVFoundation's `nominalFrameRate` reporting ~29.970029 rather than a bit-exact
    /// 29.97.
    private static func isDropFrame(rate: Double) -> Bool {
        abs(rate - 29.97) < 0.01 || abs(rate - 59.94) < 0.01
    }

    private static func timecodeString(seconds: TimeInterval, rate: Double) -> String {
        let clampedSeconds = max(0, seconds)
        let totalFrames = Int((clampedSeconds * rate).rounded())
        let df = isDropFrame(rate: rate)
        let (hh, mm, ss, ff) = df ? dropFrameComponents(frameCount: totalFrames, rate: rate) : nonDropFrameComponents(frameCount: totalFrames, rate: rate)
        let separator = df ? ";" : ":"
        return String(format: "%02d:%02d:%02d\(separator)%02d", hh, mm, ss, ff)
    }

    private static func nonDropFrameComponents(frameCount: Int, rate: Double) -> (Int, Int, Int, Int) {
        let nominalRate = Int(rate.rounded())
        let frames = frameCount % nominalRate
        let totalSeconds = frameCount / nominalRate
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return (hours, minutes, seconds, frames)
    }

    /// Andrew Duncan / David Heidelberger's drop-frame conversion algorithm (see docs/spec.md §8
    /// for the citation): frame numbers 0 and 1 are skipped at the start of every minute except
    /// every 10th, which keeps drop-frame timecode in step with wall-clock time despite 29.97 not
    /// being exactly 30fps. Naively treating 29.97 as flat 30fps (skipping this entirely) is
    /// exactly the "EDL imports with wrong timing" bug class this exists to avoid.
    private static func dropFrameComponents(frameCount: Int, rate: Double) -> (Int, Int, Int, Int) {
        let nominalRate = Int(rate.rounded()) // 30 or 60
        let dropFramesPerMinute = Int((rate * 0.066666).rounded()) // 2 for 30, 4 for 60
        let framesPerHour = Int((rate * 60 * 60).rounded())
        let framesPer24Hours = framesPerHour * 24
        let framesPer10Minutes = Int((rate * 60 * 10).rounded())
        let framesPerMinute = nominalRate * 60 - dropFramesPerMinute

        var frameNumber = frameCount % framesPer24Hours
        if frameNumber < 0 { frameNumber += framesPer24Hours }

        let tenMinuteBlocks = frameNumber / framesPer10Minutes
        let remainder = frameNumber % framesPer10Minutes

        if remainder > dropFramesPerMinute {
            frameNumber += dropFramesPerMinute * 9 * tenMinuteBlocks + dropFramesPerMinute * ((remainder - dropFramesPerMinute) / framesPerMinute)
        } else {
            frameNumber += dropFramesPerMinute * 9 * tenMinuteBlocks
        }

        let frames = frameNumber % nominalRate
        let seconds = (frameNumber / nominalRate) % 60
        let minutes = (frameNumber / nominalRate / 60) % 60
        let hours = frameNumber / nominalRate / 60 / 60
        return (hours, minutes, seconds, frames)
    }
}
