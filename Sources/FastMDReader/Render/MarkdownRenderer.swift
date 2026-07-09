import AppKit
import Markdown

enum MarkdownRenderer {
    static func render(_ markdown: String, theme: RenderTheme) -> NSAttributedString {
        let document = Document(parsing: markdown)
        var builder = AttributedBuilder(theme: theme)
        builder.visit(document)
        return builder.result
    }
}

private struct AttributedBuilder: MarkupWalker {
    let theme: RenderTheme
    var result = NSMutableAttributedString()

    init(theme: RenderTheme) { self.theme = theme }

    private func newline(_ count: Int = 1) {
        result.append(NSAttributedString(string: String(repeating: "\n", count: count)))
    }

    // Inline collection: render children into an attributed run with a base font.
    private func inlineString(_ markup: Markup, font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children {
            out.append(inlineFragment(child, font: font, color: color))
        }
        return out
    }

    private func inlineFragment(_ markup: Markup, font: NSFont, color: NSColor) -> NSAttributedString {
        switch markup {
        case let t as Text:
            return NSAttributedString(string: t.string, attributes: [.font: font, .foregroundColor: color])
        case let e as Emphasis:
            let f = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            return inlineString(e, font: f, color: color)
        case let s as Strong:
            let f = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            return inlineString(s, font: f, color: color)
        case let c as InlineCode:
            return NSAttributedString(string: c.code, attributes: [
                .font: theme.codeFont, .foregroundColor: color,
                .backgroundColor: theme.codeBackground])
        case let link as Markdown.Link:
            let inner = inlineString(link, font: font, color: .linkColor)
            let m = NSMutableAttributedString(attributedString: inner)
            if let dest = link.destination, let url = URL(string: dest) {
                m.addAttribute(.link, value: url, range: NSRange(location: 0, length: m.length))
            }
            return m
        case let sc as InlineHTML:
            return NSAttributedString(string: sc.rawHTML, attributes: [.font: font, .foregroundColor: color])
        case is LineBreak, is SoftBreak:
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
    private enum PS {
        static let body = make(spacing: 12)
        static let headingMajor = make(spacing: 6, before: 22)   // # / ##
        static let headingMinor = make(spacing: 6, before: 14)   // ### and deeper
        static let ul = make(spacing: 4, headIndent: 18)
        static let ol = make(spacing: 4, headIndent: 22)
        static let quote = make(spacing: 12, headIndent: 16, firstLineIndent: 16)

        static func make(spacing: CGFloat, before: CGFloat = 0,
                         headIndent: CGFloat = 0, firstLineIndent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.45
            p.paragraphSpacing = spacing
            p.paragraphSpacingBefore = before
            p.headIndent = headIndent
            p.firstLineHeadIndent = firstLineIndent
            return p.copy() as! NSParagraphStyle
        }
    }

    mutating func visitHeading(_ heading: Heading) {
        let size = theme.headingSize(level: heading.level)
        let font = NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .boldFontMask)
        let start = result.length
        result.append(inlineString(heading, font: font, color: theme.textColor))
        // Tag the heading run (C5 / spec §5): heading jump offsets are derived by
        // scanning this attribute on the live text — never a stored offsets array.
        result.addAttribute(MDAttr.heading, value: heading.level,
                            range: NSRange(location: start, length: result.length - start))
        newline(1)
        result.addAttribute(.paragraphStyle,
            value: heading.level <= 2 ? PS.headingMajor : PS.headingMinor,
            range: NSRange(location: start, length: result.length - start))
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        let start = result.length
        result.append(inlineString(paragraph, font: theme.bodyFont, color: theme.textColor))
        newline(1)
        result.addAttribute(.paragraphStyle, value: PS.body,
                            range: NSRange(location: start, length: result.length - start))
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let start = result.length
        descendInto(blockQuote)
        let range = NSRange(location: start, length: result.length - start)
        if range.length > 0 {
            result.addAttributes([.paragraphStyle: PS.quote, .foregroundColor: theme.secondaryColor], range: range)
        }
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        for item in list.listItems {
            let start = result.length
            result.append(NSAttributedString(string: "•  ", attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor]))
            for child in item.children { renderBlockInline(child) }
            newline()
            result.addAttribute(.paragraphStyle, value: PS.ul, range: NSRange(location: start, length: result.length - start))
        }
        newline()
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        var i = 1
        for item in list.listItems {
            let start = result.length
            result.append(NSAttributedString(string: "\(i).  ", attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor]))
            for child in item.children { renderBlockInline(child) }
            newline(); i += 1
            result.addAttribute(.paragraphStyle, value: PS.ol, range: NSRange(location: start, length: result.length - start))
        }
        newline()
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
        // mermaid handled in Task 5; here treat everything else as a highlighted block.
        if (codeBlock.language ?? "").lowercased() == "mermaid" {
            // Placeholder line the document layer replaces with a rendered PDF attachment.
            let ph = NSMutableAttributedString(string: "⧗ rendering diagram…",
                attributes: [.font: theme.codeFont, .foregroundColor: theme.secondaryColor])
            ph.addAttribute(MDAttr.mermaid, value: codeBlock.code,
                            range: NSRange(location: 0, length: ph.length))
            result.append(ph); newline(2)
            return
        }
        // Card look: padding inside (head/tail indent) and gaps outside (paragraph spacing).
        // No flat .backgroundColor — CodeCardLayoutManager draws the rounded card backdrop.
        let ps = NSMutableParagraphStyle()
        ps.headIndent = CodeCardMetrics.textInset
        ps.firstLineHeadIndent = CodeCardMetrics.textInset
        ps.tailIndent = -CodeCardMetrics.textInset
        ps.paragraphSpacingBefore = CodeCardMetrics.verticalPadding + 6
        ps.paragraphSpacing = CodeCardMetrics.verticalPadding + 6
        ps.lineSpacing = 2
        ps.lineBreakMode = .byCharWrapping   // fold long code lines instead of scrolling sideways
        let highlighted = NSMutableAttributedString(attributedString:
            CodeHighlighter.highlight(codeBlock.code, language: codeBlock.language, theme: theme))
        highlighted.addAttributes([.paragraphStyle: ps],
                                  range: NSRange(location: 0, length: highlighted.length))
        // Tag the block so the copy-button overlay can find it (C5: MDAttr, not a literal).
        highlighted.addAttribute(MDAttr.codeBlock, value: codeBlock.code,
                                 range: NSRange(location: 0, length: highlighted.length))
        result.append(highlighted)
        newline(2)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result.append(NSAttributedString(string: "─────────",
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor]))
        newline(2)
    }

    mutating func visitTable(_ table: Markdown.Table) {
        // Baseline text rendering; monospaced grid. Visual polish can come later.
        func renderRow(_ cells: [String]) {
            let line = cells.joined(separator: "  |  ")
            result.append(NSAttributedString(string: line, attributes: [.font: theme.codeFont, .foregroundColor: theme.textColor]))
            newline()
        }
        renderRow(table.head.cells.map { $0.plainText })
        for row in table.body.rows { renderRow(row.cells.map { $0.plainText }) }
        newline()
    }
}
