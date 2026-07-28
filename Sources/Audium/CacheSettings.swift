import Foundation

/// Global cache/render location for derived/temporary files (spec §8) — extracted audio from
/// video-to-transcription conversion, YouTube-downloaded audio, whisper.cpp intermediate format
/// conversions. One global, app-wide location (UserDefaults-backed), not per-project — same
/// conceptual model as Avid's Media Cache setting. Defaults to
/// `~/Library/Caches/com.postproduction.Audium/` until the user overrides it in Settings.
/// whisper.cpp/WhisperKit *model* downloads are unrelated (spec-scoped to derived/temp files only)
/// and stay in Application Support (`WhisperCppModelManager.modelsDirectory`) — models are
/// long-lived assets the user picks a size for, not scratch files from one transcription run.
enum CacheSettings {
    private static let locationKey = "com.postproduction.Audium.cacheLocation"

    static var defaultLocation: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.postproduction.Audium")
    }

    static var location: URL {
        get {
            guard let path = UserDefaults.standard.string(forKey: locationKey), !path.isEmpty else {
                return defaultLocation
            }
            return URL(fileURLWithPath: path)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: locationKey) }
    }

    /// Fresh UUID-named subdirectory inside the configured cache location, created on demand —
    /// same per-call isolation the previous scattered `FileManager.default.temporaryDirectory
    /// .appendingPathComponent(UUID().uuidString)` call sites already used (each derived file gets
    /// its own directory so concurrent runs/cleanup can't collide), just rooted at the configured
    /// location instead of the system temp dir.
    static func freshWorkDirectory() throws -> URL {
        let dir = location.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
