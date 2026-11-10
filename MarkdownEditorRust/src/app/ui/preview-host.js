// Preview-side helpers for the app (loaded after preview.js inside the
// preview frame): link handling, PDF harvesting and the HTML export.
(function () {
  'use strict';
  const content = document.getElementById('content');

  // Links: in-page anchors scroll here; everything else opens in the
  // default browser instead of replacing the preview.
  document.addEventListener('click', function (event) {
    const link = event.target.closest && event.target.closest('a[href]');
    if (!link) { return; }
    event.preventDefault();
    const href = link.getAttribute('href') || '';
    if (href.startsWith('#')) {
      const target = document.getElementById(decodeURIComponent(href.slice(1)));
      if (target) { target.scrollIntoView({ block: 'start' }); }
      return;
    }
    if (window.parent && window.parent.openExternal) { window.parent.openExternal(href); }
  });

  // Keyboard shortcuts typed while the preview has focus go to the app.
  document.addEventListener('keydown', function (event) {
    if (window.parent && window.parent.previewKeyDown) { window.parent.previewKeyDown(event); }
  });

  /// Rasterizes the <svg> inside every element matching `selector` to a PNG
  /// data URL (2x), in document order; `null` where nothing rendered.
  /// Geometry is in em of the surrounding text so the PDF can re-scale it.
  window.harvestSVGs = async function (selector, ink) {
    const containers = Array.from(document.querySelectorAll(selector));
    const results = [];
    for (const container of containers) {
      const svg = container.querySelector('svg');
      if (!svg) { results.push(null); continue; }
      try {
        const rect = svg.getBoundingClientRect();
        const fontSize = parseFloat(getComputedStyle(container).fontSize) || 16;
        const verticalAlign = parseFloat(getComputedStyle(svg).verticalAlign);
        const depth = isNaN(verticalAlign) ? 0 : Math.max(0, -verticalAlign);
        const clone = svg.cloneNode(true);
        clone.setAttribute('width', Math.max(1, Math.round(rect.width)));
        clone.setAttribute('height', Math.max(1, Math.round(rect.height)));
        if (!clone.getAttribute('xmlns')) { clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg'); }
        if (ink) { clone.style.color = ink; }
        const xml = new XMLSerializer().serializeToString(clone);
        const img = new Image();
        const loaded = new Promise(function (resolve, reject) { img.onload = resolve; img.onerror = reject; });
        img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml);
        await loaded;
        const scale = 2;
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(rect.width * scale));
        canvas.height = Math.max(1, Math.round(rect.height * scale));
        const ctx = canvas.getContext('2d');
        ctx.scale(scale, scale);
        ctx.drawImage(img, 0, 0, rect.width, rect.height);
        results.push({
          png: canvas.toDataURL('image/png'),
          widthEm: rect.width / fontSize,
          heightEm: rect.height / fontSize,
          depthEm: depth / fontSize
        });
      } catch (error) {
        results.push(null);
      }
    }
    return results;
  };

  /// The rendered content (diagrams and formulas as inline SVG) without
  /// scripts or line attributes; document-relative image URLs made relative
  /// again so the file works next to the document.
  window.renderedContentHTML = function (docBase) {
    const clone = content.cloneNode(true);
    clone.querySelectorAll('script').forEach(function (s) { s.remove(); });
    clone.querySelectorAll('[data-line],[data-end-line],[data-hash],[data-processed]').forEach(function (el) {
      el.removeAttribute('data-line');
      el.removeAttribute('data-end-line');
      el.removeAttribute('data-hash');
    });
    if (docBase) {
      clone.querySelectorAll('img').forEach(function (img) {
        const src = img.getAttribute('src') || '';
        if (src.startsWith(docBase)) { img.setAttribute('src', decodeURI(src.slice(docBase.length))); }
      });
    }
    return clone.innerHTML;
  };

  window.previewTheme = function (theme) {
    if (theme) { document.documentElement.setAttribute('data-theme', theme); }
    else { document.documentElement.removeAttribute('data-theme'); }
  };
})();
