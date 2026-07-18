import AppKit

/// Sandbox folder grants for a document's own local media.
///
/// The sandbox hands the app exactly one thing: the file the user opened. A document's sibling
/// `![](diagram.png)` is a DIFFERENT file, so it is denied — and macOS never prompts, because the
/// sandbox refuses before TCC is consulted and there is no "Documents folder" entitlement to ask
/// for. (Verified: every local path form fails sandboxed while remote URLs load fine.)
///
/// The only sanctioned way through is to have the user point at the folder themselves via an open
/// panel, then persist that grant as a security-scoped bookmark. Marked 2, iA Writer and MWeb all
/// do exactly this.
///
/// Only the App Store build is sandboxed; the Developer ID build reads siblings directly and never
/// reaches this code (`isNeeded` is false there).
enum FolderAccess {
    private static let defaultsKey = "grantedFolderBookmarks"   // [folder path: bookmark data]

    /// Scoped URLs currently being accessed. MUST be retained: access ends when the URL deallocates.
    private static var open: [String: URL] = [:]

    /// False for the unsandboxed Developer ID build, where every local file is readable anyway.
    static var isNeeded: Bool = {
        // The sandbox redirects the home directory into a container; that's the cheapest reliable
        // signal, and it needs no entitlement to check.
        NSHomeDirectory().contains("/Containers/")
    }()

    // MARK: - Restore

    /// Re-open every folder the user has already granted. Call once at launch, BEFORE any document
    /// opens, so restored access is live by the time media load.
    static func restoreGrants() {
        guard isNeeded else { return }
        for (path, data) in stored() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            open[path] = url
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                var all = stored(); all[path] = fresh; save(all)
            }
        }
    }

    // MARK: - Query

    /// Whether this exact file can be read right now — the honest test, since a grant may cover it
    /// via an ancestor folder, or the app may not be sandboxed at all.
    static func canRead(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    /// True when a grant would plausibly help: sandboxed, a local file, and currently unreadable.
    static func needsGrant(for url: URL) -> Bool {
        isNeeded && url.isFileURL && !canRead(url)
    }

    /// What to pre-select in the panel: the top-level home folder the target lives in (Documents,
    /// Desktop or Downloads), not its own subfolder. A grant covers everything beneath it, so picking
    /// ~/Documents once answers every document under it — asking per-subfolder would mean a prompt for
    /// every project. Anything outside those three (say ~/projects/notes) has no natural top level, so
    /// the enclosing folder is the sensible default — or the target itself when it already is one.
    static func suggestedFolder(for target: URL) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // Sandboxed: NSHomeDirectory() is the container, so build the real home from the user name.
        let realHome = isNeeded ? URL(fileURLWithPath: "/Users/\(NSUserName())") : home
        let tops = ["Documents", "Desktop", "Downloads"].map { realHome.appendingPathComponent($0) }
        let path = target.standardizedFileURL.path
        for top in tops where path.hasPrefix(top.path + "/") { return top }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
        return exists && isDir.boolValue ? target : target.deletingLastPathComponent()
    }

    // MARK: - Request

    /// Ask the user to grant the folder, pre-selected, and remember it. `completion(true)` means the
    /// grant is live now — the caller should reload its media.
    ///
    /// Deliberately user-initiated (they click the placeholder or the menu item): a panel that
    /// appears by itself on open reads as a broken app, and Apple's reviewers see it the same way.
    static func requestAccess(to folder: URL, in window: NSWindow?, what: String = "images",
                              completion: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = "Allow Fast Markdown Reader to read \(what) in “\(folder.lastPathComponent)”. "
                      + "This covers everything inside it — pick a narrower folder if you'd rather."
        panel.prompt = "Allow"
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let picked = panel.url else { return completion(false) }
            completion(grant(picked))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) }
        else { handle(panel.runModal()) }
    }

    /// Persist a picked folder and start using it. Returns false if the bookmark can't be made.
    @discardableResult
    static func grant(_ folder: URL) -> Bool {
        guard let data = try? folder.bookmarkData(options: [.withSecurityScope],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        var all = stored(); all[folder.path] = data; save(all)
        // The panel's own grant is already live for this launch; keep the URL so it survives, and
        // resolving the bookmark is what makes it survive the NEXT launch.
        _ = folder.startAccessingSecurityScopedResource()
        open[folder.path] = folder
        return true
    }

    // MARK: - Storage

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private static func save(_ v: [String: Data]) {
        UserDefaults.standard.set(v, forKey: defaultsKey)
    }
}
