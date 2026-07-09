import AppKit

/// Read-only text view with a "reading cursor" (UTF-16 caret) moved by the spec §5 key
/// scheme. Because this is a viewer, navigation SELECTS the unit it moves by, so ⌘C copies
/// it immediately:
///   • click (no drag) / ⌘⇧←→ → the sentence      • ⇧←→ → the paragraph
///   • ⌘←→ → the line                              • ⌘↑↓ → the whole heading subsection
/// Page (Space), number-jump (N+Enter) and document ends (⌥↑↓) move without selecting
/// (too-large / jump moves stay caret-only). Heading targets/levels are scanned live from
/// MDAttr.heading so they never drift when diagrams shift offsets.
final class ReaderTextView: NSTextView {
    private let nav = TextNavigator()
    private var headingRuns: [(offset: Int, level: Int)] = []
    var headingOffsets: [Int] { headingRuns.map { $0.offset } }
    private var caret: Int = 0
    private var digitBuffer = ""
    private var lastLineRange: NSRange?

    override var acceptsFirstResponder: Bool { true }

    private var plain: String { textStorage?.string ?? "" }
    private var length: Int { (plain as NSString).length }

    /// Rebuild heading offsets+levels from the live text (ascending). MDAttr.heading's value
    /// is the heading level (Int). This scan is the only source of truth (C1: UTF-16).
    func recomputeHeadingOffsets() {
        guard let ts = textStorage else { headingRuns = []; return }
        var runs: [(Int, Int)] = []
        ts.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if let level = v as? Int { runs.append((r.location, level)) }
        }
        headingRuns = runs.sorted { $0.0 < $1.0 }.map { (offset: $0.0, level: $0.1) }
    }

    func clampCaretToText() { moveCaretOnly(min(caret, length)) }

    // MARK: - Key routing

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let s = plain

        // number + Enter → Nth heading (no selection — it's a jump)
        if let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let ch = chars.first, ch.isNumber, flags.isEmpty {
            digitBuffer.append(ch); return
        }
        if event.keyCode == 36 /* return */, !digitBuffer.isEmpty {
            if let n = Int(digitBuffer), n >= 1, n <= headingRuns.count { moveCaretOnly(headingRuns[n - 1].offset) }
            digitBuffer = ""; return
        }
        digitBuffer = ""

        // Bare [ / ] jump to the previous / next heading and select its subsection.
        if flags.isEmpty, let c = event.charactersIgnoringModifiers {
            if c == "[" { selectHeadingSection(prevHeadingOffset()); return }
            if c == "]" { selectHeadingSection(nextHeadingOffset()); return }
        }

        // No Shift anywhere (Shift = system text selection). ⌘↑↓ match the standard
        // document-start/end; ⌥ arrows repurpose word/paragraph moves (a viewer has no
        // editing) and each unit move SELECTS its unit for instant copy.
        switch (event.keyCode, flags) {
        case (123, [.command]):                                                        // ⌘← line start
            selectUnit(nav.lineRange(s, from: nav.previousLineBoundary(s, from: caret)))
        case (124, [.command]):                                                        // ⌘→ line end
            selectUnit(nav.lineRange(s, from: nav.nextLineBoundary(s, from: caret)))
        case (123, [.option]):                                                         // ⌥← sentence prev
            selectUnit(nav.sentenceRange(s, from: nav.sentenceStart(s, from: caret)))
        case (124, [.option]):                                                         // ⌥→ sentence next
            selectUnit(nav.sentenceRange(s, from: nav.nextSentenceStart(s, from: caret)))
        case (126, [.option]):                                                         // ⌥↑ paragraph prev
            selectUnit(nav.paragraphRange(s, from: nav.paragraphStart(s, from: caret)))
        case (125, [.option]):                                                         // ⌥↓ paragraph next
            selectUnit(nav.paragraphRange(s, from: nav.nextParagraphStart(s, from: caret)))
        case (126, [.command]): moveCaretOnly(0)                                        // ⌘↑ document start
        case (125, [.command]): moveCaretOnly(length)                                   // ⌘↓ document end
        case (49, []): scrollPageDown(nil)                                             // Space page down
        case (49, [.shift]): scrollPageUp(nil)                                         // ⇧Space page up
        default: super.keyDown(with: event)                                            // ↑/↓ scroll etc.
        }
    }

    // MARK: - Mouse: plain click selects the sentence

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)   // runs the full click/drag tracking loop
        // If the user did not drag out a selection, expand the caret to its sentence.
        if selectedRange().length == 0 {
            selectUnit(nav.sentenceRange(plain, from: selectedRange().location))
        } else {
            caret = selectedRange().location
            clearReadingLine()
        }
    }

    // MARK: - Heading subsections

    private func prevHeadingOffset() -> Int? { headingRuns.last(where: { $0.offset < caret })?.offset }
    private func nextHeadingOffset() -> Int? { headingRuns.first(where: { $0.offset > caret })?.offset }

    private func selectHeadingSection(_ offset: Int?) {
        guard let offset else { return }
        selectUnit(subsectionRange(at: offset))
    }

    /// A heading's subsection = from the heading to the next heading of the SAME OR HIGHER
    /// rank (level ≤ its own), so it grabs its nested deeper headings but never spills into a
    /// sibling/parent section. Keeps ranges to the minimal owning section.
    private func subsectionRange(at offset: Int) -> NSRange {
        guard let idx = headingRuns.firstIndex(where: { $0.offset == offset }) else {
            return NSRange(location: offset, length: 0)
        }
        let level = headingRuns[idx].level
        let end = headingRuns[(idx + 1)...].first(where: { $0.level <= level })?.offset ?? length
        var range = NSRange(location: offset, length: max(0, end - offset))
        // trim trailing blank lines
        let ns = plain as NSString
        var b = range.location + range.length
        while b > range.location, ns.character(at: b - 1) == 10 { b -= 1 }
        range.length = b - range.location
        return range
    }

    // MARK: - Selection / caret helpers

    private func selectUnit(_ range: NSRange) {
        let r = NSRange(location: min(range.location, length),
                        length: min(range.length, max(0, length - min(range.location, length))))
        clearReadingLine()                 // selection is the feedback now
        caret = r.location
        setSelectedRange(r)
        scrollRangeToVisible(r)
    }

    private func moveCaretOnly(_ pos: Int) {
        caret = max(0, min(pos, length))
        setSelectedRange(NSRange(location: caret, length: 0))   // collapse any selection
        highlightCurrentLine()
        scrollRangeToVisible(NSRange(location: caret, length: 0))
    }

    // Reading-line highlight lives ONLY as a layout-manager temporary attribute so it never
    // touches stored .backgroundColor (which would wipe code-card / inline-code shading).
    private func highlightCurrentLine() {
        clearReadingLine()
        guard let lm = layoutManager, length > 0 else { return }
        let start = nav.lineStart(plain, from: caret), end = nav.lineEnd(plain, from: caret)
        let r = NSRange(location: start, length: max(0, end - start))
        lm.addTemporaryAttribute(.backgroundColor,
            value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25), forCharacterRange: r)
        lastLineRange = r
    }

    private func clearReadingLine() {
        if let prev = lastLineRange, let lm = layoutManager, prev.location + prev.length <= length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: prev)
        }
        lastLineRange = nil
    }

    /// Reset to the top when a fresh document is displayed (no selection).
    func resetCaret() { clearReadingLine(); moveCaretOnly(0) }

    /// Reading caret (UTF-16 offset); used to preserve reading position across a font re-render.
    var readingCaret: Int {
        get { caret }
        set { moveCaretOnly(newValue) }
    }
}
