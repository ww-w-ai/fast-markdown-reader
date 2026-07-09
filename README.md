# fast-md-reader

**A featherweight, native macOS Markdown viewer that never balloons.** Other viewers —
especially Electron ones — creep from a few hundred megabytes toward a gigabyte the longer
you leave them open. fast-md-reader is pure Swift/AppKit: it opens, renders, and gets out of
the way.

| | fast-md-reader |
|---|---|
| Engine | 100% native AppKit + TextKit — **no web runtime** |
| Idle CPU | **0%** (no timers, no polling, no background web process) |
| Memory | **flat under use** — held steady at ~127 MB across 9 large docs opened in a row, **reclaimed to ~52 MB** when documents close. No growth over a session. |
| Long docs | Non-contiguous layout lays out only the viewport → a 4,000-paragraph file opens and scrolls fast |
| Diagrams | mermaid rendered once to a cached vector PDF; cached/no-diagram docs **never spawn a web view** |
| Editing | none — read-only viewer, opens files read-only |

## What it does

- Renders Markdown (CommonMark + GFM tables) natively to styled text — headings, emphasis,
  lists, quotes, links, inline code.
- Fenced code blocks render as distinct **rounded cards** with native syntax highlighting
  (swift, js/ts, python, bash, json) and a per-block **Copy** button.
- **mermaid** diagrams render on demand through a transient offscreen WebKit view, snapshotted
  to a vector PDF and cached (in-RAM + temp dir, content-addressed). Reopen a file and the
  diagram appears instantly with zero web/JS cost.
- A **reading cursor** with a full keyboard scheme (below), softly highlighting the current
  line and keeping it on screen.
- **⌘F** find bar, **⌘±** font size (persisted across launches), automatic **dark/light**.
- Opens from Finder (double-click a `.md`), native window **tabs**, recent documents.

## Build & run

Requires macOS 13+. Build assembles a `.app` bundle with ad-hoc signing:

```bash
./Scripts/make-app.sh
open FastMDReader.app
```

> Toolchain note: if a standalone Command Line Tools install has a mismatched SwiftPM
> ManifestAPI, `make-app.sh` automatically prefers Xcode's toolchain via `DEVELOPER_DIR`.
> Make it permanent with `sudo xcode-select -s /Applications/Xcode.app` or by updating CLT.

Run the tests with `swift test` (Xcode toolchain: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`).

## Install

Copy `FastMDReader.app` to `/Applications`. To make it your default Markdown viewer:
right-click any `.md` in Finder → **Get Info** → **Open with** → choose fast-md-reader →
**Change All…**.

## Keyboard (reading cursor)

Navigation **selects the unit it moves to**, so ⌘C copies it immediately. No Shift is used
(Shift stays free for system selection), and the keys avoid conflicts with standard macOS
shortcuts.

| Key | Action (and what gets selected) |
|---|---|
| **⌥← / ⌥→** | Previous / next **sentence** (selects it) |
| **⌥↑ / ⌥↓** | Previous / next **paragraph** (selects it) |
| **⌘← / ⌘→** | Start / end of the current **line** (selects the line) |
| **[ / ]** | Previous / next **heading** (selects the whole subsection) |
| **click** (no drag) | Selects the **sentence** under the cursor |
| **number then Enter** | Jump to the Nth heading |
| **Space / ⇧Space** | Page down / up |
| **⌘↑ / ⌘↓** | Document start / end |
| **⌘F** | Find in document |
| **⌘+ / ⌘−** | Font size (persists to the next launch) |
| **↑ / ↓** | Scroll one line |

Page / number-jump / document-ends move without selecting (too-large or jump moves stay
caret-only). Mouse drag-selection + copy also work. Each code block has **Copy** and a
**Wrap** toggle (fold long lines vs. no-wrap with its own horizontal scroll).

## How the lightness holds

- No web runtime for text — a single native `NSAttributedString` renderer.
- mermaid is the only WebKit user, and only on a **cache miss**; the web view is released the
  instant its PDF snapshot completes. No-diagram and fully-cached documents touch no web/JS.
- Non-contiguous TextKit layout means long documents lay out lazily, per viewport.
- Overlays (copy buttons) are placed only for the **visible** code blocks, never forcing
  layout of off-screen content.

## Third-party

See `THIRD-PARTY-NOTICES.md` — swift-markdown (Apache-2.0), mermaid (MIT).
