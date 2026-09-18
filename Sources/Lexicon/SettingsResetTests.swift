import Foundation

/// Uses disposable preferences and sidecar files; never modifies real history
/// or writes to Keychain. Covers partial restores and their persistence.
@MainActor
enum SettingsResetTests {
    static func run() -> Bool {
        let suiteName = "Lexicon.SettingsResetTests.\(UUID().uuidString)"
        guard setenv("LEXICON_SETTINGS_SUITE", suiteName, 1) == 0,
              let settings = UserDefaults(suiteName: suiteName) else { return false }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer {
            settings.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        let choices: [Set<SettingsResetSection>] = [[], Set(SettingsResetSection.allCases)]
            + SettingsResetSection.allCases.map { [$0] }
        let originalHistory = (0..<125).map { "word\($0)" }
        let stars = ["saved-word"]

        do {
            for (index, selection) in choices.enumerated() {
                settings.setPersistentDomain([
                    "entryZoom": 1.5, "lookUpOnDoubleClick": false,
                    "historyLimit": 200, "appAppearance": "dark", "translucentSidebar": false,
                    "dictionaryNetworkPolicy": "offlineOnly", "collapsedDictionaries": ["test-dictionary"],
                    "translationProvider": "disabled", "dashScopeRegion": "unitedStates",
                    "translationModel.openAI": "custom-model", "dashScopeModel": "custom-qwen",
                    "lastTranslationAPIProvider": "deepL", "lastLanguageModelProvider": "openAI",
                    "ttsProvider": "googleCloud", "systemBritishVoice": "custom-british",
                    "systemAmericanVoice": "custom-american", "googleBritishVoice": "Achernar",
                    "googleAmericanVoice": "Achernar",
                ], forName: suiteName)
                let fixtureRoot = root.appendingPathComponent("case-\(index)")
                try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
                try JSONEncoder().encode(originalHistory).write(to: fixtureRoot.appendingPathComponent("history.json"))
                try JSONEncoder().encode(stars).write(to: fixtureRoot.appendingPathComponent("starred.json"))
                let model = LibraryModel(rootURL: fixtureRoot)
                let customShortcut = ShortcutBinding(key: "f", modifiers: 9)
                model.shortcuts.set(customShortcut, for: .focusSearch)
                let hadSpeechKey = model.hasGoogleAPIKey
                model.restoreDefaultSettings(selection)

                // A second instance verifies values survived a fresh load, not
                // just that the controls' in-memory values changed.
                let reloaded = LibraryModel(rootURL: fixtureRoot)
                for candidate in [model, reloaded] {
                    let prefix = "selection \(index): "
                    expect(candidate.shortcuts[.focusSearch] == (selection.contains(.shortcuts) ? ShortcutAction.focusSearch.defaultBinding : customShortcut), prefix + "wrong shortcut")
                    expect(candidate.entryZoom == (selection.contains(.reading) ? 1 : 1.5), prefix + "wrong text size")
                    expect(candidate.lookUpOnDoubleClick == selection.contains(.reading), prefix + "wrong lookup behavior")
                    expect(candidate.appAppearance == (selection.contains(.appearance) ? .system : .dark), prefix + "wrong theme")
                    expect(candidate.translucentSidebar == selection.contains(.appearance), prefix + "wrong sidebar transparency")
                    expect(candidate.dictionaryNetworkPolicy == (selection.contains(.content) ? .allowHTTPS : .offlineOnly), prefix + "wrong network access")
                    expect(candidate.collapsedDictionaries == (selection.contains(.content) ? [] : ["test-dictionary"]), prefix + "wrong collapsed sections")
                    expect(candidate.historyLimit == (selection.contains(.history) ? 100 : 200), prefix + "wrong history limit")
                    expect(candidate.history == (selection.contains(.history) ? Array(originalHistory.prefix(100)) : originalHistory), prefix + "wrong history entries removed")
                    expect(candidate.starred == stars, prefix + "starred words changed")
                    expect(candidate.translation.provider == (selection.contains(.translation) ? .apple : .disabled), prefix + "wrong translation provider")
                    expect(candidate.translation.dashScopeRegion == (selection.contains(.translation) ? .china : .unitedStates), prefix + "wrong translation region")
                    expect(candidate.ttsProvider == (selection.contains(.speech) ? .system : .googleCloud), prefix + "wrong speech provider")
                    expect(candidate.systemBritishVoiceIdentifier == (selection.contains(.speech) ? "" : "custom-british"), prefix + "wrong British system voice")
                    expect(candidate.systemAmericanVoiceIdentifier == (selection.contains(.speech) ? "" : "custom-american"), prefix + "wrong American system voice")
                    expect(candidate.googleBritishVoice == (selection.contains(.speech) ? "Algieba" : "Achernar"), prefix + "wrong British cloud voice")
                    expect(candidate.googleAmericanVoice == (selection.contains(.speech) ? "Algieba" : "Achernar"), prefix + "wrong American cloud voice")
                    expect(candidate.hasGoogleAPIKey == hadSpeechKey, prefix + "speech credential state changed")
                }
                expect(settings.string(forKey: "translationModel.openAI") == (selection.contains(.translation) ? nil : "custom-model"), "custom model reset outside selection \(index)")
                expect(settings.string(forKey: "dashScopeModel") == (selection.contains(.translation) ? nil : "custom-qwen"), "regional model reset outside selection \(index)")
                expect(settings.string(forKey: "lastLanguageModelProvider") == (selection.contains(.translation) ? nil : "openAI"), "provider memory reset outside selection \(index)")
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        for failure in failures { print("SETTINGS RESET FAIL: \(failure)") }
        if failures.isEmpty { print("SETTINGS RESET OK: 9 selections, persistence, history trimming, and saved data preservation") }
        return failures.isEmpty
    }
}
