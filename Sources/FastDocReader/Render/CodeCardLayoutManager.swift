import AppKit

/// Draws each fenced code block as a distinct rounded "card" (fill + hairline border)
/// behind its text, instead of a flat background tint. Text stays selectable and
/// syntax-highlighted; only the backdrop changes. Card metrics are shared with the
/// copy-button overlay via `CodeCardMetrics` so the button lands on the card's edge.
enum CodeCardMetrics {
    static let horizontalMargin: CGFloat = 4   // gap from the text-area edges
    static let verticalPadding: CGFloat = 11   // extra height above/below the code text
    static let cornerRadius: CGFloat = 7
    static let textInset: CGFloat = 14         // left/right padding of code inside the card
}

/// Non-contiguous-layout NSLayoutManager. Decoration drawing (code cards, inline-code chips,
/// rules, quote bars) is intentionally NOT here — it lives in ReaderTextView.drawBackground(in:)
/// (the view's background pass) so it sits UNDER the selection highlight and text, instead of
/// painting over the selection like a layout-manager background would.
final class CodeCardLayoutManager: NSLayoutManager {}

/// Draw all block decorations behind the text for the glyphs in `glyphsToShow`. Called from the
/// text view's background pass, so everything drawn here is beneath selection + glyphs.
func drawMDDecorations(_ lm: NSLayoutManager, _ storage: NSTextStorage,
                       _ container: NSTextContainer, glyphsToShow: NSRange, at origin: NSPoint) {
    let m = CodeCardMetrics.self
    let charRange = lm.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

    // Code blocks → warm rounded card (Notion off-white / dark panel).
    let whole = NSRange(location: 0, length: storage.length)
    storage.enumerateAttribute(MDAttr.codeBlock, in: charRange) { value, range, _ in
        guard value != nil else { return }
        // Recover the block's FULL range (the visible slice is clipped to charRange). Drawing the
        // card from the full extent keeps it a single stable rect while scrolling, instead of a
        // per-strip sliver that tears into bands. The context clips it to the dirty area for us.
        var full = range
        _ = storage.attribute(MDAttr.codeBlock, at: range.location, longestEffectiveRange: &full, in: whole)
        let range = full
        let inset = CGFloat((storage.attribute(MDAttr.codeInset, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: container).offsetBy(dx: origin.x, dy: origin.y)
        // The card bottom must hug the LAST code line's text, not boundingRect's bottom — the
        // latter includes the paragraph's OUTER spacing (the gap to the next block), which made
        // the card bottom padding much larger than the top. usedRect excludes that spacing, so
        // top and bottom padding come out symmetric (both = verticalPadding).
        let lastGlyph = max(gr.location, NSMaxRange(gr) - 1)
        let lastBottom = lm.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y).maxY
        var card = rect
        card.origin.x = origin.x + m.horizontalMargin + inset
        card.size.width = container.size.width - m.horizontalMargin * 2 - inset
        card.origin.y = rect.minY - m.verticalPadding
        card.size.height = (lastBottom + m.verticalPadding) - card.origin.y
        let path = NSBezierPath(roundedRect: card, xRadius: m.cornerRadius, yRadius: m.cornerRadius)
        Palette.codeCardBg.setFill(); path.fill()
        Palette.codeCardBorder.setStroke(); path.lineWidth = 1; path.stroke()
    }

    // Inline code → a rounded chip hugging the glyphs (baseline-anchored, per line fragment).
    storage.enumerateAttribute(MDAttr.inlineCode, in: charRange) { value, range, _ in
        guard value != nil else { return }
        let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let ascent = font.ascender, descent = font.descender   // descent is negative
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var idx = gr.location
        while idx < NSMaxRange(gr) {
            var eff = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &eff)
            let lineRange = NSIntersectionRange(gr, eff)
            guard lineRange.length > 0 else { break }
            let baselineY = frag.minY + lm.location(forGlyphAt: lineRange.location).y
            let hx = lm.boundingRect(forGlyphRange: lineRange, in: container)   // x + width only
            let chip = NSRect(x: hx.minX - 2, y: baselineY - ascent - 1,
                              width: hx.width + 4, height: ascent - descent + 2)
                .offsetBy(dx: origin.x, dy: origin.y)
            Palette.inlineCodeBg.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
            idx = NSMaxRange(eff)
        }
    }

    // Office paragraph shading (docx `w:pPr/w:shd`, odt `fo:background-color`) → a full-width fill
    // behind the paragraph's own line fragments, drawn the SAME way a code block's card is: recover
    // the FULL attribute range (not the clipped `charRange` slice) so the fill is one stable rect
    // across scroll passes, not a per-strip sliver. No rounding/border here — that's a plain fill;
    // `paraBorderColor`/`paraBorderWidth` below draws the (independent) border box.
    storage.enumerateAttribute(MDAttr.paraShading, in: charRange) { value, r0, _ in
        guard let color = value as? NSColor else { return }
        var range = r0
        _ = storage.attribute(MDAttr.paraShading, at: r0.location, longestEffectiveRange: &range, in: whole)
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let fill = NSRect(x: origin.x, y: rect.minY, width: container.size.width, height: rect.height)
        color.setFill()
        NSBezierPath(rect: fill).fill()
    }

    // Office paragraph border (docx `w:pPr/w:pBdr`, odt `fo:border`) → a full-width stroked box
    // around the paragraph's own line fragments — same full-range recovery as shading above.
    // `paraBorderColor`/`paraBorderWidth` are always set together (see `MDAttr.paraBorderColor`'s
    // doc), so reading the width at the SAME location the colour enumeration already found is safe.
    storage.enumerateAttribute(MDAttr.paraBorderColor, in: charRange) { value, r0, _ in
        guard let color = value as? NSColor else { return }
        let width = CGFloat((storage.attribute(MDAttr.paraBorderWidth, at: r0.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 1)
        var range = r0
        _ = storage.attribute(MDAttr.paraBorderColor, at: r0.location, longestEffectiveRange: &range, in: whole)
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let box = NSRect(x: origin.x + width / 2, y: rect.minY + width / 2,
                         width: container.size.width - width, height: rect.height - width)
        color.setStroke()
        let path = NSBezierPath(rect: box)
        path.lineWidth = width
        path.stroke()
    }

    // Thematic breaks → a full-width hairline centered on the marker line.
    storage.enumerateAttribute(MDAttr.rule, in: charRange) { value, range, _ in
        guard value != nil else { return }
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let line = NSRect(x: origin.x + m.horizontalMargin, y: rect.midY.rounded(),
                          width: container.size.width - m.horizontalMargin * 2, height: 1)
        Palette.hairline.setFill(); NSBezierPath(rect: line).fill()
    }

    // Blockquotes → a 3pt accent bar down the left edge, hugging the ACTUAL text (glyph top of
    // the first line to glyph bottom of the last line). With a padded line height the glyphs sit
    // low in each line box, so a line-box-centered bar floats above the text — anchor to the
    // baselines instead (same fix as the inline-code chip).
    storage.enumerateAttribute(MDAttr.blockQuote, in: charRange) { value, r0, _ in
        guard value != nil else { return }
        // Recover the quote's FULL range (the visible slice is clipped) so the bar spans it all.
        var range = r0
        _ = storage.attribute(MDAttr.blockQuote, at: r0.location, longestEffectiveRange: &range, in: whole)
        guard range.length > 0 else { return }
        // TOP = first glyph's top.
        let firstFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 16)
        let firstGlyph = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil).location
        let firstFrag = lm.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        var topY = firstFrag.minY + lm.location(forGlyphAt: firstGlyph).y - firstFont.ascender
        // BOTTOM = last CONTENT glyph's bottom (skip trailing newlines).
        let str = storage.string as NSString
        var lastChar = NSMaxRange(range) - 1
        while lastChar > range.location, str.character(at: lastChar) == 0x0A { lastChar -= 1 }
        let lastFont = (storage.attribute(.font, at: lastChar, effectiveRange: nil) as? NSFont) ?? firstFont
        let lastGlyph = lm.glyphRange(forCharacterRange: NSRange(location: lastChar, length: 1), actualCharacterRange: nil).location
        let lastFrag = lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        var botY = lastFrag.minY + lm.location(forGlyphAt: lastGlyph).y - lastFont.descender  // descender < 0
        // If the quote STARTS or ENDS with a code CARD, extend the bar to the card's padded edge —
        // otherwise it stops at the code's text, leaving the bar short of the card's rounded box.
        if storage.attribute(MDAttr.codeBlock, at: range.location, effectiveRange: nil) != nil {
            topY -= m.verticalPadding
        }
        if storage.attribute(MDAttr.codeBlock, at: lastChar, effectiveRange: nil) != nil {
            botY += m.verticalPadding
        }
        let bar = NSRect(x: origin.x + m.horizontalMargin, y: topY + origin.y,
                         width: 3, height: max(0, botY - topY))
        Palette.quoteBar.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Draw the comments panel's body-side signal (P6b): a faint highlight behind every commented
/// span plus a small circular number badge at its start — PAINT ONLY, called from the text view's
/// background pass exactly like `drawMDDecorations` (same reasoning: it must sit under the
/// selection highlight and glyphs, never invalidate layout, and cost nothing beyond a fill + a
/// short string draw). The caller gates this entirely on whether the comments panel is open —
/// closed, `MDAttr.commentMark` is never even enumerated, so a comment-free document and a
/// comment-bearing one with the panel shut are visually and behaviourally identical.
func drawCommentMarks(_ lm: NSLayoutManager, _ storage: NSTextStorage, _ container: NSTextContainer,
                      glyphsToShow: NSRange, at origin: NSPoint) {
    let charRange = lm.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    let whole = NSRange(location: 0, length: storage.length)
    storage.enumerateAttribute(MDAttr.commentMark, in: charRange) { value, r0, _ in
        guard let numbers = value as? [Int], !numbers.isEmpty else { return }
        // Recover the FULL commented range (visible slice is clipped) — same reasoning as every
        // other decoration here: one stable rect across scroll passes, not a per-strip sliver.
        var range = r0
        _ = storage.attribute(MDAttr.commentMark, at: r0.location, longestEffectiveRange: &range, in: whole)
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: gr, in: container).offsetBy(dx: origin.x, dy: origin.y)
        Palette.commentHighlight.setFill()
        NSBezierPath(rect: rect).fill()

        // Small numbered badge just above-left of where the commented text starts. Drawn here (the
        // view's background/decoration pass), NOT as an NSTextAttachment — an attachment is a
        // glyph, and inserting one would change the character stream and the layout (invariant 1's
        // "size must never depend on what's drawn" applies just as much to "whether anything is
        // drawn at all").
        let label = numbers.map(String.init).joined(separator: ",")
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let badgeSize = NSSize(width: max(14, textSize.width + 6), height: 14)
        let badgeRect = NSRect(x: rect.minX - badgeSize.width - 2,
                               y: rect.maxY - badgeSize.height,
                               width: badgeSize.width, height: badgeSize.height)
        Palette.commentBadgeBg.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize.height / 2, yRadius: badgeSize.height / 2).fill()
        (label as NSString).draw(at: NSPoint(x: badgeRect.midX - textSize.width / 2,
                                             y: badgeRect.midY - textSize.height / 2), withAttributes: attrs)
    }
}
