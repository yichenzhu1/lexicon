import SwiftUI

/// A native multi-pane Settings window. macOS promotes the TabView items into
/// a stable preferences toolbar and restores the last pane the user visited.
struct SettingsView: View {
    private enum Pane: String {
        // Keep the old raw value so existing users land on General after the
        // Interface pane is renamed.
        case general = "interface"
        case content
        case translation
        case speech
        case hotkeys
    }

    @EnvironmentObject private var libraryModel: LibraryModel
    @AppStorage("selectedSettingsPane", store: LibraryModel.settings)
    private var selectedPane = Pane.general.rawValue
    @State private var googleAPIKey = ""
    @State private var translationAPIKey = ""
    @State private var showingRestoreConfirmation = false

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general.rawValue)

            contentPane
                .tabItem { Label("Content", systemImage: "book.closed") }
                .tag(Pane.content.rawValue)

            translationPane
                .tabItem { Label("Translation", systemImage: "character.bubble") }
                .tag(Pane.translation.rawValue)

            speechPane
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
                .tag(Pane.speech.rawValue)

            hotkeysPane
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(Pane.hotkeys.rawValue)
        }
        .frame(width: 620, height: 470)
        .confirmationDialog(
            "Restore All Settings?",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore All Settings", role: .destructive) {
                withAnimation(.smooth(duration: 0.2)) {
                    libraryModel.restoreDefaultSettings()
                    googleAPIKey = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("General, content, translation, speech, history, and folded-section preferences will return to their defaults. Your API keys, dictionaries, history, and starred words will be kept.")
        }
        .onChange(of: libraryModel.translationProvider) { _, _ in
            translationAPIKey = ""
        }
        .background {
            // Keeps Test Translation functional even when the Settings window
            // is the only visible app window.
            AppleTranslationHost()
                .environmentObject(libraryModel)
        }
    }

    private var generalPane: some View {
        settingsPage {
            Form {
                Section("Reading") {
                    LabeledContent("Entry text size") {
                        Picker("Entry text size", selection: entryZoom) {
                            ForEach(LibraryModel.zoomSteps, id: \.self) { zoom in
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .tag(zoom)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 120, alignment: .trailing)
                    }

                    Toggle(
                        "Look up words by double-clicking entry text",
                        isOn: $libraryModel.lookUpOnDoubleClick
                    )
                }

                Section("History") {
                    LabeledContent("Keep recent lookups") {
                        Picker("Keep recent lookups", selection: historyLimit) {
                            ForEach(LibraryModel.historyLimitOptions, id: \.self) { limit in
                                Text("\(limit) records").tag(limit)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 120, alignment: .trailing)
                    }

                    Text("New words are added at the top. Opening an existing item keeps it in place.")
                        .settingsNote()
                }

                Section("Defaults") {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Restore all settings")
                            Text("Resets preferences without deleting your dictionaries or saved lists.")
                                .settingsNote()
                        }
                        Spacer()
                        Button("Restore All Defaults…") {
                            showingRestoreConfirmation = true
                        }
                    }
                }
            }
        }
    }

    private var contentPane: some View {
        settingsPage {
            Form {
                Section("Dictionary Pages") {
                    Picker("Network access", selection: $libraryModel.dictionaryNetworkPolicy) {
                        ForEach(LibraryModel.DictionaryNetworkPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }

                    Text(libraryModel.dictionaryNetworkPolicy == .allowHTTPS
                        ? "Dictionary pages may load HTTPS images, fonts, styles, scripts, and data. Remote scripts can read the displayed entry. HTTP remains blocked."
                        : "All dictionary page resources must come from the imported dictionary files.")
                        .settingsNote()
                }

                Section("Privacy") {
                    Label("Imported dictionary files stay on this Mac.", systemImage: "internaldrive")
                    Text("Text leaves the app only when you select a cloud translation provider, select Google Cloud in the Speech pane, or allow a dictionary page to load HTTPS content. Apple Translation stays on-device.")
                        .settingsNote()
                }
            }
        }
    }

    private var translationPane: some View {
        settingsPage {
            Form {
                Section("Live Translation") {
                    Picker("Method", selection: translationCategoryBinding) {
                        ForEach(TranslationProviderCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }

                    let category = libraryModel.translationProvider.category
                    if category == .translationAPIs || category == .languageModels {
                        Picker(
                            category.providerPickerTitle,
                            selection: $libraryModel.translationProvider
                        ) {
                            ForEach(TranslationProvider.providers(in: category)) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                    }

                    if libraryModel.translationProvider == .disabled {
                        Text("Dictionary-provided network translation is intercepted and kept off. Bundled translations, such as OALD’s hidden Chinese examples, continue to work locally.")
                            .settingsNote()
                    } else {
                        Text(translationProviderDescription)
                            .settingsNote()
                    }
                }

                if libraryModel.translationProvider != .disabled {
                    Section(libraryModel.translationProvider.title) {
                        if libraryModel.translationProvider == .apple {
                            HStack {
                                Label("On-device translation", systemImage: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Test Translation") { libraryModel.testTranslation() }
                            }
                            Text("Apple may ask to download the English and Simplified Chinese language models the first time they are needed.")
                                .settingsNote()
                            Text("No API key is required, and dictionary text is processed on this Mac.")
                                .settingsNote()
                        } else {
                            if libraryModel.translationProvider == .dashScope {
                                Picker("Region", selection: $libraryModel.dashScopeRegion) {
                                    ForEach(DashScopeRegion.allCases) { region in
                                        Text(region.title).tag(region)
                                    }
                                }
                            }

                            if let model = translationModelBinding {
                                LabeledContent("Model") {
                                    TextField("", text: model)
                                        .labelsHidden()
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel(
                                            "\(libraryModel.translationProvider.title) model name"
                                        )
                                        .frame(width: 220)
                                }
                                Text(recommendedTranslationModelText)
                                    .settingsNote()
                            }

                            translationCredentialRow

                            HStack {
                                Label(
                                    libraryModel.hasTranslationAPIKey
                                        ? "Saved in Keychain" : "No key saved",
                                    systemImage: libraryModel.hasTranslationAPIKey
                                        ? "checkmark.circle.fill" : "key"
                                )
                                .foregroundStyle(
                                    libraryModel.hasTranslationAPIKey ? .green : .secondary
                                )
                                Spacer()
                                Button("Test Translation") { libraryModel.testTranslation() }
                                    .disabled(!libraryModel.hasTranslationAPIKey)
                            }

                            DisclosureGroup("Setup instructions") {
                                VStack(alignment: .leading, spacing: 6) {
                                    switch libraryModel.translationProvider {
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

                if let status = libraryModel.translationStatus {
                    Section("Status") {
                        Text(status).settingsNote()
                    }
                }
            }
        }
    }

    private var translationCredentialRow: some View {
        LabeledContent("API key") {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    SecureField("", text: $translationAPIKey)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Translation API key")

                    if translationAPIKey.isEmpty {
                        Text(libraryModel.hasTranslationAPIKey
                            ? "Replacement key" : "Paste API key")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 7)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: 220)

                Button("Save") {
                    if libraryModel.saveTranslationAPIKey(translationAPIKey) {
                        translationAPIKey = ""
                    }
                }
                .disabled(
                    translationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if libraryModel.hasTranslationAPIKey {
                    Button("Remove") { libraryModel.removeTranslationAPIKey() }
                }
            }
        }
    }

    private var translationProviderDescription: String {
        switch libraryModel.translationProvider {
        case .apple:
            return "Uses Apple’s Translation framework and the system’s preferred translation model. This is the default and keeps dictionary text on-device."
        case .disabled:
            return ""
        case .googleCloud:
            return "Translates the source passage with Google Cloud Translation. This is predictable and works well for ordinary modern examples."
        case .deepL:
            return "Translates the source passage with DeepL, preserving OED’s supported markup and using the remaining dictionary prompt as translation context."
        case .openAI:
            return "Sends the dictionary’s full contextual prompt to an OpenAI GPT model through the Responses API."
        case .deepSeek:
            return "Sends the dictionary’s full contextual prompt to a DeepSeek chat model."
        case .gemini:
            return "Sends the dictionary’s full contextual prompt to a Gemini model through Google’s OpenAI-compatible endpoint."
        case .claude:
            return "Sends the dictionary’s full contextual prompt to Claude through Anthropic’s Messages API."
        case .dashScope:
            return "Sends the dictionary’s complete contextual prompt to an OpenAI-compatible DashScope model. This best preserves OED and ODE’s definition-aware instructions and markup."
        }
    }

    private var translationCategoryBinding: Binding<TranslationProviderCategory> {
        Binding(
            get: { libraryModel.translationProvider.category },
            set: { libraryModel.selectTranslationCategory($0) }
        )
    }

    private var translationModelBinding: Binding<String>? {
        switch libraryModel.translationProvider {
        case .openAI: return $libraryModel.openAIModel
        case .deepSeek: return $libraryModel.deepSeekModel
        case .gemini: return $libraryModel.geminiModel
        case .claude: return $libraryModel.claudeModel
        case .dashScope: return $libraryModel.dashScopeModel
        case .apple, .googleCloud, .deepL, .disabled: return nil
        }
    }

    private var recommendedTranslationModelText: String {
        if libraryModel.translationProvider == .dashScope {
            return "Recommended for this region: \(libraryModel.dashScopeRegion.recommendedModel)"
        }
        return "Suggested model: \(libraryModel.translationProvider.recommendedModel ?? "")"
    }

    private var speechPane: some View {
        settingsPage {
            Form {
                Section("Text-to-Speech") {
                    Picker("Provider", selection: $libraryModel.ttsProvider) {
                        ForEach(TTSProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    if libraryModel.ttsProvider == .system {
                        systemVoicePicker(
                            title: "British English",
                            selection: $libraryModel.systemBritishVoiceIdentifier,
                            language: "en-GB"
                        )
                        systemVoicePicker(
                            title: "American English",
                            selection: $libraryModel.systemAmericanVoiceIdentifier,
                            language: "en-US"
                        )
                        Text("Uses voices installed on this Mac. Speech stays on the device and works when dictionary network access is off.")
                            .settingsNote()
                    } else {
                        Picker("British English", selection: $libraryModel.googleBritishVoice) {
                            ForEach(GoogleCloudTTS.voiceNames, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("American English", selection: $libraryModel.googleAmericanVoice) {
                            ForEach(GoogleCloudTTS.voiceNames, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                if libraryModel.ttsProvider == .googleCloud {
                    googleCloudSection
                }

                if let status = libraryModel.ttsStatus {
                    Section("Status") {
                        Text(status).settingsNote()
                    }
                }
            }
        }
    }

    private var googleCloudSection: some View {
        Section("Google Cloud") {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        SecureField("", text: $googleAPIKey)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Google Cloud API key")

                        if googleAPIKey.isEmpty {
                            Text(libraryModel.hasGoogleAPIKey
                                ? "Replacement key" : "Paste API key")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 7)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: 220)

                    Button("Save") {
                        if libraryModel.saveGoogleAPIKey(googleAPIKey) {
                            googleAPIKey = ""
                        }
                    }
                    .disabled(googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if libraryModel.hasGoogleAPIKey {
                        Button("Remove") { libraryModel.removeGoogleAPIKey() }
                    }
                }
            }

            HStack {
                Label(
                    libraryModel.hasGoogleAPIKey ? "Saved in Keychain" : "No key saved",
                    systemImage: libraryModel.hasGoogleAPIKey ? "checkmark.circle.fill" : "key"
                )
                .foregroundStyle(libraryModel.hasGoogleAPIKey ? .green : .secondary)
                Spacer()
                Button("Test Voice") { libraryModel.testTTS() }
                    .disabled(!libraryModel.hasGoogleAPIKey)
            }

            DisclosureGroup("Setup instructions") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Create or select a Google Cloud project and enable billing.")
                    Text("2. Enable the Cloud Text-to-Speech API.")
                    Text("3. Create an API key, restrict it to Cloud Text-to-Speech, then paste it above.")
                    HStack(spacing: 12) {
                        Link(
                            "Enable Text-to-Speech API",
                            destination: URL(string: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")!
                        )
                        Link(
                            "Open API credentials",
                            destination: URL(string: "https://console.cloud.google.com/apis/credentials")!
                        )
                    }
                }
                .settingsNote()
                .padding(.top, 4)
            }

            Text("Clicked dictionary text is sent directly from Lexicon to Google Cloud. Usage may incur charges; dictionary pages cannot access the saved key.")
                .settingsNote()
        }
    }

    private var hotkeysPane: some View {
        settingsPage {
            Form {
                Section("Search") {
                    shortcutRow("Focus the search field", shortcut: "⌘F")
                    shortcutRow("Clear search or leave the field", shortcut: "esc")
                    shortcutRow("Move through results", shortcut: "↑  ↓")
                    shortcutRow("Open the first result", shortcut: "↩")
                }

                Section("Navigation") {
                    shortcutRow("Go back", shortcut: "⌘[")
                    shortcutRow("Go forward", shortcut: "⌘]")
                    shortcutRow("New tab", shortcut: "⌘T")
                    shortcutRow("Close tab or window", shortcut: "⌘W")
                    shortcutRow("Switch tabs", shortcut: "⌘1–⌘9")
                }

                Section("App and View") {
                    shortcutRow("New window", shortcut: "⌘N")
                    shortcutRow("Import dictionaries", shortcut: "⇧⌘I")
                    shortcutRow("Zoom in / out", shortcut: "⌘+  ⌘−")
                    shortcutRow("Actual size", shortcut: "⌘0")
                    shortcutRow("Open Settings", shortcut: "⌘,")
                }
            }
        }
    }

    private func settingsPage<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entryZoom: Binding<Double> {
        Binding(
            get: { libraryModel.entryZoom },
            set: { libraryModel.setZoom($0) }
        )
    }

    private var historyLimit: Binding<Int> {
        Binding(
            get: { libraryModel.historyLimit },
            set: { libraryModel.setHistoryLimit($0) }
        )
    }

    @ViewBuilder
    private func systemVoicePicker(
        title: String, selection: Binding<String>, language: String
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(LibraryModel.systemVoices(language: language)) { voice in
                Text(voice.name).tag(voice.id)
            }
        }
    }

    private func shortcutRow(_ title: String, shortcut: String) -> some View {
        LabeledContent(title) {
            Text(shortcut)
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospaced()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }
}

private extension View {
    func settingsNote() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
