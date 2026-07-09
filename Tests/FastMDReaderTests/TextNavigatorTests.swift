import XCTest
@testable import FastMDReader

final class TextNavigatorTests: XCTestCase {
    let nav = TextNavigator()
    // "abc\ndef ghi. jkl mno\n\npqr"
    let s = "abc\ndef ghi. jkl mno\n\npqr"

    func testLineStartAndEnd() {
        XCTAssertEqual(nav.lineStart(s, from: 6), 4)          // after first \n
        XCTAssertEqual(nav.lineEnd(s, from: 6), 20)           // before the \n at index 20
    }

    func testLineBoundaryStepsToAdjacentLineAtEdge() {
        XCTAssertEqual(nav.previousLineBoundary(s, from: 4), 0)   // at line start → previous line start
        // At the def-line's end (\n at 20), one more step → the next (empty) line's end = 21.
        // (Plan wrote 22, inconsistent with its own algorithm; 21 is correct.)
        XCTAssertEqual(nav.nextLineBoundary(s, from: 20), 21)
    }

    func testSentenceStart() {
        XCTAssertEqual(nav.sentenceStart(s, from: 15), 13)
        // 13 is itself a sentence start → jump to the previous sentence start. The prior
        // sentence ("abc\ndef ghi.") starts at 0, not 4. (Plan wrote 4; 0 is correct.)
        XCTAssertEqual(nav.sentenceStart(s, from: 13), 0)
        XCTAssertEqual(nav.nextSentenceStart(s, from: 4), 13)
    }

    func testParagraphStart() {
        XCTAssertEqual(nav.paragraphStart(s, from: 10), 0)      // first paragraph
        XCTAssertEqual(nav.nextParagraphStart(s, from: 0), 22)  // after blank line
        XCTAssertEqual(nav.paragraphStart(s, from: 22), 0)      // already at start → previous paragraph
    }

    // C1: navigator must operate in UTF-16 offsets (NSString), matching NSTextView/NSRange.
    // With an emoji (a UTF-16 surrogate pair) present, a Character-index implementation would
    // drift after the emoji and land inside or past the pair. Assert exact UTF-16 offsets.
    func testNonASCIIUsesUTF16Offsets() {
        // 가 나 . ␠ 다 라 ␠ 😀(2 units) ␠ 마 바 . \n
        // idx: 0 1  2 3  4  5 6  7,8   9 10 11 12 13   length=14
        let t = "가나. 다라 😀 마바.\n"
        XCTAssertEqual((t as NSString).length, 14)
        XCTAssertEqual(nav.lineEnd(t, from: 0), 13)             // the \n at UTF-16 index 13
        XCTAssertEqual(nav.nextSentenceStart(t, from: 0), 4)    // after "가나. "
        XCTAssertEqual(nav.sentenceStart(t, from: 4), 0)        // already a start → previous
        XCTAssertEqual(nav.sentenceStart(t, from: 9), 4)        // caret past the emoji lands on a valid boundary
    }

    func testUnitRangesForSelection() {
        // s = "abc\ndef ghi. jkl mno\n\npqr"
        XCTAssertEqual(nav.lineRange(s, from: 6), NSRange(location: 4, length: 16))   // "def ghi. jkl mno"
        XCTAssertEqual(nav.sentenceRange(s, from: 6), NSRange(location: 0, length: 12)) // "abc\ndef ghi." (trailing space trimmed)
        XCTAssertEqual(nav.paragraphRange(s, from: 10), NSRange(location: 0, length: 20)) // para 1, blank line trimmed
        XCTAssertEqual(nav.paragraphRange(s, from: 22), NSRange(location: 22, length: 3)) // "pqr"
    }

    func testUnitRangesNonASCII() {
        let t = "가나. 다라 😀 마바.\n"   // len 14 (see UTF-16 test above)
        // sentence containing index 9 (past emoji) = "다라 😀 마바." starting at 4
        let r = nav.sentenceRange(t, from: 9)
        XCTAssertEqual(r.location, 4)
        XCTAssertEqual(r.location + r.length, 13) // ends at the period (before \n), trimmed
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(nav.lineEnd(s, from: 9999), (s as NSString).length)
        XCTAssertEqual(nav.lineStart(s, from: -5), 0)
    }
}
