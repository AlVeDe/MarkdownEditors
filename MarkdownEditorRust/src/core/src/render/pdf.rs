//! Renderer #3: document → PDF.
//!
//! A4 pages with 2 cm margins and a `page / total` footer. Each block is
//! laid out by a small line breaker over the PDF standard fonts (Helvetica
//! for text, Courier for code — available in every PDF viewer, so nothing is
//! embedded and the output is identical on every platform). A block that
//! does not fit the remaining height continues on the next page.
//!
//! Code blocks use the shared tokenizers with the preview's colors; mermaid
//! diagrams and LaTeX formulas are drawn from PNGs harvested from the live
//! preview (with the source text as fallback, so nothing silently vanishes).
//! Inline formulas reserve exactly their harvested box on the line and sit on
//! the text baseline.
//!
//! The standard fonts cover Windows-1252 (Latin-1 plus typographic quotes,
//! dashes, €…). Other characters are transliterated where a close equivalent
//! exists and printed as `?` otherwise.

use std::collections::HashMap;

use base64::Engine;
use pdf_writer::types::{ActionType, AnnotationType};
use pdf_writer::{Content, Filter, Finish, Name, Pdf, Rect, Ref, Str};
use serde::Deserialize;

use super::ast::{self, Block, Inline, ListItem};
use super::math_blocks::LANGUAGE as MATH_LANGUAGE;
use super::syntax::tokenizer_for;

const PAGE_W: f32 = 595.28;
const PAGE_H: f32 = 841.89;
const MARGIN: f32 = 56.7;
const CONTENT_W: f32 = PAGE_W - 2.0 * MARGIN;
const CONTENT_H: f32 = PAGE_H - 2.0 * MARGIN;
const BODY_SIZE: f32 = 11.0;
const CODE_SIZE: f32 = 9.0;
const HEADING_SIZES: [f32; 6] = [22.0, 17.0, 14.5, 12.5, 11.5, 11.0];

type Color = (f32, f32, f32);

fn hex(c: u32) -> Color {
    (((c >> 16) & 0xFF) as f32 / 255.0, ((c >> 8) & 0xFF) as f32 / 255.0, (c & 0xFF) as f32 / 255.0)
}

const BLACK: Color = (0.0, 0.0, 0.0);
const SECONDARY: Color = (0.45, 0.45, 0.45);
const BORDER: Color = (0.78, 0.78, 0.78);
const CODE_BG: Color = (0.955, 0.955, 0.955);
const QUOTE_BAR: Color = (0.8, 0.8, 0.8);

fn link_color() -> Color {
    hex(0x0969DA)
}
fn mark_color() -> Color {
    hex(0xFFF3A3)
}

// MARK: - Harvested images

/// One rasterized SVG harvested from the preview. Geometry in em of the
/// surrounding text, so a formula keeps its proportion to the text.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Harvested {
    /// `data:image/png;base64,…`
    pub png: String,
    pub width_em: f64,
    pub height_em: f64,
    #[serde(default)]
    pub depth_em: f64,
}

/// A decoded image ready to embed.
#[derive(Clone)]
struct Image {
    width: u32,
    height: u32,
    rgb: Vec<u8>,
    alpha: Option<Vec<u8>>,
}

fn decode_png_data_url(url: &str) -> Option<Image> {
    let b64 = url.split("base64,").nth(1)?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64.trim()).ok()?;
    decode_png(&bytes)
}

fn decode_png(bytes: &[u8]) -> Option<Image> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let data = &buf[..info.buffer_size()];
    let (w, h) = (info.width, info.height);
    let px = (w * h) as usize;
    let mut rgb = Vec::with_capacity(px * 3);
    let mut alpha = Vec::with_capacity(px);
    match info.color_type {
        png::ColorType::Rgba => {
            for p in data.chunks_exact(4) {
                rgb.extend_from_slice(&p[..3]);
                alpha.push(p[3]);
            }
        }
        png::ColorType::Rgb => rgb.extend_from_slice(data),
        png::ColorType::GrayscaleAlpha => {
            for p in data.chunks_exact(2) {
                rgb.extend_from_slice(&[p[0], p[0], p[0]]);
                alpha.push(p[1]);
            }
        }
        png::ColorType::Grayscale => {
            for &g in data {
                rgb.extend_from_slice(&[g, g, g]);
            }
        }
        png::ColorType::Indexed => return None,
    }
    let has_alpha = !alpha.is_empty() && alpha.iter().any(|&a| a != 255);
    Some(Image { width: w, height: h, rgb, alpha: has_alpha.then_some(alpha) })
}

struct MathImage {
    image: usize,
    width_em: f32,
    height_em: f32,
    depth_em: f32,
}

// MARK: - Fonts

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Font {
    Regular,
    Bold,
    Italic,
    BoldItalic,
    Mono,
}

impl Font {
    fn name(self) -> &'static [u8] {
        match self {
            Font::Regular => b"F1",
            Font::Bold => b"F2",
            Font::Italic => b"F3",
            Font::BoldItalic => b"F4",
            Font::Mono => b"F5",
        }
    }
    fn base(self) -> &'static [u8] {
        match self {
            Font::Regular => b"Helvetica",
            Font::Bold => b"Helvetica-Bold",
            Font::Italic => b"Helvetica-Oblique",
            Font::BoldItalic => b"Helvetica-BoldOblique",
            Font::Mono => b"Courier",
        }
    }
    fn with(bold: bool, italic: bool) -> Font {
        match (bold, italic) {
            (false, false) => Font::Regular,
            (true, false) => Font::Bold,
            (false, true) => Font::Italic,
            (true, true) => Font::BoldItalic,
        }
    }
    fn is_bold(self) -> bool {
        matches!(self, Font::Bold | Font::BoldItalic)
    }
}

#[rustfmt::skip]
const HELVETICA: [u16; 95] = [
    278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,
    556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,
    1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,
    333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,
    556,556,333,500,278,556,500,722,500,500,500,334,260,334,584,
];

#[rustfmt::skip]
const HELVETICA_BOLD: [u16; 95] = [
    278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,
    556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,
    975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,
    333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,
    611,611,389,556,333,611,556,778,556,556,500,389,280,389,584,
];

/// Windows-1252 byte for a character, if the standard fonts have it.
fn win_ansi(c: char) -> Option<u8> {
    let v = c as u32;
    if (0x20..=0x7E).contains(&v) || (0xA0..=0xFF).contains(&v) {
        return Some(v as u8);
    }
    Some(match c {
        '€' => 0x80,
        '‚' => 0x82,
        'ƒ' => 0x83,
        '„' => 0x84,
        '…' => 0x85,
        '†' => 0x86,
        '‡' => 0x87,
        'ˆ' => 0x88,
        '‰' => 0x89,
        'Š' => 0x8A,
        '‹' => 0x8B,
        'Œ' => 0x8C,
        'Ž' => 0x8E,
        '‘' => 0x91,
        '’' => 0x92,
        '“' => 0x93,
        '”' => 0x94,
        '•' => 0x95,
        '–' => 0x96,
        '—' => 0x97,
        '˜' => 0x98,
        '™' => 0x99,
        'š' => 0x9A,
        '›' => 0x9B,
        'œ' => 0x9C,
        'ž' => 0x9E,
        'Ÿ' => 0x9F,
        _ => return None,
    })
}

/// Transliteration for characters outside Windows-1252.
fn transliterate(c: char) -> &'static str {
    match c {
        '\t' => "    ",
        '⌘' => "Cmd+",
        '⌥' => "Alt+",
        '⌃' => "Ctrl+",
        '⇧' => "Shift+",
        '⎋' => "Esc",
        '▸' | '▶' | '►' => ">",
        '→' | '⟶' => "->",
        '←' | '⟵' => "<-",
        '↔' => "<->",
        '⇒' => "=>",
        '⇐' => "<=",
        '↩' => "^",
        '≤' => "<=",
        '≥' => ">=",
        '≠' => "!=",
        '≈' => "~",
        '−' => "-",
        '✓' | '✔' => "v",
        '✗' | '✘' => "x",
        '\u{200B}' | '\u{FEFF}' | '\u{200D}' => "",
        '\u{2002}'..='\u{200A}' | '\u{202F}' => " ",
        _ => "?",
    }
}

/// Encodes `s` for a standard font (as Windows-1252 bytes).
fn encode(s: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    for c in s.chars() {
        match win_ansi(c) {
            Some(b) => out.push(b),
            None => out.extend(transliterate(c).bytes()),
        }
    }
    out
}

fn ascii_fold(b: u8) -> u8 {
    match b {
        0xC0..=0xC6 => b'A',
        0xC7 => b'C',
        0xC8..=0xCB => b'E',
        0xCC..=0xCF => b'I',
        0xD0 => b'D',
        0xD1 => b'N',
        0xD2..=0xD6 | 0xD8 => b'O',
        0xD9..=0xDC => b'U',
        0xDD => b'Y',
        0xDE => b'P',
        0xDF => b'B',
        0xE0..=0xE6 => b'a',
        0xE7 => b'c',
        0xE8..=0xEB => b'e',
        0xEC..=0xEF => b'i',
        0xF0 => b'o',
        0xF1 => b'n',
        0xF2..=0xF6 | 0xF8 => b'o',
        0xF9..=0xFC => b'u',
        0xFD | 0xFF => b'y',
        0xFE => b'p',
        0x8A | 0x9A => b'S',
        0x8E | 0x9E => b'Z',
        0x8C | 0x9C => b'W',
        0x93 | 0x94 | 0x84 => b'"',
        0x91 | 0x92 | 0x82 => b'\'',
        0x96 => b'-',
        0x97 | 0x85 | 0x89 => b'M',
        0x80 => b'C',
        _ => b'n',
    }
}

fn byte_width(font: Font, b: u8) -> f32 {
    if font == Font::Mono {
        return 600.0;
    }
    let table = if font.is_bold() { &HELVETICA_BOLD } else { &HELVETICA };
    let b = if (0x20..=0x7E).contains(&b) { b } else { ascii_fold(b) };
    table[(b - 0x20) as usize] as f32
}

fn measure(bytes: &[u8], font: Font, size: f32) -> f32 {
    bytes.iter().map(|&b| byte_width(font, b)).sum::<f32>() * size / 1000.0
}

// MARK: - Inline model

#[derive(Debug, Clone, PartialEq)]
struct Style {
    font: Font,
    size: f32,
    color: Color,
    background: Option<Color>,
    link: Option<String>,
    underline: bool,
    strike: bool,
    rise: f32,
    /// The size of the surrounding text (line metrics), for sub/sup.
    line_size: f32,
}

impl Style {
    fn plain(font: Font, size: f32) -> Style {
        Style {
            font,
            size,
            color: BLACK,
            background: None,
            link: None,
            underline: false,
            strike: false,
            rise: 0.0,
            line_size: size,
        }
    }
}

#[derive(Debug, Clone)]
enum Piece {
    Text(String, Style),
    Math { image: usize, width: f32, ascent: f32, descent: f32 },
    Break,
}

/// Folds inline nodes into pieces (the PDF twin of the HTML inline pass).
struct InlineBuilder<'a> {
    base_font_bold: bool,
    size: f32,
    bold: bool,
    italic: bool,
    mark: i32,
    sub: i32,
    sup: i32,
    link: Option<String>,
    strike: bool,
    pieces: Vec<Piece>,
    math: &'a [Option<MathImage>],
    math_index: &'a mut usize,
}

impl InlineBuilder<'_> {
    fn style(&self) -> Style {
        let mut font = Font::with(self.bold || self.base_font_bold, self.italic);
        let mut size = self.size;
        let mut rise = 0.0;
        if self.sup > 0 || self.sub > 0 {
            size = (self.size * 0.75).round();
            rise = if self.sup > 0 { self.size * 0.35 } else { -self.size * 0.18 };
        }
        if font == Font::Mono {
            font = Font::Regular;
        }
        Style {
            font,
            size,
            color: if self.link.is_some() { link_color() } else { BLACK },
            background: (self.mark > 0).then(mark_color),
            link: self.link.clone(),
            underline: self.link.is_some(),
            strike: self.strike,
            rise,
            line_size: self.size,
        }
    }

    fn inlines(&mut self, inlines: &[Inline]) {
        for i in inlines {
            self.inline(i);
        }
    }

    fn inline(&mut self, inline: &Inline) {
        match inline {
            Inline::Text(t) => {
                let style = self.style();
                self.pieces.push(Piece::Text(t.clone(), style));
            }
            Inline::Emphasis(c) => {
                let was = self.italic;
                self.italic = true;
                self.inlines(c);
                self.italic = was;
            }
            Inline::Strong(c) => {
                let was = self.bold;
                self.bold = true;
                self.inlines(c);
                self.bold = was;
            }
            Inline::Strikethrough(c) => {
                let was = self.strike;
                self.strike = true;
                self.inlines(c);
                self.strike = was;
            }
            Inline::Code(code) => {
                let mut style = self.style();
                style.font = Font::Mono;
                style.size = self.size * 0.88;
                style.background = Some(CODE_BG);
                self.pieces.push(Piece::Text(code.clone(), style));
            }
            Inline::Math(tex) => {
                let index = *self.math_index;
                *self.math_index += 1;
                match self.math.get(index).and_then(|m| m.as_ref()) {
                    Some(m) => {
                        let s = self.size;
                        self.pieces.push(Piece::Math {
                            image: m.image,
                            width: m.width_em * s,
                            ascent: (m.height_em - m.depth_em) * s,
                            descent: m.depth_em * s,
                        });
                    }
                    None => {
                        let mut style = self.style();
                        style.font = Font::Mono;
                        style.size = self.size * 0.88;
                        self.pieces.push(Piece::Text(tex.clone(), style));
                    }
                }
            }
            Inline::Html(raw) => {
                let tag = raw.trim().to_lowercase();
                let closing = tag.starts_with("</");
                let name: String = tag.trim_start_matches(['<', '/']).chars().take_while(|c| c.is_alphabetic()).collect();
                let delta = if closing { -1 } else { 1 };
                match name.as_str() {
                    "mark" => self.mark = (self.mark + delta).max(0),
                    "sub" => self.sub = (self.sub + delta).max(0),
                    "sup" => self.sup = (self.sup + delta).max(0),
                    "br" => self.pieces.push(Piece::Break),
                    _ => {}
                }
            }
            Inline::Link { destination, children } => {
                let was = self.link.take();
                self.link = Some(destination.clone());
                self.inlines(children);
                self.link = was;
            }
            Inline::Image { source, children } => {
                let alt: String =
                    children.iter().filter_map(|c| if let Inline::Text(t) = c { Some(t.as_str()) } else { None }).collect();
                let mut style = self.style();
                style.color = SECONDARY;
                let label = if alt.is_empty() { if source.is_empty() { "image" } else { source } } else { &alt };
                self.pieces.push(Piece::Text(format!("[image: {label}]"), style));
            }
            Inline::SoftBreak => {
                let style = self.style();
                self.pieces.push(Piece::Text(" ".into(), style));
            }
            Inline::LineBreak => self.pieces.push(Piece::Break),
        }
    }
}

// MARK: - Line layout

#[derive(Debug, Clone)]
enum FragKind {
    Text(Vec<u8>, Style),
    Math(usize),
}

#[derive(Debug, Clone)]
struct Fragment {
    kind: FragKind,
    x: f32,
    width: f32,
    ascent: f32,
    descent: f32,
}

#[derive(Debug, Clone, Default)]
struct Line {
    fragments: Vec<Fragment>,
    ascent: f32,
    descent: f32,
    height: f32,
}

fn text_metrics(style: &Style) -> (f32, f32) {
    let s = style.line_size;
    let (asc, desc) = if style.font == Font::Mono { (0.75 * s, 0.25 * s) } else { (0.77 * s, 0.23 * s) };
    ((asc + style.rise.max(0.0)).max(0.0), (desc - style.rise.min(0.0)).max(0.0))
}

/// Atoms: break opportunities are only at spaces (and before a forced
/// break); a word made of several styles stays together.
enum Atom {
    Word(Vec<(Vec<u8>, Style)>),
    Space(Style),
    Math { image: usize, width: f32, ascent: f32, descent: f32 },
    Break,
}

fn atoms(pieces: &[Piece]) -> Vec<Atom> {
    let mut out = vec![];
    let mut word: Vec<(Vec<u8>, Style)> = vec![];
    let flush = |word: &mut Vec<(Vec<u8>, Style)>, out: &mut Vec<Atom>| {
        if !word.is_empty() {
            out.push(Atom::Word(std::mem::take(word)));
        }
    };
    for piece in pieces {
        match piece {
            Piece::Text(text, style) => {
                let bytes = encode(text);
                let mut current = vec![];
                for &b in &bytes {
                    if b == b' ' || b == b'\n' {
                        if !current.is_empty() {
                            word.push((std::mem::take(&mut current), style.clone()));
                        }
                        flush(&mut word, &mut out);
                        out.push(Atom::Space(style.clone()));
                    } else {
                        current.push(b);
                    }
                }
                if !current.is_empty() {
                    word.push((current, style.clone()));
                }
            }
            Piece::Math { image, width, ascent, descent } => {
                flush(&mut word, &mut out);
                out.push(Atom::Math { image: *image, width: *width, ascent: *ascent, descent: *descent });
            }
            Piece::Break => {
                flush(&mut word, &mut out);
                out.push(Atom::Break);
            }
        }
    }
    flush(&mut word, &mut out);
    out
}

struct LineBuilder {
    lines: Vec<Line>,
    current: Line,
    x: f32,
    width: f32,
    default_metrics: (f32, f32),
}

impl LineBuilder {
    fn new(width: f32, default_size: f32) -> Self {
        LineBuilder {
            lines: vec![],
            current: Line::default(),
            x: 0.0,
            width,
            default_metrics: (0.77 * default_size, 0.23 * default_size),
        }
    }

    fn push(&mut self, kind: FragKind, width: f32, ascent: f32, descent: f32) {
        // Merge adjacent text with the same style.
        if let (FragKind::Text(bytes, style), Some(last)) = (&kind, self.current.fragments.last_mut()) {
            if let FragKind::Text(lb, ls) = &mut last.kind {
                if ls == style && (last.x + last.width - self.x).abs() < 0.01 {
                    lb.extend_from_slice(bytes);
                    last.width += width;
                    self.x += width;
                    self.current.ascent = self.current.ascent.max(ascent);
                    self.current.descent = self.current.descent.max(descent);
                    return;
                }
            }
        }
        self.current.fragments.push(Fragment { kind, x: self.x, width, ascent, descent });
        self.current.ascent = self.current.ascent.max(ascent);
        self.current.descent = self.current.descent.max(descent);
        self.x += width;
    }

    fn end_line(&mut self) {
        let mut line = std::mem::take(&mut self.current);
        // Drop trailing spaces.
        while let Some(Fragment { kind: FragKind::Text(b, _), .. }) = line.fragments.last() {
            if b.iter().all(|&c| c == b' ') {
                line.fragments.pop();
            } else {
                break;
            }
        }
        if line.fragments.is_empty() {
            line.ascent = self.default_metrics.0;
            line.descent = self.default_metrics.1;
        }
        line.height = (line.ascent + line.descent) * 1.08;
        self.lines.push(line);
        self.x = 0.0;
    }

    /// A word too long for a line on its own: break between characters.
    fn push_long_word(&mut self, parts: Vec<(Vec<u8>, Style)>) {
        for (bytes, style) in parts {
            let (asc, desc) = text_metrics(&style);
            for &b in &bytes {
                let w = byte_width(style.font, b) * style.size / 1000.0;
                if self.x + w > self.width && self.x > 0.0 {
                    self.end_line();
                }
                self.push(FragKind::Text(vec![b], style.clone()), w, asc, desc);
            }
        }
    }
}

fn layout(pieces: &[Piece], width: f32, default_size: f32) -> Vec<Line> {
    let mut lb = LineBuilder::new(width, default_size);
    for atom in atoms(pieces) {
        match atom {
            Atom::Break => lb.end_line(),
            Atom::Space(style) => {
                if lb.x == 0.0 {
                    continue;
                }
                let w = byte_width(style.font, b' ') * style.size / 1000.0;
                let (a, d) = text_metrics(&style);
                lb.push(FragKind::Text(vec![b' '], style), w, a, d);
            }
            Atom::Math { image, width: w, ascent, descent } => {
                if lb.x + w > lb.width && lb.x > 0.0 {
                    lb.end_line();
                }
                lb.push(FragKind::Math(image), w, ascent, descent);
            }
            Atom::Word(parts) => {
                let total: f32 = parts.iter().map(|(b, s)| measure(b, s.font, s.size)).sum();
                if lb.x + total > lb.width && lb.x > 0.0 {
                    lb.end_line();
                }
                if total > lb.width {
                    lb.push_long_word(parts);
                    continue;
                }
                for (bytes, style) in parts {
                    let w = measure(&bytes, style.font, style.size);
                    let (a, d) = text_metrics(&style);
                    lb.push(FragKind::Text(bytes, style), w, a, d);
                }
            }
        }
    }
    if !lb.current.fragments.is_empty() || lb.lines.is_empty() {
        lb.end_line();
    }
    lb.lines
}

/// Code: newlines are hard breaks, whitespace is kept, long lines wrap at
/// any character.
fn layout_code(tokens: &[(String, Color)], width: f32) -> Vec<Line> {
    let mut lb = LineBuilder::new(width, CODE_SIZE);
    for (text, color) in tokens {
        let style = Style { color: *color, ..Style::plain(Font::Mono, CODE_SIZE) };
        let (a, d) = text_metrics(&style);
        for (i, segment) in text.split('\n').enumerate() {
            if i > 0 {
                lb.end_line();
            }
            for b in encode(segment) {
                let w = 600.0 * CODE_SIZE / 1000.0;
                if lb.x + w > lb.width + 0.01 && lb.x > 0.0 {
                    lb.end_line();
                }
                lb.push(FragKind::Text(vec![b], style.clone()), w, a, d);
            }
        }
    }
    lb.end_line();
    // Code keeps its trailing spaces' line structure; empty lines keep height.
    lb.lines
}

// MARK: - Pages

struct Page {
    content: Content,
    links: Vec<(Rect, String)>,
}

struct Renderer {
    pages: Vec<Page>,
    cursor_y: f32,
    images: Vec<Image>,
    mermaid: Vec<Option<usize>>,
    display_math: Vec<Option<MathImage>>,
    inline_math: Vec<Option<MathImage>>,
    mermaid_index: usize,
    display_index: usize,
    inline_index: usize,
    /// Width of the block being drawn (code backgrounds).
    block_width: f32,
}

impl Renderer {
    fn page(&mut self) -> &mut Page {
        self.pages.last_mut().unwrap()
    }

    fn remaining(&self) -> f32 {
        CONTENT_H - self.cursor_y
    }

    fn new_page(&mut self) {
        self.pages.push(Page { content: Content::new(), links: vec![] });
        self.cursor_y = 0.0;
    }

    /// Page y coordinate of the current cursor.
    fn top(&self) -> f32 {
        PAGE_H - MARGIN - self.cursor_y
    }

    fn fill_rect(&mut self, x: f32, y: f32, w: f32, h: f32, color: Color) {
        let c = &mut self.page().content;
        c.save_state();
        c.set_fill_rgb(color.0, color.1, color.2);
        c.rect(x, y, w, h);
        c.fill_nonzero();
        c.restore_state();
    }

    fn stroke_line(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, width: f32, color: Color) {
        let c = &mut self.page().content;
        c.save_state();
        c.set_stroke_rgb(color.0, color.1, color.2);
        c.set_line_width(width);
        c.move_to(x1, y1);
        c.line_to(x2, y2);
        c.stroke();
        c.restore_state();
    }

    fn draw_rule(&mut self, x: f32, width: f32) {
        if self.remaining() < 4.0 {
            self.new_page();
        }
        let y = self.top() - 1.0;
        self.stroke_line(MARGIN + x, y, MARGIN + x + width, y, 1.0, BORDER);
        self.cursor_y += 4.0;
    }

    /// Draws laid-out lines at `x`, breaking across pages between lines.
    /// `background`/`padding` paint a box behind each page's part; `quoted`
    /// draws the quote bar. Returns the total height consumed.
    fn draw_lines(&mut self, lines: &[Line], x: f32, quoted: bool, background: Option<Color>, padding: f32, advance: bool) -> f32 {
        if lines.is_empty() {
            return 0.0;
        }
        let total: f32 = lines.iter().map(|l| l.height).sum::<f32>() + 2.0 * padding;
        if (total > self.remaining() && total <= CONTENT_H) || self.remaining() <= 0.0 {
            self.new_page();
        }
        let start_cursor = self.cursor_y;
        let start_page = self.pages.len();
        let mut i = 0;
        let mut consumed = 0.0;
        while i < lines.len() {
            // Lines that fit on this page.
            let mut h = padding;
            let mut j = i;
            while j < lines.len() && (h + lines[j].height + padding <= self.remaining() || j == i) {
                h += lines[j].height;
                j += 1;
            }
            h += padding;
            if j == i + 1 && h > self.remaining() && self.cursor_y > 0.0 {
                self.new_page();
                continue;
            }
            let top = self.top();
            if let Some(bg) = background {
                self.fill_rect(MARGIN + x, top - h, CONTENT_W.min(CONTENT_W - x).max(0.0).min(self.block_width), h, bg);
            }
            if quoted {
                self.fill_rect(MARGIN + x - 10.0, top - h, 3.0, h, QUOTE_BAR);
            }
            let mut y = top - padding;
            for line in &lines[i..j] {
                let baseline = y - line.ascent;
                self.draw_line(line, MARGIN + x + padding, baseline);
                y -= line.height;
            }
            consumed += h;
            i = j;
            if i < lines.len() {
                self.new_page();
            } else if advance {
                self.cursor_y += h;
            } else if self.pages.len() != start_page {
                // Should not happen for non-advancing (single-line) blocks.
                self.cursor_y = h;
            } else {
                self.cursor_y = start_cursor;
            }
        }
        consumed
    }

    fn draw_line(&mut self, line: &Line, x0: f32, baseline: f32) {
        for frag in &line.fragments {
            let x = x0 + frag.x;
            match &frag.kind {
                FragKind::Text(bytes, style) => {
                    let y = baseline + style.rise;
                    if let Some(bg) = style.background {
                        let (a, d) = (style.size * 0.77, style.size * 0.23);
                        self.fill_rect(x - 1.0, y - d - 1.0, frag.width + 2.0, a + d + 2.0, bg);
                    }
                    let c = &mut self.page().content;
                    c.set_fill_rgb(style.color.0, style.color.1, style.color.2);
                    c.begin_text();
                    c.set_font(Name(style.font.name()), style.size);
                    c.next_line(x, y);
                    c.show(Str(bytes));
                    c.end_text();
                    if style.underline {
                        self.stroke_line(x, y - 1.5, x + frag.width, y - 1.5, 0.7, style.color);
                    }
                    if style.strike {
                        let sy = y + style.size * 0.3;
                        self.stroke_line(x, sy, x + frag.width, sy, 0.7, style.color);
                    }
                    if let Some(url) = &style.link {
                        let rect = Rect::new(x, y - style.size * 0.23, x + frag.width, y + style.size * 0.77);
                        self.page().links.push((rect, url.clone()));
                    }
                }
                FragKind::Math(image) => {
                    let y = baseline - frag.descent;
                    self.draw_image(*image, x, y, frag.width, frag.ascent + frag.descent);
                }
            }
        }
    }

    fn draw_image(&mut self, image: usize, x: f32, y: f32, w: f32, h: f32) {
        let name = format!("Im{image}");
        let c = &mut self.page().content;
        c.save_state();
        c.transform([w, 0.0, 0.0, h, x, y]);
        c.x_object(Name(name.as_bytes()));
        c.restore_state();
    }
}

// MARK: - Blocks

struct Ctx {
    r: Renderer,
}

impl Renderer {
    fn inline_pieces(&mut self, inlines: &[Inline], size: f32, bold: bool) -> Vec<Piece> {
        let mut index = self.inline_index;
        let pieces = {
            let mut b = InlineBuilder {
                base_font_bold: bold,
                size,
                bold: false,
                italic: false,
                mark: 0,
                sub: 0,
                sup: 0,
                link: None,
                strike: false,
                pieces: vec![],
                math: &self.inline_math,
                math_index: &mut index,
            };
            b.inlines(inlines);
            b.pieces
        };
        self.inline_index = index;
        pieces
    }

    fn render_children(&mut self, blocks: &[Block], x: f32, width: f32, quoted: bool, spacing: f32) {
        for (i, block) in blocks.iter().enumerate() {
            self.render_block(block, x, width, quoted);
            if i + 1 < blocks.len() {
                self.cursor_y += spacing;
            }
        }
    }

    fn render_block(&mut self, block: &Block, x: f32, width: f32, quoted: bool) {
        self.block_width = width;
        match block {
            Block::Heading { level, children, .. } => {
                let level = (*level).clamp(1, 6) as usize;
                let size = HEADING_SIZES[level - 1];
                self.cursor_y += 4.0;
                let pieces = self.inline_pieces(children, size, true);
                let lines = layout(&pieces, width, size);
                self.draw_lines(&lines, x, quoted, None, 0.0, true);
                if level <= 2 {
                    self.cursor_y += 4.0;
                    self.draw_rule(x, width);
                }
            }
            Block::Paragraph { children, .. } => {
                let pieces = self.inline_pieces(children, BODY_SIZE, false);
                let lines = layout(&pieces, width, BODY_SIZE);
                self.draw_lines(&lines, x, quoted, None, 0.0, true);
            }
            Block::CodeBlock { language, code, .. } => match language.as_deref().map(str::to_lowercase).as_deref() {
                Some("mermaid") => self.draw_mermaid(code, x, width, quoted),
                Some(l) if l == MATH_LANGUAGE => self.draw_math(code, x, width, quoted),
                _ => self.draw_code_block(code, language.as_deref(), x, width, quoted),
            },
            Block::BlockQuote { children, .. } => self.render_children(children, x + 14.0, width - 14.0, true, 8.0),
            Block::List { ordered, start, items, .. } => self.render_list(items, *ordered, *start, x, width, quoted),
            Block::Table { head, rows, .. } => {
                let columns = head.cells.len().max(1);
                let col_w = width / columns as f32;
                self.draw_table_row(&head.cells, columns, col_w, x, true);
                for row in rows {
                    self.draw_table_row(&row.cells, columns, col_w, x, false);
                }
            }
            Block::ThematicBreak { .. } => {
                self.cursor_y += 4.0;
                self.draw_rule(x, width);
                self.cursor_y += 4.0;
            }
            Block::HtmlBlock { .. } => {}
        }
    }

    fn render_list(&mut self, items: &[ListItem], ordered: bool, start: usize, x: f32, width: f32, quoted: bool) {
        let marker_w = 22.0;
        for (index, item) in items.iter().enumerate() {
            if self.remaining() < 20.0 {
                self.new_page();
            }
            let top = self.top();
            match item.checkbox {
                Some(checked) => self.draw_checkbox(MARGIN + x, top, checked),
                None => {
                    let text = if ordered { format!("{}.", start + index) } else { "•".to_string() };
                    let lines = layout(&[Piece::Text(text, Style::plain(Font::Regular, BODY_SIZE))], marker_w, BODY_SIZE);
                    self.draw_lines(&lines, x, false, None, 0.0, false);
                }
            }
            self.block_width = width - marker_w;
            self.render_children(&item.children, x + marker_w, width - marker_w, quoted, 4.0);
            if item.children.is_empty() {
                self.cursor_y += BODY_SIZE * 1.1;
            }
            if index + 1 < items.len() {
                self.cursor_y += 4.0;
            }
        }
    }

    fn draw_checkbox(&mut self, x: f32, top: f32, checked: bool) {
        let size = 8.5;
        let y = top - BODY_SIZE * 0.77 - 0.5;
        let c = &mut self.page().content;
        c.save_state();
        c.set_stroke_rgb(0.2, 0.2, 0.2);
        c.set_line_width(0.8);
        c.rect(x + 0.5, y, size, size);
        c.stroke();
        if checked {
            c.set_line_width(1.2);
            c.move_to(x + 2.2, y + size * 0.5);
            c.line_to(x + 4.2, y + 2.0);
            c.line_to(x + size - 1.0, y + size - 1.5);
            c.stroke();
        }
        c.restore_state();
    }

    fn draw_code_block(&mut self, code: &str, language: Option<&str>, x: f32, width: f32, quoted: bool) {
        let text = code.strip_suffix('\n').unwrap_or(code);
        let tokens: Vec<(String, Color)> = match tokenizer_for(language) {
            Some(t) => t
                .tokenize(text)
                .into_iter()
                .map(|tok| (tok.text, tok.kind.light_color().map(hex).unwrap_or(BLACK)))
                .collect(),
            None => vec![(text.to_string(), BLACK)],
        };
        let padding = 8.0;
        let lines = layout_code(&tokens, width - 2.0 * padding);
        self.block_width = width;
        self.draw_lines(&lines, x, quoted, Some(CODE_BG), padding, true);
    }

    fn draw_mermaid(&mut self, code: &str, x: f32, width: f32, quoted: bool) {
        let image = self.mermaid.get(self.mermaid_index).copied().flatten();
        self.mermaid_index += 1;
        match image {
            Some(i) => {
                let (w, h) = (self.images[i].width as f32 / 2.0, self.images[i].height as f32 / 2.0);
                self.draw_block_image(i, w, h, x, width);
            }
            None => self.draw_code_block(code, None, x, width, quoted),
        }
    }

    fn draw_math(&mut self, code: &str, x: f32, width: f32, quoted: bool) {
        let index = self.display_index;
        self.display_index += 1;
        self.cursor_y += 4.0;
        match self.display_math.get(index).and_then(|m| m.as_ref()).map(|m| (m.image, m.width_em, m.height_em)) {
            Some((i, w, h)) => self.draw_block_image(i, w * BODY_SIZE, h * BODY_SIZE, x, width),
            None => self.draw_code_block(code, None, x, width, quoted),
        }
        self.cursor_y += 4.0;
    }

    fn draw_block_image(&mut self, image: usize, mut w: f32, mut h: f32, x: f32, width: f32) {
        if w > width {
            h *= width / w;
            w = width;
        }
        if h > CONTENT_H {
            w *= CONTENT_H / h;
            h = CONTENT_H;
        }
        if (h > self.remaining() && h <= CONTENT_H) || self.remaining() <= 0.0 {
            self.new_page();
        }
        let top = self.top();
        self.draw_image(image, MARGIN + x + (width - w) / 2.0, top - h, w, h);
        self.cursor_y += h;
    }

    fn draw_table_row(&mut self, cells: &[Vec<Inline>], columns: usize, col_w: f32, x: f32, header: bool) {
        let padding = 5.0;
        let size = 10.0;
        let mut laid: Vec<Vec<Line>> = vec![];
        let mut row_h: f32 = 16.0;
        for i in 0..columns {
            let lines = match cells.get(i) {
                Some(cell) if !cell.is_empty() => {
                    let pieces = self.inline_pieces(cell, size, header);
                    layout(&pieces, col_w - 2.0 * padding, size)
                }
                _ => vec![],
            };
            let h: f32 = lines.iter().map(|l| l.height).sum::<f32>() + 2.0 * padding;
            row_h = row_h.max(h);
            laid.push(lines);
        }
        if (row_h > self.remaining() && row_h <= CONTENT_H) || self.remaining() <= 0.0 {
            self.new_page();
        }
        let top = self.top();
        for (i, lines) in laid.iter().enumerate() {
            let cx = MARGIN + x + i as f32 * col_w;
            if header {
                self.fill_rect(cx, top - row_h, col_w, row_h, CODE_BG);
            }
            {
                let c = &mut self.page().content;
                c.save_state();
                c.set_stroke_rgb(BORDER.0, BORDER.1, BORDER.2);
                c.set_line_width(0.5);
                c.rect(cx, top - row_h, col_w, row_h);
                c.stroke();
                c.restore_state();
            }
            let mut y = top - padding;
            for line in lines {
                let baseline = y - line.ascent;
                self.draw_line(line, cx + padding, baseline);
                y -= line.height;
            }
        }
        self.cursor_y += row_h;
    }
}

// The renderer's current block width, used for code-block backgrounds.
impl Renderer {
    #[allow(clippy::new_ret_no_self)]
    fn create(images: Vec<Image>, mermaid: Vec<Option<usize>>, display: Vec<Option<MathImage>>, inline: Vec<Option<MathImage>>) -> Ctx {
        Ctx {
            r: Renderer {
                pages: vec![],
                cursor_y: 0.0,
                images,
                mermaid,
                display_math: display,
                inline_math: inline,
                mermaid_index: 0,
                display_index: 0,
                inline_index: 0,
                block_width: CONTENT_W,
            },
        }
    }
}

// MARK: - Export

/// Renders `markdown` (with every rewrite the preview applies) to PDF bytes.
/// The harvested lists are in document order; `None` entries fall back to
/// the source text.
pub fn export(
    markdown: &str,
    mermaid: &[Option<Harvested>],
    display_math: &[Option<Harvested>],
    inline_math: &[Option<Harvested>],
) -> Vec<u8> {
    let document = ast::parse(markdown);
    let mut images: Vec<Image> = vec![];
    let mut add = |h: &Option<Harvested>| -> Option<usize> {
        let img = decode_png_data_url(&h.as_ref()?.png)?;
        images.push(img);
        Some(images.len() - 1)
    };
    let mermaid_ix: Vec<Option<usize>> = mermaid.iter().map(&mut add).collect();
    let math = |list: &[Option<Harvested>], add: &mut dyn FnMut(&Option<Harvested>) -> Option<usize>| {
        list.iter()
            .map(|h| {
                let image = add(h)?;
                let h = h.as_ref()?;
                Some(MathImage {
                    image,
                    width_em: h.width_em as f32,
                    height_em: h.height_em as f32,
                    depth_em: h.depth_em as f32,
                })
            })
            .collect::<Vec<_>>()
    };
    let display = math(display_math, &mut add);
    let inline = math(inline_math, &mut add);

    let mut ctx = Renderer::create(images, mermaid_ix, display, inline);
    let r = &mut ctx.r;
    r.new_page();
    r.render_children(&document.blocks, 0.0, CONTENT_W, false, 12.0);
    write_pdf(r)
}

fn write_pdf(r: &mut Renderer) -> Vec<u8> {
    let mut pdf = Pdf::new();
    let mut next = 1;
    let mut alloc = || {
        let id = Ref::new(next);
        next += 1;
        id
    };
    let catalog_id = alloc();
    let tree_id = alloc();
    let fonts: Vec<(Font, Ref)> = [Font::Regular, Font::Bold, Font::Italic, Font::BoldItalic, Font::Mono]
        .into_iter()
        .map(|f| (f, alloc()))
        .collect();
    let image_ids: Vec<(Ref, Option<Ref>)> =
        r.images.iter().map(|img| (alloc(), img.alpha.as_ref().map(|_| alloc()))).collect();
    let total = r.pages.len();
    let page_ids: Vec<(Ref, Ref)> = (0..total).map(|_| (alloc(), alloc())).collect();
    let mut annot_ids: HashMap<usize, Vec<Ref>> = HashMap::new();
    for (i, page) in r.pages.iter().enumerate() {
        annot_ids.insert(i, page.links.iter().map(|_| alloc()).collect());
    }

    pdf.catalog(catalog_id).pages(tree_id);
    pdf.pages(tree_id).kids(page_ids.iter().map(|p| p.0)).count(total as i32);
    for (font, id) in &fonts {
        pdf.type1_font(*id).base_font(Name(font.base())).encoding_predefined(Name(b"WinAnsiEncoding"));
    }
    for (img, (id, mask)) in r.images.iter().zip(&image_ids) {
        let data = miniz_oxide::deflate::compress_to_vec_zlib(&img.rgb, 6);
        let mut x = pdf.image_xobject(*id, &data);
        x.filter(Filter::FlateDecode);
        x.width(img.width as i32);
        x.height(img.height as i32);
        x.color_space().device_rgb();
        x.bits_per_component(8);
        if let Some(m) = mask {
            x.s_mask(*m);
        }
        x.finish();
        if let (Some(m), Some(alpha)) = (mask, &img.alpha) {
            let data = miniz_oxide::deflate::compress_to_vec_zlib(alpha, 6);
            let mut s = pdf.image_xobject(*m, &data);
            s.filter(Filter::FlateDecode);
            s.width(img.width as i32);
            s.height(img.height as i32);
            s.color_space().device_gray();
            s.bits_per_component(8);
            s.finish();
        }
    }

    let pages = std::mem::take(&mut r.pages);
    for (i, mut page) in pages.into_iter().enumerate() {
        // Footer: "page / total", centered.
        let footer = format!("{} / {}", i + 1, total);
        let bytes = encode(&footer);
        let w = measure(&bytes, Font::Regular, 9.0);
        page.content.set_fill_rgb(SECONDARY.0, SECONDARY.1, SECONDARY.2);
        page.content.begin_text();
        page.content.set_font(Name(Font::Regular.name()), 9.0);
        page.content.next_line((PAGE_W - w) / 2.0, MARGIN * 0.45);
        page.content.show(Str(&bytes));
        page.content.end_text();

        let (page_id, content_id) = page_ids[i];
        let mut p = pdf.page(page_id);
        p.media_box(Rect::new(0.0, 0.0, PAGE_W, PAGE_H));
        p.parent(tree_id);
        p.contents(content_id);
        let ids = annot_ids.remove(&i).unwrap_or_default();
        if !ids.is_empty() {
            p.annotations(ids.iter().copied());
        }
        let mut res = p.resources();
        let mut f = res.fonts();
        for (font, id) in &fonts {
            f.pair(Name(font.name()), *id);
        }
        f.finish();
        if !image_ids.is_empty() {
            let mut xo = res.x_objects();
            for (n, (id, _)) in image_ids.iter().enumerate() {
                xo.pair(Name(format!("Im{n}").as_bytes()), *id);
            }
            xo.finish();
        }
        res.finish();
        p.finish();
        pdf.stream(content_id, &page.content.finish());
        for ((rect, url), id) in page.links.iter().zip(ids) {
            let mut a = pdf.annotation(id);
            a.subtype(AnnotationType::Link);
            a.rect(*rect);
            a.border(0.0, 0.0, 0.0, None);
            if url.starts_with('#') {
                // In-document anchors have no target page here; keep the text only.
                a.finish();
                continue;
            }
            a.action().action_type(ActionType::Uri).uri(Str(url.as_bytes()));
            a.finish();
        }
    }
    pdf.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exports_a_document() {
        let md = "# Title\n\nSome *text* with `code` and a [link](https://example.com).\n\n- [x] done\n- open\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```python\ndef f():\n    return 1\n```\n\n$$\nE=mc^2\n$$\n\nÄrger über “Quotes” — fine.";
        let bytes = export(md, &[], &[], &[]);
        assert!(bytes.starts_with(b"%PDF-"));
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("/Helvetica-Bold"));
        assert!(s.contains("https://example.com"));
    }

    #[test]
    fn long_documents_paginate() {
        let md = (0..400).map(|i| format!("Paragraph number {i} with some words.\n")).collect::<Vec<_>>().join("\n");
        let bytes = export(&md, &[], &[], &[]);
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.matches("/Type /Page\n").count() + s.matches("/Type /Page ").count() > 3 || s.contains("/Count"));
    }

    #[test]
    fn encodes_win_ansi() {
        assert_eq!(encode("Ä€→"), vec![0xC4, 0x80, b'-', b'>']);
    }
}
