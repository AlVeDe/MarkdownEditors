import AppKit

/// Automatic renumbering of ordered lists: after an item is inserted,
/// deleted, moved or re-indented, the numbers of its list become
/// consecutive again.
///
/// The pure core works on an array of lines so it can be tested without a
/// text view; `EditorController.renumberOrderedList(around:)` applies its
/// result as one undoable edit that only touches the digits that change.
///
/// The list structure is a deliberately small approximation of CommonMark:
/// items of one list share quote depth, indentation and delimiter; blank
/// lines stay inside (loose lists); deeper lines are item content (nested
/// lists are lists of their own); a shallower line, a heading, a thematic
/// break, a fence, another kind of list marker at the same level or a
/// paragraph after a blank line end the list. Lines inside fenced code are
/// never items.
enum ListRenumbering {
    /// One number to replace.
    struct Edit: Equatable {
        /// 0-based line index.
        var line: Int
        /// UTF-16 range of the digits within the line.
        var range: NSRange
        var replacement: String
    }

    /// The digits to rewrite so that the lists at `line` (and the lists
    /// nested inside them) count up from their start number.
    ///
    /// - Parameters:
    ///   - startNumber: overrides the start of the innermost list containing
    ///     `line` — used after moving or deleting the first item, where the
    ///     new first item's number would otherwise become the start.
    ///   - restartsNestedLists: nested lists at `line` start at 1 — used
    ///     after Tab / Shift-Tab, where an item that just became (or just
    ///     left) a sub-list would otherwise carry its old number along.
    static func edits(
        in lines: [String], around line: Int, startNumber: Int? = nil, restartsNestedLists: Bool = false
    ) -> [Edit] {
        let blocks = parse(lines)
        let touching = blocks.indices.filter { blocks[$0].firstLine - 1 <= line && line <= blocks[$0].lastLine + 1 }
        guard !touching.isEmpty else { return [] }
        let anchor = innermostBlock(in: blocks, containing: line)
        // Lists nested inside a touched list are renumbered along with it.
        let affected = blocks.indices.filter { index in
            touching.contains { blocks[$0].firstLine <= blocks[index].firstLine && blocks[index].lastLine <= blocks[$0].lastLine }
        }

        var edits: [Edit] = []
        for index in affected {
            let block = blocks[index]
            // "1. 1. 1." is a deliberate style (Markdown numbers it anyway).
            if block.items.allSatisfy({ $0.number == 1 }) { continue }
            var start = block.items[0].number
            if restartsNestedLists, block.indent > 0, touching.contains(index) {
                start = 1
            } else if index == anchor, let startNumber {
                start = startNumber
            }
            for (offset, item) in block.items.enumerated() where item.number != start + offset {
                edits.append(Edit(line: item.line, range: item.numberRange, replacement: String(start + offset)))
            }
        }
        return edits.sorted { ($0.line, $0.range.location) < ($1.line, $1.range.location) }
    }

    /// The start number of the innermost list containing `line`, to keep a
    /// list's start across an edit that may remove or move its first item.
    static func startNumber(in lines: [String], at line: Int) -> Int? {
        let blocks = parse(lines)
        return innermostBlock(in: blocks, containing: line).map { blocks[$0].items[0].number }
    }

    /// True when the list containing `line` uses the "all ones" style (at
    /// least two items, every one numbered 1), so a new item should be `1.`
    /// too rather than starting a renumbering.
    static func isAllOnesList(in lines: [String], at line: Int) -> Bool {
        let blocks = parse(lines)
        guard let index = innermostBlock(in: blocks, containing: line) else { return false }
        let items = blocks[index].items
        return items.count >= 2 && items.allSatisfy { $0.number == 1 }
    }

    /// True when `line` looks like an ordered list item (fences ignored —
    /// this only decides whether renumbering is worth trying).
    static func isOrderedItem(_ line: String) -> Bool {
        if case .ordered = classify(line).kind { return true }
        return false
    }

    // MARK: Lines

    struct Item: Equatable {
        var line: Int
        var number: Int
        var numberRange: NSRange
    }

    struct Block: Equatable {
        var quoteDepth: Int
        /// Indentation width of the markers (after any quote markers).
        var indent: Int
        var delimiter: Character
        var items: [Item]
        var firstLine: Int
        /// The last non-blank line that belongs to the list.
        var lastLine: Int
        /// A blank line followed since the last line of the list.
        var sawBlank = false
    }

    enum Kind: Equatable {
        case blank
        case code
        case ordered(number: Int, delimiter: Character, numberRange: NSRange)
        case bullet
        case heading
        case thematicBreak
        case text
    }

    struct Line: Equatable {
        var quoteDepth: Int
        /// Width of the leading whitespace (a tab advances to the next
        /// multiple of 4, as in CommonMark) after any quote markers.
        var indent: Int
        var kind: Kind
    }

    /// All ordered lists of the document, nested ones included, in the
    /// order their first items appear.
    ///
    /// One linear pass with a stack of open lists sorted by indentation:
    /// each line closes the lists it cannot belong to and then either adds
    /// an item, opens a list or is content of the lists still open.
    static func parse(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var open: [Int] = []
        var inFence = false
        var fenceIndent = 0

        for (index, text) in lines.enumerated() {
            var line: Line
            if MarkdownSource.isFenceLine(text) {
                if !inFence { fenceIndent = classify(text).indent }
                inFence.toggle()
                line = Line(quoteDepth: 0, indent: fenceIndent, kind: .code)
            } else if inFence {
                // Code content never holds items; it belongs where its fence is.
                line = Line(quoteDepth: 0, indent: fenceIndent, kind: .code)
            } else {
                line = classify(text)
            }

            if line.kind == .blank {
                for block in open { blocks[block].sawBlank = true }
                continue
            }
            open.removeAll { blocks[$0].quoteDepth != line.quoteDepth }

            switch line.kind {
            case .ordered(let number, let delimiter, let range):
                open.removeAll { blocks[$0].indent > line.indent }
                let item = Item(line: index, number: number, numberRange: range)
                if let last = open.last, blocks[last].indent == line.indent, blocks[last].delimiter == delimiter {
                    blocks[last].items.append(item)
                } else {
                    // A different delimiter at the same level starts a new list.
                    if let last = open.last, blocks[last].indent == line.indent { open.removeLast() }
                    blocks.append(Block(
                        quoteDepth: line.quoteDepth, indent: line.indent, delimiter: delimiter,
                        items: [item], firstLine: index, lastLine: index
                    ))
                    open.append(blocks.count - 1)
                }
            case .bullet, .heading, .thematicBreak, .code:
                open.removeAll { blocks[$0].indent >= line.indent }
            case .text:
                // Same-level text right after an item is a lazy continuation;
                // after a blank line it is a new paragraph that ends the list.
                open.removeAll { blocks[$0].indent > line.indent || (blocks[$0].indent == line.indent && blocks[$0].sawBlank) }
            case .blank:
                break
            }
            for block in open {
                blocks[block].sawBlank = false
                blocks[block].lastLine = index
            }
        }
        return blocks
    }

    /// The deepest list whose lines include `line`.
    private static func innermostBlock(in blocks: [Block], containing line: Int) -> Int? {
        blocks.indices
            .filter { blocks[$0].firstLine <= line && line <= blocks[$0].lastLine }
            .max { (blocks[$0].quoteDepth, blocks[$0].indent) < (blocks[$1].quoteDepth, blocks[$1].indent) }
    }

    /// Classifies one line outside fenced code. Works on UTF-16 units: every
    /// structural character is ASCII, and the number ranges are needed in
    /// `NSString` coordinates anyway.
    static func classify(_ text: String) -> Line {
        let units = Array(text.utf16)
        let space: UInt16 = 0x20, tab: UInt16 = 0x09
        var index = 0

        func skipIndent() -> Int {
            var width = 0
            while index < units.count, units[index] == space || units[index] == tab {
                width = units[index] == tab ? width + 4 - width % 4 : width + 1
                index += 1
            }
            return width
        }

        var indent = skipIndent()
        // Blockquote markers: `>` with one optional space, possibly repeated
        // with spaces in between (`> > item`).
        var quoteDepth = 0
        while index < units.count, units[index] == 0x3E {  // ">"
            quoteDepth += 1
            index += 1
            if index < units.count, units[index] == space || units[index] == tab { index += 1 }
            var lookahead = index
            while lookahead < units.count, units[lookahead] == space { lookahead += 1 }
            if lookahead < units.count, units[lookahead] == 0x3E { index = lookahead }
        }
        if quoteDepth > 0 { indent = skipIndent() }

        var rest = units[index...]
        while let last = rest.last, last == space || last == tab || last == 0x0D { rest = rest.dropLast() }
        guard let first = rest.first else { return Line(quoteDepth: quoteDepth, indent: indent, kind: .blank) }

        func isSpaceOrEnd(_ position: Int) -> Bool {
            position >= units.count || units[position] == space || units[position] == tab || units[position] == 0x0D
        }

        // Heading: 1–6 `#` followed by whitespace or the end.
        if first == 0x23 {
            let hashes = rest.prefix { $0 == 0x23 }.count
            if hashes <= 6, isSpaceOrEnd(index + hashes) {
                return Line(quoteDepth: quoteDepth, indent: indent, kind: .heading)
            }
        }
        // Thematic break: three or more of the same `-`, `*` or `_`, spaces
        // allowed. Checked before bullets because `- - -` is one.
        if first == 0x2D || first == 0x2A || first == 0x5F {
            let marks = rest.filter { $0 != space && $0 != tab }
            if marks.count >= 3, marks.allSatisfy({ $0 == first }) {
                return Line(quoteDepth: quoteDepth, indent: indent, kind: .thematicBreak)
            }
            if first != 0x5F, isSpaceOrEnd(index + 1) {
                return Line(quoteDepth: quoteDepth, indent: indent, kind: .bullet)
            }
        }
        if first == 0x2B, isSpaceOrEnd(index + 1) {  // "+"
            return Line(quoteDepth: quoteDepth, indent: indent, kind: .bullet)
        }
        // Ordered: 1–9 digits, `.` or `)`, then whitespace or the end.
        let digits = rest.prefix { $0 >= 0x30 && $0 <= 0x39 }.count
        if (1...9).contains(digits), index + digits < units.count {
            let delimiter = units[index + digits]
            if delimiter == 0x2E || delimiter == 0x29, isSpaceOrEnd(index + digits + 1) {
                let range = NSRange(location: index, length: digits)
                let number = Int(String(decoding: units[index..<index + digits], as: UTF16.self)) ?? 0
                return Line(quoteDepth: quoteDepth, indent: indent, kind: .ordered(
                    number: number, delimiter: delimiter == 0x2E ? "." : ")", numberRange: range
                ))
            }
        }
        return Line(quoteDepth: quoteDepth, indent: indent, kind: .text)
    }
}

// MARK: - Editor

extension EditorController {
    /// The document's lines (without terminators) and the UTF-16 offset of
    /// each line's start.
    private func lineTable() -> (lines: [String], starts: [Int]) {
        let lines = (string as String).components(separatedBy: "\n")
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        return (lines, starts)
    }

    private func lineIndex(of location: Int, starts: [Int]) -> Int {
        max(0, (starts.lastIndex { $0 <= location }) ?? 0)
    }

    /// Makes the ordered list(s) at `location` — and the lists nested in
    /// them — count up from their start number again. Only the digits that
    /// change are replaced, as one text change (call it inside an undo
    /// group); the selection stays on the same characters even when a
    /// number gains or loses a digit.
    ///
    /// - Returns: true when a number changed.
    @discardableResult
    func renumberOrderedList(around location: Int, startingAt startNumber: Int? = nil, restartsNestedLists: Bool = false) -> Bool {
        let (lines, starts) = lineTable()
        let edits = ListRenumbering.edits(
            in: lines, around: lineIndex(of: location, starts: starts),
            startNumber: startNumber, restartsNestedLists: restartsNestedLists
        )
        guard !edits.isEmpty, let storage = textView.textStorage else { return false }

        let ranges = edits.map { NSRange(location: starts[$0.line] + $0.range.location, length: $0.range.length) }
        let replacements = edits.map(\.replacement)
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: replacements)
        else { return false }

        var selection = selectedRange
        // Back to front, so the earlier ranges stay valid.
        storage.beginEditing()
        for (range, replacement) in zip(ranges, replacements).reversed() {
            storage.replaceCharacters(in: range, with: replacement)
            selection = Self.map(selection, replacing: range, withLength: (replacement as NSString).length)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.setSelectedRange(selection)
        return true
    }

    /// Where `selection` ends up after `range` is replaced by text of
    /// `length`: positions after the range shift, positions inside it are
    /// clamped to the replacement.
    private static func map(_ selection: NSRange, replacing range: NSRange, withLength length: Int) -> NSRange {
        func map(_ position: Int) -> Int {
            if position <= range.location { return position }
            if position >= NSMaxRange(range) { return position + length - range.length }
            return range.location + min(position - range.location, length)
        }
        let start = map(selection.location)
        let end = map(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Format ▸ Renumber List: renumbers the list at the caret regardless of
    /// the automatic-renumbering setting.
    func renumberOrderedListAtSelection() {
        textView.breakUndoCoalescing()
        performEdit(actionName: "Renumber List") {
            renumberOrderedList(around: selectedRange.location)
        }
    }

    /// Runs a list-changing `edit` and, when automatic renumbering is on and
    /// an ordered item is involved, renumbers the list at the caret in the
    /// same undo group — one ⌘Z undoes both.
    ///
    /// - Parameters:
    ///   - affecting: the range the edit touches, checked before the edit
    ///     for ordered items (the line at the caret is checked after it).
    ///   - keepsStart: keep the start number the list had before the edit —
    ///     for edits that move or delete lines, which may remove the first
    ///     item.
    ///   - restartsNestedLists: see `ListRenumbering.edits`.
    @discardableResult
    func performListEdit<Result>(
        actionName: String,
        affecting range: NSRange,
        keepsStart: Bool = false,
        restartsNestedLists: Bool = false,
        _ edit: () -> Result
    ) -> Result {
        guard settings.renumbersLists else { return edit() }

        let wasList = lines(in: lineBlock(for: range)).lines.contains(where: ListRenumbering.isOrderedItem)
        var startNumber: Int?
        if keepsStart {
            let (lines, starts) = lineTable()
            startNumber = ListRenumbering.startNumber(in: lines, at: lineIndex(of: selectedRange.location, starts: starts))
        }

        var result: Result?
        performEdit(actionName: actionName) {
            result = edit()
            let caretLines = lines(in: lineBlock(for: selectedRange)).lines
            if wasList || caretLines.contains(where: ListRenumbering.isOrderedItem) {
                renumberOrderedList(
                    around: selectedRange.location, startingAt: startNumber, restartsNestedLists: restartsNestedLists
                )
            }
        }
        // `performEdit` runs its closure synchronously, exactly once.
        return result!
    }

    /// True when automatic renumbering is on and the list at `location`
    /// uses the "all ones" style, so Return should continue it with `1.`.
    func continuesAllOnesList(at location: Int) -> Bool {
        guard settings.renumbersLists else { return false }
        let (lines, starts) = lineTable()
        return ListRenumbering.isAllOnesList(in: lines, at: lineIndex(of: location, starts: starts))
    }
}
