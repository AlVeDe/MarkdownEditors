import AppKit
import Testing
@testable import MarkdownEditor

/// Text with the selection marked: `|` is the caret, `«…»` a selection.
@MainActor
private final class Harness {
    let settings: EditorSettings
    let editor: EditorController
    let assistant: MarkdownEditingAssistant

    init() {
        let defaults = UserDefaults(suiteName: "tests-assist")!
        defaults.removePersistentDomain(forName: "tests-assist")
        settings = EditorSettings(defaults: defaults)
        settings.tabWidth = 4
        settings.indentWithSpaces = true
        settings.autoPairs = true
        editor = EditorController(settings: settings)
        assistant = MarkdownEditingAssistant(editor: editor, settings: settings)
    }

    func set(_ marked: String) {
        var text = marked
        var selection = NSRange(location: 0, length: 0)
        if let open = text.range(of: "«"), let close = text.range(of: "»") {
            let start = (String(text[..<open.lowerBound]) as NSString).length
            let end = (String(text[..<close.lowerBound]) as NSString).length - 1
            text.removeSubrange(close)
            text.removeSubrange(open)
            selection = NSRange(location: start, length: end - start)
        } else if let caret = text.range(of: "|") {
            selection = NSRange(location: (String(text[..<caret.lowerBound]) as NSString).length, length: 0)
            text.removeSubrange(caret)
        }
        editor.setText(text)
        editor.selectedRange = selection
    }

    var state: String {
        let text = editor.string
        let selection = editor.selectedRange
        if selection.length == 0 {
            return text.replacingCharacters(in: selection, with: "|")
        }
        return text.substring(to: selection.location) + "«" + text.substring(with: selection) + "»"
            + text.substring(from: NSMaxRange(selection))
    }

    @discardableResult
    func command(_ selector: Selector) -> Bool {
        assistant.textView(editor.textView, doCommandBy: selector)
    }

    func newline() { if !command(#selector(NSResponder.insertNewline(_:))) { editor.textView.insertNewline(nil) } }
    func tab() { if !command(#selector(NSResponder.insertTab(_:))) { editor.textView.insertTab(nil) } }
    func backtab() { command(#selector(NSResponder.insertBacktab(_:))) }
    func backspace() { if !command(#selector(NSResponder.deleteBackward(_:))) { editor.textView.deleteBackward(nil) } }

    func type(_ text: String) {
        for character in text {
            let string = String(character)
            if !assistant.textView(editor.textView, insertText: string, replacementRange: NSRange(location: NSNotFound, length: 0)) {
                editor.replaceCharacters(in: editor.selectedRange, with: string)
            }
        }
    }

    func perform(_ action: FormatAction, pasteboard: NSPasteboard? = nil) {
        let board = pasteboard ?? NSPasteboard(name: NSPasteboard.Name("tests-assist-empty"))
        if pasteboard == nil { board.clearContents() }
        editor.perform(action, pasteboard: board)
    }
}

@MainActor
struct ListContinuationTests {
    @Test func continuesBullets() {
        let h = Harness()
        h.set("- one|")
        h.newline()
        #expect(h.state == "- one\n- |")
        h.set("  * nested|")
        h.newline()
        #expect(h.state == "  * nested\n  * |")
        h.set("+ plus|")
        h.newline()
        #expect(h.state == "+ plus\n+ |")
    }

    @Test func incrementsNumbers() {
        let h = Harness()
        h.set("1. one|")
        h.newline()
        #expect(h.state == "1. one\n2. |")
        h.set("9) nine|")
        h.newline()
        #expect(h.state == "9) nine\n10) |")
    }

    @Test func continuesTasksUnchecked() {
        let h = Harness()
        h.set("- [x] done|")
        h.newline()
        #expect(h.state == "- [x] done\n- [ ] |")
    }

    @Test func continuesQuotes() {
        let h = Harness()
        h.set("> quoted|")
        h.newline()
        #expect(h.state == "> quoted\n> |")
        h.set("> - item|")
        h.newline()
        #expect(h.state == "> - item\n> - |")
    }

    @Test func emptyItemEndsList() {
        let h = Harness()
        h.set("- one\n- |")
        h.newline()
        #expect(h.state == "- one\n|")
        h.set("1. one\n2. |")
        h.newline()
        #expect(h.state == "1. one\n|")
        h.set("> - a\n> - |")
        h.newline()
        #expect(h.state == "> - a\n>|")
        h.set("> a\n> |")
        h.newline()
        #expect(h.state == "> a\n|")
    }

    @Test func splitsItemInTheMiddle() {
        let h = Harness()
        h.set("- one|two")
        h.newline()
        #expect(h.state == "- one\n- |two")
    }

    @Test func autoIndentsPlainLines() {
        let h = Harness()
        h.set("    indented|")
        h.newline()
        #expect(h.state == "    indented\n    |")
        h.set("plain|")
        h.newline()
        #expect(h.state == "plain\n|")
    }

    @Test func noListContinuationInCode() {
        let h = Harness()
        h.set("```\n- not a list|\n```")
        h.newline()
        #expect(h.state == "```\n- not a list\n|\n```")
        h.set("```\n  code|\n```")
        h.newline()
        #expect(h.state == "```\n  code\n  |\n```")
    }
}

@MainActor
struct IndentationTests {
    @Test func tabIndentsListItem() {
        let h = Harness()
        h.set("- it|em")
        h.tab()
        #expect(h.state == "    - it|em")
        h.backtab()
        #expect(h.state == "- it|em")
    }

    @Test func tabInsertsIndentUnitOtherwise() {
        let h = Harness()
        h.set("ab|c")
        h.tab()
        #expect(h.state == "ab    |c")
    }

    @Test func indentsAndOutdentsSelection() {
        let h = Harness()
        h.set("«one\n\ntwo»\nthree")
        h.tab()
        #expect(h.state == "«    one\n\n    two»\nthree")
        h.backtab()
        #expect(h.state == "«one\n\ntwo»\nthree")
        h.set("\t«a\n  b»")
        h.backtab()
        #expect(h.state == "«a\nb»")
    }

    @Test func formatIndentOutdent() {
        let h = Harness()
        h.set("x|")
        h.perform(.indent)
        #expect(h.editor.string == "    x")
        h.perform(.outdent)
        #expect(h.editor.string == "x")
    }
}

@MainActor
struct AutoPairTests {
    @Test func insertsPairs() {
        let h = Harness()
        h.set("|")
        h.type("(")
        #expect(h.state == "(|)")
        h.type("a)")
        #expect(h.state == "(a)|")
        h.set("|")
        h.type("[")
        #expect(h.state == "[|]")
        h.set("say |")
        h.type("\"")
        #expect(h.state == "say \"|\"")
    }

    @Test func noQuotePairAfterWord() {
        let h = Harness()
        h.set("don|")
        h.type("\"")
        #expect(h.state == "don\"|")
        h.set("word|")
        h.type("`")
        #expect(h.state == "word`|")
    }

    @Test func typingAFenceDoesNotLeaveStrayBackticks() {
        let h = Harness()
        h.set("|")
        h.type("```")
        #expect(h.state == "```|")
    }

    @Test func noPairBeforeWord() {
        let h = Harness()
        h.set("|word")
        h.type("(")
        #expect(h.state == "(|word")
    }

    @Test func wrapsSelection() {
        let h = Harness()
        h.set("«word»")
        h.type("*")
        #expect(h.state == "*«word»*")
        h.type("*")
        #expect(h.state == "**«word»**")
        h.set("«x»")
        h.type("$")
        #expect(h.state == "$«x»$")
        h.set("«x»")
        h.type("(")
        #expect(h.state == "(«x»)")
    }

    @Test func backspaceDeletesEmptyPair() {
        let h = Harness()
        h.set("a(|)b")
        h.backspace()
        #expect(h.state == "a|b")
    }

    @Test func noPairsInCodeBlock() {
        let h = Harness()
        h.set("```\n|\n```")
        h.type("(")
        #expect(h.state == "```\n(|\n```")
    }

    @Test func respectsSetting() {
        let h = Harness()
        h.settings.autoPairs = false
        h.set("|")
        h.type("(")
        #expect(h.state == "(|")
    }
}

@MainActor
struct FormatActionTests {
    @Test func boldTogglesOnSelection() {
        let h = Harness()
        h.set("a «word» b")
        h.perform(.bold)
        #expect(h.state == "a **«word»** b")
        h.perform(.bold)
        #expect(h.state == "a «word» b")
        h.set("«**word**»")
        h.perform(.bold)
        #expect(h.state == "«word»")
    }

    @Test func boldWithoutSelectionInsertsPair() {
        let h = Harness()
        h.set("a |")
        h.perform(.bold)
        #expect(h.state == "a **|**")
        h.perform(.bold)
        #expect(h.state == "a |")
    }

    @Test func italicDistinguishesBold() {
        let h = Harness()
        h.set("**«word»**")
        h.perform(.italic)
        #expect(h.state == "***«word»***")
        h.perform(.italic)
        #expect(h.state == "**«word»**")
        h.set("«word »")
        h.perform(.italic)
        #expect(h.state == "*«word»* ")
    }

    @Test func strikethroughAndMath() {
        let h = Harness()
        h.set("«x»")
        h.perform(.strikethrough)
        #expect(h.state == "~~«x»~~")
        h.perform(.strikethrough)
        #expect(h.state == "«x»")
        h.perform(.inlineMath)
        #expect(h.state == "$«x»$")
        h.perform(.inlineMath)
        #expect(h.state == "«x»")
    }

    @Test func inlineCodeUsesLongerFence() {
        let h = Harness()
        h.set("«code»")
        h.perform(.inlineCode)
        #expect(h.state == "`«code»`")
        h.perform(.inlineCode)
        #expect(h.state == "«code»")
        h.set("«a`b»")
        h.perform(.inlineCode)
        #expect(h.state == "``«a`b»``")
        h.set("«`x»")
        h.perform(.inlineCode)
        #expect(h.state == "`` «`x»``" || h.state == "`` «`x» ``")
    }

    @Test func headings() {
        let h = Harness()
        h.set("Tit|le")
        h.perform(.heading(2))
        #expect(h.state == "## Tit|le")
        h.perform(.heading(1))
        #expect(h.state == "# Tit|le")
        h.perform(.heading(1))
        #expect(h.state == "Tit|le")
        h.perform(.heading(3))
        h.perform(.paragraph)
        #expect(h.state == "Tit|le")
    }

    @Test func quoteToggles() {
        let h = Harness()
        h.set("«a\nb»")
        h.perform(.quote)
        #expect(h.editor.string == "> a\n> b")
        h.perform(.quote)
        #expect(h.editor.string == "a\nb")
    }

    @Test func listsToggleAndConvert() {
        let h = Harness()
        h.set("«a\n\nb»")
        h.perform(.bulletList)
        #expect(h.editor.string == "- a\n\n- b")
        h.perform(.numberedList)
        #expect(h.editor.string == "1. a\n\n2. b")
        h.perform(.numberedList)
        #expect(h.editor.string == "a\n\nb")
        h.perform(.taskList)
        #expect(h.editor.string == "- [ ] a\n\n- [ ] b")
        h.perform(.taskList)
        #expect(h.editor.string == "a\n\nb")
        h.set("|")
        h.perform(.bulletList)
        #expect(h.state == "- |")
    }

    @Test func toggleTaskCheckbox() {
        let h = Harness()
        h.set("- [ ] t|odo")
        h.perform(.toggleTask)
        #expect(h.state == "- [x] t|odo")
        h.perform(.toggleTask)
        #expect(h.state == "- [ ] t|odo")
        h.set("- item|")
        h.perform(.toggleTask)
        #expect(h.state == "- [ ] item|")
        h.set("plain|")
        h.perform(.toggleTask)
        #expect(h.state == "- [ ] plain|")
    }

    @Test func linkUsesPlaceholderOrClipboard() {
        let h = Harness()
        h.set("«text»")
        h.perform(.link)
        #expect(h.state == "[text](«url»)")

        let board = NSPasteboard(name: NSPasteboard.Name("tests-assist-url"))
        board.clearContents()
        board.setString("https://example.com", forType: .string)
        h.set("«text»")
        h.perform(.link, pasteboard: board)
        #expect(h.state == "[«text»](https://example.com)")

        h.set("|")
        h.perform(.image)
        #expect(h.state == "![alt text](«path»)")
    }

    @Test func codeBlockWrapsAndUnwraps() {
        let h = Harness()
        h.set("«let x = 1»")
        h.perform(.codeBlock(language: "python"))
        #expect(h.state == "```«python»\nlet x = 1\n```")
        h.perform(.codeBlock(language: "python"))
        #expect(h.state == "«let x = 1»")
        h.set("|")
        h.perform(.codeBlock(language: nil))
        #expect(h.state == "```|\n\n```")
    }

    @Test func displayMathAndMermaid() {
        let h = Harness()
        h.set("|")
        h.perform(.displayMath)
        #expect(h.state == "$$\n|\n$$")
        h.set("|")
        h.perform(.mermaid)
        #expect(h.state == "```mermaid\nflowchart TD\n    |\n```")
    }

    @Test func tableAndRule() {
        let h = Harness()
        h.set("|")
        h.perform(.table(rows: 1, columns: 2))
        #expect(h.state == "| «Column 1» | Column 2 |\n| -------- | -------- |\n|          |          |")
        h.set("Paragraph|")
        h.perform(.horizontalRule)
        #expect(h.state == "Paragraph\n\n---|")
    }

    @Test func undoRestoresText() {
        let h = Harness()
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        h.set("a «word» b")
        h.perform(.bold)
        #expect(h.editor.string == "a **word** b")
        #expect(undo.canUndo)
        undo.undo()
        #expect(h.editor.string == "a word b")
        h.perform(.heading(2))
        #expect(h.editor.string == "## a word b")
        undo.undo()
        #expect(h.editor.string == "a word b")
    }
}

@MainActor
struct LineOperationTests {
    @Test func moveLines() {
        let h = Harness()
        h.set("one\ntw|o\nthree")
        h.editor.moveLinesUp()
        #expect(h.state == "tw|o\none\nthree")
        h.editor.moveLinesDown()
        h.editor.moveLinesDown()
        #expect(h.state == "one\nthree\ntw|o")
        h.set("«a\nb»\nc\n")
        h.editor.moveLinesDown()
        #expect(h.state == "c\n«a\nb»\n")
    }

    @Test func duplicateLines() {
        let h = Harness()
        h.set("a|\nb")
        h.editor.duplicateLines()
        #expect(h.state == "a\na|\nb")
        h.set("x\nl|ast")
        h.editor.duplicateLines()
        #expect(h.state == "x\nlast\nl|ast")
    }

    @Test func deleteJoinCommentSelect() {
        let h = Harness()
        h.set("a\nb|\nc")
        h.editor.deleteLines()
        #expect(h.state == "a\n|c")
        h.set("a\nb|")
        h.editor.deleteLines()
        #expect(h.state == "|a")

        h.set("one|  \n   two")
        h.editor.joinLines()
        #expect(h.state == "one| two")

        h.set("te|xt")
        h.editor.toggleLineComment()
        #expect(h.editor.string == "<!-- text -->")
        h.editor.toggleLineComment()
        #expect(h.editor.string == "text")

        h.set("a|\nb\n")
        h.editor.selectLines()
        #expect(h.state == "«a\n»b\n")
        h.editor.selectLines()
        #expect(h.state == "«a\nb\n»")
    }
}
