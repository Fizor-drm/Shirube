// Shirube common-rule Markdown editor/preview (rules screen).
// Part 1: static source contract against Dashboard-Server.ps1 (no deps).
// Part 2: rule editor block behavior against a small DOM stub in vm (no deps).
// Part 3: REAL parsing/sanitization/augmentation against the actual vendored
//         bundle (marked + DOMPurify + CodeMirror) in jsdom. Requires
//         `npm ci` in .automation/vendor/rule-editor; those sections skip
//         with an explicit notice when the vendor deps are not installed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, '..', 'Dashboard-Server.ps1'), 'utf8');
const vendorBundlePath = path.join(here, '..', 'vendor', 'rule-editor.bundle.js');
const vendorDir = path.join(here, '..', 'vendor', 'rule-editor');

const failures = [];
let passes = 0;
function ok(cond, name) {
  if (cond) { passes++; console.log('PASS: ' + name); return; }
  console.log('FAIL: ' + name);
  failures.push(name);
}
function test(name, fn) {
  try { fn(); ok(true, name); }
  catch (e) { ok(false, name + ' -> ' + (e && e.message || e)); }
}
async function testAsync(name, fn) {
  try { await fn(); ok(true, name); }
  catch (e) { ok(false, name + ' -> ' + (e && e.message || e)); }
}
function must(cond, message) { if (!cond) throw new Error(message); }

// --- Part 1: static source contract --------------------------------------

test('the page keeps exactly one script tag and inlines the vendor placeholder', () => {
  const opens = src.match(/<script>/g) || [];
  const closes = src.match(/<\/script>/g) || [];
  must(opens.length === 1, 'expected exactly one <script>, found ' + opens.length);
  must(closes.length === 1, 'expected exactly one </script>, found ' + closes.length);
  const scriptStart = src.indexOf('<script>');
  const scriptEnd = src.indexOf('</script>', scriptStart);
  const ph = src.slice(scriptStart, scriptEnd).match(/__RULE_EDITOR_VENDOR__/g) || [];
  must(ph.length === 1, 'expected one __RULE_EDITOR_VENDOR__ placeholder in the script, found ' + ph.length);
  must(scriptStart < src.indexOf('__RULE_EDITOR_VENDOR__'), 'placeholder sits inside the script block');
});

test('the vendor bundle exists, exposes ShirubeRuleLib and has no literal script closer', () => {
  must(fs.existsSync(vendorBundlePath), 'vendor bundle committed at .automation/vendor/rule-editor.bundle.js');
  const bundle = fs.readFileSync(vendorBundlePath, 'utf8');
  must(bundle.includes('ShirubeRuleLib'), 'bundle assigns globalThis.ShirubeRuleLib');
  must(!/<\/script/i.test(bundle), 'bundle contains no literal </script sequence');
  for (const f of ['package.json', 'package-lock.json', 'build.mjs', 'src/main.mjs']) {
    must(fs.existsSync(path.join(vendorDir, f)), 'vendor recipe file present: ' + f);
  }
  const lock = JSON.parse(fs.readFileSync(path.join(vendorDir, 'package-lock.json'), 'utf8'));
  const root = lock.packages && lock.packages[''];
  must(root && root.dependencies && root.dependencies.marked === '18.1.1', 'lock pins marked 18.1.1');
  must(root && root.dependencies && root.dependencies.dompurify === '3.4.17', 'lock pins dompurify 3.4.17');
  must(root && root.dependencies && root.dependencies['@codemirror/view'] === '6.43.15', 'lock pins @codemirror/view 6.43.15');
  // A second copy of @codemirror/state (e.g. a stale root pin) gives the two
  // Facet id counters colliding facets, which silently corrupts extensions.
  const stateCopies = Object.keys(lock.packages).filter(k => k.endsWith('node_modules/@codemirror/state'));
  must(stateCopies.length === 1 && stateCopies[0] === 'node_modules/@codemirror/state', 'exactly one @codemirror/state copy in the lock (found: ' + stateCopies.join(', ') + ')');
  const gitignore = fs.readFileSync(path.join(here, '..', '..', '.gitignore'), 'utf8');
  must(/vendor\/rule-editor\/node_modules/.test(gitignore), 'node_modules of the vendor recipe is gitignored');
});

test('full license notices of every bundled package are committed', () => {
  const licensesDir = path.join(here, '..', 'vendor', 'licenses');
  must(fs.existsSync(licensesDir), 'licenses/ directory committed');
  const expected = ['@codemirror+commands', '@codemirror+language', '@codemirror+state', '@codemirror+view',
    '@lezer+common', '@lezer+highlight', '@lezer+lr', '@lezer+markdown',
    '@marijn+find-cluster-break', 'dompurify', 'marked', 'style-mod', 'w3c-keyname'];
  const files = fs.readdirSync(licensesDir);
  for (const pkg of expected) {
    const hit = files.filter(f => f.startsWith(pkg + '.'));
    must(hit.length >= 1, 'license notice for ' + pkg);
    for (const f of hit) {
      const text = fs.readFileSync(path.join(licensesDir, f), 'utf8');
      must(text.trim().length >= 200, pkg + ' notice carries full text (' + f + ')');
    }
  }
  must(files.includes('dompurify.LICENSE') && files.includes('dompurify.LICENSE-MPL'), 'dompurify dual license (Apache-2.0 + MPL-2.0)');
});

test('embedded notices survive in the bundle and the regenerator notice ships beside it', () => {
  const bundle = fs.readFileSync(vendorBundlePath, 'utf8');
  must(/Cure53/.test(bundle) && /DOMPurify/.test(bundle), 'the Cure53 @license header stays embedded in the bundle');
  must(/regenerator-runtime/.test(bundle) && /Facebook, Inc\./.test(bundle), 'the Facebook regenerator-runtime MIT comment stays embedded in the bundle');
  const regen = fs.readFileSync(path.join(here, '..', 'vendor', 'licenses', 'dompurify+regenerator-runtime.LICENSE'), 'utf8');
  must(/MIT License/.test(regen) && /Facebook, Inc\./.test(regen) && /Sebastian McKenzie/.test(regen), 'the regenerator-runtime MIT full text is shipped as a notice');
});

test('the markdown language uses Language, not LRLanguage (subword commands crash on LRLanguage)', () => {
  const mainSrc = fs.readFileSync(path.join(vendorDir, 'src', 'main.mjs'), 'utf8');
  must(!/import[^;]*\bLRLanguage\b/.test(mainSrc) && !/LRLanguage\.(define|of)/.test(mainSrc), 'no LRLanguage usage in the vendor entry');
  must(/new Language\(/.test(mainSrc), 'markdown language built like lang-markdown (Language + defineLanguageFacet)');
  must(/cursorSubwordForward/.test(mainSrc) && /deleteGroupBackward/.test(mainSrc), 'word movement/deletion commands exposed for tests');
});

test('rules markup keeps rules-grid and ruleText and adds the three modes', () => {
  const start = src.indexOf('<div id="rules" hidden>');
  const end = src.indexOf('<div id="backups" hidden>', start);
  must(start >= 0 && end > start, 'rules screen slice missing');
  const html = src.slice(start, end);
  must(/class="rules-grid"/.test(html), 'rules-grid class preserved');
  must(/<textarea id="ruleText"/.test(html), 'textarea#ruleText stays the authoritative field');
  must(/id="btnRuleModeEdit"[^>]*aria-pressed="false"/.test(html), 'edit mode button with aria-pressed');
  must(/id="btnRuleModeSplit"[^>]*aria-pressed="true"/.test(html), 'split is the default (pressed) mode');
  must(/id="btnRuleModePreview"[^>]*aria-pressed="false"/.test(html), 'preview mode button with aria-pressed');
  for (const id of ['btnRuleModeEdit', 'btnRuleModeSplit', 'btnRuleModePreview']) {
    must(new RegExp('id="' + id + '"[^>]*data-i18n=').test(html), id + ' is localized chrome');
  }
  must(/data-i18n-aria="表示モード"/.test(html), 'mode group aria-label is localized');
  must(/id="ruleEditorWrap"/.test(html) && /id="rulePreview"/.test(html), 'editor and preview containers exist');
  must(/id="ruleSrcPane"/.test(html) && /id="rulePreviewPane"/.test(html), 'mode-switchable panes exist');
});

test('mode button and editor colors keep >=4.5:1 contrast', () => {
  function lum(hex) {
    const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map(v => (v <= 0.03928) ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function ratio(fg, bg) { const a = lum(fg), b = lum(bg); return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05); }
  const pairs = [
    ['#ffffff', '#161616', 'inactive mode button text'],
    ['#ffffff', '#2563eb', 'pressed mode button text'],
    ['#8b949e', '#0a0a0a', 'muted table pipes / line numbers'],
    ['#60a5fa', '#0a0a0a', 'blue headings'],
    ['#fbbf24', '#0a0a0a', 'orange inline code']
  ];
  for (const [fg, bg, label] of pairs) {
    const r = ratio(fg, bg);
    must(r >= 4.5, label + ' contrast ' + r.toFixed(2) + ':1 (needs >= 4.5)');
    const cssHas = hex => src.toLowerCase().includes(hex.toLowerCase()) ||
      (hex.toLowerCase() === '#ffffff' && /#fff([^0-9a-f]|$)/i.test(src));
    must(cssHas(fg) && cssHas(bg), label + ' colors appear in the served CSS');
  }
});

test('new UI strings are translated to en and zh-CN', () => {
  const keys = ['表示モード', '編集', '分割', '共通ルールプレビュー', 'テーブル',
    'プレビューを表示できません。ソースのみ編集できます。',
    'プレビューの表示中にエラーが発生しました。',
    '本文が大きいためプレビューを省略しました。'];
  const enStart = src.indexOf('const I18N = {');
  const enEnd = src.indexOf('"zh-CN": {', enStart);
  const zhEnd = src.indexOf('\n};', src.indexOf('"zh-CN": {'));
  must(enStart >= 0 && enEnd > enStart && zhEnd > enEnd, 'I18N dictionaries found');
  const en = src.slice(enStart, enEnd);
  const zh = src.slice(enEnd, zhEnd);
  for (const k of keys) {
    must(en.includes('"' + k + '":'), 'en translation for ' + k);
    must(zh.includes('"' + k + '":'), 'zh-CN translation for ' + k);
  }
});

test('localizeGeneratedUI exempts the CodeMirror and preview DOM', () => {
  const start = src.indexOf('function localizeGeneratedUI(');
  const end = src.indexOf('function applyStaticLanguage(', start);
  must(start >= 0 && end > start, 'localizeGeneratedUI found');
  const body = src.slice(start, end);
  must(/ruleEditorWrap/.test(body) && /rulePreview/.test(body), 'editor/preview subtrees are skipped by the traversal');
});

test('the CodeMirror editor enables line wrapping for long rule lines', () => {
  must(/cm\.EditorView\.lineWrapping,/.test(src), 'EditorView.lineWrapping is part of the editor extensions');
});

test('the assembled page script (vendor bundle inlined) parses as JavaScript', () => {
  const scriptStart = src.indexOf('<script>');
  const scriptEnd = src.indexOf('</script>', scriptStart);
  const js = src.slice(scriptStart + '<script>'.length, scriptEnd)
    .replace('__RULE_EDITOR_VENDOR__', fs.readFileSync(vendorBundlePath, 'utf8'));
  new vm.Script(js); // throws on any syntax error, including broken script embedding
});

test('the three READMEs ship the vendor bundle and licenses in setup and migration', () => {
  for (const name of ['README.md', 'README.en.md', 'README.zh-CN.md']) {
    const text = fs.readFileSync(path.join(here, '..', '..', name), 'utf8');
    const setup = text.slice(text.indexOf('### 4.'), text.indexOf('### 5.'));
    must(/rule-editor\.bundle\.js/.test(setup) && /licenses/.test(setup), name + ': setup step 4 copies the bundle and license notices');
    must(/rule-editor\\/.test(setup) || /rebuild-only|再ビルド用|重新构建/.test(setup), name + ': setup step 4 excludes the rebuild-only directory');
    const bundleMentions = text.match(/rule-editor\.bundle\.js/g) || [];
    must(bundleMentions.length >= 2, name + ': the bundle appears in setup and migration (' + bundleMentions.length + ')');
    must(/\.automation\\\*\.ps1/.test(text), name + ': migration anchor (ps1 copy) preserved');
    must(/管理\.bat/.test(text), name + ': migration anchor (launcher) preserved');
  }
});

// --- Part 2: rules block behavior on a DOM stub --------------------------

function rulesBlock() {
  const start = src.indexOf('function rulesLockedByGitHub(){');
  const end = src.indexOf('async function pollGlobalUntilDone', start);
  must(start >= 0 && end > start, 'rules UI block missing');
  return src.slice(start, end);
}

function makeElement(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(), attrs: {}, listeners: {},
    className: '', classList: {
      add(c) { if (!el.className.includes(c)) el.className += ' ' + c; },
      contains(c) { return el.className.split(/\s+/).indexOf(c) >= 0; }
    },
    textContent: '', value: '', disabled: false, hidden: false, children: [],
    setAttribute(k, v) { this.attrs[k] = v; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    addEventListener(t, fn) { this.listeners[t] = fn; }
  };
  return el;
}

function stubHarness() {
  const elements = new Map();
  function byId(id) {
    if (!elements.has(id)) {
      const el = makeElement(id === 'ruleText' ? 'textarea' : 'div');
      elements.set(id, el);
    }
    return elements.get(id);
  }
  const calls = { save: [] };
  const context = vm.createContext({
    document: { getElementById: byId, querySelectorAll() { return []; }, querySelector() { return null; }, createElement: t => makeElement(t) },
    console, setTimeout, clearTimeout,
    currentGlobalStatus: null,
    showConfirm: async () => true,
    L(key, vars) {
      return String(key).replace(/\{([^{}]+)\}/g, (m, k) =>
        vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
    },
    setMsg(id, msg) { byId(id).textContent = msg; },
    api: async (ep, method, body) => {
      if (ep === '/api/github-rule-get') {
        return { ok: true, kind: 'project', path: 'rules/project.md', repo: 'Fizor-drm/Shirube', branch: 'main', sha: 'sha-1', text: 'loaded', redacted: false };
      }
      if (ep === '/api/github-rule-save') { calls.save.push(body); return { ok: true, sha: 'sha-2', repo: 'Fizor-drm/Shirube', branch: 'main', path: 'rules/project.md' }; }
      return {};
    }
  });
  vm.runInContext(rulesBlock() +
    ';globalThis.__r={ruleModeSet:ruleModeSet,ruleModeGet:function(){return ruleMode;},' +
    'ruleEditorInit:ruleEditorInit,ruleEditorReady:ruleEditorReady,' +
    'ruleEditorApplyText:ruleEditorApplyText,ruleRenderPreviewNow:ruleRenderPreviewNow,' +
    'ruleSchedulePreview:ruleSchedulePreview,ruleLoad:ruleLoad,ruleSave:ruleSave,' +
    'renderRulesLock:renderRulesLock,view:function(){return ruleCmView;}};', context);
  return { context, byId, calls, r: context.__r };
}

test('default mode is split and mode switching updates aria-pressed and panes', () => {
  const h = stubHarness();
  must(h.r.ruleModeGet() === 'split', 'block initializes to split mode');
  must(h.byId('btnRuleModeSplit').getAttribute('aria-pressed') === 'true', 'split pressed by default');
  must(h.byId('btnRuleModeEdit').getAttribute('aria-pressed') === 'false', 'edit not pressed');
  must(h.byId('btnRuleModePreview').getAttribute('aria-pressed') === 'false', 'preview not pressed');
  must(h.byId('ruleSrcPane').hidden === false && h.byId('rulePreviewPane').hidden === false, 'split shows both panes');

  h.r.ruleModeSet('edit');
  must(h.byId('btnRuleModeEdit').getAttribute('aria-pressed') === 'true', 'edit pressed after switch');
  must(h.byId('btnRuleModeSplit').getAttribute('aria-pressed') === 'false', 'split released');
  must(h.byId('ruleSrcPane').hidden === false && h.byId('rulePreviewPane').hidden === true, 'edit hides the preview pane');

  h.r.ruleModeSet('preview');
  must(h.r.ruleModeGet() === 'split', 'without the vendor editor, preview normalizes to split so the source stays usable');
  must(h.byId('ruleSrcPane').hidden === false && h.byId('rulePreviewPane').hidden === false, 'normalized split shows both panes');
  h.r.ruleModeSet('bogus');
  must(h.r.ruleModeGet() === 'split', 'unknown modes are ignored');
});

test('preview fails closed to a localized notice when the vendor bundle is absent', () => {
  const h = stubHarness();
  h.byId('ruleText').value = '# 見出し';
  h.r.ruleRenderPreviewNow();
  must(h.byId('rulePreview').textContent === 'プレビューを表示できません。ソースのみ編集できます。', 'unavailable notice rendered');
});

test('oversized documents skip the preview instead of parsing them', () => {
  const h = stubHarness();
  let parsed = 0;
  h.context.ShirubeRuleLib = { marked: { parse: () => { parsed++; return 'x'; } }, DOMPurify: { sanitize: x => x }, cm: {} };
  const big = '# x\n' + 'a'.repeat(300 * 1024);
  h.byId('ruleText').value = big;
  h.r.ruleRenderPreviewNow();
  must(parsed === 0, '256KB+ text never reaches marked');
  must(h.byId('rulePreview').textContent === '本文が大きいためプレビューを省略しました。', 'localized size notice shown');
});

await testAsync('preview input is debounced and programmatic loads render immediately', async () => {
  const h = stubHarness();
  let renders = 0;
  h.context.ruleRenderPreviewNow = () => { renders++; };
  h.r.ruleSchedulePreview(false);
  h.r.ruleSchedulePreview(false);
  h.r.ruleSchedulePreview(false);
  must(renders === 0, 'debounced renders wait for the timer');
  await new Promise(r => setTimeout(r, 450));
  must(renders === 1, 'bursty input collapses into one render');
  h.r.ruleSchedulePreview(true);
  must(renders === 2, 'programmatic loads render immediately');
});

await testAsync('ruleLoad syncs the editor and save posts the raw source untouched', async () => {
  const h = stubHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  let applied = 0;
  h.context.ruleEditorApplyText = () => { applied++; };
  await h.r.ruleLoad();
  must(applied === 1, 'a successful load syncs the editor + preview');
  const raw = '---\ntitle: keep\n---\n\n# 保存 Save {placeholder}\n\n| a | b |\n|---|---|\n| `code` | x\\|y |\n';
  h.byId('ruleText').value = raw;
  await h.r.ruleSave();
  must(h.calls.save.length === 1, 'save posted once');
  must(h.calls.save[0].text === raw, 'save posts the raw source (frontmatter, pipes, backticks intact)');
  must(h.calls.save[0].sha === 'sha-1', 'save still posts the loaded sha');
});

test('the GitHub lock also makes the CodeMirror editor read-only', () => {
  const h = stubHarness();
  let readOnlyArg = null;
  h.context.ruleEditorSetReadOnly = v => { readOnlyArg = v; };
  h.r.renderRulesLock();
  must(readOnlyArg === true, 'unconfigured GitHub locks the editor');
  h.context.currentGlobalStatus = { githubConfigured: true };
  h.r.renderRulesLock();
  must(readOnlyArg === false, 'configured GitHub unlocks the editor');
});

// --- Part 3: real bundle in jsdom ----------------------------------------

const jsdomPath = path.join(vendorDir, 'node_modules', 'jsdom');
if (!fs.existsSync(jsdomPath)) {
  console.log('SKIP: jsdom sections (vendor deps not installed; run: npm ci in .automation/vendor/rule-editor)');
} else {
  const { JSDOM } = createRequire(import.meta.url)(jsdomPath);
  const bundle = fs.readFileSync(vendorBundlePath, 'utf8');
  const rulesMarkup = (() => {
    const start = src.indexOf('<div id="rules" hidden>');
    const end = src.indexOf('<div id="backups" hidden>', start);
    return src.slice(start, end);
  })();
  const i18nBlock = (() => {
    const start = src.indexOf('const LANG_KEY');
    const end = src.indexOf('\nfunction esc(s)', start);
    return src.slice(start, end);
  })();

  function domHarness(withBundle) {
    const dom = new JSDOM('<!doctype html><html><body><div id="host">' + rulesMarkup.replace('<div id="rules" hidden>', '<div id="rules">') + '</div></body></html>', { url: 'http://localhost/', runScripts: 'outside-only', pretendToBeVisual: true });
    const ctx = dom.getInternalVMContext();
    if (typeof ctx.setTimeout !== 'function') ctx.setTimeout = (fn, ms) => setTimeout(fn, ms);
    if (typeof ctx.clearTimeout !== 'function') ctx.clearTimeout = clearTimeout;
    // jsdom has no layout: give CM's measure pass the Range API it expects so
    // pending animation frames do not throw after the assertions complete.
    try { vm.runInContext('if (typeof Range !== "undefined" && !Range.prototype.getClientRects) { Range.prototype.getClientRects = function(){ return []; }; Range.prototype.getBoundingClientRect = function(){ return {left:0, top:0, right:0, bottom:0, width:0, height:0}; }; }', ctx); } catch (e) {}
    if (withBundle) vm.runInContext(bundle, ctx);
    const calls = { get: 0, save: [] };
    ctx.currentGlobalStatus = { githubConfigured: true };
    ctx.setMsg = (id, msg) => { ctx.document.getElementById(id).textContent = msg; };
    ctx.showConfirm = async () => true;
    ctx.api = async (ep, method, body) => {
      if (ep === '/api/github-rule-get') {
        calls.get++;
        return { ok: true, kind: 'project', path: 'rules/project.md', repo: 'Fizor-drm/Shirube', branch: 'main', sha: 'sha-1', text: '', redacted: false };
      }
      if (ep === '/api/github-rule-save') { calls.save.push(body); return { ok: true, sha: 'sha-2', repo: 'Fizor-drm/Shirube', branch: 'main', path: 'rules/project.md' }; }
      return {};
    };
    vm.runInContext(i18nBlock + '\n' + rulesBlock() +
      ';globalThis.__r={ruleModeSet:ruleModeSet,ruleModeGet:function(){return ruleMode;},' +
      'ruleEditorInit:ruleEditorInit,ruleEditorReady:ruleEditorReady,' +
      'ruleEditorApplyText:ruleEditorApplyText,ruleRenderPreviewNow:ruleRenderPreviewNow,' +
      'ruleLoad:ruleLoad,ruleSave:ruleSave,renderRulesLock:renderRulesLock,' +
      'applyLanguage:applyLanguage,L:L,view:function(){return ruleCmView;}};', ctx);
    return { dom, ctx, calls, r: ctx.__r };
  }

  test('the vendored marked, DOMPurify and CodeMirror load inside a DOM', () => {
    const h = domHarness(true);
    const lib = h.ctx.ShirubeRuleLib;
    must(lib && lib.marked && lib.marked.parse, 'marked is exposed');
    must(lib && lib.DOMPurify && typeof lib.DOMPurify(h.ctx.window) === 'function' && typeof lib.DOMPurify(h.ctx.window).sanitize === 'function', 'DOMPurify factory works against the window');
    must(lib && lib.cm && lib.cm.EditorView, 'CodeMirror view is exposed');
  });

  test('real parse + sanitize renders GFM content and neutralizes XSS', () => {
    const h = domHarness(true);
    const md = [
      '# 見出し Heading',
      '',
      '本文 with `inline {code}` and [link](https://example.com/a).',
      '',
      '| 列A | 列B |',
      '| --- | --- |',
      '| `x` | y\\|z |',
      '',
      '<script>alert(1)</script>',
      '<img src=x onerror=alert(1)>',
      '![image](https://evil.example/x.png)',
      '<svg onload=alert(2)><circle/></svg>',
      '<iframe src="https://evil.example"></iframe>',
      '<object data="https://evil.example"></object>',
      '<embed src="https://evil.example">',
      '<form action="https://evil.example"><input type="text"></form>',
      '<style>body{background:red}</style>',
      '<a href="javascript:alert(3)">js</a>',
      '<a href="data:text/html,hi">data</a>',
      '<a href="file:///C:/Windows/win.ini">file</a>',
      '<a href="vbscript:alert(4)">vbs</a>',
      '<a href="https://ok.example/page" onclick="alert(5)">ok</a>',
      '<div id="x" name="y" style="color:red">styled</div>',
      '<p onmouseover="alert(6)">hover</p>'
    ].join('\n');
    h.ctx.document.getElementById('ruleText').value = md;
    h.r.ruleRenderPreviewNow();
    const p = h.ctx.document.getElementById('rulePreview');
    const all = tag => Array.from(p.querySelectorAll(tag));
    must(all('script').length === 0, 'script removed');
    must(all('img').length === 0, 'img removed (markdown and raw HTML)');
    must(all('svg').length === 0 && all('iframe').length === 0 && all('object').length === 0 && all('embed').length === 0, 'svg/iframe/object/embed removed');
    must(all('form').length === 0 && all('input').length === 0 && all('style').length === 0, 'form/input/style removed');
    for (const el of p.querySelectorAll('*')) {
      for (const a of Array.from(el.attributes)) {
        must(!/^on/i.test(a.name), 'no event handler attributes (found ' + a.name + ')');
        must(!['id', 'name', 'style', 'class'].includes(a.name.toLowerCase()) || el.tagName === 'DIV' && a.name === 'class' && a.value === 'rpreview-scroll',
          'no id/name/style/class attributes survive (found ' + a.name + ' on ' + el.tagName + ')');
      }
      if (el.tagName === 'A' && el.hasAttribute('href')) {
        must(/^https?:/i.test(el.getAttribute('href')), 'hrefs limited to http(s): ' + el.getAttribute('href'));
      }
    }
    const links = all('a');
    must(links.some(a => a.getAttribute('href') === 'https://example.com/a'), 'markdown link kept');
    for (const a of links) {
      if (a.hasAttribute('href')) {
        must(a.getAttribute('target') === '_blank' && /noopener/.test(a.getAttribute('rel') || '') && /noreferrer/.test(a.getAttribute('rel') || ''), 'links open in a blank hardened context');
      }
    }
    must(!links.some(a => (a.getAttribute('href') || '').match(/^(javascript|data|file|vbscript):/i)), 'dangerous hrefs stripped');
  });

  test('preview augmentation builds row headers and scrollable table regions', () => {
    const h = domHarness(true);
    h.ctx.document.getElementById('ruleText').value = '# H\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n';
    h.r.ruleRenderPreviewNow();
    const p = h.ctx.document.getElementById('rulePreview');
    const table = p.querySelector('table');
    must(table, 'GFM table rendered');
    must(p.querySelectorAll('thead th').length === 2, 'header row rendered as th');
    const rows = Array.from(p.querySelectorAll('tbody tr'));
    must(rows.length === 2, 'two body rows');
    for (const row of rows) {
      const first = row.firstElementChild;
      must(first.tagName === 'TH' && first.getAttribute('scope') === 'row', 'first body cell is a row header');
    }
    const wrap = table.closest('.rpreview-scroll');
    must(wrap, 'table wrapped in a scroll region');
    must(wrap.getAttribute('role') === 'region', 'scroll wrapper is a region');
    must(wrap.getAttribute('aria-label') === 'テーブル', 'scroll wrapper has a localized label');
    must(wrap.getAttribute('tabindex') === '0', 'scroll wrapper is keyboard focusable');
  });

  test('source text is never mutated: placeholders, pipes and entities stay raw', () => {
    const h = domHarness(true);
    const raw = '---\ntitle: x\n---\n\n# 見出し {name} <keep> & "q"\n\n`{code}` `a<b`\n';
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = raw;
    h.r.ruleRenderPreviewNow();
    must(ta.value === raw, 'rendering the preview leaves the textarea untouched');
    const p = h.ctx.document.getElementById('rulePreview');
    must(p.textContent.includes('{name}'), 'placeholders survive into the preview');
  });

  test('language changes re-render chrome and errors but keep the raw source and mode', () => {
    const h = domHarness(true);
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = '# 保存 Save {x}';
    h.r.ruleModeSet('preview');
    // sabotage marked so the error path runs
    h.ctx.ShirubeRuleLib.marked = { parse: () => { throw new Error('boom'); } };
    h.r.ruleRenderPreviewNow();
    must(h.ctx.document.getElementById('rulePreview').textContent === 'プレビューの表示中にエラーが発生しました。', 'error notice in Japanese');
    h.r.applyLanguage('en', false);
    must(h.ctx.document.getElementById('rulePreview').textContent === 'The preview could not be rendered.', 'error notice follows the locale');
    must(ta.value === '# 保存 Save {x}', 'raw source untouched by the language switch');
    must(h.r.ruleModeGet() === 'preview', 'mode preserved across the language switch');
    must(h.ctx.document.getElementById('btnRuleModePreview').getAttribute('aria-pressed') === 'true', 'pressed state preserved');
    must(h.ctx.document.getElementById('btnRuleModePreview').textContent === 'Preview', 'mode buttons localized');
    must(h.ctx.document.getElementById('ruleText').getAttribute('aria-label') === 'Rule body', 'aria label localized');
  });

  test('preview user content is exempt from the i18n dictionary traversal', () => {
    const h = domHarness(true);
    const ta = h.ctx.document.getElementById('ruleText');
    // "保存" is an existing dictionary value; rule text containing it must stay raw.
    ta.value = '# 保存する\n\n- 保存する\n';
    h.r.ruleRenderPreviewNow();
    h.r.applyLanguage('en', false);
    const p = h.ctx.document.getElementById('rulePreview');
    must(p.textContent.includes('保存する'), 'preview content not translated by the traversal');
    must(ta.value === '# 保存する\n\n- 保存する\n', 'source not translated');
  });

  test('long lines wrap while line numbers and table stripes stay per logical line', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = '| ' + 'long '.repeat(120) + '|\n| - |\n| end |';
    h.r.ruleEditorApplyText();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    const wrap = h.r.view().state.facet(cm.EditorView.lineWrapping);
    must(!!wrap && wrap.class === 'cm-lineWrapping', 'lineWrapping facet is enabled');
    const content = h.ctx.document.querySelector('#ruleEditorWrap .cm-content');
    must(content && content.childElementCount >= 3, 'the long line renders as a single logical line block');
    must(ta.value.length > 600 && content.textContent.length > 500, 'the long line is rendered in the DOM');
    must(h.ctx.document.querySelectorAll('#ruleEditorWrap .rule-md-row').length === 3, 'stripe decorations follow logical lines');
  });

  test('real word movement and deletion commands work without hasWrappers errors', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    const v = h.r.view();
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = 'one two three';
    h.r.ruleEditorApplyText();
    // cursor at end, Ctrl+Left (start of 'three'), Ctrl+Backspace deletes the group left of it ('two')
    let out = {};
    try {
      v.dispatch({ selection: { anchor: v.state.doc.length } });
      cm.cursorSubwordBackward(v);
      out.afterMove = v.state.selection.main.head < v.state.doc.length;
      cm.deleteGroupBackward(v);
      out.docAfterDelete = v.state.doc.toString();
      cm.cursorSubwordForward(v);
      out.noThrow = true;
    } catch (e) {
      out.noThrow = false;
      out.err = String(e && e.message);
    }
    must(out.noThrow === true, 'subword/group commands do not throw: ' + (out.err || ''));
    must(out.afterMove === true, 'Ctrl+Left moves the cursor left');
    must(out.docAfterDelete === 'one three', 'Ctrl+Backspace deletes the group left of the cursor (got: ' + JSON.stringify(out.docAfterDelete) + ')');
    must(ta.value === 'one three', 'the mirror tracks command edits');
  });

  test('the editor uses an explicit dark theme with a visible caret and selection', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    must(!!h.r.view().state.facet(cm.EditorView.darkTheme), 'darkTheme facet is set');
    const injected = Array.from(h.ctx.document.querySelectorAll('style'))
      .map(s => s.textContent || '').join('\n');
    must(/cm-cursor/.test(injected) && /#fff/.test(injected), 'caret color is forced to white');
    must(/#264f78/.test(injected), 'selection background is forced to a dark-theme blue');
  });

  test('the GitHub lock blocks edits, deletes and undo inside CodeMirror', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    const v = h.r.view();
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = 'locked text';
    h.r.ruleEditorApplyText();
    // make an edit first so undo has something to undo
    v.dispatch({ changes: { from: 0, to: 0, insert: 'x' } });
    must(ta.value === 'xlocked text', 'pre-lock edit mirrored');
    h.ctx.currentGlobalStatus = { githubConfigured: false };
    h.r.renderRulesLock();
    v.dispatch({ changes: { from: 0, to: 1, insert: 'y' } });
    must(v.state.doc.toString() === 'xlocked text', 'locked: dispatched inserts are rejected by the change filter');
    cm.deleteGroupBackward(v);
    must(v.state.doc.toString() === 'xlocked text', 'locked: delete command cannot mutate the doc');
    cm.historyKeymap && (() => {
      const undo = cm.historyKeymap.find(k => k.key === 'Mod-z');
      if (undo && undo.run) undo.run(v);
    })();
    must(v.state.doc.toString() === 'xlocked text', 'locked: Ctrl+Z cannot mutate the doc');
    must(ta.value === 'xlocked text', 'locked: the raw textarea never changes');
    h.ctx.currentGlobalStatus = { githubConfigured: true };
    h.r.renderRulesLock();
    v.dispatch({ changes: { from: 0, to: 1, insert: '' } });
    must(v.state.doc.toString() === 'locked text', 'unlocked: edits flow again');
  });

  await testAsync('a load finishing while locked still syncs the editor; user edits stay blocked', async () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    const ta = h.ctx.document.getElementById('ruleText');
    let resolveGet;
    h.ctx.api = (ep) => {
      if (ep === '/api/github-rule-get') {
        return new Promise(resolve => { resolveGet = () => resolve({ ok: true, kind: 'project', path: 'rules/project.md', repo: 'R', branch: 'main', sha: 's1', text: '# fresh source', redacted: false }); });
      }
      return Promise.resolve({ ok: true });
    };
    const pending = h.r.ruleLoad();
    await new Promise(r => setTimeout(r, 0));
    // the lock closes while the GET is in flight, then it resolves
    h.ctx.currentGlobalStatus = { githubConfigured: false };
    h.r.renderRulesLock();
    resolveGet();
    await pending;
    must(ta.value === '# fresh source', 'textarea holds the loaded source');
    must(h.r.view().state.doc.toString() === '# fresh source', 'CodeMirror is synced to the load despite the lock');
    h.r.view().dispatch({ changes: { from: 0, to: 0, insert: 'x' } });
    must(ta.value === '# fresh source', 'locked: user dispatches are still rejected');
    const undo = cm.historyKeymap.find(k => k.key === 'Mod-z');
    if (undo && undo.run) undo.run(h.r.view());
    must(h.r.view().state.doc.toString() === '# fresh source', 'locked: undo is still rejected');
    h.ctx.currentGlobalStatus = { githubConfigured: true };
    h.r.renderRulesLock();
    h.r.view().dispatch({ changes: { from: 0, to: 0, insert: 'y' } });
    must(ta.value === 'y# fresh source', 'unlocked: user input builds on the new source, not the stale one');
  });

  await testAsync('undo history resets when another file is loaded or the kind changes', async () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    const doc = h.ctx.document;
    const ta = doc.getElementById('ruleText');
    const posts = [];
    h.ctx.api = (ep, method, body) => {
      if (ep === '/api/github-rule-get') {
        const kind = doc.getElementById('selRuleKind').value;
        return Promise.resolve({ ok: true, kind, path: 'rules/' + kind + '.md', repo: 'R', branch: 'main', sha: 'sha-' + kind, text: kind === 'global' ? 'global authority' : 'project authority', redacted: false });
      }
      if (ep === '/api/github-rule-save') { posts.push(body); return Promise.resolve({ ok: true, sha: 'sha-new', repo: 'R', branch: 'main', path: 'rules/global.md' }); }
      return Promise.resolve({ ok: true });
    };
    const undo = () => {
      const k = cm.historyKeymap.find(x => x.key === 'Mod-z');
      return k && k.run(h.r.view());
    };
    // project file: in-file edit + undo still works
    await h.r.ruleLoad();
    must(ta.value === 'project authority' && h.r.view().state.doc.toString() === 'project authority', 'project load lands in the editor and textarea');
    h.r.view().dispatch({ changes: { from: 0, to: 0, insert: 'X' } });
    must(ta.value === 'Xproject authority', 'in-file edit mirrors to the textarea');
    undo();
    must(h.r.view().state.doc.toString() === 'project authority', 'undo works within the same file');
    // switch kind (authority clear) and load the global file
    doc.getElementById('selRuleKind').value = 'global';
    doc.getElementById('selRuleKind').onchange();
    must(h.r.view().state.doc.toString() === '', 'kind clear resets the editor');
    await h.r.ruleLoad();
    must(ta.value === 'global authority' && h.r.view().state.doc.toString() === 'global authority', 'global load lands in the editor and textarea');
    // cross-file undo must not resurrect the project text
    undo();
    must(h.r.view().state.doc.toString() === 'global authority', 'undo cannot bring back the other file\'s text');
    must(ta.value === 'global authority', 'the textarea keeps the global authority after the undo attempt');
    await h.r.ruleSave();
    must(posts.length === 1 && posts[0].kind === 'global' && posts[0].text === 'global authority' && posts[0].sha === 'sha-global', 'save posts the loaded global file with its own sha');
  });

  await testAsync('undo history resets even when the reloaded text is identical or empty', async () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const cm = h.ctx.ShirubeRuleLib.cm;
    const doc = h.ctx.document;
    const ta = doc.getElementById('ruleText');
    let getText = 'project authority';
    h.ctx.api = (ep) => {
      if (ep === '/api/github-rule-get') {
        const kind = doc.getElementById('selRuleKind').value;
        return Promise.resolve({ ok: true, kind, path: 'rules/' + kind + '.md', repo: 'R', branch: 'main', sha: 'sha-' + kind, text: kind === 'global' ? getText : 'project authority', redacted: false });
      }
      return Promise.resolve({ ok: true });
    };
    const undo = () => {
      const k = cm.historyKeymap.find(x => x.key === 'Mod-z');
      return k && k.run(h.r.view());
    };
    // same-text reload: edit away and back, then re-fetch the identical text
    await h.r.ruleLoad();
    h.r.view().dispatch({ changes: { from: 0, to: 'project authority'.length, insert: 'edited away' } });
    // stay outside CM's newGroupDelay window so the two edits are separate undo events
    await new Promise(r => setTimeout(r, 550));
    h.r.view().dispatch({ changes: { from: 0, to: 'edited away'.length, insert: 'project authority' } });
    must(h.r.view().state.doc.toString() === 'project authority', 'doc edited back to the loaded text (history holds the edits)');
    await h.r.ruleLoad();
    undo();
    must(h.r.view().state.doc.toString() === 'project authority' && ta.value === 'project authority', 'identical reload resets history: undo changes nothing');
    // empty-doc cross-kind: edit the project file down to empty, clear, load an empty global file
    h.r.view().dispatch({ changes: { from: 0, to: 'project authority'.length, insert: '' } });
    doc.getElementById('selRuleKind').value = 'global';
    doc.getElementById('selRuleKind').onchange();
    getText = '';
    await h.r.ruleLoad();
    must(h.r.view().state.doc.toString() === '' && ta.value === '', 'empty global load lands');
    undo();
    must(h.r.view().state.doc.toString() === '' && ta.value === '', 'empty reload resets history: undo cannot resurrect the project text');
  });

  test('table row stripes come from the syntax tree and cover both GFM forms', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const countRows = () => ({
      rows: h.ctx.document.querySelectorAll('#ruleEditorWrap .rule-md-row').length,
      alt: h.ctx.document.querySelectorAll('#ruleEditorWrap .rule-md-row-alt').length
    });
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = '| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n';
    h.r.ruleEditorApplyText();
    const piped = countRows();
    must(piped.rows === 4 && piped.alt === 2, 'piped table: every logical row striped (got ' + JSON.stringify(piped) + ')');

    ta.value = 'A | B\n--- | ---\nx | y\n';
    h.r.ruleEditorApplyText();
    const bare = countRows();
    must(bare.rows === 3 && bare.alt === 1, 'pipeless table: header/delimiter/row striped (got ' + JSON.stringify(bare) + ')');

    ta.value = '```\n| a | b |\n| --- | --- |\n```\n| real | table |\n| --- | --- |\n';
    h.r.ruleEditorApplyText();
    const fenced = countRows();
    must(fenced.rows === 2, 'fenced code lookalikes are not striped, only the real table (got ' + JSON.stringify(fenced) + ')');
  });

  test('the CodeMirror textbox carries a localized accessible name', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    const content = h.ctx.document.querySelector('#ruleEditorWrap .cm-content');
    must(content && content.getAttribute('aria-label') === 'ルール本文', 'textbox is named in Japanese');
    const ta = h.ctx.document.getElementById('ruleText');
    ta.value = '# 保存 {x}';
    h.r.applyLanguage('en', false);
    must(content.getAttribute('aria-label') === 'Rule body', 'the accessible name follows the locale');
    must(ta.value === '# 保存 {x}', 'the raw source is untouched by the label update');
  });

  test('with the CodeMirror editor, preview mode does hide the source pane', () => {
    const h = domHarness(true);
    h.r.ruleEditorInit();
    if (!h.r.ruleEditorReady()) return; // editor unavailable in this DOM
    h.r.ruleModeSet('preview');
    must(h.r.ruleModeGet() === 'preview', 'preview stays preview when the editor is real');
    must(h.ctx.document.getElementById('ruleSrcPane').hidden === true, 'source pane hidden');
    h.r.ruleModeSet('split');
    must(h.ctx.document.getElementById('ruleSrcPane').hidden === false, 'split restores the source pane');
  });

  test('row headers pick the row\'s own first cell, not a descendant cell', () => {
    const h = domHarness(true);
    const ta = h.ctx.document.getElementById('ruleText');
    const p = h.ctx.document.getElementById('rulePreview');

    // raw HTML row already using th in the first column keeps it and only gains scope
    ta.value = '<table><thead><tr><th>H</th></tr></thead><tbody><tr><th>RowA</th><td>42</td></tr></tbody></table>';
    h.r.ruleRenderPreviewNow();
    const firstTh = p.querySelector('tbody th');
    must(firstTh && firstTh.textContent === 'RowA' && firstTh.getAttribute('scope') === 'row', 'existing th keeps its text and gains scope=row');
    must(p.querySelectorAll('tbody td').length === 1 && p.querySelector('tbody td').textContent === '42', 'the second cell stays a td');

    // nested table: the outer row converts its own first cell, never a nested cell
    ta.value = '<table><tbody><tr><td>outer</td><td><table><tbody><tr><td>inner</td></tr></tbody></table></td></tr></tbody></table>';
    h.r.ruleRenderPreviewNow();
    const outerRow = p.querySelector('table > tbody > tr');
    must(outerRow && outerRow.children[0].tagName === 'TH' && outerRow.children[0].textContent === 'outer', 'the outer first cell is the converted row header');
    must(outerRow.children[1].tagName === 'TD', 'the outer second cell stays td');
    const inner = p.querySelectorAll('table > tbody > tr')[1];
    must(inner && inner.children[0].textContent === 'inner', 'the nested table is intact');

    // standard GFM keeps converting td to th scope=row
    ta.value = '| a | b |\n| - | - |\n| 1 | 2 |';
    h.r.ruleRenderPreviewNow();
    must(p.querySelector('tbody th[scope=row]').textContent === '1', 'GFM body rows still get th scope=row');
  });

  test('without the vendor bundle the editor fails closed to the plain textarea', () => {
    const h = domHarness(false);
    h.r.ruleEditorInit();
    const ta = h.ctx.document.getElementById('ruleText');
    must(h.r.ruleEditorReady() === false, 'no CodeMirror without the bundle');
    must(!ta.hidden, 'textarea stays visible as the fallback editor');
    ta.value = '# x';
    h.r.ruleModeSet('preview');
    h.r.ruleRenderPreviewNow();
    must(h.ctx.document.getElementById('rulePreview').textContent === 'プレビューを表示できません。ソースのみ編集できます。', 'unavailable notice (ja)');
    h.r.applyLanguage('en', false);
    must(h.ctx.document.getElementById('rulePreview').textContent === 'The preview is unavailable. Only the source text can be edited.', 'unavailable notice follows the locale');
    must(!ta.hidden, 'fallback editor never gets hidden');
  });

  test('preview mode never hides the fallback textarea editor', () => {
    const h = domHarness(false);
    h.r.ruleEditorInit();
    const ta = h.ctx.document.getElementById('ruleText');
    const pane = h.ctx.document.getElementById('ruleSrcPane');
    h.r.ruleModeSet('preview');
    must(h.r.ruleModeGet() === 'split', 'preview normalizes to split without CodeMirror');
    must(pane.hidden === false, 'the source pane stays visible');
    must(!ta.closest('[hidden]'), 'no hidden ancestor above the fallback editor');
    must(h.ctx.document.getElementById('btnRuleModeSplit').getAttribute('aria-pressed') === 'true', 'the effective mode is what the buttons show');
    h.r.ruleModeSet('edit');
    must(pane.hidden === false && h.ctx.document.getElementById('rulePreviewPane').hidden === true, 'edit still works');
    h.r.ruleModeSet('split');
    must(pane.hidden === false && h.ctx.document.getElementById('rulePreviewPane').hidden === false, 'split still works');
  });
}

console.log(failures.length ? 'FAILURES: ' + failures.length + ' (' + failures.join('; ') + ')' : 'ALL RULE MARKDOWN CHECKS PASSED (' + passes + ')');
process.exitCode = failures.length ? 1 : 0;
