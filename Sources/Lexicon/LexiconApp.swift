import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            RenderSmokeTest.run() // never returns
        } else {
            LexiconApp.main()
        }
    }
}

struct LexiconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "dictionary") {
            LexiconWindowRoot()
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            LexiconCommands()
        }
    }
}

private struct LexiconWindowRoot: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedSceneValue(\.lexiconAppState, appState)
            .frame(minWidth: 760, minHeight: 480)
    }
}

private struct LexiconAppStateKey: FocusedValueKey {
    typealias Value = AppState
}

private extension FocusedValues {
    var lexiconAppState: AppState? {
        get { self[LexiconAppStateKey.self] }
        set { self[LexiconAppStateKey.self] = newValue }
    }
}

private struct LexiconCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.lexiconAppState) private var appState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "dictionary")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab") {
                appState?.openNewTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Dictionaries…") {
                appState?.showDictionaryManager = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(appState == nil)
        }
    }
}

/// Ensures the app behaves like a regular foreground app even when launched
/// from a bare executable (swift run) rather than an .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.titlebarSeparatorStyle = .none }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
