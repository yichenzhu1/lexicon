import Foundation
import MdxKit

// Seed mode: `swift run MdxKitTester seed <root>` imports the fixture
// dictionaries into a library root, for manually trying the app:
//   LEXICON_ROOT=<root> ./build/Lexicon.app/Contents/MacOS/Lexicon
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "seed" {
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    do {
        let library = try DictionaryLibrary(rootURL: root)
        for fixture in ["basic.mdx", "encrypted.mdx", "utf16.mdx"] {
            let record = try library.importDictionary(
                from: fixturesURL.appendingPathComponent(fixture)
            )
            print("imported \(fixture) as \"\(record.title)\" (\(record.entryCount) entries)")
        }
        print("seeded library at \(root.path)")
        exit(0)
    } catch {
        print("seed failed: \(error)")
        exit(1)
    }
}

// Import mode: `swift run MdxKitTester import <root> <dictionary.mdx>`
// is useful for verifying a real package without opening the GUI.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "import" {
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let mdx = URL(fileURLWithPath: CommandLine.arguments[3])
    do {
        let library = try DictionaryLibrary(rootURL: root)
        let record = try library.importDictionary(from: mdx) { update in
            if update.completed == 0 || update.completed == update.total
                || (update.completed > 0 && update.completed.isMultiple(of: 100_000)) {
                print("\(update.stage): \(update.completed)/\(update.total)")
            }
        }
        let folder = library.folderURL(for: record)
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        print("imported \(record.title): \(record.entryCount) entries, "
            + "\(record.resourceCount) MDD resources, \(record.looseResourceCount) loose resources")
        print("folder: \(folder.path)")
        print("files: \(files.joined(separator: ", "))")
        exit(0)
    } catch {
        print("import failed: \(error)")
        exit(1)
    }
}

// Dump mode: `swift run MdxKitTester dump <root> <word> <outdir>`
// writes each dictionary's raw entry HTML for a word to files.
if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "dump" {
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let word = CommandLine.arguments[3]
    let outDir = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let library = try DictionaryLibrary(rootURL: root)
        let hits = try library.entries(forNormalizedKey: DictionaryLibrary.normalizeKey(word))
        for (i, hit) in hits.enumerated() {
            let text = try library.entryText(for: hit)
            let name = "\(i)-\(hit.dictionaryTitle.prefix(8))-\(word).html"
                .replacingOccurrences(of: "/", with: "_")
            try text.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            print("wrote \(name) (\(text.count) chars)")
        }
        exit(0)
    } catch {
        print("dump failed: \(error)")
        exit(1)
    }
}

// Resource dump: `swift run MdxKitTester res <root> <dictTitleSubstring> <path> <outfile>`
if CommandLine.arguments.count >= 6, CommandLine.arguments[1] == "res" {
    let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let titlePart = CommandLine.arguments[3]
    let path = CommandLine.arguments[4]
    let outFile = URL(fileURLWithPath: CommandLine.arguments[5])
    do {
        let library = try DictionaryLibrary(rootURL: root)
        guard let record = try library.dictionaries().first(where: { $0.title.contains(titlePart) }) else {
            print("no dictionary matching \(titlePart)")
            exit(1)
        }
        guard let resource = try library.resource(path: path, dictionaryUUID: record.uuid) else {
            print("resource not found: \(path)")
            exit(1)
        }
        try resource.data.write(to: outFile)
        print("wrote \(resource.data.count) bytes from \(record.title) to \(outFile.path)")
        exit(0)
    } catch {
        print("res failed: \(error)")
        exit(1)
    }
}

// Diagnostic mode: `swift run MdxKitTester diag <root> [words…]`
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "diag" {
    let words = CommandLine.arguments.count > 3
        ? Array(CommandLine.arguments.dropFirst(3))
        : ["apple", "go", "take off", "naïve", "color"]
    runDiagnostics(root: CommandLine.arguments[2], words: words)
    exit(0)
}

let t = TestHarness()

print("MdxKit tests")
print("============")

// MARK: - Hashing / checksums

t.run("ripemd128 known vectors") {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    t.expectEqual(hex(RIPEMD128.hash(Data())), "cdf26213a150dc3ecb610f18f6b38b46")
    t.expectEqual(hex(RIPEMD128.hash(Data("a".utf8))), "86be7afa339d0fc7cfc785e72f578d33")
    t.expectEqual(hex(RIPEMD128.hash(Data("abc".utf8))), "c14a12199c66e4ba84636b0f69144c77")
    t.expectEqual(hex(RIPEMD128.hash(Data("message digest".utf8))), "9e327b3d6e523062afc1132d7df9d1b8")
    t.expectEqual(
        hex(RIPEMD128.hash(Data("abcdefghijklmnopqrstuvwxyz".utf8))),
        "fd2aa607f71dc8f510714922b371834e"
    )
}

t.run("adler32") {
    t.expectEqual(Adler32.checksum(Data("Wikipedia".utf8)), 0x11E6_0398)
    t.expectEqual(Adler32.checksum(Data()), 1)
}

// MARK: - LZO

t.run("lzo literal-only stream") {
    let payload = Data("hello, lzo!".utf8)
    var stream = Data([UInt8(17 + payload.count)])
    stream.append(payload)
    stream.append(contentsOf: [0x11, 0x00, 0x00])
    let out = try LZO1X.decompress(stream, expectedSize: payload.count)
    t.expectEqual(out, payload)
}

t.run("lzo truncated stream throws") {
    var stream = Data([0x16])
    stream.append(Data("abcab".utf8))
    t.expectThrows("truncated stream") {
        _ = try LZO1X.decompress(stream, expectedSize: 5)
    }
}

// MARK: - MDX/MDD parser (fixture-based)

runParserTests(t)

// MARK: - Parser robustness against damaged files

runCorruptFileTests(t)

// MARK: - Library: import, index, search

runLibraryTests(t)

// MARK: - Library under concurrent access

runConcurrencyTests(t)

// MARK: - HTML page generation

runPageBuilderTests(t)

t.finish()
