import Foundation
import MdxKit

/// Lexicon opens dictionary files it did not produce, so every size, count and
/// offset in a header is untrusted input. The parser must reject a damaged file
/// with a thrown `MdxError`; it must never trap.
///
/// A Swift runtime trap kills the whole runner rather than failing one case, so
/// a regression here shows up as the test executable crashing mid-suite — which
/// is the intended signal, not a gap in the assertions.
func runCorruptFileTests(_ t: TestHarness) {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("LexiconCorrupt-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    /// Parses `bytes` through the full read path and reports whether it was
    /// handled — parsed cleanly or threw. Reaching the return at all means no
    /// trap occurred, which is what these tests are really asserting.
    @discardableResult
    func parseHandled(_ bytes: [UInt8], as ext: String = "mdx") -> Bool {
        let url = scratch.appendingPathComponent("case.\(ext)")
        do {
            try Data(bytes).write(to: url)
            let file = try MdictFile(url: url)
            let entries = try file.indexedEntries()
            for entry in entries.prefix(20) {
                _ = try file.recordData(at: entry.recordOffset, length: Int(entry.recordLength))
            }
        } catch {
            return true // rejected, as intended
        }
        return true
    }

    func fixtureBytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: fixturesURL.appendingPathComponent(name)))
    }

    t.run("corrupt: oversized header fields are rejected, not trapped") {
        // Setting an 8-byte window to 0xFF makes whatever UInt64 field lives
        // there equal UInt64.max. Before hardening this trapped with
        // "arithmetic overflow" while accumulating the record block table.
        let original = try fixtureBytes("basic.mdx")
        for offset in stride(from: 0, to: original.count - 8, by: 4) {
            var damaged = original
            for i in offset ..< offset + 8 { damaged[i] = 0xFF }
            t.expect(parseHandled(damaged), "handled 0xFF window at \(offset)")
        }
    }

    t.run("corrupt: truncation at every length is rejected, not trapped") {
        for name in ["basic.mdx", "v1.mdx", "utf16.mdx", "nocomp.mdx"] {
            let original = try fixtureBytes(name)
            for cut in stride(from: 1, to: original.count, by: max(1, original.count / 40)) {
                t.expect(parseHandled(Array(original.prefix(cut))), "handled \(name) cut to \(cut)")
            }
        }
    }

    t.run("corrupt: v1 files (no section checksums) are rejected, not trapped") {
        // v1 protects neither the keyword nor the record header, so its size
        // fields reach the table builders unvalidated by any checksum.
        let original = try fixtureBytes("v1.mdx")
        for offset in stride(from: 0, to: original.count - 8, by: 4) {
            var damaged = original
            for i in offset ..< offset + 8 { damaged[i] = 0xFF }
            t.expect(parseHandled(damaged), "handled v1 0xFF window at \(offset)")
        }
    }

    t.run("corrupt: damaged MDD resource files are rejected, not trapped") {
        let original = try fixtureBytes("basic.mdd")
        for offset in stride(from: 0, to: original.count - 8, by: 16) {
            var damaged = original
            for i in offset ..< offset + 8 { damaged[i] = 0xFF }
            t.expect(parseHandled(damaged, as: "mdd"), "handled mdd 0xFF window at \(offset)")
        }
    }

    t.run("corrupt: random byte damage is rejected, not trapped") {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextRandom(_ bound: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        let original = try fixtureBytes("basic.mdx")
        for _ in 0 ..< 300 {
            var damaged = original
            for _ in 0 ..< 6 {
                damaged[nextRandom(damaged.count)] = UInt8(nextRandom(256))
            }
            t.expect(parseHandled(damaged), "handled randomly damaged file")
        }
    }

    t.run("corrupt: an empty or stub file throws") {
        t.expectThrows("empty file") {
            let url = scratch.appendingPathComponent("empty.mdx")
            try Data().write(to: url)
            _ = try MdictFile(url: url)
        }
        t.expectThrows("stub file") {
            let url = scratch.appendingPathComponent("stub.mdx")
            try Data([0x00, 0x00, 0x10, 0x00, 0x41, 0x42]).write(to: url)
            _ = try MdictFile(url: url)
        }
    }
}
