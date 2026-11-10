//! UTF-16 code units the analyzers look at, and stateless scans shared by the
//! line and inline analyzers. All ranges are `from..to` indices into `c`.

pub mod ch {
    pub const TAB: u16 = 0x09;
    pub const NEWLINE: u16 = 0x0A;
    pub const CR: u16 = 0x0D;
    pub const SPACE: u16 = 0x20;
    pub const BANG: u16 = 0x21;
    pub const QUOTE: u16 = 0x22;
    pub const HASH: u16 = 0x23;
    pub const DOLLAR: u16 = 0x24;
    pub const APOSTROPHE: u16 = 0x27;
    pub const LPAREN: u16 = 0x28;
    pub const RPAREN: u16 = 0x29;
    pub const STAR: u16 = 0x2A;
    pub const PLUS: u16 = 0x2B;
    pub const DASH: u16 = 0x2D;
    pub const DOT: u16 = 0x2E;
    pub const SLASH: u16 = 0x2F;
    pub const COLON: u16 = 0x3A;
    pub const LT: u16 = 0x3C;
    pub const EQUALS: u16 = 0x3D;
    pub const GT: u16 = 0x3E;
    pub const AT: u16 = 0x40;
    pub const LBRACKET: u16 = 0x5B;
    pub const BACKSLASH: u16 = 0x5C;
    pub const RBRACKET: u16 = 0x5D;
    pub const CARET: u16 = 0x5E;
    pub const UNDERSCORE: u16 = 0x5F;
    pub const BACKTICK: u16 = 0x60;
    pub const LBRACE: u16 = 0x7B;
    pub const PIPE: u16 = 0x7C;
    pub const RBRACE: u16 = 0x7D;
    pub const TILDE: u16 = 0x7E;

    #[inline]
    pub fn is_space(c: u16) -> bool {
        c == SPACE || c == TAB
    }
    #[inline]
    pub fn is_digit(c: u16) -> bool {
        (0x30..=0x39).contains(&c)
    }
    #[inline]
    pub fn is_letter(c: u16) -> bool {
        let l = c | 0x20;
        (0x61..=0x7A).contains(&l)
    }
    /// Word characters for emphasis flanking; non-ASCII counts as a letter.
    #[inline]
    pub fn is_word(c: u16) -> bool {
        is_letter(c) || is_digit(c) || c >= 0x80
    }
    pub fn is_punctuation(c: u16) -> bool {
        (0x21..=0x2F).contains(&c) || (0x3A..=0x40).contains(&c) || (0x5B..=0x60).contains(&c) || (0x7B..=0x7E).contains(&c)
    }
}

use ch::*;

pub fn run_length(c: &[u16], i: usize, to: usize) -> usize {
    let x = c[i];
    let mut end = i;
    while end < to && c[end] == x {
        end += 1;
    }
    end - i
}

/// Start of the next run of exactly `length` `marker`s in `from..to`.
pub fn find_run(c: &[u16], marker: u16, length: usize, from: usize, to: usize) -> Option<usize> {
    let mut i = from;
    while i < to {
        if c[i] == marker {
            let r = run_length(c, i, to);
            if r == length {
                return Some(i);
            }
            i += r;
        } else {
            i += 1;
        }
    }
    None
}

/// First unescaped `a` `b` pair in `from..to`.
pub fn find(c: &[u16], a: u16, b: u16, from: usize, to: usize) -> Option<usize> {
    let mut i = from;
    while i + 1 < to {
        if c[i] == BACKSLASH {
            i += 2;
            continue;
        }
        if c[i] == a && c[i + 1] == b {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Start of `-->` in `from..to`.
pub fn find_comment_end(c: &[u16], from: usize, to: usize) -> Option<usize> {
    let mut i = from;
    while i + 2 < to {
        if c[i] == DASH && c[i + 1] == DASH && c[i + 2] == GT {
            return Some(i);
        }
        i += 1;
    }
    None
}

pub fn has_prefix(c: &[u16], prefix: &str, i: usize, to: usize) -> bool {
    let p = prefix.as_bytes();
    if i + p.len() > to {
        return false;
    }
    p.iter().enumerate().all(|(k, &b)| c[i + k] == b as u16)
}

/// The `)` matching the `(` at `open`.
pub fn match_paren(c: &[u16], open: usize, to: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut i = open;
    while i < to {
        match c[i] {
            BACKSLASH => i += 1,
            LPAREN => depth += 1,
            RPAREN => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// `<https://…>` or `<name@host>`; returns the index after `>`.
pub fn autolink(c: &[u16], i: usize, to: usize) -> Option<usize> {
    let mut j = i + 1;
    let mut saw_colon = false;
    let mut saw_at = false;
    if !(j < to && (is_letter(c[j]) || is_digit(c[j]))) {
        return None;
    }
    while j < to {
        let x = c[j];
        if x == GT {
            return if (saw_colon || saw_at) && j > i + 1 { Some(j + 1) } else { None };
        }
        if is_space(x) || x == LT {
            return None;
        }
        if x == COLON {
            saw_colon = true;
        }
        if x == AT {
            saw_at = true;
        }
        j += 1;
    }
    None
}

/// `<tag …>`, `</tag>`, `<!DOCTYPE …>`; returns the index after `>`.
pub fn html_tag(c: &[u16], i: usize, to: usize) -> Option<usize> {
    let mut j = i + 1;
    if j < to && (c[j] == SLASH || c[j] == BANG) {
        j += 1;
    }
    if !(j < to && is_letter(c[j])) {
        return None;
    }
    while j < to {
        if c[j] == GT {
            return Some(j + 1);
        }
        if c[j] == LT {
            return None;
        }
        j += 1;
    }
    None
}

/// `http://`, `https://` or `www.` up to whitespace, minus trailing
/// punctuation; returns the end index.
pub fn bare_url(c: &[u16], i: usize, to: usize) -> Option<usize> {
    let prefix = if has_prefix(c, "https://", i, to) {
        8
    } else if has_prefix(c, "http://", i, to) {
        7
    } else if has_prefix(c, "www.", i, to) {
        4
    } else {
        return None;
    };
    let mut end = i + prefix;
    while end < to && !is_space(c[end]) && c[end] != LT {
        end += 1;
    }
    while end > i + prefix {
        let last = c[end - 1];
        if [DOT, COLON, 0x2C, 0x3B, BANG, 0x3F, STAR, UNDERSCORE, TILDE, QUOTE, APOSTROPHE, RPAREN].contains(&last) {
            end -= 1;
        } else {
            break;
        }
    }
    (end > i + prefix).then_some(end)
}
