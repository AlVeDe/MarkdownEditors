//! The editor's Markdown highlighter, and "what is the caret in?".
//!
//! Two passes, as in the original: a line pass (`line`) tracks block
//! structure — fences, `$$` blocks, front matter, comments — and records each
//! line's inline content; an inline pass (`inline`) analyzes whole paragraphs,
//! because CommonMark parses emphasis, code spans and links across lines.
//! Fences whose language has a tokenizer are colored by the shared tokenizer
//! as a whole block.
//!
//! The web editor draws the result as a backdrop behind a transparent
//! `<textarea>`; [`render_lines`] produces that backdrop's HTML, one string
//! per line, so the front end can replace only the lines that changed.

pub mod inline;
pub mod line;
pub mod scan;

use serde::Serialize;

use crate::render::syntax::{tokenizer_for, TokenKind};
use crate::text::Range;
use inline::{InlineAnalyzer, InlineSegment};
use line::{BlockKind, InlineKind, InlineLine, LineAnalyzer, LineState};

/// What kind of source the caret is in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "language", rename_all = "camelCase")]
pub enum EditorContext {
    Markdown,
    InlineCode,
    CodeBlock(Option<String>),
    FenceInfo,
    InlineMath,
    DisplayMath,
    Mermaid,
    FrontMatter,
    HtmlComment,
}

impl EditorContext {
    pub fn is_math(&self) -> bool {
        matches!(self, EditorContext::InlineMath | EditorContext::DisplayMath)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct FontTraits(pub u8);

impl FontTraits {
    pub const NONE: FontTraits = FontTraits(0);
    pub const BOLD: FontTraits = FontTraits(1);
    pub const ITALIC: FontTraits = FontTraits(2);
    pub fn contains(self, other: FontTraits) -> bool {
        self.0 & other.0 == other.0
    }
    pub fn union(self, other: FontTraits) -> FontTraits {
        FontTraits(self.0 | other.0)
    }
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpanStyle {
    Marker,
    Heading,
    Font(FontTraits),
    Strikethrough,
    InlineCode,
    CodeBlock,
    FenceInfo,
    Link,
    Url,
    Image,
    LinkTitle,
    Quote,
    QuoteMarker,
    ListMarker,
    TaskBox,
    Html,
    Comment,
    FrontMatterKey,
    FrontMatterValue,
    Math,
    MathCommand,
    Token(TokenKind),
    MermaidKeyword,
    MermaidArrow,
    MermaidText,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HighlightSpan {
    pub location: usize,
    pub length: usize,
    pub style: SpanStyle,
}

/// A range in which the caret has a non-Markdown context. `end` is
/// inclusive: a caret right before a closing `` ` `` or `$` is still inside.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextRegion {
    pub location: usize,
    pub end: usize,
    pub context: EditorContext,
}

/// The block pass's result for a whole text.
pub struct Analysis {
    pub line_starts: Vec<usize>,
    pub states: Vec<LineState>,
    pub inline_lines: Vec<InlineLine>,
}

fn line_starts(text: &[u16]) -> Vec<usize> {
    let mut starts = vec![0];
    for (i, &u) in text.iter().enumerate() {
        if u == scan::ch::NEWLINE {
            starts.push(i + 1);
        }
    }
    starts
}

fn line_chars<'a>(text: &'a [u16], starts: &[usize], k: usize) -> &'a [u16] {
    let start = starts[k];
    let end = if k + 1 < starts.len() { starts[k + 1] - 1 } else { text.len() };
    if end <= start {
        return &[];
    }
    let mut chars = &text[start..end];
    if chars.last() == Some(&scan::ch::CR) {
        chars = &chars[..chars.len() - 1];
    }
    chars
}

/// Paragraphs longer than this are analyzed in windows for caret context.
const PARAGRAPH_CAP: usize = 200;
const PARAGRAPH_WINDOW: usize = 50;

/// Runs the block pass over the whole text. With `spans`, also collects the
/// block-level spans and the tokens of tokenized fences.
fn block_pass(text: &[u16], spans: Option<&mut Vec<HighlightSpan>>) -> Analysis {
    let starts = line_starts(text);
    let count = starts.len();
    let mut states = vec![LineState::default(); count + 1];
    let mut inline_lines = vec![InlineLine::default(); count];
    let collect = spans.is_some();
    let mut block_spans = Vec::new();
    let mut token_spans = Vec::new();

    let mut i = 0;
    while i < count {
        let entering_normal = states[i].block == BlockKind::Normal;
        analyze_line(text, &starts, &mut states, &mut inline_lines, i, collect, &mut block_spans);
        i += 1;
        if let BlockKind::Fence(fence) = states[i].block.clone() {
            if fence.is_tokenized && entering_normal {
                let content_start = i;
                while i < count && matches!(states[i].block, BlockKind::Fence(_)) {
                    analyze_line(text, &starts, &mut states, &mut inline_lines, i, collect, &mut block_spans);
                    i += 1;
                }
                let closed = !matches!(states[i].block, BlockKind::Fence(_));
                let content_end = if closed { starts[i - 1] } else if i < count { starts[i] } else { text.len() };
                if collect && content_start < count {
                    tokenize(text, starts[content_start], content_end, fence.language.as_deref(), &mut token_spans);
                }
            }
        }
    }

    if let Some(out) = spans {
        out.extend(block_spans);
        let analysis = Analysis { line_starts: starts, states, inline_lines };
        // Inline spans over block spans, tokens last.
        let mut inline = InlineAnalyzer::new(true, false);
        analyze_units(text, &analysis, 0, count, &mut inline);
        out.extend(inline.spans);
        out.extend(token_spans);
        return analysis;
    }
    Analysis { line_starts: starts, states, inline_lines }
}

fn analyze_line(
    text: &[u16],
    starts: &[usize],
    states: &mut [LineState],
    inline_lines: &mut [InlineLine],
    k: usize,
    collect: bool,
    spans: &mut Vec<HighlightSpan>,
) {
    let count = starts.len();
    let next_line = if k + 1 < count { Some(line_chars(text, starts, k + 1)) } else { None };
    let mut analyzer = LineAnalyzer::new(collect, false);
    let next = analyzer.analyze(line_chars(text, starts, k), starts[k], &states[k], k == 0, next_line);
    inline_lines[k] = analyzer.inline_line;
    states[k + 1] = next;
    spans.append(&mut analyzer.spans);
}

fn tokenize(text: &[u16], start: usize, end: usize, language: Option<&str>, out: &mut Vec<HighlightSpan>) {
    if end <= start {
        return;
    }
    let Some(tokenizer) = tokenizer_for(language) else { return };
    let code = String::from_utf16_lossy(&text[start..end]);
    let mut location = start;
    for token in tokenizer.tokenize(&code) {
        let length = token.text.encode_utf16().count();
        if token.kind != TokenKind::Plain && location + length <= end {
            out.push(HighlightSpan { location, length, style: SpanStyle::Token(token.kind) });
        }
        location += length;
    }
}

/// Groups lines `lo..hi` into inline units and analyzes them.
fn analyze_units(text: &[u16], a: &Analysis, lo: usize, hi: usize, analyzer: &mut InlineAnalyzer) {
    let mut k = lo;
    let segment = |k: usize, info: &InlineLine, chars: &mut Vec<u16>, segs: &mut Vec<InlineSegment>| {
        let location = a.line_starts[k] + info.start;
        let count = info.end - info.start;
        segs.push(InlineSegment { buffer_start: chars.len(), length: count, location, traits: info.traits });
        chars.extend_from_slice(&text[location..location + count]);
    };
    while k < hi {
        let info = a.inline_lines[k];
        match info.kind {
            InlineKind::None => k += 1,
            InlineKind::Single => {
                let (mut chars, mut segs) = (vec![], vec![]);
                segment(k, &info, &mut chars, &mut segs);
                analyzer.analyze(chars, segs);
                k += 1;
            }
            InlineKind::TableRow => {
                let (mut chars, mut segs) = (vec![], vec![]);
                segment(k, &info, &mut chars, &mut segs);
                analyzer.analyze_table_row(&chars, a.line_starts[k] + info.start);
                k += 1;
            }
            InlineKind::Paragraph => {
                let (mut chars, mut segs) = (vec![], vec![]);
                segment(k, &info, &mut chars, &mut segs);
                k += 1;
                while k < hi && a.inline_lines[k].continues {
                    chars.push(scan::ch::NEWLINE);
                    let info = a.inline_lines[k];
                    segment(k, &info, &mut chars, &mut segs);
                    k += 1;
                }
                analyzer.analyze(chars, segs);
            }
        }
    }
}

/// Every highlight span of `text`, in application order (later wins).
pub fn spans(text: &[u16]) -> Vec<HighlightSpan> {
    let mut out = Vec::new();
    block_pass(text, Some(&mut out));
    out
}

pub fn analyze(text: &[u16]) -> Analysis {
    block_pass(text, None)
}

fn line_index(starts: &[usize], location: usize) -> usize {
    match starts.binary_search(&location) {
        Ok(i) => i,
        Err(i) => i - 1,
    }
}

/// The context at a UTF-16 offset.
pub fn context_at(text: &[u16], location: usize) -> EditorContext {
    let a = analyze(text);
    context_in(text, &a, location)
}

pub fn context_in(text: &[u16], a: &Analysis, location: usize) -> EditorContext {
    let location = location.min(text.len());
    let line = line_index(&a.line_starts, location);
    let chars = line_chars(text, &a.line_starts, line);
    let mut la = LineAnalyzer::new(false, true);
    la.analyze(chars, a.line_starts[line], &a.states[line], line == 0, None);
    let mut regions = la.regions;
    let mut unclosed = Vec::new();
    if a.inline_lines[line].kind != InlineKind::None {
        let mut lo = line;
        let mut hi = line + 1;
        if a.inline_lines[line].kind == InlineKind::Paragraph {
            while lo > 0 && a.inline_lines[lo].continues {
                lo -= 1;
            }
            while hi < a.inline_lines.len() && a.inline_lines[hi].continues {
                hi += 1;
            }
            if hi - lo > PARAGRAPH_CAP {
                lo = lo.max(line.saturating_sub(PARAGRAPH_WINDOW));
                hi = hi.min(line + PARAGRAPH_WINDOW + 1);
            }
        }
        let mut inline = InlineAnalyzer::new(false, true);
        analyze_units(text, a, lo, hi, &mut inline);
        regions.extend(inline.regions);
        unclosed = inline.unclosed_math;
    }
    if let Some(region) = regions.iter().rev().find(|r| r.location <= location && location <= r.end) {
        return region.context.clone();
    }
    if a.states[line].block == BlockKind::Normal
        && unclosed.iter().any(|u| u.location + 1 < location && location <= u.line_end)
    {
        return EditorContext::InlineMath;
    }
    EditorContext::Markdown
}

// MARK: - Backdrop rendering

/// Resolved attributes of one UTF-16 unit; later spans overwrite earlier
/// ones attribute by attribute, as text attributes do.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
struct Attr {
    color: u8,
    font: u8,
    bg: u8,
    strike: bool,
    /// Decoration bits: 1 diagnostic, 2 find match, 4 current find match.
    deco: u8,
}

const COLORS: &[&str] = &[
    "", "marker", "heading", "secondary", "icode", "fenceinfo", "link", "url", "image", "linktitle", "quotemarker",
    "listmarker", "html", "comment", "fmkey", "math", "mathcmd", "keyword", "string", "number", "preprocessor",
];

fn color_id(name: &str) -> u8 {
    COLORS.iter().position(|c| *c == name).unwrap_or(0) as u8
}

fn token_color(kind: TokenKind) -> u8 {
    match kind {
        TokenKind::Plain => 0,
        TokenKind::Keyword => color_id("keyword"),
        TokenKind::String => color_id("string"),
        TokenKind::Comment => color_id("comment"),
        TokenKind::Number => color_id("number"),
        TokenKind::Preprocessor => color_id("preprocessor"),
    }
}

/// (color, font, background, strike) a style sets; `None` leaves it alone.
fn style_attrs(style: SpanStyle) -> (Option<u8>, Option<u8>, Option<u8>, Option<bool>) {
    use SpanStyle::*;
    let c = |n: &str| Some(color_id(n));
    match style {
        Marker => (c("marker"), None, None, None),
        Heading => (c("heading"), Some(1), None, None),
        Font(t) => (None, Some(t.0), None, None),
        Strikethrough => (c("secondary"), None, None, Some(true)),
        InlineCode => (c("icode"), None, Some(1), None),
        CodeBlock => (None, None, Some(2), None),
        FenceInfo => (c("fenceinfo"), None, None, None),
        Link => (c("link"), None, None, None),
        Url => (c("url"), None, None, None),
        Image => (c("image"), None, None, None),
        LinkTitle => (c("linktitle"), None, None, None),
        Quote | FrontMatterValue => (c("secondary"), None, None, None),
        QuoteMarker => (c("quotemarker"), None, None, None),
        ListMarker | TaskBox | MermaidArrow => (c("listmarker"), None, None, None),
        Html => (c("html"), None, None, None),
        Comment => (c("comment"), None, None, None),
        FrontMatterKey => (c("fmkey"), None, None, None),
        Math => (c("math"), None, None, None),
        MathCommand => (c("mathcmd"), None, None, None),
        Token(k) => ((k != TokenKind::Plain).then(|| token_color(k)), None, None, None),
        MermaidKeyword => (c("keyword"), None, None, None),
        MermaidText => (c("string"), None, None, None),
    }
}

/// An extra mark over the text: a diagnostic underline or a find match.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
pub struct Decoration {
    pub range: Range,
    pub kind: DecorationKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DecorationKind {
    Diagnostic,
    Found,
    CurrentFound,
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderOptions {
    #[serde(default)]
    pub show_invisibles: bool,
}

fn escape_into(out: &mut String, units: &[u16], invisibles: bool) {
    for c in char::decode_utf16(units.iter().copied()) {
        let c = c.unwrap_or('\u{FFFD}');
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            ' ' if invisibles => out.push_str("<span class=\"ws sp\"> </span>"),
            '\t' if invisibles => out.push_str("<span class=\"ws tb\">\t</span>"),
            '\r' => {}
            _ => out.push(c),
        }
    }
}

/// The backdrop HTML of every line of `text`: runs of equal attributes as
/// `<span class="…">`, diagnostics underlined.
pub fn render_lines(text: &[u16], decorations: &[Decoration], options: &RenderOptions) -> Vec<String> {
    let mut attrs = vec![Attr::default(); text.len()];
    for span in spans(text) {
        let (color, font, bg, strike) = style_attrs(span.style);
        let end = (span.location + span.length).min(text.len());
        for a in &mut attrs[span.location.min(end)..end] {
            if let Some(c) = color {
                a.color = c;
            }
            if let Some(f) = font {
                a.font = f;
            }
            if let Some(b) = bg {
                a.bg = b;
            }
            if let Some(s) = strike {
                a.strike = s;
            }
        }
    }
    for d in decorations {
        let end = d.range.end().min(text.len());
        let start = d.range.location.min(end);
        let bit = match d.kind {
            DecorationKind::Diagnostic => 1,
            DecorationKind::Found => 2,
            DecorationKind::CurrentFound => 4,
        };
        for a in &mut attrs[start..end] {
            a.deco |= bit;
        }
    }
    let starts = line_starts(text);
    let mut lines = Vec::with_capacity(starts.len());
    for k in 0..starts.len() {
        let start = starts[k];
        let end = if k + 1 < starts.len() { starts[k + 1] - 1 } else { text.len() };
        let mut html = String::new();
        let mut i = start;
        while i < end {
            let a = attrs[i];
            let mut j = i + 1;
            while j < end && attrs[j] == a {
                j += 1;
            }
            if a == Attr::default() {
                escape_into(&mut html, &text[i..j], options.show_invisibles);
            } else {
                html.push_str("<span class=\"");
                let mut classes = Vec::new();
                if a.color != 0 {
                    classes.push(format!("c-{}", COLORS[a.color as usize]));
                }
                if a.font & 1 != 0 {
                    classes.push("f-b".into());
                }
                if a.font & 2 != 0 {
                    classes.push("f-i".into());
                }
                if a.bg == 1 {
                    classes.push("bg-icode".into());
                } else if a.bg == 2 {
                    classes.push("bg-code".into());
                }
                if a.strike {
                    classes.push("strike".into());
                }
                if a.deco & 1 != 0 {
                    classes.push("diag".into());
                }
                if a.deco & 2 != 0 {
                    classes.push("found".into());
                }
                if a.deco & 4 != 0 {
                    classes.push("found-current".into());
                }
                html.push_str(&classes.join(" "));
                html.push_str("\">");
                escape_into(&mut html, &text[i..j], options.show_invisibles);
                html.push_str("</span>");
            }
            i = j;
        }
        lines.push(html);
    }
    lines
}

/// Whether line `k` (0-based) lies in a fenced or indented code block — the
/// backdrop paints such lines' full width.
pub fn code_block_lines(text: &[u16]) -> Vec<bool> {
    let a = analyze(text);
    (0..a.line_starts.len())
        .map(|k| matches!(a.states[k].block, BlockKind::Fence(_)) || matches!(a.states[k + 1].block, BlockKind::Fence(_)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::utf16;

    fn ctx(s: &str, at: usize) -> EditorContext {
        context_at(&utf16(s), at)
    }

    #[test]
    fn contexts() {
        assert_eq!(ctx("a `code` b", 4), EditorContext::InlineCode);
        assert_eq!(ctx("x $\\alpha$ y", 5), EditorContext::InlineMath);
        assert_eq!(ctx("$$\n\\frac\n$$", 4), EditorContext::DisplayMath);
        assert_eq!(ctx("```mermaid\ngraph\n```", 12), EditorContext::Mermaid);
        assert_eq!(ctx("```py\nx\n```", 7), EditorContext::CodeBlock(Some("py".into())));
        assert_eq!(ctx("```py\nx\n```", 4), EditorContext::FenceInfo);
        assert_eq!(ctx("plain", 2), EditorContext::Markdown);
        // Still typing an unclosed formula.
        assert_eq!(ctx("see $\\alp", 9), EditorContext::InlineMath);
    }

    #[test]
    fn multi_line_emphasis() {
        let s = utf16("**bold\nstill**");
        let sp = spans(&s);
        assert!(sp.iter().any(|x| x.style == SpanStyle::Font(FontTraits::BOLD) && x.location == 7));
    }

    #[test]
    fn heading_line_html() {
        let lines = render_lines(&utf16("# Hi *x*"), &[], &RenderOptions::default());
        assert_eq!(
            lines[0],
            "<span class=\"c-marker\">#</span><span class=\"c-heading f-b\"> Hi </span><span class=\"c-marker f-b\">*</span><span class=\"c-heading f-b f-i\">x</span><span class=\"c-marker f-b\">*</span>"
        );
    }
}
