import AppKit
import Foundation

// Build with Sources/Renderer.swift. No capture APIs or installed app are used.
enum Failure: Error { case message(String) }

@main
struct Demo {
    static let width = 960
    static let height = 680
    static let fps = 30
    static let frameCount = 225
    static let ink = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.09, alpha: 1)
    static let cyan = NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.95, alpha: 1)
    static let pink = NSColor(calibratedRed: 1, green: 0.22, blue: 0.57, alpha: 1)

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    static func graphics(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
    static func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                     _ color: NSColor = .white, weight: NSFont.Weight = .regular, mono: Bool = false) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ])
    }
    static func box(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    static func desktop(resolved: Bool) -> CGImage {
        let ctx = context(960, 540)
        graphics(ctx) {
            let colors = [NSColor(calibratedRed: 0.12, green: 0.19, blue: 0.28, alpha: 1).cgColor,
                          NSColor(calibratedRed: 0.30, green: 0.15, blue: 0.31, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 960, y: 540), options: [])
            box(CGRect(x: 0, y: 513, width: 960, height: 27), ink.withAlphaComponent(0.65))
            text("DEMO DESKTOP", 20, 519, 11, .white, weight: .bold, mono: true)
            text("All content is fictional", 763, 519, 11, .lightGray)

            // A fictional foreground workspace. Nothing here comes from a desktop image.
            box(CGRect(x: 34, y: 64, width: 570, height: 409), ink, radius: 12)
            box(CGRect(x: 34, y: 434, width: 570, height: 39), NSColor(calibratedWhite: 0.15, alpha: 1), radius: 12)
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                box(CGRect(x: 51 + i * 19, y: 449, width: 9, height: 9), color, radius: 5)
            }
            text("a very busy workspace", 137, 445, 12, .lightGray, mono: true)
            text("FOCUS MODE", 61, 389, 13, cyan, weight: .bold, mono: true)
            text("Keep making things.", 61, 344, 26, .white, weight: .bold)
            text("Your agent can get your attention", 61, 309, 17, .lightGray)
            text("when it needs your next move.", 61, 283, 17, .lightGray)
            for i in 0..<5 {
                box(CGRect(x: 61, y: 230 - i * 25, width: [295, 410, 250, 365, 190][i], height: 7),
                    (i == 2 ? cyan : NSColor(calibratedWhite: 0.5, alpha: 1)).withAlphaComponent(0.28), radius: 3)
            }
            // A second fictional window makes the whole-screen displacement easy to see.
            box(CGRect(x: 418, y: 112, width: 507, height: 309), NSColor(calibratedWhite: 0.96, alpha: 1), radius: 14)
            text("AGENT / EXAMPLE CHAT", 444, 385, 11, NSColor.darkGray, weight: .bold, mono: true)
            box(CGRect(x: 444, y: 345, width: resolved ? 157 : 169, height: 25),
                resolved ? NSColor(calibratedRed: 0.81, green: 0.95, blue: 0.86, alpha: 1) : NSColor(calibratedRed: 1, green: 0.88, blue: 0.65, alpha: 1), radius: 6)
            text(resolved ? "✓ BACK TO WORK" : "● APPROVAL NEEDED", 454, 351, 11, ink, weight: .bold, mono: true)
            text(resolved ? "Got it. Carrying on." : "Ready for your next move.", 444, 299, 24, ink, weight: .bold)
            text(resolved ? "You replied. The reminder is cleared." : "May I run the example build?", 444, 268, 17, NSColor.darkGray)
            box(CGRect(x: 444, y: 174, width: 454, height: 63), ink, radius: 8)
            text(resolved ? "YOU: Go ahead." : "$ example-build --preview", 461, 196, 15,
                 resolved ? cyan : .white, weight: .medium, mono: true)
            text(resolved ? "No more cues for this request." : "Waiting for the human…", 444, 139, 13, NSColor.darkGray)
            // Synthetic dock marks; no real apps, filenames, accounts, or clock data.
            for i in 0..<8 {
                box(CGRect(x: 323 + i * 40, y: 17, width: 28, height: 28),
                    NSColor(calibratedHue: CGFloat(i) / 8, saturation: 0.45, brightness: 0.82, alpha: 0.75), radius: 7)
            }
        }
        return ctx.makeImage()!
    }
    static func png(_ image: CGImage, _ path: String) throws {
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try data.write(to: URL(fileURLWithPath: path))
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.message("Pass an output frames directory") }
        let directory = CommandLine.arguments[1]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let waiting = desktop(resolved: false)
        let resolved = desktop(resolved: true)
        let renderer = try GlitchRenderer(image: waiting)
        for frame in 0..<frameCount {
            let desktopCtx = context(960, 540)
            var progress = 0.0
            if (60..<78).contains(frame) { progress = Double(frame - 60) / 18.0 }
            if (84..<102).contains(frame) { progress = Double(frame - 84) / 18.0 }
            if frame >= 159 { desktopCtx.draw(resolved, in: CGRect(x: 0, y: 0, width: 960, height: 540)) }
            else { renderer.draw(desktopCtx, rect: CGRect(x: 0, y: 0, width: 960, height: 540), progress: progress, intensity: 0.75) }
            let ctx = context(width, height)
            graphics(ctx) {
                box(CGRect(x: 0, y: 0, width: width, height: height), ink)
                text("GLITCHRUPT", 24, 636, 27, .white, weight: .heavy)
                text("POKE THE HUMAN.", 261, 641, 13, cyan, weight: .bold, mono: true)
                text("SYNTHETIC DEMO · REAL-TIME EFFECT", 656, 641, 10, .lightGray, mono: true)
                ctx.draw(desktopCtx.makeImage()!, in: CGRect(x: 0, y: 78, width: 960, height: 540))
                let caption: String
                if frame < 60 { caption = "Agent waiting for approval? Glitchrupt gives your screen a nudge." }
                else if frame < 102 { caption = "600 ms glitch  +  200 ms gap  +  600 ms glitch" }
                else if frame < 159 { caption = "Still waiting? The pair repeats every 15 minutes." }
                else { caption = "You reply or the task unblocks. The reminders stop." }
                text(caption, 24, 43, 17, .white, weight: .medium)
                text("Code-drawn pixels only. No personal screen capture.", 24, 17, 12, .lightGray)
                text("macOS · local MCP / CLI", 756, 17, 11, cyan, mono: true)
                box(CGRect(x: 0, y: 75, width: 960, height: 3), frame >= 159 ? cyan : pink)
            }
            try png(ctx.makeImage()!, directory + String(format: "/frame-%04d.png", frame))
        }
    }
}
