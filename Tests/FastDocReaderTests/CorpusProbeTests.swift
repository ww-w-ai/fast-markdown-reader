import XCTest
@testable import FastDocReader

/// PRIVACY (read before touching this file): the corpus this probe scans is the owner's REAL
/// PRIVATE DOCUMENTS. This file is deliberately incapable of emitting document body text — not
/// merely by convention, but by what it does with the data:
///   - every `OfficeBlock` is reduced to its KIND and COUNT (`BlockTally.add`) the instant it's
///     read; no `Span.text` is ever copied out of that reduction, printed, or written anywhere.
///   - the two raw-XML string reads (`hasHeadingSignal`) exist only to test `String.contains` for
///     a handful of STRUCTURAL tag names (`w:outlineLvl`, `<text:h`, …) — the decoded string never
///     leaves that function, is never printed, and is discarded the instant the boolean is formed.
///   - nothing in this file ever writes a filename, path, or any document content to the report —
///     only aggregate counts with denominators, keyed by format and element kind.
/// If you're adding a metric here, keep that invariant: reduce to a count before it can escape.
///
/// Re-runnable measurement, mirroring `RealEditLatencyTests`' `FMD_LATENCY_FILE` shape: skips
/// cleanly unless its environment variable is set, so the default `swift test` run never depends
/// on the owner's private files existing.
///
///   FMD_CORPUS_DIR="$HOME/Downloads:$HOME/Documents:$HOME/Desktop" \
///   FMD_CORPUS_REPORT=/tmp/fmd-corpus-report.txt \
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
///     --filter CorpusProbeTests
///
/// `FMD_CORPUS_DIR` is colon-separated (like `$PATH`) so one run covers several roots; each is
/// walked recursively, `node_modules` directories are skipped, and macOS `AppleDouble` sidecar
/// junk (`._*.docx`) is counted separately and excluded from every other tally.
///
/// Every `.docx`/`.odt` is read through `DocumentTypes.readOffice` — the SAME single dispatch
/// table `MarkdownDocument.read(from:)` uses — never by calling `DocxReader`/`OdtReader` directly.
/// Invariant 29 exists because of exactly this shortcut: a parser test proves the parser, not that
/// the app can reach it, and `.odt` shipped once with 24 passing parser tests and zero working
/// opens. Going through the dispatch table is what makes this probe an honest acceptance test.
final class CorpusProbeTests: XCTestCase {
    private struct BlockTally {
        var headingByLevel: [Int: Int] = [:]
        var paragraphs = 0
        var listItems = 0
        var tables = 0
        var images = 0
        var headingTotal: Int { headingByLevel.values.reduce(0, +) }

        mutating func add(_ block: OfficeBlock) {
            switch block {
            case .heading(let level, _): headingByLevel[level, default: 0] += 1
            case .paragraph: paragraphs += 1
            case .listItem: listItems += 1
            case .table: tables += 1
            case .image: images += 1
            }
        }
    }

    private struct FormatStats {
        var filesFound = 0
        var appleDoubleSidecars = 0
        var zipOpenFailed = 0
        var zipOpenFailedByKind: [String: Int] = [:]
        var readerThrew = 0
        var parsedOK = 0
        var tally = BlockTally()
        var docsWithHeadingSignal = 0
        var docsZeroHeadingsDespiteSignal = 0
    }

    func testScanCorpus() throws {
        guard let dirList = ProcessInfo.processInfo.environment["FMD_CORPUS_DIR"] else {
            throw XCTSkip("set FMD_CORPUS_DIR (colon-separated directories) to scan a corpus")
        }
        let reportPath = ProcessInfo.processInfo.environment["FMD_CORPUS_REPORT"]
            ?? (NSTemporaryDirectory() + "fmd-corpus-report.txt")
        let roots = dirList.split(separator: ":").map { URL(fileURLWithPath: String($0)) }

        var stats: [String: FormatStats] = ["docx": FormatStats(), "odt": FormatStats()]

        var enumerationErrors = 0
        for root in roots {
            // WITHOUT an errorHandler, FileManager's enumerator stops SILENTLY at the first
            // unreadable subdirectory (permission-denied, a broken symlink, …) — the rest of that
            // root's tree is then never visited and never reported missing. That is exactly the
            // "silent truncation" this project's working style forbids: return `true` to keep
            // going past the bad entry, and count how often it happened so the report says so
            // instead of just quietly under-counting the corpus.
            // Deliberately NOT `.skipsHiddenFiles`: that option would also skip macOS AppleDouble
            // sidecars (`._*.docx`), which start with a dot — and Part 2 of this probe's brief is
            // to COUNT those, not silently drop them before they're ever seen. Hidden DIRECTORIES
            // (`.git`, `.Trash`, …) are skipped explicitly below instead, which is the narrower cut.
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [],
                errorHandler: { _, _ in enumerationErrors += 1; return true }
            ) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if url.lastPathComponent == "node_modules" || url.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard ext == "docx" || ext == "odt" else { continue }
                scan(url, ext: ext, into: &stats)
            }
        }

        var lines: [String] = ["scan.enumeration_errors_skipped_past=\(enumerationErrors)"]
        for ext in ["docx", "odt"] {
            guard let s = stats[ext] else { continue }
            lines.append("\(ext).files_found=\(s.filesFound)")
            lines.append("\(ext).appledouble_sidecar=\(s.appleDoubleSidecars)")
            lines.append("\(ext).zip_open_failed=\(s.zipOpenFailed)")
            for (kind, count) in s.zipOpenFailedByKind.sorted(by: { $0.key < $1.key }) {
                lines.append("\(ext).zip_open_failed.\(kind)=\(count)")
            }
            lines.append("\(ext).reader_threw=\(s.readerThrew)")
            lines.append("\(ext).parsed_ok=\(s.parsedOK)")
            lines.append("\(ext).blocks.heading_total=\(s.tally.headingTotal)")
            for (level, count) in s.tally.headingByLevel.sorted(by: { $0.key < $1.key }) {
                lines.append("\(ext).blocks.heading_level.\(level)=\(count)")
            }
            lines.append("\(ext).blocks.paragraph=\(s.tally.paragraphs)")
            lines.append("\(ext).blocks.listItem=\(s.tally.listItems)")
            lines.append("\(ext).blocks.table=\(s.tally.tables)")
            lines.append("\(ext).blocks.image=\(s.tally.images)")
            lines.append("\(ext).docs_with_heading_signal=\(s.docsWithHeadingSignal)")
            lines.append("\(ext).docs_zero_headings_despite_signal=\(s.docsZeroHeadingsDespiteSignal)")
        }
        let report = lines.joined(separator: "\n") + "\n"
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("CorpusProbe: wrote \(lines.count) metric lines to \(reportPath)")
    }

    private func scan(_ url: URL, ext: String, into stats: inout [String: FormatStats]) {
        var s = stats[ext] ?? FormatStats()
        defer { stats[ext] = s }

        s.filesFound += 1
        if url.lastPathComponent.hasPrefix("._") {
            s.appleDoubleSidecars += 1
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            s.zipOpenFailed += 1
            s.zipOpenFailedByKind["unreadable", default: 0] += 1
            return
        }

        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            s.zipOpenFailed += 1
            s.zipOpenFailedByKind[headerSignatureKind(data), default: 0] += 1
            return
        }

        let blocks: [OfficeBlock]
        do {
            // Single dispatch table, matching invariant 29 — never DocxReader/OdtReader directly.
            blocks = try DocumentTypes.readOffice(archive, extension: ext)
        } catch {
            s.readerThrew += 1
            return
        }

        s.parsedOK += 1
        // A PER-FILE tally first — "zero headings despite a signal" is a per-document question,
        // and folding straight into the cumulative `s.tally` would compare this file's heading
        // count against every other file's too.
        var fileTally = BlockTally()
        for block in blocks { fileTally.add(block) }
        s.tally.headingByLevel.merge(fileTally.headingByLevel, uniquingKeysWith: +)
        s.tally.paragraphs += fileTally.paragraphs
        s.tally.listItems += fileTally.listItems
        s.tally.tables += fileTally.tables
        s.tally.images += fileTally.images

        if hasHeadingSignal(archive: archive, ext: ext) {
            s.docsWithHeadingSignal += 1
            if fileTally.headingTotal == 0 {
                s.docsZeroHeadingsDespiteSignal += 1
            }
        }
    }

    /// Classifies a file that failed to open as a ZIP, using only the first bytes of the file
    /// (never any content past the header, never the filename in the returned string beyond the
    /// caller's own aggregate key). `D0 CF 11 E0` is the OLE Compound File signature both a legacy
    /// binary `.doc` misnamed `.docx` and a password-encrypted OOXML package share (OOXML encryption
    /// wraps the whole package in an OLE container, per MS-OFFCRYPTO) — this probe cannot tell those
    /// two apart from the header alone, so it reports the shared signature honestly rather than
    /// guessing. `PK` (`0x50 0x4B`) with a failed parse is a genuine but truncated/corrupt ZIP.
    private func headerSignatureKind(_ data: Data) -> String {
        guard data.count >= 4 else { return "too_short" }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]
        if b0 == 0xD0, b1 == 0xCF, b2 == 0x11, b3 == 0xE0 {
            return "ole_compound_file(legacy_doc_or_encrypted_ooxml)"
        }
        if b0 == 0x50, b1 == 0x4B {
            return "zip_pk_but_corrupt_or_truncated"
        }
        return String(format: "other_signature(%02X_%02X_%02X_%02X)", b0, b1, b2, b3)
    }

    /// True if the raw XML carries a STRUCTURAL heading marker — never printed or stored, the
    /// decoded string lives only inside this function and only a Bool escapes it. Deliberately
    /// scoped to `word/document.xml` (the BODY) only, matching mechanisms (a)/(b) from
    /// `corpus-measurement-2026-07-21.md` — a paragraph's own `w:outlineLvl`, or a `w:pStyle`
    /// reference to a heading-ish style id. `styles.xml` is deliberately NOT scanned here: nearly
    /// every Word template ships built-in Heading1-9 style DEFINITIONS (declaring `w:outlineLvl`)
    /// whether or not any paragraph in the body actually uses one — an earlier version of this
    /// function scanned styles.xml too and flagged 350/351 documents as "heading signal present",
    /// which is a signal on the TEMPLATE, not on the author's actual use of it; that made the
    /// "zero headings despite signal" count wildly overstate the real problem this probe exists to
    /// measure. Scoping to the body only recovers the intended question: did the AUTHOR mark a
    /// heading, not did the template merely make one available.
    private func hasHeadingSignal(archive: ZipArchive, ext: String) -> Bool {
        switch ext {
        case "docx":
            guard let partData = try? archive.data(for: "word/document.xml"),
                  let xml = String(data: partData, encoding: .utf8) else { return false }
            if xml.contains("<w:outlineLvl") { return true }
            if xml.range(of: "w:pStyle w:val=\"Heading", options: .caseInsensitive) != nil { return true }
            return false
        case "odt":
            guard let partData = try? archive.data(for: "content.xml"),
                  let xml = String(data: partData, encoding: .utf8) else { return false }
            return xml.contains("<text:h ") || xml.contains("<text:h>") || xml.contains("text:outline-level")
        default:
            return false
        }
    }
}
