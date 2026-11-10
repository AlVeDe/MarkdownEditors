//! The document model every renderer works on.
//!
//! Parsing goes through comrak (CommonMark + GFM tables, strikethrough, task
//! lists and autolinks) and is converted into this small owned tree, which
//! mirrors the node set the renderers care about. The single entry point
//! [`parse_mapped`] runs the source rewrites first (front matter, footnotes,
//! `$$` blocks) and splits inline `$ … $` formulas out of the text runs, so
//! the preview, the PDF and the outline can never disagree.

use comrak::nodes::{AstNode, ListType, NodeValue, TableAlignment};
use comrak::{parse_document, Arena, Options};

use super::inline_math;
use super::math_blocks::{self, LineMap};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alignment {
    None,
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Inline {
    Text(String),
    Emphasis(Vec<Inline>),
    Strong(Vec<Inline>),
    Strikethrough(Vec<Inline>),
    Code(String),
    /// An inline `$ … $` formula (TeX without the delimiters).
    Math(String),
    Html(String),
    Link { destination: String, children: Vec<Inline> },
    Image { source: String, children: Vec<Inline> },
    SoftBreak,
    LineBreak,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ListItem {
    pub line: usize,
    /// `Some(true)` for `[x]`, `Some(false)` for `[ ]`, `None` without a box.
    pub checkbox: Option<bool>,
    pub children: Vec<Block>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TableRow {
    pub line: usize,
    pub cells: Vec<Vec<Inline>>,
}

/// Block nodes. `line` / `end_line` are 1-based lines of the *parsed*
/// (preprocessed) text; map them through the `LineMap` for editor lines.
#[derive(Debug, Clone, PartialEq)]
pub enum Block {
    Heading { level: u8, line: usize, children: Vec<Inline> },
    Paragraph { line: usize, children: Vec<Inline> },
    BlockQuote { line: usize, children: Vec<Block> },
    CodeBlock { language: Option<String>, code: String, line: usize, end_line: usize },
    ThematicBreak { line: usize },
    HtmlBlock { raw: String },
    List { ordered: bool, start: usize, line: usize, items: Vec<ListItem> },
    Table { line: usize, alignments: Vec<Alignment>, head: TableRow, rows: Vec<TableRow> },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Document {
    pub blocks: Vec<Block>,
}

pub fn options() -> Options<'static> {
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.strikethrough = true;
    options.extension.tasklist = true;
    options.extension.autolink = true;
    options.render.r#unsafe = true;
    options
}

/// Parses `markdown` with every rewrite applied.
pub fn parse(markdown: &str) -> Document {
    parse_mapped(markdown).0
}

/// Like [`parse`], but also returns the map from parsed lines back to the
/// author's lines.
pub fn parse_mapped(markdown: &str) -> (Document, LineMap) {
    let (text, map) = math_blocks::preprocess_mapped(markdown);
    (parse_plain(&text), map)
}

/// Parses already-preprocessed text (no `$$` / footnote rewrite).
pub fn parse_plain(text: &str) -> Document {
    let arena = Arena::new();
    let root = parse_document(&arena, text, &options());
    Document { blocks: blocks_of(root) }
}

fn blocks_of<'a>(node: &'a AstNode<'a>) -> Vec<Block> {
    node.children().filter_map(block).collect()
}

fn block<'a>(node: &'a AstNode<'a>) -> Option<Block> {
    let data = node.data.borrow();
    let line = data.sourcepos.start.line;
    let end_line = data.sourcepos.end.line;
    Some(match &data.value {
        NodeValue::Heading(h) => Block::Heading { level: h.level, line, children: inlines_of(node) },
        NodeValue::Paragraph => Block::Paragraph { line, children: inlines_of(node) },
        NodeValue::BlockQuote | NodeValue::MultilineBlockQuote(_) => {
            Block::BlockQuote { line, children: blocks_of(node) }
        }
        NodeValue::CodeBlock(cb) => {
            let info = cb.info.trim();
            Block::CodeBlock {
                language: (!info.is_empty()).then(|| info.to_string()),
                code: cb.literal.clone(),
                line,
                end_line,
            }
        }
        NodeValue::ThematicBreak => Block::ThematicBreak { line },
        NodeValue::HtmlBlock(h) => Block::HtmlBlock { raw: h.literal.clone() },
        NodeValue::List(list) => {
            let items = node
                .children()
                .map(|item| {
                    let d = item.data.borrow();
                    let checkbox = match &d.value {
                        NodeValue::TaskItem(t) => Some(t.symbol.is_some()),
                        _ => None,
                    };
                    ListItem { line: d.sourcepos.start.line, checkbox, children: blocks_of(item) }
                })
                .collect();
            Block::List {
                ordered: list.list_type == ListType::Ordered,
                start: list.start,
                line,
                items,
            }
        }
        NodeValue::Table(table) => {
            let alignments = table
                .alignments
                .iter()
                .map(|a| match a {
                    TableAlignment::Left => Alignment::Left,
                    TableAlignment::Center => Alignment::Center,
                    TableAlignment::Right => Alignment::Right,
                    TableAlignment::None => Alignment::None,
                })
                .collect();
            let mut head = TableRow { line, cells: vec![] };
            let mut rows = vec![];
            for row in node.children() {
                let rd = row.data.borrow();
                let is_head = matches!(rd.value, NodeValue::TableRow(true));
                let r = TableRow { line: rd.sourcepos.start.line, cells: row.children().map(inlines_of).collect() };
                if is_head {
                    head = r;
                } else {
                    rows.push(r);
                }
            }
            Block::Table { line, alignments, head, rows }
        }
        NodeValue::FootnoteDefinition(_) | NodeValue::FrontMatter(_) => return None,
        NodeValue::Document => return None,
        _ => {
            // Anything else block-like with inline content renders as a paragraph.
            let children = inlines_of(node);
            if children.is_empty() {
                return None;
            }
            Block::Paragraph { line, children }
        }
    })
}

/// Converts a node's inline children, merging adjacent text runs and
/// splitting inline formulas out of them.
fn inlines_of<'a>(node: &'a AstNode<'a>) -> Vec<Inline> {
    let mut out: Vec<Inline> = Vec::new();
    let mut text = String::new();
    let flush = |text: &mut String, out: &mut Vec<Inline>| {
        if text.is_empty() {
            return;
        }
        for piece in inline_math::split(text) {
            match piece.tex {
                Some(tex) => out.push(Inline::Math(tex)),
                None => out.push(Inline::Text(piece.text)),
            }
        }
        text.clear();
    };
    for child in node.children() {
        let data = child.data.borrow();
        if let NodeValue::Text(t) = &data.value {
            text.push_str(t);
            continue;
        }
        flush(&mut text, &mut out);
        let inline = match &data.value {
            NodeValue::Emph => Inline::Emphasis(inlines_of(child)),
            NodeValue::Strong => Inline::Strong(inlines_of(child)),
            NodeValue::Strikethrough => Inline::Strikethrough(inlines_of(child)),
            NodeValue::Code(code) => Inline::Code(code.literal.clone()),
            NodeValue::HtmlInline(html) => Inline::Html(html.clone()),
            NodeValue::Link(link) => Inline::Link { destination: link.url.clone(), children: inlines_of(child) },
            NodeValue::Image(link) => Inline::Image { source: link.url.clone(), children: inlines_of(child) },
            NodeValue::SoftBreak => Inline::SoftBreak,
            NodeValue::LineBreak => Inline::LineBreak,
            _ => {
                // Unknown inline containers: keep their content.
                out.extend(inlines_of(child));
                continue;
            }
        };
        out.push(inline);
    }
    flush(&mut text, &mut out);
    out
}

/// Plain text of inline content (alt text, outline titles, anchors).
pub fn plain_text(inlines: &[Inline]) -> String {
    let mut s = String::new();
    for inline in inlines {
        match inline {
            Inline::Text(t) => s.push_str(t),
            Inline::Code(c) => s.push_str(c),
            Inline::Math(t) => {
                s.push('$');
                s.push_str(t);
                s.push('$');
            }
            Inline::Emphasis(c) | Inline::Strong(c) | Inline::Strikethrough(c) => s.push_str(&plain_text(c)),
            Inline::Link { children, .. } | Inline::Image { children, .. } => s.push_str(&plain_text(children)),
            Inline::SoftBreak | Inline::LineBreak => s.push(' '),
            Inline::Html(_) => {}
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_inline_math() {
        let doc = parse("sei $x \\in R$ die");
        let Block::Paragraph { children, .. } = &doc.blocks[0] else { panic!() };
        assert_eq!(children[1], Inline::Math("x \\in R".into()));
    }

    #[test]
    fn code_span_is_not_math() {
        let doc = parse("`$PATH$`");
        let Block::Paragraph { children, .. } = &doc.blocks[0] else { panic!() };
        assert_eq!(children[0], Inline::Code("$PATH$".into()));
    }

    #[test]
    fn task_items() {
        let doc = parse("- [x] a\n- [ ] b\n- c");
        let Block::List { items, .. } = &doc.blocks[0] else { panic!() };
        assert_eq!(items.iter().map(|i| i.checkbox).collect::<Vec<_>>(), vec![Some(true), Some(false), None]);
    }
}
