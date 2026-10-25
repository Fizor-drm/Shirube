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

test('the assembled page script (vendor bundle inlined) parses as JavaScript', () => {
  const scriptStart = src.indexOf('<script>');
  const scriptEnd = src.indexOf('</script>', scriptStart);
  const js = src.slice(scriptStart + '<script>'.length, scriptEnd)
    .replace('__RULE_EDITOR_VENDOR__', fs.readFileSync(vendorBundlePath, 'utf8'));
  new vm.Script(js); // throws on any syntax error, including broken script embedding
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
    'renderRulesLock:renderRulesLock};', context);
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
  must(h.byId('rulePreviewPane').hidden === false && h.byId('ruleSrcPane').hidden === true, 'preview hides the source pane');
  h.r.ruleModeSet('bogus');
  must(h.r.ruleModeGet() === 'preview', 'unknown modes are ignored');
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
    const dom = new JSDOM('<!doctype html><html><body><div id="host">' + rulesMarkup.replace('<div id="rules" hidden>', '<div id="rules">') + '</div></body></html>', { url: 'http://localhost/', runScripts: 'outside-only' });
    const ctx = dom.getInternalVMContext();
    if (typeof ctx.setTimeout !== 'function') ctx.setTimeout = (fn, ms) => setTimeout(fn, ms);
    if (typeof ctx.clearTimeout !== 'function') ctx.clearTimeout = clearTimeout;
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
      'applyLanguage:applyLanguage,L:L};', ctx);
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
}

console.log(failures.length ? 'FAILURES: ' + failures.length + ' (' + failures.join('; ') + ')' : 'ALL RULE MARKDOWN CHECKS PASSED (' + passes + ')');
process.exitCode = failures.length ? 1 : 0;
