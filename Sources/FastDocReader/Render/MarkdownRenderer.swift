import AppKit
import Markdown

enum MarkdownRenderer {
    // Reuse the parsed tree across renders of the SAME text (e.g. every ⌘+/− zoom step re-renders
    // to rescale fonts but the markdown hasn't changed) so we don't re-parse on each zoom.
    private static var parseMemo: (text: String, doc: Document)?

    static func render(_ markdown: String, theme: RenderTheme) -> NSAttributedString {
        let document: Document
        if let m = parseMemo, m.text == markdown {
            document = m.doc
        } else {
            document = Document(parsing: markdown)
            parseMemo = (markdown, document)
        }
        var builder = AttributedBuilder(theme: theme, source: markdown)
        builder.visit(document)
        autolink(builder.result)
        return builder.result
    }

    /// After rendering, detect bare URLs and file paths in the prose and make them clickable
    /// links. Markdown links (already carrying `.link`) are left untouched.
    // Compiled once, reused across renders (these were rebuilt on every render — incl. every zoom).
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let filePathRE = try? NSRegularExpression(pattern: "(?<=\\s|^)(?:~|\\.{1,2})?/[\\w.\\-/@+]+")

    /// Code is shown, not offered as navigation — nothing inside a fence or a `code span` is
    /// autolinked. Three reasons, and the first is the one you can see: link styling is painted
    /// AFTER highlighting, so a URL in a string turns blue-underlined and the syntax colour dies
    /// right there. Selecting code is also common, and a link answers a click by leaving the app.
    /// GitHub draws the same line. (Explicit markdown links are untouched — those were asked for.)
    private static func isCode(_ s: NSAttributedString, _ at: Int) -> Bool {
        s.attribute(MDAttr.codeBlock, at: at, effectiveRange: nil) != nil ||
        s.attribute(MDAttr.inlineCode, at: at, effectiveRange: nil) != nil
    }

    private static func autolink(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        let str = s.string
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: Palette.link, .underlineStyle: NSUnderlineStyle.single.rawValue]

        if let det = linkDetector {
            det.enumerateMatches(in: str, range: full) { m, _, _ in
                guard let m, let url = m.url, !isCode(s, m.range.location),
                      s.attribute(.link, at: m.range.location, effectiveRange: nil) == nil else { return }
                s.addAttribute(.link, value: url, range: m.range)
                s.addAttributes(linkAttrs, range: m.range)
            }
        }
        // File paths: absolute (/…, ~/…) or explicit relative (./… ../…), only at a word
        // boundary so mid-word slashes ("and/or") are never matched. The raw path is stored;
        // the link handler resolves it against the document's directory.
        //
        // In code this pattern is also plain WRONG, not just unwanted: ` // comment` is a space then
        // slashes, so every C-style comment became a folder shortcut that opened Finder (Dockerfile
        // `COPY /src /usr/local/bin` too).
        if let re = filePathRE {
            let trailing = CharacterSet(charactersIn: ".,;:!?)")
            re.enumerateMatches(in: str, range: full) { m, _, _ in
                guard let m, !isCode(s, m.range.location),
                      s.attribute(.link, at: m.range.location, effectiveRange: nil) == nil else { return }
                var range = m.range
                // Drop trailing sentence punctuation the greedy match swallowed ("./x.md." → "./x.md").
                let ns = str as NSString
                while range.length > 0,
                      let u = ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1)).unicodeScalars.first,
                      trailing.contains(u) { range.length -= 1 }
                let path = ns.substring(with: range)
                guard path.contains("/") else { return }
                s.addAttribute(MDAttr.filePath, value: path, range: range)
                s.addAttribute(.link, value: URL(string: "fmdpath:file")!, range: range)
                s.addAttributes(linkAttrs, range: range)
            }
        }
    }
}

/// Build a paragraph style with an ABSOLUTE line height (min == max, in points) rather than a
/// multiple. AppKit's lineHeightMultiple multiplies each font's natural leading — which is
/// larger for Korean than Latin — so it reads loose and uneven; a fixed line height gives
/// tight, consistent leading that scales cleanly with the font size.
private func mdPara(lineHeight: CGFloat, spacingAfter: CGFloat, spacingBefore: CGFloat = 0,
                    headIndent: CGFloat = 0, firstLineIndent: CGFloat = 0) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    let lh = lineHeight.rounded()
    p.minimumLineHeight = lh
    p.maximumLineHeight = lh
    p.paragraphSpacing = spacingAfter
    p.paragraphSpacingBefore = spacingBefore
    p.headIndent = headIndent
    p.firstLineHeadIndent = firstLineIndent
    return p.copy() as! NSParagraphStyle
}

private struct AttributedBuilder: MarkupWalker {
    let theme: RenderTheme
    var result = NSMutableAttributedString()
    private var blockSeq = 0
    private let bodyPS: NSParagraphStyle
    private let quotePS: NSParagraphStyle
    private let imagePS: NSParagraphStyle   // no max line height, so the line grows to fit an image
    private let source: String              // original markdown, for block→source mapping
    private let lineStarts: [Int]           // UTF-16 offset of each source line start
    private let mathSpans: [(range: NSRange, tex: String)]
    private var emittedMath = Set<Int>()    // span starts already turned into a formula

    init(theme: RenderTheme, source: String) {
        self.theme = theme
        self.source = source
        var ls = [0]
        let sns = source as NSString
        for i in 0..<sns.length where sns.character(at: i) == 10 { ls.append(i + 1) }
        self.lineStarts = ls
        self.mathSpans = AttributedBuilder.scanMathSpans(source, lineStarts: ls)
        let b = theme.baseFontSize
        // All spacing is derived from the base font size with ABSOLUTE line heights, so it
        // scales with ⌘+/− and reads consistently. Within-paragraph leading is tight (1.45×);
        // the gap BETWEEN paragraphs is clearly larger — "near things close, far things far."
        bodyPS  = mdPara(lineHeight: b * 1.45, spacingAfter: b * 0.9)
        quotePS = mdPara(lineHeight: b * 1.45, spacingAfter: b * 0.9, headIndent: b * 1.25, firstLineIndent: b * 1.25)
        let ip = NSMutableParagraphStyle()
        ip.minimumLineHeight = (b * 1.45).rounded()   // floor only — NO ceiling, so a tall image fits
        ip.paragraphSpacing = b * 0.9
        imagePS = ip.copy() as! NSParagraphStyle
    }

    /// True if this markup contains an image anywhere in its subtree — such a paragraph must
    /// not cap its line height (see imagePS) or the image overflows and overlaps neighbors.
    private func containsImage(_ markup: Markup) -> Bool {
        if markup is Markdown.Image { return true }
        for child in markup.children where containsImage(child) { return true }
        return false
    }

    private func newline(_ count: Int = 1) {
        result.append(NSAttributedString(string: String(repeating: "\n", count: count)))
    }

    /// Tag everything appended since `start` as one top-level block with a unique id, so a
    /// gutter click can recover this exact block's range. Headings get their own id, cleanly
    /// separated from the paragraph beneath them.
    private mutating func tagBlock(from start: Int, src srcRange: SourceRange? = nil) {
        tagBlock(from: start, srcOffsets: sourceOffsets(srcRange))
    }

    private mutating func tagBlock(from start: Int, srcOffsets: NSRange?) {
        let r = NSRange(location: start, length: result.length - start)
        guard r.length > 0 else { return }
        result.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
        if let so = srcOffsets {
            result.addAttribute(MDAttr.srcRange, value: NSValue(range: so), range: r)
        }
        blockSeq += 1
    }

    /// Map a swift-markdown SourceRange to a UTF-16 NSRange in the source, by WHOLE LINES (blocks
    /// occupy full lines, so this sidesteps column encoding — safe for CJK). The trailing newline
    /// of the last line is excluded so a replacement keeps the block separators intact.
    private func sourceOffsets(_ srcRange: SourceRange?) -> NSRange? {
        guard let srcRange else { return nil }
        let startLine = srcRange.lowerBound.line
        let endLine = srcRange.upperBound.line
        guard startLine >= 1, startLine <= lineStarts.count else { return nil }
        let startOff = lineStarts[startLine - 1]
        let sns = source as NSString
        var endOff = (endLine >= 1 && endLine < lineStarts.count) ? lineStarts[endLine] - 1 : sns.length
        // Some blocks (e.g. lists) report a range that runs one line long; trim trailing newlines
        // so the span hugs the block's own text and a replacement can't swallow block separators.
        while endOff > startOff, sns.character(at: endOff - 1) == 10 || sns.character(at: endOff - 1) == 13 {
            endOff -= 1
        }
        guard endOff >= startOff else { return nil }
        return NSRange(location: startOff, length: endOff - startOff)
    }

    // Inline collection: render children into an attributed run with a base font. Images are
    // handled here (not in inlineFragment) so a trailing Pandoc `{width=…}` text sibling can be
    // consumed as the image's width.
    private func inlineString(_ markup: Markup, font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let children = Array(markup.children)
        var i = 0
        while i < children.count {
            if let img = children[i] as? Markdown.Image {
                let (alt, pts0, pct0) = parseSizedAlt(img.plainText)     // Obsidian ![alt|N]
                var pts = pts0, pct = pct0
                if i + 1 < children.count, let t = children[i + 1] as? Text,
                   let attr = parsePandocAttr(t.string) {                 // Pandoc ![](x){width=N}
                    if pts == nil, pct == nil { pts = attr.pts; pct = attr.pct }
                    out.append(imageString(source: img.source ?? "", alt: alt, widthPts: pts, widthPct: pct))
                    if !attr.remainder.isEmpty {
                        out.append(NSAttributedString(string: attr.remainder, attributes: [.font: font, .foregroundColor: color]))
                    }
                    i += 2; continue
                }
                out.append(imageString(source: img.source ?? "", alt: alt, widthPts: pts, widthPct: pct))
                i += 1; continue
            }
            out.append(inlineFragment(children[i], font: font, color: color))
            i += 1
        }
        return out
    }

    private func imageString(source: String, alt: String, widthPts: CGFloat?, widthPct: CGFloat?) -> NSMutableAttributedString {
        let att = NSTextAttachment()
        // A custom cell OWNS the layout size so image==nil (not-yet-loaded / purged) still reserves
        // the area — the default cell would collapse to zero and make the scroll bar swing. Real
        // size is applied to the cell right after (local images) or on first load (remote).
        let ph = NSSize(width: (widthPts ?? 480), height: 360)
        att.bounds = NSRect(origin: .zero, size: ph)
        att.attachmentCell = SizedAttachmentCell(reservedSize: ph)
        let out = NSMutableAttributedString(attachment: att)
        let whole = NSRange(location: 0, length: out.length)
        out.addAttribute(MDAttr.image, value: source, range: whole)
        if !alt.isEmpty { out.addAttribute(MDAttr.imageAlt, value: alt, range: whole) }
        if let w = widthPts { out.addAttribute(MDAttr.imageWidth, value: NSNumber(value: Double(w)), range: whole) }
        if let p = widthPct { out.addAttribute(MDAttr.imageWidthPct, value: NSNumber(value: Double(p)), range: whole) }
        return out
    }

    /// Obsidian `![alt|300]` / `![alt|300x200]` → strip the size off the alt.
    private func parseSizedAlt(_ alt: String) -> (alt: String, pts: CGFloat?, pct: CGFloat?) {
        guard let pipe = alt.lastIndex(of: "|") else { return (alt, nil, nil) }
        let sizePart = alt[alt.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
        let widthTok = sizePart.split(separator: "x").first.map(String.init) ?? sizePart
        let (pts, pct) = parseWidthSpec(widthTok)
        if pts != nil || pct != nil {
            return (String(alt[..<pipe]).trimmingCharacters(in: .whitespaces), pts, pct)
        }
        return (alt, nil, nil)
    }

    /// "300", "300px", "50%" → points or a 0–1 fraction.
    private func parseWidthSpec(_ s: String) -> (pts: CGFloat?, pct: CGFloat?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%"), let n = Double(t.dropLast()) { return (nil, CGFloat(n / 100)) }
        if let n = Double(t.replacingOccurrences(of: "px", with: "")) { return (CGFloat(n), nil) }
        return (nil, nil)
    }

    /// A leading `{ … }` attribute block (Pandoc). Consumes the braces even without a width=
    /// so the raw attribute never renders as literal text; returns text after `}` as remainder.
    private func parsePandocAttr(_ s: String) -> (pts: CGFloat?, pct: CGFloat?, remainder: String)? {
        let trimmed = s.drop(while: { $0 == " " })
        guard trimmed.first == "{", let close = trimmed.firstIndex(of: "}") else { return nil }
        let inside = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let remainder = String(trimmed[trimmed.index(after: close)...])
        if let re = try? NSRegularExpression(pattern: "width\\s*=\\s*\"?([0-9.]+%?(?:px)?)\"?", options: .caseInsensitive),
           let m = re.firstMatch(in: inside, range: NSRange(inside.startIndex..., in: inside)),
           let r = Range(m.range(at: 1), in: inside) {
            let (pts, pct) = parseWidthSpec(String(inside[r]))
            return (pts, pct, remainder)
        }
        return (nil, nil, remainder)
    }

    /// Parse an `<img …>` HTML tag → (src, alt, width). nil if it isn't an img tag.
    private func parseImgTag(_ html: String) -> (src: String, alt: String, pts: CGFloat?, pct: CGFloat?)? {
        guard html.range(of: "<img", options: .caseInsensitive) != nil else { return nil }
        func attr(_ name: String) -> String? {
            let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
            for g in 1...3 { if let r = Range(m.range(at: g), in: html) { return String(html[r]) } }
            return nil
        }
        guard let src = attr("src") else { return nil }
        var pts: CGFloat?, pct: CGFloat?
        if let w = attr("width") { (pts, pct) = parseWidthSpec(w) }
        return (src, attr("alt") ?? "", pts, pct)
    }

    /// Add bold/italic by keeping the SAME family (via the font descriptor) so vertical metrics
    /// (ascent/descent) don't change — otherwise a bold run shifts the baseline and line spacing
    /// looks jagged under a fixed line height.
    private func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    private func inlineFragment(_ markup: Markup, font: NSFont, color: NSColor) -> NSAttributedString {
        switch markup {
        case let t as Text:
            return NSAttributedString(string: t.string, attributes: [.font: font, .foregroundColor: color])
        case let e as Emphasis:
            return inlineString(e, font: fontAdding(.italic, to: font), color: color)
        case let s as Strong:
            return inlineString(s, font: fontAdding(.bold, to: font), color: color)
        case let c as InlineCode:
            // The one deliberate accent in the reading view: subtle muted-red text. The warm
            // chip behind it is drawn by the layout manager (MDAttr.inlineCode) so it hugs the
            // glyphs instead of filling the inflated 1.5× line box.
            return NSAttributedString(string: c.code, attributes: [
                .font: theme.codeFont, .foregroundColor: theme.inlineCodeColor,
                MDAttr.inlineCode: true])
        case let link as Markdown.Link:
            let inner = inlineString(link, font: font, color: theme.linkColor)
            let m = NSMutableAttributedString(attributedString: inner)
            let full = NSRange(location: 0, length: m.length)
            m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: full)
            if let dest = link.destination, dest.hasPrefix("#") {
                // In-document anchor (TOC). URL(string:) rejects non-ASCII fragments (Korean), so
                // store the raw slug and use a placeholder link the click handler recognizes.
                m.addAttribute(MDAttr.anchor, value: String(dest.dropFirst()), range: full)
                m.addAttribute(.link, value: URL(string: "fmdanchor:jump")!, range: full)
            } else if let dest = link.destination, let url = URL(string: dest) {
                m.addAttribute(.link, value: url, range: full)
            }
            return m
        case let sc as InlineHTML:
            // Inline <img …> becomes an image (with optional width); other inline HTML is text.
            if let tag = parseImgTag(sc.rawHTML) {
                return imageString(source: tag.src, alt: tag.alt, widthPts: tag.pts, widthPct: tag.pct)
            }
            return NSAttributedString(string: sc.rawHTML, attributes: [.font: font, .foregroundColor: color])
        case is LineBreak:
            // Hard break (two trailing spaces or a backslash) → a real line break within the block.
            return NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color])
        case is SoftBreak:
            // Soft break (a plain source newline) → a space, so the paragraph reflows.
            return NSAttributedString(string: " ", attributes: [.font: font, .foregroundColor: color])
        default:
            return inlineString(markup, font: font, color: color)
        }
    }

    // Readability (research-backed: Butterick / Baymard / WCAG 1.4.12): line height 1.45×,
    // paragraph spacing ~12pt. Column width + margins are handled by the window controller
    // (centered ~660pt measure). Styles are immutable and value-independent of the theme, so
    // they are built ONCE and reused across every block/render (per-block allocation made a
    // 4000-paragraph doc render 6× slower — this keeps it fast).
    mutating func visitHeading(_ heading: Heading) {
        let font = theme.headingFont(level: heading.level)
        let start = result.length
        result.append(inlineString(heading, font: font, color: theme.textColor))
        // Tag the heading run (C5 / spec §5): heading jump offsets are derived by
        // scanning this attribute on the live text — never a stored offsets array.
        result.addAttribute(MDAttr.heading, value: heading.level,
                            range: NSRange(location: start, length: result.length - start))
        newline(1)
        // Tight heading leading (1.25×) with a roomy space-before and small space-after so the
        // heading bonds to the text below it. All scaled to the font size.
        let b = theme.baseFontSize
        let ps = mdPara(lineHeight: theme.headingSize(level: heading.level) * 1.25,
                        spacingAfter: b * 0.4,
                        spacingBefore: b * (heading.level <= 2 ? 1.9 : 1.4))
        result.addAttribute(.paragraphStyle, value: ps,
                            range: NSRange(location: start, length: result.length - start))
        tagBlock(from: start, src: heading.range)
    }

    /// Find every `$$ … $$` span in the RAW source, before markdown ever sees it.
    ///
    /// `$$` is not markdown, so the parser reads a formula's insides as markdown and mangles them:
    /// a lone `=` line under a matrix makes the line above a setext HEADING, `_` becomes emphasis,
    /// `*` opens a list. By the time we hold the tree the formula is shredded across several nodes,
    /// and no node-level test can put it back together — claiming the span from the source first is
    /// the only order that works. (Measured: `\begin{pmatrix} … \\ = \\ … \end{pmatrix}` arrived as
    /// a heading plus a paragraph, and rendered as a giant title.)
    private static func scanMathSpans(_ source: String, lineStarts: [Int]) -> [(range: NSRange, tex: String)] {
        let ns = source as NSString
        var out: [(range: NSRange, tex: String)] = []
        var openLine: Int?
        for i in 0..<lineStarts.count {
            let start = lineStarts[i]
            let end = (i + 1 < lineStarts.count) ? lineStarts[i + 1] - 1 : ns.length
            guard end >= start else { continue }
            let line = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            if let open = openLine {                       // inside a fence: look for its close
                guard line == "$$" else { continue }
                let from = lineStarts[open]
                let texStart = lineStarts[open + 1]
                let tex = ns.substring(with: NSRange(location: texStart, length: max(0, start - texStart)))
                out.append((NSRange(location: from, length: end - from),
                            tex.trimmingCharacters(in: .whitespacesAndNewlines)))
                openLine = nil
                continue
            }
            if line == "$$" {
                if i + 1 < lineStarts.count { openLine = i }   // an unterminated `$$` stays plain text
                continue
            }
            // One-liner: `$$ x = 1 $$`. Two formulas on one line are left to the text path rather
            // than merged into one bogus render.
            if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 {
                let inner = String(line.dropFirst(2).dropLast(2))
                guard !inner.contains("$$") else { continue }
                out.append((NSRange(location: start, length: end - start),
                            inner.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return out.filter { !$0.tex.isEmpty }
    }

    /// The span this block was made from, if the block lies ENTIRELY inside one. Containment, not
    /// overlap: the Document (and any list/quote wrapping a formula) merely overlaps, so it keeps
    /// descending until it reaches the nodes the formula itself produced.
    private func mathSpan(containing r: NSRange) -> (range: NSRange, tex: String)? {
        mathSpans.first { $0.range.location <= r.location &&
                          r.location + r.length <= $0.range.location + $0.range.length }
    }

    /// Every block goes through here, so a formula is caught wherever the parser put its pieces —
    /// top level, or nested in a list or quote.
    mutating func visit(_ markup: Markup) {
        if let so = sourceOffsets(markup.range), let span = mathSpan(containing: so) {
            // All the nodes of one span collapse into a single formula; emit on the first, drop the
            // rest, and never descend into them — they're fragments of TeX, not text.
            if emittedMath.insert(span.range.location).inserted {
                appendWebBlock(.math, code: span.tex, srcOffsets: span.range, size: NSSize(width: 260, height: 60))
            }
            return
        }
        markup.accept(&self)
    }

    /// The placeholder for a block WebKit will draw later (mermaid diagram, TeX formula). A real
    /// attachment from the start, so the lazy media manager treats it exactly like an image (load
    /// when on-screen, drop when far) and the size/pixel split holds. The reserved size here is only
    /// a guess; the up-front measure pass replaces it with the exact one before layout.
    mutating func appendWebBlock(_ engine: WebBlock.Engine, code: String, srcOffsets: NSRange?, size: NSSize) {
        let blockStart = result.length
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: size)
        att.attachmentCell = SizedAttachmentCell(reservedSize: size)   // owns size when image==nil
        let ph = NSMutableAttributedString(attachment: att)
        ph.addAttribute(engine.attribute, value: code, range: NSRange(location: 0, length: ph.length))
        result.append(ph); newline(2)
        tagBlock(from: blockStart, srcOffsets: srcOffsets)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        let start = result.length
        result.append(inlineString(paragraph, font: theme.bodyFont, color: theme.textColor))
        newline(1)
        result.addAttribute(.paragraphStyle, value: containsImage(paragraph) ? imagePS : bodyPS,
                            range: NSRange(location: start, length: result.length - start))
        tagBlock(from: start, src: paragraph.range)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Only a block-level <img> is rendered (as an image); other raw HTML blocks are skipped.
        guard let tag = parseImgTag(html.rawHTML) else { return }
        let start = result.length
        let s = imageString(source: tag.src, alt: tag.alt, widthPts: tag.pts, widthPct: tag.pct)
        s.addAttribute(.paragraphStyle, value: imagePS, range: NSRange(location: 0, length: s.length))
        result.append(s); newline(1)
        tagBlock(from: start, src: html.range)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let start = result.length
        descendInto(blockQuote)
        // A nested code block ends with newline(2), leaving an empty QUOTED line below it (the
        // quote bar would extend past the content). Collapse trailing blank lines to a single \n.
        let ns = result.mutableString
        while result.length > start + 1,
              ns.substring(with: NSRange(location: result.length - 1, length: 1)) == "\n",
              ns.substring(with: NSRange(location: result.length - 2, length: 1)) == "\n" {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        let range = NSRange(location: start, length: result.length - start)
        if range.length > 0 {
            // Apply the quote paragraph style + muted color ONLY to the quote's own prose —
            // a nested code block keeps its own card paragraph style and syntax colors instead
            // of being flattened to grey indented text.
            let codeIndent = theme.baseFontSize   // shift nested code right to sit inside the quote
            result.enumerateAttribute(MDAttr.codeBlock, in: range) { code, sub, _ in
                if code == nil {
                    result.addAttributes([.paragraphStyle: quotePS, .foregroundColor: theme.secondaryColor], range: sub)
                } else {
                    // Nested code keeps its card style but is indented to align with the quote.
                    result.addAttribute(MDAttr.codeInset, value: NSNumber(value: Double(codeIndent)), range: sub)
                    result.enumerateAttribute(.paragraphStyle, in: sub, options: []) { psv, s2, _ in
                        guard let psv = psv as? NSParagraphStyle,
                              let mm = psv.mutableCopy() as? NSMutableParagraphStyle else { return }
                        mm.headIndent += codeIndent
                        mm.firstLineHeadIndent += codeIndent
                        result.addAttribute(.paragraphStyle, value: mm, range: s2)
                    }
                }
            }
            result.addAttribute(MDAttr.blockQuote, value: true, range: range)   // bar spans the whole quote
        }
        tagBlock(from: start, src: blockQuote.range)   // overwrites inner ids: the quote is one block
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        let start = result.length
        renderList(Array(list.listItems), ordered: false, depth: 0)
        newline()
        tagBlock(from: start, src: list.range)
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        let start = result.length
        renderList(Array(list.listItems), ordered: true, depth: 0)
        newline()
        tagBlock(from: start, src: list.range)
    }

    /// Render list items at a given nesting `depth`. Each level indents one step further, so
    /// 2nd/3rd/4th-level bullets sit progressively inside. A list item's own text is rendered and
    /// styled first; nested child lists then recurse at depth+1 (they carry their own indent, so
    /// the parent's paragraph style is applied ONLY to the item's own line — not over the nested
    /// range, which would flatten it).
    private mutating func renderList(_ items: [ListItem], ordered: Bool, depth: Int) {
        let hang = theme.baseFontSize * 1.7                     // one indent step
        let markerX = CGFloat(depth) * hang                     // where the bullet / number sits
        let textX = CGFloat(depth + 1) * hang                   // where the text (and wraps) align
        let ps = listPara(markerX: markerX, textX: textX)
        var i = 1
        for item in items {
            let s = result.length
            let marker = ordered ? "\(i).\t" : bullet(depth) + "\t"
            result.append(NSAttributedString(string: marker,
                attributes: [.font: theme.bodyFont, .foregroundColor: theme.textColor]))
            // The item's own paragraph text (skip nested lists — handled after, at depth+1).
            for child in item.children where !(child is UnorderedList || child is OrderedList) {
                renderBlockInline(child)
            }
            newline()
            result.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: s, length: result.length - s))
            // Nested lists follow the item's line, indented one level deeper.
            for child in item.children {
                if let ul = child as? UnorderedList { renderList(Array(ul.listItems), ordered: false, depth: depth + 1) }
                else if let ol = child as? OrderedList { renderList(Array(ol.listItems), ordered: true, depth: depth + 1) }
            }
            i += 1
        }
    }

    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat).
    private func bullet(_ depth: Int) -> String {
        switch depth % 3 {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }

    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    private func listPara(markerX: CGFloat, textX: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * 1.45).rounded()
        p.minimumLineHeight = lh; p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * 0.3
        p.firstLineHeadIndent = markerX
        p.headIndent = textX
        p.tabStops = [NSTextTab(textAlignment: .left, location: textX)]
        p.defaultTabInterval = textX
        return p.copy() as! NSParagraphStyle
    }

    // List items contain paragraphs; render their inline content without extra blank lines.
    private mutating func renderBlockInline(_ markup: Markup) {
        if let p = markup as? Paragraph {
            result.append(inlineString(p, font: theme.bodyFont, color: theme.textColor))
        } else {
            result.append(inlineString(markup, font: theme.bodyFont, color: theme.textColor))
        }
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let blockStart = result.length
        // Fences WebKit draws instead of highlighting; everything else is a highlighted code card.
        switch (codeBlock.language ?? "").lowercased() {
        case "mermaid":
            appendWebBlock(.mermaid, code: codeBlock.code, srcOffsets: sourceOffsets(codeBlock.range),
                           size: NSSize(width: 480, height: 360))
            return
        case "math", "tex", "latex":
            // GitHub's ```math fence. A fence's content is verbatim, so unlike `$$…$$` there's no
            // emphasis to dodge — the parser hands over exactly what was typed.
            appendWebBlock(.math, code: codeBlock.code, srcOffsets: sourceOffsets(codeBlock.range),
                           size: NSSize(width: 260, height: 60))
            return
        default:
            break
        }
        // Card look: padding inside (head/tail indent) and gaps outside (paragraph spacing).
        // No flat .backgroundColor — CodeCardLayoutManager draws the rounded card backdrop.
        // Slightly open code leading — a bit more air between lines than a raw terminal.
        let codeLH = (theme.codeFont.pointSize * 1.4).rounded()
        // The block is TWO paragraphs: a blank HEADER line (reserves room for the Copy / Wrap
        // buttons) and the CODE. Splitting them lets paragraphSpacingBefore on the code add a
        // real gap BELOW the buttons — a single \u{2028}-joined paragraph could not.
        let headerPS = NSMutableParagraphStyle()
        headerPS.headIndent = CodeCardMetrics.textInset
        headerPS.firstLineHeadIndent = CodeCardMetrics.textInset
        headerPS.tailIndent = -CodeCardMetrics.textInset
        headerPS.paragraphSpacingBefore = CodeCardMetrics.verticalPadding + 6   // outer gap above the card
        headerPS.minimumLineHeight = codeLH; headerPS.maximumLineHeight = codeLH

        let ps = NSMutableParagraphStyle()
        ps.headIndent = CodeCardMetrics.textInset
        ps.firstLineHeadIndent = CodeCardMetrics.textInset
        ps.tailIndent = -CodeCardMetrics.textInset
        ps.paragraphSpacingBefore = 9   // breathing room UNDER the header buttons / divider
        ps.paragraphSpacing = CodeCardMetrics.verticalPadding + 6   // outer gap below the card
        ps.minimumLineHeight = codeLH; ps.maximumLineHeight = codeLH
        ps.lineBreakMode = .byCharWrapping   // default: fold long lines (toggle to no-wrap per block)
        // Trailing newlines would render as empty lines inside the card (a 1–2 line gap at the
        // bottom). Drop them so the card hugs the last line of code.
        var code = codeBlock.code
        while code.hasSuffix("\n") || code.hasSuffix("\r") { code.removeLast() }
        // Header = ZWSP + a REAL newline so it is its own paragraph (2 chars — placeCopyButtons
        // skips them via location+2). The code that follows is ONE paragraph whose lines are
        // joined by U+2028, so no per-line paragraph spacing loosens the code.
        let highlighted = NSMutableAttributedString(string: "\u{200B}\n",
            attributes: [.font: theme.codeFont, .foregroundColor: theme.textColor])
        let codeAttr = NSMutableAttributedString(attributedString:
            CodeHighlighter.highlight(code, language: codeBlock.language, theme: theme))
        codeAttr.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [],
            range: NSRange(location: 0, length: codeAttr.length))
        highlighted.append(codeAttr)
        let full = NSRange(location: 0, length: highlighted.length)
        highlighted.addAttribute(.paragraphStyle, value: headerPS, range: NSRange(location: 0, length: 2))
        highlighted.addAttribute(.paragraphStyle, value: ps,
            range: NSRange(location: 2, length: highlighted.length - 2))
        // Tag the block (C5: MDAttr, not a literal) with the code + its language so the
        // copy overlay and the no-wrap toggle can rebuild it.
        highlighted.addAttribute(MDAttr.codeBlock, value: code, range: full)
        highlighted.addAttribute(MDAttr.codeLang, value: codeBlock.language ?? "", range: full)
        result.append(highlighted)
        newline(2)
        tagBlock(from: blockStart, src: codeBlock.range)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        // A zero-width line the layout manager paints as a full-width hairline.
        let start = result.length
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 10; p.paragraphSpacingBefore = 10
        result.append(NSAttributedString(string: "\u{200B}",
            attributes: [.font: theme.bodyFont, MDAttr.rule: true, .paragraphStyle: p]))
        newline(1)
        tagBlock(from: start, src: thematicBreak.range)
    }

    mutating func visitTable(_ table: Markdown.Table) {
        let start = result.length
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows.map { Array($0.cells) })
        let ncol = max(headerCells.count, bodyRows.map(\.count).max() ?? 0)
        guard ncol > 0 else { newline(); tagBlock(from: start, src: table.range); return }

        // Real bordered grid via the shared `TableBlockBuilder` (also used by office tables) —
        // replaces the old monospaced "|"-joined text that wrapped into mush. Cell content is
        // rendered inline here so `code`, **bold**, and links work inside cells; the builder only
        // lays already-styled strings into `NSTextTableBlock` cells.
        // GFM tables never merge cells, so every cell is its own anchor with rowSpan/columnSpan 1
        // — `TableBlockBuilder.CellContent`'s defaults, unmentioned here.
        func renderRow(_ cells: [Markdown.Table.Cell], header: Bool) -> [TableBlockBuilder.CellContent] {
            let font = header ? NSFont.systemFont(ofSize: theme.baseFontSize, weight: .semibold) : theme.bodyFont
            return cells.map { .init(content: inlineString($0, font: font, color: theme.textColor)) }
        }
        var rows = [renderRow(headerCells, header: true)]
        rows.append(contentsOf: bodyRows.map { renderRow($0, header: false) })
        result.append(TableBlockBuilder.build(rows: rows, headerRows: 1, theme: theme))
        newline()
        tagBlock(from: start, src: table.range)
    }
}
