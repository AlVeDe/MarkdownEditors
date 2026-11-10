import AppKit

/// Aligns GFM tables and navigates them like a spreadsheet.
///
/// - Tab / Shift-Tab: re-align the whole table, then select the next /
///   previous cell. Tab in the last cell appends an empty row.
/// - Return at the end of the last row: append an empty row. Return on an
///   empty last row: remove it and leave the table.
///
/// Every action is one `replaceCharacters` of the whole table, so it is a
/// single undo step.
@MainActor
final class TableFormatter: EditorInputHandler {
    let priority = 20
    private weak var editor: EditorController?

    init(editor: EditorController) {
        self.editor = editor
    }

    func textView(_ textView: MarkdownTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): moveToCell(forward: true)
        case #selector(NSResponder.insertBacktab(_:)): moveToCell(forward: false)
        case #selector(NSResponder.insertNewline(_:)): insertNewline()
        default: false
        }
    }

    // MARK: Locating the table

    /// The table around a location, as found in the editor text.
    struct Located {
        /// From the start of the header line to the end of the last row's
        /// contents (line terminator excluded).
        var range: NSRange
        var table: MarkdownTable
        var lines: [String]
        var lineEnding: String
        /// Line index (0 header, 1 delimiter, 2… body) of `location`.
        var row: Int
        var column: Int
        var offsetInContent: Int
    }

    /// Finds the GFM table containing `location`, if any.
    func locateTable(at location: Int) -> Located? {
        guard let editor else { return nil }
        let string = editor.string
        guard string.length > 0, location <= string.length else { return nil }
        if case .codeBlock = editor.context(at: location) { return nil }

        func contentsRange(_ lineRange: NSRange) -> NSRange {
            var end = 0
            string.getLineStart(nil, end: nil, contentsEnd: &end, for: lineRange)
            return NSRange(location: lineRange.location, length: end - lineRange.location)
        }

        let caretLine = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
        func isRowLine(_ range: NSRange) -> Bool {
            let text = string.substring(with: contentsRange(range))
            return !text.allSatisfy(\.isWhitespace) && MarkdownTable.looksLikeRow(text)
        }
        guard isRowLine(caretLine) else { return nil }

        // Expand to the block of contiguous pipe lines.
        var lineRanges = [caretLine]
        var caretIndex = 0
        while lineRanges[0].location > 0 {
            let previous = string.lineRange(for: NSRange(location: lineRanges[0].location - 1, length: 0))
            guard isRowLine(previous) else { break }
            lineRanges.insert(previous, at: 0)
            caretIndex += 1
        }
        while NSMaxRange(lineRanges[lineRanges.count - 1]) < string.length {
            let next = string.lineRange(for: NSRange(location: NSMaxRange(lineRanges[lineRanges.count - 1]), length: 0))
            guard isRowLine(next) else { break }
            lineRanges.append(next)
        }
        let lines = lineRanges.map { string.substring(with: contentsRange($0)) }

        // The header is the line before the last delimiter row at or after
        // which the caret sits.
        var delimiterIndex: Int?
        for index in 1..<max(1, lines.count) where index - 1 <= caretIndex && MarkdownTable.isDelimiterRow(lines[index]) {
            delimiterIndex = index
        }
        guard let delimiterIndex else { return nil }
        let first = delimiterIndex - 1
        let tableLines = Array(lines[first...])
        guard let table = MarkdownTable(lines: tableLines) else { return nil }
        let start = lineRanges[first].location
        guard !isInsideFence(before: start, in: string) else { return nil }

        let end = NSMaxRange(contentsRange(lineRanges[lineRanges.count - 1]))
        let firstRange = lineRanges[first]
        let terminator = string.substring(with: NSRange(
            location: NSMaxRange(contentsRange(firstRange)),
            length: NSMaxRange(firstRange) - NSMaxRange(contentsRange(firstRange))
        ))
        let row = caretIndex - first
        let cell = MarkdownTable.cell(at: location - lineRanges[caretIndex].location, inLine: lines[caretIndex])
        return Located(
            range: NSRange(location: start, length: end - start),
            table: table,
            lines: tableLines,
            lineEnding: terminator.isEmpty ? "\n" : terminator,
            row: row,
            column: min(cell.column, max(0, table.columnCount - 1)),
            offsetInContent: cell.offsetInContent
        )
    }

    /// Cheap fence check: counts fence lines (```` ``` ```` / `~~~`) before
    /// `location`. The highlighter's context covers this once it tracks
    /// fences; this keeps the formatter safe without it.
    private func isInsideFence(before location: Int, in string: NSString) -> Bool {
        var open: (Character, Int)?
        var index = 0
        while index < location {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(lineRange)
            let line = string.substring(with: lineRange)
            let indent = line.prefix { $0 == " " }.count
            guard indent < 4 else { continue }
            let body = line.dropFirst(indent)
            guard let first = body.first, first == "`" || first == "~" else { continue }
            let count = body.prefix { $0 == first }.count
            guard count >= 3 else { continue }
            if let fence = open {
                if fence.0 == first, count >= fence.1,
                   body.dropFirst(count).allSatisfy(\.isWhitespace) {
                    open = nil
                }
            } else {
                open = (first, count)
            }
        }
        return open != nil
    }

    // MARK: Commands

    /// Re-aligns the table at `location` keeping the caret in the same cell.
    /// Returns false when there is no table there. (For a menu command.)
    @discardableResult
    func formatTable(at location: Int) -> Bool {
        guard let editor, let located = locateTable(at: location) else { return false }
        let (text, cells) = located.table.formatted(lineEnding: located.lineEnding)
        let cell = cells[located.row][located.column]
        let caret = located.range.location + cell.location + min(located.offsetInContent, cell.length)
        apply(text, to: located, selecting: NSRange(location: caret, length: 0), in: editor)
        return true
    }

    private func moveToCell(forward: Bool) -> Bool {
        guard let editor, let located = locateTable(at: editor.selectedRange.location) else { return false }
        var table = located.table
        let columns = max(1, table.columnCount)
        // The delimiter row navigates like the header.
        var row = located.row == 1 ? 0 : located.row
        var column = located.column

        if forward {
            if column + 1 < columns {
                column += 1
            } else {
                row = row == 0 ? 2 : row + 1
                column = 0
                if row >= table.lineCount {
                    table.rows.append(Array(repeating: "", count: columns))
                }
            }
        } else {
            if column > 0 {
                column -= 1
            } else if row > 0 {
                row = row == 2 ? 0 : row - 1
                column = columns - 1
            }
        }

        let (text, cells) = table.formatted(lineEnding: located.lineEnding)
        let cell = cells[row][column]
        let selection = NSRange(location: located.range.location + cell.location, length: cell.length)
        apply(text, to: located, selecting: selection, in: editor)
        return true
    }

    private func insertNewline() -> Bool {
        guard let editor else { return false }
        let selection = editor.selectedRange
        guard selection.length == 0, let located = locateTable(at: selection.location) else { return false }
        let isLastRow = located.row == located.table.lineCount - 1
        guard located.row >= 2, isLastRow else { return false }

        let line = located.lines[located.row]
        let cells = located.table.rows[located.row - 2]
        var table = located.table

        if cells.allSatisfy(\.isEmpty) {
            // Leave the table: the empty row becomes an empty line.
            table.rows.removeLast()
            let (text, _) = table.formatted(lineEnding: located.lineEnding)
            let replacement = text + located.lineEnding
            let caret = located.range.location + (replacement as NSString).length
            apply(replacement, to: located, selecting: NSRange(location: caret, length: 0), in: editor)
            return true
        }

        // Only at the end of the row's text; elsewhere Return splits the
        // line as usual.
        let lineStart = editor.string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let trimmedLength = (line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) as NSString).length
        guard selection.location - lineStart >= trimmedLength else { return false }

        table.rows.append(Array(repeating: "", count: max(1, table.columnCount)))
        let (text, ranges) = table.formatted(lineEnding: located.lineEnding)
        let cell = ranges[table.lineCount - 1][0]
        apply(text, to: located, selecting: NSRange(location: located.range.location + cell.location, length: 0), in: editor)
        return true
    }

    private func apply(_ text: String, to located: Located, selecting selection: NSRange, in editor: EditorController) {
        if editor.string.substring(with: located.range) == text {
            // Already aligned: just move, don't record an empty undo step.
            editor.selectedRange = selection
        } else {
            editor.replaceCharacters(in: located.range, with: text, selecting: selection, actionName: "Format Table")
        }
    }
}
