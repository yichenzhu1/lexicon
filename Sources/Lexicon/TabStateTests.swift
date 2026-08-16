import Foundation

/// Small executable regression suite for app-only state that cannot live in
/// MdxKitTester. Run with `swift run Lexicon --tab-state-test`.
@MainActor
enum TabStateTests {
    static func run() -> Bool {
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
        state.navigate(to: "Beta")
        expect(state.activeTab?.word == "beta", "navigation did not update the active tab")
        state.goBack()
        expect(state.activeTab?.word == "alpha", "back history escaped its tab")
        state.goForward()
        expect(state.activeTab?.word == "beta", "forward history escaped its tab")

        state.closeTab(evictedTabID)
        expect(!state.tabs.contains(where: { $0.id == evictedTabID }), "closed tab remained in state")
        expect(!state.residentTabIDs.contains(evictedTabID), "closed tab remained resident")
        expect(
            state.residentTabIDs.count <= AppState.maximumResidentTabCount,
            "resident view limit was exceeded"
        )

        if failures.isEmpty {
            print("TAB STATE OK")
            return true
        }
        failures.forEach { print("TAB STATE FAIL: \($0)") }
        return false
    }
}
