import MdxKit
import SwiftUI
import UniformTypeIdentifiers

struct DictionaryManagerView: View {
    @EnvironmentObject private var libraryModel: LibraryModel
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
                .disabled(libraryModel.isImporting)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if libraryModel.dictionaries.isEmpty && !libraryModel.isImporting {
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
                    ForEach(libraryModel.dictionaries) { dictionary in
                        DictionaryRow(
                            dictionary: dictionary,
                            isRemoving: libraryModel.removingDictionaryIDs.contains(dictionary.id)
                        ) {
                            dictionaryPendingRemoval = dictionary
                        }
                    }
                    .onMove { offsets, target in
                        libraryModel.moveDictionaries(fromOffsets: offsets, toOffset: target)
                    }
                }
                .listStyle(.inset)
            }

            if libraryModel.isImporting {
                Divider()
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(libraryModel.importStatus)
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
                libraryModel.removeDictionary(dictionary)
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
                libraryModel.importDictionaries(at: urls)
            }
        }
    }
}

private struct DictionaryRow: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    let dictionary: DictionaryRecord
    let isRemoving: Bool
    let requestRemoval: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { dictionary.enabled },
                set: { libraryModel.setEnabled($0, for: dictionary) }
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
