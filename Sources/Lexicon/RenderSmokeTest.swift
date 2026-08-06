import AppKit
import Foundation
import MdxKit
import WebKit

/// Headless verification of the WebKit pipeline: loads the real results page
/// for a word in an offscreen WKWebView and checks, via JavaScript, that
/// every dictionary iframe was served by the dict:// scheme handler, is
/// same-origin readable, auto-sized, and that its image resources loaded.
///
/// Run with:
///   LEXICON_ROOT=<library root> Lexicon --smoke-test
/// Optional:
///   LEXICON_SMOKE_WORD=<word>       (default "apple")
///   LEXICON_SMOKE_EXPECT=<substr>   text every frame must contain
///                                   (default "a round fruit", the fixture
///                                   content; set to "" to only require
///                                   non-empty rendering)
///   LEXICON_SMOKE_RESIZE_CYCLE=1    grow then shrink every entry frame and
///                                   verify both sizes settle without clipping
@MainActor
enum RenderSmokeTest {
    private static var webView: WKWebView?
    private static var attempts = 0
    private static var resizePhase = 0
    private static var baselineHeights: [Double] = []

    private static let word = ProcessInfo.processInfo.environment["LEXICON_SMOKE_WORD"] ?? "apple"
    private static let expected = ProcessInfo.processInfo.environment["LEXICON_SMOKE_EXPECT"] ?? "a round fruit"
    /// Optional JS function body "(doc) => string" evaluated per frame; when
    /// LEXICON_SMOKE_PROBE_EQUAL=1, all frames must report the same value.
    private static let probeJS = ProcessInfo.processInfo.environment["LEXICON_SMOKE_PROBE"] ?? ""
    private static let probeMustMatch = ProcessInfo.processInfo.environment["LEXICON_SMOKE_PROBE_EQUAL"] == "1"
    private static let shouldTestResizeCycle =
        ProcessInfo.processInfo.environment["LEXICON_SMOKE_RESIZE_CYCLE"] == "1"

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let libraryModel = LibraryModel()
        guard let library = libraryModel.library else {
            print("SMOKE FAIL: library unavailable")
            exit(1)
        }
        guard (try? library.dictionaries())?.isEmpty == false else {
            print("SMOKE FAIL: library has no dictionaries (seed it first)")
            exit(1)
        }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            DictSchemeHandler(libraryModel: libraryModel), forURLScheme: DictSchemeHandler.scheme
        )
        // Collect JS errors in every frame for reporting.
        let errorCollector = WKUserScript(
            source: "window.__errs = []; window.onerror = function (m, s, l) { window.__errs.push(String(m) + ' @' + String(s) + ':' + String(l)); };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(errorCollector)

        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 1400),
            configuration: configuration
        )
        webView = view

        let normalized = DictionaryLibrary.normalizeKey(word)
        let html = EntryPageBuilder.resultsDocument(for: normalized, library: library)
        view.loadHTMLString(html, baseURL: URL(string: "dict://d/page"))

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in poll() }
        }
        app.run()
        exit(0)
    }

    private static var inspectionJS: String {
        let probe = probeJS.isEmpty ? "null" : "(\(probeJS))"
        return """
        (function () {
          const probeFn = \(probe);
          const frames = Array.from(document.querySelectorAll('iframe'));
          const pageErrs = window.__errs ? window.__errs.slice(0, 5) : [];
          return JSON.stringify(frames.map(function (f) {
            const out = { height: f.style.height || '', contentHeight: 0, state: f.dataset.sizeState || ('hook:' + typeof hookFrame + ':' + document.readyState), text: '', imgTotal: 0, imgLoaded: 0, errs: [], pageErrs: pageErrs, err: '', probe: '' };
            try {
              const doc = f.contentDocument;
              out.text = doc && doc.body ? doc.body.innerText.slice(0, 200) : '';
              if (doc) {
                out.contentHeight = doc.body
                  ? Math.max(doc.body.scrollHeight, doc.body.offsetHeight)
                  : (doc.documentElement ? doc.documentElement.scrollHeight : 0);
                const imgs = Array.from(doc.images);
                out.imgTotal = imgs.length;
                out.imgLoaded = imgs.filter(function (i) { return i.naturalWidth > 0; }).length;
                if (probeFn) { try { out.probe = String(probeFn(doc)); } catch (e) { out.probe = 'probe-error:' + e; } }
              }
              const w = f.contentWindow;
              if (w && w.__errs) out.errs = w.__errs.slice(0, 5);
            } catch (e) { out.err = String(e); }
            return out;
          }));
        })()
        """
    }

    private static func poll() {
        attempts += 1
        guard let webView else { return }
        webView.evaluateJavaScript(inspectionJS) { result, error in
            Task { @MainActor in
                evaluate(result: result, error: error)
            }
        }
    }

    private static func evaluate(result: Any?, error: Error?) {
        struct FrameProbe: Decodable {
            let height: String
            let contentHeight: Int
            let state: String
            let text: String
            let imgTotal: Int
            let imgLoaded: Int
            let errs: [String]
            let pageErrs: [String]
            let err: String
            let probe: String
        }

        defer {
            if attempts > 24 {
                print("SMOKE FAIL: timed out waiting for frames")
                exit(1)
            }
        }
        guard error == nil,
              let json = result as? String,
              let probes = try? JSONDecoder().decode([FrameProbe].self, from: Data(json.utf8)),
              !probes.isEmpty
        else { return }

        // Wait until every frame has both rendered text and settled to its
        // content height. Large legacy stylesheets often reflow after load.
        let contentReady = probes.allSatisfy { !$0.text.isEmpty || !$0.err.isEmpty }
        let sizeReady = probes.allSatisfy { probe in
            let height = Double(probe.height.replacingOccurrences(of: "px", with: "")) ?? 0
            return height != 10_000 && height + 1 >= Double(probe.contentHeight)
        }
        guard contentReady && sizeReady else { return }

        let heights = probes.map {
            Double($0.height.replacingOccurrences(of: "px", with: "")) ?? 0
        }
        if shouldTestResizeCycle {
            if resizePhase == 0 {
                baselineHeights = heights
                resizePhase = 1
                attempts = 0
                webView?.evaluateJavaScript("""
                document.querySelectorAll('iframe').forEach(function (f) {
                  const marker = f.contentDocument.createElement('div');
                  marker.id = 'lexicon-smoke-growth';
                  marker.style.height = (parseFloat(f.style.height) + 480) + 'px';
                  f.contentDocument.body.appendChild(marker);
                });
                """)
                return
            }

            if resizePhase == 1 {
                let grew = zip(heights, baselineHeights).allSatisfy { current, baseline in
                    current >= baseline + 450
                }
                guard grew else {
                    if attempts > 20 {
                        print("SMOKE FAIL: entry frames did not grow after dynamic expansion " +
                              "baseline=\(baselineHeights) current=\(heights) " +
                              "content=\(probes.map(\.contentHeight)) " +
                              "state=\(probes.map(\.state))")
                        exit(1)
                    }
                    return
                }
                print("SMOKE RESIZE: frames expanded from \(baselineHeights) to \(heights)")
                resizePhase = 2
                attempts = 0
                webView?.evaluateJavaScript("""
                document.querySelectorAll('iframe').forEach(function (f) {
                  f.contentDocument.getElementById('lexicon-smoke-growth')?.remove();
                });
                """)
                return
            }

            if resizePhase == 2 {
                let shrank = zip(heights, baselineHeights).allSatisfy { current, baseline in
                    current <= baseline + 2
                }
                guard shrank else {
                    if attempts > 20 {
                        print("SMOKE FAIL: entry frames did not shrink after dynamic collapse " +
                              "baseline=\(baselineHeights) current=\(heights) " +
                              "content=\(probes.map(\.contentHeight)) " +
                              "state=\(probes.map(\.state)) " +
                              "probe=\(probes.map(\.probe))")
                        exit(1)
                    }
                    return
                }
                print("SMOKE RESIZE: frames collapsed back to \(heights)")
                resizePhase = 3
            }
        }

        var failures: [String] = []
        for (i, probe) in probes.enumerated() {
            let summary = probe.text.replacingOccurrences(of: "\n", with: " ").prefix(90)
            print("frame \(i): height=\(probe.height) content=\(probe.contentHeight) state=\(probe.state) imgs=\(probe.imgLoaded)/\(probe.imgTotal) text=\"\(summary)\"")
            for jsError in probe.errs {
                print("frame \(i): JS error: \(jsError)")
            }
            if i == 0 {
                for jsError in probe.pageErrs {
                    print("page JS error: \(jsError)")
                }
            }
            if !probe.err.isEmpty {
                failures.append("frame \(i): probe error \(probe.err) (cross-origin?)")
            }
            if probe.text.isEmpty {
                failures.append("frame \(i): no rendered text")
            }
            if !expected.isEmpty && !probe.text.contains(expected) {
                failures.append("frame \(i): expected text not found")
            }
            if probe.imgTotal > 0 && probe.imgLoaded == 0 {
                failures.append("frame \(i): none of \(probe.imgTotal) images loaded")
            }
            let height = Double(probe.height.replacingOccurrences(of: "px", with: "")) ?? 0
            if height < 30 {
                failures.append("frame \(i): not auto-sized (height \(probe.height))")
            }
            if height + 1 < Double(probe.contentHeight) {
                failures.append(
                    "frame \(i): clipped (height \(probe.height), content \(probe.contentHeight)px)"
                )
            }
        }

        if !probeJS.isEmpty {
            for (i, probe) in probes.enumerated() {
                print("frame \(i): probe=\(probe.probe)")
                if probe.probe.isEmpty || probe.probe.hasPrefix("probe-error") {
                    failures.append("frame \(i): probe failed: \(probe.probe)")
                }
            }
            if probeMustMatch, Set(probes.map(\.probe)).count > 1 {
                failures.append("probe values differ across frames")
            }
        }

        if failures.isEmpty {
            print("SMOKE OK: \(probes.count) dictionary frames rendered")
            exit(0)
        } else {
            for failure in failures { print("SMOKE FAIL: \(failure)") }
            exit(1)
        }
    }
}
