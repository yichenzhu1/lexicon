import AVFoundation
import AppKit
import Combine
import Foundation
import MdxKit
import SwiftUI

/// State that belongs to the whole app rather than to one window: the open
/// dictionary library, the imported dictionary list, and the history and
/// starred-word files.
///
/// Exactly one of these exists. Giving each window its own would mean a second
/// SQLite connection, duplicate memory-mapped dictionary files and block
/// caches, and two windows writing `history.json` over each other.
@MainActor
final class LibraryModel: ObservableObject {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum DictionaryNetworkPolicy: String, CaseIterable, Identifiable {
        case offlineOnly
        case allowHTTPS

        var id: String { rawValue }
        var title: String {
            switch self {
            case .offlineOnly: return "Offline only"
            case .allowHTTPS: return "Allow HTTPS content"
            }
        }
    }
    @Published private(set) var dictionaries: [DictionaryRecord] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var starred: [String] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    /// nil while the current stage is not countable, so the UI can fall back to
    /// an indeterminate spinner.
    @Published var importFraction: Double?
    @Published var errorMessage: String?
    @Published private(set) var notice: Notice?
    @Published private(set) var removingDictionaryIDs: Set<Int64> = []
    /// Bumped whenever rendered content may change (dictionary set edited).
    @Published private(set) var contentVersion = 0
    @Published var dictionaryNetworkPolicy: DictionaryNetworkPolicy = LibraryModel.storedNetworkPolicy() {
        didSet {
            Self.settings.set(dictionaryNetworkPolicy.rawValue, forKey: Self.networkPolicyKey)
            if dictionaryNetworkPolicy != oldValue { contentVersion += 1 }
        }
    }

    let library: DictionaryLibrary?

    private var audioPlayer: AVAudioPlayer?
    private let importQueue = DispatchQueue(label: "lexicon.import", qos: .userInitiated)
    private var importCancellation: ImportCancellationToken?
    /// Resolved headwords, keyed by normalized key. `displayWord` is called
    /// from view bodies for every history row, tab and starred card, so an
    /// uncached lookup ran a SQL query per row on every keystroke.
    private var displayWordCache: [String: String] = [:]

    nonisolated static var defaultRoot: URL {
        // Override for testing against a disposable library.
        if let override = ProcessInfo.processInfo.environment["LEXICON_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexicon", isDirectory: true)
    }

    init(rootURL: URL = LibraryModel.defaultRoot) {
        do {
            library = try DictionaryLibrary(rootURL: rootURL)
        } catch {
            library = nil
            errorMessage = "Could not open the dictionary library: \(error.localizedDescription)"
        }
        loadSidecarLists()
        reloadDictionaries()
        if let warnings = library?.startupWarnings, !warnings.isEmpty {
            notice = Notice(title: "Library notice", message: warnings.joined(separator: "\n"))
        }
    }

    // MARK: - Dictionaries

    func reloadDictionaries() {
        guard let library else { return }
        do {
            dictionaries = try library.dictionaries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDictionaries(at urls: [URL]) {
        guard let library else { return }
        isImporting = true
        let cancellation = ImportCancellationToken()
        importCancellation = cancellation
        importStatus = "Starting import…"
        importFraction = nil
        notice = nil
        importQueue.async { [weak self] in
            var failures: [String] = []
            var withoutResources: [String] = []
            var importWarnings: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let name = url.deletingPathExtension().lastPathComponent
                    let record = try library.importDictionary(from: url, cancellation: cancellation) { update in
                        if update.stage.hasPrefix("Warning:") {
                            importWarnings.append(
                                "\(name): " + String(update.stage.dropFirst("Warning: ".count))
                            )
                        }
                        let text = update.total > 0
                            ? "\(name): \(update.stage) \(update.completed.formatted()) of \(update.total.formatted())"
                            : "\(name): \(update.stage)"
                        Task { @MainActor [weak self] in
                            self?.importStatus = text
                            self?.importFraction = update.fraction
                        }
                    }
                    if !record.hasResources {
                        withoutResources.append(record.title)
                    }
                } catch {
                    if !(error is CancellationError) {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if cancellation.isCancelled { break }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isImporting = false
                self.importCancellation = nil
                self.importStatus = ""
                self.importFraction = nil
                var warnings: [String] = []
                if !failures.isEmpty {
                    self.errorMessage = "Import failed for:\n" + failures.joined(separator: "\n")
                }
                if !withoutResources.isEmpty {
                    // Silent resource loss is the most common import mistake:
                    // the .mdd sits somewhere else and only images go missing.
                    warnings.append(
                        "No images, audio or stylesheets were found for "
                        + withoutResources.map { "“\($0)”" }.joined(separator: ", ")
                        + ". Keep the .mdd files next to the .mdx and import again "
                        + "if the entries look incomplete."
                    )
                }
                if !importWarnings.isEmpty {
                    warnings.append("Some optional files were not found:\n" + importWarnings.joined(separator: "\n"))
                }
                if !warnings.isEmpty {
                    self.notice = Notice(
                        title: "Import completed with warnings",
                        message: warnings.joined(separator: "\n\n")
                    )
                }
                self.dictionariesChanged()
            }
        }
    }

    func cancelImport() {
        importCancellation?.cancel()
        importStatus = "Cancelling import…"
        importFraction = nil
    }

    func dismissNotice() {
        notice = nil
    }

    func rename(_ record: DictionaryRecord, to title: String) {
        guard let library else { return }
        do {
            try library.setTitle(title, for: record)
        } catch {
            errorMessage = error.localizedDescription
        }
        dictionariesChanged()
    }

    func removeDictionary(_ record: DictionaryRecord) {
        guard let library, !removingDictionaryIDs.contains(record.id) else { return }
        let folderURL = library.folderURL(for: record)
        removingDictionaryIDs.insert(record.id)

        // A stale database row can outlive a manually removed folder. In that
        // case there is nothing to recycle, so only unregister the record.
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            finishRemovingDictionary(record, filesWereRecycled: false)
            return
        }

        NSWorkspace.shared.recycle([folderURL]) { [weak self] _, recycleError in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let recycleError {
                    self.removingDictionaryIDs.remove(record.id)
                    self.errorMessage = "Could not move “\(record.title)” to Trash: "
                        + recycleError.localizedDescription
                    return
                }
                self.finishRemovingDictionary(record, filesWereRecycled: true)
            }
        }
    }

    private func finishRemovingDictionary(
        _ record: DictionaryRecord, filesWereRecycled: Bool
    ) {
        guard let library else {
            removingDictionaryIDs.remove(record.id)
            return
        }
        do {
            try library.unregisterDictionary(record)
        } catch {
            if filesWereRecycled {
                errorMessage = "“\(record.title)” was moved to Trash, but Lexicon "
                    + "could not remove it from the library index: \(error.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
        removingDictionaryIDs.remove(record.id)
        dictionariesChanged()
    }

    func setEnabled(_ enabled: Bool, for record: DictionaryRecord) {
        guard let library else { return }
        do {
            try library.setEnabled(enabled, for: record)
        } catch {
            errorMessage = error.localizedDescription
        }
        dictionariesChanged()
    }

    func moveDictionaries(fromOffsets: IndexSet, toOffset: Int) {
        guard let library else { return }
        var reordered = dictionaries
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        do {
            try library.reorder(reordered)
        } catch {
            errorMessage = error.localizedDescription
        }
        dictionariesChanged()
    }

    /// Invalidates rendered content everywhere. Every window observes this
    /// model, so all of them re-render.
    private func dictionariesChanged() {
        displayWordCache.removeAll()
        reloadDictionaries()
        contentVersion += 1
    }

    func reloadRenderedContent() {
        contentVersion += 1
    }

    // MARK: - Reading preferences

    /// Settings live in a named suite so they are the same whether the app runs
    /// as `build/Lexicon.app` or as the bare `swift build` executable, which
    /// has no bundle identifier and would otherwise get its own domain.
    /// The suite is derived from `CFBundleIdentifier` in `scripts/make_app.sh`.
    static let settings: UserDefaults = {
        let current = UserDefaults(suiteName: "com.yichenzhu.Lexicon.settings") ?? .standard

        // Preserve preferences created before the app adopted its permanent
        // reverse-DNS identifier. Dictionary files, history and starred words
        // already live in Application Support/Lexicon and need no migration.
        if !current.bool(forKey: settingsMigrationKey),
           let legacy = UserDefaults(suiteName: "org.lexicon.Lexicon.settings") {
            for key in [zoomKey, lookUpKey, collapsedKey, historyLimitKey, networkPolicyKey]
            where current.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    current.set(value, forKey: key)
                }
            }
            current.set(true, forKey: settingsMigrationKey)
        }
        return current
    }()

    /// Zoom applied to rendered entries, shared by every tab and window and
    /// remembered across launches.
    @Published private(set) var entryZoom: Double = LibraryModel.storedZoom()
    /// Whether double-clicking a word inside an entry looks it up. Off means
    /// double-click keeps its ordinary select-a-word-to-copy behavior.
    @Published var lookUpOnDoubleClick: Bool = LibraryModel.storedLookUpOnDoubleClick() {
        didSet {
            Self.settings.set(lookUpOnDoubleClick, forKey: Self.lookUpKey)
        }
    }

    /// Maximum number of unique lookup records kept in browser-style history.
    @Published private(set) var historyLimit: Int = LibraryModel.storedHistoryLimit()

    /// Dictionaries the user collapsed on a results page. Remembered across
    /// lookups so a dictionary you always skip stays folded away.
    ///
    /// Deliberately does not bump `contentVersion`: collapsing a card must not
    /// reload the page out from under the click that caused it.
    @Published private(set) var collapsedDictionaries: Set<String> = Set(
        (LibraryModel.settings.stringArray(forKey: LibraryModel.collapsedKey) ?? [])
            .map { $0.lowercased() }
    )

    func setDictionary(_ uuid: String, collapsed: Bool) {
        let uuid = uuid.lowercased()
        let changed = collapsed
            ? collapsedDictionaries.insert(uuid).inserted
            : collapsedDictionaries.remove(uuid) != nil
        guard changed else { return }
        Self.settings.set(Array(collapsedDictionaries), forKey: Self.collapsedKey)
    }

    private static let zoomKey = "entryZoom"
    private static let lookUpKey = "lookUpOnDoubleClick"
    private static let collapsedKey = "collapsedDictionaries"
    private static let historyLimitKey = "historyLimit"
    private static let networkPolicyKey = "dictionaryNetworkPolicy"
    private static let settingsMigrationKey = "migratedFromOrgLexiconSettings"
    private static let sidebarWidthKey = "sidebarWidth"
    private static let sidebarVisibleKey = "sidebarVisible"
    private static let sidebarModeKey = "sidebarMode"
    static let defaultSidebarWidth: Double = 248

    /// Sidebar layout is window chrome, not library state, so it lives in the
    /// settings suite and applies app-wide, like a browser remembering its
    /// sidebar. Reads are one-shot at window creation; writes happen on change.
    static var storedSidebarWidth: Double {
        let stored = settings.double(forKey: sidebarWidthKey)
        return stored >= 200 && stored <= 380 ? stored : defaultSidebarWidth
    }

    static var storedSidebarVisible: Bool {
        settings.object(forKey: sidebarVisibleKey) as? Bool ?? true
    }

    static var storedSidebarMode: String {
        settings.string(forKey: sidebarModeKey) ?? "lexicon"
    }

    static func storeSidebarLayout(width: Double, visible: Bool, mode: String) {
        settings.set(width, forKey: sidebarWidthKey)
        settings.set(visible, forKey: sidebarVisibleKey)
        settings.set(mode, forKey: sidebarModeKey)
    }
    static let defaultHistoryLimit = 100
    static let historyLimitOptions = [25, 50, 100, 200, 500]
    /// Discrete stops, like a browser's zoom menu.
    static let zoomSteps: [Double] = [
        0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
    ]

    private static func storedZoom() -> Double {
        let stored = settings.double(forKey: zoomKey)
        guard stored > 0 else { return 1.0 }
        return min(max(stored, zoomSteps[0]), zoomSteps[zoomSteps.count - 1])
    }

    private static func storedLookUpOnDoubleClick() -> Bool {
        // Default on: looking a word up is what this app is for.
        settings.object(forKey: lookUpKey) as? Bool ?? true
    }

    private static func storedHistoryLimit() -> Int {
        let stored = settings.integer(forKey: historyLimitKey)
        return historyLimitOptions.contains(stored) ? stored : defaultHistoryLimit
    }

    private static func storedNetworkPolicy() -> DictionaryNetworkPolicy {
        guard let raw = settings.string(forKey: networkPolicyKey) else { return .allowHTTPS }
        return DictionaryNetworkPolicy(rawValue: raw) ?? .allowHTTPS
    }

    var canZoomIn: Bool { entryZoom < Self.zoomSteps[Self.zoomSteps.count - 1] }
    var canZoomOut: Bool { entryZoom > Self.zoomSteps[0] }
    /// "125%" for the View menu.
    var zoomDescription: String { "\(Int((entryZoom * 100).rounded()))%" }

    func zoomIn() {
        setZoom(Self.zoomSteps.first { $0 > entryZoom + 0.001 } ?? entryZoom)
    }

    func zoomOut() {
        setZoom(Self.zoomSteps.last { $0 < entryZoom - 0.001 } ?? entryZoom)
    }

    func resetZoom() {
        setZoom(1.0)
    }

    func setZoom(_ value: Double) {
        guard value != entryZoom else { return }
        entryZoom = value
        Self.settings.set(value, forKey: Self.zoomKey)
    }

    func setHistoryLimit(_ value: Int) {
        guard Self.historyLimitOptions.contains(value), value != historyLimit else { return }
        historyLimit = value
        Self.settings.set(value, forKey: Self.historyLimitKey)
        trimHistoryToLimit()
    }

    func restoreDefaultSettings() {
        setZoom(1.0)
        lookUpOnDoubleClick = true
        setHistoryLimit(Self.defaultHistoryLimit)
        dictionaryNetworkPolicy = .allowHTTPS
        if !collapsedDictionaries.isEmpty {
            collapsedDictionaries.removeAll()
            Self.settings.removeObject(forKey: Self.collapsedKey)
        }
    }

    // MARK: - Headword display

    /// Headword with original casing/diacritics for a normalized key.
    func displayWord(for normalizedKey: String?) -> String? {
        guard let normalizedKey else { return nil }
        if let cached = displayWordCache[normalizedKey] { return cached }
        let resolved = try? library?.entries(forNormalizedKey: normalizedKey).first?.key
        // Cache the fallback too, so an unknown word is not re-queried on
        // every render pass.
        let display = (resolved ?? nil) ?? normalizedKey
        displayWordCache[normalizedKey] = display
        return display
    }

    // MARK: - History & starred

    private var historyURL: URL? {
        library?.rootURL.appendingPathComponent("history.json")
    }
    private var starredURL: URL? {
        library?.rootURL.appendingPathComponent("starred.json")
    }

    private func loadSidecarLists() {
        func load(_ url: URL?) -> [String] {
            guard let url, let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return list
        }
        let storedHistory = load(historyURL).map(DictionaryLibrary.normalizeKey).filter { !$0.isEmpty }
        var seenHistory = Set<String>()
        let uniqueHistory = storedHistory.filter { seenHistory.insert($0).inserted }
        history = Array(uniqueHistory.prefix(historyLimit))
        if history != storedHistory {
            save(history, to: historyURL)
        }
        let storedStarred = load(starredURL).map(DictionaryLibrary.normalizeKey).filter { !$0.isEmpty }
        var seenStarred = Set<String>()
        starred = storedStarred.filter { seenStarred.insert($0).inserted }
        if starred != storedStarred { save(starred, to: starredURL) }
    }

    private func save(_ list: [String], to url: URL?) {
        guard let url else { return }
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Could not save your Lexicon data: \(error.localizedDescription)"
        }
    }

    func recordHistory(_ word: String) {
        // Browser-style history: new unique lookups stack at the top, while
        // revisiting an existing entry never changes its established position.
        guard !history.contains(word) else { return }
        history.insert(word, at: 0)
        trimHistoryToLimit()
        save(history, to: historyURL)
    }

    private func trimHistoryToLimit() {
        guard history.count > historyLimit else { return }
        history.removeLast(history.count - historyLimit)
        save(history, to: historyURL)
    }

    func removeFromHistory(_ word: String) {
        history.removeAll { $0 == word }
        save(history, to: historyURL)
    }

    func clearHistory() {
        history = []
        save(history, to: historyURL)
    }

    func isStarred(_ word: String) -> Bool {
        starred.contains(word)
    }

    func toggleStar(_ word: String) {
        if starred.contains(word) {
            starred.removeAll { $0 == word }
        } else {
            starred.insert(word, at: 0)
        }
        save(starred, to: starredURL)
    }

    // MARK: - Audio

    func playAudio(path: String, dictionaryUUID: String) {
        guard let library else { return }
        do {
            guard let resource = try library.resource(path: path, dictionaryUUID: dictionaryUUID) else {
                errorMessage = "Audio resource not found: \(path)"
                return
            }
            audioPlayer = try AVAudioPlayer(data: resource.data)
            audioPlayer?.play()
        } catch {
            errorMessage = "Could not play this dictionary audio: \(error.localizedDescription)"
        }
    }
}
