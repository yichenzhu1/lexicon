import Foundation
import MdxKit

/// End-to-end tests of the import + SQLite index + search layer.
func runLibraryTests(_ t: TestHarness) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LexiconTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    var library: DictionaryLibrary!
    var basic: DictionaryRecord!

    t.run("library: import basic.mdx (with sibling mdd)") {
        library = try DictionaryLibrary(rootURL: tempRoot)
        basic = try library.importDictionary(
            from: fixturesURL.appendingPathComponent("basic.mdx")
        )
        t.expectEqual(basic.title, "Basic Test Dictionary")
        t.expectEqual(basic.entryCount, 56)

        // The sibling basic.mdd must have been copied alongside.
        let folder = library.folderURL(for: basic)
        t.expect(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("basic.mdd").path),
            "mdd copied with mdx"
        )
    }

    t.run("library: prefix search") {
        let results = try library.search(prefix: "app")
        t.expect(results.contains { $0.displayKey == "apple" }, "apple found by prefix")

        // Diacritic-insensitive: plain "nai" finds "naïve".
        let naive = try library.search(prefix: "nai")
        t.expect(naive.contains { $0.displayKey == "naïve" }, "diacritic-insensitive search")

        // Case-insensitive: "case sen" finds "Case Sensitive".
        let mixed = try library.search(prefix: "CASE SEN")
        t.expect(mixed.contains { $0.displayKey == "Case Sensitive" }, "case-insensitive search")

        t.expectEqual(try library.search(prefix: "zzzz").count, 0, "no bogus matches")
        t.expectEqual(try library.search(prefix: "  ").count, 0, "blank query")
    }

    t.run("library: entry text and @@@LINK redirect") {
        let hits = try library.entries(forNormalizedKey: "colour")
        t.expectEqual(hits.count, 1)
        let text = try library.entryText(for: hits[0])
        t.expect(text.contains("the American spelling"), "redirect resolved to color, got: \(text)")
    }

    t.run("library: resource lookup via index") {
        let png = try library.resource(path: "apple.png", dictionaryUUID: basic.uuid)
        t.expect(png?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "png from mdd")

        let wav = try library.resource(path: "pron/apple.wav", dictionaryUUID: basic.uuid)
        t.expect(wav?.prefix(4) == Data("RIFF".utf8), "wav from mdd subdirectory")

        t.expectEqual(
            try library.resource(path: "nope.bin", dictionaryUUID: basic.uuid), nil,
            "absent resource"
        )
    }

    t.run("library: resource fallbacks (renamed css/js, extension-less audio)") {
        // Repack case: entry references "renamed_style.css" but the package
        // ships "<mdx base>.css" as a loose file.
        let folder = library.folderURL(for: basic)
        try Data("body { --lexicon-test: 1; }".utf8)
            .write(to: folder.appendingPathComponent("basic.css"))
        let css = try library.resource(path: "renamed_style.css", dictionaryUUID: basic.uuid)
        t.expect(
            css.map { String(decoding: $0, as: UTF8.self) }?.contains("--lexicon-test") == true,
            "css falls back to mdx base name"
        )

        // Optional overrides must not fall back to the dictionary's base JS;
        // that would execute the original script twice when custom.js is absent.
        t.expectEqual(
            try library.resource(path: "custom.js", dictionaryUUID: basic.uuid), nil,
            "missing custom.js stays missing"
        )

        // A loose file with the exact requested name must beat the base-name
        // heuristic (custom.css themes rely on this).
        try Data("/* theme */".utf8)
            .write(to: folder.appendingPathComponent("custom.css"))
        let custom = try library.resource(path: "custom.css", dictionaryUUID: basic.uuid)
        t.expect(
            custom.map { String(decoding: $0, as: UTF8.self) } == "/* theme */",
            "exact loose file wins over base-name fallback"
        )

        // OALD-style extension-less sound reference completed by prefix.
        let wav = try library.resource(path: "pron/apple", dictionaryUUID: basic.uuid)
        t.expect(wav?.prefix(4) == Data("RIFF".utf8), "prefix completion for extension-less path")

        // Lost-context absolute path found by searching all dictionaries.
        let png = try library.resourceSearchingAllDictionaries(path: "apple.png")
        t.expect(png?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "cross-dictionary resource search")

        t.expect(!library.isKnownDictionaryUUID("apple.png"), "uuid check")
        t.expect(library.isKnownDictionaryUUID(basic.uuid), "uuid check positive")
    }

    t.run("library: second dictionary and unified search") {
        let second = try library.importDictionary(
            from: fixturesURL.appendingPathComponent("utf16.mdx")
        )
        let results = try library.search(prefix: "apple")
        t.expectEqual(results.first?.dictionaryCount, 2, "apple in both dictionaries")

        let hits = try library.entries(forNormalizedKey: "apple")
        t.expectEqual(hits.count, 2, "one hit per dictionary")
        t.expectEqual(hits[0].dictionaryTitle, "Basic Test Dictionary", "sort order respected")

        // Disable the second dictionary: search narrows.
        try library.setEnabled(false, for: second)
        let narrowed = try library.entries(forNormalizedKey: "apple")
        t.expectEqual(narrowed.count, 1, "disabled dictionary excluded")
        try library.setEnabled(true, for: second)
    }

    t.run("library: reorder") {
        var records = try library.dictionaries()
        t.expectEqual(records.count, 2)
        records.reverse()
        try library.reorder(records)
        let hits = try library.entries(forNormalizedKey: "apple")
        t.expectEqual(hits[0].dictionaryTitle, "UTF-16 Dictionary", "new order respected")
    }

    t.run("library: unregister dictionary preserves files") {
        let records = try library.dictionaries()
        guard let utf16 = records.first(where: { $0.title == "UTF-16 Dictionary" }) else {
            t.expect(false, "utf16 record missing")
            return
        }
        let dictionaryFolder = library.folderURL(for: utf16)
        try library.unregisterDictionary(utf16)
        t.expectEqual(try library.dictionaries().count, 1)
        let hits = try library.entries(forNormalizedKey: "apple")
        t.expectEqual(hits.count, 1, "entries cleaned up")
        t.expect(
            FileManager.default.fileExists(atPath: dictionaryFolder.path),
            "unregistering does not permanently delete dictionary files"
        )
    }
}
