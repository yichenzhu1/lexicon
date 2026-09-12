import AppKit
import Combine
import Foundation
import Translation

/// Preferences and the Settings test belong here. Each dictionary frame owns
/// its own translation task and presents its own result or error.
@MainActor
final class TranslationModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @MainActor
    struct Credentials {
        var read: (TranslationProvider) throws -> String?
        var save: (TranslationProvider, String) throws -> Void
        var remove: (TranslationProvider) throws -> Void

        static let keychain = Credentials(
            read: { try $0.keychain?.read() },
            save: { try $0.keychain?.save($1) },
            remove: { try $0.keychain?.remove() }
        )
    }

    @Published var provider: TranslationProvider {
        didSet {
            guard provider != oldValue else { return }
            cancelTest()
            settings.set(provider.rawValue, forKey: "translationProvider")
            rememberProvider()
            refreshCredentialState()
        }
    }

    @Published var dashScopeRegion: DashScopeRegion {
        didSet {
            guard dashScopeRegion != oldValue else { return }
            cancelTest()
            settings.set(dashScopeRegion.rawValue, forKey: "dashScopeRegion")
            let standardModels = DashScopeRegion.allCases.map(\.recommendedModel) + ["qwen-plus"]
            if standardModels.contains(model(for: .dashScope)) {
                setModel(dashScopeRegion.recommendedModel, for: .dashScope)
            }
        }
    }

    @Published private var models: [TranslationProvider: String]
    @Published private(set) var hasAPIKey = false
    @Published private(set) var status: Status = .idle
    @Published private(set) var appleAvailability: LanguageAvailability.Status?

    private let settings: UserDefaults
    private let apple: AppleTranslationService
    private let credentials: Credentials
    private let session: URLSession
    private var testTask: Task<Void, Never>?

    init(
        settings: UserDefaults,
        apple: AppleTranslationService = .system,
        credentials: Credentials = .keychain,
        session: URLSession = .shared
    ) {
        self.settings = settings
        self.apple = apple
        self.credentials = credentials
        self.session = session
        provider = settings.string(forKey: "translationProvider")
            .flatMap(TranslationProvider.init(rawValue:)) ?? .apple
        dashScopeRegion = settings.string(forKey: "dashScopeRegion")
            .flatMap(DashScopeRegion.init(rawValue:)) ?? .china
        models = Dictionary(uniqueKeysWithValues: TranslationProvider.providers(in: .languageModels)
            .compactMap { provider in
                settings.string(forKey: Self.modelKey(provider)).map { (provider, $0) }
            })
        rememberProvider()
        refreshCredentialState()
    }

    var selectedModel: String {
        get { model(for: provider) }
        set {
            guard newValue != selectedModel else { return }
            cancelTest()
            setModel(newValue, for: provider)
        }
    }

    func selectCategory(_ category: TranslationProviderCategory) {
        switch category {
        case .apple: provider = .apple
        case .disabled: provider = .disabled
        case .translationAPIs: provider = rememberedProvider(in: category, fallback: .googleCloud)
        case .languageModels: provider = rememberedProvider(in: category, fallback: .openAI)
        }
    }

    /// Capture all preferences and credentials before suspending. Editing
    /// Settings cannot change an already submitted dictionary request.
    func translate(_ rawPrompt: String) async throws -> String {
        try Task.checkCancellation()
        let input = try TranslationInput(rawPrompt)
        let configuration = TranslationConfiguration(
            provider: provider, model: selectedModel, dashScopeRegion: dashScopeRegion
        )
        if configuration.provider == .apple {
            let source = DictionaryTranslationService.plainSourcePassage(from: input.prompt)
            guard !source.isEmpty else {
                throw TranslationServiceError(message: "The dictionary supplied no text to translate.")
            }
            return try await apple.translate(source)
        }
        let key = configuration.provider.requiresAPIKey
            ? try credentials.read(configuration.provider) ?? "" : ""
        return try await DictionaryTranslationService.translate(
            input: input, configuration: configuration, apiKey: key, session: session
        )
    }

    func testTranslation() {
        cancelTest()
        status = .testing
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await translate(
                    "Translate the following English sentence into Simplified Chinese:\n"
                    + "The dictionary helps us understand how words are used."
                )
                try Task.checkCancellation()
                if provider == .apple { appleAvailability = .installed }
                status = .success(result)
            } catch {
                guard !Task.isCancelled else { return }
                if let setup = error as? AppleTranslationSetupError {
                    appleAvailability = setup == .languagesNotInstalled ? .supported : .unsupported
                }
                status = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .idle : .failure(error.localizedDescription)
            }
            testTask = nil
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        status = .idle
    }

    func saveAPIKey(_ rawValue: String) -> Bool {
        cancelTest()
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.requiresAPIKey, !value.isEmpty else {
            status = .failure("Enter an API key for the selected provider first.")
            return false
        }
        do {
            try credentials.save(provider, value)
            hasAPIKey = true
            status = .success("\(provider.title) API key saved in Keychain.")
            return true
        } catch {
            status = .failure("Could not save the API key: \(error.localizedDescription)")
            return false
        }
    }

    func removeAPIKey() {
        cancelTest()
        do {
            try credentials.remove(provider)
            hasAPIKey = false
            status = .success("\(provider.title) API key removed.")
        } catch {
            status = .failure("Could not remove the API key: \(error.localizedDescription)")
        }
    }

    func checkAppleLanguages() async {
        guard provider == .apple else { return }
        let availability = await apple.availability()
        guard !Task.isCancelled, provider == .apple else { return }
        appleAvailability = availability
    }

    func openLanguageSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation")!
        if !NSWorkspace.shared.open(url) {
            status = .failure("Could not open System Settings. " + AppleTranslationSetupError.downloadInstructions)
        }
    }

    func restoreDefaults() {
        cancelTest()
        provider = .apple
        dashScopeRegion = .china
        for provider in TranslationProvider.providers(in: .languageModels) {
            settings.removeObject(forKey: Self.modelKey(provider))
        }
        models = [:]
        settings.removeObject(forKey: "lastTranslationAPIProvider")
        settings.removeObject(forKey: "lastLanguageModelProvider")
    }

    private func refreshCredentialState() {
        guard provider.requiresAPIKey else {
            hasAPIKey = false
            return
        }
        do {
            hasAPIKey = try credentials.read(provider)?.isEmpty == false
        } catch {
            hasAPIKey = false
            status = .failure("Could not read the API key: \(error.localizedDescription)")
        }
    }

    private func model(for provider: TranslationProvider) -> String {
        models[provider] ?? (provider == .dashScope ? dashScopeRegion.recommendedModel : provider.recommendedModel ?? "")
    }

    private func setModel(_ model: String, for provider: TranslationProvider) {
        models[provider] = model
        settings.set(model, forKey: Self.modelKey(provider))
    }

    private static func modelKey(_ provider: TranslationProvider) -> String {
        provider == .dashScope ? "dashScopeModel" : "translationModel." + provider.rawValue
    }

    private func rememberProvider() {
        if let key = categoryKey(provider.category) {
            settings.set(provider.rawValue, forKey: key)
        }
    }

    private func rememberedProvider(
        in category: TranslationProviderCategory, fallback: TranslationProvider
    ) -> TranslationProvider {
        guard let key = categoryKey(category),
              let raw = settings.string(forKey: key),
              let saved = TranslationProvider(rawValue: raw), saved.category == category
        else { return fallback }
        return saved
    }

    private func categoryKey(_ category: TranslationProviderCategory) -> String? {
        switch category {
        case .translationAPIs: return "lastTranslationAPIProvider"
        case .languageModels: return "lastLanguageModelProvider"
        case .apple, .disabled: return nil
        }
    }
}
