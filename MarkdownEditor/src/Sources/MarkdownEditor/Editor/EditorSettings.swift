import AppKit
import Observation

/// How a document window lays out editor and preview.
enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case editor
    case split
    case preview

    var id: Self { self }

    var title: String {
        switch self {
        case .editor: "Editor Only"
        case .split: "Editor and Preview"
        case .preview: "Preview Only"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: "doc.plaintext"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}

enum SplitOrientation: String, CaseIterable, Identifiable, Sendable {
    case sideBySide
    case stacked

    var id: Self { self }

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .stacked: "Stacked"
        }
    }
}

/// App-wide editor preferences, persisted in `UserDefaults`.
///
/// Every window's editor observes this one instance, so a change in the
/// Settings window (or a View-menu toggle) applies everywhere at once.
@MainActor
@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 40
    static let defaultFontSize: CGFloat = 13

    /// Empty means the system monospaced font.
    var fontName: String { didSet { store(fontName, "fontName") } }
    var fontSize: CGFloat { didSet { store(Double(fontSize), "fontSize") } }
    var tabWidth: Int { didSet { store(tabWidth, "tabWidth") } }
    var indentWithSpaces: Bool { didSet { store(indentWithSpaces, "indentWithSpaces") } }
    var wrapsLines: Bool { didSet { store(wrapsLines, "wrapsLines") } }
    var showsLineNumbers: Bool { didSet { store(showsLineNumbers, "showsLineNumbers") } }
    var showsInvisibles: Bool { didSet { store(showsInvisibles, "showsInvisibles") } }
    var highlightsCurrentLine: Bool { didSet { store(highlightsCurrentLine, "highlightsCurrentLine") } }
    var showsStatusBar: Bool { didSet { store(showsStatusBar, "showsStatusBar") } }
    var autoPairs: Bool { didSet { store(autoPairs, "autoPairs") } }
    /// Renumber ordered lists after list edits (Return, line moves, Tab…).
    /// When off, only Format ▸ Renumber List touches the numbers, for
    /// people who number by hand.
    var renumbersLists: Bool { didSet { store(renumbersLists, "renumbersLists") } }
    var smartQuotes: Bool { didSet { store(smartQuotes, "smartQuotes") } }
    var spellChecking: Bool { didSet { store(spellChecking, "spellChecking") } }
    var showsCompletions: Bool { didSet { store(showsCompletions, "showsCompletions") } }
    var syncScrolling: Bool { didSet { store(syncScrolling, "syncScrolling") } }
    var defaultViewMode: ViewMode { didSet { store(defaultViewMode.rawValue, "defaultViewMode") } }
    var splitOrientation: SplitOrientation { didSet { store(splitOrientation.rawValue, "splitOrientation") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T {
            defaults.object(forKey: "editor.\(key)") as? T ?? fallback
        }
        fontName = value("fontName", "")
        fontSize = CGFloat(value("fontSize", Double(Self.defaultFontSize)))
        tabWidth = value("tabWidth", 4)
        indentWithSpaces = value("indentWithSpaces", true)
        wrapsLines = value("wrapsLines", true)
        showsLineNumbers = value("showsLineNumbers", true)
        showsInvisibles = value("showsInvisibles", false)
        highlightsCurrentLine = value("highlightsCurrentLine", true)
        showsStatusBar = value("showsStatusBar", true)
        autoPairs = value("autoPairs", true)
        renumbersLists = value("renumbersLists", true)
        smartQuotes = value("smartQuotes", false)
        spellChecking = value("spellChecking", false)
        showsCompletions = value("showsCompletions", true)
        syncScrolling = value("syncScrolling", true)
        defaultViewMode = ViewMode(rawValue: value("defaultViewMode", "")) ?? .split
        splitOrientation = SplitOrientation(rawValue: value("splitOrientation", "")) ?? .sideBySide
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "editor.\(key)")
    }

    /// The editor font; falls back to the system monospaced font when the
    /// configured family is missing.
    var font: NSFont {
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: fontSize) {
            return font
        }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// One indentation step as inserted by Tab.
    var indentUnit: String {
        indentWithSpaces ? String(repeating: " ", count: max(1, tabWidth)) : "\t"
    }

    /// Restores every preference to its default (Settings ▸ Reset to
    /// Defaults). The values match the fallbacks in `init`.
    func resetToDefaults() {
        fontName = ""
        fontSize = Self.defaultFontSize
        tabWidth = 4
        indentWithSpaces = true
        wrapsLines = true
        showsLineNumbers = true
        showsInvisibles = false
        highlightsCurrentLine = true
        showsStatusBar = true
        autoPairs = true
        renumbersLists = true
        smartQuotes = false
        spellChecking = false
        showsCompletions = true
        syncScrolling = true
        defaultViewMode = .split
        splitOrientation = .sideBySide
    }

    func zoomIn() { fontSize = min(Self.maxFontSize, fontSize + 1) }
    func zoomOut() { fontSize = max(Self.minFontSize, fontSize - 1) }
    func resetZoom() { fontSize = Self.defaultFontSize }
}
