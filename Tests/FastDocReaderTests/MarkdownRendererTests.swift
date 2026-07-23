import XCTest
import AppKit
@testable import FastDocReader

final class MarkdownRendererTests: XCTestCase {
    private func render(_ md: String) -> NSAttributedString {
        MarkdownRenderer.render(md, theme: .current(size: 14))
    }

    func testHeadingIsBoldAndLarger() {
        let s = render("# Title")
        XCTAssertTrue(s.string.contains("Title"))
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font!.pointSize, 14) // heading > base
    }

    func testEmphasisAndStrong() {
        let s = render("normal *em* **strong**")
        XCTAssertTrue(s.string.contains("em"))
        XCTAssertTrue(s.string.contains("strong"))
    }

    func testInlineCodeUsesMonospace() {
        let s = render("use `code` here")
        let idx = s.string.range(of: "code")!
        let offset = s.string.distance(from: s.string.startIndex, to: idx.lowerBound)
        let font = s.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testUnorderedListRendersBullets() {
        let s = render("- one\n- two")
        XCTAssertTrue(s.string.contains("one"))
        XCTAssertTrue(s.string.contains("two"))
    }

    func testGFMTableRendersAllCells() {
        let s = render("| A | B |\n|---|---|\n| 1 | 2 |")
        // Cells are REAL document text now (an `NSTextTable`), so they live in the top-level string —
        // which is exactly why they became selectable, copyable and searchable.
        for cell in ["A", "B", "1", "2"] {
            XCTAssertTrue(s.string.contains(cell), "missing \(cell)")
        }
    }

    /// One `(block, cellText)` per table-cell paragraph — every cell is a paragraph whose style carries
    /// its `NSTextTableBlock`. Office and markdown tables share the identical builder, so they're
    /// inspected the same way.
    private func tableBlocks(in out: NSAttributedString) -> [(block: NSTextTableBlock, text: String)] {
        var found: [(NSTextTableBlock, String)] = []
        let ns = out.string as NSString
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let ps = value as? NSParagraphStyle, let block = ps.textBlocks.first as? NSTextTableBlock else { return }
            found.append((block, ns.substring(with: range)))
        }
        return found
    }
    private func firstGridTable(in out: NSAttributedString) -> GridTextTable? {
        tableBlocks(in: out).compactMap { $0.block.table as? GridTextTable }.first
    }

    /// Characterizes the real bordered `NSTextTable` grid `MarkdownRenderer.visitTable` produces via
    /// `TableBlockBuilder` — office and markdown tables share the identical builder.
    func testGFMTableUsesRealTextTableWithBorderAndHeaderShading() {
        let s = render("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        let blocks = tableBlocks(in: s)
        // 2 header cells + 2 body rows * 2 cells = 6 placed cells total.
        XCTAssertEqual(blocks.count, 6)
        // They all belong to ONE table (a real grid, not per-cell islands).
        XCTAssertEqual(Set(blocks.map { ObjectIdentifier($0.block.table) }).count, 1)
        // Exactly the 2 header cells (row 0) are shaded — headerRows defaults to 1 for markdown.
        XCTAssertEqual(blocks.filter { $0.block.startingRow == 0 && $0.block.backgroundColor != nil }.count, 2)
        // Every cell carries a border.
        for (block, _) in blocks { XCTAssertGreaterThan(block.width(for: .border, edge: .minX), 0) }
        // Row placement is exact: header at row 0, body at rows 1 and 2.
        XCTAssertEqual(Set(blocks.filter { $0.block.startingRow == 0 }.map { $0.block.startingColumn }), [0, 1])
        XCTAssertEqual(Set(blocks.filter { $0.block.startingRow != 0 }.map { $0.block.startingRow }), [1, 2])
    }

    /// A markdown table has no source grid, so its columns are an EQUAL share — every entry in the
    /// table's stored proportions is `1 / ncol` (fed as absolute integer widths, not percentages).
    func testGFMTableColumnsAreEqualProportions() {
        let s = render("| A | B |\n|---|---|\n| 1 | 2 |")
        let table = try! XCTUnwrap(firstGridTable(in: s))
        XCTAssertEqual(table.columnProportions.count, 2)
        for p in table.columnProportions { XCTAssertEqual(p, 0.5, accuracy: 0.001) }
    }

    func testHeadingIsTaggedWithMDAttr() {
        // Contract for keyboard heading-jump (C5): every heading run carries MDAttr.heading.
        let s = render("# One\n\nbody\n\n## Two")
        var found: [Int] = []
        s.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let level = v as? Int { found.append(level) }
        }
        XCTAssertEqual(found, [1, 2])
    }

    /// A `// comment` inside code matched the file-path pattern (space, slash, slash) and became a
    /// folder shortcut that opened Finder. Code is shown, not offered as navigation.
    func testCodeBlockSlashesAreNotFilePathLinks() {
        let md = """
        Open ./notes/readme.md for context.

        ```go
        func main() {
        	u := "https://ww-w.ai" // the // here is a comment
        }
        ```
        """
        let s = MarkdownRenderer.render(md, theme: RenderTheme.current(size: 14))
        let text = s.string as NSString
        var linkedPaths: [String] = []
        s.enumerateAttribute(MDAttr.filePath, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if v != nil { linkedPaths.append(text.substring(with: r)) }
        }
        // The prose path still links; nothing from inside the fence does.
        XCTAssertTrue(linkedPaths.contains("./notes/readme.md"), "prose path stopped linking: \(linkedPaths)")
        XCTAssertFalse(linkedPaths.contains(where: { $0.hasPrefix("//") }), "code comment linked: \(linkedPaths)")
    }

    /// A URL in code must keep its syntax colour: link styling is painted after highlighting, so
    /// linking it would repaint the string blue and underline it mid-code.
    func testURLsInCodeAreNotLinked() {
        let md = """
        Visit https://ww-w.ai for the app.

        ```go
        u := "https://ww-w.ai/fast-markdown-reader"
        ```

        Inline `https://ww-w.ai/inline` stays code too.
        """
        let s = MarkdownRenderer.render(md, theme: RenderTheme.current(size: 14))
        let text = s.string as NSString
        var linked: [String] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if v != nil { linked.append(text.substring(with: r)) }
        }
        XCTAssertTrue(linked.contains("https://ww-w.ai"), "prose URL stopped linking: \(linked)")
        XCTAssertFalse(linked.contains(where: { $0.contains("fast-markdown-reader") }), "code URL linked: \(linked)")
        XCTAssertFalse(linked.contains(where: { $0.contains("inline") }), "inline-code URL linked: \(linked)")
    }

    /// Relative markdown links are how every README points at its neighbours. They are neither
    /// file: nor http: URLs, and handing one to NSWorkspace asks macOS to open "demo/x.md" as a web
    /// address — which is the error the reader used to show. The renderer must keep them intact for
    /// the click handler to resolve against the document's folder.
    func testRelativeLinksSurviveAsSchemelessURLs() {
        let md = "See [the demo](demo/code-blocks.md) and [the site](https://ww-w.ai)."
        let s = MarkdownRenderer.render(md, theme: RenderTheme.current(size: 14))
        let text = s.string as NSString
        var byLabel: [String: URL] = [:]
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let u = v as? URL { byLabel[text.substring(with: r)] = u }
        }
        XCTAssertEqual(byLabel["the demo"]?.scheme, nil)                       // relative: resolved on click
        XCTAssertEqual(byLabel["the demo"]?.relativePath, "demo/code-blocks.md")
        XCTAssertEqual(byLabel["the site"]?.scheme, "https")                   // absolute: still the browser
    }
}
