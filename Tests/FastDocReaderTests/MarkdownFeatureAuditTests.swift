import XCTest
import AppKit
@testable import FastDocReader

/// Full-coverage audit of CommonMark + GFM inline/block features through the REAL render path
/// (`MarkdownRenderer.render`), not a grep of the visitor. Behaviour wins over structure
/// (CLAUDE.md invariant 34): each feature is rendered and its evidence attribute is asserted, so a
/// silently-unhandled feature (how strikethrough shipped dead) fails here instead of on screen.
/// Every assertion doubles as the regression guard invariant 30 asks for.
final class MarkdownFeatureAuditTests: XCTestCase {
    private func render(_ md: String) -> NSAttributedString {
        MarkdownRenderer.render(md, theme: .current(size: 14))
    }

    // MARK: - helpers (all offsets in UTF-16 via NSString, matching attribute indexing)

    private func attr(_ s: NSAttributedString, _ key: NSAttributedString.Key, on sub: String) -> Any? {
        let ns = s.string as NSString
        let r = ns.range(of: sub)
        guard r.location != NSNotFound else { return nil }
        return s.attribute(key, at: r.location, effectiveRange: nil)
    }

    private func font(_ s: NSAttributedString, on sub: String) -> NSFont? {
        attr(s, .font, on: sub) as? NSFont
    }

    private func attrAnywhere(_ s: NSAttributedString, _ key: NSAttributedString.Key) -> Bool {
        var found = false
        s.enumerateAttribute(key, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private func hasTableAttachment(_ s: NSAttributedString) -> Bool {
        var found = false
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, stop in
            if let ps = v as? NSParagraphStyle, ps.textBlocks.first is NSTextTableBlock {
                found = true; stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Inline

    func testEmphasisIsItalic() {
        XCTAssertTrue(font(render("a *em* b"), on: "em")!.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testStrongIsBold() {
        XCTAssertTrue(font(render("a **st** b"), on: "st")!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testNestedStrongEmphasisIsBoldAndItalic() {
        let t = font(render("a ***both*** b"), on: "both")!.fontDescriptor.symbolicTraits
        XCTAssertTrue(t.contains(.bold) && t.contains(.italic), "***x*** must be both bold and italic")
    }

    func testInlineCodeIsMonospace() {
        XCTAssertTrue(font(render("a `code` b"), on: "code")!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testStrikethroughIsStruckThrough() {
        let s = render("a ~~gone~~ b")
        XCTAssertTrue(s.string.contains("gone"), "strikethrough text must survive")
        let v = attr(s, .strikethroughStyle, on: "gone") as? Int ?? 0
        XCTAssertNotEqual(v, 0, "~~gone~~ must carry a strikethrough style attribute")
    }

    func testMarkdownLinkIsLinked() {
        XCTAssertTrue(attr(render("see [site](https://ww-w.ai) now"), .link, on: "site") != nil)
    }

    func testBareURLIsAutolinked() {
        XCTAssertTrue(attr(render("visit https://ww-w.ai today"), .link, on: "https://ww-w.ai") != nil)
    }

    func testAngleAutolinkIsLinked() {
        XCTAssertTrue(attr(render("mail <https://ww-w.ai> here"), .link, on: "https://ww-w.ai") != nil)
    }

    func testImageProducesImageAttr() {
        XCTAssertTrue(attrAnywhere(render("![alt](pic.png)"), MDAttr.image), "image must tag MDAttr.image")
    }

    // MARK: - Block

    func testHeadingTagged() {
        XCTAssertTrue(attrAnywhere(render("# Title"), MDAttr.heading))
    }

    func testSetextHeadingTagged() {
        XCTAssertTrue(attrAnywhere(render("Title\n=====\n\nbody"), MDAttr.heading), "setext (===) heading must tag")
    }

    func testBlockquoteTagged() {
        XCTAssertTrue(attrAnywhere(render("> quoted"), MDAttr.blockQuote))
    }

    func testCodeBlockTagged() {
        XCTAssertTrue(attrAnywhere(render("```\ncode\n```"), MDAttr.codeBlock))
    }

    func testThematicBreakTagged() {
        XCTAssertTrue(attrAnywhere(render("a\n\n---\n\nb"), MDAttr.rule))
    }

    func testOrderedListMarker() {
        XCTAssertTrue(render("1. one\n2. two").string.contains("1."))
    }

    func testUnorderedListMarker() {
        XCTAssertTrue(render("- one\n- two").string.contains("•"))
    }

    func testTaskListShowsCheckboxes() {
        let s = render("- [ ] todo\n- [x] done")
        XCTAssertTrue(s.string.contains("todo") && s.string.contains("done"), "task text must survive")
        XCTAssertTrue(s.string.contains("☐"), "an unchecked task must render an empty checkbox ☐")
        XCTAssertTrue(s.string.contains("☑"), "a checked task must render a ticked checkbox ☑")
    }

    func testTableRendersAsRealTextTable() {
        // Tables are a real `NSTextTable` (invariant 39, revised): cell text is real document text —
        // selectable, copyable, searchable — carried in `NSTextTableBlock` paragraphs, not a drawing.
        let s = render("| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(hasTableAttachment(s), "a GFM table must render as a real NSTextTable")
        XCTAssertTrue(s.string.contains("A") && s.string.contains("2"),
                      "cell text must be real document text, not locked inside a drawn attachment")
    }

    func testHardLineBreakStaysInParagraph() {
        // Two trailing spaces = a hard break: one paragraph, but a newline inside it.
        let s = render("line one  \nline two")
        XCTAssertTrue(s.string.contains("line one\nline two"), "hard break must place a newline within the block")
    }
}

extension MarkdownFeatureAuditTests {
    /// Footnotes are NOT yet rendered as footnotes: swift-markdown does not parse `[^id]`, so the
    /// marker stays literal and the definition renders as an ordinary paragraph. This test
    /// CHARACTERIZES that limitation (content is preserved, not dropped) so it is visible and so the
    /// day a real footnote engine lands — source-scanned like `scanMathSpans`, with superscript refs
    /// and a collected section — this test is the thing that flips. README must not claim footnotes
    /// until then. (Found during the markdown-feature audit; strikethrough + task lists were the
    /// two GFM features that shipped dead and are now fixed.)
    func testFootnotesAreNotYetRenderedButContentSurvives() {
        let s = MarkdownRenderer.render("Body.[^1]\n\n[^1]: The note.", theme: .current(size: 14))
        XCTAssertTrue(s.string.contains("[^1]"), "not-yet-supported: the marker is still literal")
        XCTAssertTrue(s.string.contains("The note."), "the definition text is preserved, never dropped")
    }
}
