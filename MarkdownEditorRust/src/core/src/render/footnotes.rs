//! GitHub-style footnotes for the preview and the PDF.
//!
//! This is a source rewrite before parsing, next to the `$$` rewrite:
//!
//! - each definition's lines become **empty lines**, so every other line
//!   keeps its number (scroll sync and diagnostics map by line);
//! - each reference becomes `<sup class="footnote-ref"><a …>n</a></sup>`,
//!   numbered by first use;
//! - the notes are appended after a rule as an ordered list inside a
//!   `<section class="footnotes">`, each with a back link.
//!
//! References without a definition stay as typed, like on GitHub; so do
//! definitions nobody references (they are dropped). Fenced code and inline
//! code are left alone.

use std::collections::HashMap;

use super::math_blocks::trim_ws;

pub fn rewrite(markdown: &str) -> String {
    if !markdown.contains("[^") {
        return markdown.to_string();
    }
    let mut lines: Vec<String> = markdown.split('\n').map(str::to_string).collect();
    let definitions = extract_definitions(&mut lines);
    if definitions.is_empty() {
        return markdown.to_string();
    }

    let mut numbers: HashMap<String, usize> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut in_fence: Option<(char, usize)> = None;
    for line in lines.iter_mut() {
        if let Some(fence) = in_fence {
            if closes_fence(line, fence) {
                in_fence = None;
            }
            continue;
        }
        if let Some(fence) = opens_fence(line) {
            in_fence = Some(fence);
            continue;
        }
        *line = replacing_references(line, &definitions, &mut |label: &str| {
            if let Some(&n) = numbers.get(label) {
                return (n, false);
            }
            order.push(label.to_string());
            numbers.insert(label.to_string(), order.len());
            (order.len(), true)
        });
    }
    if order.is_empty() {
        return lines.join("\n");
    }

    let mut notes: Vec<String> =
        ["", "---", "", "<section class=\"footnotes\">", ""].iter().map(|s| s.to_string()).collect();
    for (offset, label) in order.iter().enumerate() {
        let number = offset + 1;
        let body = definitions.get(label).cloned().unwrap_or_default().replace('\n', "\n    ");
        notes.push(format!(
            "{number}. <span id=\"fn-{number}\"></span>{body} <a href=\"#fnref-{number}\" class=\"footnote-back\">↩</a>"
        ));
    }
    notes.extend(["", "</section>", ""].iter().map(|s| s.to_string()));
    format!("{}\n{}", lines.join("\n"), notes.join("\n"))
}

/// Removes `[^label]: text` definitions (plus indented continuation lines)
/// by blanking them, and returns label → note text.
fn extract_definitions(lines: &mut [String]) -> HashMap<String, String> {
    let mut definitions = HashMap::new();
    let mut in_fence: Option<(char, usize)> = None;
    let mut index = 0;
    while index < lines.len() {
        if let Some(fence) = in_fence {
            if closes_fence(&lines[index], fence) {
                in_fence = None;
            }
            index += 1;
            continue;
        }
        if let Some(fence) = opens_fence(&lines[index]) {
            in_fence = Some(fence);
            index += 1;
            continue;
        }
        let Some((label, first)) = definition(&lines[index]) else {
            index += 1;
            continue;
        };
        let mut body = vec![first];
        lines[index].clear();
        index += 1;
        while index < lines.len() {
            if is_indented(&lines[index]) {
                body.push(trim_ws(&lines[index]).to_string());
                lines[index].clear();
                index += 1;
            } else if trim_ws(&lines[index]).is_empty() && index + 1 < lines.len() && is_indented(&lines[index + 1]) {
                body.push(String::new());
                index += 1;
            } else {
                break;
            }
        }
        definitions.entry(label).or_insert_with(|| body.join("\n"));
    }
    definitions
}

/// `[^label]: text` with at most three spaces of indentation.
pub fn definition(line: &str) -> Option<(String, String)> {
    let indent = line.chars().take_while(|&c| c == ' ').count();
    if indent > 3 {
        return None;
    }
    let rest = &line[indent..];
    let after = rest.strip_prefix("[^")?;
    let close = after.find(']')?;
    let label = &after[..close];
    if label.is_empty() || label.chars().any(char::is_whitespace) {
        return None;
    }
    let after_close = after[close + 1..].strip_prefix(':')?;
    Some((label.to_string(), trim_ws(after_close).to_string()))
}

fn is_indented(line: &str) -> bool {
    line.starts_with("    ") || line.starts_with('\t')
}

fn replacing_references(
    line: &str,
    definitions: &HashMap<String, String>,
    number: &mut dyn FnMut(&str) -> (usize, bool),
) -> String {
    if !line.contains("[^") {
        return line.to_string();
    }
    let chars: Vec<char> = line.chars().collect();
    let mut output = String::new();
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if c == '`' {
            let mut run = 0;
            while index + run < chars.len() && chars[index + run] == '`' {
                run += 1;
            }
            if let Some(end) = closing_backticks(&chars, index + run, run) {
                output.extend(&chars[index..end + run]);
                index = end + run;
            } else {
                output.extend(&chars[index..index + run]);
                index += run;
            }
            continue;
        }
        if c == '[' && index + 1 < chars.len() && chars[index + 1] == '^' {
            if let Some(close) = chars[index + 2..].iter().position(|&c| c == ']').map(|p| p + index + 2) {
                let label: String = chars[index + 2..close].iter().collect();
                let followed_by_colon = close + 1 < chars.len() && chars[close + 1] == ':';
                if !label.is_empty() && definitions.contains_key(&label) && !followed_by_colon {
                    let (n, first) = number(&label);
                    let anchor = if first { format!(" id=\"fnref-{n}\"") } else { String::new() };
                    output.push_str(&format!("<sup class=\"footnote-ref\"><a href=\"#fn-{n}\"{anchor}>{n}</a></sup>"));
                    index = close + 1;
                    continue;
                }
            }
        }
        output.push(c);
        index += 1;
    }
    output
}

fn closing_backticks(chars: &[char], start: usize, length: usize) -> Option<usize> {
    let mut index = start;
    while index < chars.len() {
        if chars[index] == '`' {
            let mut run = 0;
            while index + run < chars.len() && chars[index + run] == '`' {
                run += 1;
            }
            if run == length {
                return Some(index);
            }
            index += run;
        } else {
            index += 1;
        }
    }
    None
}

fn opens_fence(line: &str) -> Option<(char, usize)> {
    let trimmed = line.trim_start_matches(' ');
    if line.len() - trimmed.len() > 3 {
        return None;
    }
    let first = trimmed.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let length = trimmed.chars().take_while(|&c| c == first).count();
    (length >= 3).then_some((first, length))
}

fn closes_fence(line: &str, fence: (char, usize)) -> bool {
    let trimmed = trim_ws(line);
    trimmed.chars().count() >= fence.1 && trimmed.chars().all(|c| c == fence.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_by_first_use() {
        let out = rewrite("A[^b] and[^a].\n\n[^a]: first\n[^b]: second");
        assert!(out.starts_with("A<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup> and"));
        assert!(out.contains("1. <span id=\"fn-1\"></span>second"));
        assert!(out.contains("2. <span id=\"fn-2\"></span>first"));
        // Definition lines are blanked, line count kept.
        assert_eq!(out.split('\n').nth(2), Some(""));
    }

    #[test]
    fn undefined_reference_stays() {
        assert_eq!(rewrite("x[^nope]"), "x[^nope]");
    }
}
