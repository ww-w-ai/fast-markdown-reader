import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MUST stay false. The app starts empty (no window) and is driven from the menu bar, so a
    // windowless app is a normal, intended state — not a reason to quit. Returning true here made
    // the app terminate the instant Open… was chosen from the empty (zero-window) launch state: the
    // open panel counts as the "last window", and dismissing it tripped last-window-closed → quit.
    // With false, closing the last document returns to the empty menu-bar state; quitting is ⌘Q only.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opt out of state restoration entirely: no previously-open documents are reopened on launch,
    // so the app always starts clean (closing / quitting never leaves old tabs behind).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-open previously granted folders BEFORE any document loads, so restored access is live
        // by the time media resolve (sandboxed build only; a no-op otherwise).
        FolderAccess.restoreGrants()
        buildMenu()
    }

    // Launching WITHOUT a document must NOT auto-pop an Open panel — start empty and let the
    // user pick via the File menu (Open… / Open Recent). Returning false here suppresses the
    // untitled-file path entirely; launching WITH a document still opens it normally (AppKit
    // never calls the untitled hooks in that case).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // A SwiftPM executable has no MainMenu.nib, so build the menu bar in code. Without it,
    // standard shortcuts (⌘Q/⌘O/⌘W/⌘C/⌘F/⌘±) and the native Window/tabs menu don't work.
    private func buildMenu() {
        let appName = "fast-md-reader"
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Offered, never taken. An app that makes itself the default handler on its own — at first
        // launch or otherwise — is hijacking a system-wide setting the user didn't touch, which the
        // App Store rejects and users rightly resent. This does it only when asked, and says
        // exactly which kinds of file it will claim before doing anything.
        let defaults = appMenu.addItem(withTitle: "Set as Default App…",
                                       action: #selector(offerToBecomeDefault(_:)), keyEquivalent: "")
        defaults.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        // Open… — do NOT use NSDocumentController.openDocument(_:) (its built-in panel path crashes
        // immediately in this code-menu / ad-hoc-signed SwiftPM app). Present our OWN NSOpenPanel and
        // route the result through openDocument(withContentsOf:) — the exact path Open Recent uses,
        // which is known-good.
        let newItem = fileMenu.addItem(withTitle: "New File…", action: #selector(newFileDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openDocumentPanel(_:)), keyEquivalent: "o")
        openItem.target = self
        // Open Recent — AppKit's automatic population does NOT attach to a code-built menu (no
        // MainMenu.nib), so it stayed empty. Populate it ourselves from recentDocumentURLs via a
        // menu delegate that rebuilds on every open (menuNeedsUpdate).
        let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        let close = fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        // Edits live in memory until this. Closing with unsaved changes gets AppKit's own
        // Save / Don't Save / Cancel sheet, because the document now reports itself as dirty.
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        // Sandboxed build only: the App Store sandbox blocks a document's own sibling images until
        // the user grants the folder. Clicking a blocked image does the same thing; this is the
        // discoverable route when none is on screen.
        if FolderAccess.isNeeded {
            fileMenu.addItem(withTitle: "Allow Images in This Folder…",
                             action: #selector(DocumentWindowController.grantFolderAccess(_:)), keyEquivalent: "")
        }
        fileMenu.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")

        // Edit menu (copy / select-all / find)
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: #selector(MarkdownDocument.undoSourceEdit(_:)),
                         keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(MarkdownDocument.redoSourceEdit(_:)),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = 1 // NSFindPanelAction.showFindPanel → shows the find bar (usesFindBar)

        // View menu (font size)
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Increase Font Size", action: Selector(("increaseReaderFontSize:")), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Decrease Font Size", action: Selector(("decreaseReaderFontSize:")), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: Selector(("resetReaderFontSize:")), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        // Table of contents — markdown with headings only; the window controller validates it, so
        // it greys out for a .txt or a document that has no headings rather than opening empty.
        let toc = viewMenu.addItem(withTitle: "Table of Contents",
                                   action: Selector(("toggleTableOfContents:")), keyEquivalent: "t")
        toc.keyEquivalentModifierMask = []   // a bare letter, like the block keys E/I/D/U/J
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload", action: Selector(("reloadDocument:")), keyEquivalent: "r")

        // Window menu (minimize, zoom, native tabs)
        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // Help menu — Keyboard Shortcuts guide (also opens with the "?" key in the reader).
        let helpItem = NSMenuItem(); mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help"); helpItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: Selector(("showShortcutGuide:")), keyEquivalent: "?")
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - New file

    /// ⌘N. Asks which kind first, because the answer changes what the document IS here — markdown
    /// is parsed into blocks, plain text is kept line for line — and picking wrong means starting
    /// over. The choice is two buttons rather than a save panel with a type popup: the file has no
    /// home yet, and asking where to put something before knowing what it is gets the order wrong.
    @objc func newFileDocument(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New file"
        alert.informativeText = """
            Markdown is rendered — headings, lists, tables — and starts with a small outline to \
            edit. Plain text is shown exactly as typed, one block per line.

            It is saved when you press ⌘S; until then it lives only here.
            """
        alert.addButton(withTitle: "Markdown  (Untitled.md)")
        alert.addButton(withTitle: "Plain Text  (Untitled.txt)")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        let doc = MarkdownDocument()
        doc.prepareUntitled(markdown: choice == .alertFirstButtonReturn)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }

    // MARK: - Become the default app for text files (user-initiated only)

    /// The kinds this offer covers, and whether one is ticked to begin with. Only types macOS
    /// actually has a registered identity for — .conf/.env/.rst and friends resolve to a throwaway
    /// identity that no association can be pinned to, so promising them here would be a promise the
    /// system can't keep.
    ///
    /// Markdown starts ticked because that is what this app is for. The text kinds start clear:
    /// they are a capability, not the reason someone installed a Markdown reader, and quietly
    /// taking over every .csv on someone's Mac is not a favour.
    private static let claimable: [(name: String, id: String, onByDefault: Bool)] = [
        ("Markdown  (.md, .markdown)", "net.daringfireball.markdown", true),
        ("Plain text  (.txt)", "public.plain-text", false),
        ("Comma-separated values  (.csv)", "public.comma-separated-values-text", false),
        ("Tab-separated values  (.tsv)", "public.tab-separated-values-text", false),
        ("Log files  (.log)", "com.apple.log", false),
    ]

    @objc func offerToBecomeDefault(_ sender: Any?) {
        // A checkbox per kind, so the choice is the user's rather than a take-it-or-leave-it lump.
        // A kind this app ALREADY handles is shown ticked and disabled: unticking couldn't undo it
        // (macOS has no "no default app" — some other app has to claim it), and a control that
        // looks like it undoes something but doesn't is worse than no control.
        let rowHeight: CGFloat = 24
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340,
                                       height: rowHeight * CGFloat(Self.claimable.count)))
        var boxes: [(NSButton, String)] = []
        for (i, kind) in Self.claimable.enumerated() {
            let already = isDefaultApp(for: kind.id)
            let button = NSButton(checkboxWithTitle: already ? kind.name + "  — already set" : kind.name,
                                  target: nil, action: nil)
            button.state = (already || kind.onByDefault) ? .on : .off
            button.isEnabled = !already
            // Top-down reading order in a bottom-up coordinate system.
            button.frame = NSRect(x: 0, y: CGFloat(Self.claimable.count - 1 - i) * rowHeight,
                                  width: 340, height: rowHeight - 4)
            box.addSubview(button)
            if !already { boxes.append((button, kind.id)) }
        }

        let alert = NSAlert()
        alert.messageText = "Set fast-md-reader as the default app"
        alert.informativeText = "Double-clicking a ticked kind of file in the Finder will open it here. "
            + "To undo this later, select a file in the Finder, press ⌘I, and pick another app under “Open with”."
        alert.accessoryView = box
        alert.addButton(withTitle: "Set as Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let chosen = boxes.filter { $0.0.state == .on }.map { $0.1 }
        guard !chosen.isEmpty else { return }        // everything unticked = nothing to do
        applyDefaults(for: chosen)
    }

    /// Whether this app is already what macOS opens the given kind with.
    private func isDefaultApp(for identifier: String) -> Bool {
        guard let type = UTType(identifier),
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return current.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func applyDefaults(for identifiers: [String]) {
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        // The completion handlers come back on whatever queue AppKit chooses, so the tally is
        // guarded — several of them landing at once would otherwise corrupt the array.
        let lock = NSLock()
        var failures: [String] = []
        func note(_ name: String) { lock.lock(); failures.append(name); lock.unlock() }
        let group = DispatchGroup()
        for identifier in identifiers {
            let name = Self.claimable.first { $0.id == identifier }?.name ?? identifier
            guard let type = UTType(identifier) else { note(name); continue }
            group.enter()
            if #available(macOS 14.0, *) {
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                    if error != nil { note(name) }
                    group.leave()
                }
            } else {
                let status = LSSetDefaultRoleHandlerForContentType(
                    identifier as CFString, .all, bundleID as CFString)
                if status != noErr { note(name) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Report the outcome either way. A settings change with no visible result leaves the
            // user unsure whether it took — and macOS can refuse one (a managed Mac, say).
            let done = NSAlert()
            done.messageText = failures.isEmpty ? "Done" : "Partly done"
            done.informativeText = failures.isEmpty
                ? "Those files now open in fast-md-reader."
                : "macOS declined to change:\n\n\(failures.map { "•  " + $0 }.joined(separator: "\n"))\n\nYou can set these per file with ⌘I in the Finder."
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    // MARK: - Open… (own panel → known-good open path)

    @objc func openDocumentPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Markdown (rendered) + plain text (verbatim) — see DocumentTypes, the single list.
        panel.allowedContentTypes = DocumentTypes.openPanelTypes
        panel.allowsOtherFileTypes = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }

    // MARK: - Open Recent (manual population)

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

extension AppDelegate: NSMenuDelegate {
    // Rebuild the Open Recent submenu each time it opens: recent files first, then Clear Menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentDocument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }
}
