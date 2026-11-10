import AppKit

/// Line-number gutter for a TextKit 1 `NSTextView` inside an `NSScrollView`.
///
/// Numbers count logical lines (paragraphs), not wrapped line fragments; a
/// wrapped line shows its number only on its first fragment. Only the visible
/// part is drawn, and line starts are cached per text change, so cost does
/// not grow with the document length beyond one linear scan per edit.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offsets of every line start; rebuilt lazily after edits.
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false

    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { updateThickness(); needsDisplay = true }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()

        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Call after replacing the whole text without a change notification.
    func invalidateLineStarts() {
        lineStartsValid = false
        updateThickness()
        needsDisplay = true
    }

    @objc private func textDidChange(_ notification: Notification) {
        invalidateLineStarts()
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    private func rebuildLineStartsIfNeeded() {
        guard !lineStartsValid, let textView else { return }
        let string = textView.string as NSString
        var starts = [0]
        starts.reserveCapacity(max(16, string.length / 30))
        var index = 0
        while index < string.length {
            var end = 0
            string.getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: index, length: 0))
            if end >= string.length {
                // A trailing newline starts one more (empty) line.
                let last = string.character(at: string.length - 1)
                if last == 0x0A || last == 0x0D { starts.append(string.length) }
                break
            }
            starts.append(end)
            index = end
        }
        lineStarts = starts
        lineStartsValid = true
    }

    /// 1-based line number of a UTF-16 offset (binary search).
    func lineNumber(at location: Int) -> Int {
        rebuildLineStartsIfNeeded()
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    private func updateThickness() {
        rebuildLineStartsIfNeeded()
        let digits = max(3, String(lineStarts.count).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 20
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        rebuildLineStartsIfNeeded()

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let string = textView.string as NSString
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let caretLine = lineNumber(at: min(textView.selectedRange().location, string.length))
        // Text-view coordinates → ruler coordinates (accounts for scrolling).
        let originY = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y

        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        func draw(_ number: Int, in fragment: NSRect) {
            let label = String(number) as NSString
            let attributes = number == caretLine ? current : normal
            let size = label.size(withAttributes: attributes)
            let y = originY + fragment.minY + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: y), withAttributes: attributes)
        }

        var line = lineNumber(at: characterRange.location)
        var lineIndex = line - 1
        while lineIndex < lineStarts.count {
            let start = lineStarts[lineIndex]
            if start > NSMaxRange(characterRange) { break }
            if start >= string.length {
                // The empty last line after a trailing newline.
                if layoutManager.extraLineFragmentTextContainer != nil {
                    draw(line, in: layoutManager.extraLineFragmentRect)
                }
                break
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(line, in: fragment)
            line += 1
            lineIndex += 1
        }
        if string.length == 0 {
            draw(1, in: layoutManager.extraLineFragmentRect)
        }
    }
}
