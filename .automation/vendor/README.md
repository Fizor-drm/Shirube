# Vendored rule-editor bundle

`rule-editor.bundle.js` is a single pre-built IIFE embedded by
`Dashboard-Server.ps1` (`Get-PageHtml` → `__RULE_EDITOR_VENDOR__` placeholder)
at the head of the dashboard's one `<script>` block. It provides the common-rule
Markdown editor and preview:

- **CodeMirror 6** (view 6.43.15, state 6.7.6, commands 6.8.1, language 6.11.0,
  lang-markdown is NOT used: the markdown language is assembled from
  `@lezer/markdown` 1.4.3 + `GFM` to avoid inlining the JS/CSS/HTML parsers) — MIT license
- **marked 18.1.1** — MIT license
- **DOMPurify 3.4.17** — Apache-2.0 OR MPL-2.0 (dual license)

It exposes `globalThis.ShirubeRuleLib = { cm, marked, DOMPurify }`. When the
bundle is missing, the dashboard fails closed to the plain `#ruleText` textarea
and shows a localized "preview unavailable" notice. No CDN, no eval, no runtime
Node requirement — the dashboard only reads this file.

## Sizes (measured 2026-10-25)

- `rule-editor.bundle.js`: 393,908 bytes minified (384.7 KB), 128,213 bytes gzip (125.2 KB)
  - roughly: @codemirror/view 202.1 KB, marked 45.6 KB, @codemirror/state ~45 KB,
    @lezer/markdown 34.3 KB, DOMPurify 30.3 KB, remaining CM/lezer packages ~90 KB

## Rebuild (development only, not needed to run the dashboard)

```
cd .automation/vendor/rule-editor
npm ci
npm run build
```

`build.mjs` bundles `src/main.mjs` with esbuild 0.28.2 (pinned in
`package-lock.json`), rejects a literal `</script` sequence in the output
(it is escaped to `<\/script`, which is identical inside string literals and
regexes), and writes `../rule-editor.bundle.js`. After rebuilding, run
`node .automation/tests/Test-RuleMarkdown.mjs` — it verifies the bundle, the
assembled page script, and the real parse/sanitize pipeline in jsdom.

## Third-party licenses

- CodeMirror: Copyright (c) Marijn Haverbeke — MIT (https://codemirror.net/5/LICENSE for CM5; CM6 packages are MIT, https://github.com/codemirror/basic-setup)
- marked: Copyright (c) 2011-2025, Christopher Jeffrey — MIT (https://github.com/markedjs/marked/blob/master/LICENSE.md)
- DOMPurify: Copyright 2015 Mario Heiderich — Apache-2.0 OR MPL-2.0 (https://github.com/cure53/DOMPurify/blob/main/LICENSE)

Full license texts are available in the respective npm packages; the minified
bundle carries no license banner (esbuild `legalComments: "none"`) to keep the
embedded page small, which is why they are reproduced above.
