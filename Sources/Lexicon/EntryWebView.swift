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
        controller.addUserScript(WKUserScript(
            source: Coordinator.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Coordinator.bridgeWorld
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
        coordinator.schemeHandler = nil
        coordinator.diagnosticHandler = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let bridgeMessageName = "lexiconBridge"
        static let bridgeWorld = WKContentWorld.world(name: "LexiconBridge")

        let tabID: UUID
        var appState: AppState
        var libraryModel: LibraryModel
        var schemeHandler: DictSchemeHandler?
        var networkPolicyOverride: LibraryModel.DictionaryNetworkPolicy?
        /// Test-only observer used by the offscreen WebKit harness. Production
        /// pages never receive the diagnostic user script that emits it.
        var diagnosticHandler: ((String, [String: Any]) -> Void)?
        private var loadedToken: String?

        init(tabID: UUID, appState: AppState, libraryModel: LibraryModel) {
            self.tabID = tabID
            self.appState = appState
            self.libraryModel = libraryModel
        }

        func load(
            word: String?, anchor: String?, preferredDictionaryUUID: String?,
            initialScrollOffset: Double,
            version: Int, into webView: WKWebView, force: Bool
        ) {
            let token = "\(version)|\(word ?? "")|\(anchor ?? "")|\(preferredDictionaryUUID ?? "")"
            guard force || token != loadedToken else { return }
            loadedToken = token
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
            }
            #endif
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.bridgeMessageName,
                  let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String,
                  let frameURL = message.frameInfo.request.url,
                  frameURL.scheme?.lowercased() == DictSchemeHandler.scheme,
                  let host = frameURL.host?.lowercased()
            else { return }

            if host == "page" {
                if kind == "pageScroll", let offset = payload["offset"] as? Double {
                    recordPageScroll(offset)
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

            switch kind {
            case "diagnostic":
                diagnosticHandler?(host, payload)

            case "height":
                guard let height = payload["height"] as? Double else { return }
                let script = "window.__lexiconSetFrameHeight?.('\(host)',\(height));"
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
          const send = payload => { try { webkit.messageHandlers.lexiconBridge.postMessage(payload); } catch (_) {} };
          const host = location.hostname.toLowerCase();
          const ready = callback => document.readyState === 'loading'
            ? addEventListener('DOMContentLoaded', callback, {once:true}) : callback();

          if (host === 'page') {
            ready(() => {
              document.querySelectorAll('details[data-uuid]').forEach(card => {
                card.addEventListener('toggle', () => send({kind:'collapse', dictionaryUUID:card.dataset.uuid,
                  collapsed:!card.open}));
              });
              let pending = false;
              addEventListener('scroll', () => {
                if (pending) return; pending = true;
                requestAnimationFrame(() => { pending = false; send({kind:'pageScroll', offset:scrollY}); });
              }, {passive:true});
            });
            return;
          }

          let scheduled = false, settleTimer = 0, lastSent = -1;
          function measure(deep) {
            scheduled = false;
            const root = document.documentElement, body = document.body;
            if (!root || !body) return;
            // Measure the body's own box, never scrollHeight/offsetHeight:
            // those never drop below the viewport, so they feed the frame's
            // current height back into the measurement — pinning the frame
            // too tall when content shrinks, or oscillating between the
            // viewport size and the content size and shaking the page.
            const bodyRect = body.getBoundingClientRect();
            let height = Math.ceil(bodyRect.height);
            if (deep) {
              // DOMRect coordinates already include the body's padding. Scan
              // for positioned overflow relative to the body, but do not add
              // paddingBottom again: doing so made the fast and settled paths
              // alternate forever by exactly the 14px wrapper padding.
              let bottom = bodyRect.bottom;
              document.querySelectorAll('*').forEach(element => {
                const style = getComputedStyle(element);
                if (style.visibility === 'hidden' || style.position === 'fixed') return;
                for (const rect of element.getClientRects()) bottom = Math.max(bottom, rect.bottom);
              });
              height = Math.max(height, Math.ceil(bottom - bodyRect.top));
            }
            // Sub-2px churn is ignored: resizing the frame re-fires this very
            // measurement, so tiny deltas would ping-pong the frame height
            // and visibly twitch the card.
            const rounded = Math.ceil(height);
            if (lastSent >= 0 && Math.abs(rounded - lastSent) < 2) return;
            lastSent = rounded;
            send({kind:'height', height:rounded});
          }
          function requestMeasure() {
            if (!scheduled) { scheduled = true; requestAnimationFrame(() => measure(false)); }
            clearTimeout(settleTimer); settleTimer = setTimeout(() => measure(true), 240);
          }
          ready(() => {
            new ResizeObserver(requestMeasure).observe(document.documentElement);
            if (document.body) {
              new ResizeObserver(requestMeasure).observe(document.body);
              new MutationObserver(requestMeasure).observe(document.body,
                {subtree:true, childList:true, attributes:true, characterData:true});
            }
            document.querySelectorAll('img,video,audio').forEach(item => {
              item.addEventListener('load', requestMeasure); item.addEventListener('error', requestMeasure);
            });
            document.fonts?.ready.then(requestMeasure);
            ['click','toggle','input','change','transitionend','animationend'].forEach(name =>
              document.addEventListener(name, requestMeasure, true));
            requestMeasure();
            const anchor = new URLSearchParams(location.search).get('anchor');
            if (anchor) setTimeout(() => {
              let target = document.getElementById(anchor);
              if (!target) { try { target = document.querySelector(`[name="${CSS.escape(anchor)}"]`); } catch (_) {} }
              if (target) send({kind:'scroll', mode:'element', offset:target.getBoundingClientRect().top,
                behavior:'auto'});
            }, 80);
          });
          addEventListener('resize', requestMeasure);
          visualViewport?.addEventListener('resize', requestMeasure);
          addEventListener('message', event => {
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
    }
}
