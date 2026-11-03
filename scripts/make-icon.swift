// Usage: swift scripts/make-icon.swift OUTPUT.png [MORE_OUTPUTS.png ...]
// Draws the app icon: a crescent moon and a few stars in a dark night sky. It has no Bitcoin
// symbol on purpose, so the home screen doesn't advertise that the owner holds coins.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

let g = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Night sky, a little lighter toward the horizon. (Core Graphics puts y = 0 at the bottom.)
g.drawLinearGradient(
    gradient([(0, color(0x0B1A2A)), (0.55, color(0x050B14)), (1, color(0x020408))]),
    start: pt(0, 0), end: pt(0, size), options: [])

// Stars: a few, small and uneven, each with a faint glow.
let stars: [(CGPoint, CGFloat)] = [
    (pt(250, 800), 9), (pt(170, 560), 6), (pt(330, 330), 7), (pt(820, 860), 6),
    (pt(880, 250), 8), (pt(600, 150), 5), (pt(140, 210), 5), (pt(455, 905), 5),
]
for (center, radius) in stars {
    g.drawRadialGradient(
        gradient([(0, color(0xCFEFFF, 0.45)), (1, color(0xCFEFFF, 0))]),
        startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * 4, options: [])
    g.setFillColor(color(0xF2FBFF))
    g.fillEllipse(in: circle(center, radius))
}

// Cool halo around the moon.
let moon = pt(560, 540)
let moonRadius: CGFloat = 300
g.drawRadialGradient(
    // Starts at the lit edge, not the center, so the dark side of the moon blends into the sky.
    gradient([(0, color(0x8FD0EC, 0.22)), (1, color(0x8FD0EC, 0))]),
    startCenter: pt(470, 450), startRadius: 0, endCenter: pt(470, 450), endRadius: moonRadius * 1.7, options: [])

// Crescent: the moon's disc, minus an offset disc. Lit from the lower left.
let bite = pt(690, 620)
g.saveGState()
g.addEllipse(in: circle(moon, moonRadius))
g.clip()
g.addRect(CGRect(x: 0, y: 0, width: size, height: size))
g.addEllipse(in: circle(bite, 265))
g.clip(using: .evenOdd)
g.drawRadialGradient(
    gradient([(0, color(0xF4FBFE)), (0.7, color(0xC9E8F5)), (1, color(0x8CC4DC))]),
    startCenter: pt(430, 430), startRadius: 0, endCenter: moon, endRadius: moonRadius, options: [])
g.restoreGState()

let image = g.makeImage()!
for path in CommandLine.arguments.dropFirst() {
    let output = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(path)") }
}
