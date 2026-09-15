import AppKit
import MdxKit
import SwiftUI
import WebKit

/// Renders the app-owned results page and isolated dictionary frames. The
/// bridge lives in a named WKContentWorld, so page scripts cannot invoke the
/// native message handler or inspect sibling dictionaries.
struct EntryWebView: NSViewRepresentable {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel

    let tabID: UUID
    let word: String?
    let anchor: String?
    let preferredDictionaryUUID: String?
    let initialScrollOffset: Double
    let contentVersion: Int
    let zoom: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(tabID: tabID, appState: appState, libraryModel: libraryModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(
            context.coordinator,
            contentWorld: Coordinator.bridgeWorld,
            name: Coordinator.bridgeMessageName
        )
        controller.add(
            context.coordinator,
            contentWorld: .page,
            name: Coordinator.pageGeometryMessageName
        )
        controller.addUserScript(WKUserScript(
            source: Coordinator.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Coordinator.bridgeWorld
        ))
        controller.addUserScript(WKUserScript(
            source: Coordinator.dictionaryCompatibilityScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))

        let schemeHandler = DictSchemeHandler(libraryModel: libraryModel)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: DictSchemeHandler.scheme)
        context.coordinator.schemeHandler = schemeHandler

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.identifier = NSUserInterfaceItemIdentifier(tabID.uuidString)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.pageZoom = zoom
        context.coordinator.load(
            word: word, anchor: anchor, preferredDictionaryUUID: preferredDictionaryUUID,
            initialScrollOffset: initialScrollOffset,
            version: contentVersion, into: webView, force: true
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.appState = appState
        context.coordinator.libraryModel = libraryModel
        context.coordinator.schemeHandler?.allowHTTPS =
            libraryModel.dictionaryNetworkPolicy == .allowHTTPS
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        context.coordinator.load(
            word: word, anchor: anchor, preferredDictionaryUUID: preferredDictionaryUUID,
            initialScrollOffset: initialScrollOffset,
            version: contentVersion, into: webView, force: false
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelLoading()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.bridgeMessageName,
            contentWorld: Coordinator.bridgeWorld
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.pageGeometryMessageName,
            contentWorld: .page
        )
        coordinator.schemeHandler = nil
        coordinator.diagnosticHandler = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let bridgeMessageName = "lexiconBridge"
        static let pageGeometryMessageName = "lexiconPageGeometry"
        static let bridgeWorld = WKContentWorld.world(name: "LexiconBridge")

        let tabID: UUID
        var appState: AppState
        var libraryModel: LibraryModel
        var schemeHandler: DictSchemeHandler?
        var networkPolicyOverride: LibraryModel.DictionaryNetworkPolicy?
        /// Test-only observer used by the offscreen WebKit harness. Production
        /// pages never receive the diagnostic user script that emits it.
        var diagnosticHandler: ((String, [String: Any], WKFrameInfo) -> Void)?
        private struct PageIdentity: Equatable {
            let word: String?
            let anchor: String?
            let preferredDictionaryUUID: String?
            let version: Int
        }
        private var loadedPage: PageIdentity?
        private var pageLoadTask: Task<Void, Never>?
        private enum NavigationState {
            case preparing
            case loading(WKNavigation?)
            case ready
        }
        private var navigationState: NavigationState = .preparing
        private var dictionaryFrames: [String: WKFrameInfo] = [:]
        private var translationTasks: [String: Task<Void, Never>] = [:]

        init(tabID: UUID, appState: AppState, libraryModel: LibraryModel) {
            self.tabID = tabID
            self.appState = appState
            self.libraryModel = libraryModel
        }

        func dictionaryFrameInfo(for uuid: String) -> WKFrameInfo? {
            dictionaryFrames[uuid.lowercased()]
        }

        func load(
            word: String?, anchor: String?, preferredDictionaryUUID: String?,
            initialScrollOffset: Double,
            version: Int, into webView: WKWebView, force: Bool
        ) {
            let page = PageIdentity(
                word: word, anchor: anchor,
                preferredDictionaryUUID: preferredDictionaryUUID, version: version
            )
            guard force || page != loadedPage else { return }
            cancelLoading()
            loadedPage = page
            dictionaryFrames.removeAll(keepingCapacity: true)
            let allowHTTPS = (networkPolicyOverride ?? libraryModel.dictionaryNetworkPolicy) == .allowHTTPS
            let library = libraryModel.library
            let collapsed = libraryModel.collapsedDictionaries
            let hasDictionaries = !libraryModel.dictionaries.isEmpty
            // Snapshot UI preferences once. SQL and document construction must
            // not occupy MainActor while the user is typing or switching tabs.
            let rendering = Task.detached(priority: .userInitiated) { () -> String? in
                guard !Task.isCancelled else { return nil }
                if let word, let library {
                    return EntryPageBuilder.resultsDocument(
                        for: word, library: library, collapsedDictionaries: collapsed,
                        anchor: anchor, preferredDictionaryUUID: preferredDictionaryUUID,
                        initialScrollOffset: initialScrollOffset, allowHTTPS: allowHTTPS
                    )
                }
                return EntryPageBuilder.welcomeDocument(hasDictionaries: hasDictionaries)
            }
            pageLoadTask = Task { [weak self, weak webView] in
                let html = await withTaskCancellationHandler {
                    await rendering.value
                } onCancel: {
                    rendering.cancel()
                }
                guard !Task.isCancelled, let html, let self, let webView else { return }
                self.pageLoadTask = nil
                self.navigationState = .loading(
                    webView.loadHTMLString(html, baseURL: URL(string: "dict://page/results"))
                )
                #if DEBUG
                self.scheduleDiagnostics(in: webView)
                #endif
            }
        }

        func cancelLoading() {
            navigationState = .preparing
            pageLoadTask?.cancel()
            pageLoadTask = nil
            cancelTranslations()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard case .loading(let expected) = navigationState, navigation === expected else { return }
            navigationState = .ready
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let tab = appState.tabs.first(where: { $0.id == tabID }) else { return }
            // A terminated content process loses the document even though
            // SwiftUI still has the same page identity. Rebuild explicitly,
            // using current tab state if navigation was already in progress.
            load(
                word: tab.word, anchor: tab.location?.anchor,
                preferredDictionaryUUID: tab.location?.preferredDictionaryUUID,
                initialScrollOffset: tab.scrollOffset,
                version: libraryModel.contentVersion, into: webView, force: true
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // The old document stays alive while its replacement is prepared.
            // It must not update the new destination or start another request.
            guard case .ready = navigationState,
                  let tab = appState.tabs.first(where: { $0.id == tabID }),
                  loadedPage?.word == tab.location?.word,
                  loadedPage?.anchor == tab.location?.anchor,
                  loadedPage?.preferredDictionaryUUID == tab.location?.preferredDictionaryUUID,
                  let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String,
                  let frameURL = message.frameInfo.request.url,
                  frameURL.scheme?.lowercased() == DictSchemeHandler.scheme,
                  let host = frameURL.host?.lowercased()
            else { return }

            if message.name == Self.pageGeometryMessageName {
                guard host == "page" else { return }
                if kind == "pageScroll",
                   let offset = (payload["offset"] as? NSNumber)?.doubleValue {
                    recordPageScroll(offset)
                } else if kind == "frameScroll" {
                    synchronizeDictionaryScroll(
                        payload["frames"] as? [[String: Any]] ?? [], webView: message.webView
                    )
                }
                return
            }
            guard message.name == Self.bridgeMessageName else { return }

            if host == "page" {
                if kind == "collapse",
                   appState.isActiveTab(tabID),
                   let uuid = payload["dictionaryUUID"] as? String,
                   let collapsed = payload["collapsed"] as? Bool,
                   libraryModel.library?.isKnownDictionaryUUID(uuid) == true {
                    libraryModel.setDictionary(uuid, collapsed: collapsed)
                }
                return
            }
            guard libraryModel.library?.isKnownDictionaryUUID(host) == true else { return }
            let isDictionaryRootFrame = payload["dictionaryRoot"] as? Bool == true
            if isDictionaryRootFrame { dictionaryFrames[host] = message.frameInfo }

            switch kind {
            case "diagnostic":
                if isDictionaryRootFrame {
                    diagnosticHandler?(host, payload, message.frameInfo)
                }

            case "height":
                guard isDictionaryRootFrame,
                      let flowHeight = (payload["flowHeight"] as? NSNumber)?.doubleValue
                        ?? (payload["height"] as? NSNumber)?.doubleValue
                else { return }
                let visualHeight = (payload["visualHeight"] as? NSNumber)?.doubleValue
                    ?? flowHeight
                let script = "window.__lexiconSetFrameHeight?.('\(host)',\(flowHeight),\(visualHeight));"
                message.webView?.evaluateJavaScript(script)

            case "scroll":
                let offset = payload["offset"] as? Double ?? 0
                let behavior = payload["behavior"] as? String == "smooth" ? "smooth" : "auto"
                let mode = payload["mode"] as? String ?? "element"
                if mode == "by" {
                    message.webView?.evaluateJavaScript("window.scrollBy(0,\(offset));")
                } else if mode == "home" {
                    message.webView?.evaluateJavaScript("window.scrollTo(0,0);")
                } else if mode == "end" {
                    message.webView?.evaluateJavaScript("window.scrollTo(0,document.documentElement.scrollHeight);")
                } else {
                    message.webView?.evaluateJavaScript(
                        "window.__lexiconScrollFrame?.('\(host)',\(offset),'\(behavior)');"
                    )
                }

            case "tts":
                guard appState.isActiveTab(tabID),
                      let text = payload["text"] as? String,
                      let language = payload["language"] as? String
                else { return }
                libraryModel.speak(text, language: language)

            case "translation":
                guard let requestID = payload["requestID"] as? String,
                      requestID.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil,
                      let prompt = payload["prompt"] as? String,
                      let webView = message.webView
                else { return }
                let frameInfo = message.frameInfo
                guard appState.isActiveTab(tabID) else {
                    deliverTranslationResponse(
                        requestID: requestID, text: nil,
                        error: "Return to this tab and click again to translate.",
                        frameInfo: frameInfo, webView: webView
                    )
                    return
                }
                let key = "\(host)|\(requestID)"
                guard translationTasks[key] == nil else { return }
                let translator = libraryModel.translation
                translationTasks[key] = Task { @MainActor [weak self, weak webView] in
                    var translatedText: String?
                    var failure: String?
                    do {
                        try Task.checkCancellation()
                        translatedText = try await translator.translate(prompt)
                    } catch {
                        failure = error.localizedDescription
                    }
                    guard !Task.isCancelled, let self, let webView else { return }
                    self.translationTasks.removeValue(forKey: key)
                    self.deliverTranslationResponse(
                        requestID: requestID, text: translatedText, error: failure,
                        frameInfo: frameInfo, webView: webView
                    )
                }

            case "translationCancel":
                guard let requestID = payload["requestID"] as? String else { return }
                translationTasks.removeValue(forKey: "\(host)|\(requestID)")?.cancel()

            case "link":
                guard appState.isActiveTab(tabID),
                      let href = payload["href"] as? String
                else { return }
                routeDictionaryLink(href, dictionaryUUID: host, webView: message.webView)

            case "lookup":
                guard appState.isActiveTab(tabID),
                      libraryModel.lookUpOnDoubleClick,
                      let word = payload["word"] as? String
                else { return }
                appState.navigate(to: word)

            default:
                break
            }
        }

        func cancelTranslations() {
            let tasks = translationTasks.values
            translationTasks.removeAll()
            for task in tasks { task.cancel() }
        }

        private func synchronizeDictionaryScroll(
            _ states: [[String: Any]], webView: WKWebView?
        ) {
            guard let webView else { return }
            for state in states {
                guard let uuid = (state["uuid"] as? String)?.lowercased(),
                      libraryModel.library?.isKnownDictionaryUUID(uuid) == true,
                      let frameInfo = dictionaryFrames[uuid],
                      let offset = (state["offset"] as? NSNumber)?.doubleValue,
                      let viewportHeight = (state["viewportHeight"] as? NSNumber)?.doubleValue,
                      offset.isFinite, offset >= 0,
                      viewportHeight.isFinite, viewportHeight > 0
                else { continue }
                webView.callAsyncJavaScript(
                    """
                    window.__lexiconReceiveScrollState?.(offset, viewportHeight);
                    return true;
                    """,
                    arguments: ["offset": offset, "viewportHeight": viewportHeight],
                    in: frameInfo,
                    in: .page
                ) { _ in }
            }
        }

        /// Kept separate from WebKit message decoding so tab ownership can be
        /// regression-tested without manufacturing a WKScriptMessage.
        func recordPageScroll(_ offset: Double) {
            appState.setTabScrollOffset(offset, for: tabID)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel); return
            }
            let scheme = url.scheme?.lowercased()
            switch scheme {
            case "dict", "about", "blob", "data", nil:
                decisionHandler(.allow)
            case "entry", "bword", "sound":
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated,
                   appState.isActiveTab(tabID) {
                    routeDictionaryLink(
                        url.absoluteString,
                        dictionaryUUID: navigationAction.sourceFrame.request.url?.host,
                        webView: webView
                    )
                }
            case "https":
                if navigationAction.navigationType == .linkActivated {
                    decisionHandler(.cancel)
                    if appState.isActiveTab(tabID) { NSWorkspace.shared.open(url) }
                } else if navigationAction.targetFrame == nil
                            || navigationAction.targetFrame?.isMainFrame == true {
                    decisionHandler(.cancel)
                } else {
                    let policy = networkPolicyOverride ?? libraryModel.dictionaryNetworkPolicy
                    decisionHandler(policy == .allowHTTPS ? .allow : .cancel)
                }
            case "mailto":
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated,
                   appState.isActiveTab(tabID) {
                    NSWorkspace.shared.open(url)
                }
            default:
                decisionHandler(.cancel)
            }
        }

        func routeDictionaryLink(
            _ rawLink: String, dictionaryUUID: String?, webView: WKWebView? = nil
        ) {
            let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme = trimmed.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
            switch scheme {
            case "entry", "bword":
                // Split the encoded URL first: an escaped # belongs to the
                // headword (for example C%23), not to its fragment.
                let target = rawReference(in: trimmed)
                let pieces = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let word = decodedReference(pieces.first.map(String.init) ?? "")
                let anchor = pieces.count > 1
                    ? String(pieces[1]).removingPercentEncoding ?? String(pieces[1]) : nil
                if word.isEmpty, let anchor, let dictionaryUUID {
                    scrollToAnchor(anchor, dictionaryUUID: dictionaryUUID, webView: webView)
                } else if !word.isEmpty {
                    appState.navigate(to: word, anchor: anchor, preferredDictionaryUUID: dictionaryUUID)
                }
            case "sound":
                guard let dictionaryUUID else { return }
                let path = decodedReference(rawReference(in: trimmed))
                if !path.isEmpty { libraryModel.playAudio(path: path, dictionaryUUID: dictionaryUUID) }
            case "http", "https", "mailto":
                if let url = URL(string: trimmed) { NSWorkspace.shared.open(url) }
            default:
                break
            }
        }

        private func deliverTranslationResponse(
            requestID: String,
            text: String?,
            error: String?,
            frameInfo: WKFrameInfo,
            webView: WKWebView
        ) {
            var payload: [String: String] = ["requestID": requestID]
            if let text { payload["text"] = text }
            if let error { payload["error"] = error }
            webView.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('lexicon-translation-response', {detail: JSON.stringify(payload)}));",
                arguments: ["payload": payload],
                in: frameInfo,
                in: .page
            ) { _ in }
        }

        private func scrollToAnchor(
            _ anchor: String, dictionaryUUID: String, webView: WKWebView?
        ) {
            guard let frame = dictionaryFrameInfo(for: dictionaryUUID) else { return }
            webView?.callAsyncJavaScript(
                "window.__lexiconScrollToAnchor?.(anchor);",
                arguments: ["anchor": anchor], in: frame, in: Self.bridgeWorld
            ) { _ in }
        }

        private func rawReference(in rawLink: String) -> String {
            var name = rawLink
            if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
            while name.hasPrefix("/") { name.removeFirst() }
            let fragment = name.firstIndex(of: "#") ?? name.endIndex
            if let query = name[..<fragment].firstIndex(of: "?") {
                name.removeSubrange(query..<fragment)
            }
            return name
        }

        private func decodedReference(_ reference: String) -> String {
            (reference.removingPercentEncoding ?? reference)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }


    }
}
