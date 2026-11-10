//! Finds LaTeX written between single `$` delimiters inside running text.
//!
//! An inline formula sits *inside* a paragraph, so it cannot be normalized
//! into a fenced code block. It is instead split out of the parsed AST's text
//! runs (see `ast::parse`): code spans, link destinations and raw HTML are
//! skipped for free because the parser already separated them.
//!
//! A candidate only becomes a formula when it clears two gates:
//!
//! 1. **Delimiter rules** (as in Pandoc): the opening `$` is not followed by
//!    whitespace, the closing `$` is not preceded by whitespace and not
//!    followed by a digit, and no `$` appears in between.
//! 2. **Structural LaTeX validity** ([`is_valid_latex`]).

/// One run of a split text node: prose (`tex == None`) or a formula.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Piece {
    pub text: String,
    pub tex: Option<String>,
}

const MAXIMUM_LENGTH: usize = 300;

/// Splits running text into prose and formula runs.
pub fn split(text: &str) -> Vec<Piece> {
    if !text.contains('$') {
        return vec![Piece { text: text.to_string(), tex: None }];
    }
    let chars: Vec<char> = text.chars().collect();
    let mut pieces = Vec::new();
    let mut prose = String::new();
    let mut index = 0;
    while index < chars.len() {
        let formula = if chars[index] == '$' && !is_escaped(&chars, index) { formula(&chars, index) } else { None };
        let Some((tex, next)) = formula else {
            prose.push(chars[index]);
            index += 1;
            continue;
        };
        if !prose.is_empty() {
            pieces.push(Piece { text: std::mem::take(&mut prose), tex: None });
        }
        pieces.push(Piece { text: String::new(), tex: Some(tex) });
        index = next;
    }
    if !prose.is_empty() {
        pieces.push(Piece { text: prose, tex: None });
    }
    if pieces.is_empty() {
        pieces.push(Piece { text: text.to_string(), tex: None });
    }
    pieces
}

fn formula(chars: &[char], start: usize) -> Option<(String, usize)> {
    let content_start = start + 1;
    if content_start >= chars.len() || chars[content_start].is_whitespace() {
        return None;
    }
    let mut end = content_start;
    while end < chars.len() {
        let c = chars[end];
        if c == '$' && is_escaped(chars, end) {
            end += 1;
            continue;
        }
        if c == '$' && end > content_start {
            if chars[end - 1].is_whitespace() {
                return None;
            }
            if end + 1 < chars.len() && chars[end + 1].is_numeric() {
                return None;
            }
            let tex: String = chars[content_start..end].iter().collect();
            if tex.chars().count() > MAXIMUM_LENGTH || !is_valid_latex(&tex) {
                return None;
            }
            return Some((tex, end + 1));
        }
        if c == '$' {
            return None;
        }
        end += 1;
    }
    None
}

fn is_escaped(chars: &[char], index: usize) -> bool {
    let mut backslashes = 0;
    let mut cursor = index;
    while cursor > 0 && chars[cursor - 1] == '\\' {
        backslashes += 1;
        cursor -= 1;
    }
    backslashes % 2 == 1
}

fn is_punctuation_or_symbol(c: char) -> bool {
    !c.is_alphanumeric() && !c.is_whitespace() && !c.is_control()
}

/// Checks that `tex` is *structurally* valid LaTeX: balanced braces,
/// `\left`/`\right` and environments, well-formed control sequences,
/// sub/superscripts with an argument, no TeX comment or parameter character.
/// Unknown macros pass.
pub fn is_valid_latex(tex: &str) -> bool {
    if tex.is_empty() || tex.contains(['\n', '\r']) {
        return false;
    }
    let chars: Vec<char> = tex.chars().collect();
    let mut brace_depth: i32 = 0;
    let mut left_right: i32 = 0;
    let mut environments: Vec<String> = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if c == '\\' {
            if index + 1 >= chars.len() {
                return false;
            }
            let next = chars[index + 1];
            if !next.is_alphabetic() {
                if !(is_punctuation_or_symbol(next) || next == ' ') {
                    return false;
                }
                index += 2;
                continue;
            }
            let mut name_end = index + 1;
            let mut name = String::new();
            while name_end < chars.len() && chars[name_end].is_alphabetic() {
                name.push(chars[name_end]);
                name_end += 1;
            }
            match name.as_str() {
                "left" => left_right += 1,
                "right" => {
                    left_right -= 1;
                    if left_right < 0 {
                        return false;
                    }
                }
                "begin" | "end" => {
                    let Some((env, next_index)) = environment_name(&chars, name_end) else { return false };
                    if name == "begin" {
                        environments.push(env);
                    } else if environments.pop().as_deref() != Some(env.as_str()) {
                        return false;
                    }
                    name_end = next_index;
                }
                _ => {}
            }
            index = name_end;
            continue;
        }
        match c {
            '{' => brace_depth += 1,
            '}' => {
                brace_depth -= 1;
                if brace_depth < 0 {
                    return false;
                }
            }
            '%' | '#' => return false,
            '&' => {
                if environments.is_empty() {
                    return false;
                }
            }
            '^' | '_' => {
                if index + 1 >= chars.len() {
                    return false;
                }
                let next = chars[index + 1];
                if matches!(next, '^' | '_' | '}' | '&') {
                    return false;
                }
            }
            _ => {}
        }
        index += 1;
    }
    brace_depth == 0 && left_right == 0 && environments.is_empty()
}

fn environment_name(chars: &[char], index: usize) -> Option<(String, usize)> {
    if index >= chars.len() || chars[index] != '{' {
        return None;
    }
    let mut cursor = index + 1;
    let mut name = String::new();
    while cursor < chars.len() && chars[cursor] != '}' {
        name.push(chars[cursor]);
        cursor += 1;
    }
    if cursor >= chars.len() || name.is_empty() {
        return None;
    }
    Some((name, cursor + 1))
}
