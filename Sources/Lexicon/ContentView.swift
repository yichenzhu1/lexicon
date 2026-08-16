import AppKit
import MdxKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var sidebarMode: SidebarMode = .lexicon
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 248
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var windowIsFullScreen = false
    @State private var isDropTargeted = false

    /// True while the lookup field holds a query, in which case the sidebar
    /// shows results rather than one of the saved lists.
    private var isSearching: Bool {
        !appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    sidebarTitleBar
                    interfaceSeparator.frame(height: 1)

                    sidebar
                }
                .frame(width: sidebarWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))

                sidebarDivider
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                browserTabStrip
                interfaceSeparator.frame(height: 1)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(
            .container,
            edges: windowIsFullScreen ? [] : .top
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.smooth(duration: 0.22), value: sidebarVisible)
        .animation(.smooth(duration: 0.24), value: windowIsFullScreen)
        .background {
            WindowChromeBridge(isFullScreen: $windowIsFullScreen)
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
        .onChange(of: appState.searchText) { _, text in
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.smooth(duration: 0.18)) {
                    sidebarMode = .lexicon
                }
            }
        }
        .onChange(of: appState.activeTabID) { _, _ in
            focusSearchField()
        }
    }

    private var browserTabStrip: some View {
        HStack(spacing: 4) {
            if !sidebarVisible {
                sidebarToggleButton
            }

            BrowserTabBar()
                .frame(maxWidth: .infinity)
        }
        .padding(
            .leading,
            sidebarVisible || windowIsFullScreen ? 8 : 82
        )
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarTitleBar: some View {
        HStack(spacing: 0) {
            sidebarToggleButton
            Spacer(minLength: 0)
        }
        .padding(.leading, windowIsFullScreen ? 8 : 82)
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
        .foregroundStyle(.secondary)
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }

    private var sidebarDivider: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.14)
                    : Color.black.opacity(0.14))
                .frame(width: 1)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if sidebarDragStartWidth == nil { sidebarDragStartWidth = sidebarWidth }
                    sidebarWidth = min(
                        max(200, (sidebarDragStartWidth ?? sidebarWidth) + value.translation.width),
                        380
                    )
                }
                .onEnded { _ in sidebarDragStartWidth = nil }
        )
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
                ForEach(appState.residentTabs) { tab in
                    let isActive = tab.id == appState.activeTabID
                    EntryWebView(
                        tabID: tab.id,
                        word: tab.word,
                        anchor: tab.location?.anchor,
                        preferredDictionaryUUID: tab.location?.preferredDictionaryUUID,
                        initialScrollOffset: tab.scrollOffset,
                        contentVersion: libraryModel.contentVersion,
                        zoom: libraryModel.entryZoom,
                        collapsedDictionaries: libraryModel.collapsedDictionaries
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .zIndex(isActive ? 1 : 0)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var browserNavigationBar: some View {
        HStack(spacing: 3) {
            Button {
                appState.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
            .help("Back")
            .accessibilityLabel("Back")
            .disabled(!appState.canGoBack)
            .keyboardShortcut("[", modifiers: .command)

            Button {
                appState.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
            .help("Forward")
            .accessibilityLabel("Forward")
            .disabled(!appState.canGoForward)
            .keyboardShortcut("]", modifiers: .command)

            Button {
                if let word = appState.selectedWord {
                    libraryModel.toggleStar(word)
                }
            } label: {
                Image(systemName: bookmarkIconName)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
            .help(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
            .accessibilityLabel(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
            .disabled(appState.selectedWord == nil)

            searchField

            Button {
                appState.showDictionaryManager = true
            } label: {
                Image(systemName: "books.vertical")
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
            .help("Manage dictionaries")
            .accessibilityLabel("Manage dictionaries")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(
                "",
                text: $appState.searchText,
                prompt: searchFocused ? nil : Text("Search all dictionaries…")
            )
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
            .padding(.vertical, 6)
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

    /// The sidebar behaves like a browser side panel: lookup results, history
    /// and starred words are distinct destinations and never cover one another.
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarModeMenu
                .padding(.leading, 13)
                .padding(.trailing, 8)
                .padding(.top, 11)
                .padding(.bottom, 4)

            sidebarStatusBar

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if sidebarMode == .lexicon {
                        if !isSearching {
                            EmptyView()
                        } else if appState.results.isEmpty {
                            placeholderRow("No matches")
                        } else {
                            if showingSuggestions {
                                // Nothing matched literally; these are near misses.
                                Text("Did you mean")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                            }
                            ForEach(appState.results) { result in
                                resultRow(result)
                            }
                        }
                    } else if savedWords.isEmpty {
                        placeholderRow(emptyListMessage)
                    } else {
                        ForEach(savedWordRows) { item in
                            savedWordRow(item)
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarModeMenu: some View {
        Menu {
            Button {
                sidebarMode = .lexicon
            } label: {
                Label("Lexicon", systemImage: sidebarMode == .lexicon ? "checkmark" : "text.book.closed")
            }
            Button {
                sidebarMode = .history
            } label: {
                Label("History", systemImage: sidebarMode == .history ? "checkmark" : "clock")
            }
            Button {
                sidebarMode = .starred
            } label: {
                Label("Starred", systemImage: sidebarMode == .starred ? "checkmark" : "star")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: sidebarMode.iconName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(sidebarMode.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Sidebar section")
        .accessibilityValue(sidebarMode.title)
    }

    @ViewBuilder
    private var sidebarStatusBar: some View {
        if sidebarMode == .history || (sidebarMode == .lexicon && isSearching) {
            HStack(spacing: 8) {
                Text(sidebarStatusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button("Clear") {
                    if sidebarMode == .history {
                        libraryModel.clearHistory()
                    } else {
                        appState.searchText = ""
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .disabled(sidebarMode == .history && libraryModel.history.isEmpty)
                .help(sidebarMode == .history ? "Clear lookup history" : "Clear the search")
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.bottom, 6)
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            appState.selectedWord = result.normalizedKey
        } label: {
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
            .sidebarRow(selected: appState.selectedWord == result.normalizedKey)
        }
        .buttonStyle(.plain)
        .accessibilityValue(appState.selectedWord == result.normalizedKey ? "Selected" : "")
    }

    private func savedWordRow(_ item: SavedSidebarWord) -> some View {
        let word = item.word
        return Button {
            appState.selectSavedWord(word)
        } label: {
            Text(libraryModel.displayWord(for: word) ?? word)
                .lineLimit(1)
                .sidebarRow(selected: item.isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityValue(item.isSelected ? "Selected" : "")
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
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sidebar list contents

    private var savedWords: [String] {
        switch sidebarMode {
        case .lexicon: []
        case .history: libraryModel.history
        case .starred: libraryModel.starred
        }
    }

    /// Selection participates in row identity so SwiftUI cannot retain the
    /// previous row's highlighted/accessibility state inside the lazy stack.
    /// Only the old and new rows are rebuilt, preserving scroll position.
    private var savedWordRows: [SavedSidebarWord] {
        savedWords.map { word in
            SavedSidebarWord(word: word, isSelected: appState.selectedWord == word)
        }
    }

    /// True when every result is a near miss rather than a literal match.
    private var showingSuggestions: Bool {
        !appState.results.isEmpty && appState.results.allSatisfy { $0.matchKind == .fuzzy }
    }

    private var sidebarStatusText: String {
        if sidebarMode == .history {
            return "\(libraryModel.history.count) recent"
        }
        let label = showingSuggestions ? "suggestions" : "results"
        return "\(appState.results.count) \(label)"
    }

    private var emptyListMessage: String {
        if libraryModel.dictionaries.isEmpty {
            return "Import dictionaries to get started"
        }
        switch sidebarMode {
        case .lexicon: return "Type in the search field to look up a word"
        case .history: return "No lookup history yet"
        case .starred: return "Star a word to keep it here"
        }
    }
}

private struct SavedSidebarWord: Identifiable {
    struct ID: Hashable {
        let word: String
        let isSelected: Bool
    }

    let word: String
    let isSelected: Bool
    var id: ID { ID(word: word, isSelected: isSelected) }
}

/// Keeps custom full-size window chrome aligned with macOS window state.
/// Normal windows receive a small optical correction for the traffic lights;
/// fullscreen windows stop ignoring the system safe area and reclaim the space
/// that those controls occupied.
private struct WindowChromeBridge: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> WindowChromeProbeView {
        WindowChromeProbeView()
    }

    func updateNSView(_ nsView: WindowChromeProbeView, context: Context) {
        let binding = $isFullScreen
        nsView.onFullScreenChange = { fullScreen in
            guard binding.wrappedValue != fullScreen else { return }
            withAnimation(.smooth(duration: 0.24)) {
                binding.wrappedValue = fullScreen
            }
        }
        nsView.refreshWindowChrome()
    }
}

private final class WindowChromeProbeView: NSView {
    var onFullScreenChange: @MainActor (Bool) -> Void = { _ in }

    private weak var observedWindow: NSWindow?
    private var originalButtonFrames: [NSWindow.ButtonType: NSRect] = [:]
    private let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach(to: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refreshWindowChrome() {
        guard let window else { return }
        if observedWindow !== window { attach(to: window) }
        let fullScreen = window.styleMask.contains(.fullScreen)
        onFullScreenChange(fullScreen)
        if !fullScreen { positionTrafficLights(animated: false) }
    }

    private func attach(to window: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        originalButtonFrames.removeAll()
        guard let window else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillExitFullScreen),
            name: NSWindow.willExitFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )

        refreshWindowChrome()
    }

    @objc private func windowWillEnterFullScreen() {
        onFullScreenChange(true)
    }

    @objc private func windowDidEnterFullScreen() {
        onFullScreenChange(true)
    }

    @objc private func windowWillExitFullScreen() {
        onFullScreenChange(false)
    }

    @objc private func windowDidExitFullScreen() {
        onFullScreenChange(false)
        positionTrafficLights(animated: true)
    }

    @objc private func windowDidResize() {
        guard observedWindow?.styleMask.contains(.fullScreen) == false else { return }
        positionTrafficLights(animated: false)
    }

    private func positionTrafficLights(animated: Bool) {
        guard let window = observedWindow else { return }
        for type in buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            if originalButtonFrames[type] == nil {
                originalButtonFrames[type] = button.frame
            }
            guard var target = originalButtonFrames[type] else { continue }
            target.origin.x += 8
            target.origin.y -= 5

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    button.animator().setFrameOrigin(target.origin)
                }
            } else {
                button.setFrameOrigin(target.origin)
            }
        }
    }
}

private enum SidebarMode: Hashable {
    case lexicon
    case history
    case starred

    var title: String {
        switch self {
        case .lexicon: "Lexicon"
        case .history: "History"
        case .starred: "Starred"
        }
    }

    var iconName: String {
        switch self {
        case .lexicon: "text.book.closed"
        case .history: "clock"
        case .starred: "star"
        }
    }
}

private struct BrowserTabBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel

    // Tabs keep a browser-like natural width until the strip fills; after that
    // they share the available space evenly. 268 points is roughly two-thirds
    // of the previous cap, leaving room for more entries without feeling dense.
    private let preferredTabWidth: CGFloat = 268
    private let plusWidth: CGFloat = 32
    private let spacing: CGFloat = 2
    @Namespace private var activeTabBackground
    @State private var hoveredTabIDs: Set<UUID> = []

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
                ForEach(Array(appState.tabs.enumerated()), id: \.element.id) { index, tab in
                    let nextTabIsActive = index + 1 < appState.tabs.count
                        && appState.tabs[index + 1].id == appState.activeTabID
                    tabView(
                        tab,
                        width: tabWidth,
                        showsTrailingDivider: index + 1 < appState.tabs.count
                            && tab.id != appState.activeTabID
                            && !nextTabIsActive
                    )
                        .frame(width: tabWidth)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            )
                        )
                }

                Button {
                    appState.openNewTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
                .help("New Tab")
                .accessibilityLabel("New Tab")

                Spacer(minLength: 0)
            }
            .animation(.smooth(duration: 0.2), value: appState.tabs.map(\.id))
        }
        .frame(height: 36)
    }

    private func tabView(
        _ tab: EntryTab,
        width: CGFloat,
        showsTrailingDivider: Bool
    ) -> some View {
        let isActive = tab.id == appState.activeTabID
        let compact = width < 110
        let isHovered = hoveredTabIDs.contains(tab.id)
        return HStack(spacing: 5) {
            Button {
                appState.activateTab(tab.id)
            } label: {
                HStack(spacing: compact ? 4 : 8) {
                    if width >= 72 {
                        Image(systemName: "book.closed")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(libraryModel.displayWord(for: tab.word) ?? tab.word ?? "New Tab")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive || !compact {
                Button {
                    appState.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(BrowserIconButtonStyle(cornerRadius: 6, hitPadding: 2))
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
            }
        }
        .padding(.leading, compact ? 6 : 9)
        .padding(.trailing, compact ? 3 : 5)
        .frame(height: 34)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .matchedGeometryEffect(id: "active-tab", in: activeTabBackground)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(isActive ? 0.55 : 0),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(width: 1, height: 15)
                    .offset(x: spacing / 2)
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredTabIDs.insert(tab.id)
            } else {
                hoveredTabIDs.remove(tab.id)
            }
        }
        .animation(.smooth(duration: 0.18), value: isActive)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct BrowserIconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var hitPadding: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        BrowserIconButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            hitPadding: hitPadding
        )
    }
}

private struct BrowserIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let hitPadding: CGFloat
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(hitPadding)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var backgroundColor: Color {
        if configuration.isPressed { return Color.primary.opacity(0.11) }
        if isHovered { return Color.primary.opacity(0.065) }
        return Color.clear
    }
}

private extension View {
    func sidebarRow(selected: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.24) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
