import Foundation

/// Builds the HTML shown in the entry web view: an outer page with one
/// collapsible card per dictionary, each hosting the dictionary's own HTML in
/// a same-origin iframe (so per-dictionary CSS can't leak between entries).
public enum EntryPageBuilder {
    /// Outer page listing every enabled dictionary that has the word.
    public static func resultsDocument(for normalizedKey: String, library: DictionaryLibrary) -> String {
        let hits = (try? library.entries(forNormalizedKey: normalizedKey)) ?? []
        guard !hits.isEmpty else {
            return messageDocument(
                title: escape(normalizedKey),
                message: "No entry found in the enabled dictionaries."
            )
        }

        // One card per dictionary, keeping the user's dictionary order.
        var seen = Set<String>()
        var orderedDictionaries: [(uuid: String, title: String)] = []
        for hit in hits where !seen.contains(hit.dictionaryUUID) {
            seen.insert(hit.dictionaryUUID)
            orderedDictionaries.append((hit.dictionaryUUID, hit.dictionaryTitle))
        }

        let encodedWord = normalizedKey.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? normalizedKey

        let cards = orderedDictionaries.map { dict in
            """
            <details open>
              <summary>\(escape(dict.title))</summary>
              <iframe src="dict://d/\(dict.uuid)/entry?word=\(encodedWord)"
                      scrolling="no"></iframe>
            </details>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'self' data: blob:; img-src 'self' data: blob:; media-src 'self' data: blob:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'">
        <style>
          :root { color-scheme: light dark; }
          html {
            overflow-y: auto;
            overscroll-behavior: contain;
          }
          body {
            font-family: -apple-system, "Helvetica Neue", sans-serif;
            margin: 0; padding: 12px 16px 24px;
          }
          details {
            margin: 0;
            background: transparent;
          }
          details + details {
            border-top: 1px solid rgba(128,128,128,0.28);
            margin-top: 12px;
            padding-top: 12px;
          }
          summary {
            cursor: pointer;
            padding: 7px 2px 9px;
            font-weight: 600;
            font-size: 13px;
            user-select: none;
            background: transparent;
          }
          iframe {
            display: block;
            width: 100%;
            border: 0;
            height: 1px;
            background: transparent;
          }
        </style>
        </head>
        <body>
        \(cards)
        <script>
          function hookFrame(f) {
            let observedDocument = null;
            let resizeObserver = null;
            let mutationObserver = null;
            let settleTimer = null;
            let resizePending = false;
            let intrinsicMeasureScheduled = false;
            function finishIntrinsicMeasure() {
              // requestAnimationFrame is suspended for offscreen WKWebViews,
              // so the timeout is also a required non-visual fallback.
              if (!intrinsicMeasureScheduled) return;
              intrinsicMeasureScheduled = false;
              resizeNow(true);
            }
            function renderedContentBottom(doc) {
              const body = doc.body;
              const win = doc.defaultView;
              if (!body || !win) return 0;
              let bottom = 0;
              // Repacked dictionaries sometimes put expandable content in
              // positioned wrappers that do not contribute to scrollHeight.
              Array.from(body.querySelectorAll('*'))
                .forEach(function (element) {
                  const rects = element.getClientRects();
                  if (!rects.length) return;
                  const style = win.getComputedStyle(element);
                  if (style.visibility === 'hidden' || style.position === 'fixed') return;
                  Array.from(rects).forEach(function (rect) {
                    if (rect.width > 0 || rect.height > 0) {
                      bottom = Math.max(bottom, rect.bottom + win.scrollY);
                    }
                  });
                });
              // Include direct text nodes and the body's visual bottom
              // padding without counting the iframe-sized body box itself.
              try {
                const range = doc.createRange();
                range.selectNodeContents(body);
                Array.from(range.getClientRects()).forEach(function (rect) {
                  bottom = Math.max(bottom, rect.bottom + win.scrollY);
                });
              } catch (_) {}
              const paddingBottom = parseFloat(win.getComputedStyle(body).paddingBottom) || 0;
              return bottom + paddingBottom;
            }
            function resize(measureIntrinsic) {
              if (resizePending || intrinsicMeasureScheduled) return;
              if (measureIntrinsic) {
                // WebKit does not synchronously propagate a new iframe
                // viewport into the child document. Give it two layout frames
                // before reading descendant rects, otherwise large legacy
                // panels are measured against the old, clipped viewport.
                intrinsicMeasureScheduled = true;
                f.style.height = '10000px';
                requestAnimationFrame(function () {
                  requestAnimationFrame(function () {
                    finishIntrinsicMeasure();
                  });
                });
                setTimeout(finishIntrinsicMeasure, 50);
                return;
              }
              resizeNow(false);
            }
            function resizeNow(measureIntrinsic) {
              if (resizePending) return;
              resizePending = true;
              try {
                const doc = f.contentDocument;
                if (!doc || !doc.documentElement) {
                  f.dataset.sizeState = 'nodoc';
                  return;
                }
                const body = doc.body;
                const root = doc.documentElement;
                const renderedHeight = renderedContentBottom(doc);
                const viewportBoundHeight = Math.max(
                  body ? body.scrollHeight : 0,
                  body ? body.offsetHeight : 0,
                  root.scrollHeight,
                  root.offsetHeight
                );
                const intrinsicHeight = measureIntrinsic && renderedHeight > 0
                  ? renderedHeight
                  : Math.max(viewportBoundHeight, renderedHeight);
                // A single dictionary should use the available result area
                // instead of leaving a dead band below a short iframe. Longer
                // content still grows past this floor and scrolls as one page.
                const frameTop = Math.max(0, f.getBoundingClientRect().top);
                const outerViewportHeight = document.documentElement.clientHeight || window.innerHeight;
                const viewportFloor = document.querySelectorAll('iframe').length === 1
                  ? Math.max(44, outerViewportHeight - frameTop - 24)
                  : 44;
                const h = Math.max(intrinsicHeight, viewportFloor);
                f.style.height = Math.max(44, Math.ceil(h)) + 'px';
                f.dataset.sizeState = 'ok:' + h;
              } catch (e) {
                f.dataset.sizeState = 'err:' + String(e);
              } finally {
                resizePending = false;
              }
            }
            function forwardWheel(event) {
              if (!event.deltaX && !event.deltaY) return;
              window.scrollBy(event.deltaX, event.deltaY);
              event.preventDefault();
            }
            function forwardNavigationKey(event) {
              if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
              const target = event.target;
              if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
              const page = Math.max(120, window.innerHeight * 0.85);
              if (event.key === 'PageDown') window.scrollBy(0, page);
              else if (event.key === 'PageUp') window.scrollBy(0, -page);
              else if (event.key === 'Home') window.scrollTo(0, 0);
              else if (event.key === 'End') window.scrollTo(0, document.documentElement.scrollHeight);
              else return;
              event.preventDefault();
            }
            function settle() {
              if (settleTimer) clearTimeout(settleTimer);
              // Measure once after the final mutation/event in a legacy
              // animation. Debouncing guarantees both opening and closing
              // receive an intrinsic pass without keeping a sentinel active.
              settleTimer = setTimeout(function () {
                settleTimer = null;
                resize(true);
              }, 300);
            }
            function attach() {
              resize(true);
              try {
                if (f.contentDocument && observedDocument !== f.contentDocument) {
                  const frameDocument = f.contentDocument;
                  if (resizeObserver) resizeObserver.disconnect();
                  if (mutationObserver) mutationObserver.disconnect();
                  resizeObserver = new ResizeObserver(function () { resize(false); });
                  resizeObserver.observe(frameDocument.documentElement);
                  if (frameDocument.body) resizeObserver.observe(frameDocument.body);
                  mutationObserver = new MutationObserver(function () {
                    // Attribute-heavy legacy animations can mutate every
                    // frame. Keep the current viewport stable while they run;
                    // `settle` performs one intrinsic pass at the end.
                    resize(false);
                    settle();
                  });
                  if (frameDocument.body) {
                    mutationObserver.observe(frameDocument.body, {
                      childList: true, subtree: true, attributes: true,
                      characterData: true
                    });
                  }
                  // Capture interaction before legacy handlers run. The first
                  // interval tick happens after they have changed the DOM.
                  ['click', 'toggle', 'input', 'change'].forEach(function (eventName) {
                    frameDocument.addEventListener(eventName, settle, true);
                  });
                  ['transitionrun', 'transitionend', 'animationstart', 'animationend']
                    .forEach(function (eventName) {
                      frameDocument.addEventListener(eventName, settle, true);
                    });
                  // A non-scrolling iframe still captures wheel and keyboard
                  // navigation. Forward them to the one outer results page so
                  // expanded entries never become a dead scrolling region.
                  frameDocument.addEventListener('wheel', forwardWheel, { passive: false, capture: true });
                  frameDocument.addEventListener('keydown', forwardNavigationKey, true);
                  observedDocument = frameDocument;
                }
              } catch (e) {}
              // Dictionary stylesheets and legacy ready handlers can reflow a
              // large entry without producing a useful DOM mutation. Sample
              // briefly while the frame settles so it never remains clipped.
              settle();
            }
            f.addEventListener('load', attach);
            // The frame may already be loaded before this script runs
            // (the dict:// handler responds synchronously).
            try {
              if (f.contentDocument && f.contentDocument.readyState !== 'loading') attach();
            } catch (e) {}
          }
          document.querySelectorAll('iframe').forEach(hookFrame);
        </script>
        </body>
        </html>
        """
    }

    /// Inner page: all entries for the word within one dictionary.
    public static func entryDocument(
        for normalizedKey: String, dictionaryUUID: String, library: DictionaryLibrary
    ) -> String {
        var hits = (try? library.entries(forNormalizedKey: normalizedKey))?
            .filter { $0.dictionaryUUID == dictionaryUUID } ?? []

        // Alias keys (case variants etc.) can point at the same record;
        // render each record once.
        var seenOffsets = Set<UInt64>()
        hits = hits.filter { seenOffsets.insert($0.recordOffset).inserted }

        var bodies: [String] = []
        for hit in hits {
            if var text = try? library.entryText(for: hit), !text.isEmpty {
                text = rewriteRootRelativeReferences(text, dictionaryUUID: dictionaryUUID)
                bodies.append(text)
            }
        }
        if bodies.isEmpty {
            bodies = ["<p><i>Could not read this entry.</i></p>"]
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'self' data: blob:; img-src 'self' data: blob:; media-src 'self' data: blob:; font-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'">
        <style>
          :root { color-scheme: light dark; }
          html, body { overflow: visible !important; }
          body {
            font-family: -apple-system, "Helvetica Neue", sans-serif;
            font-size: 15px;
            line-height: 1.45;
            box-sizing: border-box;
            margin: 0 !important;
            padding: 12px 14px 22px !important;
            min-height: 0 !important;
            overflow-wrap: break-word;
            /* Keep a nonzero alpha for legacy scripts that reject a fully
               transparent body, while visually blending with the app. */
            background-color: rgba(255, 255, 255, 0.001) !important;
          }
          img { max-width: 100%; height: auto; }
          hr.lexicon-sep { margin: 14px 0; opacity: 0.4; }
        </style>
        </head>
        <body>
        \(bodies.joined(separator: "\n<hr class=\"lexicon-sep\">\n"))
        <link rel="stylesheet" href="custom.css">
        <script>
          // Capture supported dictionary links before legacy site scripts can
          // cancel them. Native code performs the lookup/audio/external open.
          (function () {
            window.addEventListener('click', function (event) {
              const link = event.target && event.target.closest
                ? event.target.closest('a[href]')
                : null;
              if (!link) return;
              const href = (link.getAttribute('href') || '').trim();
              const scheme = href.includes(':')
                ? href.slice(0, href.indexOf(':')).toLowerCase()
                : '';
              if (!['entry', 'bword', 'sound', 'http', 'https', 'mailto'].includes(scheme)) {
                return;
              }
              event.preventDefault();
              event.stopImmediatePropagation();
              try {
                window.webkit.messageHandlers.lexiconLink.postMessage({
                  href: href,
                  dictionaryUUID: '\(dictionaryUUID)'
                });
              } catch (_) {}
            }, true);
          })();
        </script>
        <script src="custom.js"></script>
        </body>
        </html>
        """
        // custom.css/custom.js are optional user/theme overrides served from
        // the dictionary folder. They load last so they can normalize a
        // repack's original website-oriented styles and behavior. Missing
        // override files are silent 404s.
    }

    public static func welcomeDocument(hasDictionaries: Bool) -> String {
        let hint = hasDictionaries
            ? "Type a word in the search field to look it up in all enabled dictionaries at once."
            : "No dictionaries yet. Open <b>Dictionaries</b> in the toolbar and import your .mdx files (with their .mdd companions in the same folder)."
        return messageDocument(title: "Lexicon", message: hint)
    }

    private static func messageDocument(title: String, message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body {
            font-family: -apple-system, sans-serif;
            display: flex; align-items: center; justify-content: center;
            height: 90vh; margin: 0;
          }
          .box { max-width: 400px; text-align: center; opacity: 0.75; }
          h1 { font-size: 20px; font-weight: 600; }
          p { font-size: 14px; line-height: 1.5; }
        </style>
        </head>
        <body>
          <div class="box"><h1>\(title)</h1><p>\(message)</p></div>
        </body>
        </html>
        """
    }

    /// Root-relative references (src="/x.svg") would resolve against the
    /// scheme root and lose the dictionary UUID; pin them to the dictionary.
    private static let rootRelativeAttribute = try? NSRegularExpression(
        pattern: #"(src|href)\s*=\s*(["'])/([^/"'][^"']*)\2"#,
        options: [.caseInsensitive]
    )

    public static func rewriteRootRelativeReferences(_ html: String, dictionaryUUID: String) -> String {
        guard let regex = rootRelativeAttribute else { return html }
        let ns = html as NSString
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1=$2dict://d/\(dictionaryUUID)/$3$2"
        )
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
