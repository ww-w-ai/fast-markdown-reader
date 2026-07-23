import AppKit
import UniformTypeIdentifiers

/// R5: "Edit in <App>" — hands a read-only office document off to a real editor. Split into a
/// PURE half (this enum's static functions, fully unit-tested — candidate filtering, per-format
/// persistence, self-healing on a vanished app, label text) and a GLUE half (`ExternalEditorService`,
/// below) that actually calls `NSWorkspace`/`Bundle`. The glue is not unit-tested — it has no
/// injectable seam worth faking beyond what the pure half already covers, and is verified by
/// launching the app (see the sprint report).
enum ExternalEditor {

    /// A candidate editor app, already resolved to a bundle identifier — never remembered by path,
    /// since a path moves when an app updates or is relocated (see CLAUDE.md distribution notes on
    /// per-app identity).
    struct AppCandidate: Equatable {
        let bundleIdentifier: String
        let displayName: String
        let url: URL
    }

    /// Narrow seam over `UserDefaults` so persistence is testable without touching real defaults.
    protocol KeyValueStore {
        func string(forKey key: String) -> String?
        func set(_ value: String?, forKey key: String)
        func removeObject(forKey key: String)
    }

    /// The remembered choice is keyed by FILE EXTENSION (S7-4) — the app wanted for `.docx` is not
    /// necessarily the one for `.odt`.
    static func defaultsKey(forExtension ext: String) -> String {
        "ExternalEditor.chosenApp.\(ext.lowercased())"
    }

    /// S7-3: this app is a plausible default handler for these types once it registers them (S4),
    /// so offering it in "edit in another app" would be a loop that does nothing. Order preserved.
    static func filterCandidates(_ candidates: [AppCandidate], excluding ownBundleIdentifier: String) -> [AppCandidate] {
        // Exclude OUR app whichever variant is running or listed: a dev build's identifier ends in
        // `.dev` while the installed release's does not, so a plain `!=` let the release "Fast Document
        // Reader" show up in a dev build's own "Edit in…" list (and vice-versa). Compare on the base
        // identifier (the `.dev` suffix stripped from both sides) so both variants are filtered out.
        func base(_ id: String) -> String { id.hasSuffix(".dev") ? String(id.dropLast(4)) : id }
        let own = base(ownBundleIdentifier)
        return candidates.filter { base($0.bundleIdentifier) != own }
    }

    /// Reads the remembered app for a format. `resolve` re-checks that the bundle identifier still
    /// resolves to an installed app; if it doesn't (the app was deleted), the stale entry is
    /// cleared here — S7-5: forget silently and re-prompt, never show a dead button.
    static func rememberedApp(
        forExtension ext: String, store: KeyValueStore,
        resolve: (String) -> AppCandidate?
    ) -> AppCandidate? {
        let key = defaultsKey(forExtension: ext)
        guard let id = store.string(forKey: key) else { return nil }
        if let app = resolve(id) { return app }
        store.removeObject(forKey: key)
        return nil
    }

    static func remember(_ candidate: AppCandidate, forExtension ext: String, store: KeyValueStore) {
        store.set(candidate.bundleIdentifier, forKey: defaultsKey(forExtension: ext))
    }

    static func forget(extensionKey ext: String, store: KeyValueStore) {
        store.removeObject(forKey: defaultsKey(forExtension: ext))
    }

    /// S7-7: nothing remembered yet → the label must not name a specific app, so the body click
    /// opens the picker menu instead of launching anything.
    static func editLabel(for app: AppCandidate?) -> String {
        guard let app else { return "Edit in Another App…" }
        return "Edit in \(app.displayName)"
    }

    /// "Microsoft Word.app" → "Microsoft Word". Pure string arithmetic on the URL — no disk access,
    /// so it works the same whether or not the app is actually installed.
    static func displayName(forAppURL url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// `UserDefaults.set(_:forKey:)` is overloaded (`Any?`, `URL?`, `Bool`, …), so it does not conform
/// to `KeyValueStore` (which wants exactly `String?`) by direct extension — this thin wrapper picks
/// the overload we want and satisfies the protocol.
final class UserDefaultsKeyValueStore: ExternalEditor.KeyValueStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
}

/// GLUE: the one place that actually talks to `NSWorkspace`, `Bundle` and `UserDefaults` for R5.
/// Everything here is a thin, deterministic wrapper around system calls with no branching logic of
/// its own — the branching lives in `ExternalEditor`'s pure functions above, which this composes.
final class ExternalEditorService {
    private let store: ExternalEditor.KeyValueStore
    private let ownBundleIdentifier: String

    init(store: ExternalEditor.KeyValueStore = UserDefaultsKeyValueStore(),
         ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") {
        self.store = store
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    /// Turns an app's URL (e.g. one chosen via `NSOpenPanel`'s `Choose Other App…`) into a
    /// candidate. `Bundle(url:)` does real disk I/O, so unlike the pure half of this file this is
    /// not unit-tested — it is exercised by launching the app (see the sprint report).
    func appCandidate(from url: URL) -> ExternalEditor.AppCandidate? { candidate(from: url) }

    private func candidate(from url: URL) -> ExternalEditor.AppCandidate? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return ExternalEditor.AppCandidate(
            bundleIdentifier: id, displayName: ExternalEditor.displayName(forAppURL: url), url: url)
    }

    /// Every app that can open this extension, ours excluded (S7-3), via the modern
    /// `NSWorkspace.urlsForApplications(toOpen:)` — never the deprecated path-string APIs.
    func candidates(forExtension ext: String) -> [ExternalEditor.AppCandidate] {
        guard let type = UTType(filenameExtension: ext) else { return [] }
        let all = NSWorkspace.shared.urlsForApplications(toOpen: type).compactMap(candidate(from:))
        return ExternalEditor.filterCandidates(all, excluding: ownBundleIdentifier)
    }

    /// The remembered app for this format, self-healing if it was uninstalled (S7-5).
    func rememberedCandidate(forExtension ext: String) -> ExternalEditor.AppCandidate? {
        ExternalEditor.rememberedApp(forExtension: ext, store: store) { [weak self] id in
            guard let self, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            else { return nil }
            return self.candidate(from: url)
        }
    }

    func remember(_ candidate: ExternalEditor.AppCandidate, forExtension ext: String) {
        ExternalEditor.remember(candidate, forExtension: ext, store: store)
    }

    /// S7-8: hand the document off via the modern configuration-based API.
    func open(_ documentURL: URL, with app: ExternalEditor.AppCandidate,
              completion: @escaping (Error?) -> Void = { _ in }) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([documentURL], withApplicationAt: app.url, configuration: config) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
