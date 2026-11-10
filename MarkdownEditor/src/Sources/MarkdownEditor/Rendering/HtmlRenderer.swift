import Foundation
import Markdown

func htmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Renderer #1: AST → HTML fragment.
///
/// A `MarkupVisitor` with one `visit…` method per node type — the
/// swift-markdown equivalent of Markdig's `ObjectRenderers`. `visitCodeBlock`
/// is the customized extension point: registered languages become colored
/// `<span class="tok-…">` runs, ` ```mermaid ` fences become
/// `<pre class="mermaid">` for mermaid.js, and ` ```math ` fences become
/// `<div class="math">` for MathJax. Inline `$ … $` formulas arrive as
/// `InlineCode` carriers from `InlineMath` and become `<span class="math">`.
///
/// Two attributes serve the live preview:
///
/// - `data-line` on every block element: the 1-based line in the *editor*
///   text (mapped back through `MathBlocks`' `LineMap`) where the block
///   starts. Scroll sync interpolates between these, and diagnostics found
///   by mermaid / MathJax in the page are traced back through them.
///   Mermaid diagrams and display math also get `data-end-line`.
/// - `data-hash` on every top-level block: a hash of the block's HTML
///   *without* the line attributes. The preview diffs top-level children by
///   it, so typing in one paragraph neither re-typesets the formulas nor
///   re-renders the diagrams elsewhere — and inserting a line above them
///   (which only shifts `data-line`) does not either.
struct HtmlRenderer: MarkupVisitor {
    typealias Result = Void

    private(set) var html = ""

    /// Original-line lookup for `data-line`.
    private let lineMap: LineMap
    /// Prefix that relative image sources are resolved against (the
    /// preview's `docfile://` scheme), or nil to leave them untouched.
    private let imageBase: String?
    /// FNV-1a over everything appended through `emit`, i.e. the HTML minus
    /// the line attributes.
    private var hash: UInt64 = HtmlRenderer.fnvOffset

    init(lineMap: LineMap = .identity, imageBase: String? = nil) {
        self.lineMap = lineMap
        self.imageBase = imageBase
    }

    static func render(_ document: Document, lineMap: LineMap = .identity, imageBase: String? = nil) -> String {
        var html = ""
        for child in document.children {
            var renderer = HtmlRenderer(lineMap: lineMap, imageBase: imageBase)
            renderer.visit(child)
            html += Self.insertingHash(renderer.hash, into: renderer.html)
        }
        return html
    }

    /// Adds `data-hash` to the block's opening tag. Raw HTML blocks that do
    /// not start with an element (comments, text) stay hashless; the
    /// preview's diff then keys them by their markup instead.
    private static func insertingHash(_ hash: UInt64, into block: String) -> String {
        let scalars = block.unicodeScalars
        guard scalars.first == "<",
              let second = scalars.dropFirst().first,
              CharacterSet.letters.contains(second)
        else { return block }
        let nameEnd = scalars.dropFirst().firstIndex { !CharacterSet.alphanumerics.contains($0) } ?? scalars.endIndex
        var result = block
        result.insert(contentsOf: " data-hash=\"\(String(hash, radix: 36))\"", at: nameEnd)
        return result
    }

    // MARK: Output

    private static let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x100_0000_01b3

    /// Appends content that is part of the block's identity.
    private mutating func emit(_ string: String) {
        html += string
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* Self.fnvPrime
        }
    }

    /// Appends ` data-line="N"` (and optionally `data-end-line`) — outside
    /// the hash, so a block that merely moved keeps its identity.
    private mutating func emitLine(_ markup: Markup, includeEnd: Bool = false) {
        guard let range = markup.range else { return }
        html += " data-line=\"\(lineMap.originalLine(range.lowerBound.line))\""
        if includeEnd {
            html += " data-end-line=\"\(lineMap.originalLine(range.upperBound.line))\""
        }
    }

    /// `<name data-line="N"` + `attributes` + `>`.
    private mutating func open(_ name: String, _ markup: Markup, attributes: String = "", includeEnd: Bool = false) {
        emit("<\(name)")
        emitLine(markup, includeEnd: includeEnd)
        emit("\(attributes)>")
    }

    mutating func defaultVisit(_ markup: Markup) {
        descendInto(markup)
    }

    private mutating func descendInto(_ markup: Markup) {
        for child in markup.children {
            visit(child)
        }
    }

    // MARK: Block elements

    mutating func visitHeading(_ heading: Heading) {
        open("h\(heading.level)", heading)
        descendInto(heading)
        emit("</h\(heading.level)>\n")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        open("p", paragraph)
        descendInto(paragraph)
        emit("</p>\n")
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        open("blockquote", blockQuote)
        emit("\n")
        descendInto(blockQuote)
        emit("</blockquote>\n")
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language?.lowercased() ?? ""

        if language == "mermaid" {
            // mermaid.js's default selector; rendered into a diagram in the preview.
            open("pre", codeBlock, attributes: " class=\"mermaid\"", includeEnd: true)
            emit("\(htmlEscape(codeBlock.code))</pre>\n")
            return
        }

        if language == MathBlocks.language {
            // LaTeX display math (normalized from `$$ … $$` by `MathBlocks`).
            // MathJax is configured to look *only* inside `.math` elements and
            // reads the TeX from the DOM text, so escaping `<` and `&` here is
            // both required for valid HTML and transparent to the typesetter.
            open("div", codeBlock, attributes: " class=\"math\"", includeEnd: true)
            emit("$$\n\(htmlEscape(codeBlock.code))\n$$</div>\n")
            return
        }

        if let tokenizer = SyntaxHighlighting.tokenizer(for: codeBlock.language) {
            open("pre", codeBlock)
            emit("<code class=\"language-\(htmlEscape(language))\">")
            for token in tokenizer.tokenize(codeBlock.code) {
                if let cssClass = token.kind.cssClass {
                    emit("<span class=\"\(cssClass)\">\(htmlEscape(token.text))</span>")
                } else {
                    emit(htmlEscape(token.text))
                }
            }
            emit("</code></pre>\n")
        } else {
            open("pre", codeBlock)
            emit("<code>\(htmlEscape(codeBlock.code))</code></pre>\n")
        }
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        open("hr", thematicBreak, attributes: " /")
        emit("\n")
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
        // Raw HTML passes through untouched.
        emit(htmlBlock.rawHTML)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        open("ul", unorderedList)
        emit("\n")
        descendInto(unorderedList)
        emit("</ul>\n")
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex != 1 ? " start=\"\(orderedList.startIndex)\"" : ""
        open("ol", orderedList, attributes: start)
        emit("\n")
        descendInto(orderedList)
        emit("</ol>\n")
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            open("li", listItem, attributes: " class=\"task\"")
            emit("<input type=\"checkbox\" disabled\(checked) />")
        } else {
            open("li", listItem)
        }
        // Render paragraph children without <p> wrappers (tight-list style).
        for child in listItem.children {
            if let paragraph = child as? Paragraph {
                descendInto(paragraph)
            } else {
                visit(child)
            }
        }
        emit("</li>\n")
    }

    mutating func visitTable(_ table: Markdown.Table) {
        let alignments = table.columnAlignments

        func alignAttribute(_ index: Int) -> String {
            guard index < alignments.count, let alignment = alignments[index] else { return "" }
            switch alignment {
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }

        open("table", table)
        emit("\n<thead>\n")
        open("tr", table.head)
        for (index, cell) in table.head.cells.enumerated() {
            emit("<th\(alignAttribute(index))>")
            descendInto(cell)
            emit("</th>")
        }
        emit("</tr>\n</thead>\n<tbody>\n")
        for row in table.body.rows {
            open("tr", row)
            for (index, cell) in row.cells.enumerated() {
                emit("<td\(alignAttribute(index))>")
                descendInto(cell)
                emit("</td>")
            }
            emit("</tr>\n")
        }
        emit("</tbody>\n</table>\n")
    }

    // MARK: Inline elements

    mutating func visitText(_ text: Markdown.Text) {
        emit(htmlEscape(text.string))
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        emit("<em>")
        descendInto(emphasis)
        emit("</em>")
    }

    mutating func visitStrong(_ strong: Strong) {
        emit("<strong>")
        descendInto(strong)
        emit("</strong>")
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        emit("<del>")
        descendInto(strikethrough)
        emit("</del>")
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        if let tex = InlineMath.tex(of: inlineCode) {
            // Inline LaTeX (a `$ … $` span, see `InlineMath`). `\(…\)` are the
            // delimiters MathJax is configured to look for inline.
            emit("<span class=\"math\">\\(\(htmlEscape(tex))\\)</span>")
            return
        }
        emit("<code>\(htmlEscape(inlineCode.code))</code>")
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        emit(inlineHTML.rawHTML)
    }

    mutating func visitLink(_ link: Markdown.Link) {
        let destination = htmlEscape(link.destination ?? "#")
        emit("<a href=\"\(destination)\">")
        descendInto(link)
        emit("</a>")
    }

    mutating func visitImage(_ image: Markdown.Image) {
        let source = htmlEscape(resolvedImageSource(image.source ?? ""))
        let alt = htmlEscape(image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined())
        emit("<img src=\"\(source)\" alt=\"\(alt)\" />")
    }

    /// Points a relative image path (`images/a.png`) at `imageBase`, so the
    /// preview's `docfile://` handler serves it from the document's folder.
    /// URLs with a scheme, protocol-relative and absolute paths, and
    /// fragments are left alone.
    private func resolvedImageSource(_ source: String) -> String {
        guard let imageBase, Self.isRelativePath(source) else { return source }
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert("%") // keep sources the author already percent-encoded
        let encoded = source.addingPercentEncoding(withAllowedCharacters: allowed) ?? source
        return imageBase + encoded
    }

    static func isRelativePath(_ source: String) -> Bool {
        guard !source.isEmpty, !source.hasPrefix("/"), !source.hasPrefix("#") else { return false }
        // A scheme is letters/digits/+-. before the first ':' (RFC 3986),
        // and it has to come before any '/'.
        if let colon = source.firstIndex(of: ":") {
            let scheme = source[..<colon]
            if !scheme.isEmpty, !scheme.contains("/"),
               scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
                return false
            }
        }
        return true
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        emit("\n")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        emit("<br />\n")
    }
}
