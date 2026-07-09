import XCTest
import AppKit
@testable import FastMDReader

/// The whole point of this viewer is staying light and opening long documents fast.
/// These guard that the pure render path scales and stays correct at size.
final class LargeDocumentTests: XCTestCase {
    private func bigMarkdown(paragraphs: Int) -> String {
        var s = ""
        for i in 0..<paragraphs {
            if i % 20 == 0 { s += "# Section \(i / 20)\n\n" }
            s += "Paragraph \(i) with *emphasis*, **strong**, and `code`. More text here.\n\n"
            if i % 50 == 0 { s += "```swift\nlet x\(i) = \(i)\n```\n\n" }
        }
        return s
    }

    func testLargeDocumentRendersFullyAndFast() {
        let md = bigMarkdown(paragraphs: 4000)   // ~ a very long document
        let start = Date()
        let out = MarkdownRenderer.render(md, theme: .current(size: 15))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(out.length, md.count / 2)         // produced real content
        XCTAssertTrue(out.string.contains("Section 199"))       // reached the end (no truncation)
        XCTAssertLessThan(elapsed, 5.0, "render took \(elapsed)s — too slow for a long doc")
    }

    func testHeadingTagsScaleForJumpNavigation() {
        let md = bigMarkdown(paragraphs: 2000)
        let out = MarkdownRenderer.render(md, theme: .current(size: 15))
        var headings = 0
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { v, _, _ in
            if v != nil { headings += 1 }
        }
        XCTAssertEqual(headings, 100) // 2000/20 sections, each tagged exactly once
    }
}
