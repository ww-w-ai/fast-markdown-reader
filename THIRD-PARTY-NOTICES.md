# Third-Party Notices

This product includes software developed by third parties. All components below are under
permissive licenses (MIT, BSD-2-Clause, Apache-2.0, MPL-2.0); none is copyleft.

Standard license texts: [MIT](https://opensource.org/license/mit),
[BSD-2-Clause](https://opensource.org/license/bsd-2-clause),
[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0),
[MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0/).

## Swift dependencies (fetched at build time)

### swift-markdown — Apache-2.0
- Copyright: The Swift Project Authors
- https://github.com/swiftlang/swift-markdown

### swift-cmark (`gfm` branch) — BSD-2-Clause and MIT
Pulled in transitively by swift-markdown. Multi-licensed, with several named holders:
- BSD-2-Clause: Copyright (c) 2014, John MacFarlane (cmark core)
- MIT: Copyright (c) 2012, Github, Inc. (buffer); Copyright (c) 2012, Vicent Marti (houdini);
  Copyright (c) 2008-2009, Björn Höhrmann and Public Software Group (utf8 decoder);
  Copyright (c) 2015, Karl Dubost (normalization)
- https://github.com/swiftlang/swift-cmark

## Vendored files (copied into this repository)

### mermaid v10.9.6 — MIT
- Copyright: Knut Sveidqvist and mermaid contributors
- https://github.com/mermaid-js/mermaid
- Bundled verbatim as `Resources/mermaid.min.js` (sha256
  `eda3a0ad572bbe69a318c1be0163e8233dd824f3f12939e5168feba207767151`, byte-identical to the
  official `mermaid@10.9.6/dist/mermaid.min.js`). Used transiently in an offscreen WebKit view,
  only on a diagram cache miss.

### Libraries embedded inside `Resources/mermaid.min.js`

That file is mermaid's pre-bundled distribution, so it also contains these projects verbatim.
They are listed here because copying the bundle copies them too.

| Library | License | Copyright |
|---|---|---|
| [js-yaml](https://github.com/nodeca/js-yaml) | MIT | Vitaly Puzrin and contributors |
| [DOMPurify](https://github.com/cure53/DOMPurify) | Apache-2.0 **or** MPL-2.0 (dual — either may be chosen) | Dr.-Ing. Mario Heiderich, Cure53 |
| [KaTeX](https://github.com/KaTeX/KaTeX) | MIT | Khan Academy and contributors |
| [cytoscape.js](https://github.com/cytoscape/cytoscape.js) | MIT | The Cytoscape Consortium |
| [dagre / dagre-d3](https://github.com/dagrejs/dagre) | MIT | Chris Pettitt and contributors |
| [D3](https://github.com/d3/d3) | ISC | Mike Bostock |

Smaller snippets carrying their own notices inside the same bundle:

- **Thenable** (Promises/A+ shim) — MIT, Copyright (c) 2013-2014 Ralf S. Engelschall
- **bezier-easing** — MIT, Copyright Gaetan Renaudeau
- **Spring physics adapted from Framer.js** — MIT, Copyright Koen Bok

## Notes on scope

- `Sources/` and `Scripts/` contain no copied or ported third-party code (audited by grepping for
  copyright/provenance markers — no hits).
- The app icon (`Resources/AppIcon.icns`, `Resources/AppIcon-1024.png`) is original work.
- No third-party fonts are bundled.
