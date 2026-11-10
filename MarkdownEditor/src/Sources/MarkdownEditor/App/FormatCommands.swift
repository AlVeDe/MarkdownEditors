import SwiftUI

/// The Format menu (inline styles, headings, blocks, inserts, indentation)
/// and a Lines submenu in the Edit menu.
///
/// Shortcuts avoid the system's: ⌘0 is Actual Size (so Paragraph is ⌃⌘0),
/// ⌥⌘T toolbar, ⌥⌘M / ⌘H / ⌃⌘Q / ⌘` window and app commands.
struct FormatCommands: Commands {
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandMenu("Format") {
            item(.bold, "b")
            item(.italic, "i")
            item(.strikethrough, "x", [.command, .shift])
            item(.highlight, "h", [.command, .shift])
            item(.inlineCode, "`", .control)
            // As in TextEdit's Baseline menu.
            item(.superscriptText, "=", [.command, .control])
            item(.subscriptText, "-", [.command, .control])

            Divider()

            ForEach(1...6, id: \.self) { level in
                item(.heading(level), KeyEquivalent(Character(String(level))))
            }
            item(.paragraph, "0", [.command, .control])

            Divider()

            item(.link, "k")
            item(.image, "i", [.command, .control])
            item(.footnote, "f", [.command, .control, .option])

            Divider()

            item(.quote, "'", [.command, .option])
            item(.bulletList, "8", [.command, .shift])
            item(.numberedList, "7", [.command, .shift])
            item(.taskList, "9", [.command, .shift])
            item(.toggleTask, "x", [.command, .control])
            Button("Renumber List") { session?.performOnEditor { $0.renumberOrderedListAtSelection() } }
                .disabled(session == nil)

            Divider()

            item(.codeBlock(language: nil), "k", [.command, .option])
            Menu("Code Block Language") {
                ForEach(FormattingToolbar.codeLanguages.filter { $0.language != nil }, id: \.title) { entry in
                    Button(entry.title) { session?.perform(.codeBlock(language: entry.language)) }
                        .disabled(session == nil)
                }
            }
            Button("Insert Table") { session?.perform(.table(rows: 2, columns: 3)) }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
                .disabled(session == nil)
            Menu("Insert Table of Size") {
                ForEach(FormattingToolbar.tableSizes, id: \.label) { size in
                    Button(size.label) { session?.perform(.table(rows: size.rows, columns: size.columns)) }
                        .disabled(session == nil)
                }
            }
            item(.horizontalRule)
            item(.inlineMath, "m", [.command, .control])
            item(.displayMath)
            item(.mermaid)

            Divider()

            item(.indent, "]")
            item(.outdent, "[")
        }

        CommandGroup(after: .textEditing) {
            Menu("Lines") {
                line("Move Line Up", .upArrow, [.command, .control]) { $0.moveLinesUp() }
                line("Move Line Down", .downArrow, [.command, .control]) { $0.moveLinesDown() }
                line("Duplicate Line", "d", [.command, .shift]) { $0.duplicateLines() }
                line("Delete Line", "k", [.control, .shift]) { $0.deleteLines() }
                line("Join Lines", "j", .control) { $0.joinLines() }
                Divider()
                line("Toggle Comment", "/", .command) { $0.toggleLineComment() }
                line("Select Line", nil, []) { $0.selectLines() }
            }
            .disabled(session == nil)
        }
    }

    private func item(
        _ action: FormatAction, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command
    ) -> some View {
        Button(action.title) { session?.perform(action) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(session == nil)
    }

    private func line(
        _ title: String, _ key: KeyEquivalent?, _ modifiers: EventModifiers,
        _ operation: @escaping @MainActor (EditorController) -> Void
    ) -> some View {
        Button(title) { session?.performOnEditor(operation) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(session == nil)
    }
}
