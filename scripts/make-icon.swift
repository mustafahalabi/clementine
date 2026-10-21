#!/usr/bin/env swift
// Draws Clementine's app icon (a clementine in cross-section whose segments double as the
// format wheel) at every iconset size, then packs them into Resources/AppIcon.icns.
//
// Usage: swift scripts/make-icon.swift <out-dir> [icns-path]
//   <out-dir>    where AppIcon.iconset (the PNGs) is written
//   [icns-path]  defaults to Resources/AppIcon.icns next to this script's repo
//
// Everything is drawn with CoreGraphics paths and gradients; no external assets.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (mirrors Sources/Clementine/Support/Theme.swift)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

let tangerine: UInt32 = 0xFF9A3C
let blood: UInt32 = 0xFF5E3A
let peach: UInt32 = 0xFFD3A8
let leaf: UInt32 = 0x34C77B

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    // (hex, alpha, location)
    CGGradient(colorsSpace: space,
               colors: stops.map { rgb($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

// MARK: - Geometry helpers

/// Apple-style continuous-corner rounded square (the iOS 7+/Big Sur "squircle"): straight edges
/// that ease into the corner instead of meeting a circular arc abruptly.
func squirclePath(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    // One corner in a local frame: the corner sits at the origin, edges run along +x and +y.
    // Control points are the well-known continuous-corner coefficients (extent 1.52866r).
    let corner: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 1.08849299, y: 0), CGPoint(x: 0.86840701, y: 0.02121400), CGPoint(x: 0.63149399, y: 0.07491100)),
        (CGPoint(x: 0.37282401, y: 0.16841199), CGPoint(x: 0.16841199, y: 0.37282401), CGPoint(x: 0.07491100, y: 0.63149399)),
        (CGPoint(x: 0.02121400, y: 0.86840701), CGPoint(x: 0, y: 1.08849299), CGPoint(x: 0, y: 1.52866483)),
    ]
    let e: CGFloat = 1.52866483
    let p = CGMutablePath()
    // Corners in clockwise order (y-down): top-left, top-right, bottom-right, bottom-left.
    // Each maps local (u, v) -> world via an origin and the two edge directions.
    let frames: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
    ]
    for (i, f) in frames.enumerated() {
        func w(_ q: CGPoint) -> CGPoint {
            CGPoint(x: f.0.x + (f.1.dx * q.x + f.2.dx * q.y) * r, y: f.0.y + (f.1.dy * q.x + f.2.dy * q.y) * r)
        }
        let start = w(CGPoint(x: e, y: 0))
        if i == 0 { p.move(to: start) } else { p.addLine(to: start) }
        for seg in corner { p.addCurve(to: w(seg.2), control1: w(seg.0), control2: w(seg.1)) }
    }
    p.closeSubpath()
    return p
}

/// A pie wedge whose straight sides sit `inset` away from the true radial edges, so the gaps
/// between neighbours have constant width (like membranes) instead of tapering to the centre.
func wedgePath(center c: CGPoint, radius R: CGFloat, from a0: CGFloat, to a1: CGFloat, inset d: CGFloat) -> CGPath {
    let half = (a1 - a0) / 2
    let mid = a0 + half
    let apexDist = d / sin(half)
    let apex = CGPoint(x: c.x + cos(mid) * apexDist, y: c.y + sin(mid) * apexDist)
    let delta = asin(min(d / R, 0.99))
    let p = CGMutablePath()
    p.move(to: apex)
    p.addLine(to: CGPoint(x: c.x + cos(a0 + delta) * R, y: c.y + sin(a0 + delta) * R))
    p.addArc(center: c, radius: R, startAngle: a0 + delta, endAngle: a1 - delta, clockwise: false)
    p.closeSubpath()
    return p
}

// MARK: - Drawing

/// Draws the icon into a context whose coordinate space is 1024x1024, y pointing down.
/// `px` is the real pixel size so detail can be tuned for tiny renders.
func drawIcon(_ ctx: CGContext, px: Int) {
    let tiny = px <= 32
    let small = px <= 64

    // ---- Canvas & shape (824pt squircle centred on 1024, ~22.5% radius) ----
    let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(shapeRect, radius: 824 * 0.225)

    // Soft drop shadow, kept inside the canvas.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x5A2A10, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xFFF3E6))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: warm cream, top-lit.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFBF5, 1, 0), (0xFFEEDC, 1, 0.55), (0xFFDDBE, 1, 1)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Gentle warm glow behind the fruit.
    ctx.drawRadialGradient(gradient([(0xFFB66A, 0.30, 0), (0xFFB66A, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 470, options: [])
    ctx.restoreGState()

    // ---- The fruit ----
    let c = CGPoint(x: 506, y: 540)
    let R: CGFloat = tiny ? 344 : 326                       // outer peel
    let peel: CGFloat = tiny ? 34 : 26         // orange peel thickness
    let albedo: CGFloat = tiny ? 20 : 16       // white pith ring
    let segR = R - peel - albedo               // segments' outer radius
    let membrane: CGFloat = px <= 16 ? 40 : (tiny ? 36 : (small ? 26 : 16))  // gap between segments
    let segments = 8
    let rotation: CGFloat = -.pi / 2 - .pi / CGFloat(segments) // a segment centred on top

    // Fruit shadow on the background.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: tiny ? 10 : 18), blur: tiny ? 20 : 36, color: rgb(0xB8431A, 0.38))
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.setFillColor(rgb(blood))
    ctx.fillPath()
    ctx.restoreGState()

    // Peel: tangerine → blood orange, lit from the top.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFAA4A, 1, 0), (tangerine, 1, 0.35), (blood, 1, 1)]),
                           start: CGPoint(x: c.x - R * 0.6, y: c.y - R), end: CGPoint(x: c.x + R * 0.6, y: c.y + R), options: [])
    ctx.restoreGState()

    // Albedo (pith) disc — the membranes show through as this colour.
    let pithR = R - peel
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - pithR, y: c.y - pithR, width: 2 * pithR, height: 2 * pithR))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFF8EE, 1, 0), (peach, 1, 1)]),
                           start: CGPoint(x: c.x, y: c.y - pithR), end: CGPoint(x: c.x, y: c.y + pithR), options: [])
    ctx.restoreGState()

    // Segments: juicy radial gradient, each a rounded wedge.
    let step = 2 * CGFloat.pi / CGFloat(segments)
    let round: CGFloat = tiny ? 6 : 14          // corner rounding
    for i in 0..<segments {
        let a0 = rotation + CGFloat(i) * step
        let a1 = a0 + step
        let core = wedgePath(center: c, radius: segR - round, from: a0, to: a1, inset: membrane / 2 + round)
        let rounded = core.copy(strokingWithWidth: round * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(rgb(0x000000))
        ctx.addPath(core); ctx.fillPath()
        ctx.addPath(rounded); ctx.fillPath()
        ctx.setBlendMode(.sourceIn)
        let juice = tiny
            ? gradient([(0xFFA848, 1, 0), (0xFF8434, 1, 0.5), (0xF8602C, 1, 1)])   // punchier when tiny
            : gradient([(0xFFC46E, 1, 0), (0xFFA040, 1, 0.45), (0xFF7A30, 1, 0.85), (0xF2602E, 1, 1)])
        ctx.drawRadialGradient(juice,
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: segR, options: [.drawsAfterEndLocation])
        // Top-lit sheen across the whole fruit face.
        ctx.setBlendMode(.sourceAtop)
        ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.22, 0), (0xFFFFFF, 0, 0.55), (0x8A2A00, 0.10, 1)]),
                               start: CGPoint(x: c.x, y: c.y - segR), end: CGPoint(x: c.x, y: c.y + segR), options: [])

        if !small {
            // Juice vesicles: faint teardrops fanning out inside the segment.
            ctx.setBlendMode(.sourceAtop)
            let mid = (a0 + a1) / 2
            let fan: [(CGFloat, CGFloat, CGFloat)] = [(-0.30, 0.48, 0.80), (0, 0.36, 0.86), (0.30, 0.52, 0.78)]
            for (t, a, b) in fan {
                let ang = mid + t * step * 0.6
                let r0 = segR * a, r1 = segR * b
                let p = CGMutablePath()
                p.move(to: CGPoint(x: c.x + cos(ang) * r0, y: c.y + sin(ang) * r0))
                p.addLine(to: CGPoint(x: c.x + cos(ang) * r1, y: c.y + sin(ang) * r1))
                ctx.addPath(p)
                ctx.setStrokeColor(rgb(0xFFE6C0, 0.30))
                ctx.setLineWidth(10)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // Centre hub, where the dragged file sits in the wheel.
    let hubR: CGFloat = tiny ? 40 : 28
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: 2 * hubR, height: 2 * hubR))
    ctx.setFillColor(rgb(0xFFF6EA))
    ctx.fillPath()
    ctx.restoreGState()

    // Specular highlight on the peel, upper-left.
    if !tiny {
        ctx.saveGState()
        let hl = CGMutablePath()
        hl.addArc(center: c, radius: R - peel * 0.45, startAngle: .pi * 1.12, endAngle: .pi * 1.38, clockwise: false)
        ctx.addPath(hl)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
        ctx.setLineWidth(peel * 0.32)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    drawLeaf(ctx, fruitCenter: c, fruitRadius: R, tiny: tiny)

    // Inner hairline on the squircle so it reads against dark wallpapers / Dock.
    if !tiny {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.6))
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func drawLeaf(_ ctx: CGContext, fruitCenter c: CGPoint, fruitRadius R: CGFloat, tiny: Bool) {
    // Leaf springs from the rim at the upper right, pointing up and out.
    let baseAngle: CGFloat = -.pi * 0.30
    let base = CGPoint(x: c.x + cos(baseAngle) * (R - 30), y: c.y + sin(baseAngle) * (R - 30))
    let len: CGFloat = tiny ? 210 : 200
    let width: CGFloat = tiny ? 120 : 104
    let tilt: CGFloat = -.pi * 0.20   // leaf axis direction (from base toward tip), 0 = right

    ctx.saveGState()
    ctx.translateBy(x: base.x, y: base.y)
    ctx.rotate(by: tilt)

    // Leaf outline along +x: base at 0, tip at len. Slightly asymmetric for life.
    let leafPath = CGMutablePath()
    leafPath.move(to: .zero)
    leafPath.addCurve(to: CGPoint(x: len, y: -6),
                      control1: CGPoint(x: len * 0.22, y: -width * 0.95),
                      control2: CGPoint(x: len * 0.72, y: -width * 0.70))
    leafPath.addCurve(to: .zero,
                      control1: CGPoint(x: len * 0.70, y: width * 0.48),
                      control2: CGPoint(x: len * 0.25, y: width * 0.62))
    leafPath.closeSubpath()

    // Shadow cast onto the fruit / background.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: tiny ? 12 : 22, color: rgb(0x0E5A30, 0.35))
    ctx.addPath(leafPath)
    ctx.setFillColor(rgb(leaf))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(leafPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0x7BEDB0, 1, 0), (0x48D68A, 1, 0.45), (leaf, 1, 0.75), (0x1F9E5C, 1, 1)]),
                           start: CGPoint(x: len * 0.3, y: -width * 0.7), end: CGPoint(x: len * 0.55, y: width * 0.55), options: [])
    if !tiny {
        // Midrib.
        let rib = CGMutablePath()
        rib.move(to: CGPoint(x: len * 0.02, y: 0))
        rib.addQuadCurve(to: CGPoint(x: len * 0.86, y: -10), control: CGPoint(x: len * 0.45, y: -width * 0.16))
        ctx.addPath(rib)
        ctx.setStrokeColor(rgb(0xD9FFE9, 0.75))
        ctx.setLineWidth(7)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

// MARK: - Rendering & packing

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Flip to a y-down 1024 design space.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)
    drawIcon(ctx, px: px)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <out-dir> [icns-path]\n".data(using: .utf8)!)
    exit(64)
}
let outDir = URL(fileURLWithPath: args[1])
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icnsURL = args.count >= 3 ? URL(fileURLWithPath: args[2])
                              : repoRoot.appendingPathComponent("Resources/AppIcon.icns")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

var cache: [Int: CGImage] = [:]
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let image = cache[px] ?? render(px: px)
        cache[px] = image
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(image, to: iconset.appendingPathComponent(name))
    }
}
// 64px isn't part of the standard iconset names but is handy for previewing.
writePNG(render(px: 64), to: outDir.appendingPathComponent("preview_64.png"))

try fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed (\(task.terminationStatus))") }
print("Wrote \(iconset.path)")
print("Wrote \(icnsURL.path)")
