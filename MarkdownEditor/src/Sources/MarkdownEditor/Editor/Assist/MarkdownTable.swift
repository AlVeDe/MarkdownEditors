import Foundation

/// A parsed GFM pipe table, and the code that lays it out again aligned.
///
/// Kept free of AppKit and of the editor so the formatting rules can be
/// tested on plain strings. Rows are addressed by *line index* within the
/// table: 0 is the header, 1 the delimiter row, 2… the body rows.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case none, left, center, right }

    /// Leading whitespace of the header line, applied to every line (tables
    /// nested in list items stay nested).
    var indent: String
    var leadingPipe: Bool
    var trailingPipe: Bool
    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    var columnCount: Int {
        max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
    }

    /// Number of lines the formatted table has.
    var lineCount: Int { rows.count + 2 }

    // MARK: Parsing

    /// Parses `lines` (header, delimiter, body rows; no line terminators).
    /// Nil unless the second line is a delimiter row.
    init?(lines: [String]) {
        guard lines.count >= 2, let delimiter = Self.alignments(ofDelimiterRow: lines[1]) else { return nil }
        let headerLine = lines[0]
        let headerRow = Self.parseRow(headerLine)
        guard !headerRow.cells.isEmpty else { return nil }
        indent = String(headerLine.prefix { $0 == " " || $0 == "\t" })
        leadingPipe = headerRow.leadingPipe
        trailingPipe = headerRow.trailingPipe
        header = headerRow.cells
        alignments = delimiter
        rows = lines.dropFirst(2).map { Self.parseRow($0).cells }
    }

    struct Row {
        var cells: [String]
        /// UTF-16 ranges (within the line) of each cell's raw segment, the
        /// text between two pipes including the padding.
        var segments: [NSRange]
        var leadingPipe: Bool
        var trailingPipe: Bool
    }

    /// Splits a row at unescaped pipes. (GFM splits even inside code spans;
    /// only `\|` keeps a pipe in the cell.)
    static func parseRow(_ line: String) -> Row {
        let string = line as NSString
        var pipes: [Int] = []
        var index = 0
        while index < string.length {
            let character = string.character(at: index)
            if character == 0x5C /* \ */ {
                index += 2
                continue
            }
            if character == 0x7C /* | */ { pipes.append(index) }
            index += 1
        }
        var segments: [NSRange] = []
        var start = 0
        for pipe in pipes {
            segments.append(NSRange(location: start, length: pipe - start))
            start = pipe + 1
        }
        segments.append(NSRange(location: start, length: string.length - start))

        func isBlank(_ range: NSRange) -> Bool {
            string.substring(with: range).allSatisfy(\.isWhitespace)
        }
        let leading = !pipes.isEmpty && isBlank(segments[0])
        let trailing = pipes.count > (leading ? 1 : 0) && isBlank(segments[segments.count - 1])
        if leading { segments.removeFirst() }
        if trailing { segments.removeLast() }
        let cells = segments.map { string.substring(with: $0).trimmingCharacters(in: .whitespaces) }
        return Row(cells: cells, segments: segments, leadingPipe: leading, trailingPipe: trailing)
    }

    /// The column alignments when `line` is a delimiter row (`|:--|--:|`).
    static func alignments(ofDelimiterRow line: String) -> [Alignment]? {
        guard line.contains("|") || line.contains("-") else { return nil }
        let row = parseRow(line)
        // Without any pipe, `---` is a thematic break, not a table.
        guard line.contains("|"), !row.cells.isEmpty else { return nil }
        var result: [Alignment] = []
        for cell in row.cells {
            guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":") && cell.count > 1) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result
    }

    static func isDelimiterRow(_ line: String) -> Bool {
        alignments(ofDelimiterRow: line) != nil
    }

    /// True for a line that could be part of a table (has an unescaped pipe).
    static func looksLikeRow(_ line: String) -> Bool {
        let row = parseRow(line)
        return row.segments.count > 1 || row.leadingPipe || row.trailingPipe
    }

    // MARK: Cell addressing

    /// Which cell of a raw row line a UTF-16 offset is in, and how far into
    /// the cell's trimmed content (clamped to it).
    static func cell(at offset: Int, inLine line: String) -> (column: Int, offsetInContent: Int) {
        let row = parseRow(line)
        guard !row.segments.isEmpty else { return (0, 0) }
        let string = line as NSString
        var column = row.segments.count - 1
        for (index, segment) in row.segments.enumerated() where offset <= NSMaxRange(segment) {
            column = index
            break
        }
        let segment = row.segments[column]
        let raw = string.substring(with: segment) as NSString
        let leadingSpace = (raw as String).prefix { $0 == " " || $0 == "\t" }.utf16.count
        let contentLength = (row.cells[column] as NSString).length
        let inContent = offset - segment.location - leadingSpace
        return (column, min(max(0, inContent), contentLength))
    }

    // MARK: Formatting

    /// The aligned text (lines joined by `lineEnding`, no trailing line
    /// ending) and, per line index and column, the UTF-16 range of the
    /// cell's content within that text (empty cells: a zero-length range
    /// where typing should go). Delimiter-row ranges cover the dashes.
    func formatted(lineEnding: String = "\n") -> (text: String, cells: [[NSRange]]) {
        let columns = max(1, columnCount)
        func padded(_ row: [String]) -> [String] {
            row + Array(repeating: "", count: max(0, columns - row.count))
        }
        let header = padded(header)
        let body = rows.map(padded)
        let alignments = alignments + Array(repeating: Alignment.none, count: max(0, columns - alignments.count))

        var widths = Array(repeating: 3, count: columns)
        for row in [header] + body {
            for (column, cell) in row.enumerated() {
                widths[column] = max(widths[column], Self.displayWidth(cell))
            }
        }

        var text = ""
        var length = 0  // UTF-16 length of `text`
        var ranges: [[NSRange]] = []

        func append(_ piece: String) {
            text += piece
            length += piece.utf16.count
        }

        func appendLine(_ cells: [String], isDelimiter: Bool) {
            var lineRanges: [NSRange] = []
            append(indent)
            if leadingPipe { append("| ") }
            let lineStart = length
            for column in 0..<columns {
                if column > 0 { append(" | ") }
                let content = cells[column]
                let padding = widths[column] - Self.displayWidth(content)
                let (before, after): (Int, Int) = switch alignments[column] {
                case .right where !isDelimiter: (padding, 0)
                case .center where !isDelimiter: (padding / 2, padding - padding / 2)
                default: (0, padding)
                }
                append(String(repeating: " ", count: before))
                lineRanges.append(NSRange(location: length, length: content.utf16.count))
                append(content)
                append(String(repeating: " ", count: after))
            }
            if trailingPipe {
                append(" |")
            } else {
                // No trailing pipe: don't leave trailing whitespace behind.
                while text.hasSuffix(" "), length > lineStart {
                    text.removeLast()
                    length -= 1
                }
            }
            ranges.append(lineRanges)
        }

        appendLine(header, isDelimiter: false)
        append(lineEnding)
        let delimiterCells = (0..<columns).map { Self.delimiterCell(alignments[$0], width: widths[$0]) }
        appendLine(delimiterCells, isDelimiter: true)
        for row in body {
            append(lineEnding)
            appendLine(row, isDelimiter: false)
        }
        // Clamp ranges that trimming may have cut (empty trailing cells).
        let total = length
        ranges = ranges.map { $0.map { NSRange(location: min($0.location, total), length: min($0.length, total - min($0.location, total))) } }
        return (text, ranges)
    }

    static func delimiterCell(_ alignment: Alignment, width: Int) -> String {
        let width = max(3, width)
        switch alignment {
        case .none: return String(repeating: "-", count: width)
        case .left: return ":" + String(repeating: "-", count: width - 1)
        case .right: return String(repeating: "-", count: width - 1) + ":"
        case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
        }
    }

    /// Width in monospaced columns: East Asian wide and fullwidth
    /// characters (and most emoji) take two.
    static func displayWidth(_ string: String) -> Int {
        string.reduce(0) { total, character in
            guard let scalar = character.unicodeScalars.first?.value else { return total }
            let wide = (0x1100...0x115F).contains(scalar)
                || (0x2E80...0xA4CF).contains(scalar)
                || (0xAC00...0xD7A3).contains(scalar)
                || (0xF900...0xFAFF).contains(scalar)
                || (0xFE30...0xFE4F).contains(scalar)
                || (0xFF00...0xFF60).contains(scalar)
                || (0xFFE0...0xFFE6).contains(scalar)
                || (0x1F300...0x1F64F).contains(scalar)
                || (0x1F900...0x1F9FF).contains(scalar)
                || (0x20000...0x3FFFD).contains(scalar)
            return total + (wide ? 2 : 1)
        }
    }
}
