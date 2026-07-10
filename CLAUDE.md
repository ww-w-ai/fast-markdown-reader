# fast-md-reader — dev notes (read before continuing)

Native macOS Markdown **viewer** (read-only). Pure Swift/AppKit + TextKit, SwiftPM executable.
No web runtime for text; mermaid is the only WebKit user and only on a cache miss.

## Build / test / run

- **Build app**: `./Scripts/make-app.sh [debug|release]` → `FastMDReader.app` in repo root (ad-hoc signed).
- **Toolchain (MUST)**: standalone Command Line Tools has a mismatched SwiftPM ManifestAPI → `swift build` breaks. Always use Xcode's toolchain. `make-app.sh` auto-sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if unset.
- **Tests**: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (34 tests, keep green).
- **Deploy for local use**: the running app lives at `/Applications/FastMDReader.app`. `make-app.sh` builds in the repo dir → you must `cp -R FastMDReader.app /Applications/` and relaunch.
- **Quit cleanly, never `pkill`**: `osascript -e 'tell application "FastMDReader" to quit'`. Force-kill loses recent-docs persistence and can leave state inconsistent.
- **⌘R (Reload)** reloads the *document* content only — it does NOT pick up a new app build. A code change needs rebuild + relaunch.

## Layout / files

- `App/AppDelegate.swift` — menu bar built **in code** (no MainMenu.nib). Any standard shortcut or menu must be added here.
- `App/MarkdownDocument.swift` — `NSDocument`; render pipeline, presize + prerender, lazy media reconcile.
- `App/DocumentWindowController.swift` — text view, scroll, tabs, find, source-edit panel.
- `Render/MarkdownRenderer.swift` — CommonMark/GFM → `NSAttributedString`. `Render/MermaidRenderer.swift` — WebKit → cached PDF. `Render/CodeHighlighter.swift`.
- `Cache/MermaidCache.swift` — content-addressed disk cache.
- `Resources/Info.plist` — bundle config. `Scripts/make-app.sh` — build+bundle+ad-hoc sign.

## Hard-won invariants (DON'T regress)

1. **Scrollbar stability = decouple media SIZE from PIXELS.** An `NSTextAttachment` with `image==nil` (not-yet-loaded / purged) collapses to ~0 height → total height and the scrollbar swing on scroll. Fix in place: `SizedAttachmentCell` owns `reservedSize` independent of the image. Loading/purging pixels must **redraw only, never touch layout** (`redrawGlyphs`) — if size is unchanged, do NOT call `storage.edited`/`ensureLayout`. This cost **4 debugging rounds**; keep the size/pixel split intact.
2. **Uncached docs must behave like cached ones.** On first open, `prerenderAllDiagrams` renders every uncached diagram to the disk cache (bounded concurrency, `cap=min(3,…)`), then `presizeKnownMedia` reserves each exact area and lays out **once**. After that, sizes never change on scroll.
3. **`invalidateDisplay` alone does NOT draw a newly-set attachment image** — you need `storage.edited(.editedAttributes, …)`. (Learned the hard way when diagrams went invisible.)
4. **Mermaid cache lives in `FileManager.default.temporaryDirectory/fast-md-reader/mermaid`**, NOT `~/Library/Caches`. When testing "uncached cold start", clear THAT dir.
5. **Fresh-DB/fresh-open tests are fake-green for the cache/migration class** — they create the target state directly and skip the render path. Cold-start behavior must be tested by actually clearing the mermaid cache dir and relaunching.
6. **NSDocumentClass in Info.plist must be module-qualified**: `FastMDReader.MarkdownDocument` (a SwiftPM executable, so NSDocumentController can't find a bare class name).
7. **Open Recent**: AppKit's automatic population does NOT attach to a code-built menu → it's populated manually via a menu delegate in `AppDelegate` reading `recentDocumentURLs`. macOS prunes deleted files from the list (a deleted test file → correctly shows "No Recent Files").

## Debugging discipline (this app specifically)

- **Synthetic scroll is blocked by accessibility** — CGEvent scroll doesn't reach the window. You cannot drive scrolling programmatically; **the user reproduces, you read logs.** Log total height / frame height / scrollY per reconcile and read them.
- Temporary instrumentation goes to `/tmp/fmd-*.log`. **Remove all of it (delete `DebugLog.swift`, strip log calls) before committing** and clean `/tmp/fmd-*`.
- Verify visual/pixel behavior with a screenshot only when the judgment is truly visual; deterministic size assertions are proven by the logs/code, not screenshots.

## Commit / distribution

- **Solo local app → commit directly to `main`** (established pattern: `a80271e`, `57b485b`, `bce0ead`). No dev branch. Stage by filename (exclude `.bkit/`).
- **Distribution**: ad-hoc signed, **arm64 only**. Friends: zip with `ditto -c -k --keepParent`, recipient clears quarantine once — see README "Share it with someone". Notarized public build → `docs/NOTARIZATION.md`.
- Intel support needs a universal build (`swift build --arch arm64 --arch x86_64`) before packaging.
