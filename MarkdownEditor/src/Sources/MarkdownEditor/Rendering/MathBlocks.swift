import Foundation
import Markdown

/// Normalizes LaTeX display math (`$$ … $$`) into ` ```math ` fenced code
/// blocks *before* the document is parsed.
///
/// swift-markdown is a CommonMark/GFM parser and knows nothing about LaTeX —
/// a `$$ … $$` block would otherwise arrive as an ordinary paragraph full of
/// literal dollar signs. Rewriting it into a fence with the `math` language
/// means every renderer sees a plain `CodeBlock` and can treat formulas
/// exactly the way it already treats ` ```mermaid ` fences: no second parse,
/// no AST surgery, one shared code path.
///
/// Recognized (outside of code fences, indented by at most 3 spaces):
///
/// ```
/// $$                      $$ E = mc^2 $$      $$ a = b
/// E = mc^2                                    + c $$
/// $$
/// ```
///
/// An unterminated `$$` is left untouched, so a stray dollar pair never eats
/// the rest of the document.
enum MathBlocks {
    /// The fence language formulas are normalized to — the contract between
    /// this preprocessor and both renderers.
    static let language = "math"

    private static let delimiter = "$$"

    /// The single entry point every renderer parses through: display math is
    /// normalized into ` ```math ` fences before parsing, inline math is
    /// rewritten on the resulting AST. Both the live preview and the PDF
    /// export call this, so the two renderers can never drift apart.
    static func parse(_ markdown: String) -> Document {
        parseMapped(markdown).document
    }

    /// Like `parse`, but also returns the map from the parsed (preprocessed)
    /// text's lines back to the author's lines — the preview's scroll sync
    /// and diagnostics need line numbers of the *editor* text, while
    /// swift-markdown only knows the rewritten one.
    static func parseMapped(_ markdown: String) -> (document: Document, lineMap: LineMap) {
        let preprocessed = preprocessMapped(markdown)
        return (InlineMath.rewrite(Document(parsing: preprocessed.text)), preprocessed.lineMap)
    }

    static func preprocess(_ markdown: String) -> String {
        preprocessMapped(markdown).text
    }

    /// The rewrite plus its line map. A single-line `$$ x $$` grows into a
    /// three-line fence and a `$$ a` … `b $$` block can gain lines too, so
    /// every line after the first formula would otherwise be off.
    static func preprocessMapped(_ markdown: String) -> (text: String, lineMap: LineMap) {
        // Footnotes first: they only blank lines and append after the end,
        // so the math line map below still points at the editor's lines.
        let markdown = Footnotes.rewrite(blankingFrontMatter(markdown))
        // Cheap bail-out: no delimiter, nothing to do (every keystroke passes here).
        guard markdown.contains(delimiter) else { return (markdown, .identity) }

        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)
        // origins[i] = 0-based index in `lines` that output line i came from.
        var origins: [Int] = []
        origins.reserveCapacity(lines.count)
        func emit(_ line: String, from origin: Int) {
            output.append(line)
            origins.append(origin)
        }

        var openFence: (character: Character, length: Int)?
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Inside a code fence everything is verbatim — a ` ```markdown `
            // block documenting `$$` syntax must survive unchanged.
            if let fence = openFence {
                emit(line, from: index)
                if closesFence(line, fence) { openFence = nil }
                index += 1
                continue
            }
            if let fence = opensFence(line) {
                emit(line, from: index)
                openFence = fence
                index += 1
                continue
            }

            if let math = mathBlock(in: lines, startingAt: index) {
                // Opening fence ↔ the `$$` line, closing fence ↔ the line
                // holding the closing `$$`, each TeX line ↔ where it was typed.
                let fence = fence(for: math.body.map(\.text))
                emit("\(fence)\(language)", from: index)
                for bodyLine in math.body { emit(bodyLine.text, from: bodyLine.origin) }
                emit(fence, from: math.nextIndex - 1)
                index = math.nextIndex
                continue
            }

            emit(line, from: index)
            index += 1
        }

        return (output.joined(separator: "\n"), LineMap(origins: origins.map { $0 + 1 }))
    }

    // MARK: Math blocks

    /// Matches a display-math block starting on `lines[start]`, returning its
    /// TeX body and the index of the first line after the closing delimiter.
    /// YAML front matter (`---` on the very first line … `---` or `...`) is
    /// metadata, not content: CommonMark would render it as a rule plus a
    /// setext heading. Each of its lines is replaced by an empty line, so the
    /// line count — and with it every line number after it — stays the same.
    static func blankingFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---") else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        guard lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return markdown }
        guard let end = lines.indices.dropFirst().first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return line == "---" || line == "..."
        }) else { return markdown }
        for index in 0...end { lines[index] = "" }
        return lines.joined(separator: "\n")
    }

    private static func mathBlock(
        in lines: [String],
        startingAt start: Int
    ) -> (body: [(text: String, origin: Int)], nextIndex: Int)? {
        let first = lines[start]
        // 4+ spaces of indentation is an indented code block in CommonMark.
        guard leadingSpaces(first) < 4 else { return nil }

        let opener = first.trimmingCharacters(in: .whitespaces)
        guard opener.hasPrefix(delimiter) else { return nil }

        // Single line: `$$ E = mc^2 $$`
        let afterOpener = String(opener.dropFirst(delimiter.count))
        if afterOpener.hasSuffix(delimiter), afterOpener.count > delimiter.count {
            let body = String(afterOpener.dropLast(delimiter.count)).trimmingCharacters(in: .whitespaces)
            return (body.isEmpty ? [] : [(body, start)], start + 1)
        }
        // Multi line: scan for the closing `$$`.
        var body: [(text: String, origin: Int)] = []
        let inlineStart = afterOpener.trimmingCharacters(in: .whitespaces)
        if !inlineStart.isEmpty { body.append((inlineStart, start)) }

        var index = start + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == delimiter {
                return (body, index + 1)
            }
            if trimmed.hasSuffix(delimiter) {
                let tail = String(trimmed.dropLast(delimiter.count)).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { body.append((tail, index)) }
                return (body, index + 1)
            }
            body.append((lines[index], index))
            index += 1
        }

        return nil // Unterminated — leave the source alone.
    }

    /// A backtick fence long enough to survive any backtick run the formula
    /// might contain.
    private static func fence(for body: [String]) -> String {
        let longestRun = body.reduce(0) { longest, line in
            var longest = longest
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
            return longest
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    // MARK: Code fences

    private static func opensFence(_ line: String) -> (character: Character, length: Int)? {
        guard leadingSpaces(line) < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for character in ["`", "~"] as [Character] {
            let run = trimmed.prefix { $0 == character }.count
            if run >= 3 { return (character, run) }
        }
        return nil
    }

    private static func closesFence(_ line: String, _ fence: (character: Character, length: Int)) -> Bool {
        guard leadingSpaces(line) < 4 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == fence.character }.count
        // A closing fence is at least as long as the opener and carries no info string.
        return run >= fence.length && run == trimmed.count
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

/// Maps 1-based line numbers of the text swift-markdown parsed back to the
/// 1-based line numbers of the text the author typed (see
/// `MathBlocks.preprocessMapped`).
struct LineMap: Equatable, Sendable {
    /// `origins[i]` is the original line of parsed line `i + 1`; empty for
    /// the identity map (the common case: no `$$` in the document).
    let origins: [Int]

    static let identity = LineMap(origins: [])

    /// The original line of a parsed `line`. Lines past the end (the parser
    /// may report the line after a trailing newline) continue linearly.
    func originalLine(_ line: Int) -> Int {
        guard !origins.isEmpty, line >= 1 else { return line }
        if line <= origins.count { return origins[line - 1] }
        return origins[origins.count - 1] + (line - origins.count)
    }
}
