import Foundation

// The Markdown highlighter works line by line. Each line is analyzed with
// only two inputs: its own UTF-16 code units and the `LineState` the previous
// line left behind (open fence, `$$` block, front matter, HTML comment, plus
// a few flags that decide between "paragraph continuation", "indented code"
// and "setext underline"). That makes incremental re-highlighting simple: re-
// analyze the edited lines and keep going only while the state a line hands
// to its successor differs from the cached one.
//
// Inline syntax (emphasis, code spans, links) is not colored here: CommonMark
// parses it per paragraph, and `**bold` may close on the next line. The line
// pass only records where a line's inline content is and whether it
// continues the paragraph above (`InlineLine`); `MarkdownInlineAnalyzer`
// colors whole paragraphs afterwards. Whether a line continues a paragraph is
// a function of the line and its `LineState` alone, so the incremental
// invariant ("same entering state, same result") covers paragraph grouping
// too.
//
// The analyzer is deliberately not a full CommonMark parser. It colors what a
// writer sees — markers, code, math, links — and errs on the side of being
// local and fast. The preview is the source of truth for rendering.

// MARK: - Line state

/// An open fenced code block.
struct FenceInfo: Equatable, Sendable {
    /// `` ` `` or `~`.
    var marker: UInt16
    /// Number of marker characters in the opening fence; the closing fence
    /// needs at least as many.
    var length: Int
    /// First word of the info string, lowercased; nil without one.
    var language: String?
    /// True when `SyntaxHighlighting` has a tokenizer for `language`. Such
    /// blocks are tokenized as a whole (tokenizers carry state across lines,
    /// e.g. block comments), so they are always re-colored as a unit.
    var isTokenized: Bool
}

/// The multi-line construct a line starts in.
enum BlockKind: Equatable, Sendable {
    case normal
    case fence(FenceInfo)
    case displayMath
    case frontMatter
    case htmlComment
}

/// What a line inherits from the lines above it.
struct LineState: Equatable, Sendable {
    var block: BlockKind = .normal
    /// The previous line was paragraph text, so an indented line continues
    /// it (instead of starting indented code) and `===` / `---` underline it.
    var paragraph = false
    /// Inside a list, where indented lines are item content, not code.
    var list = false
    /// The previous line was blank (or this is the first line).
    var afterBlank = true
    /// Quote depth of the paragraph the previous line belongs to, or -1 when
    /// it was not paragraph text. A paragraph-text line with at most this
    /// many `>` continues that paragraph (lazy continuation); unlike
    /// `paragraph` this is also set inside block quotes and list items.
    var paragraphQuotes = -1

    static let initial = LineState()
}

/// Where a line's inline content is and how it groups with its neighbors.
/// The highlighter joins consecutive `.paragraph` lines (the first one, then
/// every following line with `continues`) into one inline unit.
struct InlineLine: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        /// No inline content (blank, fence, rule, code, front matter…).
        case none
        /// Paragraph text, including list item and block quote paragraphs.
        case paragraph
        /// A one-line unit: heading text, text after a closing `$$` / `-->`,
        /// footnote definition text.
        case single
        /// A table row; each cell is its own unit.
        case tableRow
    }

    var kind: Kind = .none
    /// Content range relative to the line start: after quote markers, list
    /// markers and indentation, before trailing heading `#`s.
    var start = 0
    var end = 0
    /// Traits of the whole line (bold for heading text).
    var traits: FontTraits = []
    /// Continues the paragraph of the line above.
    var continues = false

    static let none = InlineLine()
}

// MARK: - Output

struct FontTraits: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let bold = FontTraits(rawValue: 1)
    static let italic = FontTraits(rawValue: 2)
}

/// A semantic style; `HighlightTheme` maps each to attributes.
enum SpanStyle: Hashable, Sendable {
    /// Markdown punctuation that is dimmed relative to content: `#`, `**`,
    /// backticks, link brackets, fences, table pipes, horizontal rules.
    case marker
    case heading
    /// Font traits only (emphasis / strong); color is left alone.
    case font(FontTraits)
    case strikethrough
    case inlineCode
    /// Background of fenced and indented code lines.
    case codeBlock
    case fenceInfo
    case link
    case url
    case image
    case linkTitle
    case quote
    case quoteMarker
    case listMarker
    case taskBox
    case html
    case comment
    case frontMatterKey
    case frontMatterValue
    case math
    case mathCommand
    case token(TokenKind)
    case mermaidKeyword
    case mermaidArrow
    case mermaidText
}

struct HighlightSpan: Equatable, Sendable {
    var location: Int
    var length: Int
    var style: SpanStyle
}

/// A range in which the caret has a non-Markdown context. `end` is
/// inclusive: a caret right before a closing `` ` `` or `$` is still inside.
struct ContextRegion: Sendable {
    var location: Int
    var end: Int
    var context: EditorContext
}

// MARK: - Characters

/// UTF-16 code units the analyzer looks at.
enum Ch {
    static let tab: UInt16 = 0x09
    static let newline: UInt16 = 0x0A
    static let cr: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let bang: UInt16 = 0x21
    static let quote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let percent: UInt16 = 0x25
    static let apostrophe: UInt16 = 0x27
    static let lparen: UInt16 = 0x28
    static let rparen: UInt16 = 0x29
    static let star: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let dash: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A
    static let lt: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let gt: UInt16 = 0x3E
    static let at: UInt16 = 0x40
    static let lbracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let rbracket: UInt16 = 0x5D
    static let caret: UInt16 = 0x5E
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lbrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C
    static let rbrace: UInt16 = 0x7D
    static let tilde: UInt16 = 0x7E

    @inline(__always) static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }
    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    @inline(__always) static func isLetter(_ c: UInt16) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
    /// Word characters for emphasis flanking; non-ASCII counts as a letter.
    @inline(__always) static func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c >= 0x80 }
    static func isPunctuation(_ c: UInt16) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
}

// MARK: - Analyzer

/// Analyzes one line at a time; collects spans (for coloring) and context
/// regions (for `context(at:)`). Reused across lines to avoid allocations.
struct MarkdownLineAnalyzer {
    var collectsSpans = true
    var collectsRegions = false
    private(set) var spans: [HighlightSpan] = []
    private(set) var regions: [ContextRegion] = []
    /// Where the line just analyzed has inline content (relative offsets).
    private(set) var inlineLine = InlineLine.none

    /// The current line (without terminator) and its document offset.
    private var c: [UInt16] = []
    private var base = 0

    mutating func reset() {
        spans.removeAll(keepingCapacity: true)
        regions.removeAll(keepingCapacity: true)
    }

    /// Appends a span in document coordinates (for tokens colored outside).
    mutating func append(_ span: HighlightSpan) {
        if collectsSpans { spans.append(span) }
    }

    /// Analyzes `chars` (one line, no terminator) starting in `state`;
    /// returns the state the next line starts in and sets `inlineLine`.
    /// `nextLine` is consulted only for setext headings (`Title` above `===`).
    mutating func analyze(
        _ chars: [UInt16], at start: Int, state: LineState, isFirstLine: Bool,
        nextLine: () -> [UInt16]?
    ) -> LineState {
        c = chars
        base = start
        inlineLine = .none
        let n = c.count
        switch state.block {
        case .normal:
            return normalLine(state: state, isFirstLine: isFirstLine, nextLine: nextLine)

        case .frontMatter:
            region(0, n, .frontMatter)
            if isFrontMatterDelimiter(closing: true) {
                span(0, n, .marker)
                return LineState(block: .normal, paragraph: false, list: false, afterBlank: true)
            }
            frontMatterLine()
            return state

        case .fence(let fence):
            span(0, n, .codeBlock)
            if isFenceCloser(fence) {
                span(0, n, .marker)
                return LineState(block: .normal, paragraph: false, list: state.list, afterBlank: false)
            }
            switch fence.language {
            case "mermaid":
                region(0, n, .mermaid)
                mermaidLine()
            case "math", "latex", "tex":
                region(0, n, .displayMath)
                mathContent(0, n)
            default:
                region(0, n, .codeBlock(language: fence.language))
            }
            return state

        case .displayMath:
            if let close = find(Ch.dollar, Ch.dollar, from: 0, to: n) {
                region(0, close, .displayMath)
                mathContent(0, close)
                span(close, 2, .marker)
                let opens = inlineContent(close + 2, n, .single)
                return LineState(block: opens ? .htmlComment : .normal, paragraph: false, list: state.list, afterBlank: false)
            }
            region(0, n, .displayMath)
            mathContent(0, n)
            return state

        case .htmlComment:
            if let close = findCommentEnd(from: 0, to: n) {
                region(0, close, .htmlComment)
                span(0, close + 3, .comment)
                let opens = inlineContent(close + 3, n, .single)
                return LineState(block: opens ? .htmlComment : .normal, paragraph: false, list: state.list, afterBlank: false)
            }
            region(0, n, .htmlComment)
            span(0, n, .comment)
            return state
        }
    }

    // MARK: Block structure

    private mutating func normalLine(state: LineState, isFirstLine: Bool, nextLine: () -> [UInt16]?) -> LineState {
        let n = c.count
        if isFirstLine, isFrontMatterDelimiter(closing: false) {
            span(0, n, .marker)
            region(0, n, .frontMatter)
            return LineState(block: .frontMatter, paragraph: false, list: false, afterBlank: false)
        }

        var pos = 0
        var columns = 0
        while pos < n, Ch.isSpace(c[pos]) {
            columns += c[pos] == Ch.tab ? 4 - columns % 4 : 1
            pos += 1
        }
        if pos == n {
            return LineState(block: .normal, paragraph: false, list: state.list, afterBlank: true)
        }
        if columns >= 4, !state.paragraph, !state.list {
            span(0, n, .codeBlock)
            region(0, n, .codeBlock(language: nil))
            return LineState(block: .normal, paragraph: false, list: false, afterBlank: false)
        }

        // A block that starts at the left margin ends a list.
        let atMargin = columns < 2
        let listAfterBlock = atMargin ? false : state.list
        func after(_ opensComment: Bool, paragraph: Bool = false, list: Bool) -> LineState {
            LineState(block: opensComment ? .htmlComment : .normal, paragraph: paragraph && !opensComment, list: list, afterBlank: false)
        }

        var quotes = 0
        while pos < n, c[pos] == Ch.gt {
            span(pos, 1, .quoteMarker)
            pos += 1
            quotes += 1
            while pos < n, Ch.isSpace(c[pos]) { pos += 1 }
        }
        let quoted = quotes > 0
        if quoted {
            span(pos, n - pos, .quote)
            if pos == n { return after(false, list: listAfterBlock) }
        }

        if !quoted, let (fence, markerEnd) = fenceOpener(at: pos) {
            span(0, n, .codeBlock)
            span(pos, markerEnd - pos, .marker)
            span(markerEnd, n - markerEnd, .fenceInfo)
            region(markerEnd, n, .fenceInfo)
            return LineState(block: .fence(fence), paragraph: false, list: listAfterBlock, afterBlank: false)
        }

        if !quoted, pos + 1 < n, c[pos] == Ch.dollar, c[pos + 1] == Ch.dollar {
            span(pos, 2, .marker)
            if let close = find(Ch.dollar, Ch.dollar, from: pos + 2, to: n) {
                region(pos + 2, close, .displayMath)
                mathContent(pos + 2, close)
                span(close, 2, .marker)
                return after(inlineContent(close + 2, n, .single), list: listAfterBlock)
            }
            region(pos + 2, n, .displayMath)
            mathContent(pos + 2, n)
            return LineState(block: .displayMath, paragraph: false, list: listAfterBlock, afterBlank: false)
        }

        if c[pos] == Ch.hash {
            var hashes = pos
            while hashes < n, c[hashes] == Ch.hash { hashes += 1 }
            if hashes - pos <= 6, hashes == n || Ch.isSpace(c[hashes]) {
                span(pos, hashes - pos, .marker)
                var end = n
                while end > hashes, Ch.isSpace(c[end - 1]) { end -= 1 }
                var closing = end
                while closing > hashes, c[closing - 1] == Ch.hash { closing -= 1 }
                if closing < end, closing == hashes || Ch.isSpace(c[closing - 1]) {
                    span(closing, end - closing, .marker)
                    end = closing
                }
                span(hashes, end - hashes, .heading)
                return after(inlineContent(hashes, end, .single, traits: .bold), list: listAfterBlock)
            }
        }

        if !quoted, state.paragraph, columns < 4, Self.isSetextUnderline(c) {
            span(pos, n - pos, .heading)
            return after(false, list: state.list)
        }

        if isThematicBreak(from: pos) {
            span(pos, n - pos, .marker)
            return after(false, list: listAfterBlock)
        }

        if let markerEnd = listMarker(at: pos) {
            span(pos, markerEnd - pos, .listMarker)
            var text = markerEnd
            while text < n, Ch.isSpace(c[text]) { text += 1 }
            if text + 2 < n, c[text] == Ch.lbracket, c[text + 2] == Ch.rbracket,
               c[text + 1] == Ch.space || c[text + 1] | 0x20 == 0x78,
               text + 3 == n || Ch.isSpace(c[text + 3]) {
                span(text, 3, .taskBox)
                text += 3
            }
            // A list item starts a new paragraph; its continuation lines
            // (indented or lazy) join it.
            let opens = inlineContent(text, n, .paragraph)
            var next = after(opens, list: true)
            next.paragraphQuotes = opens ? -1 : quotes
            return next
        }

        if c[pos] == Ch.pipe {
            if isTableDelimiterRow(from: pos) {
                span(pos, n - pos, .marker)
                return after(false, list: listAfterBlock)
            }
            return after(inlineContent(pos, n, .tableRow), list: listAfterBlock)
        }

        if c[pos] == Ch.lbracket, columns < 4, referenceDefinition(at: pos) {
            return after(false, list: listAfterBlock)
        }

        // Paragraph text. Lazy continuation keeps a list open unless a blank
        // line came first.
        let list = atMargin && state.afterBlank ? false : state.list
        var traits: FontTraits = []
        if !quoted, columns < 4, let next = nextLine(), Self.isSetextUnderline(next) {
            span(pos, n - pos, .heading)
            traits = .bold
        }
        // It continues the paragraph above unless it is nested deeper in
        // quotes than that paragraph (`a` then `> b` starts a quote).
        let continues = state.paragraphQuotes >= 0 && quotes <= state.paragraphQuotes
        let opens = inlineContent(pos, n, .paragraph, traits: traits, continues: continues)
        var next = after(opens, paragraph: !quoted, list: list)
        next.paragraphQuotes = opens ? -1 : continues ? state.paragraphQuotes : quotes
        return next
    }

    private func isFrontMatterDelimiter(closing: Bool) -> Bool {
        var end = c.count
        while end > 0, Ch.isSpace(c[end - 1]) { end -= 1 }
        guard end == 3 else { return false }
        if c[0] == Ch.dash, c[1] == Ch.dash, c[2] == Ch.dash { return true }
        return closing && c[0] == Ch.dot && c[1] == Ch.dot && c[2] == Ch.dot
    }

    /// Opening fence at `pos`: the fence and the index after its markers.
    private func fenceOpener(at pos: Int) -> (FenceInfo, Int)? {
        let n = c.count
        let marker = c[pos]
        guard marker == Ch.backtick || marker == Ch.tilde else { return nil }
        var end = pos
        while end < n, c[end] == marker { end += 1 }
        guard end - pos >= 3 else { return nil }
        if marker == Ch.backtick, c[end...].contains(Ch.backtick) { return nil }
        var wordStart = end
        while wordStart < n, Ch.isSpace(c[wordStart]) || c[wordStart] == Ch.lbrace || c[wordStart] == Ch.dot {
            wordStart += 1
        }
        var wordEnd = wordStart
        while wordEnd < n, !Ch.isSpace(c[wordEnd]), c[wordEnd] != Ch.lbrace, c[wordEnd] != Ch.rbrace { wordEnd += 1 }
        let language = wordEnd > wordStart ? String(decoding: c[wordStart..<wordEnd], as: UTF16.self).lowercased() : nil
        let fence = FenceInfo(
            marker: marker, length: end - pos, language: language,
            isTokenized: SyntaxHighlighting.tokenizer(for: language) != nil
        )
        return (fence, end)
    }

    private func isFenceCloser(_ fence: FenceInfo) -> Bool {
        let n = c.count
        var pos = 0
        while pos < n, Ch.isSpace(c[pos]) { pos += 1 }
        var end = pos
        while end < n, c[end] == fence.marker { end += 1 }
        guard end - pos >= fence.length else { return false }
        while end < n, Ch.isSpace(c[end]) { end += 1 }
        return end == n
    }

    /// `===` or `--` (at least two dashes, so typing a list item under a
    /// paragraph does not flash a heading).
    static func isSetextUnderline(_ line: [UInt16]) -> Bool {
        let n = line.count
        var pos = 0
        while pos < n, pos < 3, line[pos] == Ch.space { pos += 1 }
        guard pos < n, line[pos] == Ch.equals || line[pos] == Ch.dash else { return false }
        let marker = line[pos]
        var end = pos
        while end < n, line[end] == marker { end += 1 }
        let run = end - pos
        while end < n, Ch.isSpace(line[end]) { end += 1 }
        return end == n && (marker == Ch.equals || run >= 2)
    }

    private func isThematicBreak(from pos: Int) -> Bool {
        let marker = c[pos]
        guard marker == Ch.dash || marker == Ch.star || marker == Ch.underscore else { return false }
        var count = 0
        for ch in c[pos...] {
            if ch == marker { count += 1 } else if !Ch.isSpace(ch) { return false }
        }
        return count >= 3
    }

    /// End of a list marker (`-`, `*`, `+`, `1.`, `1)`) at `pos`.
    private func listMarker(at pos: Int) -> Int? {
        let n = c.count
        var end = pos
        if c[pos] == Ch.dash || c[pos] == Ch.star || c[pos] == Ch.plus {
            end = pos + 1
        } else {
            while end < n, end - pos < 9, Ch.isDigit(c[end]) { end += 1 }
            guard end > pos, end < n, c[end] == Ch.dot || c[end] == Ch.rparen else { return nil }
            end += 1
        }
        return end == n || Ch.isSpace(c[end]) ? end : nil
    }

    private func isTableDelimiterRow(from pos: Int) -> Bool {
        var dashes = false
        for ch in c[pos...] {
            switch ch {
            case Ch.dash: dashes = true
            case Ch.pipe, Ch.colon, Ch.space, Ch.tab: continue
            default: return false
            }
        }
        return dashes
    }

    /// `[label]: destination "title"` or a footnote definition `[^1]: text`.
    private mutating func referenceDefinition(at pos: Int) -> Bool {
        let n = c.count
        guard let close = matchBracket(pos, to: n), close + 1 < n, c[close + 1] == Ch.colon, close > pos + 1 else {
            return false
        }
        span(pos, 1, .marker)
        span(pos + 1, close - pos - 1, .link)
        span(close, 2, .marker)
        if c[pos + 1] == Ch.caret {
            _ = inlineContent(close + 2, n, .single)
        } else {
            var dest = close + 2
            while dest < n, Ch.isSpace(c[dest]) { dest += 1 }
            destinationAndTitle(dest, n)
        }
        return true
    }

    private mutating func frontMatterLine() {
        let n = c.count
        var pos = 0
        while pos < n, Ch.isSpace(c[pos]) { pos += 1 }
        guard pos < n else { return }
        if c[pos] == Ch.hash {
            span(pos, n - pos, .comment)
            return
        }
        if c[pos] == Ch.dash, pos + 1 == n || Ch.isSpace(c[pos + 1]) {
            span(pos, 1, .listMarker)
            pos += 1
            while pos < n, Ch.isSpace(c[pos]) { pos += 1 }
        }
        var colon = pos
        while colon < n, c[colon] != Ch.colon, c[colon] != Ch.space { colon += 1 }
        if colon < n, colon > pos, c[colon] == Ch.colon, colon + 1 == n || Ch.isSpace(c[colon + 1]) {
            span(pos, colon - pos, .frontMatterKey)
            span(colon, 1, .marker)
            span(colon + 1, n - colon - 1, .frontMatterValue)
        } else {
            span(pos, n - pos, .frontMatterValue)
        }
    }

    // MARK: Inline content

    /// Records `from..<to` as this line's inline content (analyzed later,
    /// per paragraph, by `MarkdownInlineAnalyzer`). An unclosed `<!--` cuts
    /// the content short: it is colored here and returns true, because the
    /// next line then starts inside the comment — block state must not
    /// depend on the paragraph-level pass.
    private mutating func inlineContent(
        _ from: Int, _ to: Int, _ kind: InlineLine.Kind, traits: FontTraits = [], continues: Bool = false
    ) -> Bool {
        var end = to
        var opens = false
        if let open = unclosedComment(from, to) {
            span(open, to - open, .comment)
            region(open + 4, to, .htmlComment)
            end = open
            opens = true
        }
        if end > from || kind == .paragraph {
            inlineLine = InlineLine(kind: kind, start: from, end: end, traits: traits, continues: continues)
        }
        return opens
    }

    /// Start of a `<!--` in `from..<to` that is not closed on this line.
    /// Escapes, code spans, math and complete comments are skipped the way
    /// the inline pass skips them, but line-locally, so block state stays a
    /// function of the line and the state it starts in.
    private func unclosedComment(_ from: Int, _ to: Int) -> Int? {
        var i = from
        while i < to {
            switch c[i] {
            case Ch.backslash:
                i += i + 1 < to && Ch.isPunctuation(c[i + 1]) ? 2 : 1
            case Ch.backtick:
                let run = runLength(at: i, to: to)
                i = findRun(Ch.backtick, length: run, from: i + run, to: to).map { $0 + run } ?? i + run
            case Ch.dollar:
                if i + 1 < to, c[i + 1] == Ch.dollar {
                    i = find(Ch.dollar, Ch.dollar, from: i + 2, to: to).map { $0 + 2 } ?? i + 2
                } else {
                    i = inlineMathCloser(opening: i, to: to).map { $0 + 1 } ?? i + 1
                }
            case Ch.lt where hasPrefix("<!--", at: i, to: to):
                guard let close = findCommentEnd(from: i + 4, to: to) else { return i }
                i = close + 3
            default:
                i += 1
            }
        }
        return nil
    }

    /// The closing `$` for an opening `$` at `i`: the opener must not be
    /// followed by a space, the closer must not be preceded by a space (or a
    /// backslash) nor followed by a digit — so `$5 and $10` stays text.
    private func inlineMathCloser(opening i: Int, to: Int) -> Int? {
        guard i + 1 < to, !Ch.isSpace(c[i + 1]), c[i + 1] != Ch.dollar else { return nil }
        var q = i + 2
        while q < to {
            if c[q] == Ch.backslash {
                q += 2
                continue
            }
            if c[q] == Ch.dollar, !Ch.isSpace(c[q - 1]), !(q + 1 < to && Ch.isDigit(c[q + 1])) {
                return q
            }
            q += 1
        }
        return nil
    }

    private mutating func mathContent(_ from: Int, _ to: Int) {
        guard to > from else { return }
        span(from, to - from, .math)
        var i = from
        while i < to {
            if c[i] == Ch.backslash, i + 1 < to {
                var end = i + 1
                while end < to, Ch.isLetter(c[end]) { end += 1 }
                if end == i + 1 { end += 1 }
                span(i, end - i, .mathCommand)
                i = end
            } else {
                i += 1
            }
        }
    }

    /// Link destination followed by an optional `"title"`.
    private mutating func destinationAndTitle(_ from: Int, _ to: Int) {
        var titleStart = to
        var i = from
        while i + 1 < to {
            if Ch.isSpace(c[i]), c[i + 1] == Ch.quote || c[i + 1] == Ch.apostrophe || c[i + 1] == Ch.lparen {
                titleStart = i + 1
                break
            }
            i += 1
        }
        span(from, titleStart - from, .url)
        span(titleStart, to - titleStart, .linkTitle)
    }

    private func matchBracket(_ open: Int, to: Int) -> Int? {
        var depth = 0
        var i = open
        while i < to {
            switch c[i] {
            case Ch.backslash:
                i += 2
                continue
            case Ch.backtick:
                let r = runLength(at: i, to: to)
                i = findRun(Ch.backtick, length: r, from: i + r, to: to).map { $0 + r } ?? i + r
                continue
            case Ch.lbracket:
                depth += 1
            case Ch.rbracket:
                depth -= 1
                if depth == 0 { return i }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    // MARK: Mermaid

    private static let mermaidKeywords: Set<String> = [
        "graph", "flowchart", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram", "journey",
        "gantt", "pie", "gitGraph", "mindmap", "timeline", "quadrantChart", "requirementDiagram",
        "C4Context", "sankey", "xychart", "block", "packet", "architecture", "kanban",
        "subgraph", "end", "participant", "actor", "note", "Note", "loop", "alt", "else", "opt", "par",
        "and", "rect", "critical", "break", "activate", "deactivate", "autonumber", "title", "section",
        "class", "classDef", "style", "linkStyle", "click", "direction", "dateFormat", "axisFormat",
        "state", "commit", "branch", "checkout", "merge", "over", "left", "right", "of",
        "TB", "TD", "BT", "RL", "LR"
    ]

    private mutating func mermaidLine() {
        let n = c.count
        var p = 0
        while p < n, Ch.isSpace(c[p]) { p += 1 }
        if hasPrefix("%%", at: p, to: n) {
            span(p, n - p, .comment)
            return
        }
        while p < n {
            let ch = c[p]
            if Ch.isLetter(ch) {
                var end = p
                while end < n, Ch.isLetter(c[end]) || Ch.isDigit(c[end]) || c[end] == Ch.underscore { end += 1 }
                if Self.mermaidKeywords.contains(String(decoding: c[p..<end], as: UTF16.self)) {
                    span(p, end - p, .mermaidKeyword)
                }
                p = end
            } else if ch == Ch.lbracket || ch == Ch.lparen || ch == Ch.lbrace || ch == Ch.quote || ch == Ch.pipe {
                let closer: UInt16 = switch ch {
                case Ch.lbracket: Ch.rbracket
                case Ch.lparen: Ch.rparen
                case Ch.lbrace: Ch.rbrace
                default: ch
                }
                var depth = 0
                var q = p
                var close: Int?
                while q < n {
                    if c[q] == closer, closer != ch || q > p {
                        depth -= 1
                        if depth <= 0 { close = q; break }
                    } else if c[q] == ch {
                        depth += 1
                    }
                    q += 1
                }
                if let close {
                    span(p, close - p + 1, .mermaidText)
                    p = close + 1
                } else {
                    p += 1
                }
            } else if ch == Ch.dash || ch == Ch.equals || ch == Ch.dot || ch == Ch.lt || ch == Ch.gt {
                var end = p
                var hasLine = false
                while end < n, c[end] == Ch.dash || c[end] == Ch.equals || c[end] == Ch.dot || c[end] == Ch.lt || c[end] == Ch.gt {
                    if c[end] == Ch.dash || c[end] == Ch.equals { hasLine = true }
                    end += 1
                }
                if end - p >= 2, hasLine { span(p, end - p, .mermaidArrow) }
                p = end
            } else {
                p += 1
            }
        }
    }

    // MARK: Primitives

    private mutating func span(_ from: Int, _ length: Int, _ style: SpanStyle) {
        guard collectsSpans, length > 0 else { return }
        spans.append(HighlightSpan(location: base + from, length: length, style: style))
    }

    private mutating func region(_ from: Int, _ end: Int, _ context: EditorContext) {
        guard collectsRegions else { return }
        regions.append(ContextRegion(location: base + from, end: base + end, context: context))
    }

    // Line-relative wrappers around the shared `MarkdownScan` primitives.

    private func runLength(at i: Int, to: Int) -> Int { MarkdownScan.runLength(c, at: i, to: to) }

    private func findRun(_ marker: UInt16, length: Int, from: Int, to: Int) -> Int? {
        MarkdownScan.findRun(c, marker, length: length, from: from, to: to)
    }

    private func find(_ a: UInt16, _ b: UInt16, from: Int, to: Int) -> Int? {
        MarkdownScan.find(c, a, b, from: from, to: to)
    }

    private func findCommentEnd(from: Int, to: Int) -> Int? { MarkdownScan.findCommentEnd(c, from: from, to: to) }

    private func hasPrefix(_ prefix: StaticString, at i: Int, to: Int) -> Bool {
        MarkdownScan.hasPrefix(c, prefix, at: i, to: to)
    }
}
