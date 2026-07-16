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
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        // Open… — do NOT use NSDocumentController.openDocument(_:) (its built-in panel path crashes
        // immediately in this code-menu / ad-hoc-signed SwiftPM app). Present our OWN NSOpenPanel and
        // route the result through openDocument(withContentsOf:) — the exact path Open Recent uses,
        // which is known-good.
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
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")

        // Edit menu (copy / select-all / find)
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
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

    // MARK: - Open… (own panel → known-good open path)

    @objc func openDocumentPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Markdown + any plain text (be permissive — the reader can render any text file).
        var types: [UTType] = [.plainText, .text]
        if let md = UTType("net.daringfireball.markdown") { types.insert(md, at: 0) }
        if let pub = UTType("public.markdown") { types.insert(pub, at: 0) }
        panel.allowedContentTypes = types
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
