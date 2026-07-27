import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import WhisperKit
import SpeakerKit

/// Bento-grid regions per spec §4. Waveform/transcript wiring is real — both drag-and-drop and
/// YouTube URL input feed the same `runTranscription(on:)`, which respects
/// `TranscriptionSettings.defaultProvider` (WhisperKit/Gemini/OpenAI); real waveform rendering
/// and playback (spec §2) live in `AudioPlaybackController`/`WaveformPanel` below.
struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var segments: [TranscriptSegment] = []
    @State private var status = "Drop an audio or video file to begin"
    @State private var statusFraction: Double?
    @State private var isTranscribing = false
    @State private var transcriptionStartedAt: Date?
    @State private var isDropTargeted = false
    @State private var sourceAudioURL: URL?
    @State private var youtubeURLText = ""
    @State private var youtubeError: String?
    /// The Daily currently loaded into the Waveform/Transcript panels, if any (nil for a
    /// standalone/no-project file). Lets "Re-transcribe" and folder/daily deletion know which
    /// on-disk Daily — if any — the currently-displayed transcript actually belongs to.
    @State private var currentDailyID: UUID?
    /// Shared with the Paper Edit window (spec §8) — owned by `AudiumApp`, not this view, so both
    /// windows drive the same playback engine/project state instead of separate copies.
    @EnvironmentObject private var playback: AudioPlaybackController
    @EnvironmentObject private var project: ProjectController

    /// User-resizable Waveform/Preview panel height (spec fix: video preview was too small at
    /// the old fixed 180pt, and needed to be resizable, not just bigger). Persists across
    /// launches like other UI state in this app (window size, provider selections) — `@AppStorage`
    /// is the native fit, no need for a hand-rolled UserDefaults wrapper. Default (360) roughly
    /// doubles the old fixed height, sized for a comfortable video preview without starving the
    /// Transcript panel below it at the window's minHeight (700, per `AudiumApp.swift`).
    @AppStorage("com.postproduction.Audium.waveformPanelHeight") private var waveformPanelHeight: Double = 360

    private static let minWaveformHeight: CGFloat = 160
    private static let minTranscriptHeight: CGFloat = 220

    var body: some View {
        HStack(spacing: 16) {
            ProjectBrowserPanel(project: project, onSelectDaily: loadDaily, onDailyDeleted: clearLoadedContentIfMatches)
                .frame(width: 240)
            GeometryReader { geo in
                let maxWaveformHeight = max(Self.minWaveformHeight, geo.size.height - Self.minTranscriptHeight - 12)
                let clampedHeight = min(max(CGFloat(waveformPanelHeight), Self.minWaveformHeight), maxWaveformHeight)
                VStack(spacing: 0) {
                    WaveformPanel(
                        playback: playback,
                        status: status,
                        isTargeted: isDropTargeted,
                        isBusy: isTranscribing,
                        urlText: $youtubeURLText,
                        error: youtubeError,
                        onSubmitURL: { Task { await runYouTubeTranscription(urlString: youtubeURLText) } },
                        onBrowse: browseForFile,
                        onRetranscribe: { Task { await retranscribeCurrent() } }
                    )
                    .frame(height: clampedHeight)
                    .onDrop(of: [.audiovisualContent], isTargeted: $isDropTargeted, perform: handleDrop)
                    PanelResizeHandle(height: $waveformPanelHeight, minHeight: Self.minWaveformHeight, maxHeight: maxWaveformHeight)
                    TranscriptPanel(
                        segments: $segments,
                        isTranscribing: isTranscribing,
                        status: status,
                        statusFraction: statusFraction,
                        startedAt: transcriptionStartedAt,
                        sourceURL: sourceAudioURL,
                        playback: playback,
                        highlights: currentHighlights,
                        paperEdits: project.metadata?.paperEdits ?? [],
                        dailyID: currentDailyID,
                        onToggleHighlight: toggleHighlight,
                        onRemoveHighlight: removeHighlight,
                        onAddToPaperEdit: addToPaperEdit
                    )
                }
            }
            AIChatPanel(segments: segments)
                .frame(width: 340)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .toolbar {
            // Window toolbar cluster (spec §8/toolbar reorg) — Settings/About/Logs live here now
            // instead of inside AIChatPanel's header, which was fighting the role/provider
            // pickers for the panel's fixed 340pt width (see the "AI Chat" header overflow fix).
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "paperEdit") } label: {
                    Image(systemName: "film.stack")
                }
                .help("Paper Edit")
                Button { openWindow(id: "about") } label: {
                    Image(systemName: "info.circle")
                }
                .help("About Audium")
                Button { openWindow(id: "logs") } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Show Logs")
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.audiovisualContent.identifier) { url, _ in
            guard let url else { return }
            // The URL is only valid for the duration of this callback — copy it out
            // before handing off to the (async, longer-lived) transcription task. The copy lives
            // in its own UUID-named subdirectory (rather than being renamed to a UUID itself) so
            // the original filename survives into Daily.displayName instead of showing a UUID.
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let localCopy = tempDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: localCopy)
            Task { await ingest(localCopy) }
        }
        return true
    }

    /// Click-to-browse alternative to drag-and-drop (same `ingest()` destination either way) —
    /// NSOpenPanel's URL is already a stable, directly-accessible file path, so unlike
    /// `handleDrop` there's no need to copy it to a temp location first.
    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio or Video File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audiovisualContent]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await ingest(url) }
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
            await ingest(localURL)
        } catch {
            youtubeError = error.localizedDescription
            status = "Drop an audio or video file to begin"
            isTranscribing = false
            transcriptionStartedAt = nil
        }
    }

    /// Routes a newly-dropped/downloaded file to either standalone transcription (no project
    /// open, unchanged v1 behavior — spec §8 point 4's decision) or project ingestion (copies
    /// the file into the currently-selected folder as a new Daily, then transcribes that copy).
    @MainActor
    private func ingest(_ url: URL) async {
        guard project.metadata != nil else {
            currentDailyID = nil
            await runTranscription(on: url)
            return
        }
        guard let folderID = project.selectedFolderID else {
            status = "Select or create a project folder first"
            return
        }
        do {
            let (daily, mediaURL) = try await project.addDaily(from: url, to: folderID)
            currentDailyID = daily.id
            await runTranscription(on: mediaURL, dailyID: daily.id)
        } catch {
            status = "Couldn't add daily: \(error.localizedDescription)"
        }
    }

    private func loadDaily(_ daily: Daily, in folder: ProjectFolder) {
        currentDailyID = daily.id
        segments = daily.transcript.segments
        let url = project.mediaURL(for: daily, in: folder)
        sourceAudioURL = url
        playback.load(url: url)
        status = daily.transcript.segments.isEmpty ? "No transcript yet" : "\(daily.transcript.segments.count) segments"
        statusFraction = nil
        isTranscribing = false
        transcriptionStartedAt = nil
    }

    /// Re-runs transcription against whatever's currently loaded (spec fix: manual retranscribe,
    /// for a bad first pass or a provider/model change) — same `runTranscription` the initial
    /// ingest used, just re-invoked on demand rather than automatically.
    @MainActor
    private func retranscribeCurrent() async {
        guard let sourceAudioURL else { return }
        await runTranscription(on: sourceAudioURL, dailyID: currentDailyID)
    }

    /// Highlights for whatever Daily is currently loaded (spec §8, highlight marking) — derived
    /// straight from `project.metadata` rather than mirrored into separate `@State`, so it stays
    /// automatically in sync with every `addHighlight`/`removeHighlight` call with no manual
    /// re-fetch. Empty for a standalone (no-project) file — highlights are Daily data, and a
    /// standalone file has no Daily to attach them to (same constraint Re-transcribe's
    /// `dailyID` already follows).
    private var currentHighlights: [Highlight] {
        guard let currentDailyID, let metadata = project.metadata else { return [] }
        for folder in metadata.folders {
            if let daily = folder.dailies.first(where: { $0.id == currentDailyID }) { return daily.highlights }
        }
        return []
    }

    /// Marks/unmarks a single segment as a Highlight (spec §8: per-segment marking, the simpler
    /// of the two selection mechanisms considered — cross-segment ranges are a later follow-up).
    /// Toggled by matching `start` against any existing highlight for this segment; segments can
    /// share duplicate text but not duplicate start times within one transcript, so `start` alone
    /// is a safe identity check here (same reasoning as `Highlight`'s own doc comment).
    private func toggleHighlight(for segment: TranscriptSegment) {
        guard let currentDailyID else { return }
        if let existing = currentHighlights.first(where: { $0.start == segment.start }) {
            project.removeHighlight(existing.id, from: currentDailyID)
        } else {
            project.addHighlight(Highlight(id: UUID(), start: segment.start, end: segment.end, note: nil, createdAt: Date()), to: currentDailyID)
        }
    }

    private func removeHighlight(_ highlightID: UUID) {
        guard let currentDailyID else { return }
        project.removeHighlight(highlightID, from: currentDailyID)
    }

    /// Adds a Highlight to a Paper Edit (spec §8) — `paperEditID` nil means "no existing Paper
    /// Edit was chosen from the menu, create one first" (default-named, same "just works" spirit
    /// as `+ New Folder`, renamable later if that's ever added).
    private func addToPaperEdit(_ highlight: Highlight, paperEditID: UUID?) {
        guard let currentDailyID else { return }
        let targetID = paperEditID ?? project.addPaperEdit(name: "Paper Edit \((project.metadata?.paperEdits.count ?? 0) + 1)").id
        project.addPaperEditEntry(highlightID: highlight.id, dailyID: currentDailyID, to: targetID)
    }

    /// Clears the loaded-file state after the currently-displayed Daily is deleted out from under
    /// it, so the panels don't keep showing a transcript/waveform for media that no longer exists.
    /// Only reacts when the deleted Daily is the one actually loaded — deleting some other Daily
    /// (or a folder that doesn't contain the loaded one) shouldn't disturb what's on screen.
    private func clearLoadedContentIfMatches(deletedDailyID: UUID) {
        guard currentDailyID == deletedDailyID else { return }
        currentDailyID = nil
        segments = []
        sourceAudioURL = nil
        playback.reset()
        status = "Drop an audio or video file to begin"
        statusFraction = nil
    }

    @MainActor
    private func runTranscription(on url: URL, dailyID: UUID? = nil) async {
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
        case .whisperCpp:
            var whisperCpp = WhisperCppProvider()
            whisperCpp.onStatus = onStatus
            provider = whisperCpp
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
            // Video dailies (spec §8) get their audio track extracted first — every provider
            // reads its input as an audio file, and playback (above) already got the original
            // video URL for preview, so this doesn't disturb what's on screen.
            status = "Preparing audio…"
            let transcribeURL = try await extractedAudioURL(from: url)
            let transcript = try await provider.transcribe(audio: transcribeURL)
            segments = transcript.segments
            status = "\(segments.count) segments"
            if let dailyID { project.updateDailyTranscript(dailyID, segments: transcript.segments) }
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
        statusFraction = nil
        isTranscribing = false
        transcriptionStartedAt = nil
    }

}

/// Project browser sidebar (spec §8) — 4th bento region, leftmost. Folder/daily tree for the
/// currently open project, plus New/Open/Recent when none is open. Owns its own local UI state
/// (error text, new-folder alert, which folders are expanded); everything project-shaped lives
/// on `ProjectController` itself so this stays a thin presentation layer over it.
private struct ProjectBrowserPanel: View {
    @ObservedObject var project: ProjectController
    let onSelectDaily: (Daily, ProjectFolder) -> Void
    let onDailyDeleted: (UUID) -> Void

    @State private var errorText: String?
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var pendingDeleteFolder: ProjectFolder?
    @State private var pendingDeleteDaily: (daily: Daily, folder: ProjectFolder)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTitle("Project")
            if project.metadata == nil {
                noProjectContent
            } else {
                openProjectContent
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
        .onChange(of: project.rootURL) { _, _ in
            expandedFolderIDs = Set(project.metadata?.folders.map(\.id) ?? [])
        }
    }

    private var noProjectContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No project open — drag-and-drop still works above for a quick one-off transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("New Project…") { newProject() }
                .font(.caption.bold())
                .buttonStyle(.accent)
            Button("Open Project…") { openProject() }
                .font(.caption.bold())
                .buttonStyle(.accent)
            let recents = ProjectSettings.recentPaths
            if !recents.isEmpty {
                Divider()
                Text("Recent").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recents, id: \.self) { path in
                            Button(URL(fileURLWithPath: path).lastPathComponent) { openRecent(path) }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.red)
            }
            Spacer()
        }
    }

    private var openProjectContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.metadata?.name ?? "").font(.caption.bold()).foregroundStyle(Theme.accent)
                Spacer()
                Button { project.close() } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Close Project")
            }
            Button("+ New Folder") { showingNewFolderAlert = true }
                .font(.caption.bold())
                .buttonStyle(.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(project.metadata?.folders ?? []) { folder in
                        folderRow(folder)
                    }
                }
            }
            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.red)
            }
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .confirmationDialog(
            "Delete “\(pendingDeleteFolder?.name ?? "")” and everything in it?",
            isPresented: Binding(get: { pendingDeleteFolder != nil }, set: { if !$0 { pendingDeleteFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) { deleteFolder() }
            Button("Cancel", role: .cancel) { pendingDeleteFolder = nil }
        }
        .confirmationDialog(
            "Delete “\(pendingDeleteDaily?.daily.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDeleteDaily != nil }, set: { if !$0 { pendingDeleteDaily = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Daily", role: .destructive) { deleteDaily() }
            Button("Cancel", role: .cancel) { pendingDeleteDaily = nil }
        }
    }

    private func folderRow(_ folder: ProjectFolder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    if expandedFolderIDs.contains(folder.id) {
                        expandedFolderIDs.remove(folder.id)
                    } else {
                        expandedFolderIDs.insert(folder.id)
                    }
                } label: {
                    Image(systemName: expandedFolderIDs.contains(folder.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                Button(folder.name) { project.selectedFolderID = folder.id }
                    .buttonStyle(.plain)
                    .font(.caption.bold())
                    .foregroundStyle(project.selectedFolderID == folder.id ? Theme.accent : .primary)
                Spacer()
                Button { pendingDeleteFolder = folder } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete Folder")
            }
            if expandedFolderIDs.contains(folder.id) {
                ForEach(folder.dailies) { daily in
                    HStack(spacing: 4) {
                        Button {
                            project.selectedFolderID = folder.id
                            project.selectedDailyID = daily.id
                            onSelectDaily(daily, folder)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform").font(.caption2)
                                Text(daily.displayName).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(project.selectedDailyID == daily.id ? Theme.accent : .secondary)
                        Spacer()
                        Button { pendingDeleteDaily = (daily, folder) } label: {
                            Image(systemName: "trash").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete Daily")
                    }
                    .padding(.leading, 18)
                }
            }
        }
    }

    private func deleteFolder() {
        guard let folder = pendingDeleteFolder else { return }
        pendingDeleteFolder = nil
        do {
            for daily in folder.dailies { onDailyDeleted(daily.id) }
            try project.deleteFolder(folder.id)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteDaily() {
        guard let (daily, folder) = pendingDeleteDaily else { return }
        pendingDeleteDaily = nil
        do {
            try project.deleteDaily(daily.id, from: folder.id)
            onDailyDeleted(daily.id)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        do {
            try project.addFolder(name: name)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func newProject() {
        guard let url = ProjectController.presentNewProjectPanel() else { return }
        do {
            try project.createNew(at: url)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openProject() {
        guard let url = ProjectController.presentOpenProjectPanel() else { return }
        do {
            try project.open(at: url)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openRecent(_ path: String) {
        do {
            try project.open(at: URL(fileURLWithPath: path))
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
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
    let onBrowse: () -> Void
    let onRetranscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTitle(playback.isVideo ? "Preview" : "Waveform")
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
            // Click-to-browse (spec fix: not everyone wants drag-and-drop) — feeds the exact same
            // ingest path as a drop, just sourced via NSOpenPanel instead of NSItemProvider.
            Button("Browse…") { onBrowse() }
                .font(.caption.bold())
                .buttonStyle(.accent)
                .disabled(isBusy)
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
            if playback.isVideo {
                PlayerView(player: playback.avPlayer)
                    .frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                WaveformBarsView(playback: playback)
                    .frame(maxHeight: .infinity)
            }
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
                // Manual re-transcribe (spec fix: a bad first pass or a provider/model change
                // shouldn't require re-dropping the file) — reruns against the already-loaded URL.
                Button("Re-transcribe") { onRetranscribe() }
                    .font(.caption.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(isBusy)
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

/// Draggable divider between the Waveform/Preview panel and the Transcript panel (spec fix: the
/// video preview needed to be both bigger by default and user-resizable). A plain `DragGesture`
/// against a stored baseline (captured once per drag, not accumulated per-frame) rather than
/// SwiftUI's `.resizable()`/split-view APIs, which target windows/columns, not two stacked
/// panels sharing a `VStack` — this is a handful of lines either way, so no real cost to keeping
/// styling consistent with the rest of the app (accent-tinted capsule, cyan design language)
/// instead of adopting a stock unstyled splitter.
private struct PanelResizeHandle: View {
    @Binding var height: Double
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var dragStartHeight: Double?
    @State private var isHovering = false

    var body: some View {
        Capsule()
            .fill(Theme.accent.opacity(isHovering ? 0.6 : 0.3))
            .frame(width: 48, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = height }
                        let proposed = (dragStartHeight ?? height) + value.translation.height
                        height = Double(min(max(CGFloat(proposed), minHeight), maxHeight))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// AppKit's `AVPlayerView` wrapped for SwiftUI (spec §8, video playback), used in place of
/// SwiftUI's own `VideoPlayer`. `VideoPlayer` crashed on first render with a SIGABRT deep in
/// Swift's generic metadata instantiation for `_AVKit_SwiftUI` (spec §5, Known Issues) — two
/// separate crash reports, each with a *different* concurrent culprit thread, ruling out a race
/// in Audium's own code and pointing at the bridging layer itself on this OS build. `AVPlayerView`
/// is the older, stable AppKit control and never goes through `_AVKit_SwiftUI` at all.
/// `.controlsStyle = .inline` keeps AVKit's native floating play/pause/scrub-bar overlay (spec
/// §8: scrubbing must carry over to video) — cheaper and more standard than reimplementing a
/// custom drag-to-scrub gesture over raw video like `WaveformBarsView` does for audio bars.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
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


private struct TranscriptPanel: View {
    @Binding var segments: [TranscriptSegment]
    let isTranscribing: Bool
    let status: String
    let statusFraction: Double?
    let startedAt: Date?
    let sourceURL: URL?
    @ObservedObject var playback: AudioPlaybackController
    let highlights: [Highlight]
    let paperEdits: [PaperEdit]
    /// nil for a standalone (no-project) file — highlights need a Daily to attach to, same
    /// constraint as Re-transcribe's `dailyID`. Gates both the header's highlight count/list and
    /// each row's highlight-toggle star.
    let dailyID: UUID?
    let onToggleHighlight: (TranscriptSegment) -> Void
    let onRemoveHighlight: (UUID) -> Void
    let onAddToPaperEdit: (Highlight, UUID?) -> Void

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
                if dailyID != nil {
                    HighlightsMenu(
                        highlights: highlights,
                        segments: segments,
                        paperEdits: paperEdits,
                        onSeek: { playback.seek(to: $0) },
                        onRemove: onRemoveHighlight,
                        onAddToPaperEdit: onAddToPaperEdit
                    )
                }
                if !segments.isEmpty {
                    ExportMenu(segments: segments, sourceURL: sourceURL)
                }
            }
            if isTranscribing {
                TranscriptionProgressView(phase: status, fraction: statusFraction, startedAt: startedAt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                Spacer()
                Text(status.isEmpty ? "No transcript yet" : status)
                    .foregroundStyle(status.hasPrefix("Transcription failed") ? .red : .secondary)
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
                                    isHighlighted: highlights.contains { $0.start == segment.start },
                                    canHighlight: dailyID != nil,
                                    onSeek: { playback.seek(to: segment.start) },
                                    onToggleHighlight: { onToggleHighlight(segment) }
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
    /// True if a Highlight exists anchored to this segment (spec §8). Deliberately a *different*
    /// visual treatment from `isCurrent` (a leading accent stripe, not another full-row tint) so
    /// the two states read distinctly even when both are true at once — a highlighted segment
    /// that also happens to be under the playhead shouldn't look like generic "extra-accented".
    let isHighlighted: Bool
    /// False for a standalone (no-project) file — there's no Daily to persist a highlight to, so
    /// the star is shown but disabled/dimmed rather than hidden (keeps row layout stable when
    /// opening/closing a project while a file is loaded).
    let canHighlight: Bool
    let onSeek: () -> Void
    let onToggleHighlight: () -> Void

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
                Spacer()
                Button { onToggleHighlight() } label: {
                    Image(systemName: isHighlighted ? "star.fill" : "star")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHighlighted ? Theme.accent : Theme.accent.opacity(0.4))
                .disabled(!canHighlight)
                .help(canHighlight ? (isHighlighted ? "Remove highlight" : "Mark as highlight") : "Open within a project to mark highlights")
            }
            textField
        }
        .padding(6)
        .padding(.leading, isHighlighted ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.14) : .clear)
        )
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
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

/// Highlights entry point for the current Daily (spec §8: "basic visibility" for highlights —
/// not the full Paper Edit assembly view, that's the next phase). A `.popover` off a small
/// count badge, same "click to reveal a lightweight list" shape as `ExportMenu` right next to it.
private struct HighlightsMenu: View {
    let highlights: [Highlight]
    let segments: [TranscriptSegment]
    let paperEdits: [PaperEdit]
    let onSeek: (TimeInterval) -> Void
    let onRemove: (UUID) -> Void
    /// nil `PaperEdit.ID` means "create a new Paper Edit and add it there" (spec §8 UI: "Add to
    /// Paper Edit" from the highlight list).
    let onAddToPaperEdit: (Highlight, UUID?) -> Void

    @State private var isShowingList = false

    var body: some View {
        Button {
            isShowingList = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                Text("\(highlights.count)")
            }
            .font(.caption.bold())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            HighlightsListView(
                highlights: highlights.sorted { $0.start < $1.start },
                segments: segments,
                paperEdits: paperEdits,
                onSeek: { onSeek($0); isShowingList = false },
                onRemove: onRemove,
                onAddToPaperEdit: onAddToPaperEdit
            )
        }
    }
}

private struct HighlightsListView: View {
    let highlights: [Highlight]
    let segments: [TranscriptSegment]
    let paperEdits: [PaperEdit]
    let onSeek: (TimeInterval) -> Void
    let onRemove: (UUID) -> Void
    let onAddToPaperEdit: (Highlight, UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlights").font(.headline)
            if highlights.isEmpty {
                Text("No highlights yet — click the star on a transcript segment to mark one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(highlights) { highlight in
                            HStack(alignment: .top, spacing: 8) {
                                Button(formatTime(highlight.start)) { onSeek(highlight.start) }
                                    .buttonStyle(.plain)
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.accent)
                                Text(segmentText(for: highlight))
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer()
                                Menu {
                                    ForEach(paperEdits) { paperEdit in
                                        Button(paperEdit.name) { onAddToPaperEdit(highlight, paperEdit.id) }
                                    }
                                    if !paperEdits.isEmpty { Divider() }
                                    Button("New Paper Edit…") { onAddToPaperEdit(highlight, nil) }
                                } label: {
                                    Image(systemName: "film.stack")
                                        .font(.caption)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .foregroundStyle(Theme.accent.opacity(0.7))
                                .help("Add to Paper Edit")
                                Button {
                                    onRemove(highlight.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func segmentText(for highlight: Highlight) -> String {
        segments.first { $0.start == highlight.start }?.text ?? "(segment not found)"
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

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var providerKind = ChatSettings.defaultProvider
    @State private var selectedRole: Role? = ChatSettings.defaultRoleID.flatMap { id in
        RoleLibrary.all.first { $0.id == id }
    }

    private var transcriptText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Two rows, not one (spec fix: "AI Chat" header overflow) — cramming the title plus
            // the role picker and provider picker into a single HStack on this panel's fixed
            // 340pt width let two rigid-width Pickers squeeze the title's Text down to near-zero
            // width, which SwiftUI renders as a vertical single-character column. Splitting the
            // title onto its own row makes that layout impossible regardless of control count.
            PanelTitle("AI Chat")
            HStack(spacing: 8) {
                RolePickerButton(selection: $selectedRole)
                    .onChange(of: selectedRole) { _, newValue in ChatSettings.defaultRoleID = newValue?.id }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        if let role = selectedRole {
            apiMessages.append(Message(role: .system, content: role.systemPrompt))
        }
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
