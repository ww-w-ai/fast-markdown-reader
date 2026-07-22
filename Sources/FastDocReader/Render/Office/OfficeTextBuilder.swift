import AppKit

/// Turns a format-neutral `[OfficeBlock]` into styled `NSAttributedString`, the same way
/// `MarkdownRenderer` turns a parsed markdown tree into one and `PlainTextRenderer` turns raw text
/// into one. Every TOP-LEVEL block is exactly one navigation stop: it gets its own `MDAttr.blockId`
/// over its full rendered range (content + its one trailing separator), so gutter click / block
/// edit work here for free once a later sprint wires this into the document — see invariant 1's
/// sibling rule for images: a reserved layout size must never depend on whether pixels are loaded.
enum OfficeTextBuilder {
    /// `columnWidth` is the text column's width in points at build time (what `presizeKnownMedia`
    /// calls `maxWidth` for markdown) — defaulted huge so callers that don't care about wrapping
    /// (every test but the scaling one) get the declared size back untouched. A real caller
    /// (`MarkdownDocument.render(into:)`) always passes the reader's actual column width: office
    /// image sizing is decided HERE, once, at build time — never at load time (see `appendImage`).
    ///
    /// `documentDefaultFontSize` is the SOURCE document's own default body run size, in points
    /// (docx `w:docDefaults/w:rPrDefault/w:rPr/w:sz`, HALF-points, converted by the reader; the
    /// OOXML default when a document states none at all is 11pt — the same default this parameter
    /// itself defaults to, so a caller that hasn't wired a reader-supplied value through yet still
    /// gets the standard behaviour). This is the OTHER half of the font-size model, alongside
    /// `Span.fontSize`: the document, as authored, is 100% — `theme.baseFontSize` (the user's
    /// reading-size preference, `FontSizeStore.size`) is multiplied on top of it, as the RATIO
    /// `theme.baseFontSize / documentDefaultFontSize`. A run that names an explicit size (a 22
    /// half-point body run, a 32 half-point heading — `Span.fontSize` 11pt/16pt) is scaled by that
    /// ratio; a run that names none keeps whatever the surrounding block's OWN base font already is
    /// (`theme.headingFont(level:)`/`theme.bodyFont`), which is already sized off `theme.baseFontSize`
    /// with no further scaling. Two things this preserves, deliberately, the way Word itself does:
    /// a document's own internal relationships survive the user's reading-size setting (a heading
    /// stays proportionally larger than body text, an emphasised 14pt line stays larger than an
    /// 11pt paragraph, AT ANY reading size) — and the reading-size setting still governs how big
    /// the document looks overall, which is the entire point of that setting and must never be
    /// silently overridden by what the document happened to be authored at.
    /// `comments` (P6b) is `officeComments` from `MarkdownDocument` — used ONLY to resolve each
    /// `Span.commentIds` entry to that comment's DISPLAY number (`OfficeComment.number`), via
    /// `commentNumbers` below, so `MDAttr.commentMark` carries the number a reader recognizes
    /// ("Comment 3") rather than the source's opaque id string. Threaded into headings/paragraphs/
    /// list items (where a comment's anchor overwhelmingly lands); table-cell content does not
    /// receive it — cells build through a separate, already-deep call chain
    /// (`appendTable`→`cellContent`) and a comment anchored inside a table cell is rare enough that
    /// widening that chain wasn't worth the added surface for this sprint.
    static func build(_ blocks: [OfficeBlock], theme: RenderTheme,
                      columnWidth: CGFloat = .greatestFiniteMagnitude,
                      documentDefaultFontSize: CGFloat = 11,
                      comments: [OfficeComment] = []) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var blockSeq = 0
        // Ordered-list numbering state, keyed by nesting level. Lives for the whole build() call
        // (not per-block) because the restart rule below needs to see across blocks.
        var orderedCounters: [Int: Int] = [:]
        let fontSizeScale = documentDefaultFontSize > 0 ? theme.baseFontSize / documentDefaultFontSize : 1
        // id → display number, built once per build() call (comments list is small; a dictionary
        // avoids an O(n) scan per span).
        var commentNumbers: [String: Int] = [:]
        for c in comments { commentNumbers[c.id] = c.number }

        func tagBlock(from start: Int) {
            let r = NSRange(location: start, length: result.length - start)
            guard r.length > 0 else { return }
            result.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
            blockSeq += 1
        }

        for (index, block) in blocks.enumerated() {
            let start = result.length
            // P2's `w:contextualSpacing` adjacency rule (spec area 5): suppress THIS paragraph's
            // spacing-before when the PREVIOUS block is the same style (its `ParagraphFormat` is
            // EQUAL — the vocabulary carries no style id, so equal resolved format is the proxy),
            // and symmetric for spacing-after against the NEXT block. Only ever narrows a format
            // (zeroes spacing that was otherwise set) — a block with no format at all (`nil`, every
            // non-paragraph-shaped case) is untouched, and a paragraph whose OWN contextualSpacing
            // is `false`/unset never has this rule applied regardless of its neighbours.
            let format = contextualSpacingAdjustedFormat(for: block, at: index, in: blocks)
            switch block {
            case let .heading(level, spans, rtl, alignment, tabStops, _):
                result.append(spansAttributedString(spans, baseFont: theme.headingFont(level: level),
                                                     baseColor: theme.textColor, theme: theme,
                                                     fontSizeScale: fontSizeScale, commentNumbers: commentNumbers))
                // Tagged BEFORE the trailing newline is appended, so a substring of this range is
                // exactly the heading's text — precisely what the outline sidebar reads
                // (`OutlinePanel.reload` trims and shows it verbatim).
                result.addAttribute(MDAttr.heading, value: level,
                                     range: NSRange(location: start, length: result.length - start))
                result.append(NSAttributedString(string: "\n"))
                result.addAttribute(.paragraphStyle,
                                    value: headingParagraphStyle(level: level, theme: theme, rtl: rtl,
                                                                  alignment: alignment, tabStops: tabStops,
                                                                  format: format, fontSizeScale: fontSizeScale),
                                    range: NSRange(location: start, length: result.length - start))

            case let .paragraph(spans, rtl, alignment, tabStops, _):
                result.append(spansAttributedString(spans, baseFont: theme.bodyFont,
                                                     baseColor: theme.textColor, theme: theme,
                                                     fontSizeScale: fontSizeScale, commentNumbers: commentNumbers))
                result.append(NSAttributedString(string: "\n"))
                result.addAttribute(.paragraphStyle,
                                    value: bodyParagraphStyle(theme: theme, rtl: rtl, alignment: alignment,
                                                               tabStops: tabStops, format: format,
                                                               fontSizeScale: fontSizeScale),
                                    range: NSRange(location: start, length: result.length - start))

            case let .listItem(level, ordered, spans, marker, rtl, alignment, tabStops, _):
                appendListItem(level: level, ordered: ordered, spans: spans, marker: marker, rtl: rtl,
                               alignment: alignment, tabStops: tabStops, into: result,
                               theme: theme, orderedCounters: &orderedCounters, fontSizeScale: fontSizeScale,
                               format: format, commentNumbers: commentNumbers)

            case let .table(rows, headerRows, columnWidths, tableFormat):
                appendTable(rows, headerRows: headerRows, columnWidths: columnWidths, tableFormat: tableFormat,
                            into: result, theme: theme, fontSizeScale: fontSizeScale)

            case let .image(id, size):
                appendImage(id: id, size: size, columnWidth: columnWidth, into: result)

            case let .unsupportedGraphic(label, size):
                appendUnsupportedGraphic(label: label, size: size, columnWidth: columnWidth, into: result)

            case let .formula(latex):
                appendFormula(latex: latex, into: result)
            }
            // P2b — a heading/paragraph/list-item's own resolved shading/border (`format` is `nil`
            // for every other case, so this is a no-op there): tagged over the block's FULL rendered
            // range (content + its one trailing separator, same range `tagBlock` below tags), read
            // by `drawMDDecorations` at draw time — see `MDAttr.paraShading`'s own doc for why this
            // is build-time-only (nothing here recomputes geometry; the layout manager just paints a
            // rect over glyphs already laid out).
            if let format {
                let range = NSRange(location: start, length: result.length - start)
                if let shading = format.shading { result.addAttribute(MDAttr.paraShading, value: shading, range: range) }
                // Presence is "either field resolved" — a source can legally set only `w:pBdr`'s
                // `@w:sz` (width) with `@w:color="auto"` (theme decides), or vice versa; the SAME
                // per-field fallback `TableBlockBuilder` already applies to `Cell.borderColor`/
                // `.borderWidth` (`Palette.tableBorder` / `1`pt) is mirrored here so a partially
                // resolved border still draws something rather than silently vanishing.
                if format.borderColor != nil || format.borderWidth != nil {
                    let color = format.borderColor ?? Palette.tableBorder
                    let width = format.borderWidth ?? 1
                    result.addAttribute(MDAttr.paraBorderColor, value: color, range: range)
                    result.addAttribute(MDAttr.paraBorderWidth, value: NSNumber(value: Double(width)), range: range)
                }
            }
            tagBlock(from: start)
        }
        return result
    }

    /// The `format` carried by a heading/paragraph/list-item block — `nil` for every other case
    /// (table/image/unsupportedGraphic/formula), which carries no `ParagraphFormat` at all.
    private static func paragraphFormat(of block: OfficeBlock) -> ParagraphFormat? {
        switch block {
        case let .heading(_, _, _, _, _, format): return format
        case let .paragraph(_, _, _, _, format): return format
        case let .listItem(_, _, _, _, _, _, _, format): return format
        case .table, .image, .unsupportedGraphic, .formula: return nil
        }
    }

    /// `block`'s own resolved `ParagraphFormat`, with `spacingBefore`/`spacingAfter` zeroed when
    /// P2's `w:contextualSpacing` adjacency rule applies — see `build`'s call site doc. `nil` in,
    /// `nil` out (a block with no `ParagraphFormat` never gets one invented).
    private static func contextualSpacingAdjustedFormat(
        for block: OfficeBlock, at index: Int, in blocks: [OfficeBlock]
    ) -> ParagraphFormat? {
        guard let resolved = paragraphFormat(of: block), resolved.contextualSpacing else {
            return paragraphFormat(of: block)
        }
        // Both neighbour comparisons are against `resolved` — the UNMUTATED format — so zeroing
        // `spacingBefore` for the "previous block matches" check can never change what the
        // "next block matches" check compares against (and vice versa).
        var adjusted = resolved
        if index > 0, paragraphFormat(of: blocks[index - 1]) == resolved {
            adjusted.spacingBefore = 0
        }
        if index + 1 < blocks.count, paragraphFormat(of: blocks[index + 1]) == resolved {
            adjusted.spacingAfter = 0
        }
        return adjusted
    }

    // MARK: Spans → attributed runs

    /// Renders one block's spans against that block's base font/color. A `code` span overrides
    /// BOTH with the theme's inline-code styling and tags `MDAttr.inlineCode` — bold/italic/
    /// underline still layer on top of it (an office run can be monospaced AND bold at once,
    /// unlike a markdown code span, which never carries emphasis).
    ///
    /// NOT private: a later sprint's RTF reader re-themes spans it parsed itself rather than
    /// receiving as `OfficeBlock`, and needs this exact styling logic rather than a duplicate.
    ///
    /// `fontSizeScale` is `theme.baseFontSize / documentDefaultFontSize` (see `build`'s doc comment
    /// for the model) — defaulted to `1` so every pre-sprint call site (this file's own cell/list
    /// helpers used to, and `OfficeTextBuilderTests`' direct calls still do, pass none) keeps
    /// meaning "don't rescale", i.e. `Span.fontSize` is already in the units the caller wants.
    /// `commentNumbers` (P6b) maps a comment's source id (`Span.commentIds` entries) to its DISPLAY
    /// number — see `build`'s doc. Defaults to empty so every pre-P6b call site (every test, and
    /// the table-cell chain — see `build`'s doc for why cells don't thread this) keeps compiling
    /// and behaving exactly as before: a span with no matching number gets no `MDAttr.commentMark`.
    static func spansAttributedString(_ spans: [Span], baseFont: NSFont, baseColor: NSColor,
                                      theme: RenderTheme, fontSizeScale: CGFloat = 1,
                                      commentNumbers: [String: Int] = [:]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var font = baseFont
            var color = baseColor
            var attrs: [NSAttributedString.Key: Any] = [:]
            // `caps` is a DISPLAY-only transform (see `Span.caps`'s doc) — computed on a local copy
            // of the run's text, never on `span` itself, so nothing downstream (undo, re-render,
            // the source model) ever sees an uppercased string that wasn't authored.
            let displayText = span.caps ? span.text.uppercased() : span.text
            if span.code {
                font = theme.codeFont
                color = theme.inlineCodeColor
                attrs[MDAttr.inlineCode] = true
            } else if let name = span.fontName, let named = NSFont(name: name, size: font.pointSize) {
                // Family override — never applied to a `code` span (see `Span.fontName`'s doc).
                font = named
            }
            // An authored size REPLACES the block's base size before bold/italic/super-sub touch
            // it, so those still layer on top of the right starting point (traits preserve family,
            // not size; scaling preserves family, not traits — order doesn't matter between the
            // two, but both must happen before either reads `font.pointSize` for anything else).
            if let authoredSize = span.fontSize {
                let scaled = max(1, (authoredSize * fontSizeScale).rounded())
                font = NSFont(descriptor: font.fontDescriptor, size: scaled) ?? font
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if span.bold { traits.insert(.bold) }
            if span.italic { traits.insert(.italic) }
            if !traits.isEmpty { font = fontAdding(traits, to: font) }
            // Super/subscript shrink the font AND shift the baseline — `.superscript` alone isn't
            // interpreted by TextKit's own drawing, so it wouldn't actually render raised/lowered
            // here; a smaller font at an offset baseline is what makes it look right on screen.
            // `superscript`/`subscripted` are mutually exclusive in every real document, but if a
            // parser ever set both, superscript wins (checked first) rather than the two offsets
            // cancelling into something illegible.
            if span.superscript {
                let raised = font.pointSize * 0.35
                font = fontScaled(font, by: 0.7)
                attrs[.baselineOffset] = raised
            } else if span.subscripted {
                let lowered = -font.pointSize * 0.15
                font = fontScaled(font, by: 0.7)
                attrs[.baselineOffset] = lowered
            }
            // Authored colour is resolved against the theme, never applied raw — see
            // `resolvedTextColor`'s doc for the ordinary-ink-vs-marked-colour decision. Skipped for
            // a `code` span for the same reason `fontName` is: the inline-code look is one
            // consistent accent across the whole app, not something an individual run overrides.
            if let authoredColor = span.textColor, !span.code {
                color = resolvedTextColor(authoredColor, theme: theme)
            }
            // `smallCaps` (unlike `caps`) never touches `displayText` — it asks the FONT itself to
            // draw lowercase letters as small capitals, via the classic Apple `kLowerCaseType`/
            // `kLowerCaseSmallCapsSelector` font feature (present on macOS system fonts; a font
            // lacking the feature silently renders its ordinary lowercase glyphs instead — no
            // crash, just no small-caps look, the same graceful-degradation posture `fontName`'s
            // missing-family fallback already takes). Applied LAST, after every other font
            // transform above (code/family/size/bold-italic/super-sub), so the feature rides
            // whatever font those already produced rather than being clobbered by one of them.
            // Word's own precedence has `caps` win when both are set — `caps` already uppercased
            // `displayText` above, so this only visibly matters when `smallCaps` is set alone, but
            // it is harmless to also request the feature on an already-uppercased run (small-caps
            // has no effect on characters that are already capital).
            if span.smallCaps {
                let smallCapsAttrs: [[NSFontDescriptor.FeatureKey: Int]] = [[
                    .typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector,
                ]]
                let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: smallCapsAttrs])
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            attrs[.font] = font
            attrs[.foregroundColor] = color
            // Always drawn exactly as authored — see `Span.highlightColor`'s doc for why a
            // highlight, unlike text colour, is never reinterpreted against the theme.
            if let highlight = span.highlightColor { attrs[.backgroundColor] = highlight }
            if span.underline { attrs[.underlineStyle] = nsUnderlineStyle(for: span.underlineStyle).rawValue }
            if span.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Same colour/underline treatment `MarkdownRenderer.inlineFragment`'s `Markdown.Link`
            // case uses — a link must look and behave identically whether it arrived via markdown
            // or an office hyperlink, not grow a second visual style.
            if let link = span.link {
                if link.hasPrefix("#") {
                    // An in-document anchor (docx `w:anchor`, odt same-document `xlink:href`) —
                    // NEVER a `.link` URL built from the raw fragment. `MarkdownRenderer`'s own TOC
                    // links use the identical placeholder-URL-plus-`MDAttr.anchor` pair (see its
                    // `Markdown.Link` case) precisely so the click handler's `MDAttr.anchor` check
                    // catches this BEFORE it can ever reach the generic URL branch that treats a
                    // bare `#fragment` as a relative file path — that misread (clicking a
                    // cross-reference tries to open a file named after the bookmark) is the defect
                    // this exists to prevent, not a style nicety.
                    attrs[.foregroundColor] = theme.linkColor
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[MDAttr.anchor] = String(link.dropFirst())
                    attrs[.link] = URL(string: "fmdanchor:jump")!
                } else if let url = URL(string: link) {
                    attrs[.foregroundColor] = theme.linkColor
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.link] = url
                }
            }
            if !span.bookmarks.isEmpty {
                attrs[MDAttr.bookmarkTarget] = span.bookmarks
            }
            // P6b: a span whose ids resolve to a known comment gets the DISPLAY number(s) tagged —
            // an id with no match (comments capture failed to find it, or a stale/dangling id) is
            // silently skipped rather than surfacing a "Comment ?" the reader can't act on.
            if !span.commentIds.isEmpty {
                let numbers = span.commentIds.compactMap { commentNumbers[$0] }
                if !numbers.isEmpty { attrs[MDAttr.commentMark] = numbers }
            }
            // An explicitly-marked run (docx `w:rPr/w:rtl`) gets TextKit's own run-level embedding
            // override — the same mechanism a Unicode RLE/PDF control character would produce, just
            // stated declaratively instead of via invisible characters in the string. This is
            // independent of the paragraph's base direction (`OfficeBlock`'s `rtl`): a Latin phrase
            // embedded in an RTL paragraph never sets this, and a Hebrew phrase embedded in an LTR
            // one does — TextKit's bidi algorithm already reorders the two correctly around each
            // other once told which is which.
            if span.rtl {
                attrs[.writingDirection] = [NSWritingDirection.rightToLeft.rawValue
                                             | NSWritingDirectionFormatType.embedding.rawValue]
            }
            out.append(NSAttributedString(string: displayText, attributes: attrs))
        }
        return out
    }

    /// Maps `UnderlineStyle` (already-collapsed from docx `w:u/@w:val` — see that enum's doc) to
    /// the nearest `NSUnderlineStyle` AppKit actually draws. `.dashed`/`.dotted` have exact pattern
    /// equivalents; `.wavy` does not — `NSUnderlineStyle` has no wave pattern at all, so `.thick` is
    /// used as the nearest "this is not an ordinary underline" visual distinction AppKit offers
    /// (a plain `.single` would silently lose the fact the source asked for something unusual).
    private static func nsUnderlineStyle(for style: UnderlineStyle) -> NSUnderlineStyle {
        switch style {
        case .single: return .single
        case .double: return .double
        case .dotted: return .patternDot
        case .dashed: return .patternDash
        case .wavy: return .thick
        }
    }

    /// Decides whether an authored run colour survives into the current reading theme, or steps
    /// aside for the theme's own text colour. The judgement call the app makes: a NEAR-NEUTRAL
    /// authored colour (low saturation — almost always literal black, occasionally literal white)
    /// reads as "ORDINARY" — the author never meant to mark this text, they typed body copy under
    /// whatever their template's default run colour happened to be. Honouring that literally under
    /// the dark theme is exactly how ordinary text goes invisible (black-on-near-black); stepping
    /// aside for `theme.textColor` makes an authored-black run behave IDENTICALLY to a run that
    /// authored no colour at all, which is the only self-consistent reading of "ordinary" text.
    /// A genuinely COLOURFUL authored run (a red warning, a brand blue) has enough saturation to
    /// read as a DELIBERATE mark, and is drawn exactly as authored in both themes — losing that
    /// distinction would lose the meaning the colour exists to carry (a warning that silently
    /// becomes normal-coloured text is a warning nobody can see).
    ///
    /// `0.12` is a low bar deliberately: it only has to separate "grey/black/white" from "has a
    /// hue at all", not fine-tune how vivid a colour must be to count as a mark.
    static func resolvedTextColor(_ authored: NSColor, theme: RenderTheme) -> NSColor {
        guard let rgb = authored.usingColorSpace(.deviceRGB) else { return theme.textColor }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation < 0.12 ? theme.textColor : authored
    }

    /// Adds symbolic traits while keeping the SAME family, so vertical metrics (ascent/descent)
    /// don't shift — an unrelated bold face would jitter the baseline under a fixed line height
    /// (same reasoning as `MarkdownRenderer.fontAdding`, duplicated here: that one is private to
    /// its file).
    private static func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    /// Same family, scaled point size — used for super/subscript, which shrink the glyph as well
    /// as shifting its baseline.
    private static func fontScaled(_ font: NSFont, by factor: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * factor).rounded()) ?? font
    }

    // MARK: Paragraph styles

    /// `rtl` sets `baseWritingDirection` ONLY when true — an LTR block (`rtl == false`, every
    /// existing call site before this sprint) leaves it at `NSMutableParagraphStyle()`'s own default
    /// (`.natural`), so a pre-sprint document's paragraph style is byte-identical to before.
    /// `alignment`, when supplied, ALWAYS wins over `rtl`'s implicit edge (see `OfficeBlock`'s doc
    /// on the two) — `nil` (every pre-sprint call site) leaves `.natural` exactly as `rtl` alone
    /// left it before this parameter existed. `tabStops` (points) are appended to whatever default
    /// tab stops `NSMutableParagraphStyle()` already carries; empty (every pre-sprint call site)
    /// changes nothing. Each authored stop's OWN alignment (P2b) is carried into the built
    /// `NSTextTab` — see `officeTextTab`'s doc for exactly how.
    private static func bodyParagraphStyle(theme: RenderTheme, rtl: Bool = false,
                                            alignment: NSTextAlignment? = nil,
                                            tabStops: [TabStop] = [],
                                            format: ParagraphFormat? = nil,
                                            fontSizeScale: CGFloat = 1) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * theme.lineHeightRatio).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * theme.paragraphSpacingRatio
        if rtl { p.baseWritingDirection = .rightToLeft }
        if let alignment { p.alignment = alignment }
        if !tabStops.isEmpty { p.tabStops = tabStops.map(officeTextTab) }
        applyParagraphFormat(format, fontSizeScale: fontSizeScale, to: p)
        return p.copy() as! NSParagraphStyle
    }

    private static func headingParagraphStyle(level: Int, theme: RenderTheme, rtl: Bool = false,
                                               alignment: NSTextAlignment? = nil,
                                               tabStops: [TabStop] = [],
                                               format: ParagraphFormat? = nil,
                                               fontSizeScale: CGFloat = 1) -> NSParagraphStyle {
        let b = theme.baseFontSize
        let style = OfficeStyle(theme: theme)
        let p = NSMutableParagraphStyle()
        let lh = (theme.headingSize(level: level) * theme.headingLineHeightRatio).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = b * theme.headingSpacingAfterRatio
        p.paragraphSpacingBefore = style.headingSpacingBefore(level: level)
        if rtl { p.baseWritingDirection = .rightToLeft }
        if let alignment { p.alignment = alignment }
        if !tabStops.isEmpty { p.tabStops = tabStops.map(officeTextTab) }
        applyParagraphFormat(format, fontSizeScale: fontSizeScale, to: p)
        return p.copy() as! NSParagraphStyle
    }

    /// Builds ONE `NSTextTab` from an authored `TabStop` — `.left`/`.center`/`.right` map straight
    /// onto `NSTextAlignment`'s own cases (Apple's modern, non-deprecated `NSTextTab` initializer
    /// is ALREADY alignment-based, so this is a direct translation, not an emulation). `.decimal`
    /// has no `NSTextAlignment` case at all (the deprecated `NSTextTab(type:location:)`/
    /// `.decimalTabStopType` initializer is the only API that names one, and this codebase avoids
    /// deprecated AppKit surface) — the documented, still-current replacement (the header comment
    /// on `NSTextTab`'s alignment initializer) is `.right` alignment plus a column terminator
    /// character set: text runs up TO the tab stop right-aligned, then a further terminator
    /// (the decimal point) ends that column, which is what actually makes a `12.5` and a `100.25`
    /// line their decimal points up under this stop — the same visible effect `.decimal` names.
    /// `leader` is READ but never turned into a drawing instruction here — see `TabLeader`'s own
    /// doc for why (no native AppKit primitive, and a faithful fill is a deferred rendering cost).
    private static func officeTextTab(_ stop: TabStop) -> NSTextTab {
        switch stop.alignment {
        case .left: return NSTextTab(textAlignment: .left, location: stop.position, options: [:])
        case .center: return NSTextTab(textAlignment: .center, location: stop.position, options: [:])
        case .right: return NSTextTab(textAlignment: .right, location: stop.position, options: [:])
        case .decimal:
            return NSTextTab(textAlignment: .right, location: stop.position,
                             options: [.columnTerminators: CharacterSet(charactersIn: ".")])
        }
    }

    /// Applies the P2 cascade's resolved `ParagraphFormat` on top of whatever theme-token defaults
    /// the caller already set on `p` — per-field, only when the source specified that field (`nil`
    /// leaves the token value exactly as it was, which is what makes a paragraph with an entirely
    /// unspecified cascade render byte-identical to the pre-P2 token path). Order matters: this
    /// runs AFTER the caller's own token defaults, since `lineRule="atLeast"` must explicitly clear
    /// the `maximumLineHeight` cap those defaults set (a plain unset would leave the old cap active,
    /// silently reintroducing the very clipping `atLeast` exists to prevent).
    ///
    /// `fontSizeScale` is `theme.baseFontSize / documentDefaultFontSize` (see `build`'s doc) — every
    /// POINT value the source declared is scaled by it, exactly like `Span.fontSize`, so a
    /// document's own spacing/indent stays proportional at any reading-size setting.
    /// `lineHeightMultiple` is NOT scaled — `LineHeight.multiple` is already a unitless ratio
    /// (`w:lineRule="auto"`'s `line/240`), not a point value.
    private static func applyParagraphFormat(_ format: ParagraphFormat?, fontSizeScale: CGFloat,
                                              to p: NSMutableParagraphStyle) {
        guard let format else { return }
        if let before = format.spacingBefore { p.paragraphSpacingBefore = before * fontSizeScale }
        if let after = format.spacingAfter { p.paragraphSpacing = after * fontSizeScale }
        if let lineHeight = format.lineHeight {
            switch lineHeight {
            case .multiple(let ratio):
                p.lineHeightMultiple = ratio
            case .exact(let pt):
                let v = pt * fontSizeScale
                p.minimumLineHeight = v
                p.maximumLineHeight = v
            case .atLeast(let pt):
                p.minimumLineHeight = pt * fontSizeScale
                p.maximumLineHeight = 0 // a floor, not a cap — clears the token's own maximum.
            }
        }
        if format.indentStart != nil || format.indentEnd != nil || format.firstLineIndent != nil
            || format.hangingIndent != nil {
            // `NSParagraphStyle.headIndent`/`firstLineHeadIndent` per the spec's own mapping (area
            // 5): unspecified components read as 0, so a level that sets ONLY `spacingBefore`
            // (say) never reaches this block at all, and a level that sets exactly one indent
            // component still combines correctly with the other three at their neutral value.
            let start = (format.indentStart ?? 0) * fontSizeScale
            let firstLine = (format.firstLineIndent ?? 0) * fontSizeScale
            let hanging = (format.hangingIndent ?? 0) * fontSizeScale
            p.headIndent = start
            p.firstLineHeadIndent = start + firstLine - hanging
            if let end = format.indentEnd {
                // AppKit's own convention (already used by the markdown code-card header/footer,
                // `MarkdownRenderer.swift`'s `tailIndent = -CodeCardMetrics.textInset`): a positive
                // `tailIndent` measures from the LEFT margin, so the OOXML "distance from the right
                // edge" must be negated to land in the same place.
                p.tailIndent = -(end * fontSizeScale)
            }
        }
    }

    // MARK: Lists

    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat) — same
    /// progression `MarkdownRenderer.bullet(_:)` uses.
    private static func bulletGlyph(_ level: Int) -> String {
        switch level % 3 {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }

    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    /// `extraTabStops` (points, from `OfficeBlock.listItem.tabStops`) are AUTHORED stops beyond the
    /// marker's own — appended after the marker tab, never in place of it, so `1.\t<text>` still
    /// reaches the item's hanging indent first (this is the sprint brief's own required case: a
    /// custom tab stop must coexist with, not break, list indentation).
    private static func listParagraphStyle(markerX: CGFloat, textX: CGFloat, theme: RenderTheme,
                                            rtl: Bool = false, alignment: NSTextAlignment? = nil,
                                            extraTabStops: [TabStop] = [],
                                            format: ParagraphFormat? = nil,
                                            fontSizeScale: CGFloat = 1) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * theme.lineHeightRatio).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * theme.tightSpacingRatio
        p.firstLineHeadIndent = markerX
        p.headIndent = textX
        p.tabStops = [NSTextTab(textAlignment: .left, location: textX)] + extraTabStops.map(officeTextTab)
        p.defaultTabInterval = textX
        // The marker/hang-indent geometry (`markerX`/`textX`) is left exactly as it is for an LTR
        // item — mirroring it for RTL (marker on the right, indent growing leftward) is real work
        // this sprint's brief scoped out (base direction only); `baseWritingDirection` alone is
        // enough for TextKit to draw the text right-to-left, just still left-indented.
        if rtl { p.baseWritingDirection = .rightToLeft }
        if let alignment { p.alignment = alignment }
        // Applied LAST, same as the body/heading paths — a list item's own direct `w:pPr` spacing/
        // line-height/indent (P2's cascade) wins over the marker/hang-indent geometry above when
        // the source specified it; an unspecified cascade (the overwhelming common case — Word's
        // numbering, not a paragraph's own `w:ind`, usually carries a list's indentation) leaves
        // `markerX`/`textX` exactly as before this sprint.
        applyParagraphFormat(format, fontSizeScale: fontSizeScale, to: p)
        return p.copy() as! NSParagraphStyle
    }

    /// Renders one list item and updates the per-level numbering state.
    ///
    /// Restart rule (the only stateful part of this file, and only when `marker` is `nil` — see
    /// below): any item at `level` clears the counters of every level DEEPER than it —
    /// a shallower-or-equal item breaks a deeper level's run, so that level restarts at 1 the next
    /// time it appears. A deeper level intervening does NOT clear a shallower level's own counter,
    /// so `1. / a. / b. / 2.` keeps counting `1, 2` at the outer level across the nested run. An
    /// UNORDERED item also clears its OWN level's counter, so a bullet breaks an ordered run at
    /// that same level too.
    ///
    /// `marker`, when supplied, is rendered VERBATIM and `orderedCounters` is left untouched —
    /// see `OfficeBlock.listItem`'s doc comment for why only the reader can compute real numbering
    /// text (continuation across paragraphs, `w:startOverride`, multi-level `%1.%2` formats). This
    /// builder's own counters are a fallback for when the source couldn't supply that text, not a
    /// second, competing numbering scheme — the two never mix for a single item.
    private static func appendListItem(level: Int, ordered: Bool, spans: [Span], marker suppliedMarker: String?,
                                       rtl: Bool = false, alignment: NSTextAlignment? = nil,
                                       tabStops: [TabStop] = [], into result: NSMutableAttributedString,
                                       theme: RenderTheme, orderedCounters: inout [Int: Int],
                                       fontSizeScale: CGFloat = 1, format: ParagraphFormat? = nil,
                                       commentNumbers: [String: Int] = [:]) {
        let marker: String
        if let suppliedMarker {
            marker = suppliedMarker + "\t"
        } else {
            // Snapshot the keys first — removing while iterating `.keys` directly mutates the same
            // storage the view is walking.
            for deeper in orderedCounters.keys.filter({ $0 > level }) {
                orderedCounters.removeValue(forKey: deeper)
            }
            if ordered {
                let n = (orderedCounters[level] ?? 0) + 1
                orderedCounters[level] = n
                marker = "\(n).\t"
            } else {
                orderedCounters.removeValue(forKey: level)
                marker = bulletGlyph(level) + "\t"
            }
        }

        let hang = theme.baseFontSize * theme.listHangRatio
        let markerX = CGFloat(level) * hang
        let textX = CGFloat(level + 1) * hang
        let start = result.length
        result.append(NSAttributedString(string: marker,
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.textColor]))
        result.append(spansAttributedString(spans, baseFont: theme.bodyFont, baseColor: theme.textColor,
                                            theme: theme, fontSizeScale: fontSizeScale, commentNumbers: commentNumbers))
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle,
                            value: listParagraphStyle(markerX: markerX, textX: textX, theme: theme, rtl: rtl,
                                                       alignment: alignment, extraTabStops: tabStops,
                                                       format: format, fontSizeScale: fontSizeScale),
                            range: NSRange(location: start, length: result.length - start))
    }

    // MARK: Tables

    /// Real bordered grid via the shared `TableBlockBuilder` (also used by `MarkdownRenderer`'s
    /// GFM tables) — an office table now looks and behaves exactly like a markdown one, not a
    /// tab-stop approximation. `headerRows: 0` shades no row, because the source didn't say any
    /// row was a header (see `OfficeBlock.table`; guessing "row one" would misrepresent a
    /// headerless table). A cell shorter than the widest row leaves its trailing columns empty
    /// rather than collapsing the row.
    private static func appendTable(_ rows: [[Cell]], headerRows: Int, columnWidths: [CGFloat] = [],
                                    tableFormat: TableFormat = TableFormat(),
                                    into result: NSMutableAttributedString,
                                    theme: RenderTheme, fontSizeScale: CGFloat = 1) {
        guard rows.contains(where: { !$0.isEmpty }) else {
            result.append(NSAttributedString(string: "\n"))
            return
        }
        let headerFont = fontAdding(.bold, to: theme.bodyFont)
        let cellRows: [[TableBlockBuilder.CellContent]] = rows.enumerated().map { r, anchors in
            let isHeader = r < headerRows
            return anchors.map { cell in
                let content = cellContent(cell.blocks, baseFont: isHeader ? headerFont : theme.bodyFont,
                                          theme: theme, fontSizeScale: fontSizeScale)
                return TableBlockBuilder.CellContent(content: content, rowSpan: cell.rowSpan, columnSpan: cell.colSpan,
                                                      backgroundColor: cell.backgroundColor,
                                                      borderColor: cell.borderColor, borderWidth: cell.borderWidth,
                                                      width: cell.width, verticalAlignment: cell.verticalAlignment,
                                                      padding: cell.padding, styleShading: cell.styleShading,
                                                      styleBorderColor: cell.styleBorderColor,
                                                      styleBorderWidth: cell.styleBorderWidth)
            }
        }
        result.append(TableBlockBuilder.build(rows: cellRows, headerRows: headerRows, theme: theme,
                                              columnWidths: columnWidths,
                                              tableBorderColor: tableFormat.defaultBorderColor,
                                              tableBorderWidth: tableFormat.defaultBorderWidth,
                                              tableShading: tableFormat.defaultShading))
        result.append(NSAttributedString(string: "\n"))
    }

    /// Renders one cell's blocks. Deliberately NOT `build(_:theme:columnWidth:)` reused wholesale:
    /// that function ends every block with its own trailing `"\n"` PLUS a block-level paragraph
    /// style (heading/body line-height, paragraph spacing) sized for the full text column — inside
    /// a cell that fights `TableBlockBuilder`'s own paragraph style (`cellLH`, applied to the whole
    /// cell content afterwards) and would draw a spurious blank line under a single-paragraph cell.
    /// So the SEPARATOR is minimal here (a plain `"\n"` between blocks, none after the last) and no
    /// block gets its own `.paragraphStyle` — everything folds into the outer cell paragraph style.
    /// The single-block, single-paragraph case (the compatibility initialiser's shape) therefore
    /// renders BYTE-IDENTICAL to the pre-sprint `spansAttributedString(cell.spans, …)` call this
    /// replaces: no separator is ever emitted around a lone block.
    ///
    /// `.table` is handled by flattening rather than recursing into `appendTable`/
    /// `TableBlockBuilder` — a cell must never contain a REAL nested `NSTextTable` grid (the
    /// project's standing "nested tables flatten to text" decision, applied identically by both
    /// readers at parse time; this is the renderer's own backstop in case a `.table` block ever
    /// reaches a cell some other way).
    private static func cellContent(_ blocks: [OfficeBlock], baseFont: NSFont, theme: RenderTheme,
                                    fontSizeScale: CGFloat = 1) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            switch block {
            // `rtl`/`alignment`/`tabStops` are dropped here (`_`), not lost: a cell's own paragraph
            // style comes from `TableBlockBuilder`'s shared `cellLH` treatment, not from
            // `bodyParagraphStyle`/`headingParagraphStyle`/`listParagraphStyle` above, so there is
            // nowhere in a cell to apply a per-block paragraph override without reaching into that
            // shared builder (out of this sprint's file scope). A cell's RUN-level styling
            // (`Span.rtl`, `Span.textColor`, …) still applies, unaffected — it's carried entirely
            // inside `spansAttributedString`.
            case let .heading(level, spans, _, _, _, _):
                result.append(spansAttributedString(spans, baseFont: theme.headingFont(level: level),
                                                     baseColor: theme.textColor, theme: theme,
                                                     fontSizeScale: fontSizeScale))
            case let .paragraph(spans, _, _, _, _):
                result.append(spansAttributedString(spans, baseFont: baseFont, baseColor: theme.textColor,
                                                     theme: theme, fontSizeScale: fontSizeScale))
            case let .listItem(level, ordered, spans, marker, _, _, _, _):
                // Cell-local numbering state — a list embedded in one cell doesn't continue a
                // count begun in a sibling cell or at top level.
                var counters: [Int: Int] = [:]
                appendListItem(level: level, ordered: ordered, spans: spans, marker: marker, into: result,
                                theme: theme, orderedCounters: &counters, fontSizeScale: fontSizeScale)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .table(nestedRows, _, _, _):
                result.append(flattenTableToText(nestedRows, baseFont: baseFont, theme: theme))
            case let .image(id, size):
                appendImage(id: id, size: size, columnWidth: .greatestFiniteMagnitude, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .unsupportedGraphic(label, size):
                appendUnsupportedGraphic(label: label, size: size, columnWidth: .greatestFiniteMagnitude, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .formula(latex):
                appendFormula(latex: latex, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            }
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
        }
        return result
    }

    /// Flattens a nested table's cells into one run of text — a tab between cells, a newline after
    /// each non-empty row — so a reader glancing at the flattened text can still tell where one
    /// cell ended and the next began, even though the grid itself is gone. Mirrors the readers' own
    /// `flattenNestedTable` (applied when a `<w:tbl>`/`<table:table>` is found while COLLECTING a
    /// cell's spans, before a `Cell` even exists); this is the renderer-side twin for the case
    /// where a `.table` block reaches `cellContent` directly instead.
    private static func flattenTableToText(_ rows: [[Cell]], baseFont: NSFont, theme: RenderTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for row in rows {
            var rowHasContent = false
            for cell in row {
                let text = cellContent(cell.blocks, baseFont: baseFont, theme: theme)
                guard text.length > 0 else { continue }
                if rowHasContent { result.append(NSAttributedString(string: "\t", attributes: [.font: baseFont])) }
                result.append(text)
                rowHasContent = true
            }
            if rowHasContent { result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont])) }
        }
        return result
    }

    // MARK: Images

    /// Word DRAWS an image at its declared size regardless of the asset's own pixel dimensions (a
    /// 300px PNG placed at 225pt is ordinary), so — unlike a markdown image, whose true size is
    /// unknown until the bytes arrive — the declared size here is already authoritative. The only
    /// adjustment left is column-fitting: shrink proportionally if it's wider than the page. Doing
    /// that HERE, from the declared size alone, means `MarkdownDocument.reconcileMedia` never has
    /// to recompute a fit from real pixels for an office image — which matters, because
    /// recomputing on load is exactly the scroll-bar-jitter invariant 1 exists to prevent (an
    /// office image's pixel dimensions can legitimately disagree with its declared size).
    private static func fittedOfficeSize(_ declared: CGSize, columnWidth: CGFloat) -> CGSize {
        guard declared.width > columnWidth, declared.width > 0 else { return declared }
        let scale = columnWidth / declared.width
        return CGSize(width: columnWidth.rounded(), height: (declared.height * scale).rounded())
    }

    /// Reserves the (column-fitted) declared size via `SizedAttachmentCell`, image left `nil` —
    /// pixels arrive lazily via `MarkdownDocument.reconcileMedia`. This is invariant 1 of this
    /// codebase: the reserved layout size must NEVER depend on whether an image is loaded, or the
    /// scroll bar swings when it loads/purges.
    private static func appendImage(id: String, size: CGSize, columnWidth: CGFloat,
                                    into result: NSMutableAttributedString) {
        let fitted = fittedOfficeSize(size, columnWidth: columnWidth)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: fitted)
        att.attachmentCell = SizedAttachmentCell(reservedSize: fitted)
        let ph = NSMutableAttributedString(attachment: att)
        ph.addAttribute(MDAttr.image, value: id, range: NSRange(location: 0, length: ph.length))
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }

    /// A chart/SmartArt this reader could not resolve to any picture at all — reserves the SAME
    /// declared+column-fitted area `appendImage` would, drawn as a bordered, labelled frame
    /// SYNTHESIZED RIGHT HERE rather than left for `MarkdownDocument.reconcileMedia` to fill in
    /// later. Deliberately NOT built through `SizedAttachmentCell` the way `appendImage`'s
    /// reserved-but-unloaded state is (measured: `NSTextAttachment` drops a custom
    /// `attachmentCell` the moment `.image` is set — AppKit switches to its own bounds-based
    /// image layout at that point, the SAME mechanism `reconcileMedia`'s "pixels already loaded,
    /// just repaint" branch relies on) — so sizing here comes from `.bounds` alone, set once,
    /// alongside an `.image` that is never nil to begin with. Invariant 1 (reserved size must
    /// never depend on whether pixels are loaded) holds trivially: there is no "not yet loaded"
    /// state for this case at all, so nothing here can ever revise `.bounds` after the fact.
    /// `label` renders verbatim — the caller (`DocxReader`) already turned it into a word a reader
    /// understands ("Chart", "Diagram"), never an XML element name.
    private static func appendUnsupportedGraphic(label: String, size: CGSize, columnWidth: CGFloat,
                                                  into result: NSMutableAttributedString) {
        let fitted = fittedOfficeSize(size, columnWidth: columnWidth)
        let frame = NSImage(size: fitted, flipped: false) { rect in
            Palette.codeCardBg.setFill()
            rect.fill()
            Palette.codeCardBorder.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let text = "[\(label)]" as NSString
            let fontSize = max(9, min(14, rect.height * 0.18))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: Palette.secondary,
            ]
            let textSize = text.size(withAttributes: attrs)
            let origin = NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2)
            text.draw(at: origin, withAttributes: attrs)
            return true
        }
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: fitted)
        att.image = frame
        result.append(NSAttributedString(attachment: att))
        result.append(NSAttributedString(string: "\n"))
    }

    // MARK: Formulas

    /// Reserves a placeholder exactly the way `MarkdownRenderer.appendWebBlock` does for a markdown
    /// `$$…$$` — same `MDAttr.math` attribute, same `SizedAttachmentCell`-owned guessed size (260×60).
    /// `MarkdownDocument`'s pre-render/pre-size passes key off `enumerateWebBlocks`
    /// (`storage.enumerateAttribute(MDAttr.math, …)`), not this document's `kind`, so an office
    /// formula is picked up by the SAME up-front measure pass a markdown one is — nothing here (or
    /// in `MarkdownDocument`) had to be taught that office documents exist. The guessed size is only
    /// a placeholder; the up-front pass replaces it with the exact cached-PDF size before layout
    /// (invariant 1: reserved size must never depend on whether pixels are loaded).
    private static func appendFormula(latex: String, into result: NSMutableAttributedString) {
        let size = NSSize(width: 260, height: 60)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: size)
        att.attachmentCell = SizedAttachmentCell(reservedSize: size)
        let ph = NSMutableAttributedString(attachment: att)
        ph.addAttribute(MDAttr.math, value: latex, range: NSRange(location: 0, length: ph.length))
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }
}
