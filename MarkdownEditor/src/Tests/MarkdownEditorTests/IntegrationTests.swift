import AppKit
import Testing
@testable import MarkdownEditor

/// Checks that the separately built pieces agree with each other: the
/// providers' snippet text with the snippet engine, and the highlighter's
/// contexts with the providers.
@MainActor
struct IntegrationTests {
    private func makeEditor(_ text: String) -> EditorController {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-integration")!))
        editor.setText(text)
        return editor
    }

    /// Every LaTeX snippet survives the snippet parser with its LaTeX intact:
    /// apart from the placeholder syntax (`${1:x}` → `x`, `$1` → nothing) and
    /// the two snippet escapes (`\\` → `\`, `\$` → `$`), the inserted text
    /// is exactly what the catalog wrote — every LaTeX backslash survives.
    @Test func latexSnippetsParseCleanly() throws {
        let catalog = LatexCatalog.shared
        #expect(!catalog.commands.isEmpty)
        let placeholderWithDefault = try Regex(#"\$\{\d+:([^}]*)\}"#)
        let emptyPlaceholder = try Regex(#"\$\{\d+\}|\$\d"#)
        for command in catalog.commands {
            let expected = command.insertText
                .replacing(placeholderWithDefault) { String($0.output[1].substring ?? "") }
                .replacing(emptyPlaceholder, with: "")
            #expect(Snippet(parsing: command.insertText).text == unescape(expected), "\(command.name)")
        }
        for environment in catalog.environments {
            let text = Snippet(parsing: environment.fullSnippet).text
            #expect(text.hasPrefix("\\begin{\(environment.name)}"))
            #expect(text.contains("\\end{\(environment.name)}"))
        }
    }

    /// The snippet escapes, read left to right like the parser does.
    private func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else { result.append(character); continue }
            switch iterator.next() {
            case "\\": result.append("\\")
            case "$": result.append("$")
            case let other?: result.append("\\"); result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }

    /// The highlighter's context drives which provider answers.
    @Test func contextsRouteToTheRightProvider() {
        let text = "# Doc\n\nSee $\\alp$ here.\n\n```mermaid\nflowchart TD\n    A --> B\n```\n"
        let editor = makeEditor(text)
        let string = text as NSString

        let math = string.range(of: "\\alp").location + 4
        #expect(editor.context(at: math) == .inlineMath)
        let latex = LatexCompletionProvider().completions(for: CompletionRequest(
            text: string, location: math, context: editor.context(at: math), documentURL: nil, isExplicit: false
        ))
        #expect(latex?.items.contains { $0.label == "\\alpha" } == true)

        let mermaidLocation = string.range(of: "A --> B").location
        #expect(editor.context(at: mermaidLocation) == .mermaid)

        // Markdown completions stay out of math.
        #expect(MarkdownCompletionProvider().completions(for: CompletionRequest(
            text: string, location: math, context: editor.context(at: math), documentURL: nil, isExplicit: true
        )) == nil)
    }

    /// A price is not a formula: typing after `$5` must not pop up LaTeX.
    @Test func pricesDoNotTriggerLatex() {
        let text = "Costs $5"
        let editor = makeEditor(text)
        let location = (text as NSString).length
        let result = LatexCompletionProvider().completions(for: CompletionRequest(
            text: text as NSString, location: location, context: editor.context(at: location),
            documentURL: nil, isExplicit: false
        ))
        #expect(result == nil)
    }
}

@MainActor
struct FrontMatterTests {
    @Test func frontMatterIsNotRenderedButKeepsLines() {
        let markdown = "---\ntitle: X\n---\n\n# Heading\n"
        let blanked = MathBlocks.blankingFrontMatter(markdown)
        #expect(blanked == "\n\n\n\n# Heading\n")
        let html = HtmlRenderer.render(MathBlocks.parse(markdown))
        #expect(!html.contains("title"))
        #expect(!html.contains("<hr"))
        #expect(html.contains("Heading"))
    }

    @Test func ruleWithoutClosingIsKept() {
        let markdown = "---\njust a rule above\n"
        #expect(MathBlocks.blankingFrontMatter(markdown) == markdown)
    }
}
