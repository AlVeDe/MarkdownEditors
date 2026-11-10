//! Wraps the fragment from the HTML renderer in a page: GitHub-like CSS with
//! Xcode-like token colors (honoring `prefers-color-scheme`), plus the
//! MathJax configuration.
//!
//! The live preview loads a static shell (`ui/preview.html`) once and gets
//! this CSS injected; every edit then pushes a new fragment into it. The
//! standalone export uses [`standalone_page`].

use super::syntax::{css_hex, TokenKind};

/// MathJax configuration, set before the engine is loaded.
///
/// - SVG output with `fontCache: 'local'`, so a harvested formula is
///   self-contained (PDF export rasterizes formulas out of the preview).
/// - `ignoreHtmlClass` / `processHtmlClass` confine the scan to the
///   `class="math"` elements the renderer emits.
/// - Inline math uses `\(…\)`: which `$` spans are formulas has already been
///   decided in Rust, so the PDF renderer agrees with the preview.
/// - `startup.typeset: false` — the preview script typesets exactly the
///   nodes that changed.
pub const MATHJAX_CONFIG: &str = r#"window.MathJax = {
    tex: {
        inlineMath: [['\\(', '\\)']],
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
};"#;

pub fn css() -> String {
    let tokens = |dark: bool| {
        TokenKind::COLORED
            .iter()
            .map(|k| {
                let c = if dark { k.dark_color() } else { k.light_color() }.unwrap();
                format!("--tok-{}:{};", k.name(), css_hex(c))
            })
            .collect::<Vec<_>>()
            .join(" ")
    };
    format!(
        r#":root {{ color-scheme: light dark; --fg:#1f2328; --bg:#ffffff; --muted:#59636e; --border:#d1d9e0; --code-bg:#f6f8fa; --link:#0969da; --mark-bg:#fff3a3; {light} }}
@media (prefers-color-scheme: dark) {{
    :root {{ --fg:#f0f6fc; --bg:#1e1e1e; --muted:#9198a1; --border:#3d444d; --code-bg:#15191e; --link:#4493f8; --mark-bg:#6b5a12; {dark} }}
}}
:root[data-theme="light"] {{ color-scheme: light; --fg:#1f2328; --bg:#ffffff; --muted:#59636e; --border:#d1d9e0; --code-bg:#f6f8fa; --link:#0969da; --mark-bg:#fff3a3; {light} }}
:root[data-theme="dark"] {{ color-scheme: dark; --fg:#f0f6fc; --bg:#1e1e1e; --muted:#9198a1; --border:#3d444d; --code-bg:#15191e; --link:#4493f8; --mark-bg:#6b5a12; {dark} }}
* {{ box-sizing: border-box; }}
body {{ margin:0; font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Ubuntu, "Helvetica Neue", sans-serif; color:var(--fg); background:var(--bg); }}
.markdown-body {{ max-width: 52rem; margin: 0 auto; padding: 28px 36px 48px; }}
h1, h2, h3, h4, h5, h6 {{ margin: 1.4em 0 .6em; line-height: 1.25; font-weight: 600; }}
h1 {{ font-size: 2em; }} h2 {{ font-size: 1.5em; }} h3 {{ font-size: 1.25em; }} h4 {{ font-size: 1em; }}
h1, h2 {{ border-bottom: 1px solid var(--border); padding-bottom: .3em; }}
p {{ margin: .7em 0; }}
a {{ color: var(--link); }}
code, pre {{ font-family: ui-monospace, "SF Mono", Menlo, Consolas, "Cascadia Mono", "DejaVu Sans Mono", monospace; }}
code {{ font-size: .85em; background: var(--code-bg); padding: .15em .4em; border-radius: 6px; }}
pre {{ background: var(--code-bg); border-radius: 8px; padding: 14px 16px; overflow-x: auto; margin: .8em 0; }}
pre code {{ background: transparent; padding: 0; display: block; }}
pre.mermaid {{ background: transparent; text-align: center; }}
pre.mermaid.mermaid-error {{ background: var(--code-bg); text-align: left; border-left: 3px solid #d1242f; }}
div.math {{ margin: 1.2em 0; text-align: center; overflow-x: auto; overflow-y: hidden; font-size: .9em; white-space: pre-wrap; }}
span.math {{ font-size: .95em; }}
.math {{ color: var(--fg); font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; }}
.math mjx-container {{ margin: 0 !important; }}
.math mjx-container svg {{ max-width: 100%; }}
blockquote {{ margin: .8em 0; padding: .1em 1em; color: var(--muted); border-left: 4px solid var(--border); }}
ul, ol {{ padding-left: 1.8em; margin: .7em 0; }}
li {{ margin: .25em 0; }}
li.task {{ list-style: none; margin-left: -1.5em; }}
li.task input {{ margin-right: .5em; }}
table {{ border-collapse: collapse; margin: .9em 0; }}
th, td {{ border: 1px solid var(--border); padding: 6px 14px; }}
th {{ background: var(--code-bg); }}
hr {{ border: 0; border-top: 2px solid var(--border); margin: 1.6em 0; }}
img {{ max-width: 100%; }}
.tok-keyword {{ color: var(--tok-keyword); font-weight: 600; }}
.tok-string {{ color: var(--tok-string); }}
.tok-comment {{ color: var(--tok-comment); }}
.tok-number {{ color: var(--tok-number); }}
.tok-preprocessor {{ color: var(--tok-preprocessor); }}
mark {{ background: var(--mark-bg); color: inherit; padding: 0 .15em; border-radius: 3px; }}
sub, sup {{ font-size: .75em; line-height: 0; }}
sup.footnote-ref a {{ text-decoration: none; padding: 0 .1em; }}
section.footnotes {{ font-size: .9em; color: var(--muted); }}
section.footnotes a.footnote-back {{ text-decoration: none; }}
@media print {{ .markdown-body {{ max-width: none; padding: 0; }} pre, table, img, div.math, pre.mermaid {{ break-inside: avoid; }} }}
"#,
        light = tokens(false),
        dark = tokens(true)
    )
}

/// A self-contained page around `body` (already rendered content, e.g. the
/// preview's DOM with diagrams and formulas inline as SVG). No scripts.
pub fn standalone_page(title: &str, body: &str) -> String {
    format!(
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\" />\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n<title>{}</title>\n<style>\n{}</style>\n</head>\n<body>\n<article class=\"markdown-body\">\n{}\n</article>\n</body>\n</html>\n",
        super::html::html_escape(title),
        css(),
        body
    )
}

/// The live preview's page, loaded once into the preview frame; fragments
/// are then pushed into `#content` by `preview.js` (`updateContent`).
/// Script paths are relative to the app's front end.
pub fn shell() -> String {
    format!(
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\" />\n<style>\n{}</style>\n</head>\n<body>\n<article class=\"markdown-body\" id=\"content\"></article>\n<script src=\"vendor/mermaid.min.js\"></script>\n<script>\n{}\n</script>\n<script src=\"vendor/tex-svg-full.js\"></script>\n<script src=\"preview.js\"></script>\n<script src=\"preview-host.js\"></script>\n</body>\n</html>\n",
        css(),
        MATHJAX_CONFIG
    )
}
