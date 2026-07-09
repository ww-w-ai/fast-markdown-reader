import XCTest
import AppKit
@testable import FastMDReader

/// Verifies the block → markdown-source mapping (MDAttr.srcRange) that block-level editing relies
/// on: a rendered block's srcRange must point at the exact source lines of that block, so an edit
/// replaces the right span. The mapping is line-based, so it must be correct for CJK too.
final class SourceRangeTests: XCTestCase {

    /// For every rendered block, the source substring at its srcRange must equal the original
    /// markdown line(s) that produced it.
    private func srcForBlock(containing needle: String, in md: String) -> String? {
        let s = MarkdownRenderer.render(md, theme: .current(size: 14))
        let ns = s.string as NSString
        let hit = ns.range(of: needle)
        guard hit.location != NSNotFound,
              let val = s.attribute(MDAttr.srcRange, at: hit.location, effectiveRange: nil) as? NSValue
        else { return nil }
        return (md as NSString).substring(with: val.rangeValue)
    }

    func testParagraphMapsToItsSourceLine() {
        let md = "# Title\n\nFirst paragraph here.\n\nSecond paragraph.\n"
        XCTAssertEqual(srcForBlock(containing: "First paragraph", in: md), "First paragraph here.")
        XCTAssertEqual(srcForBlock(containing: "Second paragraph", in: md), "Second paragraph.")
    }

    func testHeadingMapsToItsSourceLine() {
        let md = "# Title\n\nBody.\n"
        XCTAssertEqual(srcForBlock(containing: "Title", in: md), "# Title")
    }

    func testKoreanParagraphMapsCorrectly() {
        // Line-based mapping must be immune to CJK column-width issues.
        let md = "앞 문단입니다.\n\n한글과 English가 섞인 문단.\n\n마지막 문단.\n"
        XCTAssertEqual(srcForBlock(containing: "English가", in: md), "한글과 English가 섞인 문단.")
        XCTAssertEqual(srcForBlock(containing: "마지막", in: md), "마지막 문단.")
    }

    func testMultiLineBlockCoversAllItsLines() {
        let md = "Intro.\n\n- item one\n- item two\n- item three\n\nOutro.\n"
        XCTAssertEqual(srcForBlock(containing: "item two", in: md), "- item one\n- item two\n- item three")
    }

    func testCodeBlockMapsToFullFence() {
        let md = "Text.\n\n```swift\nlet x = 1\nprint(x)\n```\n\nAfter.\n"
        XCTAssertEqual(srcForBlock(containing: "let x", in: md), "```swift\nlet x = 1\nprint(x)\n```")
    }
}
