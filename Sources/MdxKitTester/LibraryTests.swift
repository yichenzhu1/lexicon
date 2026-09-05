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

    t.run("library: differently named sibling css and js import automatically") {
        let source = tempRoot.appendingPathComponent("loose-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixturesURL.appendingPathComponent("astral.mdx"),
            to: source.appendingPathComponent("astral.mdx")
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("assets"), withIntermediateDirectories: true
        )
        try Data(
            """
            .entry { color: teal; background: url(assets/icon.svg) }
            .optional-decoration { background: url(assets/missing-chevron.png) }
            @font-face { font-family: optional; src: url(assets/missing-font.otf) }
            """.utf8
        )
            .write(to: source.appendingPathComponent("oald.css"))
        try Data("window.fixtureLoaded = true".utf8)
            .write(to: source.appendingPathComponent("oald.js"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
            .write(to: source.appendingPathComponent("assets/icon.svg"))

        let looseRoot = tempRoot.appendingPathComponent("loose-resources")
        let looseLibrary = try DictionaryLibrary(rootURL: looseRoot)
        var importStages: [String] = []
        let record = try looseLibrary.importDictionary(
            from: source.appendingPathComponent("astral.mdx")
        ) { importStages.append($0.stage) }
        t.expect(record.hasResources, "differently named loose companions detected without an MDD")
        t.expectEqual(record.resourceCount, 0, "MDD count remains separate")
        t.expectEqual(record.looseResourceCount, 3, "CSS, JavaScript and CSS dependency counted")
        t.expectEqual(try looseLibrary.dictionaries().first?.totalResourceCount, 3, "loose count persisted")
        t.expect(try looseLibrary.resource(path: "oald.css", dictionaryUUID: record.uuid) != nil,
                 "differently named CSS served")
        t.expect(try looseLibrary.resource(path: "oald.js", dictionaryUUID: record.uuid) != nil,
                 "differently named JavaScript served")
        t.expect(try looseLibrary.resource(path: "assets/icon.svg", dictionaryUUID: record.uuid) != nil,
                 "resource referenced by sibling CSS copied recursively")
        t.expect(
            !importStages.contains(where: { $0.hasPrefix("Warning:") }),
            "missing optional CSS font/background fallbacks do not warn"
        )
    }

    t.run("library: entry-only references import nested loose assets") {
        let source = tempRoot.appendingPathComponent("nested-source")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("assets"), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixturesURL.appendingPathComponent("nested.mdx"),
            to: source.appendingPathComponent("nested.mdx")
        )
        let image = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        try image.write(to: source.appendingPathComponent("assets/picture.svg"))
        let nestedLibrary = try DictionaryLibrary(rootURL: tempRoot.appendingPathComponent("nested"))
        let record = try nestedLibrary.importDictionary(from: source.appendingPathComponent("nested.mdx"))
        t.expectEqual(record.looseResourceCount, 1, "nested asset discovered without CSS or MDD")
        t.expectEqual(
            try nestedLibrary.resource(path: "assets/picture.svg", dictionaryUUID: record.uuid)?.data,
            image, "nested asset copied and served intact"
        )
    }

    t.run("library: top-level static companions import without entry discovery") {
        let source = tempRoot.appendingPathComponent("static-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixturesURL.appendingPathComponent("astral.mdx"),
            to: source.appendingPathComponent("static.mdx")
        )
        try Data("fixture image".utf8).write(to: source.appendingPathComponent("INTRODUCTION.jpeg"))
        try Data("fixture icon".utf8).write(to: source.appendingPathComponent("static.png"))

        let staticRoot = tempRoot.appendingPathComponent("static-resources")
        let staticLibrary = try DictionaryLibrary(rootURL: staticRoot)
        let record = try staticLibrary.importDictionary(from: source.appendingPathComponent("static.mdx"))
        t.expectEqual(record.looseResourceCount, 2, "top-level static companions counted")
        t.expect(
            try staticLibrary.resource(path: "INTRODUCTION.jpeg", dictionaryUUID: record.uuid) != nil,
            "differently named top-level image served"
        )
        t.expectEqual(
            staticLibrary.iconURL(for: record)?.lastPathComponent, "static.png",
            "same-basename dictionary icon discovered"
        )
    }

    t.run("library: failed resource indexing rolls back the whole import") {
        let source = tempRoot.appendingPathComponent("broken-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixturesURL.appendingPathComponent("basic.mdx"),
            to: source.appendingPathComponent("broken.mdx")
        )
        try Data("not an mdd".utf8).write(to: source.appendingPathComponent("broken.mdd"))

        let rollbackRoot = tempRoot.appendingPathComponent("rollback")
        let rollbackLibrary = try DictionaryLibrary(rootURL: rollbackRoot)
        t.expectThrows("corrupt sibling mdd rejects import") {
            try rollbackLibrary.importDictionary(from: source.appendingPathComponent("broken.mdx"))
        }
        t.expectEqual(
            try rollbackLibrary.dictionaries().count, 0,
            "failed import leaves no dictionary row"
        )
        let copiedFolders = try FileManager.default.contentsOfDirectory(
            at: rollbackLibrary.dictionariesURL,
            includingPropertiesForKeys: nil
        ).filter { ![".staging", "Recovery"].contains($0.lastPathComponent) }
        t.expectEqual(copiedFolders.count, 0, "failed import leaves no copied folder")
    }

    t.run("library: pre-cancelled import leaves staging empty") {
        let cancelRoot = tempRoot.appendingPathComponent("cancelled")
        let cancelLibrary = try DictionaryLibrary(rootURL: cancelRoot)
        let cancellation = ImportCancellationToken()
        cancellation.cancel()
        t.expectThrows("cancelled before copy") {
            try cancelLibrary.importDictionary(
                from: fixturesURL.appendingPathComponent("basic.mdx"),
                cancellation: cancellation
            )
        }
        t.expectEqual(try cancelLibrary.dictionaries().count, 0, "cancelled import has no row")
        let staging = cancelLibrary.dictionariesURL.appendingPathComponent(".staging")
        t.expectEqual(
            try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).count,
            0, "cancelled import cleans staging"
        )
    }

    t.run("library: cancellation after entry insertion rolls back the transaction") {
        let cancelRoot = tempRoot.appendingPathComponent("cancelled-during-indexing")
        let cancelLibrary = try DictionaryLibrary(rootURL: cancelRoot)
        let cancellation = ImportCancellationToken()
        var reachedResources = false
        t.expectThrows("cancelled after entries were inserted") {
            try cancelLibrary.importDictionary(
                from: fixturesURL.appendingPathComponent("basic.mdx"), cancellation: cancellation
            ) { update in
                if update.stage == "Indexing resources" {
                    reachedResources = true
                    cancellation.cancel()
                }
            }
        }
        t.expect(reachedResources, "cancellation occurred inside the indexing transaction")
        let db = try SQLiteDB(path: cancelRoot.appendingPathComponent("index.sqlite").path, readOnly: true)
        for table in ["dictionaries", "entries", "resources"] {
            t.expectEqual(
                try db.query("SELECT COUNT(*) FROM \(table)") { $0.int(0) }.first,
                0, "partial \(table) rows rolled back"
            )
        }
        t.expectEqual(
            try FileManager.default.contentsOfDirectory(
                at: cancelLibrary.dictionariesURL.appendingPathComponent(".staging"),
                includingPropertiesForKeys: nil
            ).count,
            0, "partially indexed import cleans staging"
        )
    }

    t.run("library: startup reconciliation preserves orphan folders") {
        let recoveryRoot = tempRoot.appendingPathComponent("recovery")
        var first: DictionaryLibrary? = try DictionaryLibrary(rootURL: recoveryRoot)
        let orphan = first!.dictionariesURL.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: orphan.appendingPathComponent("asset.bin"))
        first = nil

        let reopened = try DictionaryLibrary(rootURL: recoveryRoot)
        let recovery = reopened.dictionariesURL.appendingPathComponent("Recovery", isDirectory: true)
        let recovered = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        t.expectEqual(recovered.count, 1, "orphan moved to recovery")
        t.expect(
            FileManager.default.fileExists(atPath: recovered[0].appendingPathComponent("asset.bin").path),
            "orphan contents preserved"
        )
        t.expect(!reopened.startupWarnings.isEmpty, "recovery is reported")
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

    t.run("library: pre-cancelled search is rejected") {
        let cancellation = SearchCancellationToken()
        cancellation.cancel()
        t.expectThrows("cancelled search") {
            _ = try library.search(matching: "zzzz", cancellation: cancellation)
        }
    }

    t.run("SQLite: cancellation interrupts an active scan and removes its handler") {
        let db = try SQLiteDB(path: tempRoot.appendingPathComponent("scan.sqlite").path)
        let cancellation = SearchCancellationToken()
        let scan = """
            WITH RECURSIVE numbers(n) AS (
                VALUES(1) UNION ALL SELECT n + 1 FROM numbers WHERE n < 10000
            ) SELECT SUM(n) FROM numbers
            """
        t.expectThrows("running SQLite VM is interrupted") {
            try db.withProgressCancellation({
                // Invoked by SQLite only after the statement has begun running.
                cancellation.cancel()
                return cancellation.isCancelled
            }) {
                _ = try db.query(scan) { $0.int(0) }
            }
        }
        t.expect(cancellation.isCancelled, "scan reached the VM progress callback")
        t.expectEqual(
            try db.query(scan) { $0.int(0) }.first,
            50_005_000, "the same connection can scan again after cancellation"
        )
    }

    t.run("library: search tiers rank exact over prefix over substring") {
        let results = try library.search(matching: "apple")
        t.expectEqual(results.first?.displayKey, "apple", "exact match leads")
        t.expectEqual(results.first?.matchKind, .exact, "exact match is labelled")
        let prefetched = try library.searchPrefix(matching: "apple")
        let reused = try library.search(matching: "apple", prefixResults: prefetched)
        t.expectEqual(reused, results, "prefetched prefix phase is reused without changing results")

        // "ana" appears inside "banana" but starts nothing, so it can only be
        // found by the substring tier.
        let inside = try library.search(matching: "anan")
        t.expect(
            inside.contains { $0.displayKey == "banana" && $0.matchKind == .substring },
            "substring match found, got \(inside.map(\.displayKey))"
        )

        // Prefix matches must still outrank substring ones.
        let mixed = try library.search(matching: "a")
        guard let firstSubstring = mixed.firstIndex(where: { $0.matchKind == .substring }),
              let lastPrefix = mixed.lastIndex(where: { $0.matchKind <= .prefix })
        else {
            t.expect(false, "fixture must produce both prefix and substring matches")
            return
        }
        t.expect(lastPrefix < firstSubstring, "prefix matches sort above substring")
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

        // Candidate selection must not depend on the query's opening bytes.
        // The former prefix bucket could never recover this typo.
        let openingTypo = try library.search(matching: "xanana")
        t.expect(
            openingTypo.contains { $0.displayKey == "banana" },
            "opening-character typo suggests banana, got \(openingTypo.map(\.displayKey))"
        )

        // Adjacent key swaps are one human typo, not two unrelated edits.
        let transposed = try library.search(matching: "bannaa")
        t.expect(
            transposed.first?.displayKey == "banana",
            "transposition ranks banana first, got \(transposed.map(\.displayKey))"
        )

        // Gibberish should still come back empty rather than suggesting noise.
        t.expectEqual(try library.search(matching: "zzzzqqqq").count, 0, "no wild guesses")
    }

    t.run("library: existing index gains and maintains the trigram search index") {
        let upgradeRoot = tempRoot.appendingPathComponent("search-index-upgrade")
        var oldLibrary: DictionaryLibrary? = try DictionaryLibrary(rootURL: upgradeRoot)
        _ = try oldLibrary!.importDictionary(
            from: fixturesURL.appendingPathComponent("basic.mdx")
        )
        oldLibrary = nil

        // Recreate the shape of a version-4 library, before entry_trigrams
        // existed, then verify the one-time external-content rebuild.
        do {
            let db = try SQLiteDB(path: upgradeRoot.appendingPathComponent("index.sqlite").path)
            try db.exec("""
                DROP TRIGGER IF EXISTS entries_trigrams_insert;
                DROP TRIGGER IF EXISTS entries_trigrams_delete;
                DROP TRIGGER IF EXISTS entries_trigrams_update;
                DROP TABLE entry_trigrams;
                PRAGMA user_version = 4;
                """)
        }
        let upgraded = try DictionaryLibrary(rootURL: upgradeRoot)
        let suggestions = try upgraded.search(matching: "xanana")
        t.expect(
            suggestions.contains { $0.displayKey == "banana" },
            "upgraded trigram index serves fuzzy candidates"
        )

        // Entry-delete triggers must remove the matching external-content rows
        // without corrupting FTS's internal index.
        let record = try upgraded.dictionaries().first!
        try upgraded.unregisterDictionary(record)
        t.expectEqual(try upgraded.search(matching: "xanana").count, 0,
                      "unregister keeps trigram index consistent")
    }

    t.run("library: edit distance abandons past the limit") {
        t.expectEqual(DictionaryLibrary.editDistance("kitten", "sitting", limit: 5), 3)
        t.expectEqual(DictionaryLibrary.editDistance("abc", "abc", limit: 2), 0)
        t.expectEqual(DictionaryLibrary.editDistance("", "abc", limit: 5), 3)
        t.expectEqual(DictionaryLibrary.editDistance("apple", "appel", limit: 1), 1,
                      "adjacent transposition is one edit")
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
        t.expect(png?.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "png from mdd")
        t.expectEqual(png?.mimeType, "image/png", "typed resource MIME")
        let lowerUUID = try library.resource(
            path: "apple.png", dictionaryUUID: basic.uuid.lowercased()
        )
        t.expect(lowerUUID != nil, "scheme-host UUID lookup is case-insensitive")

        let wav = try library.resource(path: "pron/apple.wav", dictionaryUUID: basic.uuid)
        t.expect(wav?.data.prefix(4) == Data("RIFF".utf8), "wav from mdd subdirectory")

        t.expect(try library.resource(path: "nope.bin", dictionaryUUID: basic.uuid) == nil, "absent resource")
    }

    t.run("library: multipart MDD order and duplicate precedence") {
        let multipartRoot = tempRoot.appendingPathComponent("multipart")
        let multipartLibrary = try DictionaryLibrary(rootURL: multipartRoot)
        let record = try multipartLibrary.importDictionary(
            from: fixturesURL.appendingPathComponent("multipart.mdx")
        )
        let css = try multipartLibrary.resource(path: "reverse.css", dictionaryUUID: record.uuid)
        t.expect(
            css.map { String(decoding: $0.data, as: UTF8.self) }?.contains("rgb(12, 34, 56)") == true,
            "base MDD stylesheet resolves from part zero"
        )
        let numbered = try multipartLibrary.resource(path: "part-one.txt", dictionaryUUID: record.uuid)
        t.expectEqual(numbered.map { String(decoding: $0.data, as: UTF8.self) }, "numbered volume")
        let duplicate = try multipartLibrary.resource(path: "duplicate.txt", dictionaryUUID: record.uuid)
        t.expectEqual(
            duplicate.map { String(decoding: $0.data, as: UTF8.self) },
            "base volume wins", "base MDD deterministically precedes numbered duplicates"
        )
    }

    t.run("library: resource fallbacks (renamed css/js, extension-less audio)") {
        // Repack case: entry references "renamed_style.css" but the package
        // ships "<mdx base>.css" as a loose file.
        let folder = library.folderURL(for: basic)
        // GoldenDict-NG gives a loose file precedence over an identically
        // named MDD resource, allowing dictionary repacks to override CSS.
        try Data(".entry { --loose-override: 1; }".utf8)
            .write(to: folder.appendingPathComponent("style.css"))
        let overridden = try library.resource(path: "style.css", dictionaryUUID: basic.uuid)
        t.expect(
            overridden.map { String(decoding: $0.data, as: UTF8.self) }?.contains("--loose-override") == true,
            "exact loose stylesheet wins over MDD"
        )

        try Data("body { --lexicon-test: 1; }".utf8)
            .write(to: folder.appendingPathComponent("basic.css"))
        let css = try library.resource(path: "renamed_style.css", dictionaryUUID: basic.uuid)
        t.expect(
            css.map { String(decoding: $0.data, as: UTF8.self) }?.contains("--lexicon-test") == true,
            "css falls back to mdx base name"
        )

        // Optional overrides must not fall back to the dictionary's base JS;
        // that would execute the original script twice when custom.js is absent.
        t.expect(try library.resource(path: "custom.js", dictionaryUUID: basic.uuid) == nil, "missing custom.js stays missing")

        // A loose file with the exact requested name must beat the base-name
        // heuristic (custom.css themes rely on this).
        try Data("/* theme */".utf8)
            .write(to: folder.appendingPathComponent("custom.css"))
        let custom = try library.resource(path: "custom.css", dictionaryUUID: basic.uuid)
        t.expect(
            custom.map { String(decoding: $0.data, as: UTF8.self) } == "/* theme */",
            "exact loose file wins over base-name fallback"
        )

        // OALD-style extension-less sound reference completed by prefix.
        let wav = try library.resource(path: "pron/apple", dictionaryUUID: basic.uuid)
        t.expect(wav?.data.prefix(4) == Data("RIFF".utf8), "prefix completion for extension-less path")

        t.expect(!library.isKnownDictionaryUUID("apple.png"), "uuid check")
        t.expect(library.isKnownDictionaryUUID(basic.uuid), "uuid check positive")
    }

    t.run("library: loose resources cannot escape through a symbolic link") {
        let folder = library.folderURL(for: basic)
        let outside = tempRoot.appendingPathComponent("outside.bin")
        try Data("private outside file".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("escape.bin"),
            withDestinationURL: outside
        )
        t.expect(try library.resource(path: "escape.bin", dictionaryUUID: basic.uuid) == nil,
                 "symlink outside dictionary folder is rejected")
        t.expect(try library.resource(path: "../outside.bin", dictionaryUUID: basic.uuid) == nil,
                 "parent traversal is rejected")
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
