import AppKit
import AVFoundation
import Foundation

/// Spec §8 data model — a Project is a real folder on disk, not a database, same spirit as an
/// Avid bin structure. On-disk layout (documented in full in docs/spec.md §8):
///
///   MyProject/                  <- any folder the user names via NSSavePanel
///     .audiumproject.json       <- single metadata file: name + folders + dailies + transcripts,
///                                  all inline (spec's own wording: "a project-level metadata file
///                                  (JSON) tracking folder structure, daily<->transcript links").
///                                  One file, not one-per-daily — avoids partial-write/orphan-file
///                                  sync bugs between a project file and N transcript sidecars.
///     Scene 1 - INT Kitchen/    <- ProjectFolder, user-named, single level (no nesting in v1)
///       3F2504E0-....mov        <- copied media, filename = "<dailyID>.<original extension>"
///     Interview - Josh Pratt/
///       9F86D081-....mp4
///
/// Media is copied into the project folder when a Daily is added (not referenced in place). This
/// is a deliberate tradeoff, not an oversight: it keeps the project folder self-contained (matches
/// "the project folder is what you'd zip and hand off"), sidesteps dangling references if the
/// original file is later moved/renamed, and handles YouTube-downloaded dailies uniformly — that
/// source file lives in a temp directory and would vanish otherwise. Cost is doubled disk usage
/// for video-heavy dailies; a future "reference instead of copy" toggle is a reasonable follow-up
/// if that becomes a real pain point, not built now (no one has asked for it yet).
struct ProjectMetadata: Codable {
    let id: UUID
    var name: String
    var folders: [ProjectFolder]
    var paperEdits: [PaperEdit] = []

    private enum CodingKeys: String, CodingKey { case id, name, folders, paperEdits }

    init(id: UUID, name: String, folders: [ProjectFolder], paperEdits: [PaperEdit] = []) {
        self.id = id
        self.name = name
        self.folders = folders
        self.paperEdits = paperEdits
    }

    /// Custom decode (found via real GUI testing, spec §5 Known Issues): a stored property's
    /// `= []` default is *not* used by Swift's synthesized `Decodable` for a genuinely-missing
    /// key — only `Optional` properties fall back to `nil` automatically. Every project JSON
    /// saved before this field existed lacks the `"paperEdits"` key entirely, so opening one with
    /// the synthesized decoder threw `keyNotFound` and failed to open at all.
    /// `decodeIfPresent(...) ?? []` handles that migration explicitly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        folders = try container.decode([ProjectFolder].self, forKey: .folders)
        paperEdits = try container.decodeIfPresent([PaperEdit].self, forKey: .paperEdits) ?? []
    }
}

struct ProjectFolder: Codable, Identifiable {
    let id: UUID
    var name: String
    var dailies: [Daily]
}

struct Daily: Codable, Identifiable {
    let id: UUID
    var displayName: String
    /// Filename only, relative to this Daily's ProjectFolder directory — not a full path, so the
    /// whole project folder can be moved/renamed on disk without breaking the metadata.
    var mediaFilename: String
    var addedAt: Date
    var transcript: Transcript
    var highlights: [Highlight] = []
    /// Nominal frame rate for video dailies (nil for audio-only, or a video daily added before
    /// this field existed — Codable's default-on-missing-key handles that migration for free).
    /// Not used by anything yet — groundwork for the next phase (EDL export), which needs a
    /// frame rate to convert Paper Edit timestamps into editorial timecode. Captured opportunistically
    /// in `ProjectController.addDaily` for video files via `AVAssetTrack.load(.nominalFrameRate)`
    /// rather than left for a future backfill pass — every video Daily added between now and
    /// when EDL export actually lands would otherwise need retroactively re-scanning.
    var frameRate: Double?
}

/// A marked range within a Daily's transcript (spec §8). Anchored to `start`/`end` timestamps —
/// not `TranscriptSegment.id` (regenerated fresh on every decode, deliberately excluded from its
/// own `Codable` conformance — see that type's doc comment) and not an array index (unstable
/// across a re-transcribe, which fully replaces `Transcript.segments`). Timestamps are the one
/// piece of segment identity that's both persisted and stable, so a Highlight looks its segment(s)
/// back up by matching `start`/`end` against the current transcript at display time. Single-
/// segment for this pass (`start`/`end` mirror the one highlighted `TranscriptSegment` exactly);
/// a future cross-segment range is just a wider `start`/`end` pair spanning several segments, no
/// format change needed. `note` is freeform and optional; no separate `tag`/`color` field — the
/// app's design language deliberately uses a single accent color throughout (see
/// `WaveformBarsView`'s doc comment), so there's no second hue for a highlight color picker to
/// select between.
struct Highlight: Codable, Identifiable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var note: String?
    var createdAt: Date
}

/// The assembled "selects" reel (spec §8) — an ordered sequence of `PaperEditEntry`, each
/// referencing a Highlight rather than copying its text/timestamps, so edits to the underlying
/// transcript/highlight propagate automatically. A Project can hold multiple named Paper Edits
/// (real editorial workflow rarely wants just one assembly per project — e.g. a "selects" reel
/// vs. a tighter "presentation cut" from the same dailies), not just a single unnamed one.
struct PaperEdit: Codable, Identifiable {
    let id: UUID
    var name: String
    var entries: [PaperEditEntry]
}

/// References a Highlight by `(dailyID, highlightID)` rather than embedding a copy — `dailyID` is
/// carried explicitly (not re-derived by scanning every folder's every daily for a matching
/// highlight ID) since it's needed to resolve playback (source media URL) and display (Daily
/// name, transcript lookup) without ambiguity. If the underlying Highlight or Daily is later
/// deleted, `ProjectController.removeHighlight`/`deleteDaily`/`deleteFolder` all cascade-clean any
/// entries that would otherwise dangle — see their doc comments.
struct PaperEditEntry: Codable, Identifiable {
    let id: UUID
    var dailyID: UUID
    var highlightID: UUID
}

enum ProjectError: LocalizedError {
    case folderNotFound
    case notAProjectFolder

    var errorDescription: String? {
        switch self {
        case .folderNotFound:
            return "That folder isn't part of the open project."
        case .notAProjectFolder:
            return "That folder doesn't contain an Audium project (.audiumproject.json not found)."
        }
    }
}

/// Owns the currently-open Project's state and all disk I/O for it (spec §8). `@MainActor` since
/// every mutation is driven by UI actions (New/Open/drag-and-drop) and every read feeds SwiftUI.
@MainActor
final class ProjectController: ObservableObject {
    static let metadataFilename = ".audiumproject.json"

    @Published private(set) var metadata: ProjectMetadata?
    @Published private(set) var rootURL: URL?
    @Published var selectedFolderID: UUID?
    @Published var selectedDailyID: UUID?

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func createNew(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let meta = ProjectMetadata(id: UUID(), name: url.lastPathComponent, folders: [])
        rootURL = url
        metadata = meta
        try save()
        ProjectSettings.addRecent(url)
        AudiumLog.project.info("Project created: \(url.path, privacy: .public)")
    }

    func open(at url: URL) throws {
        let metaURL = url.appendingPathComponent(Self.metadataFilename)
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw ProjectError.notAProjectFolder
        }
        let data = try Data(contentsOf: metaURL)
        let meta = try Self.decoder.decode(ProjectMetadata.self, from: data)
        rootURL = url
        metadata = meta
        selectedFolderID = meta.folders.first?.id
        selectedDailyID = nil
        ProjectSettings.addRecent(url)
        AudiumLog.project.info("Project opened: \(url.path, privacy: .public), \(meta.folders.count) folder(s)")
    }

    func close() {
        metadata = nil
        rootURL = nil
        selectedFolderID = nil
        selectedDailyID = nil
    }

    func addFolder(name: String) throws {
        guard let rootURL else { return }
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(name), withIntermediateDirectories: true)
        let folder = ProjectFolder(id: UUID(), name: name, dailies: [])
        metadata?.folders.append(folder)
        selectedFolderID = folder.id
        try save()
        AudiumLog.project.info("Folder added: \(name, privacy: .public)")
    }

    /// Copies `sourceURL` into the given folder as a new Daily and returns both the Daily and the
    /// URL it now lives at (so the caller — transcription — doesn't need to re-derive the path).
    /// `async` (not throws-only) to capture a video Daily's frame rate via
    /// `AVAssetTrack.load(.nominalFrameRate)` — groundwork for the next phase's EDL export, which
    /// needs it for timecode conversion (spec §8). Nil for audio-only dailies or if extraction
    /// fails; failure is non-fatal (`try?`), a missing frame rate shouldn't block adding the Daily.
    @discardableResult
    func addDaily(from sourceURL: URL, to folderID: UUID) async throws -> (daily: Daily, mediaURL: URL) {
        guard let rootURL, let folder = metadata?.folders.first(where: { $0.id == folderID }) else {
            throw ProjectError.folderNotFound
        }
        let dailyID = UUID()
        let ext = sourceURL.pathExtension
        let mediaFilename = ext.isEmpty ? dailyID.uuidString : "\(dailyID.uuidString).\(ext)"
        let destURL = rootURL.appendingPathComponent(folder.name).appendingPathComponent(mediaFilename)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        var frameRate: Double?
        if AudioPlaybackController.videoExtensions.contains(ext.lowercased()) {
            frameRate = await Self.nominalFrameRate(of: destURL)
        }

        let daily = Daily(
            id: dailyID,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            mediaFilename: mediaFilename,
            addedAt: Date(),
            transcript: Transcript(segments: []),
            frameRate: frameRate
        )
        guard let folderIndex = metadata?.folders.firstIndex(where: { $0.id == folderID }) else {
            throw ProjectError.folderNotFound
        }
        metadata?.folders[folderIndex].dailies.append(daily)
        selectedFolderID = folderID
        selectedDailyID = dailyID
        try save()
        AudiumLog.project.info("Daily added: \(daily.displayName, privacy: .public) to folder \(folder.name, privacy: .public)")
        return (daily, destURL)
    }

    private static func nominalFrameRate(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let rate = try? await track.load(.nominalFrameRate), rate > 0 else { return nil }
        return Double(rate)
    }

    /// Shared by every mutation that needs to find a Daily without already knowing its folder
    /// (`updateDailyTranscript`/`addHighlight`/`removeHighlight` all used to repeat this same
    /// two-step lookup inline).
    private func locateDaily(_ dailyID: UUID) -> (folderIndex: Int, dailyIndex: Int)? {
        guard let folderIndex = metadata?.folders.firstIndex(where: { folder in
            folder.dailies.contains { $0.id == dailyID }
        }) else { return nil }
        guard let dailyIndex = metadata?.folders[folderIndex].dailies.firstIndex(where: { $0.id == dailyID }) else { return nil }
        return (folderIndex, dailyIndex)
    }

    func updateDailyTranscript(_ dailyID: UUID, segments: [TranscriptSegment]) {
        guard let (folderIndex, dailyIndex) = locateDaily(dailyID) else { return }
        metadata?.folders[folderIndex].dailies[dailyIndex].transcript.segments = segments
        try? save()
    }

    func addHighlight(_ highlight: Highlight, to dailyID: UUID) {
        guard let (folderIndex, dailyIndex) = locateDaily(dailyID) else { return }
        metadata?.folders[folderIndex].dailies[dailyIndex].highlights.append(highlight)
        try? save()
        AudiumLog.project.info("Highlight added to daily \(dailyID.uuidString, privacy: .public)")
    }

    /// Removes the Highlight and cascades to any Paper Edit entries that reference it — an entry
    /// pointing at a deleted Highlight would otherwise dangle (nothing to resolve its
    /// timestamp/text from). Removing an entry from a Paper Edit does *not* delete the underlying
    /// Highlight (see `removeEntry`) — this is the one direction that does cascade, since a
    /// Highlight is the thing an entry exists to reference.
    func removeHighlight(_ highlightID: UUID, from dailyID: UUID) {
        guard let (folderIndex, dailyIndex) = locateDaily(dailyID) else { return }
        metadata?.folders[folderIndex].dailies[dailyIndex].highlights.removeAll { $0.id == highlightID }
        removeDanglingPaperEditEntries { $0.highlightID == highlightID }
        try? save()
        AudiumLog.project.info("Highlight removed from daily \(dailyID.uuidString, privacy: .public)")
    }

    /// Deletes the folder's on-disk directory (and every Daily's media inside it) plus its
    /// metadata entry. Clears `selectedFolderID`/`selectedDailyID` if they pointed inside it, and
    /// cascades to any Paper Edit entries referencing a Daily that lived in this folder, for the
    /// same dangling-reference reason as `removeHighlight`.
    func deleteFolder(_ folderID: UUID) throws {
        guard let rootURL, let folder = metadata?.folders.first(where: { $0.id == folderID }) else {
            throw ProjectError.folderNotFound
        }
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(folder.name))
        metadata?.folders.removeAll { $0.id == folderID }
        if selectedFolderID == folderID { selectedFolderID = nil }
        if let selectedDailyID, folder.dailies.contains(where: { $0.id == selectedDailyID }) {
            self.selectedDailyID = nil
        }
        let deletedDailyIDs = Set(folder.dailies.map(\.id))
        removeDanglingPaperEditEntries { deletedDailyIDs.contains($0.dailyID) }
        try save()
        AudiumLog.project.info("Folder deleted: \(folder.name, privacy: .public)")
    }

    /// Deletes one Daily's media file and metadata entry from its folder. The media removal is
    /// best-effort (`try?`) — a missing file on disk shouldn't block clearing the (authoritative)
    /// metadata entry. Cascades to any Paper Edit entries referencing this Daily, same reasoning
    /// as `removeHighlight`.
    func deleteDaily(_ dailyID: UUID, from folderID: UUID) throws {
        guard let folderIndex = metadata?.folders.firstIndex(where: { $0.id == folderID }) else {
            throw ProjectError.folderNotFound
        }
        guard let dailyIndex = metadata?.folders[folderIndex].dailies.firstIndex(where: { $0.id == dailyID }) else { return }
        let folder = metadata!.folders[folderIndex]
        let daily = folder.dailies[dailyIndex]
        try? FileManager.default.removeItem(at: mediaURL(for: daily, in: folder))
        metadata?.folders[folderIndex].dailies.remove(at: dailyIndex)
        if selectedDailyID == dailyID { selectedDailyID = nil }
        removeDanglingPaperEditEntries { $0.dailyID == dailyID }
        try save()
        AudiumLog.project.info("Daily deleted: \(daily.displayName, privacy: .public)")
    }

    /// `rootURL!` is safe here: this is only ever called while a project is open (`metadata` and
    /// `rootURL` are always set/cleared together in `open`/`createNew`/`close`), and every caller
    /// already has a `ProjectFolder` in hand from iterating `metadata.folders`.
    func mediaURL(for daily: Daily, in folder: ProjectFolder) -> URL {
        rootURL!.appendingPathComponent(folder.name).appendingPathComponent(daily.mediaFilename)
    }

    // MARK: - Paper Edit (spec §8: the assembled "selects" reel)

    @discardableResult
    func addPaperEdit(name: String) -> PaperEdit {
        let paperEdit = PaperEdit(id: UUID(), name: name, entries: [])
        metadata?.paperEdits.append(paperEdit)
        try? save()
        AudiumLog.project.info("Paper Edit created: \(name, privacy: .public)")
        return paperEdit
    }

    func deletePaperEdit(_ paperEditID: UUID) {
        metadata?.paperEdits.removeAll { $0.id == paperEditID }
        try? save()
        AudiumLog.project.info("Paper Edit deleted")
    }

    /// Appends a new entry referencing `highlightID`/`dailyID` — does not validate that the
    /// Highlight still exists (callers already have one in hand, from the Highlights list this is
    /// wired to), matching the rest of this class's "trust the caller, it's all in-process UI
    /// state" style.
    func addPaperEditEntry(highlightID: UUID, dailyID: UUID, to paperEditID: UUID) {
        guard let index = metadata?.paperEdits.firstIndex(where: { $0.id == paperEditID }) else { return }
        metadata?.paperEdits[index].entries.append(PaperEditEntry(id: UUID(), dailyID: dailyID, highlightID: highlightID))
        try? save()
        AudiumLog.project.info("Paper Edit entry added")
    }

    /// Removes just this entry — deliberately does *not* touch the underlying Highlight (spec:
    /// "removing from the Paper Edit should NOT delete the underlying Highlight — they're
    /// independent").
    func removePaperEditEntry(_ entryID: UUID, from paperEditID: UUID) {
        guard let index = metadata?.paperEdits.firstIndex(where: { $0.id == paperEditID }) else { return }
        metadata?.paperEdits[index].entries.removeAll { $0.id == entryID }
        try? save()
    }

    /// Backs the Paper Edit view's drag-to-reorder — same `(IndexSet, Int)` shape SwiftUI's
    /// `List.onMove` already hands callers, so the view layer needs no translation.
    func movePaperEditEntries(in paperEditID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = metadata?.paperEdits.firstIndex(where: { $0.id == paperEditID }) else { return }
        metadata?.paperEdits[index].entries.move(fromOffsets: offsets, toOffset: destination)
        try? save()
    }

    private func removeDanglingPaperEditEntries(matching shouldRemove: (PaperEditEntry) -> Bool) {
        guard let paperEdits = metadata?.paperEdits else { return }
        for i in paperEdits.indices {
            metadata?.paperEdits[i].entries.removeAll(where: shouldRemove)
        }
    }

    private func save() throws {
        guard let rootURL, let metadata else { return }
        let data = try Self.encoder.encode(metadata)
        try data.write(to: rootURL.appendingPathComponent(Self.metadataFilename), options: .atomic)
    }
}

/// Recent-projects list (spec §8: "so reopening doesn't require re-browsing every time") — same
/// UserDefaults-backed pattern as TranscriptionSettings/ChatSettings.
enum ProjectSettings {
    private static let recentKey = "com.postproduction.Audium.recentProjectPaths"
    private static let maxRecents = 8

    static var recentPaths: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func addRecent(_ url: URL) {
        var paths = recentPaths.filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxRecents { paths = Array(paths.prefix(maxRecents)) }
        UserDefaults.standard.set(paths, forKey: recentKey)
    }
}

/// NSSavePanel/NSOpenPanel presentation, same precedent as Exporter.presentSavePanel — panel
/// logic lives beside the data logic it serves rather than in ContentView.
extension ProjectController {
    /// NSSavePanel, not a custom "choose location then type a name" flow — it natively combines
    /// both into one native dialog (same pattern any macOS app uses to create a new named
    /// document/package at a chosen location). The chosen `panel.url` becomes the new project's
    /// folder path; nothing is actually saved as a *file* by the panel itself, `createNew(at:)`
    /// does the real `mkdir` + metadata write.
    @MainActor
    static func presentNewProjectPanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    static func presentOpenProjectPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
