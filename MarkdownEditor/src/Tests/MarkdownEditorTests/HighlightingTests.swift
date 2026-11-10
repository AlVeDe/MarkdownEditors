import AppKit
import Foundation
import Testing
@testable import MarkdownEditor

@MainActor
struct HighlightingTests {
    private func makeEditor(_ text: String) -> EditorController {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-highlighting")!))
        editor.setText(text)
        return editor
    }

    private func sample() throws -> String {
        let url = try #require(Bundle.resources.url(forResource: "Sample", withExtension: "md"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The managed attributes of every character, as comparable strings.
    private func attributeDump(_ storage: NSTextStorage) -> [String] {
        var dump: [String] = []
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttributes(in: all) { attributes, range, _ in
            let font = (attributes[.font] as? NSFont).map { "\($0.fontName)" } ?? "-"
            let color = (attributes[.foregroundColor] as? NSColor).map { "\(ObjectIdentifier($0))" } ?? "-"
            let background = (attributes[.backgroundColor] as? NSColor).map { "\(ObjectIdentifier($0))" } ?? "-"
            let strike = attributes[.strikethroughStyle].map { "\($0)" } ?? "-"
            let entry = "\(font)|\(color)|\(background)|\(strike)"
            for _ in 0..<range.length { dump.append(entry) }
        }
        return dump
    }

    private func highlighter(_ editor: EditorController) -> MarkdownHighlighter {
        editor.highlighter as! MarkdownHighlighter
    }

    // MARK: Incremental == full

    @Test(arguments: [1, 42, 2026] as [UInt64])
    func incrementalEditsMatchFullHighlight(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let snippets = [
            "x", "\n", "```", "```python\n", "~~~\n", "$$", "$$\n", "---\n", "<!--", "-->", "`", "*", "**",
            "# ", "> ", "- ", "1. ", "| a | b |\n", "$x$", "\\", "[a](b)", "    ", "===\n", "```mermaid\n", "\n\n",
            // Inline syntax that pairs across the lines of a paragraph.
            "_", "__", "~~", "``", "`a\nb`", "**a\nb", "[a\nb", "](c)"
        ]
        let editor = makeEditor(try sample())
        let storage = try #require(editor.textView.textStorage)
        for step in 0..<120 {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &rng)
            let deleteLength = Bool.random(using: &rng) ? 0 : min(length - location, Int.random(in: 0...40, using: &rng))
            let insert = Int.random(in: 0..<4, using: &rng) == 0 ? "" : snippets.randomElement(using: &rng)!
            storage.replaceCharacters(in: NSRange(location: location, length: deleteLength), with: insert)

            let fresh = makeEditor(storage.string)
            let freshStorage = try #require(fresh.textView.textStorage)
            #expect(highlighter(editor).lineStarts == highlighter(fresh).lineStarts, "line starts after step \(step)")
            #expect(highlighter(editor).lineStates == highlighter(fresh).lineStates, "line states after step \(step)")
            let incremental = attributeDump(storage)
            let full = attributeDump(freshStorage)
            if incremental != full {
                let index = (0..<min(incremental.count, full.count)).first { incremental[$0] != full[$0] } ?? 0
                Issue.record("attributes differ after step \(step) at \(index): \(incremental[index]) vs \(full[index])")
                return
            }
        }
    }

    @Test func multiCharacterEditsInsideBlocks() throws {
        let editor = makeEditor("text\n\n```js\nlet a = 1 /* x\ny */\n```\nafter $x$\n")
        let storage = try #require(editor.textView.textStorage)
        // Close the comment differently, then delete the closing fence.
        storage.replaceCharacters(in: NSRange(location: 25, length: 4), with: "z")
        let closer = (storage.string as NSString).range(of: "```\nafter")
        storage.replaceCharacters(in: NSRange(location: closer.location, length: 4), with: "")
        let fresh = makeEditor(storage.string)
        #expect(attributeDump(storage) == attributeDump(fresh.textView.textStorage!))
        #expect(editor.context(at: storage.length - 2) == .codeBlock(language: "js"))
    }

    @Test func typingInParagraphTouchesFewLines() throws {
        let editor = makeEditor(try sample())
        let storage = try #require(editor.textView.textStorage)
        let location = (storage.string as NSString).range(of: "Parse the Markdown").location
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "a")
        #expect(highlighter(editor).lastProcessedLines.count <= 3)

        // Opening a fence re-pairs every fence below up to the next closing
        // one (the C# block's), which re-colors far more than a few lines.
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "\n```\n")
        #expect(highlighter(editor).lastProcessedLines.count > 20)
        #expect(highlighter(editor).lastProcessedLines.upperBound < highlighter(editor).lineStarts.count)
    }

    @Test func keepsParagraphStyle() throws {
        let editor = makeEditor("# Title\n\nSome **bold** text\n")
        let storage = try #require(editor.textView.textStorage)
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 99
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        editor.highlighter.highlightAll(storage)
        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x")
        for location in [0, 5, 12, storage.length - 1] {
            let found = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            #expect(found?.defaultTabInterval == 99)
            #expect(storage.attribute(.font, at: location, effectiveRange: nil) != nil)
        }
    }

    // MARK: Colors

    @Test func appliesStyles() throws {
        let text = "# Head\n\nA **bold** and *it* and ~~gone~~ `code` $x$\n\n```swift\nlet a\n```\n"
        let editor = makeEditor(text)
        let storage = try #require(editor.textView.textStorage)
        let ns = text as NSString
        func color(at needle: String, offset: Int = 0) -> NSColor? {
            storage.attribute(.foregroundColor, at: ns.range(of: needle).location + offset, effectiveRange: nil) as? NSColor
        }
        func font(at needle: String) -> NSFont? {
            storage.attribute(.font, at: ns.range(of: needle).location, effectiveRange: nil) as? NSFont
        }
        #expect(color(at: "# ") === HighlightPalette.marker)
        #expect(color(at: "Head") === HighlightPalette.heading)
        #expect(font(at: "bold")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(at: "it*")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(color(at: "**bold") === HighlightPalette.marker)
        #expect(storage.attribute(.strikethroughStyle, at: ns.range(of: "gone").location, effectiveRange: nil) != nil)
        #expect(color(at: "code`") === HighlightPalette.inlineCode)
        #expect(color(at: "$x$", offset: 1) === HighlightPalette.math)
        #expect(storage.attribute(.backgroundColor, at: ns.range(of: "let a").location, effectiveRange: nil) != nil)
        #expect(color(at: "A **") === NSColor.textColor)
    }

    @Test func tokenizesKnownLanguages() throws {
        let text = "```python\ndef f():\n    return \"s\"  # c\n```\n"
        let editor = makeEditor(text)
        let storage = try #require(editor.textView.textStorage)
        let ns = text as NSString
        let keyword = storage.attribute(.foregroundColor, at: ns.range(of: "def").location, effectiveRange: nil) as? NSColor
        let string = storage.attribute(.foregroundColor, at: ns.range(of: "\"s\"").location, effectiveRange: nil) as? NSColor
        #expect(keyword === HighlightPalette.token(.keyword))
        #expect(string === HighlightPalette.token(.string))
    }

    // MARK: Context

    @Test func contexts() {
        let text = """
        ---
        title: Demo
        ---

        Text with `code` and $x^2$ and $$y$$ here.
        <!-- note
        still note -->

        ```swift
        let a = 1
        ```

        ```mermaid
        graph TD
        ```

        ```math
        a^2
        ```

        $$
        \\frac{a}{b}
        $$

            indented code

        Typing $\\alp
        Price $5 and $ 10
        """
        let editor = makeEditor(text)
        let ns = text as NSString
        func context(_ needle: String, offset: Int = 0) -> EditorContext {
            let range = ns.range(of: needle)
            precondition(range.location != NSNotFound, needle)
            return editor.context(at: range.location + offset)
        }
        #expect(editor.context(at: 1) == .frontMatter)
        #expect(context("title") == .frontMatter)
        #expect(context("Text with") == .markdown)
        #expect(context("code`", offset: 2) == .inlineCode)
        #expect(context("`code`") == .markdown)
        #expect(context("code` and", offset: 5) == .markdown)
        #expect(context("x^2", offset: 1) == .inlineMath)
        #expect(context("x^2$", offset: 3) == .inlineMath)
        #expect(context("$x^2$", offset: 5) == .markdown)
        #expect(context("y$$") == .displayMath)
        #expect(context("note\n") == .htmlComment)
        #expect(context("still") == .htmlComment)
        #expect(context("```swift", offset: 3) == .fenceInfo)
        #expect(context("```swift", offset: 8) == .fenceInfo)
        #expect(context("let a") == .codeBlock(language: "swift"))
        #expect(context("graph") == .mermaid)
        #expect(context("a^2") == .displayMath)
        #expect(context("\\frac") == .displayMath)
        #expect(context("indented") == .codeBlock(language: nil))
        #expect(context("\\alp", offset: 4) == .inlineMath)
        #expect(context("Typing") == .markdown)
        #expect(context("Price $5", offset: 8) == .inlineMath)
        #expect(context(" 10", offset: 3) == .inlineMath || context(" 10", offset: 3) == .markdown)
        #expect(context("Price") == .markdown)
    }

    @Test func contextAfterEdits() throws {
        let editor = makeEditor("Hello\n")
        editor.replaceCharacters(in: NSRange(location: 6, length: 0), with: "```")
        #expect(editor.context(at: 9) == .fenceInfo)
        editor.replaceCharacters(in: NSRange(location: 9, length: 0), with: "mermaid\n")
        #expect(editor.context(at: 17) == .mermaid)
        editor.replaceCharacters(in: NSRange(location: 17, length: 0), with: "graph\n```\n$")
        #expect(editor.context(at: editor.string.length) == .markdown)
        editor.replaceCharacters(in: NSRange(location: editor.string.length, length: 0), with: "\\a")
        #expect(editor.context(at: editor.string.length) == .inlineMath)
    }

    @Test func contextForUnseenText() {
        let highlighter = MarkdownHighlighter()
        #expect(highlighter.context(at: 6, in: "```js\nx\n```") == .codeBlock(language: "js"))
    }

    // MARK: Performance

    @Test func tenThousandLinesIsFast() throws {
        let base = try sample()
        let baseLines = base.split(separator: "\n", omittingEmptySubsequences: false).count
        let text = String(repeating: base + "\n", count: 10_000 / baseLines + 1)
        let storage = NSTextStorage(string: text)
        let highlighter = MarkdownHighlighter()
        let clock = ContinuousClock()
        let elapsed = clock.measure { highlighter.highlightAll(storage) }
        #expect(highlighter.lineStarts.count >= 10_000)
        #expect(elapsed < .milliseconds(500), "highlightAll took \(elapsed)")

        // One keystroke in the middle touches only a few lines.
        let middle = (text as NSString).range(of: "Parse the Markdown", range: NSRange(location: text.utf16.count / 2, length: text.utf16.count / 2)).location
        storage.replaceCharacters(in: NSRange(location: middle, length: 0), with: "z")
        let keystroke = clock.measure {
            highlighter.textStorage(storage, didEditRange: NSRange(location: middle, length: 1), changeInLength: 1)
        }
        #expect(highlighter.lastProcessedLines.count <= 3)
        #expect(keystroke < .milliseconds(20), "keystroke took \(keystroke)")
    }
}

/// Deterministic random numbers so failures reproduce.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
