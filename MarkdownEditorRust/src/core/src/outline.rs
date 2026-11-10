//! The outline sidebar's headings: ATX (`# Title`) and setext (`Title` /
//! `===`) headings, skipping fenced code, YAML front matter, indented code
//! and HTML comments.

use serde::Serialize;

use crate::text::{Range, Text};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OutlineHeading {
    pub id: usize,
    pub level: usize,
    pub title: String,
    /// 1-based source line (setext: the first text line).
    pub line: usize,
    /// UTF-16 offset of the start of that line.
    pub location: usize,
}

fn trim_trailing(s: &str) -> &str {
    s.trim_end_matches([' ', '\t'])
}

fn fence_marker(body: &str) -> Option<(char, usize, String)> {
    let first = body.chars().next().filter(|&c| c == '`' || c == '~')?;
    let count = body.chars().take_while(|&c| c == first).count();
    if count < 3 {
        return None;
    }
    Some((first, count, body[count..].trim_matches([' ', '\t']).to_string()))
}

fn atx_heading(body: &str) -> Option<(usize, String)> {
    let level = body.chars().take_while(|&c| c == '#').count();
    if !(1..=6).contains(&level) {
        return None;
    }
    let rest = &body[level..];
    if !(rest.is_empty() || rest.starts_with(' ') || rest.starts_with('\t')) {
        return None;
    }
    let mut title = rest.trim_matches([' ', '\t']).to_string();
    let trailing = title.chars().rev().take_while(|&c| c == '#').count();
    if trailing > 0 {
        let cut = title.len() - trailing;
        if cut == 0 || title[..cut].ends_with([' ', '\t']) {
            title = title[..cut].trim_matches([' ', '\t']).to_string();
        }
    }
    Some((level, title))
}

fn setext_level(body: &str) -> Option<usize> {
    let t = body.trim_matches([' ', '\t']);
    let first = t.chars().next().filter(|&c| c == '=' || c == '-')?;
    t.chars().all(|c| c == first).then_some(if first == '=' { 1 } else { 2 })
}

fn starts_non_paragraph_block(body: &str) -> bool {
    if body.starts_with('>') {
        return true;
    }
    let mut chars = body.chars();
    match chars.next() {
        Some('-' | '*' | '+') => {
            if body[1..].is_empty() || body[1..].starts_with([' ', '\t']) {
                return true;
            }
        }
        Some(c) if c.is_ascii_digit() => {
            let digits = body.chars().take_while(|c| c.is_ascii_digit()).count();
            if digits <= 9 {
                let rest = &body[digits..];
                if (rest.starts_with('.') || rest.starts_with(')')) && (rest.len() == 1 || rest[1..].starts_with([' ', '\t'])) {
                    return true;
                }
            }
        }
        _ => {}
    }
    let compact: Vec<char> = body.chars().filter(|c| !c.is_whitespace()).collect();
    compact.len() >= 3 && "*_-".contains(compact[0]) && compact.iter().all(|&c| c == compact[0])
}

pub fn headings(text: &str) -> Vec<OutlineHeading> {
    let t = Text::new(text);
    let mut headings = vec![];
    let mut index = 0;
    let mut line_number = 0;
    let mut fence: Option<(char, usize)> = None;
    let mut in_front_matter = false;
    let mut in_comment = false;
    let mut paragraph: Option<(Vec<String>, usize, usize)> = None;
    while index < t.len() {
        let (start, contents_end, end) = t.line_bounds(index);
        let line = t.substring(Range::new(start, contents_end - start));
        let location = start;
        index = end;
        line_number += 1;
        if line_number == 1 && trim_trailing(&line) == "---" {
            in_front_matter = true;
            continue;
        }
        if in_front_matter {
            let tr = trim_trailing(&line);
            if tr == "---" || tr == "..." {
                in_front_matter = false;
            }
            continue;
        }
        let indent = line.chars().take_while(|&c| c == ' ').count();
        let body = &line[indent..];
        if let Some(open) = fence {
            if indent < 4 {
                if let Some(close) = fence_marker(body) {
                    if close.0 == open.0 && close.1 >= open.1 && close.2.is_empty() {
                        fence = None;
                    }
                }
            }
            continue;
        }
        if indent < 4 {
            if let Some(open) = fence_marker(body) {
                if open.0 != '`' || !open.2.contains('`') {
                    fence = Some((open.0, open.1));
                    paragraph = None;
                    continue;
                }
            }
        }
        if in_comment {
            if line.contains("-->") {
                in_comment = false;
            }
            continue;
        }
        if indent < 4 && body.starts_with("<!--") {
            if !body.contains("-->") {
                in_comment = true;
            }
            paragraph = None;
            continue;
        }
        if line.chars().all(char::is_whitespace) {
            paragraph = None;
            continue;
        }
        if indent >= 4 || line.starts_with('\t') {
            if let Some(p) = paragraph.as_mut() {
                p.0.push(line.trim_start_matches([' ', '\t']).to_string());
            }
            continue;
        }
        if let Some((level, title)) = atx_heading(body) {
            headings.push(OutlineHeading { id: headings.len(), level, title, line: line_number, location });
            paragraph = None;
            continue;
        }
        if let (Some(level), Some(p)) = (setext_level(body), paragraph.as_ref()) {
            let title = p.0.join(" ").trim_matches([' ', '\t']).to_string();
            headings.push(OutlineHeading { id: headings.len(), level, title, line: p.1, location: p.2 });
            paragraph = None;
            continue;
        }
        if starts_non_paragraph_block(body) {
            paragraph = None;
        } else if let Some(p) = paragraph.as_mut() {
            p.0.push(body.to_string());
        } else {
            paragraph = Some((vec![body.to_string()], line_number, location));
        }
    }
    headings
}

/// Index of the heading whose section contains `location`.
pub fn section_index(location: usize, headings: &[OutlineHeading]) -> Option<usize> {
    let idx = headings.partition_point(|h| h.location <= location);
    idx.checked_sub(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_headings() {
        let h = headings("---\ntitle: x\n---\n# One\n\nTwo\n---\n```\n# no\n```\n<!--\n# no\n-->\n## Three ##");
        let titles: Vec<&str> = h.iter().map(|h| h.title.as_str()).collect();
        assert_eq!(titles, vec!["One", "Two", "Three"]);
        assert_eq!(h[1].level, 2);
        assert_eq!(h[1].line, 6);
        assert_eq!(section_index(h[1].location + 1, &h), Some(1));
        assert_eq!(section_index(0, &h), None);
    }
}
