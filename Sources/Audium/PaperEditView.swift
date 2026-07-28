import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The assembled "selects" reel (spec §8) — Story Editor tab, formerly a separate `Window`
/// (spec §8, "tab-based interface" pass; see `AudiumApp.swift` for the removed `Window("Paper
/// Edit", ...)` scene and `ContentView.swift` for the tab architecture this now lives inside).
/// Shares the *same* `ProjectController`/`AudioPlaybackController` instances (`ContentView`'s
/// `@EnvironmentObject`s, passed down explicitly here since this is now a plain child view, not a
/// separate Scene) rather than owning separate copies — clicking an entry drives the one real
/// playback engine, reusing its existing load/seek/play wiring instead of duplicating it. Opened
/// **on demand** via the toolbar button, not pinned/always-present as a tab — see
/// `ContentView.activateStoryEditorTab()`'s doc comment for why.
///
/// Playing an entry now opens/focuses that entry's source Daily **tab** and seeks the shared
/// player through it (`onPlayEntry`, wired to `ContentView.openDailyTabAndPlay`) — supersedes the
/// old separate-window version's deliberate scope boundary ("does not also update the main
/// window's Transcript panel," since `segments`/`currentDailyID` were private, non-shared
/// `ContentView` state at the time). That boundary doesn't apply anymore: tabs and playback both
/// live in the one window now, so following a Paper Edit entry to its source Daily's actual
/// transcript context is the natural behavior, not a bigger change than this pass calls for.
///
/// Sequential "play the whole Paper Edit in order" (auto-advance) is still deliberately not built
/// — each entry can come from a different Daily/media file, so auto-advance means detecting an
/// entry's end via the time observer, then loading + seeking the *next* entry's file gaplessly; a
/// real state machine, not a one-line addition. Left as a reasonable v2.1 addition; clicking an
/// entry to play from its start covers this pass's actual requirement.
struct StoryEditorTab: View {
    @ObservedObject var project: ProjectController
    @ObservedObject var playback: AudioPlaybackController
    /// Routes a Play click to `ContentView.openDailyTabAndPlay` — opens/focuses the entry's
    /// source Daily tab, then seeks+plays through the shared player. A missing/moved linked
    /// source file surfaces as that Daily tab's own "Linked file not found" status message (same
    /// mechanism `ContentView.loadDaily` already uses elsewhere), so this view no longer needs
    /// its own separate not-found alert.
    let onPlayEntry: (Daily, ProjectFolder, TimeInterval) -> Void

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
                HStack(spacing: 16) {
                    sidebar
                    if let selectedPaperEdit {
                        PaperEditEntriesView(project: project, paperEdit: selectedPaperEdit, onPlay: onPlayEntry)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                            .glassPanel()
                    } else {
                        emptyState("No Paper Edit yet — create one, then add highlights to it from the Transcript panel's ★ list.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .glassPanel()
                    }
                }
            }
        }
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
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .glassPanel()
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
    let paperEdit: PaperEdit
    /// Opens/focuses the entry's source Daily tab and seeks+plays through the shared player
    /// (`ContentView.openDailyTabAndPlay`) — see `StoryEditorTab`'s doc comment for why this
    /// replaced directly driving `playback` from here.
    let onPlay: (Daily, ProjectFolder, TimeInterval) -> Void

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
                    Button("Export Docx…") { exportDocx() }
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

    /// Opens/focuses the entry's source Daily tab and seeks+plays it (spec §8 point 2) — routes
    /// through `ContentView.openDailyTabAndPlay` rather than driving `playback` directly (see
    /// `StoryEditorTab`'s doc comment); that function's own `activateDailyTab` → `loadDaily` chain
    /// already handles a missing/moved linked source file.
    private func play(_ item: ResolvedEntry) {
        onPlay(item.daily, item.folder, item.start)
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

    /// The actual "bring this into a meeting/share with the director" deliverable (spec §8/§9) —
    /// a readable assembled script: each entry's source Daily name + timestamp range as a bold/
    /// subtle-gray heading line, then the highlighted text itself, in Paper Edit sequence order.
    /// Reuses `DocxExporter` (the same OOXML/zip writer `Exporter.swift`'s transcript `.docx`
    /// export uses) rather than a second implementation.
    private func exportDocx() {
        var paragraphs: [DocxExporter.Paragraph] = [
            DocxExporter.Paragraph(
                [DocxExporter.Run(text: paperEdit.name, bold: true, sizeHalfPoints: 32)],
                spacingAfterTwips: 300
            )
        ]
        for item in resolved {
            paragraphs.append(DocxExporter.Paragraph([
                DocxExporter.Run(text: item.daily.displayName, bold: true),
                DocxExporter.Run(text: "  \(formatTime(item.start))–\(formatTime(item.end))", italic: true, color: "808080", sizeHalfPoints: 18)
            ], spacingAfterTwips: 60))
            paragraphs.append(DocxExporter.Paragraph(
                [DocxExporter.Run(text: item.text)],
                spacingAfterTwips: 300
            ))
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = paperEdit.name.isEmpty ? "Paper Edit" : paperEdit.name
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else {
            AudiumLog.export.info("Paper Edit docx export canceled by user")
            return
        }
        do {
            try DocxExporter.write(paragraphs: paragraphs, to: url)
            AudiumLog.export.info("Paper Edit docx export succeeded: \(url.path, privacy: .public)")
        } catch {
            AudiumLog.export.error("Paper Edit docx export failed: \(error.localizedDescription, privacy: .public)")
        }
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

