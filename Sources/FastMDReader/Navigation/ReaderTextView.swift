import AppKit

/// Read-only, selectable text view with a NORMAL text cursor: click to place an insertion
/// point, Shift-arrow / Shift-click to extend a selection, ⌘C to copy (native behavior — a
/// viewer benefits from ordinary selection so any span can be grabbed). Space / ⇧Space page.
///
/// The one custom behavior is a LEFT GUTTER: clicking the left margin beside a block copies
/// that whole unit at once and selects it for feedback —
///   • beside a paragraph / list / quote → that block
///   • beside a heading                  → its whole section (heading → next same/higher heading)
///   • beside a code block               → the raw code
/// Heading levels are scanned live from MDAttr.heading (C1: UTF-16) for the section range.
final class ReaderTextView: NSTextView {
    private var headingRuns: [(offset: Int, level: Int)] = []
    var headingOffsets: [Int] { headingRuns.map { $0.offset } }

    override var acceptsFirstResponder: Bool { true }

    /// Draw block decorations (code cards, inline-code chips, rules, quote bars) in the view's
    /// BACKGROUND pass so they sit beneath the selection highlight and glyphs — otherwise an
    /// opaque code card painted by the layout manager hides the selection inside it.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        // Compute decorations for the whole VISIBLE area, not just the dirty `rect`. During a
        // live selection drag AppKit only invalidates a thin strip; keying off that strip drew
        // partial cards (super erased the strip, we redrew only a sliver). Drawing all visible
        // decorations — clipped to the dirty rect by the graphics context — keeps them whole.
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        drawMDDecorations(lm, storage, tc, glyphsToShow: glyphRange, at: textContainerOrigin)
    }

    private var length: Int { textStorage?.length ?? 0 }

    /// Rebuild heading offsets+levels from the live text (ascending). This scan is the only
    /// source of truth (C1: UTF-16) so section ranges never drift when diagrams shift offsets.
    func recomputeHeadingOffsets() {
        guard let ts = textStorage else { headingRuns = []; return }
        var runs: [(Int, Int)] = []
        ts.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if let level = v as? Int { runs.append((r.location, level)) }
        }
        headingRuns = runs.sorted { $0.0 < $1.0 }.map { (offset: $0.0, level: $0.1) }
    }

    func clampCaretToText() {
        setSelectedRange(NSRange(location: min(selectedRange().location, length), length: 0))
    }

    /// Reset to the top when a fresh document is displayed (no selection).
    func resetCaret() {
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Reading position (selection start), preserved across a font re-render / zoom.
    var readingCaret: Int {
        get { selectedRange().location }
        set { setSelectedRange(NSRange(location: max(0, min(newValue, length)), length: 0)) }
    }

    // Keep Space / ⇧Space page scrolling (a plain text view lacks it); all caret movement and
    // selection is native.
    // Directional reading navigation. The modifier's position on the keyboard sets the JUMP SIZE:
    // farther left = bigger jump  →  fn (document) > ⌥ (page) > ⌘ (paragraph/block).
    // (⌃↑/↓ is deliberately NOT used — it collides with macOS Mission Control / App Exposé.)
    // Arrow keys always carry .function, so we compare against only the "real" modifiers.
    override func keyDown(with event: NSEvent) {
        // "?" opens the shortcut guide (the view is read-only, so it would never type anyway).
        if event.charactersIgnoringModifiers == "?", !event.modifierFlags.contains(.command) {
            (window?.windowController as? DocumentWindowController)?.showShortcutGuide(nil)
            return
        }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // Space / ⇧Space page WITHOUT selecting (here Shift means "page up", not "extend").
        if event.keyCode == 49, mods == [] { page(down: true, extend: false); return }
        if event.keyCode == 49, mods == [.shift] { page(down: false, extend: false); return }
        // For the modifier navigation, Shift ADDS selection while keeping the same movement.
        let extend = mods.contains(.shift)
        switch (event.keyCode, mods.subtracting(.shift)) {
        case (126, [.option]):    page(down: false, extend: extend)                   // ⌥↑  page (⇧ selects)
        case (125, [.option]):    page(down: true, extend: extend)                    // ⌥↓  page
        case (126, [.command]):   blockNav(down: false, extend: extend)               // ⌘↑  paragraph/block
        case (125, [.command]):   blockNav(down: true, extend: extend)                // ⌘↓
        case (116, _):            applyNav(to: 0, down: false, extend: extend, scroll: true)       // fn↑ doc start
        case (121, _):            applyNav(to: length, down: true, extend: extend, scroll: true)   // fn↓ doc end
        default:                  super.keyDown(with: event)
        }
    }

    private func topVisibleChar() -> Int {
        (window?.windowController as? DocumentWindowController)?.topVisibleCharIndex() ?? 0
    }

    /// Page scroll, then move the reading cursor to the TOP of the new viewport (so the next arrow
    /// continues from here instead of snapping back to the old caret). With `extend`, the selection
    /// grows to that point.
    private func page(down: Bool, extend: Bool) {
        if down { scrollPageDown(nil) } else { scrollPageUp(nil) }
        applyNav(to: topVisibleChar(), down: down, extend: extend, scroll: true)
    }

    /// Jump to the previous/next block start (a whole table is one stop).
    private func blockNav(down: Bool, extend: Bool) {
        let sel = selectedRange()
        let from = down ? sel.location + sel.length : sel.location   // move the LEADING edge
        let target = down ? nextBlockStart(from) : prevBlockStart(from)
        applyNav(to: target, down: down, extend: extend, scroll: true)
    }

    /// Move the reading cursor to `t`. With `extend`, keep the trailing edge fixed and stretch the
    /// selection to `t` (down keeps the start; up keeps the end). Top-anchors the scroll if asked.
    private func applyNav(to t: Int, down: Bool, extend: Bool, scroll: Bool) {
        let tt = max(0, min(t, length))
        let sel = selectedRange()
        let newSel: NSRange
        if extend {
            let anchor = down ? sel.location : sel.location + sel.length
            newSel = NSRange(location: min(anchor, tt), length: abs(anchor - tt))
        } else {
            newSel = NSRange(location: tt, length: 0)
        }
        setSelectedRange(newSel)
        // When selecting DOWNWARD, keep the cursor on the 2nd line so the first selected line stays
        // visible above it (otherwise the whole selection scrolls off the top and looks like nothing).
        if scroll {
            (window?.windowController as? DocumentWindowController)?
                .scrollCharToTop(tt, lineOffset: (down && extend) ? 1 : 0)
        }
    }

    /// Block starts in document order (each paragraph/list/table/code card is one block, so a
    /// whole table is a SINGLE stop — ⌘↑/↓ jumps over it rather than cell-by-cell).
    private func blockStarts() -> [Int] {
        guard let ts = textStorage else { return [0] }
        var starts: [Int] = [0]
        ts.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if v != nil { starts.append(r.location) }
        }
        return Array(Set(starts)).sorted()
    }

    private func prevBlockStart(_ caret: Int) -> Int { blockStarts().last(where: { $0 < caret }) ?? 0 }
    private func nextBlockStart(_ caret: Int) -> Int { blockStarts().first(where: { $0 > caret }) ?? length }

    // MARK: - Context menu (viewer-only)

    /// The view is editable (to show a caret), so the system tries to attach editing items —
    /// Cut/Paste, Writing Tools, AutoFill, Start Dictation, spelling, substitutions. None apply
    /// to a read-only viewer, so replace the whole menu with viewer-appropriate items.
    override func menu(for event: NSEvent) -> NSMenu? {
        // Remember which block was right-clicked so Edit works even with NO selection.
        menuClickChar = charIndex(atViewPoint: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        if selectedRange().length > 0 {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            let open = menu.addItem(withTitle: "Open Selection", action: #selector(openSelectionMenu(_:)), keyEquivalent: "")
            open.target = self
        }
        // Edit is available even without a selection — it grabs the block under the cursor.
        let edit = menu.addItem(withTitle: "Edit…", action: #selector(editSelectionMenu(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    private var menuClickChar: Int?

    private func charIndex(atViewPoint p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let cp = NSPoint(x: p.x - textContainerInset.width, y: p.y - textContainerInset.height)
        let gi = lm.glyphIndex(for: cp, in: tc)
        return min(lm.characterIndexForGlyph(at: gi), ts.length - 1)
    }

    @objc private func openSelectionMenu(_ sender: Any?) {
        guard let sel = (textStorage?.string as NSString?)?.substring(with: selectedRange()) else { return }
        (window?.windowController as? DocumentWindowController)?.openSelectionText(sel)
    }

    @objc private func editSelectionMenu(_ sender: Any?) {
        (window?.windowController as? DocumentWindowController)?.editSelectedSource(atChar: menuClickChar)
    }

    // MARK: - Left gutter: click a block's left margin to copy the whole unit

    override func mouseDown(with event: NSEvent) {
        // ⌘-click on an active selection → open it (path / url / bare domain), like `open <sel>`.
        if event.modifierFlags.contains(.command), selectedRange().length > 0,
           let sel = (textStorage?.string as NSString?)?.substring(with: selectedRange()) {
            (window?.windowController as? DocumentWindowController)?.openSelectionText(sel)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if p.x < textContainerInset.width {   // in the left gutter margin
            copyBlock(atY: p.y)
            return
        }
        // Click on a rendered diagram (mermaid) OR an image → open it enlarged in a zoomable window.
        if let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 {
            let cp = NSPoint(x: p.x - textContainerInset.width, y: p.y - textContainerInset.height)
            let gi = lm.glyphIndex(for: cp, in: tc)
            let ci = min(lm.characterIndexForGlyph(at: gi), ts.length - 1)
            let zoomable = ts.attribute(MDAttr.mermaid, at: ci, effectiveRange: nil) != nil
                        || ts.attribute(MDAttr.image, at: ci, effectiveRange: nil) != nil
            if zoomable,
               let att = ts.attribute(.attachment, at: ci, effectiveRange: nil) as? NSTextAttachment,
               let img = att.image,
               lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc).contains(cp) {
                DiagramZoomWindowController.show(img)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func copyBlock(atY y: CGFloat) {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return }
        let inset = textContainerInset
        let glyph = lm.glyphIndex(for: NSPoint(x: inset.width + 2, y: y - inset.height), in: tc)
        let char = min(lm.characterIndexForGlyph(at: glyph), ts.length - 1)
        let full = NSRange(location: 0, length: ts.length)

        let selectRange: NSRange
        let copyText: String
        if let code = ts.attribute(MDAttr.codeBlock, at: char, effectiveRange: nil) as? String {
            var r = NSRange(); _ = ts.attribute(MDAttr.codeBlock, at: char, longestEffectiveRange: &r, in: full)
            selectRange = r; copyText = code                        // raw code, not the rendered card
        } else if ts.attribute(MDAttr.heading, at: char, effectiveRange: nil) != nil {
            selectRange = sectionRange(atChar: char)                // heading → whole section
            copyText = (ts.string as NSString).substring(with: selectRange)
        } else if ts.attribute(MDAttr.blockId, at: char, effectiveRange: nil) != nil {
            var r = NSRange(); _ = ts.attribute(MDAttr.blockId, at: char, longestEffectiveRange: &r, in: full)
            selectRange = trimTrailingNewlines(r)
            copyText = (ts.string as NSString).substring(with: selectRange)
        } else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        setSelectedRange(selectRange)                               // visual feedback + ⌘C re-copy
        scrollRangeToVisible(selectRange)
    }

    /// A heading's section = from the heading to the next heading of the same-or-higher rank
    /// (level ≤ its own), so it grabs nested deeper headings but never spills into a sibling.
    private func sectionRange(atChar char: Int) -> NSRange {
        guard let idx = headingRuns.lastIndex(where: { $0.offset <= char }) else {
            return NSRange(location: char, length: 0)
        }
        let level = headingRuns[idx].level
        let start = headingRuns[idx].offset
        let end = headingRuns[(idx + 1)...].first(where: { $0.level <= level })?.offset ?? length
        return trimTrailingNewlines(NSRange(location: start, length: max(0, end - start)))
    }

    private func trimTrailingNewlines(_ range: NSRange) -> NSRange {
        guard let ns = textStorage?.string as NSString? else { return range }
        var b = range.location + range.length
        while b > range.location, ns.character(at: b - 1) == 10 { b -= 1 }
        return NSRange(location: range.location, length: b - range.location)
    }
}
