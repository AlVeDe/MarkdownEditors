import AppKit
import Observation

/// Owns one document window's editor: the scroll view, the TextKit 1 text
/// view, the line-number ruler, the highlighter and the input handlers.
///
/// The views live as long as the controller (one per window), not as long as
/// a SwiftUI view: switching to Preview Only and back re-parents the same
/// `NSScrollView`, so undo history, selection and scroll position survive.
///
/// All edits made by commands go through `replaceCharacters(in:with:…)` (or
/// `performEdit`) so they are undoable and keep the text view, the
/// highlighter and the document in sync.
@MainActor
final class EditorController: NSObject {
    let scrollView: NSScrollView
    let textView: MarkdownTextView
    let ruler: LineNumberRulerView
    private let layoutManager: InvisiblesLayoutManager

    var highlighter: any EditorHighlighter {
        didSet { highlighter.highlightAll(textView.textStorage!) }
    }

    /// The document's undo manager (from SwiftUI's environment). Registering
    /// undo actions on it is what marks the document as edited.
    weak var undoManager: UndoManager?

    /// The saved document's file, for relative paths; nil while untitled.
    var documentURL: URL?

    /// Called after every text change with the new text.
    var onTextChange: ((String) -> Void)?
    /// Called after the selection (caret) moved.
    var onSelectionChange: (() -> Void)?
    /// Called when the visible region scrolled.
    var onScroll: (() -> Void)?

    /// The preferences this editor follows; internal so editing commands
    /// in extensions (e.g. list renumbering) can honor them.
    let settings: EditorSettings
    private var diagnosticsBySource: [String: [EditorDiagnostic]] = [:]

    init(settings: EditorSettings = .shared) {
        self.settings = settings

        // TextKit 1 stack, built by hand so no TextKit 2 objects are created.
        let textStorage = NSTextStorage()
        layoutManager = InvisiblesLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.drawsBackground = true

        ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true

        highlighter = MarkdownHighlighter()

        super.init()

        textView.delegate = self
        textStorage.delegate = self
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        applySettings()
        observeSettings()
        EditorFeatures.install(on: self)
    }

    // MARK: Text

    /// The live text (no copy).
    var string: NSString { textView.string as NSString }

    /// Replaces the whole text without an undo action — for loading a
    /// document or picking up a revert. Keeps the caret where possible.
    func setText(_ text: String) {
        guard textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        highlighter.highlightAll(textView.textStorage!)
        ruler.invalidateLineStarts()
        updateDiagnosticDisplay()
    }

    /// Replaces `range` with `replacement` as one undoable step.
    ///
    /// - Parameters:
    ///   - selecting: the selection afterwards, in coordinates of the new
    ///     text; nil places the caret after the replacement.
    ///   - actionName: shown in Edit ▸ Undo <name>.
    @discardableResult
    func replaceCharacters(in range: NSRange, with replacement: String, selecting: NSRange? = nil, actionName: String? = nil) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let length = (replacement as NSString).length
        textView.setSelectedRange(selecting ?? NSRange(location: range.location + length, length: 0))
        if let actionName { textView.undoManager?.setActionName(actionName) }
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// Groups several `replaceCharacters` calls into one undo step.
    func performEdit(actionName: String, _ edits: () -> Void) {
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        edits()
        undo?.setActionName(actionName)
        undo?.endUndoGrouping()
    }

    var selectedRange: NSRange {
        get { textView.selectedRange() }
        set { textView.setSelectedRange(newValue); textView.scrollRangeToVisible(newValue) }
    }

    /// The context (prose, code, math, mermaid…) at a location.
    func context(at location: Int) -> EditorContext {
        highlighter.context(at: location, in: string)
    }

    // MARK: Lines

    /// 1-based line and column (column in characters) of the caret.
    var caretPosition: (line: Int, column: Int) {
        let location = min(selectedRange.location, string.length)
        let line = ruler.lineNumber(at: location)
        let lineStart = string.lineRange(for: NSRange(location: location, length: 0)).location
        let column = (string.substring(with: NSRange(location: lineStart, length: location - lineStart)) as String).count + 1
        return (line, column)
    }

    /// The UTF-16 offset where 1-based `line` starts (clamped).
    func location(ofLine line: Int) -> Int {
        let string = self.string
        var current = 1
        var index = 0
        while current < line, index < string.length {
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            current += 1
        }
        return min(index, string.length)
    }

    func lineNumber(at location: Int) -> Int {
        ruler.lineNumber(at: location)
    }

    /// Moves the caret to the start of a 1-based line and centers it.
    func goToLine(_ line: Int) {
        let location = location(ofLine: max(1, line))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        centerSelection()
        textView.window?.makeFirstResponder(textView)
    }

    func centerSelection() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let visible = scrollView.contentView.bounds
        let y = max(0, rect.midY + textView.textContainerOrigin.y - visible.height / 2)
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The source line at the top edge of the visible area, with a fraction
    /// for how far that line is scrolled out (1.5 = halfway through line 1).
    var topVisibleLine: Double {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 1 }
        let visible = textView.visibleRect
        let point = NSPoint(x: 0, y: visible.minY - textView.textContainerOrigin.y)
        guard string.length > 0 else { return 1 }
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        let line = ruler.lineNumber(at: location)
        // Fraction within the (possibly wrapped) logical line.
        let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let fraction = lineRect.height > 0 ? min(1, max(0, (point.y - lineRect.minY) / lineRect.height)) : 0
        return Double(line) + fraction
    }

    /// True when the editor is scrolled to the very bottom.
    var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.frame.height - 2
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        onScroll?()
    }

    // MARK: Input handlers

    private(set) var inputHandlers: [any EditorInputHandler] = []

    func addInputHandler(_ handler: any EditorInputHandler) {
        inputHandlers.append(handler)
        inputHandlers.sort { $0.priority < $1.priority }
        textView.inputHandlers = inputHandlers
    }

    // MARK: Diagnostics

    /// Replaces the diagnostics from one source (e.g. "mermaid", "mathjax").
    func setDiagnostics(_ diagnostics: [EditorDiagnostic], source: String) {
        guard diagnosticsBySource[source] != diagnostics else { return }
        diagnosticsBySource[source] = diagnostics
        updateDiagnosticDisplay()
        onSelectionChange?()
    }

    var diagnostics: [EditorDiagnostic] {
        diagnosticsBySource.values.flatMap { $0 }.sorted { $0.range.location < $1.range.location }
    }

    /// The diagnostic under (or touching) a location, for the status bar.
    func diagnostic(at location: Int) -> EditorDiagnostic? {
        diagnostics.first { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location }
    }

    private func updateDiagnosticDisplay() {
        let all = NSRange(location: 0, length: string.length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
        for diagnostic in diagnostics {
            let range = NSIntersectionRange(diagnostic.range, all)
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemOrange
            ], forCharacterRange: range)
        }
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.font
            _ = settings.wrapsLines
            _ = settings.showsLineNumbers
            _ = settings.showsInvisibles
            _ = settings.highlightsCurrentLine
            _ = settings.smartQuotes
            _ = settings.spellChecking
            _ = settings.tabWidth
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }

    private func applySettings() {
        let font = settings.font
        let fontChanged = highlighter.baseFont != font
        highlighter.baseFont = font
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        ruler.font = .monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)

        // Tab stops matching the configured width.
        let paragraph = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = spaceWidth * CGFloat(max(1, settings.tabWidth))
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph

        setWrapsLines(settings.wrapsLines)
        scrollView.rulersVisible = settings.showsLineNumbers
        layoutManager.showsInvisibles = settings.showsInvisibles
        textView.highlightsCurrentLine = settings.highlightsCurrentLine
        textView.isAutomaticQuoteSubstitutionEnabled = settings.smartQuotes
        textView.isContinuousSpellCheckingEnabled = settings.spellChecking

        if fontChanged, let storage = textView.textStorage {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
            highlighter.highlightAll(storage)
            ruler.invalidateLineStarts()
        }
    }

    private func setWrapsLines(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        if wraps {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

// MARK: - NSTextViewDelegate

extension EditorController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?(textView.string)
        for handler in inputHandlers { handler.textViewDidChangeText(textView) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
        for handler in inputHandlers { handler.textViewDidChangeSelection(textView) }
    }
}

// MARK: - NSTextStorageDelegate

extension EditorController: NSTextStorageDelegate {
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // The editor's text storage is only ever edited on the main thread.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            highlighter.textStorage(storage, didEditRange: editedRange, changeInLength: delta)
        }
    }
}
