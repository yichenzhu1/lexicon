import MdxKit
import SwiftUI
import WebKit

/// The detail web view: shows the stacked per-dictionary cards for the
/// selected word, and routes entry://, sound:// and external links.
struct EntryWebView: NSViewRepresentable {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel

    let word: String?
    let contentVersion: Int
    let zoom: Double
    let collapsedDictionaries: Set<String>

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, libraryModel: libraryModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator, name: Coordinator.linkMessageName
        )
        configuration.setURLSchemeHandler(
            DictSchemeHandler(libraryModel: libraryModel), forURLScheme: DictSchemeHandler.scheme
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // blend with window
        webView.pageZoom = zoom
        context.coordinator.load(word: word, version: contentVersion, into: webView, force: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.libraryModel = libraryModel
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        context.coordinator.load(word: word, version: contentVersion, into: webView, force: false)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let linkMessageName = "lexiconLink"

        var appState: AppState
        var libraryModel: LibraryModel
        private var loadedToken: String?

        init(appState: AppState, libraryModel: LibraryModel) {
            self.appState = appState
            self.libraryModel = libraryModel
        }

        func load(word: String?, version: Int, into webView: WKWebView, force: Bool) {
            let token = "\(version)|\(word ?? "")"
            guard force || token != loadedToken else { return }
            loadedToken = token

            let html: String
            if let word, let library = libraryModel.library {
                html = EntryPageBuilder.resultsDocument(
                    for: word,
                    library: library,
                    collapsedDictionaries: libraryModel.collapsedDictionaries
                )
            } else {
                html = EntryPageBuilder.welcomeDocument(
                    hasDictionaries: !libraryModel.dictionaries.isEmpty
                )
            }
            // Host "d" keeps the outer page same-origin with entry iframes.
            webView.loadHTMLString(html, baseURL: URL(string: "dict://d/page"))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            switch url.scheme?.lowercased() {
            case "dict", "about", "blob", "data", nil:
                decisionHandler(.allow)

            case "entry", "bword":
                // Cross-reference link to another headword.
                decisionHandler(.cancel)
                routeDictionaryLink(
                    url.absoluteString,
                    dictionaryUUID: dictionaryUUID(for: navigationAction)
                )

            case "sound":
                decisionHandler(.cancel)
                routeDictionaryLink(
                    url.absoluteString,
                    dictionaryUUID: dictionaryUUID(for: navigationAction)
                )

            case "http", "https", "mailto":
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)

            default:
                decisionHandler(.cancel)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.linkMessageName,
                  let payload = message.body as? [String: Any]
            else { return }

            if payload["kind"] as? String == "collapse" {
                guard let uuid = payload["dictionaryUUID"] as? String,
                      let collapsed = payload["collapsed"] as? Bool
                else { return }
                libraryModel.setDictionary(uuid, collapsed: collapsed)
                return
            }

            if payload["kind"] as? String == "lookup" {
                // Gated here rather than in the injected script so the
                // preference applies to already-rendered entries.
                guard libraryModel.lookUpOnDoubleClick,
                      let word = payload["word"] as? String
                else { return }
                appState.navigate(to: word)
                return
            }

            guard let href = payload["href"] as? String else { return }
            routeDictionaryLink(
                href,
                dictionaryUUID: payload["dictionaryUUID"] as? String
            )
        }

        private func routeDictionaryLink(_ rawLink: String, dictionaryUUID: String?) {
            let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme = trimmed.split(separator: ":", maxSplits: 1)
                .first.map { $0.lowercased() } ?? ""

            switch scheme {
            case "entry", "bword":
                let word = referencedName(in: trimmed, keepFragment: false)
                if !word.isEmpty { appState.navigate(to: word) }

            case "sound":
                guard let dictionaryUUID else { return }
                // Keep the fragment: OALD-style MDDs name their audio files
                // with a literal '#' (e.g. "_apple#_gbs_2.mp3").
                let path = referencedName(in: trimmed, keepFragment: true)
                if !path.isEmpty {
                    libraryModel.playAudio(path: path, dictionaryUUID: dictionaryUUID)
                }

            case "http", "https", "mailto":
                if let url = URL(string: trimmed) { NSWorkspace.shared.open(url) }

            default:
                break
            }
        }

        private func dictionaryUUID(for navigationAction: WKNavigationAction) -> String? {
            guard let sourceURL = navigationAction.sourceFrame.request.url else { return nil }
            return Self.dictionaryUUID(fromFrameURL: sourceURL)
        }

        /// Extracts "pron/apple.wav" from sound://pron/apple.wav, sound:pron/apple.wav,
        /// or the word from entry://colour. Raw strings preserve literal '#'
        /// characters used by some MDD audio resource names.
        private func referencedName(in rawLink: String, keepFragment: Bool) -> String {
            var name = rawLink
            if let colon = name.firstIndex(of: ":") {
                name = String(name[name.index(after: colon)...])
            }
            while name.hasPrefix("/") { name.removeFirst() }
            if !keepFragment, let hash = name.firstIndex(of: "#") {
                name = String(name[..<hash])
            }
            if let query = name.firstIndex(of: "?") {
                name = String(name[..<query])
            }
            name = name.removingPercentEncoding ?? name
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }

        static func dictionaryUUID(fromFrameURL url: URL) -> String? {
            guard url.scheme == DictSchemeHandler.scheme else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            return parts.first
        }
    }
}
