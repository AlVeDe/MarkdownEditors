import AppKit

/// The editor's text view: a TextKit 1 `NSTextView` that hands keyboard
/// input, paste and drop to the registered `EditorInputHandler`s first and
/// draws the current-line highlight.
///
/// TextKit 1 on purpose: TextKit 2 estimates the height of text it has not
/// laid out, which makes the scroller and a line-number ruler jump in long
/// documents.
final class MarkdownTextView: NSTextView {
    /// Sorted by priority; maintained by `EditorController`.
    var inputHandlers: [any EditorInputHandler] = []

    var highlightsCurrentLine = true {
        didSet { needsDisplay = true }
    }

    var currentLineColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 0.06)
        }
    }

    // MARK: Input routing

    override func keyDown(with event: NSEvent) {
        for handler in inputHandlers where handler.textView(self, handleKeyDown: event) {
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        for handler in inputHandlers where handler.textView(self, doCommandBy: selector) {
            return
        }
        super.doCommand(by: selector)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Marked (IME) text in progress goes straight through.
        if !hasMarkedText(), let text = (string as? String) ?? (string as? NSAttributedString)?.string {
            for handler in inputHandlers where handler.textView(self, insertText: text, replacementRange: replacementRange) {
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        for handler in inputHandlers where handler.textView(self, paste: .general) {
            return
        }
        // Markdown is plain text: never paste rich text attributes.
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let location = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        for handler in inputHandlers where handler.textView(self, drop: sender.draggingPasteboard, at: location) {
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: Current line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine,
              selectedRange().length == 0,
              let layoutManager, let textContainer
        else { return }

        let string = self.string as NSString
        let caret = min(selectedRange().location, string.length)
        let lineRect: NSRect
        if caret == string.length, layoutManager.extraLineFragmentTextContainer != nil {
            // Caret on the empty last line after a trailing newline.
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let paragraph = string.paragraphRange(for: NSRange(location: caret, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        }
        var highlight = lineRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        highlight.origin.x = bounds.minX
        highlight.size.width = bounds.width
        guard highlight.intersects(rect) else { return }
        currentLineColor.setFill()
        highlight.fill()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let oldLine = currentLineRect()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard highlightsCurrentLine else { return }
        setNeedsDisplay(oldLine)
        setNeedsDisplay(currentLineRect())
    }

    override func didChangeText() {
        super.didChangeText()
        if highlightsCurrentLine { needsDisplay = true }
    }

    private func currentLineRect() -> NSRect {
        guard let layoutManager, let textContainer else { return bounds }
        let string = self.string as NSString
        let caret = min(selectedRange().location, string.length)
        let paragraph = string.paragraphRange(for: NSRange(location: caret, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        rect.origin.x = bounds.minX
        rect.size.width = bounds.width
        // Cover the extra line fragment and rounding.
        return rect.insetBy(dx: 0, dy: -(rect.height + 2))
    }
}

/// Draws invisible characters (space ·, tab →, line break ¬) on top of the
/// normal glyphs when enabled.
final class InvisiblesLayoutManager: NSLayoutManager {
    var showsInvisibles = false {
        didSet {
            guard oldValue != showsInvisibles, let textStorage else { return }
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let textStorage else { return }

        let string = textStorage.string as NSString
        let characterRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let color = NSColor.tertiaryLabelColor
        for index in characterRange.location..<NSMaxRange(characterRange) {
            let symbol: String
            switch string.character(at: index) {
            case 0x20: symbol = "·"
            case 0x09: symbol = "→"
            case 0x0A: symbol = "¬"
            default: continue
            }
            let glyph = glyphIndexForCharacter(at: index)
            var point = location(forGlyphAt: glyph)
            let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = (textStorage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            point.x += lineRect.minX + origin.x
            point.y = lineRect.minY + origin.y + (lineRect.height - font.ascender + font.descender) / 2 - 1
            (symbol as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
        }
    }
}
