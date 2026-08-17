import SwiftUI

/// A native multi-pane Settings window. macOS promotes the TabView items into
/// a stable preferences toolbar and restores the last pane the user visited.
struct SettingsView: View {
    private enum Pane: String {
        // Keep the old raw value so existing users land on General after the
        // Interface pane is renamed.
        case general = "interface"
        case content
        case speech
        case hotkeys
    }

    @EnvironmentObject private var libraryModel: LibraryModel
    @AppStorage("selectedSettingsPane", store: LibraryModel.settings)
    private var selectedPane = Pane.general.rawValue
    @State private var googleAPIKey = ""
    @State private var showingRestoreConfirmation = false

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general.rawValue)

            contentPane
                .tabItem { Label("Content", systemImage: "book.closed") }
                .tag(Pane.content.rawValue)

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
            Text("General, content, speech, history, and folded-section preferences will return to their defaults. Your API key, dictionaries, history, and starred words will be kept.")
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
                    Text("Text leaves the app only when Google Cloud is selected in the Speech pane or a dictionary page is allowed to load HTTPS content.")
                        .settingsNote()
                }
            }
        }
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
