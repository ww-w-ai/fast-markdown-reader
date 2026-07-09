import AppKit

/// Read-only text view with a "reading cursor": a UTF-16 caret offset moved by the
/// keyboard scheme in spec §5, with the current line softly highlighted and kept on
/// screen. Heading jump targets are derived by scanning the live text for MDAttr.heading
/// (single source of truth), so they never drift when diagrams shift offsets.
final class ReaderTextView: NSTextView {
    private let nav = TextNavigator()
    private(set) var headingOffsets: [Int] = []
    private var caret: Int = 0 { didSet { highlightCurrentLine(); scrollCaretToVisible() } }
    private var digitBuffer = ""
    private var lastLineRange: NSRange?

    override var acceptsFirstResponder: Bool { true }

    private var plain: String { textStorage?.string ?? "" }
    private var length: Int { (plain as NSString).length }

    /// Rebuild heading offsets from the live text (ascending). The renderer never returns
    /// an offsets array — this scan is the only truth (C1: offsets are UTF-16).
    func recomputeHeadingOffsets() {
        guard let ts = textStorage else { headingOffsets = []; return }
        var offs: [Int] = []
        ts.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if v != nil { offs.append(r.location) }
        }
        headingOffsets = offs.sorted()
    }

    func clampCaretToText() {
        if caret > length { caret = length }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let s = plain

        // number + Enter → Nth heading
        if let chars = event.charactersIgnoringModifiers, chars.count == 1,
           let ch = chars.first, ch.isNumber, flags.isEmpty {
            digitBuffer.append(ch); return
        }
        if event.keyCode == 36 /* return */, !digitBuffer.isEmpty {
            if let n = Int(digitBuffer), n >= 1, n <= headingOffsets.count { caret = headingOffsets[n - 1] }
            digitBuffer = ""; return
        }
        digitBuffer = ""

        switch (event.keyCode, flags) {
        case (123, [.command]): caret = nav.previousLineBoundary(s, from: caret)     // ⌘←
        case (124, [.command]): caret = nav.nextLineBoundary(s, from: caret)         // ⌘→
        case (123, [.command, .shift]): caret = nav.sentenceStart(s, from: caret)    // ⌘⇧←
        case (124, [.command, .shift]): caret = nav.nextSentenceStart(s, from: caret) // ⌘⇧→
        case (123, [.shift]): caret = nav.paragraphStart(s, from: caret)             // ⇧←
        case (124, [.shift]): caret = nav.nextParagraphStart(s, from: caret)         // ⇧→
        case (126, [.command]): caret = prevHeading()                                // ⌘↑
        case (125, [.command]): caret = nextHeading()                                // ⌘↓
        case (126, [.option]): caret = 0                                             // ⌥↑ doc start
        case (125, [.option]): caret = length                                        // ⌥↓ doc end
        case (49, []): scrollPageDown(nil)                                           // Space
        case (49, [.shift]): scrollPageUp(nil)                                       // ⇧Space
        default: super.keyDown(with: event)                                          // ↑/↓ etc. scroll
        }
    }

    private func prevHeading() -> Int { headingOffsets.last(where: { $0 < caret }) ?? caret }
    private func nextHeading() -> Int { headingOffsets.first(where: { $0 > caret }) ?? caret }

    // Reading-line highlight lives ONLY as a layout-manager temporary attribute so it never
    // touches stored .backgroundColor (which would wipe code-card / inline-code shading).
    private func highlightCurrentLine() {
        guard let lm = layoutManager, length > 0 else { return }
        if let prev = lastLineRange { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: prev) }
        let start = nav.lineStart(plain, from: caret), end = nav.lineEnd(plain, from: caret)
        let r = NSRange(location: start, length: max(0, end - start))
        lm.addTemporaryAttribute(.backgroundColor,
            value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25), forCharacterRange: r)
        lastLineRange = r
    }

    private func scrollCaretToVisible() {
        scrollRangeToVisible(NSRange(location: min(caret, length), length: 0))
    }

    /// Reset the caret to the top when a fresh document is displayed.
    func resetCaret() { caret = 0; lastLineRange = nil }
}
