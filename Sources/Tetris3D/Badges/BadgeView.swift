import MetalKit
import MetaGame
import SwiftUI

/// An achievement's 3D badge. Still badges are cached images; hovering one brings it to life (a slow sway with a
/// light sweep) until the pointer leaves and it settles back. `.idle` animates continuously, and `.unlock` spins the
/// badge in with a white-hot flash before it settles into the idle sway, for the unlock toast.
struct BadgeView: View {
    enum Motion {
        case still, idle, unlock
    }

    let achievement: Achievement
    let unlocked: Bool
    /// Width and height in points. The plate fills about 85% of it; the rest leaves room for its glow.
    let size: CGFloat
    var motion: Motion = .still

    @Environment(\.displayScale) private var displayScale
    @State private var hovering = false
    @State private var livePresented = false
    @State private var liveVisible = false

    var body: some View {
        let pixels = Int((size * displayScale).rounded())
        ZStack {
            if motion != .unlock, let image = BadgeRenderer.shared?.image(achievement, unlocked: unlocked, pixels: pixels) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .opacity(liveVisible ? 0 : 1)
            }
            if motion != .still || livePresented {
                BadgeLiveView(achievement: achievement, unlocked: unlocked, motion: motion,
                              active: motion != .still || hovering,
                              onFirstFrame: { liveVisible = true },
                              onSettled: {
                                  livePresented = false
                                  liveVisible = false
                              })
                    .opacity(liveVisible ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .onHover { inside in
            hovering = inside
            if inside { livePresented = true }
        }
    }
}

/// A transparent Metal view that animates one badge through the shared `BadgeRenderer`.
private struct BadgeLiveView: NSViewRepresentable {
    let achievement: Achievement
    let unlocked: Bool
    let motion: BadgeView.Motion
    /// While false, the sway eases out; `onSettled` fires once the badge is back at rest.
    let active: Bool
    let onFirstFrame: () -> Void
    let onSettled: () -> Void

    func makeCoordinator() -> BadgeAnimator {
        BadgeAnimator(achievement: achievement, unlocked: unlocked, unlock: motion == .unlock)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = PassthroughMTKView()
        view.device = BadgeRenderer.shared?.device
        view.colorPixelFormat = BadgeRenderer.outputFormat
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        view.delegate = context.coordinator
        update(context.coordinator)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        update(context.coordinator)
        if active { context.coordinator.resume(view) }
    }

    private func update(_ animator: BadgeAnimator) {
        animator.active = active
        animator.onFirstFrame = onFirstFrame
        animator.onSettled = onSettled
    }
}

/// The badge view is decoration: hover and clicks belong to the SwiftUI views around it.
private final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Drives the badge's motion and draws each frame.
@MainActor
private final class BadgeAnimator: NSObject, MTKViewDelegate {
    let achievement: Achievement
    let unlocked: Bool
    let unlock: Bool
    var active = true
    var onFirstFrame: () -> Void = {}
    var onSettled: () -> Void = {}

    private var start: CFTimeInterval?
    private var last: CFTimeInterval = 0
    private var swayTime: Double = 0
    private var amplitude: Double = 0
    private var frames = 0
    private var settled = false

    init(achievement: Achievement, unlocked: Bool, unlock: Bool) {
        self.achievement = achievement
        self.unlocked = unlocked
        self.unlock = unlock
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Wakes a badge that had settled and paused.
    func resume(_ view: MTKView) {
        guard settled else { return }
        settled = false
        last = 0
        view.isPaused = false
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let elapsed = now - (start ?? now)
        if start == nil { start = now }
        let dt = min(now - (last == 0 ? now : last), 0.1)
        last = now

        let pose: BadgePose
        let unlocking = unlock && elapsed < BadgePose.unlockDuration
        if unlocking {
            pose = .unlock(at: elapsed)
        } else {
            // The amplitude eases in and out so starting and stopping never jumps.
            amplitude += ((active ? 1 : 0) - amplitude) * (1 - exp(-dt * (active ? 2.5 : 5)))
            swayTime += dt
            var idle = BadgePose.idle(at: swayTime, amplitude: amplitude)
            if unlock {
                // The unlock's extra glow fades out.
                idle.glow = Float(1 + 1.2 * exp(-(elapsed - BadgePose.unlockDuration) * 2.5))
            }
            pose = idle
        }

        guard let renderer = BadgeRenderer.shared, let drawable = view.currentDrawable,
              let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
        renderer.encode(achievement, unlocked: unlocked, pose: pose, into: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Reveal the view once its first frame is on screen, so swapping in for the still image never blinks.
        frames += 1
        if frames == 2 { onFirstFrame() }

        if !active, !unlocking, amplitude < 0.004, !settled {
            settled = true
            view.isPaused = true
            onSettled()
        }
    }
}

extension BadgePose {
    static let unlockDuration: Double = 1.25

    /// Spins in from small and fast, decelerating to face the viewer, flashing white-hot as it lands.
    static func unlock(at t: Double) -> BadgePose {
        let u = min(t / unlockDuration, 1)
        let spin = 1 - pow(1 - u, 3)
        // Ease-out-back for a slight overshoot in size.
        let back = 1 + 2.2 * pow(u - 1, 3) + 1.2 * pow(u - 1, 2)
        var pose = BadgePose()
        pose.yaw = Float(-(1 - spin) * 3 * .pi)
        pose.scale = Float(0.25 + 0.75 * back)
        let landing = (u - 0.74) / 0.06
        pose.flash = Float(0.55 * exp(-landing * landing))
        pose.glow = Float(1 + 1.2 * u * u)
        let sweep = (u - 0.55) / 0.45
        pose.sweep = Float(-11 + 22 * max(sweep, 0))
        pose.sweepStrength = sweep > 0 ? 1.4 : 0
        return pose
    }

    /// Slow sway with a light sweep every few seconds; `amplitude` 0 is the pose at rest.
    static func idle(at t: Double, amplitude: Double) -> BadgePose {
        var pose = BadgePose()
        pose.yaw = Float(amplitude * 0.42 * sin(t * 1.3))
        pose.pitch = Float(amplitude * 0.08 * sin(t * 0.9))
        let cycle = (t + 1.4).truncatingRemainder(dividingBy: 3.6) / 3.6
        pose.sweep = Float(cycle * 22 - 11)
        pose.sweepStrength = Float(amplitude * 0.7)
        return pose
    }
}
