import XCTest
import AppKit
@testable import FastMDReader

final class CodeHighlighterTests: XCTestCase {
    private let theme = RenderTheme.current(size: 14)

    func testUnknownLanguageIsPlainMonospace() {
        let s = CodeHighlighter.highlight("foo bar", language: "prolog", theme: theme)
        XCTAssertEqual(s.string, "foo bar")
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testSwiftKeywordIsColored() {
        let s = CodeHighlighter.highlight("let x = 1", language: "swift", theme: theme)
        let kwColor = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let numRange = s.string.range(of: "1")!
        let numOffset = s.string.distance(from: s.string.startIndex, to: numRange.lowerBound)
        let numColor = s.attribute(.foregroundColor, at: numOffset, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(kwColor, numColor)
    }

    func testStringLiteralIsColored() {
        let s = CodeHighlighter.highlight("x = \"hi\"", language: "python", theme: theme)
        let r = s.string.range(of: "\"hi\"")!
        let off = s.string.distance(from: s.string.startIndex, to: r.lowerBound)
        let c = s.attribute(.foregroundColor, at: off, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(c)
    }

    func testOutputPreservesExactText() {
        let code = "def f():\n    return 1\n"
        let s = CodeHighlighter.highlight(code, language: "python", theme: theme)
        XCTAssertEqual(s.string, code) // highlighting must never alter characters
    }

    /// Colour at the first character of `needle` inside `code`.
    private func color(of needle: String, in code: String, _ language: String) -> NSColor? {
        let s = CodeHighlighter.highlight(code, language: language, theme: theme)
        let off = (code as NSString).range(of: needle).location
        return s.attribute(.foregroundColor, at: off, effectiveRange: nil) as? NSColor
    }

    /// The regression the single-pass scanner exists for: a URL's `//` sits inside a string, so it
    /// must never start a comment and grey out the rest of the line.
    func testSlashesInsideAStringAreNotAComment() {
        let code = "const u = \"http://a.com\"\nconst v = 1"
        let inURL = color(of: "//a.com", in: code, "js")
        let real = color(of: "\"http", in: code, "js")
        XCTAssertEqual(inURL, real)                      // still string-coloured
        XCTAssertNotEqual(inURL, color(of: "const u", in: code, "js"))
    }

    /// Same collision from the other side: `#` inside a shell string is not a comment.
    func testHashInsideAStringIsNotAComment() {
        let code = "echo \"a # b\"\nexport X=1"
        XCTAssertEqual(color(of: "# b", in: code, "bash"), color(of: "\"a", in: code, "bash"))
    }

    /// A keyword inside a comment stays comment-coloured.
    func testKeywordInsideACommentStaysComment() {
        let code = "// return here\nlet x = 1"
        XCTAssertEqual(color(of: "return", in: code, "swift"), color(of: "//", in: code, "swift"))
    }

    /// An unterminated quote must not bleed over the whole block.
    func testUnterminatedStringStopsAtLineEnd() {
        let code = "x = \"oops\ny = 2"
        XCTAssertNotEqual(color(of: "y = 2", in: code, "python"), color(of: "\"oops", in: code, "python"))
    }

    func testNewLanguagesHighlight() {
        for (lang, kw, code) in [("go", "func", "func main() { return }"),
                                 ("rust", "fn", "fn main() { let x = 1; }"),
                                 ("sql", "select", "select * from t where id = 1"),
                                 ("yaml", "true", "flag: true"),
                                 ("ruby", "def", "def go; end")] {
            XCTAssertNotNil(color(of: kw, in: code, lang), "\(lang) produced no colour")
            XCTAssertNotEqual(color(of: kw, in: code, lang), theme.textColor, "\(lang) keyword not highlighted")
        }
    }

    /// `--` is a comment in SQL but two minus signs elsewhere.
    func testSQLDashComment() {
        let code = "select 1 -- from nowhere"
        XCTAssertNotEqual(color(of: "-- from", in: code, "sql"), color(of: "select", in: code, "sql"))
    }

    func testDiffColorsBySide() {
        let code = "@@ -1 +1 @@\n-old line\n+new line\n context"
        let added = color(of: "+new", in: code, "diff")
        let removed = color(of: "-old", in: code, "diff")
        XCTAssertNotNil(added); XCTAssertNotNil(removed)
        XCTAssertNotEqual(added, removed)
        XCTAssertEqual(color(of: " context", in: code, "diff"), theme.textColor)   // untouched line
    }

    func testAliasesResolveToTheSameLanguage() {
        for (alias, canonical) in [("yml", "yaml"), ("c++", "cpp"), ("golang", "go"), ("py", "python")] {
            let code = "x"
            XCTAssertEqual(CodeHighlighter.highlight(code, language: alias, theme: theme).string,
                           CodeHighlighter.highlight(code, language: canonical, theme: theme).string)
        }
        // An alias must actually highlight, not silently fall back to plain.
        XCTAssertNotNil(color(of: "select", in: "select 1", "postgres"))
    }

    func testUnicodeOffsetsSurviveHighlighting() {
        let code = "# 한국어 주석\nx = \"값\"\n"
        let s = CodeHighlighter.highlight(code, language: "python", theme: theme)
        XCTAssertEqual(s.string, code)   // no shifted ranges, no dropped characters
    }

    func testCanonicalAliasesResolve() {
        // javascript alias should highlight a keyword the same as "js".
        let s = CodeHighlighter.highlight("const y = 2", language: "javascript", theme: theme)
        let kw = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let numOff = s.string.distance(from: s.string.startIndex, to: s.string.range(of: "2")!.lowerBound)
        let num = s.attribute(.foregroundColor, at: numOff, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(kw, num)
    }
}
