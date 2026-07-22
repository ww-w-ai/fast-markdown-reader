import AppKit

/// Centralized custom NSAttributedString attribute keys (C5).
/// Producers (renderer) and consumers (window controller, reader view) must all
/// reference `MDAttr.*` — never raw string literals — so the producer→consumer
/// contract stays greppable and drift-free.
enum MDAttr {
    /// Value = the raw code string of a fenced code block (used by the copy-button overlay).
    static let codeBlock = NSAttributedString.Key("mdCodeBlock")
    /// Value = the code block's language string ("" if none) — lets the no-wrap overlay
    /// re-highlight with the same rules.
    static let codeLang = NSAttributedString.Key("mdCodeLang")
    /// Value = the mermaid diagram source (the document layer swaps it for a PDF attachment).
    static let mermaid = NSAttributedString.Key("mdMermaid")
    /// Value = the TeX source of a display formula. Same deal as `mermaid`, drawn by a different
    /// engine — see `WebBlock`, which is what the document layer actually iterates.
    static let math = NSAttributedString.Key("mdMath")
    /// Value = the heading level (Int); scanned live to recompute heading jump offsets.
    static let heading = NSAttributedString.Key("mdHeading")
    /// Value = a per-block sequence Int. Every top-level block (paragraph, list, quote,
    /// code, table, rule) carries one unique id over its whole range, so a gutter click can
    /// recover the exact block range to copy — headings are clearly separated from the
    /// paragraph beneath them (they own distinct ids).
    static let blockId = NSAttributedString.Key("mdBlockId")
    /// Marks a blockquote's range so the layout manager can draw its left accent bar.
    static let blockQuote = NSAttributedString.Key("mdBlockQuote")
    /// Left inset (points, NSNumber) for a code block nested inside a blockquote, so its card
    /// (and buttons) shift right to align with the quote's prose instead of the page margin.
    static let codeInset = NSAttributedString.Key("mdCodeInset")
    /// Marks an inline-code span so the layout manager can draw a rounded chip hugging the
    /// glyphs (a plain .backgroundColor fills the whole inflated line height instead).
    static let inlineCode = NSAttributedString.Key("mdInlineCode")
    /// Marks a thematic break (`---`) so the layout manager draws a full-width hairline.
    static let rule = NSAttributedString.Key("mdRule")
    /// Value = an image source (URL/path). The document layer loads it async and swaps the
    /// placeholder attachment's image in place (like mermaid). MDAttr.imageAlt holds the alt.
    static let image = NSAttributedString.Key("mdImage")
    static let imageAlt = NSAttributedString.Key("mdImageAlt")
    /// Marks an image the sandbox won't let us read — clicking it asks for the folder (App Store
    /// build only). Value = the folder to grant.
    static let needsFolderGrant = NSAttributedString.Key("mdNeedsFolderGrant")
    /// Explicit image width (non-standard extensions): points (NSNumber) or a 0–1 fraction of
    /// the column (imageWidthPct). Parsed from HTML `<img width>`, Pandoc `{width=}`, Obsidian `|N`.
    static let imageWidth = NSAttributedString.Key("mdImageWidth")
    static let imageWidthPct = NSAttributedString.Key("mdImageWidthPct")
    /// Value = a raw file path string (absolute/~/relative) detected in prose; the link
    /// handler resolves it against the document's directory and opens it.
    static let filePath = NSAttributedString.Key("mdFilePath")
    /// Reserved for the reading-line highlight contract (kept for symmetry; the reading
    /// line itself is drawn via layout-manager temporary attributes, not stored).
    static let readingLine = NSAttributedString.Key("mdReadingLine")
    /// Value = NSValue(range:) of this block's span in the ORIGINAL markdown source (line-based,
    /// UTF-16). Lets a rendered selection map back to source markdown for block-level editing.
    static let srcRange = NSAttributedString.Key("mdSrcRange")
    /// Value = the raw fragment (without `#`) of an in-document anchor link (a TOC entry, or an
    /// office cross-reference/bookmark link). The click handler resolves it — first against
    /// `bookmarkTarget` (exact name), then by GFM heading-slug match — and scrolls there; a target
    /// that resolves to neither does nothing (see `AnchorResolver`).
    static let anchor = NSAttributedString.Key("mdAnchor")
    /// Value = `[String]`, the bookmark name(s) (docx `w:bookmarkStart/@w:name`, odt
    /// `text:bookmark(-start)/@text:name`) whose target position is the START of this span — the
    /// destination side of an in-document anchor link, recorded by the office readers exactly the
    /// way a markdown heading's own text already doubles as its jump target. `AnchorResolver`
    /// matches an anchor link's raw fragment against these names EXACTLY (bookmark names are
    /// opaque ids like `_Toc123`, never slugified).
    static let bookmarkTarget = NSAttributedString.Key("mdBookmarkTarget")
    /// Value = `NSColor`, an office paragraph's own background fill (docx `w:pPr/w:shd/@w:fill`,
    /// odt `fo:background-color`) — drawn as a full-width rect behind the paragraph's line
    /// fragments by `drawMDDecorations`, the same build-time/draw-time split every other block
    /// decoration here uses (see `CodeCardLayoutManager`'s file doc). Never set by markdown or
    /// plain-text documents — see `ParagraphFormat.shading`'s own doc.
    static let paraShading = NSAttributedString.Key("mdParaShading")
    /// Value = `NSColor`, an office paragraph's own border colour (docx `w:pPr/w:pBdr`, odt
    /// `fo:border`) — paired with `paraBorderWidth` (never one without the other; both are set or
    /// neither, mirroring `ParagraphFormat.borderColor`/`.borderWidth`'s own "both resolved
    /// together" contract). Drawn as a stroked rect the same way `paraShading` is filled.
    static let paraBorderColor = NSAttributedString.Key("mdParaBorderColor")
    /// Value = `NSNumber` (CGFloat), the paragraph border's stroke width in points — see
    /// `paraBorderColor`.
    static let paraBorderWidth = NSAttributedString.Key("mdParaBorderWidth")
    /// Value = `[Int]`, the DISPLAY number(s) (`OfficeComment.number`) of the reviewer comment(s)
    /// whose range this span falls within — set by `OfficeTextBuilder` from `Span.commentIds`
    /// resolved against the document's `officeComments` (P6a captured the ids; this is P6b's
    /// number-carrying attribute). A build-time-only tag: nothing here draws anything — the
    /// comments panel's highlight + number badge (`drawCommentMarks`) reads it at DRAW time, and
    /// only while the panel is open, so setting this attribute never changes layout (invariant
    /// 1/24) and a comment-free document (or one whose panel is closed) never differs on screen.
    static let commentMark = NSAttributedString.Key("mdCommentMark")
}
