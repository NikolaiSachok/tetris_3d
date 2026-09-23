#if DEBUG
import AppKit
import MetaGame

/// `TETRIS_BADGE_SHEET=<path.png>` renders every badge, unlocked and locked, at a large and a small size into one
/// PNG when the badge renderer first starts (e.g. with `TETRIS_SCREEN=achievements`), plus `<path>.motion.png`: a
/// filmstrip of the unlock animation and the idle sway. The app then continues.
enum BadgeContactSheet {
    @MainActor
    static func renderIfRequested(with renderer: BadgeRenderer) {
        guard let path = ProcessInfo.processInfo.environment["TETRIS_BADGE_SHEET"] else { return }
        let large = 192, small = 80, gap = 16, labelHeight = 34, columns = 4
        let cellWidth = 2 * large + 2 * small + 4 * gap
        let cellHeight = large + labelHeight + gap
        let rows = (Achievement.allCases.count + columns - 1) / columns
        let width = columns * cellWidth + gap, height = rows * cellHeight + gap

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // The menu panels: dark translucent material over the backdrop.
        context.setFillColor(CGColor(srgbRed: 0.035, green: 0.04, blue: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .heavy),
            .foregroundColor: NSColor(white: 1, alpha: 0.7),
        ]
        for (index, achievement) in Achievement.allCases.enumerated() {
            let x = gap + (index % columns) * cellWidth
            let top = height - gap - (index / columns) * cellHeight
            var cursor = x
            for (pixels, unlocked) in [(large, true), (large, false), (small, true), (small, false)] {
                if let image = renderer.image(achievement, unlocked: unlocked, pixels: pixels) {
                    context.draw(image, in: CGRect(x: cursor, y: top - large + (large - pixels) / 2,
                                                   width: pixels, height: pixels))
                }
                cursor += pixels + gap
            }
            let label = "\(achievement.rawValue) · \(achievement.title) · \(achievement.tier)"
            NSAttributedString(string: label, attributes: attributes)
                .draw(at: CGPoint(x: x + 8, y: top - large - labelHeight + 4))
        }
        NSGraphicsContext.current = nil

        write(context, to: path)
        renderMotion(with: renderer, to: path + ".motion.png")
    }

    @MainActor
    private static func renderMotion(with renderer: BadgeRenderer, to path: String) {
        let size = 192, frames = 12
        let poses = (0..<frames).map { BadgePose.unlock(at: Double($0) / Double(frames - 1) * BadgePose.unlockDuration) }
            + (0..<frames).map { BadgePose.idle(at: Double($0) * 0.3, amplitude: 1) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size * frames, height: size * 2, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.setFillColor(CGColor(srgbRed: 0.035, green: 0.04, blue: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size * frames, height: size * 2))
        for (index, pose) in poses.enumerated() {
            guard let image = renderer.render(.tetrises100, unlocked: true, pose: pose, pixels: size) else { continue }
            context.draw(image, in: CGRect(x: index % frames * size, y: (1 - index / frames) * size,
                                           width: size, height: size))
        }
        write(context, to: path)
    }

    private static func write(_ context: CGContext, to path: String) {
        guard let image = context.makeImage() else { return }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        do {
            try data?.write(to: URL(filePath: path))
        } catch {
            print("Badge contact sheet failed: \(error)")
        }
    }
}
#endif
