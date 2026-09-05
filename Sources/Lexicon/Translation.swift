import Foundation
import SwiftUI
import Translation

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

enum TranslationProvider: String, CaseIterable, Identifiable {
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
        switch self {
        case .openAI, .deepSeek, .gemini, .claude, .dashScope: return true
        case .apple, .googleCloud, .deepL, .disabled: return false
        }
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

enum DashScopeRegion: String, CaseIterable, Identifiable {
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

    private struct CompatibleChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream = false
    }

    private struct DashScopeRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream = false
        let temperature = 0.1
        let enableThinking = false

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

        var outputText: String {
            content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined()
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
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
        let ignoreTags: [String]?

        enum CodingKeys: String, CodingKey {
            case text, context
            case sourceLang = "source_lang"
            case targetLang = "target_lang"
            case tagHandling = "tag_handling"
            case tagHandlingVersion = "tag_handling_version"
            case ignoreTags = "ignore_tags"
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
        prompt: String,
        provider: TranslationProvider,
        apiKey: String,
        model: String,
        dashScopeModel: String,
        dashScopeRegion: DashScopeRegion,
        session: URLSession = .shared
    ) async throws -> String {
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
            return try await translateWithGoogle(prompt: prompt, apiKey: apiKey, session: session)
        case .deepL:
            return try await translateWithDeepL(prompt: prompt, apiKey: apiKey, session: session)
        case .openAI:
            return try await translateWithOpenAI(
                prompt: prompt, apiKey: apiKey, model: model, session: session
            )
        case .deepSeek:
            return try await translateWithCompatibleChat(
                prompt: prompt,
                apiKey: apiKey,
                model: model,
                endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                service: "DeepSeek",
                session: session
            )
        case .gemini:
            return try await translateWithCompatibleChat(
                prompt: prompt,
                apiKey: apiKey,
                model: model,
                endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
                service: "Gemini",
                session: session
            )
        case .claude:
            return try await translateWithClaude(
                prompt: prompt, apiKey: apiKey, model: model, session: session
            )
        case .dashScope:
            return try await translateWithDashScope(
                prompt: prompt,
                apiKey: apiKey,
                model: dashScopeModel,
                region: dashScopeRegion,
                session: session
            )
        }
    }

    /// Dedicated translation APIs should receive only the source passage;
    /// contextual LLM providers receive the complete dictionary prompt.
    /// OED/ODE place the source first, while Longman 6 places a Chinese
    /// instruction first and the source on the following lines.
    static func sourcePassage(from prompt: String) -> String {
        let lines = prompt.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        // Find the dictionary's instruction boundary instead of assuming the
        // source itself has no line breaks. Chinese repacks consistently use
        // “翻译”; the English-prefix check covers Lexicon's own test prompt.
        let instructionIndex = lines.firstIndex { line in
            let hasCJK = line.unicodeScalars.contains {
                (0x3400 ... 0x9FFF).contains($0.value)
            }
            return (hasCJK && line.contains("翻译"))
                || line.lowercased().hasPrefix("translate ")
        }
        if let instructionIndex {
            let sourceLines: ArraySlice<String>
            if instructionIndex == lines.startIndex {
                sourceLines = lines.dropFirst()
            } else {
                sourceLines = lines[..<instructionIndex]
            }
            let source = sourceLines.joined(separator: "\n")
            if !source.isEmpty { return source }
        }
        return lines[0]
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

    private static func translateWithGoogle(
        prompt: String,
        apiKey: String,
        session: URLSession
    ) async throws -> String {
        let source = sourcePassage(from: prompt)
        guard !source.isEmpty else {
            throw TranslationServiceError(message: "The dictionary supplied no text to translate.")
        }
        guard let url = URL(
            string: "https://translation.googleapis.com/language/translate/v2"
        ) else {
            throw TranslationServiceError(message: "Could not construct the Google request.")
        }

        let containsMarkup = source.range(
            of: #"<\/?[a-zA-Z][^>]*>"#,
            options: .regularExpression
        ) != nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Keep credentials out of the URL, where proxies and diagnostic logs
        // commonly record them. Google recommends this header for REST API
        // keys and Cloud Translation v2 accepts it.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(
            GoogleRequest(q: [source], format: containsMarkup ? "html" : "text")
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "Google Cloud Translation")
        guard let text = try JSONDecoder().decode(GoogleResponse.self, from: data)
            .data.translations.first?.translatedText,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TranslationServiceError(message: "Google Cloud returned an empty translation.")
        }
        return text
    }

    private static func translateWithDeepL(
        prompt: String,
        apiKey: String,
        session: URLSession
    ) async throws -> String {
        let source = sourcePassage(from: prompt)
        guard !source.isEmpty else {
            throw TranslationServiceError(message: "The dictionary supplied no text to translate.")
        }
        let containsMarkup = source.range(
            of: #"<\/?(?:m|n|o)>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        var request = URLRequest(url: deepLEndpoint(forAPIKey: apiKey))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(DeepLRequest(
            text: [source],
            context: prompt == source ? nil : prompt,
            tagHandling: containsMarkup ? "html" : nil,
            tagHandlingVersion: containsMarkup ? "v2" : nil,
            ignoreTags: containsMarkup ? ["n", "o"] : nil
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "DeepL")
        guard let text = try JSONDecoder().decode(DeepLResponse.self, from: data)
            .translations.first?.text,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TranslationServiceError(message: "DeepL returned an empty translation.")
        }
        return text
    }

    static func deepLEndpoint(forAPIKey apiKey: String) -> URL {
        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        return URL(string: "https://\(host)/v2/translate")!
    }

    private static func validatedModel(_ rawModel: String, service: String) throws -> String {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw TranslationServiceError(message: "Enter a \(service) model name in Settings.")
        }
        return model
    }

    private static func translateWithOpenAI(
        prompt: String,
        apiKey: String,
        model rawModel: String,
        session: URLSession
    ) async throws -> String {
        let model = try validatedModel(rawModel, service: "OpenAI")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(OpenAIRequest(model: model, input: prompt))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "OpenAI")
        let text = try JSONDecoder().decode(OpenAIResponse.self, from: data).outputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranslationServiceError(message: "OpenAI returned an empty translation.")
        }
        return text
    }

    private static func translateWithCompatibleChat(
        prompt: String,
        apiKey: String,
        model rawModel: String,
        endpoint: URL,
        service: String,
        session: URLSession
    ) async throws -> String {
        let model = try validatedModel(rawModel, service: service)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(CompatibleChatRequest(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: "Follow the dictionary translation request exactly. "
                        + "Return only the requested translation and preserve requested markup."
                ),
                .init(role: "user", content: prompt),
            ]
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: service)
        let text = try JSONDecoder().decode(ChatResponse.self, from: data)
            .choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw TranslationServiceError(message: "\(service) returned an empty translation.")
        }
        return text
    }

    private static func translateWithClaude(
        prompt: String,
        apiKey: String,
        model rawModel: String,
        session: URLSession
    ) async throws -> String {
        let model = try validatedModel(rawModel, service: "Claude")
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(ClaudeRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)]
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "Claude")
        let text = try JSONDecoder().decode(ClaudeResponse.self, from: data).outputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranslationServiceError(message: "Claude returned an empty translation.")
        }
        return text
    }

    private static func translateWithDashScope(
        prompt: String,
        apiKey: String,
        model: String,
        region: DashScopeRegion,
        session: URLSession
    ) async throws -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw TranslationServiceError(message: "Enter a DashScope model name in Settings.")
        }
        var request = URLRequest(url: region.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(DashScopeRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)]
        ))

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data, service: "DashScope")
        guard let text = try JSONDecoder().decode(ChatResponse.self, from: data)
            .choices.first?.message.content,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TranslationServiceError(message: "DashScope returned an empty translation.")
        }
        return text
    }

    private static func validate(response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranslationServiceError(message: "\(service) returned an invalid response.")
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let decoder = JSONDecoder()
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.error.message
                ?? (try? decoder.decode(DirectAPIErrorBody.self, from: data))?.message
            throw TranslationServiceError(
                message: message ?? "\(service) returned HTTP \(http.statusCode)."
            )
        }
    }
}

/// A value-only view of the next Apple request. The checked continuation stays
/// private to LibraryModel so SwiftUI can observe requests without owning them.
struct AppleTranslationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceText: String
}

/// Hosts Apple's TranslationSession in the SwiftUI hierarchy. LibraryModel
/// arbitrates claims, so multiple app windows can observe the same request but
/// only one session performs the work.
struct AppleTranslationHost: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: libraryModel.appleTranslationRequest, initial: true) { _, request in
                guard request != nil else { return }
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(languageCode: "en"),
                        target: Locale.Language(languageCode: "zh", script: "Hans")
                    )
                } else {
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { @Sendable session in
                guard let request = await MainActor.run(body: {
                    libraryModel.claimAppleTranslationRequest()
                }) else { return }

                let sourceLanguage = Locale.Language(languageCode: "en")
                let targetLanguage = Locale.Language(languageCode: "zh", script: "Hans")
                let availability = LanguageAvailability()
                let status = await availability.status(
                    from: sourceLanguage,
                    to: targetLanguage
                )

                guard status != .unsupported else {
                    await MainActor.run {
                        libraryModel.completeAppleTranslation(
                            id: request.id,
                            result: .failure(TranslationServiceError(
                                message: "Apple Translation does not support English to "
                                    + "Simplified Chinese with the translation models "
                                    + "available on this Mac. Choose DeepL, Google Cloud, "
                                    + "or Alibaba DashScope in Settings > Translation."
                            ))
                        )
                    }
                    return
                }

                do {
                    // This displays Apple's permission/download UI when the
                    // English → Simplified Chinese language pair is missing.
                    try await session.prepareTranslation()
                    let response = try await session.translate(request.sourceText)
                    let targetText = response.targetText
                    await MainActor.run {
                        libraryModel.completeAppleTranslation(
                            id: request.id,
                            result: .success(targetText)
                        )
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        libraryModel.completeAppleTranslation(
                            id: request.id,
                            result: .failure(TranslationServiceError(message: message))
                        )
                    }
                }
            }
    }
}
