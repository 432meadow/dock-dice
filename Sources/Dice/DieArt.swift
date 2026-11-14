import CoreGraphics
import Foundation

/// How a face's surface is drawn (textures and Dock tile).
enum SurfaceKind: String {
    case plain        // flat colour (classic, Friday the 13th, gold)
    case aged         // bone: mottling, speckle, scratches, darker worn edges
    case translucent  // dark resin: depth gradient, pip light bleeding into the body
    case void         // flat black, faint cold rim (emission) at the edges
}

/// How the pips are drawn.
enum PipKind: String {
    case domed        // radial-gradient dots (classic)
    case ringDot      // antique bone: drilled dot inside a scribed circle, slightly irregular
    case glow         // emissive dots with a soft bleed
    case point        // small cold-white points
}

/// SceneKit material settings, kept as plain values so this file stays CoreGraphics-only.
struct SurfaceFinish {
    enum Lighting: String { case blinn, lambert }
    enum Reflection { case none, gold, rim(CGColor, exponent: CGFloat, intensity: CGFloat) }
    var lighting = Lighting.blinn
    var specular: CGColor = DieArt.grey(0.35)
    var shininess: CGFloat = 0.35
    var reflection = Reflection.none
}

/// What the die puts on the table under itself: a soft shadow, a coloured halo, or both.
struct FloorLook {
    var shadow: CGFloat = 1          // shadow strength, 0...1
    var halo: CGColor? = nil         // halo colour (the die gives off light)
    var size: CGFloat = 1.5          // plane edge in die units
    var follows = true               // shadow falls down-right from the key light; a halo sits centred
}

/// One complete look of the die: colours plus surface, pip treatment, emission, corner radius,
/// material and floor. The user's style choice (DieStyle) picks one; Friday the 13th and
/// hot-streak gold are looks too. Equality is by name.
struct DiePalette: Equatable {
    let name: String
    let body: CGColor        // face colour (textures)
    let highlight: CGColor   // tile gradient top
    let shade: CGColor       // tile gradient bottom
    let pipInner: CGColor
    let pipOuter: CGColor
    let edge: CGColor        // tile hairline
    var surface = SurfaceKind.plain
    var pips = PipKind.domed
    /// Emission colour of pips (and anything else that gives off light). nil: no emission map.
    var glow: CGColor? = nil
    /// Emission tint along face edges, so a black body still shows its shape.
    var rim: CGColor? = nil
    /// SCNBox chamfer radius (die edge = 1).
    var chamfer: CGFloat = 0.12
    /// Tile corner radius as a fraction of the tile body.
    var tileCorner: CGFloat = 0.2
    var finish = SurfaceFinish()
    var floor = FloorLook()

    /// True when the faces carry an emission map (lit pips or a rim).
    var emissive: Bool { glow != nil || rim != nil }

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
                                     edge: c(1, 1, 1, 0.16),
                                     // Tight highlight only: a broad one washes the black top face out to grey.
                                     finish: SurfaceFinish(specular: DieArt.grey(0.2), shininess: 1.0))
    static let gold = DiePalette(name: "gold",
                                 body: c(0.86, 0.68, 0.27), highlight: c(0.99, 0.88, 0.50),
                                 shade: c(0.58, 0.41, 0.11),
                                 pipInner: c(0.22, 0.15, 0.05), pipOuter: c(0.07, 0.045, 0.01),
                                 edge: c(0.35, 0.22, 0.02, 0.45),
                                 finish: SurfaceFinish(specular: c(1.0, 0.86, 0.48), shininess: 0.8, reflection: .gold))

    /// Old bone, dug up: warm uneven off-white to tan, worn darker edges, softer corners, matte,
    /// dark brown ring-and-dot pips.
    static let ancient = DiePalette(name: "ancient",
                                    body: c(0.865, 0.800, 0.665), highlight: c(0.935, 0.890, 0.780),
                                    shade: c(0.700, 0.600, 0.440),
                                    pipInner: c(0.330, 0.205, 0.100), pipOuter: c(0.205, 0.120, 0.055),
                                    edge: c(0.30, 0.19, 0.08, 0.40),
                                    surface: .aged, pips: .ringDot, chamfer: 0.2, tileCorner: 0.28,
                                    finish: SurfaceFinish(lighting: .lambert, specular: DieArt.grey(0), shininess: 0.05))

    /// Gives off light: dark, glassy resin body, phosphor aqua-green pips (emission), and a soft
    /// halo of the same colour on the table instead of most of the shadow.
    static let glowing = DiePalette(name: "glowing",
                                    body: c(0.040, 0.080, 0.085), highlight: c(0.090, 0.165, 0.165),
                                    shade: c(0.015, 0.035, 0.040),
                                    pipInner: c(0.82, 1.00, 0.93), pipOuter: c(0.34, 0.98, 0.76),
                                    edge: c(0.36, 1.00, 0.78, 0.40),
                                    surface: .translucent, pips: .glow, glow: c(0.36, 1.00, 0.78),
                                    finish: SurfaceFinish(specular: DieArt.grey(0.35), shininess: 1.0,
                                                          reflection: .rim(c(0.16, 0.42, 0.36), exponent: 2.2, intensity: 0.6)),
                                    floor: FloorLook(shadow: 0.55, halo: c(0.06, 0.76, 0.58), size: 2.7, follows: false))

    /// A hole in the screen: flat light-absorbing black, cold-white point pips, a faint cold rim
    /// so the cube still reads while it tumbles, almost no shadow.
    static let void = DiePalette(name: "void",
                                 body: c(0.0, 0.0, 0.004), highlight: c(0.0, 0.0, 0.004),
                                 shade: c(0.0, 0.0, 0.004),
                                 pipInner: c(1.0, 1.0, 1.0), pipOuter: c(0.82, 0.89, 1.0),
                                 edge: c(0.50, 0.58, 0.76, 0.55),
                                 surface: .void, pips: .point, glow: c(0.88, 0.93, 1.0), rim: c(0.30, 0.37, 0.52),
                                 finish: SurfaceFinish(lighting: .lambert, specular: DieArt.grey(0), shininess: 0,
                                                       reflection: .rim(c(0.22, 0.27, 0.40), exponent: 3.0, intensity: 0.5)),
                                 floor: FloorLook(shadow: 0.22))
}

/// The look the user picks from the Dock menu ("Dice Style"). Friday the 13th only replaces
/// classic; hot-streak gold replaces any of them while it lasts.
enum DieStyle: String, CaseIterable {
    case classic, ancient, glowing, void

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var palette: DiePalette {
        switch self {
        case .classic: return .classic
        case .ancient: return .ancient
        case .glowing: return .glowing
        case .void: return .void
        }
    }
}

/// How the pips are drawn. `constellation` (Hot Hand game dice only) keeps the standard pip
/// positions and dot size, and joins the dots with hairlines into small open "constellations";
/// the 1 gets a thin orbit ring. It must still read instantly as an ordinary die.
enum PipStyle: String {
    case plain
    case constellation
}

/// Core Graphics drawing of die faces. Shared by the SceneKit textures, the Dock tile and the
/// app icon (scripts/make-icon.swift compiles this file directly), so it depends on CoreGraphics only.
enum DieArt {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let ivory = CGColor(colorSpace: sRGB, components: [0.975, 0.962, 0.925, 1])!
    static let ivoryShade = CGColor(colorSpace: sRGB, components: [0.900, 0.885, 0.845, 1])!
    static let pipInner = CGColor(colorSpace: sRGB, components: [0.20, 0.20, 0.21, 1])!
    static let pipOuter = CGColor(colorSpace: sRGB, components: [0.03, 0.03, 0.035, 1])!
    /// Warm glow on scoring dice (Hot Hand). Materials with an emission map get it as a wash.
    static let scoreGlow = CGColor(colorSpace: sRGB, components: [1.0, 0.78, 0.42, 1])!
    static let scoreGlowIntensity: CGFloat = 0.38

    static func grey(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [w, w, w, a])!
    }

    static func alpha(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: a) ?? c }

    /// Deterministic noise, so a styled die looks the same every launch (and on every die).
    struct Seeded {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func unit() -> CGFloat {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return CGFloat(z >> 11) / CGFloat(1 << 53)
        }
        mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    }

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

    /// Pip radius for the style (the outer ring for ring-and-dot), as a fraction of the face.
    static func pipRadius(_ value: Int, _ kind: PipKind) -> CGFloat {
        switch kind {
        case .domed: return value == 1 ? 0.115 : 0.092
        case .ringDot: return value == 1 ? 0.104 : 0.080
        case .glow: return value == 1 ? 0.106 : 0.086
        case .point: return value == 1 ? 0.052 : 0.040
        }
    }

    /// The pips in the palette's style (the lit part of glowing pips is in the emission map).
    /// `weight` thickens line-drawn pips (the ring-and-dot on the small Dock tile).
    static func drawPips(_ value: Int, in r: CGRect, ctx: CGContext, palette: DiePalette = .classic, weight: CGFloat = 1) {
        switch palette.pips {
        case .domed: drawDomedPips(value, in: r, ctx: ctx, palette: palette)
        case .ringDot: drawRingDots(value, in: r, ctx: ctx, palette: palette, weight: weight)
        case .glow, .point: drawLitPips(value, in: r, ctx: ctx, palette: palette, emission: false)
        }
    }

    static func circle(_ c: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
    }

    static func radial(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, colors: [CGColor], locations: [CGFloat]) {
        let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    /// Antique bone pips: a small drilled dot inside a scribed circle. Each pip is a touch off
    /// in place and size (seeded, so always the same), never enough to misread the face.
    static func drawRingDots(_ value: Int, in r: CGRect, ctx: CGContext, palette: DiePalette, weight: CGFloat = 1) {
        let w = r.width
        for (i, p) in pipLayout(value).enumerated() {
            var rng = Seeded(UInt64(value * 97 + i * 13 + 5))
            let centre = CGPoint(x: r.minX + (p.x + rng.range(-0.011, 0.011)) * w,
                                 y: r.minY + (p.y + rng.range(-0.011, 0.011)) * w)
            let ring = w * pipRadius(value, .ringDot) * rng.range(0.95, 1.05)
            let dot = w * (value == 1 ? 0.034 : 0.026) * rng.range(0.92, 1.08) * (1 + (weight - 1) * 0.6)
            let dc = CGPoint(x: centre.x + rng.range(-0.004, 0.004) * w, y: centre.y + rng.range(-0.004, 0.004) * w)
            ctx.saveGState()
            // Grime settled inside the circle.
            ctx.setFillColor(alpha(palette.pipOuter, 0.10))
            ctx.fillEllipse(in: circle(centre, ring * 0.94))
            // The groove: a lit lower lip (light from the upper left), then the cut itself.
            ctx.setLineWidth(w * 0.011 * weight)
            ctx.setStrokeColor(alpha(palette.highlight, 0.75))
            ctx.strokeEllipse(in: circle(CGPoint(x: centre.x + w * 0.004, y: centre.y - w * 0.004), ring))
            ctx.setLineWidth(w * 0.0145 * weight)
            ctx.setStrokeColor(alpha(palette.pipInner, 0.95))
            ctx.strokeEllipse(in: circle(centre, ring))
            // The drilled dot: darkest in the middle.
            ctx.addEllipse(in: circle(dc, dot))
            ctx.clip()
            radial(ctx, at: dc, radius: dot * 1.05, colors: [alpha(palette.pipOuter, 1), alpha(palette.pipInner, 1)],
                   locations: [0.2, 1])
            ctx.restoreGState()
        }
    }

    /// Pips that give off light. `emission: false` draws their colour in the face texture;
    /// `emission: true` draws the light itself (bright core plus a soft bleed into the body).
    static func drawLitPips(_ value: Int, in r: CGRect, ctx: CGContext, palette: DiePalette, emission: Bool) {
        let radius = r.width * pipRadius(value, palette.pips)
        let glow = palette.glow ?? palette.pipOuter
        let point = palette.pips == .point
        for p in pipLayout(value) {
            let c = CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
            ctx.saveGState()
            if emission {
                radial(ctx, at: c, radius: radius * (point ? 2.3 : 2.5),
                       colors: [alpha(glow, point ? 0.30 : 0.42), alpha(glow, point ? 0.08 : 0.16), alpha(glow, 0)],
                       locations: [0.35, 0.6, 1])
            }
            ctx.addEllipse(in: circle(c, radius))
            ctx.clip()
            radial(ctx, at: c, radius: radius * 1.02,
                   colors: [palette.pipInner, palette.pipInner, emission ? glow : palette.pipOuter],
                   locations: [0, point ? 0.45 : 0.25, 1])
            ctx.restoreGState()
        }
    }

    /// Slightly domed-looking pips: a radial gradient from dark grey to near black.
    static func drawDomedPips(_ value: Int, in r: CGRect, ctx: CGContext, palette: DiePalette = .classic) {
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
    /// `wild: true` with value 1 draws the Hot Hand special die's wild face: one open ring.
    static func texture(value: Int, px: Int = 512, palette: DiePalette = .classic, pips: Bool = true,
                        style: PipStyle = .plain, wild: Bool = false) -> CGImage {
        let ctx = makeContext(px)
        let r = CGRect(x: 0, y: 0, width: px, height: px)
        drawSurface(value, in: r, path: CGPath(rect: r, transform: nil), ctx: ctx, palette: palette)
        if pips && wild && value == 1 {
            drawWildRing(in: r, ctx: ctx, palette: palette)
        } else if pips {
            if style == .constellation { drawConstellationLines(value, in: r, ctx: ctx, palette: palette) }
            drawPips(value, in: r, ctx: ctx, palette: palette)
        }
        return ctx.makeImage()!
    }

    /// The emission map for one face: what the face gives off by itself, on black. nil for
    /// looks without one. `wash` fills the background instead of black (the scoring glow).
    static func emissionTexture(value: Int, px: Int = 512, palette: DiePalette, pips: Bool = true,
                                style: PipStyle = .plain, wash: CGColor? = nil) -> CGImage? {
        guard palette.emissive else { return nil }
        let ctx = makeContext(px)
        let r = CGRect(x: 0, y: 0, width: px, height: px)
        ctx.setFillColor(wash ?? grey(0))
        ctx.fill(r)
        drawEmission(value, in: r, path: CGPath(rect: r, transform: nil), ctx: ctx, palette: palette, pips: pips, style: style)
        return ctx.makeImage()!
    }

    /// The face body under the pips. `path` is the face outline (square for a texture,
    /// rounded for the tile), used for edge wear.
    static func drawSurface(_ value: Int, in r: CGRect, path: CGPath, ctx: CGContext, palette p: DiePalette) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(p.body)
        ctx.fill(r)
        let w = r.width
        switch p.surface {
        case .plain, .void:
            break
        case .aged:
            var rng = Seeded(0xB0E5 &+ UInt64(value) &* 7919)
            // Broad uneven colour: tan stains and paler patches.
            for _ in 0..<30 {
                let c = CGPoint(x: r.minX + rng.unit() * w, y: r.minY + rng.unit() * w)
                let rad = w * rng.range(0.10, 0.36)
                let col = rng.unit() < 0.62 ? p.shade : p.highlight
                let a = rng.range(0.10, 0.26)
                radial(ctx, at: c, radius: rad, colors: [alpha(col, a), alpha(col, a * 0.5), alpha(col, 0)], locations: [0, 0.5, 1])
            }
            // Fine speckle and a few pits.
            for i in 0..<340 {
                let c = CGPoint(x: r.minX + rng.unit() * w, y: r.minY + rng.unit() * w)
                let big = i < 14
                let rad = w * (big ? rng.range(0.004, 0.009) : rng.range(0.0012, 0.005))
                ctx.setFillColor(alpha(p.pipOuter, big ? rng.range(0.18, 0.32) : rng.range(0.05, 0.20)))
                ctx.fillEllipse(in: circle(c, rad))
            }
            // Hairline scratches.
            ctx.setLineCap(.round)
            for _ in 0..<5 {
                let a = CGPoint(x: r.minX + rng.unit() * w, y: r.minY + rng.unit() * w)
                let ang = rng.range(0, 2 * .pi), len = w * rng.range(0.08, 0.26)
                let b = CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
                let m = CGPoint(x: (a.x + b.x) / 2 + rng.range(-0.03, 0.03) * w, y: (a.y + b.y) / 2 + rng.range(-0.03, 0.03) * w)
                ctx.move(to: a)
                ctx.addQuadCurve(to: b, control: m)
                ctx.setStrokeColor(alpha(p.pipOuter, rng.range(0.10, 0.20)))
                ctx.setLineWidth(w * rng.range(0.002, 0.0035))
                ctx.strokePath()
            }
            // Worn, darker edges: soft inner falloff along the outline, then uneven grime patches on it.
            let wear = CGColor(colorSpace: sRGB, components: [0.40, 0.28, 0.15, 1])!
            for i in 0..<12 {
                ctx.addPath(path)
                ctx.setStrokeColor(alpha(wear, 0.032))
                ctx.setLineWidth(w * (0.01 + 0.30 * (1 - CGFloat(i) / 12)))
                ctx.strokePath()
            }
            for _ in 0..<16 {
                let t = rng.unit(), side = Int(rng.unit() * 4)
                let e: CGPoint
                switch side {
                case 0: e = CGPoint(x: r.minX + t * w, y: r.minY)
                case 1: e = CGPoint(x: r.minX + t * w, y: r.maxY)
                case 2: e = CGPoint(x: r.minX, y: r.minY + t * w)
                default: e = CGPoint(x: r.maxX, y: r.minY + t * w)
                }
                let a = rng.range(0.10, 0.22)
                radial(ctx, at: e, radius: w * rng.range(0.05, 0.13), colors: [alpha(wear, a), alpha(wear, 0)], locations: [0, 1])
            }
        case .translucent:
            // Depth: a lighter core fading to a darker edge, as if looking into dark glass.
            let c = CGPoint(x: r.midX - w * 0.06, y: r.midY + w * 0.06)
            radial(ctx, at: c, radius: w * 0.78, colors: [p.highlight, p.body, p.shade], locations: [0, 0.5, 1])
        }
        ctx.restoreGState()
    }

    /// Everything the face gives off: the rim or edge light, the pips' light, the constellation lines.
    static func drawEmission(_ value: Int, in r: CGRect, path: CGPath, ctx: CGContext, palette p: DiePalette,
                             pips: Bool, style: PipStyle) {
        let w = r.width
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Light along the edges: a faint cold rim (void) or light piped through the resin (glowing).
        if let edgeLight = p.rim ?? (p.surface == .translucent ? p.glow : nil) {
            let rim = p.rim != nil
            for i in 0..<8 {
                ctx.addPath(path)
                ctx.setStrokeColor(alpha(edgeLight, rim ? 0.075 : 0.022))
                ctx.setLineWidth(w * (0.008 + (rim ? 0.075 : 0.11) * (1 - CGFloat(i) / 8)))
                ctx.strokePath()
            }
            if rim {
                ctx.addPath(path)
                ctx.setStrokeColor(alpha(edgeLight, 0.55))
                ctx.setLineWidth(w * 0.012)
                ctx.strokePath()
            }
        }
        if pips, p.glow != nil {
            if style == .constellation { drawConstellationLines(value, in: r, ctx: ctx, palette: p, emission: true) }
            drawLitPips(value, in: r, ctx: ctx, palette: p, emission: true)
        }
        ctx.restoreGState()
    }

    /// Links between standard pip positions (unit square, y up), as star charts draw them:
    /// short open chains, never a closed shape, never a branch or lines radiating from a centre,
    /// and no letter-like full grid paths. Each link is a pair of points.
    static func constellationLinks(_ value: Int) -> [(CGPoint, CGPoint)] {
        let l: CGFloat = 0.25, c: CGFloat = 0.5, h: CGFloat = 0.75
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        switch value {
        case 2: return [(p(l, h), p(h, l))]
        case 3: return [(p(l, h), p(c, c)), (p(c, c), p(h, l))]
        case 4: return [(p(l, h), p(h, h)), (p(h, h), p(h, l))]
        case 5: return [(p(l, l), p(l, h)), (p(l, h), p(c, c)), (p(c, c), p(h, h))]
        case 6: return [(p(l, h), p(l, c)), (p(l, c), p(h, c)), (p(h, c), p(h, l))]
        default: return []
        }
    }

    /// Hairline weight shared by constellation links, the 1's orbit ring and the wild ring.
    static func hairline(_ r: CGRect) -> CGFloat { max(1, r.width * 0.011) }

    /// The wild face: a single open ring, same weight as the hairlines, nothing else.
    static func drawWildRing(in r: CGRect, ctx: CGContext, palette: DiePalette) {
        let ring = r.width * 0.25
        ctx.saveGState()
        ctx.setStrokeColor(palette.pipOuter.copy(alpha: 0.9) ?? palette.pipOuter)
        ctx.setLineWidth(hairline(r))
        ctx.strokeEllipse(in: CGRect(x: r.midX - ring, y: r.midY - ring, width: ring * 2, height: ring * 2))
        ctx.restoreGState()
    }

    /// Hairlines between the dots (drawn under them), and a thin orbit ring around the lone 1.
    /// Drawn in the style's pip colour. Ring-and-dot pips: the lines stop at the scribed circles
    /// (a line through the ring reads as a crossed-out pip). Lit pips: the lines are lit too,
    /// a little dimmer than the pips (`emission: true` draws their light).
    static func drawConstellationLines(_ value: Int, in r: CGRect, ctx: CGContext, palette: DiePalette,
                                       emission: Bool = false) {
        let line: CGColor
        var width = hairline(r)
        var gap: CGFloat = 0
        switch palette.pips {
        case .domed:
            line = alpha(palette.pipOuter, 0.55)
        case .ringDot:
            line = alpha(palette.pipInner, 0.80)
            width *= 1.25
            gap = r.width * pipRadius(value, .ringDot) * 1.05
        case .glow:
            line = alpha(emission ? (palette.glow ?? palette.pipOuter) : palette.pipOuter, emission ? 0.55 : 0.70)
        case .point:
            line = alpha(emission ? (palette.glow ?? palette.pipOuter) : palette.pipOuter, emission ? 0.42 : 0.30)
        }
        ctx.saveGState()
        ctx.setStrokeColor(line)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func at(_ q: CGPoint) -> CGPoint { CGPoint(x: r.minX + q.x * r.width, y: r.minY + q.y * r.height) }
        // Lines run dot to dot (drawn under the dots), as most star charts draw them.
        for (a0, b0) in constellationLinks(value) {
            let a = at(a0), b = at(b0)
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > gap * 2 + 1 else { continue }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            ctx.move(to: CGPoint(x: a.x + ux * gap, y: a.y + uy * gap))
            ctx.addLine(to: CGPoint(x: b.x - ux * gap, y: b.y - uy * gap))
            ctx.strokePath()
        }
        if value == 1 {
            let ring = r.width * 0.215
            let c = at(CGPoint(x: 0.5, y: 0.5))
            ctx.setLineWidth(hairline(r))
            ctx.strokeEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2))
        }
        ctx.restoreGState()
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
        if palette.surface != .plain { return styledTileFace(value: value, px: px, palette: palette) }
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

    /// Tile face for the styled looks: the same surface, pips and light as the 3D faces, on the
    /// rounded tile body. Ancient: aged bone, softer corners, normal shadow. Glowing: dark body,
    /// lit pips, an aqua glow around the tile in place of the shadow. Void: black with a cold
    /// rim and white points, barely any shadow.
    static func styledTileFace(value: Int, px: Int, palette p: DiePalette) -> CGImage {
        let ctx = makeContext(px)
        let s = CGFloat(px)
        let body = bodyRect(px)
        let path = CGPath(roundedRect: body, cornerWidth: body.width * p.tileCorner, cornerHeight: body.width * p.tileCorner,
                          transform: nil)
        ctx.saveGState()
        switch p.surface {
        case .translucent:
            ctx.setShadow(offset: .zero, blur: s * 0.075, color: alpha(p.floor.halo ?? p.glow ?? p.pipOuter, 0.85))
        case .void:
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: grey(0, 0.42 * p.floor.shadow))
        default:
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.045, color: grey(0, 0.42 * p.floor.shadow))
        }
        ctx.addPath(path)
        ctx.setFillColor(p.body)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawSurface(value, in: body, path: path, ctx: ctx, palette: p)
        if p.surface != .void {
            // Gentle top-to-bottom shading, as on the classic tile.
            let g = CGGradient(colorsSpace: sRGB, colors: [alpha(p.highlight, 0.45), alpha(p.body, 0), alpha(p.shade, 0.45)] as CFArray,
                               locations: [0, 0.45, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        }
        drawPips(value, in: body, ctx: ctx, palette: p, weight: 1.7)
        if p.emissive {
            ctx.setBlendMode(.screen)
            drawEmission(value, in: body, path: path, ctx: ctx, palette: p, pips: true, style: .plain)
        }
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(p.edge)
        ctx.setLineWidth(max(1, s * (p.surface == .void ? 0.008 : 0.006)))
        ctx.strokePath()
        return ctx.makeImage()!
    }

    /// What lies on the table under the die: the classic blob shadow, or (for a die that gives
    /// off light) a coloured halo with a small contact shadow in the middle.
    static func floorImage(_ p: DiePalette, px: Int = 256) -> CGImage {
        guard let halo = p.floor.halo else { return blobShadow(px: px) }
        let ctx = makeContext(px)
        let s = CGFloat(px)
        let c = CGPoint(x: s / 2, y: s / 2)
        radial(ctx, at: c, radius: s / 2,
               colors: [alpha(halo, 0.85), alpha(halo, 0.62), alpha(halo, 0.24), alpha(halo, 0)],
               locations: [0, 0.32, 0.62, 1])
        let k = p.floor.shadow
        radial(ctx, at: c, radius: s * 0.17,
               colors: [grey(0, 0.5 * k), grey(0, 0.3 * k), grey(0, 0)], locations: [0, 0.6, 1])
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
