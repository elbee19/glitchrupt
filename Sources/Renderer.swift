import AppKit
import CoreImage
import QuartzCore

final class GlitchRenderer {
    let image: CGImage
    let channels: [CGImage]
    init(image: CGImage) throws {
        self.image = image
        let ci = CIImage(cgImage: image)
        let context = CIContext(options: [.cacheIntermediates: false])
        channels = try (0..<3).map { channel in
            guard let filter = CIFilter(name: "CIColorMatrix") else { throw Failure.message("CIColorMatrix unavailable") }
            filter.setValue(ci, forKey: kCIInputImageKey)
            for (index, key) in ["inputRVector", "inputGVector", "inputBVector"].enumerated() {
                let values: [CGFloat] = (0..<4).map { channel == index && $0 == index ? 1 : 0 }
                filter.setValue(CIVector(x: values[0], y: values[1], z: values[2], w: values[3]), forKey: key)
            }
            guard let output = filter.outputImage, let result = context.createCGImage(output, from: ci.extent) else {
                throw Failure.message("Could not prepare color channels")
            }
            return result
        }
    }
    func noise(_ seed: Int, _ salt: Int) -> CGFloat {
        let n = sin(Double(seed * 127 + salt * 311)) * 43758.5453
        return CGFloat(n - floor(n))
    }
    func draw(_ ctx: CGContext, rect: CGRect, progress: Double, intensity: Double) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .medium
        guard progress > 0 && progress < 1 else {
            ctx.draw(image, in: rect); ctx.restoreGState(); return
        }
        let frame = Int(progress * 24)
        let envelope = CGFloat(pow(sin(.pi * progress), 0.65) * intensity)
        let beat: CGFloat = frame % 6 == 0 ? 0.18 : 1.0
        let power = envelope * beat
        let scale = rect.width / 1440
        let separation = (9 + noise(frame, 1) * 20) * power * scale
        let shakeX = (noise(frame, 2) - 0.5) * 14 * power * scale
        let shakeY = (noise(frame, 3) - 0.5) * 8 * power * scale
        let expanded = rect.insetBy(dx: -25 * scale, dy: -15 * scale).offsetBy(dx: shakeX, dy: shakeY)
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(rect)
        ctx.setBlendMode(.screen)
        for (index, shift) in [-separation, CGFloat(0), separation].enumerated() {
            ctx.draw(channels[index], in: expanded.offsetBy(dx: shift, dy: index == 0 ? separation * 0.18 : 0))
        }
        ctx.setBlendMode(.normal)
        // Displaced strips keep the captured desktop recognizable between bursts.
        for band in 0..<11 {
            let y = noise(frame / 2, band + 10) * rect.height
            let height = (2 + noise(frame, band + 30) * (band % 3 == 0 ? 55 : 12)) * scale
            let dx = (noise(frame, band + 50) - 0.5) * 140 * power * scale
            let strip = CGRect(x: 0, y: y, width: rect.width, height: height)
            ctx.saveGState(); ctx.clip(to: strip)
            ctx.draw(image, in: expanded.offsetBy(dx: dx, dy: 0))
            ctx.setBlendMode(.screen); ctx.setAlpha(0.8 * power)
            ctx.draw(channels[band % 3], in: expanded.offsetBy(dx: dx + separation * 2, dy: 1))
            ctx.restoreGState()
            ctx.setFillColor((band % 2 == 0 ? NSColor.systemPink : NSColor.cyan).withAlphaComponent(0.4 * power).cgColor)
            ctx.fill(CGRect(x: noise(frame, band + 70) * rect.width, y: y, width: rect.width * 0.18, height: max(1, 2 * scale)))
        }
        // Broken comic-book registration lines and sparse halftone texture.
        for line in 0..<3 {
            let x = (0.18 + CGFloat(line) * 0.31 + noise(frame / 3, line) * 0.04) * rect.width
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: 0))
            for segment in 1...7 {
                path.addLine(to: CGPoint(x: x + (noise(frame / 2, segment + line * 9) - 0.5) * 60 * power * scale,
                                        y: CGFloat(segment) * rect.height / 7))
            }
            ctx.addPath(path); ctx.setStrokeColor((line % 2 == 0 ? NSColor.cyan : NSColor.magenta).withAlphaComponent(0.75 * power).cgColor)
            ctx.setLineWidth(1.5 * scale); ctx.strokePath()
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.23 * power).cgColor)
        for x in stride(from: CGFloat(0), to: rect.width, by: max(6, 10 * scale)) {
            for y in stride(from: CGFloat(0), to: rect.height, by: max(6, 10 * scale)) where x < rect.width * 0.08 || x > rect.width * 0.92 {
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: 2 * scale, height: 2 * scale))
            }
        }
        ctx.restoreGState()
    }
}

final class EffectView: NSView {
    let renderer: GlitchRenderer
    var progress = 0.0
    var intensity = 0.75
    init(frame: NSRect, renderer: GlitchRenderer) { self.renderer = renderer; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        renderer.draw(ctx, rect: bounds, progress: progress, intensity: intensity)
    }
}
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func fixture(width: Int = 1440, height: Int = 900) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let colors = [NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.19, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.26, green: 0.08, blue: 0.30, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor, mono: Bool = false) {
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium) : NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
    }
    NSColor(calibratedWhite: 0.04, alpha: 0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 90, y: 100, width: 1260, height: 700), xRadius: 20, yRadius: 20).fill()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); NSRect(x: 90, y: 730, width: 1260, height: 50).fill()
    for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: 112 + i * 24, y: 747, width: 13, height: 13)).fill()
    }
    text("GLITCHRUPT / ATTENTION, REFRAMED", 250, 742, 17, .lightGray, mono: true)
    text("GLITCHRUPT", 155, 540, 77, .white)
    text("POKE THE HUMAN.", 155, 428, 65, .cyan)
    text("DIGITAL CRACKLE  /  A BRIEF CUE  /  YOUR NEXT MOVE", 160, 348, 18, .systemPink, mono: true)
    text("600 milliseconds. Then back to your business.", 160, 277, 28, .lightGray)
    text("SYNTHETIC PREVIEW — NO SCREEN CAPTURE", 160, 168, 17, .gray, mono: true)
    for i in 0..<8 {
        NSColor(calibratedHue: CGFloat(i) / 8, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        NSRect(x: 1090, y: 170 + i * 58, width: 160, height: 42).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

