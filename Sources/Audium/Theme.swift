import SwiftUI

enum Theme {
    /// OLED-black app background (spec §4).
    static let background = Color(red: 0, green: 0, blue: 0)

    /// Single focal accent — electric cyan, used sparingly (spec §4).
    static let accent = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)

    static let panelStroke = accent.opacity(0.25)
    static let panelCornerRadius: CGFloat = 20
}

/// Press feedback per spec §4 motion guidelines: 0.95 scale on press.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundStyle(.black)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

/// Glass panel treatment shared by the bento-grid regions (spec §4).
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = Theme.panelCornerRadius

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.panelStroke, lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = Theme.panelCornerRadius) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// Section/panel heading style shared across the bento grid and Settings (spec §4) — shared
/// here (not duplicated per-file) so Settings uses the exact same heading treatment as the
/// main window rather than a stock `Form` section header.
struct PanelTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(Theme.accent)
    }
}
