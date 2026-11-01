// Usage: swift scripts/make-icon.swift OUTPUT.png [MORE_OUTPUTS.png ...]
// Draws the app icon: a crow of the Night's Watch against a pale moon, with an ember
// eye. It has no Bitcoin symbol on purpose, so the home screen doesn't advertise that
// the owner holds coins.
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

let g = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Night sky.
g.setFillColor(color(0x030507))
g.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Moon, lit from the upper left, with a cold halo.
let moon = pt(545, 565)
g.drawRadialGradient(
    gradient([(0, color(0x8FD0EC, 0.35)), (1, color(0x8FD0EC, 0))]),
    startCenter: moon, startRadius: 330, endCenter: moon, endRadius: 560, options: [])
g.drawRadialGradient(
    gradient([(0, color(0xEAF8FD)), (0.75, color(0xBFE4F3)), (1, color(0x86BFD8))]),
    startCenter: pt(505, 615), startRadius: 0, endCenter: moon, endRadius: 370, options: [])

// Crow, facing left.
let crow = CGMutablePath()
crow.move(to: pt(175, 586))                                                          // beak tip
crow.addCurve(to: pt(390, 700), control1: pt(240, 650), control2: pt(320, 695))      // top of beak
crow.addCurve(to: pt(640, 680), control1: pt(455, 770), control2: pt(580, 765))      // crown
crow.addCurve(to: pt(745, 400), control1: pt(705, 610), control2: pt(745, 510))      // nape
crow.addCurve(to: pt(900, 0), control1: pt(745, 280), control2: pt(840, 130))        // back
crow.addLine(to: pt(330, 0))
crow.addCurve(to: pt(362, 285), control1: pt(322, 110), control2: pt(345, 200))      // chest
// Shaggy throat feathers, each a curved point.
crow.addQuadCurve(to: pt(392, 330), control: pt(385, 300))
crow.addQuadCurve(to: pt(372, 385), control: pt(368, 350))
crow.addQuadCurve(to: pt(412, 415), control: pt(398, 395))
crow.addQuadCurve(to: pt(394, 468), control: pt(390, 435))
crow.addQuadCurve(to: pt(430, 498), control: pt(420, 476))
crow.addCurve(to: pt(382, 560), control1: pt(418, 525), control2: pt(400, 545))      // jaw
crow.addCurve(to: pt(175, 586), control1: pt(310, 550), control2: pt(235, 555))      // bottom of beak
crow.closeSubpath()
g.setFillColor(color(0x040608))
g.addPath(crow)
g.fillPath()

// Ember eye.
let eye = pt(472, 640)
g.drawRadialGradient(
    gradient([(0, color(0xFF8A2A, 0.6)), (1, color(0xFF5A10, 0))]),
    startCenter: eye, startRadius: 15, endCenter: eye, endRadius: 80, options: [])
g.drawRadialGradient(
    gradient([(0, color(0xFFF0B8)), (0.5, color(0xFFB23C)), (1, color(0xE85F0C))]),
    startCenter: eye, startRadius: 0, endCenter: eye, endRadius: 30, options: [])

let image = g.makeImage()!
for path in CommandLine.arguments.dropFirst() {
    let output = URL(fileURLWithPath: path)
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(path)") }
}
