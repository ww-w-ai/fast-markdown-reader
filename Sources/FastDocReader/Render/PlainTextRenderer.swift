import AppKit

/// Renders a NON-markdown text file (.txt, .csv, .log, …) verbatim. Nothing is parsed, so `#`,
/// `*`, `|` and `_` stay on screen exactly as they sit in the file — a plain text file that
/// happens to contain markdown punctuation must not silently turn into headings and italics.
///
/// Monospaced, because the files that land here (csv rows, logs, fixed-width tables) are written
/// expecting a fixed grid; a proportional font would break the only structure they have.
///
/// EVERY source line is one block — blank lines included — tagged with the same two attributes the
/// markdown renderer emits: `MDAttr.blockId` (a stop for the reading cursor / gutter click) and
/// `MDAttr.srcRange` (its exact span in the file). That is the whole integration: block edit, add,
/// delete and move are written against those attributes, so they work here for free.
///
/// Counting blank lines as blocks is what makes this a TEXT file rather than a prose document, and
/// it fixes two things at once: a blank line can be selected and deleted like any other line, and
/// "add below" inserts exactly one new line instead of copying the gap around the block — in
/// markdown a blank line separates paragraphs, but here it is simply an empty line the author put
/// there, and the app has no business preserving or reproducing it as structure.
///
/// A block's RENDERED range includes the line's terminator (so a blank line, which has no
/// characters of its own, still has something to be), while its SOURCE range covers only the line's
/// text — that keeps a replacement from swallowing the newline that separates it from the next line.
enum PlainTextRenderer {
    static func render(_ source: String, theme: RenderTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = PlainTextStyle(theme: theme)
        let font = NSFont.monospacedSystemFont(ofSize: theme.baseFontSize * style.monoSizeRatio, weight: .regular)
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.0
        ps.minimumLineHeight = (theme.baseFontSize * theme.lineHeightRatio).rounded()
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
            // Tag the whole line INCLUDING its terminator: an empty line has no characters of its
            // own, and a zero-length attribute range is no range at all — it would vanish, taking
            // the blank line's existence as a block with it.
            let r = NSRange(location: renderStart, length: out.length - renderStart)
            if r.length > 0 {
                out.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
                // The SOURCE range stays content-only, so replacing a line can't eat the newline
                // that separates it from the next one.
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
