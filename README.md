# Fast Document Reader

> **.md .docx reader, built for the AI era**

**AI writes it. You're the one reading it.** Plans, specs, summaries, transcripts — it all lands as
Markdown now, and reading it has quietly become most of the job. Your reader shouldn't be the slow
part of that. Markdown first; the `.docx` a collaborator sends opens right beside it, read-only, and
plain text too.

Most Markdown apps are a web browser wearing a costume, which is why they take a beat to open and
why memory climbs the longer you leave them running. This one is pure Swift/AppKit/TextKit:
**0% idle CPU**, **~127 MB held flat across 9 large documents opened back to back**, and **~52 MB
reclaimed** when they close. No timers, no polling, no background web process.

It is the only native Mac Markdown viewer that renders **mermaid diagrams and TeX formulas with both
engines bundled in the app** — offline, each one cached once as a vector PDF and never re-rendered
([`MermaidCache.swift`](Sources/FastDocReader/Cache/MermaidCache.swift)). Images and diagrams
outside the viewport **release their pixels but keep their exact height**, so memory stays flat and
the scrollbar never jumps
([`SizedAttachmentCell.swift`](Sources/FastDocReader/Render/SizedAttachmentCell.swift)).

A reader, on purpose — it opens, renders, and gets out of the way. There is no cursor blinking at
you and no mode to leave. But it is no longer only a viewer: when something in the text is wrong,
right-click that block (or press a key): **Edit** rewrites just its Markdown source, and **Add Below**,
**Move** and **Delete** restructure the document a block at a time. Changes are yours until you
press ⌘S, and only the block you touched is redrawn — **9 ms on a 64,000-character file, 29 ms on
1.2 MB**, so undo stays instant in documents where other apps stall.

**T** brings up a sidebar of every heading, and clicking one moves the reading cursor there — so the
next keystroke acts on that section. Press **⌘N** for a new file: Markdown starts with a small
outline you can immediately edit, plain text starts empty.

It opens **plain text too** — `.txt`, `.csv`, `.log` — shown verbatim in a fixed-width font, one
block per line, with `#` and `*` left as the characters they are. Files written on Windows or Linux
arrive intact: CP949, UTF-16, Latin-1 and friends are detected rather than assumed, and a file is
**saved back in the encoding it came in**, CRLF and all.

It also opens **Word (`.docx`, `.docm`, `.dotx`, `.dotm`) and OpenDocument (`.odt`) files** — read-only,
so nothing you didn't type can change, but shown as the author formatted it: headings, tables with
merged cells, cell-level images and lists, footnotes, tracked changes, internal links and bookmarks,
equations (drawn through the same bundled formula engine as Markdown math), charts and diagrams, and
right-to-left text. Colour, font and size follow the document — your reading-size preference
multiplies on top of what the author set, the same way Word's own zoom does. The titlebar says
plainly that these formats are read-only, with a one-click hand-off to whatever app you'd rather edit
them in.

| | Fast Document Reader |
|---|---|
| Engine | 100% native AppKit + TextKit — **no web runtime for text** |
| Idle CPU | **0%** — no timers, no polling, no background web process |
| Memory | **flat under use** — ~127 MB across 9 large docs, ~52 MB reclaimed on close |
| Long docs | The whole document is laid out up front, so the **scrollbar is honest from the first frame** — a 4,000-paragraph file opens instantly and never resizes under you |
| Editing long docs | Only the edited block is re-rendered — **9 ms on 64k characters, 29 ms on 1.2 MB** |
| Plain text | `.txt` · `.csv` · `.log` shown **verbatim**, one block per line — nothing reinterpreted as Markdown |
| Word / OpenDocument | `.docx`/`.docm`/`.dotx`/`.dotm`/`.odt` — **read-only**, formatting, tables, equations, charts and RTL text shown as authored |
| Extract for an AI | `--extract` turns a `.docx`/`.odt` into **clean Markdown on stdout** — headless, so an AI reads it without spending tokens parsing the zip |
| Encodings | CP949 · UTF-16 · Latin-1 detected, not assumed — **saved back in the same encoding**, CRLF kept |
| Diagrams | **mermaid bundled** — renders offline, cached as vector PDF, never re-rendered |
| Math | **KaTeX bundled** — `$$…$$` and ```` ```math ```` render offline, vector, cached the same way |
| Images | Off-screen pixels freed, exact height kept — **no reflow, no scrollbar jitter** |
| Code | **34 languages** highlighted natively — one-pass scanner, no JS, per-block **Copy** and **Wrap** |
| Editing | Reader first — **E** edit · **I** add below · **U/J** move · **D** delete, saved on ⌘S |
| Navigation | **T** opens a table of contents built from the document's own headings — click to jump |

## Hand a Word file to an AI, as clean Markdown

Point an AI at a `.docx` or `.odt` and it burns tokens unzipping and parsing the XML itself. Run the
same engine headless instead — no window, no Dock icon — and it prints clean Markdown to stdout:

```sh
FastDocReader.app/Contents/MacOS/FastDocReader --extract report.docx
```

Because it reuses the reader's **own** office parser, the Markdown mirrors what you'd see on screen:
headings, lists with the document's real numbering, bold/italic/strikethrough/links, simple tables as
pipe tables, standalone formulas as `$$…$$`, images and charts as honest placeholders. Mapping stays
conservative on purpose — anything a Markdown table can't hold safely (merged cells, block content in
a cell) is dumped as literal text inside a `<raw>…</raw>` marker rather than a fabricated grid that
would read as correct, and a one-line note at the top explains the marker. It reads the Word family
(`.docx` `.docm` `.dotx` `.dotm`) and `.odt` (converted), plus `.md`/`.txt` verbatim, and exits
non-zero on anything it can't read so a script can trust the output.

## Diagrams render offline, once

The mermaid engine ships inside the app — no CDN, no network, nothing to load. A diagram is
rendered a single time to a **vector PDF**, cached by content hash, and reused forever. Open the
same document again and diagrams appear instantly with zero web or JS cost. A document with no
diagrams never creates a web view at all.

![mermaid diagrams rendered natively](assets/screenshots/mermaid.png)

## Images stay sharp without staying in memory

Every image and diagram **owns its layout size independently of its pixels**. Scroll away and the
pixels are released; scroll back and they return — but the reserved height never changes, so the
document length is stable and the scrollbar never swings. Sizes are measured up front (image
headers, cached PDFs, and remote images via a range request), so the page is laid out **once**.

![images and rich Markdown](assets/screenshots/images.png)

## Formulas, drawn once and cached forever

Math ships the same way diagrams do: KaTeX is **inside the app**, fonts and all, so `$$…$$` (and
GitHub's ```` ```math ```` fence) render with no internet. Each formula is drawn a single time to a
vector PDF and reused forever — zoom as far as you like, it stays sharp.

Reading the TeX from the source, not the parsed text, is what makes it correct: Markdown claims `_`
and `^` as emphasis, so `$$a_1^2$$` would otherwise come back as *a12* — wrong maths, which is worse
than none ([`MarkdownRenderer.swift`](Sources/FastDocReader/Render/MarkdownRenderer.swift)).

## Code blocks are real cards

![code cards and tables](assets/screenshots/code.png)

Fenced blocks render as rounded cards with a language label, a **Copy** button and a **Wrap** toggle
— no JavaScript involved. **34 languages** are highlighted natively, under the names people actually
type (`yml`, `golang`, `c++`, `c#`, `sh`, `postgres`, `tsx`, `patch`…):

> swift · js · ts · go · rust · java · kotlin · c · c++ · c# · scala · dart · php · objc · python ·
> ruby · perl · lua · r · elixir · haskell · bash · powershell · dockerfile · makefile · json · yaml ·
> toml · ini · sql · html · xml · css · diff

The highlighter is a single left-to-right scanner, not a stack of regexes painting over each other
([`CodeHighlighter.swift`](Sources/FastDocReader/Render/CodeHighlighter.swift)). That's what keeps a
URL's `//` inside a string from turning the rest of the line into a comment — the bug you've seen in
every editor that gets it wrong. Tables, task lists and strikethrough come from CommonMark + GFM.

## Try it on real documents

The [`demo/`](demo/) folder has four documents, each one a case that makes readers stumble:
[34 languages in code blocks](demo/code-blocks.md), [formulas](demo/math.md), [twelve
photographs of differing heights](demo/images.md), and [the whole of *Moby-Dick*](demo/moby-dick.md) — 213,000 words in one
file, which should open the instant you double-click it.

## Install

**Apple Silicon (arm64) only.** Requires macOS 13+.

Download the notarized zip, unzip it, drag `FastDocReader.app` to `/Applications`, double-click.
No Gatekeeper prompt and no `xattr` step — the app is signed with a Developer ID and stapled.

To open files here by default: **Fast Document Reader → Set as Default App…**, which lists the kinds it
can claim with a checkbox each — Markdown ticked, text formats yours to choose. Per file, the Finder
route still works: right-click → **Get Info** → **Open with** → **Change All…**.

## Build from source

```bash
./Scripts/make-app.sh        # builds FastDocReader.app (ad-hoc signed, unsandboxed)
open FastDocReader.app
```

Tests: `swift test`.

> **Toolchain note:** a standalone Command Line Tools install can ship a mismatched SwiftPM
> ManifestAPI that breaks `swift build`. `make-app.sh` prefers Xcode's toolchain automatically via
> `DEVELOPER_DIR`; make it permanent with `sudo xcode-select -s /Applications/Xcode.app`.

Signing identity and App Store Connect key ids are **not** in this repo — the release scripts read
them from `$KEYCHAIN_DIR/signing.env` (default `~/Documents/DEV/ww-w-ai/.keychains/`) and name the
missing variable if it isn't there. To sign as yourself, export your own; no code changes:

```bash
export IDENTITY="Developer ID Application: <You> (<TEAMID>)"
export NOTARY_PROFILE="<your notarytool keychain profile>"
./Scripts/notarize.sh        # signed + notarized + stapled zip
```

### Two builds, one difference

The direct download is **not sandboxed**; the Mac App Store build is (the store requires it).
Sandboxed, macOS grants an app only the file you opened — a document's own `![](diagram.png)`
sibling is a different file and is denied, with no prompt, because the sandbox refuses before macOS
asks and no "Documents folder" entitlement exists. So the store build asks once, per folder, and
remembers it; the direct build simply reads them. `SANDBOX=1 ./Scripts/make-app.sh` builds the
sandboxed shape locally.

## Keyboard and mouse

The reading cursor moves in whole units — line, sentence, paragraph and heading. Down the page
**fn** steps the coarse `#` outline (top-level headings only) and **⌘** steps every heading, **⌥**
pages, and **fn⌘** jumps to the very top or bottom; across a line **⌘** is the whole line, **⌥** a
sentence, **fn** a paragraph. Hold **⇧** and the same move becomes a selection, so ⌘C grabs exactly
what you just crossed.

| Key | Moves the cursor to… |
|---|---|
| **⌘← / ⌘→** | Start / end of the line |
| **⌥← / ⌥→** | Previous / next sentence |
| **fn← / fn→** | Previous / next paragraph (a heading, list, code block or table is one stop) |
| **fn↑ / fn↓** | Previous / next top-level `#` heading (the document's coarse outline) |
| **⌘↑ / ⌘↓** | Previous / next heading (any level) |
| **⌥↑ / ⌥↓** | Page up / down (a few lines overlap so you keep your place) |
| **fn⌘↑ / fn⌘↓** | Start / end of the document |
| **⇧ + any of the above** | The same move, selecting everything it crosses |
| **Space / ⇧Space** | Page down / up |
| **⌘F** | Find in document |
| **⌘+ / ⌘− / ⌘0** | Font size (persists to the next launch) / actual size |

Mouse:

| Action | What it does |
|---|---|
| **Click the left margin** beside a block | Selects that whole block and copies it — a heading takes its entire section, a code block its raw source |
| **Click a diagram, formula or image** | Opens it enlarged in a zoomable window (pinch or `⌘+`/`⌘−`, `⌘0` to fit, `esc` to close) |
| **Select text, then ⌘-click it** | Opens it — a file path, a URL, or a bare domain |
| **Drag** | Ordinary text selection, as anywhere on the Mac |

The page holds still and the cursor moves inside it — the view scrolls only when the cursor would
leave the screen, and then by the least it can.

**Fix a typo without leaving:** right-click a block → **Edit** (or press **E**) opens just that
block's Markdown source; select across several blocks first and they open **merged as one**. **⌘↵**
writes it back to the file, **esc** discards. That is the only action that ever writes to your
document.

## License

MIT — see [LICENSE](LICENSE). Third-party attributions: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Built by [DubDubDub Corp.](https://ww-w.ai)
