import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Everything one document window needs besides the file itself: the editor,
/// the preview, the view mode, status-bar figures and the export actions.
///
/// Menu commands reach the session of the key window through
/// `@FocusedValue(\.documentSession)`.
@MainActor
@Observable
final class DocumentSession {
    let editor: EditorController
    let preview: PreviewController

    var viewMode: ViewMode
    /// Outline sidebar visibility.
    var showsOutline = false

    // Status bar
    private(set) var caretLine = 1
    private(set) var caretColumn = 1
    private(set) var wordCount = 0
    private(set) var characterCount = 0
    private(set) var diagnosticMessage: String?

    var isShowingGoToLine = false

    var errorMessage = ""
    var isPresentingError = false

    @ObservationIgnored private(set) weak var document: MarkdownDocument?
    @ObservationIgnored private(set) var fileURL: URL?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?

    init(settings: EditorSettings = .shared) {
        editor = EditorController(settings: settings)
        preview = PreviewController()
        viewMode = settings.defaultViewMode

        editor.onTextChange = { [weak self] text in
            self?.editorTextDidChange(text)
        }
        editor.onSelectionChange = { [weak self] in
            self?.updateCaret()
        }
        editor.onScroll = { [weak self] in
            guard let self, settings.syncScrolling, viewMode == .split else { return }
            preview.editorDidScroll(toLine: editor.topVisibleLine, atBottom: editor.isScrolledToBottom)
        }
        preview.onDiagnostics = { [weak self] diagnostics, source in
            self?.editor.setDiagnostics(diagnostics, source: source)
        }
    }

    // MARK: Document binding

    /// Connects (or re-connects, after Revert) the session to its document.
    func attach(document: MarkdownDocument, undoManager: UndoManager?, fileURL: URL?) {
        let isNewDocument = self.document !== document
        self.document = document
        editor.undoManager = undoManager
        setFileURL(fileURL)
        if isNewDocument || editor.textView.string != document.text {
            editor.setText(document.text)
            renderNow()
            updateStatistics()
        }
    }

    func setFileURL(_ url: URL?) {
        fileURL = url
        editor.documentURL = url
        preview.documentURL = url
    }

    /// The document's text changed from outside the editor (e.g. Revert).
    func documentTextDidChange(_ text: String) {
        guard editor.textView.string != text else { return }
        editor.setText(text)
        renderNow()
        updateStatistics()
    }

    private func editorTextDidChange(_ text: String) {
        document?.text = text
        scheduleRender()
    }

    // MARK: Rendering

    /// Debounce: every edit restarts the timer; the preview renders once
    /// typing pauses.
    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.renderNow()
            self?.updateStatistics()
        }
    }

    func renderNow() {
        renderTask?.cancel()
        preview.update(markdown: editor.textView.string)
    }

    // MARK: Status bar

    private func updateCaret() {
        let position = editor.caretPosition
        caretLine = position.line
        caretColumn = position.column
        diagnosticMessage = editor.diagnostic(at: editor.selectedRange.location)?.message
    }

    private func updateStatistics() {
        let text = editor.textView.string
        statsTask?.cancel()
        statsTask = Task.detached(priority: .utility) { [weak self] in
            var words = 0
            var inWord = false
            for scalar in text.unicodeScalars {
                let isWordCharacter = CharacterSet.alphanumerics.contains(scalar)
                if isWordCharacter && !inWord { words += 1 }
                inWord = isWordCharacter
            }
            let characters = text.count
            await MainActor.run { [weak self] in
                self?.wordCount = words
                self?.characterCount = characters
            }
        }
        updateCaret()
    }

    // MARK: Exports

    private var baseName: String {
        (fileURL?.deletingPathExtension().lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
    }

    func exportPDF() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = baseName + ".pdf"
        panel.message = "Export the rendered document as PDF"
        guard await run(panel), let url = panel.url else { return }

        // Mermaid diagrams and typeset formulas only exist inside the
        // WKWebView preview; grab them as rasterized SVGs (each list in
        // document order) before rendering the PDF.
        let webView = preview.webView
        let mermaid = await webView.harvestMermaidDiagrams()
        let displayMath = await webView.harvestDisplayMath()
        let inlineMath = await webView.harvestInlineMath()

        do {
            try PdfExporter.export(
                markdown: editor.textView.string,
                mermaid: mermaid,
                displayMath: displayMath,
                inlineMath: inlineMath,
                to: url
            )
        } catch {
            present(error: "PDF export failed: \(error.localizedDescription)")
        }
    }

    /// Saves the HTML preview as a standalone file. The page is taken from
    /// the live preview, so mermaid diagrams and formulas are already inline
    /// SVG and the bundled scripts (served via `appassets://`, which only
    /// exists inside this app) can be dropped.
    func exportHTML() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = baseName + ".html"
        panel.message = "Export the HTML preview as an HTML file"
        guard await run(panel), let url = panel.url else { return }

        guard let html = await preview.webView.renderedStandaloneHTML() else {
            present(error: "HTML export failed: the preview has not rendered yet.")
            return
        }
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            present(error: "HTML export failed: \(error.localizedDescription)")
        }
    }

    /// Prints the rendered preview.
    func printPreview() {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        let operation = preview.webView.printOperation(with: printInfo)
        // WKWebView's print view needs a frame, or the pages come out blank.
        operation.view?.frame = preview.webView.bounds
        operation.jobTitle = baseName
        if let window = editor.textView.window ?? preview.webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Runs a save panel as a sheet on the document window.
    private func run(_ panel: NSSavePanel) async -> Bool {
        if let window = editor.textView.window ?? preview.webView.window {
            return await panel.beginSheetModal(for: window) == .OK
        }
        return panel.runModal() == .OK
    }

    func present(error message: String) {
        errorMessage = message
        isPresentingError = true
    }
}

extension FocusedValues {
    /// The session of the key document window, for menu commands.
    @Entry var documentSession: DocumentSession?
}
