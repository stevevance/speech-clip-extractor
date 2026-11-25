import Foundation
import Security

// One highlight Claude suggests. Field names match the JSON schema below.
struct HighlightSuggestion: Decodable {
    let title: String
    let start_seconds: Double
    let end_seconds: Double
    let quote: String
    let why: String
}

/*
 * Calls the Claude Messages API over plain HTTPS (there's no official Swift
 * SDK). Claude Opus 5.5 rejects forced tool_choice, so the reply is
 * constrained with structured outputs (output_config.format) instead: the
 * response's text block is JSON matching the schema.
 */
enum ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let systemPrompt = """
    You pick highlight clips from speech and meeting transcripts so they can be cut into short videos for social media.

    Look for:
    - Short, self-contained soundbites, usually under 20 seconds
    - Surprising or strong language
    - Specific data points or statistics
    - Clear problem or solution statements
    - Rhetorical flourishes or memorable phrases

    Each clip must make sense on its own, starting at the beginning of a sentence and ending at the end of one. Use the transcript's timestamps (in seconds) for start_seconds and end_seconds: start at the first cue of the passage and end at the last cue's end time. Quote the words exactly as transcribed. Give each clip a short title. In "why", say in one sentence what makes it notable. Order the clips by start time.
    """

    // JSON schema for the reply. Strict structured outputs need additionalProperties: false and every field required.
    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["highlights"],
        "properties": [
            "highlights": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "start_seconds", "end_seconds", "quote", "why"],
                    "properties": [
                        "title": ["type": "string"],
                        "start_seconds": ["type": "number"],
                        "end_seconds": ["type": "number"],
                        "quote": ["type": "string"],
                        "why": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    struct Result {
        let highlights: [HighlightSuggestion]
        let inputTokens: Int
        let outputTokens: Int
        let model: String
    }

    static func suggestHighlights(
        cues: [Cue],
        guidance: String,
        count: Int,
        apiKey: String,
        model: String,
        effort: String
    ) async throws -> Result {
        let prompt = userPrompt(cues: cues, guidance: guidance, count: count)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": systemPrompt,
            "messages": [["role": "user", "content": prompt]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]

        // Haiku has no server-side fallback; the other current models do.
        if model.contains("haiku") {
            return try await send(body, apiKey: apiKey, beta: nil)
        }
        // If a safety classifier declines, let the API retry on a fallback model it picks.
        body["fallbacks"] = "default"
        do {
            return try await send(body, apiKey: apiKey, beta: "server-side-fallback-2026-07-01")
        } catch ToolError.message(let text) where text.localizedCaseInsensitiveContains("fallback") {
            // An account without the fallback beta gets a 400 naming it; retry without fallbacks.
            body.removeValue(forKey: "fallbacks")
            return try await send(body, apiKey: apiKey, beta: nil)
        }
    }

    /*
     * The user message, shared by every provider: the request, any editor
     * guidance, then one line per cue ("[12.3-15.8] SPEAKER_00: text"). The
     * whole transcript is sent, never truncated.
     */
    static func userPrompt(cues: [Cue], guidance: String, count: Int) -> String {
        let transcript = cues.map { cue in
            let who = cue.speaker.map { "\($0): " } ?? ""
            return String(format: "[%.1f-%.1f] ", cue.start, cue.end) + who + cue.text
        }.joined(separator: "\n")

        var prompt = "Suggest about \(count) highlight clips from this transcript.\n"
        let trimmedGuidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGuidance.isEmpty {
            prompt += "Guidance from the editor: \(trimmedGuidance)\n"
        }
        prompt += "\n<transcript>\n\(transcript)\n</transcript>"
        return prompt
    }

    private static func send(_ body: [String: Any], apiKey: String, beta: String?) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await SecureHTTP.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        // Non-2xx: surface the API's own error message.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw ToolError.message("Claude API error \(http.statusCode): \(message)")
        }

        // Check why the reply stopped before reading it.
        switch json["stop_reason"] as? String {
        case "refusal":
            let details = json["stop_details"] as? [String: Any]
            let why = details?["explanation"] as? String ?? "no explanation given"
            throw ToolError.message("Claude declined this request: \(why)")
        case "max_tokens":
            throw ToolError.message("Claude's reply hit the max_tokens limit before finishing. Ask for fewer clips.")
        default:
            break
        }

        // The JSON answer is the text block (thinking blocks, if any, come first).
        let content = json["content"] as? [[String: Any]] ?? []
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ToolError.message("Claude's reply had no text block.")
        }

        struct Envelope: Decodable { let highlights: [HighlightSuggestion] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))

        let usage = json["usage"] as? [String: Any]
        return Result(
            highlights: envelope.highlights,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0,
            model: json["model"] as? String ?? ""
        )
    }
}

/*
 * Stores each provider's API key in the login Keychain, all under the
 * service label "app.speechclipextractor", one item per provider (the
 * account name, e.g. "anthropic-api-key").
 */
enum Keychain {
    private static let service = "app.speechclipextractor"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String = Provider.anthropic.keychainAccount) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Whether a key is saved, without reading the key itself.
    static func exists(_ account: String = Provider.anthropic.keychainAccount) -> Bool {
        SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String = Provider.anthropic.keychainAccount) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func save(_ key: String, account: String = Provider.anthropic.keychainAccount) {
        delete(account)
        guard !key.isEmpty else { return }
        var add = query(account)
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
