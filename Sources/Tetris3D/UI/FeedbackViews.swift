import MetaGame
import SwiftUI

/// The latest scoring callout under the next queue, and banners (level up, perfect clear) across the well.
struct CalloutLayer: View {
    let feedback: Feedback
    let anchor: CGPoint
    let boardCenter: CGPoint
    let unit: CGFloat

    var body: some View {
        ZStack {
            ZStack {
                if let callout = feedback.callout {
                    CalloutView(callout: callout, unit: unit)
                        .id(callout.id)
                        .transition(.asymmetric(insertion: .scale(scale: 1.15).combined(with: .opacity),
                                                removal: .opacity.animation(.easeOut(duration: 0.1))))
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: feedback.callout?.id)
            .position(anchor)

            ZStack {
                if let banner = feedback.banner {
                    BannerView(banner: banner, unit: unit)
                        .id(banner.id)
                        .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .animation(.spring(duration: 0.5, bounce: 0.15), value: feedback.banner?.id)
            .position(boardCenter)
        }
    }
}

private struct CalloutView: View {
    let callout: Feedback.Callout
    let unit: CGFloat

    var body: some View {
        let u = unit
        VStack(spacing: u * 0.14) {
            if let caption = callout.caption {
                Caption(caption, size: u * 0.34, opacity: 1)
                    .foregroundStyle(callout.backToBack ? Palette.gold : callout.tint)
            }
            Text(callout.headline)
                .font(.rounded(u * 0.72, .black))
                .tracking(u * 0.06)
                .foregroundStyle(callout.tint)
                .shadow(color: callout.tint.opacity(0.7), radius: u * 0.35)
            if callout.combo > 0 {
                Text("COMBO ×\(callout.combo)")
                    .font(.rounded(u * 0.46, .heavy))
                    .tracking(u * 0.08)
                    .foregroundStyle(Palette.combo)
                    .shadow(color: Palette.combo.opacity(0.6), radius: u * 0.25)
            }
            Text("+\(callout.points.formatted())")
                .font(.rounded(u * 0.4, .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .fixedSize()
    }
}

private struct BannerView: View {
    let banner: Feedback.Banner
    let unit: CGFloat

    var body: some View {
        Text(banner.text)
            .font(.rounded(unit * 1.05, .black))
            .tracking(unit * 0.12)
            .foregroundStyle(banner.tint)
            .shadow(color: banner.tint.opacity(0.9), radius: unit * 0.5)
            .shadow(color: Palette.glow.opacity(0.6), radius: unit * 1.2)
            .fixedSize()
    }
}

/// 3-2-1-GO over the well before timed modes.
struct CountdownLayer: View {
    let step: Int?
    let anchor: CGPoint
    let unit: CGFloat

    var body: some View {
        ZStack {
            if let step {
                Text(step == 0 ? "GO!" : "\(step)")
                    .font(.rounded(unit * (step == 0 ? 2.4 : 3.2), .black))
                    .tracking(unit * 0.1)
                    .foregroundStyle(.white)
                    .shadow(color: Palette.glow.opacity(0.9), radius: unit * 0.8)
                    .fixedSize()
                    .id(step)
                    .transition(.asymmetric(insertion: .scale(scale: 1.3).combined(with: .opacity),
                                            removal: .scale(scale: 0.7).combined(with: .opacity)))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: step)
        .position(anchor)
    }
}

/// Achievement-unlocked toasts under the well.
struct ToastLayer: View {
    let feedback: Feedback
    let anchor: CGPoint
    let unit: CGFloat

    var body: some View {
        ZStack {
            if let toast = feedback.toast {
                ToastView(achievement: toast.achievement, unit: unit)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.25), value: feedback.toast?.id)
        .position(anchor)
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let achievement: Achievement
    let unit: CGFloat

    var body: some View {
        let u = unit
        HStack(spacing: u * 0.4) {
            BadgeView(achievement: achievement, unlocked: true, size: u * 1.45, motion: .unlock)
            VStack(alignment: .leading, spacing: u * 0.08) {
                Caption("ACHIEVEMENT UNLOCKED", size: u * 0.26, opacity: 0.6)
                Text(achievement.title)
                    .font(.rounded(u * 0.46, .heavy))
                    .foregroundStyle(.white)
            }
        }
        .padding(.leading, u * 0.25)
        .padding(.trailing, u * 0.6)
        .padding(.vertical, u * 0.22)
        .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.tier(achievement.tier).opacity(0.45)))
        .shadow(color: Palette.tier(achievement.tier).opacity(0.35), radius: u * 0.5)
        .fixedSize()
    }
}
