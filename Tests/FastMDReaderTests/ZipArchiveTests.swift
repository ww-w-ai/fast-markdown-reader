import XCTest
import Compression
@testable import FastMDReader

/// `ZipArchive` is pure: build the container's bytes by hand, hand them to it, and assert on what
/// comes back — no fixture files on disk, no window, no document (same shape as `BlockEditTests`).
final class ZipArchiveTests: XCTestCase {
    // MARK: Fixture construction — a real ZIP, byte-for-byte, built in memory

    private struct FixtureEntry {
        let name: String
        let method: UInt16 // 0 = stored, 8 = deflated
        let content: Data
        var extraLocal: Data = Data()
        var extraCentral: Data = Data()
        var generalPurposeBitFlag: UInt16 = 0
        /// When set, the CENTRAL DIRECTORY's uncompressed-size field lies — it is emitted instead of
        /// `content.count`, while the local header keeps the true value (`ZipArchive` never reads the
        /// local header's uncompressed size, so only the central directory's number is under test).
        var declaredUncompressedSizeOverride: UInt32?
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Raw DEFLATE (not zlib-wrapped) — `COMPRESSION_ZLIB` in Apple's Compression framework, on
    /// both the encode and decode side, is the raw format ZIP stores.
    private func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = [UInt8](repeating: 0, count: data.count + 256)
        let count = output.withUnsafeMutableBufferPointer { dest -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dest.baseAddress!, dest.count,
                                           src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                           nil, COMPRESSION_ZLIB)
            }
        }
        precondition(count > 0, "test fixture failed to deflate")
        return Data(output.prefix(count))
    }

    /// Emits a local file header per entry, then a central-directory entry mirroring each one, then
    /// the End Of Central Directory record that anchors both — the exact three record types
    /// `ZipArchive` reads.
    private func buildZip(_ entries: [FixtureEntry]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let payload: Data; let localOffset: Int }

        var body = [UInt8]()
        var prepared: [Prepared] = []
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let payload = entry.method == 8 ? deflate(entry.content) : entry.content
            let localOffset = body.count
            body += le32(0x0403_4b50)                             // local file header signature
            body += le16(20)                                      // version needed to extract
            body += le16(entry.generalPurposeBitFlag)
            body += le16(entry.method)
            body += le16(0) + le16(0)                             // mod time, mod date
            body += le32(0)                                       // crc-32 (unused by ZipArchive)
            body += le32(UInt32(payload.count))                   // compressed size
            body += le32(UInt32(entry.content.count))              // uncompressed size
            body += le16(UInt16(nameBytes.count))
            body += le16(UInt16(entry.extraLocal.count))
            body += nameBytes
            body += Array(entry.extraLocal)
            body += Array(payload)
            prepared.append(Prepared(nameBytes: nameBytes, payload: payload, localOffset: localOffset))
        }

        var centralDirectory = [UInt8]()
        for (i, entry) in entries.enumerated() {
            let p = prepared[i]
            centralDirectory += le32(0x0201_4b50)                 // central directory signature
            centralDirectory += le16(20) + le16(20)                // version made by, version needed
            centralDirectory += le16(entry.generalPurposeBitFlag)
            centralDirectory += le16(entry.method)
            centralDirectory += le16(0) + le16(0)                 // mod time, mod date
            centralDirectory += le32(0)                           // crc-32
            centralDirectory += le32(UInt32(p.payload.count))
            centralDirectory += le32(entry.declaredUncompressedSizeOverride ?? UInt32(entry.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(UInt16(entry.extraCentral.count))
            centralDirectory += le16(0)                           // file comment length
            centralDirectory += le16(0)                           // disk number start
            centralDirectory += le16(0)                           // internal attributes
            centralDirectory += le32(0)                           // external attributes
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
            centralDirectory += Array(entry.extraCentral)
        }

        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)                              // end of central directory signature
        archive += le16(0) + le16(0)                              // disk number, disk with CD start
        archive += le16(UInt16(entries.count))                    // records on this disk
        archive += le16(UInt16(entries.count))                    // total records
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)                                        // comment length
        return Data(archive)
    }

    // MARK: entryNames / contains

    func testEntryNamesListsExactlyTheArchivesNamesInOrder() throws {
        let zip = buildZip([
            FixtureEntry(name: "a.txt", method: 0, content: Data("a".utf8)),
            FixtureEntry(name: "b/c.txt", method: 0, content: Data("c".utf8)),
            FixtureEntry(name: "d.txt", method: 0, content: Data("d".utf8)),
        ])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(archive.entryNames, ["a.txt", "b/c.txt", "d.txt"])
    }

    func testContainsIsTrueForAPresentNameAndFalseOtherwise() throws {
        let zip = buildZip([FixtureEntry(name: "present.txt", method: 0, content: Data("x".utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertTrue(archive.contains("present.txt"))
        XCTAssertFalse(archive.contains("absent.txt"))
    }

    // MARK: Round trips

    func testStoredEntryRoundTripsByteIdentical() throws {
        let content = Data("hello, stored world".utf8)
        let zip = buildZip([FixtureEntry(name: "stored.txt", method: 0, content: content)])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(try archive.data(for: "stored.txt"), content)
    }

    func testDeflatedEntryRoundTripsByteIdentical() throws {
        let content = Data(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 50).utf8)
        let zip = buildZip([FixtureEntry(name: "deflated.txt", method: 8, content: content)])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(try archive.data(for: "deflated.txt"), content)
    }

    /// Sizing the inflate destination from a hardcoded constant instead of the central directory's
    /// declared uncompressed size is a classic bug this catches: anything over 64KB would be silently
    /// cut off.
    func testDeflatedEntryLargerThan64KBRoundTripsByteIdentical() throws {
        var text = ""
        for i in 0..<3000 { text += "line \(i): the quick brown fox jumps over the lazy dog.\n" }
        let content = Data(text.utf8)
        XCTAssertGreaterThan(content.count, 65536)
        let zip = buildZip([FixtureEntry(name: "big.txt", method: 8, content: content)])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(try archive.data(for: "big.txt"), content)
    }

    /// The central directory's extra-field length is allowed to differ from the local header's (some
    /// writers pad the local one for alignment); reading must follow the LOCAL header's own length,
    /// not the central directory's.
    func testEntryWhoseLocalExtraFieldLengthDiffersFromCentralsStillReadsCorrectly() throws {
        let content = Data("padded local header".utf8)
        let entry = FixtureEntry(name: "padded.txt", method: 0, content: content,
                                 extraLocal: Data([0xAA, 0xBB, 0xCC, 0xDD]), extraCentral: Data())
        let zip = buildZip([entry])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(try archive.data(for: "padded.txt"), content)
    }

    // MARK: init(url:)

    func testInitFromURLDelegatesToInitFromData() throws {
        let content = Data("from disk".utf8)
        let zip = buildZip([FixtureEntry(name: "only.txt", method: 0, content: content)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ziparchive-test-\(UUID().uuidString).zip")
        try zip.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try ZipArchive(url: url)
        XCTAssertEqual(try archive.data(for: "only.txt"), content)
    }

    // MARK: Distinct thrown errors

    func testUnsupportedCompressionMethodThrows() throws {
        let zip = buildZip([FixtureEntry(name: "weird.bin", method: 99, content: Data("x".utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(for: "weird.bin")) { error in
            XCTAssertEqual(error as? ZipArchive.Error, .unsupportedCompressionMethod(99))
        }
    }

    func testEncryptedEntryThrows() throws {
        var entry = FixtureEntry(name: "secret.txt", method: 0, content: Data("shh".utf8))
        entry.generalPurposeBitFlag = 0x1 // bit 0 = encrypted
        let zip = buildZip([entry])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(for: "secret.txt")) { error in
            XCTAssertEqual(error as? ZipArchive.Error, .encryptedEntry("secret.txt"))
        }
    }

    /// The cap is checked before the compressed bytes are even sliced out, so this archive's payload
    /// can be one byte — if the check allocated anything from the declared size first, this would
    /// hang or balloon memory instead of failing immediately. `UInt32.max` (0xFFFFFFFF) is deliberately
    /// NOT used here — that exact value is the Zip64 "look elsewhere" sentinel and is correctly refused
    /// as `.zip64Unsupported` at parse time, before this per-read cap even runs.
    func testDeclaredUncompressedSizeAboveCapThrowsWithoutAllocating() throws {
        let absurd: UInt32 = 2_000_000_000 // ~1.9 GiB, well past the cap, nowhere near the zip64 sentinel
        let entry = FixtureEntry(name: "huge.bin", method: 0, content: Data([0x01]),
                                 declaredUncompressedSizeOverride: absurd)
        let zip = buildZip([entry])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(for: "huge.bin")) { error in
            XCTAssertEqual(error as? ZipArchive.Error,
                           .entryTooLarge(declared: Int(absurd), cap: ZipArchive.maxEntryUncompressedSize))
        }
    }

    /// The opposite lie from `testDeflatedEntryLargerThan64KBRoundTripsByteIdentical`'s bug class: a
    /// declared size SMALLER than what the stream actually inflates to. `compression_decode_buffer`
    /// alone can't tell "the stream ended exactly here" from "the buffer ran out first" — silently
    /// accepting the short buffer would hand back a truncated prefix as if it were the whole entry.
    func testDeclaredUncompressedSizeSmallerThanActualThrowsInsteadOfTruncating() throws {
        let trueContent = Data(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 60).utf8)
        let entry = FixtureEntry(name: "lied-small.txt", method: 8, content: trueContent,
                                 declaredUncompressedSizeOverride: 50)
        let zip = buildZip([entry])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(for: "lied-small.txt")) { error in
            XCTAssertEqual(error as? ZipArchive.Error, .corruptEntry("lied-small.txt"))
        }
    }

    /// A hand-crafted EOCD (not derived from `buildZip`) that is internally consistent — its
    /// comment-length field lands exactly on the data's end, so it IS found — but whose central
    /// directory offset points past the data actually present.
    func testTruncatedDataThrows() {
        var bytes = [UInt8]()
        bytes += le32(0x0605_4b50)   // EOCD signature
        bytes += le16(0) + le16(0)   // disk number, disk with CD start
        bytes += le16(1) + le16(1)   // records on this disk, total records
        bytes += le32(46)            // central directory size (plausible for one bare entry)
        bytes += le32(1000)          // central directory offset — beyond this 22-byte blob
        bytes += le16(0)             // comment length
        XCTAssertEqual(bytes.count, 22)
        XCTAssertThrowsError(try ZipArchive(data: Data(bytes))) { error in
            XCTAssertEqual(error as? ZipArchive.Error, .truncated)
        }
    }

    func testMissingEndOfCentralDirectoryThrows() {
        let garbage = Data(repeating: 0x41, count: 200) // no EOCD signature anywhere in here
        XCTAssertThrowsError(try ZipArchive(data: garbage)) { error in
            XCTAssertEqual(error as? ZipArchive.Error, .missingEndOfCentralDirectory)
        }
    }

    func testUnknownNameThrows() throws {
        let zip = buildZip([FixtureEntry(name: "known.txt", method: 0, content: Data("k".utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try archive.data(for: "unknown.txt")) { error in
            XCTAssertEqual(error as? ZipArchive.Error, .entryNotFound("unknown.txt"))
        }
    }
}
