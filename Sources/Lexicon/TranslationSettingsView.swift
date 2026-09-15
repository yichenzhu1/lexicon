import SwiftUI

struct TranslationSettingsView: View {
    @ObservedObject var model: TranslationModel
    @ViewState private var translationAPIKey = ""
    @ViewState private var activation = 0

    private struct LanguageCheck: Equatable {
        let provider: TranslationProvider
        let activation: Int
    }

    var body: some View {
        Form {
            Section("Live Translation") {
                Picker("Method", selection: translationCategoryBinding) {
                    ForEach(TranslationProviderCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }

                let category = model.provider.category
                if category == .translationAPIs || category == .languageModels {
                    Picker(
                        category.providerPickerTitle,
                        selection: $model.provider
                    ) {
                        ForEach(TranslationProvider.providers(in: category)) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                }

                if model.provider == .disabled {
                    Text("Dictionary-provided network translation is intercepted and kept off. Bundled translations, such as OALD’s hidden Chinese examples, continue to work locally.")
                        .settingsNote()
                } else {
                    Text(translationProviderDescription)
                        .settingsNote()
                }
            }

            if model.provider != .disabled {
                Section(model.provider.title) {
                    if model.provider == .apple {
                        HStack {
                            Label(appleTranslationStatus, systemImage: "character.bubble")
                                .foregroundStyle(.secondary)
                            Spacer()
                            testButton
                        }
                        Button("Manage Translation Languages…") {
                            model.openLanguageSettings()
                        }
                        Text(AppleTranslationSetupError.downloadInstructions)
                            .settingsNote()
                        Text("No API key is required, and dictionary text is processed on this Mac.")
                            .settingsNote()
                    } else {
                        if model.provider == .dashScope {
                            Picker("Region", selection: $model.dashScopeRegion) {
                                ForEach(DashScopeRegion.allCases) { region in
                                    Text(region.title).tag(region)
                                }
                            }
                        }

                        if model.provider.isGeneralLanguageModel {
                            LabeledContent("Model") {
                                TextField("", text: $model.selectedModel)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(
                                        "\(model.provider.title) model name"
                                    )
                                    .frame(width: 220)
                            }
                            Text(recommendedTranslationModelText)
                                .settingsNote()
                        }

                        APIKeyRow(
                            draft: $translationAPIKey,
                            hasSavedKey: model.hasAPIKey,
                            fieldLabel: "Translation API key",
                            save: model.saveAPIKey,
                            remove: model.removeAPIKey
                        )

                        HStack {
                            Label(
                                model.hasAPIKey
                                    ? "Saved in Keychain" : "No key saved",
                                systemImage: model.hasAPIKey
                                    ? "checkmark.circle.fill" : "key"
                            )
                            .foregroundStyle(
                                model.hasAPIKey ? .green : .secondary
                            )
                            Spacer()
                            testButton
                        }

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
                            }
                            .settingsNote()
                            .padding(.top, 4)
                        }

                        Text("Only the translation prompt triggered by a passage you click is sent directly from Lexicon to the selected provider. Dictionary pages cannot read the saved key. Output is Simplified Chinese.")
                            .settingsNote()
                    }
                }
            }

            switch model.status {
            case .idle, .testing:
                EmptyView()
            case .success(let message):
                Section("Status") { Text(message).settingsNote().textSelection(.enabled) }
            case .failure(let message):
                Section("Status") {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: LanguageCheck(provider: model.provider, activation: activation)) {
            await model.checkAppleLanguages()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activation += 1
        }
        .onChange(of: model.provider) { _, _ in translationAPIKey = "" }
    }

    private var appleTranslationStatus: String {
        switch model.appleAvailability {
        case .installed: return "Ready for on-device translation"
        case .supported: return "Language packs needed"
        case .unsupported: return "Language pair unavailable on this Mac"
        case nil: return "Checking language packs…"
        @unknown default: return "Language pair unavailable on this Mac"
        }
    }

    private var translationProviderDescription: String {
        switch model.provider {
        case .apple:
            return "Translates on this Mac using Apple’s preferred translation model. No account or API key is needed."
        case .disabled:
            return ""
        case .googleCloud:
            return "Translates the source passage with Google Cloud Translation. This is predictable and works well for ordinary modern examples."
        case .deepL:
            return "Translates the source passage with DeepL, preserving OED’s supported markup and using the remaining dictionary prompt as translation context."
        case .openAI:
            return "Sends the dictionary’s full contextual prompt to your selected OpenAI model."
        case .deepSeek:
            return "Sends the dictionary’s full contextual prompt to a DeepSeek chat model."
        case .gemini:
            return "Sends the dictionary’s full contextual prompt to your selected Gemini model."
        case .claude:
            return "Sends the dictionary’s full contextual prompt to your selected Claude model."
        case .dashScope:
            return "Sends the dictionary’s complete contextual prompt to your selected DashScope model, including definition-aware instructions and markup."
        }
    }

    private var translationCategoryBinding: Binding<TranslationProviderCategory> {
        Binding(
            get: { model.provider.category },
            set: { model.selectCategory($0) }
        )
    }

    private var recommendedTranslationModelText: String {
        if model.provider == .dashScope {
            return "Recommended for this region: \(model.dashScopeRegion.recommendedModel)"
        }
        return "Suggested model: \(model.provider.recommendedModel ?? "")"
    }

    @ViewBuilder
    private var testButton: some View {
        if model.status == .testing {
            ProgressView().controlSize(.small)
            Button("Cancel", action: model.cancelTest)
        } else {
            Button("Test Translation", action: model.testTranslation)
                .disabled(model.provider.requiresAPIKey && !model.hasAPIKey)
        }
    }
}
