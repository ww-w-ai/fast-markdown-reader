import Foundation

/// What a text file is, as opposed to what we wish it were: its characters, the encoding those
/// characters were stored in, and whether it carried a byte-order mark.
///
/// The encoding travels with the text because this app WRITES the file back (block edit / add /
/// delete / move). Reading a Windows-made CP949 file and saving it as UTF-8 would silently convert
/// a document the user never asked to convert — it would still look right here and be mojibake in
/// the tool they made it with. So a file goes back out the way it came in.
struct TextFile {
    var text: String
    var encoding: String.Encoding
    var hasBOM: Bool
}

/// Decides how to read a text file's bytes. macOS writes UTF-8, but the files that land in a reader
/// come from everywhere: Windows editors still emit CP949 (Korean) and UTF-16LE-with-BOM, and Linux
/// tools emit UTF-8 with no BOM. Decoding all of them as UTF-8 turns every non-ASCII character into
/// a replacement glyph — the file looks corrupted when it is perfectly fine.
enum TextEncodingDetector {
    /// Korean legacy encoding (Windows-949 / CP949, a superset of EUC-KR). Not in String.Encoding,
    /// so it comes from the CoreFoundation table.
    static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    /// Japanese and Simplified/Traditional Chinese legacy encodings, for the same reason as CP949.
    static let shiftJIS = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5.rawValue)))

    static func decode(_ data: Data) -> TextFile {
        if data.isEmpty { return TextFile(text: "", encoding: .utf8, hasBOM: false) }
        // 1. A byte-order mark is a statement, not a guess — believe it.
        if let f = fromBOM(data) { return f }
        // 2. Strict UTF-8. `String(data:encoding:.utf8)` returns nil on ANY invalid byte, unlike
        //    `String(decoding:as:)`, which substitutes replacement characters and reports success —
        //    that difference is the whole bug this type exists to fix.
        if let s = String(data: data, encoding: .utf8) { return TextFile(text: s, encoding: .utf8, hasBOM: false) }
        // 3. UTF-16 with no BOM, which Windows tools do emit: ASCII text in UTF-16 is half NUL
        //    bytes, and a NUL never appears in real single-byte text.
        if let f = bomlessUTF16(data) { return f }
        // 4. Legacy regional encodings. Accepting one requires it to produce that script's
        //    characters — any byte sequence "decodes" as some legacy encoding, so a successful
        //    decode alone proves nothing.
        for (encoding, script) in [(cp949, hangul), (shiftJIS, kana), (gbk, cjkIdeographs), (big5, cjkIdeographs)] {
            if let s = String(data: data, encoding: encoding), s.unicodeScalars.contains(where: script),
               let f = reversible(s, encoding, data) {
                return f
            }
        }
        // 5. Let the system guess (it reads user preferences and its own heuristics).
        var guess: NSString?
        let raw = NSString.stringEncoding(for: data, encodingOptions: nil,
                                          convertedString: &guess, usedLossyConversion: nil)
        if raw != 0, let guess = guess as String?,
           let f = reversible(guess, String.Encoding(rawValue: raw), data) {
            return f
        }
        // 6. Last resort: Latin-1 maps every possible byte to a character and back, so the file
        //    round-trips byte for byte even though the text may read as nonsense. Better a
        //    reversible misreading than a lossy one — an edit must never corrupt the rest.
        let s = String(data: data, encoding: .isoLatin1) ?? ""
        return TextFile(text: s, encoding: .isoLatin1, hasBOM: false)
    }

    /// Bytes for a file, in ITS encoding, with the BOM it arrived with. Returns nil when the text
    /// can no longer be represented — e.g. a CJK character typed into a Latin-1 file — so the
    /// caller can refuse to write rather than save a file full of "?".
    static func encode(_ text: String, like file: TextFile) -> Data? {
        guard var out = text.data(using: file.encoding, allowLossyConversion: false) else { return nil }
        if file.hasBOM, let bom = bom(for: file.encoding) { out = bom + out }
        return out
    }

    /// Accept a guessed encoding only if writing the decoded text back reproduces the file's bytes
    /// EXACTLY. A guess that can't be reversed is worse than no guess: the text may look plausible
    /// on screen, and then the first edit rewrites every other byte in the file. (Measured: the
    /// system's own guess for arbitrary binary is Windows-Cyrillic, which does not reverse.)
    private static func reversible(_ text: String, _ encoding: String.Encoding, _ data: Data) -> TextFile? {
        let f = TextFile(text: text, encoding: encoding, hasBOM: false)
        return encode(text, like: f) == data ? f : nil
    }

    // MARK: - Detection details

    private static func fromBOM(_ data: Data) -> TextFile? {
        let b = [UInt8](data.prefix(4))
        func decode(_ count: Int, _ encoding: String.Encoding) -> TextFile? {
            guard let s = String(data: data.dropFirst(count), encoding: encoding) else { return nil }
            return TextFile(text: s, encoding: encoding, hasBOM: true)
        }
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return decode(3, .utf8) }
        // UTF-32's BOM starts with UTF-16LE's, so it must be tested first.
        if b.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return decode(4, .utf32LittleEndian) }
        if b.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return decode(4, .utf32BigEndian) }
        if b.starts(with: [0xFF, 0xFE]) { return decode(2, .utf16LittleEndian) }
        if b.starts(with: [0xFE, 0xFF]) { return decode(2, .utf16BigEndian) }
        return nil
    }

    private static func bom(for encoding: String.Encoding) -> Data? {
        switch encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: return Data([0xFF, 0xFE])
        case .utf16BigEndian: return Data([0xFE, 0xFF])
        case .utf32LittleEndian: return Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: return Data([0x00, 0x00, 0xFE, 0xFF])
        default: return nil
        }
    }

    /// UTF-16 without a BOM: in mostly-ASCII text every other byte is NUL, and which half holds
    /// them says which end is first. Requires a clear majority, so a file with one stray NUL isn't
    /// mistaken for UTF-16.
    private static func bomlessUTF16(_ data: Data) -> TextFile? {
        let sample = [UInt8](data.prefix(4096))
        guard sample.count >= 4 else { return nil }
        var oddNULs = 0, evenNULs = 0
        for (i, byte) in sample.enumerated() where byte == 0 {
            if i.isMultiple(of: 2) { evenNULs += 1 } else { oddNULs += 1 }
        }
        let pairs = sample.count / 2
        let threshold = pairs / 2                       // half the character slots
        if oddNULs > threshold, evenNULs <= oddNULs / 8,
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return TextFile(text: s, encoding: .utf16LittleEndian, hasBOM: false)
        }
        if evenNULs > threshold, oddNULs <= evenNULs / 8,
           let s = String(data: data, encoding: .utf16BigEndian) {
            return TextFile(text: s, encoding: .utf16BigEndian, hasBOM: false)
        }
        return nil
    }

    private static let hangul: (Unicode.Scalar) -> Bool = { s in
        (0xAC00...0xD7A3).contains(s.value) || (0x1100...0x11FF).contains(s.value)
            || (0x3130...0x318F).contains(s.value)
    }
    private static let kana: (Unicode.Scalar) -> Bool = { s in
        (0x3040...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
    }
    private static let cjkIdeographs: (Unicode.Scalar) -> Bool = { s in
        (0x4E00...0x9FFF).contains(s.value)
    }
}
