import SwiftUI

/// A compact, native preferences panel. It exposes durable reading behavior
/// without mixing in library-management actions such as importing or deleting
/// dictionaries.
struct SettingsView: View {
    @EnvironmentObject private var libraryModel: LibraryModel

    var body: some View {
        Form {
            Section("Reading") {
                LabeledContent("Entry text size") {
                    Picker("Entry text size", selection: entryZoom) {
                        ForEach(LibraryModel.zoomSteps, id: \.self) { zoom in
                            Text("\(Int((zoom * 100).rounded()))%")
                                .tag(zoom)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 120, alignment: .trailing)
                }

                Toggle(
                    "Look up words by double-clicking entry text",
                    isOn: $libraryModel.lookUpOnDoubleClick
                )
            }

            Section("Dictionary Content") {
                Picker("Network access", selection: $libraryModel.dictionaryNetworkPolicy) {
                    ForEach(LibraryModel.DictionaryNetworkPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }

                Text(libraryModel.dictionaryNetworkPolicy == .allowHTTPS
                    ? "Dictionary pages may load HTTPS images, fonts, styles, scripts, and data. Remote scripts can read the displayed entry. HTTP remains blocked."
                    : "All dictionary page resources must come from the imported dictionary files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("History") {
                LabeledContent("Keep recent lookups") {
                    Picker("Keep recent lookups", selection: historyLimit) {
                        ForEach(LibraryModel.historyLimitOptions, id: \.self) { limit in
                            Text("\(limit) records")
                                .tag(limit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(width: 120, alignment: .trailing)
                }

                Text("New words are added at the top. Opening an existing item keeps it in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        withAnimation(.smooth(duration: 0.2)) {
                            libraryModel.restoreDefaultSettings()
                        }
                    }
                }

                Text("Restores reading, network, history-limit, and folded-section preferences. Dictionaries, history, and starred words are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var entryZoom: Binding<Double> {
        Binding(
            get: { libraryModel.entryZoom },
            set: { libraryModel.setZoom($0) }
        )
    }

    private var historyLimit: Binding<Int> {
        Binding(
            get: { libraryModel.historyLimit },
            set: { libraryModel.setHistoryLimit($0) }
        )
    }
}
