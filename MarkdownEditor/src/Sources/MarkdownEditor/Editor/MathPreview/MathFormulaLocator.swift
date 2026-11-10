import Foundation

/// A LaTeX formula in the editor text.
struct MathFormula: Equatable, Sendable {
    /// The TeX between the delimiters (UTF-16).
    var contentRange: NSRange
    /// The formula including its delimiters (or fence lines).
    var range: NSRange
    /// `$$ … $$` / ` ```math ` (true) or `$ … $` (false).
    var isDisplay: Bool
    /// False for a block whose closing delimiter has not been typed yet.
    var isTerminated: Bool = true

    func tex(in text: NSString) -> String {
        text.substring(with: contentRange)
    }
}

/// Finds the formula around a caret position by scanning the source text.
///
/// Mirrors the delimiter rules the renderers use — `MathBlocks` for display
/// math (a line starting with `$$`; code fences are verbatim; ` ```math `
/// fences are formulas) and `InlineMath`'s Pandoc-style rules for `$ … $` —
/// so the caret preview appears where the document preview shows a formula,
/// with two deliberate differences that only make sense while typing:
///
/// - an inline formula is *not* required to be structurally valid LaTeX:
///   half-typed TeX is precisely what the caret preview should show, error
///   message included;
/// - a `$$` block without a closing `$$` extends to the next blank line, so
///   the formula being typed previews before its closing delimiter exists.
///
/// The context highlighter answers "am I in math?" too, but the preview also
/// needs the formula's *extent* — and stays correct with any highlighter.
enum MathFormulaLocator {
    private static let dollar = UInt16(UInt8(ascii: "$"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let tilde = UInt16(UInt8(ascii: "~"))
    private static let space = UInt16(UInt8(ascii: " "))
    private static let tab = UInt16(UInt8(ascii: "\t"))

    /// The formula containing `location`: the caret is anywhere from right
    /// after the opening delimiter to right before the closing one.
    static func formula(at location: Int, in text: NSString) -> MathFormula? {
        guard location >= 0, location <= text.length else { return nil }
        switch blockScan(to: location, in: text) {
        case .formula(let formula): return formula
        case .none: return nil
        case .prose(let line): return inlineFormula(at: location, onLine: line, in: text)
        }
    }

    // MARK: Lines

    private struct Line {
        /// Including the line terminator.
        var range: NSRange
        /// Excluding the line terminator.
        var contentsEnd: Int

        var end: Int { NSMaxRange(range) }
    }

    private static func line(at location: Int, in text: NSString) -> Line {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return Line(range: NSRange(location: start, length: end - start), contentsEnd: contentsEnd)
    }

    /// The lines after `previous`, lazily, up to the end of the text.
    private static func lines(after previous: Line, in text: NSString) -> some Sequence<Line> {
        sequence(state: previous.end) { cursor -> Line? in
            guard cursor < text.length else { return nil }
            let next = line(at: cursor, in: text)
            cursor = next.end
            return next
        }
    }

    private static func leadingSpaces(_ line: Line, in text: NSString) -> Int {
        var index = line.range.location
        while index < line.contentsEnd, text.character(at: index) == space { index += 1 }
        return index - line.range.location
    }

    private static func trimmed(_ line: Line, in text: NSString) -> String {
        text.substring(with: NSRange(location: line.range.location, length: line.contentsEnd - line.range.location))
            .trimmingCharacters(in: .whitespaces)
    }

    /// End of the line's text without trailing blanks.
    private static func trimmedEnd(_ line: Line, notBefore floor: Int, in text: NSString) -> Int {
        var end = line.contentsEnd
        while end > floor, [space, tab].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    // MARK: Blocks

    private enum BlockResult {
        case formula(MathFormula)
        /// Inside a code fence, or on a `$$` line outside the formula.
        case none
        /// Not inside any block; the line holding the location.
        case prose(line: NSRange)
    }

    /// One block found by the top-down scan.
    private struct Block {
        /// The formula, nil for a code fence.
        var formula: MathFormula?
        /// Start of the first line after the block.
        var nextLineStart: Int
    }

    /// Walks the document line by line from the top — block structure
    /// (fences, `$$`) can only be decided from the start — until the block
    /// or line containing `location` is known.
    private static func blockScan(to location: Int, in text: NSString) -> BlockResult {
        var start = 0
        while true {
            let current = line(at: start, in: text)
            if let block = fencedBlock(startingWith: current, in: text) ?? displayBlock(startingWith: current, in: text) {
                let isLastBlock = block.nextLineStart >= text.length
                if location < block.nextLineStart || isLastBlock {
                    if let formula = block.formula,
                       location >= formula.contentRange.location, location <= NSMaxRange(formula.contentRange) {
                        return .formula(formula)
                    }
                    return .none
                }
                start = block.nextLineStart
                continue
            }
            if location < current.end || current.end >= text.length {
                return .prose(line: current.range)
            }
            start = current.end
        }
    }

    /// A ` ``` ` / `~~~` code fence opening on `first`. ` ```math ` fences
    /// are display formulas (as in `MathBlocks`); any other fence is code.
    private static func fencedBlock(startingWith first: Line, in text: NSString) -> Block? {
        guard leadingSpaces(first, in: text) < 4 else { return nil }
        let opener = trimmed(first, in: text)
        guard let character = (["`", "~"] as [Character]).first(where: { opener.hasPrefix(String(repeating: $0, count: 3)) }) else {
            return nil
        }
        let length = opener.prefix { $0 == character }.count
        let language = opener.dropFirst(length).trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: " ").first.map(String.init)

        let close = lines(after: first, in: text).first { candidate in
            guard leadingSpaces(candidate, in: text) < 4 else { return false }
            let content = trimmed(candidate, in: text)
            let run = content.prefix { $0 == character }.count
            return run >= length && run == content.count
        }
        let nextLineStart = close?.end ?? text.length
        guard language == MathBlocks.language else { return Block(formula: nil, nextLineStart: nextLineStart) }

        let bodyStart = first.end
        // The body ends before the newline that precedes the closing fence.
        let bodyEnd = close.map { max(bodyStart, $0.range.location - 1) } ?? text.length
        return Block(
            formula: MathFormula(
                contentRange: NSRange(location: bodyStart, length: bodyEnd - bodyStart),
                range: NSRange(location: first.range.location, length: (close?.contentsEnd ?? text.length) - first.range.location),
                isDisplay: true,
                isTerminated: close != nil
            ),
            nextLineStart: nextLineStart
        )
    }

    /// A `$$` block opening on `first`, read as `MathBlocks.mathBlock` does.
    private static func displayBlock(startingWith first: Line, in text: NSString) -> Block? {
        guard leadingSpaces(first, in: text) < 4 else { return nil }
        var opener = first.range.location
        while opener < first.contentsEnd, [space, tab].contains(text.character(at: opener)) { opener += 1 }
        guard opener + 1 < first.contentsEnd,
              text.character(at: opener) == dollar, text.character(at: opener + 1) == dollar
        else { return nil }
        let contentStart = opener + 2

        func block(closingAt closer: Int, on line: Line, terminated: Bool = true) -> Block {
            Block(
                formula: MathFormula(
                    contentRange: NSRange(location: contentStart, length: closer - contentStart),
                    range: NSRange(location: opener, length: (terminated ? closer + 2 : closer) - opener),
                    isDisplay: true,
                    isTerminated: terminated
                ),
                nextLineStart: line.end
            )
        }

        // Single line: `$$ E = mc^2 $$`.
        let firstEnd = trimmedEnd(first, notBefore: contentStart, in: text)
        if firstEnd - contentStart > 2,
           text.character(at: firstEnd - 1) == dollar, text.character(at: firstEnd - 2) == dollar {
            return block(closingAt: firstEnd - 2, on: first)
        }

        // Multi line: the first line that is `$$` or ends with `$$` closes.
        var lastBeforeBlank: Line?
        var previous = first
        for current in lines(after: first, in: text) {
            if trimmed(current, in: text).hasSuffix("$$") {
                return block(closingAt: trimmedEnd(current, notBefore: current.range.location, in: text) - 2, on: current)
            }
            if lastBeforeBlank == nil, trimmed(current, in: text).isEmpty { lastBeforeBlank = previous }
            previous = current
        }

        // Unterminated: up to the next blank line (or the end of the text),
        // so the block being typed previews before its closing `$$` exists.
        let last = lastBeforeBlank ?? previous
        return block(closingAt: max(contentStart, last.contentsEnd), on: last, terminated: false)
    }

    // MARK: Inline

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == 0xA0 || unit == 0x0A || unit == 0x0D
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }

    /// `$ … $` on the caret's line, applying `InlineMath`'s delimiter rules.
    /// Code spans are skipped, as the Markdown parser would.
    private static func inlineFormula(at location: Int, onLine lineRange: NSRange, in text: NSString) -> MathFormula? {
        let units = Array((text.substring(with: lineRange) as String).utf16)
        let caret = location - lineRange.location
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == backtick {
                var run = 0
                while index + run < units.count, units[index + run] == backtick { run += 1 }
                index = closingCodeSpan(units, after: index + run, length: run) ?? index + run
                continue
            }
            if unit == dollar, !isEscaped(units, at: index), let close = inlineClose(units, openingAt: index) {
                if caret > index, caret <= close {
                    return MathFormula(
                        contentRange: NSRange(location: lineRange.location + index + 1, length: close - index - 1),
                        range: NSRange(location: lineRange.location + index, length: close - index + 1),
                        isDisplay: false
                    )
                }
                index = close + 1
                continue
            }
            index += 1
        }
        return nil
    }

    /// End index (exclusive) of a code span whose opening backtick run of
    /// `length` ends at `start`, or nil when it is never closed.
    private static func closingCodeSpan(_ units: [UInt16], after start: Int, length: Int) -> Int? {
        var index = start
        while index < units.count {
            guard units[index] == backtick else { index += 1; continue }
            var run = 0
            while index + run < units.count, units[index + run] == backtick { run += 1 }
            if run == length { return index + run }
            index += run
        }
        return nil
    }

    /// Index of the closing `$` for an opener at `start` — the rules of
    /// `InlineMath.formula(in:openingAt:)` minus its validity gate.
    private static func inlineClose(_ units: [UInt16], openingAt start: Int) -> Int? {
        let contentStart = start + 1
        guard contentStart < units.count, !isWhitespace(units[contentStart]) else { return nil }
        var end = contentStart
        while end < units.count {
            if units[end] == dollar {
                if isEscaped(units, at: end) { end += 1; continue }
                guard end > contentStart, !isWhitespace(units[end - 1]) else { return nil }
                if end + 1 < units.count, isDigit(units[end + 1]) { return nil }
                return end
            }
            end += 1
        }
        return nil
    }

    private static func isEscaped(_ units: [UInt16], at index: Int) -> Bool {
        var count = 0
        var cursor = index - 1
        while cursor >= 0, units[cursor] == backslash {
            count += 1
            cursor -= 1
        }
        return !count.isMultiple(of: 2)
    }
}
