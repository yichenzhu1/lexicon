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
                let results = try library.search(matching: "app")
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
                    if png?.data.prefix(4) != Data([0x89, 0x50, 0x4E, 0x47]) {
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
        let transactionHeld = DispatchSemaphore(value: 0)
        let resumeImport = DispatchSemaphore(value: 0)
        let importDone = DispatchSemaphore(value: 0)
        let importFailure = Locked("")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { importDone.signal() }
            do {
                try library.importDictionary(
                    from: fixturesURL.appendingPathComponent("utf16.mdx")
                ) { update in
                    // This callback runs after entry insertion, while the
                    // import still owns the writer transaction.
                    if update.stage == "Indexing resources", update.completed == 0 {
                        transactionHeld.signal()
                        if resumeImport.wait(timeout: .now() + 10) == .timedOut {
                            importFailure.mutate { $0 = "timed out waiting to resume import" }
                        }
                    }
                }
            } catch {
                importFailure.mutate { $0 = "\(error)" }
            }
        }

        let held = transactionHeld.wait(timeout: .now() + 5) == .success
        t.expect(held, "import reached its open transaction")
        let readDone = DispatchSemaphore(value: 0)
        let readFailure = Locked("")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readDone.signal() }
            do {
                let results = try library.search(matching: "app")
                let hits = try library.entries(forNormalizedKey: "apple")
                guard results.contains(where: { $0.displayKey == "apple" }),
                      hits.count == 1,
                      let hit = hits.first,
                      try library.entryText(for: hit).contains("a round fruit")
                else {
                    readFailure.mutate { $0 = "existing dictionary was unreadable during import" }
                    return
                }
            } catch {
                readFailure.mutate { $0 = "\(error)" }
            }
        }
        let readWhileImportHeld = readDone.wait(timeout: .now() + 2) == .success
        // Always release the writer, including when a regression blocked the
        // reader, so the test can report a failure without hanging.
        resumeImport.signal()
        guard importDone.wait(timeout: .now() + 5) == .success else {
            print("FAIL: import did not finish after releasing its transaction")
            exit(1)
        }
        if !readWhileImportHeld, readDone.wait(timeout: .now() + 5) != .success {
            print("FAIL: reader did not finish after releasing the import")
            exit(1)
        }
        t.expect(readWhileImportHeld, "search and entry read finished before releasing the writer")
        t.expectEqual(importFailure.value, "", "import succeeded")
        t.expectEqual(readFailure.value, "", "reads remained correct during import")

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
