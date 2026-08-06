import AVFoundation
import AppKit
import Combine
import Foundation
import MdxKit
import SwiftUI

/// State that belongs to the whole app rather than to one window: the open
/// dictionary library, the imported dictionary list, and the history and
/// starred-word files.
///
/// Exactly one of these exists. Giving each window its own would mean a second
/// SQLite connection, duplicate memory-mapped dictionary files and block
/// caches, and two windows writing `history.json` over each other.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var dictionaries: [DictionaryRecord] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var starred: [String] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    @Published var errorMessage: String?
    @Published private(set) var removingDictionaryIDs: Set<Int64> = []
    /// Bumped whenever rendered content may change (dictionary set edited).
    @Published private(set) var contentVersion = 0

    let library: DictionaryLibrary?

    private var audioPlayer: AVAudioPlayer?
    private let importQueue = DispatchQueue(label: "lexicon.import", qos: .userInitiated)
    /// Resolved headwords, keyed by normalized key. `displayWord` is called
    /// from view bodies for every history row, tab and starred card, so an
    /// uncached lookup ran a SQL query per row on every keystroke.
    private var displayWordCache: [String: String] = [:]

    nonisolated static var defaultRoot: URL {
        // Override for testing against a disposable library.
        if let override = ProcessInfo.processInfo.environment["LEXICON_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexicon", isDirectory: true)
    }

    init(rootURL: URL = LibraryModel.defaultRoot) {
        do {
            library = try DictionaryLibrary(rootURL: rootURL)
        } catch {
            library = nil
            errorMessage = "Could not open the dictionary library: \(error.localizedDescription)"
        }
        loadSidecarLists()
        reloadDictionaries()
    }

    // MARK: - Dictionaries

    func reloadDictionaries() {
        guard let library else { return }
        do {
            dictionaries = try library.dictionaries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDictionaries(at urls: [URL]) {
        guard let library else { return }
        isImporting = true
        importStatus = "Starting import…"
        importQueue.async { [weak self] in
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let name = url.lastPathComponent
                    try library.importDictionary(from: url) { status in
                        Task { @MainActor [weak self] in
                            self?.importStatus = "\(name): \(status)"
                        }
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isImporting = false
                self.importStatus = ""
                if !failures.isEmpty {
                    self.errorMessage = "Import failed for:\n" + failures.joined(separator: "\n")
                }
                self.dictionariesChanged()
            }
        }
    }

    func removeDictionary(_ record: DictionaryRecord) {
        guard let library, !removingDictionaryIDs.contains(record.id) else { return }
        let folderURL = library.folderURL(for: record)
        removingDictionaryIDs.insert(record.id)

        // A stale database row can outlive a manually removed folder. In that
        // case there is nothing to recycle, so only unregister the record.
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            finishRemovingDictionary(record, filesWereRecycled: false)
            return
        }

        NSWorkspace.shared.recycle([folderURL]) { [weak self] _, recycleError in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let recycleError {
                    self.removingDictionaryIDs.remove(record.id)
                    self.errorMessage = "Could not move “\(record.title)” to Trash: "
                        + recycleError.localizedDescription
                    return
                }
                self.finishRemovingDictionary(record, filesWereRecycled: true)
            }
        }
    }

    private func finishRemovingDictionary(
        _ record: DictionaryRecord, filesWereRecycled: Bool
    ) {
        guard let library else {
            removingDictionaryIDs.remove(record.id)
            return
        }
        do {
            try library.unregisterDictionary(record)
        } catch {
            if filesWereRecycled {
                errorMessage = "“\(record.title)” was moved to Trash, but Lexicon "
                    + "could not remove it from the library index: \(error.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
        removingDictionaryIDs.remove(record.id)
        dictionariesChanged()
    }

    func setEnabled(_ enabled: Bool, for record: DictionaryRecord) {
        guard let library else { return }
        do {
            try library.setEnabled(enabled, for: record)
        } catch {
            errorMessage = error.localizedDescription
        }
        dictionariesChanged()
    }

    func moveDictionaries(fromOffsets: IndexSet, toOffset: Int) {
        guard let library else { return }
        var reordered = dictionaries
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        do {
            try library.reorder(reordered)
        } catch {
            errorMessage = error.localizedDescription
        }
        dictionariesChanged()
    }

    /// Invalidates rendered content everywhere. Every window observes this
    /// model, so all of them re-render.
    private func dictionariesChanged() {
        displayWordCache.removeAll()
        reloadDictionaries()
        contentVersion += 1
    }

    func reloadRenderedContent() {
        contentVersion += 1
    }

    // MARK: - Headword display

    /// Headword with original casing/diacritics for a normalized key.
    func displayWord(for normalizedKey: String?) -> String? {
        guard let normalizedKey else { return nil }
        if let cached = displayWordCache[normalizedKey] { return cached }
        let resolved = try? library?.entries(forNormalizedKey: normalizedKey).first?.key
        // Cache the fallback too, so an unknown word is not re-queried on
        // every render pass.
        let display = (resolved ?? nil) ?? normalizedKey
        displayWordCache[normalizedKey] = display
        return display
    }

    // MARK: - History & starred

    private var historyURL: URL? {
        library?.rootURL.appendingPathComponent("history.json")
    }
    private var starredURL: URL? {
        library?.rootURL.appendingPathComponent("starred.json")
    }

    private func loadSidecarLists() {
        func load(_ url: URL?) -> [String] {
            guard let url, let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return list
        }
        history = load(historyURL)
        starred = load(starredURL)
    }

    private func save(_ list: [String], to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func recordHistory(_ word: String) {
        var updated = history.filter { $0 != word }
        updated.insert(word, at: 0)
        if updated.count > 200 { updated.removeLast(updated.count - 200) }
        history = updated
        save(history, to: historyURL)
    }

    func clearHistory() {
        history = []
        save(history, to: historyURL)
    }

    func isStarred(_ word: String) -> Bool {
        starred.contains(word)
    }

    func toggleStar(_ word: String) {
        if let index = starred.firstIndex(of: word) {
            starred.remove(at: index)
        } else {
            starred.insert(word, at: 0)
        }
        save(starred, to: starredURL)
    }

    // MARK: - Audio

    func playAudio(path: String, dictionaryUUID: String) {
        guard let library else { return }
        do {
            guard let data = try library.resource(path: path, dictionaryUUID: dictionaryUUID) else {
                return
            }
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            // Unsupported codec (e.g. .spx) — ignore silently.
        }
    }
}
