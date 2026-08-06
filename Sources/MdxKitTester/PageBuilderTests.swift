import Foundation
import MdxKit

/// Tests the HTML generation that feeds the app's web view.
func runPageBuilderTests(_ t: TestHarness) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LexiconPageTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    var library: DictionaryLibrary!
    var basic: DictionaryRecord!

    t.run("page builder: setup") {
        library = try DictionaryLibrary(rootURL: tempRoot)
        basic = try library.importDictionary(
            from: fixturesURL.appendingPathComponent("basic.mdx")
        )
        try library.importDictionary(from: fixturesURL.appendingPathComponent("utf16.mdx"))
    }

    t.run("page builder: results document") {
        let html = EntryPageBuilder.resultsDocument(for: "apple", library: library)
        // One card per dictionary that has the word, in order.
        t.expect(html.contains("Basic Test Dictionary"), "first dictionary card")
        t.expect(html.contains("UTF-16 Dictionary"), "second dictionary card")
        t.expect(
            html.contains("dict://d/\(basic.uuid)/entry?word=apple"),
            "iframe url carries dictionary uuid and word"
        )
        t.expect(html.contains("MutationObserver"), "late layout changes resize entry frames")
        t.expect(html.contains("range.selectNodeContents(body)"), "frames measure content without collapsing")
        t.expect(html.contains("f.style.height = '10000px'"), "legacy overflow receives a full layout pass")
        t.expect(html.contains("requestAnimationFrame(function ()"), "intrinsic sizing waits for WebKit layout")
        t.expect(html.contains("setTimeout(finishIntrinsicMeasure, 50)"), "offscreen layout has a timer fallback")
        t.expect(html.contains("{ passive: false, capture: true }"), "iframe wheel events reach the outer page in capture phase")
        t.expect(html.contains("frameDocument.addEventListener('keydown', forwardNavigationKey"), "iframe page keys reach the outer page")
        t.expect(html.contains("observedDocument !== f.contentDocument"), "hooks reconnect after WebKit replaces the blank iframe document")
        t.expect(html.contains("transitionend"), "animated expansions restart frame sizing")
        t.expect(html.contains("frameDocument.addEventListener"), "entry interactions restart sizing")
        t.expect(html.contains("renderedContentBottom"), "positioned expansion content is measured")
        t.expect(html.contains("overscroll-behavior: contain"), "long result pages remain scrollable")
        t.expect(html.contains(#"scrolling="no""#), "entry frames never create nested scrolling")
        t.expect(html.contains("viewportFloor"), "single entries fill unused result space")
        t.expect(html.contains("details + details"), "dictionary entries use thin separators")
        t.expect(!html.contains("border-radius: 10px"), "dictionary entries are not boxed cards")
        let firstCard = html.range(of: "Basic Test Dictionary")!.lowerBound
        let secondCard = html.range(of: "UTF-16 Dictionary")!.lowerBound
        t.expect(firstCard < secondCard, "cards follow dictionary sort order")
    }

    t.run("page builder: entry document with resources and audio") {
        let html = EntryPageBuilder.entryDocument(
            for: "apple", dictionaryUUID: basic.uuid, library: library
        )
        t.expect(html.contains("a round fruit with firm flesh"), "entry content")
        t.expect(html.contains("apple.png"), "image reference preserved")
        t.expect(html.contains("sound://pron/apple.wav"), "audio link preserved")
        t.expect(html.contains("style.css"), "css link preserved")
        t.expect(html.contains(#"href="custom.css""#), "custom css override loaded")
        t.expect(html.contains(#"src="custom.js""#), "custom js override loaded")
        t.expect(html.contains("Content-Security-Policy"), "offline content policy installed")
        t.expect(html.contains("lexiconLink"), "native dictionary link bridge installed")
        t.expect(html.contains("padding: 12px 14px 22px"), "entry has consistent bottom padding")
        t.expect(html.contains("rgba(255, 255, 255, 0.001)"), "entry background blends with app")
        t.expect(html.contains("overflow: visible !important"), "inner document does not scroll")
    }

    t.run("page builder: collapsed dictionaries stay folded") {
        let expanded = EntryPageBuilder.resultsDocument(for: "apple", library: library)
        t.expect(
            expanded.contains("<details open id=\"dict-\(basic.uuid)\""),
            "cards open by default"
        )

        let collapsed = EntryPageBuilder.resultsDocument(
            for: "apple", library: library, collapsedDictionaries: [basic.uuid]
        )
        t.expect(
            collapsed.contains("<details id=\"dict-\(basic.uuid)\""),
            "collapsed dictionary renders folded"
        )
        t.expect(
            collapsed.contains("<details open id=\"dict-"),
            "other dictionaries stay open"
        )
        t.expect(collapsed.contains("kind: 'collapse'"), "toggles are reported back")
    }

    t.run("page builder: jump bar appears only with several dictionaries") {
        let html = EntryPageBuilder.resultsDocument(for: "apple", library: library)
        t.expect(html.contains("<nav class=\"lexicon-jump\""), "jump bar present for two dictionaries")
        let chips = html.components(separatedBy: "data-jump=").count - 1
        t.expectEqual(chips, 2, "one chip per dictionary")

        // A single dictionary would make the bar pure chrome.
        let soloRoot = tempRoot.appendingPathComponent("solo")
        let solo = try DictionaryLibrary(rootURL: soloRoot)
        try solo.importDictionary(from: fixturesURL.appendingPathComponent("basic.mdx"))
        let soloHTML = EntryPageBuilder.resultsDocument(for: "apple", library: solo)
        t.expect(!soloHTML.contains("<nav class=\"lexicon-jump\""), "no jump bar for one dictionary")
        t.expect(!soloHTML.contains("data-jump="), "no jump chips for one dictionary")
    }

    t.run("page builder: double-click lookup bridge is installed and guarded") {
        let html = EntryPageBuilder.entryDocument(
            for: "apple", dictionaryUUID: basic.uuid, library: library
        )
        t.expect(html.contains("'dblclick'"), "double-click handler installed")
        t.expect(html.contains("kind: 'lookup'"), "lookup messages are tagged")
        // Guards that keep double-click-to-select-and-copy working.
        t.expect(html.contains(#"/\s/.test(word)"#), "multi-word selections ignored")
        t.expect(
            html.contains("a[href], input, textarea, select, [contenteditable]"),
            "links and form fields ignored"
        )
    }

    t.run("page builder: hostile dictionary uuid cannot inject script") {
        // `URL.path` percent-decodes, so a dictionary's own markup can point an
        // iframe at dict://d/<anything>/entry and choose this string. It is
        // interpolated into a JS string literal, which must stay closed.

        /// The `dictionaryUUID:` literal the bridge emits.
        func emittedLiteral(_ uuid: String) -> String {
            let html = EntryPageBuilder.entryDocument(
                for: "apple", dictionaryUUID: uuid, library: library
            )
            guard let start = html.range(of: "dictionaryUUID: "),
                  let end = html.range(
                      of: "\n", range: start.upperBound ..< html.endIndex
                  )
            else { return "" }
            return String(html[start.upperBound ..< end.lowerBound])
        }

        // A single quote is inert inside the double-quoted literal we emit.
        t.expectEqual(
            emittedLiteral("x');alert(1)//"),
            #""x');alert(1)//""#,
            "single quotes stay inside the literal"
        )
        // A double quote would close it, so it must be escaped.
        t.expectEqual(
            emittedLiteral(#"x");alert(1)//"#),
            #""x\");alert(1)//""#,
            "double quote escaped"
        )
        // '<' must never survive, or the payload could close the <script>.
        let closingTag = emittedLiteral("a</script><script>alert(1)</script>")
        t.expect(!closingTag.contains("<"), "no raw '<' in the literal, got \(closingTag)")
        t.expect(closingTag.contains("\\u003C"), "'<' escaped as a unicode escape")

        let fullPage = EntryPageBuilder.entryDocument(
            for: "apple", dictionaryUUID: "a</script><script>alert(1)</script>", library: library
        )
        t.expect(
            !fullPage.contains("<script>alert(1)"),
            "cannot break out of the script element"
        )
    }

    t.run("page builder: redirect entry renders target") {
        let html = EntryPageBuilder.entryDocument(
            for: "colour", dictionaryUUID: basic.uuid, library: library
        )
        t.expect(html.contains("the American spelling"), "@@@LINK resolved in rendered entry")
        t.expect(!html.contains("@@@LINK"), "no raw redirect marker in output")
    }

    t.run("page builder: root-relative reference rewriting") {
        let html = """
        <img src="/a.svg"><link href='/css/x.css'><img src="img/rel.png">
        <a href="//cdn.example.com/x"></a><a href="http://x/y"></a><a href="/z.js"></a>
        """
        let out = EntryPageBuilder.rewriteRootRelativeReferences(html, dictionaryUUID: "UUID1")
        t.expect(out.contains(#"src="dict://d/UUID1/a.svg""#), "double-quoted src rewritten")
        t.expect(out.contains("href='dict://d/UUID1/css/x.css'"), "single-quoted href rewritten")
        t.expect(out.contains(#"href="dict://d/UUID1/z.js""#), "anchor href rewritten")
        t.expect(out.contains(#"src="img/rel.png""#), "relative path untouched")
        t.expect(out.contains(#"href="//cdn.example.com/x""#), "protocol-relative untouched")
        t.expect(out.contains(#"href="http://x/y""#), "absolute url untouched")
    }

    t.run("page builder: missing word and welcome pages") {
        let missing = EntryPageBuilder.resultsDocument(for: "qqqqq", library: library)
        t.expect(missing.contains("No entry found"), "missing word message")

        let welcome = EntryPageBuilder.welcomeDocument(hasDictionaries: false)
        t.expect(welcome.contains("No dictionaries yet"), "empty-library welcome")
    }
}
