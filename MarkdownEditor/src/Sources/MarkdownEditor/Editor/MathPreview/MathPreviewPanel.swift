import AppKit
import WebKit

/// Outcome of rendering one formula in the preview panel.
struct MathRenderResult: Equatable {
    /// Size of the rendered content in points (formula or error message).
    var size: CGSize
    /// MathJax's message when the TeX is invalid (shown in red instead of
    /// the formula).
    var error: String?
}

/// A small floating window that shows one formula rendered by MathJax.
///
/// - It is a borderless, non-activating `NSPanel` that refuses key status,
///   so showing it never takes focus from the editor; it ignores the mouse,
///   so it never intercepts a click either.
/// - It is attached as a child window of the editor's window, so it moves
///   with it and is ordered with it.
/// - The formula renders in a `WKWebView` that loads the bundled MathJax
///   through the same `appassets://` scheme as the document preview — no
///   network. The page is loaded once; each formula is then rendered by
///   calling `renderFormula(tex, display)` with `callAsyncJavaScript`
///   arguments, so TeX is never spliced into JavaScript source.
@MainActor
final class MathPreviewPanel: NSObject, WKNavigationDelegate {
    private let panel: NSPanel
    private let webView: WKWebView
    private let background: NSVisualEffectView

    /// Padding between the panel edge and the formula.
    private let inset: CGFloat = 8
    /// The panel never grows beyond this; larger formulas scale down.
    static let maximumContentSize = CGSize(width: 640, height: 320)

    private var isPageLoaded = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.maximumContentSize), configuration: configuration)
        // Transparent page: the panel's material shows through.
        webView.setValue(false, forKey: "drawsBackground")

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.clipsToBounds = true
        panel.contentView = background
        background.addSubview(webView)

        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.page, baseURL: URL(string: "\(AssetSchemeHandler.scheme)://local/"))
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Rendering

    /// Renders `tex` into the (possibly hidden) web view. Nil if the page
    /// failed or the render threw (a newer render overtaking it, say).
    func render(tex: String, display: Bool, fontSize: CGFloat) async -> MathRenderResult? {
        await waitForPage()
        let maximum = Self.maximumContentSize
        do {
            let value = try await webView.callAsyncJavaScript(
                "return await renderFormula(tex, display, fontSize, maxWidth);",
                arguments: ["tex": tex, "display": display, "fontSize": fontSize, "maxWidth": maximum.width],
                in: nil,
                contentWorld: .page
            )
            guard let result = value as? [String: Any],
                  let width = result["width"] as? Double,
                  let height = result["height"] as? Double
            else { return nil }
            return MathRenderResult(
                size: CGSize(width: min(width, maximum.width), height: min(height, maximum.height)),
                error: result["error"] as? String
            )
        } catch {
            return nil
        }
    }

    private func waitForPage() async {
        guard !isPageLoaded else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: Showing

    /// Shows the panel with the last rendered content of `size`, its top-left
    /// corner at `anchor` (screen coordinates) — or above `avoiding` when
    /// there is no room below it on screen.
    func show(contentSize size: CGSize, below anchor: NSPoint, avoiding formulaRect: NSRect, parent: NSWindow, appearance: NSAppearance) {
        let frameSize = CGSize(width: ceil(size.width) + 2 * inset, height: ceil(size.height) + 2 * inset)
        var origin = NSPoint(x: anchor.x - inset, y: anchor.y - 4 - frameSize.height)
        if let screen = parent.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY { origin.y = formulaRect.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frameSize.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - frameSize.height)
        }

        panel.appearance = appearance
        webView.appearance = appearance
        // CGColor does not follow the appearance; resolve it for this one.
        var border = NSColor.separatorColor.cgColor
        appearance.performAsCurrentDrawingAppearance { border = NSColor.separatorColor.cgColor }
        background.layer?.borderColor = border
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: false)
        // The web view keeps its full size (re-sizing its viewport between
        // renders would re-flow the formula being measured); the panel only
        // shows its top-left corner, where the formula is.
        let maximum = Self.maximumContentSize
        webView.frame = NSRect(x: inset, y: frameSize.height - inset - maximum.height, width: maximum.width, height: maximum.height)

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: Page

    /// The panel's page. MathJax is configured like the document preview's
    /// (`HtmlPageRenderer`), except that:
    ///
    /// - it never typesets the page by itself — formulas arrive through
    ///   `renderFormula`;
    /// - `noerrors` / `noundefined` are switched off, so invalid TeX produces
    ///   an `merror` node carrying MathJax's message (`data-mjx-error`),
    ///   which the panel shows in red;
    /// - `texReset()` before each render forgets `\label`s, otherwise
    ///   re-rendering the same formula would report them as duplicates.
    private static let page = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8" />
    <style>
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
    body { color: #1d1d1f; font: 13px -apple-system, sans-serif; }
    #out { display: inline-block; white-space: nowrap; }
    #out.error { color: #d70015; white-space: pre-wrap; max-width: 480px; font-size: 12px; }
    mjx-container { margin: 0 !important; }
    mjx-container[display="true"] { display: inline-block !important; }
    mjx-container svg { max-width: 100%; height: auto; }
    @media (prefers-color-scheme: dark) {
        body { color: #f5f5f7; }
        #out.error { color: #ff6961; }
    }
    </style>
    <script>
    window.MathJax = {
        tex: {
            packages: { '[-]': ['noerrors', 'noundefined'] },
            processEscapes: false,
            processEnvironments: true,
            tags: 'none'
        },
        svg: { fontCache: 'local' },
        options: { enableMenu: false },
        startup: { typeset: false }
    };
    async function renderFormula(tex, display, fontSize, maxWidth) {
        await MathJax.startup.promise;
        document.body.style.fontSize = fontSize + 'px';
        const out = document.getElementById('out');
        out.style.maxWidth = maxWidth + 'px';
        MathJax.texReset();
        let error = null;
        let node = null;
        try {
            node = await MathJax.tex2svgPromise(tex, { display: display });
            const merror = node.querySelector('[data-mjx-error]');
            if (merror) { error = merror.getAttribute('data-mjx-error') || merror.textContent; }
        } catch (e) {
            error = String(e && e.message ? e.message : e);
        }
        out.replaceChildren();
        if (error) {
            out.className = 'error';
            out.textContent = error;
        } else {
            out.className = '';
            out.appendChild(node);
        }
        const rect = out.getBoundingClientRect();
        return { width: Math.ceil(rect.width), height: Math.ceil(rect.height), error: error };
    }
    </script>
    <script src="appassets://local/tex-svg-full.js"></script>
    </head>
    <body><div id="out"></div></body>
    </html>
    """
}
