import AppKit
import Testing
@testable import MarkdownEditor

/// Editor plus assistant with private settings; `|` marks the caret.
@MainActor
private final class RenumberHarness {
    let settings: EditorSettings
    let editor: EditorController
    let assistant: MarkdownEditingAssistant

    init() {
        let defaults = UserDefaults(suiteName: "tests-renumber")!
        defaults.removePersistentDomain(forName: "tests-renumber")
        settings = EditorSettings(defaults: defaults)
        editor = EditorController(settings: settings)
        assistant = MarkdownEditingAssistant(editor: editor, settings: settings)
    }

    /// An undo manager that only accepts explicit groups — so a test fails
    /// loudly if an edit is not grouped. Only for tests whose edits all are.
    func installStrictUndo() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return undo
    }

    func set(_ marked: String) {
        var text = marked
        var caret = 0
        if let range = text.range(of: "|") {
            caret = (String(text[..<range.lowerBound]) as NSString).length
            text.removeSubrange(range)
        }
        editor.setText(text)
        editor.selectedRange = NSRange(location: caret, length: 0)
    }

    var state: String {
        let selection = editor.selectedRange
        return editor.string.replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "|")
    }

    func command(_ selector: Selector) {
        _ = assistant.textView(editor.textView, doCommandBy: selector)
    }

    func newline() { command(#selector(NSResponder.insertNewline(_:))) }
    func tab() { command(#selector(NSResponder.insertTab(_:))) }
    func backtab() { command(#selector(NSResponder.insertBacktab(_:))) }
}

@MainActor
struct ListRenumberingTests {
    @Test func returnInTheMiddleShiftsFollowingItems() {
        let h = RenumberHarness()
        h.set("1. a|\n2. b\n3. c")
        h.newline()
        #expect(h.state == "1. a\n2. |\n3. b\n4. c")
    }

    @Test func endingTheListWithReturnRenumbersTheRest() {
        let h = RenumberHarness()
        h.set("1. a\n2. |\n3. b")
        h.newline()
        #expect(h.state == "1. a\n|\n2. b")
    }

    @Test func deleteLine() {
        let h = RenumberHarness()
        h.set("1. a\n2. b|\n3. c\n4. d")
        h.editor.deleteLines()
        #expect(h.state == "1. a\n|2. c\n3. d")
        // Deleting the first item keeps the list's start.
        h.set("1. |a\n2. b\n3. c")
        h.editor.deleteLines()
        #expect(h.state == "|1. b\n2. c")
    }

    @Test func moveLineUpAndDown() {
        let h = RenumberHarness()
        h.set("1. a\n2. b\n3. c|")
        h.editor.moveLinesUp()
        #expect(h.state == "1. a\n2. c|\n3. b")
        h.editor.moveLinesUp()
        #expect(h.state == "1. c|\n2. a\n3. b")
        h.editor.moveLinesDown()
        #expect(h.state == "1. a\n2. c|\n3. b")
    }

    @Test func duplicateLine() {
        let h = RenumberHarness()
        h.set("1. a|\n2. b")
        h.editor.duplicateLines()
        #expect(h.state == "1. a\n2. a|\n3. b")
    }

    @Test func keepsStartNumber() {
        let h = RenumberHarness()
        h.set("3. a|\n4. b")
        h.newline()
        #expect(h.state == "3. a\n4. |\n5. b")
        h.set("3. a\n4. b|\n5. c")
        h.editor.moveLinesUp()
        #expect(h.state == "3. b|\n4. a\n5. c")
    }

    @Test func nestedListsAreIndependent() {
        let h = RenumberHarness()
        h.set("1. a\n   1. x|\n   2. y\n2. b\n3. c")
        h.newline()
        #expect(h.state == "1. a\n   1. x\n   2. |\n   3. y\n2. b\n3. c")

        // Renumbering the outer list fixes the inner one too, on its own.
        h.set("1. a\n   1. x\n   5. y\n7. b|")
        h.editor.renumberOrderedListAtSelection()
        #expect(h.editor.string == "1. a\n   1. x\n   2. y\n2. b")
    }

    @Test func tabAndShiftTabChangeLevels() {
        let h = RenumberHarness()
        h.set("1. a\n2. b|\n3. c")
        h.tab()
        #expect(h.state == "1. a\n    1. b|\n2. c")
        h.backtab()
        #expect(h.state == "1. a\n2. b|\n3. c")
    }

    @Test func caretStaysWhenDigitsGrow() {
        let h = RenumberHarness()
        let items = (1...8).map { "\($0). i\($0)" }.joined(separator: "\n")
        h.set(items + "|\n9. last")
        h.newline()
        #expect(h.state == items + "\n9. |\n10. last")
        // Caret after a number that gains a digit moves with its text.
        h.set("1. a\n" + (2...9).map { "\($0). i" }.joined(separator: "\n") + "\n9. x|y")
        h.editor.renumberOrderedListAtSelection()
        #expect(h.state.hasSuffix("\n9. i\n10. x|y"))
    }

    @Test func allOnesStyleIsLeftAlone() {
        let h = RenumberHarness()
        h.set("1. a\n1. b|\n1. c")
        h.newline()
        #expect(h.state == "1. a\n1. b\n1. |\n1. c")
        h.editor.deleteLines()
        #expect(h.editor.string == "1. a\n1. b\n1. c")
    }

    @Test func parenDelimiter() {
        let h = RenumberHarness()
        h.set("1) a|\n2) b")
        h.newline()
        #expect(h.state == "1) a\n2) |\n3) b")
        // A different delimiter is a different list.
        h.set("1. a|\n2. b\n1) x\n2) y")
        h.newline()
        #expect(h.editor.string == "1. a\n2. \n3. b\n1) x\n2) y")
    }

    @Test func fencedCodeIsUntouched() {
        let h = RenumberHarness()
        h.set("1. a|\n2. b\n```\n3. code\n9. code\n```\n5. after")
        h.newline()
        #expect(h.editor.string == "1. a\n2. \n3. b\n```\n3. code\n9. code\n```\n5. after")
    }

    @Test func toggleNumbersJoinsTheList() {
        let h = RenumberHarness()
        h.set("1. a\n2. b\nc|")
        h.editor.perform(.numberedList)
        #expect(h.editor.string == "1. a\n2. b\n3. c")
    }

    @Test func settingOffDisablesAutomaticRenumbering() {
        let h = RenumberHarness()
        h.settings.renumbersLists = false
        h.set("1. a|\n2. b")
        h.newline()
        #expect(h.state == "1. a\n2. |\n2. b")
        h.editor.deleteLines()
        #expect(h.editor.string == "1. a\n2. b")
        h.set("1. a\n3. b|")
        h.editor.renumberOrderedListAtSelection()
        #expect(h.state == "1. a\n2. b|")
    }

    @Test func oneUndoRestoresOriginal() {
        let h = RenumberHarness()
        let undo = h.installStrictUndo()
        h.set("1. a|\n2. b\n3. c")
        h.newline()
        #expect(h.editor.string == "1. a\n2. \n3. b\n4. c")
        undo.undo()
        #expect(h.editor.string == "1. a\n2. b\n3. c")

        h.set("1. a\n2. b\n3. c|")
        h.editor.moveLinesUp()
        #expect(h.editor.string == "1. a\n2. c\n3. b")
        undo.undo()
        #expect(h.editor.string == "1. a\n2. b\n3. c")
    }

    @Test func pureCore() {
        let lines = ["2. a", "", "   text", "2. b", "", "para", "1. c"]
        let edits = ListRenumbering.edits(in: lines, around: 0)
        #expect(edits == [ListRenumbering.Edit(line: 3, range: NSRange(location: 0, length: 1), replacement: "3")])
        // Quoted list.
        #expect(ListRenumbering.edits(in: ["> 1. a", "> 5. b", "> 9. c"], around: 1).map(\.replacement) == ["2", "3"])
        // A heading ends the list.
        #expect(ListRenumbering.edits(in: ["1. a", "# H", "5. b"], around: 0).isEmpty)
    }
}
