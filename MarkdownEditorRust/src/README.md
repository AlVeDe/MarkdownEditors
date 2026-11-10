# MarkdownEditor (Rust · Windows / Linux / macOS)

A Rust port of the macOS app in `../MarkdownEditor`. The shell is
[Tauri 2](https://tauri.app). All program logic is Rust, in the `mdcore`
crate. The UI runs in the system web view: WebView2 on Windows, WebKitGTK
on Linux, WKWebView on macOS.

## Layout

```
Cargo.toml            workspace
core/                 mdcore — platform-independent, unit-tested
  src/render/         comrak → own AST, $$/footnote/front-matter rewrites,
                      inline math, tokenizers (C#, JS, TS, Python),
                      HTML renderer (data-line / data-hash), page CSS,
                      PDF renderer (pdf-writer), preview diagnostics
  src/highlight/      editor highlighter (line + paragraph passes) and
                      "context at caret"
  src/editor/         list continuation, renumbering, Tab/indent, pairs,
                      smart quotes, format actions, line operations,
                      tables, inline tags/footnotes, image paste/drop
  src/completion/     fuzzy ranking, snippets, Markdown / LaTeX / mermaid
                      providers (latex-commands.json, mermaid-syntax.json)
  src/outline.rs, src/math_locator.rs, src/api.rs (what the UI calls)
app/                  Tauri shell: windows, native menus, dialogs, files,
                      docfile:// for relative images, commands → mdcore
  ui/                 front end: editor.js (textarea + highlighted backdrop),
                      app.js (window glue), preview.js (unchanged preview
                      script), preview-host.js, vendor/ mermaid + MathJax
```

## Build and run

Requirements: Rust (stable). On Linux you also need the WebKitGTK
development packages:

```
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev
```

Windows needs the WebView2 runtime, which ships with Windows 10 and 11.

```
cd src/MarkdownEditorRust
cargo test -p mdcore                       # core tests
cargo run -p markdown-editor -- notes.md   # run (debug)
```

Installers (`.dmg`/`.app`, `.msi`/NSIS `.exe`, `.deb`/`.AppImage`/`.rpm`)
are built with the Tauri CLI, on each target OS:

```
cargo install tauri-cli --version "^2" --locked
cd app && cargo tauri build
```

`.github/workflows/rust-app.yml` runs the tests and builds the installers
on all three platforms.

The core can also be used without the app:

```
cargo run -p mdcore --example render_pdf -- in.md out.pdf
```

## Differences from the macOS version

- **Editor**: a `<textarea>` with transparent text over a backdrop that the
  core highlights. Caret, selection, IME input, spell checking and undo
  stay native. Every command (Return in a list, Tab in a table, a format
  action) comes back from Rust as a single replacement and is applied as
  one undo step.
- **PDF**: uses the PDF standard fonts (Helvetica, Courier), so nothing is
  embedded and the output is the same on every platform. Text is limited to
  Windows-1252 (Latin-1, typographic quotes, dashes, €). Other characters
  are transliterated or printed as `?`. Unlike the original, long
  paragraphs and code blocks continue on the next page instead of being
  clipped. Diagrams and formulas are still harvested from the preview.
- **LaTeX completion**: `\al` now matches `alpha`. The Swift popup filtered
  the typed backslash against names stored without one.
- **Documents**: no autosave/Versions or Open Recent. Unsaved changes are
  asked about on close and quit. Opening a file reuses the window unless it
  holds an unsaved untitled document, as before. On Windows and Linux every
  launch from the file manager starts its own process.
- **Find & replace** is the app's own bar (case and regex options) instead
  of the macOS find bar.
- **Settings** are stored in the platform config directory
  (`…/MarkdownEditor/settings.json`).
