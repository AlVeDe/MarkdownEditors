import AppKit
import Testing
@testable import MarkdownEditor

/// A provider that offers LaTeX-ish commands after `\` and words after "wo".
@MainActor
private final class FakeProvider: CompletionProvider {
    let triggerCharacters: Set<Character> = ["\\"]
    var requests: [CompletionRequest] = []
    var items: [CompletionItem] = [
        CompletionItem(label: "\\alpha", detail: "Greek", documentation: "α", kind: .symbol, insertText: "\\alpha"),
        CompletionItem(label: "\\beta", kind: .symbol, insertText: "\\beta"),
        CompletionItem(label: "\\frac", kind: .command, insertText: "\\frac{${1:num}}{${2:den}}$0"),
        CompletionItem(label: "\\leftarrow", kind: .symbol, insertText: "\\leftarrow")
    ]

    func completions(for request: CompletionRequest) -> CompletionResult? {
        requests.append(request)
        let text = request.text
        // Walk back over letters to a backslash.
        var start = request.location
        while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)), CharacterSet.letters.contains(scalar) {
            start -= 1
        }
        if start > 0, text.character(at: start - 1) == 0x5C {
            return CompletionResult(replacementRange: NSRange(location: start - 1, length: request.location - start + 1), items: items)
        }
        if request.isExplicit {
            return CompletionResult(replacementRange: NSRange(location: start, length: request.location - start), items: items)
        }
        return nil
    }
}

@MainActor
struct CompletionTests {
    private func makeEditor(_ suite: String = "tests-completion") -> EditorController {
        EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: suite)!))
    }

    /// An editor with a dedicated completion controller using `provider`.
    private func makeSetup(autoComplete: Bool = true) -> (EditorController, CompletionController, FakeProvider) {
        let editor = makeEditor()
        let settings = EditorSettings(defaults: UserDefaults(suiteName: "tests-completion-\(autoComplete)")!)
        settings.showsCompletions = autoComplete
        let provider = FakeProvider()
        let controller = CompletionController(editor: editor, providers: [provider], settings: settings)
        editor.addInputHandler(controller)
        return (editor, controller, provider)
    }

    /// Types like the keyboard does: through the handlers, then the text view.
    private func type(_ text: String, in editor: EditorController) {
        for character in text {
            editor.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    // MARK: Snippet parsing

    @Test func parsesPlaceholdersAndEscapes() {
        let snippet = Snippet(parsing: #"\frac{${1:a}}{$2} \$x \\ ${3}$0"#)
        #expect(snippet.text == #"\frac{a}{} $x \ "#)
        #expect(snippet.placeholders == [
            .init(index: 1, range: NSRange(location: 6, length: 1)),
            .init(index: 2, range: NSRange(location: 9, length: 0)),
            .init(index: 3, range: NSRange(location: 16, length: 0)),
            .init(index: 0, range: NSRange(location: 16, length: 0))
        ])
        #expect(snippet.tabStopOrder == [1, 2, 3, 0])
    }

    @Test func parsingOrdersByIndexAndKeepsLiteralDollars() {
        let snippet = Snippet(parsing: "$$ ${2:b} ${1:a} ${x} $")
        #expect(snippet.text == "$$ b a ${x} $")
        #expect(snippet.tabStopOrder == [1, 2, 0])
        #expect(!Snippet(parsing: "plain").hasTabStops)
        #expect(Snippet(parsing: "${1:a\\}b}").text == "a}b")
    }

    @Test func parsingIndentsContinuationLines() {
        let snippet = Snippet(parsing: "a\n${1:b}\nc", indentation: "  ")
        #expect(snippet.text == "a\n  b\n  c")
        #expect(snippet.placeholders[0].range == NSRange(location: 4, length: 1))
    }

    // MARK: Snippet session

    @Test func insertSelectsFirstPlaceholderAndTabNavigates() {
        let editor = makeEditor()
        editor.setText("x = \\fr")
        let session = SnippetSession.insert("\\frac{${1:num}}{${2:den}}$0 ", replacing: NSRange(location: 4, length: 3), in: editor)
        #expect(editor.textView.string == "x = \\frac{num}{den} ")
        #expect(editor.selectedRange == NSRange(location: 10, length: 3))
        #expect(session != nil)
        #expect(SnippetSession.active(in: editor) === session)

        // Typing over placeholder 1 moves placeholder 2.
        type("ab", in: editor)
        #expect(editor.textView.string == "x = \\frac{ab}{den} ")
        editor.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(editor.selectedRange == NSRange(location: 14, length: 3))

        editor.textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(editor.selectedRange == NSRange(location: 10, length: 2))

        editor.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        editor.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        // Reached $0: caret after "}" and the session is over.
        #expect(editor.selectedRange == NSRange(location: 18, length: 0))
        #expect(SnippetSession.active(in: editor) == nil)
    }

    @Test func emptyPlaceholdersTrackTyping() {
        let editor = makeEditor()
        editor.setText("")
        SnippetSession.insert("[$1]($2)", replacing: NSRange(location: 0, length: 0), in: editor)
        #expect(editor.selectedRange == NSRange(location: 1, length: 0))
        type("text", in: editor)
        editor.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(editor.selectedRange == NSRange(location: 7, length: 0))
        type("url", in: editor)
        #expect(editor.textView.string == "[text](url)")
        // No $0: the final stop is the end of the snippet.
        editor.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(editor.selectedRange == NSRange(location: 11, length: 0))
        #expect(SnippetSession.active(in: editor) == nil)
    }

    @Test func sessionEndsOnEscapeAndWhenCaretLeaves() {
        let editor = makeEditor()
        editor.setText("start ")
        SnippetSession.insert("${1:a} ${2:b}", replacing: NSRange(location: 6, length: 0), in: editor)
        #expect(SnippetSession.active(in: editor) != nil)
        editor.selectedRange = NSRange(location: 0, length: 0)
        #expect(SnippetSession.active(in: editor) == nil)

        SnippetSession.insert("${1:a}", replacing: NSRange(location: 0, length: 0), in: editor)
        #expect(SnippetSession.active(in: editor) != nil)
        editor.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(SnippetSession.active(in: editor) == nil)
    }

    @Test func multiLineInsertKeepsIndentation() {
        let editor = makeEditor()
        editor.setText("    item")
        SnippetSession.insert("one\ntwo", replacing: NSRange(location: 4, length: 4), in: editor)
        #expect(editor.textView.string == "    one\n    two")
    }

    @Test func placeholderRangeAdjustment() {
        let r = NSRange(location: 10, length: 3)
        #expect(SnippetSession.adjust(r, location: 0, oldLength: 0, newLength: 2, growsAtBoundary: false) == NSRange(location: 12, length: 3))
        #expect(SnippetSession.adjust(r, location: 10, oldLength: 0, newLength: 1, growsAtBoundary: false) == NSRange(location: 11, length: 3))
        #expect(SnippetSession.adjust(r, location: 10, oldLength: 0, newLength: 1, growsAtBoundary: true) == NSRange(location: 10, length: 4))
        #expect(SnippetSession.adjust(r, location: 13, oldLength: 0, newLength: 1, growsAtBoundary: false) == r)
        #expect(SnippetSession.adjust(r, location: 11, oldLength: 1, newLength: 0, growsAtBoundary: false) == NSRange(location: 10, length: 2))
        #expect(SnippetSession.adjust(r, location: 9, oldLength: 3, newLength: 0, growsAtBoundary: true) == nil)
    }

    @Test func insertionIsOneUndoStep() {
        let editor = makeEditor()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.setText("\\fr")
        SnippetSession.insert("\\frac{${1}}{${2}}", replacing: NSRange(location: 0, length: 3), in: editor)
        #expect(editor.textView.string == "\\frac{}{}")
        undo.undo()
        #expect(editor.textView.string == "\\fr")
    }

    // MARK: Fuzzy ranking

    @Test func fuzzyTiers() {
        #expect(FuzzyMatcher.match("alp", in: "alpha")?.tier == .prefix)
        #expect(FuzzyMatcher.match("ALP", in: "alpha")?.matchedIndices == [0, 1, 2])
        #expect(FuzzyMatcher.match("bar", in: "foo_bar")?.tier == .wordBoundary)
        #expect(FuzzyMatcher.match("ra", in: "LeftRightArrow")?.tier == .wordBoundary)
        #expect(FuzzyMatcher.match("ra", in: "LeftRightArrow")?.matchedIndices == [4, 9])
        #expect(FuzzyMatcher.match("lra", in: "leftrightarrow")?.tier == .subsequence)
        #expect(FuzzyMatcher.match("xyz", in: "alpha") == nil)
        #expect(FuzzyMatcher.match("", in: "alpha")?.tier == .prefix)
    }

    @Test func rankingOrder() {
        let items = [
            CompletionItem(label: "subsequence-epsilon", kind: .symbol, insertText: "", filterText: "zzepzzszz"),
            CompletionItem(label: "varepsilon", kind: .symbol, insertText: ""),
            CompletionItem(label: "epsilon-long", kind: .symbol, insertText: ""),
            CompletionItem(label: "epsilon", kind: .symbol, insertText: ""),
            CompletionItem(label: "eps-low", kind: .symbol, insertText: "", sortPriority: -1),
            CompletionItem(label: "my-eps", kind: .symbol, insertText: "")
        ]
        var model = CompletionListModel(result: CompletionResult(replacementRange: NSRange(location: 0, length: 0), items: items), caret: 0)
        model.filter("eps")
        #expect(model.entries.map(\.item.label) == ["epsilon", "epsilon-long", "eps-low", "my-eps", "varepsilon", "subsequence-epsilon"])
        model.moveSelection(by: 100)
        #expect(model.selectedIndex == 5)
        model.moveSelectionWrapping(by: 1)
        #expect(model.selectedIndex == 0)
        model.filter("eps")
        #expect(model.selectedIndex == 0)
    }

    // MARK: Controller

    @Test func triggerCharacterOpensAndTypingFilters() throws {
        let (editor, controller, provider) = makeSetup()
        editor.setText("Let ")
        editor.selectedRange = NSRange(location: 4, length: 0)
        type("\\", in: editor)
        #expect(controller.isShowingCompletions)
        #expect(provider.requests.last?.isExplicit == false)
        #expect(provider.requests.last?.location == 5)
        #expect(controller.model?.entries.count == 4)

        type("fr", in: editor)
        #expect(controller.model?.query == "\\fr")
        #expect(controller.model?.entries.map(\.item.label) == ["\\frac", "\\leftarrow"])

        // Return accepts and replaces exactly `\fr`.
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(!controller.isShowingCompletions)
        #expect(editor.textView.string == "Let \\frac{num}{den}")
        #expect(editor.selectedRange == NSRange(location: 10, length: 3))
        #expect(SnippetSession.active(in: editor) != nil)
    }

    @Test func arrowsMoveSelectionAndTabAccepts() {
        let (editor, controller, _) = makeSetup()
        editor.setText("")
        type("\\", in: editor)
        // Equal matches: shorter labels first, then provider order.
        #expect(controller.model?.entries.map(\.item.label) == ["\\beta", "\\frac", "\\alpha", "\\leftarrow"])
        editor.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(controller.model?.selectedItem?.label == "\\frac")
        editor.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        editor.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(controller.model?.selectedIndex == 3)
        editor.textView.doCommand(by: #selector(NSResponder.scrollPageUp(_:)))
        #expect(controller.model?.selectedIndex == 0)
        editor.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(editor.textView.string == "\\beta")
    }

    @Test func escapeBackspaceAndCaretMovesClose() {
        let (editor, controller, _) = makeSetup()
        editor.setText("a ")
        editor.selectedRange = NSRange(location: 2, length: 0)
        type("\\al", in: editor)
        #expect(controller.isShowingCompletions)
        editor.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!controller.isShowingCompletions)

        type("p", in: editor)
        #expect(controller.model?.query == "\\alp")
        // Backspace widens the filter.
        editor.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(controller.model?.query == "\\al")
        // Deleting before the start closes.
        editor.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        editor.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        editor.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(editor.textView.string == "a ")
        #expect(!controller.isShowingCompletions)

        type("\\b", in: editor)
        #expect(controller.isShowingCompletions)
        editor.selectedRange = NSRange(location: 0, length: 0)
        #expect(!controller.isShowingCompletions)

        // A non-matching character closes.
        editor.selectedRange = NSRange(location: editor.string.length, length: 0)
        type("eta ", in: editor)
        #expect(!controller.isShowingCompletions)
    }

    @Test func explicitControlSpace() throws {
        let (editor, controller, provider) = makeSetup(autoComplete: false)
        editor.setText("fr")
        editor.selectedRange = NSRange(location: 2, length: 0)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        #expect(controller.textView(editor.textView, handleKeyDown: event))
        #expect(provider.requests.last?.isExplicit == true)
        #expect(controller.isShowingCompletions)
        // Explicit popup keeps filtering while typing even with auto-completion off.
        #expect(controller.model?.query == "fr")
        controller.close()

        let plain = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        #expect(!controller.textView(editor.textView, handleKeyDown: plain))
    }

    @Test func settingOffDisablesAutoTrigger() {
        let (editor, controller, provider) = makeSetup(autoComplete: false)
        editor.setText("")
        type("\\al", in: editor)
        #expect(!controller.isShowingCompletions)
        #expect(provider.requests.isEmpty)
        controller.showCompletions()
        #expect(controller.isShowingCompletions)
        #expect(controller.model?.query == "\\al")
        type("p", in: editor)
        #expect(controller.model?.entries.map(\.item.label) == ["\\alpha"])
    }

    @Test func pasteDoesNotTrigger() {
        let (editor, controller, provider) = makeSetup()
        editor.setText("")
        editor.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\\")
        #expect(!controller.isShowingCompletions)
        #expect(provider.requests.isEmpty)
    }

    @Test func highlightedLabelBoldsMatches() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let string = CompletionCellView.highlighted("αbc", matches: [0, 2], font: font)
        let first = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let second = string.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        #expect(first?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(second?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }
}
