import SwiftUI
import WhisperKit

/// API keys, default providers, and WhisperKit model size (spec §2/§3). Custom glass/cyan layout
/// — no stock `Form`/`Section` (spec §4 explicitly rejects that look), same treatment as the
/// main window's bento panels.
struct SettingsView: View {
    @State private var geminiKey = ""
    @State private var openAIKey = ""
    @State private var status = ""

    @State private var defaultTranscriptionProvider = TranscriptionSettings.defaultProvider
    @State private var defaultChatProvider = ChatSettings.defaultProvider

    @State private var whisperVariants: [String] = []
    @State private var whisperDefaultVariant = ""
    @State private var selectedWhisperVariant: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                apiKeysSection
                transcriptionProviderSection
                whisperModelSection
                chatProviderSection
            }
            .padding()
        }
        .frame(width: 460, height: 620)
        .background(Theme.background)
        .onAppear {
            loadExistingKeys()
            loadWhisperModels()
        }
    }

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle("API Keys")
            keyRow(label: "Gemini", key: $geminiKey)
            keyRow(label: "OpenAI", key: $openAIKey)
            HStack {
                Button("Save Keys", action: saveKeys)
                    .buttonStyle(.accent)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private func keyRow(label: String, key: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SecureField(label, text: key)
                .textFieldStyle(.plain)
                .padding(8)
                .glassPanel(cornerRadius: 10)
            // Both Gemini and OpenAI keys serve double duty (spec §3): the same vendor key
            // backs both TranscriptionProvider and AIProvider conformances, so this caption
            // applies identically to both rows rather than needing per-key differentiation.
            Text("Used for transcription and AI chat")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptionProviderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle("Default Transcription Provider")
            Picker("", selection: $defaultTranscriptionProvider) {
                Text("WhisperKit (local)").tag(TranscriptionProviderKind.whisperKit)
                Text("Gemini (cloud)").tag(TranscriptionProviderKind.gemini)
                Text("OpenAI (cloud)").tag(TranscriptionProviderKind.openAI)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: defaultTranscriptionProvider) { _, newValue in
                TranscriptionSettings.defaultProvider = newValue
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var whisperModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle("WhisperKit Model Size")
            Text("Options reflect what this Mac actually supports, not a fixed list.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("", selection: $selectedWhisperVariant) {
                Text("Default (\(whisperDisplayName(whisperDefaultVariant)))").tag(String?.none)
                ForEach(whisperVariants, id: \.self) { variant in
                    Text(whisperDisplayName(variant)).tag(String?.some(variant))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: selectedWhisperVariant) { _, newValue in
                WhisperModelSettings.selectedVariant = newValue
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var chatProviderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle("Default AI Chat Provider")
            Picker("", selection: $defaultChatProvider) {
                ForEach(AIProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: defaultChatProvider) { _, newValue in
                ChatSettings.defaultProvider = newValue
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private func loadExistingKeys() {
        geminiKey = (try? KeychainStore.load(for: .gemini)) ?? nil ?? ""
        openAIKey = (try? KeychainStore.load(for: .openai)) ?? nil ?? ""
    }

    private func saveKeys() {
        do {
            if !geminiKey.isEmpty { try KeychainStore.save(key: geminiKey, for: .gemini) }
            if !openAIKey.isEmpty { try KeychainStore.save(key: openAIKey, for: .openai) }
            status = "Saved."
        } catch {
            status = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func loadWhisperModels() {
        let support = WhisperKit.recommendedModels()
        whisperDefaultVariant = support.default
        whisperVariants = support.supported.sorted()
        selectedWhisperVariant = WhisperModelSettings.selectedVariant
    }

    // e.g. "openai_whisper-large-v3-v20240930_turbo_632MB" -> "Large V3 V20240930 Turbo 632mb"
    private func whisperDisplayName(_ variant: String) -> String {
        var name = variant.replacingOccurrences(of: "openai_whisper-", with: "")
        name = name.replacingOccurrences(of: ".en", with: " (English)")
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")
        return name.split(separator: " ").map(\.capitalized).joined(separator: " ")
    }
}
