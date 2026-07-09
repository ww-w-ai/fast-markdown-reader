import AppKit

extension NSColor {
    /// sRGB from a 0xRRGGBB literal.
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
    /// A light/dark dynamic color — resolves against whatever appearance is drawing it, so
    /// it adapts automatically without asset catalogs.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Notion-inspired reading palette. Warm near-neutral everything, with ONE reddish accent
/// (inline code) — the single deliberate spot of color, per the Notion reading view. Links
/// keep a restrained blue since they're now clickable (affordance). All values are
/// light/dark dynamic.
enum Palette {
    static let text            = NSColor.dynamic(light: NSColor(rgb: 0x373530), dark: NSColor(rgb: 0xD4D4D4))
    static let secondary       = NSColor.dynamic(light: NSColor(rgb: 0x787774), dark: NSColor(rgb: 0x9B9B9B))
    static let inlineCodeText  = NSColor.dynamic(light: NSColor(rgb: 0xC4554D), dark: NSColor(rgb: 0xBE524B))
    static let inlineCodeBg    = NSColor(rgb: 0x878378, alpha: 0.15)   // warm neutral chip, both modes
    static let codeCardBg      = NSColor.dynamic(light: NSColor(rgb: 0xF7F6F3), dark: NSColor(rgb: 0x2F3437))
    static let codeCardBorder  = NSColor.dynamic(light: NSColor(rgb: 0x000000, alpha: 0.09),
                                                 dark:  NSColor(rgb: 0xFFFFFF, alpha: 0.12))
    static let hairline        = NSColor.dynamic(light: NSColor(rgb: 0x37352F, alpha: 0.12),
                                                 dark:  NSColor(rgb: 0xFFFFFF, alpha: 0.14))
    static let quoteBar        = NSColor.dynamic(light: NSColor(rgb: 0x37352F, alpha: 0.30),
                                                 dark:  NSColor(rgb: 0xFFFFFF, alpha: 0.30))
    static let link            = NSColor.dynamic(light: NSColor(rgb: 0x2E7AB8), dark: NSColor(rgb: 0x6CB0F5))
    static let tableBorder     = NSColor.dynamic(light: NSColor(rgb: 0x37352F, alpha: 0.16),
                                                 dark:  NSColor(rgb: 0xFFFFFF, alpha: 0.16))
    static let tableHeaderBg   = NSColor(rgb: 0x878378, alpha: 0.10)   // warm neutral, both modes
}

struct RenderTheme {
    var baseFontSize: CGFloat

    static func current(size: CGFloat) -> RenderTheme { RenderTheme(baseFontSize: size) }

    // Notion heading scale relative to a 16pt base: H1 30 / H2 24 / H3 20 / H4+ ~18.
    func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize * 1.875
        case 2: return baseFontSize * 1.5
        case 3: return baseFontSize * 1.25
        default: return baseFontSize * 1.15
        }
    }
    var bodyFont: NSFont { .systemFont(ofSize: baseFontSize) }
    func headingFont(level: Int) -> NSFont { .systemFont(ofSize: headingSize(level: level), weight: .semibold) }
    var codeFont: NSFont { .monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular) }

    var textColor: NSColor { Palette.text }
    var secondaryColor: NSColor { Palette.secondary }
    var linkColor: NSColor { Palette.link }
    var inlineCodeColor: NSColor { Palette.inlineCodeText }
    var inlineCodeBackground: NSColor { Palette.inlineCodeBg }
}
