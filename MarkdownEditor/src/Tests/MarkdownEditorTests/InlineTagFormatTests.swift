import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct InlineTagFormatTests {
    private func makeEditor(_ text: String, selection: NSRange) -> EditorController {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-inline-tags")!))
        // No run loop in tests closes event groups; group explicitly only.
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.setText(text)
        editor.selectedRange = selection
        return editor
    }

    @Test func highlightWrapsAndUnwraps() {
        let editor = makeEditor("a word here", selection: NSRange(location: 2, length: 4))
        editor.perform(.highlight)
        #expect(editor.textView.string == "a <mark>word</mark> here")
        #expect(editor.selectedRange == NSRange(location: 8, length: 4))
        // Same command again with the inner text selected removes the tags.
        editor.perform(.highlight)
        #expect(editor.textView.string == "a word here")
        #expect(editor.selectedRange == NSRange(location: 2, length: 4))
    }

    @Test func unwrapsWhenTagsAreSelected() {
        let editor = makeEditor("x<sup>2</sup>", selection: NSRange(location: 1, length: 12))
        editor.perform(.superscriptText)
        #expect(editor.textView.string == "x2")
    }

    @Test func emptyPairAtCaretTogglesBack() {
        let editor = makeEditor("H2O", selection: NSRange(location: 1, length: 0))
        editor.perform(.subscriptText)
        #expect(editor.textView.string == "H<sub></sub>2O")
        #expect(editor.selectedRange == NSRange(location: 6, length: 0))
        editor.perform(.subscriptText)
        #expect(editor.textView.string == "H2O")
    }

    @Test func footnoteInsertsReferenceAndDefinition() {
        let editor = makeEditor("A claim.\n", selection: NSRange(location: 8, length: 0))
        editor.perform(.footnote)
        #expect(editor.textView.string == "A claim.[^1]\n\n[^1]: ")
        #expect(editor.selectedRange.location == (editor.textView.string as NSString).length)

        // The next one gets the next number and joins the existing notes.
        editor.textView.string.append("First note")
        editor.selectedRange = NSRange(location: 12, length: 0)
        editor.perform(.footnote)
        #expect(editor.textView.string == "A claim.[^1][^2]\n\n[^1]: First note\n[^2]: ")
    }

    @Test func footnoteIsOneUndoStep() {
        let editor = makeEditor("Text", selection: NSRange(location: 4, length: 0))
        // `EditorController.undoManager` is weak (the document owns it), so
        // the test keeps its own strong reference.
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.perform(.footnote)
        #expect(editor.textView.string == "Text[^1]\n\n[^1]: ")
        undo.undo()
        #expect(editor.textView.string == "Text")
    }

    @Test func nextFootnoteNumberSkipsNamedLabels() {
        #expect(EditorController.nextFootnoteNumber(in: "a[^note] b[^3] c[^1]") == 4)
        #expect(EditorController.nextFootnoteNumber(in: "none") == 1)
    }
}

@MainActor
struct FootnoteRenderingTests {
    @Test func referencesAreNumberedByFirstUse() {
        let markdown = """
        First[^b] and second[^a], again[^b].

        [^a]: Note A.
        [^b]: Note B with *emphasis*.
        """
        let rewritten = Footnotes.rewrite(markdown)
        #expect(rewritten.contains(##"First<sup class="footnote-ref"><a href="#fn-1" id="fnref-1">1</a></sup>"##))
        #expect(rewritten.contains(##"second<sup class="footnote-ref"><a href="#fn-2" id="fnref-2">2</a></sup>"##))
        // A repeated reference links to the same note, without a second anchor.
        #expect(rewritten.contains(##"again<sup class="footnote-ref"><a href="#fn-1">1</a></sup>"##))
        #expect(rewritten.contains(##"1. <span id="fn-1"></span>Note B with *emphasis*."##))
        #expect(rewritten.contains(##"2. <span id="fn-2"></span>Note A."##))
    }

    @Test func definitionsBecomeBlankLinesSoLineNumbersHold() {
        let markdown = "Text[^1]\n\n[^1]: The note\n    continued\nAfter"
        let rewritten = Footnotes.rewrite(markdown)
        let lines = rewritten.components(separatedBy: "\n")
        #expect(lines[2] == "")
        #expect(lines[3] == "")
        #expect(lines[4] == "After")
        #expect(rewritten.contains("The note\n    continued"))
    }

    @Test func codeAndUndefinedReferencesStayLiteral() {
        let markdown = "Use `[^1]` and [^missing].[^1]\n\n```\n[^1]\n```\n\n[^1]: Real."
        let rewritten = Footnotes.rewrite(markdown)
        #expect(rewritten.contains("`[^1]`"))
        #expect(rewritten.contains("[^missing]"))
        #expect(rewritten.contains("```\n[^1]\n```"))
        #expect(rewritten.contains(##"<a href="#fn-1" id="fnref-1">1</a>"##))
    }

    @Test func previewHTMLHasFootnoteSection() {
        let html = HtmlRenderer.render(MathBlocks.parse("Claim.[^1]\n\n[^1]: Source."))
        #expect(html.contains("footnote-ref"))
        #expect(html.contains("class=\"footnotes\""))
        #expect(html.contains("<ol"))
        #expect(html.contains("Source."))
        #expect(!html.contains("[^1]"))
    }

    @Test func pdfRendersTagsAndFootnotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PdfExporter.export(
            markdown: "H<sub>2</sub>O, x<sup>2</sup>, <mark>marked</mark>.[^1]\n\n[^1]: The note.",
            mermaid: [], displayMath: [], inlineMath: [], to: url
        )
        let data = try Data(contentsOf: url)
        #expect(data.count > 1000)
    }
}
