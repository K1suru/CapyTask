import AppKit
import SwiftUI

enum Theme {
    // Paleta CapyCoin
    static let capyBrown = Color(hex: 0x7A4B29)
    static let mandarina = Color(hex: 0xFF8C42)
    static let bamboo = Color(hex: 0x88A764)
    static let onsen = Color(hex: 0x5B92E5)
    static let danger = Color(hex: 0xE5675A)
    static let peach = Color(hex: 0xFFC49B)
    static let woodLight = Color(hex: 0xC99A6E)
    static let bambooLight = Color(hex: 0xC6D8A8)
    static let onsenLight = Color(hex: 0xAFC9F2)

    // Superficies (claro / oscuro)
    static let background = Color(light: 0xFDFBF7, dark: 0x23211F)
    static let card = Color(light: 0xFFFFFF, dark: 0x2D2A27)
    static let cardBorder = Color(light: 0xF0E7DC, dark: 0x3B3733)
    static let track = Color(light: 0xF3ECE4, dark: 0x3A3531)
    static let chip = Color(light: 0xF7F1EA, dark: 0x35312D)
    static let ink = Color(light: 0x4A2F1C, dark: 0xF3EADF)
    static let inkSoft = Color(light: 0x9B8472, dark: 0xA89888)
    static let accentInk = Color(light: 0x7A4B29, dark: 0xEBBE95)
    static let bambooInk = Color(light: 0x5E7A3F, dark: 0xB5D196)

    static let nsBackground = NSColor(light: 0xFDFBF7, dark: 0x23211F)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func color(for mood: CapyMood) -> Color {
        switch mood {
        case .normal: bamboo
        case .worried: mandarina
        case .stressed: danger
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(light: light, dark: dark))
    }
}

struct CapyCard: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card)
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    func capyCard(padding: CGFloat = 14) -> some View {
        modifier(CapyCard(padding: padding))
    }
}

/// Formatos de número con la configuración regional del usuario.
enum Format {
    static func bytes(_ bytes: UInt64, locale: Locale = AppLanguage.current.locale) -> String {
        let value = Double(bytes)
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if value >= gb { return number(value / gb, digits: 1, locale: locale) + " GB" }
        if value >= mb { return number(value / mb, digits: value / mb >= 100 ? 0 : 1, locale: locale) + " MB" }
        return number(value / kb, digits: 0, locale: locale) + " KB"
    }

    static func bytes(_ bytes: Int64, locale: Locale = AppLanguage.current.locale) -> String {
        Self.bytes(UInt64(max(0, bytes)), locale: locale)
    }

    /// Siempre en MB (columna "Memoria (MB)" de la tabla de procesos).
    static func megabytes(_ bytes: UInt64, locale: Locale = AppLanguage.current.locale) -> String {
        let value = Double(bytes) / 1_048_576
        return number(value, digits: value >= 100 ? 0 : 1, locale: locale)
    }

    /// Fracción 0...1 → "24%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Porcentaje de CPU por proceso (100% = un núcleo, como Monitor de Actividad).
    static func cpu(_ percent: Double, locale: Locale = AppLanguage.current.locale) -> String {
        number(percent, digits: percent >= 100 ? 0 : 1, locale: locale) + "%"
    }

    static func seconds(_ value: Double, locale: Locale = AppLanguage.current.locale) -> String {
        number(value, digits: 1, locale: locale) + " s"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    static func number(_ value: Double, digits: Int, locale: Locale = AppLanguage.current.locale) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }
}
