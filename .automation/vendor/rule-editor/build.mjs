// Rebuilds ../rule-editor.bundle.js. Run: npm ci && npm run build
// The bundle must stay a single IIFE with no literal "</script" sequence so it
// can be embedded inside the dashboard's one <script> block.
// License notices of every package that ends up in the bundle are copied to
// ../licenses/ so the distribution carries the required copyright/license text
// even though the minified bundle ships without license banners.
import { build } from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "..", "rule-editor.bundle.js");
const licensesOut = path.join(here, "..", "licenses");

// Every package whose code can end up in the bundle (runtime deps only).
const LICENSED = [
  "@codemirror/commands", "@codemirror/language", "@codemirror/state", "@codemirror/view",
  "@lezer/common", "@lezer/highlight", "@lezer/lr", "@lezer/markdown",
  "@marijn/find-cluster-break", "dompurify", "marked", "style-mod", "w3c-keyname"
];

const result = await build({
  entryPoints: [path.join(here, "src", "main.mjs")],
  bundle: true,
  format: "iife",
  minify: true,
  // inline (not none): the DOMPurify dist embeds /*! @license */ notices
  // (Cure53 header and the Facebook regenerator-runtime MIT comment) that
  // "none" would strip from the shipped bundle.
  legalComments: "inline",
  write: false,
  charset: "utf8",
  target: ["es2019"]
});

let code = result.outputFiles[0].text;
const hits = code.match(/<\/script/gi);
if (hits) {
  // Only safe inside string literals and regexes, which is the only place a
  // minified bundle can carry this sequence; verify with node --check after.
  code = code.replace(/<\/script/gi, "<\\/script");
}

fs.writeFileSync(out, code, "utf8");
const check = fs.readFileSync(out, "utf8");
if (/<\/script/i.test(check)) throw new Error("bundle still contains a literal </script sequence");

fs.mkdirSync(licensesOut, { recursive: true });
for (const pkg of LICENSED) {
  const dir = path.join(here, "node_modules", pkg);
  for (const name of fs.readdirSync(dir)) {
    if (!/^licen[cs]e([.-]|$)/i.test(name)) continue;
    const text = fs.readFileSync(path.join(dir, name), "utf8");
    if (text.trim().length < 200) throw new Error(pkg + " license file looks empty: " + name);
    fs.writeFileSync(path.join(licensesOut, pkg.replace(/\//g, "+") + "." + name), text, "utf8");
  }
}

// DOMPurify embeds regenerator-runtime helpers (babel-helpers) under the MIT
// license; that code is not a separate npm package, so its notice is written
// verbatim here. Source: https://github.com/babel/babel/blob/main/packages/babel-helpers/LICENSE
const REGENERATOR_NOTICE = `MIT License

Copyright (c) 2014-present Sebastian McKenzie and other contributors
Copyright (c) 2014-present, Facebook, Inc. (ONLY ./src/helpers/regenerator* files)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
`;
fs.writeFileSync(path.join(licensesOut, "dompurify+regenerator-runtime.LICENSE"), REGENERATOR_NOTICE, "utf8");

const kb = (n) => (n / 1024).toFixed(1) + "KB";
console.log("wrote " + out);
console.log("size: " + kb(check.length) + " minified (uncompressed)");
console.log("licenses: " + fs.readdirSync(licensesOut).length + " files in " + licensesOut);
