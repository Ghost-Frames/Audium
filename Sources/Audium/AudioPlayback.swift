import AVFoundation

/// Drives waveform + playback for the currently-loaded audio file (spec §2, "Real audio waveform
/// visualization + playback"). AVAudioPlayer over AVPlayer — this is always a local file
/// (drag-and-drop copy or downloaded YouTube audio, never a remote stream), and AVAudioPlayer's
/// `currentTime` is a plain synchronous property rather than AVPlayer's async/observer-based time
/// reporting, which is simpler for the playhead poll below.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var isLoaded = false

    /// A few hundred bars reads as a waveform at typical panel widths (~600-900pt) without
    /// per-sample overkill — one bar per 2-3pt.
    private nonisolated static let barCount = 240

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    func load(url: URL) {
        reset()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        isLoaded = true

        Task.detached(priority: .userInitiated) {
            let samples = Self.extractWaveform(from: url, barCount: Self.barCount)
            await MainActor.run { [weak self] in
                self?.waveformSamples = samples
            }
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player, isLoaded else { return }
        player.play()
        isPlaying = true
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, self.isPlaying {
                self.currentTime = self.player?.currentTime ?? 0
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        tickTask?.cancel()
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        player?.currentTime = clamped
        currentTime = clamped
    }

    private func reset() {
        tickTask?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        waveformSamples = []
        isLoaded = false
    }

    /// Peak amplitude per bar, normalized to 0...1. Runs off the main actor (`Self.` only, no
    /// `self` capture) so a long file doesn't block the UI; called once per `load`, not per
    /// render.
    private nonisolated static func extractWaveform(from url: URL, barCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData else { return [] }

        let sampleCount = Int(buffer.frameLength)
        guard sampleCount > 0 else { return [] }
        let channelCount = Int(format.channelCount)
        let samplesPerBar = max(1, sampleCount / barCount)

        var bars: [Float] = []
        bars.reserveCapacity(barCount)
        var i = 0
        while i < sampleCount {
            let end = min(i + samplesPerBar, sampleCount)
            var peak: Float = 0
            for channel in 0..<channelCount {
                let data = channelData[channel]
                for j in stride(from: i, to: end, by: 1) {
                    peak = max(peak, abs(data[j]))
                }
            }
            bars.append(peak)
            i = end
        }

        let maxAmp = bars.max() ?? 0
        guard maxAmp > 0 else { return bars }
        return bars.map { $0 / maxAmp }
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.tickTask?.cancel()
            self.currentTime = 0
            self.player?.currentTime = 0
        }
    }
}
