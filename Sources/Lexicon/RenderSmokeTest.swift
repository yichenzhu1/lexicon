import AppKit
import Foundation
import MdxKit
import WebKit

/// Offscreen WebKit verification for the cross-origin renderer. Entry-frame
/// contents are intentionally unreadable from the app-owned page; readiness is
/// therefore observed through the same isolated height bridge used in-app.
@MainActor
enum RenderSmokeTest {
    private static var webView: WKWebView?
    private static var coordinator: EntryWebView.Coordinator?
    private static var attempts = 0
    private static var resizePhase = 0
    private static var baselineHeights: [Double] = []
    private static var stabilityCheckStarted = false
    private static var stabilityPassed = false
    private static var diagnostics: [String: Diagnostic] = [:]
    private static let word = ProcessInfo.processInfo.environment["LEXICON_SMOKE_WORD"] ?? "apple"
    private static let resizeCycle = ProcessInfo.processInfo.environment["LEXICON_SMOKE_RESIZE_CYCLE"] == "1"
    /// Geometry probe: LEXICON_SMOKE_PROBE=1 [LEXICON_SMOKE_SIZE=1230x950]
    /// reports outer card rects and per-frame content bottoms, to diagnose
    /// oversized iframes (blank tails) without guessing.
    private static let probe = ProcessInfo.processInfo.environment["LEXICON_SMOKE_PROBE"] == "1"
    private static var probeReports: [String: String] = [:]

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = LibraryModel()
        guard model.library != nil, !model.dictionaries.isEmpty else {
            print("SMOKE FAIL: library unavailable or empty")
            exit(1)
        }
        let state = AppState(libraryModel: model)
        let bridge = EntryWebView.Coordinator(
            tabID: state.activeTabID, appState: state, libraryModel: model
        )
        // Installed dictionaries may contain arbitrary remote scripts. The
        // smoke test only needs to prove local loading/execution, so never let
        // it make an outbound request regardless of the user's saved policy.
        // LEXICON_SMOKE_ONLINE=1 lifts this to reproduce online-only layout bugs.
        if ProcessInfo.processInfo.environment["LEXICON_SMOKE_ONLINE"] != "1" {
            bridge.networkPolicyOverride = .offlineOnly
        }
        bridge.diagnosticHandler = { uuid, payload in
            if let report = payload["probe"] as? String {
                probeReports[uuid] = report
                return
            }
            let styles = payload["styles"] as? [String] ?? []
            let reverseColor = payload["reverseColor"] as? String ?? ""
            let lm6Font = payload["lm6Font"] as? String ?? ""
            let lm6JS = payload["lm6JS"] as? Bool ?? false
            let lm6WordSetItems = payload["lm6WordSetItems"] as? Int ?? 0
            let lm6WordSetVisible = payload["lm6WordSetVisible"] as? Bool ?? false
            diagnostics[uuid] = Diagnostic(
                styles: styles, reverseColor: reverseColor, lm6Font: lm6Font, lm6JS: lm6JS,
                lm6WordSetItems: lm6WordSetItems, lm6WordSetVisible: lm6WordSetVisible
            )
        }
        coordinator = bridge

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            bridge,
            contentWorld: EntryWebView.Coordinator.bridgeWorld,
            name: EntryWebView.Coordinator.bridgeMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: EntryWebView.Coordinator.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: EntryWebView.Coordinator.bridgeWorld
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            setTimeout(() => {
              document.documentElement.dataset.lexiconSmokeLm6 =
                typeof window.lm6cf === 'object' ? '1' : '0';
            }, 500);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            setTimeout(() => {
              if (location.host === 'page') return;
              const reverse = document.querySelector('.leon-zh-en .headw');
              const lm6 = document.querySelector('.lm6');
              const lm6WordSet = document.querySelector('body > .category.lm6 > .content');
              webkit.messageHandlers.lexiconBridge.postMessage({
                kind:'diagnostic',
                styles:Array.from(document.styleSheets).map(s => s.href || 'inline'),
                reverseColor:reverse ? getComputedStyle(reverse).color : '',
                lm6Font:lm6 ? getComputedStyle(lm6).fontFamily : '',
                lm6JS:document.documentElement.dataset.lexiconSmokeLm6 === '1',
                lm6WordSetItems:lm6WordSet?.querySelectorAll('a[href]').length || 0,
                lm6WordSetVisible:!!lm6WordSet && getComputedStyle(lm6WordSet).display !== 'none'
              });
            }, 700);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: EntryWebView.Coordinator.bridgeWorld
        ))
        if probe {
            configuration.userContentController.addUserScript(WKUserScript(
                source: """
                setTimeout(() => {
                  if (location.host === 'page') return;
                  const de = document.documentElement, b = document.body;
                  let bottom = 0, deepest = '';
                  document.querySelectorAll('*').forEach(el => {
                    for (const rect of el.getClientRects()) {
                      if (rect.bottom > bottom) {
                        bottom = rect.bottom;
                        deepest = el.tagName.toLowerCase() + '.' + String(el.className).slice(0, 40);
                      }
                    }
                  });
                  const hidden = Array.from(document.querySelectorAll('*')).filter(
                    el => getComputedStyle(el).display === 'none').length;
                  webkit.messageHandlers.lexiconBridge.postMessage({ kind:'diagnostic',
                    probe:'scrollH=' + de.scrollHeight + ' bodyH=' + (b ? b.scrollHeight : 0)
                      + ' deepestBottom=' + Math.round(bottom) + ' deepest=' + deepest
                      + ' elements=' + document.querySelectorAll('*').length
                      + ' displayNone=' + hidden });
                }, 900);
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false,
                in: EntryWebView.Coordinator.bridgeWorld
            ))
        }
        let handler = DictSchemeHandler(libraryModel: model)
        handler.allowHTTPS = ProcessInfo.processInfo.environment["LEXICON_SMOKE_ONLINE"] == "1"
        bridge.schemeHandler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: DictSchemeHandler.scheme)

        let probeSize = ProcessInfo.processInfo.environment["LEXICON_SMOKE_SIZE"]?
            .split(separator: "x").compactMap { Double($0) }
        let viewSize = NSSize(
            width: probeSize?.first ?? 900,
            height: probeSize?.count ?? 0 > 1 ? probeSize?[1] ?? 1400 : 1400
        )
        let view = WKWebView(frame: NSRect(origin: .zero, size: viewSize), configuration: configuration)
        view.navigationDelegate = bridge
        webView = view
        bridge.load(
            word: DictionaryLibrary.normalizeKey(word), anchor: nil,
            preferredDictionaryUUID: nil, initialScrollOffset: 0,
            version: 0, into: view, force: true
        )
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in poll() }
        }
        app.run()
        exit(0)
    }

    private static func poll() {
        attempts += 1
        guard let webView else { return }
        webView.evaluateJavaScript("""
        JSON.stringify(Array.from(document.querySelectorAll('iframe')).map(f => ({
          uuid:f.dataset.uuid || '', src:f.getAttribute('src') || '', height:parseFloat(f.style.height)||0,
          state:f.dataset.sizeState || '', isolated:f.contentDocument === null
        })))
        """) { value, error in
            Task { @MainActor in
                guard error == nil, let json = value as? String,
                      let data = json.data(using: .utf8),
                      let frames = try? JSONDecoder().decode([Frame].self, from: data),
                      !frames.isEmpty
                else {
                    if attempts > 30 { print("SMOKE FAIL: results page did not load"); exit(1) }
                    return
                }
                let ready = frames.allSatisfy {
                    !$0.src.isEmpty && $0.height > 44 && $0.state.hasPrefix("ok:") && $0.isolated
                }
                let styleReady = frames.allSatisfy { diagnostics[$0.uuid] != nil }
                let probeReady = !probe || frames.allSatisfy { probeReports[$0.uuid] != nil }
                if ready && styleReady && probeReady {
                    if resizeCycle, resizePhase == 1 {
                        let changed = zip(frames.map(\.height), baselineHeights).contains {
                            abs($0.0 - $0.1) > 10
                        }
                        if !changed {
                            if attempts > 30 {
                                print("SMOKE FAIL: resize/zoom did not produce a new stable height")
                                exit(1)
                            }
                            return
                        }
                    }
                    guard stabilityPassed else {
                        if !stabilityCheckStarted { startStabilityCheck() }
                        return
                    }
                    if word == "苹果" {
                        let reverse = diagnostics.values.first {
                            $0.styles.contains(where: { $0.hasSuffix("/oaldzh.css") })
                        }
                        let appliedColor = reverse?.reverseColor ?? ""
                        guard !appliedColor.isEmpty,
                              appliedColor != "rgb(0, 0, 0)",
                              appliedColor != "rgb(255, 255, 255)"
                        else {
                            print("SMOKE FAIL: oaldzh.css did not style reverse lookup: \(diagnostics)")
                            exit(1)
                        }
                    }
                    if word == "apple" {
                        guard diagnostics.values.contains(where: {
                            $0.styles.contains(where: { $0.hasSuffix("/lm6.css") })
                                && $0.lm6Font.lowercased().contains("lm6font") && $0.lm6JS
                        }) else {
                            print("SMOKE FAIL: lm6.css/lm6.js did not load: \(diagnostics)")
                            exit(1)
                        }
                    }
                    if word == "word-set-transport" {
                        guard diagnostics.values.contains(where: {
                            $0.lm6WordSetVisible && $0.lm6WordSetItems > 100
                        }) else {
                            print("SMOKE FAIL: Longman word-set content stayed hidden: \(diagnostics)")
                            exit(1)
                        }
                    }
                    if resizeCycle, resizePhase == 0 {
                        baselineHeights = frames.map(\.height)
                        resizePhase = 1
                        attempts = 0
                        stabilityCheckStarted = false
                        stabilityPassed = false
                        webView.frame.size.width = 620
                        webView.pageZoom = 1.35
                        return
                    }
                    if resizeCycle, resizePhase == 1 {
                        print("SMOKE RESIZE: \(baselineHeights) -> \(frames.map(\.height))")
                    }
                    frames.forEach { print("frame \($0.uuid): height=\($0.height) src=\($0.src)") }
                    diagnostics.forEach { print("styles \($0.key): \($0.value)") }
                    if probe {
                        probeReports.forEach { print("probe \($0.key): \($0.value)") }
                        Task { @MainActor in
                            let value = try? await webView.evaluateJavaScript("""
                            JSON.stringify(Array.from(document.querySelectorAll('details[data-uuid]')).map(d => ({
                              uuid:d.dataset.uuid, open:d.open,
                              top:Math.round(d.getBoundingClientRect().top + scrollY),
                              height:Math.round(d.getBoundingClientRect().height)
                            })))
                            """)
                            print("cards: \(value ?? "")")
                            print("SMOKE OK: \(frames.count) isolated dictionary frames rendered")
                            exit(0)
                        }
                        return
                    }
                    print("SMOKE OK: \(frames.count) isolated dictionary frames rendered")
                    exit(0)
                }
                if attempts > 30 {
                    print("SMOKE FAIL: frames did not report stable heights: \(frames)")
                    exit(1)
                }
            }
        }
    }

    /// Record every height assignment rather than accepting the first
    /// plausible value. The old 14px feedback loop only occupied a single
    /// display frame at a time, so the previous 400ms poll could miss it.
    private static func startStabilityCheck() {
        guard let webView else { return }
        stabilityCheckStarted = true
        Task { @MainActor in
            do {
                _ = try await webView.evaluateJavaScript("""
                (() => {
                  const frames = Array.from(document.querySelectorAll('iframe[data-uuid]'));
                  window.__lexiconStabilityRanges = new Map(frames.map(frame => {
                    const height = frame.getBoundingClientRect().height;
                    return [frame.dataset.uuid || '', {uuid:frame.dataset.uuid || '', min:height, max:height}];
                  }));
                  window.__lexiconOriginalSetFrameHeight ||= window.__lexiconSetFrameHeight;
                  const original = window.__lexiconOriginalSetFrameHeight;
                  window.__lexiconSetFrameHeight = (uuid, requested) => {
                    const id = String(uuid).toLowerCase(), height = Number(requested) || 44;
                    const range = window.__lexiconStabilityRanges.get(id) || {uuid:id, min:height, max:height};
                    range.min = Math.min(range.min, height); range.max = Math.max(range.max, height);
                    window.__lexiconStabilityRanges.set(id, range);
                    return original(uuid, requested);
                  };
                  return true;
                })()
                """)
                try await Task.sleep(for: .seconds(2))
                let value = try await webView.evaluateJavaScript(
                    "JSON.stringify(Array.from(window.__lexiconStabilityRanges?.values?.() || []))"
                )
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let ranges = try? JSONDecoder().decode([HeightRange].self, from: data),
                      !ranges.isEmpty
                else {
                    print("SMOKE FAIL: could not sample iframe stability: invalid result")
                    exit(1)
                }
                let unstable = ranges.filter { $0.max - $0.min > 1 }
                guard unstable.isEmpty else {
                    print("SMOKE FAIL: iframe heights oscillated: \(unstable)")
                    exit(1)
                }
                stabilityPassed = true
            } catch {
                print("SMOKE FAIL: could not sample iframe stability: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private struct Diagnostic: CustomStringConvertible {
        let styles: [String]
        let reverseColor: String
        let lm6Font: String
        let lm6JS: Bool
        let lm6WordSetItems: Int
        let lm6WordSetVisible: Bool
        var description: String {
            "styles=\(styles), reverseColor=\(reverseColor), lm6Font=\(lm6Font), lm6JS=\(lm6JS), "
                + "lm6WordSetItems=\(lm6WordSetItems), lm6WordSetVisible=\(lm6WordSetVisible)"
        }
    }

    private struct Frame: Codable, CustomStringConvertible {
        let uuid: String
        let src: String
        let height: Double
        let state: String
        let isolated: Bool
        var description: String { "\(uuid):\(height):\(state):isolated=\(isolated)" }
    }

    private struct HeightRange: Codable, CustomStringConvertible {
        let uuid: String
        let min: Double
        let max: Double
        var description: String { "\(uuid):\(min)...\(max)" }
    }
}
