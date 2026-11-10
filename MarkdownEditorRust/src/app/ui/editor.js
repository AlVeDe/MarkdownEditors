// The source editor: a native <textarea> (caret, selection, IME, undo,
// spell checking) whose text is transparent, over a backdrop of rows that
// the Rust core highlights. All editing *decisions* — list continuation,
// tables, pairs, formatting, completion — are made in Rust (`edit`,
// `completion_*` commands); this file only routes keys and applies the
// single replacement each command returns, as one native edit, so every
// command is exactly one undo step.
'use strict';

// Report front-end errors to the terminal running the app.
(function () {
  const send = (level, message) => {
    try { window.__TAURI__.core.invoke('log', { level, message: String(message) }); } catch (e) { /* not ready */ }
  };
  window.addEventListener('error', (e) => send('error', `${e.message} (${e.filename}:${e.lineno})`));
  window.addEventListener('unhandledrejection', (e) => send('error', (e.reason && (e.reason.stack || e.reason.message)) || e.reason));
  const original = console.error.bind(console);
  console.error = (...args) => { original(...args); send('error', args.map((a) => (a && a.stack) || a).join(' ')); };
})();

(function () {
  const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);

  const PAIR_OPEN = { '(': ')', '[': ']', '{': '}', '"': '"', '`': '`' };
  const PAIR_CLOSE = new Set([')', ']', '}', '"', '`']);
  const WRAPPERS = new Set(['*', '_', '~', '`', '(', '[', '"', '$']);

  function escapeHTML(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function isWordChar(c) {
    return /[\p{L}\p{N}_-]/u.test(c);
  }

  /// Where an old → new text change happened: the common prefix and suffix.
  function diff(a, b) {
    let p = 0;
    const max = Math.min(a.length, b.length);
    while (p < max && a.charCodeAt(p) === b.charCodeAt(p)) p++;
    let s = 0;
    while (s < a.length - p && s < b.length - p && a.charCodeAt(a.length - 1 - s) === b.charCodeAt(b.length - 1 - s)) s++;
    return { location: p, oldLength: a.length - p - s, newLength: b.length - p - s };
  }

  class Editor {
    constructor(root, hooks) {
      this.root = root;
      this.ta = root.querySelector('textarea');
      this.rowsEl = root.querySelector('.layer');
      this.hooks = {}; // attached after construction
      this.settings = {};
      this.triggers = new Set();
      this.plain = [''];
      this.html = [''];
      this.version = 0;
      this.lastValue = '';
      this.diagnostics = [];
      this.findDecorations = [];
      this.chain = Promise.resolve();
      this.busy = 0;
      this.programmatic = 0;
      this.pendingTyped = null;
      this.highlightQueued = false;
      this.highlightRunning = false;
      this.currentRow = -1;
      this.completion = null; // { anchor, entries, selected }
      this.explicitSession = false;
      this.snippet = null; // { stops: [{index, ranges}], current }
      this.documentPath = null;

      this.ta.addEventListener('keydown', (e) => this.onKeyDown(e));
      this.ta.addEventListener('input', () => this.onInput());
      this.ta.addEventListener('scroll', () => this.onScroll());
      this.ta.addEventListener('paste', (e) => this.onPaste(e));
      this.ta.addEventListener('blur', () => setTimeout(() => {
        if (document.activeElement !== this.ta) this.closeCompletion();
      }, 120));
      document.addEventListener('selectionchange', () => {
        if (document.activeElement === this.ta) this.onSelectionChange();
      });
      new ResizeObserver(() => this.layout()).observe(this.ta);
      this.setText('');
      this.hooks = hooks;
    }

    // MARK: Text and selection

    get text() { return this.ta.value; }

    get selection() {
      const s = this.ta.selectionStart, e = this.ta.selectionEnd;
      return { location: s, length: e - s };
    }

    set selection(r) {
      this.ta.setSelectionRange(r.location, r.location + r.length);
    }

    focus() { this.ta.focus({ preventScroll: true }); }

    /// Replaces the whole text without an undo step (loading a document).
    setText(text) {
      this.ta.value = text;
      this.lastValue = text;
      this.plain = text.split('\n');
      this.html = this.plain.map(escapeHTML);
      this.rowsEl.innerHTML = this.html.map((h) => `<div class="row">${h}</div>`).join('');
      this.currentRow = -1;
      this.version++;
      this.endSnippet();
      this.closeCompletion();
      this.ta.setSelectionRange(0, 0);
      this.ta.scrollTop = 0;
      this.updateGutter();
      this.scheduleHighlight();
      this.onSelectionChange();
    }

    /// Replaces `range` with `text` as one native (undoable) edit and selects
    /// `selection` afterwards.
    replace(range, text, selection) {
      this.focus();
      this.ta.setSelectionRange(range.location, range.location + range.length);
      this.programmatic++;
      let ok;
      try {
        ok = text.length === 0 && range.length > 0
          ? document.execCommand('delete', false)
          : document.execCommand('insertText', false, text);
      } finally {
        this.programmatic--;
      }
      if (!ok) {
        // Fallback (no undo integration): edit the value directly.
        this.ta.setRangeText(text, range.location, range.location + range.length, 'end');
        this.programmatic++;
        try { this.onInput(); } finally { this.programmatic--; }
      }
      if (selection) this.selection = selection;
      this.revealSelection();
    }

    applyOutcome(outcome) {
      if (!outcome) return;
      if (outcome.edit) {
        this.replace(outcome.edit.range, outcome.edit.text, outcome.selection);
      } else {
        this.selection = outcome.selection;
        this.revealSelection();
      }
      if (outcome.beep) this.hooks.beep && this.hooks.beep();
    }

    /// Runs `job` after every earlier command (commands are async: a key
    /// typed while one is in flight must land after it).
    enqueue(job) {
      this.busy++;
      const run = async () => {
        try { return await job(); } finally { this.busy--; }
      };
      const p = this.chain.then(run, run);
      this.chain = p.catch(() => {});
      return p;
    }

    /// Asks the core to run an editing command; applies its result.
    command(command) {
      return this.enqueue(async () => {
        const response = await invoke('edit', { text: this.text, selection: this.selection, command });
        if (response.message) this.hooks.message && this.hooks.message(response.message);
        if (response.handled) this.applyOutcome(response.outcome);
        return response.handled;
      });
    }

    insertPlain(text) {
      const s = this.selection;
      this.replace(s, text, { location: s.location + text.length, length: 0 });
    }

    // MARK: Keys

    onKeyDown(e) {
      if (e.isComposing || e.keyCode === 229) return;
      const mod = e.metaKey || (e.ctrlKey && !e.altKey);

      // Ctrl+Space: completions on demand.
      if (e.ctrlKey && !e.metaKey && !e.altKey && (e.key === ' ' || e.code === 'Space')) {
        e.preventDefault();
        this.showCompletions();
        return;
      }

      if (this.completion) {
        const handled = this.completionKey(e);
        if (handled) { e.preventDefault(); return; }
      }

      if (this.snippet && !mod) {
        if (e.key === 'Tab') { e.preventDefault(); e.shiftKey ? this.snippetPrevious() : this.snippetNext(); return; }
        if (e.key === 'Escape') { e.preventDefault(); this.endSnippet(); return; }
      }

      if (mod) return; // Shortcuts belong to the menu.

      let action = null;
      if (e.key === 'Enter' && !e.altKey) {
        action = e.shiftKey ? { plain: '\n' } : { command: { command: 'newline' }, fallback: '\n' };
      } else if (e.key === 'Tab' && !e.altKey) {
        action = e.shiftKey ? { command: { command: 'backtab' } } : { command: { command: 'tab' }, fallback: '\t' };
      } else if (e.key === 'Backspace' && !e.altKey) {
        if (this.busy || this.mayDeletePair()) action = { command: { command: 'deleteBackward' }, deleteFallback: true };
      } else if (e.key.length === 1 || (e.key.length === 2 && /[\uD800-\uDBFF]/.test(e.key[0]))) {
        this.pendingTyped = e.key;
        if (this.wantsCharCommand(e.key)) {
          action = { command: { command: 'insertText', text: e.key }, fallback: e.key };
        } else if (this.busy) {
          action = { plain: e.key };
        }
      } else if (e.key === 'Delete' && this.busy) {
        action = { forwardDelete: true };
      }
      if (!action) return;
      e.preventDefault();
      if (action.command) this.pendingTyped = action.command.command === 'insertText' ? action.command.text : null;
      this.enqueue(async () => {
        if (action.plain !== undefined) { this.insertPlain(action.plain); return; }
        if (action.forwardDelete) { document.execCommand('forwardDelete'); return; }
        const response = await invoke('edit', { text: this.text, selection: this.selection, command: action.command });
        if (response.handled) {
          // A typed character the core inserted (pair, wrap) still counts
          // as typing for completion triggers.
          this.commandTyped = action.command.command === 'insertText' ? action.command.text : null;
          try { this.applyOutcome(response.outcome); } finally { this.commandTyped = null; }
        } else if (action.fallback !== undefined) {
          this.insertPlain(action.fallback);
        } else if (action.deleteFallback) {
          this.focus();
          document.execCommand('delete');
        }
      });
    }

    /// Only typed characters that can open a pair, wrap the selection,
    /// overtype a closer or become a smart quote need the core.
    wantsCharCommand(c) {
      const s = this.settings;
      if (!s.autoPairs && !(s.smartQuotes && (c === '"' || c === "'"))) return false;
      const sel = this.selection;
      if (s.smartQuotes && (c === '"' || c === "'")) return true;
      if (sel.length > 0) return WRAPPERS.has(c);
      if (PAIR_OPEN[c]) return true;
      return PAIR_CLOSE.has(c) && this.text[sel.location] === c;
    }

    mayDeletePair() {
      if (!this.settings.autoPairs) return false;
      const s = this.selection;
      if (s.length || s.location === 0) return false;
      const prev = this.text[s.location - 1];
      return PAIR_OPEN[prev] !== undefined && this.text[s.location] === PAIR_OPEN[prev];
    }

    // MARK: Input

    onInput() {
      const value = this.ta.value;
      const change = diff(this.lastValue, value);
      this.lastValue = value;
      this.version++;
      this.updateRowsPlain(change);
      if (this.snippet) this.snippetApplyEdit(change);
      this.scheduleHighlight();
      const typed = this.commandTyped || (this.programmatic ? null : this.pendingTyped);
      this.pendingTyped = null;
      this.hooks.textChanged && this.hooks.textChanged();
      this.afterTextChange(typed);
      this.onSelectionChange();
    }

    /// Shows the edited lines right away as plain text, before the
    /// highlighted version arrives from the core.
    updateRowsPlain(change) {
      const value = this.ta.value;
      const before = this.lastValueLines || null;
      const newLines = value.split('\n');
      const old = this.plain;
      let start = 0;
      const max = Math.min(old.length, newLines.length);
      while (start < max && old[start] === newLines[start]) start++;
      let endOld = old.length, endNew = newLines.length;
      while (endOld > start && endNew > start && old[endOld - 1] === newLines[endNew - 1]) { endOld--; endNew--; }
      const rows = this.rowsEl.children;
      const fragment = document.createDocumentFragment();
      const replacements = [];
      for (let i = start; i < endNew; i++) {
        const row = document.createElement('div');
        row.className = 'row';
        row.innerHTML = escapeHTML(newLines[i]);
        fragment.appendChild(row);
        replacements.push(escapeHTML(newLines[i]));
      }
      const anchor = rows[endOld] || null;
      for (let i = endOld - 1; i >= start; i--) rows[i].remove();
      this.rowsEl.insertBefore(fragment, anchor);
      this.plain = newLines;
      this.html.splice(start, endOld - start, ...replacements);
      if (this.currentRow >= start) this.currentRow = -1;
      if (old.length !== newLines.length) this.updateGutter();
      void before; void change;
    }

    scheduleHighlight() {
      if (this.highlightQueued) return;
      this.highlightQueued = true;
      requestAnimationFrame(() => this.runHighlight());
    }

    async runHighlight() {
      if (this.highlightRunning) { setTimeout(() => this.runHighlight(), 16); return; }
      this.highlightQueued = false;
      this.highlightRunning = true;
      const version = this.version;
      const text = this.text;
      try {
        const decorations = this.diagnostics.map((d) => ({ range: d.range, kind: 'diagnostic' })).concat(this.findDecorations);
        const lines = await invoke('highlight', {
          text,
          decorations,
          options: { showInvisibles: !!this.settings.showsInvisibles },
        });
        if (version !== this.version || lines.length !== this.plain.length) {
          this.scheduleHighlight();
          return;
        }
        const rows = this.rowsEl.children;
        for (let i = 0; i < lines.length; i++) {
          if (this.html[i] !== lines[i]) {
            rows[i].innerHTML = lines[i];
            this.html[i] = lines[i];
          }
        }
      } catch (error) {
        console.error(error);
      } finally {
        this.highlightRunning = false;
      }
    }

    /// Re-highlights everything (settings or decorations changed).
    refresh() {
      this.html = this.html.map(() => null);
      this.scheduleHighlight();
    }

    // MARK: Layout

    applySettings(settings) {
      this.settings = settings;
      const r = this.root;
      r.style.setProperty('--font-size', settings.fontSize + 'px');
      r.style.setProperty('--tab-size', settings.tabWidth);
      if (settings.fontName) {
        r.style.setProperty('--mono', `"${settings.fontName}", ui-monospace, Menlo, Consolas, "DejaVu Sans Mono", monospace`);
        r.querySelectorAll('.layer, textarea').forEach((el) => { el.style.fontFamily = `"${settings.fontName}", ui-monospace, Menlo, Consolas, "DejaVu Sans Mono", monospace`; });
      } else {
        r.querySelectorAll('.layer, textarea').forEach((el) => { el.style.fontFamily = ''; });
      }
      r.classList.toggle('nowrap', !settings.wrapsLines);
      this.ta.wrap = settings.wrapsLines ? 'soft' : 'off';
      r.classList.toggle('numbers', !!settings.showsLineNumbers);
      r.classList.toggle('no-current-line', !settings.highlightsCurrentLine);
      this.ta.spellcheck = !!settings.spellChecking;
      this.updateGutter();
      this.refresh();
    }

    updateGutter() {
      if (!this.settings.showsLineNumbers) {
        this.root.style.setProperty('--gutter', '0px');
      } else {
        const digits = Math.max(2, String(this.plain.length).length);
        const charWidth = this.measureCharWidth() * 0.85;
        this.root.style.setProperty('--gutter', Math.ceil(digits * charWidth + 18) + 'px');
      }
      this.layout();
    }

    measureCharWidth() {
      if (!this._probe) {
        this._probe = document.createElement('span');
        this._probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre';
        this.rowsEl.appendChild(this._probe);
      }
      if (!this.rowsEl.contains(this._probe)) this.rowsEl.appendChild(this._probe);
      this._probe.textContent = '0000000000';
      const w = this._probe.getBoundingClientRect().width / 10;
      return w || 8;
    }

    layout() {
      // The backdrop wraps exactly like the text area: same content width
      // (the text area's scrollbar excluded).
      const width = this.ta.clientWidth;
      if (this.settings.wrapsLines === false) {
        this.rowsEl.style.width = '';
        this.rowsEl.style.minWidth = width + 'px';
      } else {
        this.rowsEl.style.width = width + 'px';
        this.rowsEl.style.minWidth = '';
      }
      this.onScroll();
    }

    onScroll() {
      const st = this.ta.scrollTop, sl = this.ta.scrollLeft;
      this.rowsEl.style.transform = `translate(${-sl}px, ${-st}px)`;
      this.root.style.setProperty('--sx', sl + 'px');
      this.hooks.scrolled && this.hooks.scrolled();
      if (this.completion) this.positionCompletion();
    }

    // MARK: Geometry

    lineColumn(offset) {
      const text = this.text;
      let line = 0, lineStart = 0;
      for (let i = text.indexOf('\n'); i !== -1 && i < offset; i = text.indexOf('\n', i + 1)) {
        line++;
        lineStart = i + 1;
      }
      return { line, column: offset - lineStart, lineStart };
    }

    offsetOfLine(line) {
      const text = this.text;
      let offset = 0;
      for (let l = 0; l < line; l++) {
        const i = text.indexOf('\n', offset);
        if (i === -1) return text.length;
        offset = i + 1;
      }
      return offset;
    }

    /// Viewport rectangle of the caret at `offset`.
    caretRect(offset) {
      const { line, column } = this.lineColumn(offset);
      const row = this.rowsEl.children[line];
      if (!row) return null;
      let remaining = column;
      const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
      let node = walker.nextNode();
      while (node) {
        if (remaining <= node.length) {
          const range = document.createRange();
          range.setStart(node, remaining);
          range.setEnd(node, remaining);
          const rects = range.getClientRects();
          if (rects.length) return rects[rects.length - 1];
          if (remaining < node.length) {
            range.setEnd(node, remaining + 1);
            const r = range.getBoundingClientRect();
            return { left: r.left, top: r.top, bottom: r.bottom, height: r.height };
          }
          break;
        }
        remaining -= node.length;
        node = walker.nextNode();
      }
      const r = row.getBoundingClientRect();
      const padding = parseFloat(getComputedStyle(this.rowsEl).paddingLeft) || 0;
      return { left: column === 0 ? r.left : r.right, top: r.top, bottom: r.top + this.lineHeight(), height: this.lineHeight() };
    }

    lineHeight() {
      return this.settings.fontSize * 1.5;
    }

    /// The source line at the top edge (1-based, fractional) and whether
    /// the editor is scrolled to the very top / bottom.
    topVisibleLine() {
      const ta = this.ta;
      const rows = this.rowsEl.children;
      const padTop = parseFloat(getComputedStyle(this.rowsEl).paddingTop) || 0;
      const y = ta.scrollTop - padTop;
      let lo = 0, hi = rows.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        if (rows[mid].offsetTop - padTop <= y) lo = mid; else hi = mid - 1;
      }
      const row = rows[lo];
      const fraction = row && row.offsetHeight ? Math.min(1, Math.max(0, (y - (row.offsetTop - padTop)) / row.offsetHeight)) : 0;
      return {
        line: lo + 1 + fraction,
        atTop: ta.scrollTop <= 0,
        atBottom: ta.scrollTop + ta.clientHeight >= ta.scrollHeight - 2,
      };
    }

    /// Scrolls so that `offset` is visible (centered when `center`).
    revealOffset(offset, center) {
      const { line } = this.lineColumn(offset);
      const row = this.rowsEl.children[line];
      if (!row) return;
      const padTop = 0;
      const top = row.offsetTop + padTop;
      const ta = this.ta;
      if (center) {
        ta.scrollTop = Math.max(0, top - ta.clientHeight / 2);
      } else if (top < ta.scrollTop + 4) {
        ta.scrollTop = Math.max(0, top - 8);
      } else if (top + row.offsetHeight > ta.scrollTop + ta.clientHeight - 4) {
        ta.scrollTop = top + row.offsetHeight - ta.clientHeight + 8;
      }
    }

    revealSelection() {
      this.revealOffset(this.ta.selectionEnd, false);
    }

    goToLine(line) {
      const offset = this.offsetOfLine(Math.max(0, line - 1));
      this.focus();
      this.selection = { location: offset, length: 0 };
      this.revealOffset(offset, true);
    }

    // MARK: Selection

    onSelectionChange() {
      const { line } = this.lineColumn(this.ta.selectionStart);
      if (line !== this.currentRow) {
        const rows = this.rowsEl.children;
        if (rows[this.currentRow]) rows[this.currentRow].classList.remove('current');
        if (rows[line]) rows[line].classList.add('current');
        this.currentRow = line;
      }
      if (this.snippet) this.snippetCheckSelection();
      if (this.completion && !this.busy) this.refilterSoon();
      this.hooks.selectionChanged && this.hooks.selectionChanged();
    }

    // MARK: Diagnostics and find marks

    setDiagnostics(list) {
      const same = JSON.stringify(list) === JSON.stringify(this.diagnostics);
      this.diagnostics = list;
      if (!same) this.refresh();
    }

    diagnosticAt(offset) {
      return this.diagnostics.find((d) => offset >= d.range.location && offset <= d.range.location + d.range.length) || null;
    }

    setFindDecorations(list) {
      this.findDecorations = list;
      this.refresh();
    }

    // MARK: Paste

    onPaste(e) {
      const data = e.clipboardData;
      if (!data) return;
      if (data.types.includes('text/plain') && data.getData('text/plain')) return; // text wins
      const item = Array.from(data.items || []).find((i) => i.kind === 'file' && i.type.startsWith('image/'));
      if (!item) return;
      const file = item.getAsFile();
      if (!file) return;
      e.preventDefault();
      this.toPNGBase64(file).then((png) => {
        if (!png) return;
        this.command({ command: 'pasteImage', png_base64: png, document_path: this.documentPath });
      });
    }

    async toPNGBase64(blob) {
      const url = URL.createObjectURL(blob);
      try {
        const img = new Image();
        await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = reject; img.src = url; });
        const canvas = document.createElement('canvas');
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        canvas.getContext('2d').drawImage(img, 0, 0);
        return canvas.toDataURL('image/png').split(',')[1];
      } catch (error) {
        return null;
      } finally {
        URL.revokeObjectURL(url);
      }
    }

    /// UTF-16 offset of the text under a viewport point (for drops).
    offsetAtPoint(x, y) {
      const ta = this.ta;
      const rows = this.rowsEl;
      const prevTa = ta.style.pointerEvents, prevRows = rows.style.pointerEvents;
      ta.style.pointerEvents = 'none';
      rows.style.pointerEvents = 'auto';
      let range = null;
      try {
        if (document.caretRangeFromPoint) range = document.caretRangeFromPoint(x, y);
        else if (document.caretPositionFromPoint) {
          const p = document.caretPositionFromPoint(x, y);
          if (p) { range = document.createRange(); range.setStart(p.offsetNode, p.offset); }
        }
      } finally {
        ta.style.pointerEvents = prevTa;
        rows.style.pointerEvents = prevRows;
      }
      if (!range) return null;
      let node = range.startContainer;
      let row = node.nodeType === 1 ? node : node.parentElement;
      while (row && !(row.classList && row.classList.contains('row'))) row = row.parentElement;
      if (!row) return null;
      const index = Array.prototype.indexOf.call(rows.children, row);
      let column = 0;
      const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (n === range.startContainer) { column += range.startOffset; break; }
        column += n.length;
      }
      return this.offsetOfLine(index) + column;
    }

    // MARK: Completion

    async showCompletions() {
      this.explicitSession = true;
      const view = await this.enqueue(() => invoke('completion_open', { text: this.text, caret: this.ta.selectionStart, explicit: true }));
      if (!view) this.explicitSession = false;
      this.setCompletion(view);
    }

    afterTextChange(typed) {
      const explicit = this.explicitSession;
      if (!typed) {
        if (this.completion && this.ta.selectionStart <= this.completion.anchor) { this.closeCompletion(); return; }
        if (this.completion) this.refilterSoon();
        return;
      }
      const last = typed[typed.length - 1];
      const isTrigger = this.triggers.has(last);
      const run = async () => {
        if (this.completion && !isTrigger) {
          const view = await invoke('completion_refilter', { text: this.text, caret: this.ta.selectionStart });
          this.setCompletion(view);
          if (view) return;
        }
        if (!(isTrigger || isWordChar(last))) return;
        if (!(this.settings.showsCompletions || explicit)) return;
        if (this.ta.selectionStart !== this.ta.selectionEnd) return;
        const view = await invoke('completion_open', { text: this.text, caret: this.ta.selectionStart, explicit });
        if (!view) this.explicitSession = false;
        this.setCompletion(view);
      };
      this.enqueue(run);
    }

    refilterSoon() {
      if (this._refilterQueued) return;
      this._refilterQueued = true;
      queueMicrotask(() => {
        this._refilterQueued = false;
        if (!this.completion) return;
        const s = this.selection;
        if (s.length) { this.closeCompletion(); return; }
        this.enqueue(async () => {
          if (!this.completion) return;
          const view = await invoke('completion_refilter', { text: this.text, caret: this.ta.selectionStart });
          this.setCompletion(view);
        });
      });
    }

    setCompletion(view) {
      if (!view || !view.entries.length) {
        if (this.completion) {
          this.completion = null;
          this.explicitSession = false;
          this.hooks.completionChanged && this.hooks.completionChanged(null);
        }
        return;
      }
      this.completion = view;
      this.hooks.completionChanged && this.hooks.completionChanged(view);
    }

    positionCompletion() {
      this.hooks.completionChanged && this.hooks.completionChanged(this.completion);
    }

    closeCompletion() {
      if (!this.completion) return;
      this.completion = null;
      this.explicitSession = false;
      invoke('completion_close');
      this.hooks.completionChanged && this.hooks.completionChanged(null);
    }

    completionKey(e) {
      if (e.metaKey || e.ctrlKey || e.altKey) return false;
      const move = (delta, wrapping) => {
        this.enqueue(async () => this.setCompletion(await invoke('completion_move', { delta, wrapping })));
      };
      switch (e.key) {
        case 'ArrowUp': move(-1, true); return true;
        case 'ArrowDown': move(1, true); return true;
        case 'PageUp': move(-9, false); return true;
        case 'PageDown': move(9, false); return true;
        case 'Enter':
        case 'Tab': this.acceptCompletion(); return true;
        case 'Escape': this.closeCompletion(); return true;
        default: return false;
      }
    }

    selectCompletion(index, accept) {
      this.enqueue(async () => {
        this.setCompletion(await invoke('completion_select', { index }));
        if (accept) await this.acceptCompletionNow();
      });
    }

    acceptCompletion() {
      this.enqueue(() => this.acceptCompletionNow());
    }

    async acceptCompletionNow() {
      if (!this.completion) return;
      const insertion = await invoke('completion_accept', { text: this.text, caret: this.ta.selectionStart });
      this.completion = null;
      this.explicitSession = false;
      this.hooks.completionChanged && this.hooks.completionChanged(null);
      if (!insertion) return;
      this.endSnippet();
      this.replace(insertion.range, insertion.text, insertion.selection);
      if (insertion.tabStops && insertion.tabStops.length) {
        this.snippet = { stops: insertion.tabStops.map((s) => ({ index: s.index, ranges: s.ranges.slice() })), current: 0 };
      }
    }

    // MARK: Snippet sessions (tab stops after inserting a snippet)

    endSnippet() { this.snippet = null; }

    snippetSelect(position) {
      const s = this.snippet;
      if (!s) return;
      let target = Math.min(position, s.stops.length - 1);
      while (target < s.stops.length - 1 && !s.stops[target].ranges.length) target++;
      const range = s.stops[target].ranges[0];
      if (!range) { this.endSnippet(); return; }
      s.current = target;
      if (s.stops[target].index === 0) this.endSnippet();
      this.selecting = true;
      this.selection = range;
      this.selecting = false;
      this.revealSelection();
    }

    snippetNext() { if (this.snippet) this.snippetSelect(this.snippet.current + 1); }
    snippetPrevious() { if (this.snippet) this.snippetSelect(Math.max(0, this.snippet.current - 1)); }

    snippetApplyEdit(change) {
      const s = this.snippet;
      const { location, oldLength, newLength } = change;
      const editEnd = location + oldLength;
      const delta = newLength - oldLength;
      s.stops.forEach((stop, i) => {
        const grows = i === s.current;
        stop.ranges = stop.ranges.map((r) => {
          const contained = location >= r.location && editEnd <= r.location + r.length;
          if (grows && contained) return { location: r.location, length: r.length + delta };
          if (editEnd <= r.location) return { location: r.location + delta, length: r.length };
          if (location >= r.location + r.length) return r;
          if (contained) return { location: r.location, length: r.length + delta };
          return null;
        }).filter(Boolean);
      });
      if (s.stops.every((st) => !st.ranges.length) || !s.stops[s.current].ranges.length) this.endSnippet();
    }

    snippetCheckSelection() {
      if (this.selecting) return;
      const sel = this.selection;
      const inside = this.snippet.stops.some((st) => st.ranges.some((r) => sel.location >= r.location && sel.location + sel.length <= r.location + r.length));
      if (!inside) this.endSnippet();
    }
  }

  window.MDEditor = { Editor, escapeHTML };
})();
