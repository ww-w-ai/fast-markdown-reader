import AppKit

/// Renders a NON-markdown text file (.txt, .csv, .log, …) verbatim. Nothing is parsed, so `#`,
/// `*`, `|` and `_` stay on screen exactly as they sit in the file — a plain text file that
/// happens to contain markdown punctuation must not silently turn into headings and italics.
///
/// Monospaced, because the files that land here (csv rows, logs, fixed-width tables) are written
/// expecting a fixed grid; a proportional font would break the only structure they have.
///
/// Each NON-BLANK source line is tagged as one block, with the same two attributes the markdown
/// renderer emits — `MDAttr.blockId` (a stop for the reading cursor / gutter click) and
/// `MDAttr.srcRange` (its exact span in the file). That is the whole integration: block edit,
/// add, delete and move are written against those attributes, so they work here for free.
/// A blank line is deliberately left untagged — it is a separator, not something to step onto,
/// and leaving it out lets a move swap two real lines across it without disturbing the gap.
enum PlainTextRenderer {
    static func render(_ source: String, theme: RenderTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: theme.baseFontSize * 0.95, weight: .regular)
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.0
        ps.minimumLineHeight = (theme.baseFontSize * 1.45).rounded()
        // Wrapped continuation lines are indented so a long csv row still reads as ONE row.
        ps.headIndent = theme.baseFontSize * 1.5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: theme.textColor, .paragraphStyle: ps,
        ]

        let ns = source as NSString
        var blockSeq = 0
        var lineStart = 0
        while lineStart < ns.length {
            // `end` is where the next line begins; `contentsEnd` excludes this line's terminator.
            var end = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let renderStart = out.length
            // The line INCLUDING its terminator, so the rendered string equals the file exactly —
            // dropping a trailing newline here would silently lose it on the next save.
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: lineStart, length: end - lineStart)),
                                          attributes: attrs))
            let contentLength = contentsEnd - lineStart
            if contentLength > 0 {
                // Tag the CONTENT only; the terminator is a separator, like the blank line between
                // two markdown blocks, and belongs to no block.
                let r = NSRange(location: renderStart, length: contentLength)
                out.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
                out.addAttribute(MDAttr.srcRange,
                                 value: NSValue(range: NSRange(location: lineStart, length: contentLength)),
                                 range: r)
                blockSeq += 1
            }
            lineStart = end
        }
        return out
    }
}
