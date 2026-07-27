import Foundation
import OSLog

struct Message {
    enum Role: String {
        case system, user, assistant
    }

    let role: Role
    let content: String
}

/// Common surface for the vendor integrations (spec §3, Multi-provider AI). Anthropic/Claude
/// is deliberately not a conformer — removed from the app's provider set entirely (no audio
/// input for transcription, and dropped from text-completion too during build). Kept generic
/// enough that a Claude conformance could be added back later, but it's not part of v1.
/// Each provider calls its vendor's native API directly — no OpenAI-compatible shim.
protocol AIProvider {
    func complete(messages: [Message], model: String) async throws -> String
}

enum AIProviderError: LocalizedError {
    case missingAPIKey(KeychainStore.Provider)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key saved for \(provider.rawValue). Add one in Settings."
        case .emptyResponse:
            return "Empty completion response"
        }
    }
}

/// Thrown by the shared `validateHTTP` below — used by both this file and
/// `TranscriptionProvider.swift`, which hit the exact same non-2xx-response shape against
/// different vendor APIs. Used to be two identical `.httpError` cases, one on each file's own
/// error enum; neither call site ever switched on that specific case (both just surface
/// `.localizedDescription`), so one shared error type replaces both.
struct HTTPValidationError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "HTTP \(status): \(body)" }
}

func validateHTTP(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200...299).contains(http.statusCode) else {
        throw HTTPValidationError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
    }
}

/// generateContent for text completion — same endpoint shape as GeminiTranscriptionProvider's
/// audio call, separate conformance since transcription and text-completion are different
/// operations (spec §3). Two quirks verified against current docs (ai.google.dev/api/generate-content)
/// that matter for a shared chat UI:
/// - `contents[].role` only accepts "user"/"model" — there is no "assistant" role, and no
///   "system" role either; system prompts go in a separate top-level `systemInstruction` field,
///   unlike OpenAI's `messages[]`, which accepts a "system" role directly.
/// - Uses the same "-latest" alias convention as GeminiTranscriptionProvider (see that type's
///   comment) rather than a pinned version, since a pinned Gemini model name has already gone
///   stale on us once.
struct GeminiProvider: AIProvider {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    func complete(messages: [Message], model: String) async throws -> String {
        AudiumLog.aiChat.info("Gemini completion started: model \(model, privacy: .public), \(messages.count) message(s)")
        do {
            return try await completeInner(messages: messages, model: model)
        } catch {
            AudiumLog.aiChat.error("Gemini completion failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func completeInner(messages: [Message], model: String) async throws -> String {
        guard let apiKey = try KeychainStore.load(for: .gemini), !apiKey.isEmpty else {
            throw AIProviderError.missingAPIKey(.gemini)
        }

        let systemText = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let contents = messages.filter { $0.role != .system }.map {
            ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]]
        }

        var body: [String: Any] = ["contents": contents]
        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": ["text": systemText]]
        }

        let url = Self.endpoint.appendingPathComponent("\(model):generateContent")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)

        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text, !text.isEmpty else {
            throw AIProviderError.emptyResponse
        }
        AudiumLog.aiChat.info("Gemini completion succeeded: \(text.count) character(s)")
        return text
    }
}

/// Chat Completions API. Verified current default model against docs (developers.openai.com/api/docs/changelog,
/// July 2026 entries): "gpt-5.6" is a rolling alias routing to gpt-5.6-sol, same rolling-alias
/// convention as Gemini's "-latest" — used here instead of pinning to gpt-5.6-sol directly, for
/// the same reason (avoid another stale-pin incident). Request/response shape unchanged from
/// what OpenAIWhisperAPIProvider's neighbors already assume: `messages[].role` accepts "system"
/// directly (the one provider of the three that does), text lives at `choices[0].message.content`.
struct OpenAIProvider: AIProvider {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(messages: [Message], model: String) async throws -> String {
        AudiumLog.aiChat.info("OpenAI completion started: model \(model, privacy: .public), \(messages.count) message(s)")
        do {
            return try await completeInner(messages: messages, model: model)
        } catch {
            AudiumLog.aiChat.error("OpenAI completion failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func completeInner(messages: [Message], model: String) async throws -> String {
        guard let apiKey = try KeychainStore.load(for: .openai), !apiKey.isEmpty else {
            throw AIProviderError.missingAPIKey(.openai)
        }

        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response, data: data)

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct ChoiceMessage: Decodable { let content: String? }
                let message: ChoiceMessage
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw AIProviderError.emptyResponse
        }
        AudiumLog.aiChat.info("OpenAI completion succeeded: \(text.count) character(s)")
        return text
    }
}

enum AIProviderKind: String, CaseIterable, Identifiable {
    case gemini, openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        }
    }

    /// Rolling alias per vendor — same avoid-stale-pin reasoning as GeminiTranscriptionProvider/
    /// GeminiProvider/OpenAIProvider already use, rather than a version pinned at UI-build time.
    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-flash-latest"
        case .openai: return "gpt-5.6"
        }
    }

    func makeProvider() -> AIProvider {
        switch self {
        case .gemini: return GeminiProvider()
        case .openai: return OpenAIProvider()
        }
    }
}

/// Persists the chat panel's default AI provider — same UserDefaults pattern as
/// TranscriptionSettings' default-transcription-provider storage.
enum ChatSettings {
    private static let defaultProviderKey = "com.postproduction.Audium.defaultAIProvider"
    private static let defaultRoleKey = "com.postproduction.Audium.defaultAIRole"

    static var defaultProvider: AIProviderKind {
        get {
            UserDefaults.standard.string(forKey: defaultProviderKey)
                .flatMap(AIProviderKind.init(rawValue:)) ?? .gemini
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultProviderKey)
        }
    }

    /// Stores the selected Role's `id` (its Skills/ filename) — nil means "No role". Resolved
    /// back to a `Role` via `RoleLibrary.all` since UserDefaults can't hold the struct itself.
    static var defaultRoleID: String? {
        get { UserDefaults.standard.string(forKey: defaultRoleKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultRoleKey) }
    }
}
