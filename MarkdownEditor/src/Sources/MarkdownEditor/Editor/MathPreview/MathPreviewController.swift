import AppKit

/// Shows the formula under the caret, rendered by MathJax, in a small panel
/// just below it — so a `$ … $` or `$$ … $$` can be checked while typing
/// without looking over at the preview pane (or when it is hidden).
///
/// It is an input handler only to hear about caret moves and edits (plus
/// Escape); it never consumes an event. The high priority number puts it
/// after every handler that might.
///
/// Updates are debounced (`debounce`): MathJax is fast, but re-rendering on
/// every keystroke of a long formula would still make the panel flicker.
/// The panel hides as soon as the caret leaves the formula, the window
/// resigns key, the editor scrolls or Escape is pressed; after Escape it
/// stays away until the caret moves into a different formula.
@MainActor
final class MathPreviewController: NSObject, EditorInputHandler {
    let priority = 50

    static let debounce: Duration = .milliseconds(150)

    private weak var editor: EditorController?
    /// Created on first use: most documents never show it, and the editor
    /// tests never need a web view.
    private var panel: MathPreviewPanel?
    private var pendingUpdate: Task<Void, Never>?
    /// Bumped whenever the panel hides, so a render still in flight cannot
    /// bring it back.
    private var generation = 0

    /// The formula the panel currently shows.
    private var shownFormula: MathFormula?
    /// `shownFormula`'s ranges are stale once the text changed.
    private var textChangedSinceShown = false
    /// Start of the formula the user dismissed with Escape.
    private var dismissedFormulaStart: Int?

    init(editor: EditorController) {
        self.editor = editor
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(editorDidScroll(_:)),
                           name: NSView.boundsDidChangeNotification, object: editor.scrollView.contentView)
        center.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                           name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
    }

    // MARK: EditorInputHandler

    func textViewDidChangeSelection(_ textView: MarkdownTextView) {
        // Leaving the formula hides at once; everything else waits for the
        // debounce.
        if let shown = shownFormula, !textChangedSinceShown, !Self.contains(shown, textView.selectedRange().location) {
            hide()
        }
        scheduleUpdate()
    }

    func textViewDidChangeText(_ textView: MarkdownTextView) {
        textChangedSinceShown = true
        scheduleUpdate()
    }

    func textView(_ textView: MarkdownTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), let shown = shownFormula {
            dismissedFormulaStart = shown.range.location
            pendingUpdate?.cancel()
            hide()
        }
        return false // Escape keeps its normal meaning.
    }

    // MARK: Hiding

    @objc private func editorDidScroll(_ notification: Notification) {
        hide()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === editor?.textView.window else { return }
        hide()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === editor?.textView.window else { return }
        pendingUpdate?.cancel()
        hide()
    }

    private func hide() {
        generation += 1
        shownFormula = nil
        panel?.hide()
    }

    // MARK: Updating

    /// The formula to preview at `location`, if any. Code, front matter and
    /// the like are excluded by the highlighter's context; the formula's
    /// extent comes from the source scan (which also works before the
    /// highlighter reports math contexts).
    static func formula(at location: Int, in text: NSString, context: EditorContext) -> MathFormula? {
        switch context {
        case .inlineCode, .codeBlock, .fenceInfo, .mermaid, .frontMatter, .htmlComment:
            return nil
        case .markdown, .inlineMath, .displayMath:
            return MathFormulaLocator.formula(at: location, in: text)
        }
    }

    private static func contains(_ formula: MathFormula, _ location: Int) -> Bool {
        location >= formula.contentRange.location && location <= NSMaxRange(formula.contentRange)
    }

    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    private func update() async {
        guard let editor, let window = editor.textView.window, window.isKeyWindow,
              window.firstResponder === editor.textView
        else { return hide() }

        let textView = editor.textView
        let text = editor.string
        let location = textView.selectedRange().location
        guard let formula = Self.formula(at: location, in: text, context: editor.context(at: location)) else {
            dismissedFormulaStart = nil
            return hide()
        }
        if dismissedFormulaStart == formula.range.location { return }
        dismissedFormulaStart = nil

        let tex = formula.tex(in: text)
        guard !tex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return hide() }

        let panel = self.panel ?? MathPreviewPanel()
        self.panel = panel
        let generation = self.generation
        let fontSize = max(13, editor.highlighter.baseFont.pointSize * 1.15)
        guard let result = await panel.render(tex: tex, display: formula.isDisplay, fontSize: fontSize),
              !Task.isCancelled, generation == self.generation,
              textView.window === window
        else { return }

        guard let placement = placement(of: formula, in: textView, window: window) else { return hide() }
        panel.show(
            contentSize: result.size,
            below: placement.anchor,
            avoiding: placement.formulaRect,
            parent: window,
            appearance: textView.effectiveAppearance
        )
        shownFormula = formula
        textChangedSinceShown = false
    }

    /// Screen position for the panel: the bottom-left corner of the
    /// formula's last line (clamped to the visible part of the editor), and
    /// the formula's visible rectangle, which the panel must not cover when
    /// it has to go above instead.
    private func placement(of formula: MathFormula, in textView: NSTextView, window: NSWindow) -> (anchor: NSPoint, formulaRect: NSRect)? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: formula.range, actualCharacterRange: nil)
        let origin = textView.textContainerOrigin
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let visibleFormula = rect.intersection(textView.visibleRect)
        guard !visibleFormula.isNull, !visibleFormula.isEmpty else { return nil }

        // The text view is flipped: maxY is the bottom edge.
        let anchor = NSPoint(x: visibleFormula.minX, y: visibleFormula.maxY)
        let screenAnchor = window.convertPoint(toScreen: textView.convert(anchor, to: nil))
        let screenRect = window.convertToScreen(textView.convert(visibleFormula, to: nil))
        return (screenAnchor, screenRect)
    }
}
