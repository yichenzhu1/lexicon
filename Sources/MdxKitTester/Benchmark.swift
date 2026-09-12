import Foundation
import MdxKit

/// Synthetic, repeatable public-API benchmarks. Setup and import are excluded
/// from timings; no user dictionary files are read or modified.
func runBenchmarks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("LexiconBenchmark-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    try runParserAndHTMLBenchmarks(root: root)

    func measure<Input>(
        _ name: String, prepare: () throws -> Input,
        operation: (Input) throws -> Void
    ) throws {
        for _ in 0..<3 { try operation(prepare()) }
        var milliseconds: [Double] = []
        for _ in 0..<31 {
            let input = try prepare()
            let start = DispatchTime.now().uptimeNanoseconds
            try operation(input)
            milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        milliseconds.sort()
        print(String(format: "%@: median %.3f ms, p95 %.3f ms (31 samples)",
                     name, milliseconds[15], milliseconds[29]))
    }

    let resourceRoot = root.appendingPathComponent("resources")
    let resources = try DictionaryLibrary(rootURL: resourceRoot)
    let resourceRecord = try resources.importDictionary(from: fixturesURL.appendingPathComponent("resources.mdx"))
    try measure("warm 2 MiB binary resource", prepare: {}) { _ in
        let resource = try resources.resource(path: "large.bin", dictionaryUUID: resourceRecord.uuid)
        precondition(resource?.data.count == 2 * 1024 * 1024 + 2)
    }

    // Reuse real record offsets so every lookup still reads and serves an MDD
    // payload. Only the resource index is expanded, to model a large package.
    let prefixRoot = root.appendingPathComponent("prefix")
    let prefixes = try DictionaryLibrary(rootURL: prefixRoot)
    let prefixRecord = try prefixes.importDictionary(from: fixturesURL.appendingPathComponent("basic.mdx"))
    do {
        let db = try SQLiteDB(path: prefixRoot.appendingPathComponent("index.sqlite").path)
        let source = try db.query(
            "SELECT part, offset, length FROM resources WHERE dict = ? AND path = 'pron/apple.wav'",
            [.int(prefixRecord.id)]
        ) { ($0.int(0), $0.int(1), $0.int(2)) }.first!
        try db.transaction {
            let insert = try db.prepare("INSERT INTO resources(dict,part,path,offset,length) VALUES (?,?,?,?,?)")
            for index in 0..<200_000 {
                try insert.bind([
                    .int(prefixRecord.id), .int(source.0), .text("noise/\(index).wav"),
                    .int(source.1), .int(source.2),
                ])
                try insert.step()
                insert.reset()
            }
        }
    }
    try measure("extensionless audio / 200000 indexed resources", prepare: {}) { _ in
        let resource = try prefixes.resource(path: "pron/apple", dictionaryUUID: prefixRecord.uuid)
        precondition(resource?.data.prefix(4) == Data("RIFF".utf8))
    }

    let source = root.appendingPathComponent("multipart-source")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try fm.copyItem(at: fixturesURL.appendingPathComponent("basic.mdx"), to: source.appendingPathComponent("cold.mdx"))
    for part in 0..<32 {
        let name = part == 0 ? "cold.mdd" : "cold.\(part).mdd"
        try fm.copyItem(at: fixturesURL.appendingPathComponent("basic.mdd"), to: source.appendingPathComponent(name))
    }
    let coldRoot = root.appendingPathComponent("cold-library")
    let cold = try DictionaryLibrary(rootURL: coldRoot)
    try cold.importDictionary(from: source.appendingPathComponent("cold.mdx"))
    try measure("first entry / 32 unopened MDD volumes", prepare: {
        let library = try DictionaryLibrary(rootURL: coldRoot)
        return (library, try library.entries(forNormalizedKey: "apple").first!)
    }) { library, hit in
        let text = try library.entryText(for: hit)
        precondition(text.contains("a round fruit"))
    }
}

/// Run with `swift run -c release MdxKitTester benchmark`. The writer is
/// vendored in tools/; large inputs are generated in the benchmark's temporary
/// directory and removed afterwards. Generation is excluded from timings.
private func runParserAndHTMLBenchmarks(root: URL) throws {
    let large = root.appendingPathComponent("large.mdx")
    let generator = fixturesURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/make_fixtures.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [generator.path, "--benchmark", large.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MdxError.corruptData("benchmark fixture generator exited \(process.terminationStatus)")
    }

    func measure(_ name: String, iterations: Int, operation: () throws -> Int) rethrows {
        let start = DispatchTime.now().uptimeNanoseconds
        var checksum = 0
        for _ in 0..<iterations { checksum += try operation() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "%@: %.3f ms total (%d iterations, checksum %d)",
                     name, elapsed, iterations, checksum))
    }

    try measure("parse/index 50000 long Unicode headwords", iterations: 3) {
        try MdictFile(url: large).indexedEntries().count
    }
    try measure("parse/index/read five format fixtures", iterations: 100) {
        var checksum = 0
        for name in ["basic", "encrypted", "utf16", "v1", "nocomp"] {
            let file = try MdictFile(url: fixturesURL.appendingPathComponent("\(name).mdx"))
            checksum += try file.indexedEntries().count
            checksum += try file.recordData(at: 0, length: 700).count
        }
        return checksum
    }
    let html = String(repeating:
        "é😀中文<img src='//cdn.example/a.png'>尾<style>.x{background:url(file:///b.png)}</style>", count: 500)
    measure("normalize 500 Unicode HTML reference groups", iterations: 20) {
        EntryPageBuilder.normalizeEntryHTML(html).utf8.count
    }
    measure("discover resources in 500 HTML reference groups", iterations: 20) {
        EntryPageBuilder.localResourceReferences(in: html).count
    }
}
