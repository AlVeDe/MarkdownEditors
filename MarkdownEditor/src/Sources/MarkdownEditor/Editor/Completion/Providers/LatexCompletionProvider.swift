import AppKit

/// IntelliSense for LaTeX inside `$ … $` and `$$ … $$`.
///
/// Three situations, decided by a short backwards scan from the caret:
///
/// 1. `\alp|` — a control word is being typed: every catalog command plus
///    the `\begin{…}` environment snippets. The replacement range starts at
///    the backslash, so choosing `\alpha` replaces `\alp` as a whole.
/// 2. `\begin{ma|`, `\end{|`, `\mathbb{R|` — inside the brace argument of
///    one of those commands: environment names (with the body and matching
///    `\end` auto-inserted), the environments still open (nearest first), or
///    the letters A–Z with a Unicode preview of the font.
/// 3. ⌃Space with no backslash — the everyday commands and environments,
///    replacing the letters before the caret.
///
/// Outside math the provider returns nil so the Markdown provider answers.
@MainActor
final class LatexCompletionProvider: CompletionProvider {
    let triggerCharacters: Set<Character> = ["\\", "{"]

    private let catalog: LatexCatalog

    init(catalog: LatexCatalog = .shared) {
        self.catalog = catalog
    }

    func completions(for request: CompletionRequest) -> CompletionResult? {
        guard request.context.isMath else { return nil }
        let text = request.text
        let location = request.location
        guard location >= 0, location <= text.length else { return nil }

        if let argument = LatexSourceScanner.braceArgument(in: text, before: location),
           let result = argumentCompletions(command: argument.command, range: argument.range, request: request) {
            return result
        }
        if let prefix = LatexSourceScanner.commandPrefix(in: text, before: location) {
            return CompletionResult(replacementRange: prefix, items: commandItems + beginItems)
        }
        if request.isExplicit {
            let word = LatexSourceScanner.wordPrefix(in: text, before: location)
            return CompletionResult(replacementRange: word, items: commonItems + beginItems)
        }
        return nil
    }

    // MARK: Commands

    /// Detail text: glyph first so the eye finds the symbol, then the group.
    nonisolated private static func detail(glyph: String?, category: String) -> String {
        glyph.map { "\($0)  \(category)" } ?? category
    }

    nonisolated private static func item(for command: LatexCommand) -> CompletionItem {
        var documentation = command.description
        if let package = command.requires {
            documentation += "\n\nFrom the MathJax “\(package)” extension (bundled)."
        }
        return CompletionItem(
            label: command.displayLabel,
            detail: detail(glyph: command.glyph, category: command.category),
            documentation: documentation,
            kind: command.isSymbol ? .symbol : .command,
            insertText: command.insertText,
            filterText: command.name,
            sortPriority: command.priority ?? 0
        )
    }

    /// Built once: the catalog never changes while the app runs.
    private lazy var commandItems: [CompletionItem] = catalog.commands.map(Self.item)

    /// `\begin{name} … \end{name}` snippets, offered when `\begin` (or any
    /// prefix of it) is typed as a command.
    private lazy var beginItems: [CompletionItem] = catalog.environments.map { environment in
        CompletionItem(
            label: "\\begin{\(environment.name)}",
            detail: "Environment",
            documentation: environment.description,
            kind: .environment,
            insertText: environment.fullSnippet,
            filterText: "begin{\(environment.name)}"
        )
    }

    /// The commands worth offering on ⌃Space without any prefix.
    private lazy var commonItems: [CompletionItem] = catalog.commands
        .filter { ($0.priority ?? 0) > 0 }
        .map(Self.item)

    // MARK: Brace arguments

    private func argumentCompletions(command: String, range: NSRange, request: CompletionRequest) -> CompletionResult? {
        let braceFollows = LatexSourceScanner.closingBraceFollows(in: request.text, at: request.location)
        // With an auto-paired `}` already after the caret, insert without our
        // own closing brace.
        let close = braceFollows ? "" : "}"

        switch command {
        case "begin":
            let items = catalog.environments.map { environment in
                CompletionItem(
                    label: environment.name,
                    detail: "Environment",
                    documentation: environment.description,
                    kind: .environment,
                    insertText: environment.beginSnippet(closingBraceFollows: braceFollows),
                    filterText: environment.name
                )
            }
            return CompletionResult(replacementRange: range, items: items)

        case "end":
            let open = openEnvironments(before: range.location, in: request.text)
            // Nearest unclosed environment first, then the rest of the list.
            var items = open.reversed().enumerated().map { index, name in
                CompletionItem(
                    label: name,
                    detail: "Open environment",
                    documentation: "Closes the \\begin{\(name)} above.",
                    kind: .environment,
                    insertText: name + close,
                    filterText: name,
                    sortPriority: 100 - index
                )
            }
            let openNames = Set(open)
            items += catalog.environments.filter { !openNames.contains($0.name) }.map { environment in
                CompletionItem(
                    label: environment.name,
                    detail: "Environment",
                    documentation: environment.description,
                    kind: .environment,
                    insertText: environment.name + close,
                    filterText: environment.name
                )
            }
            return CompletionResult(replacementRange: range, items: items)

        default:
            guard let font = LatexLetterFont(rawValue: command) else { return nil }
            let items = LatexLetterFont.letters.map { letter in
                let glyph = font.glyph(for: letter)
                return CompletionItem(
                    label: String(letter),
                    detail: glyph ?? "",
                    documentation: "\\\(command){\(letter)}",
                    kind: .symbol,
                    insertText: String(letter) + close,
                    filterText: String(letter),
                    sortPriority: font.commonLetters.contains(letter) ? 10 : 0
                )
            }
            return CompletionResult(replacementRange: range, items: items)
        }
    }

    /// Environments opened and not yet closed in the formula before
    /// `location`, innermost last.
    ///
    /// Scoped to the formula around the caret, so an `\end` never offers an
    /// environment from another formula. When the formula cannot be located
    /// (the highlighter says math, the scan disagrees), falls back to the
    /// current paragraph — a formula never spans a blank line.
    private func openEnvironments(before location: Int, in text: NSString) -> [String] {
        let start: Int
        if let formula = MathFormulaLocator.formula(at: location, in: text) {
            start = formula.contentRange.location
        } else {
            start = Self.paragraphStart(before: location, in: text)
        }
        return LatexSourceScanner.unclosedEnvironments(in: text, range: NSRange(location: start, length: location - start))
    }

    private static func paragraphStart(before location: Int, in text: NSString) -> Int {
        var lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        while lineStart > 0 {
            let previous = text.lineRange(for: NSRange(location: lineStart - 1, length: 0))
            if text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            lineStart = previous.location
        }
        return lineStart
    }
}
