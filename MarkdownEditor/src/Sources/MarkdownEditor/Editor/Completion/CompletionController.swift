import AppKit

/// IntelliSense: asks the completion providers for items, shows them in a
/// popup that filters as the user types, and inserts the chosen item as a
/// snippet. Also routes Tab / Shift-Tab / Escape to a running
/// `SnippetSession`, since this handler runs first (priority 0).
///
/// Providers are queried synchronously on the main thread: they work on the
/// in-memory text and return in well under a millisecond, and running them
/// inline means the list is already correct when the keystroke is drawn (a
/// debounce would show stale items for a frame).
///
/// The popup's state lives in `model` (a `CompletionListModel`); the window
/// is only created when the text view is in a window, so everything here can
/// be exercised by unit tests without UI.
@MainActor
final class CompletionController: NSObject, EditorInputHandler {
    let priority = 0
    private weak var editor: EditorController?
    private let providers: [any CompletionProvider]
    private let settings: EditorSettings

    /// The open popup's state; nil while closed.
    private(set) var model: CompletionListModel?
    /// The popup was opened with ⌃Space: keep re-querying with
    /// `isExplicit: true` while it stays open, even with auto-completion off.
    private var isExplicitSession = false

    /// Text from the last `insertText` call, consumed by the next text
    /// change. Distinguishes typing (which may trigger) from paste, undo and
    /// programmatic edits (which never do).
    private var pendingTypedText: String?
    private var lastTextChange = Date.distantPast

    private lazy var popup: CompletionPopup = {
        let popup = CompletionPopup()
        popup.onSelect = { [weak self] index in self?.select(index) }
        popup.onAccept = { [weak self] index in
            self?.select(index)
            self?.accept()
        }
        return popup
    }()

    private let triggerCharacters: Set<Character>

    init(editor: EditorController, providers: [any CompletionProvider], settings: EditorSettings = .shared) {
        self.editor = editor
        self.providers = providers
        self.settings = settings
        triggerCharacters = providers.reduce(into: []) { $0.formUnion($1.triggerCharacters) }
        super.init()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSText.didEndEditingNotification, object: editor.textView)
        center.addObserver(self, selector: #selector(didScroll(_:)), name: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView)
    }

    var isShowingCompletions: Bool { model != nil }

    // MARK: Opening

    /// Opens the popup at the caret regardless of the auto-completion
    /// setting (Edit ▸ Show Completions, ⌃Space).
    func showCompletions() {
        isExplicitSession = true
        if !query(explicit: true) { isExplicitSession = false }
    }

    /// Asks the providers in order; the first non-empty result is shown.
    /// Returns false (and closes) when nobody has anything.
    @discardableResult
    private func query(explicit: Bool) -> Bool {
        guard let editor else { return false }
        let text = editor.string
        let caret = editor.selectedRange.location
        guard editor.selectedRange.length == 0, caret <= text.length else { close(); return false }

        let request = CompletionRequest(
            text: text, location: caret, context: editor.context(at: caret),
            documentURL: editor.documentURL, isExplicit: explicit
        )
        for provider in providers {
            guard let result = provider.completions(for: request), !result.items.isEmpty else { continue }
            let range = result.replacementRange
            guard range.location <= caret, NSMaxRange(range) >= caret, NSMaxRange(range) <= text.length else { continue }
            var model = CompletionListModel(result: result, caret: caret)
            model.filter(text.substring(with: NSRange(location: range.location, length: caret - range.location)))
            guard !model.isEmpty else { continue }
            self.model = model
            present()
            return true
        }
        close()
        return false
    }

    /// Re-filters for the text between the replacement start and the caret;
    /// closes when the caret left that range or nothing matches any more.
    private func refilter() {
        guard var model, let editor else { return }
        let text = editor.string
        let selection = editor.selectedRange
        guard selection.length == 0, selection.location >= model.anchor, selection.location <= text.length else {
            return close()
        }
        let typed = text.substring(with: NSRange(location: model.anchor, length: selection.location - model.anchor))
        guard !typed.contains(where: \.isNewline) else { return close() }
        if typed != model.query { model.filter(typed) }
        guard !model.isEmpty else { return close() }
        self.model = model
        present()
    }

    func close() {
        guard model != nil else { return }
        model = nil
        isExplicitSession = false
        popup.hide()
    }

    // MARK: Selection and acceptance

    func moveSelection(by delta: Int, wrapping: Bool = true) {
        guard model != nil else { return }
        if wrapping { model!.moveSelectionWrapping(by: delta) } else { model!.moveSelection(by: delta) }
        popup.updateSelection(model!.selectedIndex)
    }

    func select(_ index: Int) {
        guard model != nil else { return }
        model!.select(index)
        popup.updateSelection(model!.selectedIndex)
    }

    /// Inserts the selected item, replacing what was typed (plus any text
    /// after the caret the provider asked to replace).
    func accept() {
        guard let model, let item = model.selectedItem, let editor else { return }
        let range = model.replacementRange(caret: editor.selectedRange.location)
        close()
        guard NSMaxRange(range) <= editor.string.length else { return }
        SnippetSession.insert(item.insertText, replacing: range, in: editor, actionName: "Completion")
    }

    // MARK: Popup window

    private func present() {
        guard let model, let editor, let window = editor.textView.window else { return }
        let caretRect = editor.textView.firstRect(forCharacterRange: NSRange(location: model.anchor, length: 0), actualRange: nil)
        popup.show(model, caretRect: caretRect, parent: window, font: editor.textView.font ?? settings.font)
    }

    @objc private func focusLost(_ notification: Notification) {
        // NSTextView also posts did-end-editing after edits while it is not
        // first responder (e.g. not in a window at all), so check the actual
        // focus instead of trusting the notification.
        guard let textView = editor?.textView, let window = textView.window else { return }
        if let resigned = notification.object as? NSWindow {
            if resigned === window { close() }
        } else if window.firstResponder !== textView {
            close()
        }
    }

    @objc private func didScroll(_ notification: Notification) {
        guard model != nil else { return }
        // Typing near the edge scrolls the caret into view: follow it. Any
        // other scroll (wheel, scroller) moves the text away from the popup.
        if Date().timeIntervalSince(lastTextChange) < 0.25 { present() } else { close() }
    }

    // MARK: Character classes

    /// Characters that continue a word for auto-triggering.
    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_"
    }

    // MARK: EditorInputHandler

    func textView(_ textView: MarkdownTextView, handleKeyDown event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .control, event.keyCode == 49 || event.charactersIgnoringModifiers == " " {
            showCompletions()
            return true
        }
        return false
    }

    func textView(_ textView: MarkdownTextView, doCommandBy selector: Selector) -> Bool {
        if model != nil {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
            case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                moveSelection(by: -(CompletionPopup.maxVisibleRows - 1), wrapping: false)
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                moveSelection(by: CompletionPopup.maxVisibleRows - 1, wrapping: false)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                accept()
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                close()
            default:
                return false
            }
            return true
        }
        if let editor, let session = SnippetSession.active(in: editor) {
            switch selector {
            case #selector(NSResponder.insertTab(_:)): session.next()
            case #selector(NSResponder.insertBacktab(_:)): session.previous()
            case #selector(NSResponder.cancelOperation(_:)): session.end()
            default: return false
            }
            return true
        }
        return false
    }

    func textView(_ textView: MarkdownTextView, insertText string: String, replacementRange: NSRange) -> Bool {
        pendingTypedText = string
        // Set before the edit too: NSTextView may scroll the caret into view
        // before the text-change callback runs.
        lastTextChange = Date()
        return false
    }

    func textViewDidChangeText(_ textView: MarkdownTextView) {
        lastTextChange = Date()
        let typed = pendingTypedText
        pendingTypedText = nil
        // Captured first: a closing re-filter below resets it.
        let explicit = isExplicitSession

        guard let typed, let last = typed.last else {
            // Delete, paste, undo, programmatic edit: never opens, only
            // re-filters (Backspace widens the filter) or closes — including
            // when the deletion reached the start of the completed text
            // (Backspace over the `\\` that opened the list).
            if let model, editor?.selectedRange.location ?? 0 <= model.anchor { return close() }
            refilter()
            return
        }
        let isTrigger = triggerCharacters.contains(last)
        if model != nil, !isTrigger {
            refilter()
            if model != nil { return }
        }
        guard isTrigger || Self.isWordCharacter(last) else { return }
        guard settings.showsCompletions || explicit else { return }
        if !query(explicit: explicit) { isExplicitSession = false }
        if model != nil { isExplicitSession = explicit }
    }

    func textViewDidChangeSelection(_ textView: MarkdownTextView) {
        // Arrow keys and clicks: re-filter for the new caret, close when it
        // left the word. (During typing this runs before the text-change
        // callback; re-filtering twice is harmless.)
        refilter()
    }
}

extension EditorController {
    /// The editor's completion handler, for menu commands.
    var completionController: CompletionController? {
        inputHandlers.lazy.compactMap { $0 as? CompletionController }.first
    }

    /// Edit ▸ Show Completions.
    func showCompletions() {
        completionController?.showCompletions()
    }
}
