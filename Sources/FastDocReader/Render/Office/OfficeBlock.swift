import AppKit

/// A single formatted run of text — the smallest unit `OfficeTextBuilder` styles. Traits are
/// independent flags, not mutually exclusive: a run can be bold AND italic AND underlined AND
/// `code` at once (an office format's run properties are independent axes, unlike markdown where
/// `` `code` `` can't nest inside `**bold**`) — `code` only changes which FONT/COLOR the run
/// renders with (see `OfficeTextBuilder`), it doesn't suppress the others.
struct Span: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var code: Bool = false
    /// The link target, if this run is (or is inside) a hyperlink — `nil` for ordinary text. A
    /// later sprint's docx/odt parser resolves relationship ids / `text:a` hrefs down to this
    /// string; this sprint only carries the field through to rendering.
    var link: String? = nil
    var strikethrough: Bool = false
    var superscript: Bool = false
    /// Named `subscripted`, not `subscript` — that spelling is a Swift keyword and would need
    /// backticks at every call site (`` `subscript` ``). `superscript`/`subscripted` reads a little
    /// unevenly next to each other, but stays typeable everywhere without ceremony.
    var subscripted: Bool = false
    /// Bookmark name(s) (docx `w:bookmarkStart`, odt `text:bookmark`/`text:bookmark-start`) whose
    /// target position is the START of this span — empty for ordinary text. `OfficeTextBuilder`
    /// turns a non-empty value into `MDAttr.bookmarkTarget` so an in-document anchor link elsewhere
    /// in the document can jump here by exact name. A span carrying a bookmark is never merged into
    /// its neighbour (see both readers' `appendMerging`) — merging would smear the marker's exact
    /// position across text that predates the bookmark.
    var bookmarks: [String] = []
}

/// One cell of a table row. Only ANCHOR cells — the top-left corner of a merge — appear in
/// `OfficeBlock.table`'s `rows`; a grid position covered by another cell's `rowSpan`/`colSpan` is
/// simply absent, not present-and-empty. `TableBlockBuilder` derives which columns those covered
/// positions land in at render time, the same way `NSTextTableBlock` itself only needs to be told
/// about anchors. All-1 spans (this sprint's parsers emit nothing else yet) reproduce a plain
/// rectangular grid exactly — one `Cell` per visible position, nothing skipped.
struct Cell: Equatable {
    /// A cell's content is the SAME format-neutral block vocabulary as the top of a document —
    /// a paragraph, heading, list item, image, or (flattened, never a real nested grid — see
    /// `OfficeTextBuilder`'s cell renderer) another table — not a bare run of spans. That is what
    /// gives an image or a list item inside a cell somewhere to go at all: before this sprint
    /// `Cell` could only ever hold formatted text, so both `.image` and `.listItem` collection had
    /// to be skipped the moment the cell walk found them (gap-list rows 6 and 7). Rendering
    /// recurses through `OfficeTextBuilder`'s existing per-block machinery rather than growing a
    /// second, cell-only set of cases.
    var blocks: [OfficeBlock]
    var rowSpan: Int = 1
    var colSpan: Int = 1

    /// Back-compat convenience for the many construction sites (both readers' plain-text cells,
    /// most existing tests) that only ever need a cell of formatted text — wraps the spans in a
    /// single `.paragraph`, which `OfficeTextBuilder` renders BYTE-IDENTICAL to the pre-sprint
    /// direct-spans path: no block-level separator is added around a lone paragraph, so a
    /// plain-text cell looks exactly as it did before `Cell` could hold anything else.
    init(spans: [Span], rowSpan: Int = 1, colSpan: Int = 1) {
        self.blocks = [.paragraph(spans: spans)]
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }

    init(blocks: [OfficeBlock], rowSpan: Int = 1, colSpan: Int = 1) {
        self.blocks = blocks
        self.rowSpan = rowSpan
        self.colSpan = colSpan
    }
}

/// The format-neutral block vocabulary between a document-format parser (docx/odt/… — later
/// sprints) and `OfficeTextBuilder`, which turns these into typography. Deliberately knows
/// nothing about Word, ODF or XML: a parser's only job is to produce this vocabulary, and
/// `OfficeTextBuilder`'s only job is to consume it, so the two are built and tested apart.
enum OfficeBlock: Equatable {
    case heading(level: Int, spans: [Span])
    case paragraph(spans: [Span])
    /// `level` is a 0-based nesting depth. `ordered` selects "1. 2. 3." numbering — per level,
    /// restarting when a SHALLOWER level intervenes but continuing across a deeper nested run —
    /// vs a bullet. See `OfficeTextBuilder` for the exact restart rule.
    ///
    /// `marker` is the pre-computed display text for THIS item (e.g. `"1.2.3"`, `"iv."`, `"c)"`),
    /// or `nil`. Only a format that can actually resolve real numbering — a numId that names a
    /// concrete numbering definition, WITH an `w:lvlText` to substitute into — can honestly know
    /// this text, and only the READER (`DocxReader`) has that information: a numbering definition
    /// lives in a side part of the source file (`word/numbering.xml`), continues its counters
    /// across intervening body paragraphs, and can be overridden per-list (`w:startOverride`,
    /// `w:lvlOverride`) — none of which `OfficeTextBuilder` can see from one block in isolation.
    /// `nil` means "the source's numbering couldn't be resolved to real text" (no numbering part,
    /// an unresolvable numId, a level with no `w:lvlText`, ODF's list styles carrying no such
    /// field at all) — the field is OPTIONAL rather than mandatory precisely so that case keeps
    /// working: `OfficeTextBuilder` falls back to counting the item itself from `level`+`ordered`
    /// alone, EXACTLY as it always has (never inventing a number the source didn't give a way to
    /// compute — same principle as `image`'s reserved-but-unloaded size, applied to text instead
    /// of pixels). `ordered`/`level` still drive indentation and the bullet glyph even when
    /// `marker` is supplied — only the marker TEXT bypasses the builder's own counters.
    case listItem(level: Int, ordered: Bool, spans: [Span], marker: String? = nil)
    /// Rows of ANCHOR cells only (`rows[row]` lists the cells that START in that row, left to
    /// right — a row's `count` is therefore the number of anchors in it, NOT the column count once
    /// any span is wider than 1; a parser reading `w:gridSpan`/`table:number-columns-spanned` must
    /// size the grid from the source's own column authority (`w:tblGrid` / repeated cells), not
    /// from `rows[row].count`). `headerRows` is the count of LEADING rows that are a genuine
    /// header, and the SOURCE format must say so explicitly — docx marks it with `w:tblHeader`, a
    /// markdown table always has exactly one. It is not a guess `OfficeTextBuilder` makes: pass 0
    /// when the format can't tell you. DEFAULT TO 0 WHEN UNKNOWN, never 1 — an un-styled table is a
    /// faithful rendering of the source; a wrongly-bolded row is a lie about it (real contracts
    /// commonly have zero header rows — guessing "row one" bolds ordinary text).
    case table(rows: [[Cell]], headerRows: Int)
    /// `id` is an opaque key a later sprint resolves to pixels (a docx relationship id, an odt
    /// href, a markdown source path, …) — this sprint only reserves the LAYOUT area, exactly like
    /// a not-yet-loaded markdown image (invariant 1: reserved size must never depend on whether
    /// pixels are loaded).
    case image(id: String, size: CGSize)
    /// A chart or SmartArt diagram: DrawingML content this reader has no vector renderer for and
    /// for which no already-rendered `mc:Fallback` picture could be recovered either (see
    /// `DocxReader.graphicPlaceholderBlock`). Deliberately its OWN case rather than reusing
    /// `.image` with a synthetic id: an `.image` id names something `MarkdownDocument`'s async
    /// loader is expected to go find pixels FOR (an archive entry, a folder-grant path, or — when
    /// that lookup fails — the SAME generic "broken image" icon a corrupt picture reference gets).
    /// This case is different in kind, not just in degree: there was never any picture to look up
    /// in the first place, so showing the broken-image icon would misreport a decoding failure
    /// that didn't happen. `label` is the pre-formatted, reader-facing word to draw in the frame
    /// ("Chart", "Diagram" — never an XML element name); `size` is the drawing's own declared area
    /// (`wp:extent`, EMU-converted exactly like `.image`'s size), reserved up front and never
    /// revised — there is no later pixel arrival to protect invariant 1 against here, since unlike
    /// `.image` this case's rendering is synthesized once, fully, at build time.
    case unsupportedGraphic(label: String, size: CGSize)
    /// A Word/OOXML equation (`m:oMathPara` — a display equation on its own line), translated to
    /// the LaTeX the app's existing formula engine already renders (`OmmlTranslator`). Rides the
    /// SAME web-block pipeline a markdown `$$…$$` does — `OfficeTextBuilder` reserves a placeholder
    /// tagged with the identical `MDAttr.math` attribute `MarkdownRenderer.appendWebBlock` uses —
    /// so `MarkdownDocument`'s pre-render/pre-size passes (which enumerate `MDAttr.math` wherever it
    /// appears, not by document kind) pick it up automatically; invariant 1/2's scroll stability is
    /// inherited, not re-earned. Only a genuinely STANDALONE display equation becomes this case — a
    /// bare inline `m:oMath` mixed into a sentence has no web-block equivalent this sprint (no
    /// inline placeholder mechanism exists in `WebBlock`), so `DocxReader` degrades it to plain text
    /// INSIDE the surrounding paragraph's spans instead of ever reaching here. `latex` is never
    /// empty: an equation with no translatable content at all is degraded, before construction, to
    /// a visible text block by the reader — this case never carries "nothing to render".
    case formula(latex: String)
}
