import Foundation
import Compression

/// A read-only ZIP container reader: parses just enough of the format to list and extract entries
/// by name, which is all `.docx`/`.xlsx`/`.pptx` need (they are ZIP containers holding XML parts).
/// No third-party dependency — the format needs exactly three record types, and this stays small
/// enough to read end to end: an End Of Central Directory record anchors a table of Central
/// Directory entries, each of which points at a Local File Header that precedes the entry's bytes.
///
/// A `struct`, not an `enum` namespace: parsing the central directory is real work (a corrupt or
/// Zip64 archive throws), so this holds the parsed table as state instead of re-deriving it per call.
struct ZipArchive {
    enum Error: Swift.Error, Equatable {
        /// No End Of Central Directory record found anywhere in the data — this isn't a ZIP file.
        case missingEndOfCentralDirectory
        /// A record's declared offset or length reaches past the end of the data.
        case truncated
        /// The archive (or one of its entries) uses Zip64 extensions, which this reader does not
        /// implement — refusing beats reading a 32-bit field that Zip64 repurposes as a "look
        /// elsewhere" sentinel (0xFFFF / 0xFFFFFFFF).
        case zip64Unsupported
        /// Only stored (0) and deflated (8) are implemented.
        case unsupportedCompressionMethod(UInt16)
        /// General-purpose bit 0 is set — the entry's bytes are encrypted, and this type has no way
        /// to ask for a password.
        case encryptedEntry(String)
        /// No entry with this name is in the central directory.
        case entryNotFound(String)
        /// Bytes were present where a record was expected but did not parse as a valid one.
        case corruptEntry(String)
        /// The entry's declared uncompressed size exceeds `maxEntryUncompressedSize` — refused
        /// before any buffer sized from that (untrusted) number is allocated.
        case entryTooLarge(declared: Int, cap: Int)
    }

    private struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let generalPurposeBitFlag: UInt16
    }

    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let zip64Sentinel16: UInt16 = 0xFFFF
    private static let zip64Sentinel32: UInt32 = 0xFFFF_FFFF
    /// 512 MiB — comfortably above any legitimate single part in a real `.docx`/`.xlsx`/`.pptx`
    /// (embedded media, a huge sheet), and a fixed ceiling on the allocation a declared-size lie can
    /// force. These files arrive as untrusted input (email attachments), so the declared size is
    /// checked against this BEFORE anything is allocated on its word.
    static let maxEntryUncompressedSize = 512 * 1024 * 1024

    private let data: Data
    private let entriesByName: [String: Entry]
    private let order: [String]

    /// The archive's entry names, in central-directory order (the order files were added — not
    /// necessarily alphabetical, and not required to match local-header order).
    var entryNames: [String] { order }

    init(data: Data) throws {
        self.data = data
        let eocdOffset = try ZipArchive.findEndOfCentralDirectory(in: data)
        let totalEntries = try data.readUInt16LE(at: eocdOffset + 10)
        let centralDirectorySize = try data.readUInt32LE(at: eocdOffset + 12)
        let centralDirectoryOffset = try data.readUInt32LE(at: eocdOffset + 16)
        guard totalEntries != ZipArchive.zip64Sentinel16,
              centralDirectorySize != ZipArchive.zip64Sentinel32,
              centralDirectoryOffset != ZipArchive.zip64Sentinel32 else {
            throw Error.zip64Unsupported
        }
        var byName: [String: Entry] = [:]
        var names: [String] = []
        var cursor = Int(centralDirectoryOffset)
        for _ in 0..<Int(totalEntries) {
            let entry = try ZipArchive.readCentralDirectoryEntry(in: data, at: &cursor)
            byName[entry.name] = entry
            names.append(entry.name)
        }
        entriesByName = byName
        order = names
    }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    func contains(_ name: String) -> Bool { entriesByName[name] != nil }

    func data(for name: String) throws -> Data {
        guard let entry = entriesByName[name] else { throw Error.entryNotFound(name) }
        guard entry.generalPurposeBitFlag & 0x1 == 0 else { throw Error.encryptedEntry(name) }
        // Checked BEFORE the compressed bytes are even sliced out: the declared size is the
        // attacker-controlled number every downstream allocation (inflate's destination buffer
        // above all) would otherwise be sized from.
        guard Int(entry.uncompressedSize) <= ZipArchive.maxEntryUncompressedSize else {
            throw Error.entryTooLarge(declared: Int(entry.uncompressedSize), cap: ZipArchive.maxEntryUncompressedSize)
        }
        let compressed = try ZipArchive.compressedBytes(in: data, for: entry)
        switch entry.compressionMethod {
        case 0:
            guard compressed.count == Int(entry.uncompressedSize) else { throw Error.corruptEntry(name) }
            return compressed
        case 8:
            return try ZipArchive.inflate(compressed, uncompressedSize: Int(entry.uncompressedSize), name: name)
        default:
            throw Error.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    // MARK: End Of Central Directory

    /// Scans BACKWARD for the EOCD signature because the record ends with a variable-length comment,
    /// so it is not at a fixed offset from the end of the file. A signature match only counts if the
    /// comment-length field it carries lands exactly on the true end of the data — otherwise it is a
    /// coincidental byte sequence (inside a comment or entry data) and the scan keeps going.
    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let recordSize = 22
        guard data.count >= recordSize else { throw Error.missingEndOfCentralDirectory }
        let maxCommentLength = 0xFFFF
        let floor = max(0, data.count - recordSize - maxCommentLength)
        var offset = data.count - recordSize
        while offset >= floor {
            if try data.readUInt32LE(at: offset) == endOfCentralDirectorySignature {
                let commentLength = try data.readUInt16LE(at: offset + 20)
                if offset + recordSize + Int(commentLength) == data.count { return offset }
            }
            offset -= 1
        }
        throw Error.missingEndOfCentralDirectory
    }

    // MARK: Central directory

    private static func readCentralDirectoryEntry(in data: Data, at cursor: inout Int) throws -> Entry {
        let start = cursor
        guard try data.readUInt32LE(at: start) == centralDirectorySignature else {
            throw Error.corruptEntry("central directory entry at offset \(start)")
        }
        let generalPurposeBitFlag = try data.readUInt16LE(at: start + 8)
        let compressionMethod = try data.readUInt16LE(at: start + 10)
        let compressedSize = try data.readUInt32LE(at: start + 20)
        let uncompressedSize = try data.readUInt32LE(at: start + 24)
        let nameLength = Int(try data.readUInt16LE(at: start + 28))
        let extraLength = Int(try data.readUInt16LE(at: start + 30))
        let commentLength = Int(try data.readUInt16LE(at: start + 32))
        let localHeaderOffset = try data.readUInt32LE(at: start + 42)
        let nameStart = start + 46
        guard nameStart + nameLength <= data.count else { throw Error.truncated }
        guard let name = String(data: data.subdata(in: byteRange(nameStart, nameLength, in: data)), encoding: .utf8)
        else {
            throw Error.corruptEntry("central directory entry at offset \(start)")
        }
        guard compressedSize != zip64Sentinel32, uncompressedSize != zip64Sentinel32,
              localHeaderOffset != zip64Sentinel32 else {
            throw Error.zip64Unsupported
        }
        cursor = nameStart + nameLength + extraLength + commentLength
        return Entry(name: name, compressionMethod: compressionMethod, compressedSize: compressedSize,
                     uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset,
                     generalPurposeBitFlag: generalPurposeBitFlag)
    }

    // MARK: Local file header + payload

    /// The compressed bytes for one entry. The name/extra lengths MUST come from the LOCAL header,
    /// not the central directory's — the two are allowed to differ (some writers pad the local extra
    /// field for alignment), and trusting the central directory's lengths here would skip the wrong
    /// number of bytes and hand back the tail of a name or extra field as if it were payload.
    private static func compressedBytes(in data: Data, for entry: Entry) throws -> Data {
        let start = Int(entry.localHeaderOffset)
        guard try data.readUInt32LE(at: start) == localFileHeaderSignature else {
            throw Error.corruptEntry(entry.name)
        }
        let nameLength = Int(try data.readUInt16LE(at: start + 26))
        let extraLength = Int(try data.readUInt16LE(at: start + 28))
        let contentStart = start + 30 + nameLength + extraLength
        let contentLength = Int(entry.compressedSize)
        guard contentStart + contentLength <= data.count else { throw Error.truncated }
        return data.subdata(in: byteRange(contentStart, contentLength, in: data))
    }

    private static func byteRange(_ offset: Int, _ length: Int, in data: Data) -> Range<Int> {
        (data.startIndex + offset)..<(data.startIndex + offset + length)
    }

    // MARK: Inflate

    /// `compression_decode_buffer` is a one-shot call with no signal of its own for "the source had
    /// more data than fit" — filling the destination exactly looks identical to the source genuinely
    /// ending there. Since the destination is always sized to the declared uncompressed size, an
    /// exact fill is the ORDINARY outcome for every well-formed entry, so it has to be verified:
    /// decode again into a buffer one byte larger. If that produces more bytes, the central
    /// directory's declared size undersold the real content, and the first decode was a truncated
    /// read wearing the costume of a complete one.
    private static func inflate(_ compressed: Data, uncompressedSize: Int, name: String) throws -> Data {
        let decoded = try decode(compressed, capacity: uncompressedSize)
        guard decoded.count == uncompressedSize else { throw Error.corruptEntry(name) }
        let recheck = try decode(compressed, capacity: uncompressedSize + 1)
        guard recheck.count == uncompressedSize else { throw Error.corruptEntry(name) }
        return decoded
    }

    /// `COMPRESSION_ZLIB` in Apple's Compression framework is raw DEFLATE — exactly what a ZIP entry
    /// stores — not zlib-wrapped data, so no header is prepended or expected here.
    private static func decode(_ compressed: Data, capacity: Int) throws -> Data {
        guard capacity > 0 else { return Data() }
        guard !compressed.isEmpty else { return Data() }
        var output = [UInt8](repeating: 0, count: capacity)
        let count = output.withUnsafeMutableBufferPointer { dest -> Int in
            compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let destBase = dest.baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destBase, capacity, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data(output.prefix(count))
    }
}

extension ZipArchive.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingEndOfCentralDirectory: return "Not a ZIP archive: no end-of-central-directory record found."
        case .truncated: return "ZIP archive is truncated: a record reaches past the end of the data."
        case .zip64Unsupported: return "This ZIP archive uses Zip64 extensions, which are not supported."
        case .unsupportedCompressionMethod(let method): return "Unsupported ZIP compression method \(method)."
        case .encryptedEntry(let name): return "\"\(name)\" is encrypted and cannot be read."
        case .entryNotFound(let name): return "\"\(name)\" was not found in the archive."
        case .corruptEntry(let name): return "\"\(name)\" is corrupt."
        case .entryTooLarge(let declared, let cap): return "Declared size \(declared) bytes exceeds the \(cap)-byte limit."
        }
    }
}

// MARK: Little-endian field reads

private extension Data {
    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZipArchive.Error.truncated }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchive.Error.truncated }
        let base = startIndex + offset
        return UInt32(self[base]) | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16) | (UInt32(self[base + 3]) << 24)
    }
}
