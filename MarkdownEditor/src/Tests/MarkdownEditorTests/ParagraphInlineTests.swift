import AppKit
import Foundation
import Testing
@testable import MarkdownEditor

/// Inline syntax is analyzed per paragraph: emphasis, code spans and links
/// may span the lines of one paragraph but never leave it.
@MainActor
struct ParagraphInlineTests {
    private func makeEditor(_ text: String) -> EditorController {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-paragraph-inline")!))
        editor.setText(text)
        return editor
    }

    /// Reads attributes at the first occurrence of a needle.
    private struct Probe {
        let storage: NSTextStorage

        func location(_ needle: String, offset: Int = 0) -> Int {
            let range = (storage.string as NSString).range(of: needle)
            precondition(range.location != NSNotFound, needle)
            return range.location + offset
        }

        func traits(_ needle: String, offset: Int = 0) -> NSFontDescriptor.SymbolicTraits {
            let font = storage.attribute(.font, at: location(needle, offset: offset), effectiveRange: nil) as? NSFont
            return font?.fontDescriptor.symbolicTraits ?? []
        }

        func bold(_ needle: String, offset: Int = 0) -> Bool { traits(needle, offset: offset).contains(.bold) }
        func italic(_ needle: String, offset: Int = 0) -> Bool { traits(needle, offset: offset).contains(.italic) }

        func color(_ needle: String, offset: Int = 0) -> NSColor? {
            storage.attribute(.foregroundColor, at: location(needle, offset: offset), effectiveRange: nil) as? NSColor
        }

        func struck(_ needle: String) -> Bool {
            storage.attribute(.strikethroughStyle, at: location(needle), effectiveRange: nil) != nil
        }
    }

    private func probe(_ text: String) throws -> Probe {
        Probe(storage: try #require(makeEditor(text).textView.textStorage))
    }

    // MARK: Emphasis across lines

    @Test func emphasisSpansLinesOfOneParagraph() throws {
        let p = try probe("**bold\ncontinued** plain\n\n*one\ntwo\nthree* x\n\n~~gone\nstill~~ kept\n")
        #expect(p.bold("bold"))
        #expect(p.bold("continued"))
        #expect(!p.bold("plain"))
        #expect(p.color("**bold") === HighlightPalette.marker)
        #expect(p.color("** plain") === HighlightPalette.marker)
        #expect(p.italic("one"))
        #expect(p.italic("two"))
        #expect(p.italic("three"))
        #expect(!p.italic(" x"))
        #expect(p.struck("gone"))
        #expect(p.struck("still"))
        #expect(!p.struck("kept"))
    }

    @Test func emphasisNestingAndRuleOfThree() throws {
        let p = try probe("*a **b** c*\n\n***both*** after\n\n**x*y*z**\n")
        #expect(p.italic("a "))
        #expect(p.bold("b**") && p.italic("b**"))
        #expect(!p.bold("c*"))
        #expect(p.bold("both") && p.italic("both"))
        #expect(!p.bold("after"))
        #expect(p.bold("y") && p.italic("y"))
        #expect(p.bold("x") && !p.italic("x"))
    }

    @Test func intrawordUnderscoreIsNotEmphasis() throws {
        let p = try probe("snake_case_name and _real_ and 2*3*4\n")
        #expect(!p.italic("case"))
        #expect(p.italic("real"))
        // `*` between alphanumerics may still open/close (CommonMark).
        #expect(p.italic("3"))
    }

    @Test func emphasisStaysInsideItsParagraph() throws {
        let blank = try probe("**a\n\nb**\n")
        #expect(!blank.bold("a"))
        #expect(!blank.bold("b"))

        let list = try probe("**a\n- b**\n")
        #expect(!list.bold("a"))
        #expect(!list.bold("b"))

        let heading = try probe("*a\n# b*\n")
        #expect(!heading.italic("a"))
        #expect(!heading.italic("b"))

        let quote = try probe("*a\n> b*\n")
        #expect(!quote.italic("a"))
        #expect(!quote.italic("b"))
    }

    // MARK: Code spans and links

    @Test func codeSpanAcrossLines() throws {
        let editor = makeEditor("a `code\nspan` b\n")
        let p = Probe(storage: try #require(editor.textView.textStorage))
        #expect(p.color("code") === HighlightPalette.inlineCode)
        #expect(p.color("span") === HighlightPalette.inlineCode)
        #expect(p.color("` b") === HighlightPalette.marker)
        #expect(p.color(" b") === NSColor.textColor)
        // The line break itself is not colored.
        #expect(p.color("\nspan") === NSColor.textColor)
        #expect(editor.context(at: p.location("span", offset: 2)) == .inlineCode)
        #expect(editor.context(at: p.location("code", offset: 2)) == .inlineCode)
        #expect(editor.context(at: p.location(" b", offset: 1)) == .markdown)
    }

    @Test func codeSpanTakesPrecedenceOverEmphasis() throws {
        let p = try probe("`a*b` *c*\n\n*x `y*` z*\n")
        #expect(p.color("a*b") === HighlightPalette.inlineCode)
        #expect(!p.italic("b`"))
        #expect(p.italic("c"))
        // The `*` inside the code span cannot close the outer emphasis.
        #expect(p.italic(" z"))
        #expect(p.color("y*") === HighlightPalette.inlineCode)
    }

    @Test func inlineMathDoesNotPairAcrossCodeSpans() throws {
        let p = try probe("$a `b$` c$ and $x$\n")
        #expect(p.color("a `") !== HighlightPalette.math)
        #expect(p.color("b$") === HighlightPalette.inlineCode)
        #expect(p.color("x$") === HighlightPalette.math)
    }

    @Test func inlineMathStaysOnOneLine() throws {
        let p = try probe("price $a\nb$ here\n")
        #expect(p.color("a\n") !== HighlightPalette.math)
        #expect(p.color("b$") !== HighlightPalette.math)
    }

    @Test func linkTextAcrossLines() throws {
        let p = try probe("see [link\ntext](https://example.com) now\n")
        #expect(p.color("link") === HighlightPalette.link)
        #expect(p.color("text") === HighlightPalette.link)
        #expect(p.color("https") === HighlightPalette.url)
        #expect(p.color(" now") === NSColor.textColor)
    }

    @Test func noLinksInsideLinks() throws {
        let p = try probe("[a [b](c) d](e)\n")
        #expect(p.color("b]") === HighlightPalette.link)
        #expect(p.color("c)") === HighlightPalette.url)
        // The outer brackets are plain text once the inner link closed.
        #expect(p.color("e)") === NSColor.textColor)
    }

    // MARK: Containers

    @Test func quoteParagraphWithPrefixes() throws {
        let p = try probe("> **bold\n> still** plain\n")
        #expect(p.bold("bold"))
        #expect(p.bold("still"))
        #expect(!p.bold("plain"))
        // The second `>` keeps its marker color and is not part of the emphasis.
        let secondMarker = p.location("> still")
        #expect(p.storage.attribute(.foregroundColor, at: secondMarker, effectiveRange: nil) as? NSColor === HighlightPalette.quoteMarker)
        let font = p.storage.attribute(.font, at: secondMarker, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test func listItemContinuation() throws {
        let lazy = try probe("- *item\nlazy* tail\n- next\n")
        #expect(lazy.italic("item"))
        #expect(lazy.italic("lazy"))
        #expect(!lazy.italic("tail"))

        let indented = try probe("1. **one\n   two**\n2. three\n")
        #expect(indented.bold("one"))
        #expect(indented.bold("two"))
        #expect(!indented.bold("three"))
    }

    @Test func headingsAndTableCellsStaySingleLine() throws {
        let heading = try probe("# A *b\nc* d\n")
        #expect(!heading.italic("b"))
        #expect(!heading.italic("c*"))

        let table = try probe("| *a | b* |\n| --- | --- |\n| `x | y` | **z** |\n")
        #expect(!table.italic("a"))
        #expect(table.color("x") !== HighlightPalette.inlineCode)
        #expect(table.bold("z"))
    }

    // MARK: Incremental

    @Test func editsRecolorTheWholeParagraph() throws {
        let editor = makeEditor("# H\n\nl1 **a\nl2\nl3\nl4\nl5\n\nafter\n")
        let storage = try #require(editor.textView.textStorage)
        let p = Probe(storage: storage)
        #expect(!p.bold("l3"))

        // Closing the emphasis on line 5 re-colors lines 2…6 above it.
        storage.replaceCharacters(in: NSRange(location: p.location("l5") + 2, length: 0), with: "**")
        let highlighter = try #require(editor.highlighter as? MarkdownHighlighter)
        #expect(highlighter.lastProcessedLines == 2..<7)
        #expect(p.bold("l3"))
        #expect(p.bold("a\n"))

        // Typing a character re-analyzes exactly this paragraph.
        storage.replaceCharacters(in: NSRange(location: p.location("l3"), length: 0), with: "x")
        #expect(highlighter.lastProcessedLines == 2..<7)
        #expect(p.bold("xl3"))

        // Splitting the paragraph with a blank line un-bolds both halves.
        storage.replaceCharacters(in: NSRange(location: p.location("l4"), length: 0), with: "\n")
        #expect(!p.bold("xl3"))
        #expect(!p.bold("l4"))
        let fresh = makeEditor(storage.string)
        #expect(attributeDump(storage) == attributeDump(try #require(fresh.textView.textStorage)))

        // Joining them again restores the emphasis.
        storage.replaceCharacters(in: NSRange(location: p.location("l4") - 1, length: 1), with: "")
        #expect(p.bold("xl3"))
        #expect(p.bold("l4"))
    }

    @Test func blockChangeBelowEndsParagraphAbove() throws {
        let editor = makeEditor("*a\nb\nc*\n")
        let storage = try #require(editor.textView.textStorage)
        let p = Probe(storage: storage)
        #expect(p.italic("a"))
        // Line 2 becomes a heading: the paragraph above is cut short.
        storage.replaceCharacters(in: NSRange(location: p.location("b"), length: 0), with: "# ")
        #expect(!p.italic("a"))
        let fresh = makeEditor(storage.string)
        #expect(attributeDump(storage) == attributeDump(try #require(fresh.textView.textStorage)))
    }

    @Test func longParagraphsAreCappedOnEdits() throws {
        let lines = (0..<300).map { "line \($0)" }
        let text = "**" + lines.joined(separator: "\n") + "**\n"
        let editor = makeEditor(text)
        let storage = try #require(editor.textView.textStorage)
        let p = Probe(storage: storage)
        // The full pass sees the whole 300-line paragraph.
        #expect(p.bold("line 150"))
        #expect(p.bold("line 299"))

        storage.replaceCharacters(in: NSRange(location: p.location("line 150"), length: 0), with: "x")
        let highlighter = try #require(editor.highlighter as? MarkdownHighlighter)
        #expect(highlighter.lastProcessedLines.count <= 2 * MarkdownHighlighter.paragraphWindow + 3)
        #expect(highlighter.lastProcessedLines.contains(150))
    }

    @Test(arguments: [7, 99, 4242] as [UInt64])
    func incrementalParagraphEditsMatchFullHighlight(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        let snippets = ["*", "**", "_", "__", "~~", "`", "``", "\n", "\n\n", "> ", "- ", "# ", "[", "](u)", "x", " ", "$", "<!--", "-->"]
        let editor = makeEditor("Some *text\nacross* lines with `code\nspans` and [a\nlink](b).\n\n> quoted **bold\n> more** end\n\n- item _one\n  two_ done\n- next\n")
        let storage = try #require(editor.textView.textStorage)
        for step in 0..<200 {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &rng)
            let deleteLength = Int.random(in: 0..<3, using: &rng) == 0 ? min(length - location, Int.random(in: 0...6, using: &rng)) : 0
            storage.replaceCharacters(in: NSRange(location: location, length: deleteLength), with: snippets.randomElement(using: &rng)!)
            let fresh = makeEditor(storage.string)
            let incremental = attributeDump(storage)
            let full = attributeDump(try #require(fresh.textView.textStorage))
            if incremental != full {
                let index = (0..<min(incremental.count, full.count)).first { incremental[$0] != full[$0] } ?? 0
                Issue.record("attributes differ after step \(step) at \(index) in \(storage.string.debugDescription)")
                return
            }
        }
    }

    /// The managed attributes of every character, as comparable strings.
    private func attributeDump(_ storage: NSTextStorage) -> [String] {
        var dump: [String] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            let font = (attributes[.font] as? NSFont).map { "\($0.fontName)" } ?? "-"
            let color = (attributes[.foregroundColor] as? NSColor).map { "\(ObjectIdentifier($0))" } ?? "-"
            let background = (attributes[.backgroundColor] as? NSColor).map { "\(ObjectIdentifier($0))" } ?? "-"
            let strike = attributes[.strikethroughStyle].map { "\($0)" } ?? "-"
            for _ in 0..<range.length { dump.append("\(font)|\(color)|\(background)|\(strike)") }
        }
        return dump
    }
}
