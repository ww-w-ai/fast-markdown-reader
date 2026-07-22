import AppKit

/// One row in the comments panel — a display-ready projection of `OfficeComment`, not the model
/// itself, the same reasoning `OutlineEntry` uses for headings: the panel shows exactly what a
/// reader needs (number, author, text), nothing it would have to re-derive.
struct CommentRow {
    let number: Int
    let author: String
    let text: String
}

/// The right-side comments panel (P6b): every reviewer comment the document's `officeComments`
/// carries, in DISPLAY order (`OfficeComment.number`), click to jump to its anchored span.
///
/// Mirrors `OutlinePanel`'s shape exactly (same NSTableView-in-NSScrollView construction, same
/// `onSelect` callback pattern, same "no material of our own — the real panel material comes from
/// the split item that hosts us" reasoning) — see that file's doc for why each of those choices
/// was made; nothing here reargues them.
final class CommentPanel: NSView, NSTableViewDelegate, NSTableViewDataSource {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private(set) var entries: [CommentRow] = []
    /// Called with the comment's DISPLAY NUMBER (not a table row index — the body's
    /// `MDAttr.commentMark` is keyed by that same number, so the window controller can look up the
    /// anchored range directly without the panel knowing anything about text storage).
    var onSelect: (Int) -> Void = { _ in }

    static let defaultWidth: CGFloat = 260

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comment"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 44   // taller than the outline's flat row — author + a text preview
        table.backgroundColor = .clear
        table.style = .sourceList
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked)
        table.intercellSpacing = NSSize(width: 0, height: 4)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        scroll.automaticallyAdjustsContentInsets = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuild from the document's comments — called from every place that (re)renders the
    /// document, the same "both render paths" discipline `reloadOutline()` follows (invariant 23),
    /// so the panel never shows a stale list after an edit or a reload.
    func reload(from comments: [OfficeComment]) {
        entries = comments
            .sorted { $0.number < $1.number }
            .map { CommentRow(number: $0.number, author: $0.author ?? "Anonymous", text: $0.text) }
        table.reloadData()
    }

    private var suppressCallback = false

    @objc private func rowClicked() {
        guard !suppressCallback, entries.indices.contains(table.clickedRow) else { return }
        onSelect(entries[table.clickedRow].number)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()

        let header = NSTextField(labelWithString: "\(entry.number) · \(entry.author)")
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .labelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false

        let body = NSTextField(wrappingLabelWithString: entry.text)
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        body.textColor = .secondaryLabelColor
        body.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = 2
        body.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(header)
        cell.addSubview(body)
        cell.textField = header
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),

            body.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
        ])
        return cell
    }
}
