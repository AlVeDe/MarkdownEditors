import AppKit
import CoreText
import Markdown

/// Renderer #3: AST → PDF, built on Core Graphics + Core Text.
///
/// A4 pages with 2 cm margins and a `page / total` footer. Each block is
/// converted to an `NSAttributedString`, measured with a `CTFramesetter`,
/// and a new PDF page is started when a block does not fit the remaining
/// height. Code blocks use the shared tokenizers with the same colors as the
/// HTML preview; mermaid diagrams and LaTeX formulas are drawn from PNGs
/// harvested from the WKWebView preview (with the source text as fallback).
/// A formula harvested from the preview, ready to be drawn into the PDF.
/// The geometry is in em of the surrounding text (see `HarvestedSVG`).
struct MathImage {
    let image: CGImage
    let widthEm: CGFloat
    let heightEm: CGFloat
    /// Extent below the text baseline, in em — what puts an inline formula on
    /// the line rather than floating above it.
    let depthEm: CGFloat
}

/// Hands out the harvested inline formulas in document order.
///
/// `PdfInlineText` is a value type that the visitor copies freely, so the
/// running index lives in a reference all copies share. One supply per render
/// pass — the page-counting pass consumes it just like the real one.
final class InlineMathSupply {
    private let images: [MathImage?]
    private var index = 0

    init(_ images: [MathImage?]) {
        self.images = images
    }

    /// The next formula, with the index the draw pass will look it up by.
    func next() -> (index: Int, image: MathImage?) {
        defer { index += 1 }
        return (index, images.indices.contains(index) ? images[index] : nil)
    }
}

extension NSAttributedString.Key {
    /// Index into the renderer's inline-formula images, carried by the
    /// placeholder run so the draw pass can find the right picture.
    static let inlineMathIndex = NSAttributedString.Key("MarkdownEditorInlineMathIndex")
}

final class PdfDocumentRenderer {
    enum Layout {
        static let pageSize = CGSize(width: 595.28, height: 841.89) // A4 in points
        static let margin: CGFloat = 56.7 // 2 cm
        static var contentWidth: CGFloat { pageSize.width - 2 * margin }
        static var contentHeight: CGFloat { pageSize.height - 2 * margin }
    }

    static var bodyFont: NSFont { .systemFont(ofSize: 11) }
    static var codeFont: NSFont { .monospacedSystemFont(ofSize: 9, weight: .regular) }
    static let headingSizes: [CGFloat] = [22, 17, 14.5, 12.5, 11.5, 11]
    static var textColor: NSColor { .black }
    static var secondaryColor: NSColor { NSColor(white: 0.45, alpha: 1) }
    static var borderColor: NSColor { NSColor(white: 0.78, alpha: 1) }
    static var codeBackground: NSColor { NSColor(white: 0.955, alpha: 1) }
    static var quoteBarColor: NSColor { NSColor(white: 0.8, alpha: 1) }
    static var linkColor: NSColor { NSColor(hex: 0x0969DA) }
    static var markBackground: NSColor { NSColor(hex: 0xFFF3A3) }

    private let mermaidImages: [CGImage?]
    private let displayMathImages: [MathImage?]
    private let inlineMathImages: [MathImage?]
    private let totalPages: Int?
    private var mermaidIndex = 0
    private var displayMathIndex = 0
    private var inlineMath: InlineMathSupply
    private var context: CGContext!
    private var pageNumber = 0
    private var cursorY: CGFloat = 0 // distance consumed from the top content edge

    init(
        mermaidImages: [CGImage?],
        displayMathImages: [MathImage?],
        inlineMathImages: [MathImage?],
        totalPages: Int? = nil
    ) {
        self.mermaidImages = mermaidImages
        self.displayMathImages = displayMathImages
        self.inlineMathImages = inlineMathImages
        self.inlineMath = InlineMathSupply(inlineMathImages)
        self.totalPages = totalPages
    }

    private var remainingHeight: CGFloat {
        Layout.contentHeight - cursorY
    }

    /// Renders the document into an open PDF context and returns the page
    /// count (used by the two-pass `page / total` footer).
    @discardableResult
    func render(_ document: Document, into context: CGContext) -> Int {
        self.context = context
        pageNumber = 0
        cursorY = 0
        mermaidIndex = 0
        displayMathIndex = 0
        // A fresh supply per pass: the page-counting pass consumes it too.
        inlineMath = InlineMathSupply(inlineMathImages)

        beginPage()
        renderChildren(Array(document.children), x: 0, width: Layout.contentWidth, quoted: false, spacing: 12)
        endPage()
        return pageNumber
    }

    // MARK: Pages

    private func beginPage() {
        pageNumber += 1
        context.beginPDFPage(nil)
        cursorY = 0
    }

    private func endPage() {
        drawFooter()
        context.endPDFPage()
    }

    private func newPage() {
        endPage()
        beginPage()
    }

    private func drawFooter() {
        let text = totalPages.map { "\(pageNumber) / \($0)" } ?? "\(pageNumber)"
        let attributed = NSAttributedString(
            string: text,
            attributes: Self.textAttributes(font: NSFont.systemFont(ofSize: 9), color: Self.secondaryColor)
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (Layout.pageSize.width - width) / 2, y: Layout.margin * 0.45)
        CTLineDraw(line, context)
    }

    // MARK: Blocks

    private func renderChildren(_ blocks: [any Markup], x: CGFloat, width: CGFloat, quoted: Bool, spacing: CGFloat) {
        for (index, block) in blocks.enumerated() {
            renderBlock(block, x: x, width: width, quoted: quoted)
            if index < blocks.count - 1 {
                cursorY += spacing
            }
        }
    }

    private func renderBlock(_ block: any Markup, x: CGFloat, width: CGFloat, quoted: Bool) {
        switch block {
        case let heading as Heading:
            let level = min(max(heading.level, 1), 6)
            let font = NSFont.systemFont(ofSize: Self.headingSizes[level - 1], weight: .semibold)
            cursorY += 4
            drawText(
                PdfInlineText.render(heading, font: font, mathSupply: inlineMath),
                x: x, width: width, quoted: quoted
            )
            if level <= 2 {
                cursorY += 4
                drawRule(x: x, width: width)
            }

        case let paragraph as Paragraph:
            drawText(
                PdfInlineText.render(paragraph, font: Self.bodyFont, mathSupply: inlineMath),
                x: x, width: width, quoted: quoted
            )

        case let codeBlock as CodeBlock:
            switch codeBlock.language?.lowercased() {
            case "mermaid":
                drawMermaid(codeBlock, x: x, width: width, quoted: quoted)
            case MathBlocks.language:
                drawMath(codeBlock, x: x, width: width, quoted: quoted)
            default:
                drawCodeBlock(codeBlock.code, language: codeBlock.language, x: x, width: width, quoted: quoted)
            }

        case let quote as BlockQuote:
            renderChildren(Array(quote.children), x: x + 14, width: width - 14, quoted: true, spacing: 8)

        case let list as UnorderedList:
            renderList(Array(list.listItems), ordered: false, start: 1, x: x, width: width, quoted: quoted)

        case let list as OrderedList:
            renderList(Array(list.listItems), ordered: true, start: Int(list.startIndex), x: x, width: width, quoted: quoted)

        case let table as Markdown.Table:
            drawTable(table, x: x, width: width)

        case is ThematicBreak:
            cursorY += 4
            drawRule(x: x, width: width)
            cursorY += 4

        case is HTMLBlock:
            break // Raw HTML is skipped by the PDF renderer.

        default:
            drawText(
                PdfInlineText.render(block, font: Self.bodyFont, mathSupply: inlineMath),
                x: x, width: width, quoted: quoted
            )
        }
    }

    private func renderList(_ items: [ListItem], ordered: Bool, start: Int, x: CGFloat, width: CGFloat, quoted: Bool) {
        let markerWidth: CGFloat = 22
        for (index, item) in items.enumerated() {
            if remainingHeight < 20 { newPage() }

            let markerText: String
            if let checkbox = item.checkbox {
                markerText = checkbox == .checked ? "☑" : "☐"
            } else if ordered {
                markerText = "\(start + index)."
            } else {
                markerText = "•"
            }
            let marker = NSAttributedString(
                string: markerText,
                attributes: Self.textAttributes(font: Self.bodyFont, color: Self.textColor)
            )
            drawText(marker, x: x, width: markerWidth, quoted: false, advance: false)
            renderChildren(Array(item.children), x: x + markerWidth, width: width - markerWidth, quoted: quoted, spacing: 4)
            if index < items.count - 1 {
                cursorY += 4
            }
        }
    }

    // MARK: Drawing primitives

    private func drawRule(x: CGFloat, width: CGFloat) {
        if remainingHeight < 4 { newPage() }
        let y = Layout.pageSize.height - Layout.margin - cursorY - 1
        context.setStrokeColor(Self.borderColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: Layout.margin + x, y: y))
        context.addLine(to: CGPoint(x: Layout.margin + x + width, y: y))
        context.strokePath()
        cursorY += 4
    }

    @discardableResult
    private func drawText(
        _ attributed: NSAttributedString,
        x: CGFloat,
        width: CGFloat,
        quoted: Bool = false,
        background: NSColor? = nil,
        padding: CGFloat = 0,
        advance: Bool = true
    ) -> CGFloat {
        guard attributed.length > 0 else { return 0 }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textWidth = width - 2 * padding
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let blockHeight = ceil(size.height) + 2 * padding

        if (blockHeight > remainingHeight && blockHeight <= Layout.contentHeight) || remainingHeight <= 0 {
            newPage()
        }

        // Blocks taller than one page are clipped (by design, see spec §4).
        let drawnHeight = min(blockHeight, remainingHeight)
        let top = Layout.pageSize.height - Layout.margin - cursorY
        let blockRect = CGRect(x: Layout.margin + x, y: top - drawnHeight, width: width, height: drawnHeight)

        if let background {
            context.setFillColor(background.cgColor)
            let path = CGPath(roundedRect: blockRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.fillPath()
        }

        let textRect = blockRect.insetBy(dx: padding, dy: padding)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        // Inline-code backgrounds (Core Text does not draw .backgroundColor).
        enumerateRuns(in: frame, textRect: textRect) { rect, _, attributes in
            if let color = attributes[.backgroundColor] as? NSColor {
                self.context.setFillColor(color.cgColor)
                self.context.fill(rect.insetBy(dx: -1.5, dy: -1.5))
            }
        }

        context.textMatrix = .identity
        CTFrameDraw(frame, context)

        drawInlineMath(in: frame, textRect: textRect)

        // Link annotations, underlines and strikethrough (not drawn by Core Text).
        enumerateRuns(in: frame, textRect: textRect) { rect, baseline, attributes in
            if let url = attributes[.link] as? URL {
                self.context.setURL(url as CFURL, for: rect)
            }
            if attributes[.underlineStyle] != nil {
                let color = (attributes[.foregroundColor] as? NSColor) ?? Self.textColor
                self.strokeLine(from: CGPoint(x: rect.minX, y: baseline - 1.5),
                                to: CGPoint(x: rect.maxX, y: baseline - 1.5),
                                color: color)
            }
            if attributes[.strikethroughStyle] != nil {
                let color = (attributes[.foregroundColor] as? NSColor) ?? Self.textColor
                let y = baseline + (rect.maxY - baseline) * 0.4
                self.strokeLine(from: CGPoint(x: rect.minX, y: y),
                                to: CGPoint(x: rect.maxX, y: y),
                                color: color)
            }
        }

        if quoted {
            context.setFillColor(Self.quoteBarColor.cgColor)
            context.fill(CGRect(x: blockRect.minX - 10, y: blockRect.minY, width: 3, height: blockRect.height))
        }

        if advance {
            cursorY += blockHeight
        }
        return blockHeight
    }

    /// Draws the harvested picture for every inline-formula placeholder in a
    /// laid-out frame. Each placeholder reserved its space through a
    /// `CTRunDelegate`, so the run's rectangle *is* the formula's box, already
    /// sitting on the text baseline.
    ///
    /// Every `CTFrameDraw` in this renderer has to be followed by this call —
    /// paragraphs and headings go through `drawText`, table cells draw their
    /// own frames.
    private func drawInlineMath(in frame: CTFrame, textRect: CGRect) {
        enumerateRuns(in: frame, textRect: textRect) { rect, _, attributes in
            guard let index = attributes[.inlineMathIndex] as? Int,
                  index < self.inlineMathImages.count,
                  let math = self.inlineMathImages[index]
            else { return }
            self.context.draw(math.image, in: rect)
        }
    }

    private func strokeLine(from: CGPoint, to: CGPoint, color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(0.7)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    /// Calls `body` with the page-space bounds, baseline y and attributes of
    /// every glyph run in the frame.
    private func enumerateRuns(
        in frame: CTFrame,
        textRect: CGRect,
        _ body: (CGRect, CGFloat, [NSAttributedString.Key: Any]) -> Void
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (line, origin) in zip(lines, origins) {
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let attributes = (CTRunGetAttributes(run) as NSDictionary) as? [NSAttributedString.Key: Any] ?? [:]
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let runWidth = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, &leading))
                let offset = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                let baseline = textRect.minY + origin.y
                let rect = CGRect(
                    x: textRect.minX + origin.x + offset,
                    y: baseline - descent,
                    width: runWidth,
                    height: ascent + descent
                )
                body(rect, baseline, attributes)
            }
        }
    }

    // MARK: Code blocks

    private func drawCodeBlock(_ code: String, language: String?, x: CGFloat, width: CGFloat, quoted: Bool) {
        var text = code
        if text.hasSuffix("\n") { text.removeLast() }

        let attributed = NSMutableAttributedString()
        if let tokenizer = SyntaxHighlighting.tokenizer(for: language) {
            for token in tokenizer.tokenize(text) {
                let color = token.kind.lightColor ?? Self.textColor
                attributed.append(NSAttributedString(
                    string: token.text,
                    attributes: Self.textAttributes(font: Self.codeFont, color: color)
                ))
            }
        } else {
            attributed.append(NSAttributedString(
                string: text,
                attributes: Self.textAttributes(font: Self.codeFont, color: Self.textColor)
            ))
        }
        drawText(attributed, x: x, width: width, quoted: quoted, background: Self.codeBackground, padding: 8)
    }

    // MARK: Harvested images (mermaid diagrams, LaTeX formulas)

    private func drawMermaid(_ codeBlock: CodeBlock, x: CGFloat, width: CGFloat, quoted: Bool) {
        let image = mermaidIndex < mermaidImages.count ? mermaidImages[mermaidIndex] : nil
        mermaidIndex += 1
        // Mermaid diagrams are drawn at the size the preview gave them.
        draw(image.map { ($0, CGFloat($0.width) / 2, CGFloat($0.height) / 2) },
             fallback: codeBlock, x: x, width: width, quoted: quoted)
    }

    private func drawMath(_ codeBlock: CodeBlock, x: CGFloat, width: CGFloat, quoted: Bool) {
        let math = displayMathIndex < displayMathImages.count ? displayMathImages[displayMathIndex] : nil
        displayMathIndex += 1
        cursorY += 4 // A display formula gets a little air above and below.
        // The harvested geometry is in em, so the formula keeps its proportion
        // to the body text whatever size either renderer uses.
        let size = Self.bodyFont.pointSize
        draw(math.map { ($0.image, $0.widthEm * size, $0.heightEm * size) },
             fallback: codeBlock, x: x, width: width, quoted: quoted)
        cursorY += 4
    }

    /// Draws a PNG harvested from the preview, centered and scaled to fit the
    /// content width. Without an image (preview not rendered yet, or the
    /// renderer choked on the source) the block's source text is printed
    /// instead, so nothing silently vanishes from the PDF.
    private func draw(
        _ harvested: (image: CGImage, width: CGFloat, height: CGFloat)?,
        fallback codeBlock: CodeBlock,
        x: CGFloat,
        width: CGFloat,
        quoted: Bool
    ) {
        guard let harvested else {
            drawCodeBlock(codeBlock.code, language: nil, x: x, width: width, quoted: quoted)
            return
        }

        let image = harvested.image
        var imageWidth = harvested.width
        var imageHeight = harvested.height
        if imageWidth > width {
            imageHeight *= width / imageWidth
            imageWidth = width
        }
        if (imageHeight > remainingHeight && imageHeight <= Layout.contentHeight) || remainingHeight <= 0 {
            newPage()
        }
        let top = Layout.pageSize.height - Layout.margin - cursorY
        let rect = CGRect(
            x: Layout.margin + x + (width - imageWidth) / 2,
            y: top - imageHeight,
            width: imageWidth,
            height: imageHeight
        )
        context.draw(image, in: rect)
        cursorY += imageHeight
    }

    // MARK: Tables

    private func drawTable(_ table: Markdown.Table, x: CGFloat, width: CGFloat) {
        let headCells = Array(table.head.cells)
        let columnCount = max(headCells.count, 1)
        let columnWidth = width / CGFloat(columnCount)

        drawTableRow(cells: headCells, columnCount: columnCount, columnWidth: columnWidth, x: x, header: true)
        for row in table.body.rows {
            drawTableRow(cells: Array(row.cells), columnCount: columnCount, columnWidth: columnWidth, x: x, header: false)
        }
    }

    private func drawTableRow(
        cells: [Markdown.Table.Cell],
        columnCount: Int,
        columnWidth: CGFloat,
        x: CGFloat,
        header: Bool
    ) {
        let padding: CGFloat = 5
        let font = header
            ? NSFont.systemFont(ofSize: 10, weight: .semibold)
            : NSFont.systemFont(ofSize: 10)

        var framesetters: [CTFramesetter?] = []
        var rowHeight: CGFloat = 16
        for index in 0..<columnCount {
            guard index < cells.count else {
                framesetters.append(nil)
                continue
            }
            let attributed = PdfInlineText.render(cells[index], font: font, mathSupply: inlineMath)
            guard attributed.length > 0 else {
                framesetters.append(nil)
                continue
            }
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                nil,
                CGSize(width: columnWidth - 2 * padding, height: .greatestFiniteMagnitude),
                nil
            )
            rowHeight = max(rowHeight, ceil(size.height) + 2 * padding)
            framesetters.append(framesetter)
        }

        if (rowHeight > remainingHeight && rowHeight <= Layout.contentHeight) || remainingHeight <= 0 {
            newPage()
        }

        let top = Layout.pageSize.height - Layout.margin - cursorY
        for index in 0..<columnCount {
            let cellRect = CGRect(
                x: Layout.margin + x + CGFloat(index) * columnWidth,
                y: top - rowHeight,
                width: columnWidth,
                height: rowHeight
            )
            if header {
                context.setFillColor(Self.codeBackground.cgColor)
                context.fill(cellRect)
            }
            context.setStrokeColor(Self.borderColor.cgColor)
            context.setLineWidth(0.5)
            context.stroke(cellRect)

            if let framesetter = framesetters[index] {
                let textRect = cellRect.insetBy(dx: padding, dy: padding)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: 0, length: 0),
                    CGPath(rect: textRect, transform: nil),
                    nil
                )
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                drawInlineMath(in: frame, textRect: textRect)
            }
        }
        cursorY += rowHeight
    }

    // MARK: Attributes

    /// Sets both the Cocoa and the Core Text keys so `CTFrameDraw` reliably
    /// picks up font and color.
    static func textAttributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.font] = font
        attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = font
        attributes[.foregroundColor] = color
        attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color.cgColor
        return attributes
    }
}

// MARK: - Inline content → NSAttributedString (for Core Text)

/// The PDF twin of `InlineAttributedRenderer`: folds inline AST nodes into an
/// `NSAttributedString` with Core Text-compatible attributes.
struct PdfInlineText: MarkupVisitor {
    typealias Result = NSAttributedString

    var baseFont: NSFont
    var bold = false
    var italic = false
    /// Open inline-HTML formatting tags (`<mark>`, `<sub>`, `<sup>`) — they
    /// arrive as separate `InlineHTML` siblings around the text they style.
    var markDepth = 0
    var subscriptDepth = 0
    var superscriptDepth = 0
    /// Shared across the whole document so inline formulas are consumed in the
    /// same order the preview harvested them.
    var mathSupply: InlineMathSupply?

    static func render(
        _ markup: any Markup,
        font: NSFont,
        mathSupply: InlineMathSupply? = nil
    ) -> NSAttributedString {
        var renderer = PdfInlineText(baseFont: font, mathSupply: mathSupply)
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(renderer.visit(child))
        }
        return result
    }

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    private var currentFont: NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return baseFont }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
    }

    private func leaf(_ string: String, font: NSFont, color: NSColor = PdfDocumentRenderer.textColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: PdfDocumentRenderer.textAttributes(font: font, color: color))
    }

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        guard markDepth > 0 || subscriptDepth > 0 || superscriptDepth > 0 else {
            return leaf(text.string, font: currentFont)
        }
        var font = currentFont
        var attributes = PdfDocumentRenderer.textAttributes(font: font, color: PdfDocumentRenderer.textColor)
        if superscriptDepth > 0 || subscriptDepth > 0 {
            // Smaller and shifted, roughly like a browser's sub/sup.
            let size = baseFont.pointSize
            font = NSFontManager.shared.convert(font, toSize: (size * 0.75).rounded())
            attributes = PdfDocumentRenderer.textAttributes(font: font, color: PdfDocumentRenderer.textColor)
            let offset = superscriptDepth > 0 ? size * 0.35 : -size * 0.18
            attributes[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = offset
        }
        if markDepth > 0 {
            attributes[.backgroundColor] = PdfDocumentRenderer.markBackground
        }
        return NSAttributedString(string: text.string, attributes: attributes)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        let wasItalic = italic
        italic = true
        let result = defaultVisit(emphasis)
        italic = wasItalic
        return result
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        let wasBold = bold
        bold = true
        let result = defaultVisit(strong)
        bold = wasBold
        return result
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: defaultVisit(strikethrough))
        result.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        if let tex = InlineMath.tex(of: inlineCode) {
            return mathPlaceholder(tex: tex)
        }
        let font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.88, weight: .regular)
        let result = NSMutableAttributedString(attributedString: leaf(inlineCode.code, font: font))
        result.addAttribute(
            .backgroundColor,
            value: PdfDocumentRenderer.codeBackground,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let wasBold = bold // links keep surrounding traits
        bold = wasBold
        result.append(defaultVisit(link))
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: PdfDocumentRenderer.linkColor, range: range)
        result.addAttribute(
            NSAttributedString.Key(kCTForegroundColorAttributeName as String),
            value: PdfDocumentRenderer.linkColor.cgColor,
            range: range
        )
        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        if let destination = link.destination, let url = URL(string: destination) {
            result.addAttribute(.link, value: url, range: range)
        }
        return result
    }

    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        let alt = image.children.compactMap { ($0 as? Markdown.Text)?.string }.joined()
        return leaf("[image: \(alt.isEmpty ? (image.source ?? "image") : alt)]",
                    font: currentFont,
                    color: PdfDocumentRenderer.secondaryColor)
    }

    /// Raw HTML is not rendered, but the formatting tags the editor inserts
    /// (`<mark>`, `<sub>`, `<sup>` — also used for footnote numbers) style
    /// the text between them. Everything else is skipped.
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString {
        let tag = inlineHTML.rawHTML.trimmingCharacters(in: .whitespaces).lowercased()
        let isClosing = tag.hasPrefix("</")
        let name = tag.drop(while: { $0 == "<" || $0 == "/" })
            .prefix(while: { $0.isLetter })
        let delta = isClosing ? -1 : 1
        switch name {
        case "mark": markDepth = max(0, markDepth + delta)
        case "sub": subscriptDepth = max(0, subscriptDepth + delta)
        case "sup": superscriptDepth = max(0, superscriptDepth + delta)
        default: break
        }
        return NSAttributedString()
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        leaf(" ", font: currentFont)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        leaf("\n", font: currentFont)
    }

    // MARK: Inline formulas

    /// A zero-ink placeholder run that reserves exactly the formula's box on
    /// the line. Core Text has no notion of an embedded image, so the space is
    /// claimed through a `CTRunDelegate` reporting the harvested width, ascent
    /// and descent; `PdfDocumentRenderer` then draws the picture into the run's
    /// rectangle after the text has been laid out.
    ///
    /// Without a harvested image (preview not rendered yet, or MathJax could
    /// not parse the formula) the TeX source is set in monospace instead, so
    /// the formula never silently disappears.
    private mutating func mathPlaceholder(tex: String) -> NSAttributedString {
        guard let supply = mathSupply else { return mathFallback(tex) }
        let (index, harvested) = supply.next()
        guard let math = harvested else { return mathFallback(tex) }

        let size = baseFont.pointSize
        let metrics = MathRunMetrics(
            ascent: (math.heightEm - math.depthEm) * size,
            descent: math.depthEm * size,
            width: math.widthEm * size
        )
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<MathRunMetrics>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<MathRunMetrics>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<MathRunMetrics>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<MathRunMetrics>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )
        guard let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque()) else {
            return mathFallback(tex)
        }

        // U+FFFC (object replacement) drawn in clear: the glyph is never seen,
        // only the space the delegate claims for it.
        let result = NSMutableAttributedString(string: "\u{FFFC}")
        let range = NSRange(location: 0, length: result.length)
        result.addAttributes(
            PdfDocumentRenderer.textAttributes(font: baseFont, color: .clear),
            range: range
        )
        result.addAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            value: delegate,
            range: range
        )
        result.addAttribute(.inlineMathIndex, value: index, range: range)
        return result
    }

    private func mathFallback(_ tex: String) -> NSAttributedString {
        leaf(
            tex,
            font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.88, weight: .regular),
            color: PdfDocumentRenderer.textColor
        )
    }
}

/// Metrics a `CTRunDelegate` reports for one inline formula. A class because
/// Core Text keeps an opaque pointer to it.
private final class MathRunMetrics {
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }
}

