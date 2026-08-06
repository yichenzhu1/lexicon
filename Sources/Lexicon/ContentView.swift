import AppKit
import MdxKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var sidebarMode: SidebarMode = .history
    @State private var historyExpanded = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        VStack(spacing: 0) {
            browserTabStrip
            interfaceSeparator.frame(height: 1)

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
        }
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .sidebarToggle)
        .background {
            WindowChromeConfigurator()
        }
        .sheet(isPresented: $appState.showDictionaryManager) {
            DictionaryManagerView()
                .environmentObject(appState)
        }
        .alert(
            "Lexicon",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .background {
            Group {
                // Focused-window shortcuts take precedence over the generic
                // window menu, matching browser tab behavior.
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { appState.closeActiveTabOrWindow() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .hidden()
        }
        .onAppear { focusSearchField() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { focusSearchField() }
        }
        .onChange(of: appState.searchText) { _, text in
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sidebarMode = .history
            }
        }
        .onChange(of: appState.activeTabID) { _, _ in
            if appState.activeTab?.word == nil { sidebarMode = .history }
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

            BrowserTabBar()
                .frame(maxWidth: 820)

            Spacer(minLength: 0)
        }
        .padding(.leading, 76)
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
                        contentVersion: appState.contentVersion
                    )
                    .opacity(tab.id == appState.activeTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == appState.activeTabID)
                    .accessibilityHidden(tab.id != appState.activeTabID)
                    .zIndex(tab.id == appState.activeTabID ? 1 : 0)
                }

                if sidebarMode == .starred,
                   appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StarredWordsView { word in
                        sidebarMode = .history
                        appState.selectedWord = word
                    }
                    .zIndex(2)
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

            Button {
                if let word = appState.selectedWord {
                    appState.toggleStar(word)
                }
            } label: {
                Image(systemName: bookmarkIconName)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Star this word")
            .disabled(appState.selectedWord == nil || sidebarMode == .starred)

            searchField

            Button {
                appState.showDictionaryManager = true
            } label: {
                Image(systemName: "books.vertical")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.plain)
            .help("Manage dictionaries")
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

    private var bookmarkIconName: String {
        guard let word = appState.selectedWord else { return "bookmark" }
        return appState.isStarred(word) ? "bookmark.fill" : "bookmark"
    }

    @ViewBuilder
    private var sidebar: some View {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $sidebarMode) {
                Label("History", systemImage: "clock").tag(SidebarMode.history)
                Label("Starred", systemImage: "star").tag(SidebarMode.starred)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 5)

            historyHeader
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 3)

            List(selection: $appState.selectedWord) {
                if query.isEmpty {
                    if historyExpanded {
                        if !appState.history.isEmpty {
                            ForEach(appState.history, id: \.self) { word in
                                Text(appState.displayWord(for: word) ?? word).tag(word)
                            }
                        }
                        if appState.history.isEmpty {
                            Text(appState.dictionaries.isEmpty
                                ? "Import dictionaries to get started"
                                : "Type to search")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }
                } else if appState.results.isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(appState.results) { result in
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
                            }
                        }
                        .tag(result.normalizedKey)
                    }
                }
            }
            .listStyle(.sidebar)
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 10) {
            Text("History")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clear") { appState.clearHistory() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .disabled(appState.history.isEmpty)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    historyExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(historyExpanded ? 0 : -90))
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(.plain)
            .help(historyExpanded ? "Collapse History" : "Expand History")
        }
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
                    Text(appState.displayWord(for: tab.word) ?? tab.word ?? "New Tab")
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

private struct StarredWordsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""

    let onOpen: (String) -> Void

    private var matchingWords: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.starred }
        return appState.starred.filter { word in
            let displayWord = appState.displayWord(for: word) ?? word
            return displayWord.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search starred words", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(16)

            if appState.starred.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "star")
                        .foregroundStyle(.secondary)
                    Text("No starred words yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .top)
            } else if matchingWords.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(matchingWords, id: \.self) { word in
                            starredCard(for: word)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func starredCard(for word: String) -> some View {
        HStack(spacing: 8) {
            Button {
                onOpen(word)
            } label: {
                Text(appState.displayWord(for: word) ?? word)
                    .font(.headline)
                    .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                appState.toggleStar(word)
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help("Remove from starred words")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }
}
