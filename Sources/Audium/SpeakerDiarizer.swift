import Foundation
import WhisperKit
import SpeakerKit
import OSLog

/// Runs SpeakerKit against the same audio a transcript was produced from, then merges
/// speaker labels into TranscriptSegment.speaker by timestamp overlap (spec §3, Diarization).
/// Independent of which TranscriptionProvider produced the transcript.
struct SpeakerDiarizer {
    func labelSpeakers(in transcript: Transcript, audio: URL, onStatus: TranscriptionStatusHandler? = nil) async throws -> Transcript {
        AudiumLog.diarization.info("Diarization started: \(audio.lastPathComponent, privacy: .public), \(transcript.segments.count) segment(s)")
        onStatus?("Identifying speakers…", nil)
        do {
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
            let speakerKit = try await SpeakerKit()
            // SpeakerKit reports real chunk-based progress here — same treatment as WhisperKit's
            // decode-window progress, not just a static phase label.
            let result = try await speakerKit.diarize(audioArray: audioArray, progressCallback: { progress in
                let fraction = progress.fractionCompleted
                onStatus?("Identifying speakers: \(Int(fraction * 100))%", fraction)
            })

            let labeledSegments = transcript.segments.map { segment in
                TranscriptSegment(
                    text: segment.text,
                    start: segment.start,
                    end: segment.end,
                    speaker: speakerLabel(for: segment, in: result.segments),
                    words: segment.words
                )
            }
            let speakerCount = Set(labeledSegments.compactMap(\.speaker)).count
            AudiumLog.diarization.info("Diarization succeeded: \(speakerCount) speaker(s) identified")
            return Transcript(segments: labeledSegments)
        } catch {
            AudiumLog.diarization.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func speakerLabel(for segment: TranscriptSegment, in speakerSegments: [SpeakerSegment]) -> String? {
        var bestOverlap: TimeInterval = 0
        var bestSpeakerId: Int?
        for speakerSegment in speakerSegments {
            let overlapStart = max(segment.start, TimeInterval(speakerSegment.startTime))
            let overlapEnd = min(segment.end, TimeInterval(speakerSegment.endTime))
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > bestOverlap, let id = speakerSegment.speaker.speakerId {
                bestOverlap = overlap
                bestSpeakerId = id
            }
        }
        return bestSpeakerId.map { "Speaker \($0)" }
    }
}
