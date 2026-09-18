import SwiftUI

struct RestoreSettingsSheet: View {
    @ObservedObject var model: LibraryModel
    let restore: (Set<SettingsResetSection>) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection = Set(SettingsResetSection.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore Defaults").font(.headline)
                Text("Choose which settings to reset.").foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsResetSection.allCases) { section in
                    Toggle(isOn: Binding(
                        get: { selection.contains(section) },
                        set: { if $0 { selection.insert(section) } else { selection.remove(section) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                            Text(section.detail).settingsNote()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack(spacing: 12) {
                Button("Select All") { selection = Set(SettingsResetSection.allCases) }
                    .disabled(selection.count == SettingsResetSection.allCases.count)
                Button("Deselect All") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 6) {
                Text("Dictionaries, starred words, and API keys are kept.")
                    .settingsNote()
                if historyRemovalCount > 0 {
                    Label(
                        "The latest \(LibraryModel.defaultHistoryLimit) lookups will be kept. \(historyRemovalCount) older \(historyRemovalCount == 1 ? "lookup" : "lookups") will be permanently deleted. Deselect History limit to keep all history.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("All existing history will be kept.")
                        .settingsNote()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore", role: historyRemovalCount > 0 ? .destructive : nil) {
                    restore(selection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var historyRemovalCount: Int {
        selection.contains(.history) ? max(0, model.history.count - LibraryModel.defaultHistoryLimit) : 0
    }
}
