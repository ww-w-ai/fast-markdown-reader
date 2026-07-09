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

    mutating func visitHeading(_ heading: Heading) {
        let size = theme.headingSize(level: heading.level)
        let font = NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .boldFontMask)
        let start = result.length
        result.append(inlineString(heading, font: font, color: theme.textColor))
        // Tag the heading run (C5 / spec §5): heading jump offsets are derived by
        // scanning this attribute on the live text — never a stored offsets array.
        result.addAttribute(MDAttr.heading, value: heading.level,
                            range: NSRange(location: start, length: result.length - start))
        newline(2)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result.append(inlineString(paragraph, font: theme.bodyFont, color: theme.textColor))
        newline(2)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        let start = result.length
        descendInto(blockQuote)
        let range = NSRange(location: start, length: result.length - start)
        if range.length > 0 {
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 16; ps.firstLineHeadIndent = 16
            result.addAttributes([.paragraphStyle: ps, .foregroundColor: theme.secondaryColor], range: range)
        }
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        for item in list.listItems {
            result.append(NSAttributedString(string: "•  ", attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor]))
            for child in item.children { renderBlockInline(child) }
            newline()
        }
        newline()
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        var i = 1
        for item in list.listItems {
            result.append(NSAttributedString(string: "\(i).  ", attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondaryColor]))
            for child in item.children { renderBlockInline(child) }
            newline(); i += 1
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
