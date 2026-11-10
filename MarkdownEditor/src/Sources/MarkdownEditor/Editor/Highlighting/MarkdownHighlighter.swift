import AppKit

/// Colors Markdown source incrementally and answers "what is the caret in?".
///
/// Two passes. The block pass is line-based: `lineStarts[i]` is the UTF-16
/// offset of line `i`, `lineStates[i]` the `LineState` that line starts in
/// (one extra entry for the state after the last line), `inlineLines[i]`
/// where its inline content is. On an edit the cache is spliced using
/// `changeInLength`, the edited lines (plus the line above, which may be a
/// setext heading) are re-analyzed, and analysis continues only while the
/// state handed to the next line differs from the cached one. Typing ```
/// re-colors to the end of the newly opened (or closed) block.
///
/// The inline pass works per paragraph, because CommonMark parses emphasis,
/// code spans and links across the lines of a paragraph. The lines the block
/// pass touched are widened to whole paragraphs — as they were before the
/// edit and as they are after it, since an edit can merge or split
/// paragraphs — and each paragraph is analyzed as a unit. Typing in a
/// paragraph therefore re-analyzes exactly that paragraph.
///
/// Safety cap: a paragraph longer than `paragraphCap` lines is analyzed in
/// full by `highlightAll`, but an incremental edit extends at most
/// `paragraphWindow` lines beyond the lines the block pass re-analyzed, so a
/// keystroke in a huge unbroken paragraph stays cheap. Inline constructs that
/// span the window's edge can then be stale until the next full pass.
///
/// Fences whose language has a tokenizer are re-colored as a whole block,
/// because tokenizers keep state across lines (block comments, strings).
@MainActor
final class MarkdownHighlighter: EditorHighlighter {
    /// Paragraphs longer than this are only partly re-analyzed on edits.
    static let paragraphCap = 200
    /// How far an incremental edit reaches into a capped paragraph.
    static let paragraphWindow = 50

    var baseFont: NSFont {
        didSet {
            if baseFont != oldValue { theme = HighlightTheme(baseFont: baseFont) }
        }
    }

    private var theme: HighlightTheme
    private(set) var lineStarts: [Int] = [0]
    private(set) var lineStates: [LineState] = [.initial, .initial]
    /// Inline content of each line, parallel to `lineStarts`.
    private(set) var inlineLines: [InlineLine] = [.none]
    /// Length of the text the cache describes.
    private var cachedLength = 0
    /// Lines re-colored by the most recent update — the block pass's lines
    /// widened to whole paragraphs (for tests and tuning).
    private(set) var lastProcessedLines: Range<Int> = 0..<0

    private var analyzer = MarkdownLineAnalyzer()
    private var inlineAnalyzer = MarkdownInlineAnalyzer()
    private var tokenSpans: [HighlightSpan] = []
    /// Reused buffers for joining a paragraph's lines.
    private var unitChars: [UInt16] = []
    private var unitSegments: [InlineSegment] = []

    init(baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
        self.baseFont = baseFont
        theme = HighlightTheme(baseFont: baseFont)
    }

    // MARK: EditorHighlighter

    func highlightAll(_ textStorage: NSTextStorage) {
        textStorage.beginEditing()
        rebuild(textStorage.string as NSString, storage: textStorage)
        textStorage.endEditing()
    }

    func textStorage(_ textStorage: NSTextStorage, didEditRange editedRange: NSRange, changeInLength delta: Int) {
        let text = textStorage.string as NSString
        let oldEnd = NSMaxRange(editedRange) - delta
        guard cachedLength + delta == text.length, editedRange.location >= 0,
              NSMaxRange(editedRange) <= text.length, oldEnd >= editedRange.location, oldEnd <= cachedLength else {
            // The cache does not describe the text before this edit (e.g. the
            // highlighter was swapped in mid-flight): start over.
            rebuild(text, storage: textStorage)
            return
        }

        let first = lineIndex(containing: editedRange.location, in: lineStarts)
        let lastOld = lineIndex(containing: oldEnd, in: lineStarts)

        // Line starts inside the new text of the edited range.
        var inserted: [Int] = []
        if editedRange.length > 0 {
            var buffer = [UInt16](repeating: 0, count: editedRange.length)
            text.getCharacters(&buffer, range: editedRange)
            for (offset, unit) in buffer.enumerated() where unit == Ch.newline {
                inserted.append(editedRange.location + offset + 1)
            }
        }

        // Splice: lines first+1…lastOld are replaced by the inserted ones,
        // later lines shift by `delta`. Their states are placeholders that
        // `run` overwrites before comparing.
        lineStarts.replaceSubrange((first + 1)..<(lastOld + 1), with: inserted)
        if delta != 0 {
            for k in (first + 1 + inserted.count)..<lineStarts.count { lineStarts[k] += delta }
        }
        lineStates.replaceSubrange(
            (first + 1)..<(lastOld + 1),
            with: repeatElement(lineStates[first], count: inserted.count)
        )
        inlineLines.replaceSubrange((first + 1)..<(lastOld + 1), with: repeatElement(.none, count: inserted.count))
        cachedLength = text.length

        // The line above may be paragraph text that the edited line turns
        // into (or out of) a setext heading.
        var start = first
        if first > 0, lineStates[first - 1].block == .normal { start = first - 1 }
        run(text: text, all: nil, storage: textStorage, from: start, minEnd: first + inserted.count + 1, incremental: true)
    }

    func context(at location: Int, in text: NSString) -> EditorContext {
        let starts: [Int]
        let states: [LineState]
        let inlines: [InlineLine]
        if text.length == cachedLength {
            starts = lineStarts
            states = lineStates
            inlines = inlineLines
        } else {
            // Asked about text this highlighter has not seen: scan it.
            let scratch = MarkdownHighlighter(baseFont: baseFont)
            scratch.rebuild(text, storage: nil)
            starts = scratch.lineStarts
            states = scratch.lineStates
            inlines = scratch.inlineLines
        }
        let location = max(0, min(location, text.length))
        let line = lineIndex(containing: location, in: starts)
        let chars = Self.lineChars(line, starts: starts, text: text, length: text.length, all: nil)

        var lineAnalyzer = MarkdownLineAnalyzer(collectsSpans: false, collectsRegions: true)
        _ = lineAnalyzer.analyze(chars, at: starts[line], state: states[line], isFirstLine: line == 0, nextLine: { nil })
        var regions = lineAnalyzer.regions

        // The same paragraph-level analysis as coloring, so a code span that
        // started on an earlier line is still `.inlineCode` here.
        var unclosedMath: [UnclosedMath] = []
        if inlines[line].kind != .none {
            var lo = line
            var hi = line + 1
            if inlines[line].kind == .paragraph {
                while lo > 0, inlines[lo].continues { lo -= 1 }
                while hi < inlines.count, inlines[hi].continues { hi += 1 }
                if hi - lo > Self.paragraphCap {
                    lo = max(lo, line - Self.paragraphWindow)
                    hi = min(hi, line + Self.paragraphWindow + 1)
                }
            }
            var unit = InlineUnitBuilder()
            var inline = MarkdownInlineAnalyzer(collectsSpans: false, collectsRegions: true)
            unit.analyze(lines: lo..<hi, inlines: inlines, starts: starts, text: text, all: nil, length: text.length, with: &inline)
            regions += inline.regions
            unclosedMath = inline.unclosedMath
        }

        if let region = regions.last(where: { $0.location <= location && location <= $0.end }) {
            return region.context
        }
        if states[line].block == .normal,
           unclosedMath.contains(where: { $0.location + 1 < location && location <= $0.lineEnd }) {
            return .inlineMath
        }
        return .markdown
    }

    // MARK: Full pass

    /// Recomputes the whole cache; colors when `storage` is non-nil.
    private func rebuild(_ text: NSString, storage: NSTextStorage?) {
        let length = text.length
        var all = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&all, range: NSRange(location: 0, length: length)) }
        var starts = [0]
        starts.reserveCapacity(length / 32 + 1)
        for (offset, unit) in all.enumerated() where unit == Ch.newline { starts.append(offset + 1) }
        lineStarts = starts
        lineStates = Array(repeating: .initial, count: starts.count + 1)
        inlineLines = Array(repeating: .none, count: starts.count)
        cachedLength = length
        run(text: text, all: all, storage: storage, from: 0, minEnd: starts.count, incremental: false)
    }

    // MARK: Analysis

    /// Analyzes lines from `firstLine` until at least `minEnd` and until the
    /// state entering a line matches the cache again, widens that to whole
    /// paragraphs for the inline pass, then applies colors.
    private func run(text: NSString, all: [UInt16]?, storage: NSTextStorage?, from firstLine: Int, minEnd: Int, incremental: Bool) {
        var i = firstLine
        // Inside a tokenized fence: back up to its opening line.
        while i > 0, case .fence(let fence) = lineStates[i].block, fence.isTokenized { i -= 1 }
        let startLine = i
        let count = lineStarts.count
        // Whether the first line joined the paragraph above *before* the
        // edit; if so that paragraph changed even when it no longer does.
        let continuedBefore = inlineLines[startLine].continues
        analyzer.collectsSpans = storage != nil
        analyzer.reset()
        tokenSpans.removeAll(keepingCapacity: true)

        func line(_ k: Int) -> [UInt16] {
            Self.lineChars(k, starts: lineStarts, text: text, length: cachedLength, all: all)
        }
        func analyzeLine(_ k: Int) -> Bool {
            let next = analyzer.analyze(
                line(k), at: lineStarts[k], state: lineStates[k], isFirstLine: k == 0,
                nextLine: { k + 1 < count ? line(k + 1) : nil }
            )
            inlineLines[k] = analyzer.inlineLine
            let changed = lineStates[k + 1] != next
            lineStates[k + 1] = next
            return changed
        }

        while i < count {
            let entering = lineStates[i]
            var changed = analyzeLine(i)
            i += 1
            if case .fence(let fence) = lineStates[i].block, fence.isTokenized, entering.block == .normal {
                // Analyze the whole block, then tokenize its content at once.
                let contentStart = i
                while i < count, case .fence = lineStates[i].block {
                    changed = analyzeLine(i)
                    i += 1
                }
                let closed: Bool = if case .fence = lineStates[i].block { false } else { true }
                let contentEnd = closed ? lineStarts[i - 1] : (i < count ? lineStarts[i] : cachedLength)
                if storage != nil, contentStart < count {
                    tokenize(text, from: lineStarts[contentStart], to: contentEnd, language: fence.language)
                }
            }
            if i >= minEnd, !changed { break }
        }
        let blockEnd = i

        // Widen to paragraph boundaries. Below `blockEnd` nothing changed:
        // the entering state is the cached one, and whether a line continues
        // a paragraph depends only on that state and the line itself.
        var lo = startLine
        if continuedBefore || inlineLines[lo].continues {
            lo -= 1
            while lo > 0, inlineLines[lo].continues { lo -= 1 }
        }
        var hi = blockEnd
        while hi < count, inlineLines[hi].continues { hi += 1 }
        if incremental {
            // Cap the reach into very long paragraphs (see type comment).
            if lo < startLine {
                var end = startLine + 1
                while end < count, inlineLines[end].continues { end += 1 }
                if end - lo > Self.paragraphCap { lo = max(lo, startLine - Self.paragraphWindow) }
            }
            if hi > blockEnd {
                var begin = blockEnd - 1
                while begin > 0, inlineLines[begin].continues { begin -= 1 }
                if hi - begin > Self.paragraphCap { hi = min(hi, blockEnd + Self.paragraphWindow) }
            }
        }
        lastProcessedLines = lo..<hi

        guard let storage else { return }
        // The widened lines are re-colored as a whole, so they need their
        // block spans (quote and list markers…) again; their states and
        // inline ranges come out unchanged.
        for k in lo..<startLine { _ = analyzeLine(k) }
        for k in blockEnd..<hi { _ = analyzeLine(k) }

        inlineAnalyzer.reset()
        var unit = InlineUnitBuilder(chars: unitChars, segments: unitSegments)
        // Hand the buffers over so appending does not copy them on write.
        unitChars = []
        unitSegments = []
        unit.analyze(lines: lo..<hi, inlines: inlineLines, starts: lineStarts, text: text, all: all, length: cachedLength, with: &inlineAnalyzer)
        unitChars = unit.chars
        unitSegments = unit.segments

        let regionStart = lineStarts[lo]
        let regionEnd = hi < count ? lineStarts[hi] : cachedLength
        apply(to: storage, range: NSRange(location: regionStart, length: regionEnd - regionStart))
    }

    private func tokenize(_ text: NSString, from start: Int, to end: Int, language: String?) {
        guard end > start, let tokenizer = SyntaxHighlighting.tokenizer(for: language) else { return }
        let code = text.substring(with: NSRange(location: start, length: end - start))
        var location = start
        for token in tokenizer.tokenize(code) {
            let length = token.text.utf16.count
            if token.kind != .plain, location + length <= end {
                tokenSpans.append(HighlightSpan(location: location, length: length, style: .token(token.kind)))
            }
            location += length
        }
    }

    /// Block spans first, inline spans over them (inline styles win inside
    /// quotes and headings), fence tokens last.
    private func apply(to storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttributes(theme.baseAttributes, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        for spans in [analyzer.spans, inlineAnalyzer.spans, tokenSpans] {
            for span in spans {
                storage.addAttributes(theme.attributes(for: span.style), range: NSRange(location: span.location, length: span.length))
            }
        }
    }

    // MARK: Lines

    /// The index of the line containing `location` (the last line starting
    /// at or before it).
    private func lineIndex(containing location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Line `index` without its terminator (`\n`, or `\r\n`).
    private static func lineChars(_ index: Int, starts: [Int], text: NSString, length: Int, all: [UInt16]?) -> [UInt16] {
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] - 1 : length
        guard end > start else { return [] }
        var chars: [UInt16]
        if let all {
            chars = Array(all[start..<end])
        } else {
            chars = [UInt16](repeating: 0, count: end - start)
            text.getCharacters(&chars, range: NSRange(location: start, length: end - start))
        }
        if chars.last == Ch.cr { chars.removeLast() }
        return chars
    }
}

/// Groups lines into inline units — paragraphs, single lines, table rows —
/// and feeds their joined content to a `MarkdownInlineAnalyzer`.
private struct InlineUnitBuilder {
    var chars: [UInt16] = []
    var segments: [InlineSegment] = []

    /// Analyzes every unit that starts in `lines`; a paragraph is cut off at
    /// `lines.upperBound` (and starts at `lines.lowerBound` even when that
    /// line continues one above), which is how the incremental cap applies.
    mutating func analyze(
        lines: Range<Int>, inlines: [InlineLine], starts: [Int], text: NSString, all: [UInt16]?, length: Int,
        with analyzer: inout MarkdownInlineAnalyzer
    ) {
        var k = lines.lowerBound
        while k < lines.upperBound {
            let info = inlines[k]
            switch info.kind {
            case .none:
                k += 1
            case .single:
                begin()
                append(line: k, info: info, starts: starts, text: text, all: all)
                analyzer.analyze(chars, segments: segments)
                k += 1
            case .tableRow:
                begin()
                append(line: k, info: info, starts: starts, text: text, all: all)
                analyzer.analyzeTableRow(chars, location: starts[k] + info.start)
                k += 1
            case .paragraph:
                begin()
                append(line: k, info: info, starts: starts, text: text, all: all)
                k += 1
                while k < lines.upperBound, inlines[k].continues {
                    chars.append(Ch.newline)
                    append(line: k, info: inlines[k], starts: starts, text: text, all: all)
                    k += 1
                }
                analyzer.analyze(chars, segments: segments)
            }
        }
    }

    private mutating func begin() {
        chars.removeAll(keepingCapacity: true)
        segments.removeAll(keepingCapacity: true)
    }

    /// Appends line `k`'s inline content and its segment.
    private mutating func append(line k: Int, info: InlineLine, starts: [Int], text: NSString, all: [UInt16]?) {
        let location = starts[k] + info.start
        let count = info.end - info.start
        segments.append(InlineSegment(bufferStart: chars.count, length: count, location: location, traits: info.traits))
        guard count > 0 else { return }
        if let all {
            chars.append(contentsOf: all[location..<(location + count)])
        } else {
            let offset = chars.count
            chars.append(contentsOf: repeatElement(0, count: count))
            chars.withUnsafeMutableBufferPointer { buffer in
                text.getCharacters(buffer.baseAddress! + offset, range: NSRange(location: location, length: count))
            }
        }
    }
}
