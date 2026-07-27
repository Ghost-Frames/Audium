import AVFoundation
import AVKit

/// Drives waveform/video preview + playback for the currently-loaded media file (spec §2 "Real
/// audio waveform visualization + playback", spec §8 "Video playback (upgraded from audio-only)").
/// Audio files use `AVAudioPlayer` — always a local file (drag-and-drop copy or downloaded
/// YouTube audio, never a remote stream), and its `currentTime` is a plain synchronous property
/// rather than AVPlayer's async/observer-based time reporting, which is simpler for the playhead
/// poll below. Video files use `AVPlayer` instead (`AVAudioPlayer` doesn't play video), driving a
/// SwiftUI `VideoPlayer` in `WaveformPanel`; audio-only files still get the bar waveform, per the
/// spec's explicit "audio-only dailies still use the existing waveform view" decision.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var waveformSamples: [Float] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isVideo = false
    /// Bound directly into SwiftUI's `VideoPlayer(player:)` when `isVideo`; nil otherwise.
    @Published private(set) var avPlayer: AVPlayer?

    nonisolated static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    /// A few hundred bars reads as a waveform at typical panel widths (~600-900pt) without
    /// per-sample overkill — one bar per 2-3pt.
    private nonisolated static let barCount = 240

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    /// Keeps `isPlaying` accurate when playback is toggled via the native `VideoPlayer` transport
    /// controls (scrub bar, its own play/pause) rather than our own button — `play()`/`pause()`
    /// alone only cover taps on our button.
    private var statusObservation: NSKeyValueObservation?

    func load(url: URL) {
        reset()
        if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
            loadVideo(url: url)
        } else {
            loadAudio(url: url)
        }
    }

    private func loadAudio(url: URL) {
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

    private func loadVideo(url: URL) {
        isVideo = true
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        self.avPlayer = avPlayer
        isLoaded = true

        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.currentTime = time.seconds }
        }
        endObserverToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.avPlayer?.seek(to: .zero)
            }
        }
        statusObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in self?.isPlaying = playing }
        }

        Task {
            let loadedDuration = (try? await item.asset.load(.duration)) ?? .zero
            self.duration = loadedDuration.seconds.isFinite ? loadedDuration.seconds : 0
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isLoaded else { return }
        if isVideo {
            avPlayer?.play()
            isPlaying = true
        } else {
            guard let player else { return }
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
    }

    func pause() {
        if isVideo {
            avPlayer?.pause()
            isPlaying = false
        } else {
            player?.pause()
            isPlaying = false
            tickTask?.cancel()
            currentTime = player?.currentTime ?? currentTime
        }
    }

    func seek(to time: TimeInterval) {
        // `duration` is 0 until `loadVideo`'s async `asset.load(.duration)` resolves — clamping
        // against it during that window (e.g. Paper Edit's load-then-immediately-seek) would
        // wrongly force every seek to 0. Only clamp the upper bound once a real duration is known;
        // AVPlayer safely clamps an out-of-range seek to the item's actual duration internally.
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = max(0, min(time, upperBound))
        if isVideo {
            avPlayer?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        } else {
            player?.currentTime = clamped
        }
        currentTime = clamped
    }

    /// Also called externally when the loaded file is deleted out from under the player (e.g.
    /// deleting the currently-open Daily) and there's nothing new to `load(url:)` in its place.
    func reset() {
        tickTask?.cancel()
        player?.stop()
        player = nil
        if let timeObserverToken { avPlayer?.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
        if let endObserverToken { NotificationCenter.default.removeObserver(endObserverToken) }
        endObserverToken = nil
        statusObservation?.invalidate()
        statusObservation = nil
        avPlayer?.pause()
        avPlayer = nil
        isVideo = false
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
