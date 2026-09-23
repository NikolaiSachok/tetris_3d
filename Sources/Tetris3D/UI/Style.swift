import MetaGame
import SwiftUI

/// Colours shared by the overlay screens, tuned to the block palette in `GameScene`.
enum Palette {
    static let glow = Color(red: 0.2, green: 0.6, blue: 1)
    static let tetris = Color(red: 0.4, green: 0.88, blue: 1)
    static let tSpin = Color(red: 0.8, green: 0.52, blue: 1)
    static let gold = Color(red: 1, green: 0.82, blue: 0.36)
    static let combo = Color(red: 1, green: 0.62, blue: 0.3)
    static let danger = Color(red: 1, green: 0.36, blue: 0.36)

    static func tier(_ tier: Achievement.Tier) -> Color {
        switch tier {
        case .bronze: Color(red: 0.9, green: 0.6, blue: 0.4)
        case .silver: Color(red: 0.8, green: 0.86, blue: 0.95)
        case .gold: gold
        }
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The small uppercase, widely tracked label used throughout the HUD.
struct Caption: View {
    let text: String
    let size: CGFloat
    var opacity = 0.55

    init(_ text: String, size: CGFloat, opacity: Double = 0.55) {
        self.text = text
        self.size = size
        self.opacity = opacity
    }

    var body: some View {
        Text(text)
            .font(.rounded(size, .heavy))
            .tracking(size * 0.35)
            .foregroundStyle(.white.opacity(opacity))
    }
}

/// Dark translucent card behind every menu page.
struct PanelBackground: ViewModifier {
    let unit: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: unit * 0.6)
        content
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill(.black.opacity(0.4))
            }
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
    }
}

extension View {
    func panel(unit: CGFloat) -> some View { modifier(PanelBackground(unit: unit)) }
}

/// A standard menu page: title, content, key hints.
struct MenuPanel<Content: View>: View {
    let unit: CGFloat
    let title: String
    let hints: [KeyHint]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: unit * 0.8) {
            Text(title)
                .font(.rounded(unit * 0.95, .black))
                .tracking(unit * 0.3)
                .foregroundStyle(.white)
                .shadow(color: Palette.glow.opacity(0.6), radius: unit * 0.4)
            content
            KeyHintBar(unit: unit, hints: hints)
        }
        .padding(.horizontal, unit * 1.2)
        .padding(.top, unit * 0.9)
        .padding(.bottom, unit * 0.7)
        .panel(unit: unit)
    }
}

struct KeyHint: Hashable {
    let key: String
    let action: String

    static let select = KeyHint(key: "↑↓", action: "SELECT")
    static let back = KeyHint(key: "ESC", action: "BACK")
    static func confirm(_ action: String) -> KeyHint { KeyHint(key: "RETURN", action: action) }
}

struct KeyHintBar: View {
    let unit: CGFloat
    let hints: [KeyHint]

    var body: some View {
        HStack(spacing: unit * 0.7) {
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: unit * 0.2) {
                    Text(hint.key)
                        .font(.rounded(unit * 0.26, .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, unit * 0.14)
                        .frame(minWidth: unit * 0.55, minHeight: unit * 0.42)
                        .overlay(RoundedRectangle(cornerRadius: unit * 0.1).strokeBorder(.white.opacity(0.3)))
                    Caption(hint.action, size: unit * 0.26, opacity: 0.45)
                }
            }
        }
    }
}

/// A selectable row: highlighted when chosen by keyboard or hovered, activated by click.
struct SelectableRow<Label: View>: View {
    let unit: CGFloat
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
                .padding(.horizontal, unit * 0.45)
                .padding(.vertical, unit * 0.3)
                .background(
                    RoundedRectangle(cornerRadius: unit * 0.3)
                        .fill(.white.opacity(isSelected ? 0.1 : 0))
                        .overlay(RoundedRectangle(cornerRadius: unit * 0.3)
                            .strokeBorder(.white.opacity(isSelected ? 0.22 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { if $0 { onHover() } }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
