import SwiftUI

struct TranslationSettingsView: View {
    @ObservedObject var model: TranslationModel
    @ViewState private var translationAPIKey = ""
    @ViewState private var activation = 0

    private struct HealthCheck: Equatable {
        let provider: TranslationProvider
        let model: String
        let region: DashScopeRegion
        let credentialRevision: Int
        let activation: Int
    }

    var body: some View {
        SettingsPage {
            SettingsRow("Translate using") {
                Picker("Translate using", selection: translationCategoryBinding) {
                    ForEach(TranslationProviderCategory.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            if model.provider.category == .translationAPIs || model.provider.category == .languageModels {
                SettingsRow("Provider") {
                    Picker("Provider", selection: $model.provider) {
                        ForEach(TranslationProvider.providers(in: model.provider.category)) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
            }
            SettingsNote(translationProviderDescription)

            if model.provider == .apple {
                SettingsDivider()
                healthStatus
                if model.appleAvailability == .supported {
                    SettingsNote("Download English and Chinese (Mandarin, Simplified) in System Settings > General > Language & Region > Translation Languages.")
                }
                SettingsRow {
                    Button("Manage Translation Languages…", action: model.openLanguageSettings)
                }
            } else if model.provider.requiresAPIKey {
                SettingsDivider()
                if model.provider == .dashScope {
                    SettingsRow("Region") {
                        Picker("Region", selection: $model.dashScopeRegion) {
                            ForEach(DashScopeRegion.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                }
                if model.provider.isGeneralLanguageModel {
                    SettingsRow("Model") {
                        TextField("Model name", text: $model.selectedModel)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(model.provider.title) model name")
                    }
                    SettingsNote("Suggested: \(model.provider == .dashScope ? model.dashScopeRegion.recommendedModel : model.provider.recommendedModel ?? "")")
                }
                APIKeyRow(draft: $translationAPIKey, hasSavedKey: model.hasAPIKey,
                          fieldLabel: "Translation API key", save: model.saveAPIKey, remove: model.removeAPIKey)
                healthStatus
                SettingsRow {
                    DisclosureGroup("Setup instructions") {
                        VStack(alignment: .leading, spacing: 6) {
                            switch model.provider {
                            case .googleCloud:
                                Text("1. Enable billing and the Cloud Translation API in a Google Cloud project.")
                                Text("2. Create an API key restricted to Cloud Translation, then paste it above.")
                                HStack(spacing: 12) {
                                    Link(
                                        "Enable Cloud Translation API",
                                        destination: URL(string: "https://console.cloud.google.com/apis/library/translate.googleapis.com")!
                                    )
                                    Link(
                                        "Open API credentials",
                                        destination: URL(string: "https://console.cloud.google.com/apis/credentials")!
                                    )
                                }
                            case .deepL:
                                Text("1. Create a DeepL API Free or API Pro account and copy its authentication key.")
                                Text("2. Paste the key above. Free keys ending in :fx automatically use the Free endpoint.")
                                Link(
                                    "Open DeepL API keys",
                                    destination: URL(string: "https://www.deepl.com/your-account/keys")!
                                )
                            case .openAI:
                                Text("1. Create an OpenAI API key. ChatGPT subscriptions do not include API usage.")
                                Text("2. Enter a Responses API-compatible model name and paste the key above.")
                                Link(
                                    "Open OpenAI API keys",
                                    destination: URL(string: "https://platform.openai.com/api-keys")!
                                )
                            case .deepSeek:
                                Text("1. Create a DeepSeek API key and add API credit if required.")
                                Text("2. Enter an available chat model name and paste the key above.")
                                Link(
                                    "Open DeepSeek API keys",
                                    destination: URL(string: "https://platform.deepseek.com/api_keys")!
                                )
                            case .gemini:
                                Text("1. Create a Gemini API key in Google AI Studio.")
                                Text("2. Enter an OpenAI-compatible Gemini model name and paste the key above.")
                                Link(
                                    "Open Google AI Studio API keys",
                                    destination: URL(string: "https://aistudio.google.com/apikey")!
                                )
                            case .claude:
                                Text("1. Create an API key in the Claude Console.")
                                Text("2. Enter a Claude Messages API model name and paste the key above.")
                                Link(
                                    "Open Claude API keys",
                                    destination: URL(string: "https://platform.claude.com/settings/keys")!
                                )
                            case .dashScope:
                                Text("1. Create a Model Studio API key for the selected region.")
                                Text("2. Enter a supported OpenAI-compatible model name, then paste the key above.")
                                Link(
                                    "DashScope API-key guide",
                                    destination: URL(string: "https://www.alibabacloud.com/help/en/model-studio/get-api-key")!
                                )
                            case .apple, .disabled:
                                EmptyView()
                            }
                        }.settingsNote().padding(.top, 4)
                    }
                }
                SettingsNote("Translates into Simplified Chinese. Selected text and its dictionary context go directly to this provider. A short sample checks the connection automatically; API usage may incur charges. Keys are stored in Keychain.")
            }
        }
        .task(id: HealthCheck(provider: model.provider, model: model.selectedModel,
                              region: model.dashScopeRegion, credentialRevision: model.credentialRevision,
                              activation: model.provider == .apple ? activation : 0)) {
            // Debounce model edits before sending a single small health check.
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            await model.checkHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activation += 1
        }
        .onChange(of: model.provider) { _, _ in translationAPIKey = "" }
        .onDisappear { model.cancelTest() }
    }

    @ViewBuilder private var healthStatus: some View {
        SettingsRow("Status") {
            HStack(spacing: 6) {
                switch model.status {
                case .testing:
                    ProgressView().controlSize(.mini)
                    Text("Checking translation…").foregroundStyle(.secondary)
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Working normally")
                case .failure:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(model.appleAvailability == .supported && model.provider == .apple
                         ? "Language packs needed" : "Needs attention")
                case .idle, .success:
                    Text(model.provider.requiresAPIKey && !model.hasAPIKey
                         ? "Add an API key to connect" : "Waiting to check…")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if case .failure(let message) = model.status,
           !(model.provider == .apple && model.appleAvailability == .supported) {
            SettingsRow { Text(message).settingsNote().textSelection(.enabled) }
        }
    }

    private var translationProviderDescription: String {
        switch model.provider {
        case .apple: return "English to Simplified Chinese, on this Mac. No account or API key needed."
        case .disabled: return "Live translation is off. Translations included with your dictionaries still work."
        case .googleCloud: return "Translates passages with Google Cloud Translation."
        case .deepL: return "Translates passages with DeepL, preserving supported markup and dictionary context."
        case .openAI, .deepSeek, .gemini, .claude, .dashScope:
            return "Uses the selected model to translate with the dictionary’s context and instructions."
        }
    }

    private var translationCategoryBinding: Binding<TranslationProviderCategory> {
        Binding(get: { model.provider.category }, set: { model.selectCategory($0) })
    }
}
