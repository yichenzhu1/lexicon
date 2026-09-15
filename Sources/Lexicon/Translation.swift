import Foundation

enum TranslationProviderCategory: String, CaseIterable, Identifiable {
    case apple
    case translationAPIs
    case languageModels
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Translation"
        case .translationAPIs: return "Translation APIs"
        case .languageModels: return "AI Models"
        case .disabled: return "Off"
        }
    }

    var providerPickerTitle: String {
        switch self {
        case .translationAPIs: return "Service"
        case .languageModels: return "Provider"
        case .apple, .disabled: return "Provider"
        }
    }
}

enum TranslationProvider: String, CaseIterable, Identifiable, Sendable {
    case apple
    case googleCloud
    case deepL
    case openAI
    case deepSeek
    case gemini
    case claude
    case dashScope
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Translation"
        case .disabled: return "Off"
        case .googleCloud: return "Google Cloud Translation"
        case .deepL: return "DeepL"
        case .openAI: return "OpenAI (GPT)"
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Google Gemini"
        case .claude: return "Anthropic Claude"
        case .dashScope: return "Alibaba DashScope"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .googleCloud, .deepL, .openAI, .deepSeek, .gemini, .claude, .dashScope:
            return true
        case .apple, .disabled: return false
        }
    }

    var keychain: APIKeychain? {
        requiresAPIKey
            ? APIKeychain(service: "com.yichenzhu.Lexicon.translation.\(rawValue)") : nil
    }

    var category: TranslationProviderCategory {
        switch self {
        case .apple: return .apple
        case .googleCloud, .deepL: return .translationAPIs
        case .openAI, .deepSeek, .gemini, .claude, .dashScope: return .languageModels
        case .disabled: return .disabled
        }
    }

    var isGeneralLanguageModel: Bool {
        category == .languageModels
    }

    var recommendedModel: String? {
        switch self {
        case .openAI: return "gpt-5.6-luna"
        case .deepSeek: return "deepseek-v4-flash"
        case .gemini: return "gemini-3.7-flash"
        case .claude: return "claude-sonnet-5"
        case .apple, .googleCloud, .deepL, .dashScope, .disabled: return nil
        }
    }

    static func providers(in category: TranslationProviderCategory) -> [TranslationProvider] {
        allCases.filter { $0.category == category }
    }
}

enum DashScopeRegion: String, CaseIterable, Identifiable, Sendable {
    case china
    case international
    case unitedStates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .china: return "China (Beijing)"
        case .international: return "International (Singapore)"
        case .unitedStates: return "United States (Virginia)"
        }
    }

    var endpoint: URL {
        switch self {
        case .china:
            return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        case .international:
            return URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!
        case .unitedStates:
            return URL(string: "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions")!
        }
    }

    var recommendedModel: String {
        switch self {
        case .china, .international: return "qwen3.7-plus"
        case .unitedStates: return "qwen3.7-plus-us"
        }
    }
}

struct TranslationServiceError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Validate the dictionary's input once, before selecting the local or cloud
/// execution path. LLMs receive this complete prompt, including instructions.
struct TranslationInput: Sendable {
    let prompt: String

    init(_ rawPrompt: String) throws {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw TranslationServiceError(message: "The dictionary supplied no text to translate.")
        }
        guard prompt.utf8.count <= 20_000 else {
            throw TranslationServiceError(message: "This dictionary passage is too long to translate.")
        }
        self.prompt = prompt
    }
}

/// One immutable settings snapshot per request. Every model provider,
/// including DashScope, uses the same model field.
struct TranslationConfiguration: Equatable, Sendable {
    let provider: TranslationProvider
    let model: String
    let dashScopeRegion: DashScopeRegion

    init(provider: TranslationProvider, model: String = "", dashScopeRegion: DashScopeRegion = .china) {
        self.provider = provider
        self.model = model
        self.dashScopeRegion = dashScopeRegion
    }
}

enum DictionaryTranslationService {
    private struct GoogleRequest: Encodable {
        let q: [String]
        let source = "en"
        let target = "zh-CN"
        let format: String
    }

    private struct GoogleResponse: Decodable {
        struct Container: Decodable {
            struct Translation: Decodable { let translatedText: String }
            let translations: [Translation]
        }
        let data: Container
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream = false
        let temperature: Double?
        let enableThinking: Bool?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case enableThinking = "enable_thinking"
        }
    }

    private struct OpenAIRequest: Encodable {
        let model: String
        let input: String
        let instructions = "Follow the dictionary translation request exactly. "
            + "Return only the requested translation and preserve any requested markup."
        let store = false
    }

    private struct OpenAIResponse: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Content]?
        }
        let output: [Output]
        let status: String?

        var outputText: String {
            output
                .filter { $0.type == "message" }
                .flatMap { $0.content ?? [] }
                .filter { $0.type == "output_text" }
                .compactMap(\.text)
                .joined()
        }
    }

    private struct ClaudeRequest: Encodable {
        let model: String
        let maxTokens = 8_192
        let system = "Follow the dictionary translation request exactly. "
            + "Return only the requested translation and preserve any requested markup."
        let messages: [ChatMessage]

        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct ClaudeResponse: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        let content: [Content]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }

        var outputText: String {
            content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined()
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }

    private struct DeepLRequest: Encodable {
        let text: [String]
        let sourceLang = "EN"
        let targetLang = "ZH-HANS"
        let context: String?
        let tagHandling: String?
        let tagHandlingVersion: String?

        enum CodingKeys: String, CodingKey {
            case text, context
            case sourceLang = "source_lang"
            case targetLang = "target_lang"
            case tagHandling = "tag_handling"
            case tagHandlingVersion = "tag_handling_version"
        }
    }

    private struct DeepLResponse: Decodable {
        struct Translation: Decodable { let text: String }
        let translations: [Translation]
    }

    private struct APIErrorBody: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }

    private struct DirectAPIErrorBody: Decodable {
        let message: String
    }

    static func translate(
        input: TranslationInput,
        configuration: TranslationConfiguration,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        try Task.checkCancellation()
        let provider = configuration.provider
        let service = serviceName(for: provider)
        let request = try makeRequest(
            input: input, configuration: configuration, apiKey: apiKey, service: service
        )
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validate(response: response, data: data, service: service)
        let text = try translationText(from: data, provider: provider, service: service)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let name = provider == .googleCloud ? "Google Cloud" : service
            throw TranslationServiceError(message: "\(name) returned an empty translation.")
        }
        // Dedicated APIs may intentionally preserve surrounding whitespace in
        // translated HTML; LLM completions retain the existing trimming policy.
        return provider.isGeneralLanguageModel ? trimmed : text
    }

    /// Extract the text translated by Apple and dedicated APIs. DeepL also
    /// receives the full prompt as context; LLMs receive the complete prompt.
    /// OED/ODE place the source first, while Longman 6 places a Chinese
    /// instruction first and the source on the following lines.
    static func sourcePassage(from prompt: String) -> String {
        let lines = prompt.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        // Find the dictionary's instruction boundary instead of assuming the
        // source itself has no line breaks. Prefer the Chinese instruction
        // used by dictionary repacks: an English source sentence can itself
        // start with “Translate”. The English fallback covers our test prompt.
        let instructionIndex = lines.firstIndex { line in
            let hasCJK = line.unicodeScalars.contains {
                (0x3400 ... 0x9FFF).contains($0.value)
            }
            return hasCJK && line.contains("翻译")
        } ?? lines.firstIndex { $0.lowercased().hasPrefix("translate ") }
        if let instructionIndex {
            let sourceLines: ArraySlice<String>
            if instructionIndex == lines.startIndex {
                sourceLines = lines.dropFirst()
            } else {
                sourceLines = lines[..<instructionIndex]
            }
            return sourceLines.joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }

    static func plainSourcePassage(from prompt: String) -> String {
        sourcePassage(from: prompt)
            .replacingOccurrences(
                of: #"<\/?(?:m|n|o)>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "⋖", with: "<")
    }

    private static func makeRequest(
        input: TranslationInput, configuration: TranslationConfiguration,
        apiKey rawAPIKey: String, service: String
    ) throws -> URLRequest {
        let provider = configuration.provider
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.requiresAPIKey || !apiKey.isEmpty else {
            throw TranslationServiceError(
                message: "Add a \(provider.title) API key in Settings > Translation."
            )
        }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isGeneralLanguageModel || !model.isEmpty else {
            throw TranslationServiceError(message: "Enter a \(service) model name in Settings.")
        }
        let prompt = input.prompt
        let source = provider.category == .translationAPIs ? sourcePassage(from: prompt) : prompt
        guard !source.isEmpty else {
            throw TranslationServiceError(message: "The dictionary supplied no text to translate.")
        }

        let endpoint: URL
        let authorization: (field: String, value: String)
        let body: Data
        let encoder = JSONEncoder()
        switch provider {
        case .apple:
            throw TranslationServiceError(
                message: "Apple Translation must be performed by the system translation session."
            )
        case .disabled:
            throw TranslationServiceError(
                message: "Choose a live translation provider in Settings > Translation."
            )
        case .googleCloud:
            endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!
            // Credentials belong in headers, never in URLs or query logs.
            authorization = ("x-goog-api-key", apiKey)
            let markup = source.range(of: #"<\/?[a-zA-Z][^>]*>"#, options: .regularExpression) != nil
            body = try encoder.encode(GoogleRequest(q: [source], format: markup ? "html" : "text"))
        case .deepL:
            endpoint = deepLEndpoint(forAPIKey: apiKey)
            authorization = ("Authorization", "DeepL-Auth-Key \(apiKey)")
            let markup = source.range(
                of: #"<\/?(?:m|n|o)>"#, options: [.regularExpression, .caseInsensitive]
            ) != nil
            // DeepL's ignore_tags option applies only to XML. Dictionary
            // passages are HTML fragments, so protect annotations using its
            // supported HTML attribute and restore the bare markers on return.
            let protectedSource = source.replacingOccurrences(
                of: #"<([no])>"#, with: #"<$1 translate="no">"#,
                options: [.regularExpression, .caseInsensitive]
            )
            body = try encoder.encode(DeepLRequest(
                text: [protectedSource], context: prompt == source ? nil : prompt,
                tagHandling: markup ? "html" : nil,
                tagHandlingVersion: markup ? "v2" : nil
            ))
        case .openAI:
            endpoint = URL(string: "https://api.openai.com/v1/responses")!
            authorization = ("Authorization", "Bearer \(apiKey)")
            body = try encoder.encode(OpenAIRequest(model: model, input: prompt))
        case .claude:
            endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
            authorization = ("x-api-key", apiKey)
            body = try encoder.encode(ClaudeRequest(
                model: model, messages: [.init(role: "user", content: prompt)]
            ))
        case .deepSeek, .gemini, .dashScope:
            switch provider {
            case .deepSeek:
                endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
            case .gemini:
                endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
            default:
                endpoint = configuration.dashScopeRegion.endpoint
            }
            authorization = ("Authorization", "Bearer \(apiKey)")
            var messages: [ChatMessage] = []
            if provider != .dashScope {
                messages.append(.init(
                    role: "system",
                    content: "Follow the dictionary translation request exactly. "
                        + "Return only the requested translation and preserve requested markup."
                ))
            }
            messages.append(.init(role: "user", content: prompt))
            body = try encoder.encode(ChatRequest(
                model: model, messages: messages,
                temperature: provider == .dashScope ? 0.1 : nil,
                enableThinking: provider == .dashScope ? false : nil
            ))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = provider.category == .translationAPIs ? 30 : provider == .dashScope ? 45 : 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization.value, forHTTPHeaderField: authorization.field)
        if provider == .claude {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = body
        return request
    }

    private static func translationText(
        from data: Data, provider: TranslationProvider, service: String
    ) throws -> String {
        let decoder = JSONDecoder()
        switch provider {
        case .googleCloud:
            return try decoder.decode(GoogleResponse.self, from: data)
                .data.translations.first?.translatedText ?? ""
        case .deepL:
            let text = try decoder.decode(DeepLResponse.self, from: data).translations.first?.text ?? ""
            return text.replacingOccurrences(
                of: #"<([no])\s+translate\s*=\s*(?:"no"|'no'|no)\s*>"#, with: "<$1>",
                options: [.regularExpression, .caseInsensitive]
            )
        case .openAI:
            let result = try decoder.decode(OpenAIResponse.self, from: data)
            if let status = result.status, status != "completed" {
                throw incompleteTranslation(service: service)
            }
            return result.outputText
        case .claude:
            let result = try decoder.decode(ClaudeResponse.self, from: data)
            if let reason = result.stopReason, reason != "end_turn", reason != "stop_sequence" {
                throw incompleteTranslation(service: service)
            }
            return result.outputText
        case .deepSeek, .gemini, .dashScope:
            let choice = try decoder.decode(ChatResponse.self, from: data).choices.first
            if let reason = choice?.finishReason, reason != "stop" {
                throw incompleteTranslation(service: service)
            }
            return choice?.message.content ?? ""
        case .apple, .disabled:
            // These providers are rejected before a cloud request is created.
            throw TranslationServiceError(message: "\(service) returned an invalid response.")
        }
    }

    static func deepLEndpoint(forAPIKey apiKey: String) -> URL {
        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        return URL(string: "https://\(host)/v2/translate")!
    }

    private static func serviceName(for provider: TranslationProvider) -> String {
        switch provider {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .dashScope: return "DashScope"
        default: return provider.title
        }
    }

    private static func incompleteTranslation(service: String) -> TranslationServiceError {
        TranslationServiceError(
            message: "\(service) did not finish the translation. Please try again."
        )
    }

    private static func validate(response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranslationServiceError(message: "\(service) returned an invalid response.")
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let decoder = JSONDecoder()
            let message = ((try? decoder.decode(APIErrorBody.self, from: data))?.error.message
                ?? (try? decoder.decode(DirectAPIErrorBody.self, from: data))?.message
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranslationServiceError(
                message: message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(service) returned HTTP \(http.statusCode)."
            )
        }
    }
}
