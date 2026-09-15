import AppKit
import WebKit

/// Deterministic lifecycle checks, run alongside the real WebKit tab smoke test.
@MainActor
enum EntryLoadingTests {
    private final class PageProbe: WKWebView {
        var documents: [String] = []

        override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
            documents.append(string)
            return nil
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(model: LibraryModel) async throws -> Int {
        let state = AppState(libraryModel: model)
        let coordinator = EntryWebView.Coordinator(
            tabID: state.activeTabID, appState: state, libraryModel: model
        )
        let view = PageProbe(frame: .zero, configuration: WKWebViewConfiguration())
        func load(_ word: String, anchor: String? = nil) {
            coordinator.load(
                word: word, anchor: anchor, preferredDictionaryUUID: nil,
                initialScrollOffset: 0, version: 0, into: view, force: false
            )
        }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        func awaitDocument(count: Int) async throws {
            for _ in 0..<200 {
                if view.documents.count >= count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure(description: "page construction did not finish")
        }

        // These destinations collided when the load identity was a pipe-joined
        // string. Both requests happen before MainActor can accept either result.
        load("alpha|beta", anchor: "gamma")
        load("alpha", anchor: "beta|gamma")
        try await awaitDocument(count: 1)
        try expect(view.documents.count == 1, "superseded page was delivered")
        try expect(
            view.documents[0].contains(">alpha<") && !view.documents[0].contains("alpha|beta"),
            "distinct destinations were treated as the same page"
        )

        load("alpha", anchor: "beta|gamma")
        load("cancelled")
        EntryWebView.dismantleNSView(view, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(100))
        try expect(view.documents.count == 1, "a dismantled view accepted a pending page")

        // A fresh navigation remains usable after cancellation.
        load("omega")
        try await awaitDocument(count: 2)
        try expect(view.documents[1].contains(">omega<"), "navigation after cancellation failed")

        state.navigate(to: "omega")
        coordinator.webViewWebContentProcessDidTerminate(view)
        try await awaitDocument(count: 3)
        try expect(view.documents[2].contains(">omega<"), "terminated WebKit process did not rebuild its document")

        // Recovery must follow the tab's latest destination, including when
        // SwiftUI has not delivered that navigation to the view yet.
        state.navigate(to: "latest")
        coordinator.webViewWebContentProcessDidTerminate(view)
        try await awaitDocument(count: 4)
        try expect(view.documents[3].contains(">latest<"), "process recovery restored an obsolete destination")
        coordinator.cancelLoading()
        return 6
    }
}
