import SwiftUI
import OSLog
import AppKit

/// In-app log viewer (spec §2) — Portainer-style: a controls bar (auto-refresh, wrap-lines,
/// timestamps, fetch scope, search, line count, download/copy actions) above a plain
/// terminal-style scrolling log body. Outer chrome stays GlassPanel/Theme-consistent with the
/// rest of the app; the log body itself is deliberately raw/monospace, not app-styled prose.
/// Reads back what `AudiumLog` wrote via `OSLogStore`.
struct LogViewerView: View {
    @State private var allLines: [LogLine] = []
    @State private var errorMessage: String?
    @State private var autoRefresh = false
    @State private var wrapLines = false
    @State private var showTimestamps = true
    @State private var fetchScope: FetchScope = .last1h
    @State private var searchText = ""
    @State private var linesText = "200"
    @State private var selectedIDs: Set<Int> = []

    private var lineLimit: Int {
        max(1, Int(linesText) ?? 200)
    }

    private var visibleLines: [LogLine] {
        let capped = Array(allLines.prefix(lineLimit))
        guard !searchText.isEmpty else { return capped }
        return capped.filter {
            $0.entry.composedMessage.localizedCaseInsensitiveContains(searchText)
                || $0.entry.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controlsBar
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            logBody
        }
        .padding()
        .frame(minWidth: 780, minHeight: 500)
        .background(Theme.background)
        .onAppear { load() }
        .onChange(of: fetchScope) { _, _ in load() }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                load()
            }
        }
    }

    private var header: some View {
        HStack {
            PanelTitle("Logs")
            Spacer()
            Button("Refresh") { load() }
                .font(.caption.bold())
                .buttonStyle(.accent)
        }
    }

    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Toggle("Auto-refresh", isOn: $autoRefresh)
                Toggle("Wrap lines", isOn: $wrapLines)
                Toggle("Timestamps", isOn: $showTimestamps)
                Spacer()
                HStack(spacing: 4) {
                    Text("Fetch")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $fetchScope) {
                        ForEach(FetchScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .font(.caption)

            HStack(spacing: 8) {
                TextField("Filter…", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .glassPanel(cornerRadius: 8)
                HStack(spacing: 4) {
                    Text("Lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", text: $linesText)
                        .textFieldStyle(.plain)
                        .padding(6)
                        .frame(width: 56)
                        .glassPanel(cornerRadius: 8)
                }
                Button("Download") { downloadLogs() }
                    .font(.caption.bold())
                    .buttonStyle(.accent)
                Button("Copy") { copy(visibleLines) }
                    .font(.caption.bold())
                    .buttonStyle(.accent)
                Button("Copy Selected") { copy(visibleLines.filter { selectedIDs.contains($0.id) }) }
                    .font(.caption.bold())
                    .buttonStyle(.accent)
                    .disabled(selectedIDs.isEmpty)
                Button("Unselect") { selectedIDs.removeAll() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(selectedIDs.isEmpty)
            }
        }
    }

    private var logBody: some View {
        ScrollView(wrapLines ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                if visibleLines.isEmpty {
                    Text("No log entries")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(.caption, design: .monospaced))
                        .padding(.top, 20)
                } else {
                    ForEach(visibleLines) { line in
                        LogLineRow(
                            line: line,
                            showTimestamp: showTimestamps,
                            wraps: wrapLines,
                            isSelected: selectedIDs.contains(line.id),
                            onToggleSelect: { toggleSelection(line.id) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.panelStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleSelection(_ id: Int) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func load() {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceEnd: -fetchScope.secondsAgo)
            let entries = try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == AudiumLog.subsystem }
                .sorted { $0.date > $1.date }
            allLines = entries.enumerated().map { LogLine(id: $0.offset, entry: $0.element) }
            selectedIDs.removeAll()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to read logs: \(error.localizedDescription)"
        }
    }

    private func formatted(_ line: LogLine) -> String {
        "[\(Self.timestampFormatter.string(from: line.entry.date))] \(levelLabel(line.entry.level)) [\(line.entry.category)] \(line.entry.composedMessage)"
    }

    private func copy(_ lines: [LogLine]) {
        let text = lines.map(formatted).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func downloadLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "audium-logs.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = visibleLines.map(formatted).joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to save logs: \(error.localizedDescription)"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "—"
        @unknown default: return "—"
        }
    }
}

private struct LogLine: Identifiable {
    let id: Int
    let entry: OSLogEntryLog
}

private enum FetchScope: String, CaseIterable, Identifiable {
    case last5m = "Last 5 min"
    case last15m = "Last 15 min"
    case last1h = "Last hour"
    case last6h = "Last 6 hours"
    case last24h = "Last 24 hours"

    var id: String { rawValue }

    var secondsAgo: TimeInterval {
        switch self {
        case .last5m: return 5 * 60
        case .last15m: return 15 * 60
        case .last1h: return 60 * 60
        case .last6h: return 6 * 60 * 60
        case .last24h: return 24 * 60 * 60
        }
    }
}

/// Terminal-style row: monospace, dark background inherited from `logBody`, colored level tag
/// within the app's existing cyan/red palette (no new hues introduced). Tap toggles selection
/// for "Copy Selected" — deliberately basic (no shift/cmd-click range selection).
private struct LogLineRow: View {
    let line: LogLine
    let showTimestamp: Bool
    let wraps: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var levelColor: Color {
        switch line.entry.level {
        case .error, .fault: return .red
        case .notice, .info: return Theme.accent
        default: return .white.opacity(0.7)
        }
    }

    private var levelLabel: String {
        switch line.entry.level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        case .undefined: return "—"
        @unknown default: return "—"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showTimestamp {
                Text(Self.timeFormatter.string(from: line.entry.date))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 62, alignment: .leading)
            }
            Text(levelLabel)
                .foregroundStyle(levelColor)
                .frame(width: 48, alignment: .leading)
            Text("[\(line.entry.category)]")
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 100, alignment: .leading)
            Text(line.entry.composedMessage)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: false)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? Theme.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelect() }
    }
}
