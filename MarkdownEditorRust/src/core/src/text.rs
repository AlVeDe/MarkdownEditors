//! UTF-16 text primitives.
//!
//! The editor runs in a web view, where JavaScript strings — and therefore
//! caret positions and selections — are indexed in UTF-16 code units. All
//! editor-facing APIs of this crate use the same unit, so a range computed
//! here can be applied to the `<textarea>` without conversion.

use serde::{Deserialize, Serialize};

/// A UTF-16 range (location + length), like `NSRange`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct Range {
    pub location: usize,
    pub length: usize,
}

impl Range {
    pub const fn new(location: usize, length: usize) -> Self {
        Range { location, length }
    }
    pub fn end(&self) -> usize {
        self.location + self.length
    }
    pub fn contains(&self, index: usize) -> bool {
        index >= self.location && index < self.end()
    }
    pub fn intersects(&self, other: Range) -> bool {
        self.location < other.end() && other.location < self.end()
    }
}

pub fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

pub fn string(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

pub const NL: u16 = 0x0A;
pub const CR: u16 = 0x0D;

/// A UTF-16 text with `NSString`-like helpers used throughout the editor.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Text {
    pub u: Vec<u16>,
}

impl Text {
    pub fn new(s: &str) -> Self {
        Text { u: utf16(s) }
    }
    pub fn from_units(u: Vec<u16>) -> Self {
        Text { u }
    }
    pub fn len(&self) -> usize {
        self.u.len()
    }
    pub fn is_empty(&self) -> bool {
        self.u.is_empty()
    }
    pub fn at(&self, i: usize) -> u16 {
        self.u[i]
    }
    pub fn substring(&self, r: Range) -> String {
        string(&self.u[r.location.min(self.len())..r.end().min(self.len())])
    }
    pub fn to_string(&self) -> String {
        string(&self.u)
    }

    /// The range of the line containing `index`, including its terminator
    /// (like `NSString.lineRange(for:)`).
    pub fn line_range(&self, index: usize) -> Range {
        let (start, _, end) = self.line_bounds(index);
        Range::new(start, end - start)
    }

    /// The range spanning all lines touched by `r`, terminators included.
    pub fn line_range_for(&self, r: Range) -> Range {
        let start = self.line_bounds(r.location).0;
        let last = if r.length > 0 { r.end() - 1 } else { r.location };
        let end = self.line_bounds(last.max(r.location)).2;
        Range::new(start, end - start)
    }

    /// (start, contents end, end incl. terminator) of the line holding `index`.
    pub fn line_bounds(&self, index: usize) -> (usize, usize, usize) {
        let n = self.len();
        let index = index.min(n);
        let mut start = index;
        while start > 0 {
            let c = self.u[start - 1];
            if c == NL || c == CR {
                break;
            }
            start -= 1;
        }
        // A caret right after "\r" of "\r\n" belongs to the line before the \n.
        if index < n && self.u[index] == NL && index > 0 && self.u[index - 1] == CR && start == index {
            // index sits between \r and \n: treat as end of previous line.
            let prev = self.line_bounds(index - 1);
            return prev;
        }
        let mut contents_end = index;
        while contents_end < n && self.u[contents_end] != NL && self.u[contents_end] != CR {
            contents_end += 1;
        }
        let mut end = contents_end;
        if end < n {
            if self.u[end] == CR && end + 1 < n && self.u[end + 1] == NL {
                end += 2;
            } else {
                end += 1;
            }
        }
        (start, contents_end, end)
    }

    /// Line contents (without terminator) of the line holding `index`.
    pub fn line_contents_range(&self, index: usize) -> Range {
        let (s, c, _) = self.line_bounds(index);
        Range::new(s, c - s)
    }

    pub fn find(&self, needle: &[u16], within: Range) -> Option<Range> {
        if needle.is_empty() {
            return None;
        }
        let end = within.end().min(self.len());
        if end < needle.len() {
            return None;
        }
        let mut i = within.location;
        while i + needle.len() <= end {
            if &self.u[i..i + needle.len()] == needle {
                return Some(Range::new(i, needle.len()));
            }
            i += 1;
        }
        None
    }

    /// Replaces `r` with `s` and returns the new range of the inserted text.
    pub fn replace(&mut self, r: Range, s: &str) -> Range {
        let ins = utf16(s);
        let len = ins.len();
        self.u.splice(r.location..r.end(), ins);
        Range::new(r.location, len)
    }
}

/// UTF-16 line ranges of a text (1-based lines, terminators excluded).
pub struct LineIndex<'a> {
    text: &'a [u16],
    starts: Vec<usize>,
}

impl<'a> LineIndex<'a> {
    pub fn new(text: &'a [u16]) -> Self {
        let mut starts = vec![0];
        let mut i = 0;
        while i < text.len() {
            let c = text[i];
            if c == NL {
                starts.push(i + 1);
            } else if c == CR {
                if i + 1 < text.len() && text[i + 1] == NL {
                    i += 1;
                }
                starts.push(i + 1);
            }
            i += 1;
        }
        LineIndex { text, starts }
    }

    pub fn line_count(&self) -> usize {
        self.starts.len()
    }

    /// The range of 1-based `line` without its terminator.
    pub fn range_of_line(&self, line: usize) -> Option<Range> {
        if line < 1 || line > self.starts.len() {
            return None;
        }
        let start = self.starts[line - 1];
        let mut end = if line < self.starts.len() { self.starts[line] } else { self.text.len() };
        while end > start && (self.text[end - 1] == NL || self.text[end - 1] == CR) {
            end -= 1;
        }
        Some(Range::new(start, end - start))
    }

    /// 1-based line number of a UTF-16 offset.
    pub fn line_of(&self, offset: usize) -> usize {
        match self.starts.binary_search(&offset) {
            Ok(i) => i + 1,
            Err(i) => i,
        }
    }

    pub fn start_of_line(&self, line: usize) -> usize {
        self.starts[(line.max(1) - 1).min(self.starts.len() - 1)]
    }
}

pub fn line_count(s: &str) -> usize {
    LineIndex::new(&utf16(s)).line_count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_ranges() {
        let t = Text::new("ab\ncd\n");
        assert_eq!(t.line_range(0), Range::new(0, 3));
        assert_eq!(t.line_range(4), Range::new(3, 3));
        assert_eq!(t.line_range(6), Range::new(6, 0));
        let idx = LineIndex::new(&t.u);
        assert_eq!(idx.line_count(), 3);
        assert_eq!(idx.range_of_line(2), Some(Range::new(3, 2)));
        assert_eq!(idx.line_of(4), 2);
    }
}
