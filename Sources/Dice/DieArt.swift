import CoreGraphics
import Foundation

/// Colours for one look of the die (classic, Friday the 13th, hot-streak gold).
struct DiePalette: Equatable {
    let name: String
    let body: CGColor        // face colour (textures)
    let highlight: CGColor   // tile gradient top
    let shade: CGColor       // tile gradient bottom
    let pipInner: CGColor
    let pipOuter: CGColor
    let edge: CGColor        // tile hairline

    static func == (a: DiePalette, b: DiePalette) -> Bool { a.name == b.name }

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: DieArt.sRGB, components: [r, g, b, a])!
    }
    static let classic = DiePalette(name: "classic",
                                    body: c(0.975, 0.962, 0.925), highlight: c(0.975, 0.962, 0.925),
                                    shade: c(0.900, 0.885, 0.845),
                                    pipInner: c(0.20, 0.20, 0.21), pipOuter: c(0.03, 0.03, 0.035),
                                    edge: c(0, 0, 0, 0.14))
    static let friday13 = DiePalette(name: "friday13",
                                     body: c(0.085, 0.085, 0.095), highlight: c(0.20, 0.20, 0.22),
                                     shade: c(0.035, 0.035, 0.04),
                                     pipInner: c(1.00, 0.33, 0.27), pipOuter: c(0.66, 0.03, 0.04),
                                     edge: c(1, 1, 1, 0.16))
    static let gold = DiePalette(name: "gold",
                                 body: c(0.86, 0.68, 0.27), highlight: c(0.99, 0.88, 0.50),
                                 shade: c(0.58, 0.41, 0.11),
                                 pipInner: c(0.22, 0.15, 0.05), pipOuter: c(0.07, 0.045, 0.01),
                                 edge: c(0.35, 0.22, 0.02, 0.45))
}

/// Core Graphics drawing of die faces. Shared by the SceneKit textures, the Dock tile and the
/// app icon (scripts/make-icon.swift compiles this file directly), so it depends on CoreGraphics only.
enum DieArt {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let ivory = CGColor(colorSpace: sRGB, components: [0.975, 0.962, 0.925, 1])!
    static let ivoryShade = CGColor(colorSpace: sRGB, components: [0.900, 0.885, 0.845, 1])!
    static let pipInner = CGColor(colorSpace: sRGB, components: [0.20, 0.20, 0.21, 1])!
    static let pipOuter = CGColor(colorSpace: sRGB, components: [0.03, 0.03, 0.035, 1])!

    static func makeContext(_ px: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        return ctx
    }

    /// Pip centres in a unit square (y up). Opposite faces sum to 7 by construction of the values.
    static func pipLayout(_ value: Int) -> [CGPoint] {
        let l: CGFloat = 0.25, c: CGFloat = 0.5, h: CGFloat = 0.75
        switch value {
        case 1: return [CGPoint(x: c, y: c)]
        case 2: return [CGPoint(x: l, y: h), CGPoint(x: h, y: l)]
        case 3: return [CGPoint(x: l, y: h), CGPoint(x: c, y: c), CGPoint(x: h, y: l)]
        case 4: return [CGPoint(x: l, y: l), CGPoint(x: l, y: h), CGPoint(x: h, y: l), CGPoint(x: h, y: h)]
        case 5: return [CGPoint(x: l, y: l), CGPoint(x: l, y: h), CGPoint(x: c, y: c),
                        CGPoint(x: h, y: l), CGPoint(x: h, y: h)]
        default: return [CGPoint(x: l, y: l), CGPoint(x: l, y: c), CGPoint(x: l, y: h),
                         CGPoint(x: h, y: l), CGPoint(x: h, y: c), CGPoint(x: h, y: h)]
        }
    }

    /// Slightly domed-looking pips: a radial gradient from dark grey to near black.
    static func drawPips(_ value: Int, in r: CGRect, ctx: CGContext, palette: DiePalette = .classic) {
        let radius = r.width * (value == 1 ? 0.115 : 0.092)
        let gradient = CGGradient(colorsSpace: sRGB, colors: [palette.pipInner, palette.pipOuter] as CFArray,
                                  locations: [0, 1])!
        for p in pipLayout(value) {
            let centre = CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                      width: radius * 2, height: radius * 2))
            ctx.clip()
            let hot = CGPoint(x: centre.x - radius * 0.3, y: centre.y + radius * 0.3)
            ctx.drawRadialGradient(gradient, startCenter: hot, startRadius: 0,
                                   endCenter: centre, endRadius: radius * 1.05,
                                   options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    /// Full-bleed square texture for one face of the SceneKit die.
    /// `pips: false` gives the bare face (used for the loaded die's wink).
    static func texture(value: Int, px: Int = 512, palette: DiePalette = .classic, pips: Bool = true) -> CGImage {
        let ctx = makeContext(px)
        let r = CGRect(x: 0, y: 0, width: px, height: px)
        ctx.setFillColor(palette.body)
        ctx.fill(r)
        if pips { drawPips(value, in: r, ctx: ctx, palette: palette) }
        return ctx.makeImage()!
    }

    /// Vertical gradient used as a fake environment reflection for the gold die.
    static func goldReflection(px: Int = 256) -> CGImage {
        let ctx = makeContext(px)
        let g = CGGradient(colorsSpace: sRGB,
                           colors: [CGColor(colorSpace: sRGB, components: [1.0, 0.95, 0.75, 1])!,
                                    CGColor(colorSpace: sRGB, components: [0.85, 0.62, 0.20, 1])!,
                                    CGColor(colorSpace: sRGB, components: [0.30, 0.18, 0.03, 1])!,
                                    CGColor(colorSpace: sRGB, components: [0.75, 0.55, 0.18, 1])!] as CFArray,
                           locations: [0, 0.35, 0.65, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(px)), end: .zero, options: [])
        return ctx.makeImage()!
    }

    /// The body rect for tile/icon art: macOS icon grid (824/1024 body, centred, nudged up for the shadow).
    static func bodyRect(_ px: Int) -> CGRect {
        let s = CGFloat(px)
        let side = s * 0.80
        return CGRect(x: (s - side) / 2, y: (s - side) / 2 + s * 0.012, width: side, height: side)
    }

    /// 2D die face for the Dock tile and app icon: rounded ivory square, soft shadow, black pips.
    static func tileFace(value: Int, px: Int = 256, palette: DiePalette = .classic) -> CGImage {
        let ctx = makeContext(px)
        let s = CGFloat(px)
        let body = bodyRect(px)
        let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.2, cornerHeight: body.width * 0.2,
                          transform: nil)
        // Shadow pass.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.045,
                      color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.42]))
        ctx.addPath(path)
        ctx.setFillColor(palette.body)
        ctx.fillPath()
        ctx.restoreGState()
        // Gentle top-to-bottom shading.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: sRGB, colors: [palette.highlight, palette.body, palette.shade] as CFArray,
                           locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        ctx.restoreGState()
        // Hairline edge.
        ctx.addPath(path)
        ctx.setStrokeColor(palette.edge)
        ctx.setLineWidth(max(1, s * 0.006))
        ctx.strokePath()
        drawPips(value, in: body, ctx: ctx, palette: palette)
        return ctx.makeImage()!
    }

    /// The empty slot shown in the Dock while the die is out: dashed rounded square, low opacity.
    static func emptySlot(px: Int = 256) -> CGImage {
        let ctx = makeContext(px)
        let s = CGFloat(px)
        let body = bodyRect(px).insetBy(dx: s * 0.02, dy: s * 0.02)
        let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.2, cornerHeight: body.width * 0.2,
                          transform: nil)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(colorSpace: sRGB, components: [0.55, 0.55, 0.57, 0.6])!)
        ctx.setLineWidth(s * 0.03)
        ctx.setLineDash(phase: 0, lengths: [s * 0.075, s * 0.05])
        ctx.setLineCap(.round)
        ctx.strokePath()
        return ctx.makeImage()!
    }

    /// Soft radial blob used as the fallback contact shadow under the die.
    static func blobShadow(px: Int = 256) -> CGImage {
        let ctx = makeContext(px)
        let s = CGFloat(px)
        let g = CGGradient(colorsSpace: sRGB,
                           colors: [CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.55])!,
                                    CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.25])!,
                                    CGColor(colorSpace: sRGB, components: [0, 0, 0, 0])!] as CFArray,
                           locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                               endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
        return ctx.makeImage()!
    }
}
