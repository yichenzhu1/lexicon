import AppKit
import SwiftUI

/// Exercises the actual search field in a foreground window. This requires a
/// desktop session; the offscreen WebKit tests cannot check keyboard focus.
@MainActor
enum SearchFocusTests {
    static func run() -> Never {
        TestApplication.main()
        exit(1)
    }

    /// Match the real app's scene and delegate lifecycle, rather than embedding
    /// ContentView in a manually constructed NSHostingView and NSWindow.
    private struct TestApplication: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
        @StateObject private var fixture = Fixture()

        var body: some Scene {
            WindowGroup(id: "search-focus-test") {
                ContentView()
                    .environmentObject(fixture.model)
                    .environmentObject(fixture.state)
                    .frame(minWidth: 760, minHeight: 480)
                    .background {
                        WindowProbe { fixture.start(in: $0) }
                    }
            }
            .defaultSize(width: 1000, height: 680)
            .windowStyle(.hiddenTitleBar)
            .windowBackgroundDragBehavior(.disabled)
        }
    }

    @MainActor
    private final class Fixture: ObservableObject {
        let settingsSuiteName: String
        let settings: UserDefaults
        let root: URL
        let model: LibraryModel
        let state: AppState
        private var started = false

        init() {
            settingsSuiteName = "LexiconSearchFocusTests.\(UUID().uuidString)"
            guard setenv("LEXICON_SETTINGS_SUITE", settingsSuiteName, 1) == 0,
                  let settings = UserDefaults(suiteName: settingsSuiteName) else {
                print("SEARCH FOCUS FAIL: could not create isolated settings")
                exit(1)
            }
            self.settings = settings
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LexiconSearchFocusTests-\(UUID().uuidString)", isDirectory: true)
            model = LibraryModel(rootURL: root)
            state = AppState(libraryModel: model)
        }

        func start(in window: NSWindow) {
            guard !started else { return }
            started = true
            Task { @MainActor in
                var succeeded = false
                do {
                    try await until("SwiftUI scene did not become active and key") {
                        NSApp.isActive && window.isKeyWindow && window.contentView != nil
                    }
                    guard let host = window.contentView else {
                        throw Failure("SwiftUI scene lost its content view")
                    }
                    try await verify(window: window, host: host, model: model, state: state)
                    print("SEARCH FOCUS OK (initial focus, window focus transitions, application hide/reactivation, explicit dismissal, tab race, composition)")
                    succeeded = true
                } catch {
                    print("SEARCH FOCUS FAIL: \(error)")
                    print("appActive=\(NSApp.isActive) appHidden=\(NSApp.isHidden) appRunning=\(NSApp.isRunning) windowKey=\(window.isKeyWindow) firstResponder=\(String(describing: window.firstResponder))")
                }
                window.orderOut(nil)
                settings.removePersistentDomain(forName: settingsSuiteName)
                try? FileManager.default.removeItem(at: root)
                exit(succeeded ? 0 : 1)
            }
        }
    }

    private struct WindowProbe: NSViewRepresentable {
        let attached: @MainActor (NSWindow) -> Void

        func makeNSView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.attached = attached
            return view
        }

        func updateNSView(_ view: ProbeView, context: Context) {
            view.attached = attached
            if let window = view.window { attached(window) }
        }

        final class ProbeView: NSView {
            var attached: @MainActor (NSWindow) -> Void = { _ in }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { attached(window) }
            }
        }
    }

    private static func verify(
        window: NSWindow, host: NSView, model: LibraryModel, state: AppState
    ) async throws {
        try await until("initial search focus") {
            NSApp.isActive && window.isKeyWindow && searchEditor(in: host, window: window) != nil
        }
        let initialEditor = try requireEditor(in: host, window: window)
        initialEditor.insertText("literal query", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await until("typing did not reach the search binding") { state.searchText == "literal query" }
        let selection = NSRange(location: 2, length: 3)
        initialEditor.setSelectedRange(selection)

        // Returning key status to an existing window should retain AppKit's
        // editing session and selection.
        try await transferWindowFocusAndReturn(window)
        try await remains("regaining window focus restarted or changed search editing") {
            searchEditor(in: host, window: window) === initialEditor
                && initialEditor.selectedRange() == selection
                && state.searchText == "literal query"
        }
        try await hideAndRestoreApplication(window)
        try await remains("application reactivation changed search editing or selection") {
            guard let editor = searchEditor(in: host, window: window) else { return false }
            return editor.selectedRange() == selection && editor.string == "literal query"
                && state.searchText == "literal query"
        }

        clickOutsideSearch(in: host, window: window)
        try await until("outside click did not release search focus") {
            searchEditor(in: host, window: window) == nil
        }
        try await transferWindowFocusAndReturn(window)
        try await remains("regaining window focus stole focus after an explicit dismissal") {
            searchEditor(in: host, window: window) == nil
        }
        try await hideAndRestoreApplication(window)
        try await remains("application reactivation stole focus after an explicit dismissal") {
            searchEditor(in: host, window: window) == nil
        }

        state.openNewTab()
        try await until("new tab did not focus search") {
            searchEditor(in: host, window: window) != nil
        }

        // Submit consecutive view updates and dismiss in the same main-actor
        // turn. An unowned Task.yield() focus request can outlive that dismissal.
        // Explicit layout commits the real SwiftUI onChange handlers without
        // advancing the run loop to let pending Tasks finish first.
        for _ in 0..<6 {
            state.openNewTab()
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        clickOutsideSearch(in: host, window: window)
        try await until("tab-switch dismissal did not release search focus") {
            searchEditor(in: host, window: window) == nil
        }
        try await remains("a pending tab focus request overrode explicit dismissal") {
            searchEditor(in: host, window: window) == nil
        }

        state.openNewTab()
        try await until("search could not regain focus after dismissal") {
            searchEditor(in: host, window: window) != nil
        }
        let editor = try requireEditor(in: host, window: window)
        editor.setMarkedText(
            "拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        guard editor.hasMarkedText() else { throw Failure("the search editor rejected marked text") }
        let markedRange = editor.markedRange()
        model.reloadDictionaries()
        try await remains("a view update interrupted marked-text composition") {
            searchEditor(in: host, window: window) === editor
                && editor.hasMarkedText() && editor.markedRange() == markedRange
        }
        editor.insertText("拼音", replacementRange: markedRange)
        try await until("committed composed text did not reach search") {
            !editor.hasMarkedText() && state.searchText == "拼音"
        }
    }

    /// Use only public AppKit types; no SwiftUI private view names or remote
    /// text-input windows are inspected. The empty main view has one field.
    private static func searchEditor(in view: NSView, window: NSWindow) -> NSTextView? {
        if let field = view as? NSTextField, field.isEditable,
           let editor = field.currentEditor() as? NSTextView,
           window.firstResponder === editor {
            return editor
        }
        for child in view.subviews {
            if let editor = searchEditor(in: child, window: window) { return editor }
        }
        return nil
    }

    private static func requireEditor(in view: NSView, window: NSWindow) throws -> NSTextView {
        guard let editor = searchEditor(in: view, window: window) else {
            throw Failure("the search field has no active AppKit field editor")
        }
        return editor
    }

    private static func clickOutsideSearch(in host: NSView, window: NSWindow) {
        let point = host.convert(NSPoint(x: host.bounds.maxX - 32, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func transferWindowFocusAndReturn(_ window: NSWindow) async throws {
        let otherWindow = NSWindow(
            contentRect: NSRect(x: window.frame.minX + 40, y: window.frame.minY + 40, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        otherWindow.title = "Focus Transfer Target"
        otherWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        defer { otherWindow.orderOut(nil) }

        otherWindow.makeKeyAndOrderFront(nil)
        try await until("second window did not receive keyboard focus") {
            NSApp.keyWindow === otherWindow && otherWindow.isKeyWindow && !window.isKeyWindow
        }
        window.makeKeyAndOrderFront(nil)
        try await until("search window did not regain keyboard focus") {
            NSApp.keyWindow === window && window.isKeyWindow && !otherWindow.isKeyWindow
        }
    }

    private static func hideAndRestoreApplication(_ window: NSWindow) async throws {
        // Hide performs a real application transition without targeting
        // another app. In this CLI harness, unhide alone can restore visibility
        // without activation. Request both explicitly, while leaving AppKit
        // to restore the key window and its first responder.
        defer { if NSApp.isHidden { NSApp.unhideWithoutActivation() } }
        NSApp.hide(nil)
        try await until("application did not become hidden and inactive") {
            NSApp.isHidden && !NSApp.isActive
        }
        NSApp.unhideWithoutActivation()
        NSApp.activate(ignoringOtherApps: true)
        try await until("application did not restore its search window after unhiding") {
            !NSApp.isHidden && NSApp.isActive && NSApp.keyWindow === window && window.isKeyWindow
        }
    }

    private static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure("timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A bounded observation interval catches queued focus work that runs
    /// after the expected state was first reached.
    private static func remains(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(400)
        repeat {
            guard condition() else { throw Failure(message) }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
