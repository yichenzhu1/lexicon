import Foundation
import MdxKit

/// The app reads the library from the main thread and from the dict:// scheme
/// handler's queue while imports run on their own queue. These tests exercise
/// that overlap: they are checking for crashes, corrupted results and deadlock,
/// which a single-threaded suite cannot surface.
func runConcurrencyTests(_ t: TestHarness) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("LexiconConcurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    var library: DictionaryLibrary!

    t.run("concurrency: setup") {
        library = try DictionaryLibrary(rootURL: tempRoot)
        try library.importDictionary(from: fixturesURL.appendingPathComponent("basic.mdx"))
    }

    t.run("concurrency: parallel searches and entry reads agree") {
        let library = library!
        // Pooled reader connections plus one shared block cache per open file.
        let iterations = 200
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                let results = try library.search(prefix: "app")
                guard results.contains(where: { $0.displayKey == "apple" }) else {
                    failures.mutate { $0 += 1 }
                    return
                }
                let hits = try library.entries(forNormalizedKey: "apple")
                guard let hit = hits.first,
                      try library.entryText(for: hit).contains("a round fruit")
                else {
                    failures.mutate { $0 += 1 }
                    return
                }
                // Resource reads share the same decompressed-block cache.
                if index % 4 == 0 {
                    let png = try library.resource(path: "apple.png", dictionaryUUID: hit.dictionaryUUID)
                    if png?.prefix(4) != Data([0x89, 0x50, 0x4E, 0x47]) {
                        failures.mutate { $0 += 1 }
                    }
                }
            } catch {
                failures.mutate { $0 += 1 }
            }
        }
        t.expectEqual(failures.value, 0, "no concurrent read failed")
    }

    t.run("concurrency: searches keep working during an import") {
        let library = library!
        // With one full-mutex connection this blocks behind the import's bulk
        // insert transaction; with a pool and WAL the reads proceed.
        let importDone = DispatchSemaphore(value: 0)
        let importFailure = Locked("")
        let importFinished = Locked(false)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try library.importDictionary(
                    from: fixturesURL.appendingPathComponent("utf16.mdx")
                )
            } catch {
                importFailure.mutate { $0 = "\(error)" }
            }
            importFinished.mutate { $0 = true }
            importDone.signal()
        }

        // Poll a flag rather than the semaphore: the semaphore is signalled
        // once, so consuming it here would leave the wait below hanging.
        var searchesCompleted = 0
        var searchFailure: String?
        while !importFinished.value {
            do {
                // The dictionary being imported may or may not be visible yet;
                // the one already present must be, on every single pass.
                let hits = try library.entries(forNormalizedKey: "apple")
                if !hits.contains(where: { $0.dictionaryTitle == "Basic Test Dictionary" }) {
                    searchFailure = "existing dictionary vanished mid-import"
                    break
                }
                searchesCompleted += 1
            } catch {
                searchFailure = "\(error)"
                break
            }
        }
        importDone.wait()

        t.expectEqual(importFailure.value, "", "import succeeded")
        t.expectEqual(searchFailure ?? "", "", "reads stayed available during import")
        t.expect(searchesCompleted > 0, "at least one search ran while importing")

        // The newly imported dictionary is visible once the import returns.
        let hits = try library.entries(forNormalizedKey: "apple")
        t.expectEqual(hits.count, 2, "both dictionaries visible after import")
    }

    t.run("concurrency: opening the same dictionary from many threads is consistent") {
        let library = library!
        let records = try library.dictionaries()
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            for record in records {
                if (try? library.resource(path: "apple.png", dictionaryUUID: record.uuid)) == nil {
                    failures.mutate { $0 += 1 }
                }
            }
        }
        t.expectEqual(failures.value, 0, "concurrent first-open races resolved to one handle")
    }
}

/// Minimal lock box; the suite has no dependencies to lean on.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
