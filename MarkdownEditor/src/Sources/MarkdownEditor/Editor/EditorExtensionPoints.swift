import AppKit

// The editor core (`EditorController`, `MarkdownTextView`) knows nothing about
// Markdown. Everything language-specific plugs in through the protocols in
// this file:
//
// - `EditorHighlighter`      colors the text and answers "what am I in?"
// - `EditorInputHandler`     intercepts keys, typed text, paste and drop
// - `CompletionProvider`     supplies IntelliSense items for one language
// - `EditorDiagnostic`       red squiggles plus a message in the status bar

// MARK: - Context

/// What kind of source the caret is in. Computed by the highlighter, which
/// already tracks fences and math while coloring; completion providers and
/// editing helpers use it to stay out of each other's way.
enum EditorContext: Equatable, Sendable {
    /// Ordinary Markdown prose (including headings, lists, tables, quotes).
    case markdown
    /// Inside a `` `code span` ``.
    case inlineCode
    /// Inside a fenced or indented code block. `language` is the first word
    /// of the fence's info string, lowercased; nil for none.
    case codeBlock(language: String?)
    /// The info-string line of a fence (right after the opening backticks).
    case fenceInfo
    /// Between `$ … $`.
    case inlineMath
    /// Inside a `$$ … $$` block (or a ` ```math ` fence).
    case displayMath
    /// Inside a ` ```mermaid ` fence.
    case mermaid
    /// Inside YAML front matter (`---` … `---` at the top of the file).
    case frontMatter
    /// Inside an HTML comment `<!-- … -->`.
    case htmlComment

    /// True for the two math contexts.
    var isMath: Bool { self == .inlineMath || self == .displayMath }
}

// MARK: - Highlighting

/// Colors Markdown source in the editor's text storage.
@MainActor
protocol EditorHighlighter: AnyObject {
    /// Called from `NSTextStorageDelegate.textStorage(_:didProcessEditing:…)`
    /// after every edit. Re-color as little as possible: at least the edited
    /// paragraphs, more only when block structure (fences, `$$`) changed.
    /// Only change attributes here — never characters.
    func textStorage(_ textStorage: NSTextStorage, didEditRange editedRange: NSRange, changeInLength delta: Int)

    /// Re-colors everything (new text loaded, font or appearance changed).
    func highlightAll(_ textStorage: NSTextStorage)

    /// The context at a UTF-16 offset in `text`.
    func context(at location: Int, in text: NSString) -> EditorContext

    /// The font the highlighter uses as base (headings may derive from it).
    var baseFont: NSFont { get set }
}

// MARK: - Input interception

/// Gets the first chance at keyboard input, typed text, paste and drop.
///
/// Handlers are asked in ascending `priority` order; the first one that
/// returns `true` consumes the event. Suggested priorities: completion popup
/// 0, snippet placeholders 10, table formatting 20, list/indent/pair
/// assistance 30, image paste/drop 40.
@MainActor
protocol EditorInputHandler: AnyObject {
    var priority: Int { get }

    /// Raw key events, before key bindings run. Only needed for keys that are
    /// not commands (the completion popup uses it for ⌃Space).
    func textView(_ textView: MarkdownTextView, handleKeyDown event: NSEvent) -> Bool

    /// Key-binding commands such as `insertNewline(_:)`, `insertTab(_:)`,
    /// `insertBacktab(_:)`, `cancelOperation(_:)`, `moveUp(_:)`, `moveDown(_:)`.
    func textView(_ textView: MarkdownTextView, doCommandBy selector: Selector) -> Bool

    /// Typed text (one keystroke or an IME commit). Return `true` after making
    /// the edit yourself (e.g. inserting a closing pair).
    func textView(_ textView: MarkdownTextView, insertText string: String, replacementRange: NSRange) -> Bool

    /// Paste. Return `true` after handling the pasteboard yourself.
    func textView(_ textView: MarkdownTextView, paste pasteboard: NSPasteboard) -> Bool

    /// Drop of files or images onto the editor at character `location`.
    func textView(_ textView: MarkdownTextView, drop pasteboard: NSPasteboard, at location: Int) -> Bool

    /// The text or selection changed (after the edit, from any source).
    func textViewDidChangeSelection(_ textView: MarkdownTextView)
    func textViewDidChangeText(_ textView: MarkdownTextView)
}

extension EditorInputHandler {
    func textView(_ textView: MarkdownTextView, handleKeyDown event: NSEvent) -> Bool { false }
    func textView(_ textView: MarkdownTextView, doCommandBy selector: Selector) -> Bool { false }
    func textView(_ textView: MarkdownTextView, insertText string: String, replacementRange: NSRange) -> Bool { false }
    func textView(_ textView: MarkdownTextView, paste pasteboard: NSPasteboard) -> Bool { false }
    func textView(_ textView: MarkdownTextView, drop pasteboard: NSPasteboard, at location: Int) -> Bool { false }
    func textViewDidChangeSelection(_ textView: MarkdownTextView) {}
    func textViewDidChangeText(_ textView: MarkdownTextView) {}
}

// MARK: - Completion (IntelliSense)

enum CompletionItemKind: Sendable {
    case keyword
    case snippet
    case command       // LaTeX \command
    case environment   // LaTeX \begin{…}
    case symbol        // Greek letters, operators, arrows
    case heading       // link target inside this document
    case reference     // [ref] link definitions
    case file          // paths for links and images
    case language      // fence info strings
    case diagram       // mermaid diagram types
    case identifier    // mermaid node ids / participants

    var systemImage: String {
        switch self {
        case .keyword: "textformat"
        case .snippet: "text.badge.plus"
        case .command: "function"
        case .environment: "curlybraces.square"
        case .symbol: "sum"
        case .heading: "number"
        case .reference: "link"
        case .file: "doc"
        case .language: "chevron.left.forwardslash.chevron.right"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .identifier: "tag"
        }
    }
}

struct CompletionItem: Identifiable, Sendable {
    let id = UUID()
    /// Shown in the list.
    var label: String
    /// Short grey text right of the label (e.g. "Greek letter", "snippet").
    var detail: String = ""
    /// Longer explanation shown in the side panel; plain text.
    var documentation: String = ""
    var kind: CompletionItemKind
    /// Text that replaces `CompletionResult.replacementRange`. May contain
    /// snippet placeholders: `${1:default}`, `${2}`, and `$0` for the final
    /// caret position. A literal `$` must be written `\$`.
    var insertText: String
    /// Matched against what the user typed; defaults to `label`.
    var filterText: String?
    /// Higher sorts first among equally good matches.
    var sortPriority: Int = 0
}

struct CompletionRequest {
    /// The whole document.
    let text: NSString
    /// Caret position (UTF-16 offset).
    let location: Int
    let context: EditorContext
    /// The saved document's location, for resolving relative paths; nil for
    /// an untitled document.
    let documentURL: URL?
    /// True when the user asked explicitly (⌃Space); providers may then
    /// offer items even without a trigger character.
    let isExplicit: Bool
}

struct CompletionResult {
    /// The range the chosen item replaces — typically the partial word
    /// before the caret (`\alp` for `\alpha`). Also what the popup filters by.
    var replacementRange: NSRange
    var items: [CompletionItem]
}

/// Supplies completions for one language. Asked in order; the first non-nil
/// result wins.
@MainActor
protocol CompletionProvider: AnyObject {
    /// Characters that open the popup automatically when typed (e.g. `\` for
    /// LaTeX). Typing a letter that continues a word also re-queries.
    var triggerCharacters: Set<Character> { get }

    /// Return nil when the provider has nothing for this position.
    func completions(for request: CompletionRequest) -> CompletionResult?
}

// MARK: - Diagnostics

struct EditorDiagnostic: Equatable, Sendable {
    enum Severity: Sendable { case error, warning }

    /// UTF-16 range in the editor text that is underlined.
    var range: NSRange
    var message: String
    var severity: Severity = .error
}
