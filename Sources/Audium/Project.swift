import AppKit
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
    /// Stub for spec §8's future Highlight feature (range/tag/color/note within a transcript) —
    /// deliberately not implemented yet, this pass is data model + browser only. Reserving the
    /// slot now avoids a breaking metadata-format migration when highlight marking lands later.
    var highlights: [Highlight] = []
}

struct Highlight: Codable, Identifiable {
    let id: UUID
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
    @discardableResult
    func addDaily(from sourceURL: URL, to folderID: UUID) throws -> (daily: Daily, mediaURL: URL) {
        guard let rootURL, let folder = metadata?.folders.first(where: { $0.id == folderID }) else {
            throw ProjectError.folderNotFound
        }
        let dailyID = UUID()
        let ext = sourceURL.pathExtension
        let mediaFilename = ext.isEmpty ? dailyID.uuidString : "\(dailyID.uuidString).\(ext)"
        let destURL = rootURL.appendingPathComponent(folder.name).appendingPathComponent(mediaFilename)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let daily = Daily(
            id: dailyID,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            mediaFilename: mediaFilename,
            addedAt: Date(),
            transcript: Transcript(segments: [])
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

    func updateDailyTranscript(_ dailyID: UUID, segments: [TranscriptSegment]) {
        guard let folderIndex = metadata?.folders.firstIndex(where: { folder in
            folder.dailies.contains { $0.id == dailyID }
        }) else { return }
        guard let dailyIndex = metadata?.folders[folderIndex].dailies.firstIndex(where: { $0.id == dailyID }) else { return }
        metadata?.folders[folderIndex].dailies[dailyIndex].transcript.segments = segments
        try? save()
    }

    /// Deletes the folder's on-disk directory (and every Daily's media inside it) plus its
    /// metadata entry. Clears `selectedFolderID`/`selectedDailyID` if they pointed inside it, so
    /// the UI doesn't keep referencing a folder that no longer exists.
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
        try save()
        AudiumLog.project.info("Folder deleted: \(folder.name, privacy: .public)")
    }

    /// Deletes one Daily's media file and metadata entry from its folder. The media removal is
    /// best-effort (`try?`) — a missing file on disk shouldn't block clearing the (authoritative)
    /// metadata entry.
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
        try save()
        AudiumLog.project.info("Daily deleted: \(daily.displayName, privacy: .public)")
    }

    /// `rootURL!` is safe here: this is only ever called while a project is open (`metadata` and
    /// `rootURL` are always set/cleared together in `open`/`createNew`/`close`), and every caller
    /// already has a `ProjectFolder` in hand from iterating `metadata.folders`.
    func mediaURL(for daily: Daily, in folder: ProjectFolder) -> URL {
        rootURL!.appendingPathComponent(folder.name).appendingPathComponent(daily.mediaFilename)
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
