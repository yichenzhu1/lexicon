import SwiftUI

enum SettingsLayout {
    // Keep room for six toolbar items and a readable two-column form.
    static let paneWidth: CGFloat = 620
}

/// Shared macOS preferences layout: trailing labels, leading controls, and
/// small notes below the control they explain. No full-width card rows.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            content
        }
        .padding(24)
        .frame(width: SettingsLayout.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var controlWidth: CGFloat = 360
    @ViewBuilder var content: Content

    init(_ title: String = "", controlWidth: CGFloat = 360, @ViewBuilder content: () -> Content) {
        self.title = title
        self.controlWidth = controlWidth
        self.content = content()
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title.isEmpty ? "" : title + ":")
                .gridColumnAlignment(.trailing)
            content
                .frame(width: controlWidth, alignment: .leading)
                .gridColumnAlignment(.leading)
        }
    }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        SettingsRow {
            Text(text).settingsNote()
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        GridRow {
            Divider().padding(.vertical, 6)
                .gridCellColumns(2)
                .gridCellUnsizedAxes(.horizontal)
        }
    }
}

struct SettingsPaneHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func settingsPane(_ id: String) -> some View {
        ScrollView {
            self.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SettingsPaneHeightKey.self, value: [id: geometry.size.height])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Paint the whole viewport, including unused space, with the same
        // opaque semantic color in every tab. Transparent content otherwise
        // allows the window's backdrop tint to vary as its height changes.
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    func settingsNote() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct APIKeyRow: View {
    @Binding var draft: String
    let hasSavedKey: Bool
    let fieldLabel: String
    let save: (String) -> Bool
    let remove: () -> Void

    var body: some View {
        SettingsRow("API key") {
            HStack(spacing: 8) {
                SecureField(hasSavedKey ? "Replacement key" : "Paste API key", text: $draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(fieldLabel)
                    .onSubmit(saveDraft)
                Button("Save", action: saveDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedKey { Button("Remove", action: remove) }
            }
        }
    }

    private func saveDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if save(draft) { draft = "" }
    }
}

/// Keep the native preferences titlebar visibly distinct from the content,
/// matching Safari's persistent title-and-toolbar background.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) { nsView.configureWindow() }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .line
            window.toolbarStyle = .preference
            // SwiftUI's full-size content mode puts the pane beneath the
            // toolbar. Use separate regions so AppKit keeps its titlebar
            // material visible even when the pointer leaves the toolbar.
            window.styleMask.remove(.fullSizeContentView)
            window.toolbar?.allowsUserCustomization = false
            window.toolbar?.allowsDisplayModeCustomization = false
        }
    }
}
