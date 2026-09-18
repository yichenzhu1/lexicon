import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    @ViewState private var editing: ShortcutAction?
    @ViewState private var showTabShortcuts = false
    @ViewState private var message: String?

    private let left: [ShortcutAction] = [.focusSearch, .clearSearch, .previousResult, .nextResult, .openResult, .back, .forward]
    private let right: [ShortcutAction] = [.newTab, .closeTab, .newWindow, .importDictionaries, .zoomIn, .zoomOut, .actualSize, .settings]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 24, verticalSpacing: 5) {
                ForEach(0..<max(left.count, right.count), id: \.self) { index in
                    GridRow {
                        if index < left.count { row(left[index]) } else { Color.clear.frame(height: 24) }
                        row(right[index])
                    }
                }
            }
            DisclosureGroup("Switch to a specific tab", isExpanded: $showTabShortcuts) {
                Grid(horizontalSpacing: 24, verticalSpacing: 5) {
                    ForEach(0..<5, id: \.self) { index in
                        GridRow {
                            row(ShortcutAction.tabActions[index])
                            if index + 5 < ShortcutAction.tabActions.count {
                                row(ShortcutAction.tabActions[index + 5])
                            } else { Color.clear.frame(height: 24) }
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
            Text(message ?? (editing == nil
                ? "Click a shortcut to record. Restore all shortcuts in General → Restore Defaults."
                : "Press a key combination. Escape or a click elsewhere cancels."))
                .font(.system(size: 11))
                .foregroundStyle(message == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("shortcutHelp")
        }
        .frame(width: 536)
        .padding(.vertical, 24)
        .frame(width: SettingsLayout.paneWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ShortcutKeyCapture(active: editing != nil, receive: record, cancel: cancel)
        }
        .onDisappear { cancel() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        HStack(spacing: 8) {
            Text(shortTitle(action))
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 4) {
                Button {
                    if editing == action { cancel() }
                    else { message = nil; editing = action }
                } label: {
                    Text(editing == action ? "Press keys" : model.shortcuts[action].displayParts.joined(separator: "\u{2009}"))
                        .font(.system(size: editing == action ? 13 : 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 76, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 96)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(editing == action ? Color.accentColor : .clear, lineWidth: 1.5)
                }
                .accessibilityLabel("Change \(action.title) shortcut")
                .accessibilityValue(editing == action ? "Recording" : model.shortcuts[action].title)
                Button { restore(action) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(model.shortcuts[action] == action.defaultBinding)
                .opacity(model.shortcuts[action] == action.defaultBinding ? 0 : 1)
                .accessibilityHidden(model.shortcuts[action] == action.defaultBinding)
                .help("Restore default: \(action.defaultBinding.title)")
                .accessibilityLabel("Restore \(action.title) shortcut")
            }
        }
        .frame(width: 256, height: 26)
    }

    private func shortTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .clearSearch: "Clear / leave search"
        case .openResult: "Open result"
        case .closeTab: "Close tab / window"
        default: action.title
        }
    }

    private func record(_ binding: ShortcutBinding) {
        guard let editing else { return }
        if let error = model.shortcuts.validationMessage(binding, for: editing) {
            message = error
        } else {
            model.shortcuts.set(binding, for: editing)
            cancel()
        }
    }

    private func restore(_ action: ShortcutAction) {
        cancel()
        if let error = model.shortcuts.validationMessage(action.defaultBinding, for: action) {
            message = error
        } else {
            model.shortcuts.set(action.defaultBinding, for: action)
        }
    }

    private func cancel() {
        editing = nil
        message = nil
    }
}

private struct ShortcutKeyCapture: NSViewRepresentable {
    let active: Bool
    let receive: (ShortcutBinding) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> ShortcutRecordingView {
        let view = ShortcutRecordingView()
        view.install()
        return view
    }
    func updateNSView(_ view: ShortcutRecordingView, context: Context) {
        view.receive = receive
        view.cancel = cancel
        view.setRecording(active)
    }
    static func dismantleNSView(_ view: ShortcutRecordingView, coordinator: ()) { view.uninstall() }
}

/// The first-responder marker also keeps the native Close bridge from handling
/// a combination while it is being recorded. Nothing is monitored globally.
final class ShortcutRecordingView: NSView {
    var receive: ((ShortcutBinding) -> Void)?
    var cancel: (() -> Void)?
    private var active = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?
    override var acceptsFirstResponder: Bool { true }

    func setRecording(_ recording: Bool) {
        guard recording != active else { return }
        active = recording
        if recording {
            previousResponder = window?.firstResponder
            // Native buttons finish their focus handling after their action.
            // Acquire recording focus once that mouse event has completed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.window?.makeFirstResponder(self)
            }
        } else if window?.firstResponder === self {
            window?.makeFirstResponder(previousResponder)
        }
    }

    func install() {
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active, self.window?.isKeyWindow == false else { return }
                self.cancel?()
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.active else { return false }
                if event.type != .keyDown {
                    self.cancel?()
                    return false
                }
                guard self.window?.isKeyWindow == true, event.window === self.window,
                      self.window?.firstResponder === self else { return false }
                guard !event.isARepeat, let key = event.charactersIgnoringModifiers, key.count == 1 else { return true }
                let modifiers = ShortcutBinding.flags(event.modifierFlags)
                if modifiers == 0 && (key == "\u{1b}" || key == "\t") {
                    self.cancel?()
                    return key != "\t"
                }
                self.receive?(.normalized(key, modifiers: modifiers))
                return true
            }
            return handled ? nil : event
        }
    }

    func uninstall() {
        setRecording(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
