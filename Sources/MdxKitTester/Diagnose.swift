import Foundation
import MdxKit

/// Diagnostic mode against a real library:
///   swift run MdxKitTester diag <libraryRoot> [words…]
/// Prints per-dictionary health, lookup results, and resource resolution
/// misses for the given words.
func runDiagnostics(root: String, words: [String]) {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let library: DictionaryLibrary
    do {
        library = try DictionaryLibrary(rootURL: rootURL)
    } catch {
        print("cannot open library: \(error)")
        exit(1)
    }

    var records: [DictionaryRecord] = []
    do {
        records = try library.dictionaries()
        print("Dictionaries (\(records.count)):")
        for record in records {
            print("  [\(record.enabled ? "on " : "off")] \(record.title) — \(record.entryCount) entries (\(record.folderName))")
        }
    } catch {
        print("cannot list dictionaries: \(error)")
        exit(1)
    }

    // Per-dictionary: parse header info and sample entries.
    for record in records {
        let folder = library.folderURL(for: record)
        let mdxURL = folder.appendingPathComponent(record.mdxFileName)
        do {
            let mdx = try MdictFile(url: mdxURL)
            print("\n== \(record.title)")
            print("   engine \(mdx.info.engineVersion), encoding \(mdx.info.encoding), attrs: \(mdx.info.attributes.filter { $0.key != "StyleSheet" && $0.key != "Description" })")
        } catch {
            print("\n== \(record.title): FAILED TO OPEN: \(error)")
        }
    }

    let resourceAttributePattern = try! NSRegularExpression(
        pattern: #"(?:src|href)\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]
    )

    for word in words {
        print("\n### word: \(word)")
        let started = Date()
        do {
            let results = try library.search(matching: word, limit: 10)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print("  search(\(word)) -> \(results.count) results in \(elapsed)ms: \(results.prefix(6).map(\.displayKey))")
        } catch {
            print("  search FAILED: \(error)")
        }

        let nkey = DictionaryLibrary.normalizeKey(word)
        do {
            let hits = try library.entries(forNormalizedKey: nkey)
            print("  entries(\(nkey)) -> \(hits.count) hits")
            var seenDict = Set<String>()
            for hit in hits {
                let text: String
                do {
                    text = try library.entryText(for: hit)
                } catch {
                    print("    [\(hit.dictionaryTitle)] entryText FAILED: \(error)")
                    continue
                }
                let oneline = text.replacingOccurrences(of: "\n", with: " ")
                let head = String(oneline.prefix(140))
                print("    [\(hit.dictionaryTitle)] key=\(hit.key) len=\(text.count)")
                print("      head: \(head)")

                // Resolve every referenced resource once per dictionary.
                guard !seenDict.contains(hit.dictionaryUUID) else { continue }
                seenDict.insert(hit.dictionaryUUID)
                let ns = text as NSString
                var missing: [String] = []
                var resolved = 0
                var checked = Set<String>()
                for match in resourceAttributePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    var ref = ns.substring(with: match.range(at: 1))
                    if let hash = ref.firstIndex(of: "#") { ref = String(ref[..<hash]) }
                    guard !ref.isEmpty, !checked.contains(ref) else { continue }
                    checked.insert(ref)
                    let lower = ref.lowercased()
                    if lower.hasPrefix("entry://") || lower.hasPrefix("bword://")
                        || lower.hasPrefix("http://") || lower.hasPrefix("https://")
                        || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") {
                        continue
                    }
                    var path = ref
                    if lower.hasPrefix("sound://") { path = String(ref.dropFirst("sound://".count)) }
                    path = path.removingPercentEncoding ?? path
                    do {
                        if try library.resource(path: path, dictionaryUUID: hit.dictionaryUUID) != nil {
                            resolved += 1
                        } else {
                            missing.append(ref)
                        }
                    } catch {
                        missing.append("\(ref) (error: \(error))")
                    }
                }
                print("      resources: \(resolved) resolved, \(missing.count) missing"
                      + (missing.isEmpty ? "" : " -> \(missing.prefix(8))"))
            }
        } catch {
            print("  entries FAILED: \(error)")
        }
    }

    // Random sampling: decode a spread of entries from each dictionary.
    print("\n### random entry sampling")
    for record in records {
        let folder = library.folderURL(for: record)
        do {
            let mdx = try MdictFile(url: folder.appendingPathComponent(record.mdxFileName))
            let entries = try mdx.indexedEntries()
            guard !entries.isEmpty else { continue }
            var failures = 0
            var emptyCount = 0
            let step = max(1, entries.count / 400)
            var checked = 0
            for i in stride(from: 0, to: entries.count, by: step) {
                checked += 1
                do {
                    let text = try mdx.entryText(at: entries[i].recordOffset, length: Int(entries[i].recordLength))
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyCount += 1
                        if emptyCount <= 3 { print("  [\(record.title)] EMPTY entry for key \(entries[i].key)") }
                    }
                } catch {
                    failures += 1
                    if failures <= 3 {
                        print("  [\(record.title)] DECODE FAIL key=\(entries[i].key): \(error)")
                    }
                }
            }
            print("  [\(record.title)] sampled \(checked): \(failures) decode failures, \(emptyCount) empty")
        } catch {
            print("  [\(record.title)] open failed: \(error)")
        }
    }
}
