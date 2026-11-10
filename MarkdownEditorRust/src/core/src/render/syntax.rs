//! Source-code tokenizers shared by the HTML preview, the PDF export and the
//! editor's highlighter: one tokenizer per language, three outputs.
//!
//! Adding a language means writing one tokenizer and one entry in
//! [`tokenizer_for`].

use std::collections::HashSet;
use std::sync::OnceLock;

/// Classification of a source-code token. Output-agnostic: the HTML renderer
/// maps kinds to CSS classes, the PDF renderer to colors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TokenKind {
    Plain,
    Keyword,
    String,
    Comment,
    Number,
    Preprocessor,
}

impl TokenKind {
    /// CSS class emitted by the HTML renderer; `None` for plain text.
    pub fn css_class(self) -> Option<&'static str> {
        match self {
            TokenKind::Plain => None,
            TokenKind::Keyword => Some("tok-keyword"),
            TokenKind::String => Some("tok-string"),
            TokenKind::Comment => Some("tok-comment"),
            TokenKind::Number => Some("tok-number"),
            TokenKind::Preprocessor => Some("tok-preprocessor"),
        }
    }

    /// Short name used for CSS custom properties and the editor's spans.
    pub fn name(self) -> &'static str {
        match self {
            TokenKind::Plain => "plain",
            TokenKind::Keyword => "keyword",
            TokenKind::String => "string",
            TokenKind::Comment => "comment",
            TokenKind::Number => "number",
            TokenKind::Preprocessor => "preprocessor",
        }
    }

    /// Light-appearance color (Xcode-like) — single source of truth shared
    /// by the preview CSS, the editor and the PDF renderer.
    pub fn light_color(self) -> Option<u32> {
        match self {
            TokenKind::Plain => None,
            TokenKind::Keyword => Some(0xAD3DA4),
            TokenKind::String => Some(0xC41A16),
            TokenKind::Comment => Some(0x007400),
            TokenKind::Number => Some(0x1C00CF),
            TokenKind::Preprocessor => Some(0x643820),
        }
    }

    pub fn dark_color(self) -> Option<u32> {
        match self {
            TokenKind::Plain => None,
            TokenKind::Keyword => Some(0xFC5FA3),
            TokenKind::String => Some(0xFC6A5D),
            TokenKind::Comment => Some(0x7F8C98),
            TokenKind::Number => Some(0xD0BF69),
            TokenKind::Preprocessor => Some(0xFDB37B),
        }
    }

    pub const COLORED: [TokenKind; 5] = [
        TokenKind::Keyword,
        TokenKind::String,
        TokenKind::Comment,
        TokenKind::Number,
        TokenKind::Preprocessor,
    ];
}

pub fn css_hex(color: u32) -> String {
    format!("#{:06x}", color & 0xFF_FFFF)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenKind,
    pub text: String,
}

/// A minimal lexer for one language.
pub trait LanguageTokenizer: Send + Sync {
    fn tokenize(&self, code: &str) -> Vec<Token>;
}

/// Maps a fence info string (`csharp`, `js`, …) to its tokenizer. Only the
/// first word counts, case-insensitively.
pub fn tokenizer_for(language: Option<&str>) -> Option<&'static dyn LanguageTokenizer> {
    let first = language?.split(' ').find(|s| !s.is_empty())?.to_lowercase();
    static CS: CSharpTokenizer = CSharpTokenizer;
    static PY: PythonTokenizer = PythonTokenizer;
    match first.as_str() {
        "csharp" | "cs" | "c#" => Some(&CS),
        "javascript" | "js" | "jsx" => Some(javascript()),
        "typescript" | "ts" | "tsx" => Some(typescript()),
        "python" | "py" => Some(&PY),
        _ => None,
    }
}

/// Every registered alias (for fence-language completion).
pub const REGISTERED_ALIASES: &[&str] = &[
    "csharp", "cs", "c#", "javascript", "js", "jsx", "typescript", "ts", "tsx", "python", "py",
];

/// Accumulates tokens, merging consecutive plain characters into one token.
#[derive(Default)]
struct TokenBuilder {
    tokens: Vec<Token>,
    plain: String,
}

impl TokenBuilder {
    fn plain_char(&mut self, c: char) {
        self.plain.push(c);
    }
    fn plain_str(&mut self, s: &str) {
        self.plain.push_str(s);
    }
    fn emit(&mut self, kind: TokenKind, text: String) {
        self.flush();
        self.tokens.push(Token { kind, text });
    }
    fn finish(mut self) -> Vec<Token> {
        self.flush();
        self.tokens
    }
    fn flush(&mut self) {
        if !self.plain.is_empty() {
            let text = std::mem::take(&mut self.plain);
            self.tokens.push(Token { kind: TokenKind::Plain, text });
        }
    }
}

fn s(chars: &[char]) -> String {
    chars.iter().collect()
}

fn is_ident_char(c: char) -> bool {
    c.is_alphabetic() || c.is_numeric() || c == '_'
}

// MARK: - C#

/// Deliberately small hand-written C# lexer: keywords, strings (incl. `@`/`$`
/// prefixed), comments (`//`, `/* */`, `///`), numbers and preprocessor
/// directives.
pub struct CSharpTokenizer;

const CSHARP_KEYWORDS: &[&str] = &[
    "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class",
    "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event",
    "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach", "goto", "if",
    "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new",
    "null", "object", "operator", "out", "override", "params", "private", "protected", "public",
    "readonly", "record", "ref", "required", "return", "sbyte", "sealed", "short", "sizeof",
    "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof",
    "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "var", "virtual", "void", "volatile",
    "while", "async", "await", "dynamic", "get", "global", "init", "nameof", "partial", "set",
    "value", "when", "where", "yield",
];

impl CSharpTokenizer {
    fn scan_string(chars: &[char], quote_index: usize, verbatim: bool) -> usize {
        let mut j = quote_index + 1;
        while j < chars.len() {
            let ch = chars[j];
            if verbatim {
                if ch == '"' {
                    if j + 1 < chars.len() && chars[j + 1] == '"' {
                        j += 2;
                        continue;
                    }
                    return j + 1;
                }
            } else {
                if ch == '\\' {
                    j += 2;
                    continue;
                }
                if ch == '"' {
                    return j + 1;
                }
                if ch == '\n' {
                    return j;
                }
            }
            j += 1;
        }
        chars.len()
    }
}

impl LanguageTokenizer for CSharpTokenizer {
    fn tokenize(&self, code: &str) -> Vec<Token> {
        let keywords: &HashSet<&str> = {
            static K: OnceLock<HashSet<&'static str>> = OnceLock::new();
            K.get_or_init(|| CSHARP_KEYWORDS.iter().copied().collect())
        };
        let mut b = TokenBuilder::default();
        let chars: Vec<char> = code.chars().collect();
        let count = chars.len();
        let mut i = 0;
        let mut at_line_start = true;

        while i < count {
            let c = chars[i];
            if c == '\n' {
                b.plain_char(c);
                at_line_start = true;
                i += 1;
                continue;
            }
            if c == ' ' || c == '\t' {
                b.plain_char(c);
                i += 1;
                continue;
            }
            if at_line_start && c == '#' {
                let start = i;
                while i < count && chars[i] != '\n' {
                    i += 1;
                }
                b.emit(TokenKind::Preprocessor, s(&chars[start..i]));
                at_line_start = false;
                continue;
            }
            at_line_start = false;

            if c == '/' && i + 1 < count && chars[i + 1] == '/' {
                let start = i;
                while i < count && chars[i] != '\n' {
                    i += 1;
                }
                b.emit(TokenKind::Comment, s(&chars[start..i]));
                continue;
            }
            if c == '/' && i + 1 < count && chars[i + 1] == '*' {
                let start = i;
                i += 2;
                while i < count && !(chars[i] == '*' && i + 1 < count && chars[i + 1] == '/') {
                    i += 1;
                }
                i = (i + 2).min(count);
                b.emit(TokenKind::Comment, s(&chars[start..i]));
                continue;
            }
            if c == '@' || c == '$' {
                let mut j = i;
                let mut verbatim = false;
                while j < count && (chars[j] == '@' || chars[j] == '$') {
                    if chars[j] == '@' {
                        verbatim = true;
                    }
                    j += 1;
                }
                if j < count && chars[j] == '"' {
                    let end = Self::scan_string(&chars, j, verbatim);
                    b.emit(TokenKind::String, s(&chars[i..end]));
                    i = end;
                    continue;
                }
                if c == '@' && j < count && (chars[j].is_alphabetic() || chars[j] == '_') {
                    let mut k = j;
                    while k < count && is_ident_char(chars[k]) {
                        k += 1;
                    }
                    b.plain_str(&s(&chars[i..k]));
                    i = k;
                    continue;
                }
                b.plain_char(c);
                i += 1;
                continue;
            }
            if c == '"' {
                let end = Self::scan_string(&chars, i, false);
                b.emit(TokenKind::String, s(&chars[i..end]));
                i = end;
                continue;
            }
            if c == '\'' {
                let mut j = i + 1;
                while j < count && chars[j] != '\'' && chars[j] != '\n' {
                    if chars[j] == '\\' {
                        j += 1;
                    }
                    j += 1;
                }
                j = (j + 1).min(count);
                b.emit(TokenKind::String, s(&chars[i..j]));
                i = j;
                continue;
            }
            if c.is_numeric() {
                let mut j = i;
                while j < count && (chars[j].is_ascii_hexdigit() || "xXbBoO._eEfFdDmMuUlL".contains(chars[j])) {
                    j += 1;
                }
                b.emit(TokenKind::Number, s(&chars[i..j]));
                i = j;
                continue;
            }
            if c.is_alphabetic() || c == '_' {
                let mut j = i;
                while j < count && is_ident_char(chars[j]) {
                    j += 1;
                }
                let word = s(&chars[i..j]);
                if keywords.contains(word.as_str()) {
                    b.emit(TokenKind::Keyword, word);
                } else {
                    b.plain_str(&word);
                }
                i = j;
                continue;
            }
            b.plain_char(c);
            i += 1;
        }
        b.finish()
    }
}

// MARK: - JavaScript / TypeScript

/// Minimal JavaScript lexer: keywords, `'`/`"`/template strings, comments and
/// numbers. Serves as the base for TypeScript via extra keywords.
pub struct JavaScriptTokenizer {
    keywords: HashSet<&'static str>,
}

const JS_KEYWORDS: &[&str] = &[
    "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
    "else", "export", "extends", "finally", "for", "function", "if", "import", "in", "instanceof",
    "let", "new", "of", "return", "static", "super", "switch", "this", "throw", "try", "typeof",
    "var", "void", "while", "with", "yield", "async", "await", "get", "set", "true", "false",
    "null", "undefined", "NaN",
];

const TS_KEYWORDS: &[&str] = &[
    "abstract", "any", "as", "asserts", "boolean", "declare", "enum", "implements", "infer",
    "interface", "is", "keyof", "namespace", "never", "number", "object", "override", "private",
    "protected", "public", "readonly", "satisfies", "string", "symbol", "type", "unknown", "unique",
];

impl JavaScriptTokenizer {
    pub fn new(extra: &[&'static str]) -> Self {
        let mut keywords: HashSet<&'static str> = JS_KEYWORDS.iter().copied().collect();
        keywords.extend(extra.iter().copied());
        JavaScriptTokenizer { keywords }
    }
}

fn javascript() -> &'static JavaScriptTokenizer {
    static T: OnceLock<JavaScriptTokenizer> = OnceLock::new();
    T.get_or_init(|| JavaScriptTokenizer::new(&[]))
}

fn typescript() -> &'static JavaScriptTokenizer {
    static T: OnceLock<JavaScriptTokenizer> = OnceLock::new();
    T.get_or_init(|| JavaScriptTokenizer::new(TS_KEYWORDS))
}

impl LanguageTokenizer for JavaScriptTokenizer {
    fn tokenize(&self, code: &str) -> Vec<Token> {
        let mut b = TokenBuilder::default();
        let chars: Vec<char> = code.chars().collect();
        let count = chars.len();
        let mut i = 0;
        while i < count {
            let c = chars[i];
            if c == '/' && i + 1 < count && chars[i + 1] == '/' {
                let start = i;
                while i < count && chars[i] != '\n' {
                    i += 1;
                }
                b.emit(TokenKind::Comment, s(&chars[start..i]));
                continue;
            }
            if c == '/' && i + 1 < count && chars[i + 1] == '*' {
                let start = i;
                i += 2;
                while i < count && !(chars[i] == '*' && i + 1 < count && chars[i + 1] == '/') {
                    i += 1;
                }
                i = (i + 2).min(count);
                b.emit(TokenKind::Comment, s(&chars[start..i]));
                continue;
            }
            if c == '\'' || c == '"' || c == '`' {
                let start = i;
                let mut j = i + 1;
                while j < count {
                    let ch = chars[j];
                    if ch == '\\' {
                        j += 2;
                        continue;
                    }
                    if ch == c {
                        j += 1;
                        break;
                    }
                    if ch == '\n' && c != '`' {
                        break;
                    }
                    j += 1;
                }
                let end = j.min(count);
                b.emit(TokenKind::String, s(&chars[start..end]));
                i = end;
                continue;
            }
            if c.is_numeric() {
                let mut j = i;
                while j < count && (chars[j].is_ascii_hexdigit() || "xXoObBn._eE".contains(chars[j])) {
                    j += 1;
                }
                b.emit(TokenKind::Number, s(&chars[i..j]));
                i = j;
                continue;
            }
            if c.is_alphabetic() || c == '_' || c == '$' {
                let mut j = i;
                while j < count && (is_ident_char(chars[j]) || chars[j] == '$') {
                    j += 1;
                }
                let word = s(&chars[i..j]);
                if self.keywords.contains(word.as_str()) {
                    b.emit(TokenKind::Keyword, word);
                } else {
                    b.plain_str(&word);
                }
                i = j;
                continue;
            }
            b.plain_char(c);
            i += 1;
        }
        b.finish()
    }
}

// MARK: - Python

/// Minimal Python lexer: `#` comments, single- and triple-quoted strings
/// (with `r`/`b`/`f`/`u` prefixes), numbers, keywords, and decorators
/// (colored via the preprocessor kind).
pub struct PythonTokenizer;

const PYTHON_KEYWORDS: &[&str] = &[
    "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue",
    "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
    "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try",
    "while", "with", "yield",
];

impl PythonTokenizer {
    fn scan_string(chars: &[char], quote_index: usize, prefix_start: usize, b: &mut TokenBuilder) -> usize {
        let count = chars.len();
        let quote = chars[quote_index];
        let triple = quote_index + 2 < count && chars[quote_index + 1] == quote && chars[quote_index + 2] == quote;
        let mut j = quote_index + if triple { 3 } else { 1 };
        while j < count {
            let ch = chars[j];
            if ch == '\\' {
                j += 2;
                continue;
            }
            if triple {
                if ch == quote && j + 2 < count && chars[j + 1] == quote && chars[j + 2] == quote {
                    j += 3;
                    break;
                }
            } else {
                if ch == quote {
                    j += 1;
                    break;
                }
                if ch == '\n' {
                    break;
                }
            }
            j += 1;
        }
        let end = j.min(count);
        b.emit(TokenKind::String, s(&chars[prefix_start..end]));
        end
    }
}

impl LanguageTokenizer for PythonTokenizer {
    fn tokenize(&self, code: &str) -> Vec<Token> {
        let mut b = TokenBuilder::default();
        let chars: Vec<char> = code.chars().collect();
        let count = chars.len();
        let mut i = 0;
        let mut at_line_start = true;
        while i < count {
            let c = chars[i];
            if c == '\n' {
                b.plain_char(c);
                at_line_start = true;
                i += 1;
                continue;
            }
            if c == ' ' || c == '\t' {
                b.plain_char(c);
                i += 1;
                continue;
            }
            if c == '#' {
                let start = i;
                while i < count && chars[i] != '\n' {
                    i += 1;
                }
                b.emit(TokenKind::Comment, s(&chars[start..i]));
                at_line_start = false;
                continue;
            }
            if at_line_start && c == '@' {
                let mut j = i + 1;
                while j < count && (is_ident_char(chars[j]) || chars[j] == '.') {
                    j += 1;
                }
                b.emit(TokenKind::Preprocessor, s(&chars[i..j]));
                i = j;
                at_line_start = false;
                continue;
            }
            at_line_start = false;
            if c == '\'' || c == '"' {
                i = Self::scan_string(&chars, i, i, &mut b);
                continue;
            }
            if c.is_alphabetic() || c == '_' {
                let mut j = i;
                while j < count && is_ident_char(chars[j]) {
                    j += 1;
                }
                let word = s(&chars[i..j]);
                if word.chars().count() <= 2
                    && word.to_lowercase().chars().all(|c| "rbfu".contains(c))
                    && j < count
                    && (chars[j] == '\'' || chars[j] == '"')
                {
                    i = Self::scan_string(&chars, j, i, &mut b);
                    continue;
                }
                if PYTHON_KEYWORDS.contains(&word.as_str()) {
                    b.emit(TokenKind::Keyword, word);
                } else {
                    b.plain_str(&word);
                }
                i = j;
                continue;
            }
            if c.is_numeric() {
                let mut j = i;
                while j < count && (chars[j].is_ascii_hexdigit() || "xXoObB._eEjJ".contains(chars[j])) {
                    j += 1;
                }
                b.emit(TokenKind::Number, s(&chars[i..j]));
                i = j;
                continue;
            }
            b.plain_char(c);
            i += 1;
        }
        b.finish()
    }
}
