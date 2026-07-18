# Demo documents

Open these in Fast Markdown Reader. Each one exists to show a claim the app makes, and most of them
are the exact cases that make other readers stumble.

| Document | What to look at |
|---|---|
| [`code-blocks.md`](code-blocks.md) | 34 languages highlighted natively. Every snippet hides a URL or a `#` **inside a string** — the case that makes naive highlighters grey out the rest of the line. Nothing here should be grey except real comments. |
| [`math.md`](math.md) | Formulas between `$$`, drawn by the app itself with no internet. Zoom in: they stay sharp, because they're vector art, not pictures. |
| [`images.md`](images.md) | Twelve public-domain photographs of differing heights. Scroll hard, both ways — the scroll bar shouldn't twitch and your place shouldn't jump. |
| [`moby-dick.md`](moby-dick.md) | The whole novel — 213,000 words in one file, public domain. It should open instantly, the scroll bar should be right from the first frame, and the contents list jumps. |

## If images don't appear

Mac App Store builds are sandboxed, which means macOS hands the app the single file you opened and
nothing else — a document's own pictures are a *different* file, so they're blocked, and macOS never
asks. Click the **"Click to allow images in this folder"** placeholder (or **File → Allow Images in
This Folder…**) and pick the folder once. It's remembered from then on.

The direct download isn't sandboxed and reads them straight away.
