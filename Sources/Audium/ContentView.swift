import SwiftUI
import UniformTypeIdentifiers
import WhisperKit
import SpeakerKit

/// Bento-grid regions per spec §4. Waveform/transcript wiring is real — both drag-and-drop and
/// YouTube URL input feed the same `runTranscription(on:)`, which respects
/// `TranscriptionSettings.defaultProvider` (WhisperKit/Gemini/OpenAI); real waveform rendering
/// and playback (spec §2) live in `AudioPlaybackController`/`WaveformPanel` below.
struct ContentView: View {
    @Environment(\.openWindow) private var openWindow

    @State private var segments: [TranscriptSegment] = []
    @State private var status = "Drop an audio file to begin"
    @State private var statusFraction: Double?
    @State private var isTranscribing = false
    @State private var transcriptionStartedAt: Date?
    @State private var isDropTargeted = false
    @State private var sourceAudioURL: URL?
    @State private var youtubeURLText = ""
    @State private var youtubeError: String?
    @StateObject private var playback = AudioPlaybackController()

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 16) {
                WaveformPanel(
                    playback: playback,
                    status: status,
                    isTargeted: isDropTargeted,
                    isBusy: isTranscribing,
                    urlText: $youtubeURLText,
                    error: youtubeError,
                    onSubmitURL: { Task { await runYouTubeTranscription(urlString: youtubeURLText) } }
                )
                .frame(height: 180)
                .onDrop(of: [.audio], isTargeted: $isDropTargeted, perform: handleDrop)
                TranscriptPanel(
                    segments: $segments,
                    isTranscribing: isTranscribing,
                    status: status,
                    statusFraction: statusFraction,
                    startedAt: transcriptionStartedAt,
                    sourceURL: sourceAudioURL,
                    playback: playback
                )
            }
            AIChatPanel(segments: segments, onShowLogs: { openWindow(id: "logs") })
                .frame(width: 340)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear { seedWaveformTestIfNeeded() }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
            guard let url else { return }
            // The URL is only valid for the duration of this callback — copy it out
            // before handing off to the (async, longer-lived) transcription task.
            let localCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            try? FileManager.default.copyItem(at: url, to: localCopy)
            Task { await runTranscription(on: localCopy) }
        }
        return true
    }

    @MainActor
    private func runYouTubeTranscription(urlString: String) async {
        guard !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        youtubeError = nil
        isTranscribing = true
        transcriptionStartedAt = Date()
        status = "Resolving URL…"
        statusFraction = nil
        do {
            let localURL = try await YouTubeDownloader.downloadAudio(from: urlString) { progressText in
                Task { @MainActor in status = progressText }
            }
            youtubeURLText = ""
            await runTranscription(on: localURL)
        } catch {
            youtubeError = error.localizedDescription
            status = "Drop an audio file to begin"
            isTranscribing = false
            transcriptionStartedAt = nil
        }
    }

    @MainActor
    private func runTranscription(on url: URL) async {
        isTranscribing = true
        if transcriptionStartedAt == nil { transcriptionStartedAt = Date() }
        segments = []
        sourceAudioURL = url
        playback.load(url: url)

        let onStatus: TranscriptionStatusHandler = { message, fraction in
            Task { @MainActor in
                status = message
                statusFraction = fraction
            }
        }

        let provider: TranscriptionProvider
        switch TranscriptionSettings.defaultProvider {
        case .whisperKit:
            var whisperKit = WhisperKitProvider()
            whisperKit.onStatus = onStatus
            provider = whisperKit
        case .gemini:
            var gemini = GeminiTranscriptionProvider()
            gemini.onStatus = onStatus
            provider = gemini
        case .openAI:
            var openAI = OpenAIWhisperAPIProvider()
            openAI.onStatus = onStatus
            provider = openAI
        }

        do {
            let transcript = try await provider.transcribe(audio: url)
            segments = transcript.segments
            status = "\(segments.count) segments"
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
        statusFraction = nil
        isTranscribing = false
        transcriptionStartedAt = nil
    }

    // TEMP manual test hook — see conversation, will be removed after verification (spec §7).
    // Seeds waveform+playback+transcript state directly from a local file, bypassing every
    // TranscriptionProvider — used to verify the waveform/playback/sync feature itself on Zeus
    // (Intel: WhisperKit SIGSEGVs; cloud providers need a Keychain password prompt that blocks
    // synthetic input) without depending on either.
    private func seedWaveformTestIfNeeded() {
        guard let path = ProcessInfo.processInfo.environment["AUDIUM_TEST_WAVEFORM_SEED"] else { return }
        let url = URL(fileURLWithPath: path)
        sourceAudioURL = url
        playback.load(url: url)
        segments = [
            TranscriptSegment(text: "This is the first sentence for testing the waveform.", start: 0.0, end: 2.8, speaker: "Speaker 1"),
            TranscriptSegment(text: "Here comes a second sentence with different words.", start: 2.8, end: 5.6, speaker: "Speaker 1"),
            TranscriptSegment(text: "And now a third and final sentence to wrap things up.", start: 5.6, end: 8.4, speaker: "Speaker 1"),
        ]
        status = "\(segments.count) segments"
    }
}

/// Real waveform + playback (spec §2). Bar-style amplitude visualizer — a row of vertical bars
/// scaled by amplitude with a playhead overlay — is the de facto standard for audio-player UI
/// (SoundCloud-style scrubbers, and the closest match among Aceternity/Magic UI/21st.dev's
/// motion-focused component sets, none of which ship a canonical named "waveform" component).
/// Adapted natively: a `Canvas`-drawn bar row (not per-sample — `AudioPlaybackController`
/// downsamples to ~240 bars), accent-filled up to the playhead and dimmed after it (using the
/// single accent color for "waveform highlights" per spec §4, not a second palette color), with
/// a drag-to-scrub gesture over the same area doubling as tap-to-seek.
///
/// Still the entry point (spec §2 point 5) — drop-target / YouTube URL input shows until a file
/// is loaded, then the waveform replaces it in the same panel.
private struct WaveformPanel: View {
    @ObservedObject var playback: AudioPlaybackController
    let status: String
    let isTargeted: Bool
    let isBusy: Bool
    @Binding var urlText: String
    let error: String?
    let onSubmitURL: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTitle("Waveform")
            if playback.isLoaded {
                loadedContent
            } else {
                entryContent
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .glassPanel()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                .stroke(Theme.accent, lineWidth: isTargeted ? 2 : 0)
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            // YouTube URL transcription (spec §2) — alongside drag-and-drop, not a replacement.
            HStack(spacing: 8) {
                TextField("Paste a YouTube URL…", text: $urlText)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .glassPanel(cornerRadius: 10)
                    .onSubmit(onSubmitURL)
                Button("Transcribe") { onSubmitURL() }
                    .font(.caption.bold())
                    .buttonStyle(.accent)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
        }
    }

    private var loadedContent: some View {
        VStack(spacing: 8) {
            WaveformBarsView(playback: playback)
                .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.accent)
                Text(formatTime(playback.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.accent)
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatTime(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if isBusy {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The bars themselves plus the draggable/tappable playhead. A single `DragGesture` with zero
/// minimum distance covers both a plain click-to-seek and a press-and-drag scrub — one gesture,
/// not two competing recognizers.
private struct WaveformBarsView: View {
    @ObservedObject var playback: AudioPlaybackController

    var body: some View {
        GeometryReader { geo in
            let progress = playback.duration > 0 ? playback.currentTime / playback.duration : 0

            Canvas { context, size in
                let samples = playback.waveformSamples
                guard !samples.isEmpty else { return }
                let barSpacing: CGFloat = 2
                let barWidth = max(1, size.width / CGFloat(samples.count) - barSpacing)
                let midY = size.height / 2
                let playedBars = Int(progress * Double(samples.count))

                for (index, amplitude) in samples.enumerated() {
                    let x = CGFloat(index) * (barWidth + barSpacing)
                    let barHeight = max(2, CGFloat(amplitude) * size.height)
                    let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                    let color = index <= playedBars ? Theme.accent : Theme.accent.opacity(0.28)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 4)
                    .offset(x: geo.size.width * progress)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in seek(at: value.location.x, in: geo.size.width) }
            )
        }
    }

    private func seek(at x: CGFloat, in width: CGFloat) {
        guard width > 0, playback.duration > 0 else { return }
        let fraction = max(0, min(1, x / width))
        playback.seek(to: fraction * playback.duration)
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d", m, s)
}

private struct TranscriptPanel: View {
    @Binding var segments: [TranscriptSegment]
    let isTranscribing: Bool
    let status: String
    let statusFraction: Double?
    let startedAt: Date?
    let sourceURL: URL?
    @ObservedObject var playback: AudioPlaybackController

    /// Last segment whose start falls at or before the playhead — the one currently playing
    /// (spec §2: "clickable transcript sync"). A linear scan over a few hundred segments at most,
    /// re-run on every ~50ms playhead tick; no need for anything fancier.
    private var currentSegmentID: TranscriptSegment.ID? {
        guard playback.isLoaded else { return nil }
        return segments.last { $0.start <= playback.currentTime }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelTitle("Transcript")
                Spacer()
                if !segments.isEmpty {
                    ExportMenu(segments: segments, sourceURL: sourceURL)
                }
            }
            if isTranscribing {
                TranscriptionProgressView(phase: status, fraction: statusFraction, startedAt: startedAt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                Spacer()
                Text("No transcript yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                let currentID = currentSegmentID
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach($segments) { $segment in
                                SegmentRow(
                                    segment: $segment,
                                    isCurrent: segment.id == currentID,
                                    onSeek: { playback.seek(to: segment.start) }
                                )
                                .id(segment.id)
                            }
                        }
                    }
                    .onChange(of: currentID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
    }
}

/// Real transcription progress (spec §2) — a determinate bar + percent where the provider
/// reports one (WhisperKit model download, WhisperKit/SpeakerKit processing chunks), otherwise
/// an elapsed-time counter so a long-running cloud call still reads as "alive" rather than a
/// bare spinner. `startedAt` drives the counter via `TimelineView` rather than a manual
/// Timer/Task — one fewer piece of state to keep in sync.
private struct TranscriptionProgressView: View {
    let phase: String
    let fraction: Double?
    let startedAt: Date?

    /// Past this many seconds with no determinate progress, hint that something may be stuck
    /// rather than leaving the user to guess (spec §2).
    private static let stuckHintThreshold = 30

    var body: some View {
        VStack(spacing: 10) {
            if let fraction {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                    .frame(maxWidth: 220)
                Text(phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                TimelineView(.periodic(from: startedAt ?? .now, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startedAt ?? context.date))
                    VStack(spacing: 4) {
                        Text("\(phase) \(elapsed)s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if elapsed >= Self.stuckHintThreshold {
                            Text("This is taking longer than expected…")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent.opacity(0.8))
                        }
                    }
                }
            }
        }
    }
}

/// One transcript segment, editable in place (spec §2: "Transcript editing (inline
/// correction..."). Text and speaker are independently click-to-edit — a real Button (not just
/// a bare tap gesture) so the affordance is keyboard/accessibility-reachable, plus double-click
/// on the text itself as a shortcut — since they're logically separate corrections (a
/// mistranscription vs. a diarization mislabel). Timestamps are read-only (spec §5, resolved:
/// text-only editing for v1, no word-level resync).
///
/// Enter/losing focus commits (the field writes straight through the binding as you type, so
/// "commit" is really just leaving edit mode); Escape reverts to a snapshot taken when editing
/// started. No undo/redo beyond that single revert — out of scope for this pass, flagged as a
/// possible future addition rather than built now.
private struct SegmentRow: View {
    @Binding var segment: TranscriptSegment
    /// True while this is the segment under the playhead (spec §2, clickable transcript sync).
    let isCurrent: Bool
    let onSeek: () -> Void

    @State private var isEditingText = false
    @State private var isEditingSpeaker = false
    @State private var textSnapshot = ""
    @State private var speakerSnapshot = ""
    @FocusState private var textFieldFocused: Bool
    @FocusState private var speakerFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(formatTime(segment.start)) { onSeek() }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.accent)
                speakerField
            }
            textField
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSeek() }
    }

    private func enterTextEdit() {
        textSnapshot = segment.text
        isEditingText = true
    }

    private func enterSpeakerEdit() {
        speakerSnapshot = segment.speaker ?? ""
        if segment.speaker == nil { segment.speaker = "" }
        isEditingSpeaker = true
    }

    @ViewBuilder
    private var speakerField: some View {
        if isEditingSpeaker {
            TextField("Speaker", text: Binding(
                get: { segment.speaker ?? "" },
                set: { segment.speaker = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(Theme.accent)
            .frame(width: 110)
            .focused($speakerFieldFocused)
            .onAppear { speakerFieldFocused = true }
            .onSubmit { isEditingSpeaker = false }
            .onExitCommand {
                segment.speaker = speakerSnapshot.isEmpty ? nil : speakerSnapshot
                isEditingSpeaker = false
            }
            .onChange(of: speakerFieldFocused) { _, focused in
                if !focused { isEditingSpeaker = false }
            }
        } else {
            Button(segment.speaker ?? "+ speaker") { enterSpeakerEdit() }
                .buttonStyle(.plain)
                .font(segment.speaker == nil ? .caption : .caption.bold())
                .foregroundStyle(segment.speaker == nil ? .secondary : Theme.accent)
        }
    }

    @ViewBuilder
    private var textField: some View {
        if isEditingText {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Segment text", text: $segment.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(6)
                    .glassPanel(cornerRadius: 8)
                    .focused($textFieldFocused)
                    .onAppear { textFieldFocused = true }
                    .onSubmit { isEditingText = false }
                    .onExitCommand {
                        segment.text = textSnapshot
                        isEditingText = false
                    }
                    .onChange(of: textFieldFocused) { _, focused in
                        if !focused { isEditingText = false }
                    }
                HStack(spacing: 6) {
                    Button("Done") { isEditingText = false }
                        .font(.caption.bold())
                        .buttonStyle(.accent)
                    Button("Cancel") {
                        segment.text = textSnapshot
                        isEditingText = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Text(segment.text)
                    .onTapGesture(count: 2) { enterTextEdit() }
                Button { enterTextEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent.opacity(0.7))
            }
        }
    }
}

/// Export toolbar entry point (spec §2: "Export: TXT, SRT, VTT"). Uses the shared
/// AccentButtonStyle rather than a stock Button — this is established chrome, not throwaway UI.
private struct ExportMenu: View {
    let segments: [TranscriptSegment]
    let sourceURL: URL?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName) {
                    Exporter.presentSavePanel(for: Transcript(segments: segments), format: format, sourceURL: sourceURL)
                }
                .font(.caption.bold())
                .buttonStyle(.accent)
            }
        }
    }
}

private struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var content: String
    /// The text actually sent to the API for this turn, when it differs from what's displayed —
    /// e.g. quick actions show a short label ("Summarize transcript") but send a full instruction.
    /// Falls back to `content` when nil.
    var payload: String?
    var isError = false

    init(role: Role, content: String, payload: String? = nil, isError: Bool = false) {
        self.role = role
        self.content = content
        self.payload = payload
        self.isError = isError
    }
}

/// Chat/cleanup panel (spec §3, Multi-provider AI). Adapts two patterns from Vercel AI SDK
/// Elements (visual/interaction reference only, no code borrowed): its `Conversation`/`Message`
/// pair — a scrollable message list with role-based bubble styling, user right-aligned, assistant
/// left-aligned — and its `PromptInput` composer — a bottom-pinned input with a toolbar row
/// (here: Cleanup/Summarize quick actions) above the text field + submit button.
private struct AIChatPanel: View {
    let segments: [TranscriptSegment]
    let onShowLogs: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var providerKind = ChatSettings.defaultProvider

    private var transcriptText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PanelTitle("AI Chat")
                Spacer()
                Button(action: onShowLogs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Show Logs")
                Picker("", selection: $providerKind) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 100)
                .onChange(of: providerKind) { _, newValue in ChatSettings.defaultProvider = newValue }
            }

            conversationList

            HStack(spacing: 6) {
                Button("Cleanup") { runQuickAction(instruction: "Clean up this transcript: fix punctuation and remove filler words/false starts, but keep the wording otherwise unchanged. Reply with only the cleaned transcript.", label: "Clean up transcript") }
                    .font(.caption.bold())
                    .buttonStyle(.accent)
                    .disabled(segments.isEmpty || isLoading)
                Button("Summarize") { runQuickAction(instruction: "Summarize this transcript in a few sentences.", label: "Summarize transcript") }
                    .font(.caption.bold())
                    .buttonStyle(.accent)
                    .disabled(segments.isEmpty || isLoading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(8)
                    .glassPanel(cornerRadius: 10)
                Button("Send") { send(inputText) }
                    .buttonStyle(.accent)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Text("Ask about your transcript, or use a quick action below.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                    if isLoading {
                        ProgressView().tint(Theme.accent).id("loading")
                    }
                }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func runQuickAction(instruction: String, label: String) {
        send(label, payload: instruction)
    }

    private func send(_ text: String, payload: String? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPayload = (payload ?? trimmedText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty else { return }
        messages.append(ChatMessage(role: .user, content: trimmedText, payload: payload))
        inputText = ""

        var apiMessages: [Message] = []
        if !transcriptText.isEmpty {
            apiMessages.append(Message(
                role: .system,
                content: "You are assisting with the following transcript. Use it as context for the user's requests.\n\nTranscript:\n\(transcriptText)"
            ))
        }
        apiMessages += messages.filter { !$0.isError }.map {
            Message(role: $0.role == .user ? .user : .assistant, content: $0.payload ?? $0.content)
        }

        isLoading = true
        let kind = providerKind
        Task {
            do {
                let reply = try await kind.makeProvider().complete(messages: apiMessages, model: kind.defaultModel)
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: reply))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: error.localizedDescription, isError: true))
                    isLoading = false
                }
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            Text(message.content)
                .foregroundStyle(message.isError ? .red : .primary)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.role == .user ? Theme.accent.opacity(0.22) : Color.clear)
                        .background(message.role == .assistant ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }
}
