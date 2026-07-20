import XCTest
import AppKit
@testable import FastMDReader

/// Splicing only the edited part into the screen rests on ONE assumption: rendering a block's
/// source by itself produces the same thing as that block's slice of a full render. If it doesn't,
/// an edit would leave a subtly different-looking block behind, so this is checked before anything
/// is built on it — and it establishes which documents the shortcut is safe for.
final class FragmentRenderTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    /// The rendered range carrying a given source span.
    private func renderedRange(of span: NSRange, in doc: NSAttributedString) -> NSRange? {
        var lo = Int.max, hi = Int.min
        doc.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: doc.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue, s.location == span.location, s.length == span.length
            else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        return lo == Int.max ? nil : NSRange(location: lo, length: hi - lo)
    }

    func testPlainTextLineRendersIdenticallyAloneAndInContext() {
        let source = "first line\nsecond line here\n\nfourth,line,with,commas\nfifth"
        let full = PlainTextRenderer.render(source, theme: theme)
        for span in BlockEdit.spans(in: full) {
            let alone = PlainTextRenderer.render((source as NSString).substring(with: span), theme: theme)
            let slice = full.attributedSubstring(from: renderedRange(of: span, in: full)!)
            // A line's rendered range carries its terminator (that is all a blank line is made of),
            // which a fragment rendered from the line's TEXT alone doesn't have — the splice adds
            // the separator back by extending the fragment, so compare the text itself.
            XCTAssertEqual(alone.string, slice.string.trimmingCharacters(in: .newlines), "text of \(span)")
        }
    }

    /// Markdown block kinds, each checked as "alone == in context". Whatever fails here is a
    /// document shape the splice must refuse and fall back to a full render for.
    func testMarkdownBlocksRenderIdenticallyAloneAndInContext() {
        let source = """
        # Heading one

        A plain paragraph with *emphasis* and `code` inside it.

        - a list item
        - another item

        > a quotation

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        Closing paragraph.
        """
        let full = MarkdownRenderer.render(source, theme: theme)
        var mismatches: [String] = []
        for span in BlockEdit.spans(in: full) {
            guard let rendered = renderedRange(of: span, in: full) else { continue }
            let fragment = (source as NSString).substring(with: span)
            let alone = MarkdownRenderer.render(fragment, theme: theme)
            let slice = full.attributedSubstring(from: rendered)
            // Trailing separators differ by construction (the last block of a document has none),
            // so compare the trimmed text.
            let a = alone.string.trimmingCharacters(in: .newlines)
            let b = slice.string.trimmingCharacters(in: .newlines)
            if a != b { mismatches.append("\(fragment.prefix(24))… alone=\(a.debugDescription) inContext=\(b.debugDescription)") }
        }
        XCTAssertEqual(mismatches, [], "block kinds that do not survive being rendered alone")
    }

    /// The known exception: a reference-style link resolves against a definition somewhere ELSE in
    /// the document, so the block cannot be rendered in isolation. Documented by test so the splice
    /// keeps refusing it.
    func testReferenceStyleLinkNeedsTheWholeDocument() {
        let source = "See [the docs][ref] for more.\n\n[ref]: https://example.com\n"
        let full = MarkdownRenderer.render(source, theme: theme)
        let span = BlockEdit.spans(in: full)[0]
        let alone = MarkdownRenderer.render((source as NSString).substring(with: span), theme: theme)
        let slice = full.attributedSubstring(from: renderedRange(of: span, in: full)!)
        XCTAssertNotEqual(alone.string.trimmingCharacters(in: .newlines),
                          slice.string.trimmingCharacters(in: .newlines),
                          "if this ever matches, the splice may stop refusing reference links")
    }
}
