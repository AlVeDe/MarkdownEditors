//! Automatic renumbering of ordered lists: after an item is inserted,
//! deleted, moved or re-indented, the numbers of its list become consecutive
//! again.
//!
//! The list structure is a deliberately small approximation of CommonMark:
//! items of one list share quote depth, indentation and delimiter; blank
//! lines stay inside (loose lists); deeper lines are item content (nested
//! lists are lists of their own); a shallower line, a heading, a thematic
//! break, a fence, another kind of list marker at the same level or a
//! paragraph after a blank line end the list. Lines inside fenced code are
//! never items.

use super::prefix::is_fence_line;
use super::{line_index_of, u16len, Editor};
use crate::text::Range;

/// One number to replace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NumberEdit {
    pub line: usize,
    /// UTF-16 range of the digits within the line.
    pub range: Range,
    pub replacement: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub line: usize,
    pub number: usize,
    pub number_range: Range,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub quote_depth: usize,
    pub indent: usize,
    pub delimiter: char,
    pub items: Vec<Item>,
    pub first_line: usize,
    pub last_line: usize,
    pub saw_blank: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Blank,
    Code,
    Ordered { number: usize, delimiter: char, number_range: Range },
    Bullet,
    Heading,
    ThematicBreak,
    Text,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub quote_depth: usize,
    pub indent: usize,
    pub kind: Kind,
}

/// The digits to rewrite so that the lists at `line` (and the lists nested
/// inside them) count up from their start number.
pub fn edits(lines: &[String], line: usize, start_number: Option<usize>, restarts_nested: bool) -> Vec<NumberEdit> {
    let blocks = parse(lines);
    let touching: Vec<usize> = (0..blocks.len())
        .filter(|&i| blocks[i].first_line as isize - 1 <= line as isize && line <= blocks[i].last_line + 1)
        .collect();
    if touching.is_empty() {
        return vec![];
    }
    let anchor = innermost_block(&blocks, line);
    let affected: Vec<usize> = (0..blocks.len())
        .filter(|&i| {
            touching
                .iter()
                .any(|&t| blocks[t].first_line <= blocks[i].first_line && blocks[i].last_line <= blocks[t].last_line)
        })
        .collect();
    let mut out = vec![];
    for index in affected {
        let block = &blocks[index];
        if block.items.iter().all(|i| i.number == 1) {
            continue;
        }
        let mut start = block.items[0].number;
        if restarts_nested && block.indent > 0 && touching.contains(&index) {
            start = 1;
        } else if Some(index) == anchor {
            if let Some(s) = start_number {
                start = s;
            }
        }
        for (offset, item) in block.items.iter().enumerate() {
            if item.number != start + offset {
                out.push(NumberEdit { line: item.line, range: item.number_range, replacement: (start + offset).to_string() });
            }
        }
    }
    out.sort_by_key(|e| (e.line, e.range.location));
    out
}

pub fn start_number(lines: &[String], line: usize) -> Option<usize> {
    let blocks = parse(lines);
    innermost_block(&blocks, line).map(|i| blocks[i].items[0].number)
}

pub fn is_all_ones_list(lines: &[String], line: usize) -> bool {
    let blocks = parse(lines);
    let Some(i) = innermost_block(&blocks, line) else { return false };
    let items = &blocks[i].items;
    items.len() >= 2 && items.iter().all(|i| i.number == 1)
}

pub fn is_ordered_item(line: &str) -> bool {
    matches!(classify(line).kind, Kind::Ordered { .. })
}

pub fn parse(lines: &[String]) -> Vec<Block> {
    let mut blocks: Vec<Block> = vec![];
    let mut open: Vec<usize> = vec![];
    let mut in_fence = false;
    let mut fence_indent = 0;
    for (index, text) in lines.iter().enumerate() {
        let line = if is_fence_line(text) {
            if !in_fence {
                fence_indent = classify(text).indent;
            }
            in_fence = !in_fence;
            Line { quote_depth: 0, indent: fence_indent, kind: Kind::Code }
        } else if in_fence {
            Line { quote_depth: 0, indent: fence_indent, kind: Kind::Code }
        } else {
            classify(text)
        };
        if line.kind == Kind::Blank {
            for &b in &open {
                blocks[b].saw_blank = true;
            }
            continue;
        }
        open.retain(|&b| blocks[b].quote_depth == line.quote_depth);
        match &line.kind {
            Kind::Ordered { number, delimiter, number_range } => {
                open.retain(|&b| blocks[b].indent <= line.indent);
                let item = Item { line: index, number: *number, number_range: *number_range };
                let last = open.last().copied();
                if let Some(last) = last.filter(|&l| blocks[l].indent == line.indent && blocks[l].delimiter == *delimiter) {
                    blocks[last].items.push(item);
                } else {
                    if let Some(last) = last.filter(|&l| blocks[l].indent == line.indent) {
                        let _ = last;
                        open.pop();
                    }
                    blocks.push(Block {
                        quote_depth: line.quote_depth,
                        indent: line.indent,
                        delimiter: *delimiter,
                        items: vec![item],
                        first_line: index,
                        last_line: index,
                        saw_blank: false,
                    });
                    open.push(blocks.len() - 1);
                }
            }
            Kind::Bullet | Kind::Heading | Kind::ThematicBreak | Kind::Code => {
                open.retain(|&b| blocks[b].indent < line.indent);
            }
            Kind::Text => {
                open.retain(|&b| !(blocks[b].indent > line.indent || (blocks[b].indent == line.indent && blocks[b].saw_blank)));
            }
            Kind::Blank => {}
        }
        for &b in &open {
            blocks[b].saw_blank = false;
            blocks[b].last_line = index;
        }
    }
    blocks
}

fn innermost_block(blocks: &[Block], line: usize) -> Option<usize> {
    (0..blocks.len())
        .filter(|&i| blocks[i].first_line <= line && line <= blocks[i].last_line)
        .max_by_key(|&i| (blocks[i].quote_depth, blocks[i].indent))
}

/// Classifies one line outside fenced code (UTF-16 based).
pub fn classify(text: &str) -> Line {
    let units: Vec<u16> = text.encode_utf16().collect();
    let (space, tab) = (0x20u16, 0x09u16);
    let mut index = 0;
    let skip_indent = |index: &mut usize| {
        let mut width = 0;
        while *index < units.len() && (units[*index] == space || units[*index] == tab) {
            width = if units[*index] == tab { width + 4 - width % 4 } else { width + 1 };
            *index += 1;
        }
        width
    };
    let mut indent = skip_indent(&mut index);
    let mut quote_depth = 0;
    while index < units.len() && units[index] == 0x3E {
        quote_depth += 1;
        index += 1;
        if index < units.len() && (units[index] == space || units[index] == tab) {
            index += 1;
        }
        let mut look = index;
        while look < units.len() && units[look] == space {
            look += 1;
        }
        if look < units.len() && units[look] == 0x3E {
            index = look;
        }
    }
    if quote_depth > 0 {
        indent = skip_indent(&mut index);
    }
    let mut end = units.len();
    while end > index && (units[end - 1] == space || units[end - 1] == tab || units[end - 1] == 0x0D) {
        end -= 1;
    }
    let rest = &units[index..end];
    let Some(&first) = rest.first() else { return Line { quote_depth, indent, kind: Kind::Blank } };
    let is_space_or_end = |p: usize| p >= units.len() || units[p] == space || units[p] == tab || units[p] == 0x0D;

    if first == 0x23 {
        let hashes = rest.iter().take_while(|&&u| u == 0x23).count();
        if hashes <= 6 && is_space_or_end(index + hashes) {
            return Line { quote_depth, indent, kind: Kind::Heading };
        }
    }
    if first == 0x2D || first == 0x2A || first == 0x5F {
        let marks: Vec<u16> = rest.iter().copied().filter(|&u| u != space && u != tab).collect();
        if marks.len() >= 3 && marks.iter().all(|&m| m == first) {
            return Line { quote_depth, indent, kind: Kind::ThematicBreak };
        }
        if first != 0x5F && is_space_or_end(index + 1) {
            return Line { quote_depth, indent, kind: Kind::Bullet };
        }
    }
    if first == 0x2B && is_space_or_end(index + 1) {
        return Line { quote_depth, indent, kind: Kind::Bullet };
    }
    let digits = rest.iter().take_while(|&&u| (0x30..=0x39).contains(&u)).count();
    if (1..=9).contains(&digits) && index + digits < units.len() {
        let delimiter = units[index + digits];
        if (delimiter == 0x2E || delimiter == 0x29) && is_space_or_end(index + digits + 1) {
            let number = String::from_utf16_lossy(&units[index..index + digits]).parse().unwrap_or(0);
            return Line {
                quote_depth,
                indent,
                kind: Kind::Ordered {
                    number,
                    delimiter: if delimiter == 0x2E { '.' } else { ')' },
                    number_range: Range::new(index, digits),
                },
            };
        }
    }
    Line { quote_depth, indent, kind: Kind::Text }
}

/// Where `selection` ends up after `range` is replaced by text of `length`.
pub fn map_selection(selection: Range, range: Range, length: usize) -> Range {
    let map = |p: usize| {
        if p <= range.location {
            p
        } else if p >= range.end() {
            p + length - range.length
        } else {
            range.location + (p - range.location).min(length)
        }
    };
    let start = map(selection.location);
    let end = map(selection.end());
    Range::new(start, end.saturating_sub(start))
}

impl Editor<'_> {
    /// Makes the ordered list(s) at `location` count up from their start
    /// number again; only the digits that change are replaced and the
    /// selection stays on the same characters. Returns true when a number
    /// changed.
    pub fn renumber_ordered_list(&mut self, location: usize, start_number: Option<usize>, restarts_nested: bool) -> bool {
        let (lines, starts) = self.line_table();
        let edits = edits(&lines, line_index_of(location, &starts), start_number, restarts_nested);
        if edits.is_empty() {
            return false;
        }
        let mut selection = self.selection;
        for e in edits.iter().rev() {
            let range = Range::new(starts[e.line] + e.range.location, e.range.length);
            self.text.replace(range, &e.replacement);
            selection = map_selection(selection, range, u16len(&e.replacement));
        }
        self.selection = selection;
        true
    }

    /// Format ▸ Renumber List, regardless of the automatic setting.
    pub fn renumber_ordered_list_at_selection(&mut self) {
        let location = self.selection.location;
        self.renumber_ordered_list(location, None, false);
    }

    /// Runs a list-changing `edit` and, when automatic renumbering is on and
    /// an ordered item is involved, renumbers the list at the caret in the
    /// same command.
    pub fn perform_list_edit<R>(
        &mut self,
        affecting: Range,
        keeps_start: bool,
        restarts_nested: bool,
        edit: impl FnOnce(&mut Self) -> R,
    ) -> R {
        if !self.settings.renumbers_lists {
            return edit(self);
        }
        let block = self.line_block(affecting);
        let was_list = self.lines_in(block).0.iter().any(|l| is_ordered_item(l));
        let mut start = None;
        if keeps_start {
            let (lines, starts) = self.line_table();
            start = start_number(&lines, line_index_of(self.selection.location, &starts));
        }
        let result = edit(self);
        let caret_block = self.line_block(self.selection);
        let caret_lines = self.lines_in(caret_block).0;
        if was_list || caret_lines.iter().any(|l| is_ordered_item(l)) {
            let location = self.selection.location;
            self.renumber_ordered_list(location, start, restarts_nested);
        }
        result
    }

    pub fn continues_all_ones_list(&self, location: usize) -> bool {
        if !self.settings.renumbers_lists {
            return false;
        }
        let (lines, starts) = self.line_table();
        is_all_ones_list(&lines, line_index_of(location, &starts))
    }
}
