import AppKit

/// Line-oriented editing on top of `replaceCharacters`: the building block
/// for indentation, list and heading toggles, and the Lines menu (move,
/// duplicate, delete, join, comment, select).
///
/// Lives in an `EditorController` extension rather than in the assistant so
/// the Format menu can use it without finding the input handler first.
/// Every operation is one `replaceCharacters` call, i.e. one undo step;
/// move, duplicate and delete renumber an ordered list they touch within
/// that step (`performListEdit`).
extension EditorController {
    // MARK: Line blocks

    /// The full lines (including their terminators) touched by `range`.
    ///
    /// A multi-line selection that ends at the very start of a line does not
    /// include that line — that is what a user who triple-clicked or dragged
    /// to the left margin means.
    func lineBlock(for range: NSRange) -> NSRange {
        let text = string
        var end = NSMaxRange(range)
        if range.length > 0, end > range.location, end <= text.length, text.character(at: end - 1) == 0x0A {
            end -= 1
        }
        let first = text.lineRange(for: NSRange(location: range.location, length: 0))
        let last = text.lineRange(for: NSRange(location: max(range.location, end), length: 0))
        return NSUnionRange(first, last)
    }

    /// A line block split into lines without terminators; `hasTerminator`
    /// tells whether the block ended with a newline (false only for the last
    /// line of a document without a trailing newline).
    func lines(in block: NSRange) -> (lines: [String], hasTerminator: Bool) {
        var content = string.substring(with: block)
        let hasTerminator = content.hasSuffix("\n")
        if hasTerminator { content.removeLast() }
        return (content.components(separatedBy: "\n"), hasTerminator)
    }

    /// Rewrites each line of the current selection's line block with
    /// `transform` (which also gets the line's index in the block) as one
    /// undo step.
    ///
    /// The selection is mapped line by line: a position keeps its column
    /// shifted by the line's change in length, clamped to the line. That is
    /// exact for the common case of prefixes being added or removed at the
    /// start of a line (indent, `- `, `# `, `> `).
    @discardableResult
    func transformSelectedLines(actionName: String, _ transform: (_ line: String, _ index: Int) -> String) -> Bool {
        let selection = selectedRange
        let block = lineBlock(for: selection)
        let (oldLines, hasTerminator) = lines(in: block)
        let newLines = oldLines.enumerated().map { transform($0.element, $0.offset) }
        guard newLines != oldLines else { return false }

        // Offsets of each line start, old and new (UTF-16).
        func starts(_ lines: [String]) -> [Int] {
            var result: [Int] = []
            var offset = 0
            for line in lines {
                result.append(offset)
                offset += (line as NSString).length + 1
            }
            return result
        }
        let oldStarts = starts(oldLines)
        let newStarts = starts(newLines)
        func map(_ location: Int, keepsLineStart: Bool = false) -> Int {
            let offset = location - block.location
            let index = max(0, (oldStarts.lastIndex { $0 <= offset }) ?? 0)
            let column = offset - oldStarts[index]
            let delta = (newLines[index] as NSString).length - (oldLines[index] as NSString).length
            let newColumn = keepsLineStart && column == 0
                ? 0
                : min(max(0, column + delta), (newLines[index] as NSString).length)
            return block.location + newStarts[index] + newColumn
        }
        // A selection starting at a line start keeps covering whole lines.
        let start = map(selection.location, keepsLineStart: selection.length > 0)
        let end = selection.length == 0 ? start : map(NSMaxRange(selection))

        let replacement = newLines.joined(separator: "\n") + (hasTerminator ? "\n" : "")
        return replaceCharacters(
            in: block, with: replacement,
            selecting: NSRange(location: start, length: max(0, end - start)),
            actionName: actionName
        )
    }

    // MARK: Indentation

    /// Indents every line of the selection by `unit`. Empty lines stay empty
    /// in a multi-line selection so no trailing whitespace is created.
    func indentLines(unit: String) {
        let multiLine = lines(in: lineBlock(for: selectedRange)).lines.count > 1
        transformSelectedLines(actionName: "Indent") { line, _ in
            multiLine && line.isEmpty ? line : unit + line
        }
    }

    /// Removes one indentation step (a tab, or up to `width` spaces) from
    /// every line of the selection.
    func outdentLines(width: Int) {
        transformSelectedLines(actionName: "Outdent") { line, _ in
            Self.removingIndentStep(from: line, width: width)
        }
    }

    static func removingIndentStep(from line: String, width: Int) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let spaces = line.prefix { $0 == " " }.count
        return String(line.dropFirst(min(spaces, max(1, width))))
    }

    // MARK: Lines menu

    /// Swaps the selected lines with the line above; the selection moves
    /// along.
    func moveLinesUp() {
        let selection = selectedRange
        let block = lineBlock(for: selection)
        guard block.location > 0 else { NSSound.beep(); return }
        let previous = string.lineRange(for: NSRange(location: block.location - 1, length: 0))
        let combined = NSUnionRange(previous, block)
        let (blockLines, hasTerminator) = lines(in: block)
        let previousLine = lines(in: previous).lines[0]
        let replacement = blockLines.joined(separator: "\n") + "\n" + previousLine + (hasTerminator ? "\n" : "")
        let offset = selection.location - block.location
        performListEdit(actionName: "Move Line Up", affecting: combined, keepsStart: true) {
            replaceCharacters(
                in: combined, with: replacement,
                selecting: NSRange(location: combined.location + offset, length: selection.length),
                actionName: "Move Line Up"
            )
        }
    }

    /// Swaps the selected lines with the line below.
    func moveLinesDown() {
        let selection = selectedRange
        let block = lineBlock(for: selection)
        guard NSMaxRange(block) < string.length else { NSSound.beep(); return }
        let next = string.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        let combined = NSUnionRange(block, next)
        let blockLines = lines(in: block).lines
        let (nextLines, hasTerminator) = lines(in: next)
        let nextLine = nextLines[0]
        let replacement = nextLine + "\n" + blockLines.joined(separator: "\n") + (hasTerminator ? "\n" : "")
        let offset = selection.location - block.location
        let shift = (nextLine as NSString).length + 1
        performListEdit(actionName: "Move Line Down", affecting: combined, keepsStart: true) {
            replaceCharacters(
                in: combined, with: replacement,
                selecting: NSRange(location: combined.location + shift + offset, length: selection.length),
                actionName: "Move Line Down"
            )
        }
    }

    /// Inserts a copy of the selected lines below them and moves the
    /// selection onto the copy, so repeating the command keeps duplicating.
    func duplicateLines() {
        let selection = selectedRange
        let block = lineBlock(for: selection)
        let (blockLines, hasTerminator) = lines(in: block)
        let content = blockLines.joined(separator: "\n")
        let shift = (content as NSString).length + 1
        // Without a trailing newline the copy goes after a new one.
        let insertion = hasTerminator ? content + "\n" : "\n" + content
        performListEdit(actionName: "Duplicate Line", affecting: block, keepsStart: true) {
            replaceCharacters(
                in: NSRange(location: NSMaxRange(block), length: 0), with: insertion,
                selecting: NSRange(location: selection.location + shift, length: selection.length),
                actionName: "Duplicate Line"
            )
        }
    }

    /// Deletes the selected lines entirely. On the last line (no trailing
    /// newline) the preceding newline goes too, so no empty line remains.
    func deleteLines() {
        var block = lineBlock(for: selectedRange)
        var caret = block.location
        if !lines(in: block).hasTerminator, block.location > 0 {
            block.location -= 1
            block.length += 1
            // The caret lands at the start of the line that is now last.
            caret = string.lineRange(for: NSRange(location: block.location, length: 0)).location
        }
        guard block.length > 0 else { return }
        performListEdit(actionName: "Delete Line", affecting: block, keepsStart: true) {
            replaceCharacters(in: block, with: "", selecting: NSRange(location: caret, length: 0), actionName: "Delete Line")
        }
    }

    /// Joins the selected lines (or the current line and the next) with
    /// single spaces, dropping the indentation of the joined lines — like
    /// `J` in vi.
    func joinLines() {
        let selection = selectedRange
        var block = lineBlock(for: selection)
        var blockLines = lines(in: block)
        if blockLines.lines.count == 1 {
            guard NSMaxRange(block) < string.length else { NSSound.beep(); return }
            block = NSUnionRange(block, string.lineRange(for: NSRange(location: NSMaxRange(block), length: 0)))
            blockLines = lines(in: block)
        }
        var joined = blockLines.lines[0].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        var caret = (joined as NSString).length
        for line in blockLines.lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            caret = (joined as NSString).length
            joined += (joined.isEmpty ? "" : " ") + trimmed
        }
        replaceCharacters(
            in: block, with: joined + (blockLines.hasTerminator ? "\n" : ""),
            selecting: NSRange(location: block.location + caret, length: 0),
            actionName: "Join Lines"
        )
    }

    /// Wraps the selected lines in `<!-- … -->`, or unwraps them when they
    /// already form one comment. The comment opens after the first line's
    /// indentation so nested list content keeps its structure.
    func toggleLineComment() {
        let block = lineBlock(for: selectedRange)
        let blockLines = lines(in: block).lines
        let first = blockLines[0]
        let last = blockLines[blockLines.count - 1]
        let indent = String(first.prefix { $0 == " " || $0 == "\t" })
        let firstBody = first.dropFirst(indent.count)

        let isCommented = firstBody.hasPrefix("<!--") && last.trimmingCharacters(in: .whitespaces).hasSuffix("-->")
        transformSelectedLines(actionName: "Toggle Comment") { line, index in
            var line = line
            let isFirst = index == 0, isLast = index == blockLines.count - 1
            if isCommented {
                if isFirst {
                    var body = line.dropFirst(indent.count).dropFirst(4)
                    if body.first == " " { body = body.dropFirst() }
                    line = indent + body
                }
                if isLast, let range = line.range(of: "-->", options: .backwards) {
                    var head = line[..<range.lowerBound]
                    if head.last == " " { head = head.dropLast() }
                    line = String(head) + line[range.upperBound...]
                }
            } else {
                if isFirst { line = indent + "<!-- " + line.dropFirst(indent.count) }
                if isLast { line += " -->" }
            }
            return line
        }
    }

    /// Selects the whole current line(s) including the newline; when whole
    /// lines are already selected, extends the selection by the next line.
    func selectLines() {
        let selection = selectedRange
        var block = lineBlock(for: selection)
        if block == selection, NSMaxRange(block) < string.length {
            block = NSUnionRange(block, string.lineRange(for: NSRange(location: NSMaxRange(block), length: 0)))
        }
        selectedRange = block
    }
}
