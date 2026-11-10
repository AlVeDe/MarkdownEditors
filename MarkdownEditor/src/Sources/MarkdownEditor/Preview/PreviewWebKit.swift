import AppKit
import WebKit

/// Serves bundled resources for the custom `appassets://` scheme.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "appassets"

    /// The allow-list of bundled scripts: mermaid.js for diagrams, MathJax
    /// (TeX → SVG, all TeX packages bundled so no CDN is ever contacted) for
    /// LaTeX formulas.
    private static let scripts: Set<String> = ["mermaid.min.js", "tex-svg-full.js"]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              Self.scripts.contains(url.lastPathComponent),
              let fileURL = Bundle.resources.url(
                  forResource: (url.lastPathComponent as NSString).deletingPathExtension,
                  withExtension: "js"
              ),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: "text/javascript",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// One rasterized SVG harvested from the preview.
///
/// The geometry is expressed in **em of the surrounding text** rather than in
/// pixels: the PDF renders at a different font size than the preview, and a
/// formula has to keep its proportion to the text around it — and, for inline
/// math, sit on the same baseline.
struct HarvestedSVG {
    let pngDataURL: String
    let widthEm: Double
    let heightEm: Double
    /// How far the image reaches below the text baseline, in em. Zero for
    /// block-level elements (mermaid diagrams, display math).
    let depthEm: Double
}

extension WKWebView {
    /// The preview as currently rendered — mermaid diagrams and MathJax
    /// formulas already turned into inline SVG — with all `<script>` elements
    /// removed, so the page opens in any browser without the `appassets://`
    /// scheme, and with `docfile://` image sources relative again (they
    /// resolve when the file is saved next to the document). Nil if the page
    /// cannot be read.
    func renderedStandaloneHTML() async -> String? {
        let js = """
        const root = document.documentElement.cloneNode(true);
        root.querySelectorAll('script').forEach(function (script) { script.remove(); });
        root.querySelectorAll('img').forEach(function (img) {
            const src = img.getAttribute('src') || '';
            if (src.startsWith(docBase)) { img.setAttribute('src', src.slice(docBase.length)); }
        });
        return '<!DOCTYPE html>\\n' + root.outerHTML;
        """
        return try? await callAsyncJavaScript(
            js,
            arguments: ["docBase": DocumentFileSchemeHandler.base],
            in: nil,
            contentWorld: .page
        ) as? String
    }

    /// Rasterizes every rendered mermaid diagram in the preview, in document
    /// order.
    func harvestMermaidDiagrams() async -> [HarvestedSVG?] {
        await harvestSVGs(containerSelector: "pre.mermaid")
    }

    /// Rasterizes every display formula (`$$ … $$`), in document order.
    func harvestDisplayMath() async -> [HarvestedSVG?] {
        await harvestSVGs(containerSelector: "div.math", inkColor: "#000000")
    }

    /// Rasterizes every inline formula (`$ … $`), in document order.
    func harvestInlineMath() async -> [HarvestedSVG?] {
        await harvestSVGs(containerSelector: "span.math", inkColor: "#000000")
    }

    /// Rasterizes the `<svg>` inside every element matching `containerSelector`
    /// to a PNG data URL (2x resolution), in document order. Containers whose
    /// SVG has not rendered (yet) yield `nil` so the PDF renderer can fall
    /// back to the source text.
    ///
    /// The SVG is cloned, given explicit pixel dimensions and serialized into
    /// a `data:` URL that an `Image` loads and a `<canvas>` rasterizes — the
    /// only way to get pixels out of a `WKWebView` subtree via JavaScript.
    /// `inkColor` pins `currentColor`, which a detached SVG cannot inherit.
    private func harvestSVGs(containerSelector: String, inkColor: String? = nil) async -> [HarvestedSVG?] {
        let js = """
        const containers = Array.from(document.querySelectorAll(selector));
        const results = [];
        for (const container of containers) {
            const svg = container.querySelector('svg');
            if (!svg) { results.push(null); continue; }
            try {
                const rect = svg.getBoundingClientRect();
                // Measure against the font the formula is embedded in, so the
                // PDF can re-scale it to its own type size.
                const fontSize = parseFloat(getComputedStyle(container).fontSize) || 16;
                // MathJax puts an inline formula's depth in `vertical-align`.
                const verticalAlign = parseFloat(getComputedStyle(svg).verticalAlign);
                const depth = isNaN(verticalAlign) ? 0 : Math.max(0, -verticalAlign);

                const clone = svg.cloneNode(true);
                clone.setAttribute('width', Math.max(1, Math.round(rect.width)));
                clone.setAttribute('height', Math.max(1, Math.round(rect.height)));
                if (ink) { clone.style.color = ink; }
                const xml = new XMLSerializer().serializeToString(clone);
                const img = new Image();
                const loaded = new Promise(function (resolve, reject) {
                    img.onload = resolve;
                    img.onerror = reject;
                });
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
        """
        do {
            let result = try await callAsyncJavaScript(
                js,
                arguments: ["selector": containerSelector, "ink": inkColor ?? ""],
                in: nil,
                contentWorld: .page
            )
            return (result as? [Any])?.map { entry in
                guard let entry = entry as? [String: Any],
                      let png = entry["png"] as? String,
                      let widthEm = entry["widthEm"] as? Double,
                      let heightEm = entry["heightEm"] as? Double
                else { return nil }
                return HarvestedSVG(
                    pngDataURL: png,
                    widthEm: widthEm,
                    heightEm: heightEm,
                    depthEm: entry["depthEm"] as? Double ?? 0
                )
            } ?? []
        } catch {
            return []
        }
    }
}
