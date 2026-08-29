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
    let collapsedDictionaries: Set<String>

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
        private var loadedToken: String?
        private var dictionaryFrames: [String: WKFrameInfo] = [:]

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
            let token = "\(version)|\(word ?? "")|\(anchor ?? "")|\(preferredDictionaryUUID ?? "")"
            guard force || token != loadedToken else { return }
            loadedToken = token
            dictionaryFrames.removeAll(keepingCapacity: true)
            let allowHTTPS = (networkPolicyOverride ?? libraryModel.dictionaryNetworkPolicy) == .allowHTTPS
            let html: String
            if let word, let library = libraryModel.library {
                html = EntryPageBuilder.resultsDocument(
                    for: word, library: library,
                    collapsedDictionaries: libraryModel.collapsedDictionaries,
                    anchor: anchor,
                    preferredDictionaryUUID: preferredDictionaryUUID,
                    initialScrollOffset: initialScrollOffset,
                    allowHTTPS: allowHTTPS
                )
            } else {
                html = EntryPageBuilder.welcomeDocument(
                    hasDictionaries: !libraryModel.dictionaries.isEmpty
                )
            }
            webView.loadHTMLString(html, baseURL: URL(string: "dict://page/results"))
            #if DEBUG
            if ProcessInfo.processInfo.environment["LEXICON_DEBUG_PAGE"] == "1" {
                // One-shot geometry dump for diagnosing layout issues in the
                // live window: `LEXICON_DEBUG_PAGE=1 .build/debug/Lexicon`.
                // LEXICON_DEBUG_SCROLL=<points> scrolls the page first.
                let scroll = ProcessInfo.processInfo.environment["LEXICON_DEBUG_SCROLL"]
                    .flatMap(Double.init) ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak webView] in
                    guard scroll > 0 else { return }
                    webView?.evaluateJavaScript("window.scrollTo(0, \(scroll));") { _, _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak webView] in
                    webView?.evaluateJavaScript("""
                    JSON.stringify({
                      scrollY: Math.round(scrollY), docH: document.documentElement.scrollHeight,
                      clientH: document.documentElement.clientHeight,
                      cards: Array.from(document.querySelectorAll('details[data-uuid]')).map(d => ({
                        uuid: d.dataset.uuid.slice(0, 8), open: d.open,
                        top: Math.round(d.getBoundingClientRect().top + scrollY),
                        h: Math.round(d.getBoundingClientRect().height),
                        summaryH: Math.round(d.querySelector('summary')?.getBoundingClientRect().height || 0),
                        frameH: Math.round(d.querySelector('iframe')?.getBoundingClientRect().height || 0),
                        frameSrc: (d.querySelector('iframe')?.getAttribute('src') || 'none').slice(0, 40)
                      }))
                    })
                    """) { value, _ in
                        let line = "PAGE DUMP: \(value ?? "")\n"
                        FileHandle.standardOutput.write(Data(line.utf8))
                    }
                }
                // LEXICON_DEBUG_WATCH=1 samples frame heights over time, to
                // catch oscillating (twitching) frames in the live window.
                if ProcessInfo.processInfo.environment["LEXICON_DEBUG_WATCH"] == "1" {
                    for tick in 0 ..< 10 {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 3 + Double(tick) * 0.7
                        ) { [weak webView] in
                            webView?.evaluateJavaScript("""
                            JSON.stringify(Array.from(document.querySelectorAll('iframe[data-uuid]'))
                              .map(f => f.dataset.uuid.slice(0, 8) + '=' + Math.round(f.getBoundingClientRect().height)))
                            """) { value, _ in
                                let line = "WATCH \(tick): \(value ?? "")\n"
                                FileHandle.standardOutput.write(Data(line.utf8))
                            }
                        }
                    }
                }
                // LEXICON_DEBUG_SWEEP=1 simulates wheel-like scrolling in the
                // live window — fine-grained steps with direction reversals —
                // logging scroll position, frame heights, and every height
                // assignment between ticks to catch bounce/oscillation.
                if ProcessInfo.processInfo.environment["LEXICON_DEBUG_SWEEP"] == "1" {
                    for step in 0 ..< 400 {
                        // Four phases: down, up, down, up (60px per 60ms).
                        let delta = (step / 100) % 2 == 0 ? 60 : -60
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 4 + Double(step) * 0.06
                        ) { [weak webView] in
                            webView?.evaluateJavaScript("""
                            (() => {
                              if (!window.__lexiconHeightLog) {
                                const log = [];
                                const orig = window.__lexiconSetFrameHeight;
                                window.__lexiconSetFrameHeight = (u, flow, visual) => {
                                  log.push(u.slice(0, 8) + '=' + Math.round(Number(flow) || 0)
                                    + '/' + Math.round(Number(visual) || Number(flow) || 0));
                                  return orig(u, flow, visual);
                                };
                                window.__lexiconHeightLog = log;
                              }
                              const dh = window.__lexiconHeightLog.splice(0);
                              const s = JSON.stringify({y: Math.round(scrollY),
                                h: Array.from(document.querySelectorAll('iframe[data-uuid]'))
                                  .map(f => Math.round(f.getBoundingClientRect().height)), dh});
                              scrollBy(0, \(delta)); return s; })()
                            """) { value, _ in
                                let line = "SWEEP \(step): \(value ?? "")\n"
                                FileHandle.standardOutput.write(Data(line.utf8))
                            }
                        }
                    }
                }
            }
            #endif
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any],
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
                if kind == "pageScroll",
                   let offset = (payload["offset"] as? NSNumber)?.doubleValue {
                    recordPageScroll(offset)
                } else if kind == "frameScroll" {
                    synchronizeDictionaryScroll(
                        payload["frames"] as? [[String: Any]] ?? [], webView: message.webView
                    )
                } else if kind == "collapse",
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
                guard appState.isActiveTab(tabID),
                      let requestID = payload["requestID"] as? String,
                      requestID.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil,
                      let prompt = payload["prompt"] as? String,
                      !prompt.isEmpty,
                      prompt.utf8.count <= 20_000,
                      let webView = message.webView
                else { return }
                let frameInfo = message.frameInfo
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    do {
                        let text = try await libraryModel.translateDictionaryPrompt(prompt)
                        deliverTranslationResponse(
                            requestID: requestID,
                            text: text,
                            error: nil,
                            frameInfo: frameInfo,
                            webView: webView
                        )
                    } catch {
                        deliverTranslationResponse(
                            requestID: requestID,
                            text: nil,
                            error: error.localizedDescription,
                            frameInfo: frameInfo,
                            webView: webView
                        )
                    }
                }

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
                    window.__lexiconVirtualScrollY = offset;
                    window.__lexiconVirtualViewportHeight = viewportHeight;
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

        private func routeDictionaryLink(
            _ rawLink: String, dictionaryUUID: String?, webView: WKWebView? = nil
        ) {
            let trimmed = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme = trimmed.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
            switch scheme {
            case "entry", "bword":
                let target = referencedName(in: trimmed, keepFragment: true)
                let pieces = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let word = pieces.first.map(String.init) ?? ""
                let anchor = pieces.count > 1 ? String(pieces[1]) : nil
                if word.isEmpty, let anchor, let dictionaryUUID {
                    scrollToAnchor(anchor, dictionaryUUID: dictionaryUUID, webView: webView)
                } else if !word.isEmpty {
                    appState.navigate(to: word, anchor: anchor, preferredDictionaryUUID: dictionaryUUID)
                }
            case "sound":
                guard let dictionaryUUID else { return }
                let path = referencedName(in: trimmed, keepFragment: true)
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
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let detail = String(data: data, encoding: .utf8)
            else { return }
            webView.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent('lexicon-translation-response', {detail: detail}));",
                arguments: ["detail": detail],
                in: frameInfo,
                in: .page
            ) { _ in }
        }

        private func scrollToAnchor(
            _ anchor: String, dictionaryUUID: String, webView: WKWebView?
        ) {
            // Fragment-only links are normally handled in the isolated script.
            // This fallback covers navigation-delegate links from legacy pages.
            guard let encoded = try? JSONSerialization.data(withJSONObject: anchor),
                  let literal = String(data: encoded, encoding: .utf8)
            else { return }
            let script = """
            (() => { const f=document.querySelector('iframe[data-uuid="\(dictionaryUUID.lowercased())"]');
              if (!f) return; f.contentWindow?.postMessage({kind:'lexicon-anchor',anchor:\(literal)}, '*'); })();
            """
            webView?.evaluateJavaScript(script)
        }

        private func referencedName(in rawLink: String, keepFragment: Bool) -> String {
            var name = rawLink
            if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
            while name.hasPrefix("/") { name.removeFirst() }
            if !keepFragment, let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
            if let query = name.firstIndex(of: "?") { name = String(name[..<query]) }
            return (name.removingPercentEncoding ?? name)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }

        static let bridgeScript = #"""
        (() => {
          const send = payload => {
            try {
              webkit.messageHandlers.lexiconBridge.postMessage(Object.assign({}, payload, {
                dictionaryRoot:window !== top && parent === top
              }));
            } catch (_) {}
          };
          const host = location.hostname.toLowerCase();
          const ready = callback => document.readyState === 'loading'
            ? addEventListener('DOMContentLoaded', callback, {once:true}) : callback();

          if (host === 'page') {
            ready(() => {
              document.querySelectorAll('details[data-uuid]').forEach(card => {
                card.addEventListener('toggle', () => send({kind:'collapse', dictionaryUUID:card.dataset.uuid,
                  collapsed:!card.open}));
              });
            });
            return;
          }

          let scheduled = false, scheduledDeep = false, settleTimer = 0;
          let lastFlowSent = -1, lastVisualSent = -1;
          let lastTrustedClick = -Infinity;
          let translationUsedForClick = false;
          addEventListener('click', event => {
            if (event.isTrusted) {
              lastTrustedClick = performance.now();
              translationUsedForClick = false;
            }
          }, true);
          function forwardTTSRequest(detail) {
            // Page scripts cannot invoke the native bridge directly. Accept a
            // compatibility request only immediately after a real user click.
            if (performance.now() - lastTrustedClick > 2000) return;
            let request;
            try { request = JSON.parse(String(detail || '')); } catch (_) { return; }
            const text = String(request.text || '').trim();
            const language = String(request.language || '').toLowerCase() === 'en-gb'
              ? 'en-GB' : 'en-US';
            if (!text || new TextEncoder().encode(text).length > 5000) return;
            send({kind:'tts', text, language});
          }
          function forwardTranslationRequest(detail) {
            // One paid translation at most per physical click. The page may
            // choose the passage and prompt, but it never sees the API key.
            if (translationUsedForClick || performance.now() - lastTrustedClick > 2000) return;
            let request;
            try { request = JSON.parse(String(detail || '')); } catch (_) { return; }
            const requestID = String(request.requestID || '');
            const prompt = String(request.prompt || '').trim();
            if (!/^[A-Za-z0-9-]{1,80}$/.test(requestID) || !prompt
                || new TextEncoder().encode(prompt).length > 20000) return;
            translationUsedForClick = true;
            send({kind:'translation', requestID, prompt});
          }
          function measure(deep) {
            scheduled = false;
            deep = deep === true || scheduledDeep;
            scheduledDeep = false;
            const root = document.documentElement, body = document.body;
            if (!root || !body) return;
            // Measure the body's own box, never scrollHeight/offsetHeight:
            // those never drop below the viewport, so they feed the frame's
            // current height back into the measurement — pinning the frame
            // too tall when content shrinks, or oscillating between the
            // viewport size and the content size and shaking the page.
            const bodyRect = body.getBoundingClientRect();
            const flowHeight = Math.ceil(bodyRect.height);
            // Keep a previously measured overlay open through the resize event
            // caused by enlarging its iframe. Attribute/mutation events request
            // a deep measurement immediately, so closing it still shrinks on
            // the next animation frame.
            let visualHeight = !deep && lastFlowSent >= 0
              && Math.abs(flowHeight - lastFlowSent) < 2
              ? Math.max(flowHeight, lastVisualSent) : flowHeight;
            if (deep) {
              // DOMRect coordinates already include the body's padding. Scan
              // for positioned overflow relative to the body, but do not add
              // paddingBottom again: doing so made the fast and settled paths
              // alternate forever by exactly the 14px wrapper padding.
              let bottom = bodyRect.bottom;
              // Descendants of an overflow-clipping box (line-clamped fold
              // boxes, nested scrollboxes) keep their laid-out client rects
              // even where the box clips them away. Counting that invisible
              // overflow made the settled height thousands of points taller
              // than the body box on OED entries, so the fast and settled
              // paths alternated forever and the resize compensation bounced
              // the outer page on every scroll.
              const clipBottoms = new Map();
              // A bottom-anchored fixed subtree moves when its iframe is made
              // taller. Normalize it back to the flow viewport so measuring
              // the overlay cannot recursively grow the frame.
              const fixedShifts = new Map();
              document.querySelectorAll('*').forEach(element => {
                const style = getComputedStyle(element);
                let fixedShift = fixedShifts.get(element.parentElement) || 0;
                if (style.position === 'fixed') {
                  fixedShift = style.top === 'auto' && style.bottom !== 'auto'
                    ? Math.max(0, innerHeight - flowHeight) : 0;
                  fixedShifts.set(element, fixedShift);
                } else if (fixedShifts.has(element.parentElement)) {
                  fixedShifts.set(element, fixedShift);
                }
                if (style.overflowY !== 'visible') {
                  clipBottoms.set(element, element.getBoundingClientRect().bottom - fixedShift);
                }
                if (style.visibility === 'hidden') return;
                for (const rect of element.getClientRects()) {
                  const rectBottom = rect.bottom - fixedShift;
                  if (rectBottom <= bottom) continue;
                  let clipped = false;
                  for (let p = element.parentElement; p && p !== body; p = p.parentElement) {
                    const clipBottom = clipBottoms.get(p);
                    if (clipBottom !== undefined && rectBottom > clipBottom + 1) {
                      clipped = true;
                      break;
                    }
                  }
                  if (!clipped) bottom = rectBottom;
                }
              });
              visualHeight = Math.max(flowHeight, Math.ceil(bottom - bodyRect.top));
            }
            // Sub-2px churn is ignored: resizing the frame re-fires this very
            // measurement, so tiny deltas would ping-pong the frame height
            // and visibly twitch the card.
            const roundedFlow = Math.ceil(flowHeight);
            const roundedVisual = Math.ceil(visualHeight);
            if (lastFlowSent >= 0 && Math.abs(roundedFlow - lastFlowSent) < 2
                && Math.abs(roundedVisual - lastVisualSent) < 2) return;
            lastFlowSent = roundedFlow;
            lastVisualSent = roundedVisual;
            send({kind:'height', flowHeight:roundedFlow, visualHeight:roundedVisual});
          }
          function requestMeasure(deepSoon) {
            scheduledDeep ||= deepSoon === true;
            if (!scheduled) { scheduled = true; requestAnimationFrame(() => measure(false)); }
            clearTimeout(settleTimer); settleTimer = setTimeout(() => measure(true), 240);
          }
          ready(() => {
            new ResizeObserver(() => requestMeasure(false)).observe(document.documentElement);
            if (document.body) {
              new ResizeObserver(() => requestMeasure(false)).observe(document.body);
              new MutationObserver(records => requestMeasure(records.some(record =>
                record.type === 'attributes' || record.type === 'childList'))).observe(document.body,
                {subtree:true, childList:true, attributes:true, characterData:true});
            }
            document.querySelectorAll('img,video,audio').forEach(item => {
              item.addEventListener('load', () => requestMeasure(true));
              item.addEventListener('error', () => requestMeasure(true));
            });
            document.fonts?.ready.then(() => requestMeasure(true));
            ['click','toggle','input','change','transitionend','animationend'].forEach(name =>
              document.addEventListener(name, () => requestMeasure(true), true));
            requestMeasure(true);
            const anchor = new URLSearchParams(location.search).get('anchor');
            if (anchor) setTimeout(() => {
              let target = document.getElementById(anchor);
              if (!target) { try { target = document.querySelector(`[name="${CSS.escape(anchor)}"]`); } catch (_) {} }
              if (target) send({kind:'scroll', mode:'element', offset:target.getBoundingClientRect().top,
                behavior:'auto'});
            }, 80);
          });
          addEventListener('resize', () => requestMeasure(false));
          visualViewport?.addEventListener('resize', () => requestMeasure(false));
          addEventListener('message', event => {
            if (event.source === window && event.data?.kind === 'lexicon-tts-request') {
              forwardTTSRequest(event.data.detail);
              return;
            }
            if (event.source === window && event.data?.kind === 'lexicon-translation-request') {
              forwardTranslationRequest(event.data.detail);
              return;
            }
            if (event.data?.kind !== 'lexicon-anchor' || typeof event.data.anchor !== 'string') return;
            const anchor = event.data.anchor;
            let target = document.getElementById(anchor);
            if (!target) { try { target = document.querySelector(`[name="${CSS.escape(anchor)}"]`); } catch (_) {} }
            if (target) send({kind:'scroll', mode:'element', offset:target.getBoundingClientRect().top,
              behavior:'auto'});
          });

          addEventListener('click', event => {
            if (!event.isTrusted) return;
            const link = event.target?.closest?.('a[href],area[href]');
            if (!link) return;
            const href = (link.getAttribute('href') || '').trim();
            const lower = href.toLowerCase();
            if (href.startsWith('#') || lower.startsWith('entry://#') || lower.startsWith('bword://#')) {
              const raw = href.startsWith('#') ? href.slice(1) : href.slice(href.indexOf('#') + 1);
              let id = raw; try { id = decodeURIComponent(raw); } catch (_) {}
              const target = document.getElementById(id) || document.querySelector(`[name="${CSS.escape(id)}"]`);
              if (target) send({kind:'scroll', mode:'element', offset:target.getBoundingClientRect().top,
                behavior:getComputedStyle(document.documentElement).scrollBehavior});
              event.preventDefault(); event.stopImmediatePropagation(); return;
            }
            const scheme = href.includes(':') ? href.slice(0, href.indexOf(':')).toLowerCase() : '';
            if (['entry','bword','sound','http','https','mailto'].includes(scheme)) {
              event.preventDefault(); event.stopImmediatePropagation(); send({kind:'link', href});
            }
          }, true);
          addEventListener('dblclick', event => {
            if (!event.isTrusted || event.target?.closest?.('a[href],input,textarea,select,[contenteditable]')) return;
            const word = String(getSelection()?.toString() || '').trim();
            if (word && word.length <= 64 && !/\s/.test(word)) send({kind:'lookup', word});
          }, true);
          addEventListener('wheel', event => {
            if (!event.deltaX && !event.deltaY) return;
            send({kind:'scroll', mode:'by', offset:event.deltaY}); event.preventDefault();
          }, {passive:false, capture:true});
          addEventListener('keydown', event => {
            if (!event.isTrusted || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey
                || event.target?.matches?.('input,textarea,select,[contenteditable]')) return;
            const page = Math.max(120, innerHeight * .85);
            if (event.key === 'PageDown') send({kind:'scroll', mode:'by', offset:page});
            else if (event.key === 'PageUp') send({kind:'scroll', mode:'by', offset:-page});
            else if (event.key === 'Home') send({kind:'scroll', mode:'home'});
            else if (event.key === 'End') send({kind:'scroll', mode:'end'});
            else return;
            event.preventDefault();
          }, true);
          addEventListener('lexicon-scroll-request', event => {
            const detail = event.detail || {};
            send({kind:'scroll', mode:detail.kind === 'by' ? 'by' : 'element', offset:detail.value || 0,
              behavior:detail.behavior || 'auto'});
          });
        })();
        """#

        /// Compatibility adapters for optional services embedded by common
        /// dictionary repacks. Requests are intercepted before credentials or
        /// text can leave the page, then handed to the isolated native bridge.
        static let dictionaryCompatibilityScript = #"""
        (() => {
          const nativeFetch = window.fetch.bind(window);
          const NativeWebSocket = window.WebSocket;
          const pendingTranslations = new Map();
          if (!Number.isFinite(Number(window.__lexiconVirtualScrollY))) {
            window.__lexiconVirtualScrollY = 0;
          }
          if (!Number.isFinite(Number(window.__lexiconVirtualViewportHeight))) {
            window.__lexiconVirtualViewportHeight = window.innerHeight;
          }

          // Dictionary pages live in full-content-height iframes, so their
          // native window scroll offset is always zero even while the outer
          // results page is far down the entry. jQuery-based dictionaries use
          // $(window).scrollTop() around fold/show operations to keep the
          // clicked control stationary. Feed those calls the outer page's
          // dictionary-local offset and route setters back through the narrow
          // scroll compatibility shim.
          function installJQueryScrollAdapter() {
            const jq = window.jQuery;
            if (!jq?.fn || typeof jq.fn.scrollTop !== 'function') return false;
            if (!jq.fn.scrollTop.__lexiconVirtualScroll) {
              const originalScrollTop = jq.fn.scrollTop;
              function adaptedScrollTop(value) {
                const target = this[0];
                const isViewport = target === window || target === document;
                if (!isViewport) return originalScrollTop.apply(this, arguments);
                if (!arguments.length) return Number(window.__lexiconVirtualScrollY) || 0;
                const top = Number(value);
                const current = Number(window.__lexiconVirtualScrollY) || 0;
                const delta = top - current;
                // jQuery dictionaries use a getter/setter pair around a DOM
                // mutation to preserve the clicked control. Treat the result
                // as a relative correction: interpreting it as an absolute
                // iframe offset is what sent the outer page back toward the
                // dictionary's top when WebKit reported a stale zero.
                if (Number.isFinite(delta) && Math.abs(delta) > .5) {
                  window.__lexiconVirtualScrollY = top;
                  window.scrollBy({top:delta, left:0, behavior:'auto'});
                }
                return this;
              }
              Object.defineProperty(adaptedScrollTop, '__lexiconVirtualScroll', {value:true});
              jq.fn.scrollTop = adaptedScrollTop;
            }
            if (typeof jq.fn.height === 'function' && !jq.fn.height.__lexiconVirtualViewport) {
              const originalHeight = jq.fn.height;
              function adaptedHeight(value) {
                const target = this[0];
                if (!arguments.length && (target === window || target === document)) {
                  return Number(window.__lexiconVirtualViewportHeight) || window.innerHeight;
                }
                return originalHeight.apply(this, arguments);
              }
              Object.defineProperty(adaptedHeight, '__lexiconVirtualViewport', {value:true});
              jq.fn.height = adaptedHeight;
            }
            return true;
          }

          let jqueryInstallAttempts = 0;
          const jqueryInstallTimer = setInterval(() => {
            jqueryInstallAttempts += 1;
            if (installJQueryScrollAdapter() || jqueryInstallAttempts >= 200) {
              clearInterval(jqueryInstallTimer);
            }
          }, 50);
          addEventListener('DOMContentLoaded', installJQueryScrollAdapter, {once:true});
          function receiveScrollState(offset, viewportHeight) {
            const next = Number(offset);
            const viewport = Number(viewportHeight);
            if (!Number.isFinite(next) || next < 0) return;
            const changed = Math.abs(next - Number(window.__lexiconVirtualScrollY)) > .5;
            window.__lexiconVirtualScrollY = next;
            if (Number.isFinite(viewport) && viewport > 0) {
              window.__lexiconVirtualViewportHeight = viewport;
            }
            installJQueryScrollAdapter();
            if (changed) dispatchEvent(new Event('scroll'));
          }
          Object.defineProperty(window, '__lexiconReceiveScrollState', {
            value:receiveScrollState, configurable:true
          });

          function safeTranslationMarkup(value, allowDictionaryTags) {
            let text = String(value || '')
              .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
              .replaceAll('"', '&quot;').replaceAll("'", '&#39;');
            if (allowDictionaryTags) {
              // OED intentionally round-trips only these three inert markup
              // tags. Everything else stays escaped before jQuery appends it.
              text = text.replace(/&lt;(\/?)(m|n|o)&gt;/gi, '<$1$2>');
            }
            return text;
          }

          addEventListener('lexicon-translation-response', event => {
            let payload;
            try { payload = JSON.parse(String(event.detail || '')); } catch (_) { return; }
            const pending = pendingTranslations.get(String(payload.requestID || ''));
            if (!pending) return;
            pendingTranslations.delete(payload.requestID);
            clearTimeout(pending.timer);
            if (payload.error) {
              if (pending.kind === 'websocket') pending.socket.fail();
              else pending.resolve(new Response('', {status:502, statusText:'Translation failed'}));
              return;
            }
            if (pending.kind === 'websocket') {
              pending.socket.succeed(safeTranslationMarkup(payload.text, false));
              return;
            }
            const content = safeTranslationMarkup(payload.text, true);
            const chunk = JSON.stringify({choices:[{delta:{content}}]});
            const stream = `data: ${chunk}\n\ndata: [DONE]\n\n`;
            pending.resolve(new Response(stream, {
              status:200,
              headers:{'Content-Type':'text/event-stream; charset=utf-8'}
            }));
          });

          function makeRequestID() {
            return typeof crypto.randomUUID === 'function'
              ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
          }

          function postTranslationRequest(requestID, prompt) {
            window.postMessage({
              kind:'lexicon-translation-request',
              detail:JSON.stringify({requestID, prompt})
            }, '*');
          }

          function requestTranslation(prompt) {
            const requestID = makeRequestID();
            return new Promise(resolve => {
              const timer = setTimeout(() => {
                pendingTranslations.delete(requestID);
                resolve(new Response('', {status:504, statusText:'Translation timed out'}));
              }, 60000);
              pendingTranslations.set(requestID, {kind:'fetch', resolve, timer});
              postTranslationRequest(requestID, prompt);
            });
          }

          class TranslationWebSocket extends EventTarget {
            constructor(url) {
              super();
              this.url = String(url);
              this.protocol = '';
              this.extensions = '';
              this.binaryType = 'blob';
              this.bufferedAmount = 0;
              this._readyState = NativeWebSocket.CONNECTING;
              this.onopen = null;
              this.onmessage = null;
              this.onerror = null;
              this.onclose = null;
              queueMicrotask(() => {
                if (this._readyState !== NativeWebSocket.CONNECTING) return;
                this._readyState = NativeWebSocket.OPEN;
                this._emit('open', new Event('open'));
              });
            }

            get readyState() { return this._readyState; }

            send(data) {
              if (this._readyState !== NativeWebSocket.OPEN) {
                throw new DOMException('WebSocket is not open', 'InvalidStateError');
              }
              let request;
              try { request = JSON.parse(String(data)); } catch (_) { this.fail(); return; }
              const messages = request?.payload?.message?.text;
              const userMessage = Array.isArray(messages)
                ? [...messages].reverse().find(item => item?.role === 'user') : null;
              const prompt = typeof userMessage?.content === 'string'
                ? userMessage.content.trim() : '';
              if (!prompt) { this.fail(); return; }

              const requestID = makeRequestID();
              const timer = setTimeout(() => {
                pendingTranslations.delete(requestID);
                this.fail();
              }, 60000);
              pendingTranslations.set(requestID, {kind:'websocket', socket:this, timer});
              postTranslationRequest(requestID, prompt);
            }

            close(code = 1000, reason = '') {
              if (this._readyState === NativeWebSocket.CLOSED) return;
              this._readyState = NativeWebSocket.CLOSED;
              this._emit('close', new CloseEvent('close', {code, reason, wasClean:code === 1000}));
            }

            succeed(text) {
              if (this._readyState !== NativeWebSocket.OPEN) return;
              // Match the iFlytek Spark/MAAS response shape consumed by the
              // Longman 6 repack. Its existing renderer remains unchanged.
              const data = JSON.stringify({
                header:{code:0, status:2},
                payload:{choices:{status:2, text:[{role:'assistant', content:text, index:0}]}}
              });
              this._emit('message', new MessageEvent('message', {data}));
              this.close();
            }

            fail() {
              if (this._readyState === NativeWebSocket.CLOSED) return;
              this._emit('error', new Event('error'));
              this.close(1011, 'Translation failed');
            }

            _emit(type, event) {
              try { this.dispatchEvent(event); } catch (_) {}
              const handler = this[`on${type}`];
              if (typeof handler === 'function') {
                try { handler.call(this, event); } catch (error) { setTimeout(() => { throw error; }); }
              }
            }
          }

          function isLongmanTranslationSocket(url) {
            try {
              const parsed = new URL(String(url), location.href);
              return parsed.protocol === 'wss:'
                && parsed.hostname.endsWith('.xf-yun.com')
                && parsed.hostname.startsWith('maas-api.')
                && parsed.pathname.endsWith('/chat');
            } catch (_) { return false; }
          }

          function CompatibleWebSocket(url, protocols) {
            if (!new.target) throw new TypeError("Failed to construct 'WebSocket': use 'new'");
            if (isLongmanTranslationSocket(url)) return new TranslationWebSocket(url);
            return protocols === undefined
              ? new NativeWebSocket(url) : new NativeWebSocket(url, protocols);
          }
          CompatibleWebSocket.prototype = NativeWebSocket.prototype;
          Object.defineProperties(CompatibleWebSocket, {
            CONNECTING:{value:NativeWebSocket.CONNECTING}, OPEN:{value:NativeWebSocket.OPEN},
            CLOSING:{value:NativeWebSocket.CLOSING}, CLOSED:{value:NativeWebSocket.CLOSED}
          });
          window.WebSocket = CompatibleWebSocket;

          window.fetch = function(input, init) {
            let url;
            try { url = new URL(typeof input === 'string' ? input : input.url, location.href); }
            catch (_) { return nativeFetch(input, init); }
            const method = String(init?.method || (typeof input !== 'string' && input.method) || 'GET')
              .toUpperCase();
            if (url.protocol === 'https:' && url.hostname === 'tts.dxde.de' && method === 'POST') {
              try {
                const body = typeof init?.body === 'string' ? JSON.parse(init.body) : null;
                if (body && typeof body.text === 'string') {
                  window.postMessage({
                    kind:'lexicon-tts-request',
                    detail:JSON.stringify({text:body.text, language:body.language_code})
                  }, '*');
                  return Promise.resolve(new Response(new Blob([], {type:'audio/mpeg'}), {status:200}));
                }
              } catch (_) {}
            }

            const dashScopeHost = url.hostname === 'dashscope.aliyuncs.com'
              || url.hostname === 'dashscope-intl.aliyuncs.com'
              || url.hostname === 'dashscope-us.aliyuncs.com'
              || url.hostname.endsWith('.maas.aliyuncs.com');
            if (url.protocol === 'https:' && dashScopeHost
                && url.pathname.endsWith('/chat/completions') && method === 'POST') {
              try {
                const body = typeof init?.body === 'string' ? JSON.parse(init.body) : null;
                const messages = Array.isArray(body?.messages) ? body.messages : [];
                const userMessage = [...messages].reverse().find(item => item?.role === 'user');
                if (typeof userMessage?.content === 'string' && userMessage.content.trim()) {
                  // Never forward the dictionary bundle's Authorization header.
                  return requestTranslation(userMessage.content);
                }
              } catch (_) {}
              return Promise.resolve(new Response('', {status:400, statusText:'Invalid translation request'}));
            }
            return nativeFetch(input, init);
          };
        })();
        """#
    }
}
