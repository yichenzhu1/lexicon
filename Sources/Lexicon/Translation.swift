import Foundation
import Security
import SwiftUI
import Translation

enum TranslationProvider: String, CaseIterable, Identifiable {
    case apple
    case googleCloud
    case deepL
    case dashScope
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Translation"
        case .disabled: return "Off"
        case .googleCloud: return "Google Cloud Translation"
        case .deepL: return "DeepL"
        case .dashScope: return "Alibaba DashScope"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .googleCloud, .deepL, .dashScope: return true
        case .apple, .disabled: return false
        }
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

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream = false
        let temperature = 0.1
        let enableThinking = false

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case enableThinking = "enable_thinking"
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
        var components = URLComponents(
            string: "https://translation.googleapis.com/language/translate/v2"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
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
        request.httpBody = try JSONEncoder().encode(ChatRequest(
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

enum TranslationKeychain {
    static func readAPIKey(for provider: TranslationProvider) throws -> String? {
        guard provider.requiresAPIKey else { return nil }
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw KeychainError(status: status) }
        return value
    }

    static func saveAPIKey(_ value: String, for provider: TranslationProvider) throws {
        guard provider.requiresAPIKey else { return }
        let data = Data(value.utf8)
        let query = baseQuery(for: provider)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func removeAPIKey(for provider: TranslationProvider) throws {
        guard provider.requiresAPIKey else { return }
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static func baseQuery(for provider: TranslationProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.yichenzhu.Lexicon.translation.\(provider.rawValue)",
            kSecAttrAccount as String: "api-key",
        ]
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
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
