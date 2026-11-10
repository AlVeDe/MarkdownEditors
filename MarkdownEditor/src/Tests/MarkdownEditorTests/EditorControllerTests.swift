import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct EditorControllerTests {
    @Test func lineNumbersAndLocations() {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests")!))
        editor.setText("one\ntwo\nthree\n")
        #expect(editor.lineNumber(at: 0) == 1)
        #expect(editor.lineNumber(at: 4) == 2)
        #expect(editor.lineNumber(at: 14) == 4)
        #expect(editor.location(ofLine: 3) == 8)
        #expect(editor.location(ofLine: 99) == 14)
    }

    @Test func replaceCharactersUpdatesTextAndSelection() {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests")!))
        editor.setText("hello world")
        editor.replaceCharacters(in: NSRange(location: 6, length: 5), with: "there")
        #expect(editor.textView.string == "hello there")
        #expect(editor.selectedRange == NSRange(location: 11, length: 0))
    }
}
