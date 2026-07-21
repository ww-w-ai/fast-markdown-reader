import Foundation

/// Pure source-range arithmetic behind the block operations (add / delete / move). No views, no
/// document — it takes the block spans and the source text and returns ONE (range, replacement)
/// pair, which the caller hands to `MarkdownDocument.applySourceEdit`. Everything therefore rides
/// the single existing write path, so file persistence, re-render and undo come for free and no
/// operation can half-apply.
///
/// A "block span" is the source range the renderer already tagged onto the rendered text
/// (`MDAttr.srcRange`) — whole lines, trailing newlines excluded. The text BETWEEN two spans (the
/// "gap": one or two newlines, maybe trailing spaces) is never rewritten, only carried along, so
/// a document keeps its own separator style instead of being normalised behind the user's back.
enum BlockEdit {
    /// Every block's source span, in document order, de-duplicated. One rendered block carries the
    /// attribute across all of its glyphs, so runs of the same span collapse to one entry.
    static func spans(in storage: NSAttributedString) -> [NSRange] {
        var out: [NSRange] = []
        let whole = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(MDAttr.srcRange, in: whole) { value, _, _ in
            guard let r = (value as? NSValue)?.rangeValue else { return }
            if let last = out.last, last.location == r.location, last.length == r.length { return }
            out.append(r)
        }
        // Rendered order usually matches source order, but a renderer is free to emit otherwise;
        // sort so "previous / next block" always means previous / next IN THE FILE.
        out.sort { $0.location < $1.location }
        return out
    }

    /// The index of the block containing (or, failing that, nearest above) a source offset.
    static func indexOfBlock(containing offset: Int, in spans: [NSRange]) -> Int? {
        for (i, s) in spans.enumerated() where offset >= s.location && offset <= s.location + s.length {
            return i
        }
        return spans.lastIndex { $0.location <= offset }
    }

    /// The separator to reuse when inserting next to block `i` — literally the gap that already
    /// follows it (or, for the last block, the one before it). A one-newline document stays
    /// one-newline; a blank-line-separated one stays blank-line-separated.
    static func separator(around i: Int, spans: [NSRange], text: NSString,
                          fallback: String) -> String {
        func gap(_ a: Int, _ b: Int) -> String? {
            guard a >= 0, b < spans.count else { return nil }
            let from = spans[a].location + spans[a].length
            let to = spans[b].location
            guard to > from else { return nil }
            let g = text.substring(with: NSRange(location: from, length: to - from))
            return g.contains("\n") ? g : nil
        }
        return gap(i, i + 1) ?? gap(i - 1, i) ?? fallback
    }

    /// Insert a new block immediately AFTER block `i`.
    ///
    /// `fixedSeparator` overrides the copy-the-neighbouring-gap rule. A text file wants it: there,
    /// a block is a LINE, so adding below means adding the next line — copying the gap would
    /// reproduce a blank line the author happened to leave above, turning their spacing into
    /// structure. Markdown passes nil and keeps the document's own paragraph spacing.
    static func insertion(after i: Int, spans: [NSRange], text: NSString,
                          newSource: String, fallbackSeparator: String,
                          fixedSeparator: String? = nil) -> (NSRange, String)? {
        guard spans.indices.contains(i) else { return nil }
        let sep = fixedSeparator
            ?? separator(around: i, spans: spans, text: text, fallback: fallbackSeparator)
        let at = spans[i].location + spans[i].length
        return (NSRange(location: at, length: 0), sep + newSource)
    }

    /// Delete block `i`, taking ONE separator with it so the deletion doesn't leave a widening
    /// hole behind. The trailing gap goes normally; for the last block the leading one goes
    /// instead, otherwise the file would end in the blank line that used to separate them.
    static func deletion(of i: Int, spans: [NSRange]) -> NSRange? {
        deletion(from: i, through: i, spans: spans)
    }

    /// Delete a RUN of blocks, `first` through `last` inclusive — what a selection spanning several
    /// blocks means. One range, so it is one undoable step rather than a pile of them, and the same
    /// separator rule applies at the ends as for a single block.
    static func deletion(from first: Int, through last: Int, spans: [NSRange]) -> NSRange? {
        guard spans.indices.contains(first), spans.indices.contains(last), first <= last else { return nil }
        if last + 1 < spans.count {
            return NSRange(location: spans[first].location, length: spans[last + 1].location - spans[first].location)
        }
        let end = spans[last].location + spans[last].length
        if first > 0 {
            let prevEnd = spans[first - 1].location + spans[first - 1].length
            return NSRange(location: prevEnd, length: end - prevEnd)
        }
        return NSRange(location: spans[first].location, length: end - spans[first].location)
    }

    /// Swap block `i` with the one after it. The gap between them stays exactly where it is, so
    /// the replacement is the same length as what it replaces — every offset outside this span
    /// (including the rest of the undo stack's view of the file) is untouched.
    static func swapWithNext(_ i: Int, spans: [NSRange], text: NSString) -> (NSRange, String)? {
        guard spans.indices.contains(i), spans.indices.contains(i + 1) else { return nil }
        let a = spans[i], b = spans[i + 1]
        let gapStart = a.location + a.length
        guard b.location >= gapStart else { return nil }
        let gap = text.substring(with: NSRange(location: gapStart, length: b.location - gapStart))
        let whole = NSRange(location: a.location, length: b.location + b.length - a.location)
        return (whole, text.substring(with: b) + gap + text.substring(with: a))
    }
}
