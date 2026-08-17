import MdxKit
import SwiftUI
import UniformTypeIdentifiers

struct DictionaryManagerView: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var dictionaryPendingRemoval: DictionaryRecord?
    @State private var dictionaryPendingRename: DictionaryRecord?
    @State private var draftTitle = ""

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
                        "Import a .mdx file, or drag one onto the window. Companion "
                        + "files (.mdd resources, .css) in the same folder are copied "
                        + "automatically. Drag to set the display order."
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
                        } requestRename: {
                            draftTitle = dictionary.title
                            dictionaryPendingRename = dictionary
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
                importProgress
                    .padding()
            } else if let notice = libraryModel.notice {
                Divider()
                LibraryNoticeView(notice: notice) {
                    libraryModel.dismissNotice()
                }
                .padding(12)
            }
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 360, idealHeight: 460)
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
        .alert(
            "Rename Dictionary",
            isPresented: Binding(
                get: { dictionaryPendingRename != nil },
                set: { if !$0 { dictionaryPendingRename = nil } }
            ),
            presenting: dictionaryPendingRename
        ) { dictionary in
            TextField("Name", text: $draftTitle)
            Button("Cancel", role: .cancel) { dictionaryPendingRename = nil }
            Button("Rename") {
                libraryModel.rename(dictionary, to: draftTitle)
                dictionaryPendingRename = nil
            }
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { _ in
            Text("Only the name shown in Lexicon changes; the dictionary files are untouched.")
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

    private var importProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(libraryModel.importStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let fraction = libraryModel.importFraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { libraryModel.cancelImport() }
                    .buttonStyle(.borderless)
            }
            // Determinate once the entry count is known; the header supplies it.
            if let fraction = libraryModel.importFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }
}

private struct DictionaryRow: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    let dictionary: DictionaryRecord
    let isRemoving: Bool
    let requestRemoval: () -> Void
    let requestRename: () -> Void

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
            .accessibilityLabel("Enable \(dictionary.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(dictionary.title)
                    .fontWeight(.medium)
                    .foregroundStyle(dictionary.enabled ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text("\(dictionary.entryCount.formatted()) entries")
                    Text("·")
                    if dictionary.hasResources {
                        Text("\(dictionary.totalResourceCount.formatted()) resources")
                            .help(dictionary.looseResourceCount > 0
                                ? "Includes \(dictionary.looseResourceCount.formatted()) loose companion file(s), such as same-name CSS or JavaScript."
                                : "Resources indexed from MDD companion files.")
                    } else {
                        Label("No resources", systemImage: "exclamationmark.triangle")
                            .help(
                                "No MDD resources or loose companion files were found at import, "
                                + "so images, audio and stylesheets may be unavailable."
                            )
                    }
                    Text("·")
                    Text(dictionary.mdxFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .help("Moving dictionary to Trash")
            } else {
                Button(action: requestRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this dictionary")
                .accessibilityLabel("Rename \(dictionary.title)")

                Button(action: requestRemoval) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Move this dictionary to Trash")
                .accessibilityLabel("Move \(dictionary.title) to Trash")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Rename…", action: requestRename)
            Button("Move to Trash", role: .destructive, action: requestRemoval)
        }
    }
}
