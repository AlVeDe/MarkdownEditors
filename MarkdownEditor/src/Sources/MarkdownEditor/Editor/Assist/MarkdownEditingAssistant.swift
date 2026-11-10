import AppKit

/// Editing help while typing Markdown: list continuation on Return,
/// indentation on Tab / Shift-Tab, auto-closing pairs and wrapping the
/// selection in emphasis markers.
///
/// Runs after the completion popup (0), snippets (10) and table formatting
/// (20), so those get Return and Tab first when they have something to do.
/// Every edit goes through `EditorController.replaceCharacters`, so each
/// keystroke handled here is exactly one undo step.
@MainActor
final class MarkdownEditingAssistant: EditorInputHandler {
    let priority = 30
    private weak var editor: EditorController?
    let settings: EditorSettings

    init(editor: EditorController, settings: EditorSettings = .shared) {
        self.editor = editor
        self.settings = settings
    }

    /// Characters that open a pair when typed without a selection, and their
    /// partners.
    static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`"]
    /// Characters that wrap a selection instead of replacing it.
    static let wrappers: [Character: Character] = [
        "*": "*", "_": "_", "~": "~", "`": "`", "(": ")", "[": "]", "\"": "\"", "$": "$"
    ]

    // MARK: EditorInputHandler

    func textView(_ textView: MarkdownTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): insertNewline()
        case #selector(NSResponder.insertTab(_:)): insertTab()
        case #selector(NSResponder.insertBacktab(_:)): insertBacktab()
        case #selector(NSResponder.deleteBackward(_:)): deleteBackward()
        default: false
        }
    }

    func textView(_ textView: MarkdownTextView, insertText string: String, replacementRange: NSRange) -> Bool {
        guard settings.autoPairs, string.count == 1, let character = string.first, let editor else { return false }
        let range = replacementRange.location == NSNotFound ? editor.selectedRange : replacementRange
        return autoPair(character, in: range)
    }

    // MARK: Context

    /// True where Markdown assistance must stay out: code blocks, front
    /// matter, comments. (Inline code spans are handled by `autoPair` itself:
    /// a list item containing `` `code` `` still continues.) Uses the highlighter's context and, as a fallback
    /// that works without it, a scan for fence lines.
    private func isCode(at location: Int) -> Bool {
        guard let editor else { return false }
        switch editor.context(at: location) {
        case .codeBlock, .fenceInfo, .mermaid, .frontMatter, .htmlComment:
            return true
        case .markdown, .inlineCode, .inlineMath, .displayMath:
            return MarkdownSource.isInFencedCode(editor.string, at: location)
        }
    }

    // MARK: Return

    /// Continues lists and quotes, ends them on an empty item, and keeps the
    /// indentation of plain lines and code.
    private func insertNewline() -> Bool {
        guard let editor else { return false }
        let selection = editor.selectedRange
        let text = editor.string
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineEnd = lineContentEnd(lineRange, in: text)
        let line = text.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        let column = selection.location - lineRange.location

        let parsed = MarkdownLinePrefix(line: line)
        let inCode = isCode(at: selection.location)

        // Caret inside the indentation or marker: a plain newline is what
        // the user wants (e.g. to push the item down).
        if !inCode, (parsed.isListItem || parsed.isQuote), column < parsed.prefixLength {
            return false
        }

        if inCode || (!parsed.isListItem && !parsed.isQuote) {
            guard !parsed.indent.isEmpty else { return false }
            // Auto-indent: never more indentation than there is before the caret.
            let indent = String(parsed.indent.prefix(column))
            return editor.replaceCharacters(in: selection, with: "\n" + indent, actionName: "Typing")
        }

        // Empty item at the end of its line: end the list (or quote). A
        // quoted list keeps the quote; a bare quote loses its marker.
        let isEmptyItem = parsed.content.trimmingCharacters(in: .whitespaces).isEmpty
            && selection.location + selection.length >= lineEnd
        if isEmptyItem {
            let remaining = parsed.isListItem ? parsed.indent + parsed.quote : parsed.indent
            let trimmedRemaining = remaining.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let range = NSRange(location: lineRange.location, length: lineEnd - lineRange.location)
            guard case .ordered = parsed.marker else {
                return editor.replaceCharacters(in: range, with: trimmedRemaining, actionName: "End List")
            }
            // Items after the emptied one still belong to the (now loose)
            // list and follow on from the items before it.
            return editor.performListEdit(actionName: "End List", affecting: lineRange) {
                editor.replaceCharacters(in: range, with: trimmedRemaining, actionName: "End List")
            }
        }

        guard case .ordered(_, let delimiter) = parsed.marker else {
            return editor.replaceCharacters(in: selection, with: "\n" + parsed.continuation, actionName: "Typing")
        }
        // A numbered item: the new item gets the next number and the items
        // below shift up by one, in the same undo step. An "all ones" list
        // stays that way.
        var continued = parsed
        if editor.continuesAllOnesList(at: selection.location) {
            continued.marker = .ordered(number: 0, delimiter: delimiter)  // continuation adds 1
        }
        return editor.performListEdit(actionName: "Typing", affecting: lineRange) {
            editor.replaceCharacters(in: selection, with: "\n" + continued.continuation, actionName: "Typing")
        }
    }

    /// End of a line's content, before its terminator.
    private func lineContentEnd(_ lineRange: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = text.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return end
    }

    // MARK: Tab

    private func isMultiLineSelection(_ selection: NSRange) -> Bool {
        guard let editor, selection.length > 0 else { return false }
        return editor.lines(in: editor.lineBlock(for: selection)).lines.count > 1
    }

    private func currentLinePrefix() -> MarkdownLinePrefix? {
        guard let editor else { return nil }
        let block = editor.lineBlock(for: NSRange(location: editor.selectedRange.location, length: 0))
        return MarkdownLinePrefix(line: editor.lines(in: block).lines[0])
    }

    /// Multi-line selection: indent all lines. List item (caret anywhere on
    /// the line): indent the item. Otherwise insert one indent unit.
    private func insertTab() -> Bool {
        guard let editor else { return false }
        let selection = editor.selectedRange
        if isMultiLineSelection(selection)
            || (!isCode(at: selection.location) && currentLinePrefix()?.isListItem == true) {
            editor.performListEdit(actionName: "Indent", affecting: selection, restartsNestedLists: true) {
                editor.indentLines(unit: settings.indentUnit)
            }
            return true
        }
        return editor.replaceCharacters(in: selection, with: settings.indentUnit, actionName: "Typing")
    }

    /// Shift-Tab outdents the selected lines or the current line.
    private func insertBacktab() -> Bool {
        guard let editor else { return false }
        editor.performListEdit(actionName: "Outdent", affecting: editor.selectedRange, restartsNestedLists: true) {
            editor.outdentLines(width: settings.tabWidth)
        }
        return true
    }

    // MARK: Pairs

    private func character(at location: Int) -> Character? {
        guard let editor, location >= 0, location < editor.string.length else { return nil }
        let range = editor.string.rangeOfComposedCharacterSequence(at: location)
        return editor.string.substring(with: range).first
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    /// Wraps a selection, overtypes a closing character or inserts a pair.
    ///
    /// Pairs are only inserted when the next character is whitespace, the
    /// end of the text or a closing bracket — typing `(` in front of a word
    /// should not leave a stray `)`. Quotes and backticks right after a word
    /// character (`don't`, ``foo` ``) and backticks after a backtick (typing a
    /// ```` ``` ```` fence) are not paired either.
    private func autoPair(_ typed: Character, in range: NSRange) -> Bool {
        guard let editor, !isCode(at: range.location) else { return false }

        if range.length > 0 {
            guard editor.context(at: range.location) != .inlineCode, let closing = Self.wrappers[typed] else { return false }
            let selected = editor.string.substring(with: range)
            let open = String(typed)
            return editor.replaceCharacters(
                in: range, with: open + selected + String(closing),
                selecting: NSRange(location: range.location + 1, length: range.length),
                actionName: "Typing"
            )
        }

        let next = character(at: range.location)
        let previous = range.location > 0 ? character(at: range.location - 1) : nil

        // Overtype the closing half that is already there.
        if Self.pairs.values.contains(typed), next == typed {
            editor.selectedRange = NSRange(location: range.location + 1, length: 0)
            return true
        }
        // Inside a code span only the closing backtick is helped along.
        if editor.context(at: range.location) == .inlineCode { return false }

        guard let closing = Self.pairs[typed] else { return false }
        if typed == "\"" || typed == "`" {
            if Self.isWordCharacter(previous) { return false }
            if typed == "`" && previous == "`" { return false }
        }
        if let next, !(next.isWhitespace || ")]}".contains(next)) { return false }

        return editor.replaceCharacters(
            in: range, with: String(typed) + String(closing),
            selecting: NSRange(location: range.location + 1, length: 0),
            actionName: "Typing"
        )
    }

    /// Backspace between an empty pair `(|)` deletes both halves.
    private func deleteBackward() -> Bool {
        guard settings.autoPairs, let editor else { return false }
        let selection = editor.selectedRange
        guard selection.length == 0, selection.location > 0,
              let previous = character(at: selection.location - 1),
              let closing = Self.pairs[previous],
              character(at: selection.location) == closing,
              !isCode(at: selection.location)
        else { return false }
        return editor.replaceCharacters(
            in: NSRange(location: selection.location - 1, length: 2), with: "",
            actionName: "Typing"
        )
    }
}

extension EditorController {
    /// The installed editing assistant, for menu commands that need its
    /// settings.
    var editingAssistant: MarkdownEditingAssistant? {
        inputHandlers.lazy.compactMap { $0 as? MarkdownEditingAssistant }.first
    }
}
