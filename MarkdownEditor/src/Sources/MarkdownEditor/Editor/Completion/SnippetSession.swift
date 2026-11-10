import AppKit

/// Tab-stop navigation after a snippet was inserted.
///
/// `SnippetSession.insert(_:replacing:in:)` inserts a snippet (see `Snippet`
/// for the syntax) as one undo step, selects placeholder 1 and keeps the
/// session alive while the user fills in the placeholders: Tab moves to the
/// next one, Shift-Tab to the previous one; Escape, reaching `$0`, or moving
/// the caret outside every placeholder ends it.
///
/// The session follows edits through `NSTextStorage`'s will-process-editing
/// notification, which reports every character change (typing, paste, undo,
/// edits by other handlers) with its exact range — so placeholder offsets stay
/// right without anyone having to tell the session about edits. "Will", not
/// "did": by the time of did-process-editing the highlighter has re-colored
/// whole paragraphs and `editedRange` has grown to cover them.
///
/// Key handling is not done here: `CompletionController` (input-handler
/// priority 0) forwards Tab, Shift-Tab and Escape to `SnippetSession.active(in:)`
/// so that snippets inserted by any feature get navigation.
@MainActor
final class SnippetSession: NSObject {
    /// One tab stop: every range of one placeholder index (several when the
    /// snippet mirrors an index; only the first is selected, the others are
    /// tracked but not synchronized).
    struct TabStop: Equatable {
        var index: Int
        var ranges: [NSRange]
    }

    private(set) weak var editor: EditorController?
    /// In navigation order (1, 2, …, then 0).
    private(set) var tabStops: [TabStop]
    /// Position in `tabStops` of the active placeholder.
    private(set) var current = 0
    private(set) var isActive = true

    /// Sessions by editor. A static table rather than a property on
    /// `EditorController` so the editor core needs no snippet knowledge.
    private static var sessions: [ObjectIdentifier: SnippetSession] = [:]

    /// The running session in `editor`, if any.
    static func active(in editor: EditorController) -> SnippetSession? {
        guard let session = sessions[ObjectIdentifier(editor)], session.editor === editor, session.isActive else {
            return nil
        }
        return session
    }

    /// Replaces `range` with the parsed snippet as one undo step, preserving
    /// the line's indentation on continuation lines, and starts a session when
    /// the snippet has numbered tab stops. Returns the session (nil when the
    /// snippet had none, in which case the caret is placed at `$0` or the end).
    @discardableResult
    static func insert(_ snippet: String, replacing range: NSRange, in editor: EditorController, actionName: String = "Insert Completion") -> SnippetSession? {
        active(in: editor)?.end()

        let text = editor.string
        let lineStart = text.lineRange(for: NSRange(location: min(range.location, text.length), length: 0)).location
        var indentEnd = lineStart
        while indentEnd < range.location, indentEnd < text.length {
            let c = text.character(at: indentEnd)
            guard c == 0x20 || c == 0x09 else { break }
            indentEnd += 1
        }
        let indentation = text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))

        let parsed = Snippet(parsing: snippet, indentation: indentation)
        let base = range.location
        let insertedLength = (parsed.text as NSString).length

        var stops: [TabStop] = parsed.tabStopOrder.map { index in
            TabStop(index: index, ranges: parsed.placeholders
                .filter { $0.index == index }
                .map { NSRange(location: base + $0.range.location, length: $0.range.length) })
        }
        // No explicit `$0`: the final stop is the end of the inserted text.
        if let last = stops.indices.last, stops[last].ranges.isEmpty {
            stops[last].ranges = [NSRange(location: base + insertedLength, length: 0)]
        }
        let firstSelection = stops[0].ranges[0]

        // Typing right before must not merge with this edit in one undo step.
        editor.textView.breakUndoCoalescing()
        editor.performEdit(actionName: actionName) {
            editor.replaceCharacters(in: range, with: parsed.text, selecting: firstSelection)
        }
        editor.textView.breakUndoCoalescing()

        guard parsed.hasTabStops else { return nil }
        let session = SnippetSession(editor: editor, tabStops: stops)
        sessions[ObjectIdentifier(editor)] = session
        return session
    }

    private init(editor: EditorController, tabStops: [TabStop]) {
        self.editor = editor
        self.tabStops = tabStops
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageWillProcessEditing(_:)),
            name: NSTextStorage.willProcessEditingNotification, object: editor.textView.textStorage
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: editor.textView
        )
    }

    /// The range that is selected for the active tab stop.
    var activeRange: NSRange? {
        guard isActive, tabStops.indices.contains(current) else { return nil }
        return tabStops[current].ranges.first
    }

    // MARK: Navigation

    /// Selects the next placeholder; reaching the final stop (`$0`) ends the
    /// session.
    func next() {
        guard isActive else { return }
        select(current + 1)
    }

    /// Selects the previous placeholder (stays on the first one).
    func previous() {
        guard isActive else { return }
        select(max(0, current - 1))
    }

    func end() {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.removeObserver(self)
        if let editor, Self.sessions[ObjectIdentifier(editor)] === self {
            Self.sessions[ObjectIdentifier(editor)] = nil
        }
    }

    private func select(_ position: Int) {
        guard let editor else { return end() }
        // Skip stops whose ranges were invalidated by overlapping edits.
        var target = min(position, tabStops.count - 1)
        while target < tabStops.count - 1, tabStops[target].ranges.isEmpty { target += 1 }
        guard let range = tabStops[target].ranges.first else { return end() }
        current = target
        let isFinal = tabStops[target].index == 0
        if isFinal { end() }
        editor.selectedRange = range
    }

    // MARK: Edit tracking

    @objc private func storageWillProcessEditing(_ notification: Notification) {
        guard isActive, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let delta = storage.changeInLength
        let edited = storage.editedRange
        applyEdit(location: edited.location, oldLength: edited.length - delta, newLength: edited.length)
    }

    /// Moves, grows or drops placeholder ranges for a replacement of
    /// `oldLength` characters at `location` by `newLength` characters.
    func applyEdit(location: Int, oldLength: Int, newLength: Int) {
        for s in tabStops.indices {
            let isActiveStop = s == current
            tabStops[s].ranges = tabStops[s].ranges.compactMap {
                Self.adjust($0, location: location, oldLength: oldLength, newLength: newLength, growsAtBoundary: isActiveStop)
            }
        }
        if tabStops.allSatisfy({ $0.ranges.isEmpty }) || tabStops[current].ranges.isEmpty { end() }
    }

    /// The new range of `range` after an edit, or nil when the edit only
    /// partially overlaps it (the placeholder is then meaningless).
    ///
    /// `growsAtBoundary` is true for the active placeholder: text typed at its
    /// start or end belongs to it. Other placeholders treat an insertion at
    /// their start as "before" (they move) and at their end as "after".
    static func adjust(_ range: NSRange, location: Int, oldLength: Int, newLength: Int, growsAtBoundary: Bool) -> NSRange? {
        let editEnd = location + oldLength
        let delta = newLength - oldLength
        let contained = location >= range.location && editEnd <= NSMaxRange(range)
        if growsAtBoundary && contained {
            return NSRange(location: range.location, length: range.length + delta)
        }
        if editEnd <= range.location {
            return NSRange(location: range.location + delta, length: range.length)
        }
        if location >= NSMaxRange(range) {
            return range
        }
        if contained {
            return NSRange(location: range.location, length: range.length + delta)
        }
        return nil
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard isActive, let editor else { return }
        checkSelection(editor.textView.selectedRange())
    }

    /// Ends the session when `selection` is outside every placeholder.
    func checkSelection(_ selection: NSRange) {
        let inside = tabStops.contains { stop in
            stop.ranges.contains { selection.location >= $0.location && NSMaxRange(selection) <= NSMaxRange($0) }
        }
        if !inside { end() }
    }
}
