import XCTest
@testable import FastDocReader

/// P1 of the paragraph-format sprint: vocabulary only. These tests exist to pin down that the new
/// `ParagraphFormat`/`LineHeight` types behave as a plain, all-default-able value type and that
/// adding `format` to `.heading`/`.paragraph`/`.listItem` didn't change what an existing,
/// format-less construction means — NOT to test any reader or builder behaviour, since neither
/// populates or consumes this field yet (that's P2).
final class OfficeBlockParagraphFormatTests: XCTestCase {

    // MARK: ParagraphFormat defaults

    func testDefaultParagraphFormatHasAllFieldsNilOrFalse() {
        let format = ParagraphFormat()
        XCTAssertNil(format.spacingBefore)
        XCTAssertNil(format.spacingAfter)
        XCTAssertNil(format.lineHeight)
        XCTAssertNil(format.indentStart)
        XCTAssertNil(format.indentEnd)
        XCTAssertNil(format.firstLineIndent)
        XCTAssertNil(format.hangingIndent)
        XCTAssertFalse(format.contextualSpacing)
        XCTAssertNil(format.shading)
        XCTAssertNil(format.borderColor)
        XCTAssertNil(format.borderWidth)
    }

    // MARK: LineHeight equatability

    func testLineHeightCasesAreEquatable() {
        XCTAssertEqual(LineHeight.multiple(1.5), LineHeight.multiple(1.5))
        XCTAssertNotEqual(LineHeight.multiple(1.5), LineHeight.multiple(2.0))
        XCTAssertEqual(LineHeight.exact(12), LineHeight.exact(12))
        XCTAssertEqual(LineHeight.atLeast(10), LineHeight.atLeast(10))
        XCTAssertNotEqual(LineHeight.exact(12), LineHeight.atLeast(12))
        XCTAssertNotEqual(LineHeight.multiple(1.0), LineHeight.exact(1.0))
    }

    // MARK: A non-default format is a distinct block, an all-default one matches the format-less form

    func testBlockWithNonDefaultFormatIsNotEqualToDefaultFormatBlock() {
        let plain = OfficeBlock.paragraph(spans: [Span(text: "hi")])
        var customFormat = ParagraphFormat()
        customFormat.spacingBefore = 12
        let withFormat = OfficeBlock.paragraph(spans: [Span(text: "hi")], format: customFormat)
        XCTAssertNotEqual(plain, withFormat)
    }

    func testParagraphConstructedWithoutFormatEqualsOneConstructedWithExplicitDefaultFormat() {
        let implicit = OfficeBlock.paragraph(spans: [Span(text: "hi")])
        let explicit = OfficeBlock.paragraph(spans: [Span(text: "hi")], format: ParagraphFormat())
        XCTAssertEqual(implicit, explicit)
    }

    func testHeadingAndListItemAlsoDefaultFormatToEqualInstances() {
        let implicitHeading = OfficeBlock.heading(level: 1, spans: [Span(text: "H")])
        let explicitHeading = OfficeBlock.heading(level: 1, spans: [Span(text: "H")], format: ParagraphFormat())
        XCTAssertEqual(implicitHeading, explicitHeading)

        let implicitItem = OfficeBlock.listItem(level: 0, ordered: false, spans: [Span(text: "I")])
        let explicitItem = OfficeBlock.listItem(level: 0, ordered: false, spans: [Span(text: "I")],
                                                 format: ParagraphFormat())
        XCTAssertEqual(implicitItem, explicitItem)
    }

    // MARK: Round-trip — a non-default format survives construction/destructuring unchanged

    func testParagraphFormatRoundTripsThroughConstructionAndDestructuring() {
        var format = ParagraphFormat()
        format.spacingBefore = 6
        format.spacingAfter = 12
        format.lineHeight = .multiple(1.5)
        format.indentStart = 18
        format.indentEnd = 0
        format.firstLineIndent = 24
        format.hangingIndent = nil
        format.contextualSpacing = true
        format.shading = NSColor.yellow
        format.borderColor = NSColor.red
        format.borderWidth = 1.5

        let block = OfficeBlock.paragraph(spans: [Span(text: "x")], format: format)
        guard case .paragraph(_, _, _, _, let roundTripped) = block else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(roundTripped, format)
        XCTAssertEqual(roundTripped.spacingBefore, 6)
        XCTAssertEqual(roundTripped.spacingAfter, 12)
        XCTAssertEqual(roundTripped.lineHeight, .multiple(1.5))
        XCTAssertEqual(roundTripped.indentStart, 18)
        XCTAssertEqual(roundTripped.firstLineIndent, 24)
        XCTAssertNil(roundTripped.hangingIndent)
        XCTAssertTrue(roundTripped.contextualSpacing)
        XCTAssertEqual(roundTripped.shading, NSColor.yellow)
        XCTAssertEqual(roundTripped.borderColor, NSColor.red)
        XCTAssertEqual(roundTripped.borderWidth, 1.5)
    }

    // MARK: Behaviour-preservation proof — a default-format block still builds byte-identical output

    /// The builder ignores `format` entirely this sprint (P2 wires it) — proven here by rendering
    /// a block WITH an explicit non-default `ParagraphFormat` and confirming its text output is
    /// identical to the same block with no format at all, i.e. the field currently has zero
    /// influence on `OfficeTextBuilder`'s output.
    func testBuilderOutputIsUnaffectedByNonDefaultParagraphFormat() {
        var customFormat = ParagraphFormat()
        customFormat.spacingBefore = 40
        customFormat.shading = NSColor.blue
        customFormat.contextualSpacing = true

        let plainBlock = OfficeBlock.paragraph(spans: [Span(text: "Hello")])
        let formattedBlock = OfficeBlock.paragraph(spans: [Span(text: "Hello")], format: customFormat)

        let theme = RenderTheme.current(size: 16)
        let plainOutput = OfficeTextBuilder.build([plainBlock], theme: theme, columnWidth: 400)
        let formattedOutput = OfficeTextBuilder.build([formattedBlock], theme: theme, columnWidth: 400)

        XCTAssertEqual(plainOutput.string, formattedOutput.string)
        XCTAssertEqual(plainOutput.length, formattedOutput.length)
    }
}
