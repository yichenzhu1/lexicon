import AppKit
import SwiftUI
import WebKit

/// Offscreen SwiftUI/WebKit check for the resident-tab view hierarchy.
@MainActor
enum TabWebViewSmokeTest {
    private static var window: NSWindow?
    private static var hostingView: NSHostingView<AnyView>?
    private static var appState: AppState?
    private static var rootURL: URL?
    private static var initialTabID: UUID?
    private static var initialWebView: WKWebView?
    private static var residentIdentities: [UUID: ObjectIdentifier] = [:]
    private static var phase = 0
    private static var attempts = 0

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LexiconTabWebViewTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = root
        let model = LibraryModel(rootURL: root)
        let state = AppState(libraryModel: model)
        appState = state
        initialTabID = state.activeTabID

        let content = AnyView(
            ContentView()
                .environmentObject(model)
                .environmentObject(state)
                .frame(width: 900, height: 640)
        )
        let host = NSHostingView(rootView: content)
        hostingView = host
        let testWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        testWindow.contentView = host
        testWindow.orderBack(nil)
        window = testWindow

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in poll() }
        }
        app.run()
        exit(1)
    }

    private static func poll() {
        attempts += 1
        guard let state = appState, let host = hostingView, let initialTabID else {
            finish("test state was released", success: false)
        }
        let views = webViews(in: host)
        let byTab = Dictionary(uniqueKeysWithValues: views.compactMap { view -> (UUID, WKWebView)? in
            guard let raw = view.identifier?.rawValue, let id = UUID(uuidString: raw) else { return nil }
            return (id, view)
        })

        switch phase {
        case 0:
            guard let first = byTab[initialTabID] else { return timeoutIfNeeded() }
            initialWebView = first
            for _ in 0..<4 { state.openNewTab() }
            phase = 1
            attempts = 0

        case 1:
            guard byTab.count == AppState.maximumResidentTabCount,
                  Set(byTab.keys) == Set(state.residentTabIDs)
            else { return timeoutIfNeeded() }
            guard byTab[initialTabID] == nil else {
                finish("the least-recent tab view was not evicted", success: false)
            }
            residentIdentities = byTab.mapValues(ObjectIdentifier.init)
            guard let residentToActivate = state.residentTabIDs.dropLast().last else {
                finish("no inactive resident tab was available", success: false)
            }
            state.activateTab(residentToActivate)
            phase = 2
            attempts = 0

        case 2:
            guard byTab.count == AppState.maximumResidentTabCount else { return timeoutIfNeeded() }
            let identities = byTab.mapValues(ObjectIdentifier.init)
            guard identities == residentIdentities else {
                finish("switching to a resident tab recreated a WKWebView", success: false)
            }
            state.activateTab(initialTabID)
            phase = 3
            attempts = 0

        default:
            guard byTab.count == AppState.maximumResidentTabCount,
                  Set(byTab.keys) == Set(state.residentTabIDs),
                  let reloaded = byTab[initialTabID]
            else { return timeoutIfNeeded() }
            guard reloaded !== initialWebView else {
                finish("reactivating an evicted tab reused its released WKWebView", success: false)
            }
            finish("TAB WEBVIEW OK", success: true)
        }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = view as? WKWebView { found.append(webView) }
        for child in view.subviews { found.append(contentsOf: webViews(in: child)) }
        return found
    }

    private static func timeoutIfNeeded() {
        if attempts > 100 { finish("timed out waiting for the resident view hierarchy", success: false) }
    }

    private static func finish(_ message: String, success: Bool) -> Never {
        print(success ? message : "TAB WEBVIEW FAIL: \(message)")
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        appState = nil
        initialWebView = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        exit(success ? 0 : 1)
    }
}
