import AppKit

/// A small transient window for editing ONE block's markdown source (right-click a selection →
/// Edit). ⌘↵ or Save writes the change back through the document; Esc or Cancel discards. This is
/// for quick manual fixes — complex edits stay the AI's job. Lightweight: one window, no live cost.
final class SourceEditPanel: NSWindowController, NSWindowDelegate {
    private static var open: [SourceEditPanel] = []
    private let editor = NSTextView()
    private let onSave: (String) -> Void

    static func show(markdown: String, onSave: @escaping (String) -> Void) {
        let c = SourceEditPanel(markdown: markdown, onSave: onSave)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.window?.makeFirstResponder(c.editor)
    }

    private init(markdown: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Edit block source  —  ⌘↵ save · esc cancel"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        win.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 48, width: 640, height: 372))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        editor.frame = scroll.bounds
        editor.autoresizingMask = [.width]
        editor.isRichText = false
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
}
