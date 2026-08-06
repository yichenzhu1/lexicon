import AppKit
import Combine
import Foundation
import MdxKit
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

/// State belonging to one window: its search field, result list, and browser
/// tabs. The dictionaries themselves live in the shared ``LibraryModel``, so
/// several windows can browse independently over one open library.
@MainActor
final class AppState: ObservableObject {
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedWord: String? {
        didSet {
            if let word = selectedWord, word != oldValue, !isSyncingTabSelection {
                libraryModel.recordHistory(word)
                updateActiveTab(to: word)
            }
        }
    }
    @Published private(set) var tabs: [EntryTab]
    @Published private(set) var activeTabID: UUID
    @Published var showDictionaryManager = false

    let libraryModel: LibraryModel
    private var searchTask: Task<Void, Never>?
    private var isSyncingTabSelection = false

    var library: DictionaryLibrary? { libraryModel.library }

    init(libraryModel: LibraryModel) {
        self.libraryModel = libraryModel
        let initialTab = EntryTab()
        tabs = [initialTab]
        activeTabID = initialTab.id
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
            results = try library.search(matching: trimmed, limit: 80)
        } catch {
            libraryModel.errorMessage = error.localizedDescription
            results = []
        }
    }

    /// Headword with original casing/diacritics for a normalized key.
    func displayWord(for normalizedKey: String?) -> String? {
        libraryModel.displayWord(for: normalizedKey)
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
        libraryModel.reloadRenderedContent()
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
}
