import Foundation
import MdxKit

/// Small executable regression suite for app-only state that cannot live in
/// MdxKitTester. Run with `swift run Lexicon --tab-state-test`.
@MainActor
enum TabStateTests {
    static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LexiconTabStateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = LibraryModel(rootURL: root)
        let state = AppState(libraryModel: model)
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let initialID = state.activeTabID
        expect(state.residentTabIDs == [initialID], "initial tab was not resident")

        var tabIDs = [initialID]
        for _ in 0..<4 {
            state.openNewTab()
            tabIDs.append(state.activeTabID)
        }
        expect(
            state.residentTabIDs == Array(tabIDs.suffix(AppState.maximumResidentTabCount)),
            "opening tabs did not retain the three most recent views"
        )

        let evictedTabID = tabIDs[1]
        state.activateTab(evictedTabID)
        expect(
            state.residentTabIDs == [tabIDs[3], tabIDs[4], evictedTabID],
            "reactivating an evicted tab did not update MRU order"
        )

        state.navigate(to: "Outgoing")
        state.setTabScrollOffset(125, for: evictedTabID)
        let destinationTabID = tabIDs[4]
        state.activateTab(destinationTabID)
        let outgoingBridge = EntryWebView.Coordinator(
            tabID: evictedTabID, appState: state, libraryModel: model
        )
        outgoingBridge.recordPageScroll(640)
        expect(
            state.tabs.first(where: { $0.id == evictedTabID })?.scrollOffset == 640,
            "an outgoing bridge did not update its source tab"
        )
        expect(
            state.tabs.first(where: { $0.id == destinationTabID })?.scrollOffset == 0,
            "an outgoing bridge overwrote the active destination tab"
        )

        state.navigate(to: "Alpha")
        state.setTabScrollOffset(240, for: destinationTabID)
        state.navigate(to: "Beta")
        state.setTabScrollOffset(480, for: destinationTabID)
        expect(state.activeTab?.word == "beta", "navigation did not update the active tab")
        state.goBack()
        expect(state.activeTab?.word == "alpha", "back history escaped its tab")
        expect(state.selectedWord == "alpha", "selection drifted from the active tab")
        expect(state.activeTab?.scrollOffset == 240, "back did not restore the location's scroll")
        state.goForward()
        expect(state.activeTab?.word == "beta", "forward history escaped its tab")
        expect(state.activeTab?.scrollOffset == 480, "forward did not restore the location's scroll")

        let historyCount = state.activeTab?.backStack.count
        state.navigate(to: "Beta")
        expect(state.activeTab?.backStack.count == historyCount, "same destination added phantom history")
        expect(state.activeTab?.scrollOffset == 480, "same destination reset the current scroll")
        state.navigate(to: "Beta", anchor: "meaning", preferredDictionaryUUID: "ABC")
        expect(state.activeTab?.location?.anchor == "meaning", "same-word anchor navigation was lost")
        expect(state.activeTab?.location?.preferredDictionaryUUID == "abc", "dictionary target was not normalized")
        expect(state.activeTab?.scrollOffset == 0, "new anchor inherited the old scroll")
        state.goBack()
        expect(state.activeTab?.location?.anchor == nil, "back did not restore the original destination")
        expect(state.activeTab?.scrollOffset == 480, "back from an anchor lost the previous scroll")
        state.selectSavedWord("Saved")
        expect(state.selectedWord == "saved", "saved selection was not normalized")
        expect(!model.history.contains("saved"), "saved selection unexpectedly recorded global history")
        expect(!state.canGoForward, "a new destination retained obsolete forward history")
        state.selectSearchResult("Result")
        expect(model.history.contains("result"), "result selection did not record global history")
        state.setTabScrollOffset(.nan, for: destinationTabID)
        expect(state.activeTab?.scrollOffset == 0, "invalid bridge scroll poisoned navigation state")

        state.closeTab(evictedTabID)
        expect(!state.tabs.contains(where: { $0.id == evictedTabID }), "closed tab remained in state")
        expect(!state.residentTabIDs.contains(evictedTabID), "closed tab remained resident")
        expect(
            state.residentTabIDs.count <= AppState.maximumResidentTabCount,
            "resident view limit was exceeded"
        )

        // Drag reorder: move the last tab to the front, then back to the end.
        let remainingIDs = state.tabs.map(\.id)
        state.moveTab(id: destinationTabID, before: remainingIDs[0])
        expect(state.tabs.first?.id == destinationTabID, "reorder did not move tab to front")
        expect(state.tabs.count == remainingIDs.count, "reorder changed the tab count")
        state.moveTab(id: destinationTabID, before: nil)
        expect(state.tabs.last?.id == destinationTabID, "reorder did not append at the end")

        // Browser-style positional activation (⌘1 / ⌘9).
        state.activateTab(at: 0)
        expect(state.activeTabID == state.tabs.first?.id, "positional activation failed")
        state.activateLastTab()
        expect(state.activeTabID == destinationTabID, "last-tab activation failed")

        // Close tabs to the right; the active tab is among them, so the tab at
        // the boundary takes over.
        let keeper = state.tabs[0].id
        let survivor = state.tabs[1].id
        state.closeTabsToTheRight(of: survivor)
        expect(state.tabs.map(\.id) == [keeper, survivor], "close-to-the-right kept the wrong tabs")
        expect(state.activeTabID == survivor, "close-to-the-right did not activate the boundary tab")

        // Close other tabs; only the kept tab survives and becomes active.
        state.closeOtherTabs(of: keeper)
        expect(state.tabs.map(\.id) == [keeper], "close-other-tabs kept the wrong tabs")
        expect(state.activeTabID == keeper, "close-other-tabs did not activate the kept tab")
        expect(state.residentTabIDs == [keeper], "close-other-tabs left stale resident views")

        // Search uses the real index, including its prefix and completion phases.
        do {
            let fixture = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tests/Fixtures/basic.mdx")
            guard let library = model.library else { throw TestError.libraryUnavailable }
            let dictionary = try library.importDictionary(from: fixture)
            model.reloadDictionaries()

            func finishSearch() async {
                let deadline = ContinuousClock.now + .seconds(5)
                while state.isSearchPending && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                expect(!state.isSearchPending, "search did not finish")
            }

            state.searchText = "w"
            await finishSearch()
            expect(state.results.count > 1, "fixture did not produce multiple search results")
            state.moveSearchSelection(by: 1)
            state.moveSearchSelection(by: 1)
            let keyboardSelection = state.selectedWord
            state.submitSearch()
            expect(state.selectedWord == keyboardSelection, "Return discarded the keyboard-selected result")

            state.searchText = "apple"
            expect(state.results.isEmpty, "new query left stale results selectable during debounce")
            expect(state.isSearchPending, "new query was presented as a completed empty result")
            state.searchText = "colour"
            await finishSearch()
            expect(state.results.first?.normalizedKey == "colour", "cancelled query replaced the newest results")

            state.searchText = "  \n"
            expect(state.results.isEmpty && !state.isSearchPending, "clear did not synchronously reset search")
            state.searchText = "apple"
            await finishSearch()
            expect(state.results.first?.normalizedKey == "apple", "search did not resume after clearing")
            model.setEnabled(false, for: dictionary)
            await finishSearch()
            expect(state.results.isEmpty, "disabling a dictionary left stale search results")
        } catch {
            failures.append("search fixture failed: \(error)")
        }

        if failures.isEmpty {
            print("TAB STATE OK")
            return true
        }
        failures.forEach { print("TAB STATE FAIL: \($0)") }
        return false
    }

    private enum TestError: Error { case libraryUnavailable }
}
