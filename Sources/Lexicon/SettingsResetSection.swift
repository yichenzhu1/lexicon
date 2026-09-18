import Foundation

/// Restore choices are independent of the navigation tabs: keeping the history
/// limit separate lets people reset preferences without trimming their history.
enum SettingsResetSection: String, CaseIterable, Identifiable {
    case reading, history, appearance, content, translation, speech, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reading: return "Reading"
        case .history: return "History limit"
        case .appearance: return "Appearance"
        case .content: return "Dictionary pages"
        case .translation: return "Translation"
        case .speech: return "Speech"
        case .shortcuts: return "Keyboard shortcuts"
        }
    }

    @MainActor var detail: String {
        switch self {
        case .reading: return "Text size and double-click lookup"
        case .history: return "Reset limit to \(LibraryModel.defaultHistoryLimit) recent lookups"
        case .appearance: return "Theme and sidebar transparency"
        case .content: return "Network access and collapsed sections"
        case .translation: return "Provider, models, and region"
        case .speech: return "Provider and voices"
        case .shortcuts: return "All custom key combinations"
        }
    }
}
