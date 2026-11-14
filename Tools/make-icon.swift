// Draws Jet's app icon: a pear-shaped checkerboard-cut jet cabochon (polished black lignite) on deep slate.
//
//   swift Tools/make-icon.swift            # writes into Resources/Assets.xcassets
//   swift Tools/make-icon.swift <outdir>   # writes previews into <outdir> instead
//
// iOS gets one full-bleed 1024 square (the system applies the mask).
// macOS gets the standard rounded-square body with margin and shadow, rendered at every size.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.displayP3)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func poly(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts)
    p.closeSubpath()
    return p
}

// MARK: Geometry, in a 1024 design space with y pointing down.
//
// The stone is a pear (teardrop) checkerboard-cut jet cabochon, point up: a lattice of diamond facets
// laid over a dome, then pinched into a teardrop. Each facet is flat and shaded from its own normal.

struct Vec { var x, y, z: Double }
func + (a: Vec, b: Vec) -> Vec { Vec(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
func - (a: Vec, b: Vec) -> Vec { Vec(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
func * (a: Vec, k: Double) -> Vec { Vec(x: a.x * k, y: a.y * k, z: a.z * k) }
func dot(_ a: Vec, _ b: Vec) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
func cross(_ a: Vec, _ b: Vec) -> Vec { Vec(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
func norm(_ a: Vec) -> Vec { a * (1 / sqrt(dot(a, a))) }

let center = CGPoint(x: 512, y: 508)
let halfHeight = 352.0           // tip to bottom is 2 × this
let halfWidth = 268.0            // at the widest point, a little below center
let pinchPower = 0.38            // 0.5 is a water drop; lower is a fuller pear with a softer point
/// Width of the pinched unit circle at its widest (y = p / (1 + p)), used to normalise it to 1.
let pinchPeak: Double = {
    let y = pinchPower / (1 + pinchPower)
    return sqrt(1 - y * y) * pow((1 + y) / 2, pinchPower)
}()
let domeHeight = 250.0
let lattice = 0.205              // half-diagonal of a facet in dome space (≈ 5 facets across)
let maxTilt = 0.46 * Double.pi   // the rim facets are steep, like the side of a cabochon

/// Unit disk point → point on the dome, pinched into a teardrop and scaled to design units (z up toward viewer).
func lift(_ px: Double, _ py: Double) -> Vec {
    var r = sqrt(px * px + py * py)
    let (dx, dy) = r > 1e-9 ? (px / r, py / r) : (0, 0)
    r = min(r, 1)
    let theta = r * maxTilt
    let x = sin(theta) * dx, y = sin(theta) * dy, z = cos(theta)
    // Teardrop: the width shrinks toward the top as ((1 + y) / 2)^p, which closes to a point at y = -1.
    let pinch = pow(max(0, (1 + y) / 2), pinchPower) / pinchPeak
    return Vec(x: x * pinch * halfWidth, y: y * halfHeight, z: z * domeHeight)
}

func screen(_ v: Vec) -> CGPoint { CGPoint(x: center.x + CGFloat(v.x), y: center.y + CGFloat(v.y)) }

struct Facet { let pts: [CGPoint]; let normal: Vec }

let facets: [Facet] = {
    var out: [Facet] = []
    let n = 9
    for i in -n...n {
        for j in -n...n {
            // Diamond cell on a 45°-rotated lattice, shifted so one facet sits on the centre line.
            let corners = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)].map { (a, b) in
                lift(Double(a - b) * lattice, Double(a + b - 1) * lattice + 0.05)
            }
            let pts = corners.map(screen)
            let area = abs(zip(pts, pts.dropFirst() + [pts[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
            if area < 30 { continue }  // fully outside: collapsed onto the rim
            var normal = norm(cross(corners[2] - corners[0], corners[3] - corners[1]))
            if normal.z < 0 { normal = normal * -1 }
            out.append(Facet(pts: pts, normal: normal))
        }
    }
    return out
}()

let outline: CGPath = {
    let p = CGMutablePath()
    let steps = 360
    for k in 0..<steps {
        let a = Double(k) / Double(steps) * 2 * .pi
        let pt = screen(lift(cos(a), sin(a)))
        k == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}()

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

let lightDir = norm(Vec(x: -0.55, y: -0.65, z: 0.52))   // upper left, like the first design

func reflect(_ n: Vec) -> Vec { n * (2 * n.z) - Vec(x: 0, y: 0, z: 1) }

func facet(near p: CGPoint) -> Facet {
    facets.min { a, b in
        func d(_ f: Facet) -> CGFloat {
            let c = f.pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
            return hypot(c.x - p.x, c.y - p.y)
        }
        return d(a) < d(b)
    }!
}

/// Window reflections, art-directed like the photo: each is aimed at the facet nearest a chosen spot,
/// so that facet mirrors it fully and its neighbours catch only a little.
let windows: [(dir: Vec, strength: Double)] = [
    (reflect(facet(near: CGPoint(x: 410, y: 440)).normal), 0.92),
    (reflect(facet(near: CGPoint(x: 540, y: 270)).normal), 0.80),
    (reflect(facet(near: CGPoint(x: 640, y: 560)).normal), 0.55),
]

/// Two tones per facet, top-left to bottom-right, in 0…1 brightness.
func shade(_ n: Vec) -> (Double, Double) {
    let r = reflect(n)
    // Satin body tone: facets turned toward the light read as slate grey, the rest fall to black.
    let body = 0.34 * pow(max(0, dot(n, lightDir)), 3.2)
    let glint = windows.reduce(0) { $0 + $1.strength * smoothstep(0.975, 0.999, dot(r, $1.dir)) }
    // A cool rim bounce on the lower-right edge, like the first design's far facets.
    let rim = 0.16 * pow(max(0, dot(n, norm(Vec(x: 0.7, y: 0.5, z: 0.2)))), 2)
    let top = min(1, body + glint + rim + 0.03)
    return (top, top * (glint > 0.3 ? 0.62 : 0.42) + 0.01)
}

func tone(_ b: Double, _ a: CGFloat = 1) -> CGColor {
    // Black with the first design's cool slate tint (0x5A5F6B at the bright end of the body tone).
    let k = CGFloat(b)
    return CGColor(colorSpace: space, components: [0.025 + 0.90 * k, 0.027 + 0.93 * k, 0.034 + 0.99 * k, a])!
}

// MARK: Drawing

/// Draws the full-bleed artwork into the 1024 design square.
func drawArtwork(_ ctx: CGContext) {
    // Background: deep slate with a faint cool glow behind the stone (as in the first design).
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x3A3D46)), (1, rgb(0x121317))]),
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x8A93A8, 0.30)), (1, rgb(0x8A93A8, 0))]),
        startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 470), endRadius: 540, options: [])

    // Soft contact shadow under the stone, and its own drop shadow.
    ctx.saveGState()
    ctx.translateBy(x: 520, y: 890)
    ctx.scaleBy(x: 1, y: 0.15)
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x000000, 0.55)), (1, rgb(0x000000, 0))]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 300, options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: rgb(0x000000, 0.65))
    ctx.addPath(outline)
    ctx.setFillColor(rgb(0x050506))
    ctx.fillPath()
    ctx.restoreGState()

    // Facets.
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    for f in facets {
        let (a, b) = shade(f.normal)
        let path = poly(f.pts)
        let box = path.boundingBox
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, tone(a)), (1, tone(b))]),
            start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // Waxy luster: a broad soft sheen across the upper left of the stone.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xCFD6E6, 0.22)), (1, rgb(0xCFD6E6, 0))]),
        startCenter: CGPoint(x: 400, y: 380), startRadius: 0,
        endCenter: CGPoint(x: 400, y: 380), endRadius: 320, options: [])

    // Facet edges: faint light lines, as in the first design.
    ctx.setLineJoin(.round)
    for f in facets { ctx.addPath(poly(f.pts)) }
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.11))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
    ctx.restoreGState()

    // Polished rim: bright where it faces the light (upper left), fading to a faint line elsewhere.
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xE6EBF5, 0.65)), (0.45, rgb(0xE6EBF5, 0.12)), (1, rgb(0xE6EBF5, 0.20))]),
        start: CGPoint(x: 260, y: 160), end: CGPoint(x: 780, y: 880), options: [])
    ctx.restoreGState()

    // Glint: a four-point sparkle on the upper-left shoulder.
    let lit = facet(near: CGPoint(x: 410, y: 440)).pts
    drawSparkle(ctx, at: lit.min { $0.y < $1.y }!, radius: 58)
}

func drawSparkle(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat) {
    ctx.saveGState()
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFFFFF, 0.65)), (1, rgb(0xFFFFFF, 0))]),
        startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 0.6, options: [])
    let w = r * 0.13
    let star = CGMutablePath()
    star.move(to: CGPoint(x: c.x, y: c.y - r))
    star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    ctx.addPath(star)
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    ctx.fillPath()
    ctx.restoreGState()
}

/// Renders the icon at `px` pixels. `mac` draws the macOS rounded-square body with margin and shadow.
func render(px: Int, mac: Bool) -> CGImage {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(px) / 1024
    // Flip to y-down design space.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)

    if mac {
        // Apple's macOS grid: 824 body centered in 1024, corner radius ~185, soft shadow below.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x121317))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
        drawArtwork(ctx)
        ctx.restoreGState()
        // Hairline inner edge so the dark tile separates from a dark Dock.
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
        ctx.setLineWidth(3)
        ctx.strokePath()
    } else {
        drawArtwork(ctx)
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL, opaque: Bool) {
    var img = image
    if opaque, let flat = image.copy(colorSpace: space) {
        // App Store rejects an iOS icon with an alpha channel: redraw without one.
        let ctx = CGContext(
            data: nil, width: flat.width, height: flat.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: flat.width, height: flat.height))
        img = ctx.makeImage()!
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
    print("wrote \(url.path)")
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments.dropFirst()
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let iosDir = args.first.map { URL(fileURLWithPath: $0) } ?? assets.appendingPathComponent("AppIcon.appiconset")
let macDir = args.first.map { URL(fileURLWithPath: $0) } ?? assets.appendingPathComponent("AppIcon-Mac.appiconset")
try FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)

write(render(px: 1024, mac: false), to: iosDir.appendingPathComponent("AppIcon.png"), opaque: true)
for pt in [16, 32, 128, 256, 512] {
    write(render(px: pt, mac: true), to: macDir.appendingPathComponent("icon_\(pt).png"), opaque: false)
    write(render(px: pt * 2, mac: true), to: macDir.appendingPathComponent("icon_\(pt)@2x.png"), opaque: false)
}
