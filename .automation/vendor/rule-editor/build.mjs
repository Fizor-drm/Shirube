// Rebuilds ../rule-editor.bundle.js. Run: npm ci && npm run build
// The bundle must stay a single IIFE with no literal "</script" sequence so it
// can be embedded inside the dashboard's one <script> block.
import { build } from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "..", "rule-editor.bundle.js");

const result = await build({
  entryPoints: [path.join(here, "src", "main.mjs")],
  bundle: true,
  format: "iife",
  minify: true,
  legalComments: "none",
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
const kb = (n) => (n / 1024).toFixed(1) + "KB";
console.log("wrote " + out);
console.log("size: " + kb(check.length) + " minified (uncompressed)");
