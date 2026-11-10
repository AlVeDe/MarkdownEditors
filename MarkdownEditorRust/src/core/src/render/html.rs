//! Renderer #1: document → HTML fragment.
//!
//! Code blocks are the customized extension point: registered languages
//! become colored `<span class="tok-…">` runs, ` ```mermaid ` fences become
//! `<pre class="mermaid">` for mermaid.js, and ` ```math ` fences become
//! `<div class="math">` for MathJax. Inline formulas become
//! `<span class="math">\(…\)</span>`.
//!
//! Two attributes serve the live preview:
//!
//! - `data-line` on every block element: the 1-based line in the *editor*
//!   text where the block starts (scroll sync, diagnostics). Mermaid diagrams
//!   and display math also get `data-end-line`.
//! - `data-hash` on every top-level block: a hash of the block's HTML
//!   *without* the line attributes. The preview diffs top-level children by
//!   it, so typing in one paragraph neither re-typesets formulas nor
//!   re-renders diagrams elsewhere.

use super::ast::{Alignment, Block, Document, Inline, ListItem};
use super::math_blocks::{LineMap, LANGUAGE as MATH_LANGUAGE};
use super::syntax::tokenizer_for;

pub fn html_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x100_0000_01b3;

pub struct HtmlRenderer<'a> {
    html: String,
    line_map: &'a LineMap,
    image_base: Option<&'a str>,
    hash: u64,
}

/// Renders a whole document; every top-level block carries `data-hash`.
pub fn render(document: &Document, line_map: &LineMap, image_base: Option<&str>) -> String {
    let mut html = String::new();
    for block in &document.blocks {
        let mut r = HtmlRenderer { html: String::new(), line_map, image_base, hash: FNV_OFFSET };
        r.block(block);
        html.push_str(&inserting_hash(r.hash, &r.html));
    }
    html
}

/// Convenience: parse + render with the identity of every rewrite applied.
pub fn markdown_to_html(markdown: &str, image_base: Option<&str>) -> String {
    let (doc, map) = super::ast::parse_mapped(markdown);
    render(&doc, &map, image_base)
}

fn to_base36(mut n: u64) -> String {
    if n == 0 {
        return "0".into();
    }
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    while n > 0 {
        out.push(digits[(n % 36) as usize]);
        n /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap()
}

/// Adds `data-hash` to the block's opening tag. Raw HTML blocks that do not
/// start with an element stay hashless.
fn inserting_hash(hash: u64, block: &str) -> String {
    let mut chars = block.char_indices();
    match (chars.next(), chars.next()) {
        (Some((_, '<')), Some((_, second))) if second.is_alphabetic() => {}
        _ => return block.to_string(),
    }
    let name_end = block[1..].find(|c: char| !c.is_alphanumeric()).map(|i| i + 1).unwrap_or(block.len());
    let mut result = block.to_string();
    result.insert_str(name_end, &format!(" data-hash=\"{}\"", to_base36(hash)));
    result
}

impl HtmlRenderer<'_> {
    fn emit(&mut self, s: &str) {
        self.html.push_str(s);
        for b in s.bytes() {
            self.hash = (self.hash ^ b as u64).wrapping_mul(FNV_PRIME);
        }
    }

    fn emit_line(&mut self, line: usize, end_line: Option<usize>) {
        if line == 0 {
            return;
        }
        self.html.push_str(&format!(" data-line=\"{}\"", self.line_map.original_line(line)));
        if let Some(end) = end_line {
            self.html.push_str(&format!(" data-end-line=\"{}\"", self.line_map.original_line(end)));
        }
    }

    fn open(&mut self, name: &str, line: usize, attributes: &str, end_line: Option<usize>) {
        self.emit(&format!("<{name}"));
        self.emit_line(line, end_line);
        self.emit(&format!("{attributes}>"));
    }

    fn blocks(&mut self, blocks: &[Block]) {
        for b in blocks {
            self.block(b);
        }
    }

    fn block(&mut self, block: &Block) {
        match block {
            Block::Heading { level, line, children } => {
                self.open(&format!("h{level}"), *line, "", None);
                self.inlines(children);
                self.emit(&format!("</h{level}>\n"));
            }
            Block::Paragraph { line, children } => {
                self.open("p", *line, "", None);
                self.inlines(children);
                self.emit("</p>\n");
            }
            Block::BlockQuote { line, children } => {
                self.open("blockquote", *line, "", None);
                self.emit("\n");
                self.blocks(children);
                self.emit("</blockquote>\n");
            }
            Block::CodeBlock { language, code, line, end_line } => self.code_block(language.as_deref(), code, *line, *end_line),
            Block::ThematicBreak { line } => {
                self.open("hr", *line, " /", None);
                self.emit("\n");
            }
            Block::HtmlBlock { raw } => self.emit(raw),
            Block::List { ordered, start, line, items } => {
                if *ordered {
                    let start_attr = if *start != 1 { format!(" start=\"{start}\"") } else { String::new() };
                    self.open("ol", *line, &start_attr, None);
                } else {
                    self.open("ul", *line, "", None);
                }
                self.emit("\n");
                for item in items {
                    self.list_item(item);
                }
                self.emit(if *ordered { "</ol>\n" } else { "</ul>\n" });
            }
            Block::Table { line, alignments, head, rows } => {
                let align = |i: usize| match alignments.get(i) {
                    Some(Alignment::Left) => " style=\"text-align:left\"",
                    Some(Alignment::Center) => " style=\"text-align:center\"",
                    Some(Alignment::Right) => " style=\"text-align:right\"",
                    _ => "",
                };
                self.open("table", *line, "", None);
                self.emit("\n<thead>\n");
                self.open("tr", head.line, "", None);
                for (i, cell) in head.cells.iter().enumerate() {
                    self.emit(&format!("<th{}>", align(i)));
                    self.inlines(cell);
                    self.emit("</th>");
                }
                self.emit("</tr>\n</thead>\n<tbody>\n");
                for row in rows {
                    self.open("tr", row.line, "", None);
                    for (i, cell) in row.cells.iter().enumerate() {
                        self.emit(&format!("<td{}>", align(i)));
                        self.inlines(cell);
                        self.emit("</td>");
                    }
                    self.emit("</tr>\n");
                }
                self.emit("</tbody>\n</table>\n");
            }
        }
    }

    fn code_block(&mut self, language: Option<&str>, code: &str, line: usize, end_line: usize) {
        let lang = language.unwrap_or("").to_lowercase();
        if lang == "mermaid" {
            self.open("pre", line, " class=\"mermaid\"", Some(end_line));
            self.emit(&format!("{}</pre>\n", html_escape(code)));
            return;
        }
        if lang == MATH_LANGUAGE {
            self.open("div", line, " class=\"math\"", Some(end_line));
            self.emit(&format!("$$\n{}\n$$</div>\n", html_escape(code)));
            return;
        }
        if let Some(tokenizer) = tokenizer_for(language) {
            self.open("pre", line, "", None);
            self.emit(&format!("<code class=\"language-{}\">", html_escape(&lang)));
            for token in tokenizer.tokenize(code) {
                match token.kind.css_class() {
                    Some(class) => self.emit(&format!("<span class=\"{class}\">{}</span>", html_escape(&token.text))),
                    None => self.emit(&html_escape(&token.text)),
                }
            }
            self.emit("</code></pre>\n");
        } else {
            self.open("pre", line, "", None);
            self.emit(&format!("<code>{}</code></pre>\n", html_escape(code)));
        }
    }

    fn list_item(&mut self, item: &ListItem) {
        if let Some(checked) = item.checkbox {
            self.open("li", item.line, " class=\"task\"", None);
            self.emit(&format!("<input type=\"checkbox\" disabled{} />", if checked { " checked" } else { "" }));
        } else {
            self.open("li", item.line, "", None);
        }
        // Paragraph children without <p> wrappers (tight-list style).
        for child in &item.children {
            if let Block::Paragraph { children, .. } = child {
                self.inlines(children);
            } else {
                self.block(child);
            }
        }
        self.emit("</li>\n");
    }

    fn inlines(&mut self, inlines: &[Inline]) {
        for inline in inlines {
            self.inline(inline);
        }
    }

    fn inline(&mut self, inline: &Inline) {
        match inline {
            Inline::Text(t) => self.emit(&html_escape(t)),
            Inline::Emphasis(c) => {
                self.emit("<em>");
                self.inlines(c);
                self.emit("</em>");
            }
            Inline::Strong(c) => {
                self.emit("<strong>");
                self.inlines(c);
                self.emit("</strong>");
            }
            Inline::Strikethrough(c) => {
                self.emit("<del>");
                self.inlines(c);
                self.emit("</del>");
            }
            Inline::Code(code) => self.emit(&format!("<code>{}</code>", html_escape(code))),
            Inline::Math(tex) => self.emit(&format!("<span class=\"math\">\\({}\\)</span>", html_escape(tex))),
            Inline::Html(raw) => self.emit(raw),
            Inline::Link { destination, children } => {
                let dest = if destination.is_empty() { "#".to_string() } else { html_escape(destination) };
                self.emit(&format!("<a href=\"{dest}\">"));
                self.inlines(children);
                self.emit("</a>");
            }
            Inline::Image { source, children } => {
                let src = html_escape(&self.resolved_image_source(source));
                let alt: String = children
                    .iter()
                    .filter_map(|c| if let Inline::Text(t) = c { Some(t.as_str()) } else { None })
                    .collect();
                self.emit(&format!("<img src=\"{src}\" alt=\"{}\" />", html_escape(&alt)));
            }
            Inline::SoftBreak => self.emit("\n"),
            Inline::LineBreak => self.emit("<br />\n"),
        }
    }

    fn resolved_image_source(&self, source: &str) -> String {
        match self.image_base {
            Some(base) if is_relative_path(source) => format!("{base}{}", percent_encode_path(source)),
            _ => source.to_string(),
        }
    }
}

/// Percent-encodes everything outside RFC 3986's path characters, keeping
/// `%` so already-encoded sources survive.
pub fn percent_encode_path(source: &str) -> String {
    let mut out = String::new();
    for b in source.bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || "-._~!$&'()*+,;=:@/%".contains(c) {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Whether an image source is a relative path (no scheme, not absolute,
/// not a fragment).
pub fn is_relative_path(source: &str) -> bool {
    if source.is_empty() || source.starts_with('/') || source.starts_with('#') {
        return false;
    }
    if let Some(colon) = source.find(':') {
        let scheme = &source[..colon];
        if !scheme.is_empty()
            && !scheme.contains('/')
            && scheme.chars().all(|c| c.is_alphanumeric() || "+-.".contains(c))
        {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_and_lines() {
        let html = markdown_to_html("# Title\n\ntext", None);
        assert!(html.starts_with("<h1 data-hash=\""));
        assert!(html.contains(" data-line=\"1\">Title</h1>"));
        assert!(html.contains(" data-line=\"3\">text</p>"));
    }

    #[test]
    fn same_block_same_hash_after_move() {
        let a = markdown_to_html("para", None);
        let b = markdown_to_html("\n\npara", None);
        let hash = |s: &str| s.split("data-hash=\"").nth(1).unwrap().split('"').next().unwrap().to_string();
        assert_eq!(hash(&a), hash(&b));
    }

    #[test]
    fn math_and_mermaid() {
        let html = markdown_to_html("$$\nE=mc^2\n$$\n\n```mermaid\ngraph TD\n```", None);
        assert!(html.contains("data-end-line=\"3\" class=\"math\""), "{html}");
        assert!(html.contains("data-line=\"1\" data-end-line=\"3\""), "{html}");
        assert!(html.contains("<pre data-hash"));
        assert!(html.contains("class=\"mermaid\""));
    }

    #[test]
    fn relative_images() {
        let html = markdown_to_html("![a b](<img/x y.png>)", Some("docfile://localhost/"));
        assert!(html.contains("src=\"docfile://localhost/img/x%20y.png\""), "{html}");
        assert!(!is_relative_path("https://x"));
        assert!(is_relative_path("a/b:c"));
    }
}
