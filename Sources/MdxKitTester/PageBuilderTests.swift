import Foundation
import MdxKit

func runPageBuilderTests(_ t: TestHarness) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LexiconPageTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var library: DictionaryLibrary!
    var basic: DictionaryRecord!

    t.run("page builder: setup") {
        library = try DictionaryLibrary(rootURL: root)
        basic = try library.importDictionary(from: fixturesURL.appendingPathComponent("basic.mdx"))
        try library.importDictionary(from: fixturesURL.appendingPathComponent("utf16.mdx"))
    }

    t.run("page builder: per-dictionary origins and lazy frames") {
        let html = EntryPageBuilder.resultsDocument(for: "apple", library: library)
        t.expect(html.contains("Basic Test Dictionary"), "first dictionary card")
        t.expect(html.contains("UTF-16 Dictionary"), "second dictionary card")
        t.expect(
            html.contains("dict://\(basic.uuid.lowercased())/entry?word=apple"),
            "dictionary UUID is the frame origin"
        )
        t.expect(html.contains("data-src="), "frames use lazy sources")
        t.expect(html.contains("IntersectionObserver"), "nearby expanded frames load")
        t.expect(html.contains("__lexiconSetFrameHeight"), "child height reports have an outer receiver")
        t.expect(!html.contains("10000px"), "no temporary sizing sentinel")
        t.expect(html.contains(#"scrolling="no""#), "one outer scroll surface")
        t.expect(html.contains("overscroll-behavior:contain"), "result page remains scrollable")
    }

    t.run("page builder: entry document and network policy") {
        let online = EntryPageBuilder.entryDocument(
            for: "apple", dictionaryUUID: basic.uuid, library: library, allowHTTPS: true
        )
        t.expect(online.contains("a round fruit with firm flesh"), "entry content")
        t.expect(online.contains("apple.png"), "image reference")
        t.expect(online.contains("sound://pron/apple.wav"), "audio link")
        t.expect(online.contains(#"href="custom.css""#), "custom css")
        t.expect(online.contains(#"src="custom.js""#), "custom js")
        t.expect(online.contains("https:"), "HTTPS allowed by CSP")
        t.expect(online.contains("wss:"), "secure WebSocket requests allowed with HTTPS policy")
        t.expect(!online.contains("webkit.messageHandlers"), "native bridge absent from page world")
        t.expect(online.contains("lexicon-scroll-request"), "scroll compatibility shim")

        let offline = EntryPageBuilder.entryDocument(
            for: "apple", dictionaryUUID: basic.uuid, library: library, allowHTTPS: false
        )
        let csp = offline.components(separatedBy: "Content-Security-Policy").dropFirst().first ?? ""
        t.expect(!csp.prefix(500).contains("https:"), "offline CSP blocks HTTPS")
        t.expect(!csp.prefix(500).contains("wss:"), "offline CSP blocks secure WebSockets")
    }

    t.run("page builder: collapse, jump bar, and anchor target") {
        let collapsed = EntryPageBuilder.resultsDocument(
            for: "apple", library: library, collapsedDictionaries: [basic.uuid]
        )
        t.expect(collapsed.contains("<details id=\"dict-\(basic.uuid.lowercased())\""), "saved collapse state")
        t.expect(collapsed.contains("<nav class=\"lexicon-jump\""), "jump bar for multiple dictionaries")
        t.expect(collapsed.contains("lexicon-toggle-all"), "expand/collapse-all control for multiple dictionaries")
        let anchored = EntryPageBuilder.resultsDocument(
            for: "apple", library: library, collapsedDictionaries: [basic.uuid],
            anchor: "sense-2", preferredDictionaryUUID: basic.uuid
        )
        t.expect(anchored.contains("anchor=sense-2"), "anchor passed only to target frame")
        t.expect(anchored.contains("<details open id=\"dict-\(basic.uuid.lowercased())\""), "anchor target expands")
    }

    t.run("page builder: full document and resource normalization") {
        let source = #"""
        <html><head><style>.x{background:url(//cdn.example/x.png)} @import 'file:///theme.css';</style></head>
        <body style="background:url(file:///bg.png)">
          <img src="/a.svg" srcset="//cdn.example/a.png 1x, local@2x.png 2x">
          <object data=file:///movie.svg></object><video poster='/poster.jpg'></video>
        </body></html>
        """#
        let out = EntryPageBuilder.normalizeEntryHTML(source)
        for tag in ["html", "head", "body"] {
            t.expect(out.contains("lexicon-\(tag)"), "\(tag) tag neutralized")
        }
        t.expect(out.contains("https://cdn.example/x.png"), "CSS protocol-relative URL")
        t.expect(out.contains("https://cdn.example/a.png 1x"), "srcset URL")
        t.expect(out.contains("theme.css"), "file CSS URL made dictionary-relative")
        t.expect(out.contains("data=movie.svg"), "unquoted object data URL")
        t.expect(out.contains("poster='/poster.jpg'"), "root-relative poster remains dictionary-local")
    }

    t.run("page builder: entry redirect and empty pages") {
        let redirected = EntryPageBuilder.entryDocument(
            for: "colour", dictionaryUUID: basic.uuid, library: library
        )
        t.expect(redirected.contains("the American spelling"), "entry redirect resolved")
        t.expect(!redirected.contains("@@@LINK"), "redirect marker hidden")
        t.expect(EntryPageBuilder.resultsDocument(for: "qqqqq", library: library).contains("No entry found"))
        t.expect(EntryPageBuilder.welcomeDocument(hasDictionaries: false).contains("No dictionaries yet"))
    }
}
