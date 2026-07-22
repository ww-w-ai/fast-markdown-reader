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
    /// The underline's STYLE (docx `w:rPr/w:u/@w:val`, §17.18.99 `ST_Underline`) — meaningful only
    /// when `underline` is `true`; a non-underlined span still carries whatever default this field
    /// has, but `OfficeTextBuilder` never reads it in that case. Defaults to `.single`, which is
    /// both `ST_Underline`'s own most common value AND what every span rendered before this field
    /// existed (unconditionally `NSUnderlineStyle.single`). `underline` itself stays the on/off
    /// toggle it always was — see `DocxReader.isOn` — this field only refines what an ON underline
    /// LOOKS like.
    var underlineStyle: UnderlineStyle = .single
    var code: Bool = false
    /// docx `w:rPr/w:caps` (§17.3.2.5) — renders the run's text UPPERCASE at build time, without
    /// changing the underlying source model (`OfficeTextBuilder` uppercases only the DISPLAYED
    /// string). Wins over `smallCaps` when both are set (matches Word's own precedence — `w:caps`
    /// is the stronger of the two transforms).
    var caps: Bool = false
    /// docx `w:rPr/w:smallCaps` (§17.3.2.33) — renders lowercase letters as small capitals via an
    /// AppKit font feature, WITHOUT uppercasing the source text (unlike `caps` above) — the glyphs
    /// change, the characters don't.
    var smallCaps: Bool = false
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
    /// Whether THIS run is explicitly marked right-to-left (docx `w:rPr/w:rtl`, a toggle read the
    /// same on/off way as `bold`/`italic` — see `DocxReader.isOn`: present-and-unset-`w:val` is ON,
    /// `w:val="0"`/`"false"` is explicitly OFF). This is a RUN-level override for text embedded
    /// inside a paragraph of the opposite direction (a Latin phrase inside an Arabic sentence, or
    /// the reverse) — it does not, by itself, decide where the paragraph begins; that is
    /// `OfficeBlock`'s own `rtl` (see there for why direction is a paragraph property, not a font
    /// one). ODF's run-level markup (`text:span`) carries no equivalent signal — only a PARAGRAPH
    /// style's `style:writing-mode` — so an ODT-sourced `Span` never sets this; it stays `false`.
    var rtl: Bool = false
    /// Bookmark name(s) (docx `w:bookmarkStart`, odt `text:bookmark`/`text:bookmark-start`) whose
    /// target position is the START of this span — empty for ordinary text. `OfficeTextBuilder`
    /// turns a non-empty value into `MDAttr.bookmarkTarget` so an in-document anchor link elsewhere
    /// in the document can jump here by exact name. A span carrying a bookmark is never merged into
    /// its neighbour (see both readers' `appendMerging`) — merging would smear the marker's exact
    /// position across text that predates the bookmark.
    var bookmarks: [String] = []
    /// The run's authored text colour, already resolved to a literal RGB — `nil` means the source
    /// didn't specify one (or, for a THEME colour reference such as docx `w:color/@themeColor`,
    /// that a reader hasn't resolved it to a literal value yet; resolving those references against
    /// the document's theme part is later work, but this field is exactly where that resolved
    /// colour goes once it exists — nothing about this vocabulary or `OfficeTextBuilder` needs to
    /// change to receive it). `nil` is NOT "black" — `OfficeTextBuilder` decides what an unset (or,
    /// per its own judgement call, a near-neutral authored) colour renders as; see its
    /// `resolvedTextColor`.
    var textColor: NSColor? = nil
    /// The run's highlighter/background colour (docx `w:highlight`/`w:shd`, odt
    /// `style:text-background-color`) — `nil` for no highlight. Unlike `textColor`, a highlight is
    /// never reinterpreted against the reading theme: painting a background behind text is already
    /// an unambiguous, deliberate mark (there's no "ordinary black highlight" the way there's
    /// "ordinary black body text"), so it is always drawn exactly as authored.
    var highlightColor: NSColor? = nil
    /// The run's authored font size, in POINTS — a reader converts from its own source unit before
    /// constructing this (docx `w:sz`/`w:szCs` are HALF-points; ODT `fo:font-size` is already
    /// points). `nil` means the source didn't specify a size for this run — see
    /// `OfficeTextBuilder.build`'s `documentDefaultFontSize` parameter for exactly how a non-nil
    /// value becomes a rendered size (the model is Word's own: authored size scaled by the ratio
    /// between the user's chosen reading size and the document's own default body size, so a
    /// heading stays proportionally larger than body text at ANY reading size, and the reading-size
    /// setting still governs how big the whole document looks).
    var fontSize: CGFloat? = nil
    /// The run's authored font FAMILY name (docx `w:rFonts/@w:ascii`, odt `style:font-name`) —
    /// `nil` means "the theme's own body/heading/code font", exactly as before this field existed.
    /// Never applied to a `code` span: `OfficeTextBuilder`'s inline-code styling is a single,
    /// consistent monospaced look across the whole app (see `Palette`'s "one deliberate spot of
    /// color" reasoning) — letting an authored family override it would make some code spans
    /// inconsistent with others for no reason a reader would understand.
    var fontName: String? = nil
}

/// An underline's drawn style — docx `w:rPr/w:u/@w:val` (§17.18.99 `ST_Underline`), collapsed from
/// that enumeration's ~20 named values down to the handful AppKit can actually distinguish.
/// `DocxReader` maps `double`→`.double`; `dotted`/`dottedHeavy`→`.dotted`; every `dash*` variant
/// (`dash`/`dashLong`/`dashedHeavy`/…)→`.dashed`; every `wave*` variant (`wave`/`wavyHeavy`/
/// `wavyDouble`)→`.wavy`; anything else, including `single` itself and an absent/unrecognized
/// `@w:val`, →`.single`. Only consulted when `Span.underline` is `true` — see that field's doc.
enum UnderlineStyle: Equatable {
    case single, double, dotted, dashed, wavy
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
    /// The cell's own shading (docx `w:tcPr/w:shd/@w:fill`, odt `style:background-color` on the
    /// cell's style) — `nil` means unshaded, which `TableBlockBuilder` still shades with
    /// `Palette.tableHeaderBg` for a header row exactly as it did before this field existed (an
    /// explicit `backgroundColor` on a HEADER cell overrides that theme shading; on a body cell it
    /// is the only shading there is).
    var backgroundColor: NSColor? = nil
    /// The cell's own border colour/width (docx `w:tcPr/w:tcBorders`, odt cell-style borders) —
    /// either or both may be `nil`, in which case `TableBlockBuilder`'s existing theme default
    /// (`Palette.tableBorder` at 1pt) is used for that one, exactly as before this field existed.
    /// A real per-edge border model (top/bottom/left/right independently) is out of this sprint's
    /// scope — both readers' input formats can express far more than this vocabulary carries yet,
    /// and one uniform colour/width already covers the measured "borders" need without inventing
    /// four fields no parser fills in this sprint.
    var borderColor: NSColor? = nil
    var borderWidth: CGFloat? = nil
    /// The cell's own declared column width in POINTS (docx `w:tcPr/w:tcW`, converted from twips;
    /// odt column widths) — `nil` leaves `TableBlockBuilder`'s existing auto layout (equal-ish,
    /// content-driven column sizing via the table's own `percentageValueType`) untouched, exactly
    /// as before this field existed. Set on the grid's anchor cells; a merged cell's covered
    /// positions have no `Cell` of their own to carry a width at all (see `OfficeBlock.table`'s doc
    /// comment on anchor-only rows).
    var width: CGFloat? = nil
    /// The cell's own vertical alignment (docx `w:tcPr/w:vAlign/@w:val` — `top`/`center`/`bottom`;
    /// ODT, P4, carries no equivalent yet) — `nil` means the source didn't say, which is also
    /// Word's own default (`top`), so `TableBlockBuilder` leaves `NSTextTableBlock`'s already-`.top`
    /// vertical alignment untouched rather than setting it explicitly. `CellVAlign` is a closed
    /// three-case vocabulary rather than reusing `NSTextBlock.VerticalAlignment` directly so the
    /// reader stays free of AppKit's own `.baseline` case, which no source format expresses.
    var verticalAlignment: CellVAlign? = nil
    /// The cell's own resolved cell margin/padding, in POINTS, ALREADY resolved by the reader
    /// against the table's default before reaching this struct (docx: per-cell `w:tcPr/w:tcMar` →
    /// table-wide `w:tblPr/w:tblCellMar` → `nil`; ODT, P4, carries no equivalent yet) — `nil` means
    /// neither the cell nor its table said anything, and `TableBlockBuilder` keeps its own
    /// pre-existing 7pt default exactly as before this field existed. A uniform value, mirroring
    /// `borderColor`/`borderWidth`'s same simplification: `w:tcMar`/`w:tblCellMar` can express four
    /// independent edges, and this reader takes the START/left edge as representative (the same
    /// edge `ParagraphFormat.indentStart` reads for indentation) rather than inventing a four-field
    /// per-edge model nothing here would consistently fill in.
    var padding: CGFloat? = nil

    /// The cell's shading RESOLVED from the table's named STYLE (docx `w:tbl/w:tblPr/w:tblStyle`
    /// cascaded through that style's `w:tblStylePr` conditional blocks for this cell's grid
    /// position — P5) — `nil` means the table either has no named style, or that style has no
    /// shading applicable to this position. A LOWER-priority layer than `backgroundColor`
    /// (this cell's own direct `w:tcPr/w:shd`) and the table's own DIRECT default
    /// (`TableFormat.defaultShading`): `TableBlockBuilder` only falls to this when both of those
    /// are `nil`, and falls further still to the header theme colour when this is `nil` too.
    var styleShading: NSColor? = nil
    /// The cell's border colour/width RESOLVED from the table's named STYLE, mirroring
    /// `styleShading`'s doc — same lower-priority layer, same position-conditional resolution.
    var styleBorderColor: NSColor? = nil
    var styleBorderWidth: CGFloat? = nil

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

    init(blocks: [OfficeBlock], rowSpan: Int = 1, colSpan: Int = 1,
         backgroundColor: NSColor? = nil, borderColor: NSColor? = nil, borderWidth: CGFloat? = nil,
         width: CGFloat? = nil, verticalAlignment: CellVAlign? = nil, padding: CGFloat? = nil) {
        self.blocks = blocks
        self.rowSpan = rowSpan
        self.colSpan = colSpan
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.width = width
        self.verticalAlignment = verticalAlignment
        self.padding = padding
    }
}

/// A cell's vertical alignment — docx `w:tcPr/w:vAlign/@w:val`. See `Cell.verticalAlignment`'s own
/// doc comment for why this is a closed three-case vocabulary rather than AppKit's own
/// `NSTextBlock.VerticalAlignment`.
enum CellVAlign: Equatable {
    case top, center, bottom
}

/// A table's OWN default border/shading — docx `w:tbl/w:tblPr/w:tblBorders` and
/// `w:tbl/w:tblPr/w:shd/@w:fill` — that every cell in the table inherits unless it declares its
/// own (see `Cell.borderColor`/`.backgroundColor`). Mirrors `Cell`'s own uniform-border
/// simplification: `w:tblBorders` can express four edges (plus `insideH`/`insideV`) independently,
/// and this reader takes the first drawn edge, same as `Cell`'s own border reading. `nil` in any
/// field means the table didn't declare one — `TableBlockBuilder` falls through past it to its
/// existing theme default (`Palette.tableBorder`/1pt/header shading), exactly as before this
/// struct existed. A table with no `w:tblPr` at all (every markdown table; any docx table that
/// declares neither) constructs the all-`nil` default, which renders BYTE-IDENTICAL to before.
struct TableFormat: Equatable {
    var defaultBorderColor: NSColor? = nil
    var defaultBorderWidth: CGFloat? = nil
    var defaultShading: NSColor? = nil
}

/// A paragraph's line-spacing mode — docx `w:pPr/w:spacing/@w:lineRule` (`auto`/`exact`/`atLeast`)
/// and ODF's equivalent `style:line-height-at-least`/`fo:line-height` distinction, carried as one
/// closed vocabulary rather than a raw (rule, value) pair so a later sprint's builder can switch
/// over it exhaustively. Reserved for P2 (the reader that populates it, and
/// `OfficeTextBuilder`'s translation to `NSParagraphStyle` line-height, are next sprint's job) —
/// this sprint only carries the vocabulary, nothing constructs a non-nil value yet.
enum LineHeight: Equatable {
    /// docx `w:lineRule="auto"` — a RATIO of the line's own font size, not an absolute value;
    /// `1.0` means single spacing (the same as no line-height set at all), `2.0` double, etc.
    case multiple(CGFloat)
    /// docx `w:lineRule="exact"` — an EXACT height in POINTS, overriding the line's natural size
    /// (a tall glyph or embedded object can be clipped if the exact value is smaller than it needs).
    case exact(CGFloat)
    /// docx `w:lineRule="atLeast"` — a MINIMUM height in POINTS; the line grows past this value
    /// when its own content needs more room, but never shrinks below it.
    case atLeast(CGFloat)
}

/// A tab stop's ALIGNMENT — docx `w:tabs/w:tab/@w:val` (`start`/`left` → `.left`, `center` →
/// `.center`, `end`/`right` → `.right`, `decimal` → `.decimal`; `bar`/`clear` never reach this
/// vocabulary at all — see the reader's own `w:tab` parse for why). Text before the stop is
/// positioned relative to `position` according to this case, exactly the way Word itself lays a
/// tab column out — `.left` pushes text to start AT `position` (the paragraph's pre-P2b behaviour,
/// and every markdown/office call site that never authored a real alignment), `.right` ends text
/// AT `position`, `.center` centers it ON `position`, and `.decimal` aligns the decimal point (or,
/// for non-numeric text, the whole run) ON `position`.
enum TabAlignment: Equatable {
    case left, center, right, decimal
}

/// A tab stop's LEADER (fill) character — docx `w:tabs/w:tab/@w:leader` (`dot` → `.dot`, `hyphen` →
/// `.hyphen`, `underscore` → `.underscore`; absent or any other value → `.none`). Carried through
/// the vocabulary but NOT drawn this sprint — AppKit's `NSTextTab` has no native leader-fill
/// primitive, and a faithful dotted/dashed fill between the preceding text and the tab stop is a
/// real (measured-later) rendering cost this sprint doesn't take on. A tab with a leader still
/// renders as an ordinary aligned tab, just without the fill; `OfficeTextBuilder`'s `NSTextTab`
/// construction reads `position`/`alignment` only, and comments why `leader` is inert.
enum TabLeader: Equatable {
    case none, dot, hyphen, underscore
}

/// One authored tab stop — docx `w:tabs/w:tab` (`@w:pos` in twips → `position` in points, `@w:val`
/// → `alignment`, `@w:leader` → `leader`), odt `style:tab-stop` (`style:position` → `position`;
/// this sprint migrates the VOCABULARY only for ODT — see `OdtReader`'s own doc on why it doesn't
/// yet read ODF's `style:type`/`style:leader-text` into `alignment`/`leader`, so an ODT-sourced
/// stop is always `.left`/`.none`, identical to how it rendered before this type existed).
///
/// `init(position:)` is the ergonomic, position-only constructor every pre-P2b call site (tests,
/// `OdtReader`, markdown-adjacent code that never touches this vocabulary) becomes with a single
/// added token — `alignment`/`leader` default to `.left`/`.none`, which is EXACTLY what a bare
/// `CGFloat` position meant before this type existed, so a call site that only ever cared about
/// position renders byte-identical after the one-token change.
struct TabStop: Equatable {
    var position: CGFloat
    var alignment: TabAlignment
    var leader: TabLeader

    init(position: CGFloat, alignment: TabAlignment = .left, leader: TabLeader = .none) {
        self.position = position
        self.alignment = alignment
        self.leader = leader
    }
}

/// A paragraph's block-level formatting — spacing, indentation, shading and border — read from the
/// source but not yet applied anywhere. Every field defaults to `nil`/`false`, meaning "the source
/// didn't say → `OfficeTextBuilder` keeps using its own token/theme default, exactly as before this
/// struct existed." This sprint (P1) only adds the vocabulary and a default-constructed instance to
/// every block that can carry one; NEITHER reader (`DocxReader`/`OdtReader`) constructs a non-default
/// value yet, NOR does `OfficeTextBuilder` read any of these fields into layout — both are P2's job.
/// A default `ParagraphFormat()` therefore renders BYTE-IDENTICAL to a block with no `format` at all.
struct ParagraphFormat: Equatable {
    /// Space before/after the paragraph, in POINTS (docx `w:pPr/w:spacing/@w:before`/`@w:after` are
    /// TWIPS — a reader converts twips→points before constructing this; ODT `fo:margin-top`/
    /// `fo:margin-bottom` are already points). `nil` leaves the builder's own theme spacing in place.
    var spacingBefore: CGFloat? = nil
    var spacingAfter: CGFloat? = nil
    /// The paragraph's line-spacing mode — see `LineHeight` above. `nil` leaves whatever line
    /// height the builder already computes (typically driven by font size) untouched.
    var lineHeight: LineHeight? = nil
    /// Indentation from the text block's start/end edge (docx `w:pPr/w:ind/@w:start`(or `@w:left`)/
    /// `@w:end`(or `@w:right`), converted twips→points; odt `fo:margin-left`/`fo:margin-right`), and
    /// first-line/hanging indent (`w:ind/@w:firstLine`/`@w:hanging`; odt `fo:text-indent` — a
    /// negative value there is ODF's own hanging-indent spelling, so a reader normalizes it into
    /// EITHER `firstLineIndent` OR `hangingIndent`, never both at once, mirroring docx's own
    /// mutually-exclusive pair). All four in POINTS. Named after the SOURCE spec's own attributes
    /// deliberately — mapping `start`/`end` (which flip with `rtl`) onto `NSParagraphStyle`'s
    /// physical `firstLineHeadIndent`/`headIndent` is P2's job, not this struct's.
    var indentStart: CGFloat? = nil
    var indentEnd: CGFloat? = nil
    var firstLineIndent: CGFloat? = nil
    var hangingIndent: CGFloat? = nil
    /// docx `w:pPr/w:contextualSpacing` (a toggle, read the same on/off way as `Span.rtl` — see
    /// `DocxReader.isOn`) / odt paragraph-style `style:contextual-spacing` — when `true`, suppresses
    /// `spacingBefore`/`spacingAfter` between two consecutive paragraphs of the SAME style (list
    /// items are the common case: no gap wanted between "1." and "2.", but one wanted before the
    /// list and after it). Applying that adjacency rule is P2's job; this field only carries the bit.
    var contextualSpacing: Bool = false
    /// The paragraph's own background fill (docx `w:pPr/w:shd/@w:fill`, odt paragraph-style
    /// `fo:background-color`) — `nil` means unshaded, exactly as every paragraph renders today.
    /// Mirrors `Cell.backgroundColor`'s naming/semantics one level up, for the same reason: a
    /// paragraph can carry its own fill independent of any table it might sit inside.
    var shading: NSColor? = nil
    /// The paragraph's border box (docx `w:pPr/w:pBdr`, odt paragraph-style `fo:border`) — one
    /// uniform colour/width, mirroring `Cell.borderColor`/`Cell.borderWidth`'s existing model and
    /// its documented reasoning: a real per-edge border (top/bottom/left/right independently) is
    /// out of scope for the same reason it is on `Cell` — both source formats can express far more
    /// than this vocabulary carries, and one uniform colour/width already covers the measured need.
    var borderColor: NSColor? = nil
    var borderWidth: CGFloat? = nil
}

/// The format-neutral block vocabulary between a document-format parser (docx/odt/… — later
/// sprints) and `OfficeTextBuilder`, which turns these into typography. Deliberately knows
/// nothing about Word, ODF or XML: a parser's only job is to produce this vocabulary, and
/// `OfficeTextBuilder`'s only job is to consume it, so the two are built and tested apart.
enum OfficeBlock: Equatable {
    /// Every case below that holds spans also carries `rtl`, defaulted `false` so every existing
    /// caller (hundreds, mostly tests) that never mentions it keeps meaning "not explicitly marked
    /// right-to-left" — the same reading an absent source attribute gets.
    ///
    /// This is a PARAGRAPH property, not a font one: docx's `w:pPr/w:bidi` and ODT's paragraph-style
    /// `style:writing-mode="rl-tb"` both mark the whole block, deciding where it BEGINS, which side
    /// neutral characters (digits, punctuation, brackets) resolve toward at its edges, and — when
    /// `alignment` below is `nil` — which edge the block starts flush against. TextKit's own
    /// bidirectional algorithm already reorders mixed-direction RUNS correctly within a line once
    /// it knows the paragraph's base direction; what it cannot recover on its own is THAT base
    /// direction when the source doesn't say, which is exactly what carrying this bit through from
    /// the reader restores (see `OfficeTextBuilder`, which turns it into
    /// `NSParagraphStyle.baseWritingDirection`). An EXPLICIT `alignment` always wins over this
    /// default — `.natural` alignment already resolves to the right edge once the base direction is
    /// `.rightToLeft`, so `rtl` alone is only ever a fallback for when the source has no explicit
    /// alignment of its own to say instead.
    ///
    /// `alignment` (docx `w:pPr/w:jc`, odt `fo:text-align`) is `nil` when the source didn't say —
    /// meaning "let `rtl`/the theme's own default decide", never a hardcoded `.left`. `tabStops`
    /// (docx `w:pPr/w:tabs`, odt `style:tab-stop`) are the paragraph's OWN authored stops, in
    /// POINTS, in addition to whatever tab machinery the block already has for other reasons — a
    /// `listItem`'s marker tab (see below) is never replaced by these, only added to.
    /// `format` (trailing, defaulted — see `ParagraphFormat` above) is this sprint's (P1)
    /// vocabulary-only addition: every existing caller that never mentions it keeps meaning "no
    /// paragraph formatting beyond what the builder already applies," identical to before this
    /// field existed. Populating it from a real document (the reader) and consuming it in layout
    /// (`OfficeTextBuilder`) are both P2's job — this sprint changes no rendered output.
    case heading(level: Int, spans: [Span], rtl: Bool = false, alignment: NSTextAlignment? = nil, tabStops: [TabStop] = [], format: ParagraphFormat = ParagraphFormat())
    case paragraph(spans: [Span], rtl: Bool = false, alignment: NSTextAlignment? = nil, tabStops: [TabStop] = [], format: ParagraphFormat = ParagraphFormat())
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
    ///
    /// `alignment`/`tabStops` mean exactly what they mean on `.paragraph`/`.heading` above. A
    /// custom tab stop never displaces the marker's own hanging-indent tab — `OfficeTextBuilder`
    /// APPENDS these after it, so `1.\t<text>` still lands the text at the item's hanging indent
    /// first and any authored stops beyond that still work inside the item's own text.
    /// `format` means exactly what it means on `.paragraph`/`.heading` above — this sprint's
    /// vocabulary-only addition, trailing and defaulted so no existing caller changes meaning.
    case listItem(level: Int, ordered: Bool, spans: [Span], marker: String? = nil, rtl: Bool = false,
                  alignment: NSTextAlignment? = nil, tabStops: [TabStop] = [], format: ParagraphFormat = ParagraphFormat())
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
    /// `columnWidths` is the table's own grid column widths in POINTS, in left-to-right grid
    /// order (docx `w:tbl/w:tblGrid/w:gridCol/@w:w`, twips converted the same way `cellWidth`
    /// converts a per-cell `w:tcW`; odt column widths, P4) — the AUTHORITATIVE proportions Word
    /// itself fills the table's width with, which is why they win over a per-cell `Cell.width`
    /// (that field is a fallback for when no grid was readable at all, see its own doc comment).
    /// Empty means "no grid known" — every markdown table (GFM has no such concept) and any docx
    /// table whose `w:tblGrid` couldn't be read — and `TableBlockBuilder` falls back to its
    /// pre-this-field per-cell/auto layout exactly as before this field existed. When non-empty
    /// its count is expected to equal the table's own derived column count; a caller that can't
    /// establish that (a malformed grid) should pass `[]` rather than a mismatched array — a
    /// mismatch is treated as "unusable" and ignored, never partially applied.
    /// `format` (trailing, defaulted — see `TableFormat` above) is this sprint's (P3b) table-level
    /// default border/shading, inherited by any cell that doesn't declare its own. A
    /// default-constructed `TableFormat()` — every markdown table, and every existing call site that
    /// never mentions this parameter — renders BYTE-IDENTICAL to before this field existed.
    case table(rows: [[Cell]], headerRows: Int, columnWidths: [CGFloat] = [], format: TableFormat = TableFormat())
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
