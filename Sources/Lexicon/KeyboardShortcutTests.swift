import Foundation

@MainActor
enum KeyboardShortcutTests {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }
        expect(ShortcutBinding(key: "\u{f704}").title == "⌘F1", "F1 has no readable label")
        expect(ShortcutBinding(key: "\u{f70f}", modifiers: 6).title == "⌃⌥F12", "F12 label or modifier order is wrong")
        expect(ShortcutBinding(key: "\u{f703}", modifiers: 3).title == "⌥⌘→", "right arrow has no readable label")
        expect(ShortcutAction.importDictionaries.defaultBinding.displayParts == ["⇧", "⌘", "I"], "modifier display lost a key")
        var config = ShortcutConfiguration()
        for action in ShortcutAction.allCases {
            expect(config.validationMessage(action.defaultBinding, for: action) == nil, "invalid default for \(action)")
        }
        expect(!config.set(.init(key: "t"), for: .focusSearch), "duplicate accepted")
        expect(!config.set(.init(key: "q"), for: .focusSearch), "Quit was overridden")
        expect(!config.set(.init(key: "v"), for: .focusSearch), "Paste was overridden")
        expect(!config.set(.init(key: "k", modifiers: 0), for: .focusSearch), "plain typing intercepted")
        expect(!config.set(.init(key: "\r", modifiers: 0), for: .newWindow), "global Return accepted")
        expect(config.set(.init(key: "k", modifiers: 9), for: .focusSearch), "custom shortcut rejected")
        expect(config[.focusSearch] == .init(key: "k", modifiers: 9), "custom shortcut not active")
        expect(config.set(.init(key: "f"), for: .newTab), "freed shortcut unavailable")
        expect(config.validationMessage(ShortcutAction.focusSearch.defaultBinding, for: .focusSearch) != nil, "reset conflict ignored")
        expect(config.zoomAliasAvailable, "default zoom alias missing")
        expect(config.set(.init(key: "="), for: .newWindow), "zoom alias could not be reassigned")
        expect(!config.zoomAliasAvailable, "zoom alias steals custom shortcut")
        expect(ShortcutBinding.normalized("+", modifiers: 1) == ShortcutAction.zoomIn.defaultBinding, "plus normalization failed")
        expect(ShortcutBinding.normalized("K", modifiers: 9) == .init(key: "k", modifiers: 9), "case normalization failed")
        let name = "Lexicon.KeyboardShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try? JSONEncoder().encode(config), forKey: "keyboardShortcuts")
        expect(ShortcutConfiguration.load(from: defaults) == config, "configuration did not survive reload")
        defaults.set(Data("broken".utf8), forKey: "keyboardShortcuts")
        expect(ShortcutConfiguration.load(from: defaults).isDefault, "corrupt preferences did not recover")
        config = ShortcutConfiguration()
        expect(config.isDefault && config[.focusSearch] == ShortcutAction.focusSearch.defaultBinding, "restore failed")
        for failure in failures { print("SHORTCUT FAIL: \(failure)") }
        if failures.isEmpty { print("SHORTCUT OK: defaults, conflicts, reserved keys, reassignment, persistence, and restore") }
        return failures.isEmpty
    }
}
