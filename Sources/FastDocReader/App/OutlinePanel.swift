import AppKit

/// One heading in the table of contents.
struct OutlineEntry {
    let title: String
    let level: Int
    /// Where the heading starts in the RENDERED text — what scrolling needs.
    let charIndex: Int
}

/// The table-of-contents sidebar: every heading in the document, indented by level, click to jump.
///
/// The headings are read from the rendered text (`MDAttr.heading` carries each one's level), so
/// there is no second parser to keep in step with the first — whatever the renderer decided is a
/// heading is exactly what appears here.
///
/// A flat table rather than an outline view: headings are already an ordered list, collapsing one
/// would hide document the reader is looking for, and indentation shows the nesting without adding
/// a second thing to operate.
final class OutlinePanel: NSView, NSTableViewDelegate, NSTableViewDataSource {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private(set) var entries: [OutlineEntry] = []
    /// Called with the character index to scroll to.
    var onSelect: (Int) -> Void = { _ in }

    static let defaultWidth: CGFloat = 240

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No backdrop of our own: this view is the content of an NSSplitViewItem(sidebarWith:),
        // and AppKit gives THAT the sidebar material, the inset rounded panel and the light/dark
        // behaviour. Painting our own underneath would sit on top of the real one and lose it.

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("toc"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.style = .sourceList              // rounded selection + sidebar metrics, for free
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked)
        table.intercellSpacing = NSSize(width: 0, height: 2)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false          // let the material through
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        // Clear of the title bar, so the first heading doesn't sit under the toolbar button.
        scroll.automaticallyAdjustsContentInsets = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuild from the document's rendered text. Cheap enough to run after every edit: it walks
    /// heading attribute runs, not the whole string.
    func reload(from storage: NSTextStorage) {
        var found: [OutlineEntry] = []
        let whole = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        storage.enumerateAttribute(MDAttr.heading, in: whole) { value, range, _ in
            guard let level = value as? Int else { return }
            let title = text.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            found.append(OutlineEntry(title: title, level: level, charIndex: range.location))
        }
        entries = found.sorted { $0.charIndex < $1.charIndex }
        table.reloadData()
    }

    /// Highlight the heading the reader is currently under, without telling anyone we did — a
    /// selection change here must not scroll the document back to that heading.
    func markCurrent(charIndex: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.lastIndex { $0.charIndex <= charIndex } ?? 0
        guard table.selectedRow != index else { return }
        suppressCallback = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        suppressCallback = false
    }

    private var suppressCallback = false

    @objc private func rowClicked() {
        guard !suppressCallback, entries.indices.contains(table.clickedRow) else { return }
        onSelect(entries[table.clickedRow].charIndex)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: entry.title)
        label.lineBreakMode = .byTruncatingTail
        // Size and weight fall off with depth, so the shape of the document is readable at a glance
        // rather than having to be worked out from indentation alone.
        let size = NSFont.smallSystemFontSize + (entry.level <= 1 ? 1 : 0)
        label.font = .systemFont(ofSize: size, weight: entry.level <= 2 ? .semibold : .regular)
        label.textColor = entry.level <= 2 ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        let indent = 8 + CGFloat(min(entry.level, 6) - 1) * 12
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
