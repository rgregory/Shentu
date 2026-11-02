import AppKit
import SwiftUI

// Shentu's look: Retro, shared with Fuxi. Off-white window, white panels with a 2-px black
// border and a hard black drop shadow, square corners, black text. Status colours (red,
// orange, green) keep their meaning.

enum Look {
    static let desktop = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let panel = Color.white
    static let text = Color.black
    static let accent = Color.black
    static let rule = Color.black.opacity(0.5)

    // System font throughout.
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func font(_ style: Font.TextStyle) -> Font { .system(style) }
}

/// White, 2-px black border with slightly rounded corners, hard 2-px shadow. The default button's label is semibold.
struct LookButtonStyle: ButtonStyle {
    var isDefault = false

    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(Look.font(.callout).weight(isDefault ? .semibold : .regular))
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(c.isPressed ? Color(white: 0.85) : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black, lineWidth: 2))
            // Flatten first so the shadow follows the box, not each letter.
            .compositingGroup()
            .shadow(color: .black, radius: 0, x: c.isPressed ? 0 : 2, y: c.isPressed ? 0 : 2)
    }
}

extension View {
    /// White panel, 2-px black border, hard 3-px black drop shadow.
    func lookPanel(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(Look.panel)
            .border(Color.black, width: 2)
            .compositingGroup()
            .shadow(color: .black, radius: 0, x: 3, y: 3)
    }

    /// Bold title over a grey rule.
    func lookHeader() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            self.font(Look.font(size: 13, weight: .semibold))
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Window-level look: off-white background, black text, light appearance.
    func lookWindow() -> some View {
        self
            .font(Look.font(.body))
            .foregroundStyle(Look.text)
            .tint(Look.accent)
            .background(Look.desktop)
            .preferredColorScheme(.light)
    }
}
