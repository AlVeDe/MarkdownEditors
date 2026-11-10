import AppKit
import Markdown

struct PdfExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// PDF export entry point: parses the Markdown (LaTeX blocks normalized by
/// `MathBlocks` first, exactly as for the preview), decodes the PNGs harvested
/// from the preview and drives `PdfDocumentRenderer` through a `CGPDFContext`.
///
/// Rendering runs twice: a throwaway pass counts the pages so the second,
/// real pass can emit a correct `page / total` footer.
enum PdfExporter {
    static func export(
        markdown: String,
        mermaid: [HarvestedSVG?],
        displayMath: [HarvestedSVG?],
        inlineMath: [HarvestedSVG?],
        to url: URL
    ) throws {
        let document = MathBlocks.parse(markdown)
        let mermaidImages = mermaid.map { decodePNG($0?.pngDataURL) }
        let displayMathImages = displayMath.map(decodeMath)
        let inlineMathImages = inlineMath.map(decodeMath)
        var mediaBox = CGRect(origin: .zero, size: PdfDocumentRenderer.Layout.pageSize)

        // Pass 1: count pages.
        let scratch = NSMutableData()
        guard let scratchConsumer = CGDataConsumer(data: scratch),
              let scratchContext = CGContext(consumer: scratchConsumer, mediaBox: &mediaBox, nil)
        else {
            throw PdfExportError(message: "Could not create a PDF context.")
        }
        let pageCount = PdfDocumentRenderer(mermaidImages: mermaidImages, displayMathImages: displayMathImages, inlineMathImages: inlineMathImages)
            .render(document, into: scratchContext)
        scratchContext.closePDF()

        // Pass 2: render for real, with the total page count for the footer.
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw PdfExportError(message: "Could not write to “\(url.lastPathComponent)”.")
        }
        PdfDocumentRenderer(mermaidImages: mermaidImages, displayMathImages: displayMathImages, inlineMathImages: inlineMathImages, totalPages: pageCount)
            .render(document, into: context)
        context.closePDF()
    }

    /// Pairs a decoded bitmap with the geometry the harvester measured.
    private static func decodeMath(_ harvested: HarvestedSVG?) -> MathImage? {
        guard let harvested, let image = decodePNG(harvested.pngDataURL) else { return nil }
        return MathImage(
            image: image,
            widthEm: CGFloat(harvested.widthEm),
            heightEm: CGFloat(harvested.heightEm),
            depthEm: CGFloat(harvested.depthEm)
        )
    }

    /// Decodes a `data:image/png;base64,…` URL (from the preview harvesters)
    /// into a `CGImage`.
    private static func decodePNG(_ dataURL: String?) -> CGImage? {
        guard let dataURL,
              let marker = dataURL.range(of: "base64,"),
              let data = Data(base64Encoded: String(dataURL[marker.upperBound...]))
        else {
            return nil
        }
        return NSBitmapImageRep(data: data)?.cgImage
    }
}
