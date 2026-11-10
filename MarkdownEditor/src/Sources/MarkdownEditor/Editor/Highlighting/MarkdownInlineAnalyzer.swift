import Foundation

// Inline syntax is analyzed per paragraph, not per line. In CommonMark the
// paragraph is the unit of inline parsing: `**bold\ncontinued**` is bold,
// a code span may contain a line break, and link text may wrap. The line
// analyzer therefore only records *where* each line's inline content is
// (`InlineLine`); the highlighter joins the content of consecutive lines of
// one paragraph into a buffer — prefixes such as `> ` or list markers are
// left out, lines are separated by `\n` — and hands it to this analyzer
// together with segments that map buffer offsets back to the document.
//
// The analyzer follows CommonMark's precedence: one left-to-right scan
// consumes code spans, autolinks, raw HTML, inline math and backslash escapes
// atomically, collects `[` / `![` openers on a bracket stack and `*` `_` `~`
// runs on a delimiter stack; a `]` resolves a link (processing the emphasis
// inside its text first), and the remaining delimiters are paired at the end
// ("process emphasis" with flanking rules and the rule of 3). Inline math
// deliberately stays single-line, like the renderer's `InlineMath`.

// MARK: - Inputs and outputs

/// One line's share of an inline unit: `length` code units at `bufferStart`
/// in the joined buffer, copied from document offset `location`.
struct InlineSegment: Sendable {
    var bufferStart: Int
    var length: Int
    var location: Int
    /// Traits the whole line carries (bold for heading text), merged into
    /// emphasis fonts so `# A *b*` is bold italic.
    var traits: FontTraits

    var bufferEnd: Int { bufferStart + length }
}

/// A `$` that opens inline math without a closer on its line. While the user
/// is still typing `$\alp`, `context(at:)` reports `.inlineMath` after it.
struct UnclosedMath: Sendable {
    var location: Int
    /// Document offset of the end of the `$`'s line.
    var lineEnd: Int
}

// MARK: - Analyzer

/// Analyzes one inline unit (a paragraph, a heading, a table cell) at a time.
/// Reused across units to avoid allocations; `reset()` clears the output.
struct MarkdownInlineAnalyzer {
    var collectsSpans = true
    var collectsRegions = false
    private(set) var spans: [HighlightSpan] = []
    private(set) var regions: [ContextRegion] = []
    private(set) var unclosedMath: [UnclosedMath] = []

    /// A pending span in buffer coordinates.
    private struct Pending {
        var start: Int
        var length: Int
        var style: SpanStyle
    }

    /// A run of `*`, `_` or `~` that may open and/or close emphasis.
    private struct Delimiter {
        var position: Int
        var marker: UInt16
        /// Length of the original run (the rule of 3 looks at it).
        var length: Int
        /// Characters not yet used; openers lose them from the end, closers
        /// from the start. Zero means removed from the stack.
        var count: Int
        var canOpen: Bool
        var canClose: Bool
    }

    /// A `[` (or the `[` of `![`) waiting for its `]`.
    private struct Bracket {
        var position: Int
        var image: Bool
        /// False once a link closed after it: links cannot contain links.
        var active: Bool
        /// Delimiters at or above this index are inside the link text.
        var delimiterBottom: Int
    }

    private var c: [UInt16] = []
    private var segments: [InlineSegment] = []
    /// Color styles that contain other constructs (link text, strikethrough).
    /// Emitted first, outer before inner, so inner styles win.
    private var containers: [Pending] = []
    /// Markers, code, URLs, math…: emitted last, in discovery order.
    private var leaves: [Pending] = []
    /// Emphasis content ranges; merged into per-character traits.
    private var emphasis: [(start: Int, end: Int, traits: FontTraits)] = []
    private var delimiters: [Delimiter] = []
    private var brackets: [Bracket] = []
    /// `noCodeCloser[r] = p`: there is no backtick run of length `r` at or
    /// after `p`, so later searches can stop at once (keeps paragraphs full
    /// of unmatched backticks linear, as cmark does).
    private var noCodeCloser: [Int] = Array(repeating: Int.max, count: 32)

    mutating func reset() {
        spans.removeAll(keepingCapacity: true)
        regions.removeAll(keepingCapacity: true)
        unclosedMath.removeAll(keepingCapacity: true)
    }

    // MARK: Units

    /// Analyzes the joined content of one unit. Output accumulates until
    /// `reset()`.
    mutating func analyze(_ chars: [UInt16], segments: [InlineSegment]) {
        c = chars
        self.segments = segments
        containers.removeAll(keepingCapacity: true)
        leaves.removeAll(keepingCapacity: true)
        emphasis.removeAll(keepingCapacity: true)
        delimiters.removeAll(keepingCapacity: true)
        brackets.removeAll(keepingCapacity: true)
        for k in noCodeCloser.indices { noCodeCloser[k] = Int.max }

        let n = c.count
        var i = 0
        while i < n {
            switch c[i] {
            case Ch.backslash:
                if i + 1 < n, Ch.isPunctuation(c[i + 1]) {
                    leaf(i, 1, .marker)
                    i += 2
                } else {
                    i += 1
                }
            case Ch.backtick:
                let run = MarkdownScan.runLength(c, at: i, to: n)
                if let close = codeSpanCloser(length: run, from: i + run) {
                    leaf(i, run, .marker)
                    leaf(i + run, close - i - run, .inlineCode)
                    leaf(close, run, .marker)
                    region(i + run, close, .inlineCode)
                    i = close + run
                } else {
                    i += run
                }
            case Ch.dollar:
                i = inlineMath(at: i)
            case Ch.lt:
                i = angleBracket(at: i)
            case Ch.bang where i + 1 < n && c[i + 1] == Ch.lbracket:
                brackets.append(Bracket(position: i + 1, image: true, active: true, delimiterBottom: delimiters.count))
                i += 2
            case Ch.lbracket:
                brackets.append(Bracket(position: i, image: false, active: true, delimiterBottom: delimiters.count))
                i += 1
            case Ch.rbracket:
                i = closeBracket(at: i)
            case Ch.star, Ch.underscore, Ch.tilde:
                i = pushDelimiter(at: i)
            case 0x68, 0x77: // h, w: bare URLs
                let to = segmentEnd(containing: i)
                if i == 0 || !Ch.isWord(c[i - 1]), let end = MarkdownScan.bareURL(c, at: i, to: to) {
                    leaf(i, end - i, .link)
                    i = end
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }
        processEmphasis(bottom: 0)
        emit()
        // Drop the references so the caller's buffer is not copied on write.
        c = []
        self.segments = []
    }

    /// A table row: GFM splits cells at unescaped pipes before inline
    /// parsing, so each cell is its own unit and the pipes are markers.
    mutating func analyzeTableRow(_ row: [UInt16], location: Int) {
        let n = row.count
        var cellStart = 0
        var i = 0
        func cell(_ from: Int, _ to: Int) {
            guard to > from else { return }
            analyze(Array(row[from..<to]), segments: [
                InlineSegment(bufferStart: 0, length: to - from, location: location + from, traits: [])
            ])
        }
        while i < n {
            if row[i] == Ch.backslash {
                i += 2
                continue
            }
            if row[i] == Ch.pipe {
                cell(cellStart, i)
                if collectsSpans { spans.append(HighlightSpan(location: location + i, length: 1, style: .marker)) }
                cellStart = i + 1
            }
            i += 1
        }
        cell(cellStart, n)
    }

    // MARK: Code spans and math

    /// Start of the closing backtick run for an opener of `length` whose
    /// content starts at `from`. Backslash escapes do not apply inside code
    /// spans, so the search is raw; it may cross line breaks.
    private mutating func codeSpanCloser(length: Int, from: Int) -> Int? {
        let cacheable = length < noCodeCloser.count
        if cacheable, from >= noCodeCloser[length] { return nil }
        let found = MarkdownScan.findRun(c, Ch.backtick, length: length, from: from, to: c.count)
        if found == nil, cacheable { noCodeCloser[length] = min(noCodeCloser[length], from) }
        return found
    }

    /// True when a backtick run in `from..<to` starts a code span. Math must
    /// not pair across one: code spans bind tighter than everything else.
    private mutating func containsCodeSpan(from: Int, to: Int) -> Bool {
        var q = from
        while q < to {
            if c[q] == Ch.backtick {
                let r = MarkdownScan.runLength(c, at: q, to: c.count)
                if codeSpanCloser(length: r, from: q + r) != nil { return true }
                q += r
            } else {
                q += 1
            }
        }
        return false
    }

    /// `$…$` or `$$…$$` on one line (multi-line math is the `$$` block).
    private mutating func inlineMath(at i: Int) -> Int {
        let to = segmentEnd(containing: i)
        if i + 1 < to, c[i + 1] == Ch.dollar {
            guard let close = MarkdownScan.find(c, Ch.dollar, Ch.dollar, from: i + 2, to: to),
                  !containsCodeSpan(from: i + 2, to: close) else { return i + 2 }
            leaf(i, 2, .marker)
            mathContent(i + 2, close)
            leaf(close, 2, .marker)
            region(i + 2, close, .displayMath)
            return close + 2
        }
        guard let close = inlineMathCloser(opening: i, to: to), !containsCodeSpan(from: i + 1, to: close) else {
            if i + 1 < to, !Ch.isSpace(c[i + 1]), collectsRegions {
                unclosedMath.append(UnclosedMath(location: document(i), lineEnd: document(to)))
            }
            return i + 1
        }
        leaf(i, 1, .marker)
        mathContent(i + 1, close)
        leaf(close, 1, .marker)
        region(i + 1, close, .inlineMath)
        return close + 1
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
        leaf(from, to - from, .math)
        var i = from
        while i < to {
            if c[i] == Ch.backslash, i + 1 < to {
                var end = i + 1
                while end < to, Ch.isLetter(c[end]) { end += 1 }
                if end == i + 1 { end += 1 }
                leaf(i, end - i, .mathCommand)
                i = end
            } else {
                i += 1
            }
        }
    }

    /// `<!-- … -->` (closed on this line; an unclosed one ended the
    /// paragraph in the line pass), autolinks and raw HTML tags.
    private mutating func angleBracket(at i: Int) -> Int {
        let to = segmentEnd(containing: i)
        if MarkdownScan.hasPrefix(c, "<!--", at: i, to: to) {
            guard let close = MarkdownScan.findCommentEnd(c, from: i + 4, to: to) else { return i + 1 }
            leaf(i, close + 3 - i, .comment)
            region(i + 4, close, .htmlComment)
            return close + 3
        }
        if let end = MarkdownScan.autolink(c, at: i, to: to) {
            leaf(i, 1, .marker)
            leaf(i + 1, end - i - 2, .link)
            leaf(end - 1, 1, .marker)
            return end
        }
        if let end = MarkdownScan.htmlTag(c, at: i, to: to) {
            leaf(i, end - i, .html)
            return end
        }
        return i + 1
    }

    // MARK: Links

    /// Resolves `]` against the innermost `[`: `[text](url "title")`,
    /// `[text][ref]`, `![alt](src)` or a footnote reference `[^1]`. Returns
    /// the index to continue scanning at.
    private mutating func closeBracket(at close: Int) -> Int {
        guard let opener = brackets.popLast() else { return close + 1 }
        guard opener.active else { return close + 1 }
        let n = c.count
        let open = opener.position
        let start = opener.image ? open - 1 : open

        if !opener.image, open + 1 < close, c[open + 1] == Ch.caret {
            delimiters.removeSubrange(opener.delimiterBottom...)
            containers.append(Pending(start: open, length: close - open + 1, style: .link))
            return close + 1
        }

        let textStyle: SpanStyle = opener.image ? .image : .link
        var end: Int?
        if close + 1 < n, c[close + 1] == Ch.lparen, let paren = MarkdownScan.matchParen(c, close + 1, to: n) {
            leaf(close, 2, .marker)
            destinationAndTitle(close + 2, paren)
            leaf(paren, 1, .marker)
            end = paren + 1
        } else if close + 1 < n, c[close + 1] == Ch.lbracket,
                  let refClose = c[(close + 2)..<n].firstIndex(of: Ch.rbracket) {
            leaf(close, 2, .marker)
            leaf(close + 2, refClose - close - 2, .url)
            leaf(refClose, 1, .marker)
            end = refClose + 1
        }
        guard let end else { return close + 1 }

        leaf(start, open + 1 - start, .marker)
        containers.append(Pending(start: open + 1, length: close - open - 1, style: textStyle))
        processEmphasis(bottom: opener.delimiterBottom)
        delimiters.removeSubrange(opener.delimiterBottom...)
        if !opener.image {
            for k in brackets.indices where !brackets[k].image { brackets[k].active = false }
        }
        return end
    }

    /// Link destination followed by an optional `"title"`.
    private mutating func destinationAndTitle(_ from: Int, _ to: Int) {
        var titleStart = to
        var i = from
        while i + 1 < to {
            if Ch.isSpace(c[i]) || c[i] == Ch.newline, c[i + 1] == Ch.quote || c[i + 1] == Ch.apostrophe || c[i + 1] == Ch.lparen {
                titleStart = i + 1
                break
            }
            i += 1
        }
        leaf(from, titleStart - from, .url)
        leaf(titleStart, to - titleStart, .linkTitle)
    }

    // MARK: Emphasis

    /// Pushes a `*`, `_` or `~` run with CommonMark's flanking rules. A line
    /// break counts as whitespace, so `**` at the end of a line can close
    /// but not open.
    private mutating func pushDelimiter(at i: Int) -> Int {
        let n = c.count
        let marker = c[i]
        let run = MarkdownScan.runLength(c, at: i, to: n)
        if marker == Ch.tilde, run > 2 { return i + run }
        let before = i > 0 ? c[i - 1] : Ch.newline
        let after = i + run < n ? c[i + run] : Ch.newline
        let beforeSpace = Self.isWhitespace(before)
        let afterSpace = Self.isWhitespace(after)
        let beforePunct = Ch.isPunctuation(before)
        let afterPunct = Ch.isPunctuation(after)
        let left = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
        let right = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
        var canOpen = left
        var canClose = right
        if marker == Ch.underscore {
            // `_` inside a word (snake_case_name) neither opens nor closes.
            canOpen = left && (!right || beforePunct)
            canClose = right && (!left || afterPunct)
        }
        if canOpen || canClose {
            delimiters.append(Delimiter(position: i, marker: marker, length: run, count: run, canOpen: canOpen, canClose: canClose))
        }
        return i + run
    }

    /// CommonMark's "process emphasis" over `delimiters[bottom...]`: each
    /// closer pairs with the nearest compatible opener below it; `~` needs
    /// an opener of the same length (GFM strikethrough).
    private mutating func processEmphasis(bottom: Int) {
        // Lowest index worth searching for an opener, per closer kind
        // (marker, length mod 3, can-open), so failed searches are not
        // repeated — this keeps the pass linear in practice.
        var openersBottom = [Int](repeating: bottom, count: 18)
        var ci = bottom
        while ci < delimiters.count {
            let closer = delimiters[ci]
            guard closer.canClose, closer.count > 0 else {
                ci += 1
                continue
            }
            let kind = closer.marker == Ch.star ? 0 : closer.marker == Ch.underscore ? 1 : 2
            let key = kind * 6 + (closer.length % 3) * 2 + (closer.canOpen ? 1 : 0)
            var found: Int?
            var oi = ci - 1
            while oi >= openersBottom[key] {
                let o = delimiters[oi]
                if o.marker == closer.marker, o.canOpen, o.count > 0 {
                    if closer.marker == Ch.tilde {
                        if o.length == closer.length, o.count == o.length, closer.count == closer.length {
                            found = oi
                            break
                        }
                    } else {
                        let oddMatch = (o.canClose || closer.canOpen) && (o.length + closer.length) % 3 == 0
                            && !(o.length % 3 == 0 && closer.length % 3 == 0)
                        if !oddMatch {
                            found = oi
                            break
                        }
                    }
                }
                oi -= 1
            }
            guard let opener = found else {
                openersBottom[key] = ci
                if !closer.canOpen { delimiters[ci].count = 0 }
                ci += 1
                continue
            }

            let o = delimiters[opener]
            let use = closer.marker == Ch.tilde ? closer.count : (closer.count >= 2 && o.count >= 2 ? 2 : 1)
            let openMarker = o.position + o.count - use
            let closeMarker = closer.position + closer.length - closer.count
            leaf(openMarker, use, .marker)
            leaf(closeMarker, use, .marker)
            if closer.marker == Ch.tilde {
                containers.append(Pending(start: openMarker + use, length: closeMarker - openMarker - use, style: .strikethrough))
            } else {
                emphasis.append((openMarker + use, closeMarker, use == 1 ? .italic : .bold))
            }
            delimiters[opener].count -= use
            delimiters[ci].count -= use
            for k in (opener + 1)..<ci { delimiters[k].count = 0 }
            if delimiters[ci].count == 0 { ci += 1 }
        }
    }

    // MARK: Output

    private mutating func emit() {
        guard collectsSpans else { return }
        containers.sort { $0.start != $1.start ? $0.start < $1.start : $0.length > $1.length }
        for p in containers { output(p.start, p.length, p.style) }
        if !emphasis.isEmpty { emitFonts() }
        for p in leaves { output(p.start, p.length, p.style) }
    }

    /// Turns (possibly nested) emphasis ranges into runs of combined traits:
    /// font attributes replace each other, so `*a **b** c*` needs a
    /// bold-italic run in the middle rather than two overlapping spans.
    private mutating func emitFonts() {
        var events: [(position: Int, bold: Int, italic: Int)] = []
        events.reserveCapacity(emphasis.count * 2)
        for e in emphasis where e.end > e.start {
            let bold = e.traits.contains(.bold) ? 1 : 0
            let italic = e.traits.contains(.italic) ? 1 : 0
            events.append((e.start, bold, italic))
            events.append((e.end, -bold, -italic))
        }
        events.sort { $0.position < $1.position }
        var bold = 0
        var italic = 0
        var k = 0
        while k < events.count {
            let position = events[k].position
            while k < events.count, events[k].position == position {
                bold += events[k].bold
                italic += events[k].italic
                k += 1
            }
            guard k < events.count else { break }
            var traits: FontTraits = []
            if bold > 0 { traits.insert(.bold) }
            if italic > 0 { traits.insert(.italic) }
            if !traits.isEmpty { output(position, events[k].position - position, .font(traits)) }
        }
    }

    /// Emits a span in buffer coordinates as document spans, one per
    /// segment it touches; the `\n` separators and stripped prefixes stay
    /// untouched.
    private mutating func output(_ start: Int, _ length: Int, _ style: SpanStyle) {
        guard length > 0 else { return }
        let end = start + length
        var k = segmentIndex(containing: start)
        while k < segments.count {
            let segment = segments[k]
            if segment.bufferStart >= end { break }
            let a = max(start, segment.bufferStart)
            let b = min(end, segment.bufferEnd)
            if b > a {
                var styled = style
                if case .font(let traits) = style, !segment.traits.isEmpty { styled = .font(traits.union(segment.traits)) }
                spans.append(HighlightSpan(location: segment.location + a - segment.bufferStart, length: b - a, style: styled))
            }
            k += 1
        }
    }

    private mutating func leaf(_ start: Int, _ length: Int, _ style: SpanStyle) {
        guard collectsSpans, length > 0 else { return }
        leaves.append(Pending(start: start, length: length, style: style))
    }

    private mutating func region(_ start: Int, _ end: Int, _ context: EditorContext) {
        guard collectsRegions else { return }
        regions.append(ContextRegion(location: document(start), end: document(end), context: context))
    }

    // MARK: Segments

    /// The last segment starting at or before buffer offset `i`.
    private func segmentIndex(containing i: Int) -> Int {
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].bufferStart <= i { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// End of the line (segment) containing `i`, for single-line constructs.
    private func segmentEnd(containing i: Int) -> Int {
        segments.count == 1 ? c.count : segments[segmentIndex(containing: i)].bufferEnd
    }

    /// Document offset of buffer offset `i`. A separator maps to the end of
    /// the line before it.
    private func document(_ i: Int) -> Int {
        let segment = segments[segmentIndex(containing: i)]
        return segment.location + min(i - segment.bufferStart, segment.length)
    }

    /// Unicode-agnostic whitespace for flanking: space, tab, line break, NBSP.
    private static func isWhitespace(_ ch: UInt16) -> Bool {
        ch == Ch.space || ch == Ch.tab || ch == Ch.newline || ch == Ch.cr || ch == 0xA0
    }
}

// MARK: - Shared scanning primitives

/// Stateless scans over UTF-16 buffers, shared by the line and inline
/// analyzers. All ranges are `from..<to` indices into `c`.
enum MarkdownScan {
    static func runLength(_ c: [UInt16], at i: Int, to: Int) -> Int {
        let ch = c[i]
        var end = i
        while end < to, c[end] == ch { end += 1 }
        return end - i
    }

    /// Start of the next run of exactly `length` `marker`s in `from..<to`.
    static func findRun(_ c: [UInt16], _ marker: UInt16, length: Int, from: Int, to: Int) -> Int? {
        var i = from
        while i < to {
            if c[i] == marker {
                let r = runLength(c, at: i, to: to)
                if r == length { return i }
                i += r
            } else {
                i += 1
            }
        }
        return nil
    }

    /// First unescaped `a` `b` pair in `from..<to`.
    static func find(_ c: [UInt16], _ a: UInt16, _ b: UInt16, from: Int, to: Int) -> Int? {
        var i = from
        while i + 1 < to {
            if c[i] == Ch.backslash {
                i += 2
                continue
            }
            if c[i] == a, c[i + 1] == b { return i }
            i += 1
        }
        return nil
    }

    /// Start of `-->` in `from..<to`.
    static func findCommentEnd(_ c: [UInt16], from: Int, to: Int) -> Int? {
        var i = from
        while i + 2 < to {
            if c[i] == Ch.dash, c[i + 1] == Ch.dash, c[i + 2] == Ch.gt { return i }
            i += 1
        }
        return nil
    }

    static func hasPrefix(_ c: [UInt16], _ prefix: StaticString, at i: Int, to: Int) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard i + count <= to else { return false }
        return prefix.withUTF8Buffer { bytes in
            for k in 0..<count where UInt16(bytes[k]) != c[i + k] { return false }
            return true
        }
    }

    /// The `)` matching the `(` at `open`.
    static func matchParen(_ c: [UInt16], _ open: Int, to: Int) -> Int? {
        var depth = 0
        var i = open
        while i < to {
            switch c[i] {
            case Ch.backslash:
                i += 1
            case Ch.lparen:
                depth += 1
            case Ch.rparen:
                depth -= 1
                if depth == 0 { return i }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// `<https://…>` or `<name@host>`; returns the index after `>`.
    static func autolink(_ c: [UInt16], at i: Int, to: Int) -> Int? {
        var j = i + 1
        var sawColon = false
        var sawAt = false
        guard j < to, Ch.isLetter(c[j]) || Ch.isDigit(c[j]) else { return nil }
        while j < to {
            let ch = c[j]
            if ch == Ch.gt { return (sawColon || sawAt) && j > i + 1 ? j + 1 : nil }
            if Ch.isSpace(ch) || ch == Ch.lt { return nil }
            if ch == Ch.colon { sawColon = true }
            if ch == Ch.at { sawAt = true }
            j += 1
        }
        return nil
    }

    /// `<tag …>`, `</tag>`, `<!DOCTYPE …>`; returns the index after `>`.
    static func htmlTag(_ c: [UInt16], at i: Int, to: Int) -> Int? {
        var j = i + 1
        if j < to, c[j] == Ch.slash || c[j] == Ch.bang { j += 1 }
        guard j < to, Ch.isLetter(c[j]) else { return nil }
        while j < to {
            if c[j] == Ch.gt { return j + 1 }
            if c[j] == Ch.lt { return nil }
            j += 1
        }
        return nil
    }

    /// `http://`, `https://` or `www.` up to whitespace, minus trailing
    /// punctuation; returns the end index.
    static func bareURL(_ c: [UInt16], at i: Int, to: Int) -> Int? {
        let prefixLength: Int
        if hasPrefix(c, "https://", at: i, to: to) {
            prefixLength = 8
        } else if hasPrefix(c, "http://", at: i, to: to) {
            prefixLength = 7
        } else if hasPrefix(c, "www.", at: i, to: to) {
            prefixLength = 4
        } else {
            return nil
        }
        var end = i + prefixLength
        while end < to, !Ch.isSpace(c[end]), c[end] != Ch.lt { end += 1 }
        while end > i + prefixLength {
            let last = c[end - 1]
            if last == Ch.dot || last == Ch.colon || last == 0x2C || last == 0x3B || last == Ch.bang || last == 0x3F
                || last == Ch.star || last == Ch.underscore || last == Ch.tilde || last == Ch.quote
                || last == Ch.apostrophe || last == Ch.rparen {
                end -= 1
            } else {
                break
            }
        }
        return end > i + prefixLength ? end : nil
    }
}
