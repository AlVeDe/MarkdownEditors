//! The inline pass of the Markdown highlighter, run per paragraph.
//!
//! In CommonMark the paragraph is the unit of inline parsing: `**bold\n
//! continued**` is bold, a code span may contain a line break, and link text
//! may wrap. The driver joins the inline content of consecutive lines of one
//! paragraph into a buffer (prefixes like `> ` or list markers left out,
//! lines separated by `\n`) and hands it here with segments that map buffer
//! offsets back to the document.
//!
//! The analyzer follows CommonMark's precedence: one left-to-right scan
//! consumes code spans, autolinks, raw HTML, inline math and backslash
//! escapes atomically, collects `[` / `![` openers on a bracket stack and
//! `*` `_` `~` runs on a delimiter stack; a `]` resolves a link, and the
//! remaining delimiters are paired at the end ("process emphasis" with
//! flanking rules and the rule of 3).

use super::scan::{self, ch, ch::*};
use super::{ContextRegion, EditorContext, FontTraits, HighlightSpan, SpanStyle};

#[derive(Debug, Clone, Copy)]
pub struct InlineSegment {
    pub buffer_start: usize,
    pub length: usize,
    pub location: usize,
    pub traits: FontTraits,
}

impl InlineSegment {
    fn buffer_end(&self) -> usize {
        self.buffer_start + self.length
    }
}

/// A `$` that opens inline math without a closer on its line.
#[derive(Debug, Clone, Copy)]
pub struct UnclosedMath {
    pub location: usize,
    pub line_end: usize,
}

#[derive(Clone, Copy)]
struct Pending {
    start: usize,
    length: usize,
    style: SpanStyle,
}

#[derive(Clone, Copy)]
struct Delimiter {
    position: usize,
    marker: u16,
    length: usize,
    count: usize,
    can_open: bool,
    can_close: bool,
}

#[derive(Clone, Copy)]
struct Bracket {
    position: usize,
    image: bool,
    active: bool,
    delimiter_bottom: usize,
}

pub struct InlineAnalyzer {
    pub collects_spans: bool,
    pub collects_regions: bool,
    pub spans: Vec<HighlightSpan>,
    pub regions: Vec<ContextRegion>,
    pub unclosed_math: Vec<UnclosedMath>,
    c: Vec<u16>,
    segments: Vec<InlineSegment>,
    containers: Vec<Pending>,
    leaves: Vec<Pending>,
    emphasis: Vec<(usize, usize, FontTraits)>,
    delimiters: Vec<Delimiter>,
    brackets: Vec<Bracket>,
    no_code_closer: [usize; 32],
}

fn is_whitespace(x: u16) -> bool {
    x == SPACE || x == TAB || x == NEWLINE || x == CR || x == 0xA0
}

impl InlineAnalyzer {
    pub fn new(collects_spans: bool, collects_regions: bool) -> Self {
        InlineAnalyzer {
            collects_spans,
            collects_regions,
            spans: vec![],
            regions: vec![],
            unclosed_math: vec![],
            c: vec![],
            segments: vec![],
            containers: vec![],
            leaves: vec![],
            emphasis: vec![],
            delimiters: vec![],
            brackets: vec![],
            no_code_closer: [usize::MAX; 32],
        }
    }

    /// Analyzes the joined content of one unit. Output accumulates.
    pub fn analyze(&mut self, chars: Vec<u16>, segments: Vec<InlineSegment>) {
        self.c = chars;
        self.segments = segments;
        self.containers.clear();
        self.leaves.clear();
        self.emphasis.clear();
        self.delimiters.clear();
        self.brackets.clear();
        self.no_code_closer = [usize::MAX; 32];

        let n = self.c.len();
        let mut i = 0;
        while i < n {
            match self.c[i] {
                BACKSLASH => {
                    if i + 1 < n && ch::is_punctuation(self.c[i + 1]) {
                        self.leaf(i, 1, SpanStyle::Marker);
                        i += 2;
                    } else {
                        i += 1;
                    }
                }
                BACKTICK => {
                    let run = scan::run_length(&self.c, i, n);
                    if let Some(close) = self.code_span_closer(run, i + run) {
                        self.leaf(i, run, SpanStyle::Marker);
                        self.leaf(i + run, close - i - run, SpanStyle::InlineCode);
                        self.leaf(close, run, SpanStyle::Marker);
                        self.region(i + run, close, EditorContext::InlineCode);
                        i = close + run;
                    } else {
                        i += run;
                    }
                }
                DOLLAR => i = self.inline_math(i),
                LT => i = self.angle_bracket(i),
                BANG if i + 1 < n && self.c[i + 1] == LBRACKET => {
                    self.brackets.push(Bracket {
                        position: i + 1,
                        image: true,
                        active: true,
                        delimiter_bottom: self.delimiters.len(),
                    });
                    i += 2;
                }
                LBRACKET => {
                    self.brackets.push(Bracket {
                        position: i,
                        image: false,
                        active: true,
                        delimiter_bottom: self.delimiters.len(),
                    });
                    i += 1;
                }
                RBRACKET => i = self.close_bracket(i),
                STAR | UNDERSCORE | TILDE => i = self.push_delimiter(i),
                0x68 | 0x77 => {
                    let to = self.segment_end(i);
                    let url = if i == 0 || !ch::is_word(self.c[i - 1]) { scan::bare_url(&self.c, i, to) } else { None };
                    if let Some(end) = url {
                        self.leaf(i, end - i, SpanStyle::Link);
                        i = end;
                    } else {
                        i += 1;
                    }
                }
                _ => i += 1,
            }
        }
        self.process_emphasis(0);
        self.emit();
    }

    /// A table row: each cell is its own unit and the pipes are markers.
    pub fn analyze_table_row(&mut self, row: &[u16], location: usize) {
        let n = row.len();
        let mut cell_start = 0;
        let mut i = 0;
        while i < n {
            if row[i] == BACKSLASH {
                i += 2;
                continue;
            }
            if row[i] == PIPE {
                self.cell(row, cell_start, i, location);
                if self.collects_spans {
                    self.spans.push(HighlightSpan { location: location + i, length: 1, style: SpanStyle::Marker });
                }
                cell_start = i + 1;
            }
            i += 1;
        }
        self.cell(row, cell_start, n, location);
    }

    fn cell(&mut self, row: &[u16], from: usize, to: usize, location: usize) {
        if to <= from {
            return;
        }
        self.analyze(
            row[from..to].to_vec(),
            vec![InlineSegment { buffer_start: 0, length: to - from, location: location + from, traits: FontTraits::NONE }],
        );
    }

    fn code_span_closer(&mut self, length: usize, from: usize) -> Option<usize> {
        let cacheable = length < self.no_code_closer.len();
        if cacheable && from >= self.no_code_closer[length] {
            return None;
        }
        let found = scan::find_run(&self.c, BACKTICK, length, from, self.c.len());
        if found.is_none() && cacheable {
            self.no_code_closer[length] = self.no_code_closer[length].min(from);
        }
        found
    }

    fn contains_code_span(&mut self, from: usize, to: usize) -> bool {
        let mut q = from;
        while q < to {
            if self.c[q] == BACKTICK {
                let r = scan::run_length(&self.c, q, self.c.len());
                if self.code_span_closer(r, q + r).is_some() {
                    return true;
                }
                q += r;
            } else {
                q += 1;
            }
        }
        false
    }

    fn inline_math(&mut self, i: usize) -> usize {
        let to = self.segment_end(i);
        if i + 1 < to && self.c[i + 1] == DOLLAR {
            let Some(close) = scan::find(&self.c, DOLLAR, DOLLAR, i + 2, to) else { return i + 2 };
            if self.contains_code_span(i + 2, close) {
                return i + 2;
            }
            self.leaf(i, 2, SpanStyle::Marker);
            self.math_content(i + 2, close);
            self.leaf(close, 2, SpanStyle::Marker);
            self.region(i + 2, close, EditorContext::DisplayMath);
            return close + 2;
        }
        let close = self.inline_math_closer(i, to);
        let close = match close {
            Some(c) if !self.contains_code_span(i + 1, c) => c,
            _ => {
                if i + 1 < to && !ch::is_space(self.c[i + 1]) && self.collects_regions {
                    let location = self.document(i);
                    let line_end = self.document(to);
                    self.unclosed_math.push(UnclosedMath { location, line_end });
                }
                return i + 1;
            }
        };
        self.leaf(i, 1, SpanStyle::Marker);
        self.math_content(i + 1, close);
        self.leaf(close, 1, SpanStyle::Marker);
        self.region(i + 1, close, EditorContext::InlineMath);
        close + 1
    }

    fn inline_math_closer(&self, i: usize, to: usize) -> Option<usize> {
        let c = &self.c;
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
        self.leaf(from, to - from, SpanStyle::Math);
        let mut i = from;
        while i < to {
            if self.c[i] == BACKSLASH && i + 1 < to {
                let mut end = i + 1;
                while end < to && ch::is_letter(self.c[end]) {
                    end += 1;
                }
                if end == i + 1 {
                    end += 1;
                }
                self.leaf(i, end - i, SpanStyle::MathCommand);
                i = end;
            } else {
                i += 1;
            }
        }
    }

    fn angle_bracket(&mut self, i: usize) -> usize {
        let to = self.segment_end(i);
        if scan::has_prefix(&self.c, "<!--", i, to) {
            let Some(close) = scan::find_comment_end(&self.c, i + 4, to) else { return i + 1 };
            self.leaf(i, close + 3 - i, SpanStyle::Comment);
            self.region(i + 4, close, EditorContext::HtmlComment);
            return close + 3;
        }
        if let Some(end) = scan::autolink(&self.c, i, to) {
            self.leaf(i, 1, SpanStyle::Marker);
            self.leaf(i + 1, end - i - 2, SpanStyle::Link);
            self.leaf(end - 1, 1, SpanStyle::Marker);
            return end;
        }
        if let Some(end) = scan::html_tag(&self.c, i, to) {
            self.leaf(i, end - i, SpanStyle::Html);
            return end;
        }
        i + 1
    }

    fn close_bracket(&mut self, close: usize) -> usize {
        let Some(opener) = self.brackets.pop() else { return close + 1 };
        if !opener.active {
            return close + 1;
        }
        let n = self.c.len();
        let open = opener.position;
        let start = if opener.image { open - 1 } else { open };

        if !opener.image && open + 1 < close && self.c[open + 1] == CARET {
            self.delimiters.truncate(opener.delimiter_bottom);
            self.containers.push(Pending { start: open, length: close - open + 1, style: SpanStyle::Link });
            return close + 1;
        }

        let text_style = if opener.image { SpanStyle::Image } else { SpanStyle::Link };
        let mut end = None;
        if close + 1 < n && self.c[close + 1] == LPAREN {
            if let Some(paren) = scan::match_paren(&self.c, close + 1, n) {
                self.leaf(close, 2, SpanStyle::Marker);
                self.destination_and_title(close + 2, paren);
                self.leaf(paren, 1, SpanStyle::Marker);
                end = Some(paren + 1);
            }
        } else if close + 1 < n && self.c[close + 1] == LBRACKET {
            if let Some(ref_close) = self.c[close + 2..n].iter().position(|&x| x == RBRACKET).map(|p| p + close + 2) {
                self.leaf(close, 2, SpanStyle::Marker);
                self.leaf(close + 2, ref_close - close - 2, SpanStyle::Url);
                self.leaf(ref_close, 1, SpanStyle::Marker);
                end = Some(ref_close + 1);
            }
        }
        let Some(end) = end else { return close + 1 };

        self.leaf(start, open + 1 - start, SpanStyle::Marker);
        self.containers.push(Pending { start: open + 1, length: close - open - 1, style: text_style });
        self.process_emphasis(opener.delimiter_bottom);
        self.delimiters.truncate(opener.delimiter_bottom);
        if !opener.image {
            for b in self.brackets.iter_mut().filter(|b| !b.image) {
                b.active = false;
            }
        }
        end
    }

    fn destination_and_title(&mut self, from: usize, to: usize) {
        let mut title_start = to;
        let mut i = from;
        while i + 1 < to {
            let x = self.c[i];
            let y = self.c[i + 1];
            if (ch::is_space(x) || x == NEWLINE) && (y == QUOTE || y == APOSTROPHE || y == LPAREN) {
                title_start = i + 1;
                break;
            }
            i += 1;
        }
        self.leaf(from, title_start.saturating_sub(from), SpanStyle::Url);
        self.leaf(title_start, to.saturating_sub(title_start), SpanStyle::LinkTitle);
    }

    fn push_delimiter(&mut self, i: usize) -> usize {
        let n = self.c.len();
        let marker = self.c[i];
        let run = scan::run_length(&self.c, i, n);
        if marker == TILDE && run > 2 {
            return i + run;
        }
        let before = if i > 0 { self.c[i - 1] } else { NEWLINE };
        let after = if i + run < n { self.c[i + run] } else { NEWLINE };
        let before_space = is_whitespace(before);
        let after_space = is_whitespace(after);
        let before_punct = ch::is_punctuation(before);
        let after_punct = ch::is_punctuation(after);
        let left = !after_space && (!after_punct || before_space || before_punct);
        let right = !before_space && (!before_punct || after_space || after_punct);
        let mut can_open = left;
        let mut can_close = right;
        if marker == UNDERSCORE {
            can_open = left && (!right || before_punct);
            can_close = right && (!left || after_punct);
        }
        if can_open || can_close {
            self.delimiters.push(Delimiter { position: i, marker, length: run, count: run, can_open, can_close });
        }
        i + run
    }

    fn process_emphasis(&mut self, bottom: usize) {
        let mut openers_bottom = [bottom; 18];
        let mut ci = bottom;
        while ci < self.delimiters.len() {
            let closer = self.delimiters[ci];
            if !closer.can_close || closer.count == 0 {
                ci += 1;
                continue;
            }
            let kind = if closer.marker == STAR {
                0
            } else if closer.marker == UNDERSCORE {
                1
            } else {
                2
            };
            let key = kind * 6 + (closer.length % 3) * 2 + usize::from(closer.can_open);
            let mut found = None;
            let mut oi = ci as isize - 1;
            while oi >= openers_bottom[key] as isize {
                let o = self.delimiters[oi as usize];
                if o.marker == closer.marker && o.can_open && o.count > 0 {
                    if closer.marker == TILDE {
                        if o.length == closer.length && o.count == o.length && closer.count == closer.length {
                            found = Some(oi as usize);
                            break;
                        }
                    } else {
                        let odd_match = (o.can_close || closer.can_open)
                            && (o.length + closer.length) % 3 == 0
                            && !(o.length % 3 == 0 && closer.length % 3 == 0);
                        if !odd_match {
                            found = Some(oi as usize);
                            break;
                        }
                    }
                }
                oi -= 1;
            }
            let Some(opener) = found else {
                openers_bottom[key] = ci;
                if !closer.can_open {
                    self.delimiters[ci].count = 0;
                }
                ci += 1;
                continue;
            };
            let o = self.delimiters[opener];
            let used = if closer.marker == TILDE {
                closer.count
            } else if closer.count >= 2 && o.count >= 2 {
                2
            } else {
                1
            };
            let open_marker = o.position + o.count - used;
            let close_marker = closer.position + closer.length - closer.count;
            self.leaf(open_marker, used, SpanStyle::Marker);
            self.leaf(close_marker, used, SpanStyle::Marker);
            if closer.marker == TILDE {
                self.containers.push(Pending {
                    start: open_marker + used,
                    length: close_marker.saturating_sub(open_marker + used),
                    style: SpanStyle::Strikethrough,
                });
            } else {
                self.emphasis.push((
                    open_marker + used,
                    close_marker,
                    if used == 1 { FontTraits::ITALIC } else { FontTraits::BOLD },
                ));
            }
            self.delimiters[opener].count -= used;
            self.delimiters[ci].count -= used;
            for k in opener + 1..ci {
                self.delimiters[k].count = 0;
            }
            if self.delimiters[ci].count == 0 {
                ci += 1;
            }
        }
    }

    fn emit(&mut self) {
        if !self.collects_spans {
            return;
        }
        let mut containers = std::mem::take(&mut self.containers);
        containers.sort_by(|a, b| a.start.cmp(&b.start).then(b.length.cmp(&a.length)));
        for p in &containers {
            self.output(p.start, p.length, p.style);
        }
        if !self.emphasis.is_empty() {
            self.emit_fonts();
        }
        let leaves = std::mem::take(&mut self.leaves);
        for p in &leaves {
            self.output(p.start, p.length, p.style);
        }
    }

    fn emit_fonts(&mut self) {
        let mut events: Vec<(usize, i32, i32)> = Vec::with_capacity(self.emphasis.len() * 2);
        for &(start, end, traits) in &self.emphasis {
            if end <= start {
                continue;
            }
            let bold = i32::from(traits.contains(FontTraits::BOLD));
            let italic = i32::from(traits.contains(FontTraits::ITALIC));
            events.push((start, bold, italic));
            events.push((end, -bold, -italic));
        }
        events.sort_by_key(|e| e.0);
        let (mut bold, mut italic) = (0, 0);
        let mut k = 0;
        while k < events.len() {
            let position = events[k].0;
            while k < events.len() && events[k].0 == position {
                bold += events[k].1;
                italic += events[k].2;
                k += 1;
            }
            if k >= events.len() {
                break;
            }
            let mut traits = FontTraits::NONE;
            if bold > 0 {
                traits = traits.union(FontTraits::BOLD);
            }
            if italic > 0 {
                traits = traits.union(FontTraits::ITALIC);
            }
            if !traits.is_empty() {
                self.output(position, events[k].0 - position, SpanStyle::Font(traits));
            }
        }
    }

    fn output(&mut self, start: usize, length: usize, style: SpanStyle) {
        if length == 0 {
            return;
        }
        let end = start + length;
        let mut k = self.segment_index(start);
        while k < self.segments.len() {
            let seg = self.segments[k];
            if seg.buffer_start >= end {
                break;
            }
            let a = start.max(seg.buffer_start);
            let b = end.min(seg.buffer_end());
            if b > a {
                let styled = match style {
                    SpanStyle::Font(t) if !seg.traits.is_empty() => SpanStyle::Font(t.union(seg.traits)),
                    s => s,
                };
                self.spans.push(HighlightSpan { location: seg.location + a - seg.buffer_start, length: b - a, style: styled });
            }
            k += 1;
        }
    }

    fn leaf(&mut self, start: usize, length: usize, style: SpanStyle) {
        if !self.collects_spans || length == 0 {
            return;
        }
        self.leaves.push(Pending { start, length, style });
    }

    fn region(&mut self, start: usize, end: usize, context: EditorContext) {
        if !self.collects_regions {
            return;
        }
        let location = self.document(start);
        let end = self.document(end);
        self.regions.push(ContextRegion { location, end, context });
    }

    fn segment_index(&self, i: usize) -> usize {
        let mut low = 0;
        let mut high = self.segments.len().saturating_sub(1);
        while low < high {
            let mid = (low + high + 1) / 2;
            if self.segments[mid].buffer_start <= i {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        low
    }

    fn segment_end(&self, i: usize) -> usize {
        if self.segments.len() == 1 {
            self.c.len()
        } else {
            self.segments[self.segment_index(i)].buffer_end()
        }
    }

    fn document(&self, i: usize) -> usize {
        let seg = self.segments[self.segment_index(i)];
        seg.location + (i.saturating_sub(seg.buffer_start)).min(seg.length)
    }
}
