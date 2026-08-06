import AppKit
import MdxKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var sidebarMode: SidebarMode = .history
    /// Filters the history/starred list. Only shown when not searching, so it
    /// never competes with the lookup field for attention.
    @State private var listFilter = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isDropTargeted = false

    /// True while the lookup field holds a query, in which case the sidebar
    /// shows results rather than one of the saved lists.
    private var isSearching: Bool {
        !appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // NavigationSplitView claims the whole window on macOS: as a plain
        // VStack sibling the tab strip was laid out at zero height, which hid
        // the tab bar and the sidebar toggle entirely. A top safe-area inset
        // reserves the space the split view then lays out below.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .background {
                    SplitDividerOverlay(
                        color: colorScheme == .dark
                            ? NSColor(white: 0.22, alpha: 1)
                            : NSColor(white: 0.78, alpha: 1)
                    )
                    .allowsHitTesting(false)
                }
        } detail: {
            detail
                .navigationTitle("")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                browserTabStrip
                interfaceSeparator.frame(height: 1)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .sidebarToggle)
        .background {
            WindowChromeConfigurator()
        }
        .sheet(isPresented: $appState.showDictionaryManager) {
            DictionaryManagerView()
                .environmentObject(libraryModel)
        }
        // Dropping a .mdx on the window imports it, the obvious Mac gesture
        // for "add this dictionary".
        .dropDestination(for: URL.self) { urls, _ in
            let dictionaries = urls.filter { $0.pathExtension.lowercased() == "mdx" }
            guard !dictionaries.isEmpty else { return false }
            libraryModel.importDictionaries(at: dictionaries)
            appState.showDictionaryManager = true
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .alert(
            "Lexicon",
            isPresented: Binding(
                get: { libraryModel.errorMessage != nil },
                set: { if !$0 { libraryModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryModel.errorMessage ?? "")
        }
        .background {
            Group {
                // Focused-window shortcuts take precedence over the generic
                // window menu, matching browser tab behavior.
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { appState.closeActiveTabOrWindow() }
                    .keyboardShortcut("w", modifiers: .command)
                // ⌘= is the unshifted twin of ⌘+; browsers accept both.
                Button("") { libraryModel.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
            }
            .hidden()
        }
        .onAppear { focusSearchField() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { focusSearchField() }
        }
        .onChange(of: sidebarMode) { _, _ in
            // The picker chooses which saved list the sidebar shows. Asking for
            // one while a query is up means the user wants that list, so drop
            // the query rather than leaving the control looking inert.
            listFilter = ""
            if isSearching { appState.searchText = "" }
        }
        .onChange(of: appState.activeTabID) { _, _ in
            focusSearchField()
        }
    }

    private var browserTabStrip: some View {
        HStack(spacing: 10) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
            .accessibilityLabel(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")

            BrowserTabBar()
                .frame(maxWidth: 820)

            Spacer(minLength: 0)
        }
        .padding(.leading, 88)
        .padding(.trailing, 12)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var interfaceSeparator: some View {
        Rectangle()
            .fill(colorScheme == .dark
                ? Color.white.opacity(0.12)
                : Color.black.opacity(0.12))
    }

    private var detail: some View {
        VStack(spacing: 0) {
            browserNavigationBar
            interfaceSeparator.frame(height: 1)
            ZStack {
                ForEach(appState.tabs) { tab in
                    EntryWebView(
                        word: tab.word,
                        contentVersion: libraryModel.contentVersion,
                        zoom: libraryModel.entryZoom,
                        collapsedDictionaries: libraryModel.collapsedDictionaries
                    )
                    .opacity(tab.id == appState.activeTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == appState.activeTabID)
                    .accessibilityHidden(tab.id != appState.activeTabID)
                    .zIndex(tab.id == appState.activeTabID ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var browserNavigationBar: some View {
        HStack(spacing: 7) {
            Button {
                appState.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Back")
            .accessibilityLabel("Back")
            .disabled(!appState.canGoBack)
            .keyboardShortcut("[", modifiers: .command)

            Button {
                appState.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Forward")
            .accessibilityLabel("Forward")
            .disabled(!appState.canGoForward)
            .keyboardShortcut("]", modifiers: .command)

            Button {
                appState.reloadActiveEntry()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Reload Entry")
            .accessibilityLabel("Reload Entry")

            Button {
                if let word = appState.selectedWord {
                    libraryModel.toggleStar(word)
                }
            } label: {
                Image(systemName: bookmarkIconName)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
            .accessibilityLabel(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
            .disabled(appState.selectedWord == nil)

            searchField

            Button {
                appState.showDictionaryManager = true
            } label: {
                Image(systemName: "books.vertical")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .help("Manage dictionaries")
            .accessibilityLabel("Manage dictionaries")
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search all dictionaries…", text: $appState.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let first = appState.results.first {
                        appState.selectedWord = first.normalizedKey
                    }
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
        }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        searchFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: searchFocused ? 2 : 1
                    )
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Search all dictionaries")
    }

    private func focusSearchField() {
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    /// Arrow keys in the search field walk through the result list.
    private func moveSelection(by delta: Int) {
        let results = appState.results
        guard !results.isEmpty else { return }
        if let current = appState.selectedWord,
           let index = results.firstIndex(where: { $0.normalizedKey == current }) {
            let next = min(max(index + delta, 0), results.count - 1)
            appState.selectedWord = results[next].normalizedKey
        } else {
            appState.selectedWord = results.first?.normalizedKey
        }
    }

    private var isCurrentWordStarred: Bool {
        guard let word = appState.selectedWord else { return false }
        return libraryModel.isStarred(word)
    }

    private var bookmarkIconName: String {
        isCurrentWordStarred ? "bookmark.fill" : "bookmark"
    }

    /// The sidebar always shows exactly one list, and the header describes the
    /// list that is actually on screen: results while searching, otherwise the
    /// saved list the picker selects.
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Sidebar list", selection: $sidebarMode) {
                Label("History", systemImage: "clock").tag(SidebarMode.history)
                Label("Starred", systemImage: "star").tag(SidebarMode.starred)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 5)

            sidebarHeader
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 3)

            if !isSearching, !savedWords.isEmpty {
                listFilterField
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            List(selection: $appState.selectedWord) {
                if isSearching {
                    if appState.results.isEmpty {
                        placeholderRow("No matches")
                    } else {
                        if showingSuggestions {
                            // Nothing matched literally; these are near misses.
                            Text("Did you mean")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(appState.results) { result in
                            resultRow(result)
                        }
                    }
                } else if visibleWords.isEmpty {
                    placeholderRow(emptyListMessage)
                } else {
                    ForEach(visibleWords, id: \.self) { word in
                        savedWordRow(word)
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Text(sidebarTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let count = sidebarCount {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if isSearching {
                Button("Clear") { appState.searchText = "" }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Clear the search")
            } else if sidebarMode == .history {
                Button("Clear") { libraryModel.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .disabled(libraryModel.history.isEmpty)
                    .help("Clear lookup history")
            }
        }
    }

    private var listFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            TextField(
                sidebarMode == .history ? "Filter history" : "Filter starred",
                text: $listFilter
            )
            .textFieldStyle(.plain)
            .font(.callout)
            if !listFilter.isEmpty {
                Button {
                    listFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        HStack {
            Text(result.displayKey)
                .lineLimit(1)
            Spacer()
            if result.dictionaryCount > 1 {
                Text("\(result.dictionaryCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .help("In \(result.dictionaryCount) dictionaries")
            }
        }
        .tag(result.normalizedKey)
    }

    private func savedWordRow(_ word: String) -> some View {
        Text(libraryModel.displayWord(for: word) ?? word)
            .lineLimit(1)
            .tag(word)
            .contextMenu {
                Button(libraryModel.isStarred(word) ? "Remove from Starred" : "Add to Starred") {
                    libraryModel.toggleStar(word)
                }
                if sidebarMode == .history {
                    Button("Remove from History") {
                        libraryModel.removeFromHistory(word)
                    }
                }
            }
    }

    private func placeholderRow(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    // MARK: - Sidebar list contents

    private var savedWords: [String] {
        sidebarMode == .history ? libraryModel.history : libraryModel.starred
    }

    private var visibleWords: [String] {
        let query = listFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return savedWords }
        return savedWords.filter { word in
            (libraryModel.displayWord(for: word) ?? word).localizedStandardContains(query)
        }
    }

    /// True when every result is a near miss rather than a literal match.
    private var showingSuggestions: Bool {
        !appState.results.isEmpty && appState.results.allSatisfy { $0.matchKind == .fuzzy }
    }

    private var sidebarTitle: String {
        if isSearching { return showingSuggestions ? "Suggestions" : "Results" }
        return sidebarMode == .history ? "History" : "Starred"
    }

    private var sidebarCount: Int? {
        if isSearching {
            return appState.results.isEmpty ? nil : appState.results.count
        }
        return visibleWords.isEmpty ? nil : visibleWords.count
    }

    private var emptyListMessage: String {
        if !listFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Nothing matches that filter"
        }
        if libraryModel.dictionaries.isEmpty {
            return "Import dictionaries to get started"
        }
        return sidebarMode == .history
            ? "Type to search"
            : "Star a word to keep it here"
    }
}

/// SwiftUI can reinsert its automatic sidebar toolbar item when the tab state
/// changes. The app has its own browser-style sidebar control, so remove the
/// duplicate directly from the hosting window whenever this view is updated.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let toolbar = view.window?.toolbar else { return }
            for index in toolbar.items.indices.reversed()
            {
                let item = toolbar.items[index]
                let labels = [item.label, item.paletteLabel, item.toolTip ?? ""]
                    .joined(separator: " ")
                if item.itemIdentifier == .toggleSidebar
                    || labels.localizedCaseInsensitiveContains("sidebar") {
                    toolbar.removeItem(at: index)
                }
            }
        }
    }
}

private struct SplitDividerOverlay: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> SplitDividerProbeView {
        let view = SplitDividerProbeView()
        view.dividerColor = color
        return view
    }

    func updateNSView(_ nsView: SplitDividerProbeView, context: Context) {
        nsView.dividerColor = color
        nsView.attachToSplitViewIfNeeded()
    }
}

private final class SplitDividerProbeView: NSView {
    private let dividerLine = SplitDividerLineView()
    private weak var observedSplitView: NSSplitView?

    var dividerColor: NSColor = .separatorColor {
        didSet {
            dividerLine.wantsLayer = true
            dividerLine.layer?.backgroundColor = dividerColor.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerLine.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in
            self?.attachToSplitViewIfNeeded()
        }
    }

    func attachToSplitViewIfNeeded() {
        var ancestor = superview
        while let view = ancestor, !(view is NSSplitView) {
            ancestor = view.superview
        }
        guard let splitView = ancestor as? NSSplitView,
              let overlayContainer = splitView.superview
        else { return }

        if observedSplitView !== splitView {
            NotificationCenter.default.removeObserver(self)
            observedSplitView = splitView
            splitView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateDividerFrame),
                name: NSSplitView.didResizeSubviewsNotification,
                object: splitView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateDividerFrame),
                name: NSView.frameDidChangeNotification,
                object: splitView
            )
        }

        if dividerLine.superview !== overlayContainer {
            dividerLine.removeFromSuperview()
            overlayContainer.addSubview(dividerLine, positioned: .above, relativeTo: splitView)
        }
        dividerLine.layer?.backgroundColor = dividerColor.cgColor
        updateDividerFrame()
    }

    @objc private func updateDividerFrame() {
        guard let splitView = observedSplitView,
              let overlayContainer = splitView.superview,
              let sidebar = splitView.arrangedSubviews.first
        else { return }

        let dividerRect = NSRect(
            x: sidebar.frame.maxX,
            y: splitView.bounds.minY,
            width: max(1, splitView.dividerThickness),
            height: splitView.bounds.height
        )
        dividerLine.frame = splitView.convert(dividerRect, to: overlayContainer)
    }
}

private final class SplitDividerLineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum SidebarMode: Hashable {
    case history
    case starred
}

private struct BrowserTabBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel

    private let preferredTabWidth: CGFloat = 190
    private let plusWidth: CGFloat = 28
    private let spacing: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, appState.tabs.count)
            let interItemSpacing = spacing * CGFloat(count)
            let availableForTabs = max(
                CGFloat(count),
                proxy.size.width - plusWidth - interItemSpacing
            )
            let tabWidth = min(
                preferredTabWidth,
                availableForTabs / CGFloat(count)
            )

            HStack(spacing: spacing) {
                ForEach(appState.tabs) { tab in
                    tabView(tab, width: tabWidth)
                        .frame(width: tabWidth)
                }

                Button {
                    appState.openNewTab()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: plusWidth, height: 28)
                }
                .buttonStyle(.plain)
                .help("New Tab")
                .accessibilityLabel("New Tab")

                Spacer(minLength: 0)
            }
        }
        .frame(height: 38)
    }

    private func tabView(_ tab: EntryTab, width: CGFloat) -> some View {
        let isActive = tab.id == appState.activeTabID
        let compact = width < 110
        return HStack(spacing: 5) {
            Button {
                appState.activateTab(tab.id)
            } label: {
                HStack(spacing: compact ? 4 : 8) {
                    if width >= 72 {
                        Image(systemName: "book.closed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(libraryModel.displayWord(for: tab.word) ?? tab.word ?? "New Tab")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive || !compact {
                Button {
                    appState.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
            }
        }
        .padding(.leading, compact ? 6 : 10)
        .padding(.trailing, compact ? 4 : 6)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(isActive ? 0.55 : 0),
                    lineWidth: 1
                )
        }
    }
}
