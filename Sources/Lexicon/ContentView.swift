import AppKit
import MdxKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var searchFocused: Bool
    @State private var sidebarMode: SidebarMode =
        SidebarMode(rawValue: LibraryModel.storedSidebarMode) ?? .lexicon
    /// The section the user was browsing before a query pulled the sidebar
    /// into results; restored when the search field is cleared.
    @State private var modeBeforeSearch: SidebarMode?
    /// Direction of the sidebar section slide: sections are ordered
    /// Lexicon → History → Starred, so a higher destination slides left.
    @Namespace private var segmentThumb
    @State private var sidebarVisible = LibraryModel.storedSidebarVisible
    @State private var sidebarWidth: CGFloat = LibraryModel.storedSidebarWidth
    @State private var sidebarDragStartWidth: CGFloat?
    /// Two clicks on the divider within a beat reset the sidebar width.
    @State private var lastDividerTap: Date?
    @State private var windowIsFullScreen = false
    @State private var isDropTargeted = false
    @State private var zoomHUDVisible = false
    @State private var zoomHUDTask: Task<Void, Never>?
    @State private var starPulse = false

    /// True while the lookup field holds a query, in which case the sidebar
    /// shows results rather than one of the saved lists.
    private var isSearching: Bool {
        !appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                VStack(spacing: 0) {
                    sidebarTopRegion

                    sidebar
                }
                .frame(width: sidebarWidth)
                // A true sidebar material gives the panel its own depth
                // against the content area instead of the same flat gray.
                .background(.regularMaterial)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The divider rides the exact sidebar/content boundary, drawn above
        // both columns so the opaque bars can't cover it, and every
        // horizontal separator runs flush into it.
        .overlay(alignment: .topLeading) {
            if sidebarVisible {
                sidebarDivider
                    .offset(x: sidebarWidth)
                    .transition(.opacity)
            }
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
                // Browser-style tab switching: ⌘1…⌘8 by position, ⌘9 = last.
                ForEach(1 ... 8, id: \.self) { number in
                    Button("") { appState.activateTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
                Button("") { appState.activateLastTab() }
                    .keyboardShortcut("9", modifiers: .command)
            }
            .hidden()
        }
        .onAppear {
            focusSearchField()
            #if DEBUG
            // Debug hook: auto-look-up a word at launch so layout issues can
            // be reproduced headlessly: `LEXICON_DEBUG_LOOKUP=hello .build/debug/Lexicon`.
            if let lookup = ProcessInfo.processInfo.environment["LEXICON_DEBUG_LOOKUP"],
               !lookup.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    appState.navigate(to: lookup)
                }
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { focusSearchField() }
        }
        .onChange(of: appState.searchText) { _, text in
            let searching = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            withAnimation(.smooth(duration: 0.18)) {
                if searching {
                    if sidebarMode != .lexicon { modeBeforeSearch = sidebarMode }
                    setSidebarMode(.lexicon)
                } else if let previous = modeBeforeSearch {
                    setSidebarMode(previous)
                    modeBeforeSearch = nil
                }
            }
        }
        .onChange(of: appState.activeTabID) { _, _ in
            focusSearchField()
        }
        .onChange(of: sidebarVisible) { _, _ in persistSidebarLayout() }
        .onChange(of: sidebarMode) { _, _ in persistSidebarLayout() }
        .onChange(of: libraryModel.entryZoom) { _, _ in showZoomHUD() }
        .onChange(of: isCurrentWordStarred) { _, starred in
            guard starred else { return }
            withAnimation(.easeOut(duration: 0.12)) { starPulse = true } completion: {
                withAnimation(.easeOut(duration: 0.18)) { starPulse = false }
            }
        }
    }

    private func persistSidebarLayout() {
        LibraryModel.storeSidebarLayout(
            width: Double(sidebarWidth),
            visible: sidebarVisible,
            mode: sidebarMode.rawValue
        )
    }

    /// Routes every section switch through one place so programmatic jumps
    /// (search results) animate exactly like picker clicks.
    private func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
    }

    /// Briefly surfaces the new entry text size so ⌘+/⌘-/⌘0 have visible
    /// feedback; a plain fade, so Reduce Motion needs no special case.
    private func showZoomHUD() {
        zoomHUDTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { zoomHUDVisible = true }
        zoomHUDTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { zoomHUDVisible = false }
        }
    }

    /// The window's toolbar: navigation, the lookup field (centered), and the
    /// entry controls. Tabs live in their own row below, Safari-style. When
    /// the sidebar is hidden, the sidebar toggle moves here and the leading
    /// padding clears the traffic lights.
    private var toolbarRow: some View {
        HStack(spacing: 6) {
            if !sidebarVisible {
                sidebarToggleButton
            }

            ToolbarCapsule {
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
            }

            Spacer(minLength: 8)
            searchField
                .frame(minWidth: 220, idealWidth: 360, maxWidth: 560)
            Spacer(minLength: 8)

            // The star acts on the current entry, so it lives with the entry
            // controls trailing the search field, not with navigation.
            ToolbarCapsule {
                Button {
                    if let word = appState.selectedWord {
                        libraryModel.toggleStar(word)
                    }
                } label: {
                    Image(systemName: bookmarkIconName)
                        .scaleEffect(starPulse ? 1.22 : 1)
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
                .help(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
                .accessibilityLabel(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
                .disabled(appState.selectedWord == nil)

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

                Button {
                    appState.openNewTab()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(BrowserIconButtonStyle(cornerRadius: 7))
                .help("New Tab")
                .accessibilityLabel("New Tab")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(
            .leading,
            sidebarVisible || windowIsFullScreen
                ? ChromeMetrics.horizontalInset : ChromeMetrics.trafficLightInset
        )
        .padding(.trailing, ChromeMetrics.horizontalInset)
        // A one-point optical correction aligns the controls' visible centers
        // with the denser tab row without changing either row's geometry.
        .offset(y: ChromeMetrics.toolbarContentVerticalOffset)
        .frame(height: ChromeMetrics.toolbarRowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Safari's separate tab bar layout: tabs get their own full-width row
    /// below the toolbar.
    private var tabStripRow: some View {
        BrowserTabBar()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ChromeMetrics.horizontalInset)
            .frame(height: ChromeMetrics.tabStripRowHeight)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The strip above the sidebar: the traffic lights float at its leading
    /// edge and the sidebar toggle sits at its trailing edge, so the control
    /// that dismisses the sidebar stays on the sidebar itself.
    private var sidebarTopRegion: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            sidebarToggleButton
        }
        .padding(.trailing, ChromeMetrics.horizontalInset)
        .frame(height: ChromeMetrics.toolbarRowHeight)
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
        // The visible hairline sits at the leading edge, flush with the
        // sidebar; the remaining width is invisible drag area into the detail.
        ZStack(alignment: .leading) {
            Color.clear
            ChromeSeparator(.vertical)
        }
        .frame(width: ChromeMetrics.splitterHitWidth)
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
                .onEnded { value in
                    sidebarDragStartWidth = nil
                    defer { persistSidebarLayout() }
                    // A double-tap on the divider restores the default width,
                    // the standard Mac splitter gesture.
                    guard abs(value.translation.width) < 2 else {
                        lastDividerTap = nil
                        return
                    }
                    let now = Date()
                    if let last = lastDividerTap, now.timeIntervalSince(last) < 0.35 {
                        withAnimation(.smooth(duration: 0.2)) {
                            sidebarWidth = CGFloat(LibraryModel.defaultSidebarWidth)
                        }
                        lastDividerTap = nil
                    } else {
                        lastDividerTap = now
                    }
                }
        )
    }

    private var detail: some View {
        VStack(spacing: 0) {
            toolbarRow
            // No separator between the toolbar and the tab strip — Safari
            // runs them together as one chrome surface.
            tabStripRow
            ChromeSeparator(.horizontal)
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
            .overlay {
                if zoomHUDVisible {
                    Text("\(Int((libraryModel.entryZoom * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityLabel(
                            "Entry text size \(Int((libraryModel.entryZoom * 100).rounded())) percent"
                        )
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(
                "",
                text: $appState.searchText,
                prompt: Text("Search all dictionaries…")
            )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let first = appState.results.first {
                        appState.selectedWord = first.normalizedKey
                    }
                }
                .onKeyPress(.escape) {
                    if appState.searchText.isEmpty {
                        searchFocused = false
                    } else {
                        appState.searchText = ""
                    }
                    return .handled
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
            // Matches the toolbar capsules (32pt), so the field and the
            // button groups share one height and one vertical rhythm.
            .frame(height: ChromeMetrics.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .overlay {
                // Glass carries the resting state; only focus gets a ring.
                if searchFocused {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                SearchFocusDismissBridge(isFocused: $searchFocused)
            }
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
            sidebarModePicker
                // The selector and result rows share one horizontal edge. Its
                // 30-point surface matches the tabs, with a one-point optical
                // lift inside the common 38-point navigation row.
                .padding(.horizontal, ChromeMetrics.sidebarContentInset)
                .offset(y: ChromeMetrics.sidebarModeVerticalOffset)
                .frame(height: ChromeMetrics.tabStripRowHeight)

            sidebarStatusBar

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if sidebarMode == .lexicon {
                        if !isSearching {
                            placeholderRow(emptyListMessage)
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
                .padding(.horizontal, ChromeMetrics.sidebarContentInset)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
        // Animates the picker's sliding selection thumb (and the status bar's
        // arrival); the list content itself swaps without motion.
        .animation(.smooth(duration: 0.2), value: sidebarMode)
    }

    /// A segmented control in the Safari mold, with the selection thumb
    /// gliding between segments instead of a hard highlight swap.
    private var sidebarModePicker: some View {
        HStack(spacing: 2) {
            ForEach(SidebarMode.allCases, id: \.self) { mode in
                Button {
                    setSidebarMode(mode)
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(sidebarMode == mode ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: ChromeMetrics.sidebarModeButtonHeight)
                        .contentShape(Rectangle())
                        .background {
                            if sidebarMode == mode {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(
                                        id: "sidebar-section-thumb", in: segmentThumb
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(sidebarMode == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .accessibilityLabel("Sidebar section")
        .accessibilityValue(sidebarMode.title)
    }

    @ViewBuilder
    private var sidebarStatusBar: some View {
        if sidebarMode == .history || sidebarMode == .starred
            || (sidebarMode == .lexicon && isSearching) {
            HStack(spacing: 8) {
                Text(sidebarStatusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                // Starred words are managed one by one; only the transient
                // lists (search, history) get a bulk Clear.
                if sidebarMode != .starred {
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
        switch sidebarMode {
        case .history:
            return "\(libraryModel.history.count) recent"
        case .starred:
            return "\(libraryModel.starred.count) starred"
        case .lexicon:
            let label = showingSuggestions ? "suggestions" : "results"
            return "\(appState.results.count) \(label)"
        }
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

/// SwiftUI's focus state doesn't automatically resign when an AppKit-backed
/// view (notably WKWebView) receives a click. This unobtrusive bridge watches
/// the containing window and releases search focus on any click outside the
/// search field without consuming the click meant for the destination view.
private struct SearchFocusDismissBridge: NSViewRepresentable {
    let isFocused: FocusState<Bool>.Binding

    func makeCoordinator() -> Coordinator {
        Coordinator(isFocused: isFocused)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isFocused = isFocused
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var isFocused: FocusState<Bool>.Binding
        private var eventMonitor: Any?

        init(isFocused: FocusState<Bool>.Binding) {
            self.isFocused = isFocused
        }

        func installMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self,
                      isFocused.wrappedValue,
                      let hostView,
                      let window = hostView.window,
                      event.window === window
                else { return event }

                let point = hostView.convert(event.locationInWindow, from: nil)
                guard !hostView.bounds.contains(point) else { return event }

                isFocused.wrappedValue = false
                return event
            }
        }

        func removeMonitor() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
        }
    }
}

struct LibraryNoticeView: View {
    let notice: LibraryModel.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .help(notice.message)
            }

            Spacer(minLength: 4)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notice")
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ChromeMetrics.separatorColor, lineWidth: ChromeMetrics.separatorThickness)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
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

/// Shared chrome geometry keeps the toolbar, tab strip, and sidebar edge on
/// one deliberate rhythm. Separators use one quiet adaptive color everywhere;
/// their hit areas may be wider, but the visible rule never changes thickness.
private enum ChromeMetrics {
    static let toolbarRowHeight: CGFloat = 42
    static let tabStripRowHeight: CGFloat = 38
    static let controlHeight: CGFloat = 32
    static let toolbarContentVerticalOffset: CGFloat = 1
    static let horizontalInset: CGFloat = 8
    static let sidebarContentInset: CGFloat = 7
    static let sidebarModeButtonHeight: CGFloat = 26
    static let sidebarModeVerticalOffset: CGFloat = -1
    static let trafficLightInset: CGFloat = 82
    static let splitterHitWidth: CGFloat = 7
    static let separatorThickness: CGFloat = 1

    static var separatorColor: Color {
        Color(nsColor: .separatorColor).opacity(0.62)
    }
}

private struct ChromeSeparator: View {
    enum Orientation {
        case horizontal
        case vertical
    }

    let orientation: Orientation

    init(_ orientation: Orientation) {
        self.orientation = orientation
    }

    @ViewBuilder
    var body: some View {
        switch orientation {
        case .horizontal:
            Rectangle()
                .fill(ChromeMetrics.separatorColor)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.separatorThickness)
                .allowsHitTesting(false)
        case .vertical:
            Rectangle()
                .fill(ChromeMetrics.separatorColor)
                .frame(width: ChromeMetrics.separatorThickness)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
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

private enum SidebarMode: String, CaseIterable {
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
}

private struct BrowserTabBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel

    private let spacing: CGFloat = 2
    @Namespace private var activeTabBackground
    @State private var hoveredTabIDs: Set<UUID> = []
    /// The tab a reorder drag is hovering over; drives the insertion indicator.
    @State private var dropTargetTabID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, appState.tabs.count)
            let interItemSpacing = spacing * CGFloat(max(0, count - 1))
            let availableForTabs = max(
                CGFloat(count),
                proxy.size.width - interItemSpacing
            )
            // Tabs share the full strip evenly, like Safari's tab bar — a
            // single tab spans the whole space instead of hugging the left.
            let tabWidth = max(56, availableForTabs / CGFloat(count))

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
                        // Drag to reorder, like a browser tab strip. Dropping
                        // on a tab inserts before it.
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let first = items.first,
                                  let uuid = UUID(uuidString: first)
                            else { return false }
                            appState.moveTab(id: uuid, before: tab.id)
                            return true
                        } isTargeted: { targeted in
                            withAnimation(.easeOut(duration: 0.12)) {
                                dropTargetTabID = targeted ? tab.id : nil
                            }
                        }
                        .overlay(alignment: .leading) {
                            if dropTargetTabID == tab.id {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(Color.accentColor)
                                    .frame(width: 3, height: 20)
                                    .accessibilityLabel("Move tab here")
                            }
                        }
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .animation(.smooth(duration: 0.2), value: appState.tabs.map(\.id))
        }
        .frame(height: ChromeMetrics.controlHeight)
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
        .frame(height: 30)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .matchedGeometryEffect(id: "active-tab", in: activeTabBackground)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(ChromeMetrics.separatorColor)
                    .frame(width: ChromeMetrics.separatorThickness, height: 15)
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
        .overlay {
            MiddleClickClose { appState.closeTab(tab.id) }
        }
        .contextMenu {
            Button("Close Tab") { appState.closeTab(tab.id) }
            Button("Close Other Tabs") { appState.closeOtherTabs(of: tab.id) }
                .disabled(appState.tabs.count <= 1)
            Button("Close Tabs to the Right") { appState.closeTabsToTheRight(of: tab.id) }
                .disabled(appState.tabs.last?.id == tab.id)
        }
        .animation(.smooth(duration: 0.18), value: isActive)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// SwiftUI has no middle-click API, so tab middle-click close is forwarded
/// from AppKit. The view is transparent to every other event, including
/// left-clicks, which keeps the tab's own buttons fully functional.
private struct MiddleClickClose: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickView, context: Context) {
        nsView.action = action
    }
}

private final class MiddleClickView: NSView {
    var action: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .otherMouseDown,
              NSApp.currentEvent?.buttonNumber == 2
        else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            action()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

/// Safari-style toolbar capsule: a hairline-ringed pill grouping related
/// buttons (back/forward, entry actions) into one visual unit.
private struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 2)
            .frame(height: ChromeMetrics.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ChromeMetrics.separatorColor, lineWidth: 1)
            }
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
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.3) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
