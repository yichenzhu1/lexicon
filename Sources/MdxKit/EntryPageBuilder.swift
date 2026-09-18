import Foundation

/// Builds the two-layer entry UI. The outer results document is app-owned;
/// every dictionary is rendered in its own `dict://<uuid>` origin so absolute
/// paths stay dictionary-local and scripts cannot reach sibling entries.
public enum EntryPageBuilder {
    // These patterns are code, not dictionary input. Compile them once and
    // surface a programming error instead of silently skipping normalization.
    private enum Pattern {
        static let documentTag = try! NSRegularExpression(pattern: #"(?i)<\s*(/?)\s*(html|head|body)\b"#)
        static let styleBlock = try! NSRegularExpression(pattern: #"(?is)(<style\b[^>]*>)(.*?)(</style\s*>)"#)
        static let inlineStyle = try! NSRegularExpression(pattern: #"(?is)(\bstyle\s*=\s*)(["'])(.*?)(\2)"#)
        static let cssURL = try! NSRegularExpression(pattern: #"(?is)(url\(\s*)(["']?)(.*?)(\2\s*\))"#)
        static let cssImport = try! NSRegularExpression(pattern: #"(?is)(@import\s+)(["'])(.*?)(\2)"#)
        static let tag = try! NSRegularExpression(pattern: #"(?is)<\s*([a-z][a-z0-9:-]*)\b(?:[^>"']|"[^"]*"|'[^']*')*>"#)
        static let cssResources = [
            try! NSRegularExpression(pattern: #"(?is)url\(\s*["']?([^"')]+)"#),
            try! NSRegularExpression(pattern: #"(?is)@import\s+["']([^"']+)["']"#),
        ]
        static let attributes = try! NSRegularExpression(pattern: #"(?is)(?:^|\s)([a-z_:][a-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'`=<>]+))"#)
        static let quotedReference = try! NSRegularExpression(pattern: #"(?is)(\b(?:src|href|data|poster|xlink:href)\s*=\s*)(["'])(.*?)(\2)"#)
        static let unquotedReference = try! NSRegularExpression(pattern: #"(?i)(\b(?:src|href|data|poster|xlink:href)\s*=\s*)([^\s"'`=<>]+)"#)
        static let srcset = try! NSRegularExpression(pattern: #"(?is)(\bsrcset\s*=\s*)(["'])(.*?)(\2)"#)
    }

    public static func resultsDocument(
        for normalizedKey: String,
        library: DictionaryLibrary,
        collapsedDictionaries: Set<String> = [],
        anchor: String? = nil,
        preferredDictionaryUUID: String? = nil,
        initialScrollOffset: Double = 0,
        allowHTTPS: Bool = true
    ) -> String {
        let hits = (try? library.entries(forNormalizedKey: normalizedKey)) ?? []
        guard !hits.isEmpty else {
            return messageDocument(title: escape(normalizedKey), message: "No entry found in the enabled dictionaries.")
        }

        var seen = Set<String>()
        var dictionaries: [(uuid: String, title: String)] = []
        for hit in hits where seen.insert(hit.dictionaryUUID.lowercased()).inserted {
            dictionaries.append((hit.dictionaryUUID, hit.dictionaryTitle))
        }
        let word = normalizedKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? normalizedKey
        let targetUUID = dictionaries.contains {
            $0.uuid.caseInsensitiveCompare(preferredDictionaryUUID ?? "") == .orderedSame
        } ? preferredDictionaryUUID?.lowercased() : dictionaries.first?.uuid.lowercased()
        let anchorAllowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=+#"))
        let anchorQuery = anchor?.addingPercentEncoding(withAllowedCharacters: anchorAllowed)
        let collapsedUUIDs = Set(collapsedDictionaries.map { $0.lowercased() })
        let cards = dictionaries.map { dictionary in
            let uuid = dictionary.uuid.lowercased()
            let anchorSuffix = uuid == targetUUID && anchorQuery != nil ? "&anchor=\(anchorQuery!)" : ""
            let source = "dict://\(uuid)/entry?word=\(word)\(anchorSuffix)"
            let isAnchorTarget = uuid == targetUUID && anchorQuery != nil
            let open = isAnchorTarget || !collapsedUUIDs.contains(uuid) ? " open" : ""
            return """
            <details\(open) id="dict-\(escape(uuid))" data-uuid="\(escape(uuid))">
              <summary>\(escape(dictionary.title))</summary>
              <div class="lexicon-frame-slot" data-uuid="\(escape(uuid))">
                <iframe data-uuid="\(escape(uuid))" data-src="\(escape(source))"
                        title="\(escape(dictionary.title))" scrolling="no"></iframe>
              </div>
            </details>
            """
        }.joined(separator: "\n")
        let jumpBar = dictionaries.count > 1 ? """
        <nav class="lexicon-jump" aria-label="Jump to dictionary">
        \(dictionaries.map { dictionary in
            let uuid = dictionary.uuid.lowercased()
            return "<button type=\"button\" data-jump=\"\(escape(uuid))\">\(escape(dictionary.title))</button>"
        }.joined(separator: "\n"))
        <span class="lexicon-jump-spacer"></span>
        <button type="button" class="lexicon-toggle-all" aria-label="Collapse all dictionaries">Collapse all</button>
        </nav>
        """ : ""

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowHTTPS: allowHTTPS, outerPage: true))">
        <style>
          :root { color-scheme:light dark; --dictionary-content-indent:16px;
            /* One hairline spec for the whole app: matches NSColor.separatorColor,
               which the SwiftUI chrome draws at full strength (LayoutMetrics). */
            --lexicon-hairline:rgba(0,0,0,.10); }
          html { overflow-y:auto; overscroll-behavior:contain; }
          body { font-family:-apple-system,"Helvetica Neue",sans-serif; margin:0; padding:10px 8px 20px; }
          /* Flat, minimalist stack: no card chrome; dictionaries are separated
             by a single hairline so the entries themselves carry the page. */
          details { margin:0; padding:0; background:transparent; border:0; }
          details + details { border-top:1px solid var(--lexicon-hairline); margin-top:4px; padding-top:2px; }
          summary { cursor:pointer; padding:5px 2px; font-weight:600; font-size:13px; user-select:none; }
          /* Match the entry's content edge to the summary title, leaving the
             native disclosure triangle in its own stable gutter. */
          .lexicon-frame-slot { position:relative; width:calc(100% - var(--dictionary-content-indent));
            height:44px; margin-left:var(--dictionary-content-indent); }
          .lexicon-frame-slot[data-overlay="1"] { z-index:20; }
          iframe { position:absolute; inset:0 auto auto 0; display:block; width:100%; margin:0; border:0; height:44px;
            background:transparent; }
          details:not([open]) .lexicon-frame-slot { display:none; }
          .lexicon-jump { position:sticky; top:0; z-index:100; display:flex; gap:4px; overflow-x:auto;
            scrollbar-width:none; margin:-10px -8px 6px; padding:6px 8px;
            background:rgba(255,255,255,.72); backdrop-filter:blur(20px) saturate(180%);
            -webkit-backdrop-filter:blur(20px) saturate(180%);
            border-bottom:1px solid var(--lexicon-hairline); }
          .lexicon-jump::-webkit-scrollbar { display:none; }
          .lexicon-jump button { flex:0 0 auto; font:inherit; font-size:11px; font-weight:600; color:inherit;
            opacity:.65; padding:3px 8px; border:1px solid rgba(128,128,128,.35); border-radius:999px;
            background:transparent; cursor:pointer; }
          .lexicon-jump button:hover,.lexicon-jump button[data-current] { opacity:1; }
          .lexicon-jump button[data-current] { background:rgba(128,128,128,.16); }
          .lexicon-jump-spacer { flex:1 0 auto; }
          .lexicon-jump .lexicon-toggle-all { border-style:none; text-decoration:none; }
          .lexicon-jump .lexicon-toggle-all:hover { background:rgba(128,128,128,.16); }
          @media (prefers-color-scheme:dark) {
            :root { --lexicon-hairline:rgba(255,255,255,.10); }
            .lexicon-jump { background:rgba(34,34,34,.68); }
          }
          @media (prefers-reduced-motion:reduce) { * { scroll-behavior:auto!important; } }
        </style></head><body>\(jumpBar)\(cards)
        <script>
        (() => {
          const cards = Array.from(document.querySelectorAll('details[data-uuid]'));
          const frames = new Map(Array.from(document.querySelectorAll('iframe[data-uuid]'))
            .map(frame => [frame.dataset.uuid, frame]));
          const slots = new Map(Array.from(document.querySelectorAll('.lexicon-frame-slot[data-uuid]'))
            .map(slot => [slot.dataset.uuid, slot]));
          let scrollSyncPending = false;
          function syncFrameScrollState() {
            scrollSyncPending = false;
            markCurrent();
            const states = [];
            frames.forEach(frame => {
              const rect = frame.getBoundingClientRect();
              const flowHeight = frame.parentElement?.getBoundingClientRect().height || rect.height;
              const maxLocalY = Math.max(0, flowHeight - innerHeight);
              const localY = Math.max(0, Math.min(maxLocalY, -rect.top));
              states.push({uuid:frame.dataset.uuid || '', offset:localY, viewportHeight:innerHeight});
            });
            // Cross-origin custom-scheme frames do not consistently support
            // Window.postMessage in WebKit. Hand inert geometry to a dedicated
            // page-only handler; native code validates the main-frame origin
            // and delivers it to each dictionary by WKFrameInfo.
            try {
              webkit.messageHandlers.lexiconPageGeometry.postMessage({kind:'pageScroll', offset:scrollY});
              webkit.messageHandlers.lexiconPageGeometry.postMessage({kind:'frameScroll', frames:states});
            } catch (_) {}
          }
          function requestFrameScrollSync() {
            if (scrollSyncPending) return;
            scrollSyncPending = true;
            // This bridge updates dictionary scroll semantics even in a
            // background tab, where WebKit may suspend animation frames.
            queueMicrotask(syncFrameScrollState);
          }
          function load(frame) {
            if (!frame || frame.src || !frame.dataset.src) return;
            frame.src = frame.dataset.src;
          }
          const proximity = new IntersectionObserver(entries => entries.forEach(entry => {
            if (entry.isIntersecting && entry.target.closest('details')?.open) load(entry.target);
          }), { rootMargin:'800px 0px' });
          frames.forEach(frame => {
            proximity.observe(frame);
            frame.addEventListener('load', requestFrameScrollSync);
          });
          cards.forEach(card => {
            card.addEventListener('toggle', () => { if (card.open) load(card.querySelector('iframe')); });
          });
          requestAnimationFrame(() => frames.forEach(frame => {
            if (frame.closest('details')?.open && frame.getBoundingClientRect().top < innerHeight + 800) load(frame);
          }));

          window.__lexiconSetFrameHeight = (uuid, requestedFlow, requestedVisual) => {
            const frame = frames.get(String(uuid).toLowerCase());
            const slot = slots.get(String(uuid).toLowerCase());
            if (!frame || !slot) return;
            const oldFlowHeight = slot.getBoundingClientRect().height;
            const wasAbove = slot.getBoundingClientRect().bottom < 0;
            const floor = frames.size === 1
              ? Math.max(44, document.documentElement.clientHeight - Math.max(0, frame.getBoundingClientRect().top) - 24)
              : 44;
            const flowHeight = Math.max(floor,
              Math.min(200000, Math.ceil(Number(requestedFlow) || 44)));
            let visualHeight = Math.max(flowHeight,
              Math.min(200000, Math.ceil(Number(requestedVisual) || flowHeight)));
            if (visualHeight <= flowHeight + 8) visualHeight = flowHeight;
            const oldVisualHeight = frame.getBoundingClientRect().height;
            if (Math.abs(flowHeight - oldFlowHeight) < 1
                && Math.abs(visualHeight - oldVisualHeight) < 1) {
              frame.dataset.sizeState = 'ok:' + flowHeight;
              return;
            }
            slot.style.height = flowHeight + 'px';
            frame.style.height = visualHeight + 'px';
            const overlaysFollowingContent = visualHeight > flowHeight + 1;
            if (overlaysFollowingContent) slot.dataset.overlay = '1';
            else delete slot.dataset.overlay;
            frame.dataset.sizeState = 'ok:' + flowHeight;
            if (wasAbove && Math.abs(flowHeight - oldFlowHeight) > .5) {
              scrollBy(0, flowHeight - oldFlowHeight);
            }
            requestFrameScrollSync();
          };
          window.__lexiconScrollFrame = (uuid, offset, behavior) => {
            const frame = frames.get(String(uuid).toLowerCase());
            if (!frame) return;
            const top = frame.getBoundingClientRect().top + scrollY + (Number(offset) || 0);
            scrollTo({ top:Math.max(0, top - 8), behavior:behavior === 'smooth' ? 'smooth' : 'auto' });
          };

          const buttons = Array.from(document.querySelectorAll('.lexicon-jump button[data-jump]'));
          buttons.forEach(button => button.addEventListener('click', () => {
            const card = document.getElementById('dict-' + button.dataset.jump);
            if (!card) return;
            card.open = true; load(card.querySelector('iframe'));
            card.scrollIntoView({ block:'start', behavior:'smooth' });
          }));

          // Expand/collapse every card at once. Programmatic `open` changes
          // fire toggle events, so lazy loading and the native collapse-state
          // bridge stay in sync without extra work.
          const toggleAll = document.querySelector('.lexicon-toggle-all');
          function refreshToggleAll() {
            if (!toggleAll) return;
            const anyOpen = cards.some(card => card.open);
            const label = anyOpen ? 'Collapse all' : 'Expand all';
            toggleAll.textContent = label;
            toggleAll.setAttribute('aria-label', label + ' dictionaries');
          }
          toggleAll?.addEventListener('click', () => {
            const open = !cards.some(card => card.open);
            cards.forEach(card => { card.open = open; });
            refreshToggleAll();
          });
          cards.forEach(card => card.addEventListener('toggle', () => {
            refreshToggleAll(); requestFrameScrollSync();
          }));
          refreshToggleAll();
          function markCurrent() {
            const bar = document.querySelector('.lexicon-jump');
            const cutoff = (bar?.getBoundingClientRect().bottom || 0) + 4;
            let current = buttons[0]?.dataset.jump;
            cards.forEach(card => {
              if (card.getBoundingClientRect().top <= cutoff) current = card.dataset.uuid;
            });
            buttons.forEach(button => button.toggleAttribute('data-current', button.dataset.jump === current));
          }
          addEventListener('scroll', requestFrameScrollSync, { passive:true });
          addEventListener('resize', requestFrameScrollSync);
          requestFrameScrollSync();
          if (\(max(0, initialScrollOffset)) > 0) requestAnimationFrame(() => scrollTo(0, \(max(0, initialScrollOffset))));
        })();
        </script></body></html>
        """
    }

    public static func entryDocument(
        for normalizedKey: String,
        dictionaryUUID: String,
        library: DictionaryLibrary,
        allowHTTPS: Bool = true
    ) -> String {
        var hits = ((try? library.entries(forNormalizedKey: normalizedKey)) ?? [])
            .filter { $0.dictionaryUUID.caseInsensitiveCompare(dictionaryUUID) == .orderedSame }
        var offsets = Set<UInt64>()
        hits = hits.filter { offsets.insert($0.recordOffset).inserted }
        let bodies = hits.compactMap { hit -> String? in
            guard let text = try? library.entryText(for: hit), !text.isEmpty else { return nil }
            return normalizeEntryHTML(text)
        }
        let content = bodies.isEmpty
            ? "<p><i>Could not read this entry.</i></p>"
            : bodies.joined(separator: "\n<hr class=\"lexicon-sep\">\n")

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowHTTPS: allowHTTPS, outerPage: false))">
        <style>
          :root { color-scheme:light dark; }
          html,body { overflow:visible!important; }
          body { font-family:-apple-system,"Helvetica Neue",sans-serif; font-size:15px; line-height:1.45;
            box-sizing:border-box; margin:0!important; padding:6px 0 14px!important; min-height:0!important;
            overflow-wrap:break-word; background-color:rgba(255,255,255,.001)!important; }
          /* Longman 6 word-set records hide their root list inline, but their
             companion script only opens category headings carrying the
             `.expandable` class. Standalone records use `.topic_head`
             instead, leaving the entire linked list permanently hidden. */
          body > .category.lm6 > .content { display:block!important; }
          img,video,svg { max-width:100%; height:auto; }
          hr.lexicon-sep { margin:14px 0; opacity:.4; }
        </style>
        <script>
        (() => {
          const emit = (kind,value,behavior) => dispatchEvent(new CustomEvent('lexicon-scroll-request',
            { detail:{ kind, value:Number(value)||0, behavior:behavior === 'smooth' ? 'smooth' : 'auto' } }));
          window.scrollTo = function(a,b) { const y = typeof a === 'object' ? a.top : b; emit('to',y,typeof a === 'object' ? a.behavior : 'auto'); };
          window.scrollBy = function(a,b) { const y = typeof a === 'object' ? a.top : b; emit('by',y,typeof a === 'object' ? a.behavior : 'auto'); };
          Element.prototype.scrollIntoView = function(options) { emit('element',this.getBoundingClientRect().top,options?.behavior); };
        })();
        </script></head><body>\(content)
        <link rel="stylesheet" href="custom.css"><script src="custom.js"></script>
        </body></html>
        """
    }

    public static func welcomeDocument(hasDictionaries: Bool) -> String {
        if hasDictionaries {
            return messageDocument(
                title: "Lexicon",
                message: "Type a word in the search field to look it up in all enabled dictionaries at once.",
                hint: "Press ⌘F to jump to the search field."
            )
        }
        return messageDocument(
            title: "Welcome to Lexicon",
            message: "No dictionaries yet. Open <b>Dictionaries</b> and import an .mdx file with its companions.",
            hint: "You can also drag an .mdx file onto this window."
        )
    }

    public static func normalizeEntryHTML(_ html: String) -> String {
        var output = replacingBlocks(html, regex: Pattern.documentTag) { groups in
            "<" + groups[1] + "lexicon-" + groups[2].lowercased()
        }
        output = rewriteAttributes(output)
        output = replacingBlocks(output, regex: Pattern.styleBlock) { groups in
            groups[1] + rewriteCSSReferences(groups[2]) + groups[3]
        }
        output = replacingBlocks(output, regex: Pattern.inlineStyle) { groups in
            groups[1] + groups[2] + rewriteCSSReferences(groups[3]) + groups[4]
        }
        return output
    }

    public static func rewriteCSSReferences(_ css: String) -> String {
        var output = replacingBlocks(css, regex: Pattern.cssURL) { groups in
            groups[1] + groups[2] + canonicalReference(groups[3]) + groups[4]
        }
        output = replacingBlocks(output, regex: Pattern.cssImport) { groups in
            groups[1] + groups[2] + canonicalReference(groups[3]) + groups[4]
        }
        return output
    }

    /// Local resources statically discoverable in entry HTML. Attributes are
    /// interpreted in the context of their element: an anchor's `href` is a
    /// dictionary link, while a stylesheet link's `href` is a resource. This
    /// distinction prevents headwords and JavaScript data values from being
    /// reported as thousands of missing files during import.
    public static func localResourceReferences(in text: String) -> Set<String> {
        var result = Set<String>()

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in Pattern.tag.matches(in: text, range: range) {
            let tagName = ns.substring(with: match.range(at: 1)).lowercased()
            let tag = ns.substring(with: match.range)
            let attributes = htmlAttributes(in: tag)

            func add(_ name: String) {
                for value in attributes[name] ?? [] {
                    if let path = normalizedLocalReference(value) { result.insert(path) }
                }
            }

            // Only resource-bearing elements: dictionary links and arbitrary
            // JavaScript data attributes are not companion files.
            if ["audio", "embed", "iframe", "img", "input", "script", "source", "track", "video"]
                .contains(tagName) {
                add("src")
            }
            if tagName == "link" || tagName == "image" || tagName == "use" {
                add("href")
                add("xlink:href")
            }
            if tagName == "object" { add("data") }
            if tagName == "video" { add("poster") }

            if tagName == "img" || tagName == "source" {
                for srcset in attributes["srcset"] ?? [] {
                    addSrcsetReferences(srcset, to: &result)
                }
            }
            for style in attributes["style"] ?? [] {
                result.formUnion(localCSSResourceReferences(in: style))
            }
        }

        for match in Pattern.styleBlock.matches(in: text, range: range) {
            result.formUnion(localCSSResourceReferences(in: ns.substring(with: match.range(at: 2))))
        }
        return result
    }

    /// Resource references in a CSS file or inline declaration. This is kept
    /// separate from HTML scanning so JavaScript calls and prose containing
    /// `url(...)` cannot be mistaken for assets.
    public static func localCSSResourceReferences(
        in css: String, relativeTo directory: String = ""
    ) -> Set<String> {
        var result = Set<String>()
        let ns = css as NSString
        for regex in Pattern.cssResources {
            for match in regex.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
                if let path = normalizedLocalReference(
                    ns.substring(with: match.range(at: 1)), relativeTo: directory
                ) {
                    result.insert(path)
                }
            }
        }
        return result
    }

    private static func htmlAttributes(in tag: String) -> [String: [String]] {
        let ns = tag as NSString
        var result: [String: [String]] = [:]
        for match in Pattern.attributes.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            for index in 2 ... 4 where match.range(at: index).location != NSNotFound {
                result[name, default: []].append(ns.substring(with: match.range(at: index)))
                break
            }
        }
        return result
    }

    private static func addSrcsetReferences(_ srcset: String, to result: inout Set<String>) {
        if srcset.lowercased().contains("data:") { return }
        for candidate in srcset.split(separator: ",") {
            guard let raw = candidate.split(whereSeparator: { $0.isWhitespace }).first,
                  let path = normalizedLocalReference(String(raw))
            else { continue }
            result.insert(path)
        }
    }

    private static func normalizedLocalReference(
        _ raw: String, relativeTo directory: String = ""
    ) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if value.hasPrefix("#") || value.hasPrefix("//") || value.hasPrefix("&")
            || ["http:", "https:", "entry:", "bword:", "sound:", "data:", "blob:", "javascript:"]
                .contains(where: lower.hasPrefix) { return nil }
        if lower.hasPrefix("file://") { value = String(value.dropFirst("file://".count)) }
        if let query = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<query])
        }
        value = (value.removingPercentEncoding ?? value)
            .replacingOccurrences(of: "\\", with: "/")
        let components = value.split(separator: "/")
        guard !value.isEmpty,
              !(components.first?.contains(":") ?? false)
        else { return nil }
        // Resolve parent segments against the stylesheet's directory before
        // enforcing the package boundary. css/theme.css can legitimately use
        // ../fonts/body.woff2, while ../../outside still escapes the package.
        var resolved = value.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for component in components {
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else { return nil }
                resolved.removeLast()
            } else {
                resolved.append(String(component))
            }
        }
        return resolved.isEmpty ? nil : resolved.joined(separator: "/")
    }

    private static func rewriteAttributes(_ html: String) -> String {
        var output = replacingBlocks(html, regex: Pattern.quotedReference) { groups in
            groups[1] + groups[2] + canonicalReference(groups[3]) + groups[4]
        }
        output = replacingBlocks(output, regex: Pattern.unquotedReference) { groups in
            groups[1] + canonicalReference(groups[2])
        }
        output = replacingBlocks(output, regex: Pattern.srcset) { groups in
            if groups[3].lowercased().contains("data:") {
                return groups[1] + groups[2] + groups[3] + groups[4]
            }
            let items = groups[3].split(separator: ",", omittingEmptySubsequences: false).map { item -> String in
                let bits = item.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard let first = bits.first else { return String(item) }
                return canonicalReference(String(first)) + (bits.count > 1 ? " " + String(bits[1]) : "")
            }
            return groups[1] + groups[2] + items.joined(separator: ", ") + groups[4]
        }
        return output
    }

    private static func canonicalReference(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { return "https:" + value }
        if value.lowercased().hasPrefix("file://") {
            if let url = URL(string: value), url.host == nil || url.host == "localhost" {
                return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return String(value.dropFirst("file://".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return value
    }

    /// Shared by generated page metadata and resource response headers, so
    /// imported HTML and SVG documents receive the same network restrictions.
    public static func contentSecurityPolicy(allowHTTPS: Bool, outerPage: Bool) -> String {
        let network = allowHTTPS ? " https:" : ""
        let connections = allowHTTPS ? " https: wss:" : ""
        let frame = outerPage ? "frame-src dict:\(network); " : "frame-src 'self'\(network); "
        return "default-src 'self' data: blob:\(network); img-src 'self' data: blob:\(network); "
            + "media-src 'self' data: blob:\(network); font-src 'self' data:\(network); "
            + "style-src 'self' 'unsafe-inline'\(network); script-src 'self' 'unsafe-inline'\(network); "
            + "connect-src 'self'\(connections); " + frame
    }

    private static func messageDocument(title: String, message: String, hint: String? = nil) -> String {
        let hintHTML = hint.map { "<p class=\"hint\">\($0)</p>" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{color-scheme:light dark} body{font-family:-apple-system,sans-serif;display:flex;align-items:center;
        justify-content:center;height:90vh;margin:0}.box{max-width:400px;text-align:center}
        h1{font-size:22px;font-weight:700;letter-spacing:-.02em;margin:0 0 8px}
        p{font-size:14px;line-height:1.5;color:GrayText;margin:0}
        p.hint{font-size:12px;margin-top:16px}</style></head>
        <body><div class="box"><h1>\(title)</h1><p>\(message)</p>\(hintHTML)</div></body></html>
        """
    }

    private static func replacingBlocks(
        _ value: String, regex: NSRegularExpression, transform: ([String]) -> String
    ) -> String {
        let ns = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }
        var output = ""
        output.reserveCapacity(value.utf8.count)
        var cursor = 0
        for match in matches {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0 ..< match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            output += transform(groups)
            cursor = NSMaxRange(match.range)
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
