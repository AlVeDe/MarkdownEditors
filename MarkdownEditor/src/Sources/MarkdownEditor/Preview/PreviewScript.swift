import Foundation

/// The JavaScript half of the live preview, embedded in the page by
/// `HtmlPageRenderer` after mermaid.js and MathJax.
///
/// It exposes two functions to `PreviewController`:
///
/// - `updateContent(html, lineCount)` replaces the content of
///   `#content` with a new `HtmlRenderer` fragment **by diffing** its
///   top-level blocks on `data-hash`: unchanged blocks stay in the DOM with
///   their rendered diagrams and formulas, only new blocks are typeset. It
///   resolves to the mermaid and MathJax errors of the whole document, so
///   Swift can underline them in the editor.
/// - `scrollToSourceLine(line, edge, immediate)` scrolls so that the
///   editor's top source line (fractional) sits at the top of the preview,
///   interpolating between the `data-line` blocks around it.
///
/// Updates are serialized in a promise queue: MathJax's typesetting is not
/// re-entrant, and a theme switch re-rendering the diagrams must not race a
/// content update.
enum PreviewScript {
    static let source = #"""
    (function () {
        'use strict';
        const content = document.getElementById('content');
        const darkScheme = window.matchMedia('(prefers-color-scheme: dark)');
        const hasMermaid = typeof window.mermaid !== 'undefined';
        const hasMathJax = !!(window.MathJax && window.MathJax.startup);

        // The text of each diagram / formula, captured before the libraries
        // replace it with SVG: needed to re-render on a theme switch and to
        // report which formula failed.
        const sources = new WeakMap();
        // Mermaid parse errors per <pre class="mermaid">.
        const mermaidErrors = new WeakMap();
        // Diff keys of nodes without data-hash (raw HTML), fixed at insertion
        // because rendering may change their markup afterwards.
        const keys = new WeakMap();

        let lineCount = 1;

        function mermaidConfig() {
            return {
                startOnLoad: false,
                securityLevel: 'strict',
                suppressErrorRendering: true,
                htmlLabels: false,
                flowchart: { htmlLabels: false },
                theme: darkScheme.matches ? 'dark' : 'default'
            };
        }
        if (hasMermaid) { mermaid.initialize(mermaidConfig()); }

        let queue = Promise.resolve();
        function enqueue(job) {
            const result = queue.then(job, job);
            queue = result.catch(function () {});
            return result;
        }

        // MARK: Diff

        function significantChildren(parent) {
            for (const node of Array.from(parent.childNodes)) {
                if (node.nodeType === Node.TEXT_NODE && !node.textContent.trim()) { node.remove(); }
            }
            return Array.from(parent.childNodes);
        }

        function keyOf(node) {
            if (keys.has(node)) { return keys.get(node); }
            if (node.nodeType === Node.ELEMENT_NODE) {
                const hash = node.getAttribute('data-hash');
                return hash !== null ? 'h:' + hash : 'x:' + node.outerHTML;
            }
            return 'n' + node.nodeType + ':' + node.textContent;
        }

        // A kept block has the same HTML apart from line numbers; take the
        // new numbers (on itself and, pairwise, on its nested blocks).
        function copyLines(from, to) {
            if (from.nodeType !== Node.ELEMENT_NODE) { return; }
            for (const name of ['data-line', 'data-end-line']) {
                const value = from.getAttribute(name);
                if (value === null) { to.removeAttribute(name); } else { to.setAttribute(name, value); }
            }
            const fresh = from.querySelectorAll('[data-line]');
            const stale = to.querySelectorAll('[data-line]');
            if (fresh.length === stale.length) {
                fresh.forEach(function (element, index) {
                    stale[index].setAttribute('data-line', element.getAttribute('data-line'));
                });
            }
        }

        function within(nodes, selector) {
            const found = [];
            for (const node of nodes) {
                if (node.nodeType !== Node.ELEMENT_NODE) { continue; }
                if (node.matches(selector)) { found.push(node); }
                found.push.apply(found, node.querySelectorAll(selector));
            }
            return found;
        }

        async function applyUpdate(html, lines) {
            lineCount = Math.max(1, lines || 1);
            const anchor = captureAnchor();
            const template = document.createElement('template');
            template.innerHTML = html;
            const incoming = significantChildren(template.content);
            const current = significantChildren(content);

            const pool = new Map();
            for (const node of current) {
                const key = keyOf(node);
                if (!pool.has(key)) { pool.set(key, []); }
                pool.get(key).push(node);
            }
            const next = [];
            const added = [];
            for (const node of incoming) {
                const key = keyOf(node);
                const candidates = pool.get(key);
                if (candidates && candidates.length) {
                    const kept = candidates.shift();
                    copyLines(node, kept);
                    next.push(kept);
                } else {
                    keys.set(node, key);
                    next.push(node);
                    added.push(node);
                }
            }
            const removed = [];
            for (const rest of pool.values()) { removed.push.apply(removed, rest); }
            const removedElements = removed.filter(function (node) { return node.nodeType === Node.ELEMENT_NODE; });
            if (hasMathJax && removedElements.length && MathJax.typesetClear) {
                try { MathJax.typesetClear(removedElements); } catch (error) {}
            }
            for (const node of removed) { node.remove(); }
            next.forEach(function (node, index) {
                const occupant = content.childNodes[index];
                if (occupant !== node) { content.insertBefore(node, occupant || null); }
            });

            layoutChanged(anchor);
            await typeset(added);
            layoutChanged(anchor);
            return diagnostics();
        }

        // MARK: Typesetting

        async function typeset(nodes) {
            const math = within(nodes, '.math');
            const diagrams = within(nodes, 'pre.mermaid');
            for (const node of math) { sources.set(node, node.textContent); }
            for (const node of diagrams) { sources.set(node, node.textContent); }
            await Promise.all([renderDiagrams(diagrams), typesetMath(math)]);
        }

        async function typesetMath(nodes) {
            if (!hasMathJax || !nodes.length) { return; }
            try {
                await MathJax.startup.promise;
                await MathJax.typesetPromise(nodes);
            } catch (error) {}
        }

        async function renderDiagrams(nodes) {
            if (!hasMermaid || !nodes.length) { return; }
            const valid = [];
            for (const node of nodes) {
                try {
                    await mermaid.parse(sources.get(node));
                    mermaidErrors.delete(node);
                    node.classList.remove('mermaid-error');
                    valid.push(node);
                } catch (error) {
                    mermaidErrors.set(node, String((error && error.message) || error));
                    node.classList.add('mermaid-error');
                }
            }
            if (valid.length) {
                try { await mermaid.run({ nodes: valid, suppressErrors: true }); } catch (error) {}
            }
        }

        // Mermaid picks its theme at initialization: on a light/dark switch,
        // re-initialize and re-render every diagram from its source.
        darkScheme.addEventListener('change', function () {
            if (!hasMermaid) { return; }
            enqueue(async function () {
                mermaid.initialize(mermaidConfig());
                const nodes = Array.from(content.querySelectorAll('pre.mermaid')).filter(function (node) {
                    return sources.has(node) && !mermaidErrors.has(node);
                });
                for (const node of nodes) {
                    node.removeAttribute('data-processed');
                    node.textContent = sources.get(node);
                }
                const anchor = captureAnchor();
                if (nodes.length) {
                    try { await mermaid.run({ nodes: nodes, suppressErrors: true }); } catch (error) {}
                }
                layoutChanged(anchor);
            });
        });

        // MARK: Diagnostics

        function lineOf(element, attribute) {
            const holder = element.closest('[data-line]');
            const value = holder ? parseInt(holder.getAttribute(attribute || 'data-line'), 10) : NaN;
            return isNaN(value) ? 0 : value;
        }

        function diagnostics() {
            const diagrams = [];
            for (const node of content.querySelectorAll('pre.mermaid')) {
                const message = mermaidErrors.get(node);
                if (message) {
                    diagrams.push({ line: lineOf(node), endLine: lineOf(node, 'data-end-line'), message: message });
                }
            }
            const formulas = [];
            for (const node of content.querySelectorAll('.math')) {
                const failed = node.querySelector('[data-mjx-error]');
                let message = failed ? failed.getAttribute('data-mjx-error') : null;
                if (!message && node.querySelector('mjx-merror, [data-mml-node="merror"]')) {
                    message = 'Invalid formula';
                }
                if (!message) { continue; }
                const display = node.tagName === 'DIV';
                let tex = sources.get(node) || '';
                tex = display ? tex.replace(/^\s*\$\$/, '').replace(/\$\$\s*$/, '') : tex.replace(/^\\\(/, '').replace(/\\\)$/, '');
                formulas.push({
                    line: lineOf(node),
                    endLine: display ? lineOf(node, 'data-end-line') : 0,
                    display: display,
                    tex: tex.trim(),
                    message: message
                });
            }
            return { mermaid: diagrams, math: formulas };
        }

        // MARK: Scroll position

        // The last line the editor asked for; null once the user scrolls the
        // preview themselves, so later re-layouts stop yanking it back.
        let sync = null;
        let layout = null;
        let frame = 0;

        function scroller() { return document.scrollingElement || document.documentElement; }

        // [{line, top}] in source order with increasing `top`. For blocks
        // starting on the same line (a list and its first item) the
        // innermost one — last in document order — wins.
        function buildLayout() {
            const offset = scroller().scrollTop;
            const entries = [];
            for (const element of content.querySelectorAll('[data-line]')) {
                const line = parseInt(element.getAttribute('data-line'), 10);
                if (!line) { continue; }
                entries.push({ line: line, top: element.getBoundingClientRect().top + offset });
            }
            entries.sort(function (a, b) { return a.line - b.line; });
            const result = [];
            for (const entry of entries) {
                const last = result[result.length - 1];
                if (last && last.line === entry.line) {
                    last.top = entry.top;
                } else if (!last || entry.top >= last.top) {
                    result.push(entry);
                }
            }
            // The same-line replacement may have broken monotony; drop such
            // entries rather than scroll backwards.
            layout = result.filter(function (entry, index) {
                return index === 0 || entry.top >= result[index - 1].top;
            });
        }

        function offsetForLine(line) {
            if (!layout) { buildLayout(); }
            let previous = { line: 1, top: 0 };
            let next = { line: lineCount + 1, top: scroller().scrollHeight };
            let low = 0;
            let high = layout.length - 1;
            let found = -1;
            while (low <= high) {
                const middle = (low + high) >> 1;
                if (layout[middle].line <= line) { found = middle; low = middle + 1; } else { high = middle - 1; }
            }
            if (found >= 0) { previous = layout[found]; }
            if (found + 1 < layout.length) { next = layout[found + 1]; }
            const span = next.line - previous.line;
            const fraction = span > 0 ? Math.min(1, Math.max(0, (line - previous.line) / span)) : 0;
            return previous.top + fraction * (next.top - previous.top);
        }

        function applySync() {
            if (!sync) { return; }
            const element = scroller();
            if (sync.edge === 'top') {
                element.scrollTop = 0;
            } else if (sync.edge === 'bottom') {
                element.scrollTop = element.scrollHeight;
            } else {
                element.scrollTop = offsetForLine(sync.line);
            }
        }

        window.scrollToSourceLine = function (line, edge, immediate) {
            sync = { line: Number(line) || 1, edge: edge || null };
            if (immediate) { applySync(); return; }
            if (!frame) {
                frame = requestAnimationFrame(function () { frame = 0; applySync(); });
            }
        };

        // Without sync, keep what the reader looks at in place: remember the
        // first blocks in view and, after the DOM changed, scroll by however
        // far the first one still present moved.
        function captureAnchor() {
            if (sync || scroller().scrollTop <= 0) { return null; }
            const anchors = [];
            for (const element of content.children) {
                const rect = element.getBoundingClientRect();
                if (rect.bottom <= 0) { continue; }
                anchors.push({ element: element, top: rect.top });
                if (anchors.length >= 8 || rect.top > window.innerHeight) { break; }
            }
            return anchors;
        }

        function layoutChanged(anchors) {
            layout = null;
            if (sync) { applySync(); return; }
            if (!anchors) { return; }
            for (const anchor of anchors) {
                if (!anchor.element.isConnected) { continue; }
                const delta = anchor.element.getBoundingClientRect().top - anchor.top;
                if (delta) { scroller().scrollTop += delta; }
                return;
            }
        }

        for (const type of ['wheel', 'keydown', 'mousedown', 'touchstart']) {
            window.addEventListener(type, function () { sync = null; }, { passive: true });
        }
        // Diagrams, formulas and images change height after the fact; the
        // ResizeObserver catches all of them (an image `load` too, which is
        // listened for explicitly in case the size did not change).
        if (window.ResizeObserver) {
            new ResizeObserver(function () { layoutChanged(null); }).observe(content);
        }
        window.addEventListener('resize', function () { layoutChanged(null); });
        document.addEventListener('load', function (event) {
            if (event.target && event.target.tagName === 'IMG') { layoutChanged(null); }
        }, true);

        window.updateContent = function (html, lines) {
            return enqueue(function () { return applyUpdate(html, lines); });
        };

        // A page rendered with content up front (`HtmlPageRenderer.page`):
        // render its diagrams and formulas the same way.
        const initial = significantChildren(content);
        if (initial.length) {
            enqueue(function () { return typeset(initial); });
        }
    })();
    """#
}
