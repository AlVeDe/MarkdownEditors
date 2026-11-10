import Foundation

/// Wraps the fragment from `HtmlRenderer` in a small HTML page: GitHub-like
/// CSS with Xcode-like token colors (honoring `prefers-color-scheme`), plus
/// mermaid.js and MathJax loaded via the custom `appassets://` scheme.
///
/// The live preview loads this page **once**, empty (`shell()`), and from
/// then on pushes each new fragment into it through `updateContent(html,
/// lineCount)` (see `PreviewScript`). Reloading the page per keystroke would
/// re-run mermaid and MathJax over the whole document and flash white.
enum HtmlPageRenderer {
    /// The empty preview page the live fragments are pushed into.
    static func shell() -> String {
        page(fragment: "")
    }

    /// A complete page around `fragment`; diagrams and formulas in it are
    /// rendered as soon as the libraries have loaded.
    static func page(fragment: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8" />
        <style>
        \(css)
        </style>
        </head>
        <body>
        <article class="markdown-body" id="content">
        \(fragment)
        </article>
        <script src="appassets://local/mermaid.min.js"></script>
        \(mathJaxScripts)
        <script>
        \(PreviewScript.source)
        </script>
        </body>
        </html>
        """
    }

    /// MathJax (TeX → SVG), configured before the bundled engine is loaded.
    ///
    /// - SVG output rather than MathJax's HTML/CSS output, because the PDF
    ///   export rasterizes the rendered formulas straight out of the preview —
    ///   exactly the route the mermaid diagrams already take.
    /// - `fontCache: 'local'` keeps every formula's glyph definitions inside
    ///   its own `<svg>`. With MathJax's default shared cache the glyphs live
    ///   in one page-global `<svg>` and a harvested formula would rasterize
    ///   empty.
    /// - `ignoreHtmlClass` / `processHtmlClass` confine the delimiter scan to
    ///   the `class="math"` elements emitted by `HtmlRenderer` — a `<div>` for
    ///   display math, a `<span>` for inline math — so a stray `$$` in prose is
    ///   never mistaken for a formula.
    /// - Inline math uses `\(…\)` rather than `$…$`: which `$` spans are
    ///   formulas has already been decided in Swift by `InlineMath`, so the
    ///   PDF renderer, which cannot run MathJax, agrees with the preview.
    /// - `tags: 'none'` — no automatic equation numbers; an explicit
    ///   `\tag{…}` in the formula still renders.
    /// - `startup.typeset: false` — the preview script typesets exactly the
    ///   nodes that changed, so MathJax must not also sweep the page on load.
    private static var mathJaxScripts: String {
        """
        <script>
        window.MathJax = {
            tex: {
                inlineMath: [['\\\\(', '\\\\)']],
                displayMath: [['$$', '$$']],
                processEscapes: false,
                processEnvironments: true,
                tags: 'none'
            },
            svg: { fontCache: 'local', displayAlign: 'center' },
            startup: { typeset: false },
            options: {
                enableMenu: false,
                ignoreHtmlClass: 'markdown-body',
                processHtmlClass: 'math'
            }
        };
        </script>
        <script src="appassets://local/tex-svg-full.js"></script>
        """
    }

    private static var css: String {
        let tokens: [(TokenKind, String)] = [
            (.keyword, "keyword"),
            (.string, "string"),
            (.comment, "comment"),
            (.number, "number"),
            (.preprocessor, "preprocessor")
        ]
        let lightTokens = tokens
            .map { "--tok-\($0.1):\($0.0.lightColor!.cssHex);" }
            .joined(separator: " ")
        let darkTokens = tokens
            .map { "--tok-\($0.1):\($0.0.darkColor!.cssHex);" }
            .joined(separator: " ")

        return """
        :root { color-scheme: light dark; --fg:#1f2328; --bg:#ffffff; --muted:#59636e; --border:#d1d9e0; --code-bg:#f6f8fa; --link:#0969da; --mark-bg:#fff3a3; \(lightTokens) }
        @media (prefers-color-scheme: dark) {
            :root { --fg:#f0f6fc; --bg:#1e1e1e; --muted:#9198a1; --border:#3d444d; --code-bg:#15191e; --link:#4493f8; --mark-bg:#6b5a12; \(darkTokens) }
        }
        * { box-sizing: border-box; }
        body { margin:0; font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; color:var(--fg); background:var(--bg); }
        .markdown-body { max-width: 52rem; margin: 0 auto; padding: 28px 36px 48px; }
        h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 .6em; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4 { font-size: 1em; }
        h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
        p { margin: .7em 0; }
        a { color: var(--link); }
        code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        code { font-size: .85em; background: var(--code-bg); padding: .15em .4em; border-radius: 6px; }
        pre { background: var(--code-bg); border-radius: 8px; padding: 14px 16px; overflow-x: auto; margin: .8em 0; }
        pre code { background: transparent; padding: 0; display: block; }
        pre.mermaid { background: transparent; text-align: center; }
        /* A diagram mermaid could not parse stays visible as its source. */
        pre.mermaid.mermaid-error { background: var(--code-bg); text-align: left; border-left: 3px solid #d1242f; }
        /* MathJax draws its SVG glyphs with `currentColor`, so the formula
           follows the page's light/dark foreground automatically. */
        /* The monospace font only ever shows on a formula MathJax refused to
           typeset — its SVG output draws glyph outlines, not styled text — so
           a broken formula reads as source rather than as prose. */
        div.math { margin: 1.2em 0; text-align: center; overflow-x: auto; overflow-y: hidden; font-size: .9em; white-space: pre-wrap; }
        span.math { font-size: .95em; }
        .math { color: var(--fg); font-family: ui-monospace, "SF Mono", Menlo, monospace; }
        .math mjx-container { margin: 0 !important; }
        .math mjx-container svg { max-width: 100%; }
        blockquote { margin: .8em 0; padding: .1em 1em; color: var(--muted); border-left: 4px solid var(--border); }
        ul, ol { padding-left: 1.8em; margin: .7em 0; }
        li { margin: .25em 0; }
        li.task { list-style: none; margin-left: -1.5em; }
        li.task input { margin-right: .5em; }
        table { border-collapse: collapse; margin: .9em 0; }
        th, td { border: 1px solid var(--border); padding: 6px 14px; }
        th { background: var(--code-bg); }
        hr { border: 0; border-top: 2px solid var(--border); margin: 1.6em 0; }
        img { max-width: 100%; }
        .tok-keyword { color: var(--tok-keyword); font-weight: 600; }
        .tok-string { color: var(--tok-string); }
        .tok-comment { color: var(--tok-comment); }
        .tok-number { color: var(--tok-number); }
        .tok-preprocessor { color: var(--tok-preprocessor); }
        mark { background: var(--mark-bg); color: inherit; padding: 0 .15em; border-radius: 3px; }
        sub, sup { font-size: .75em; line-height: 0; }
        sup.footnote-ref a { text-decoration: none; padding: 0 .1em; }
        section.footnotes { font-size: .9em; color: var(--muted); }
        section.footnotes a.footnote-back { text-decoration: none; }
        """
    }
}
