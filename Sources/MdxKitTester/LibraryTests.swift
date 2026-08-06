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

    t.run("library: import reports progress and counts resources") {
        let progressRoot = tempRoot.appendingPathComponent("progress")
        let progressLibrary = try DictionaryLibrary(rootURL: progressRoot)

        var stages: [String] = []
        var sawDeterminate = false
        var lastCompleted = 0
        var monotonic = true
        let record = try progressLibrary.importDictionary(
            from: fixturesURL.appendingPathComponent("basic.mdx")
        ) { update in
            if stages.last != update.stage { stages.append(update.stage) }
            if let fraction = update.fraction {
                sawDeterminate = true
                if fraction < 0 || fraction > 1 { monotonic = false }
                if update.completed < lastCompleted { monotonic = false }
                lastCompleted = update.completed
            }
        }

        t.expect(stages.contains("Copying files…"), "reports copying, got \(stages)")
        t.expect(stages.contains("Indexing entries"), "reports indexing, got \(stages)")
        t.expect(sawDeterminate, "entry indexing is countable from the header")
        t.expect(monotonic, "progress never goes backwards or out of range")

        // basic.mdd sits beside basic.mdx, so resources must be indexed.
        t.expect(record.hasResources, "sibling mdd indexed, got \(record.resourceCount)")
        t.expectEqual(
            try progressLibrary.dictionaries().first?.resourceCount, record.resourceCount,
            "resource count persisted"
        )
    }

    t.run("library: a dictionary with no mdd reports having no resources") {
        // astral.mdx ships without a companion .mdd — the silent-failure case
        // the import warning exists to catch.
        let soloRoot = tempRoot.appendingPathComponent("noresources")
        let soloLibrary = try DictionaryLibrary(rootURL: soloRoot)
        let record = try soloLibrary.importDictionary(
            from: fixturesURL.appendingPathComponent("astral.mdx")
        )
        t.expect(!record.hasResources, "no resources detected")
        t.expectEqual(record.resourceCount, 0, "resource count is zero")
    }

    t.run("library: renaming changes only the library label") {
        let renameRoot = tempRoot.appendingPathComponent("rename")
        let renameLibrary = try DictionaryLibrary(rootURL: renameRoot)
        let record = try renameLibrary.importDictionary(
            from: fixturesURL.appendingPathComponent("basic.mdx")
        )
        try renameLibrary.setTitle("  My Dictionary  ", for: record)
        t.expectEqual(
            try renameLibrary.dictionaries().first?.title, "My Dictionary",
            "renamed and trimmed"
        )

        // A blank name would leave the row unlabelled, so it is ignored.
        try renameLibrary.setTitle("   ", for: record)
        t.expectEqual(
            try renameLibrary.dictionaries().first?.title, "My Dictionary",
            "blank rename rejected"
        )

        // The underlying files keep their own names.
        t.expectEqual(
            try renameLibrary.dictionaries().first?.mdxFileName, "basic.mdx",
            "files untouched"
        )
    }

    t.run("library: prefix search") {
        let results = try library.search(matching: "app")
        t.expect(results.contains { $0.displayKey == "apple" }, "apple found by prefix")

        // Diacritic-insensitive: plain "nai" finds "naïve".
        let naive = try library.search(matching: "nai")
        t.expect(naive.contains { $0.displayKey == "naïve" }, "diacritic-insensitive search")

        // Case-insensitive: "case sen" finds "Case Sensitive".
        let mixed = try library.search(matching: "CASE SEN")
        t.expect(mixed.contains { $0.displayKey == "Case Sensitive" }, "case-insensitive search")

        t.expectEqual(try library.search(matching: "zzzz").count, 0, "no bogus matches")
        t.expectEqual(try library.search(matching: "  ").count, 0, "blank query")
    }

    t.run("library: search tiers rank exact over prefix over substring") {
        let results = try library.search(matching: "apple")
        t.expectEqual(results.first?.displayKey, "apple", "exact match leads")
        t.expectEqual(results.first?.matchKind, .exact, "exact match is labelled")

        // "ana" appears inside "banana" but starts nothing, so it can only be
        // found by the substring tier.
        let inside = try library.search(matching: "anan")
        t.expect(
            inside.contains { $0.displayKey == "banana" && $0.matchKind == .substring },
            "substring match found, got \(inside.map(\.displayKey))"
        )

        // Prefix matches must still outrank substring ones.
        let mixed = try library.search(matching: "an")
        if let firstSubstring = mixed.firstIndex(where: { $0.matchKind == .substring }),
           let lastPrefix = mixed.lastIndex(where: { $0.matchKind <= .prefix }) {
            t.expect(lastPrefix < firstSubstring, "prefix matches sort above substring")
        }
    }

    t.run("library: near misses are suggested when nothing matches") {
        // A typo: one substitution away from "banana".
        let suggestions = try library.search(matching: "banona")
        t.expect(
            suggestions.contains { $0.displayKey == "banana" },
            "typo suggests the real word, got \(suggestions.map(\.displayKey))"
        )
        t.expect(
            suggestions.allSatisfy { $0.matchKind == .fuzzy },
            "suggestions are labelled as such"
        )

        // Gibberish should still come back empty rather than suggesting noise.
        t.expectEqual(try library.search(matching: "zzzzqqqq").count, 0, "no wild guesses")
    }

    t.run("library: edit distance abandons past the limit") {
        t.expectEqual(DictionaryLibrary.editDistance("kitten", "sitting", limit: 5), 3)
        t.expectEqual(DictionaryLibrary.editDistance("abc", "abc", limit: 2), 0)
        t.expectEqual(DictionaryLibrary.editDistance("", "abc", limit: 5), 3)
        // Beyond the limit the exact value does not matter, only that it is over.
        t.expect(DictionaryLibrary.editDistance("abcdef", "uvwxyz", limit: 2) > 2, "bails out")
    }

    t.run("library: prefix search spans the whole Unicode range") {
        // The key range's upper bound is compared byte-wise by SQLite. A bound
        // of U+FFFF sorts below astral UTF-8 sequences and silently hides
        // emoji and CJK Extension B headwords.
        let astralRoot = tempRoot.appendingPathComponent("astral")
        let astralLibrary = try DictionaryLibrary(rootURL: astralRoot)
        try astralLibrary.importDictionary(
            from: fixturesURL.appendingPathComponent("astral.mdx")
        )

        let matches = try astralLibrary.search(matching: "test")
        let keys = Set(matches.map(\.displayKey))
        t.expectEqual(matches.count, 4, "every headword sharing the prefix, got \(keys)")
        t.expect(keys.contains("test\u{1F600}"), "astral emoji headword found")
        t.expect(keys.contains("test\u{20000}"), "CJK Extension B headword found")
        t.expect(keys.contains("testing"), "plain ASCII continuation still found")

        // The range bound must still exclude non-matches: anything "tesu"
        // returns can only be a suggestion, never a literal match.
        let nonMatches = try astralLibrary.search(matching: "tesu")
        t.expect(
            nonMatches.allSatisfy { $0.matchKind == .fuzzy },
            "prefix stays tight, got \(nonMatches.map { "\($0.displayKey):\($0.matchKind)" })"
        )
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
        let results = try library.search(matching: "apple")
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
