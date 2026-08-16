import AppKit
import Combine
import Foundation
import MdxKit
import SwiftUI

struct EntryLocation: Equatable, Sendable {
    var word: String
    var anchor: String?
    var preferredDictionaryUUID: String?
    var scrollOffset: Double = 0
}

struct EntryTab: Identifiable, Equatable {
    let id: UUID
    var location: EntryLocation?
    var backStack: [EntryLocation]
    var forwardStack: [EntryLocation]
    var scrollOffset: Double

    var word: String? { location?.word }

    init(
        id: UUID = UUID(), location: EntryLocation? = nil,
        backStack: [EntryLocation] = [], forwardStack: [EntryLocation] = [],
        scrollOffset: Double = 0
    ) {
        self.id = id
        self.location = location
        self.backStack = backStack
        self.forwardStack = forwardStack
        self.scrollOffset = scrollOffset
    }
}

/// Per-window search and browser state. Library work is explicitly detached
/// from the main actor so a substring scan cannot stall typing or animation.
@MainActor
final class AppState: ObservableObject {
    static let maximumResidentTabCount = 3

    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedWord: String? {
        didSet {
            guard let word = selectedWord, word != oldValue, !isSyncingTabSelection else { return }
            if !suppressHistoryRecording { libraryModel.recordHistory(word) }
            let location = pendingNavigationLocation
                ?? EntryLocation(word: word, anchor: nil, preferredDictionaryUUID: nil)
            pendingNavigationLocation = nil
            updateActiveTab(to: location)
        }
    }
    @Published private(set) var tabs: [EntryTab]
    @Published private(set) var activeTabID: UUID
    /// Oldest-to-newest list of tabs whose WebKit views should stay mounted.
    @Published private(set) var residentTabIDs: [UUID]
    @Published var showDictionaryManager = false

    let libraryModel: LibraryModel
    private var searchTask: Task<Void, Never>?
    private var searchCancellation: SearchCancellationToken?
    private var searchGeneration = 0
    private var isSyncingTabSelection = false
    private var suppressHistoryRecording = false
    private var pendingNavigationLocation: EntryLocation?

    var library: DictionaryLibrary? { libraryModel.library }

    init(libraryModel: LibraryModel) {
        self.libraryModel = libraryModel
        let initialTab = EntryTab()
        tabs = [initialTab]
        activeTabID = initialTab.id
        residentTabIDs = [initialTab.id]
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchCancellation?.cancel()
        let cancellation = SearchCancellationToken()
        searchCancellation = cancellation
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchText
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.performSearch(query, generation: generation, cancellation: cancellation)
        }
    }

    func runSearchNow() {
        searchTask?.cancel()
        searchCancellation?.cancel()
        let cancellation = SearchCancellationToken()
        searchCancellation = cancellation
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchText
        searchTask = Task { [weak self] in
            await self?.performSearch(query, generation: generation, cancellation: cancellation)
        }
    }

    private func performSearch(
        _ query: String, generation: Int, cancellation: SearchCancellationToken
    ) async {
        guard let library else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if generation == searchGeneration { results = [] }
            return
        }
        do {
            let initial = try await Task.detached(priority: .userInitiated) {
                try library.searchPrefix(matching: trimmed, limit: 80)
            }.value
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = initial

            let found = try await Task.detached(priority: .userInitiated) {
                try library.search(matching: trimmed, limit: 80, cancellation: cancellation)
            }.value
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = found
        } catch {
            guard generation == searchGeneration else { return }
            libraryModel.errorMessage = error.localizedDescription
            results = []
        }
    }

    func displayWord(for normalizedKey: String?) -> String? {
        libraryModel.displayWord(for: normalizedKey)
    }

    func navigate(
        to word: String,
        anchor: String? = nil,
        preferredDictionaryUUID: String? = nil
    ) {
        let normalized = DictionaryLibrary.normalizeKey(word)
        guard !normalized.isEmpty else { return }
        searchText = word
        let location = EntryLocation(
            word: normalized, anchor: anchor,
            preferredDictionaryUUID: preferredDictionaryUUID?.lowercased()
        )
        if selectedWord == normalized {
            if !suppressHistoryRecording { libraryModel.recordHistory(normalized) }
            updateActiveTab(to: location)
        } else {
            pendingNavigationLocation = location
            selectedWord = normalized
        }
    }

    func selectSavedWord(_ word: String) {
        suppressHistoryRecording = true
        selectedWord = word
        suppressHistoryRecording = false
    }

    // MARK: - Browser tabs

    var activeTab: EntryTab? { tabs.first { $0.id == activeTabID } }
    var residentTabs: [EntryTab] {
        residentTabIDs.compactMap { id in tabs.first { $0.id == id } }
    }
    var canGoBack: Bool { !(activeTab?.backStack.isEmpty ?? true) }
    var canGoForward: Bool { !(activeTab?.forwardStack.isEmpty ?? true) }

    func isActiveTab(_ id: UUID) -> Bool { activeTabID == id }

    func openNewTab() {
        let tab = EntryTab()
        withAnimation(.smooth(duration: 0.2)) {
            tabs.append(tab)
            activeTabID = tab.id
            touchResidentTab(tab.id)
        }
        synchronizeSelection(to: nil)
        searchText = ""
    }

    func activateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID else { return }
        withAnimation(.smooth(duration: 0.18)) {
            activeTabID = id
            touchResidentTab(id)
        }
        synchronizeSelection(to: tab.location?.word)
        synchronizeSearchText(to: tab.location?.word)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        let wasActive = id == activeTabID
        withAnimation(.smooth(duration: 0.2)) {
            _ = tabs.remove(at: index)
            residentTabIDs.removeAll { $0 == id }
        }
        guard wasActive else { return }
        let next = min(index, tabs.count - 1)
        withAnimation(.smooth(duration: 0.18)) {
            activeTabID = tabs[next].id
            touchResidentTab(tabs[next].id)
        }
        synchronizeSelection(to: tabs[next].location?.word)
        synchronizeSearchText(to: tabs[next].location?.word)
    }

    func closeActiveTabOrWindow() { closeTab(activeTabID) }

    func goBack() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let destination = tabs[index].backStack.popLast()
        else { return }
        if let current = tabs[index].location { tabs[index].forwardStack.append(current) }
        tabs[index].location = destination
        tabs[index].scrollOffset = destination.scrollOffset
        synchronizeSelection(to: destination.word)
        synchronizeSearchText(to: destination.word)
    }

    func goForward() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let destination = tabs[index].forwardStack.popLast()
        else { return }
        if let current = tabs[index].location { tabs[index].backStack.append(current) }
        tabs[index].location = destination
        tabs[index].scrollOffset = destination.scrollOffset
        synchronizeSelection(to: destination.word)
        synchronizeSearchText(to: destination.word)
    }

    func reloadActiveEntry() { libraryModel.reloadRenderedContent() }

    func setTabScrollOffset(_ offset: Double, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].scrollOffset = max(0, offset)
        tabs[index].location?.scrollOffset = max(0, offset)
    }

    private func touchResidentTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        residentTabIDs.removeAll { $0 == id }
        residentTabIDs.append(id)
        if residentTabIDs.count > Self.maximumResidentTabCount {
            residentTabIDs.removeFirst(residentTabIDs.count - Self.maximumResidentTabCount)
        }
    }

    private func updateActiveTab(to location: EntryLocation) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs[index].location != location
        else { return }
        if let current = tabs[index].location { tabs[index].backStack.append(current) }
        tabs[index].location = location
        tabs[index].scrollOffset = 0
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
