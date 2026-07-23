import OSLog

/// App-wide unified-logging setup (spec §2, "In-app logging + log viewer"). One subsystem for
/// the whole app (matches Apple's own convention — subsystem = bundle id, category = module)
/// so `LogViewerView` can filter OSLogStore down to "logs that are ours" with a single equality
/// check; categories give the per-module breakdown the log viewer displays.
enum AudiumLog {
    static let subsystem = "com.postproduction.Audium"

    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    static let diarization = Logger(subsystem: subsystem, category: "Diarization")
    static let export = Logger(subsystem: subsystem, category: "Export")
    static let aiChat = Logger(subsystem: subsystem, category: "AIChat")
    static let keychain = Logger(subsystem: subsystem, category: "Keychain")
    static let youtube = Logger(subsystem: subsystem, category: "YouTube")
}
