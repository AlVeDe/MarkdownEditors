import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct TableFormatterTests {
    private func makeEditor(_ text: String, caret: Int) -> (EditorController, TableFormatter) {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-table")!))
        editor.setText(text)
        editor.selectedRange = NSRange(location: caret, length: 0)
        return (editor, TableFormatter(editor: editor))
    }

    private func command(_ formatter: TableFormatter, _ editor: EditorController, _ selector: Selector) -> Bool {
        formatter.textView(editor.textView, doCommandBy: selector)
    }

    @Test func formatsWithAlignment() {
        let table = MarkdownTable(lines: ["|a|b|c|d|", "|:-|-:|:-:|-|", "|long text|1|x|"])!
        #expect(table.alignments == [.left, .right, .center, .none])
        #expect(table.formatted().text == """
        | a         |   b |  c  | d   |
        | :-------- | --: | :-: | --- |
        | long text |   1 |  x  |     |
        """)
    }

    @Test func keepsPipeStyleAndIndent() {
        let table = MarkdownTable(lines: ["  a | b", "  ---|---", "  1 | 22222"])!
        #expect(!table.leadingPipe && !table.trailingPipe)
        #expect(table.formatted().text == """
          a   | b
          --- | -----
          1   | 22222
        """)
    }

    @Test func escapedPipesAndWideCharacters() {
        let table = MarkdownTable(lines: ["| a \\| b | 日本 |", "|---|---|"])!
        #expect(table.header == ["a \\| b", "日本"])
        #expect(table.formatted().text == """
        | a \\| b | 日本 |
        | ------ | ---- |
        """)
    }

    @Test func tabFormatsAndMovesToNextCell() {
        let text = "before\n\n|a|b|\n|-|-|\n|1|2|\nafter"
        let caret = (text as NSString).range(of: "|a").location + 2  // after "a"
        let (editor, formatter) = makeEditor(text, caret: caret)
        #expect(command(formatter, editor, #selector(NSResponder.insertTab(_:))))
        #expect(editor.textView.string == "before\n\n| a   | b   |\n| --- | --- |\n| 1   | 2   |\nafter")
        // "b" is selected.
        #expect(editor.string.substring(with: editor.selectedRange) == "b")

        // Tab from the last header cell skips the delimiter row.
        #expect(command(formatter, editor, #selector(NSResponder.insertTab(_:))))
        #expect(editor.string.substring(with: editor.selectedRange) == "1")

        // Shift-Tab goes back to the header.
        #expect(command(formatter, editor, #selector(NSResponder.insertBacktab(_:))))
        #expect(editor.string.substring(with: editor.selectedRange) == "b")
    }

    @Test func tabInLastCellAppendsRow() {
        let text = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let (editor, formatter) = makeEditor(text, caret: (text as NSString).length - 2)
        let undoManager = UndoManager()
        editor.undoManager = undoManager
        #expect(command(formatter, editor, #selector(NSResponder.insertTab(_:))))
        #expect(editor.textView.string == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n|     |     |")
        // Caret in the first cell of the new row.
        let lastLine = (editor.textView.string as NSString).range(of: "|     |     |")
        #expect(editor.selectedRange == NSRange(location: lastLine.location + 2, length: 0))
        // One undo step restores the original.
        undoManager.undo()
        #expect(editor.textView.string == text)
    }

    @Test func returnAddsRowAndEmptyRowExits() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\nnext"
        let caret = (text as NSString).range(of: "| 2 |").location + 5
        let (editor, formatter) = makeEditor(text, caret: caret)
        #expect(command(formatter, editor, #selector(NSResponder.insertNewline(_:))))
        #expect(editor.textView.string == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n|     |     |\n\nnext")

        #expect(command(formatter, editor, #selector(NSResponder.insertNewline(_:))))
        #expect(editor.textView.string == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n\n\nnext")
        let string = editor.textView.string as NSString
        #expect(editor.selectedRange.location == string.range(of: "2   |\n").location + 6)
    }

    @Test func returnInsideRowIsNotHandled() {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        let (editor, formatter) = makeEditor(text, caret: (text as NSString).range(of: "1").location)
        #expect(!command(formatter, editor, #selector(NSResponder.insertNewline(_:))))
        // Header row: also default.
        editor.selectedRange = NSRange(location: 9, length: 0)
        #expect(!command(formatter, editor, #selector(NSResponder.insertNewline(_:))))
    }

    @Test func formatTableKeepsCaretInCell() {
        let text = "|a|bc|\n|-|:-:|\n|1|2|"
        let caret = (text as NSString).range(of: "bc").location + 1  // between b and c
        let (editor, formatter) = makeEditor(text, caret: caret)
        #expect(formatter.formatTable(at: caret))
        let string = editor.textView.string as NSString
        #expect(string as String == "| a   | bc  |\n| --- | :-: |\n| 1   |  2  |")
        #expect(editor.selectedRange.location == string.range(of: "bc").location + 1)
    }

    @Test func ignoresNonTablesAndCodeBlocks() {
        let fenced = "```\n|a|b|\n|-|-|\n```"
        let (editor, formatter) = makeEditor(fenced, caret: 6)
        #expect(!command(formatter, editor, #selector(NSResponder.insertTab(_:))))

        editor.setText("a | b without delimiter\nnext")
        editor.selectedRange = NSRange(location: 2, length: 0)
        #expect(!command(formatter, editor, #selector(NSResponder.insertTab(_:))))

        editor.setText("plain\n---\n")
        editor.selectedRange = NSRange(location: 2, length: 0)
        #expect(!command(formatter, editor, #selector(NSResponder.insertTab(_:))))
    }
}
