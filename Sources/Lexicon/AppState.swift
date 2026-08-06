import AVFoundation
import AppKit
import Combine
import Foundation
// Library access is serialized: SQLite runs in full-mutex mode and the import
// queue never touches the main thread's open-file handle cache.
@preconcurrency import MdxKit
import SwiftUI

struct EntryTab: Identifiable, Equatable {
    let id: UUID
    var word: String?
    var backStack: [String]
    var forwardStack: [String]

    init(
        id: UUID = UUID(), word: String? = nil,
        backStack: [String] = [], forwardStack: [String] = []
    ) {
        self.id = id
        self.word = word
        self.backStack = backStack
        self.forwardStack = forwardStack
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedWord: String? {
        didSet {
            if let word = selectedWord, word != oldValue, !isSyncingTabSelection {
                recordHistory(word)
                updateActiveTab(to: word)
            }
        }
    }
    @Published private(set) var tabs: [EntryTab]
    @Published private(set) var activeTabID: UUID
    @Published private(set) var dictionaries: [DictionaryRecord] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var starred: [String] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    @Published var errorMessage: String?
    @Published var showDictionaryManager = false
    @Published private(set) var removingDictionaryIDs: Set<Int64> = []
    /// Bumped whenever rendered content may change (dictionary set edited).
    @Published private(set) var contentVersion = 0

    let library: DictionaryLibrary?
    private var searchTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var isSyncingTabSelection = false
    private let importQueue = DispatchQueue(label: "lexicon.import", qos: .userInitiated)

    nonisolated private static var defaultRoot: URL {
        // Override for testing against a disposable library.
        if let override = ProcessInfo.processInfo.environment["LEXICON_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexicon", isDirectory: true)
    }

    init(rootURL: URL = AppState.defaultRoot) {
        let initialTab = EntryTab()
        tabs = [initialTab]
        activeTabID = initialTab.id
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

    private func dictionariesChanged() {
        reloadDictionaries()
        contentVersion += 1
        runSearchNow()
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.performSearch(query)
        }
    }

    func runSearchNow() {
        searchTask?.cancel()
        performSearch(searchText)
    }

    private func performSearch(_ query: String) {
        guard let library else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        do {
            results = try library.search(prefix: trimmed, limit: 80)
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    /// Headword with original casing/diacritics for a normalized key.
    func displayWord(for normalizedKey: String?) -> String? {
        guard let normalizedKey else { return nil }
        guard let library,
              let hit = try? library.entries(forNormalizedKey: normalizedKey).first
        else { return normalizedKey }
        return hit.key
    }

    /// Called for entry:// cross-reference links inside rendered entries.
    func navigate(to word: String) {
        let normalized = DictionaryLibrary.normalizeKey(word)
        guard !normalized.isEmpty else { return }
        searchText = word
        selectedWord = normalized
    }

    // MARK: - Browser tabs

    var activeTab: EntryTab? {
        tabs.first { $0.id == activeTabID }
    }

    var canGoBack: Bool {
        !(activeTab?.backStack.isEmpty ?? true)
    }

    var canGoForward: Bool {
        !(activeTab?.forwardStack.isEmpty ?? true)
    }

    func openNewTab() {
        let tab = EntryTab()
        tabs.append(tab)
        activeTabID = tab.id
        synchronizeSelection(to: nil)
        searchText = ""
    }

    func activateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID else { return }
        activeTabID = id
        synchronizeSelection(to: tab.word)
        synchronizeSearchText(to: tab.word)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            // Browser behavior: the last tab owns the window, so closing it
            // closes that window instead of silently replacing it.
            NSApp.keyWindow?.performClose(nil)
            return
        }

        let wasActive = id == activeTabID
        tabs.remove(at: index)
        guard wasActive else { return }
        let nextIndex = min(index, tabs.count - 1)
        activeTabID = tabs[nextIndex].id
        synchronizeSelection(to: tabs[nextIndex].word)
        synchronizeSearchText(to: tabs[nextIndex].word)
    }

    func closeActiveTabOrWindow() {
        closeTab(activeTabID)
    }

    func goBack() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let destination = tabs[index].backStack.popLast()
        else { return }
        if let current = tabs[index].word {
            tabs[index].forwardStack.append(current)
        }
        tabs[index].word = destination
        synchronizeSelection(to: destination)
        synchronizeSearchText(to: destination)
    }

    func goForward() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let destination = tabs[index].forwardStack.popLast()
        else { return }
        if let current = tabs[index].word {
            tabs[index].backStack.append(current)
        }
        tabs[index].word = destination
        synchronizeSelection(to: destination)
        synchronizeSearchText(to: destination)
    }

    func reloadActiveEntry() {
        contentVersion += 1
    }

    private func updateActiveTab(to word: String) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs[index].word != word
        else { return }
        if let current = tabs[index].word {
            tabs[index].backStack.append(current)
        }
        tabs[index].word = word
        tabs[index].forwardStack.removeAll()
    }

    private func synchronizeSelection(to word: String?) {
        isSyncingTabSelection = true
        selectedWord = word
        isSyncingTabSelection = false
    }

    private func synchronizeSearchText(to word: String?) {
        searchText = displayWord(for: word) ?? word ?? ""
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

    private func recordHistory(_ word: String) {
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
