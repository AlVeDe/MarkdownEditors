import AppKit
import Testing
@testable import MarkdownEditor

/// Expands a snippet per the `CompletionItem.insertText` contract
/// (`${1:default}`, `${1}`, `$1`, `$0`, `\$`), or nil when it is malformed.
/// Returns the text with defaults filled in and the placeholder numbers.
private func expandSnippet(_ snippet: String) -> (text: String, placeholders: [Int])? {
    var text = ""
    var placeholders: [Int] = []
    var characters = Substring(snippet)
    while let character = characters.popFirst() {
        if character == "\\", characters.first == "$" {
            text.append(characters.removeFirst())
            continue
        }
        guard character == "$" else { text.append(character); continue }
        if characters.first == "{" {
            characters.removeFirst()
            let digits = characters.prefix(while: \.isNumber)
            guard let number = Int(digits) else { return nil }
            characters.removeFirst(digits.count)
            if characters.first == ":" {
                characters.removeFirst()
                guard let end = characters.firstIndex(of: "}") else { return nil }
                let defaultText = characters[..<end]
                guard !defaultText.contains("$"), !defaultText.contains("{") else { return nil }
                text += defaultText
                characters = characters[characters.index(after: end)...]
            } else {
                guard characters.popFirst() == "}" else { return nil }
                text += "x"
            }
            placeholders.append(number)
        } else {
            let digits = characters.prefix(while: \.isNumber)
            guard let number = Int(digits) else { return nil } // a bare `$` must be escaped
            characters.removeFirst(digits.count)
            placeholders.append(number)
        }
    }
    return (text, placeholders)
}

/// Braces balance, ignoring the escaped `\{` / `\}` delimiters.
private func bracesBalance(_ tex: String) -> Bool {
    var depth = 0
    var escaped = false
    for character in tex {
        if escaped { escaped = false; continue }
        switch character {
        case "\\": escaped = true
        case "{": depth += 1
        case "}": depth -= 1; if depth < 0 { return false }
        default: break
        }
    }
    return depth == 0
}

private func request(_ marked: String, context: EditorContext = .inlineMath, explicit: Bool = false) -> CompletionRequest {
    let caret = (marked as NSString).range(of: "|").location
    let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
    return CompletionRequest(text: text as NSString, location: caret, context: context, documentURL: nil, isExplicit: explicit)
}

@MainActor
struct LatexCatalogTests {
    @Test func catalogLoads() throws {
        let catalog = try LatexCatalog.load()
        #expect(catalog.commands.count >= 400)
        #expect(catalog.environments.count >= 15)
        #expect(LatexCatalog.shared.commands.count == catalog.commands.count)
        #expect(catalog.commands.contains { $0.name == "alpha" && $0.glyph == "α" })
        #expect(catalog.commands.contains { $0.name == "cancel" && $0.requires == "cancel" })
    }

    @Test func allCommandSnippetsParse() throws {
        for command in try LatexCatalog.load().commands {
            let expanded = try #require(expandSnippet(command.insertText), "\(command.name): \(command.insertText)")
            #expect(expanded.text.hasPrefix("\\") || expanded.text.hasPrefix("{\\"), "\(command.name)")
            #expect(bracesBalance(expanded.text), "\(command.name): \(command.insertText)")
            // Every `{…}` argument has a placeholder: no empty group survives.
            #expect(!expanded.text.contains("{}"), "\(command.name): \(command.insertText)")
            // Placeholders are numbered from 1 without gaps.
            let numbers = Set(expanded.placeholders.filter { $0 > 0 })
            #expect(numbers == Set(numbers.isEmpty ? [] : Array(1...numbers.count)), "\(command.name)")
            #expect(!command.name.hasPrefix("\\"), "\(command.name)")
        }
    }

    @Test func environmentSnippetsParse() throws {
        for environment in try LatexCatalog.load().environments {
            for snippet in [environment.fullSnippet, "\\begin{" + environment.beginSnippet()] {
                let expanded = try #require(expandSnippet(snippet), "\(environment.name)")
                #expect(bracesBalance(expanded.text), "\(environment.name)")
                #expect(expanded.text.hasPrefix("\\begin{\(environment.name)}"))
                #expect(expanded.text.hasSuffix("\\end{\(environment.name)}"))
                #expect(!expanded.placeholders.isEmpty)
            }
            // With an auto-paired `}` after the caret, that brace closes `\end{…`.
            let paired = "\\begin{" + environment.beginSnippet(closingBraceFollows: true) + "}"
            #expect(paired == environment.fullSnippet)
        }
    }

    @Test func letterGlyphs() {
        #expect(LatexLetterFont.mathbb.glyph(for: "R") == "ℝ")
        #expect(LatexLetterFont.mathbb.glyph(for: "N") == "ℕ")
        #expect(LatexLetterFont.mathbb.glyph(for: "A") == "𝔸")
        #expect(LatexLetterFont.mathcal.glyph(for: "L") == "ℒ")
        #expect(LatexLetterFont.mathcal.glyph(for: "A") == "𝒜")
        #expect(LatexLetterFont.mathfrak.glyph(for: "g") == nil)
        #expect(LatexLetterFont.mathfrak.glyph(for: "Z") == "ℨ")
    }
}

@MainActor
struct LatexCompletionProviderTests {
    let provider = LatexCompletionProvider()

    @Test func triggers() {
        #expect(provider.triggerCharacters == ["\\", "{"])
    }

    @Test func commandPrefixInInlineMath() throws {
        let result = try #require(provider.completions(for: request("x $\\alp|$")))
        #expect(result.replacementRange == NSRange(location: 3, length: 4))
        let alpha = try #require(result.items.first { $0.label == "\\alpha" })
        #expect(alpha.filterText == "alpha")
        #expect(alpha.insertText == "\\alpha")
        #expect(alpha.detail == "α  Greek")
        #expect(alpha.kind == .symbol)
        // `\begin` as a command offers the environment snippets.
        #expect(result.items.contains { $0.label == "\\begin{pmatrix}" && $0.insertText.contains("\\end{pmatrix}") })
    }

    @Test func loneBackslash() throws {
        let result = try #require(provider.completions(for: request("$\\|$")))
        #expect(result.replacementRange == NSRange(location: 1, length: 1))
    }

    @Test func escapedBackslashIsNotACommand() {
        #expect(provider.completions(for: request("$a \\\\b|$")) == nil)
    }

    @Test func displayMathFraction() throws {
        let result = try #require(provider.completions(for: request("$$\n\\frac|", context: .displayMath)))
        #expect(result.replacementRange == NSRange(location: 3, length: 5))
        let frac = try #require(result.items.first { $0.label == "\\frac" })
        #expect(frac.insertText == "\\frac{${1:num}}{${2:den}}")
        #expect(frac.kind == .command)
    }

    @Test func beginEnvironment() throws {
        let result = try #require(provider.completions(for: request("$$\n\\begin{ma|", context: .displayMath)))
        #expect(result.replacementRange == NSRange(location: 10, length: 2))
        let matrix = try #require(result.items.first { $0.label == "matrix" })
        #expect(matrix.filterText == "matrix")
        #expect(matrix.insertText == "matrix}\n\t${1}\n\\end{matrix}")
        let array = try #require(result.items.first { $0.label == "array" })
        #expect(array.insertText == "array}{${1:cc}}\n\t${2}\n\\end{array}")
    }

    @Test func beginEnvironmentBeforeAutoPairedBrace() throws {
        let result = try #require(provider.completions(for: request("$$\n\\begin{|}", context: .displayMath)))
        let cases = try #require(result.items.first { $0.label == "cases" })
        #expect(cases.insertText == "cases}\n\t${1}\n\\end{cases")
    }

    @Test func endOffersNearestOpenEnvironmentFirst() throws {
        let text = "$$\n\\begin{aligned}\nx &= \\begin{pmatrix} a \\\\ b \\end{pmatrix} \\\\\n\\begin{cases}\n a\n\\end{|"
        let result = try #require(provider.completions(for: request(text, context: .displayMath)))
        let best = try #require(result.items.max { $0.sortPriority < $1.sortPriority })
        #expect(best.label == "cases")
        #expect(best.insertText == "cases}")
        let open = result.items.filter { $0.detail == "Open environment" }.map(\.label)
        #expect(open == ["cases", "aligned"])
        #expect(!open.contains("pmatrix"))
        // Everything else is still offered below.
        #expect(result.items.contains { $0.label == "bmatrix" })
        #expect(result.replacementRange.length == 0)
    }

    @Test func endIgnoresEnvironmentsOfEarlierFormulas() throws {
        let text = "$$\n\\begin{cases} a \\\\ b\n$$\n\ntext\n\n$$\n\\begin{bmatrix} 1 \\end{|"
        let result = try #require(provider.completions(for: request(text, context: .displayMath)))
        let open = result.items.filter { $0.detail == "Open environment" }.map(\.label)
        #expect(open == ["bmatrix"])
    }

    @Test func mathbbLetters() throws {
        let result = try #require(provider.completions(for: request("$x \\in \\mathbb{|$")))
        #expect(result.replacementRange == NSRange(location: 15, length: 0))
        #expect(result.items.count == 26)
        let real = try #require(result.items.first { $0.label == "R" })
        #expect(real.detail == "ℝ")
        #expect(real.insertText == "R}")
        #expect(real.sortPriority > 0)

        let typed = try #require(provider.completions(for: request("$\\mathfrak{g|}$")))
        #expect(typed.replacementRange == NSRange(location: 11, length: 1))
        #expect(typed.items.first { $0.label == "G" }?.insertText == "G") // `}` already there
    }

    @Test func otherBraceArgumentsGiveNothing() {
        #expect(provider.completions(for: request("$\\frac{|$")) == nil)
    }

    @Test func nilOutsideMath() {
        #expect(provider.completions(for: request("text \\alp|", context: .markdown)) == nil)
        #expect(provider.completions(for: request("\\alp|", context: .codeBlock(language: "tex"))) == nil)
        #expect(provider.completions(for: request("\\begin{|", context: .markdown, explicit: true)) == nil)
    }

    @Test func explicitWithoutBackslash() throws {
        let result = try #require(provider.completions(for: request("$x + al|$", explicit: true)))
        #expect(result.replacementRange == NSRange(location: 5, length: 2))
        #expect(result.items.contains { $0.label == "\\alpha" })
        #expect(result.items.contains { $0.label == "\\frac" })
        #expect(result.items.contains { $0.kind == .environment })
        #expect(result.items.count < 150)
        // Not explicit: nothing to complete without a trigger.
        #expect(provider.completions(for: request("$x + al|$")) == nil)
    }
}
