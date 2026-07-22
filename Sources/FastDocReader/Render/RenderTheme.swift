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
    // The band under the line the reading cursor sits on. Faint enough to be ambient, not read as a
    // selection — a touch of the link hue so it reads as "you are here", warm-neutral in both modes.
    static let readingLine     = NSColor.dynamic(light: NSColor(rgb: 0x2E7AB8, alpha: 0.07),
                                                 dark:  NSColor(rgb: 0x6CB0F5, alpha: 0.10))
    static let tableBorder     = NSColor.dynamic(light: NSColor(rgb: 0x37352F, alpha: 0.16),
                                                 dark:  NSColor(rgb: 0xFFFFFF, alpha: 0.16))
    static let tableHeaderBg   = NSColor(rgb: 0x878378, alpha: 0.10)   // warm neutral, both modes
    // P6b: comment highlight — a faint amber wash behind a commented span (only drawn while the
    // comments panel is open, see `drawCommentMarks`), and the number badge it's paired with. Amber
    // rather than the reading-line's blue tint so the two "you should look here" signals never read
    // as the same kind of thing.
    static let commentHighlight = NSColor.dynamic(light: NSColor(rgb: 0xE9A23B, alpha: 0.16),
                                                  dark:  NSColor(rgb: 0xE9A23B, alpha: 0.22))
    static let commentBadgeBg   = NSColor(rgb: 0xE9A23B)   // solid amber, both modes
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

// MARK: - Rhythm tokens (shared BASE, every format)
//
// The same handful of ratios (line height, paragraph spacing, indent step, …) used to be
// hand-typed as `b * 1.45` / `b * 0.9` / … independently in `MarkdownRenderer`,
// `OfficeTextBuilder`, `TableBlockBuilder` and `PlainTextRenderer` — one literal per site, no
// single source of truth. These are that source: a bare ratio, multiplied by whatever base size
// (`baseFontSize`, a heading size, the code font's point size) the ORIGINAL call site used —
// this hoist changes naming only, never the arithmetic or where `.rounded()` is applied, so
// rendered output stays byte-identical (see the P0 parity harness in `RenderThemeParityTests`).
// A ratio that only one format needs stays out of here and lives on that format's own thin
// style type instead (`MarkdownStyle` / `OfficeStyle` / `PlainTextStyle`, below).
extension RenderTheme {
    /// Within-paragraph line leading, as a multiple of the base font size. (Body text, image
    /// paragraphs, list items, plain text minimum line — every format's "normal" line.)
    var lineHeightRatio: CGFloat { 1.45 }
    /// Gap AFTER a paragraph/body block, as a multiple of the base font size.
    var paragraphSpacingRatio: CGFloat { 0.9 }
    /// The smaller gap used where blocks sit closer together (list items, headings' space-after).
    var tightSpacingRatio: CGFloat { 0.3 }
    /// One list-indent step, as a multiple of the base font size (marker/text hang distance).
    var listHangRatio: CGFloat { 1.7 }
    /// Heading line leading, as a multiple of THAT heading's own font size (tighter than body).
    var headingLineHeightRatio: CGFloat { 1.25 }
    /// Gap AFTER a heading, as a multiple of the base font size (small — the heading should
    /// bond to the text below it).
    var headingSpacingAfterRatio: CGFloat { 0.4 }
    /// Code line leading, as a multiple of the code font's own point size (open enough to read
    /// as a bit more airy than a raw terminal). Also reused, applied to `baseFontSize`, for a
    /// table cell's line height — the same "slightly open" rhythm, just off a different base.
    var codeLineHeightRatio: CGFloat { 1.4 }
}

/// Markdown-only rhythm: values no other format needs, kept off the shared base per the
/// sprint's base-vs-branch split (see `RenderTheme`'s rhythm tokens doc above).
struct MarkdownStyle {
    let theme: RenderTheme
    /// Block-quote left indent (head + first-line), as a multiple of the base font size.
    var quoteIndentRatio: CGFloat { 1.25 }
    /// Space BEFORE a heading — roomier for H1/H2 than H3+, so the top two levels read as
    /// clearly starting a new section.
    func headingSpacingBefore(level: Int) -> CGFloat {
        theme.baseFontSize * (level <= 2 ? 1.9 : 1.4)
    }
}

/// Office (.docx/.odt)-only rhythm: values no other format needs.
struct OfficeStyle {
    let theme: RenderTheme
    /// Space BEFORE a heading — same shape as `MarkdownStyle`'s (roomier for H1/H2), kept as
    /// this format's own copy rather than merged into the base per the sprint's design (a value
    /// only one format uses lives on that format's branch, even when two branches happen to
    /// agree on the number).
    func headingSpacingBefore(level: Int) -> CGFloat {
        theme.baseFontSize * (level <= 2 ? 1.9 : 1.4)
    }
}

/// Plain-text (.txt/.csv/.log…)-only rhythm: values no other format needs.
struct PlainTextStyle {
    let theme: RenderTheme
    /// Monospace font size, as a fraction of the base font size (slightly smaller than prose).
    var monoSizeRatio: CGFloat { 0.95 }
}
