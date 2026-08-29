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
    private static var floatingOverlayCheckStarted = false
    private static var floatingOverlayPassed = false
    private static var scrollCompatibilityCheckStarted = false
    private static var scrollCompatibilityPassed = false
    private static var scrollSweepCheckStarted = false
    private static var scrollSweepPassed = false
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
        bridge.diagnosticHandler = { uuid, payload, _ in
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
            let hasJQuery = payload["hasJQuery"] as? Bool ?? false
            diagnostics[uuid] = Diagnostic(
                styles: styles, reverseColor: reverseColor, lm6Font: lm6Font, lm6JS: lm6JS,
                lm6WordSetItems: lm6WordSetItems, lm6WordSetVisible: lm6WordSetVisible,
                hasJQuery: hasJQuery
            )
        }
        coordinator = bridge

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            bridge,
            contentWorld: EntryWebView.Coordinator.bridgeWorld,
            name: EntryWebView.Coordinator.bridgeMessageName
        )
        configuration.userContentController.add(
            bridge,
            contentWorld: .page,
            name: EntryWebView.Coordinator.pageGeometryMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: EntryWebView.Coordinator.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: EntryWebView.Coordinator.bridgeWorld
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: EntryWebView.Coordinator.dictionaryCompatibilityScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            setTimeout(() => {
              document.documentElement.dataset.lexiconSmokeLm6 =
                typeof window.lm6cf === 'object' ? '1' : '0';
              document.documentElement.dataset.lexiconSmokeJQuery =
                typeof window.jQuery === 'function' ? '1' : '0';
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
                dictionaryRoot:window !== top && parent === top,
                styles:Array.from(document.styleSheets).map(s => s.href || 'inline'),
                reverseColor:reverse ? getComputedStyle(reverse).color : '',
                lm6Font:lm6 ? getComputedStyle(lm6).fontFamily : '',
                lm6JS:document.documentElement.dataset.lexiconSmokeLm6 === '1',
                lm6WordSetItems:lm6WordSet?.querySelectorAll('a[href]').length || 0,
                lm6WordSetVisible:!!lm6WordSet && getComputedStyle(lm6WordSet).display !== 'none',
                hasJQuery:document.documentElement.dataset.lexiconSmokeJQuery === '1'
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
                    dictionaryRoot:window !== top && parent === top,
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
                    guard floatingOverlayPassed else {
                        if !floatingOverlayCheckStarted {
                            startFloatingOverlayCheck(frames: frames)
                        }
                        return
                    }
                    guard scrollCompatibilityPassed else {
                        if !scrollCompatibilityCheckStarted {
                            startScrollCompatibilityCheck(frames: frames)
                        }
                        return
                    }
                    guard scrollSweepPassed else {
                        if !scrollSweepCheckStarted { startScrollSweepCheck() }
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
                  window.__lexiconSetFrameHeight = (uuid, requestedFlow, requestedVisual) => {
                    const id = String(uuid).toLowerCase();
                    const height = Number(requestedFlow) || 44;
                    const range = window.__lexiconStabilityRanges.get(id) || {uuid:id, min:height, max:height};
                    range.min = Math.min(range.min, height); range.max = Math.max(range.max, height);
                    window.__lexiconStabilityRanges.set(id, range);
                    return original(uuid, requestedFlow, requestedVisual);
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

    /// Oxford repacks place expandable/hoverable controls in absolute and
    /// fixed hosts. Reproduce both shapes and require the iframe to grow above
    /// following dictionaries while its in-flow slot remains unchanged.
    private static func startFloatingOverlayCheck(frames: [Frame]) {
        guard let webView,
              let target = frames.first,
              let frameInfo = coordinator?.dictionaryFrameInfo(for: target.uuid)
        else {
            floatingOverlayPassed = true
            return
        }
        floatingOverlayCheckStarted = true
        Task { @MainActor in
            do {
                let baselineValue = try await webView.evaluateJavaScript("""
                (() => {
                  const frame = document.querySelector('iframe[data-uuid="\(target.uuid)"]');
                  const slot = frame?.parentElement;
                  return JSON.stringify({frame:frame?.getBoundingClientRect().height || 0,
                    slot:slot?.getBoundingClientRect().height || 0});
                })()
                """)
                guard let baselineJSON = baselineValue as? String,
                      let baselineData = baselineJSON.data(using: .utf8),
                      let baseline = try JSONSerialization.jsonObject(with: baselineData)
                        as? [String: Any],
                      let baselineFrame = (baseline["frame"] as? NSNumber)?.doubleValue,
                      let baselineSlot = (baseline["slot"] as? NSNumber)?.doubleValue
                else { throw SmokeError.invalidFloatingOverlayGeometry }
                _ = try await callPageNumber(
                    in: webView,
                    """
                    const host = document.createElement('div');
                    host.id = 'lexicon-fixed-overlay-probe';
                    host.style.cssText = 'position:fixed;left:0;bottom:0;width:20px;height:20px';
                    const popup = document.createElement('div');
                    popup.style.cssText = 'position:absolute;top:100%;left:0;width:20px;height:600px';
                    host.appendChild(popup);
                    document.body.appendChild(host);
                    const anchored = document.createElement('div');
                    anchored.id = 'lexicon-absolute-overlay-probe';
                    anchored.style.cssText = 'position:absolute;left:24px;top:'
                      + Math.max(0, document.body.getBoundingClientRect().height, innerHeight) + 'px;'
                      + 'width:20px;height:20px';
                    const menu = document.createElement('div');
                    menu.style.cssText = 'position:relative;top:100%;width:20px;height:600px';
                    anchored.appendChild(menu);
                    document.body.appendChild(anchored);
                    return 1;
                    """,
                    frameInfo: frameInfo
                )
                try await Task.sleep(for: .seconds(1))
                let value = try await webView.evaluateJavaScript("""
                (() => {
                  const frame = document.querySelector('iframe[data-uuid="\(target.uuid)"]');
                  const slot = frame?.parentElement;
                  return JSON.stringify({frame:frame?.getBoundingClientRect().height || 0,
                    slot:slot?.getBoundingClientRect().height || 0,
                    overlay:slot?.dataset.overlay === '1', z:slot ? getComputedStyle(slot).zIndex : ''});
                })()
                """)
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let geometry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let overlayFrame = (geometry["frame"] as? NSNumber)?.doubleValue,
                      let overlaySlot = (geometry["slot"] as? NSNumber)?.doubleValue,
                      geometry["overlay"] as? Bool == true,
                      geometry["z"] as? String == "20"
                else { throw SmokeError.invalidFloatingOverlayGeometry }
                _ = try await callPageNumber(
                    in: webView,
                    """
                    document.getElementById('lexicon-fixed-overlay-probe')?.remove();
                    document.getElementById('lexicon-absolute-overlay-probe')?.remove();
                    return 1;
                    """,
                    frameInfo: frameInfo
                )
                try await Task.sleep(for: .milliseconds(500))
                guard abs(overlaySlot - baselineSlot) <= 1,
                      overlayFrame > baselineFrame + 400
                else {
                    print(
                        "SMOKE FAIL: floating popup did not overlay its stable slot: "
                            + "frame \(baselineFrame) -> \(overlayFrame), "
                            + "slot \(baselineSlot) -> \(overlaySlot)"
                    )
                    exit(1)
                }
                floatingOverlayPassed = true
            } catch {
                print("SMOKE FAIL: floating-popup check errored: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// Reproduces the contract used by Longman/OED controls: read jQuery's
    /// window scrollTop, change content, then set a corrected value. In a
    /// full-height iframe the native value is always zero, so this verifies
    /// that the page-world adapter receives and controls the outer scroll.
    private static func startScrollCompatibilityCheck(frames: [Frame]) {
        guard let webView else { return }
        scrollCompatibilityCheckStarted = true
        let viewportHeight = Double(webView.bounds.height)
        guard let target = frames.first(where: {
            $0.height > viewportHeight + 400
                && diagnostics[$0.uuid]?.hasJQuery == true
                && coordinator?.dictionaryFrameInfo(for: $0.uuid) != nil
        }), let frameInfo = coordinator?.dictionaryFrameInfo(for: target.uuid) else {
            // Tiny fixture dictionaries may have neither jQuery nor enough
            // content to scroll within; the compatibility path is inapplicable.
            scrollCompatibilityPassed = true
            return
        }
        Task { @MainActor in
            do {
                let outerValue = try await webView.evaluateJavaScript("""
                (() => {
                  const frame=document.querySelector('iframe[data-uuid="\(target.uuid)"]');
                  if (!frame) return -1;
                  const top=frame.getBoundingClientRect().top + scrollY;
                  scrollTo(0, top + 220);
                  return scrollY;
                })()
                """)
                guard let outerStart = (outerValue as? NSNumber)?.doubleValue, outerStart >= 0 else {
                    print("SMOKE FAIL: could not position the outer page for scroll compatibility")
                    exit(1)
                }
                try await Task.sleep(for: .milliseconds(250))
                let adapter = try await callPageNumber(
                    in: webView,
                    "return window.jQuery?.fn?.scrollTop?.__lexiconVirtualScroll ? 1 : 0;",
                    frameInfo: frameInfo
                )
                guard adapter == 1 else {
                    print("SMOKE FAIL: dictionary jQuery scroll adapter was not installed")
                    exit(1)
                }
                _ = try await callPageNumber(
                    in: webView,
                    "window.jQuery(window).scrollTop(window.jQuery(window).scrollTop() + 120); return 1;",
                    frameInfo: frameInfo
                )
                try await Task.sleep(for: .milliseconds(250))
                let finalValue = try await webView.evaluateJavaScript("scrollY")
                guard let outerEnd = (finalValue as? NSNumber)?.doubleValue,
                      abs(outerEnd - outerStart - 120) < 4
                else {
                    print(
                        "SMOKE FAIL: dictionary scroll setter jumped unexpectedly: "
                            + String(describing: finalValue)
                    )
                    exit(1)
                }
                scrollCompatibilityPassed = true
            } catch {
                print("SMOKE FAIL: scroll compatibility check errored: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// Reproduces a downward scroll gesture through the whole results page.
    /// Dictionary scroll handlers react to the synthetic per-frame scroll
    /// events; their floating chrome must not feed back into frame heights,
    /// and the page must never be yanked back up while scrolling down.
    private static func startScrollSweepCheck() {
        guard let webView else { return }
        scrollSweepCheckStarted = true
        Task { @MainActor in
            do {
                _ = try await webView.evaluateJavaScript("""
                (() => {
                  const frames = Array.from(document.querySelectorAll('iframe[data-uuid]'));
                  if (!window.__lexiconStabilityRanges) return false;
                  window.__lexiconStabilityRanges = new Map(frames.map(frame => {
                    const height = frame.getBoundingClientRect().height;
                    return [frame.dataset.uuid || '', {uuid:frame.dataset.uuid || '', min:height, max:height}];
                  }));
                  return true;
                })()
                """)
                let maxValue = try await webView.evaluateJavaScript(
                    "document.documentElement.scrollHeight - innerHeight"
                )
                guard let maxScroll = (maxValue as? NSNumber)?.doubleValue, maxScroll > 0 else {
                    scrollSweepPassed = true
                    return
                }
                var previousY = 0.0
                var y = 0.0
                while y <= maxScroll {
                    _ = try await webView.evaluateJavaScript("""
                    (() => { scrollTo(0, \(y)); return scrollY; })()
                    """)
                    try await Task.sleep(for: .milliseconds(320))
                    let settled = try await webView.evaluateJavaScript(
                        "JSON.stringify({y: scrollY, h: Array.from(document.querySelectorAll('iframe[data-uuid]')).map(f => Math.round(f.getBoundingClientRect().height))})"
                    )
                    let currentY = ((settled as? String)
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
                        .flatMap { ($0["y"] as? NSNumber)?.doubleValue } ?? y
                    print("SWEEP target=\(Int(y)) actual=\(Int(currentY)) "
                        + "\((settled as? String) ?? "")")
                    if currentY < previousY - 8 || currentY < y - 8 {
                        print("SMOKE FAIL: page bounced back during downward scroll: "
                            + "target=\(y) actual=\(currentY) previous=\(previousY)")
                        exit(1)
                    }
                    previousY = currentY
                    y += 500
                }
                let value = try await webView.evaluateJavaScript(
                    "JSON.stringify(Array.from(window.__lexiconStabilityRanges?.values?.() || []))"
                )
                guard let json = value as? String,
                      let data = json.data(using: .utf8),
                      let ranges = try? JSONDecoder().decode([HeightRange].self, from: data)
                else {
                    print("SMOKE FAIL: could not sample scroll-sweep stability: invalid result")
                    exit(1)
                }
                let unstable = ranges.filter { $0.max - $0.min > 1 }
                guard unstable.isEmpty else {
                    print("SMOKE FAIL: iframe heights oscillated during scroll: \(unstable)")
                    exit(1)
                }
                scrollSweepPassed = true
            } catch {
                print("SMOKE FAIL: scroll sweep errored: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private static func callPageNumber(
        in webView: WKWebView, _ source: String, frameInfo: WKFrameInfo
    ) async throws -> Double {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Double, Error>) in
            webView.callAsyncJavaScript(
                source, arguments: [:], in: frameInfo, in: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let number = value as? NSNumber else {
                        continuation.resume(throwing: SmokeError.nonNumericJavaScriptResult)
                        return
                    }
                    continuation.resume(returning: number.doubleValue)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private enum SmokeError: Error {
        case invalidFloatingOverlayGeometry
        case nonNumericJavaScriptResult
    }

    private struct Diagnostic: CustomStringConvertible {
        let styles: [String]
        let reverseColor: String
        let lm6Font: String
        let lm6JS: Bool
        let lm6WordSetItems: Int
        let lm6WordSetVisible: Bool
        let hasJQuery: Bool
        var description: String {
            "styles=\(styles), reverseColor=\(reverseColor), lm6Font=\(lm6Font), lm6JS=\(lm6JS), "
                + "lm6WordSetItems=\(lm6WordSetItems), lm6WordSetVisible=\(lm6WordSetVisible), "
                + "hasJQuery=\(hasJQuery)"
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
