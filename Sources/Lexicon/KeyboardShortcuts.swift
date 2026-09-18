import AppKit
import SwiftUI

/// Logical keys, rather than hardware key codes, follow the user's keyboard layout.
struct ShortcutBinding: Codable, Equatable {
    var key: String
    var modifiers: Int = 1 // command, option, control, shift

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers & 1 != 0 { result.insert(.command) }
        if modifiers & 2 != 0 { result.insert(.option) }
        if modifiers & 4 != 0 { result.insert(.control) }
        if modifiers & 8 != 0 { result.insert(.shift) }
        return result
    }
    var shortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key.first ?? " "), modifiers: eventModifiers)
    }
    var appKitModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { result.insert(.command) }
        if modifiers & 2 != 0 { result.insert(.option) }
        if modifiers & 4 != 0 { result.insert(.control) }
        if modifiers & 8 != 0 { result.insert(.shift) }
        return result
    }
    /// Separate display tokens let the Settings UI space modifier glyphs
    /// naturally without imposing monospaced letter widths.
    var displayParts: [String] {
        if key == "=", modifiers & 8 != 0 {
            return Self(key: "+", modifiers: modifiers & ~8).displayParts
        }
        var parts: [String] = []
        if modifiers & 4 != 0 { parts.append("⌃") }
        if modifiers & 2 != 0 { parts.append("⌥") }
        if modifiers & 8 != 0 { parts.append("⇧") }
        if modifiers & 1 != 0 { parts.append("⌘") }
        let names = [
            "\u{1b}": "⎋", "\r": "↩", "\u{3}": "⌤", "\t": "⇥",
            "\u{8}": "⌫", "\u{7f}": "⌫", "\u{f728}": "⌦",
            "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
            "\u{f729}": "↖", "\u{f72b}": "↘", "\u{f72c}": "⇞", "\u{f72d}": "⇟", " ": "Space",
        ]
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
           (0xf704...0xf726).contains(scalar.value) {
            parts.append("F\(scalar.value - 0xf704 + 1)")
        } else {
            parts.append(names[key] ?? key.uppercased())
        }
        return parts
    }
    var title: String { displayParts.joined() }
    static func flags(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.command) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.control) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }
    static func normalized(_ key: String, modifiers: Int) -> Self {
        // '+' and Shift-'=' represent the same shortcut on a US keyboard.
        if key == "+" { return Self(key: "=", modifiers: modifiers | 8) }
        return Self(key: key.lowercased(), modifiers: modifiers)
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case focusSearch, clearSearch, previousResult, nextResult, openResult
    case back, forward, newTab, closeTab, newWindow, importDictionaries, zoomIn, zoomOut, actualSize, settings
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, lastTab
    var id: String { rawValue }
    var isSearchAction: Bool { [.clearSearch, .previousResult, .nextResult, .openResult].contains(self) }
    static let tabActions: [Self] = [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab]
    var title: String {
        switch self {
        case .focusSearch: "Focus search"
        case .clearSearch: "Clear or leave search"
        case .previousResult: "Previous result"
        case .nextResult: "Next result"
        case .openResult: "Open selected result"
        case .back: "Go back"
        case .forward: "Go forward"
        case .newTab: "New tab"
        case .closeTab: "Close tab or window"
        case .newWindow: "New window"
        case .importDictionaries: "Import dictionaries"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .actualSize: "Actual size"
        case .settings: "Open Settings"
        case .lastTab: "Switch to last tab"
        default: "Switch to tab \(Self.tabActions.firstIndex(of: self)! + 1)"
        }
    }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .focusSearch: .init(key: "f")
        case .clearSearch: .init(key: "\u{1b}", modifiers: 0)
        case .previousResult: .init(key: "\u{f700}", modifiers: 0)
        case .nextResult: .init(key: "\u{f701}", modifiers: 0)
        case .openResult: .init(key: "\r", modifiers: 0)
        case .back: .init(key: "[")
        case .forward: .init(key: "]")
        case .newTab: .init(key: "t")
        case .closeTab: .init(key: "w")
        case .newWindow: .init(key: "n")
        case .importDictionaries: .init(key: "i", modifiers: 9)
        case .zoomIn: .init(key: "=", modifiers: 9)
        case .zoomOut: .init(key: "-")
        case .actualSize: .init(key: "0")
        case .settings: .init(key: ",")
        default: .init(key: String(Self.tabActions.firstIndex(of: self)! + 1))
        }
    }
}

struct ShortcutConfiguration: Codable, Equatable {
    private var overrides: [String: ShortcutBinding] = [:]
    subscript(_ action: ShortcutAction) -> ShortcutBinding { overrides[action.rawValue] ?? action.defaultBinding }
    var isDefault: Bool { overrides.isEmpty }
    var zoomAliasAvailable: Bool {
        self[.zoomIn] == ShortcutAction.zoomIn.defaultBinding && !ShortcutAction.allCases.contains {
            self[$0] == ShortcutBinding(key: "=")
        }
    }
    func validationMessage(_ binding: ShortcutBinding, for action: ShortcutAction) -> String? {
        guard binding.key.count == 1, binding.modifiers >= 0, binding.modifiers < 16 else { return "Choose a single key." }
        let navigationKeys = ["\u{1b}", "\r", "\u{f700}", "\u{f701}"]
        guard binding.modifiers & 7 != 0 || (action.isSearchAction && navigationKeys.contains(binding.key)) else {
            return "Include Command, Option, or Control."
        }
        // Preserve standard editing and application commands; the app must not
        // intercept Copy, Paste, Quit, Hide, Minimize, or keyboard focus traversal.
        let reserved: [ShortcutBinding] = ["q", "h", "m", "c", "v", "x", "a", "z"].map { .init(key: $0) }
            + [.init(key: "z", modifiers: 9), .init(key: "h", modifiers: 3), .init(key: "w", modifiers: 3), .init(key: "\t"), .init(key: " ")]
        if reserved.contains(binding) { return "This shortcut is used by macOS or text editing." }
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self[$0] == binding }) {
            return "Already used for “\(conflict.title)”. Choose another shortcut."
        }
        return nil
    }
    @discardableResult mutating func set(_ binding: ShortcutBinding, for action: ShortcutAction) -> Bool {
        guard validationMessage(binding, for: action) == nil else { return false }
        overrides[action.rawValue] = binding == action.defaultBinding ? nil : binding
        return true
    }
    static func load(from settings: UserDefaults) -> Self {
        guard let data = settings.data(forKey: "keyboardShortcuts"),
              let stored = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        // Validate against the complete saved map so swaps survive a relaunch.
        guard ShortcutAction.allCases.allSatisfy({ stored.validationMessage(stored[$0], for: $0) == nil }) else { return Self() }
        return stored
    }
}

/// SwiftUI supplies the standard Close item outside our command groups. Keep
/// its shortcut in sync too, so the old binding cannot close an entire window.
@MainActor
func updateNativeCloseShortcut(_ binding: ShortcutBinding) {
    func visit(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(NSWindow.performClose(_:)) {
                item.keyEquivalent = binding.key
                item.keyEquivalentModifierMask = binding.appKitModifiers
            }
            if let submenu = item.submenu { visit(submenu) }
        }
    }
    if let menu = NSApp.mainMenu { visit(menu) }
}

/// AppKit rebuilds its Close item as windows change. Route that one standard
/// command before menu dispatch so a stale system equivalent cannot win.
struct CloseShortcutBridge: NSViewRepresentable {
    var configuration: ShortcutConfiguration
    var close: () -> Void
    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.configuration = configuration
        view.close = close
        view.install()
        return view
    }
    func updateNSView(_ view: BridgeView, context: Context) {
        view.configuration = configuration
        view.close = close
    }
    static func dismantleNSView(_ view: BridgeView, coordinator: ()) { view.uninstall() }
    final class BridgeView: NSView {
        var configuration = ShortcutConfiguration()
        var close: (() -> Void)?
        private var monitor: Any?
        private var menuObserver: NSObjectProtocol?
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.window?.isKeyWindow == true, event.window === self.window,
                          !(self.window?.firstResponder is ShortcutRecordingView),
                          let key = event.charactersIgnoringModifiers else { return false }
                    let binding = ShortcutBinding.normalized(key, modifiers: ShortcutBinding.flags(event.modifierFlags))
                    if binding == self.configuration[.closeTab] {
                        self.close?()
                        return true
                    }
                    return binding == ShortcutAction.closeTab.defaultBinding
                        && !ShortcutAction.allCases.contains { self.configuration[$0] == binding }
                }
                return handled ? nil : event
            }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.isKeyWindow == true else { return }
                    updateNativeCloseShortcut(self.configuration[.closeTab])
                }
            }
        }
        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
            monitor = nil
            menuObserver = nil
        }
    }
}
