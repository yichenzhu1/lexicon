#if DEBUG
import Foundation
import WebKit

extension EntryWebView.Coordinator {
    func scheduleDiagnostics(in webView: WKWebView) {
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
    }
}
#endif
