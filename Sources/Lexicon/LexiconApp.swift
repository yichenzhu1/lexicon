import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--tab-state-test") {
            exit(TabStateTests.run() ? 0 : 1)
        } else if CommandLine.arguments.contains("--tab-webview-test") {
            TabWebViewSmokeTest.run() // never returns
        } else if CommandLine.arguments.contains("--smoke-test") {
            RenderSmokeTest.run() // never returns
        } else {
            LexiconApp.main()
        }
    }
}

struct LexiconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// One library for the whole app; every window shares it.
    @StateObject private var libraryModel = LibraryModel()

    var body: some Scene {
        WindowGroup(id: "dictionary") {
            LexiconWindowRoot(libraryModel: libraryModel)
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.hiddenTitleBar)
        // The custom chrome extends through the hidden title bar. Automatic
        // background dragging makes controls in that area move the window
        // when a click turns into a drag, so only explicit blank regions in
        // ContentView can move the window instead.
        .windowBackgroundDragBehavior(.disabled)
        .commands {
            LexiconCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(libraryModel)
        }
    }
}

private struct LexiconWindowRoot: View {
    private let libraryModel: LibraryModel
    /// Search field, results and tabs are per window.
    @StateObject private var appState: AppState

    init(libraryModel: LibraryModel) {
        self.libraryModel = libraryModel
        _appState = StateObject(wrappedValue: AppState(libraryModel: libraryModel))
    }

    var body: some View {
        ContentView()
            .environmentObject(libraryModel)
            .environmentObject(appState)
            .focusedSceneValue(\.lexiconAppState, appState)
            .frame(minWidth: 760, minHeight: 480)
            .background {
                AppleTranslationHost()
                    .environmentObject(libraryModel)
            }
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

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { appState?.libraryModel.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState?.libraryModel.canZoomIn != true)

            Button("Zoom Out") { appState?.libraryModel.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState?.libraryModel.canZoomOut != true)

            Button("Actual Size (\(appState?.libraryModel.zoomDescription ?? "100%"))") {
                appState?.libraryModel.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(appState == nil)

            Divider()

            Toggle(
                "Look Up on Double-Click",
                isOn: Binding(
                    get: { appState?.libraryModel.lookUpOnDoubleClick ?? true },
                    set: { appState?.libraryModel.lookUpOnDoubleClick = $0 }
                )
            )
            .disabled(appState == nil)

            Divider()
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
