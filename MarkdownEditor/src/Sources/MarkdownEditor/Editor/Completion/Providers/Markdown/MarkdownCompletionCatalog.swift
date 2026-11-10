import Foundation

/// Static completion data for Markdown: block snippets and fence languages.
/// Kept apart from the provider so the lists are easy to scan and extend.
enum MarkdownCompletionCatalog {
    struct Snippet: Sendable {
        var name: String
        var detail: String
        var documentation: String
        var body: String
        /// Only offered on the first line of the document.
        var firstLineOnly = false
    }

    /// Block snippets, offered when a word is typed at the start of a line.
    /// Bodies use the `${n:default}` / `$0` placeholder syntax; a literal `$`
    /// is `\$`.
    static let snippets: [Snippet] = {
        var list: [Snippet] = [
            Snippet(name: "table", detail: "GFM table",
                    documentation: "A table with three columns and two rows. Tab moves between cells.",
                    body: """
                    | ${1:Column 1} | ${2:Column 2} | ${3:Column 3} |
                    | --- | --- | --- |
                    | ${4} | ${5} | ${6} |
                    | ${7} | ${8} | ${9} |
                    $0
                    """),
            Snippet(name: "code", detail: "fenced code block",
                    documentation: "A fenced code block. Type the language first (csharp, javascript, typescript and python are highlighted).",
                    body: "```${1:language}\n$0\n```"),
            Snippet(name: "mermaid", detail: "diagram",
                    documentation: "A Mermaid diagram, rendered in the preview. Starts with a top-down flowchart.",
                    body: "```mermaid\nflowchart TD\n    ${1:A}[${2:Start}] --> ${3:B}[${4:End}]\n```\n$0"),
            Snippet(name: "math", detail: "display formula",
                    documentation: "A display math block rendered with LaTeX syntax.",
                    body: "\\$\\$\n${1:E = mc^2}\n\\$\\$\n$0"),
            Snippet(name: "task", detail: "task list item",
                    documentation: "An unchecked task list item. Type x between the brackets to check it.",
                    body: "- [ ] ${1:task}$0"),
            Snippet(name: "link", detail: "inline link",
                    documentation: "An inline link: link text in brackets, then the URL or file path in parentheses.",
                    body: "[${1:text}](${2:url})$0"),
            Snippet(name: "image", detail: "image",
                    documentation: "An image: alt text (for accessibility) in brackets, then the image path or URL in parentheses.",
                    body: "![${1:alt}](${2:path})$0"),
            Snippet(name: "quote", detail: "block quote",
                    documentation: "A block quote. Continue the quote by starting the next line with >.",
                    body: "> ${1:quote}$0"),
            Snippet(name: "hr", detail: "horizontal rule",
                    documentation: "A thematic break (horizontal line). Leave a blank line above it, or the line above becomes a heading.",
                    body: "---\n$0"),
            Snippet(name: "details", detail: "collapsible section",
                    documentation: "An HTML <details> element: the summary is always visible, the content is shown when expanded.",
                    body: "<details>\n<summary>${1:Summary}</summary>\n\n${2:Content}\n\n</details>\n$0"),
            Snippet(name: "footnote", detail: "footnote definition",
                    documentation: "A footnote definition. Reference it in the text with [^label].",
                    body: "[^${1:1}]: ${2:Footnote text}$0"),
            Snippet(name: "frontmatter", detail: "YAML front matter",
                    documentation: "YAML metadata at the top of the document, between --- lines.",
                    body: "---\ntitle: ${1}\n---\n$0", firstLineOnly: true),
        ]
        for level in 1...6 {
            list.append(Snippet(name: "h\(level)", detail: "heading \(level)",
                                documentation: "A level-\(level) heading (\(String(repeating: "#", count: level)) Title).",
                                body: "\(String(repeating: "#", count: level)) ${1:Heading}$0"))
        }
        return list
    }()

    struct Language: Sendable {
        var name: String
        /// What the app does with this language, shown as detail; empty for
        /// languages that are only labelled.
        var support: String
    }

    /// Languages offered after an opening fence. The ones the app renders
    /// specially come first and say so.
    static let languages: [Language] = [
        Language(name: "csharp", support: "highlighted"),
        Language(name: "javascript", support: "highlighted"),
        Language(name: "typescript", support: "highlighted"),
        Language(name: "python", support: "highlighted"),
        Language(name: "mermaid", support: "diagram"),
        Language(name: "math", support: "formula"),
    ] + [
        "json", "swift", "bash", "sh", "zsh", "html", "css", "scss", "yaml", "toml", "xml", "sql",
        "c", "cpp", "objc", "java", "kotlin", "go", "rust", "ruby", "php", "powershell",
        "dockerfile", "makefile", "diff", "markdown", "graphql", "ini", "plaintext", "text",
    ].map { Language(name: $0, support: "") }
}
