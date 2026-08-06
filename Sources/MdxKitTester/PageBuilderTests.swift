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
