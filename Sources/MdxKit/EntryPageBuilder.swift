import Foundation

/// Builds the two-layer entry UI. The outer results document is app-owned;
/// every dictionary is rendered in its own `dict://<uuid>` origin so absolute
/// paths stay dictionary-local and scripts cannot reach sibling entries.
public enum EntryPageBuilder {
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
              <iframe data-uuid="\(escape(uuid))" data-src="\(escape(source))"
                      title="\(escape(dictionary.title))" scrolling="no"></iframe>
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
          :root { color-scheme:light dark; }
          html { overflow-y:auto; overscroll-behavior:contain; }
          body { font-family:-apple-system,"Helvetica Neue",sans-serif; margin:0; padding:10px 8px 20px; }
          /* Flat, minimalist stack: no card chrome; dictionaries are separated
             by a single hairline so the entries themselves carry the page. */
          details { margin:0; padding:0; background:transparent; border:0; }
          details + details { border-top:1px solid rgba(128,128,128,.25); margin-top:4px; padding-top:2px; }
          summary { cursor:pointer; padding:5px 2px; font-weight:600; font-size:13px; user-select:none; }
          iframe { display:block; width:100%; border:0; height:44px; background:transparent; }
          details:not([open]) iframe { display:none; }
          .lexicon-jump { position:sticky; top:0; z-index:5; display:flex; gap:4px; overflow-x:auto;
            scrollbar-width:none; margin:-10px -8px 6px; padding:6px 8px;
            background:rgba(255,255,255,.72); backdrop-filter:blur(20px) saturate(180%);
            -webkit-backdrop-filter:blur(20px) saturate(180%);
            border-bottom:1px solid rgba(0,0,0,.10); }
          .lexicon-jump::-webkit-scrollbar { display:none; }
          .lexicon-jump button { flex:0 0 auto; font:inherit; font-size:11px; font-weight:600; color:inherit;
            opacity:.65; padding:3px 8px; border:1px solid rgba(128,128,128,.35); border-radius:7px;
            background:transparent; cursor:pointer; }
          .lexicon-jump button:hover,.lexicon-jump button[data-current="1"] { opacity:1; }
          .lexicon-jump button[data-current="1"] { background:rgba(128,128,128,.16); }
          .lexicon-jump-spacer { flex:1 0 auto; }
          .lexicon-jump .lexicon-toggle-all { border-style:none; text-decoration:none; }
          .lexicon-jump .lexicon-toggle-all:hover { background:rgba(128,128,128,.16); }
          @media (prefers-color-scheme:dark) {
            .lexicon-jump { background:rgba(34,34,34,.68); border-bottom-color:rgba(255,255,255,.14); }
          }
          @media (prefers-reduced-motion:reduce) { * { scroll-behavior:auto!important; } }
        </style></head><body>\(jumpBar)\(cards)
        <script>
        (() => {
          const frames = new Map(Array.from(document.querySelectorAll('iframe[data-uuid]'))
            .map(frame => [frame.dataset.uuid, frame]));
          function load(frame) {
            if (!frame || frame.src || !frame.dataset.src) return;
            frame.src = frame.dataset.src;
          }
          const proximity = new IntersectionObserver(entries => entries.forEach(entry => {
            if (entry.isIntersecting && entry.target.closest('details')?.open) load(entry.target);
          }), { rootMargin:'800px 0px' });
          frames.forEach(frame => proximity.observe(frame));
          document.querySelectorAll('details[data-uuid]').forEach(card => {
            card.addEventListener('toggle', () => { if (card.open) load(card.querySelector('iframe')); });
          });
          requestAnimationFrame(() => frames.forEach(frame => {
            if (frame.closest('details')?.open && frame.getBoundingClientRect().top < innerHeight + 800) load(frame);
          }));

          window.__lexiconSetFrameHeight = (uuid, requested) => {
            const frame = frames.get(String(uuid).toLowerCase());
            if (!frame) return;
            const oldHeight = frame.getBoundingClientRect().height;
            const wasAbove = frame.getBoundingClientRect().bottom < 0;
            const floor = frames.size === 1
              ? Math.max(44, document.documentElement.clientHeight - Math.max(0, frame.getBoundingClientRect().top) - 24)
              : 44;
            const height = Math.max(floor, Math.min(200000, Math.ceil(Number(requested) || 44)));
            if (Math.abs(height - oldHeight) < 1) {
              frame.dataset.sizeState = 'ok:' + height;
              return;
            }
            frame.style.height = height + 'px';
            frame.dataset.sizeState = 'ok:' + height;
            if (wasAbove && Math.abs(height - oldHeight) > .5) scrollBy(0, height - oldHeight);
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
            const anyOpen = Array.from(document.querySelectorAll('details[data-uuid]'))
              .some(card => card.open);
            const label = anyOpen ? 'Collapse all' : 'Expand all';
            toggleAll.textContent = label;
            toggleAll.setAttribute('aria-label', label + ' dictionaries');
          }
          toggleAll?.addEventListener('click', () => {
            const cards = Array.from(document.querySelectorAll('details[data-uuid]'));
            const open = !cards.some(card => card.open);
            cards.forEach(card => { card.open = open; });
            refreshToggleAll();
          });
          document.querySelectorAll('details[data-uuid]').forEach(card =>
            card.addEventListener('toggle', refreshToggleAll));
          refreshToggleAll();
          function markCurrent() {
            const bar = document.querySelector('.lexicon-jump');
            const cutoff = (bar?.getBoundingClientRect().bottom || 0) + 4;
            let current = buttons[0]?.dataset.jump;
            document.querySelectorAll('details[data-uuid]').forEach(card => {
              if (card.getBoundingClientRect().top <= cutoff) current = card.dataset.uuid;
            });
            buttons.forEach(button => button.toggleAttribute('data-current', button.dataset.jump === current));
          }
          addEventListener('scroll', markCurrent, { passive:true }); markCurrent();
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
          img,video,svg { max-width:100%; height:auto; }
          hr.lexicon-sep { margin:14px 0; opacity:.4; }
        </style>
        <script>
        (() => {
          const emit = (kind,value,behavior) => dispatchEvent(new CustomEvent('lexicon-scroll-request',
            { detail:{ kind, value:Number(value)||0, behavior:behavior === 'smooth' ? 'smooth' : 'auto' } }));
          const nativeTo = window.scrollTo.bind(window), nativeBy = window.scrollBy.bind(window);
          window.scrollTo = function(a,b) { const y = typeof a === 'object' ? a.top : b; emit('to',y,typeof a === 'object' ? a.behavior : 'auto'); };
          window.scrollBy = function(a,b) { const y = typeof a === 'object' ? a.top : b; emit('by',y,typeof a === 'object' ? a.behavior : 'auto'); };
          const nativeInto = Element.prototype.scrollIntoView;
          Element.prototype.scrollIntoView = function(options) { emit('element',this.getBoundingClientRect().top,options?.behavior); };
          window.__lexiconNativeScroll = { to:nativeTo, by:nativeBy, into:nativeInto };
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
        var output = html
        for tag in ["html", "head", "body"] {
            output = replacing(output, pattern: "(?i)<\\s*" + tag + "\\b", with: "<lexicon-" + tag)
            output = replacing(output, pattern: "(?i)<\\s*/\\s*" + tag + "\\s*>", with: "</lexicon-" + tag + ">")
        }
        output = rewriteAttributes(output)
        output = replacingBlocks(output, pattern: "(?is)(<style\\b[^>]*>)(.*?)(</style\\s*>)") { groups in
            groups[1] + rewriteCSSReferences(groups[2]) + groups[3]
        }
        output = replacingBlocks(output, pattern: "(?is)(\\bstyle\\s*=\\s*)([\"'])(.*?)(\\2)") { groups in
            groups[1] + groups[2] + rewriteCSSReferences(groups[3]) + groups[4]
        }
        return output
    }

    public static func rewriteCSSReferences(_ css: String) -> String {
        var output = replacingBlocks(css, pattern: "(?is)(url\\(\\s*)([\"']?)(.*?)(\\2\\s*\\))") { groups in
            groups[1] + groups[2] + canonicalReference(groups[3]) + groups[4]
        }
        output = replacingBlocks(output, pattern: "(?is)(@import\\s+)([\"'])(.*?)(\\2)") { groups in
            groups[1] + groups[2] + canonicalReference(groups[3]) + groups[4]
        }
        return output
    }

    /// Local resources statically discoverable in entry HTML or CSS. Import
    /// uses this to bring along loose assets whose names do not match the MDX.
    public static func localResourceReferences(in text: String) -> Set<String> {
        let patterns = [
            "(?is)\\b(?:src|href|data|poster|xlink:href)\\s*=\\s*[\"']([^\"']+)[\"']",
            "(?i)\\b(?:src|href|data|poster|xlink:href)\\s*=\\s*([^\\s\"'`=<>]+)",
            "(?is)url\\(\\s*[\"']?([^\"')]+)",
            "(?is)@import\\s+[\"']([^\"']+)[\"']",
        ]
        var result = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { continue }
                var value = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = value.lowercased()
                if value.hasPrefix("#") || value.hasPrefix("//")
                    || ["http:", "https:", "entry:", "bword:", "sound:", "data:", "blob:", "javascript:"]
                        .contains(where: lower.hasPrefix) { continue }
                if lower.hasPrefix("file://") { value = String(value.dropFirst("file://".count)) }
                if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
                value = (value.removingPercentEncoding ?? value)
                    .replacingOccurrences(of: "\\", with: "/")
                while value.hasPrefix("/") { value.removeFirst() }
                guard !value.isEmpty, !value.split(separator: "/").contains("..") else { continue }
                result.insert(value)
            }
        }
        if let srcset = try? NSRegularExpression(
            pattern: "(?is)\\bsrcset\\s*=\\s*[\"']([^\"']+)[\"']"
        ) {
            let ns = text as NSString
            for match in srcset.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 1))
                if value.lowercased().contains("data:") { continue }
                for candidate in value.split(separator: ",") {
                    guard let url = candidate.split(whereSeparator: { $0.isWhitespace }).first else { continue }
                    result.formUnion(localResourceReferences(in: "<img src=\"\(url)\">"))
                }
            }
        }
        return result
    }

    private static func rewriteAttributes(_ html: String) -> String {
        var output = replacingBlocks(
            html, pattern: "(?is)(\\b(?:src|href|data|poster|xlink:href)\\s*=\\s*)([\"'])(.*?)(\\2)"
        ) { groups in groups[1] + groups[2] + canonicalReference(groups[3]) + groups[4] }
        output = replacingBlocks(
            output, pattern: "(?i)(\\b(?:src|href|data|poster|xlink:href)\\s*=\\s*)([^\\s\"'`=<>]+)"
        ) { groups in groups[1] + canonicalReference(groups[2]) }
        output = replacingBlocks(output, pattern: "(?is)(\\bsrcset\\s*=\\s*)([\"'])(.*?)(\\2)") { groups in
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

    private static func contentSecurityPolicy(allowHTTPS: Bool, outerPage: Bool) -> String {
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

    private static func replacing(_ value: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }

    private static func replacingBlocks(
        _ value: String, pattern: String, transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let ns = value as NSString
        var output = value
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0 ..< match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: transform(groups))
        }
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
