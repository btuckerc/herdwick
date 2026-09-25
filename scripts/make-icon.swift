// Draws the 1024 px app icon: a Herdwick sheep (dark fleece, white face) whose
// face is a terminal prompt. Run on macOS: swift scripts/make-icon.swift OUT.png
import AppKit
import CoreGraphics

let size = 1024.0
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Fell-side background: sage to deep moss.
let background = CGGradient(colorsSpace: space, colors: [color(0x8FA88A), color(0x3E5A48)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Fleece: a cloud of overlapping circles in Herdwick grey.
let fleece: [(CGFloat, CGFloat, CGFloat)] = [
    (512, 560, 250), (330, 600, 150), (694, 600, 150), (380, 430, 150), (644, 430, 150),
    (420, 740, 130), (604, 740, 130), (512, 360, 150), (280, 480, 120), (744, 480, 120),
]
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.35))
ctx.setFillColor(color(0x4A4745))
for (x, y, r) in fleece { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(color(0x5C5856))
for (x, y, r) in fleece { ctx.fillEllipse(in: CGRect(x: x - r * 0.8, y: y - r * 0.8 + r * 0.12, width: 1.6 * r, height: 1.6 * r)) }

// White face, slightly long, with ears.
ctx.setFillColor(color(0xF4F0E6))
for dx in [-1.0, 1.0] {
    ctx.saveGState()
    ctx.translateBy(x: 512 + dx * 205, y: 560)
    ctx.rotate(by: dx * -0.35)
    ctx.fillEllipse(in: CGRect(x: -85, y: -38, width: 170, height: 76))
    ctx.restoreGState()
}
let face = CGPath(roundedRect: CGRect(x: 512 - 165, y: 300, width: 330, height: 360), cornerWidth: 160, cornerHeight: 170, transform: nil)
ctx.addPath(face)
ctx.fillPath()

// The prompt: ❯_ in charcoal and amber.
let font = NSFont.monospacedSystemFont(ofSize: 200, weight: .heavy)
func draw(_ text: String, _ hex: UInt32, at point: CGPoint) {
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color(hex))!])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}
draw("❯", 0x2B2A28, at: CGPoint(x: 512 - 130, y: 410))
draw("_", 0xD9982B, at: CGPoint(x: 512 + 10, y: 410))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
