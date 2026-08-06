import MdxKit
import SwiftUI
import UniformTypeIdentifiers

struct DictionaryManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var dictionaryPendingRemoval: DictionaryRecord?

    private var mdxType: UTType {
        UTType(filenameExtension: "mdx") ?? .data
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dictionaries")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showImporter = true
                } label: {
                    Label("Import .mdx…", systemImage: "plus")
                }
                .disabled(appState.isImporting)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if appState.dictionaries.isEmpty && !appState.isImporting {
                ContentUnavailableView(
                    "No dictionaries",
                    systemImage: "books.vertical",
                    description: Text(
                        "Import a .mdx file. Companion files (.mdd resources, .css) "
                        + "in the same folder are copied automatically. "
                        + "Drag to set the display order."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.dictionaries) { dictionary in
                        DictionaryRow(
                            dictionary: dictionary,
                            isRemoving: appState.removingDictionaryIDs.contains(dictionary.id)
                        ) {
                            dictionaryPendingRemoval = dictionary
                        }
                    }
                    .onMove { offsets, target in
                        appState.moveDictionaries(fromOffsets: offsets, toOffset: target)
                    }
                }
                .listStyle(.inset)
            }

            if appState.isImporting {
                Divider()
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.importStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding()
            }
        }
        .frame(width: 520, height: 420)
        .alert(
            "Move Dictionary to Trash?",
            isPresented: Binding(
                get: { dictionaryPendingRemoval != nil },
                set: { if !$0 { dictionaryPendingRemoval = nil } }
            ),
            presenting: dictionaryPendingRemoval
        ) { dictionary in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                dictionaryPendingRemoval = nil
                appState.removeDictionary(dictionary)
            }
        } message: { dictionary in
            Text(
                "“\(dictionary.title)” and all of its dictionary files will be "
                + "moved to the macOS Trash. You can recover them from Trash until it is emptied."
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [mdxType],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                appState.importDictionaries(at: urls)
            }
        }
    }
}

private struct DictionaryRow: View {
    @EnvironmentObject private var appState: AppState
    let dictionary: DictionaryRecord
    let isRemoving: Bool
    let requestRemoval: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { dictionary.enabled },
                set: { appState.setEnabled($0, for: dictionary) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(isRemoving)

            VStack(alignment: .leading, spacing: 2) {
                Text(dictionary.title)
                    .fontWeight(.medium)
                    .foregroundStyle(dictionary.enabled ? .primary : .secondary)
                Text("\(dictionary.entryCount.formatted()) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .help("Moving dictionary to Trash")
            } else {
                Button(action: requestRemoval) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Move this dictionary to Trash")
            }
        }
        .padding(.vertical, 3)
    }
}
