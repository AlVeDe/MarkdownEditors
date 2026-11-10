//! A parsed GFM pipe table, and the code that lays it out again aligned.
//! Rows are addressed by *line index* within the table: 0 is the header, 1
//! the delimiter row, 2… the body rows.

use crate::text::{utf16, Range};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alignment {
    None,
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownTable {
    pub indent: String,
    pub leading_pipe: bool,
    pub trailing_pipe: bool,
    pub header: Vec<String>,
    pub alignments: Vec<Alignment>,
    pub rows: Vec<Vec<String>>,
}

pub struct Row {
    pub cells: Vec<String>,
    /// UTF-16 ranges (within the line) of each cell's raw segment.
    pub segments: Vec<Range>,
    pub leading_pipe: bool,
    pub trailing_pipe: bool,
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c == ' ' || c == '\t')
}

impl MarkdownTable {
    pub fn column_count(&self) -> usize {
        self.header.len().max(self.alignments.len()).max(self.rows.iter().map(|r| r.len()).max().unwrap_or(0))
    }

    pub fn line_count(&self) -> usize {
        self.rows.len() + 2
    }

    /// Parses `lines` (header, delimiter, body rows). `None` unless the
    /// second line is a delimiter row.
    pub fn parse(lines: &[String]) -> Option<Self> {
        if lines.len() < 2 {
            return None;
        }
        let delimiter = alignments_of_delimiter_row(&lines[1])?;
        let header_row = parse_row(&lines[0]);
        if header_row.cells.is_empty() {
            return None;
        }
        Some(MarkdownTable {
            indent: lines[0].chars().take_while(|&c| c == ' ' || c == '\t').collect(),
            leading_pipe: header_row.leading_pipe,
            trailing_pipe: header_row.trailing_pipe,
            header: header_row.cells,
            alignments: delimiter,
            rows: lines[2..].iter().map(|l| parse_row(l).cells).collect(),
        })
    }

    /// The aligned text (no trailing line ending) and, per line index and
    /// column, the UTF-16 range of the cell's content within that text.
    pub fn formatted(&self, line_ending: &str) -> (String, Vec<Vec<Range>>) {
        let columns = self.column_count().max(1);
        let padded = |row: &Vec<String>| {
            let mut r = row.clone();
            r.resize(columns.max(r.len()), String::new());
            r
        };
        let header = padded(&self.header);
        let body: Vec<Vec<String>> = self.rows.iter().map(padded).collect();
        let mut alignments = self.alignments.clone();
        alignments.resize(columns.max(alignments.len()), Alignment::None);

        let mut widths = vec![3; columns];
        for row in std::iter::once(&header).chain(body.iter()) {
            for (column, cell) in row.iter().enumerate().take(columns) {
                widths[column] = widths[column].max(display_width(cell));
            }
        }

        let mut text = String::new();
        let mut length = 0usize;
        let mut ranges: Vec<Vec<Range>> = vec![];
        let append = |text: &mut String, length: &mut usize, piece: &str| {
            text.push_str(piece);
            *length += piece.encode_utf16().count();
        };
        let mut append_line = |text: &mut String, length: &mut usize, cells: &[String], is_delimiter: bool| {
            let mut line_ranges = vec![];
            append(text, length, &self.indent);
            if self.leading_pipe {
                append(text, length, "| ");
            }
            let line_start = *length;
            for column in 0..columns {
                if column > 0 {
                    append(text, length, " | ");
                }
                let content = &cells[column];
                let padding = widths[column] - display_width(content);
                let (before, after) = match alignments[column] {
                    Alignment::Right if !is_delimiter => (padding, 0),
                    Alignment::Center if !is_delimiter => (padding / 2, padding - padding / 2),
                    _ => (0, padding),
                };
                append(text, length, &" ".repeat(before));
                line_ranges.push(Range::new(*length, content.encode_utf16().count()));
                append(text, length, content);
                append(text, length, &" ".repeat(after));
            }
            if self.trailing_pipe {
                append(text, length, " |");
            } else {
                while text.ends_with(' ') && *length > line_start {
                    text.pop();
                    *length -= 1;
                }
            }
            ranges.push(line_ranges);
        };

        append_line(&mut text, &mut length, &header, false);
        append(&mut text, &mut length, line_ending);
        let delimiter_cells: Vec<String> = (0..columns).map(|c| delimiter_cell(alignments[c], widths[c])).collect();
        append_line(&mut text, &mut length, &delimiter_cells, true);
        for row in &body {
            append(&mut text, &mut length, line_ending);
            append_line(&mut text, &mut length, row, false);
        }
        let total = length;
        let ranges = ranges
            .into_iter()
            .map(|line| {
                line.into_iter()
                    .map(|r| {
                        let loc = r.location.min(total);
                        Range::new(loc, r.length.min(total - loc))
                    })
                    .collect()
            })
            .collect();
        (text, ranges)
    }
}

/// Splits a row at unescaped pipes.
pub fn parse_row(line: &str) -> Row {
    let u = utf16(line);
    let mut pipes = vec![];
    let mut i = 0;
    while i < u.len() {
        if u[i] == 0x5C {
            i += 2;
            continue;
        }
        if u[i] == 0x7C {
            pipes.push(i);
        }
        i += 1;
    }
    let mut segments = vec![];
    let mut start = 0;
    for &p in &pipes {
        segments.push(Range::new(start, p - start));
        start = p + 1;
    }
    segments.push(Range::new(start, u.len() - start));
    let sub = |r: Range| String::from_utf16_lossy(&u[r.location..r.end()]);
    let is_blank = |r: Range| sub(r).chars().all(char::is_whitespace);
    let leading = !pipes.is_empty() && is_blank(segments[0]);
    let trailing = pipes.len() > usize::from(leading) && is_blank(segments[segments.len() - 1]);
    if leading {
        segments.remove(0);
    }
    if trailing {
        segments.pop();
    }
    let cells = segments.iter().map(|&r| trim_ws(&sub(r)).to_string()).collect();
    Row { cells, segments, leading_pipe: leading, trailing_pipe: trailing }
}

pub fn alignments_of_delimiter_row(line: &str) -> Option<Vec<Alignment>> {
    if !line.contains('|') {
        return None;
    }
    let row = parse_row(line);
    if row.cells.is_empty() {
        return None;
    }
    let mut result = vec![];
    for cell in &row.cells {
        let inner = cell.strip_prefix(':').unwrap_or(cell);
        let inner = inner.strip_suffix(':').unwrap_or(inner);
        if inner.is_empty() || !inner.chars().all(|c| c == '-') {
            return None;
        }
        let left = cell.starts_with(':');
        let right = cell.ends_with(':') && cell.chars().count() > 1;
        result.push(match (left, right) {
            (true, true) => Alignment::Center,
            (true, false) => Alignment::Left,
            (false, true) => Alignment::Right,
            (false, false) => Alignment::None,
        });
    }
    Some(result)
}

pub fn is_delimiter_row(line: &str) -> bool {
    alignments_of_delimiter_row(line).is_some()
}

pub fn looks_like_row(line: &str) -> bool {
    let row = parse_row(line);
    row.segments.len() > 1 || row.leading_pipe || row.trailing_pipe
}

/// Which cell of a raw row line a UTF-16 offset is in, and how far into the
/// cell's trimmed content (clamped).
pub fn cell_at(offset: usize, line: &str) -> (usize, usize) {
    let row = parse_row(line);
    if row.segments.is_empty() {
        return (0, 0);
    }
    let u = utf16(line);
    let mut column = row.segments.len() - 1;
    for (i, seg) in row.segments.iter().enumerate() {
        if offset <= seg.end() {
            column = i;
            break;
        }
    }
    let seg = row.segments[column];
    let leading = u[seg.location..seg.end()].iter().take_while(|&&c| c == 0x20 || c == 0x09).count();
    let content_len = row.cells[column].encode_utf16().count();
    let in_content = offset as isize - seg.location as isize - leading as isize;
    (column, (in_content.max(0) as usize).min(content_len))
}

pub fn delimiter_cell(alignment: Alignment, width: usize) -> String {
    let width = width.max(3);
    match alignment {
        Alignment::None => "-".repeat(width),
        Alignment::Left => format!(":{}", "-".repeat(width - 1)),
        Alignment::Right => format!("{}:", "-".repeat(width - 1)),
        Alignment::Center => format!(":{}:", "-".repeat(width - 2)),
    }
}

/// Width in monospaced columns: East Asian wide characters (and most emoji)
/// take two.
pub fn display_width(s: &str) -> usize {
    s.chars()
        .map(|c| {
            let v = c as u32;
            let wide = (0x1100..=0x115F).contains(&v)
                || (0x2E80..=0xA4CF).contains(&v)
                || (0xAC00..=0xD7A3).contains(&v)
                || (0xF900..=0xFAFF).contains(&v)
                || (0xFE30..=0xFE4F).contains(&v)
                || (0xFF00..=0xFF60).contains(&v)
                || (0xFFE0..=0xFFE6).contains(&v)
                || (0x1F300..=0x1F64F).contains(&v)
                || (0x1F900..=0x1F9FF).contains(&v)
                || (0x20000..=0x3FFFD).contains(&v);
            // Combining marks add no width.
            if (0x0300..=0x036F).contains(&v) || (0xFE00..=0xFE0F).contains(&v) || v == 0x200D {
                0
            } else if wide {
                2
            } else {
                1
            }
        })
        .sum()
}
