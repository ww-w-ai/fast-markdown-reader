import AppKit

/// The little floating bar that appears beside a block while it is being moved: ▲ ▼ and Done.
/// It rides along with the block (repositioned on every scroll, resize and move), so the user can
/// always see WHICH block is travelling — a bar pinned to the window edge would leave that
/// ambiguous once the document scrolls.
final class BlockMoveBar: NSView {
    private let up = NSButton()
    private let down = NSButton()
    private let done = NSButton()

    var onUp: () -> Void = {}
    var onDown: () -> Void = {}
    var onDone: () -> Void = {}

    static let barSize = NSSize(width: 116, height: 30)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.barSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Palette.hairline.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        func style(_ b: NSButton, _ title: String, _ x: CGFloat, _ w: CGFloat, _ action: Selector) {
            b.title = title
            b.bezelStyle = .accessoryBarAction
            b.setButtonType(.momentaryPushIn)
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.frame = NSRect(x: x, y: 3, width: w, height: 24)
            b.target = self
            b.action = action
            addSubview(b)
        }
        style(up, "▲", 4, 26, #selector(upTapped))
        style(down, "▼", 32, 26, #selector(downTapped))
        style(done, "Done", 62, 50, #selector(doneTapped))
        up.toolTip = "Move this block up (↑)"
        down.toolTip = "Move this block down (↓)"
        done.toolTip = "Finish moving (↵ or esc)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Grey out a direction that would run off the end of the document, so the bar says how far
    /// the block can still travel instead of beeping.
    func setEnabled(up canUp: Bool, down canDown: Bool) {
        self.up.isEnabled = canUp
        self.down.isEnabled = canDown
    }

    @objc private func upTapped() { onUp() }
    @objc private func downTapped() { onDown() }
    @objc private func doneTapped() { onDone() }
}
