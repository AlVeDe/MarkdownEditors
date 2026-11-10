//! A parsed snippet: the plain text to insert plus where its tab stops are.
//!
//! Syntax (a subset of the TextMate / VS Code snippet grammar):
//!
//! - `$1`, `${1}`        an empty tab stop
//! - `${1:default}`      a tab stop pre-filled with `default`
//! - `$0`, `${0}`        where the caret ends up
//! - `\$` → `$`, `\\` → `\`, and inside a default `\}` → `}`
//!
//! Anything else is literal — notably a backslash before any other character
//! (`\frac` stays `\frac`) and a `$` not followed by a digit or `{digit`.

use serde::Serialize;

use crate::text::{Range, Text};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Placeholder {
    pub index: usize,
    /// UTF-16 range within the text.
    pub range: Range,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snippet {
    pub text: String,
    pub placeholders: Vec<Placeholder>,
}

impl Snippet {
    pub fn has_tab_stops(&self) -> bool {
        self.placeholders.iter().any(|p| p.index > 0)
    }

    /// Tab-stop indices in navigation order: 1, 2, 3, … and 0 last.
    pub fn tab_stop_order(&self) -> Vec<usize> {
        let mut numbered: Vec<usize> = self.placeholders.iter().map(|p| p.index).filter(|&i| i > 0).collect();
        numbered.sort();
        numbered.dedup();
        numbered.push(0);
        numbered
    }

    /// Parses `source`; `indentation` is appended after every newline.
    pub fn parse(source: &str, indentation: &str) -> Snippet {
        let chars: Vec<char> = source.chars().collect();
        let mut output = String::new();
        let mut len = 0usize;
        let mut placeholders = vec![];
        let indent_len = indentation.encode_utf16().count();
        let append = |output: &mut String, len: &mut usize, c: char| {
            output.push(c);
            *len += c.len_utf16();
            if c == '\n' {
                output.push_str(indentation);
                *len += indent_len;
            }
        };
        let digits = |j: usize| -> Option<(usize, usize)> {
            let mut end = j;
            while end < chars.len() && chars[end].is_ascii_digit() {
                end += 1;
            }
            if end == j {
                return None;
            }
            chars[j..end].iter().collect::<String>().parse().ok().map(|v| (v, end))
        };
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if c == '\\' && i + 1 < chars.len() && (chars[i + 1] == '$' || chars[i + 1] == '\\') {
                append(&mut output, &mut len, chars[i + 1]);
                i += 2;
                continue;
            }
            if c == '$' && i + 1 < chars.len() {
                if let Some((index, end)) = digits(i + 1) {
                    placeholders.push(Placeholder { index, range: Range::new(len, 0) });
                    i = end;
                    continue;
                }
                if chars[i + 1] == '{' {
                    if let Some((index, end)) = digits(i + 2) {
                        if end < chars.len() && (chars[end] == '}' || chars[end] == ':') {
                            let start = len;
                            let mut j = end;
                            let mut closed = chars[end] == '}';
                            if !closed {
                                j += 1;
                                let saved = (output.clone(), len);
                                while j < chars.len() {
                                    let d = chars[j];
                                    if d == '\\' && j + 1 < chars.len() && "$\\}".contains(chars[j + 1]) {
                                        append(&mut output, &mut len, chars[j + 1]);
                                        j += 2;
                                    } else if d == '}' {
                                        closed = true;
                                        break;
                                    } else {
                                        append(&mut output, &mut len, d);
                                        j += 1;
                                    }
                                }
                                if !closed {
                                    (output, len) = saved;
                                    append(&mut output, &mut len, c);
                                    i += 1;
                                    continue;
                                }
                            }
                            placeholders.push(Placeholder { index, range: Range::new(start, len - start) });
                            i = j + 1;
                            continue;
                        }
                    }
                }
            }
            append(&mut output, &mut len, c);
            i += 1;
        }
        Snippet { text: output, placeholders }
    }
}

/// One tab stop in document coordinates.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TabStop {
    pub index: usize,
    pub ranges: Vec<Range>,
}

/// The insertion of a snippet into a document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnippetInsertion {
    pub range: Range,
    pub text: String,
    pub selection: Range,
    /// Empty when the snippet has no numbered tab stops (no session).
    pub tab_stops: Vec<TabStop>,
}

/// Plans inserting `snippet` over `range`, keeping the line's indentation on
/// continuation lines.
pub fn plan_insertion(text: &Text, snippet: &str, range: Range) -> SnippetInsertion {
    let line_start = text.line_range(range.location.min(text.len())).location;
    let mut indent_end = line_start;
    while indent_end < range.location && indent_end < text.len() {
        let c = text.at(indent_end);
        if c != 0x20 && c != 0x09 {
            break;
        }
        indent_end += 1;
    }
    let indentation = text.substring(Range::new(line_start, indent_end - line_start));
    let parsed = Snippet::parse(snippet, &indentation);
    let base = range.location;
    let inserted_len = parsed.text.encode_utf16().count();
    let mut stops: Vec<TabStop> = parsed
        .tab_stop_order()
        .into_iter()
        .map(|index| TabStop {
            index,
            ranges: parsed
                .placeholders
                .iter()
                .filter(|p| p.index == index)
                .map(|p| Range::new(base + p.range.location, p.range.length))
                .collect(),
        })
        .collect();
    if let Some(last) = stops.last_mut() {
        if last.ranges.is_empty() {
            last.ranges = vec![Range::new(base + inserted_len, 0)];
        }
    }
    let selection = stops[0].ranges[0];
    SnippetInsertion {
        range,
        text: parsed.text.clone(),
        selection,
        tab_stops: if parsed.has_tab_stops() { stops } else { vec![] },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_placeholders() {
        let s = Snippet::parse("\\frac{${1:a}}{$2}$0", "");
        assert_eq!(s.text, "\\frac{a}{}");
        assert_eq!(s.placeholders[0], Placeholder { index: 1, range: Range::new(6, 1) });
        assert_eq!(s.placeholders[1], Placeholder { index: 2, range: Range::new(9, 0) });
        assert_eq!(s.placeholders[2], Placeholder { index: 0, range: Range::new(10, 0) });
        assert_eq!(s.tab_stop_order(), vec![1, 2, 0]);
    }

    #[test]
    fn literal_dollars_and_indent() {
        let s = Snippet::parse("$$\n\\$x\n$$", "  ");
        assert_eq!(s.text, "$$\n  $x\n  $$");
        assert!(s.placeholders.is_empty());
    }
}
