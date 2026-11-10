//! Finds the LaTeX formula around a caret position by scanning the source.
//!
//! Mirrors the delimiter rules the renderers use — display math is a line
//! starting with `$$` (code fences are verbatim; ` ```math ` fences are
//! formulas) and inline math follows Pandoc-style rules — with two
//! deliberate differences that only make sense while typing:
//!
//! - an inline formula need not be structurally valid LaTeX: half-typed TeX
//!   is what the caret preview should show, error included;
//! - a `$$` block without a closing `$$` extends to the next blank line.

use serde::Serialize;

use crate::text::{Range, Text};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MathFormula {
    /// The TeX between the delimiters.
    pub content_range: Range,
    /// Including delimiters (or fence lines).
    pub range: Range,
    pub is_display: bool,
    pub is_terminated: bool,
}

impl MathFormula {
    pub fn tex(&self, text: &Text) -> String {
        text.substring(self.content_range)
    }
}

const DOLLAR: u16 = b'$' as u16;
const BACKSLASH: u16 = b'\\' as u16;
const BACKTICK: u16 = b'`' as u16;
const SPACE: u16 = b' ' as u16;
const TAB: u16 = b'\t' as u16;

#[derive(Clone, Copy)]
struct Line {
    start: usize,
    contents_end: usize,
    end: usize,
}

fn line_at(text: &Text, location: usize) -> Line {
    let (start, contents_end, end) = text.line_bounds(location);
    Line { start, contents_end, end }
}

fn lines_after(text: &Text, previous: Line) -> impl Iterator<Item = Line> + '_ {
    let mut cursor = previous.end;
    std::iter::from_fn(move || {
        if cursor >= text.len() {
            return None;
        }
        let next = line_at(text, cursor);
        if next.end <= cursor {
            return None;
        }
        cursor = next.end;
        Some(next)
    })
}

fn leading_spaces(text: &Text, line: Line) -> usize {
    let mut i = line.start;
    while i < line.contents_end && text.at(i) == SPACE {
        i += 1;
    }
    i - line.start
}

fn trimmed(text: &Text, line: Line) -> String {
    text.substring(Range::new(line.start, line.contents_end - line.start))
        .trim_matches(|c| c == ' ' || c == '\t')
        .to_string()
}

fn trimmed_end(text: &Text, line: Line, floor: usize) -> usize {
    let mut end = line.contents_end;
    while end > floor && (text.at(end - 1) == SPACE || text.at(end - 1) == TAB) {
        end -= 1;
    }
    end
}

enum BlockResult {
    Formula(MathFormula),
    None,
    Prose(Range),
}

struct Block {
    formula: Option<MathFormula>,
    next_line_start: usize,
}

/// The formula containing `location`.
pub fn formula_at(text: &Text, location: usize) -> Option<MathFormula> {
    if location > text.len() {
        return None;
    }
    match block_scan(text, location) {
        BlockResult::Formula(f) => Some(f),
        BlockResult::None => None,
        BlockResult::Prose(line) => inline_formula(text, location, line),
    }
}

fn block_scan(text: &Text, location: usize) -> BlockResult {
    let mut start = 0;
    loop {
        let current = line_at(text, start);
        if let Some(block) = fenced_block(text, current).or_else(|| display_block(text, current)) {
            let is_last = block.next_line_start >= text.len();
            if location < block.next_line_start || is_last {
                if let Some(f) = block.formula {
                    if location >= f.content_range.location && location <= f.content_range.end() {
                        return BlockResult::Formula(f);
                    }
                }
                return BlockResult::None;
            }
            start = block.next_line_start;
            continue;
        }
        if location < current.end || current.end >= text.len() {
            return BlockResult::Prose(Range::new(current.start, current.end - current.start));
        }
        start = current.end;
    }
}

fn fenced_block(text: &Text, first: Line) -> Option<Block> {
    if leading_spaces(text, first) >= 4 {
        return None;
    }
    let opener = trimmed(text, first);
    let ch = ['`', '~'].into_iter().find(|&c| opener.starts_with(&c.to_string().repeat(3)))?;
    let length = opener.chars().take_while(|&c| c == ch).count();
    let language = opener[length..]
        .trim_matches(|c| c == ' ' || c == '\t')
        .to_lowercase()
        .split(' ')
        .next()
        .map(str::to_string)
        .filter(|s| !s.is_empty());
    let close = lines_after(text, first).find(|&candidate| {
        if leading_spaces(text, candidate) >= 4 {
            return false;
        }
        let content = trimmed(text, candidate);
        let run = content.chars().take_while(|&c| c == ch).count();
        run >= length && run == content.chars().count()
    });
    let next_line_start = close.map(|c| c.end).unwrap_or(text.len());
    if language.as_deref() != Some(crate::render::math_blocks::LANGUAGE) {
        return Some(Block { formula: None, next_line_start });
    }
    let body_start = first.end;
    let body_end = close.map(|c| body_start.max(c.start.saturating_sub(1))).unwrap_or(text.len());
    Some(Block {
        formula: Some(MathFormula {
            content_range: Range::new(body_start, body_end - body_start),
            range: Range::new(first.start, close.map(|c| c.contents_end).unwrap_or(text.len()) - first.start),
            is_display: true,
            is_terminated: close.is_some(),
        }),
        next_line_start,
    })
}

fn display_block(text: &Text, first: Line) -> Option<Block> {
    if leading_spaces(text, first) >= 4 {
        return None;
    }
    let mut opener = first.start;
    while opener < first.contents_end && (text.at(opener) == SPACE || text.at(opener) == TAB) {
        opener += 1;
    }
    if !(opener + 1 < first.contents_end && text.at(opener) == DOLLAR && text.at(opener + 1) == DOLLAR) {
        return None;
    }
    let content_start = opener + 2;
    let block = |closer: usize, line: Line, terminated: bool| Block {
        formula: Some(MathFormula {
            content_range: Range::new(content_start, closer.saturating_sub(content_start)),
            range: Range::new(opener, (if terminated { closer + 2 } else { closer }) - opener),
            is_display: true,
            is_terminated: terminated,
        }),
        next_line_start: line.end,
    };
    let first_end = trimmed_end(text, first, content_start);
    if first_end > content_start + 2 && text.at(first_end - 1) == DOLLAR && text.at(first_end - 2) == DOLLAR {
        return Some(block(first_end - 2, first, true));
    }
    let mut last_before_blank: Option<Line> = None;
    let mut previous = first;
    for current in lines_after(text, first) {
        let t = trimmed(text, current);
        if t.ends_with("$$") {
            let closer = trimmed_end(text, current, current.start) - 2;
            return Some(block(closer, current, true));
        }
        if last_before_blank.is_none() && t.is_empty() {
            last_before_blank = Some(previous);
        }
        previous = current;
    }
    let last = last_before_blank.unwrap_or(previous);
    Some(block(content_start.max(last.contents_end), last, false))
}

fn is_whitespace(u: u16) -> bool {
    u == SPACE || u == TAB || u == 0xA0 || u == 0x0A || u == 0x0D
}

fn inline_formula(text: &Text, location: usize, line: Range) -> Option<MathFormula> {
    let units = &text.u[line.location..line.end()];
    let caret = location - line.location;
    let mut index = 0;
    while index < units.len() {
        let u = units[index];
        if u == BACKTICK {
            let mut run = 0;
            while index + run < units.len() && units[index + run] == BACKTICK {
                run += 1;
            }
            index = closing_code_span(units, index + run, run).unwrap_or(index + run);
            continue;
        }
        if u == DOLLAR && !is_escaped(units, index) {
            if let Some(close) = inline_close(units, index) {
                if caret > index && caret <= close {
                    return Some(MathFormula {
                        content_range: Range::new(line.location + index + 1, close - index - 1),
                        range: Range::new(line.location + index, close - index + 1),
                        is_display: false,
                        is_terminated: true,
                    });
                }
                index = close + 1;
                continue;
            }
        }
        index += 1;
    }
    None
}

fn closing_code_span(units: &[u16], start: usize, length: usize) -> Option<usize> {
    let mut i = start;
    while i < units.len() {
        if units[i] != BACKTICK {
            i += 1;
            continue;
        }
        let mut run = 0;
        while i + run < units.len() && units[i + run] == BACKTICK {
            run += 1;
        }
        if run == length {
            return Some(i + run);
        }
        i += run;
    }
    None
}

fn inline_close(units: &[u16], start: usize) -> Option<usize> {
    let content_start = start + 1;
    if content_start >= units.len() || is_whitespace(units[content_start]) {
        return None;
    }
    let mut end = content_start;
    while end < units.len() {
        if units[end] == DOLLAR {
            if is_escaped(units, end) {
                end += 1;
                continue;
            }
            if end <= content_start || is_whitespace(units[end - 1]) {
                return None;
            }
            if end + 1 < units.len() && (0x30..=0x39).contains(&units[end + 1]) {
                return None;
            }
            return Some(end);
        }
        end += 1;
    }
    None
}

fn is_escaped(units: &[u16], index: usize) -> bool {
    let mut count = 0;
    let mut i = index;
    while i > 0 && units[i - 1] == BACKSLASH {
        count += 1;
        i -= 1;
    }
    count % 2 == 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_and_display() {
        let t = Text::new("a $x^2$ b\n\n$$\n\\frac12\n$$\n");
        let f = formula_at(&t, 4).unwrap();
        assert_eq!(f.tex(&t), "x^2");
        assert!(!f.is_display);
        let d = formula_at(&t, 15).unwrap();
        assert!(d.is_display);
        assert_eq!(d.tex(&t).trim(), "\\frac12");
        assert!(formula_at(&t, 0).is_none());
    }

    #[test]
    fn unterminated_block_extends_to_blank_line() {
        let t = Text::new("$$\n\\alpha\n\nnext");
        let f = formula_at(&t, 5).unwrap();
        assert!(!f.is_terminated);
        assert_eq!(f.tex(&t).trim(), "\\alpha");
    }
}
