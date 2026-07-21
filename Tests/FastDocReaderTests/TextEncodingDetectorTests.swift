import XCTest
@testable import FastDocReader

/// The files a reader gets handed come from Windows and Linux too. Each case here is a file shape
/// that used to arrive as a wall of replacement characters, plus the round-trip that keeps an edit
/// from converting someone's file behind their back.
final class TextEncodingDetectorTests: XCTestCase {
    private let korean = "안녕하세요\n국민은행 통화 기록"
    private let mixed = "Hello 안녕 123\nsecond line"

    private func roundTrip(_ text: String, encoding: String.Encoding, bom: Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        var data = text.data(using: encoding, allowLossyConversion: false)!
        if bom {
            let marks: [String.Encoding: [UInt8]] = [
                .utf8: [0xEF, 0xBB, 0xBF], .utf16LittleEndian: [0xFF, 0xFE],
                .utf16BigEndian: [0xFE, 0xFF],
            ]
            data = Data(marks[encoding]!) + data
        }
        let decoded = TextEncodingDetector.decode(data)
        XCTAssertEqual(decoded.text, text, "decoded text", file: file, line: line)
        XCTAssertEqual(decoded.encoding, encoding, "encoding", file: file, line: line)
        XCTAssertEqual(decoded.hasBOM, bom, "BOM", file: file, line: line)
        // Re-encoding an unchanged file must reproduce the original bytes exactly.
        XCTAssertEqual(TextEncodingDetector.encode(decoded.text, like: decoded), data,
                       "re-encoded bytes", file: file, line: line)
    }

    func testUTF8() { roundTrip(korean, encoding: .utf8, bom: false) }
    func testUTF8WithBOM() { roundTrip(korean, encoding: .utf8, bom: true) }
    func testUTF16LittleEndianWithBOM() { roundTrip(korean, encoding: .utf16LittleEndian, bom: true) }
    func testUTF16BigEndianWithBOM() { roundTrip(korean, encoding: .utf16BigEndian, bom: true) }

    /// The original report: a Windows-made Korean .txt shown as "???m???@2".
    func testCP949Korean() {
        let data = korean.data(using: TextEncodingDetector.cp949, allowLossyConversion: false)!
        let decoded = TextEncodingDetector.decode(data)
        XCTAssertEqual(decoded.text, korean)
        XCTAssertEqual(decoded.encoding, TextEncodingDetector.cp949)
        XCTAssertFalse(decoded.text.contains("\u{FFFD}"), "no replacement characters")
        XCTAssertEqual(TextEncodingDetector.encode(decoded.text, like: decoded), data)
    }

    func testUTF16LittleEndianWithoutBOM() {
        let data = mixed.data(using: .utf16LittleEndian, allowLossyConversion: false)!
        let decoded = TextEncodingDetector.decode(data)
        XCTAssertEqual(decoded.text, mixed)
        XCTAssertEqual(decoded.encoding, .utf16LittleEndian)
    }

    /// Plain ASCII is valid UTF-8 and must be read as UTF-8 — never guessed into a legacy encoding.
    func testASCIIStaysUTF8() {
        let decoded = TextEncodingDetector.decode(Data("plain,ascii,csv\n1,2,3".utf8))
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertFalse(decoded.hasBOM)
    }

    /// Windows line endings survive the trip; the block operations carry separators along verbatim,
    /// so a CRLF file must not come back as LF.
    func testCRLFIsPreserved() {
        let crlf = "a,1\r\nb,2\r\n"
        let decoded = TextEncodingDetector.decode(Data(crlf.utf8))
        XCTAssertEqual(decoded.text, crlf)
        XCTAssertEqual(TextEncodingDetector.encode(decoded.text, like: decoded), Data(crlf.utf8))
    }

    func testEmptyFile() {
        let decoded = TextEncodingDetector.decode(Data())
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(TextEncodingDetector.encode("", like: decoded), Data())
    }

    /// Undecodable bytes must still round-trip, so an edit elsewhere in the file can't corrupt them.
    func testArbitraryBytesRoundTrip() {
        let data = Data((0...255).map(UInt8.init))
        let decoded = TextEncodingDetector.decode(data)
        XCTAssertEqual(TextEncodingDetector.encode(decoded.text, like: decoded), data)
    }

    /// A character the file's encoding can't hold must be REFUSED, not written as "?" — the save
    /// path turns this nil into an explanation instead of a silently mangled file.
    func testRefusesLossyEncoding() {
        let latin1 = TextFile(text: "café", encoding: .isoLatin1, hasBOM: false)
        XCTAssertNil(TextEncodingDetector.encode("café 안녕", like: latin1))
        XCTAssertNotNil(TextEncodingDetector.encode("café only", like: latin1))
    }
}
