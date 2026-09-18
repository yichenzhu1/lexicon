import AppKit
import MdxKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel
    @FocusState private var searchFocused: Bool
    @ViewState private var sidebarMode: SidebarMode =
        SidebarMode(rawValue: LibraryModel.storedSidebarMode) ?? .lexicon
    /// The section the user was browsing before a query pulled the sidebar
    /// into results; restored when the search field is cleared.
    @ViewState private var modeBeforeSearch: SidebarMode?
    /// Direction of the sidebar section slide: sections are ordered
    /// Lexicon → History → Starred, so a higher destination slides left.
    @ViewState private var sidebarSlideForward = true
    @Namespace private var segmentThumb
    @ViewState private var sidebarVisible = LibraryModel.storedSidebarVisible
    @ViewState private var sidebarWidth: CGFloat = LibraryModel.storedSidebarWidth
    @ViewState private var sidebarDragStartWidth: CGFloat?
    /// Two clicks on the divider within a beat reset the sidebar width.
    @ViewState private var lastDividerTap: Date?
    @ViewState private var windowIsFullScreen = false
    @ViewState private var isDropTargeted = false
    @ViewState private var zoomHUDVisible = false
    @ViewState private var zoomHUDTask: Task<Void, Never>?
    @ViewState private var starPulse = false
    @ViewState private var confirmingClearHistory = false

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
                .background {
                    SidebarBackground(isTranslucent: libraryModel.translucentSidebar)
                }
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
        // Focus once this view is installed. SwiftUI owns and cancels this
        // task; tab commands below update focus without queuing another task.
        .task {
            searchFocused = true
        }
        .animation(.smooth(duration: 0.22), value: sidebarVisible)
        .animation(.smooth(duration: 0.24), value: windowIsFullScreen)
        .background {
            WindowChromeBridge(isFullScreen: $windowIsFullScreen)
        }
        .sheet(isPresented: $appState.showDictionaryManager) {
            DictionaryManagerView()
                .environmentObject(libraryModel)
                .presentationCornerRadius(LayoutMetrics.Corners.panel)
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
                RoundedRectangle(cornerRadius: LayoutMetrics.Corners.panel - 4, style: .continuous)
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
            CloseShortcutBridge(configuration: libraryModel.shortcuts) { appState.closeActiveTabOrWindow() }
            Group {
                // Focused-window shortcuts take precedence over the generic
                // window menu, matching browser tab behavior.
                Button("") { searchFocused = true }
                    .keyboardShortcut(libraryModel.shortcuts[.focusSearch].shortcut)
                // ⌘= is the unshifted twin of ⌘+; browsers accept both.
                if libraryModel.shortcuts.zoomAliasAvailable {
                    Button("") { libraryModel.zoomIn() }
                        .keyboardShortcut("=", modifiers: .command)
                }
                // Browser-style tab switching: ⌘1…⌘8 by position, ⌘9 = last.
                ForEach(1 ... 8, id: \.self) { number in
                    Button("") { appState.activateTab(at: number - 1) }
                        .keyboardShortcut(libraryModel.shortcuts[ShortcutAction.tabActions[number - 1]].shortcut)
                }
                Button("") { appState.activateLastTab() }
                    .keyboardShortcut(libraryModel.shortcuts[.lastTab].shortcut)
            }
            .hidden()
        }
        #if DEBUG
        .onAppear {
            // Debug hook: auto-look-up a word at launch so layout issues can
            // be reproduced headlessly: `LEXICON_DEBUG_LOOKUP=hello .build/debug/Lexicon`.
            if let lookup = ProcessInfo.processInfo.environment["LEXICON_DEBUG_LOOKUP"],
               !lookup.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    appState.navigate(to: lookup)
                }
            }
        }
        #endif
        .onChange(of: appState.searchText) { _, text in
            let searching = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if searching {
                if sidebarMode != .lexicon { modeBeforeSearch = sidebarMode }
                setSidebarMode(.lexicon)
            } else if let previous = modeBeforeSearch {
                setSidebarMode(previous)
                modeBeforeSearch = nil
            }
        }
        .onChange(of: appState.activeTabID) { _, _ in
            searchFocused = true
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
        guard mode != sidebarMode else { return }
        sidebarSlideForward = mode.position > sidebarMode.position
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

            // Keep the shared glass behind ordinary buttons. Uniting glass
            // on each button can trap macOS 27's initial key-view traversal.
            HStack(spacing: 0) {
                Button {
                    appState.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(
                            width: LayoutMetrics.toolbarButtonSize,
                            height: LayoutMetrics.toolbarButtonSize
                        )
                        .contentShape(toolbarButtonShape)
                }
                .buttonStyle(BrowserIconButtonStyle(
                    cornerRadius: LayoutMetrics.Corners.toolbar, hitPadding: 0
                ))
                .help("Back")
                .accessibilityLabel("Back")
                .disabled(!appState.canGoBack)
                .keyboardShortcut(libraryModel.shortcuts[.back].shortcut)

                Button {
                    appState.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(
                            width: LayoutMetrics.toolbarButtonSize,
                            height: LayoutMetrics.toolbarButtonSize
                        )
                        .contentShape(toolbarButtonShape)
                }
                .buttonStyle(BrowserIconButtonStyle(
                    cornerRadius: LayoutMetrics.Corners.toolbar, hitPadding: 0
                ))
                .help("Forward")
                .accessibilityLabel("Forward")
                .disabled(!appState.canGoForward)
                .keyboardShortcut(libraryModel.shortcuts[.forward].shortcut)
            }
            .background {
                toolbarButtonShape.fill(.clear)
                    .glassEffect(.regular, in: toolbarButtonShape)
            }
            .overlay {
                Rectangle()
                    .fill(LayoutMetrics.separatorColor)
                    .frame(width: LayoutMetrics.separatorThickness, height: 16)
                    .allowsHitTesting(false)
            }

            WindowDragRegion(minLength: 8)
            searchField
                .frame(minWidth: 260, idealWidth: 400, maxWidth: 640)
                // Prefer a comfortably wide lookup target before handing
                // spare toolbar space to the surrounding drag regions.
                .layoutPriority(1)
            WindowDragRegion(minLength: 8)

            // The star acts on the current entry, so it lives with the entry
            // controls trailing the search field, not with navigation.
            HStack(spacing: 0) {
                Button {
                    if let word = appState.selectedWord {
                        libraryModel.toggleStar(word)
                    }
                } label: {
                    Image(systemName: bookmarkIconName)
                        .scaleEffect(starPulse ? 1.22 : 1)
                        .frame(
                            width: LayoutMetrics.toolbarButtonSize,
                            height: LayoutMetrics.toolbarButtonSize
                        )
                        .contentShape(toolbarButtonShape)
                }
                .buttonStyle(BrowserIconButtonStyle(
                    cornerRadius: LayoutMetrics.Corners.toolbar, hitPadding: 0
                ))
                .help(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
                .accessibilityLabel(isCurrentWordStarred ? "Remove from Starred" : "Add to Starred")
                .disabled(appState.selectedWord == nil)

                Button {
                    appState.showDictionaryManager = true
                } label: {
                    Image(systemName: "books.vertical")
                        .frame(
                            width: LayoutMetrics.toolbarButtonSize,
                            height: LayoutMetrics.toolbarButtonSize
                        )
                        .contentShape(toolbarButtonShape)
                }
                .buttonStyle(BrowserIconButtonStyle(
                    cornerRadius: LayoutMetrics.Corners.toolbar, hitPadding: 0
                ))
                .help("Manage dictionaries")
                .accessibilityLabel("Manage dictionaries")

                Button {
                    appState.openNewTab()
                } label: {
                    Image(systemName: "plus")
                        .frame(
                            width: LayoutMetrics.toolbarButtonSize,
                            height: LayoutMetrics.toolbarButtonSize
                        )
                        .contentShape(toolbarButtonShape)
                }
                .buttonStyle(BrowserIconButtonStyle(
                    cornerRadius: LayoutMetrics.Corners.toolbar, hitPadding: 0
                ))
                .help("New Tab")
                .accessibilityLabel("New Tab")
            }
            .background {
                toolbarButtonShape.fill(.clear)
                    .glassEffect(.regular, in: toolbarButtonShape)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(
            .leading,
            sidebarVisible || windowIsFullScreen
                ? LayoutMetrics.horizontalInset : LayoutMetrics.trafficLightInset
        )
        .padding(.trailing, LayoutMetrics.horizontalInset)
        // A two-point optical correction centers the controls between the
        // window's top edge and the tab pill below while accounting for the
        // tab pill's top margin.
        .offset(y: LayoutMetrics.toolbarContentVerticalOffset)
        .frame(height: LayoutMetrics.toolbarRowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Safari's separate tab bar layout: tabs get their own full-width row
    /// below the toolbar.
    private var tabStripRow: some View {
        BrowserTabBar()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LayoutMetrics.horizontalInset)
            .frame(height: LayoutMetrics.tabStripRowHeight)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The strip above the sidebar: the traffic lights float at its leading
    /// edge and the sidebar toggle sits at its trailing edge, so the control
    /// that dismisses the sidebar stays on the sidebar itself. It gets the
    /// toolbar row's one-point optical correction too — the toggle and the
    /// toolbar controls form one visual row across the window top.
    private var sidebarTopRegion: some View {
        HStack(spacing: 0) {
            WindowDragRegion()
            sidebarToggleButton
        }
        .padding(.trailing, LayoutMetrics.horizontalInset)
        .offset(y: LayoutMetrics.toolbarContentVerticalOffset)
        .frame(height: LayoutMetrics.toolbarRowHeight)
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .frame(
                    width: LayoutMetrics.toolbarButtonSize,
                    height: LayoutMetrics.toolbarButtonSize
                )
                .contentShape(toolbarButtonShape)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: toolbarButtonShape
        )
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
        .frame(width: LayoutMetrics.splitterHitWidth)
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
                        zoom: libraryModel.entryZoom
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
                        .glassEffect(
                            .regular,
                            in: RoundedRectangle(cornerRadius: LayoutMetrics.Corners.hud, style: .continuous)
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
                // Dictionary queries are literal. Let Lexicon's own fuzzy
                // search handle typos rather than changing the user's text.
                .autocorrectionDisabled()
                .focused($searchFocused)
                .onKeyPress(phases: .down) { press in
                    let binding = ShortcutBinding.normalized(String(press.key.character), modifiers:
                        (press.modifiers.contains(.command) ? 1 : 0)
                        | (press.modifiers.contains(.option) ? 2 : 0)
                        | (press.modifiers.contains(.control) ? 4 : 0)
                        | (press.modifiers.contains(.shift) ? 8 : 0))
                    guard let action = ShortcutAction.allCases.first(where: {
                        $0.isSearchAction && libraryModel.shortcuts[$0] == binding
                    }) else { return .ignored }
                    switch action {
                    case .clearSearch:
                        if appState.searchText.isEmpty { searchFocused = false }
                        else { appState.searchText = "" }
                    case .nextResult: appState.moveSearchSelection(by: 1)
                    case .previousResult: appState.moveSearchSelection(by: -1)
                    case .openResult: appState.submitSearch()
                    default: return .ignored
                    }
                    return .handled
                }
        }
            .padding(.horizontal, 10)
            // Matches the Safari-sized toolbar capsules, so the field and the
            // button groups share one height and one vertical rhythm.
            .frame(height: LayoutMetrics.toolbarControlHeight)
            .background {
                RoundedRectangle(cornerRadius: LayoutMetrics.Corners.toolbar, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(cornerRadius: LayoutMetrics.Corners.toolbar, style: .continuous)
                    )
            }
            .overlay {
                // Glass carries the resting state; only focus gets a ring.
                if searchFocused {
                    RoundedRectangle(cornerRadius: LayoutMetrics.Corners.toolbar, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Search all dictionaries")
    }

    private var isCurrentWordStarred: Bool {
        guard let word = appState.selectedWord else { return false }
        return libraryModel.isStarred(word)
    }

    private var bookmarkIconName: String {
        isCurrentWordStarred ? "bookmark.fill" : "bookmark"
    }

    private var toolbarButtonShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LayoutMetrics.Corners.toolbar,
            style: .continuous
        )
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
                .padding(.horizontal, LayoutMetrics.sidebarContentInset)
                .offset(y: LayoutMetrics.sidebarModeVerticalOffset)
                .frame(height: LayoutMetrics.tabStripRowHeight)
                // Keep section motion inside the control. Animating the whole
                // sidebar also animates the status bar's insertion/removal,
                // which makes otherwise identical empty states travel in
                // different directions between sections.
                .animation(.smooth(duration: 0.2), value: sidebarMode)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    sidebarStatusBar

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if sidebarMode == .lexicon {
                                if !isSearching {
                                    placeholderRow(emptyListMessage)
                                } else if appState.results.isEmpty {
                                    placeholderRow(appState.isSearchPending ? "Searching…" : "No matches")
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
                                ForEach(savedWords, id: \.self) { word in
                                    savedWordRow(word)
                                }
                            }
                        }
                        .padding(.horizontal, LayoutMetrics.sidebarContentInset)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.automatic)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(sidebarMode)
                .transition(sidebarSectionTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            // The status row and list move as one pane. Scoping the animation
            // here prevents their different internal layouts from producing
            // the old vertical push/pull effect.
            .animation(.smooth(duration: 0.24), value: sidebarMode)
        }
    }

    /// A short horizontal travel reads as a section change without making the
    /// narrow sidebar feel as though an entire page is flying across it.
    private var sidebarSectionTransition: AnyTransition {
        let distance: CGFloat = 18
        return .asymmetric(
            insertion: .offset(x: sidebarSlideForward ? distance : -distance)
                .combined(with: .opacity),
            removal: .offset(x: sidebarSlideForward ? -distance : distance)
                .combined(with: .opacity)
        )
    }

    /// A segmented control in the Safari mold, with the selection thumb
    /// gliding between segments instead of a hard highlight swap. The thumb
    /// is glass; the shared glass ID lets it morph from segment to segment.
    private var sidebarModePicker: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(SidebarMode.allCases, id: \.self) { mode in
                    sidebarModeButton(mode)
                }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: LayoutMetrics.Corners.segmentContainer, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .accessibilityLabel("Sidebar section")
        .accessibilityValue(sidebarMode.title)
    }

    /// Glass goes directly on the selected segment's button — not in its
    /// background — so the container renders it beneath the label text.
    @ViewBuilder
    private func sidebarModeButton(_ mode: SidebarMode) -> some View {
        let button = Button {
            setSidebarMode(mode)
        } label: {
            Text(mode.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(sidebarMode == mode ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: LayoutMetrics.sidebarModeButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(sidebarMode == mode ? .isSelected : [])

        if sidebarMode == mode {
            button
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: LayoutMetrics.Corners.segment, style: .continuous)
                )
                .glassEffectID("sidebar-section-thumb", in: segmentThumb)
        } else {
            button
        }
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
                            confirmingClearHistory = true
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
                    .alert("Clear History?", isPresented: $confirmingClearHistory) {
                        Button("Cancel", role: .cancel) {}
                            .keyboardShortcut(.defaultAction)
                        Button("Clear History", role: .destructive) {
                            libraryModel.clearHistory()
                        }
                        .disabled(libraryModel.history.isEmpty)
                    } message: {
                        Text("This permanently clears history.\nYour starred words will be kept.\nYour dictionaries will be kept.")
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.bottom, 6)
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            appState.selectSearchResult(result.normalizedKey)
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

    private func savedWordRow(_ word: String) -> some View {
        let isSelected = appState.selectedWord == word
        return Button {
            appState.selectSavedWord(word)
        } label: {
            Text(libraryModel.displayWord(for: word) ?? word)
                .lineLimit(1)
                .sidebarRow(selected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
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
            if appState.isSearchPending && appState.results.isEmpty { return "Searching…" }
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
            .buttonStyle(BrowserIconButtonStyle())
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notice")
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: LayoutMetrics.Corners.hud, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

/// Shared layout geometry keeps the toolbar, tab strip, and sidebar edge on
/// one deliberate rhythm. Separators use the system separator color at full
/// strength everywhere — SwiftUI chrome and the entry page's CSS hairlines
/// (`--lexicon-hairline` in EntryPageBuilder) are the same 1pt rule, so the
/// sidebar edge, the tab-strip baseline, and the jump-bar edges read as one
/// line. Hit areas may be wider, but the visible rule never changes.
enum LayoutMetrics {
    /// Controls use half their height; nested surfaces keep concentric curves.
    enum Corners {
        static let toolbar: CGFloat = toolbarControlHeight / 2
        static let tab: CGFloat = 15
        static let segment: CGFloat = sidebarModeButtonHeight / 2
        static let segmentContainer: CGFloat = segment + 2
        static let row: CGFloat = 10
        static let icon: CGFloat = 8
        static let smallButton: CGFloat = 10
        static let hud: CGFloat = 16
        static let panel: CGFloat = 24
    }

    static let toolbarRowHeight: CGFloat = 50
    static let tabStripRowHeight: CGFloat = 38
    static let toolbarControlHeight: CGFloat = 36
    static let tabStripContentHeight: CGFloat = 32
    static let toolbarButtonSize: CGFloat = 36
    static let toolbarContentVerticalOffset: CGFloat = 2
    static let horizontalInset: CGFloat = 8
    static let sidebarContentInset: CGFloat = 7
    static let sidebarModeButtonHeight: CGFloat = 26
    static let sidebarModeVerticalOffset: CGFloat = -1
    static let trafficLightInset: CGFloat = 82
    static let trafficLightHorizontalOffset: CGFloat = 8
    /// AppKit lays out the native controls against its compact title-bar row.
    /// Center them in Lexicon's taller custom toolbar without resizing their
    /// system-standard artwork or spacing.
    static let trafficLightReferenceRowHeight: CGFloat = 32
    static var trafficLightVerticalOffset: CGFloat {
        -(toolbarRowHeight - trafficLightReferenceRowHeight) / 2
    }
    static let splitterHitWidth: CGFloat = 7
    static let separatorThickness: CGFloat = 1

    static var separatorColor: Color {
        Color(nsColor: .separatorColor)
    }
}

/// A deliberately non-functional part of the custom title bar that can move
/// the window. Window background dragging is disabled at the scene level so
/// controls and tabs never inherit this gesture accidentally.
private struct WindowDragRegion: View {
    var minLength: CGFloat = 0

    var body: some View {
        ExplicitWindowDragRegion()
            .frame(minWidth: minLength, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExplicitWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> ExplicitWindowDragRegionView {
        ExplicitWindowDragRegionView(frame: .zero)
    }

    func updateNSView(_ nsView: ExplicitWindowDragRegionView, context: Context) {}
}

/// The one native hit-test target that is allowed to begin window movement.
/// The window itself is non-movable, so this view updates its frame directly
/// while the pointer is held. No control can enter this code path.
private final class ExplicitWindowDragRegionView: NSView {
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let dragStartMouseLocation,
              let dragStartWindowOrigin
        else { return }

        let mouseLocation = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: dragStartWindowOrigin.x + mouseLocation.x - dragStartMouseLocation.x,
            y: dragStartWindowOrigin.y + mouseLocation.y - dragStartMouseLocation.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
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
                .fill(LayoutMetrics.separatorColor)
                .frame(maxWidth: .infinity)
                .frame(height: LayoutMetrics.separatorThickness)
                .allowsHitTesting(false)
        case .vertical:
            Rectangle()
                .fill(LayoutMetrics.separatorColor)
                .frame(width: LayoutMetrics.separatorThickness)
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

/// Keeps custom full-size window chrome aligned with macOS window state.
/// Normal windows center their native traffic lights in Lexicon's toolbar;
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

        // The transparent NSHostingView beneath pure SwiftUI buttons reports
        // mouseDownCanMoveWindow == true in a hidden title bar. Disable native
        // movement for the entire window so no functional control can ever
        // become a title-bar drag source. ExplicitWindowDragRegionView is the
        // sole code path that changes the frame in response to a pointer drag.
        window.isMovableByWindowBackground = false
        window.isMovable = false

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
            target.origin.x += LayoutMetrics.trafficLightHorizontalOffset
            target.origin.y += LayoutMetrics.trafficLightVerticalOffset

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

    var position: Int {
        switch self {
        case .lexicon: 0
        case .history: 1
        case .starred: 2
        }
    }
}

private struct BrowserTabBar: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var libraryModel: LibraryModel

    private let spacing = TabStripLayout.spacing
    @Namespace private var activeTabBackground
    @ViewState private var pointerLocation: CGPoint?
    @ViewState private var closingLayout: TabStripLayout?
    /// The tab a reorder drag is hovering over; drives the insertion indicator.
    @ViewState private var dropTargetTabID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let tabIDs = appState.tabs.map(\.id)
            let layout = closingLayout.flatMap {
                $0.matches(tabIDs: tabIDs, availableWidth: proxy.size.width) ? $0 : nil
            } ?? TabStripLayout(tabIDs: tabIDs, availableWidth: proxy.size.width)

            HStack(spacing: spacing) {
                ForEach(Array(appState.tabs.enumerated()), id: \.element.id) { index, tab in
                    let tabWidth = layout.widths[index]
                    let isHovered = pointerLocation.map {
                        CGRect(x: layout.origin(at: index), y: 0,
                               width: tabWidth, height: proxy.size.height).contains($0)
                    } ?? false
                    let nextTabIsActive = index + 1 < appState.tabs.count
                        && appState.tabs[index + 1].id == appState.activeTabID
                    tabView(
                        tab,
                        width: tabWidth,
                        isHovered: isHovered,
                        close: { closeTab(tab.id, layout: layout) },
                        showsTrailingDivider: index + 1 < appState.tabs.count
                            && tab.id != appState.activeTabID
                            && !nextTabIsActive
                    )
                        .frame(width: tabWidth)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.96))
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
            .contentShape(Rectangle())
            .overlay {
                TabStripPointerTracking { location in
                    pointerLocation = location
                    if location == nil {
                        withAnimation(.smooth(duration: 0.2)) { closingLayout = nil }
                    }
                }
            }
            .onChange(of: tabIDs) { _, ids in
                if closingLayout?.tabIDs != ids { closingLayout = nil }
            }
            .onChange(of: proxy.size.width) { _, _ in closingLayout = nil }
            .transaction { transaction in
                if closingLayout?.matches(tabIDs: tabIDs, availableWidth: proxy.size.width) == true {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
        .frame(height: LayoutMetrics.tabStripContentHeight)
        .onDisappear {
            closingLayout = nil
            pointerLocation = nil
        }
    }

    private func closeTab(_ id: UUID, layout: TabStripLayout) {
        // AppState and the tab backgrounds also supply animations. Disable the
        // entire transaction so the next button is immediately clickable here.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            closingLayout = layout.closing(id)
            appState.closeTab(id)
        }
    }

    private func tabView(
        _ tab: EntryTab,
        width: CGFloat,
        isHovered: Bool,
        close: @escaping () -> Void,
        showsTrailingDivider: Bool
    ) -> some View {
        let isActive = tab.id == appState.activeTabID
        let compact = width < 110
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

            if isActive || !compact || isHovered {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(BrowserIconButtonStyle())
                .foregroundStyle(.secondary)
                .help("Close Tab")
                .accessibilityLabel("Close Tab")
            }
        }
        .padding(.leading, compact ? 6 : 9)
        // A constant inset also keeps the close target fixed if the last
        // surviving compact tab grows during a pointer-close session.
        .padding(.trailing, 5)
        .frame(height: 30)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: LayoutMetrics.Corners.tab, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: LayoutMetrics.Corners.tab, style: .continuous)
                    )
                    .matchedGeometryEffect(id: "active-tab", in: activeTabBackground)
            } else if isHovered {
                RoundedRectangle(cornerRadius: LayoutMetrics.Corners.tab, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(LayoutMetrics.separatorColor)
                    .frame(width: LayoutMetrics.separatorThickness, height: 15)
                    .offset(x: spacing / 2)
            }
        }
        .overlay {
            MiddleClickClose(action: close)
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

/// Keep one tracking area for the whole strip, including its empty trailing
/// space. SwiftUI hover regions can exit when the tab under the pointer dies.
private struct TabStripPointerTracking: NSViewRepresentable {
    let changed: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        view.install()
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) {
        view.uninstall()
    }

    final class TrackingView: NSView {
        var changed: (CGPoint?) -> Void = { _ in }
        private var area: NSTrackingArea?
        private var monitor: Any?
        private weak var trackedWindow: NSWindow?
        private var previouslyAcceptedMouseMoved = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restoreWindowMouseTracking()
            trackedWindow = window
            previouslyAcceptedMouseMoved = window?.acceptsMouseMovedEvents ?? false
            window?.acceptsMouseMovedEvents = true
        }

        func install() {
            // Observe without consuming events. This also updates the pointer
            // before a click, including clicks delivered without a mouse move.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .otherMouseDragged,
            ]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    if event.window === window {
                        self.reportPointer(event)
                    } else {
                        self.changed(nil)
                    }
                }
                return event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            restoreWindowMouseTracking()
        }

        private func restoreWindowMouseTracking() {
            trackedWindow?.acceptsMouseMovedEvents = previouslyAcceptedMouseMoved
            trackedWindow = nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            // A SwiftUI-hosted view's visibleRect can extend beyond its bounds
            // to the whole window. Track the strip's actual bounds explicitly.
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved,
                                                .activeAlways],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }

        override func mouseEntered(with event: NSEvent) { reportPointer(event) }
        override func mouseMoved(with event: NSEvent) { reportPointer(event) }
        override func mouseExited(with event: NSEvent) { reportPointer(event) }

        private func reportPointer(_ event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            // Ignore synthetic exits caused by changes beneath the pointer.
            changed(bounds.contains(location) ? location : nil)
        }

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

private struct BrowserIconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = LayoutMetrics.Corners.smallButton
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
    @ViewState private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(hitPadding)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.78 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var backgroundColor: Color {
        guard isEnabled else { return .clear }
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
                RoundedRectangle(cornerRadius: LayoutMetrics.Corners.row, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.3) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: LayoutMetrics.Corners.row, style: .continuous))
    }
}
