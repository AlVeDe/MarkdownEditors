// One document window: wires the editor, the preview frame, the outline,
// the status bar, menus, dialogs and exports to the Rust commands.
'use strict';

(function () {
  const T = window.__TAURI__;
  const invoke = (cmd, args) => T.core.invoke(cmd, args);
  const listen = (event, handler) => T.event.listen(event, handler);
  const currentWindow = T.window.getCurrentWindow();
  const { Editor, escapeHTML } = window.MDEditor;

  const $ = (id) => document.getElementById(id);
  const panes = $('panes');
  const iframe = $('preview');

  const state = {
    path: null,
    savedText: '',
    dirty: false,
    viewMode: 'split',
    showsOutline: false,
    settings: null,
    platform: 'macos',
    previewCSS: '',
    mathjaxConfig: '',
    previewReady: false,
    lastFragment: null,
    lastReport: null,
    rendering: false,
    pendingRender: false,
    headings: [],
  };

  const editor = new Editor($('editor'), {
    textChanged: onTextChanged,
    selectionChanged: onSelectionChanged,
    scrolled: onEditorScrolled,
    completionChanged: renderCompletion,
    message: (m) => showMessage('MarkdownEditor', m, false),
    beep: () => {},
  });
  window.mdEditor = editor;

  // MARK: Startup

  async function init() {
    const payload = await invoke('window_init');
    state.platform = payload.platform;
    document.documentElement.dataset.platform = payload.platform;
    state.previewCSS = payload.previewCss;
    state.mathjaxConfig = payload.mathjaxConfig;
    state.settings = payload.settings;
    state.showsOutline = !!payload.settings.showsOutline;
    state.viewMode = payload.settings.defaultViewMode || 'split';
    editor.triggers = new Set(payload.triggerCharacters);
    applySettings(payload.settings);
    setDocument(payload.path, payload.text);
    iframe.addEventListener('load', () => {
      state.previewReady = true;
      state.lastFragment = null;
      renderNow();
      syncScroll(true);
    });
    iframe.srcdoc = payload.previewShell;
    applyViewMode();
    editor.focus();
    requestAnimationFrame(() => requestAnimationFrame(() => document.body.classList.remove('preload')));
  }

  function setDocument(path, text) {
    state.path = path;
    state.savedText = text;
    editor.documentPath = path;
    editor.setText(text);
    setDirty(false, true);
    state.lastFragment = null;
    renderNow();
    updateOutlineSoon(true);
    updateStatisticsSoon();
  }

  function displayName() {
    if (!state.path) return 'Untitled';
    return state.path.split(/[\\/]/).pop();
  }

  function setDirty(dirty, force) {
    if (dirty === state.dirty && !force) return;
    state.dirty = dirty;
    invoke('set_document_state', { dirty });
    currentWindow.setTitle(displayName() + (dirty ? ' — Edited' : ''));
    $('doc-name').textContent = displayName();
    $('doc-title').title = state.path || 'Untitled';
    $('doc-edited').hidden = !dirty;
  }

  // MARK: Settings

  function applySettings(settings) {
    state.settings = settings;
    editor.applySettings(settings);
    panes.classList.toggle('stacked', settings.splitOrientation === 'stacked');
    $('statusbar').hidden = !settings.showsStatusBar;
    $('toolbar').hidden = settings.showsToolbar === false;
    editor.layout();
  }

  listen('settings-changed', (event) => applySettings(event.payload));

  function saveSettings(change) {
    const settings = Object.assign({}, state.settings, change);
    invoke('set_settings', { settings });
  }

  // MARK: View modes

  function applyViewMode() {
    panes.classList.remove('mode-editor', 'mode-split', 'mode-preview');
    panes.classList.add('mode-' + state.viewMode);
    document.querySelectorAll('[data-cmd^="view:"]').forEach((b) => {
      b.classList.toggle('on', b.dataset.cmd === 'view:' + state.viewMode);
    });
    $('outline').classList.toggle('collapsed', !state.showsOutline);
    $('tb-outline').classList.toggle('on', state.showsOutline);
    requestAnimationFrame(() => { editor.layout(); syncScroll(true); });
  }

  function setViewMode(mode) {
    state.viewMode = mode;
    applyViewMode();
    if (mode !== 'preview') editor.focus();
  }

  /// Runs an editor command; shows the editor first if only the preview is
  /// visible.
  function onEditor(fn) {
    if (state.viewMode === 'preview') setViewMode('split');
    editor.focus();
    return fn();
  }

  // Splitter.
  (function () {
    const splitter = $('splitter');
    splitter.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      splitter.setPointerCapture(e.pointerId);
      const stacked = panes.classList.contains('stacked');
      const rect = panes.getBoundingClientRect();
      const move = (ev) => {
        const fraction = stacked ? (ev.clientY - rect.top) / rect.height : (ev.clientX - rect.left) / rect.width;
        const f = Math.min(0.85, Math.max(0.15, fraction));
        $('editor-pane').style.flex = `${f} 1 0`;
        $('preview-pane').style.flex = `${1 - f} 1 0`;
        editor.layout();
      };
      const up = () => {
        splitter.removeEventListener('pointermove', move);
        splitter.removeEventListener('pointerup', up);
      };
      splitter.addEventListener('pointermove', move);
      splitter.addEventListener('pointerup', up);
    });
  })();

  // MARK: Text changes

  var renderTimer = 0;
  function onTextChanged() {
    setDirty(editor.text !== state.savedText);
    clearTimeout(renderTimer);
    renderTimer = setTimeout(renderNow, 150);
    updateOutlineSoon();
    updateStatisticsSoon();
  }

  function imageBase() {
    if (!state.path) return null;
    return state.platform === 'windows' || state.platform === 'android' ? 'http://docfile.localhost/' : 'docfile://localhost/';
  }

  async function renderNow() {
    if (!state.previewReady) return;
    if (state.rendering) { state.pendingRender = true; return; }
    state.rendering = true;
    try {
      const text = editor.text;
      const rendered = await invoke('render_preview', { text, imageBase: imageBase() });
      let report = state.lastReport;
      if (rendered.html !== state.lastFragment) {
        state.lastFragment = rendered.html;
        const win = iframe.contentWindow;
        if (win && win.updateContent) {
          report = await win.updateContent(rendered.html, rendered.lineCount);
          state.lastReport = report;
        }
      }
      if (report && text === editor.text) {
        const diagnostics = await invoke('preview_diagnostics', { report, text });
        editor.setDiagnostics(diagnostics);
        onSelectionChanged();
      }
    } catch (error) {
      console.error('render failed', error);
    } finally {
      state.rendering = false;
      if (state.pendingRender) {
        state.pendingRender = false;
        renderNow();
      }
    }
  }

  // MARK: Scroll sync

  var scrollFrame = 0;
  function onEditorScrolled() {
    if (scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => { scrollFrame = 0; syncScroll(false); });
  }

  function syncScroll(immediate) {
    if (!state.settings || !state.settings.syncScrolling || state.viewMode !== 'split') return;
    const win = iframe.contentWindow;
    if (!win || !win.scrollToSourceLine) return;
    const top = editor.topVisibleLine();
    const edge = top.atTop ? 'top' : top.atBottom ? 'bottom' : '';
    win.scrollToSourceLine(top.line, edge, !!immediate);
  }

  // MARK: Selection: status bar, outline, math preview

  function onSelectionChanged() {
    const sel = editor.selection;
    const lc = editor.lineColumn(sel.location);
    const lineText = editor.text.slice(lc.lineStart, sel.location);
    $('status-pos').textContent = `Ln ${lc.line + 1}, Col ${Array.from(lineText).length + 1}`;
    const d = editor.diagnosticAt(sel.location);
    $('status-msg').innerHTML = d ? `<svg class="sym"><use href="#i-warning"/></svg><span>${escapeHTML(d.message)}</span>` : '';
    $('status-msg').title = d ? d.message : '';
    markCurrentHeading(sel.location);
    updateMathPreviewSoon();
  }

  var statsTimer = 0;
  function updateStatisticsSoon() {
    clearTimeout(statsTimer);
    statsTimer = setTimeout(async () => {
      const s = await invoke('statistics', { text: editor.text });
      $('status-words').textContent = `${s.words} word${s.words === 1 ? '' : 's'}`;
      $('status-chars').textContent = `${s.characters} character${s.characters === 1 ? '' : 's'}`;
    }, 250);
  }

  $('status-pos').addEventListener('click', showGoToLine);

  // MARK: Outline

  var outlineTimer = 0;
  function updateOutlineSoon(now) {
    clearTimeout(outlineTimer);
    outlineTimer = setTimeout(async () => {
      state.headings = await invoke('outline', { text: editor.text });
      renderOutline();
    }, now ? 0 : 300);
  }

  function renderOutline() {
    const list = $('outline-list');
    if (!state.headings.length) {
      list.innerHTML = '<div class="empty">No Headings</div>';
      return;
    }
    list.innerHTML = state.headings.map((h, i) =>
      `<button class="item l${h.level}" data-index="${i}" style="padding-left:${10 + (h.level - 1) * 14}px" title="${escapeHTML(h.title)}"><span class="t">${escapeHTML(h.title || '(untitled)')}</span></button>`
    ).join('');
    markCurrentHeading(editor.selection.location);
  }

  function markCurrentHeading(location) {
    if (!state.showsOutline) return;
    let current = -1;
    for (let i = 0; i < state.headings.length && state.headings[i].location <= location; i++) current = i;
    document.querySelectorAll('#outline-list .item').forEach((el, i) => el.classList.toggle('current', i === current));
  }

  $('outline-list').addEventListener('click', (e) => {
    const item = e.target.closest('.item');
    if (!item) return;
    const heading = state.headings[Number(item.dataset.index)];
    if (!heading) return;
    onEditor(() => {
      editor.selection = { location: heading.location, length: 0 };
      editor.revealOffset(heading.location, false);
      editor.ta.scrollTop = editor.rowsEl.children[heading.line - 1] ? editor.rowsEl.children[heading.line - 1].offsetTop : editor.ta.scrollTop;
    });
  });

  // MARK: Completion popup

  // Xcode-style kind badges (colored by data-kind in the stylesheet).
  const KIND_ICONS = {
    keyword: 'K', snippet: 'S', command: 'ƒ', environment: 'E', symbol: 'Σ', heading: '#', reference: 'R',
    file: 'F', language: 'L', diagram: 'D', identifier: 'V',
  };

  function renderCompletion(view) {
    const box = $('completion');
    if (!view) { box.hidden = true; return; }
    const list = $('completion-list');
    list.innerHTML = view.entries.map((entry, i) => {
      const label = Array.from(entry.item.label);
      const marks = new Set(entry.labelHighlights);
      const labelHTML = label.map((c, k) => marks.has(k) ? `<b>${escapeHTML(c)}</b>` : escapeHTML(c)).join('');
      return `<div class="entry${i === view.selected ? ' sel' : ''}" data-index="${i}"><span class="kind" data-kind="${entry.item.kind}">${KIND_ICONS[entry.item.kind] || ''}</span><span class="label">${labelHTML}</span><span class="detail">${escapeHTML(entry.item.detail || '')}</span></div>`;
    }).join('');
    const selected = view.entries[view.selected];
    const doc = $('completion-doc');
    if (selected && selected.item.documentation) {
      doc.hidden = false;
      doc.textContent = selected.item.documentation;
    } else {
      doc.hidden = true;
    }
    box.hidden = false;
    const rect = editor.caretRect(view.anchor);
    if (rect) {
      const left = Math.min(rect.left - 28, window.innerWidth - box.offsetWidth - 8);
      let top = rect.bottom + 4;
      if (top + box.offsetHeight > window.innerHeight - 8) top = rect.top - box.offsetHeight - 4;
      box.style.left = Math.max(4, left) + 'px';
      box.style.top = Math.max(4, top) + 'px';
    }
    const sel = list.children[view.selected];
    if (sel) {
      if (sel.offsetTop < list.scrollTop) list.scrollTop = sel.offsetTop;
      else if (sel.offsetTop + sel.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = sel.offsetTop + sel.offsetHeight - list.clientHeight;
    }
    $('mathpreview').hidden = true;
  }

  $('completion-list').addEventListener('mousedown', (e) => {
    e.preventDefault();
    const entry = e.target.closest('.entry');
    if (!entry) return;
    editor.selectCompletion(Number(entry.dataset.index), e.detail >= 2);
  });
  $('completion-list').addEventListener('dblclick', (e) => {
    e.preventDefault();
    editor.acceptCompletion();
  });

  // MARK: Formula preview at the caret

  var mathTimer = 0;
  var mathJaxLoading = null;
  function loadMathJax() {
    if (mathJaxLoading) return mathJaxLoading;
    mathJaxLoading = new Promise((resolve) => {
      const config = document.createElement('script');
      config.textContent = state.mathjaxConfig;
      document.head.appendChild(config);
      const script = document.createElement('script');
      script.src = 'vendor/tex-svg-full.js';
      script.onload = () => window.MathJax.startup.promise.then(resolve);
      script.onerror = () => resolve();
      document.head.appendChild(script);
    });
    return mathJaxLoading;
  }

  function updateMathPreviewSoon() {
    clearTimeout(mathTimer);
    mathTimer = setTimeout(updateMathPreview, 120);
  }

  async function updateMathPreview() {
    const panel = $('mathpreview');
    if (document.activeElement !== editor.ta || editor.completion || state.viewMode === 'preview') { panel.hidden = true; return; }
    const sel = editor.selection;
    const found = await invoke('formula_at', { text: editor.text, location: sel.location });
    if (!found || !found.tex.trim()) { panel.hidden = true; return; }
    await loadMathJax();
    if (!window.MathJax || !window.MathJax.tex2svgPromise) { panel.hidden = true; return; }
    try {
      const node = await window.MathJax.tex2svgPromise(found.tex, { display: found.formula.isDisplay });
      panel.innerHTML = '';
      panel.appendChild(node);
      const err = node.querySelector('[data-mjx-error]');
      if (err) {
        const msg = document.createElement('div');
        msg.className = 'error';
        msg.textContent = err.getAttribute('data-mjx-error');
        panel.appendChild(msg);
      }
    } catch (error) {
      panel.textContent = String(error.message || error);
    }
    const anchor = editor.caretRect(found.formula.range.location + found.formula.range.length) || editor.caretRect(sel.location);
    panel.hidden = false;
    if (anchor) {
      const lineBottom = editor.caretRect(sel.location) || anchor;
      let top = lineBottom.bottom + 8;
      if (top + panel.offsetHeight > window.innerHeight - 30) top = lineBottom.top - panel.offsetHeight - 8;
      const pane = $('editor-pane').getBoundingClientRect();
      panel.style.left = Math.max(pane.left + 8, Math.min(lineBottom.left, pane.right - panel.offsetWidth - 8)) + 'px';
      panel.style.top = Math.max(4, top) + 'px';
    }
  }
  editor.ta.addEventListener('blur', () => { $('mathpreview').hidden = true; });

  // MARK: Find and replace

  const find = { matches: [], index: -1, caseSensitive: false, regex: false };

  function showFind(replace) {
    const bar = $('findbar');
    bar.hidden = false;
    bar.querySelectorAll('.replace-row').forEach((r) => { r.hidden = !replace; });
    const sel = editor.selection;
    if (sel.length && sel.length < 200) {
      const s = editor.text.substr(sel.location, sel.length);
      if (!s.includes('\n')) $('find-input').value = s;
    }
    $('find-input').focus();
    $('find-input').select();
    updateFind(true);
  }

  function hideFind() {
    $('findbar').hidden = true;
    find.matches = [];
    editor.setFindDecorations([]);
    editor.focus();
  }

  function computeMatches() {
    const query = $('find-input').value;
    const text = editor.text;
    const matches = [];
    if (!query) return matches;
    if (find.regex) {
      let re;
      try { re = new RegExp(query, find.caseSensitive ? 'g' : 'gi'); } catch (e) { return null; }
      let m;
      while ((m = re.exec(text)) && matches.length < 10000) {
        if (m[0].length === 0) { re.lastIndex++; continue; }
        matches.push({ location: m.index, length: m[0].length });
      }
    } else {
      const hay = find.caseSensitive ? text : text.toLowerCase();
      const needle = find.caseSensitive ? query : query.toLowerCase();
      let i = hay.indexOf(needle);
      while (i !== -1 && matches.length < 10000) {
        matches.push({ location: i, length: needle.length });
        i = hay.indexOf(needle, i + needle.length);
      }
    }
    return matches;
  }

  function updateFind(selectNearest) {
    const matches = computeMatches();
    $('find-input').classList.toggle('nomatch', matches === null || (!!$('find-input').value && matches.length === 0));
    find.matches = matches || [];
    if (selectNearest) {
      const caret = editor.selection.location;
      find.index = find.matches.findIndex((m) => m.location >= caret);
      if (find.index === -1 && find.matches.length) find.index = 0;
    } else if (find.index >= find.matches.length) {
      find.index = find.matches.length - 1;
    }
    $('find-count').textContent = find.matches.length ? `${find.index + 1} of ${find.matches.length}` : ($('find-input').value ? 'No results' : '');
    decorateFind();
  }

  function decorateFind() {
    const list = find.matches.slice(0, 2000).map((r, i) => ({ range: r, kind: i === find.index ? 'currentFound' : 'found' }));
    editor.setFindDecorations(list);
  }

  function findStep(delta) {
    if ($('findbar').hidden) { showFind(false); return; }
    updateFind(false);
    if (!find.matches.length) return;
    find.index = (find.index + delta + find.matches.length) % find.matches.length;
    const m = find.matches[find.index];
    editor.selection = m;
    editor.revealOffset(m.location, true);
    $('find-count').textContent = `${find.index + 1} of ${find.matches.length}`;
    decorateFind();
  }

  function replaceOne() {
    if (find.index < 0 || !find.matches[find.index]) { findStep(1); return; }
    const m = find.matches[find.index];
    const replacement = replacementFor(m);
    editor.replace(m, replacement, { location: m.location + replacement.length, length: 0 });
    updateFind(false);
    if (find.matches.length) {
      find.index = find.matches.findIndex((x) => x.location >= m.location + replacement.length);
      if (find.index === -1) find.index = 0;
      findStep(0);
    }
  }

  function replacementFor(m) {
    const raw = $('replace-input').value;
    if (!find.regex) return raw;
    const re = new RegExp($('find-input').value, find.caseSensitive ? '' : 'i');
    return editor.text.substr(m.location, m.length).replace(re, raw);
  }

  function replaceAll() {
    updateFind(false);
    if (!find.matches.length) return;
    const text = editor.text;
    let out = '';
    let last = 0;
    for (const m of find.matches) {
      out += text.slice(last, m.location) + replacementFor(m);
      last = m.location + m.length;
    }
    out += text.slice(last);
    const first = find.matches[0].location;
    const end = find.matches[find.matches.length - 1];
    const tail = text.length - (end.location + end.length);
    // One edit covering every match, so Undo restores them all at once.
    editor.replace({ location: first, length: text.length - first - tail }, out.slice(first, out.length - tail), { location: first, length: 0 });
    updateFind(true);
  }

  $('find-input').addEventListener('input', () => updateFind(true));
  $('find-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); findStep(e.shiftKey ? -1 : 1); }
    if (e.key === 'Escape') { e.preventDefault(); hideFind(); }
  });
  $('replace-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); replaceOne(); }
    if (e.key === 'Escape') { e.preventDefault(); hideFind(); }
  });
  $('find-next').addEventListener('click', () => findStep(1));
  $('find-prev').addEventListener('click', () => findStep(-1));
  $('find-close').addEventListener('click', hideFind);
  $('replace-one').addEventListener('click', replaceOne);
  $('replace-all').addEventListener('click', replaceAll);
  $('find-case').addEventListener('click', () => { find.caseSensitive = !find.caseSensitive; $('find-case').classList.toggle('on', find.caseSensitive); updateFind(true); });
  $('find-regex').addEventListener('click', () => { find.regex = !find.regex; $('find-regex').classList.toggle('on', find.regex); updateFind(true); });
  editor.ta.addEventListener('input', () => { if (!$('findbar').hidden) updateFind(false); });
  editor.ta.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !$('findbar').hidden && !editor.completion && !editor.snippet) hideFind();
  });

  // MARK: Dialogs

  function modal(html, onReady, className) {
    const backdrop = document.createElement('div');
    backdrop.className = 'backdrop';
    backdrop.innerHTML = `<div class="dialog ${className || ''}" role="dialog" aria-modal="true">${html}</div>`;
    document.body.appendChild(backdrop);
    const close = () => { backdrop.remove(); editor.focus(); };
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) close(); });
    backdrop.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.preventDefault(); close(); } });
    onReady(backdrop.querySelector('.dialog'), close);
  }

  function showGoToLine() {
    const total = editor.text.split('\n').length;
    modal(`<h2>Go to Line</h2><p class="subtitle">Enter a line number between 1 and ${total}.</p>
      <input type="number" id="goto-line" min="1" max="${total}" placeholder="Line number" />
      <div class="buttons"><button class="pill" id="goto-cancel">Cancel</button><button class="pill primary" id="goto-go">Go</button></div>`, (dialog, close) => {
      const input = dialog.querySelector('#goto-line');
      input.value = editor.lineColumn(editor.selection.location).line + 1;
      input.focus();
      input.select();
      const go = () => {
        const line = parseInt(input.value, 10);
        close();
        if (line > 0) onEditor(() => editor.goToLine(line));
      };
      dialog.querySelector('#goto-go').addEventListener('click', go);
      dialog.querySelector('#goto-cancel').addEventListener('click', close);
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
    }, 'goto');
  }

  const MONO_FONTS = ['', 'SF Mono', 'Menlo', 'Monaco', 'Consolas', 'Cascadia Code', 'Cascadia Mono', 'Courier New', 'DejaVu Sans Mono', 'Liberation Mono', 'Ubuntu Mono', 'Fira Code', 'JetBrains Mono', 'Source Code Pro', 'Noto Sans Mono'];

  function showSettings() {
    const s = state.settings;
    const toggle = (key, label) =>
      `<label class="row"><span>${label}</span><input type="checkbox" class="switch" role="switch" data-key="${key}" ${s[key] ? 'checked' : ''} /></label>`;
    const field = (label, control) => `<div class="row"><span>${label}</span><span class="ctl">${control}</span></div>`;
    const group = (title, rows) => `<h4>${title}</h4><div class="group">${rows.join('')}</div>`;
    modal(`<div class="sheet-head"><span class="badge"><svg class="sym"><use href="#i-gear"/></svg></span><h2>Settings</h2></div>
      <div class="form">
      ${group('Font', [
        field('Font', `<input type="text" list="mono-fonts" data-key="fontName" value="${escapeHTML(s.fontName)}" placeholder="System Monospaced" style="width:200px" />`),
        field('Size', `<input type="number" data-key="fontSize" min="8" max="40" value="${s.fontSize}" style="width:64px" /><span class="unit">pt</span>`),
      ])}
      <datalist id="mono-fonts">${MONO_FONTS.filter(Boolean).map((f) => `<option value="${f}">`).join('')}</datalist>
      ${group('Indentation', [
        field('Tab width', `<input type="number" data-key="tabWidth" min="1" max="8" value="${s.tabWidth}" style="width:64px" /><span class="unit">spaces</span>`),
        toggle('indentWithSpaces', 'Indent with spaces'),
      ])}
      ${group('Display', [
        toggle('wrapsLines', 'Wrap lines'),
        toggle('showsLineNumbers', 'Show line numbers'),
        toggle('showsInvisibles', 'Show invisible characters'),
        toggle('highlightsCurrentLine', 'Highlight current line'),
        toggle('showsToolbar', 'Show toolbar'),
        toggle('showsStatusBar', 'Show status bar'),
      ])}
      ${group('Typing', [
        toggle('autoPairs', 'Insert closing brackets and quotes'),
        toggle('renumbersLists', 'Renumber ordered lists automatically'),
        toggle('smartQuotes', 'Smart quotes'),
        toggle('spellChecking', 'Check spelling while typing'),
        toggle('showsCompletions', 'Show completions while typing'),
      ])}
      ${group('Preview', [
        field('Default view for new windows', `<select data-key="defaultViewMode"><option value="editor">Editor Only</option><option value="split">Editor and Preview</option><option value="preview">Preview Only</option></select>`),
        field('Editor and preview', `<select data-key="splitOrientation"><option value="sideBySide">Side by Side</option><option value="stacked">Stacked</option></select>`),
        toggle('syncScrolling', 'Scroll preview with editor'),
      ])}
      </div>
      <div class="buttons"><button class="pill" id="settings-reset">Reset to Defaults…</button><span style="flex:1"></span><button class="pill primary" id="settings-done">Done</button></div>`, (dialog, close) => {
      dialog.querySelector('[data-key=defaultViewMode]').value = s.defaultViewMode;
      dialog.querySelector('[data-key=splitOrientation]').value = s.splitOrientation;
      dialog.querySelectorAll('[data-key]').forEach((input) => {
        input.addEventListener('change', () => {
          const key = input.dataset.key;
          let value;
          if (input.type === 'checkbox') value = input.checked;
          else if (input.type === 'number') value = Math.max(Number(input.min) || 0, Math.min(Number(input.max) || 99, Number(input.value) || 0));
          else value = input.value;
          saveSettings({ [key]: value });
        });
      });
      dialog.querySelector('#settings-done').addEventListener('click', close);
      dialog.querySelector('#settings-done').focus();
      dialog.querySelector('#settings-reset').addEventListener('click', async () => {
        if (!confirm('Reset all settings to their defaults?')) return;
        await invoke('reset_settings');
        close();
      });
    }, 'settings');
  }

  function showMessage(title, message, error) {
    return invoke('show_message', { title, message, error: !!error });
  }

  // MARK: Files

  async function openPath(path) {
    const replaceable = !(state.path === null && state.dirty);
    if (!replaceable) {
      await invoke('open_in_new_window', { path }).catch((e) => showMessage('Open failed', String(e), true));
      return;
    }
    if (state.dirty && state.path) {
      const saved = await save(false);
      if (!saved) {
        await invoke('open_in_new_window', { path }).catch((e) => showMessage('Open failed', String(e), true));
        return;
      }
    }
    try {
      const file = await invoke('load_file', { path });
      setDocument(file.path, file.text);
    } catch (error) {
      showMessage('Open failed', String(error), true);
    }
  }

  async function openDialog() {
    const path = await invoke('pick_open_file');
    if (path) await openPath(path);
  }

  async function save(saveAs) {
    try {
      const text = editor.text;
      const path = await invoke('save_document', { text, saveAs: !!saveAs });
      if (!path) return false;
      const moved = path !== state.path;
      state.path = path;
      editor.documentPath = path;
      state.savedText = text;
      setDirty(editor.text !== text, true);
      if (moved) { state.lastFragment = null; renderNow(); }
      return true;
    } catch (error) {
      showMessage('Save failed', String(error), true);
      return false;
    }
  }

  async function closeWindow() {
    if (state.dirty) {
      const answer = await invoke('ask_save_changes', { name: displayName() });
      if (answer === 'cancel') { invoke('cancel_quit'); return; }
      if (answer === 'save' && !(await save(false))) { invoke('cancel_quit'); return; }
    }
    invoke('close_window');
  }

  listen('close-requested', closeWindow);
  listen('open-path', (event) => openPath(event.payload));

  // MARK: Exports

  async function exportPDF() {
    const win = iframe.contentWindow;
    await renderNow();
    let mermaid = [], displayMath = [], inlineMath = [];
    if (win && win.harvestSVGs) {
      mermaid = await win.harvestSVGs('pre.mermaid', null);
      displayMath = await win.harvestSVGs('div.math', '#000000');
      inlineMath = await win.harvestSVGs('span.math', '#000000');
    }
    try {
      await invoke('export_pdf', { text: editor.text, mermaid, displayMath, inlineMath });
    } catch (error) {
      showMessage('PDF export failed', String(error), true);
    }
  }

  async function exportHTML() {
    const win = iframe.contentWindow;
    if (!win || !win.renderedContentHTML) { showMessage('HTML export failed', 'The preview has not rendered yet.', true); return; }
    await renderNow();
    try {
      await invoke('export_html', { body: win.renderedContentHTML(imageBase()) });
    } catch (error) {
      showMessage('HTML export failed', String(error), true);
    }
  }

  async function printDocument() {
    const win = iframe.contentWindow;
    await renderNow();
    const root = $('print-root');
    const body = win && win.renderedContentHTML ? win.renderedContentHTML(null) : '';
    root.innerHTML = `<style>${state.previewCSS}\n@page { margin: 2cm; }</style><article class="markdown-body">${body}</article>`;
    document.documentElement.setAttribute('data-theme', 'light');
    const cleanup = () => { root.innerHTML = ''; document.documentElement.removeAttribute('data-theme'); };
    try {
      await invoke('print_window');
    } catch (error) {
      window.print();
    }
    // The print dialog is modal on most platforms; clean up afterwards.
    setTimeout(cleanup, 1000);
  }

  window.openExternal = (href) => invoke('open_url', { url: href });

  // MARK: Drag and drop (files)

  listen('tauri://drag-drop', (event) => {
    const { paths, position } = event.payload || {};
    if (!paths || !paths.length) return;
    const scale = window.devicePixelRatio || 1;
    const x = position.x / scale, y = position.y / scale;
    const editorRect = $('editor-pane').getBoundingClientRect();
    const overEditor = !$('editor-pane').offsetParent ? false : x >= editorRect.left && x <= editorRect.right && y >= editorRect.top && y <= editorRect.bottom;
    const allMarkdown = paths.every((p) => /\.(md|markdown|mdown|mkd)$/i.test(p));
    if (!overEditor && allMarkdown) {
      paths.forEach((p, i) => (i === 0 ? openPath(p) : invoke('open_in_new_window', { path: p })));
      return;
    }
    if (!overEditor) return;
    const location = editor.offsetAtPoint(x, y);
    editor.command({ command: 'insertFiles', paths, document_path: state.path, location });
  });

  // MARK: Menu and toolbar commands

  function formatAction(id) {
    const parts = id.split(':').slice(1);
    const action = parts[0];
    switch (action) {
      case 'heading': return { action, level: Number(parts[1]) };
      case 'codeBlock': return { action, language: parts[1] || null };
      case 'table': return { action, rows: Number(parts[1]), columns: Number(parts[2]) };
      default: return { action };
    }
  }

  async function runFormat(id) {
    const action = formatAction(id);
    let clipboard = null;
    if (action.action === 'link' || action.action === 'image') {
      clipboard = await invoke('read_clipboard_text').catch(() => null);
    }
    onEditor(() => editor.command(Object.assign({ command: 'format', clipboard }, action)));
  }

  function line(command) {
    onEditor(() => editor.command({ command }));
  }

  async function handleMenu(id) {
    if (id.startsWith('fmt:')) { runFormat(id); return; }
    if (id.startsWith('view:')) { setViewMode(id.slice(5)); return; }
    switch (id) {
      case 'open': openDialog(); break;
      case 'save': save(false); break;
      case 'save_as': save(true); break;
      case 'close': closeWindow(); break;
      case 'export_pdf': exportPDF(); break;
      case 'export_html': exportHTML(); break;
      case 'print': printDocument(); break;
      case 'settings': showSettings(); break;
      case 'undo': editor.focus(); document.execCommand('undo'); break;
      case 'redo': editor.focus(); document.execCommand('redo'); break;
      case 'find': onEditor(() => showFind(false)); break;
      case 'find_replace': onEditor(() => showFind(true)); break;
      case 'find_next': findStep(1); break;
      case 'find_previous': findStep(-1); break;
      case 'find_selection': {
        const sel = editor.selection;
        if (sel.length) { $('find-input').value = editor.text.substr(sel.location, sel.length); }
        updateFind(true);
        break;
      }
      case 'go_to_line': showGoToLine(); break;
      case 'show_completions': onEditor(() => editor.showCompletions()); break;
      case 'move_lines_up': line('moveLinesUp'); break;
      case 'move_lines_down': line('moveLinesDown'); break;
      case 'duplicate_lines': line('duplicateLines'); break;
      case 'delete_lines': line('deleteLines'); break;
      case 'join_lines': line('joinLines'); break;
      case 'toggle_line_comment': line('toggleLineComment'); break;
      case 'select_lines': line('selectLines'); break;
      case 'renumber_list': line('renumberList'); break;
      case 'format_table': line('formatTable'); break;
      case 'toggle_outline':
        state.showsOutline = !state.showsOutline;
        applyViewMode();
        renderOutline();
        break;
      default:
        break;
    }
  }

  listen('menu', (event) => handleMenu(event.payload));

  // MARK: Toolbar

  const isMac = () => document.documentElement.dataset.platform === 'macos';

  /// "Shift+Mod+X" → "⇧⌘X" on macOS, "Ctrl+Shift+X" elsewhere. A spec with
  /// "|" lists the macOS chord first, then the one for other platforms.
  function formatShortcut(spec) {
    if (!spec) return '';
    const parts = spec.split('|');
    const chord = (isMac() ? parts[0] : parts[parts.length - 1]).split('+');
    const key = chord.pop();
    const mods = new Set(chord.map((m) => (m === 'Mod' ? (isMac() ? 'Cmd' : 'Ctrl') : m)));
    if (isMac()) {
      return ['Ctrl', 'Alt', 'Shift', 'Cmd'].filter((m) => mods.has(m)).map((m) => ({ Ctrl: '⌃', Alt: '⌥', Shift: '⇧', Cmd: '⌘' })[m]).join('') + key.toUpperCase();
    }
    return ['Ctrl', 'Alt', 'Shift'].filter((m) => mods.has(m)).concat([key.toUpperCase()]).join('+');
  }

  const SEP = '-';
  const MENUS = {
    heading: () => [
      ...[1, 2, 3, 4, 5, 6].map((l) => ({ t: `Heading ${l}`, cmd: `fmt:heading:${l}`, key: `Mod+${l}`, cls: `h${l}` })),
      SEP,
      { t: 'Body', cmd: 'fmt:paragraph', key: 'Ctrl+Cmd+0|Ctrl+Alt+0' },
    ],
    code: () => [
      { t: 'Code Block', cmd: 'fmt:codeBlock', icon: 'curlybraces', key: 'Alt+Mod+K' },
      SEP,
      { hdr: 'Language' },
      ...[['C#', 'csharp'], ['JavaScript', 'javascript'], ['TypeScript', 'typescript'], ['Python', 'python']]
        .map(([t, lang]) => ({ t, cmd: `fmt:codeBlock:${lang}` })),
    ],
    table: () => [
      { hdr: 'Columns × Rows' },
      ...[[2, 2], [3, 2], [3, 3], [4, 3], [4, 4], [5, 4]].map(([c, r]) => ({ t: `${c} × ${r}`, cmd: `fmt:table:${r}:${c}`, icon: 'table' })),
    ],
    math: () => [
      { t: 'Inline Math', cmd: 'fmt:inlineMath', icon: 'function', key: 'Ctrl+Cmd+M|Ctrl+Alt+M', detail: '$…$' },
      { t: 'Display Math', cmd: 'fmt:displayMath', icon: 'function', detail: '$$…$$' },
    ],
    document: () => [
      { t: 'Open…', cmd: 'open', icon: 'folder', key: 'Mod+O' },
      SEP,
      { t: 'Save', cmd: 'save', icon: 'save', key: 'Mod+S' },
      { t: 'Save As…', cmd: 'save_as', key: 'Shift+Mod+S' },
      SEP,
      { t: 'Go to Line…', cmd: 'go_to_line' },
      { t: 'Settings…', cmd: 'settings', icon: 'gear', key: 'Cmd+,|Ctrl+,' },
    ],
    share: () => [
      { t: 'Export as PDF…', cmd: 'export_pdf', icon: 'doc-badge', key: 'Alt+Mod+E' },
      { t: 'Export as HTML…', cmd: 'export_html', icon: 'globe', key: 'Shift+Mod+E' },
      SEP,
      { t: 'Print…', cmd: 'print', icon: 'printer', key: 'Mod+P' },
    ],
    more: () => {
      // Everything the toolbar currently has no room for, in toolbar order.
      const folded = [];
      document.querySelectorAll('#toolbar [data-priority]').forEach((group) => {
        if (!group.classList.contains('folded')) return;
        if (folded.length) folded.push(SEP);
        group.querySelectorAll('button').forEach((b) => {
          if (b.dataset.menu) {
            folded.push({ hdr: b.dataset.tip }, ...MENUS[b.dataset.menu]());
          } else {
            const use = b.querySelector('use');
            folded.push({ t: b.dataset.tip, cmd: b.dataset.cmd, key: b.dataset.key, icon: use ? use.getAttribute('href').slice(3) : null });
          }
        });
      });
      return folded;
    },
  };

  const openMenu = { el: null, owner: null, items: [], index: -1, closedOwner: null, closedAt: 0 };

  function closeMenu() {
    if (!openMenu.el) return;
    openMenu.el.remove();
    if (openMenu.owner) openMenu.owner.classList.remove('open');
    document.removeEventListener('mousedown', onMenuOutside, true);
    document.removeEventListener('keydown', onMenuKey, true);
    window.removeEventListener('blur', closeMenu);
    window.removeEventListener('resize', closeMenu);
    openMenu.el = null;
    openMenu.owner = null;
  }

  function onMenuOutside(e) {
    if (openMenu.el && openMenu.el.contains(e.target)) return;
    // A click on the menu's own button closes it (and must not reopen it).
    openMenu.closedOwner = openMenu.owner && openMenu.owner.contains(e.target) ? openMenu.owner : null;
    openMenu.closedAt = Date.now();
    closeMenu();
  }

  function selectMenuItem(index) {
    openMenu.index = index;
    openMenu.items.forEach((el, i) => el.classList.toggle('sel', i === index));
    if (openMenu.items[index]) openMenu.items[index].scrollIntoView({ block: 'nearest' });
  }

  function onMenuKey(e) {
    const n = openMenu.items.length;
    if (e.key === 'Escape') closeMenu();
    else if (e.key === 'ArrowDown') selectMenuItem((openMenu.index + 1) % n);
    else if (e.key === 'ArrowUp') selectMenuItem((openMenu.index - 1 + n) % n);
    else if (e.key === 'Home') selectMenuItem(0);
    else if (e.key === 'End') selectMenuItem(n - 1);
    else if (e.key === 'Enter' || e.key === ' ') { if (openMenu.items[openMenu.index]) openMenu.items[openMenu.index].click(); }
    else if (e.key === 'Tab' || e.metaKey || e.ctrlKey) { closeMenu(); return; }
    else return;
    e.preventDefault();
    e.stopPropagation();
  }

  function showToolbarMenu(button, entries) {
    closeMenu();
    hideTooltip();
    const menu = document.createElement('div');
    menu.className = 'menu';
    menu.setAttribute('role', 'menu');
    menu.innerHTML = entries.map((e) => {
      if (e === SEP) return '<div class="sep" role="separator"></div>';
      if (e.hdr) return `<div class="hdr">${escapeHTML(e.hdr)}</div>`;
      const icon = e.icon ? `<svg class="sym"><use href="#i-${e.icon}"/></svg>` : '';
      const key = e.key ? formatShortcut(e.key) : (e.detail || '');
      return `<button class="mi ${e.cls || ''}" role="menuitem" data-cmd="${e.cmd}"><span class="ico">${icon}</span><span class="label">${escapeHTML(e.t)}</span>${key ? `<span class="key">${escapeHTML(key)}</span>` : ''}</button>`;
    }).join('');
    document.body.appendChild(menu);
    const r = button.getBoundingClientRect();
    const alignRight = r.left + r.width / 2 > window.innerWidth / 2;
    let left = alignRight ? r.right - menu.offsetWidth : r.left;
    left = Math.max(6, Math.min(left, window.innerWidth - menu.offsetWidth - 6));
    menu.style.left = left + 'px';
    menu.style.top = r.bottom + 6 + 'px';
    menu.style.transformOrigin = alignRight ? 'top right' : 'top left';

    openMenu.el = menu;
    openMenu.owner = button;
    openMenu.items = Array.from(menu.querySelectorAll('.mi'));
    openMenu.index = -1;
    button.classList.add('open');

    menu.addEventListener('mousedown', (e) => e.preventDefault()); // keep the editor's selection
    menu.addEventListener('mousemove', (e) => {
      const item = e.target.closest('.mi');
      if (item) selectMenuItem(openMenu.items.indexOf(item));
    });
    menu.addEventListener('mouseleave', () => selectMenuItem(-1));
    menu.addEventListener('click', (e) => {
      const item = e.target.closest('.mi');
      if (!item) return;
      closeMenu();
      handleMenu(item.dataset.cmd);
    });
    document.addEventListener('mousedown', onMenuOutside, true);
    document.addEventListener('keydown', onMenuKey, true);
    window.addEventListener('blur', closeMenu);
    window.addEventListener('resize', closeMenu);
  }

  // Tooltips: title and shortcut after a short hover; instant while moving
  // along the toolbar once one has been shown.
  const tip = { timer: 0, warmUntil: 0 };
  function showTooltip(el) {
    const box = $('tooltip');
    const key = formatShortcut(el.dataset.key);
    box.innerHTML = escapeHTML(el.dataset.tip) + (key ? `<span class="key">${escapeHTML(key)}</span>` : '');
    box.hidden = false;
    const r = el.getBoundingClientRect();
    const left = Math.max(6, Math.min(r.left + r.width / 2 - box.offsetWidth / 2, window.innerWidth - box.offsetWidth - 6));
    box.style.left = left + 'px';
    box.style.top = r.bottom + 8 + 'px';
  }
  function hideTooltip() {
    clearTimeout(tip.timer);
    if (!$('tooltip').hidden) tip.warmUntil = Date.now() + 500;
    $('tooltip').hidden = true;
  }
  document.addEventListener('mouseover', (e) => {
    const el = e.target.closest('[data-tip]');
    if (!el || el.contains(e.relatedTarget)) return;
    hideTooltip();
    if (openMenu.el) return;
    tip.timer = setTimeout(() => showTooltip(el), Date.now() < tip.warmUntil ? 0 : 650);
  });
  document.addEventListener('mouseout', (e) => {
    const el = e.target.closest('[data-tip]');
    if (el && !el.contains(e.relatedTarget)) hideTooltip();
  });
  document.addEventListener('mousedown', hideTooltip, true);

  // Toolbar overflow: show every group that fits; when space runs out,
  // groups fold into the More menu, highest data-priority number first,
  // and reappear (in reverse order) as the window grows again.
  const toolbarCenter = $('format-tools');
  const moreGroup = $('more-group');
  const foldOrder = Array.from(toolbarCenter.querySelectorAll('[data-priority]'))
    .sort((a, b) => Number(b.dataset.priority) - Number(a.dataset.priority));

  function toolbarFits() {
    const gap = parseFloat(getComputedStyle(toolbarCenter).columnGap) || 0;
    const shown = Array.from(toolbarCenter.children).filter((el) => !el.hidden && !el.classList.contains('folded'));
    const needed = shown.reduce((sum, el) => sum + el.offsetWidth, 0) + gap * Math.max(0, shown.length - 1);
    return needed <= toolbarCenter.clientWidth;
  }

  function layoutToolbar() {
    if ($('toolbar').hidden) return;
    foldOrder.forEach((g) => g.classList.remove('folded'));
    moreGroup.hidden = true;
    if (toolbarFits()) return;
    moreGroup.hidden = false;
    for (const group of foldOrder) {
      group.classList.add('folded');
      if (toolbarFits()) break;
    }
  }

  new ResizeObserver(() => layoutToolbar()).observe(toolbarCenter);
  layoutToolbar();

  $('toolbar').addEventListener('mousedown', (e) => {
    // Keep the editor's selection while clicking toolbar buttons.
    if (e.target.closest('button')) e.preventDefault();
  });
  $('toolbar').addEventListener('click', (e) => {
    const button = e.target.closest('button');
    if (!button) return;
    if (button.dataset.menu) {
      const justClosed = openMenu.closedOwner === button && Date.now() - openMenu.closedAt < 600;
      openMenu.closedOwner = null;
      if (justClosed) return;
      showToolbarMenu(button, MENUS[button.dataset.menu]());
      return;
    }
    if (button.dataset.cmd) handleMenu(button.dataset.cmd);
  });

  window.previewKeyDown = () => {};

  init().catch((error) => {
    console.error(error);
    document.body.insertAdjacentHTML('afterbegin', `<pre style="color:red;padding:8px">${escapeHTML(String(error))}</pre>`);
  });
})();
