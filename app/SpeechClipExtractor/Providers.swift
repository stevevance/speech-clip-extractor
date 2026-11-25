import Foundation

/*
 * The AI services that can suggest highlights. Anthropic is called
 * directly (Claude.swift); OpenRouter and DeepInfra both speak the
 * OpenAI-style chat completions API, so one client below serves both.
 */
enum Provider: String, CaseIterable, Identifiable {
    case anthropic, openrouter, deepinfra

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openrouter: return "OpenRouter"
        case .deepinfra: return "DeepInfra"
        }
    }

    // Each provider's key is its own Keychain item.
    var keychainAccount: String { rawValue + "-api-key" }

    // Where each provider's chosen model is remembered (Anthropic keeps the original key).
    var modelPref: String {
        self == .anthropic ? Pref.claudeModel : "model." + rawValue
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openrouter: return "anthropic/claude-opus-5.5"
        case .deepinfra: return "Qwen/Qwen3.5-397B-A17B"
        }
    }

    var keyPage: URL {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .deepinfra: return URL(string: "https://deepinfra.com/dash/api_keys")!
        }
    }

    /*
     * Where to cap spending, and a one-line tip in each provider's own terms,
     * so a leaked key or an unexpectedly big job can't run up a large bill.
     */
    var spendingLimitPage: URL {
        switch self {
        case .anthropic: return URL(string: "https://platform.claude.com/settings/limits")!
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .deepinfra: return URL(string: "https://deepinfra.com/dash/billing")!
        }
    }

    var spendingLimitTip: String {
        switch self {
        case .anthropic:
            return "Tip: set a monthly spend limit in your Anthropic account, so a leaked key or a big job can't run up a large bill."
        case .openrouter:
            return "Tip: OpenRouter is prepaid, and you can also give this API key its own credit limit, so a leaked key can't drain your credits."
        case .deepinfra:
            return "Tip: set a spending limit on your DeepInfra Billing page, so a leaked key or a big job can't run up a large bill."
        }
    }

    // The provider and model currently chosen in Settings.
    static var current: Provider {
        Provider(rawValue: Pref.string(Pref.provider, "anthropic")) ?? .anthropic
    }

    var currentModel: String {
        let saved = Pref.string(modelPref, defaultModel).trimmingCharacters(in: .whitespaces)
        return saved.isEmpty ? defaultModel : saved
    }

    // Effort is low, medium or high; an older saved "xhigh" or "max" counts as high.
    static var currentEffort: String {
        let saved = Pref.string(Pref.claudeEffort, "medium")
        return ["low", "medium", "high"].contains(saved) ? saved : "high"
    }
}

// MARK: - Encrypted connections

/*
 * Every request to an AI service goes through here:
 * - Only https:// addresses are allowed; anything else is refused before
 *   it's sent. (macOS App Transport Security also blocks plain http, and
 *   this app's Info.plist adds no exceptions.)
 * - TLS 1.2 is the oldest encryption accepted.
 * - The session is ephemeral: no response cache, cookies or credentials
 *   are written to disk, so transcripts and replies don't linger in
 *   ~/Library/Caches.
 */
enum SecureHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            throw ToolError.message("Refused to send a request over an unencrypted connection.")
        }
        let (data, response) = try await session.data(for: request)
        // A redirect must not end up somewhere unencrypted either.
        guard response.url?.scheme?.lowercased() == "https" else {
            throw ToolError.message("The server redirected to an unencrypted address; the reply was discarded.")
        }
        return (data, response)
    }
}

// MARK: - Model lists

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let label: String
}

/*
 * Fetches a provider's current models, so new models show up without an
 * app update. Anthropic's list needs the API key; OpenRouter's and
 * DeepInfra's are public. Only models that can return the JSON reply the
 * app needs are listed.
 */
enum ModelCatalog {
    static func fetch(_ provider: Provider) async throws -> [ModelInfo] {
        switch provider {
        case .anthropic:
            guard let key = Keychain.read(provider.keychainAccount), !key.isEmpty else {
                throw ToolError.message("Save an Anthropic API key first; its model list needs the key.")
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            let json = try await getJSON(request)
            return (json["data"] as? [[String: Any]] ?? []).compactMap { model in
                guard let id = model["id"] as? String else { return nil }
                return ModelInfo(id: id, label: (model["display_name"] as? String) ?? id)
            }

        case .openrouter:
            // Only models that support structured outputs (a reply that matches a JSON schema).
            let json = try await getJSON(URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!))
            return (json["data"] as? [[String: Any]] ?? []).compactMap { model in
                guard let id = model["id"] as? String, !id.hasSuffix(":batch"),
                      let params = model["supported_parameters"] as? [String],
                      params.contains("structured_outputs") else { return nil }
                return ModelInfo(id: id, label: (model["name"] as? String) ?? id)
            }
            .sorted { $0.id < $1.id }

        case .deepinfra:
            // DeepInfra also lists image, speech and embedding models; keep the chat ones.
            let json = try await getJSON(URLRequest(url: URL(string: "https://api.deepinfra.com/v1/openai/models")!))
            return (json["data"] as? [[String: Any]] ?? []).compactMap { model in
                guard let id = model["id"] as? String,
                      let tags = (model["metadata"] as? [String: Any])?["tags"] as? [String],
                      tags.contains("chat") else { return nil }
                return ModelInfo(id: id, label: id)
            }
            .sorted { $0.id < $1.id }
        }
    }

    private static func getJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await SecureHTTP.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ToolError.message("Couldn't load the model list (HTTP \(http.statusCode)).")
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

// MARK: - Suggesting highlights with any provider

enum HighlightService {
    // Sends the transcript to the chosen provider and model.
    static func suggest(cues: [Cue], guidance: String, count: Int) async throws -> ClaudeClient.Result {
        let provider = Provider.current
        guard let key = Keychain.read(provider.keychainAccount), !key.isEmpty else {
            throw ToolError.message("Add your \(provider.name) API key in Settings (⌘,) first.")
        }
        let model = provider.currentModel
        let effort = Provider.currentEffort
        switch provider {
        case .anthropic:
            return try await ClaudeClient.suggestHighlights(
                cues: cues, guidance: guidance, count: count, apiKey: key, model: model, effort: effort
            )
        case .openrouter, .deepinfra:
            return try await OpenAICompatibleClient.suggestHighlights(
                provider: provider, cues: cues, guidance: guidance, count: count, apiKey: key, model: model, effort: effort
            )
        }
    }
}

/*
 * OpenRouter and DeepInfra via their OpenAI-style chat completions APIs.
 * OpenRouter is asked for a reply matching the JSON schema (the model list
 * only shows models that support it) and passes the effort level on as
 * reasoning effort. DeepInfra is asked for plain JSON mode, which more of
 * its models support, with the schema spelled out in the prompt.
 */
enum OpenAICompatibleClient {
    static func suggestHighlights(
        provider: Provider, cues: [Cue], guidance: String, count: Int,
        apiKey: String, model: String, effort: String
    ) async throws -> ClaudeClient.Result {
        let endpoint = provider == .openrouter
            ? URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            : URL(string: "https://api.deepinfra.com/v1/openai/chat/completions")!

        let schemaData = try JSONSerialization.data(withJSONObject: ClaudeClient.schema, options: [.sortedKeys])
        let system = ClaudeClient.systemPrompt
            + "\n\nReply with only a JSON object matching this schema, no other text:\n"
            + String(decoding: schemaData, as: UTF8.self)

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": ClaudeClient.userPrompt(cues: cues, guidance: guidance, count: count)],
            ],
        ]
        if provider == .openrouter {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "highlights", "strict": true, "schema": ClaudeClient.schema],
            ]
            body["reasoning"] = ["effort": effort]
        } else {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .openrouter {
            // Names the app on OpenRouter's usage pages.
            request.setValue("Speech Clip Extractor", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await SecureHTTP.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw ToolError.message("\(provider.name) error \(http.statusCode): \(message)")
        }

        let choice = (json["choices"] as? [[String: Any]])?.first
        if choice?["finish_reason"] as? String == "length" {
            throw ToolError.message("The reply hit the length limit before finishing. Ask for fewer clips.")
        }
        guard let content = (choice?["message"] as? [String: Any])?["content"] as? String else {
            throw ToolError.message("\(provider.name)'s reply had no text.")
        }

        // Some models wrap JSON in ``` fences or add a sentence; keep just the outermost { … }.
        guard let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}") else {
            throw ToolError.message("\(model) didn't reply with JSON. Try another model. It began: \(replyExcerpt(content))")
        }
        struct Envelope: Decodable { let highlights: [HighlightSuggestion] }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(content[open...close].utf8))
        } catch {
            throw ToolError.message("\(model)'s reply didn't match the expected format. Try another model. It began: \(replyExcerpt(content))")
        }

        let usage = json["usage"] as? [String: Any]
        return ClaudeClient.Result(
            highlights: envelope.highlights,
            inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage?["completion_tokens"] as? Int ?? 0,
            model: json["model"] as? String ?? model,
            rawReply: content
        )
    }
}
