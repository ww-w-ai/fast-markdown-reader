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
    private let nav = TextNavigator()
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
        drawReadingLine(lm, tc)   // under the decorations and glyphs — it's ambient, not a highlight
        let glyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        drawMDDecorations(lm, storage, tc, glyphsToShow: glyphRange, at: textContainerOrigin)
    }

    /// A faint band across the line the reading cursor sits on, so a glance finds your place after a
    /// scroll — the "you are here" the app promises. Only when there's no selection: an active
    /// selection is its own, stronger highlight, and painting a band under it would muddy it.
    private func drawReadingLine(_ lm: NSLayoutManager, _ tc: NSTextContainer) {
        guard selectedRange().length == 0, length > 0 else { return }
        let caret = min(selectedRange().location, length)
        // A caret at the very end has no glyph of its own; anchor on the last one.
        let glyph = min(lm.glyphIndexForCharacter(at: caret), max(0, lm.numberOfGlyphs - 1))
        var line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard line.intersects(visibleRect) else { return }
        let o = textContainerOrigin
        // Span the full text column, not just the glyphs, so the band is a clean stripe.
        line.origin.x = o.x
        line.origin.y += o.y
        line.size.width = tc.size.width
        Palette.readingLine.setFill()
        NSBezierPath(rect: line).fill()
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

    /// The reading-line band lives on the OLD caret's line until something redraws; a bare
    /// setSelectedRange only invalidates the thin caret sliver, so the band would smear (old line
    /// stays lit, new line stays dark). Repaint the whole visible area on every selection change —
    /// it's one fill, cheap, and correctness beats a partial invalidate here.
    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity,
                                   stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsDisplay(visibleRect)
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
    // Directional reading navigation. The modifier's position on the keyboard sets the JUMP SIZE —
    // farther left = bigger jump — and it reads the same on both axes:
    //   down the document:  fn (whole document) › ⌥ (page)      › ⌘ (heading)
    //   across the line:    fn (paragraph)      › ⌥ (sentence)  › ⌘ (line)
    // Shift keeps the movement identical and selects what it crosses.
    // (⌃↑/↓ is deliberately NOT used — it collides with macOS Mission Control / App Exposé.)
    // Arrow keys always carry .function, so we compare against only the "real" modifiers.
    override func keyDown(with event: NSEvent) {
        // "?" opens the shortcut guide (the view is read-only, so it would never type anyway).
        if event.charactersIgnoringModifiers == "?", !event.modifierFlags.contains(.command) {
            (window?.windowController as? DocumentWindowController)?.showShortcutGuide(nil)
            return
        }
        // Single-letter block actions on the block under the READING CURSOR. Plain letters are free
        // here because the view accepts no typing (`shouldChangeTextIn` rejects everything), which
        // is the same reason "?" opens the guide — and it keeps the common edits one key away
        // instead of a right-click and a menu.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let wc = window?.windowController as? DocumentWindowController,
           let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 {
            let caret = selectedRange().location
            switch key {
            // No editable source on an office document — see `isOfficeDocument`. The context-menu
            // gate alone would be cosmetic: these bare keys reach the same actions without it.
            case "e" where !isOfficeDocument: wc.editSelectedSource(atChar: caret); return
            case "i" where !isOfficeDocument: wc.addBlockBelow(atChar: caret); return
            case "d" where !isOfficeDocument: wc.deleteBlock(atChar: caret); return
            case "u" where !isOfficeDocument: wc.moveBlockUnderCaret(by: -1); return
            case "j" where !isOfficeDocument: wc.moveBlockUnderCaret(by: 1); return
            case "t": wc.toggleTableOfContents(nil); return
            default: break
            }
        }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // Space / ⇧Space page WITHOUT selecting (here Shift means "page up", not "extend").
        if event.keyCode == 49, mods == [] { page(down: true, extend: false); return }
        if event.keyCode == 49, mods == [.shift] { page(down: false, extend: false); return }
        // For the modifier navigation, Shift ADDS selection while keeping the same movement.
        let extend = mods.contains(.shift)
        let s = textStorage?.string ?? ""
        let sel = selectedRange()
        // Move the LEADING edge: going forward continues from the selection's end, back from its start.
        let ahead = sel.location + sel.length, behind = sel.location
        let realMods = mods.subtracting(.shift)
        switch (event.keyCode, realMods) {
        // Across the line — the modifier says how far, same as the vertical keys (fn › ⌥ › ⌘).
        case (123, [.command]):   applyNav(to: nav.lineStart(s, from: behind), down: false, extend: extend)   // ⌘←
        case (124, [.command]):   applyNav(to: nav.lineEnd(s, from: ahead), down: true, extend: extend)       // ⌘→
        case (123, [.option]):    applyNav(to: prevSentence(behind), down: false, extend: extend)     // ⌥←
        case (124, [.option]):    applyNav(to: nextSentence(ahead), down: true, extend: extend)       // ⌥→
        // fn+arrow arrives as Home / End (keyCodes 115 / 119) — NOT as a bare arrow. Matching a bare
        // arrow here was the bug that made plain ← / → jump a paragraph instead of moving one char.
        case (115, _):  applyNav(to: prevBlock(behind), down: false, extend: extend)   // fn← (Home)  paragraph
        case (119, _):  applyNav(to: nextBlock(ahead), down: true, extend: extend)     // fn→ (End)   paragraph
        // Down the document.
        case (126, [.command]):   headingNav(down: false, extend: extend)             // ⌘↑  heading
        case (125, [.command]):   headingNav(down: true, extend: extend)              // ⌘↓
        case (126, [.option]):    page(down: false, extend: extend)                   // ⌥↑  page (⇧ selects)
        case (125, [.option]):    page(down: true, extend: extend)                    // ⌥↓  page
        case (116, _):            applyNav(to: 0, down: false, extend: extend)        // fn↑ doc start
        case (121, _):            applyNav(to: length, down: true, extend: extend)    // fn↓ doc end
        default:                  super.keyDown(with: event)
        }
    }

    // MARK: - Reading units

    /// Block starts in document order — one per paragraph, heading, list, quote, code card or table
    /// (a whole table is a SINGLE stop). This is the RENDERED text's real structure via MDAttr.blockId,
    /// not a guess at where blank lines fell, so it stays right as diagrams and formulas shift offsets.
    private func blockStarts() -> [Int] {
        guard let ts = textStorage else { return [0] }
        var starts: Set<Int> = [0]
        ts.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if v != nil { starts.insert(r.location) }
        }
        return starts.sorted()
    }
    private func prevBlock(_ caret: Int) -> Int { blockStarts().last { $0 < caret } ?? 0 }
    private func nextBlock(_ caret: Int) -> Int { blockStarts().first { $0 > caret } ?? length }

    /// Sentence navigation stops at every sentence AND every block start, so a heading or list item
    /// with no period in it is still a stop — without this, ⌥→ leaps over headings (they carry no
    /// sentence boundary) and the reader skips a line.
    private func nextSentence(_ caret: Int) -> Int {
        let s = textStorage?.string ?? ""
        return min(nav.nextSentenceStart(s, from: caret), nextBlock(caret))
    }
    private func prevSentence(_ caret: Int) -> Int {
        let s = textStorage?.string ?? ""
        // The nearer of "start of my sentence" and "start of the previous block" — whichever we
        // reach first going back. Landing on a block start means a heading is never skipped.
        return max(nav.sentenceStart(s, from: caret), prevBlock(caret))
    }

    /// Previous / next heading of any level — `#` through `######`, so ⌘↑↓ walks the document's
    /// own outline.
    private func headingNav(down: Bool, extend: Bool) {
        recomputeHeadingOffsets()   // offsets move as diagrams and formulas land; never cache them
        let sel = selectedRange()
        let from = down ? sel.location + sel.length : sel.location
        let offsets = headingOffsets
        let target = down ? (offsets.first { $0 > from } ?? length)
                          : (offsets.last { $0 < from } ?? 0)
        applyNav(to: target, down: down, extend: extend)
    }

    private func topVisibleChar() -> Int {
        (window?.windowController as? DocumentWindowController)?.topVisibleCharIndex() ?? 0
    }

    /// Page scroll, then move the reading cursor to the TOP of the new viewport (so the next arrow
    /// continues from here instead of snapping back to the old caret). With `extend`, the selection
    /// grows to that point.
    private func page(down: Bool, extend: Bool) {
        if down { scrollPageDown(nil) } else { scrollPageUp(nil) }
        // Snap the caret to the START of the top line, always — the top character can fall mid-line,
        // which left the caret sometimes at a line's front and sometimes deep inside it. Front every
        // time. Reveal then nudges the scroll back a couple of lines: that's both the 2–3 line
        // overlap and what lifts the caret off the clipped top edge so it stays visible.
        let top = nav.lineStart(textStorage?.string ?? "", from: topVisibleChar())
        applyNav(to: top, down: down, extend: extend)
    }

    /// Move the reading cursor to `t`. With `extend`, keep the trailing edge fixed and stretch the
    /// selection to `t` (down keeps the start; up keeps the end).
    private func applyNav(to t: Int, down: Bool, extend: Bool, reveal: Bool = true) {
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
        if reveal { revealCaret(tt) }
    }

    /// The page holds still and the cursor moves inside it; the page follows only when the cursor
    /// would leave the screen, and then by the least it can.
    ///
    /// This used to top-anchor every move, which is backwards: the cursor sat pinned to the first
    /// line while the document slid past it, so a one-sentence step re-scrolled the whole view.
    private func revealCaret(_ char: Int) {
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else { return }
        let glyph = lm.glyphIndexForCharacter(at: max(0, min(char, length)))
        var r = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        _ = tc
        // Land with a couple of lines of air rather than flush against an edge.
        scrollToVisible(r.insetBy(dx: 0, dy: -2 * r.height))
        (window?.windowController as? DocumentWindowController)?.placeCopyButtons()
    }

    // MARK: - Context menu (viewer-only)

    /// The view is editable (to show a caret), so the system tries to attach editing items —
    /// Cut/Paste, Writing Tools, AutoFill, Start Dictation, spelling, substitutions. None apply
    /// to a read-only viewer, so replace the whole menu with viewer-appropriate items.
    override func menu(for event: NSEvent) -> NSMenu? {
        // Remember which block was right-clicked so Edit works even with NO selection.
        menuClickChar = charIndex(atViewPoint: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        // EVERY item carries an icon. macOS gives some standard actions (Copy, Select All) one
        // automatically and leaves the rest bare, which reads as a ragged left edge — so the icon
        // is set explicitly on all of them and the titles line up.
        if selectedRange().length > 0 {
            // Two groups, each named by what it acts ON, so no item has to repeat the noun:
            // these two work on the SELECTION, the four below on the block under the pointer.
            addSectionHeader("Selection", to: menu)
            add("Copy", symbol: "doc.on.doc", action: #selector(copy(_:)), to: menu)
            add("Open", symbol: "arrow.up.forward.square", action: #selector(openSelectionMenu(_:)), to: menu)
            menu.addItem(.separator())
        }
        // The block operations are ONE group, in the order a block's life runs: change it, add
        // after it, move it, remove it. Delete sits with the others (it IS a block operation) and
        // earns its safety from the confirmation, not from being set apart. All four work without
        // a selection — each grabs the block under the pointer.
        //
        // None of this applies to an office document — it has no editable source, so the block
        // surface is left out of the menu entirely rather than shown and made to do nothing.
        if !isOfficeDocument {
            addSectionHeader(unitNoun + " Actions", to: menu)
            // The single-letter keys are shown here because a shortcut nobody can see is a shortcut
            // nobody uses. They apply to the block under the reading cursor; the menu applies to the
            // block under the pointer — the same action either way.
            add("Edit…", symbol: "square.and.pencil", action: #selector(editSelectionMenu(_:)), to: menu, key: "e")
            add("Add Below…", symbol: "plus.square", action: #selector(addBlockMenu(_:)), to: menu, key: "i")
            add("Move Up", symbol: "arrow.up", action: #selector(moveUpMenu(_:)), to: menu, key: "u")
            add("Move Down", symbol: "arrow.down", action: #selector(moveDownMenu(_:)), to: menu, key: "j")
            add("Delete…", symbol: "trash", action: #selector(deleteBlockMenu(_:)), to: menu, key: "d")
            menu.addItem(.separator())
        }
        addSectionHeader("Document", to: menu)
        add("Select All", symbol: "square.dashed", action: #selector(selectAll(_:)), to: menu)
        return menu
    }

    /// What one operable unit is CALLED in the document that's open. The unit itself differs by
    /// file kind — in markdown it's a paragraph, heading, table or code fence (often several lines);
    /// in a .txt or .csv the renderer makes it exactly one line — so the menu says whichever is
    /// true here rather than teaching the reader a word for something they aren't looking at.
    private var unitNoun: String {
        let doc = (window?.windowController as? DocumentWindowController)?.document as? MarkdownDocument
        return (doc?.isPlainText ?? false) ? "Line" : "Block"
    }

    /// An office document (`.docx`, …) has no editable source — see CLAUDE.md invariant 22 and the
    /// S4 audit in `docs/plans/2026-07-21-office-reader-roadmap.md`. Every edit door checks this.
    private var isOfficeDocument: Bool {
        let doc = (window?.windowController as? DocumentWindowController)?.document as? MarkdownDocument
        return doc?.kind == .office
    }

    /// One menu item with its icon. Every action here — ours and NSTextView's own `copy:` /
    /// `selectAll:` — is implemented by this view, so `self` is the right target for all of them.
    private func add(_ title: String, symbol: String, action: Selector, to menu: NSMenu,
                     key: String = "") {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        // No modifier: these are bare letters handled in keyDown, and the menu is only showing what
        // they are. A modifier mask here would print "⌘E" and teach the wrong shortcut.
        item.keyEquivalentModifierMask = []
        item.target = self
        // A missing symbol name would silently leave ONE item unaligned — the exact raggedness this
        // is here to fix — so fall back to a blank image of the same size to hold the column.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    // AppKit adds AutoFill and Services to this menu itself, and the menu we return here is NOT the
    // last word on them: both removing them (willOpenMenu) and labelling them with a trailing
    // section header were tried on macOS 15 and neither took — whatever AppKit does with those
    // items happens outside the menu object we hand back. They're inert here anyway (this view
    // accepts no typing), so they're left as the system puts them rather than chased further.

    /// A small grey heading above a group of menu items. `NSMenuItem.sectionHeader` is macOS 14+,
    /// and this app ships back to 13 — so on 13 fall back to a disabled item, which is what that
    /// API renders as anyway. Never a plain enabled item: it would look clickable and do nothing.
    @discardableResult
    private func addSectionHeader(_ title: String, to menu: NSMenu) -> NSMenuItem {
        let header: NSMenuItem
        if #available(macOS 14.0, *) {
            header = NSMenuItem.sectionHeader(title: title)
        } else {
            header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
        }
        menu.addItem(header)
        return header
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

    @objc private func addBlockMenu(_ sender: Any?) {
        (window?.windowController as? DocumentWindowController)?.addBlockBelow(atChar: menuClickChar)
    }

    @objc private func deleteBlockMenu(_ sender: Any?) {
        (window?.windowController as? DocumentWindowController)?.deleteBlock(atChar: menuClickChar)
    }

    /// The menu acts on the block under the POINTER, so put the cursor there first — otherwise
    /// right-clicking one block and choosing Move Up would move whichever block the cursor was on.
    @objc private func moveUpMenu(_ sender: Any?) { moveFromMenu(by: -1) }
    @objc private func moveDownMenu(_ sender: Any?) { moveFromMenu(by: 1) }

    private func moveFromMenu(by delta: Int) {
        guard let wc = window?.windowController as? DocumentWindowController else { return }
        if let c = menuClickChar { setSelectedRange(NSRange(location: c, length: 0)) }
        wc.moveBlockUnderCaret(by: delta)
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
            // A sandbox-blocked image: its placeholder is an image too, so this MUST come before the
            // zoom check — otherwise clicking "Click to allow…" just enlarges that label.
            if ts.attribute(MDAttr.needsFolderGrant, at: ci, effectiveRange: nil) != nil,
               lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc).contains(cp) {
                NSApp.sendAction(#selector(DocumentWindowController.grantFolderAccess(_:)), to: nil, from: self)
                return
            }
            let zoomable = ts.attribute(MDAttr.mermaid, at: ci, effectiveRange: nil) != nil
                        || ts.attribute(MDAttr.math, at: ci, effectiveRange: nil) != nil
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
