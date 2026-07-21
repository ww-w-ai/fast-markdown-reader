import XCTest
@testable import FastDocReader

/// Covers only the PURE, injectable logic in `ExternalEditor.swift`: candidate filtering,
/// per-format persistence, self-healing on a vanished app, and label construction. The AppKit
/// wiring (the titlebar accessory, the actual `NSWorkspace`/`Bundle` calls) is not testable here
/// and is verified by launching the app instead — see the sprint report.
final class ExternalEditorTests: XCTestCase {

    private let word = ExternalEditor.AppCandidate(
        bundleIdentifier: "com.microsoft.Word",
        displayName: "Microsoft Word",
        url: URL(fileURLWithPath: "/Applications/Microsoft Word.app"))
    private let pages = ExternalEditor.AppCandidate(
        bundleIdentifier: "com.apple.iWork.Pages",
        displayName: "Pages",
        url: URL(fileURLWithPath: "/Applications/Pages.app"))
    private let ourApp = ExternalEditor.AppCandidate(
        bundleIdentifier: "ai.ww-w.fast-md-reader",
        displayName: "Fast Doc Reader",
        url: URL(fileURLWithPath: "/Applications/Fast Doc Reader.app"))

    // MARK: - S7-3: exclude our own app from the candidate list

    func testFilterCandidatesExcludesOwnBundleIdentifier() {
        let filtered = ExternalEditor.filterCandidates(
            [word, ourApp, pages], excluding: "ai.ww-w.fast-md-reader")
        XCTAssertEqual(filtered.map(\.bundleIdentifier), ["com.microsoft.Word", "com.apple.iWork.Pages"])
    }

    func testFilterCandidatesIsANoOpWhenOwnAppIsNotAmongThem() {
        let filtered = ExternalEditor.filterCandidates([word, pages], excluding: "ai.ww-w.fast-md-reader")
        XCTAssertEqual(filtered, [word, pages])
    }

    // MARK: - S7-4: per-format persistence, keyed by bundle identifier

    func testDefaultsKeyIsPerExtensionAndCaseInsensitive() {
        XCTAssertNotEqual(
            ExternalEditor.defaultsKey(forExtension: "docx"),
            ExternalEditor.defaultsKey(forExtension: "odt"))
        XCTAssertEqual(
            ExternalEditor.defaultsKey(forExtension: "DOCX"),
            ExternalEditor.defaultsKey(forExtension: "docx"))
    }

    func testRememberThenRememberedAppRoundTripsPerFormat() {
        let store = FakeKeyValueStore()
        ExternalEditor.remember(word, forExtension: "docx", store: store)
        ExternalEditor.remember(pages, forExtension: "odt", store: store)

        let known = [word, pages]
        let resolve: (String) -> ExternalEditor.AppCandidate? = { id in
            known.first { $0.bundleIdentifier == id }
        }
        XCTAssertEqual(
            ExternalEditor.rememberedApp(forExtension: "docx", store: store, resolve: resolve), word)
        XCTAssertEqual(
            ExternalEditor.rememberedApp(forExtension: "odt", store: store, resolve: resolve), pages)
    }

    func testRememberedAppIsNilWhenNothingWasStored() {
        let store = FakeKeyValueStore()
        var resolveWasCalled = false
        let result = ExternalEditor.rememberedApp(forExtension: "docx", store: store) { _ in
            resolveWasCalled = true
            return self.word
        }
        XCTAssertNil(result)
        XCTAssertFalse(resolveWasCalled, "nothing stored yet, so resolve should never run")
    }

    // MARK: - S7-5: a vanished app is forgotten silently, never surfaced as an error

    func testRememberedAppForgetsAVanishedIdentifier() {
        let store = FakeKeyValueStore()
        ExternalEditor.remember(word, forExtension: "docx", store: store)

        let result = ExternalEditor.rememberedApp(forExtension: "docx", store: store) { _ in nil }

        XCTAssertNil(result)
        XCTAssertNil(store.string(forKey: ExternalEditor.defaultsKey(forExtension: "docx")),
                     "a stored id that no longer resolves must be cleared, not left dangling")
    }

    func testForgetRemovesTheStoredChoice() {
        let store = FakeKeyValueStore()
        ExternalEditor.remember(word, forExtension: "docx", store: store)
        ExternalEditor.forget(extensionKey: "docx", store: store)
        XCTAssertNil(store.string(forKey: ExternalEditor.defaultsKey(forExtension: "docx")))
    }

    // MARK: - S7-6/S7-7: label construction

    func testEditLabelNamesTheRememberedApp() {
        XCTAssertEqual(ExternalEditor.editLabel(for: word), "Edit in Microsoft Word")
        XCTAssertEqual(ExternalEditor.editLabel(for: pages), "Edit in Pages")
    }

    func testEditLabelFallsBackWhenNothingIsRememberedYet() {
        // S7-7: no remembered app → body click must open the menu, not launch anything, so the
        // label itself must not name a specific app.
        XCTAssertEqual(ExternalEditor.editLabel(for: nil), "Edit in Another App…")
    }

    // MARK: - Display name derived from an app's URL

    func testDisplayNameStripsTheAppExtension() {
        XCTAssertEqual(
            ExternalEditor.displayName(forAppURL: URL(fileURLWithPath: "/Applications/Microsoft Word.app")),
            "Microsoft Word")
        XCTAssertEqual(
            ExternalEditor.displayName(forAppURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
            "TextEdit")
    }
}

/// In-memory stand-in for `UserDefaults` so persistence logic is testable without touching real
/// defaults or leaking state between test runs.
private final class FakeKeyValueStore: ExternalEditor.KeyValueStore {
    private var storage: [String: String] = [:]
    func string(forKey key: String) -> String? { storage[key] }
    func set(_ value: String?, forKey key: String) { storage[key] = value }
    func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
}
