import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import WhisperKit
import SpeakerKit

/// One open tab (spec §8, tab-based interface) — either a Daily (Preview + Transcript panels) or
/// the Story Editor (the former separate "Paper Edit" window, now embedded). Deliberately carries
/// only IDs, not the `Daily`/`ProjectFolder` values themselves — those are looked up fresh from
/// `project.metadata` whenever needed (`TabBarView.title(for:)`, `ContentView.selectTab`), same
/// "don't cache what can drift" reasoning as `ContentView.currentHighlights` elsewhere in this
/// file, so a Daily rename/delete elsewhere can't leave a tab showing stale data.
private enum ContentTab: Identifiable {
    case daily(dailyID: UUID, folderID: UUID)
    case storyEditor

    var id: String {
        switch self {
        case .daily(let dailyID, _): return dailyID.uuidString
        case .storyEditor: return "storyEditor"
        }
    }
}

/// Bento-grid regions per spec §4. Waveform/transcript wiring is real — both drag-and-drop and
/// YouTube URL input feed the same `runTranscription(on:)`, which respects
/// `TranscriptionSettings.defaultProvider` (WhisperKit/Gemini/OpenAI); real waveform rendering
/// and playback (spec §2) live in `AudioPlaybackController`/`WaveformPanel` below.
///
/// **Tab architecture (spec §8, tab-based interface, superseding the old single-loaded-Daily
/// model + separate Paper Edit window):** `openTabs`/`activeTabID` are pure UI bookkeeping — the
/// actual "what's loaded" state is still the exact same `segments`/`sourceAudioURL`/
/// `currentDailyID`/`status` `@State` this view already had, reused as-is rather than duplicated
/// per tab. Activating a Daily tab just calls the existing `loadDaily(_:in:)` again (same call
/// standalone sidebar clicks already made pre-tabs), which overwrites that shared state and calls
/// `playback.load(url:)` — so switching tabs is *literally* "select a different Daily" with a new
/// front-end, not a new loading mechanism. `AudioPlaybackController`/`ProjectController` stay
/// exactly where the Paper Edit phase promoted them (`AudiumApp`-level `@StateObject`s, injected
/// via `.environmentObject`) — playback was already shared before this change and stays shared
/// now, per the revised decision that ruled out per-tab independent playback.
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
    /// Tab-based interface (spec §8) — ordered list of open tabs; `activeTabID` is `ContentTab.id`
    /// (a plain `String`, not the enum itself, so it survives being looked up against a possibly-
    /// stale `openTabs` entry without needing `ContentTab` to be `Equatable`).
    @State private var openTabs: [ContentTab] = []
    @State private var activeTabID: String?
    /// Batch/folder ingest (spec §9) — sequential, not concurrent (avoids hammering cloud APIs or
    /// overloading local transcription), reusing the exact same `addDaily`/`runTranscription` pipeline
    /// per file as a single drag-and-drop. `batchTotal == 0` means no batch is running.
    @State private var batchTotal = 0
    @State private var batchIndex = 0
    @State private var batchCurrentName = ""
    @State private var batchFailures: [(name: String, error: String)] = []
    @State private var showingBatchSummary = false
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

    /// "File 3 of 12 — clip_004.mov", layered alongside the existing per-file `status`/
    /// `statusFraction` phase display rather than replacing it (spec §9: "extend the existing
    /// progress/phase-label system"). `nil` when no batch is running, so it adds nothing to the
    /// UI for the ordinary single-file case.
    private var batchProgressText: String? {
        guard batchTotal > 0 else { return nil }
        return "File \(batchIndex) of \(batchTotal) — \(batchCurrentName)"
    }

    private var activeTab: ContentTab? {
        openTabs.first { $0.id == activeTabID }
    }

    private var isStoryEditorActive: Bool {
        if case .storyEditor = activeTab { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 16) {
            ProjectBrowserPanel(
                project: project,
                onSelectDaily: activateDailyTab,
                onDailyDeleted: clearLoadedContentIfMatches,
                onAddBatch: { urls in Task { await ingestBatch(urls) } }
            )
            .frame(width: 240)
            VStack(spacing: 0) {
                // No tabs open (no project, or a project open but nothing clicked yet) shows no
                // tab bar at all — this is also the standalone/no-project drag-and-drop state,
                // unchanged from before tabs existed (spec §8 tab decision: standalone ingest
                // doesn't open a Project-browser Daily, so it doesn't get a tab either).
                if !openTabs.isEmpty {
                    TabBarView(tabs: openTabs, activeTabID: activeTabID, project: project, onSelect: selectTab, onClose: closeTab)
                        .padding(.bottom, 8)
                }
                if isStoryEditorActive {
                    StoryEditorTab(project: project, playback: playback, onPlayEntry: openDailyTabAndPlay)
                } else {
                    HStack(spacing: 16) {
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
                                    onRetranscribe: { Task { await retranscribeCurrent() } },
                                    batchProgress: batchProgressText
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
                                    onRemoveHighlight: removeHighlight,
                                    onAddToPaperEdit: addToPaperEdit,
                                    onAddHighlightFromSelection: addHighlightFromSelection,
                                    onRenameSpeaker: renameSpeaker,
                                    batchProgress: batchProgressText
                                )
                            }
                        }
                        AIChatPanel(segments: segments)
                            .frame(width: 340)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .toolbar {
            // Window toolbar cluster (spec §8/toolbar reorg) — Settings/About/Logs live here now
            // instead of inside AIChatPanel's header, which was fighting the role/provider
            // pickers for the panel's fixed 340pt width (see the "AI Chat" header overflow fix).
            ToolbarItemGroup(placement: .primaryAction) {
                // Repurposed, not removed (spec §8 tab decision item 4): the old separate "Paper
                // Edit" `Window` + its `openWindow(id: "paperEdit")` call and the app-menu
                // Cmd+Shift+P shortcut are gone entirely (see `AudiumApp.swift`) — this same
                // toolbar icon now opens/focuses the Story Editor tab instead, so there's still a
                // one-click way to reach it (Story Editor is opened on demand, not pinned — see
                // this button and `activateStoryEditorTab()`'s doc comment).
                Button { activateStoryEditorTab() } label: {
                    Image(systemName: "film.stack")
                }
                .help("Story Editor")
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
        // Batch/folder ingest failure summary (spec §9) — surfaced once at the end of a batch
        // rather than one alert per failed file, so a bad file in the middle of 12 doesn't
        // interrupt the rest of the queue with a modal that has to be dismissed to continue.
        .alert("Batch Import: \(batchFailures.count) file\(batchFailures.count == 1 ? "" : "s") failed", isPresented: $showingBatchSummary) {
            Button("OK", role: .cancel) { batchFailures = [] }
        } message: {
            Text(batchFailures.map { "\($0.name): \($0.error)" }.joined(separator: "\n"))
        }
        // Switching projects invalidates every open Daily tab's (folderID, dailyID) lookup, same
        // as `ProjectBrowserPanel`'s own `expandedFolderIDs` reset on this exact `onChange` — the
        // Story Editor tab is closed too (its Paper Edits belong to the project that just closed),
        // and whatever was loaded into the shared player is torn down cleanly rather than left
        // pointing at a Daily from the just-closed project.
        .onChange(of: project.rootURL) { _, _ in
            openTabs = []
            activeTabID = nil
            currentDailyID = nil
            segments = []
            sourceAudioURL = nil
            playback.reset()
            status = "Drop an audio or video file to begin"
            statusFraction = nil
        }
    }

    /// Adds `tab` if not already open, then makes it the active tab — the shared "open or focus"
    /// primitive every tab-opening call site (sidebar click, toolbar button, Paper Edit entry
    /// play) goes through.
    private func openTabIfNeeded(_ tab: ContentTab) {
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabID = tab.id
    }

    /// Opens/focuses a Daily's tab (spec §8: "Opening a Daily from the Project browser opens/
    /// focuses a tab" — also the target of a Paper Edit entry's Play button, and of a fresh
    /// standalone-drop-into-an-open-project ingest). Skips the reload if this tab is already the
    /// active one — clicking the tab you're already on (or re-clicking the same sidebar Daily)
    /// shouldn't restart playback; only an actual tab *switch* re-runs `loadDaily`, which is what
    /// pulls that Daily's content into the one shared `AudioPlaybackController`.
    private func activateDailyTab(_ daily: Daily, in folder: ProjectFolder) {
        let tab = ContentTab.daily(dailyID: daily.id, folderID: folder.id)
        let alreadyActive = activeTabID == tab.id
        openTabIfNeeded(tab)
        guard !alreadyActive else { return }
        loadDaily(daily, in: folder)
    }

    /// Story Editor is opened **on demand**, not pinned/always-open (spec §8 point 3's explicit
    /// decision point) — same trigger as the old separate window (one toolbar button), just
    /// producing a tab instead of a window. Rejected pinned-always-present: it would need special
    /// "this one tab can't be closed" logic in `closeTab`/`TabBarView` for a feature most sessions
    /// (plain transcription work, no Paper Edit yet) never touch — on-demand is less code and a
    /// closer match to how the feature was already reached pre-tabs.
    private func activateStoryEditorTab() {
        openTabIfNeeded(.storyEditor)
    }

    /// Activates an already-known `ContentTab` value — used by `TabBarView`'s click handler and by
    /// `closeTab`'s fallback-to-next-tab. Re-resolves a `.daily` tab's `Daily`/`ProjectFolder` from
    /// `project.metadata` fresh (same reasoning as `ContentTab`'s own doc comment); if either has
    /// vanished (deleted through some path that didn't already prune this tab), the tab is dropped
    /// instead of activating onto missing data.
    private func selectTab(_ tab: ContentTab) {
        switch tab {
        case .daily(let dailyID, let folderID):
            guard let metadata = project.metadata,
                  let folder = metadata.folders.first(where: { $0.id == folderID }),
                  let daily = folder.dailies.first(where: { $0.id == dailyID }) else {
                openTabs.removeAll { $0.id == tab.id }
                if activeTabID == tab.id { activeTabID = openTabs.last?.id }
                return
            }
            activateDailyTab(daily, in: folder)
        case .storyEditor:
            activateStoryEditorTab()
        }
    }

    /// Closes a tab (spec §8: "Include a way to close a tab"). The playback-stop condition is
    /// keyed on `currentDailyID` (whatever the shared player actually has loaded right now), not
    /// on whether the closed tab happened to be the frontmost/active one — a Daily can be loaded
    /// in the shared player while some *other* tab (e.g. Story Editor) is the one currently in
    /// front, and closing that Daily's now-background tab should still stop its audio (spec test
    /// stage 4: "close a tab while its content is actively playing, confirm playback stops
    /// cleanly").
    private func closeTab(_ tab: ContentTab) {
        let wasActive = activeTabID == tab.id
        openTabs.removeAll { $0.id == tab.id }

        if case .daily(let dailyID, _) = tab, dailyID == currentDailyID {
            playback.reset()
            currentDailyID = nil
            segments = []
            sourceAudioURL = nil
            status = "Drop an audio or video file to begin"
            statusFraction = nil
        }

        guard wasActive else { return }
        if let nextTab = openTabs.last {
            selectTab(nextTab)
        } else {
            activeTabID = nil
        }
    }

    /// Target of a Paper Edit entry's Play button (spec §8 point 2) — opens/focuses that entry's
    /// source Daily tab (so the Transcript panel actually shows the context of what's about to
    /// play, unlike the old separate-window version's deliberate "Transcript panel doesn't follow
    /// along" scope boundary, which no longer applies now that everything lives in one window with
    /// real tabs) and only seeks+plays if the media actually loaded — `activateDailyTab` →
    /// `loadDaily` already turns a missing/moved linked file into a clear `status` message instead
    /// of silently doing nothing, so there's no need for a second not-found alert here.
    private func openDailyTabAndPlay(_ daily: Daily, in folder: ProjectFolder, at time: TimeInterval) {
        activateDailyTab(daily, in: folder)
        guard playback.isLoaded else { return }
        playback.seek(to: time)
        playback.play()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // `loadInPlaceFileRepresentation`, not `loadFileRepresentation` (spec §8, "always link to
        // source media" — supersedes the old copy-based model this used to serve). Apple's docs
        // for `loadFileRepresentation` say it vends a *temporary* copy of the dropped file that's
        // no longer guaranteed to exist once the completion handler returns — fine when the next
        // step copied it again into the project folder anyway, but linking `Daily.linkedSourcePath`
        // straight to that ephemeral copy would point at a file that can vanish at any time instead
        // of the user's real source. `loadInPlaceFileRepresentation` (macOS 11+) hands back the
        // dropped file's actual on-disk location for a local Finder drag instead of copying it.
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.audiovisualContent.identifier) { url, _, _ in
            guard let url else { return }
            Task { await ingest(url) }
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
            // Opens a tab for the newly-added Daily (spec §8: ingesting into an open project is
            // functionally "open this Daily"), same as a sidebar click would — just via
            // `openTabIfNeeded` directly rather than `activateDailyTab`, since `runTranscription`
            // right below already does everything `loadDaily` would (`segments`/`sourceAudioURL`/
            // `playback.load`), no need to load twice.
            openTabIfNeeded(.daily(dailyID: daily.id, folderID: folderID))
            await runTranscription(on: mediaURL, dailyID: daily.id)
        } catch {
            status = "Couldn't add daily: \(error.localizedDescription)"
        }
    }

    private func loadDaily(_ daily: Daily, in folder: ProjectFolder) {
        currentDailyID = daily.id
        segments = daily.transcript.segments
        let url = project.mediaURL(for: daily, in: folder)
        statusFraction = nil
        isTranscribing = false
        transcriptionStartedAt = nil
        // Linked media (spec §8) can vanish out from under the project at any time — moved,
        // renamed, deleted, an external drive unmounted. Checked before `playback.load` so that
        // shows a clear message instead of `AVAudioPlayer`'s init silently failing (`try?`) and
        // leaving the panels looking like nothing happened.
        guard project.mediaExists(for: daily, in: folder) else {
            sourceAudioURL = nil
            playback.reset()
            status = "Linked file not found: \(url.path) — it may have been moved, renamed, or deleted."
            return
        }
        sourceAudioURL = url
        playback.load(url: url)
        status = daily.transcript.segments.isEmpty ? "No transcript yet" : "\(daily.transcript.segments.count) segments"
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

    /// Creates a Highlight from an arbitrary text-selection range (spec §8 Stage 2/3 — supersedes
    /// the old per-segment star-button toggle). `range.start`/`range.end` are already word-precise
    /// where the transcript has word-level timing, or clamped to whole segment(s) where it
    /// doesn't (`TranscriptFlowView`'s selection-resolution logic) — this just persists whatever
    /// range it's handed, same as the old toggle persisted a whole segment's `start`/`end`.
    @discardableResult
    private func addHighlightFromSelection(_ range: TranscriptSelectionRange) -> Highlight? {
        guard let currentDailyID else { return nil }
        let highlight = Highlight(id: UUID(), start: range.start, end: range.end, note: nil, createdAt: Date())
        project.addHighlight(highlight, to: currentDailyID)
        return highlight
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

    /// Renames every segment sharing the `from` speaker label, not just the one being edited —
    /// diarization (SpeakerKit) assigns one label per detected voice across the whole transcript,
    /// so a correction should follow the same grouping (spec §8, "global speaker rename"). Updates
    /// the working `segments` copy directly (covers a standalone/no-project file too) and, when a
    /// project Daily is loaded, persists via `ProjectController.renameSpeaker` the same way
    /// highlight/paper-edit mutations already do.
    private func renameSpeaker(from: String, to: String?) {
        for index in segments.indices where segments[index].speaker == from {
            segments[index].speaker = to
        }
        if let currentDailyID {
            project.renameSpeaker(from: from, to: to, in: currentDailyID)
        }
    }

    /// Clears the loaded-file state after the currently-displayed Daily is deleted out from under
    /// it, so the panels don't keep showing a transcript/waveform for media that no longer exists.
    /// Only reacts when the deleted Daily is the one actually loaded — deleting some other Daily
    /// (or a folder that doesn't contain the loaded one) shouldn't disturb what's on screen.
    private func clearLoadedContentIfMatches(deletedDailyID: UUID) {
        // Drops the deleted Daily's tab too, if it had one open (spec §8) — a tab pointing at a
        // just-deleted Daily would otherwise sit in the tab bar until clicked, at which point
        // `selectTab`'s own not-found fallback would remove it anyway; doing it eagerly here
        // avoids that dead intermediate state.
        let wasActiveTab = activeTabID == deletedDailyID.uuidString
        openTabs.removeAll { if case .daily(let id, _) = $0 { return id == deletedDailyID }; return false }
        if wasActiveTab {
            activeTabID = openTabs.last?.id
            if let nextTab = openTabs.last { selectTab(nextTab) }
        }
        guard currentDailyID == deletedDailyID else { return }
        currentDailyID = nil
        segments = []
        sourceAudioURL = nil
        playback.reset()
        status = "Drop an audio or video file to begin"
        statusFraction = nil
    }

    /// Returns the failure message if transcription failed, `nil` on success — lets batch ingest
    /// (below) record a per-file failure and continue the queue instead of the failure only ever
    /// surfacing as a `status` string single-file callers don't need to inspect.
    @MainActor
    @discardableResult
    private func runTranscription(on url: URL, dailyID: UUID? = nil) async -> String? {
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

        var failureMessage: String?
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
            failureMessage = error.localizedDescription
            status = "Transcription failed: \(error.localizedDescription)"
        }
        statusFraction = nil
        isTranscribing = false
        transcriptionStartedAt = nil
        return failureMessage
    }

    /// Batch/folder ingest (spec §9) — sequential (not concurrent, so this doesn't hammer a cloud
    /// API or run several local transcriptions at once), reusing `project.addDaily` +
    /// `runTranscription` per file exactly as a single drag-and-drop already does. One bad file
    /// (unreadable, unsupported format, a provider/API error) is caught and recorded rather than
    /// aborting the rest of the queue — `addDaily`'s copy can throw (bad/corrupt file) and
    /// `runTranscription`'s returned failure message covers a provider-side failure on an otherwise
    /// valid file, so both failure points during a batch item are covered.
    @MainActor
    private func ingestBatch(_ urls: [URL]) async {
        guard project.metadata != nil else {
            status = "Open a project first — batch import adds each file as a Daily"
            return
        }
        guard let folderID = project.selectedFolderID else {
            status = "Select or create a project folder first"
            return
        }
        batchFailures = []
        batchTotal = urls.count
        for (index, url) in urls.enumerated() {
            batchIndex = index + 1
            batchCurrentName = url.lastPathComponent
            do {
                let (daily, mediaURL) = try await project.addDaily(from: url, to: folderID)
                currentDailyID = daily.id
                if let failure = await runTranscription(on: mediaURL, dailyID: daily.id) {
                    batchFailures.append((url.lastPathComponent, failure))
                }
            } catch {
                batchFailures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        batchTotal = 0
        batchIndex = 0
        batchCurrentName = ""
        if !batchFailures.isEmpty { showingBatchSummary = true }
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
    /// Batch/folder ingest (spec §9) — a flat, already-expanded list of media file URLs (any
    /// selected folders already walked and filtered down to media files by `addBatch()` below);
    /// the caller (`ContentView`) owns the actual sequential add+transcribe queue.
    let onAddBatch: ([URL]) -> Void

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
            // Batch/folder ingest (spec §9) — one panel handles both "pick a whole folder of
            // dailies" and "multi-select several files at once", added into the currently
            // selected folder same as a single drag-and-drop would be.
            Button("Add Files/Folder…") { addBatch() }
                .font(.caption.bold())
                .buttonStyle(.accent)
                .disabled(project.selectedFolderID == nil)
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

    /// One `NSOpenPanel` handles both "select a whole folder of dailies" and "multi-select several
    /// files at once" (spec §9) — `canChooseDirectories`/`canChooseFiles`/`allowsMultipleSelection`
    /// all true together; Cocoa keeps directories selectable regardless of `allowedContentTypes`,
    /// which only filters which regular files are enabled, so folder-picking isn't blocked by the
    /// audio/video type filter. Selected directories are expanded to their contained media files
    /// before handing off — the caller only ever sees a flat file list.
    private func addBatch() {
        let panel = NSOpenPanel()
        panel.title = "Add Files or a Folder of Dailies"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audiovisualContent]
        guard panel.runModal() == .OK else { return }
        let urls = expandToMediaFiles(panel.urls)
        guard !urls.isEmpty else { return }
        onAddBatch(urls)
    }

    /// Walks any selected directories recursively (a dailies folder commonly has per-scene/per-day
    /// subfolders) and keeps only files whose UTType conforms to `.audiovisualContent` — the same
    /// type filter the single-file `Browse…`/drop path already uses. Plain files in the selection
    /// pass through unchanged. Sorted by filename for a deterministic, reproducible batch order.
    private func expandToMediaFiles(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles]) else { continue }
                for case let fileURL as URL in enumerator {
                    guard let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
                          type.conforms(to: .audiovisualContent) else { continue }
                    result.append(fileURL)
                }
            } else {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
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

/// Tab bar (spec §8, tab-based interface) — one row of `TabChip`s in the app's own glass/cyan
/// language (item 3's explicit requirement: "not stock unstyled TabView chrome" — SwiftUI's stock
/// `TabView` also doesn't support a dynamic, closeable, mixed-content set of tabs like this one
/// anyway, so a plain `HStack` of custom chips is both the styled *and* the mechanically simplest
/// option here). Titles are looked up live from `project.metadata` each render rather than cached
/// on `ContentTab` (see that type's doc comment) — cheap at the small number of tabs a user
/// realistically has open at once.
private struct TabBarView: View {
    let tabs: [ContentTab]
    let activeTabID: String?
    @ObservedObject var project: ProjectController
    let onSelect: (ContentTab) -> Void
    let onClose: (ContentTab) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tabs) { tab in
                TabChip(
                    title: title(for: tab),
                    icon: tab.id == "storyEditor" ? "film.stack" : "waveform",
                    isActive: tab.id == activeTabID,
                    onSelect: { onSelect(tab) },
                    onClose: { onClose(tab) }
                )
            }
            Spacer()
        }
    }

    private func title(for tab: ContentTab) -> String {
        switch tab {
        case .storyEditor:
            return "Story Editor"
        case .daily(let dailyID, let folderID):
            guard let folder = project.metadata?.folders.first(where: { $0.id == folderID }),
                  let daily = folder.dailies.first(where: { $0.id == dailyID }) else {
                return "Daily"
            }
            return daily.displayName
        }
    }
}

private struct TabChip: View {
    let title: String
    let icon: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption2)
                    Text(title).font(.caption.bold()).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .help("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 200)
        .foregroundStyle(isActive ? Theme.accent : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Theme.accent.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
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
    /// "File 3 of 12 — clip.mov" while a batch/folder ingest is running (spec §9); `nil` otherwise.
    let batchProgress: String?

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
            if let batchProgress {
                Text(batchProgress)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.accent)
            }
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
                Spacer()
                if isBusy {
                    if let batchProgress {
                        Text(batchProgress)
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accent)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Manual re-transcribe (spec fix: a bad first pass or a provider/model change
                // shouldn't require re-dropping the file) — reruns against the already-loaded URL.
                // Right-aligned (spec fix, real UI bug not just a testing artifact): the Transcript
                // panel directly below floats its "Add Highlight" bar at whatever x-coordinate a
                // selection starts at, which is almost always left-margin-ish since that's where
                // reading (and so dragging) naturally starts — a left-clustered Re-transcribe here
                // shared that same x-zone across the panel boundary, close enough on screen to
                // cause real mis-clicks, not just an automation artifact. Pinning it to the row's
                // trailing edge puts it in a zone no left-starting selection's floating bar reaches.
                Button("Re-transcribe") { onRetranscribe() }
                    .font(.caption.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(isBusy)
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


/// One segment currently being edited via the double-click popover (spec §8 Stage 2) — replaces
/// the old inline `TextField` swap, since editing a single segment's text/speaker no longer has a
/// per-segment `Binding<TranscriptSegment>` once the transcript renders as one shared
/// `TranscriptFlowView` (see that file's doc comment for why). `index` into the current `segments`
/// array — stable for the duration of one popover session (nothing else mutates segment order
/// while it's open).
private struct EditingSegment: Identifiable {
    let index: Int
    var text: String
    var speaker: String
    var id: Int { index }
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
    /// constraint as Re-transcribe's `dailyID`. Gates the header's highlight count/list and
    /// whether a text selection can produce a Highlight at all.
    let dailyID: UUID?
    let onRemoveHighlight: (UUID) -> Void
    let onAddToPaperEdit: (Highlight, UUID?) -> Void
    /// Creates a Highlight from a resolved selection range and returns it (spec §8 Stage 3) — used
    /// by both the floating "Add Highlight" button and the right-click fallback menu.
    let onAddHighlightFromSelection: (TranscriptSelectionRange) -> Highlight?
    /// Global speaker rename (spec §8) — `to == nil` clears the label. Applies to every segment
    /// currently sharing `from`, not just the one edited.
    let onRenameSpeaker: (_ from: String, _ to: String?) -> Void
    /// "File 3 of 12 — clip.mov" while a batch/folder ingest is running (spec §9); `nil` otherwise.
    let batchProgress: String?

    @State private var selectionRange: TranscriptSelectionRange?
    @State private var selectionRect: CGRect?
    @State private var clearSelectionRequest = false
    @State private var editingSegment: EditingSegment?

    private func clearSelection() {
        selectionRange = nil
        selectionRect = nil
        clearSelectionRequest = true
    }

    private func addHighlightAndClear() {
        guard let selectionRange else { return }
        _ = onAddHighlightFromSelection(selectionRange)
        clearSelection()
    }

    private func addToPaperEditAndClear(_ paperEditID: UUID?) {
        guard let selectionRange, let highlight = onAddHighlightFromSelection(selectionRange) else { return }
        onAddToPaperEdit(highlight, paperEditID)
        clearSelection()
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
                TranscriptionProgressView(phase: status, fraction: statusFraction, startedAt: startedAt, batchProgress: batchProgress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                Spacer()
                Text(status.isEmpty ? "No transcript yet" : status)
                    .foregroundStyle(status.hasPrefix("Transcription failed") ? .red : .secondary)
                Spacer()
            } else {
                ZStack(alignment: .topLeading) {
                    TranscriptFlowView(
                        segments: segments,
                        highlights: highlights,
                        currentTime: playback.isLoaded ? playback.currentTime : -1,
                        onSeek: { playback.seek(to: $0) },
                        onSelectionChange: { range, rect in
                            selectionRange = range
                            selectionRect = rect
                        },
                        onDoubleClickSegment: { index in
                            guard segments.indices.contains(index) else { return }
                            editingSegment = EditingSegment(index: index, text: segments[index].text, speaker: segments[index].speaker ?? "")
                        },
                        onRightClickAddHighlight: addHighlightAndClear,
                        onRightClickAddToPaperEdit: addToPaperEditAndClear,
                        paperEdits: paperEdits,
                        canHighlight: dailyID != nil,
                        clearSelectionRequest: $clearSelectionRequest
                    )
                    if dailyID != nil, let selectionRange, let selectionRect {
                        SelectionActionBar(paperEdits: paperEdits, onAddHighlight: addHighlightAndClear, onAddToPaperEdit: addToPaperEditAndClear)
                            .offset(x: selectionRect.minX, y: max(0, selectionRect.minY - 34))
                            .transition(.opacity)
                            .id(selectionRange)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: selectionRange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel()
        .popover(item: $editingSegment) { editing in
            EditSegmentPopover(editing: editing, onSave: { text, speaker in
                let index = editing.index
                guard segments.indices.contains(index) else { return }
                let previousSpeaker = segments[index].speaker
                if segments[index].text != text {
                    // A hand edit invalidates any existing word-level timing — `words` was
                    // computed against the *old* text, and re-matching its word strings against
                    // the *new* text via substring search (`TranscriptFlowView.rebuild`) could
                    // silently reattach a stale timestamp to an unrelated word that happens to
                    // share the same text (e.g. common short words like "the"/"you") rather than
                    // safely falling back to whole-segment (caught via adversarial review, not
                    // live) — clearing it forces that safe fallback instead of risking silently
                    // wrong sub-segment timing after an edit.
                    segments[index].words = nil
                }
                segments[index].text = text
                let newSpeaker = speaker.isEmpty ? nil : speaker
                segments[index].speaker = newSpeaker
                if let previousSpeaker, !previousSpeaker.isEmpty, previousSpeaker != newSpeaker {
                    onRenameSpeaker(previousSpeaker, newSpeaker)
                }
                editingSegment = nil
            }, onCancel: { editingSegment = nil })
        }
    }
}

/// Floating "Add Highlight" / "Add to Paper Edit" pill (spec §8 Stage 3) — the primary interaction
/// for turning a text selection into a Highlight, positioned just above the selection by
/// `TranscriptPanel`. Disappears when the selection is cleared or an action succeeds (both drive
/// `TranscriptPanel.selectionRange` back to nil), whichever happens first. "Add to Paper Edit" is
/// a `Menu` styled as one pill button (not a separate right-click flow) — a real single action
/// when there's exactly one Paper Edit to disambiguate isn't otherwise possible when several
/// exist, same disambiguation `HighlightsListView`'s existing per-highlight menu already needed.
private struct SelectionActionBar: View {
    let paperEdits: [PaperEdit]
    let onAddHighlight: () -> Void
    let onAddToPaperEdit: (UUID?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Add Highlight", action: onAddHighlight)
                .buttonStyle(.accent)
                .font(.caption.bold())
            Menu {
                ForEach(paperEdits) { paperEdit in
                    Button(paperEdit.name) { onAddToPaperEdit(paperEdit.id) }
                }
                if !paperEdits.isEmpty { Divider() }
                Button("New Paper Edit…") { onAddToPaperEdit(nil) }
            } label: {
                Label("Add to Paper Edit", systemImage: "film.stack")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption.bold())
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent, lineWidth: 1))
        }
        .padding(6)
        .glassPanel(cornerRadius: 12)
        .fixedSize()
        .shadow(radius: 6)
    }
}

/// Anchored via `.popover(item:)` to the whole Transcript panel rather than the exact click point
/// (spec §8 Stage 2's documented trade-off, `TranscriptFlowView`'s doc comment) — there's no
/// per-segment anchor view left once the transcript is one shared `NSTextView`.
private struct EditSegmentPopover: View {
    let editing: EditingSegment
    let onSave: (_ text: String, _ speaker: String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var speaker: String

    init(editing: EditingSegment, onSave: @escaping (_ text: String, _ speaker: String) -> Void, onCancel: @escaping () -> Void) {
        self.editing = editing
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: editing.text)
        _speaker = State(initialValue: editing.speaker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Segment").font(.headline)
            TextField("Speaker", text: $speaker)
                .textFieldStyle(.roundedBorder)
            TextField("Text", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...8)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Done") { onSave(text, speaker) }
                    .buttonStyle(.accent)
            }
        }
        .padding()
        .frame(width: 320)
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
    /// "File 3 of 12 — clip.mov" while a batch/folder ingest is running (spec §9); `nil`
    /// otherwise — extends this existing phase-label view rather than a second progress display.
    var batchProgress: String? = nil

    /// Past this many seconds with no determinate progress, hint that something may be stuck
    /// rather than leaving the user to guess (spec §2).
    private static let stuckHintThreshold = 30

    var body: some View {
        VStack(spacing: 10) {
            if let batchProgress {
                Text(batchProgress)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.accent)
            }
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

    /// Spec §8 Stage 2 — a Highlight's range no longer necessarily matches one whole segment's
    /// `start`/`end` exactly (arbitrary text selection), so this resolves via
    /// `Transcript.text(from:to:)` (word-precise where available, whole-segment fallback
    /// otherwise) instead of the old exact-`start`-match lookup.
    private func segmentText(for highlight: Highlight) -> String {
        let text = Transcript(segments: segments).text(from: highlight.start, to: highlight.end)
        return text.isEmpty ? "(segment not found)" : text
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
