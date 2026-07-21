import AppKit

/// A small transient window for editing ONE block's markdown source (right-click a selection →
/// Edit). ⌘↵ or Save writes the change back through the document; Esc or Cancel discards. This is
/// for quick manual fixes — complex edits stay the AI's job. Lightweight: one window, no live cost.
final class SourceEditPanel: NSWindowController, NSWindowDelegate {
    private static var open: [SourceEditPanel] = []
    private let editor = NSTextView()
    private let onSave: (String) -> Void

    static func show(title: String = "Edit block source",
                     markdown: String, onSave: @escaping (String) -> Void) {
        let c = SourceEditPanel(title: title, markdown: markdown, onSave: onSave)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.window?.makeFirstResponder(c.editor)
    }

    private init(title: String, markdown: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "\(title)  —  ⌘S or ⌘↵ save · esc cancel"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        win.center()

        let content = KeyCatchView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        content.onSave = { [weak self] in self?.saveTapped() }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 48, width: 640, height: 372))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        editor.frame = scroll.bounds
        editor.autoresizingMask = [.width]
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.string = markdown
        scroll.documentView = editor
        content.addSubview(scroll)

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"                      // ⌘↵ saves (plain ↵ still types a newline)
        save.keyEquivalentModifierMask = [.command]
        save.frame = NSRect(x: 640 - 100, y: 10, width: 88, height: 30)
        save.autoresizingMask = [.minXMargin]
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"                // esc
        cancel.frame = NSRect(x: 640 - 196, y: 10, width: 88, height: 30)
        cancel.autoresizingMask = [.minXMargin]
        content.addSubview(save)
        content.addSubview(cancel)

        win.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func saveTapped() { onSave(editor.string); close() }
    @objc private func cancelTapped() { close() }
    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }

    // MARK: - Undo / Redo while typing here

    /// The Edit menu's ⌘Z is bound to the document's `undoSourceEdit:`, and a menu key equivalent is
    /// matched before the panel's editor ever sees the keystroke. So the panel answers the same
    /// selectors and hands them to the editor's own undo manager — ⌘Z means "undo my typing" here and
    /// "undo my last saved edit" in the document, which is what each window makes the user expect.
    @objc func undoSourceEdit(_ sender: Any?) { editor.undoManager?.undo() }
    @objc func redoSourceEdit(_ sender: Any?) { editor.undoManager?.redo() }
}

/// Catches ⌘S inside the edit popup. The Save button already owns ⌘↵, but ⌘S is what a hand reaches
/// for after a lifetime of it — and here it must mean "commit this block", not the document-level
/// Save in the menu bar, which would fire while a half-finished edit sits unapplied in this window.
/// A key equivalent is offered to the whole view tree before the menu bar sees it, so catching it
/// here takes precedence for exactly as long as this window is key.
private final class KeyCatchView: NSView {
    var onSave: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension SourceEditPanel: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoSourceEdit(_:)): return editor.undoManager?.canUndo ?? false
        case #selector(redoSourceEdit(_:)): return editor.undoManager?.canRedo ?? false
        default: return true
        }
    }
}
