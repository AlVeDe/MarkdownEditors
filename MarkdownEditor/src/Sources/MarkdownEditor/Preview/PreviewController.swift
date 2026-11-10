import AppKit
import WebKit

/// Owns one document window's HTML preview (`WKWebView`).
///
/// Like `EditorController`, it lives as long as the window, so switching
/// view modes re-parents the same web view instead of reloading it.
///
/// A custom `appassets://` URL scheme serves the bundled mermaid.min.js and
/// MathJax straight from `Bundle.resources`, so no multi-megabyte script is
/// inlined into the page and no internet access is required; `docfile://`
/// serves images from the document's folder.
///
/// The page is loaded **once** (`HtmlPageRenderer.shell()`); every edit then
/// pushes the new fragment into it (`updateContent`, see `PreviewScript`),
/// which swaps only the blocks that changed. That keeps the scroll position,
/// avoids the white flash of a reload, and spares re-typesetting every
/// formula and diagram on every keystroke.
@MainActor
final class PreviewController: NSObject {
    let webView: WKWebView

    /// The saved document's file; relative image paths resolve against it.
    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            fileHandler.rootDirectory = documentURL?.deletingLastPathComponent()
            // Image sources depend on whether there is a folder to serve.
            if let lastMarkdown {
                lastRendered = nil
                update(markdown: lastMarkdown)
            }
        }
    }

    /// Diagnostics found while rendering (mermaid / MathJax errors), mapped to
    /// the editor text. Set by the session to forward them to the editor.
    var onDiagnostics: (([EditorDiagnostic], _ source: String) -> Void)?

    /// One rendered state of the document, ready to push into the page.
    private struct Rendered: Equatable {
        var fragment: String
        var markdown: String
        var lineCount: Int
    }

    private let fileHandler = DocumentFileSchemeHandler()
    /// The markdown of the latest `update` — what diagnostics are mapped
    /// against and what a reloaded shell is refilled with.
    private(set) var lastMarkdown: String?
    /// The latest rendering, pushed or about to be.
    private var lastRendered: Rendered?
    /// Rendered but not yet sent: only the newest survives (coalescing).
    private var pendingUpdate: Rendered?
    private var isUpdating = false
    /// The page's errors from the last applied update.
    private var lastReport: PreviewDiagnostics.Report?
    /// The shell has finished loading; until then updates queue up.
    private(set) var isShellLoaded = false

    private var pendingScroll: (line: Double, edge: String)?
    private var isScrolling = false

    /// Called after each update has been applied in the page (tests).
    var onUpdateApplied: (() -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        configuration.setURLSchemeHandler(fileHandler, forURLScheme: DocumentFileSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        loadShell()
    }

    private func loadShell() {
        isShellLoaded = false
        webView.loadHTMLString(HtmlPageRenderer.shell(), baseURL: URL(string: "\(AssetSchemeHandler.scheme)://local/"))
    }

    // MARK: Content

    /// Renders `markdown` into the preview.
    func update(markdown: String) {
        lastMarkdown = markdown
        let parsed = MathBlocks.parseMapped(markdown)
        let fragment = HtmlRenderer.render(
            parsed.document,
            lineMap: parsed.lineMap,
            imageBase: fileHandler.rootDirectory == nil ? nil : DocumentFileSchemeHandler.base
        )
        let rendered = Rendered(fragment: fragment, markdown: markdown, lineCount: LineIndex(markdown).lineCount)
        if rendered.fragment == lastRendered?.fragment {
            // Same blocks (e.g. trailing whitespace typed): nothing to redraw,
            // but the diagnostics' ranges are tied to the text itself.
            lastRendered = rendered
            if !isUpdating, pendingUpdate == nil, let lastReport { report(lastReport, for: markdown) }
            return
        }
        lastRendered = rendered
        pendingUpdate = rendered
        pushPendingUpdate()
    }

    /// Sends the newest pending fragment once the shell is ready and the
    /// previous update has finished — intermediate states are skipped.
    private func pushPendingUpdate() {
        guard isShellLoaded, !isUpdating, let update = pendingUpdate else { return }
        pendingUpdate = nil
        isUpdating = true
        Task { [weak self] in
            guard let self else { return }
            let result = try? await webView.callAsyncJavaScript(
                "return await updateContent(html, lineCount)",
                arguments: ["html": update.fragment, "lineCount": update.lineCount],
                in: nil,
                contentWorld: .page
            )
            isUpdating = false
            // Report only for the text the editor still shows; a newer
            // update will report for its own.
            if pendingUpdate == nil, update.markdown == lastMarkdown {
                report(result, for: update.markdown)
            }
            onUpdateApplied?()
            pushPendingUpdate()
        }
    }

    private func report(_ result: Any?, for markdown: String) {
        report(PreviewDiagnostics.decode(result), for: markdown)
    }

    private func report(_ errors: PreviewDiagnostics.Report, for markdown: String) {
        lastReport = errors
        onDiagnostics?(PreviewDiagnostics.diagnostics(for: errors.diagrams, in: markdown), "mermaid")
        onDiagnostics?(PreviewDiagnostics.diagnostics(for: errors.formulas, in: markdown), "mathjax")
    }

    // MARK: Scroll sync

    /// The editor scrolled; `line` is the 1-based source line at its top edge
    /// (fractional). Used for synchronized scrolling. At the very top or
    /// bottom of the editor the preview is pinned to its own top / bottom —
    /// interpolation alone would leave it a few pixels short.
    func editorDidScroll(toLine line: Double, atBottom: Bool = false) {
        let edge = line <= 1 ? "top" : atBottom ? "bottom" : ""
        pendingScroll = (line, edge)
        pushPendingScroll()
    }

    /// One scroll request in flight at a time; while it runs, newer requests
    /// overwrite each other. The page throttles to animation frames itself.
    private func pushPendingScroll() {
        guard isShellLoaded, !isScrolling, let scroll = pendingScroll else { return }
        pendingScroll = nil
        isScrolling = true
        Task { [weak self] in
            guard let self else { return }
            _ = try? await webView.callAsyncJavaScript(
                "scrollToSourceLine(line, edge, false)",
                arguments: ["line": scroll.line, "edge": scroll.edge],
                in: nil,
                contentWorld: .page
            )
            isScrolling = false
            pushPendingScroll()
        }
    }

    // MARK: Shell lifecycle

    private func shellDidLoad() {
        isShellLoaded = true
        // A fresh page is empty: (re)send the latest rendering.
        if pendingUpdate == nil, let lastRendered { pendingUpdate = lastRendered }
        pushPendingUpdate()
        pushPendingScroll()
    }
}

extension PreviewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellDidLoad()
    }

    /// The page's process died (memory pressure, crash): reload the shell;
    /// `shellDidLoad` refills it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isUpdating = false
        isScrolling = false
        loadShell()
    }

    /// The shell must stay loaded: a clicked link opens in the default
    /// browser instead of replacing the preview, except for in-page anchors.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == AssetSchemeHandler.scheme, url.fragment != nil {
            decisionHandler(.allow)
            return
        }
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
