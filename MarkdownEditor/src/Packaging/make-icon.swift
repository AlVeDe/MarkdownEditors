// Draws the app icon with Core Graphics and writes a macOS `.iconset`.
//
//   swift Packaging/make-icon.swift <output.iconset>
//   iconutil -c icns <output.iconset> -o Packaging/AppIcon.icns
//
// The design follows the macOS icon grid: an 824 pt rounded square on a
// 1024 pt canvas, a violet → magenta → orange gradient, and a sheet of paper
// carrying the Markdown mark (M↓) above a few lines of "text".

import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func drawIcon(in ctx: CGContext) {
    // Core Graphics origin is bottom-left; flip so the drawing reads top-down.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // MARK: Background squircle with drop shadow
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x5B2BD9))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x4F46E5), color(0x9333EA), color(0xDB2777), color(0xF97316)], [0, 0.4, 0.75, 1]),
        start: CGPoint(x: tile.minX, y: tile.minY),
        end: CGPoint(x: tile.maxX, y: tile.maxY),
        options: []
    )
    // Soft glow in the upper-left and a gloss band across the top.
    ctx.drawRadialGradient(
        gradient([color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)], [0, 1]),
        startCenter: CGPoint(x: 280, y: 230), startRadius: 0,
        endCenter: CGPoint(x: 280, y: 230), endRadius: 520,
        options: []
    )
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: 0, y: tile.minY),
        end: CGPoint(x: 0, y: tile.minY + 360),
        options: []
    )
    ctx.restoreGState()

    // Hairline inner border for definition on dark docks.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.25))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // MARK: Paper sheet with folded corner
    let sheet = CGRect(x: 262, y: 200, width: 500, height: 624)
    let fold: CGFloat = 120
    let sheetPath = CGMutablePath()
    sheetPath.move(to: CGPoint(x: sheet.minX + 36, y: sheet.minY))
    sheetPath.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.minY))
    sheetPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + fold))
    sheetPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - 36))
    sheetPath.addQuadCurve(to: CGPoint(x: sheet.maxX - 36, y: sheet.maxY), control: CGPoint(x: sheet.maxX, y: sheet.maxY))
    sheetPath.addLine(to: CGPoint(x: sheet.minX + 36, y: sheet.maxY))
    sheetPath.addQuadCurve(to: CGPoint(x: sheet.minX, y: sheet.maxY - 36), control: CGPoint(x: sheet.minX, y: sheet.maxY))
    sheetPath.addLine(to: CGPoint(x: sheet.minX, y: sheet.minY + 36))
    sheetPath.addQuadCurve(to: CGPoint(x: sheet.minX + 36, y: sheet.minY), control: CGPoint(x: sheet.minX, y: sheet.minY))
    sheetPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: color(0x1E0B4B, 0.45))
    ctx.addPath(sheetPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(sheetPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF), color(0xF1EEFB)], [0, 1]),
        start: CGPoint(x: 0, y: sheet.minY),
        end: CGPoint(x: 0, y: sheet.maxY),
        options: []
    )
    ctx.restoreGState()

    // The dog-ear.
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.minY))
    ear.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.minY + fold - 22))
    ear.addQuadCurve(to: CGPoint(x: sheet.maxX - fold + 22, y: sheet.minY + fold),
                     control: CGPoint(x: sheet.maxX - fold, y: sheet.minY + fold))
    ear.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY + fold))
    ear.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -6, height: 8), blur: 14, color: color(0x1E0B4B, 0.25))
    ctx.addPath(ear)
    ctx.setFillColor(color(0xDDD6FE))
    ctx.fillPath()
    ctx.restoreGState()

    // MARK: Markdown mark — a rounded frame holding "M" and a down arrow
    let accent = gradient([color(0x4F46E5), color(0xC026D3)], [0, 1])
    let mark = CGRect(x: 318, y: 330, width: 388, height: 238)

    let markShape = CGMutablePath()
    markShape.addPath(CGPath(roundedRect: mark, cornerWidth: 40, cornerHeight: 40, transform: nil))
    markShape.addPath(CGPath(roundedRect: mark.insetBy(dx: 24, dy: 24), cornerWidth: 20, cornerHeight: 20, transform: nil))

    // "M": two legs joined by a V.
    let m = CGMutablePath()
    let top = mark.minY + 62, bottom = mark.maxY - 62
    let mx = mark.minX + 64, mw: CGFloat = 150, stroke: CGFloat = 36
    m.move(to: CGPoint(x: mx, y: bottom))
    m.addLine(to: CGPoint(x: mx, y: top))
    m.addLine(to: CGPoint(x: mx + mw / 2, y: top + 64))
    m.addLine(to: CGPoint(x: mx + mw, y: top))
    m.addLine(to: CGPoint(x: mx + mw, y: bottom))
    let mStroke = m.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)

    // Down arrow.
    let ax = mark.maxX - 98
    let arrow = CGMutablePath()
    arrow.addRect(CGRect(x: ax - 18, y: top - 18, width: 36, height: bottom - top - 30))
    arrow.move(to: CGPoint(x: ax - 58, y: bottom - 62))
    arrow.addLine(to: CGPoint(x: ax + 58, y: bottom - 62))
    arrow.addLine(to: CGPoint(x: ax, y: bottom + 18))
    arrow.closeSubpath()

    // Each shape gets its own clip: the frame needs even-odd for its hole,
    // while the self-overlapping M and arrow must fill with nonzero.
    for (shape, rule) in [(markShape as CGPath, CGPathFillRule.evenOdd), (mStroke, .winding), (arrow, .winding)] {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip(using: rule)
        ctx.drawLinearGradient(accent, start: CGPoint(x: mark.minX, y: mark.minY),
                               end: CGPoint(x: mark.maxX, y: mark.maxY), options: [])
        ctx.restoreGState()
    }

    // MARK: Text lines
    let lines: [(CGFloat, CGFloat)] = [(626, 388), (676, 300), (726, 352)]
    for (y, width) in lines {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 318, y: y, width: width, height: 22),
                           cornerWidth: 11, cornerHeight: 11, transform: nil))
    }
    ctx.setFillColor(color(0xC4B5FD))
    ctx.fillPath()
}

// MARK: - Render master image and write the iconset

let outputDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let file = outputDir.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try render(size: points * scale).write(to: file)
    }
}
print("Wrote \(outputDir.path)")
