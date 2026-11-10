import SwiftUI

/// Markdown formatting buttons on the leading side of the window toolbar.
///
/// One `ToolbarItem` per command with a stable id, so the user can rearrange
/// them in Customize Toolbar…; the less common ones (image, numbered list,
/// math, mermaid) start hidden to keep the default
/// toolbar short. Every button goes through `DocumentSession.perform`, which
/// reveals and focuses the editor.
struct FormattingToolbar: CustomizableToolbarContent {
    let session: DocumentSession

    static let codeLanguages: [(title: String, language: String?)] = [
        ("Plain", nil),
        ("C#", "csharp"),
        ("JavaScript", "javascript"),
        ("TypeScript", "typescript"),
        ("Python", "python")
    ]

    /// Columns × body rows offered for new tables.
    static let tableSizes: [TableSize] = [
        .init(columns: 2, rows: 2), .init(columns: 3, rows: 2), .init(columns: 3, rows: 3),
        .init(columns: 4, rows: 3), .init(columns: 4, rows: 4), .init(columns: 5, rows: 4)
    ]

    struct TableSize {
        var columns: Int
        var rows: Int
        var label: String { "\(columns) × \(rows)" }
    }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "format.heading", placement: .navigation) {
            Menu {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { session.perform(.heading(level)) }
                }
                Divider()
                Button("Paragraph") { session.perform(.paragraph) }
            } label: {
                Label("Heading", systemImage: "textformat.size")
            }
            .help("Heading level (⌘1 … ⌘6, Paragraph ⌃⌘0)")
        }

        button(.bold, id: "format.bold", help: "Bold (⌘B)")
        button(.italic, id: "format.italic", help: "Italic (⌘I)")
        button(.strikethrough, id: "format.strikethrough", help: "Strikethrough (⇧⌘X)")
        button(.highlight, id: "format.highlight", help: "Highlight — <mark> (⇧⌘H)")
        button(.inlineCode, id: "format.inlineCode", help: "Inline code (⌃`)")
        button(.subscriptText, id: "format.subscript", help: "Subscript — <sub> (⌃⌘-)")
        button(.superscriptText, id: "format.superscript", help: "Superscript — <sup> (⌃⌘=)")

        button(.link, id: "format.link", help: "Link (⌘K)")
        button(.image, id: "format.image", help: "Image (⌃⌘I)", showsByDefault: false)
        button(.footnote, id: "format.footnote", help: "Footnote — [^n] with its note at the end (⌃⌥⌘F)")

        button(.quote, id: "format.quote", help: "Quote (⌥⌘')")
        button(.bulletList, id: "format.bullets", help: "Bulleted list (⇧⌘8)")
        button(.numberedList, id: "format.numbers", help: "Numbered list (⇧⌘7)", showsByDefault: false)
        button(.taskList, id: "format.tasks", help: "Task list (⇧⌘9)")

        ToolbarItem(id: "format.codeBlock", placement: .navigation) {
            Menu {
                ForEach(Self.codeLanguages, id: \.title) { entry in
                    Button(entry.title) { session.perform(.codeBlock(language: entry.language)) }
                }
            } label: {
                Label("Code Block", systemImage: "curlybraces")
            } primaryAction: {
                session.perform(.codeBlock(language: nil))
            }
            .help("Code block (⌥⌘K); hold for a language")
        }

        ToolbarItem(id: "format.table", placement: .navigation) {
            Menu {
                ForEach(Self.tableSizes, id: \.label) { size in
                    Button(size.label) {
                        session.perform(.table(rows: size.rows, columns: size.columns))
                    }
                }
            } label: {
                Label("Table", systemImage: "tablecells")
            } primaryAction: {
                session.perform(.table(rows: 2, columns: 3))
            }
            .help("Insert a table, columns × rows (⌥⇧⌘T); hold for a size")
        }

        button(.horizontalRule, id: "format.rule", help: "Horizontal rule")

        ToolbarItem(id: "format.math", placement: .navigation, showsByDefault: false) {
            Menu {
                Button("Inline Math  $…$") { session.perform(.inlineMath) }
                Button("Display Math  $$…$$") { session.perform(.displayMath) }
            } label: {
                Label("Math", systemImage: "function")
            } primaryAction: {
                session.perform(.inlineMath)
            }
            .help("Math formula (⌃⌘M); hold for display math")
        }

        button(.mermaid, id: "format.mermaid", help: "Mermaid diagram", showsByDefault: false)
    }

    private func button(
        _ action: FormatAction, id: String, help: String, showsByDefault: Bool = true
    ) -> some CustomizableToolbarContent {
        ToolbarItem(id: id, placement: .navigation, showsByDefault: showsByDefault) {
            Button {
                session.perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .help(help)
        }
    }
}
