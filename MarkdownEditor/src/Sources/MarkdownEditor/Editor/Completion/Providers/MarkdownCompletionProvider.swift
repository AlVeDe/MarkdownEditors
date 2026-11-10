import AppKit

/// Completions for Markdown prose and fence info strings.
///
/// Asked after the LaTeX and Mermaid providers, so it only answers in
/// `.markdown` and `.fenceInfo` and returns nil everywhere else. Within
/// Markdown it looks at the current line up to the caret and decides, most
/// specific first:
///
/// 1. `](#part`        → heading anchors of this document
/// 2. `](path` `![](…` → files next to the document
/// 3. `[text][part`, `[part` → reference-link labels defined in the document
/// 4. `word` alone at the start of a line → block snippets
///
/// Only the current line is inspected for the position; the whole document
/// is scanned (once per text change) for headings and reference definitions.
@MainActor
final class MarkdownCompletionProvider: CompletionProvider {
    /// `#` matters after `](`, `(` and `/` for paths, `[` for references and
    /// `` ` `` for the third backtick of a fence.
    let triggerCharacters: Set<Character> = ["#", "(", "[", "/", "`"]

    private let fileManager: FileManager

    /// The last scanned text (an immutable copy) and its index. Completion
    /// re-queries on every keystroke; comparing against the copy is a memcmp,
    /// far cheaper than re-scanning a long document.
    private var cachedText: NSString?
    private var cachedIndex: MarkdownDocumentIndex?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func completions(for request: CompletionRequest) -> CompletionResult? {
        let text = request.text
        let location = min(max(request.location, 0), text.length)
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: location - lineStart)) as NSString

        switch request.context {
        case .fenceInfo:
            return fenceLanguages(prefix: prefix, lineStart: lineStart)
        case .markdown:
            if let result = headingAnchors(prefix: prefix, lineStart: lineStart, text: text) { return result }
            if let match = Self.firstMatch(Self.linkDestination, in: prefix) {
                // An inline link destination: paths, or nothing at all (a
                // URL being typed should not fall through to references).
                return filePaths(match: match, prefix: prefix, lineStart: lineStart, documentURL: request.documentURL)
            }
            if let result = referenceLabels(prefix: prefix, lineStart: lineStart, text: text) { return result }
            return blockSnippets(prefix: prefix, lineStart: lineStart, isExplicit: request.isExplicit)
        default:
            return nil
        }
    }

    // MARK: Patterns (all anchored at the caret, i.e. the end of the prefix)

    /// `](#partial` — group 1 is the partial anchor.
    private static let anchorTarget = regex(#"\]\(#([^\s)#]*)$"#)
    /// `[text](partial` or `![alt](partial` — group 1 is `!` for images,
    /// group 2 the partial path. Allows one level of nested brackets so
    /// `[![badge](x)](` still counts as a link.
    private static let linkDestination = regex(#"(!?)\[(?:[^\[\]]|\[[^\]]*\])*\]\(([^\s)#"<>]*)$"#)
    /// `[text][partial` — group 1 is the partial label.
    private static let fullReference = regex(#"\[[^\]]*\]\[([^\[\]]*)$"#)
    /// A lone `[partial` (shortcut reference). Not after `]` (that is the
    /// full form), `!` (image) or `\` (escaped), and not a footnote `[^`.
    private static let shortcutReference = regex(#"(?<![\]!\\])\[([^\[\]()^][^\[\]()]*|)$"#)
    /// `- [` / `1. [`: the start of a task checkbox, not a reference.
    private static let taskCheckbox = regex(#"^\s*(?:[-*+]|\d+[.)])\s+\[[^\]]*$"#)
    /// Leading whitespace and one word at the caret — group 1 is the word.
    private static let lineStartWord = regex(#"^[ \t]*([A-Za-z0-9]*)$"#)
    /// Opening fence on the current line — group 1 is the partial info string.
    private static let fenceOpening = regex(#"^[ \t]*(?:`{3,}|~{3,})[ \t]*([^\s`]*)$"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in string: NSString) -> NSTextCheckingResult? {
        regex.firstMatch(in: string as String, range: NSRange(location: 0, length: string.length))
    }

    // MARK: Fence languages

    private func fenceLanguages(prefix: NSString, lineStart: Int) -> CompletionResult? {
        guard let match = Self.firstMatch(Self.fenceOpening, in: prefix) else { return nil }
        let partial = match.range(at: 1)
        let items = MarkdownCompletionCatalog.languages.enumerated().map { offset, language in
            CompletionItem(
                label: language.name,
                detail: language.support,
                documentation: Self.languageDocumentation(language),
                kind: .language,
                insertText: language.name,
                // Supported languages first, then the catalog's order.
                sortPriority: (language.support.isEmpty ? 0 : 100) - offset
            )
        }
        return CompletionResult(replacementRange: NSRange(location: lineStart + partial.location, length: partial.length),
                                items: items)
    }

    private static func languageDocumentation(_ language: MarkdownCompletionCatalog.Language) -> String {
        switch language.support {
        case "highlighted": "Syntax-highlighted in the preview and exports."
        case "diagram": "Rendered as a Mermaid diagram in the preview."
        case "formula": "Rendered as a display formula (LaTeX syntax)."
        default: "Shown as plain code; the language is kept as a label."
        }
    }

    // MARK: Heading anchors

    private func headingAnchors(prefix: NSString, lineStart: Int, text: NSString) -> CompletionResult? {
        guard let match = Self.firstMatch(Self.anchorTarget, in: prefix) else { return nil }
        let partial = match.range(at: 1)
        let headings = index(for: text).headings
        guard !headings.isEmpty else { return nil }
        let items = headings.enumerated().map { offset, heading in
            CompletionItem(
                label: heading.title.isEmpty ? "#\(heading.anchor)" : heading.title,
                detail: "H\(heading.level)",
                documentation: "#\(heading.anchor)",
                kind: .heading,
                insertText: heading.anchor,
                filterText: heading.anchor,
                // Document order, which is how people think of headings.
                sortPriority: -offset
            )
        }
        return CompletionResult(replacementRange: NSRange(location: lineStart + partial.location, length: partial.length),
                                items: items)
    }

    // MARK: Reference labels

    private func referenceLabels(prefix: NSString, lineStart: Int, text: NSString) -> CompletionResult? {
        let match: NSTextCheckingResult
        if let full = Self.firstMatch(Self.fullReference, in: prefix) {
            match = full
        } else if let shortcut = Self.firstMatch(Self.shortcutReference, in: prefix),
                  Self.firstMatch(Self.taskCheckbox, in: prefix) == nil {
            match = shortcut
        } else {
            return nil
        }
        let references = index(for: text).references
        guard !references.isEmpty else { return nil }
        let partial = match.range(at: 1)
        let items = references.map { reference in
            CompletionItem(
                label: reference.label,
                detail: reference.destination,
                documentation: "[\(reference.label)]: \(reference.destination)",
                kind: .reference,
                insertText: reference.label
            )
        }
        return CompletionResult(replacementRange: NSRange(location: lineStart + partial.location, length: partial.length),
                                items: items)
    }

    // MARK: File paths

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp"]

    private func filePaths(match: NSTextCheckingResult, prefix: NSString, lineStart: Int, documentURL: URL?) -> CompletionResult? {
        guard let documentURL else { return nil }
        let isImage = match.range(at: 1).length > 0
        let pathRange = match.range(at: 2)
        let typed = prefix.substring(with: pathRange)
        // URLs and absolute paths are not ours to complete.
        if typed.contains(":") || typed.hasPrefix("/") { return nil }

        // Split `img/sub/fo` into the directory to list and the partial name
        // that the popup filters by (and the chosen item replaces).
        let directoryPart: String
        if let slash = typed.lastIndex(of: "/") {
            directoryPart = String(typed[...slash])
        } else {
            directoryPart = ""
        }
        let namePartLength = (typed as NSString).length - (directoryPart as NSString).length

        let baseDirectory = documentURL.deletingLastPathComponent()
        let decodedDirectory = directoryPart.removingPercentEncoding ?? directoryPart
        let directory = decodedDirectory.isEmpty
            ? baseDirectory
            : baseDirectory.appendingPathComponent(decodedDirectory, isDirectory: true)

        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let items: [CompletionItem] = entries.compactMap { url in
            let name = url.lastPathComponent
            // The document itself is rarely a useful link target.
            if url.standardizedFileURL == documentURL.standardizedFileURL { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isImageFile = Self.imageExtensions.contains(url.pathExtension.lowercased())
            let priority: Int = if isImage {
                isImageFile ? 20 : (isDirectory ? 10 : 0)
            } else {
                isDirectory ? 10 : 0
            }
            return CompletionItem(
                label: isDirectory ? name + "/" : name,
                detail: isDirectory ? "folder" : (isImageFile ? "image" : url.pathExtension.lowercased()),
                documentation: (decodedDirectory + name),
                kind: .file,
                insertText: Self.encodePathComponent(name) + (isDirectory ? "/" : ""),
                filterText: name,
                sortPriority: priority
            )
        }
        guard !items.isEmpty else { return nil }
        let replacement = NSRange(location: lineStart + pathRange.location + pathRange.length - namePartLength,
                                  length: namePartLength)
        return CompletionResult(replacementRange: replacement, items: items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending })
    }

    /// Spaces would end the link destination and parentheses would close it
    /// early, so those are percent-encoded; everything else stays readable.
    static func encodePathComponent(_ name: String) -> String {
        var result = ""
        for character in name {
            switch character {
            case " ": result += "%20"
            case "(": result += "%28"
            case ")": result += "%29"
            case "<": result += "%3C"
            case ">": result += "%3E"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Block snippets

    private func blockSnippets(prefix: NSString, lineStart: Int, isExplicit: Bool) -> CompletionResult? {
        guard let match = Self.firstMatch(Self.lineStartWord, in: prefix) else { return nil }
        let wordRange = match.range(at: 1)
        let word = prefix.substring(with: wordRange)
        let isFirstLine = lineStart == 0

        let available = MarkdownCompletionCatalog.snippets.filter { !$0.firstLineOnly || isFirstLine }
        let offered: [MarkdownCompletionCatalog.Snippet]
        if isExplicit {
            offered = word.isEmpty ? available : available.filter { $0.name.hasPrefix(word.lowercased()) }
        } else {
            // Unprompted, only pop up for a real prefix of a snippet name.
            // Case-sensitive on purpose: a sentence starting with "Table" or
            // "Code" is prose, not a request for a snippet.
            guard word.count >= 2 else { return nil }
            offered = available.filter { $0.name.hasPrefix(word) }
        }
        guard !offered.isEmpty else { return nil }

        let items = offered.map { snippet in
            CompletionItem(
                label: snippet.name,
                detail: snippet.detail,
                documentation: snippet.documentation,
                kind: .snippet,
                insertText: snippet.body
            )
        }
        return CompletionResult(replacementRange: NSRange(location: lineStart + wordRange.location, length: wordRange.length),
                                items: items)
    }

    // MARK: Document index cache

    private func index(for text: NSString) -> MarkdownDocumentIndex {
        if let cachedText, let cachedIndex, cachedText.length == text.length, cachedText.isEqual(text) {
            return cachedIndex
        }
        // Copy: the request's text is usually the live, mutable text storage.
        let snapshot = text.copy() as! NSString
        let index = MarkdownDocumentIndex(text: snapshot as String)
        cachedText = snapshot
        cachedIndex = index
        return index
    }
}
