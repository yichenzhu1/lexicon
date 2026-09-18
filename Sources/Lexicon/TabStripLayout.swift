import Foundation

/// Tab geometry retained while the pointer stays in the strip after a close.
struct TabStripLayout {
    static let spacing: CGFloat = 2

    let tabIDs: [UUID]
    let availableWidth: CGFloat
    private(set) var widths: [CGFloat]

    init(tabIDs: [UUID], availableWidth: CGFloat) {
        self.tabIDs = tabIDs
        self.availableWidth = availableWidth
        let count = max(1, tabIDs.count)
        let gaps = Self.spacing * CGFloat(count - 1)
        let width = max(56, (availableWidth - gaps) / CGFloat(count))
        widths = Array(repeating: width, count: tabIDs.count)
    }

    private init(tabIDs: [UUID], availableWidth: CGFloat, widths: [CGFloat]) {
        self.tabIDs = tabIDs
        self.availableWidth = availableWidth
        self.widths = widths
    }

    func matches(tabIDs: [UUID], availableWidth: CGFloat) -> Bool {
        self.tabIDs == tabIDs && self.availableWidth == availableWidth
    }

    func origin(at index: Int) -> CGFloat {
        widths.prefix(index).reduce(0, +) + Self.spacing * CGFloat(index)
    }

    func closing(_ id: UUID) -> TabStripLayout {
        guard let index = tabIDs.firstIndex(of: id) else { return self }
        var remainingIDs = tabIDs
        var remainingWidths = widths
        remainingIDs.remove(at: index)
        let removedWidth = remainingWidths.remove(at: index)
        // A following tab slides into the closed tab's position. When closing
        // the last tab, extend its predecessor to keep the close button at the
        // same right edge for repeated clicks.
        if index == remainingWidths.count, !remainingWidths.isEmpty {
            remainingWidths[index - 1] += removedWidth + Self.spacing
        }
        return TabStripLayout(tabIDs: remainingIDs, availableWidth: availableWidth,
                              widths: remainingWidths)
    }
}
