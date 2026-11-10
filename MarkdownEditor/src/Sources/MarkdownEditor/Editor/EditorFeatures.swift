import AppKit

/// Wires the Markdown-specific features into a fresh editor. The one place
/// that knows which handlers and completion providers exist.
@MainActor
enum EditorFeatures {
    static func install(on editor: EditorController) {
        editor.addInputHandler(MarkdownEditingAssistant(editor: editor))
        editor.addInputHandler(TableFormatter(editor: editor))
        editor.addInputHandler(ImagePasteHandler(editor: editor))
        editor.addInputHandler(MathPreviewController(editor: editor))
        editor.addInputHandler(CompletionController(
            editor: editor,
            providers: [
                LatexCompletionProvider(),
                MermaidCompletionProvider(),
                MarkdownCompletionProvider()
            ]
        ))
    }
}
