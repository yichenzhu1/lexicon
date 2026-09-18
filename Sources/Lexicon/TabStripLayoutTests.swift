import Foundation

enum TabStripLayoutTests {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let ids = (0..<4).map { _ in UUID() }
        let layout = TabStripLayout(tabIDs: ids, availableWidth: 406)
        expect(layout.widths == [100, 100, 100, 100], "tabs share available width")
        expect(layout.origin(at: 2) == 204, "origins include spacing")

        let middle = layout.closing(ids[1])
        expect(middle.tabIDs == [ids[0], ids[2], ids[3]], "close removes the correct tab")
        expect(middle.widths == [100, 100, 100], "middle close preserves widths")
        expect(middle.origin(at: 1) == layout.origin(at: 1), "next close target stays fixed")
        let repeated = middle.closing(ids[2])
        expect(repeated.widths == [100, 100], "repeated middle close preserves widths")

        let last = layout.closing(ids[3])
        expect(last.widths == [100, 100, 202], "last close extends predecessor")
        let lastAgain = last.closing(ids[2])
        expect(lastAgain.widths == [100, 304], "repeated last close keeps right edge")
        let single = lastAgain.closing(ids[1])
        expect(single.widths == [406], "last survivor fills the previous span")
        expect(single.closing(ids[0]).widths.isEmpty, "closing only tab is safe")
        expect(layout.closing(UUID()).widths == layout.widths, "unknown ID leaves layout intact")

        expect(middle.matches(tabIDs: middle.tabIDs, availableWidth: 406), "retained layout matches")
        expect(!middle.matches(tabIDs: ids, availableWidth: 406), "insertion invalidates layout")
        expect(!layout.matches(tabIDs: Array(ids.reversed()), availableWidth: 406), "reorder invalidates layout")
        expect(!layout.matches(tabIDs: ids, availableWidth: 500), "resize invalidates layout")
        expect(TabStripLayout(tabIDs: middle.tabIDs, availableWidth: 406).widths[0] > 100,
               "fresh layout expands tabs after pointer leaves")

        let compact = TabStripLayout(tabIDs: ids, availableWidth: 230)
        expect(compact.widths == [56, 56, 56, 56], "compact tabs honor minimum width")
        let compactLast = compact.closing(ids[3])
        expect(compactLast.origin(at: 2) + compactLast.widths[2] == 230,
               "compact last close keeps target fixed while expanding")
        expect(TabStripLayout(tabIDs: ids, availableWidth: 0).widths == [56, 56, 56, 56],
               "narrow strip retains usable tab widths")
        expect(TabStripLayout(tabIDs: [], availableWidth: 0).widths.isEmpty, "empty strip is safe")

        for failure in failures { print("FAIL: tab strip layout: \(failure)") }
        if failures.isEmpty { print("Tab strip layout tests passed") }
        return failures.isEmpty
    }
}
