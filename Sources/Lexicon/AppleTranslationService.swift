import Foundation
import Translation

enum AppleTranslationSetupError: LocalizedError {
    case languagesNotInstalled
    case unsupported

    static let downloadInstructions = "Download English and Chinese (Mandarin, Simplified) "
        + "in System Settings > General > Language & Region > Translation Languages. "
        + "When both downloads finish, return to Lexicon and try translating again."

    var errorDescription: String? {
        switch self {
        case .languagesNotInstalled:
            return "Apple Translation needs English and Simplified Chinese language packs. "
                + Self.downloadInstructions
        case .unsupported:
            return "Apple Translation does not support English to Simplified Chinese "
                + "on this Mac. Choose another provider in Settings > Translation."
        }
    }
}

/// Never creates a download-capable session. The injectable operations keep
/// missing-language and cancellation tests independent of the Mac's downloads.
@MainActor
struct AppleTranslationService {
    var availability: @MainActor () async -> LanguageAvailability.Status
    var translateInstalled: @MainActor (String) async throws -> String

    static let system = AppleTranslationService(
        availability: {
            await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        },
        translateInstalled: { source in
            let session = TranslationSession(
                installedSource: sourceLanguage, target: targetLanguage
            )
            return try await session.translate(source).targetText
        }
    )

    private static let sourceLanguage = Locale.Language(languageCode: "en")
    private static let targetLanguage = Locale.Language(languageCode: "zh", script: "Hans")

    func translate(_ source: String) async throws -> String {
        try Task.checkCancellation()
        do {
            let result = try await translateInstalled(source)
            try Task.checkCancellation()
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationServiceError(message: "Apple Translation returned an empty translation.")
            }
            return result
        } catch TranslationError.notInstalled {
            // installedSource sessions report missing packs without downloading.
            try Task.checkCancellation()
            throw AppleTranslationSetupError.languagesNotInstalled
        } catch TranslationError.unsupportedLanguagePairing,
                TranslationError.unsupportedSourceLanguage,
                TranslationError.unsupportedTargetLanguage {
            try Task.checkCancellation()
            throw AppleTranslationSetupError.unsupported
        } catch TranslationError.alreadyCancelled {
            throw CancellationError()
        }
    }
}
