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

    func hasSameDestination(as other: EntryLocation) -> Bool {
        word == other.word && anchor == other.anchor
            && preferredDictionaryUUID == other.preferredDictionaryUUID
    }
}

struct EntryTab: Identifiable, Equatable {
    let id: UUID
    var location: EntryLocation?
    var backStack: [EntryLocation]
    var forwardStack: [EntryLocation]
    var word: String? { location?.word }
    var scrollOffset: Double { location?.scrollOffset ?? 0 }

    init(
        id: UUID = UUID(), location: EntryLocation? = nil,
        backStack: [EntryLocation] = [], forwardStack: [EntryLocation] = []
    ) {
        self.id = id
        self.location = location
        self.backStack = backStack
        self.forwardStack = forwardStack
    }
}

/// Per-window search and browser state. Library work is explicitly detached
/// from the main actor so a substring scan cannot stall typing or animation.
@MainActor
final class AppState: ObservableObject {
    static let maximumResidentTabCount = 3

    @Published var searchText = "" {
        didSet {
            if DictionaryLibrary.normalizeKey(searchText) != DictionaryLibrary.normalizeKey(oldValue) {
                scheduleSearch()
            }
        }
    }
    @Published private var searchState: SearchState = .idle
    @Published private(set) var tabs: [EntryTab]
    @Published private(set) var activeTabID: UUID
    /// Oldest-to-newest list of tabs whose WebKit views should stay mounted.
    @Published private(set) var residentTabIDs: [UUID]
    @Published var showDictionaryManager = false

    let libraryModel: LibraryModel
    private var searchTask: Task<Void, Never>?
    private var libraryChanges: AnyCancellable?

    private enum SearchState: Sendable {
        case idle
        case searching([SearchResult])
        case complete([SearchResult])

        var results: [SearchResult] {
            switch self {
            case .idle: []
            case .searching(let results), .complete(let results): results
            }
        }
    }

    var library: DictionaryLibrary? { libraryModel.library }
    var selectedWord: String? { activeTab?.word }
    var results: [SearchResult] { searchState.results }
    var isSearchPending: Bool {
        if case .searching = searchState { return true }
        return false
    }

    init(libraryModel: LibraryModel) {
        self.libraryModel = libraryModel
        let initialTab = EntryTab()
        tabs = [initialTab]
        activeTabID = initialTab.id
        residentTabIDs = [initialTab.id]
        libraryChanges = libraryModel.$contentVersion.dropFirst().sink { [weak self] _ in
            self?.scheduleSearch()
        }
    }

    deinit { searchTask?.cancel() }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = nil
        let query = DictionaryLibrary.normalizeKey(searchText)
        guard let library, !query.isEmpty else {
            searchState = .idle
            return
        }
        // Never let a click or Return select results from the previous query.
        searchState = .searching([])
        let cancellation = SearchCancellationToken()
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(for: .milliseconds(75))
                    let initial = try library.searchPrefix(matching: query, limit: 80)
                    await self?.publishSearch(.searching(initial))
                    try Task.checkCancellation()
                    let found = try library.search(
                        matching: query, limit: 80,
                        prefixResults: initial, cancellation: cancellation
                    )
                    await self?.publishSearch(.complete(found))
                } catch {
                    await self?.searchFailed(error)
                }
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    private func publishSearch(_ state: SearchState) {
        guard !Task.isCancelled else { return }
        searchState = state
    }

    private func searchFailed(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        searchState = .complete([])
        libraryModel.errorMessage = error.localizedDescription
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
        visit(location, recordingHistory: true)
    }

    func selectSearchResult(_ word: String) {
        selectWord(word, recordingHistory: true)
    }

    func selectSavedWord(_ word: String) {
        selectWord(word, recordingHistory: false)
    }

    private func selectWord(_ word: String, recordingHistory: Bool) {
        let normalized = DictionaryLibrary.normalizeKey(word)
        guard !normalized.isEmpty, normalized != selectedWord else { return }
        visit(
            EntryLocation(word: normalized, anchor: nil, preferredDictionaryUUID: nil),
            recordingHistory: recordingHistory
        )
    }

    func moveSearchSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.normalizedKey == selectedWord }
        let next = index.map { min(max($0 + delta, 0), results.count - 1) } ?? 0
        selectSearchResult(results[next].normalizedKey)
    }

    func submitSearch() {
        let result = results.first { $0.normalizedKey == selectedWord } ?? results.first
        if let result { selectSearchResult(result.normalizedKey) }
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
        searchText = ""
    }

    func activateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID else { return }
        withAnimation(.smooth(duration: 0.18)) {
            activeTabID = id
            touchResidentTab(id)
        }
        synchronizeSearchText(to: tab.location?.word)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        let next = index + 1 < tabs.count ? index + 1 : index - 1
        closeTabs([id], fallback: tabs[next].id)
    }

    func closeActiveTabOrWindow() { closeTab(activeTabID) }

    /// Moves a tab in front of `targetID`, or to the end when it is nil.
    func moveTab(id: UUID, before targetID: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        var to = targetID.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.count
        guard to != from, to != from + 1 else { return }
        withAnimation(.smooth(duration: 0.2)) {
            let tab = tabs.remove(at: from)
            if to > from { to -= 1 }
            tabs.insert(tab, at: to)
        }
    }

    /// Keeps the given tab and closes everything else, matching Safari's
    /// "Close Other Tabs": the kept tab becomes active.
    func closeOtherTabs(of id: UUID) {
        guard tabs.count > 1, tabs.contains(where: { $0.id == id }) else { return }
        closeTabs(Set(tabs.map(\.id)).subtracting([id]), fallback: id)
    }

    func closeTabsToTheRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              index < tabs.count - 1
        else { return }
        closeTabs(Set(tabs[(index + 1)...].map(\.id)), fallback: id)
    }

    private func closeTabs(_ ids: Set<UUID>, fallback: UUID) {
        let closedActive = ids.contains(activeTabID)
        withAnimation(.smooth(duration: 0.2)) {
            tabs.removeAll { ids.contains($0.id) }
            residentTabIDs.removeAll { ids.contains($0) }
            if closedActive {
                activeTabID = fallback
                touchResidentTab(fallback)
            }
        }
        if closedActive { synchronizeSearchText(to: selectedWord) }
    }

    /// Browser-style ⌘1…⌘8: activates the tab at a position, if it exists.
    func activateTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activateTab(tabs[index].id)
    }

    /// Browser-style ⌘9: activates the last tab.
    func activateLastTab() {
        if let last = tabs.last { activateTab(last.id) }
    }

    func goBack() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let destination = tabs[index].backStack.popLast()
        else { return }
        if let current = tabs[index].location { tabs[index].forwardStack.append(current) }
        tabs[index].location = destination
        synchronizeSearchText(to: destination.word)
    }

    func goForward() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              let destination = tabs[index].forwardStack.popLast()
        else { return }
        if let current = tabs[index].location { tabs[index].backStack.append(current) }
        tabs[index].location = destination
        synchronizeSearchText(to: destination.word)
    }

    func setTabScrollOffset(_ offset: Double, for tabID: UUID) {
        guard offset.isFinite,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let location = tabs[index].location,
              location.scrollOffset != max(0, offset)
        else { return }
        tabs[index].location?.scrollOffset = max(0, offset)
    }

    private func touchResidentTab(_ id: UUID) {
        residentTabIDs.removeAll { $0 == id }
        residentTabIDs.append(id)
        if residentTabIDs.count > Self.maximumResidentTabCount {
            residentTabIDs.removeFirst(residentTabIDs.count - Self.maximumResidentTabCount)
        }
    }

    private func visit(_ location: EntryLocation, recordingHistory: Bool) {
        if recordingHistory { libraryModel.recordHistory(location.word) }
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }),
              tabs[index].location?.hasSameDestination(as: location) != true
        else { return }
        if let current = tabs[index].location { tabs[index].backStack.append(current) }
        tabs[index].location = location
        tabs[index].forwardStack.removeAll()
    }

    private func synchronizeSearchText(to word: String?) {
        searchText = libraryModel.displayWord(for: word) ?? word ?? ""
    }
}
