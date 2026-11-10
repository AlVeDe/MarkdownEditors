//! The line pass of the Markdown highlighter.
//!
//! Each line is analyzed with only two inputs: its own UTF-16 code units and
//! the `LineState` the previous line left behind (open fence, `$$` block,
//! front matter, HTML comment, plus flags that decide between "paragraph
//! continuation", "indented code" and "setext underline").
//!
//! Inline syntax is not colored here: CommonMark parses it per paragraph.
//! The line pass only records where a line's inline content is and whether it
//! continues the paragraph above (`InlineLine`); the inline analyzer colors
//! whole paragraphs afterwards.
//!
//! The analyzer is deliberately not a full CommonMark parser. It colors what
//! a writer sees and errs on the side of being local and fast. The preview is
//! the source of truth for rendering.

use super::scan::{self, ch, ch::*};
use super::{ContextRegion, EditorContext, FontTraits, HighlightSpan, SpanStyle};
use crate::render::syntax::tokenizer_for;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FenceInfo {
    pub marker: u16,
    pub length: usize,
    pub language: Option<String>,
    /// True when a tokenizer exists for `language`; such blocks are tokenized
    /// as a whole.
    pub is_tokenized: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockKind {
    Normal,
    Fence(FenceInfo),
    DisplayMath,
    FrontMatter,
    HtmlComment,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LineState {
    pub block: BlockKind,
    pub paragraph: bool,
    pub list: bool,
    pub after_blank: bool,
    pub paragraph_quotes: i32,
}

impl Default for LineState {
    fn default() -> Self {
        LineState { block: BlockKind::Normal, paragraph: false, list: false, after_blank: true, paragraph_quotes: -1 }
    }
}

impl LineState {
    fn new(block: BlockKind, paragraph: bool, list: bool, after_blank: bool) -> Self {
        LineState { block, paragraph, list, after_blank, paragraph_quotes: -1 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InlineKind {
    #[default]
    None,
    Paragraph,
    Single,
    TableRow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct InlineLine {
    pub kind: InlineKind,
    pub start: usize,
    pub end: usize,
    pub traits: FontTraits,
    pub continues: bool,
}

const MERMAID_KEYWORDS: &[&str] = &[
    "graph", "flowchart", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram", "journey",
    "gantt", "pie", "gitGraph", "mindmap", "timeline", "quadrantChart", "requirementDiagram",
    "C4Context", "sankey", "xychart", "block", "packet", "architecture", "kanban", "subgraph", "end",
    "participant", "actor", "note", "Note", "loop", "alt", "else", "opt", "par", "and", "rect",
    "critical", "break", "activate", "deactivate", "autonumber", "title", "section", "class",
    "classDef", "style", "linkStyle", "click", "direction", "dateFormat", "axisFormat", "state",
    "commit", "branch", "checkout", "merge", "over", "left", "right", "of", "TB", "TD", "BT", "RL",
    "LR",
];

#[derive(Default)]
pub struct LineAnalyzer<'a> {
    pub collects_spans: bool,
    pub collects_regions: bool,
    pub spans: Vec<HighlightSpan>,
    pub regions: Vec<ContextRegion>,
    pub inline_line: InlineLine,
    c: &'a [u16],
    base: usize,
}

impl<'a> LineAnalyzer<'a> {
    pub fn new(collects_spans: bool, collects_regions: bool) -> Self {
        LineAnalyzer { collects_spans, collects_regions, ..Default::default() }
    }

    /// Analyzes `chars` (one line, no terminator) starting in `state`;
    /// returns the state the next line starts in and sets `inline_line`.
    pub fn analyze(
        &mut self,
        chars: &'a [u16],
        start: usize,
        state: &LineState,
        is_first_line: bool,
        next_line: Option<&[u16]>,
    ) -> LineState {
        self.c = chars;
        self.base = start;
        self.inline_line = InlineLine::default();
        let n = self.c.len();
        match &state.block {
            BlockKind::Normal => self.normal_line(state, is_first_line, next_line),
            BlockKind::FrontMatter => {
                self.region(0, n, EditorContext::FrontMatter);
                if self.is_front_matter_delimiter(true) {
                    self.span(0, n, SpanStyle::Marker);
                    return LineState::new(BlockKind::Normal, false, false, true);
                }
                self.front_matter_line();
                state.clone()
            }
            BlockKind::Fence(fence) => {
                self.span(0, n, SpanStyle::CodeBlock);
                if self.is_fence_closer(fence) {
                    self.span(0, n, SpanStyle::Marker);
                    return LineState::new(BlockKind::Normal, false, state.list, false);
                }
                match fence.language.as_deref() {
                    Some("mermaid") => {
                        self.region(0, n, EditorContext::Mermaid);
                        self.mermaid_line();
                    }
                    Some("math") | Some("latex") | Some("tex") => {
                        self.region(0, n, EditorContext::DisplayMath);
                        self.math_content(0, n);
                    }
                    _ => self.region(0, n, EditorContext::CodeBlock(fence.language.clone())),
                }
                state.clone()
            }
            BlockKind::DisplayMath => {
                if let Some(close) = scan::find(self.c, DOLLAR, DOLLAR, 0, n) {
                    self.region(0, close, EditorContext::DisplayMath);
                    self.math_content(0, close);
                    self.span(close, 2, SpanStyle::Marker);
                    let opens = self.inline_content(close + 2, n, InlineKind::Single, FontTraits::NONE, false);
                    return LineState::new(
                        if opens { BlockKind::HtmlComment } else { BlockKind::Normal },
                        false,
                        state.list,
                        false,
                    );
                }
                self.region(0, n, EditorContext::DisplayMath);
                self.math_content(0, n);
                state.clone()
            }
            BlockKind::HtmlComment => {
                if let Some(close) = scan::find_comment_end(self.c, 0, n) {
                    self.region(0, close, EditorContext::HtmlComment);
                    self.span(0, close + 3, SpanStyle::Comment);
                    let opens = self.inline_content(close + 3, n, InlineKind::Single, FontTraits::NONE, false);
                    return LineState::new(
                        if opens { BlockKind::HtmlComment } else { BlockKind::Normal },
                        false,
                        state.list,
                        false,
                    );
                }
                self.region(0, n, EditorContext::HtmlComment);
                self.span(0, n, SpanStyle::Comment);
                state.clone()
            }
        }
    }

    fn after(opens_comment: bool, paragraph: bool, list: bool) -> LineState {
        LineState::new(
            if opens_comment { BlockKind::HtmlComment } else { BlockKind::Normal },
            paragraph && !opens_comment,
            list,
            false,
        )
    }

    fn normal_line(&mut self, state: &LineState, is_first_line: bool, next_line: Option<&[u16]>) -> LineState {
        let c = self.c;
        let n = c.len();
        if is_first_line && self.is_front_matter_delimiter(false) {
            self.span(0, n, SpanStyle::Marker);
            self.region(0, n, EditorContext::FrontMatter);
            return LineState::new(BlockKind::FrontMatter, false, false, false);
        }
        let mut pos = 0;
        let mut columns = 0;
        while pos < n && ch::is_space(c[pos]) {
            columns += if c[pos] == TAB { 4 - columns % 4 } else { 1 };
            pos += 1;
        }
        if pos == n {
            return LineState::new(BlockKind::Normal, false, state.list, true);
        }
        if columns >= 4 && !state.paragraph && !state.list {
            self.span(0, n, SpanStyle::CodeBlock);
            self.region(0, n, EditorContext::CodeBlock(None));
            return LineState::new(BlockKind::Normal, false, false, false);
        }
        let at_margin = columns < 2;
        let list_after_block = if at_margin { false } else { state.list };

        let mut quotes = 0i32;
        while pos < n && c[pos] == GT {
            self.span(pos, 1, SpanStyle::QuoteMarker);
            pos += 1;
            quotes += 1;
            while pos < n && ch::is_space(c[pos]) {
                pos += 1;
            }
        }
        let quoted = quotes > 0;
        if quoted {
            self.span(pos, n - pos, SpanStyle::Quote);
            if pos == n {
                return Self::after(false, false, list_after_block);
            }
        }

        if !quoted {
            if let Some((fence, marker_end)) = self.fence_opener(pos) {
                self.span(0, n, SpanStyle::CodeBlock);
                self.span(pos, marker_end - pos, SpanStyle::Marker);
                self.span(marker_end, n - marker_end, SpanStyle::FenceInfo);
                self.region(marker_end, n, EditorContext::FenceInfo);
                return LineState::new(BlockKind::Fence(fence), false, list_after_block, false);
            }
        }

        if !quoted && pos + 1 < n && c[pos] == DOLLAR && c[pos + 1] == DOLLAR {
            self.span(pos, 2, SpanStyle::Marker);
            if let Some(close) = scan::find(c, DOLLAR, DOLLAR, pos + 2, n) {
                self.region(pos + 2, close, EditorContext::DisplayMath);
                self.math_content(pos + 2, close);
                self.span(close, 2, SpanStyle::Marker);
                let opens = self.inline_content(close + 2, n, InlineKind::Single, FontTraits::NONE, false);
                return Self::after(opens, false, list_after_block);
            }
            self.region(pos + 2, n, EditorContext::DisplayMath);
            self.math_content(pos + 2, n);
            return LineState::new(BlockKind::DisplayMath, false, list_after_block, false);
        }

        if c[pos] == HASH {
            let mut hashes = pos;
            while hashes < n && c[hashes] == HASH {
                hashes += 1;
            }
            if hashes - pos <= 6 && (hashes == n || ch::is_space(c[hashes])) {
                self.span(pos, hashes - pos, SpanStyle::Marker);
                let mut end = n;
                while end > hashes && ch::is_space(c[end - 1]) {
                    end -= 1;
                }
                let mut closing = end;
                while closing > hashes && c[closing - 1] == HASH {
                    closing -= 1;
                }
                if closing < end && (closing == hashes || ch::is_space(c[closing - 1])) {
                    self.span(closing, end - closing, SpanStyle::Marker);
                    end = closing;
                }
                self.span(hashes, end - hashes, SpanStyle::Heading);
                let opens = self.inline_content(hashes, end, InlineKind::Single, FontTraits::BOLD, false);
                return Self::after(opens, false, list_after_block);
            }
        }

        if !quoted && state.paragraph && columns < 4 && is_setext_underline(c) {
            self.span(pos, n - pos, SpanStyle::Heading);
            return Self::after(false, false, state.list);
        }

        if self.is_thematic_break(pos) {
            self.span(pos, n - pos, SpanStyle::Marker);
            return Self::after(false, false, list_after_block);
        }

        if let Some(marker_end) = self.list_marker(pos) {
            self.span(pos, marker_end - pos, SpanStyle::ListMarker);
            let mut text = marker_end;
            while text < n && ch::is_space(c[text]) {
                text += 1;
            }
            if text + 2 < n
                && c[text] == LBRACKET
                && c[text + 2] == RBRACKET
                && (c[text + 1] == SPACE || c[text + 1] | 0x20 == 0x78)
                && (text + 3 == n || ch::is_space(c[text + 3]))
            {
                self.span(text, 3, SpanStyle::TaskBox);
                text += 3;
            }
            let opens = self.inline_content(text, n, InlineKind::Paragraph, FontTraits::NONE, false);
            let mut next = Self::after(opens, false, true);
            next.paragraph_quotes = if opens { -1 } else { quotes };
            return next;
        }

        if c[pos] == PIPE {
            if self.is_table_delimiter_row(pos) {
                self.span(pos, n - pos, SpanStyle::Marker);
                return Self::after(false, false, list_after_block);
            }
            let opens = self.inline_content(pos, n, InlineKind::TableRow, FontTraits::NONE, false);
            return Self::after(opens, false, list_after_block);
        }

        if c[pos] == LBRACKET && columns < 4 && self.reference_definition(pos) {
            return Self::after(false, false, list_after_block);
        }

        let list = if at_margin && state.after_blank { false } else { state.list };
        let mut traits = FontTraits::NONE;
        if !quoted && columns < 4 {
            if let Some(next) = next_line {
                if is_setext_underline(next) {
                    self.span(pos, n - pos, SpanStyle::Heading);
                    traits = FontTraits::BOLD;
                }
            }
        }
        let continues = state.paragraph_quotes >= 0 && quotes <= state.paragraph_quotes;
        let opens = self.inline_content(pos, n, InlineKind::Paragraph, traits, continues);
        let mut next = Self::after(opens, !quoted, list);
        next.paragraph_quotes = if opens {
            -1
        } else if continues {
            state.paragraph_quotes
        } else {
            quotes
        };
        next
    }

    fn is_front_matter_delimiter(&self, closing: bool) -> bool {
        let c = self.c;
        let mut end = c.len();
        while end > 0 && ch::is_space(c[end - 1]) {
            end -= 1;
        }
        if end != 3 {
            return false;
        }
        if c[0] == DASH && c[1] == DASH && c[2] == DASH {
            return true;
        }
        closing && c[0] == DOT && c[1] == DOT && c[2] == DOT
    }

    fn fence_opener(&self, pos: usize) -> Option<(FenceInfo, usize)> {
        let c = self.c;
        let n = c.len();
        let marker = c[pos];
        if marker != BACKTICK && marker != TILDE {
            return None;
        }
        let mut end = pos;
        while end < n && c[end] == marker {
            end += 1;
        }
        if end - pos < 3 {
            return None;
        }
        if marker == BACKTICK && c[end..].contains(&BACKTICK) {
            return None;
        }
        let mut word_start = end;
        while word_start < n && (ch::is_space(c[word_start]) || c[word_start] == LBRACE || c[word_start] == DOT) {
            word_start += 1;
        }
        let mut word_end = word_start;
        while word_end < n && !ch::is_space(c[word_end]) && c[word_end] != LBRACE && c[word_end] != RBRACE {
            word_end += 1;
        }
        let language = (word_end > word_start).then(|| String::from_utf16_lossy(&c[word_start..word_end]).to_lowercase());
        let is_tokenized = tokenizer_for(language.as_deref()).is_some();
        Some((FenceInfo { marker, length: end - pos, language, is_tokenized }, end))
    }

    fn is_fence_closer(&self, fence: &FenceInfo) -> bool {
        let c = self.c;
        let n = c.len();
        let mut pos = 0;
        while pos < n && ch::is_space(c[pos]) {
            pos += 1;
        }
        let mut end = pos;
        while end < n && c[end] == fence.marker {
            end += 1;
        }
        if end - pos < fence.length {
            return false;
        }
        while end < n && ch::is_space(c[end]) {
            end += 1;
        }
        end == n
    }

    fn is_thematic_break(&self, pos: usize) -> bool {
        let marker = self.c[pos];
        if marker != DASH && marker != STAR && marker != UNDERSCORE {
            return false;
        }
        let mut count = 0;
        for &x in &self.c[pos..] {
            if x == marker {
                count += 1;
            } else if !ch::is_space(x) {
                return false;
            }
        }
        count >= 3
    }

    fn list_marker(&self, pos: usize) -> Option<usize> {
        let c = self.c;
        let n = c.len();
        let mut end = pos;
        if c[pos] == DASH || c[pos] == STAR || c[pos] == PLUS {
            end = pos + 1;
        } else {
            while end < n && end - pos < 9 && ch::is_digit(c[end]) {
                end += 1;
            }
            if !(end > pos && end < n && (c[end] == DOT || c[end] == RPAREN)) {
                return None;
            }
            end += 1;
        }
        (end == n || ch::is_space(c[end])).then_some(end)
    }

    fn is_table_delimiter_row(&self, pos: usize) -> bool {
        let mut dashes = false;
        for &x in &self.c[pos..] {
            match x {
                DASH => dashes = true,
                PIPE | COLON | SPACE | TAB => continue,
                _ => return false,
            }
        }
        dashes
    }

    fn reference_definition(&mut self, pos: usize) -> bool {
        let c = self.c;
        let n = c.len();
        let Some(close) = self.match_bracket(pos, n) else { return false };
        if !(close + 1 < n && c[close + 1] == COLON && close > pos + 1) {
            return false;
        }
        self.span(pos, 1, SpanStyle::Marker);
        self.span(pos + 1, close - pos - 1, SpanStyle::Link);
        self.span(close, 2, SpanStyle::Marker);
        if c[pos + 1] == CARET {
            let _ = self.inline_content(close + 2, n, InlineKind::Single, FontTraits::NONE, false);
        } else {
            let mut dest = close + 2;
            while dest < n && ch::is_space(c[dest]) {
                dest += 1;
            }
            self.destination_and_title(dest, n);
        }
        true
    }

    fn front_matter_line(&mut self) {
        let c = self.c;
        let n = c.len();
        let mut pos = 0;
        while pos < n && ch::is_space(c[pos]) {
            pos += 1;
        }
        if pos >= n {
            return;
        }
        if c[pos] == HASH {
            self.span(pos, n - pos, SpanStyle::Comment);
            return;
        }
        if c[pos] == DASH && (pos + 1 == n || ch::is_space(c[pos + 1])) {
            self.span(pos, 1, SpanStyle::ListMarker);
            pos += 1;
            while pos < n && ch::is_space(c[pos]) {
                pos += 1;
            }
        }
        let mut colon = pos;
        while colon < n && c[colon] != COLON && c[colon] != SPACE {
            colon += 1;
        }
        if colon < n && colon > pos && c[colon] == COLON && (colon + 1 == n || ch::is_space(c[colon + 1])) {
            self.span(pos, colon - pos, SpanStyle::FrontMatterKey);
            self.span(colon, 1, SpanStyle::Marker);
            self.span(colon + 1, n - colon - 1, SpanStyle::FrontMatterValue);
        } else {
            self.span(pos, n - pos, SpanStyle::FrontMatterValue);
        }
    }

    fn inline_content(&mut self, from: usize, to: usize, kind: InlineKind, traits: FontTraits, continues: bool) -> bool {
        let mut end = to;
        let mut opens = false;
        if let Some(open) = self.unclosed_comment(from, to) {
            self.span(open, to - open, SpanStyle::Comment);
            self.region(open + 4, to, EditorContext::HtmlComment);
            end = open;
            opens = true;
        }
        if end > from || kind == InlineKind::Paragraph {
            self.inline_line = InlineLine { kind, start: from, end: end.max(from), traits, continues };
        }
        opens
    }

    fn unclosed_comment(&self, from: usize, to: usize) -> Option<usize> {
        let c = self.c;
        let mut i = from;
        while i < to {
            match c[i] {
                BACKSLASH => i += if i + 1 < to && ch::is_punctuation(c[i + 1]) { 2 } else { 1 },
                BACKTICK => {
                    let run = scan::run_length(c, i, to);
                    i = scan::find_run(c, BACKTICK, run, i + run, to).map(|p| p + run).unwrap_or(i + run);
                }
                DOLLAR => {
                    if i + 1 < to && c[i + 1] == DOLLAR {
                        i = scan::find(c, DOLLAR, DOLLAR, i + 2, to).map(|p| p + 2).unwrap_or(i + 2);
                    } else {
                        i = self.inline_math_closer(i, to).map(|p| p + 1).unwrap_or(i + 1);
                    }
                }
                LT if scan::has_prefix(c, "<!--", i, to) => match scan::find_comment_end(c, i + 4, to) {
                    None => return Some(i),
                    Some(close) => i = close + 3,
                },
                _ => i += 1,
            }
        }
        None
    }

    fn inline_math_closer(&self, i: usize, to: usize) -> Option<usize> {
        let c = self.c;
        if !(i + 1 < to && !ch::is_space(c[i + 1]) && c[i + 1] != DOLLAR) {
            return None;
        }
        let mut q = i + 2;
        while q < to {
            if c[q] == BACKSLASH {
                q += 2;
                continue;
            }
            if c[q] == DOLLAR && !ch::is_space(c[q - 1]) && !(q + 1 < to && ch::is_digit(c[q + 1])) {
                return Some(q);
            }
            q += 1;
        }
        None
    }

    fn math_content(&mut self, from: usize, to: usize) {
        if to <= from {
            return;
        }
        self.span(from, to - from, SpanStyle::Math);
        let c = self.c;
        let mut i = from;
        while i < to {
            if c[i] == BACKSLASH && i + 1 < to {
                let mut end = i + 1;
                while end < to && ch::is_letter(c[end]) {
                    end += 1;
                }
                if end == i + 1 {
                    end += 1;
                }
                self.span(i, end - i, SpanStyle::MathCommand);
                i = end;
            } else {
                i += 1;
            }
        }
    }

    fn destination_and_title(&mut self, from: usize, to: usize) {
        let c = self.c;
        let mut title_start = to;
        let mut i = from;
        while i + 1 < to {
            if ch::is_space(c[i]) && (c[i + 1] == QUOTE || c[i + 1] == APOSTROPHE || c[i + 1] == LPAREN) {
                title_start = i + 1;
                break;
            }
            i += 1;
        }
        self.span(from, title_start.saturating_sub(from), SpanStyle::Url);
        self.span(title_start, to.saturating_sub(title_start), SpanStyle::LinkTitle);
    }

    fn match_bracket(&self, open: usize, to: usize) -> Option<usize> {
        let c = self.c;
        let mut depth = 0i32;
        let mut i = open;
        while i < to {
            match c[i] {
                BACKSLASH => {
                    i += 2;
                    continue;
                }
                BACKTICK => {
                    let r = scan::run_length(c, i, to);
                    i = scan::find_run(c, BACKTICK, r, i + r, to).map(|p| p + r).unwrap_or(i + r);
                    continue;
                }
                LBRACKET => depth += 1,
                RBRACKET => {
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

    fn mermaid_line(&mut self) {
        let c = self.c;
        let n = c.len();
        let mut p = 0;
        while p < n && ch::is_space(c[p]) {
            p += 1;
        }
        if scan::has_prefix(c, "%%", p, n) {
            self.span(p, n - p, SpanStyle::Comment);
            return;
        }
        while p < n {
            let x = c[p];
            if ch::is_letter(x) {
                let mut end = p;
                while end < n && (ch::is_letter(c[end]) || ch::is_digit(c[end]) || c[end] == UNDERSCORE) {
                    end += 1;
                }
                let word = String::from_utf16_lossy(&c[p..end]);
                if MERMAID_KEYWORDS.contains(&word.as_str()) {
                    self.span(p, end - p, SpanStyle::MermaidKeyword);
                }
                p = end;
            } else if x == LBRACKET || x == LPAREN || x == LBRACE || x == QUOTE || x == PIPE {
                let closer = match x {
                    LBRACKET => RBRACKET,
                    LPAREN => RPAREN,
                    LBRACE => RBRACE,
                    _ => x,
                };
                let mut depth = 0i32;
                let mut q = p;
                let mut close = None;
                while q < n {
                    if c[q] == closer && (closer != x || q > p) {
                        depth -= 1;
                        if depth <= 0 {
                            close = Some(q);
                            break;
                        }
                    } else if c[q] == x {
                        depth += 1;
                    }
                    q += 1;
                }
                if let Some(close) = close {
                    self.span(p, close - p + 1, SpanStyle::MermaidText);
                    p = close + 1;
                } else {
                    p += 1;
                }
            } else if x == DASH || x == EQUALS || x == DOT || x == LT || x == GT {
                let mut end = p;
                let mut has_line = false;
                while end < n && [DASH, EQUALS, DOT, LT, GT].contains(&c[end]) {
                    if c[end] == DASH || c[end] == EQUALS {
                        has_line = true;
                    }
                    end += 1;
                }
                if end - p >= 2 && has_line {
                    self.span(p, end - p, SpanStyle::MermaidArrow);
                }
                p = end;
            } else {
                p += 1;
            }
        }
    }

    fn span(&mut self, from: usize, length: usize, style: SpanStyle) {
        if !self.collects_spans || length == 0 {
            return;
        }
        self.spans.push(HighlightSpan { location: self.base + from, length, style });
    }

    fn region(&mut self, from: usize, end: usize, context: EditorContext) {
        if !self.collects_regions {
            return;
        }
        self.regions.push(ContextRegion { location: self.base + from, end: self.base + end, context });
    }
}

/// `===` or `--` (at least two dashes, so typing a list item under a
/// paragraph does not flash a heading).
pub fn is_setext_underline(line: &[u16]) -> bool {
    let n = line.len();
    let mut pos = 0;
    while pos < n && pos < 3 && line[pos] == SPACE {
        pos += 1;
    }
    if !(pos < n && (line[pos] == EQUALS || line[pos] == DASH)) {
        return false;
    }
    let marker = line[pos];
    let mut end = pos;
    while end < n && line[end] == marker {
        end += 1;
    }
    let run = end - pos;
    while end < n && ch::is_space(line[end]) {
        end += 1;
    }
    end == n && (marker == EQUALS || run >= 2)
}
