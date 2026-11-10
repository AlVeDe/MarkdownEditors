import AppKit
import Testing
@testable import MarkdownEditor

/// Locates the formula at the `|` marker and returns its TeX, or nil.
private func tex(at marked: String) -> String? {
    formula(at: marked).map { $0.formula.tex(in: $0.text) }
}

private func formula(at marked: String) -> (formula: MathFormula, text: NSString)? {
    let caret = (marked as NSString).range(of: "|").location
    let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    return MathFormulaLocator.formula(at: caret, in: text).map { ($0, text) }
}

@MainActor
struct MathFormulaLocatorTests {
    @Test func inlineFormula() throws {
        #expect(tex(at: "Euler: $e^{i|\\pi} + 1 = 0$ is neat") == "e^{i\\pi} + 1 = 0")
        let found = try #require(formula(at: "ab $x|^2$ cd"))
        #expect(found.formula.isDisplay == false)
        #expect(found.formula.range == NSRange(location: 3, length: 5))
        #expect(found.formula.contentRange == NSRange(location: 4, length: 3))
    }

    @Test func inlineEdges() {
        // Right after the opening `$` and right before the closing one: inside.
        #expect(tex(at: "a $|x$ b") == "x")
        #expect(tex(at: "a $x|$ b") == "x")
        // Before the opening or after the closing delimiter: outside.
        #expect(tex(at: "a |$x$ b") == nil)
        #expect(tex(at: "a $x$| b") == nil)
    }

    @Test func inlineChoosesTheRightPair() {
        #expect(tex(at: "$a$ and $b|$") == "b")
        #expect(tex(at: "$a$ and| $b$") == nil)
    }

    @Test func inlineDelimiterRules() {
        // Prices are prose: the closing `$` is preceded by whitespace.
        #expect(tex(at: "costs $5 and |$10 net") == nil)
        // An escaped dollar is not a delimiter.
        #expect(tex(at: "\\$x| and y$") == nil)
        #expect(tex(at: "$a \\$ b|$") == "a \\$ b")
        // Inside a code span nothing is math.
        #expect(tex(at: "`$x|$`") == nil)
        #expect(tex(at: "`code` then $y|$") == "y")
        // Invalid TeX still previews (with an error) while typing.
        #expect(tex(at: "$\\frac{a|$") == "\\frac{a")
    }

    @Test func displayBlock() throws {
        let text = "Intro\n\n$$\n\\int_0^1 x|\\,dx\n$$\n\nAfter $y$"
        let found = try #require(formula(at: text))
        #expect(found.formula.isDisplay)
        #expect(found.formula.isTerminated)
        #expect(found.formula.tex(in: found.text) == "\n\\int_0^1 x\\,dx\n")
        #expect(found.text.substring(with: found.formula.range) == "$$\n\\int_0^1 x\\,dx\n$$")
        // Inline formulas after the block are still found.
        #expect(tex(at: "Intro\n\n$$\nx\n$$\n\nAfter $y|$") == "y")
    }

    @Test func singleLineDisplay() throws {
        let found = try #require(formula(at: "$$ E = m|c^2 $$\nnext"))
        #expect(found.formula.isDisplay)
        #expect(found.formula.tex(in: found.text) == " E = mc^2 ")
        #expect(tex(at: "$$ a $$\nnext |line") == nil)
    }

    @Test func multiLineDisplayWithContentOnDelimiterLines() {
        let text = "$$ \\begin{aligned}\na &= b \\\\\nc &= d|\n\\end{aligned} $$\n"
        #expect(tex(at: text) == " \\begin{aligned}\na &= b \\\\\nc &= d\n\\end{aligned} ")
    }

    @Test func unterminatedDisplayRunsToBlankLine() throws {
        let found = try #require(formula(at: "$$\n\\frac|"))
        #expect(found.formula.isTerminated == false)
        #expect(found.formula.tex(in: found.text) == "\n\\frac")

        let paragraph = try #require(formula(at: "$$\na +| b\nc\n\nmore text $z$"))
        #expect(paragraph.formula.tex(in: paragraph.text) == "\na + b\nc")
        #expect(tex(at: "$$\na + b\n\nmore text $z|$") == "z")
    }

    @Test func caretOutsideDisplayBlock() {
        #expect(tex(at: "before|\n$$\nx\n$$\nafter") == nil)
        #expect(tex(at: "$$\nx\n$$\nafter|") == nil)
        #expect(tex(at: "|$$\nx\n$$") == nil)
    }

    @Test func codeFences() {
        // Math syntax inside a code fence is code.
        #expect(tex(at: "```markdown\n$$\nx|\n$$\n```\n") == nil)
        #expect(tex(at: "```\n$a|$\n```") == nil)
        // A ```math fence is a display formula.
        #expect(tex(at: "```math\na^2 +| b^2\n```\n") == "a^2 + b^2")
        // After a fence, scanning resumes.
        #expect(tex(at: "```\ncode\n```\n$$\ny|\n$$") == "\ny\n")
    }

    @Test func contextGatesTheLocator() {
        let text = "$x$" as NSString
        #expect(MathPreviewController.formula(at: 1, in: text, context: .inlineMath) != nil)
        #expect(MathPreviewController.formula(at: 1, in: text, context: .markdown) != nil)
        #expect(MathPreviewController.formula(at: 1, in: text, context: .inlineCode) == nil)
        #expect(MathPreviewController.formula(at: 1, in: text, context: .htmlComment) == nil)
    }

    @Test func previewControllerIsInstalled() {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests")!))
        let handler = editor.inputHandlers.first { $0 is MathPreviewController }
        #expect(handler?.priority == 50)
        // Moving the caret into a formula without a window must not crash
        // (nor create the panel).
        editor.setText("a $x$ b")
        editor.selectedRange = NSRange(location: 3, length: 0)
    }
}

@MainActor
struct MathPreviewPanelTests {
    /// Renders through the real web view and bundled MathJax: a valid
    /// formula has a size and no error, an invalid one reports MathJax's
    /// message, and a `\label` can be rendered twice (`texReset`).
    @Test(.timeLimit(.minutes(1))) func rendersFormulasAndErrors() async throws {
        let panel = MathPreviewPanel()
        let valid = try #require(await panel.render(tex: "\\frac{a}{b} \\label{eq}", display: true, fontSize: 15))
        #expect(valid.error == nil)
        #expect(valid.size.width > 5 && valid.size.height > 5)
        let again = try #require(await panel.render(tex: "\\frac{a}{b} \\label{eq}", display: true, fontSize: 15))
        #expect(again.error == nil)

        let invalid = try #require(await panel.render(tex: "\\frac{a", display: false, fontSize: 15))
        #expect(invalid.error == "Missing close brace")
        let undefined = try #require(await panel.render(tex: "\\nosuchmacro", display: false, fontSize: 15))
        #expect(undefined.error?.contains("Undefined control sequence") == true)
        #expect(panel.isVisible == false)
    }
}
