// Renders the two myLinux app icons as 1024 px PNGs with Core Graphics.
//   myLinux           the desktop itself (the QEMU wrapper): dusk gradient, a window with a glowing prompt
//   myLinux Launcher  the Mac app that starts machines: cooler gradient, stacked machine cards, a play button
// Usage: swift tools/icons/icons.swift <output dir>      (tools/icons/make-icons.sh turns them into .icns)
import AppKit
import CoreGraphics
import SwiftUI

let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

/// Apple's icon grid: an 824 pt body centred on the 1024 canvas with continuous corners (the same curve macOS uses,
/// taken from SwiftUI's continuous rounded rectangle; radius 22.5 % of the side).
func squircle(_ r: CGRect) -> CGPath {
    Path(roundedRect: r, cornerRadius: r.width * 0.225, style: .continuous).cgPath
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

func linear(_ ctx: CGContext, _ colors: [CGColor], _ stops: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func render(_ name: String, to dir: String, draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)          // y down, like the numbers below
    ctx.setShouldAntialias(true); ctx.interpolationQuality = .high
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}

/// The shared body: shadow, gradient, a soft light from the top left, a thin bright rim.
func body(_ ctx: CGContext, gradient: [UInt32], glow: UInt32) {
    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(gradient[1])); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    linear(ctx, gradient.map { rgb($0) }, [0, 0.55, 1], from: CGPoint(x: 140, y: 110), to: CGPoint(x: 900, y: 930))
    radial(ctx, [rgb(glow, 0.45), rgb(glow, 0)], center: CGPoint(x: 250, y: 190), radius: 620)
    radial(ctx, [rgb(0x000000, 0), rgb(0x000000, 0.22)], center: CGPoint(x: 512, y: 430), radius: 760)
    // glossy top half
    linear(ctx, [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)], [0, 1], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 520))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle(CGRect(x: 102, y: 102, width: 820, height: 820)))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
}

/// A window card: light chrome with traffic lights, a dark pane holding the glowing prompt.
func window(_ ctx: CGContext, frame f: CGRect, radius: CGFloat, promptScale k: CGFloat, shadow: CGFloat = 0.38) {
    let title = f.height * 0.15
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * k), blur: 46 * k, color: rgb(0x0B0B2A, shadow))
    ctx.addPath(rounded(f, radius)); ctx.setFillColor(rgb(0xF4F5FA)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(rounded(f, radius)); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF), rgb(0xE3E5EE)], [0, 1], from: CGPoint(x: f.midX, y: f.minY), to: CGPoint(x: f.midX, y: f.maxY))
    ctx.setFillColor(rgb(0xD6D9E4)); ctx.fill(CGRect(x: f.minX, y: f.minY + title - 2, width: f.width, height: 2))
    ctx.restoreGState()

    let lightR = title * 0.19, lightY = f.minY + title / 2
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        let x = f.minX + title * 0.62 + CGFloat(i) * lightR * 3.1
        ctx.setFillColor(rgb(UInt32(c))); ctx.fillEllipse(in: CGRect(x: x - lightR, y: lightY - lightR, width: lightR * 2, height: lightR * 2))
    }

    // terminal pane
    let inset = f.width * 0.05
    let pane = CGRect(x: f.minX + inset, y: f.minY + title + inset * 0.8, width: f.width - 2 * inset, height: f.height - title - inset * 1.8)
    ctx.saveGState()
    ctx.addPath(rounded(pane, radius * 0.5)); ctx.clip()
    linear(ctx, [rgb(0x1A1D33), rgb(0x0E1020)], [0, 1], from: CGPoint(x: pane.midX, y: pane.minY), to: CGPoint(x: pane.midX, y: pane.maxY))
    radial(ctx, [rgb(0x6D5BFF, 0.28), rgb(0x6D5BFF, 0)], center: CGPoint(x: pane.minX + pane.width * 0.3, y: pane.midY), radius: pane.width * 0.6)
    ctx.restoreGState()

    // ">" in cyan and "_" in pink, both glowing
    let h = pane.height * 0.34 * k
    let cx = pane.midX - h * 0.9, cy = pane.midY          // ">_" centred as a group in the pane
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: cx, y: cy - h / 2))
    chevron.addLine(to: CGPoint(x: cx + h * 0.55, y: cy))
    chevron.addLine(to: CGPoint(x: cx, y: cy + h / 2))
    let lw = h * 0.24
    ctx.saveGState()
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(lw)
    ctx.setShadow(offset: .zero, blur: lw * 1.6, color: rgb(0x4FE3F7, 0.9))
    ctx.addPath(chevron); ctx.setStrokeColor(rgb(0x7CF0FF)); ctx.strokePath()
    ctx.restoreGState()

    let bar = CGRect(x: cx + h * 0.95, y: cy + h / 2 - lw, width: h * 0.85, height: lw)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: lw * 1.6, color: rgb(0xFF5FA8, 0.95))
    ctx.addPath(rounded(bar, lw / 2)); ctx.setFillColor(rgb(0xFF86BF)); ctx.fillPath()
    ctx.restoreGState()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// ---- myLinux: the desktop ----------------------------------------------------------------------------------------
render("myLinux", to: out) { ctx in
    body(ctx, gradient: [0x23306F, 0x5B3FB0, 0xE66A9B], glow: 0x8FB4FF)
    window(ctx, frame: CGRect(x: 208, y: 258, width: 608, height: 500), radius: 46, promptScale: 1)
    // a small dock under the window: this is a whole desktop, not just a terminal
    let dock = CGRect(x: 352, y: 796, width: 320, height: 64)
    ctx.saveGState()
    ctx.addPath(rounded(dock, 32)); ctx.setFillColor(rgb(0xFFFFFF, 0.26)); ctx.fillPath()
    ctx.addPath(rounded(dock, 32)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.35)); ctx.setLineWidth(2); ctx.strokePath()
    ctx.restoreGState()
    for (i, c) in [0x7CF0FF, 0xFFFFFF, 0xFF86BF, 0xFFD36E].enumerated() {
        let x = dock.minX + 56 + CGFloat(i) * 69
        ctx.setFillColor(rgb(UInt32(c), 0.95))
        ctx.addPath(rounded(CGRect(x: x - 20, y: dock.midY - 20, width: 40, height: 40), 12)); ctx.fillPath()
    }
}

// ---- myLinux Launcher: machines and a start button ----------------------------------------------------------------
render("myLinux Launcher", to: out) { ctx in
    body(ctx, gradient: [0x0E8F95, 0x2563EB, 0x4A36C9], glow: 0x9CF5E6)
    // a machine behind (translucent) and one in front
    ctx.saveGState()
    ctx.addPath(rounded(CGRect(x: 300, y: 212, width: 500, height: 380), 40))
    ctx.setFillColor(rgb(0xFFFFFF, 0.30)); ctx.fillPath()
    ctx.addPath(rounded(CGRect(x: 300, y: 212, width: 500, height: 380), 40))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.45)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
    window(ctx, frame: CGRect(x: 208, y: 300, width: 520, height: 420), radius: 40, promptScale: 1)

    // play button, overlapping the front machine's corner
    let c = CGPoint(x: 716, y: 718), r: CGFloat = 138
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: rgb(0x0B0B2A, 0.45))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF), rgb(0xE6E9F5)], [0, 1], from: CGPoint(x: c.x, y: c.y - r), to: CGPoint(x: c.x, y: c.y + r))
    ctx.restoreGState()
    // the triangle, optically centred (nudged right), in the desktop icon's pink-violet
    let tri = CGMutablePath()
    let t = r * 0.46
    tri.move(to: CGPoint(x: c.x - t * 0.72, y: c.y - t))
    tri.addLine(to: CGPoint(x: c.x + t * 1.02, y: c.y))
    tri.addLine(to: CGPoint(x: c.x - t * 0.72, y: c.y + t))
    tri.closeSubpath()
    // soft corners: the gradient once through the filled triangle, once through its round-joined outline
    let grad = { linear(ctx, [rgb(0xFF6FA8), rgb(0x6D4BD8)], [0, 1], from: CGPoint(x: c.x - t, y: c.y - t), to: CGPoint(x: c.x + t, y: c.y + t)) }
    ctx.saveGState(); ctx.addPath(tri); ctx.clip(); grad(); ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tri); ctx.setLineWidth(26); ctx.setLineJoin(.round); ctx.replacePathWithStrokedPath(); ctx.clip()
    grad()
    ctx.restoreGState()
}
