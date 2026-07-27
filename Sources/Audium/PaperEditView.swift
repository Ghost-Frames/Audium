import SwiftUI

/// The assembled "selects" reel (spec §8) — a separate window rather than a 5th bento panel,
/// since the existing 4-panel layout (project tree · waveform/preview · transcript · AI chat) is
/// already tight at the window's minWidth, and a Paper Edit is a distinct editorial task (review/
/// reorder the assembly) rather than something used moment-to-moment alongside transcription like
/// the other panels. Same multi-window pattern as Logs/About (`AudiumApp.swift`), but shares the
/// *same* `ProjectController`/`AudioPlaybackController` instances (injected via
/// `.environmentObject`, promoted out of `ContentView` for exactly this) rather than owning
/// separate copies — clicking an entry drives the one real playback engine, reusing its existing
/// load/seek/play wiring instead of duplicating it.
///
/// Playing an entry loads media directly into the shared `AudioPlaybackController` — it does
/// *not* also update the main window's Transcript panel (`segments`/`currentDailyID` are private
/// `@State` on `ContentView`, not shared state). A deliberate v1 scope boundary, not an oversight:
/// syncing that too would mean promoting the main window's whole loaded-file state to shared
/// state as well, a bigger change than this pass calls for. The Waveform/Preview panel *does*
/// update live, since it's driven by the same shared `playback` object either way.
///
/// Sequential "play the whole Paper Edit in order" (auto-advance) is deliberately not built this
/// pass — each entry can come from a different Daily/media file, so auto-advance means detecting
/// an entry's end via the time observer, then loading + seeking the *next* entry's file
/// gaplessly; a real state machine, not a one-line addition. Left as a reasonable v2.1 addition;
/// clicking an entry to play from its start covers this pass's actual requirement.
struct PaperEditView: View {
    @EnvironmentObject private var project: ProjectController
    @EnvironmentObject private var playback: AudioPlaybackController

    @State private var selectedPaperEditID: UUID?
    @State private var showingNewAlert = false
    @State private var newName = ""
    @State private var pendingDelete: PaperEdit?

    private var paperEdits: [PaperEdit] { project.metadata?.paperEdits ?? [] }

    private var selectedPaperEdit: PaperEdit? {
        paperEdits.first { $0.id == selectedPaperEditID } ?? paperEdits.first
    }

    var body: some View {
        Group {
            if project.metadata == nil {
                emptyState("No project open — open a project in the main window to build a Paper Edit.")
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    if let selectedPaperEdit {
                        PaperEditEntriesView(project: project, playback: playback, paperEdit: selectedPaperEdit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyState("No Paper Edit yet — create one, then add highlights to it from the Transcript panel's ★ list.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(Theme.background)
        .frame(minWidth: 520, minHeight: 400)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTitle("Paper Edits")
            Button("+ New") { showingNewAlert = true }
                .font(.caption.bold())
                .buttonStyle(.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paperEdits) { paperEdit in
                        HStack(spacing: 4) {
                            Button(paperEdit.name) { selectedPaperEditID = paperEdit.id }
                                .buttonStyle(.plain)
                                .font(.caption.bold())
                                .foregroundStyle((selectedPaperEdit?.id == paperEdit.id) ? Theme.accent : .primary)
                            Spacer()
                            Button { pendingDelete = paperEdit } label: {
                                Image(systemName: "trash").font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Spacer()
        }
        .padding()
        .frame(width: 160)
        .alert("New Paper Edit", isPresented: $showingNewAlert) {
            TextField("Name", text: $newName)
            Button("Create") {
                guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let created = project.addPaperEdit(name: newName)
                selectedPaperEditID = created.id
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Paper Edit", role: .destructive) {
                guard let pendingDelete else { return }
                if selectedPaperEditID == pendingDelete.id { selectedPaperEditID = nil }
                project.deletePaperEdit(pendingDelete.id)
                self.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

/// One resolved, displayable entry — looked up fresh from `project.metadata` each time rather
/// than cached, so it can't drift from the underlying Highlight/transcript (same reasoning as
/// `ContentView.currentHighlights`).
private struct ResolvedEntry: Identifiable {
    let id: UUID
    let entry: PaperEditEntry
    let folder: ProjectFolder
    let daily: Daily
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

private struct PaperEditEntriesView: View {
    @ObservedObject var project: ProjectController
    @ObservedObject var playback: AudioPlaybackController
    let paperEdit: PaperEdit

    /// Entries whose Highlight/Daily still resolve — `removeHighlight`/`deleteDaily`/
    /// `deleteFolder` all cascade-clean dangling entries already, so a `nil` here would only mean
    /// a race with a mutation that hasn't saved yet, not a normal steady state.
    private var resolved: [ResolvedEntry] {
        guard let metadata = project.metadata else { return [] }
        return paperEdit.entries.compactMap { entry -> ResolvedEntry? in
            for folder in metadata.folders {
                guard let daily = folder.dailies.first(where: { $0.id == entry.dailyID }) else { continue }
                guard let highlight = daily.highlights.first(where: { $0.id == entry.highlightID }) else { return nil }
                let text = daily.transcript.segments.first { $0.start == highlight.start }?.text ?? "(segment not found)"
                return ResolvedEntry(id: entry.id, entry: entry, folder: folder, daily: daily, start: highlight.start, end: highlight.end, text: text)
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PanelTitle(paperEdit.name)
                Spacer()
                Text("\(resolved.count) entr\(resolved.count == 1 ? "y" : "ies")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !resolved.isEmpty {
                    Button("Export EDL…") { exportEDL() }
                        .font(.caption.bold())
                        .buttonStyle(.accent)
                }
            }
            .padding([.top, .horizontal])

            if resolved.isEmpty {
                VStack {
                    Spacer()
                    Text("No entries yet — use the ★ button in a Transcript panel's Highlights list to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            } else {
                List {
                    ForEach(resolved) { item in
                        PaperEditEntryRow(item: item, onPlay: { play(item) }, onRemove: { remove(item) })
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { offsets, destination in
                        project.movePaperEditEntries(in: paperEdit.id, from: offsets, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Reuses the existing playback wiring (spec §8: "reuse existing playback wiring, don't
    /// duplicate it") — same `mediaURL(for:in:)`/`load`/`seek` any sidebar Daily click already
    /// goes through, just triggered from here instead, then starts playback since the point of
    /// clicking a Paper Edit entry is to *hear* it, not just load it paused.
    private func play(_ item: ResolvedEntry) {
        let url = project.mediaURL(for: item.daily, in: item.folder)
        playback.load(url: url)
        playback.seek(to: item.start)
        playback.play()
    }

    /// Removes just this entry — the underlying Highlight is untouched (spec: independent).
    private func remove(_ item: ResolvedEntry) {
        project.removePaperEditEntry(item.entry.id, from: paperEdit.id)
    }

    /// Builds `EDLExporter.Entry` values from the already-resolved entries (spec §8/§9, CMX3600
    /// EDL export) — `clipName` reconstructs the original-looking filename (display name + the
    /// real extension recovered from the on-disk UUID-named `mediaFilename`) for the "* FROM CLIP
    /// NAME:" comment, since that's the traceable name, not the on-disk one.
    private func exportEDL() {
        let entries = resolved.map { item in
            EDLExporter.Entry(
                dailyID: item.daily.id,
                dailyDisplayName: item.daily.displayName,
                clipName: item.daily.displayName + "." + URL(fileURLWithPath: item.daily.mediaFilename).pathExtension,
                frameRate: item.daily.frameRate,
                start: item.start,
                end: item.end,
                highlightText: item.text
            )
        }
        EDLExporter.presentSavePanel(paperEditName: paperEdit.name, entries: entries)
    }
}

private struct PaperEditEntryRow: View {
    let item: ResolvedEntry
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // A real Button scoped to just this icon, not a whole-row `.onTapGesture` (found via
            // real GUI testing: a row-wide tap gesture silently ate every drag, since List's
            // native reorder-drag and a tap recognizer both claim the same touch — the row must
            // stay free of any gesture for `.onMove` to work at all).
            Button { onPlay() } label: {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.body)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.daily.displayName)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                    Text("\(formatTime(item.start))–\(formatTime(item.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer()
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from Paper Edit (keeps the Highlight)")
        }
        .padding(8)
        .glassPanel(cornerRadius: 8)
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return String(format: "%02d:%02d", m, s)
}
