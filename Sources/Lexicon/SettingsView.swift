import SwiftUI

/// Native preference tabs with one width and a content-driven height.
struct SettingsView: View {
    private enum Pane: String {
        case general = "interface" // Preserve the previously selected pane.
        case appearance, content, translation, speech, hotkeys
    }

    @EnvironmentObject private var libraryModel: LibraryModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("selectedSettingsPane", store: LibraryModel.settings)
    private var selectedPane = Pane.general.rawValue
    @ViewState private var paneHeights: [String: CGFloat] = [:]
    @ViewState private var googleAPIKey = ""
    @ViewState private var showingRestoreSheet = false

    var body: some View {
        TabView(selection: $selectedPane) {
            generalPane
                .settingsPane(Pane.general.rawValue)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Pane.general.rawValue)
            appearancePane
                .settingsPane(Pane.appearance.rawValue)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(Pane.appearance.rawValue)
            contentPane
                .settingsPane(Pane.content.rawValue)
                .tabItem { Label("Content", systemImage: "book.closed") }
                .tag(Pane.content.rawValue)
            TranslationSettingsView(model: libraryModel.translation)
                .settingsPane(Pane.translation.rawValue)
                .tabItem { Label("Translation", systemImage: "character.bubble") }
                .tag(Pane.translation.rawValue)
            speechPane
                .settingsPane(Pane.speech.rawValue)
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
                .tag(Pane.speech.rawValue)
            hotkeysPane
                .settingsPane(Pane.hotkeys.rawValue)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(Pane.hotkeys.rawValue)
        }
        .frame(width: SettingsLayout.paneWidth, height: paneHeight)
        .onPreferenceChange(SettingsPaneHeightKey.self) { heights in
            paneHeights.merge(heights, uniquingKeysWith: { _, new in new })
        }
        .background {
            SettingsWindowChrome()
            CloseShortcutBridge(configuration: libraryModel.shortcuts) { NSApp.keyWindow?.performClose(nil) }
        }
        .sheet(isPresented: $showingRestoreSheet) {
            RestoreSettingsSheet(model: libraryModel) { selection in
                libraryModel.restoreDefaultSettings(selection)
                if selection.contains(.speech) { googleAPIKey = "" }
            }
        }
    }

    private var paneHeight: CGFloat {
        let measured = paneHeights[selectedPane] ?? 300
        // Keep long error details and expanded help usable on smaller screens.
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 140
        return min(measured, max(220, availableHeight))
    }

    private var generalPane: some View {
        SettingsPage {
            SettingsRow("Entry text size") {
                Picker("Entry text size", selection: entryZoom) {
                    ForEach(LibraryModel.zoomSteps, id: \.self) { zoom in
                        Text("\(Int((zoom * 100).rounded()))%").tag(zoom)
                    }
                }.labelsHidden()
            }
            SettingsRow {
                Toggle("Look up words by double-clicking entry text", isOn: $libraryModel.lookUpOnDoubleClick)
            }
            SettingsDivider()
            SettingsRow("History") {
                Picker("Keep recent lookups", selection: historyLimit) {
                    ForEach(LibraryModel.historyLimitOptions, id: \.self) { limit in
                        Text("\(limit) recent lookups").tag(limit)
                    }
                }.labelsHidden()
            }
            SettingsNote("New words appear at the top. Reopening a word keeps its place.")
            SettingsDivider()
            SettingsRow { Button("Restore Defaults…") { showingRestoreSheet = true } }
            SettingsNote("Choose which settings to reset.")
        }
    }

    private var appearancePane: some View {
        SettingsPage {
            SettingsRow("Appearance") {
                Picker("Appearance", selection: $libraryModel.appAppearance) {
                    ForEach(LibraryModel.AppAppearance.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            SettingsNote("System follows your Mac’s appearance. Applies to all Lexicon windows.")
            SettingsDivider()
            SettingsRow("Sidebar") {
                Toggle("Translucent sidebar", isOn: $libraryModel.translucentSidebar)
            }
            SettingsNote(reduceTransparency
                ? "Reduce Transparency is enabled in macOS. Your preference is kept while the sidebar uses a solid background."
                : "Let colors behind the window show through the sidebar.")
        }
    }

    private var contentPane: some View {
        SettingsPage {
            SettingsRow("Dictionary pages") {
                Picker("Network access", selection: $libraryModel.dictionaryNetworkPolicy) {
                    ForEach(LibraryModel.DictionaryNetworkPolicy.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            SettingsNote(libraryModel.dictionaryNetworkPolicy == .allowHTTPS
                ? "Pages may load HTTPS images, fonts, styles, scripts, and data. Remote scripts can read the displayed entry. HTTP is blocked."
                : "All page resources must come from imported dictionary files.")
            SettingsDivider()
            SettingsRow("Privacy") { Text("Imported dictionaries stay on this Mac.") }
            SettingsNote("Text is sent online when you use cloud translation, Google Cloud speech, or allow HTTPS page content. Apple Translation stays on this Mac.")
        }
    }

    private var speechPane: some View {
        SettingsPage {
            SettingsRow("Speech provider") {
                Picker("Speech provider", selection: $libraryModel.ttsProvider) {
                    ForEach(TTSProvider.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            SettingsRow("British English") {
                if libraryModel.ttsProvider == .system {
                    systemVoicePicker("British English", selection: $libraryModel.systemBritishVoiceIdentifier, language: "en-GB")
                } else {
                    Picker("British English", selection: $libraryModel.googleBritishVoice) {
                        ForEach(GoogleCloudTTS.voiceNames, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            }
            SettingsRow("American English") {
                if libraryModel.ttsProvider == .system {
                    systemVoicePicker("American English", selection: $libraryModel.systemAmericanVoiceIdentifier, language: "en-US")
                } else {
                    Picker("American English", selection: $libraryModel.googleAmericanVoice) {
                        ForEach(GoogleCloudTTS.voiceNames, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            }
            if libraryModel.ttsProvider == .system {
                SettingsNote("Uses voices installed on this Mac. Speech stays on the device and works offline.")
            } else {
                googleCloudSection
            }
            if let status = libraryModel.ttsStatus { SettingsNote(status) }
        }
    }

    @ViewBuilder private var googleCloudSection: some View {
        SettingsDivider()
        APIKeyRow(draft: $googleAPIKey, hasSavedKey: libraryModel.hasGoogleAPIKey,
                  fieldLabel: "Google Cloud API key", save: libraryModel.saveGoogleAPIKey,
                  remove: libraryModel.removeGoogleAPIKey)
        SettingsRow {
            HStack {
                Text(libraryModel.hasGoogleAPIKey ? "Saved in Keychain" : "No key saved").settingsNote()
                Spacer()
                Button("Test Voice") { libraryModel.testTTS() }.disabled(!libraryModel.hasGoogleAPIKey)
            }
        }
        SettingsRow {
            DisclosureGroup("Setup instructions") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enable billing and the Cloud Text-to-Speech API in a Google Cloud project. Create an API key restricted to Text-to-Speech and paste it above.")
                    Link("Enable Text-to-Speech API", destination: URL(string: "https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")!)
                    Link("Open API credentials", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }.settingsNote().padding(.top, 4)
            }
        }
        SettingsNote("Clicked text is sent to Google Cloud. Usage may incur charges. Dictionary pages cannot access your API key.")
    }

    private var hotkeysPane: some View {
        ShortcutSettingsView()
    }

    private var entryZoom: Binding<Double> {
        Binding(get: { libraryModel.entryZoom }, set: { libraryModel.setZoom($0) })
    }
    private var historyLimit: Binding<Int> {
        Binding(get: { libraryModel.historyLimit }, set: { libraryModel.setHistoryLimit($0) })
    }
    private func systemVoicePicker(_ title: String, selection: Binding<String>, language: String) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(LibraryModel.systemVoices(language: language)) { Text($0.name).tag($0.id) }
        }.labelsHidden()
    }
}
