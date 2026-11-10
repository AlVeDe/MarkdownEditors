import Foundation
import Markdown

/// Finds LaTeX written between single `$` delimiters inside running text and
/// marks it for the renderers.
///
/// Unlike display math (`$$ … $$`, see `MathBlocks`), an inline formula sits
/// *inside* a paragraph, so it cannot be normalized into a fenced code block.
/// It is instead rewritten **on the parsed AST**: every `Text` node is split
/// into the prose around the formula and an `InlineCode` node carrying the TeX
/// behind a sentinel prefix. Working on the AST rather than on the source text
/// means code spans (`` `$PATH` ``), link destinations and raw HTML are
/// skipped for free — the parser has already separated them from running text.
///
/// `$` is an everyday character in prose, so a candidate only becomes a
/// formula when it clears two independent gates:
///
/// 1. **Delimiter rules** (as in Pandoc): the opening `$` is not followed by
///    whitespace, the closing `$` is not preceded by whitespace and not
///    followed by a digit, and no `$` appears in between. This is what keeps
///    `$5 and $10 net` prose.
/// 2. **Structural LaTeX validity** (`isValidLatex`): balanced braces,
///    `\left`/`\right` and environments, well-formed control sequences,
///    sub/superscripts with an argument, no TeX comment or parameter
///    character.
///
/// Anything that fails either gate is left exactly as the author typed it.
enum InlineMath {
    /// Prefix that turns an `InlineCode` node into a formula carrier. U+0001
    /// cannot occur in a parsed Markdown document, so there is no chance of a
    /// collision with real inline code.
    static let marker = "\u{1}tex\u{1}"

    /// The TeX inside a carrier node, or `nil` for ordinary inline code.
    static func tex(of inlineCode: InlineCode) -> String? {
        guard inlineCode.code.hasPrefix(marker) else { return nil }
        return String(inlineCode.code.dropFirst(marker.count))
    }

    /// Returns the document with every valid `$ … $` span replaced by a
    /// carrier node.
    static func rewrite(_ document: Document) -> Document {
        (rewritten(document).markup as? Document) ?? document
    }

    /// Rebuilds `markup` only if something below it actually changed, so a
    /// document without inline math comes back as the very same tree.
    private static func rewritten(_ markup: Markup) -> (markup: Markup, changed: Bool) {
        var children: [Markup] = []
        var changed = false

        for child in markup.children {
            if let text = child as? Markdown.Text {
                let pieces = split(text.string)
                guard pieces.contains(where: { $0.tex != nil }) else {
                    children.append(child)
                    continue
                }
                changed = true
                children.append(contentsOf: pieces.map { piece in
                    piece.tex.map { InlineCode(marker + $0) as Markup } ?? Markdown.Text(piece.text)
                })
            } else {
                // Leaves (inline code, raw HTML, code blocks) have no children
                // and come back untouched.
                let result = rewritten(child)
                changed = changed || result.changed
                children.append(result.markup)
            }
        }

        return changed ? (markup.withUncheckedChildren(children), true) : (markup, false)
    }

    // MARK: Scanning

    /// One run of a split `Text` node: either prose (`tex == nil`) or a
    /// formula.
    struct Piece {
        var text: String
        var tex: String?
    }

    /// Splits running text into prose and formula runs. Text without a valid
    /// `$ … $` pair comes back as a single prose piece.
    static func split(_ text: String) -> [Piece] {
        guard text.contains("$") else { return [Piece(text: text, tex: nil)] }

        let characters = Array(text)
        var pieces: [Piece] = []
        var prose = ""
        var index = 0

        while index < characters.count {
            guard characters[index] == "$",
                  !isEscaped(characters, at: index),
                  let formula = formula(in: characters, openingAt: index)
            else {
                prose.append(characters[index])
                index += 1
                continue
            }
            if !prose.isEmpty {
                pieces.append(Piece(text: prose, tex: nil))
                prose = ""
            }
            pieces.append(Piece(text: "", tex: formula.tex))
            index = formula.nextIndex
        }

        if !prose.isEmpty { pieces.append(Piece(text: prose, tex: nil)) }
        return pieces.isEmpty ? [Piece(text: text, tex: nil)] : pieces
    }

    /// Matches `$ … $` starting at `start`, applying both gates.
    private static func formula(
        in characters: [Character],
        openingAt start: Int
    ) -> (tex: String, nextIndex: Int)? {
        // The opening `$` must be followed by non-whitespace.
        let contentStart = start + 1
        guard contentStart < characters.count, !characters[contentStart].isWhitespace else { return nil }

        var end = contentStart
        while end < characters.count {
            let character = characters[end]
            // `\$` is a literal dollar belonging to the formula, not a delimiter.
            if character == "$", isEscaped(characters, at: end) {
                end += 1
                continue
            }
            // A second `$` inside the span means this is not a formula.
            if character == "$", end > contentStart {
                // The closing `$` must not be preceded by whitespace…
                guard !characters[end - 1].isWhitespace else { return nil }
                // …nor followed by a digit (`$10$20` is a price range).
                if end + 1 < characters.count, characters[end + 1].isNumber { return nil }

                let tex = String(characters[contentStart..<end])
                guard tex.count <= maximumLength, isValidLatex(tex) else { return nil }
                return (tex, end + 1)
            }
            if character == "$" { return nil }
            end += 1
        }
        return nil // No closing delimiter on this run of text.
    }

    /// An inline formula longer than this is far more likely to be prose that
    /// happens to sit between two dollar signs.
    private static let maximumLength = 300

    /// Whether the character at `index` is preceded by an odd number of
    /// backslashes, i.e. escaped.
    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        var backslashes = 0
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == "\\" {
            backslashes += 1
            cursor -= 1
        }
        return backslashes.isMultiple(of: 2) == false
    }

    // MARK: Validation

    /// Checks that `tex` is *structurally* valid LaTeX.
    ///
    /// This is a structural check, not a semantic one: unknown macros pass
    /// (there is no macro list to fall out of date), but anything TeX itself
    /// could not parse is rejected — unbalanced braces, environments or
    /// `\left`/`\right`, a dangling control sequence, a sub/superscript
    /// without an argument, or a character that only means something outside
    /// math mode.
    static func isValidLatex(_ tex: String) -> Bool {
        guard !tex.isEmpty, !tex.contains(where: \.isNewline) else { return false }

        let characters = Array(tex)
        var braceDepth = 0
        var leftRightDepth = 0
        var environments: [String] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\\" {
                guard index + 1 < characters.count else { return false } // dangling `\`
                let next = characters[index + 1]

                guard next.isLetter else {
                    // `\$`, `\{`, `\,`, `\\`, … — any punctuation escape is
                    // fine; `\5` or `\<control>` is not.
                    guard next.isPunctuation || next.isSymbol || next == " " else { return false }
                    index += 2
                    continue
                }

                var nameEnd = index + 1
                var name = ""
                while nameEnd < characters.count, characters[nameEnd].isLetter {
                    name.append(characters[nameEnd])
                    nameEnd += 1
                }

                switch name {
                case "left":
                    leftRightDepth += 1
                case "right":
                    leftRightDepth -= 1
                    if leftRightDepth < 0 { return false }
                case "begin", "end":
                    guard let environment = environmentName(characters, after: nameEnd) else { return false }
                    if name == "begin" {
                        environments.append(environment.name)
                    } else if environments.popLast() != environment.name {
                        return false
                    }
                    nameEnd = environment.nextIndex
                default:
                    break // Unknown macros are accepted — see the doc comment.
                }
                index = nameEnd
                continue
            }

            switch character {
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth < 0 { return false }
            case "%", "#":
                return false // TeX comment / macro parameter — not valid here.
            case "&":
                // Column separator: only meaningful inside an environment.
                if environments.isEmpty { return false }
            case "^", "_":
                // Needs something to apply to.
                guard index + 1 < characters.count else { return false }
                let next = characters[index + 1]
                if next == "^" || next == "_" || next == "}" || next == "&" { return false }
            default:
                break
            }
            index += 1
        }

        return braceDepth == 0 && leftRightDepth == 0 && environments.isEmpty
    }

    /// Reads the `{name}` argument of `\begin` / `\end`.
    private static func environmentName(
        _ characters: [Character],
        after index: Int
    ) -> (name: String, nextIndex: Int)? {
        guard index < characters.count, characters[index] == "{" else { return nil }
        var cursor = index + 1
        var name = ""
        while cursor < characters.count, characters[cursor] != "}" {
            name.append(characters[cursor])
            cursor += 1
        }
        guard cursor < characters.count, !name.isEmpty else { return nil }
        return (name, cursor + 1)
    }
}
