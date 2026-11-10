import AppKit

/// A Markdown formatting command, shared by the Format menu and the
/// formatting toolbar.
enum FormatAction: Hashable, Sendable {
    case bold
    case italic
    case strikethrough
    /// `<mark>…</mark>`: no Markdown syntax for highlighting is portable,
    /// raw HTML is valid CommonMark everywhere.
    case highlight
    /// `<sub>…</sub>` — not `~x~`, which GFM reads as strikethrough.
    case subscriptText
    /// `<sup>…</sup>`.
    case superscriptText
    /// A `[^n]` reference at the caret plus its `[^n]: ` definition at the
    /// end of the document (GitHub footnote syntax).
    case footnote
    case inlineCode
    /// Levels 1–6. Applying the level a line already has removes it.
    case heading(Int)
    /// Removes any heading prefix.
    case paragraph
    case link
    case image
    case quote
    case bulletList
    case numberedList
    case taskList
    /// Checks or unchecks the task boxes on the selected lines.
    case toggleTask
    /// A fenced code block; nil language leaves the info string empty.
    case codeBlock(language: String?)
    /// A GFM table skeleton with a header row plus `rows` body rows.
    case table(rows: Int, columns: Int)
    case horizontalRule
    case inlineMath
    case displayMath
    case mermaid
    case indent
    case outdent

    /// Menu title and undo action name.
    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .subscriptText: "Subscript"
        case .superscriptText: "Superscript"
        case .footnote: "Footnote"
        case .inlineCode: "Inline Code"
        case .heading(let level): "Heading \(level)"
        case .paragraph: "Paragraph"
        case .link: "Link"
        case .image: "Image"
        case .quote: "Quote"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .taskList: "Task List"
        case .toggleTask: "Toggle Task"
        case .codeBlock: "Code Block"
        case .table: "Table"
        case .horizontalRule: "Horizontal Rule"
        case .inlineMath: "Inline Math"
        case .displayMath: "Display Math"
        case .mermaid: "Mermaid Diagram"
        case .indent: "Indent"
        case .outdent: "Outdent"
        }
    }

    /// SF Symbol for toolbar buttons (all available on macOS 15).
    var systemImage: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .subscriptText: "textformat.subscript"
        case .superscriptText: "textformat.superscript"
        case .footnote: "note.text.badge.plus"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .heading, .paragraph: "textformat.size"
        case .link: "link"
        case .image: "photo"
        case .quote: "text.quote"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .taskList: "checklist"
        case .toggleTask: "checkmark.square"
        case .codeBlock: "curlybraces"
        case .table: "tablecells"
        case .horizontalRule: "minus"
        case .inlineMath, .displayMath: "function"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        }
    }
}

// MARK: - Performing

/// Formatting on the editor's text. Each action is one undo step named
/// after the action.
///
/// Inline wrappers (bold, italic, strikethrough, code, inline math) toggle:
/// they unwrap when the selection includes the markers or sits right
/// between them. Without a selection they insert an empty pair and put the
/// caret between — chosen over "wrap the word under the caret" because it
/// is predictable and also works on an empty line; repeating the command
/// with the caret still between the markers removes the pair again.
///
/// Block actions (headings, quote, lists, tasks) work on every line touched
/// by the selection; fences (code, display math, mermaid) wrap those whole
/// lines, or insert an empty block on an empty line.
extension EditorController {
    func perform(_ action: FormatAction, pasteboard: NSPasteboard = .general) {
        textView.breakUndoCoalescing()
        performEdit(actionName: action.title) {
            switch action {
            case .bold: toggleInlineWrap("**")
            case .italic: toggleInlineWrap("*")
            case .strikethrough: toggleInlineWrap("~~")
            case .highlight: toggleTagWrap("mark")
            case .subscriptText: toggleTagWrap("sub")
            case .superscriptText: toggleTagWrap("sup")
            case .footnote: insertFootnote()
            case .inlineMath: toggleInlineWrap("$")
            case .inlineCode: toggleInlineCode()
            case .heading(let level): setHeading(min(6, max(1, level)))
            case .paragraph: setHeading(0)
            case .link: insertLink(isImage: false, pasteboard: pasteboard)
            case .image: insertLink(isImage: true, pasteboard: pasteboard)
            case .quote: toggleQuote()
            case .bulletList: toggleBullets()
            case .numberedList:
                performListEdit(actionName: action.title, affecting: selectedRange) { toggleNumbers() }
            case .taskList: toggleTaskList()
            case .toggleTask: toggleTaskCheckboxes()
            case .codeBlock(let language): toggleCodeFence(language: language)
            case .table(let rows, let columns): insertTable(rows: rows, columns: columns)
            case .horizontalRule: insertBlock("---", selecting: nil)
            case .displayMath: toggleDisplayMath()
            case .mermaid: toggleMermaid()
            case .indent:
                performListEdit(actionName: action.title, affecting: selectedRange, restartsNestedLists: true) {
                    indentLines(unit: (editingAssistant?.settings ?? .shared).indentUnit)
                }
            case .outdent:
                performListEdit(actionName: action.title, affecting: selectedRange, restartsNestedLists: true) {
                    outdentLines(width: (editingAssistant?.settings ?? .shared).tabWidth)
                }
            }
        }
    }

    // MARK: Inline wrappers

    /// The selection without leading and trailing whitespace: `**word **`
    /// would not be bold.
    private func trimmedSelection() -> NSRange {
        var range = selectedRange
        let text = string
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return whitespace.contains(scalar)
        }
        while range.length > 0, isSpace(range.location) { range.location += 1; range.length -= 1 }
        while range.length > 0, isSpace(NSMaxRange(range) - 1) { range.length -= 1 }
        return range.length == 0 ? selectedRange : range
    }

    /// Number of consecutive `unit` characters ending before `location`
    /// (`backwards`) or starting at it.
    private func run(of unit: unichar, at location: Int, backwards: Bool) -> Int {
        let text = string
        var count = 0
        var index = backwards ? location - 1 : location
        while index >= 0, index < text.length, text.character(at: index) == unit {
            count += 1
            index += backwards ? -1 : 1
        }
        return count
    }

    /// Whether a run of marker characters on both sides means `marker` is
    /// applied. `*` is italic in runs of 1 and 3 (`***both***`), `**` in
    /// runs of 2 and more, `$` only alone (`$$` is display math).
    private func markerApplied(_ marker: String, run: Int) -> Bool {
        switch marker {
        case "*": run % 2 == 1
        case "$": run == 1
        default: run >= (marker as NSString).length
        }
    }

    private func toggleInlineWrap(_ marker: String) {
        let range = trimmedSelection()
        let selected = string.substring(with: range)
        let markerLength = (marker as NSString).length
        let unit = (marker as NSString).character(at: 0)

        // The selection includes the markers: `**bold**`.
        if range.length >= 2 * markerLength {
            let inner = selected as NSString
            var lead = 0
            while lead < inner.length, inner.character(at: lead) == unit { lead += 1 }
            var trail = 0
            while trail < inner.length - lead, inner.character(at: inner.length - 1 - trail) == unit { trail += 1 }
            if lead < inner.length, markerApplied(marker, run: min(lead, trail)) {
                let unwrapped = inner.substring(with: NSRange(location: markerLength, length: inner.length - 2 * markerLength))
                replaceCharacters(
                    in: range, with: unwrapped,
                    selecting: NSRange(location: range.location, length: (unwrapped as NSString).length)
                )
                return
            }
        }

        // The markers sit right around the selection (or the caret).
        let before = run(of: unit, at: range.location, backwards: true)
        let after = run(of: unit, at: NSMaxRange(range), backwards: false)
        if markerApplied(marker, run: min(before, after)) {
            replaceCharacters(
                in: NSRange(location: range.location - markerLength, length: range.length + 2 * markerLength),
                with: selected,
                selecting: NSRange(location: range.location - markerLength, length: range.length)
            )
            return
        }

        replaceCharacters(
            in: range, with: marker + selected + marker,
            selecting: NSRange(location: range.location + markerLength, length: range.length)
        )
    }

    /// Inline code needs a fence longer than any backtick run inside, and a
    /// space of padding when the content starts or ends with a backtick.
    private func toggleInlineCode() {
        let range = trimmedSelection()
        let selected = string.substring(with: range)
        let tick: unichar = 0x60

        // Selection is `code` (or ``co`de``).
        let lead = selected.prefix { $0 == "`" }.count
        let trail = String(selected.reversed()).prefix { $0 == "`" }.count
        if lead > 0, lead == trail, selected.count > 2 * lead {
            var inner = String(selected.dropFirst(lead).dropLast(trail))
            if inner.count >= 2, inner.hasPrefix(" "), inner.hasSuffix(" ") {
                inner = String(inner.dropFirst().dropLast())
            }
            replaceCharacters(in: range, with: inner, selecting: NSRange(location: range.location, length: (inner as NSString).length))
            return
        }

        let before = run(of: tick, at: range.location, backwards: true)
        let after = run(of: tick, at: NSMaxRange(range), backwards: false)
        if before > 0, before == after {
            replaceCharacters(
                in: NSRange(location: range.location - before, length: range.length + 2 * before),
                with: selected,
                selecting: NSRange(location: range.location - before, length: range.length)
            )
            return
        }

        var longest = 0, current = 0
        for character in selected {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = selected.hasPrefix("`") || selected.hasSuffix("`") ? " " : ""
        let opening = fence + pad
        replaceCharacters(
            in: range, with: opening + selected + pad + fence,
            selecting: NSRange(location: range.location + (opening as NSString).length, length: range.length)
        )
    }

    // MARK: Links

    /// A URL on the pasteboard, if the pasteboard holds exactly one.
    private func pasteboardURL(_ pasteboard: NSPasteboard) -> String? {
        guard let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains(where: \.isWhitespace),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "file"].contains(scheme)
        else { return nil }
        return raw
    }

    /// `[text](url)`. With a URL on the clipboard it is used and the text is
    /// selected for typing; otherwise the `url` placeholder is selected.
    private func insertLink(isImage: Bool, pasteboard: NSPasteboard) {
        let range = trimmedSelection()
        var label = string.substring(with: range)
        if label.isEmpty { label = isImage ? "alt text" : "link text" }
        let url = pasteboardURL(pasteboard)
        let target = url ?? (isImage ? "path" : "url")
        let bang = isImage ? "!" : ""
        let replacement = "\(bang)[\(label)](\(target))"
        let labelStart = range.location + (bang as NSString).length + 1
        let labelLength = (label as NSString).length
        let selection = url != nil
            ? NSRange(location: labelStart, length: labelLength)
            : NSRange(location: labelStart + labelLength + 2, length: (target as NSString).length)
        replaceCharacters(in: range, with: replacement, selecting: selection)
    }

    // MARK: Line prefixes

    /// Indexes of the lines a block toggle looks at: the non-empty ones, or
    /// all of them when everything is empty (a single empty line).
    private func relevantLineIndexes(_ lines: [String]) -> Set<Int> {
        let nonEmpty = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        return Set(nonEmpty.isEmpty ? Array(lines.indices) : nonEmpty)
    }

    private func selectedLines() -> [String] {
        lines(in: lineBlock(for: selectedRange)).lines
    }

    /// `level` 0 removes the heading; the level a line already has toggles off.
    private func setHeading(_ level: Int) {
        let relevant = relevantLineIndexes(selectedLines())
        transformSelectedLines(actionName: level == 0 ? "Paragraph" : "Heading \(level)") { line, index in
            guard relevant.contains(index) else { return line }
            let hashes = line.prefix { $0 == "#" }.count
            var body = Substring(line)
            var existing = 0
            if (1...6).contains(hashes), line.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) ?? true {
                existing = hashes
                body = line.dropFirst(hashes).drop { $0 == " " || $0 == "\t" }
            }
            if level == 0 || level == existing { return String(body) }
            return String(repeating: "#", count: level) + " " + body
        }
    }

    private func toggleQuote() {
        let lines = selectedLines()
        let relevant = relevantLineIndexes(lines)
        let allQuoted = relevant.allSatisfy { MarkdownLinePrefix(line: lines[$0]).isQuote }
        transformSelectedLines(actionName: "Quote") { line, index in
            if allQuoted {
                guard relevant.contains(index) else { return line }
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var rest = line.dropFirst(indent.count).dropFirst()  // ">"
                if rest.first == " " { rest = rest.dropFirst() }
                return String(indent + rest)
            }
            if line.isEmpty { return relevant.contains(index) ? "> " : ">" }
            return "> " + line
        }
    }

    /// Shared shape of the three list toggles: if every relevant line already
    /// matches, strip the list marker; otherwise give every relevant line
    /// the marker `makePrefix` builds (replacing any other list marker).
    private func toggleList(
        actionName: String,
        matches: (MarkdownLinePrefix) -> Bool,
        makePrefix: (_ parsed: MarkdownLinePrefix, _ ordinal: Int) -> String
    ) {
        let lines = selectedLines()
        let relevant = relevantLineIndexes(lines)
        let allMatch = relevant.allSatisfy { matches(MarkdownLinePrefix(line: lines[$0])) }
        var ordinals: [Int: Int] = [:]
        for (ordinal, index) in relevant.sorted().enumerated() { ordinals[index] = ordinal + 1 }
        transformSelectedLines(actionName: actionName) { line, index in
            guard let ordinal = ordinals[index] else { return line }
            let parsed = MarkdownLinePrefix(line: line)
            if allMatch {
                return parsed.indent + parsed.quote + parsed.content
            }
            return parsed.indent + parsed.quote + makePrefix(parsed, ordinal) + parsed.content
        }
    }

    private func toggleBullets() {
        toggleList(actionName: "Bulleted List", matches: { parsed in
            if case .bullet = parsed.marker { return !parsed.isTask }
            return false
        }, makePrefix: { _, _ in "- " })
    }

    private func toggleNumbers() {
        toggleList(actionName: "Numbered List", matches: { parsed in
            if case .ordered = parsed.marker { return !parsed.isTask }
            return false
        }, makePrefix: { _, ordinal in "\(ordinal). " })
    }

    /// Existing tasks keep their checked state; existing bullets keep their
    /// bullet character.
    private func toggleTaskList() {
        toggleList(actionName: "Task List", matches: \.isTask, makePrefix: { parsed, _ in
            let box = parsed.task.map { "[\($0)] " } ?? "[ ] "
            if case .bullet(let character) = parsed.marker { return "\(character) " + box }
            return "- " + box
        })
    }

    /// Flips `[ ]` ↔ `[x]`. When the lines disagree they all become checked
    /// first (like a "select all" box). Lines without a box get one.
    private func toggleTaskCheckboxes() {
        let lines = selectedLines()
        let relevant = relevantLineIndexes(lines)
        let parsedTasks = relevant.map { MarkdownLinePrefix(line: lines[$0]) }.filter(\.isTask)
        let allChecked = !parsedTasks.isEmpty && parsedTasks.allSatisfy { $0.task != " " }
        transformSelectedLines(actionName: "Toggle Task") { line, index in
            guard relevant.contains(index) else { return line }
            var parsed = MarkdownLinePrefix(line: line)
            if parsed.isTask {
                parsed.task = allChecked ? " " : "x"
            } else if parsed.isListItem {
                parsed.task = " "
                parsed.taskSpacing = " "
            } else {
                return parsed.indent + parsed.quote + "- [ ] " + parsed.content
            }
            return parsed.prefix + parsed.content
        }
    }

    // MARK: Blocks

    /// Wraps the selected lines in `open` … `close` lines, or unwraps them
    /// when they already are such a block. On a single empty line inserts
    /// the block with `emptyBody`.
    ///
    /// - Parameter caret: the selection after inserting, relative to the
    ///   block's start, given the inserted text; nil selects the body.
    private func toggleFence(
        open: String,
        close: String,
        isOpening: (String) -> Bool,
        emptyBody: String,
        caret: ((_ body: String) -> NSRange)?
    ) {
        var block = lineBlock(for: selectedRange)
        var (blockLines, hasTerminator) = lines(in: block)
        // The caret on an opening fence line (where inserting put it) means
        // the whole block up to its closing fence.
        if blockLines.count == 1, isOpening(blockLines[0]) {
            var next = NSMaxRange(block)
            while next < string.length {
                let line = string.lineRange(for: NSRange(location: next, length: 0))
                let isClose = lines(in: line).lines[0].trimmingCharacters(in: .whitespaces) == close
                next = NSMaxRange(line)
                if isClose {
                    block = NSRange(location: block.location, length: NSMaxRange(line) - block.location)
                    (blockLines, hasTerminator) = lines(in: block)
                    break
                }
            }
        }
        let terminator = hasTerminator ? "\n" : ""

        if blockLines.count >= 2, isOpening(blockLines[0]),
           blockLines[blockLines.count - 1].trimmingCharacters(in: .whitespaces) == close {
            let inner = blockLines.dropFirst().dropLast().joined(separator: "\n")
            replaceCharacters(
                in: block, with: inner + terminator,
                selecting: NSRange(location: block.location, length: (inner as NSString).length)
            )
            return
        }

        let isEmpty = blockLines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let body = isEmpty ? emptyBody : blockLines.joined(separator: "\n")
        let replacement = open + "\n" + body + "\n" + close + terminator
        let bodyRange = NSRange(location: block.location + (open as NSString).length + 1, length: (body as NSString).length)
        let selection = caret.map { range in
            let relative = range(body)
            return NSRange(location: block.location + relative.location, length: relative.length)
        } ?? bodyRange
        replaceCharacters(in: block, with: replacement, selecting: selection)
    }

    private static func isCodeFenceOpening(_ line: String) -> Bool {
        MarkdownSource.isFenceLine(line)
    }

    /// The caret lands on the language (selected, so typing replaces it).
    private func toggleCodeFence(language: String?) {
        let language = language ?? ""
        toggleFence(
            open: "```" + language, close: "```",
            isOpening: Self.isCodeFenceOpening, emptyBody: "",
            caret: { _ in NSRange(location: 3, length: (language as NSString).length) }
        )
    }

    private func toggleDisplayMath() {
        toggleFence(
            open: "$$", close: "$$",
            isOpening: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("$$") },
            emptyBody: "", caret: nil
        )
    }

    /// An empty mermaid block starts with a flowchart and the caret on the
    /// first (indented) node line.
    private func toggleMermaid() {
        let open = "```mermaid"
        let stub = "flowchart TD\n    "
        let openLength = (open as NSString).length
        let selectionIsEmpty = lines(in: lineBlock(for: selectedRange)).lines
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        toggleFence(
            open: open, close: "```",
            isOpening: Self.isCodeFenceOpening, emptyBody: stub,
            caret: selectionIsEmpty
                ? { _ in NSRange(location: openLength + 1 + (stub as NSString).length, length: 0) }
                : nil
        )
    }

    /// Inserts a block on its own line: replaces the current line when it is
    /// blank, otherwise goes below it after an empty line (so a table or
    /// `---` does not merge into the paragraph above, which would turn
    /// `---` into a setext heading).
    ///
    /// - Parameter selecting: relative to the start of `block`; nil puts the
    ///   caret after it.
    private func insertBlock(_ block: String, selecting: NSRange?) {
        let caret = selectedRange
        let line = lineBlock(for: NSRange(location: NSMaxRange(caret), length: 0))
        let content = lines(in: line).lines[0]
        let contentRange = NSRange(location: line.location, length: (content as NSString).length)
        let blockLength = (block as NSString).length

        let range: NSRange
        let replacement: String
        let blockStart: Int
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            range = contentRange
            replacement = block
            blockStart = contentRange.location
        } else {
            range = NSRange(location: NSMaxRange(contentRange), length: 0)
            replacement = "\n\n" + block
            blockStart = NSMaxRange(contentRange) + 2
        }
        let selection = selecting.map { NSRange(location: blockStart + $0.location, length: $0.length) }
            ?? NSRange(location: blockStart + blockLength, length: 0)
        replaceCharacters(in: range, with: replacement, selecting: selection)
    }

    /// A GFM table skeleton; the first header cell is selected.
    private func insertTable(rows: Int, columns: Int) {
        let columns = max(1, columns), rows = max(1, rows)
        let headers = (1...columns).map { "Column \($0)" }
        let widths = headers.map(\.count)
        let header = "| " + headers.joined(separator: " | ") + " |"
        let separator = "| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |"
        let empty = "| " + widths.map { String(repeating: " ", count: $0) }.joined(separator: " | ") + " |"
        let table = ([header, separator] + Array(repeating: empty, count: rows)).joined(separator: "\n")
        insertBlock(table, selecting: NSRange(location: 2, length: (headers[0] as NSString).length))
    }
}

// MARK: - Session

extension DocumentSession {
    /// Runs a formatting action from a menu or toolbar: shows the editor if
    /// only the preview is visible, then focuses it.
    func perform(_ action: FormatAction) {
        performOnEditor { $0.perform(action) }
    }

    /// Runs any editor command (e.g. a line operation) the same way.
    func performOnEditor(_ body: (EditorController) -> Void) {
        if viewMode == .preview { viewMode = .split }
        body(editor)
        // After switching from Preview Only the text view is back in the
        // window only once SwiftUI has updated, so focus on the next turn.
        let textView = editor.textView
        textView.window?.makeFirstResponder(textView)
        Task { @MainActor in
            textView.window?.makeFirstResponder(textView)
        }
    }
}
