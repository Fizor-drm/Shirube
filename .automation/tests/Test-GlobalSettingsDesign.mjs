// Global設定 (#gsettings) card selector + automatic-sync controls.
// Runs the ACTUAL functions/handlers from Dashboard-Server.ps1 against a small
// DOM stub. No server start, no browser, no real AppData/tasks/home access.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const src = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'Dashboard-Server.ps1'), 'utf8');
const failures = [];
function ok(cond, name) {
  if (cond) { console.log('PASS: ' + name); return; }
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

const CATALOG = [
  { id: 'codexcli', label: 'Codex', rel: '.codex\\AGENTS.md' },
  { id: 'opencode', label: 'OpenCode', rel: '.config\\opencode\\AGENTS.md' },
  { id: 'claudecode', label: 'Claude Code', rel: '.claude\\CLAUDE.md' },
  { id: 'cline', label: 'Cline', rel: '.agents\\AGENTS.md' },
  { id: 'copilotcli', label: 'GitHub Copilot CLI', rel: '.copilot\\copilot-instructions.md' },
  { id: 'antigravity-cli', label: 'Antigravity CLI', rel: '.gemini\\GEMINI.md' },
  { id: 'continue', label: 'Continue', rel: '.continue\\rules\\AGENTS.md' },
  { id: 'roo', label: 'Roo Code', rel: '.roo\\rules\\AGENTS.md' },
  { id: 'goose', label: 'Goose', rel: '.config\\goose\\.goosehints' },
  { id: 'devin', label: 'Devin', rel: '.config\\devin\\AGENTS.md' },
  { id: 'zed', label: 'Zed', rel: 'AppData\\Roaming\\Zed\\AGENTS.md' },
  { id: 'crush', label: 'Crush', rel: '.config\\crush\\CRUSH.md' },
  { id: 'codebuddy', label: 'CodeBuddy', rel: '.codebuddy\\CODEBUDDY.md' },
  { id: 'commandcode', label: 'CommandCode', rel: '.commandcode\\AGENTS.md' },
  { id: 'kimi-code', label: 'Kimi Code', rel: '.kimi-code\\AGENTS.md' },
  { id: 'vibe', label: 'Vibe', rel: '.vibe\\AGENTS.md' },
  { id: 'qoder', label: 'Qoder', rel: '.qoder\\AGENTS.md' },
  { id: 'pi', label: 'Pi', rel: '.pi\\agent\\AGENTS.md' }
];

function sectionHtml() {
  const m = /<section id="gsettings">([\s\S]*?)<\/section>/.exec(src);
  must(m, '#gsettings section missing');
  return m[1];
}
function gsCss() {
  const start = src.indexOf('/* #gsettings');
  must(start >= 0, '#gsettings css marker missing');
  const end = src.indexOf('</style>', start);
  must(end > start, 'css end missing');
  return src.slice(start, end);
}
function logoLine() {
  const start = src.indexOf('const GLOBAL_LOGOS =');
  must(start >= 0, 'GLOBAL_LOGOS map missing');
  const end = src.indexOf(');', start);
  must(end > start, 'GLOBAL_LOGOS map end missing');
  return src.slice(start, end + 2).replace(/^const /, 'var ');
}
function logos() {
  const ctx = {};
  vm.runInNewContext(logoLine() + '\n;globalThis.__logos=GLOBAL_LOGOS;', ctx);
  return ctx.__logos;
}
function mainBlock() {
  const start = src.indexOf('function updateGlobalUI(g){');
  const end = src.indexOf('document.getElementById("btnGlobalContent")');
  must(start >= 0 && end > start, 'global UI block missing');
  return src.slice(start, end).split('let ').join('var ');
}
function assignmentBlock(id) {
  const marker = 'document.getElementById("' + id + '").onclick = ';
  const start = src.indexOf(marker);
  must(start >= 0, 'handler missing: ' + id);
  let i = src.indexOf('{', start + marker.length);
  let level = 0;
  for (; i < src.length; i++) {
    if (src[i] === '{') level++;
    else if (src[i] === '}' && --level === 0) break;
  }
  must(level === 0, 'handler body incomplete: ' + id);
  return src.slice(start, i + 1) + ';';
}

function makeElement(tag) {
  const el = {
    tagName: String(tag || '').toUpperCase(), type: '', class: '',
    children: [], attrs: {}, listeners: {},
    className: '', textContent: '', value: '', checked: false, disabled: false,
    hidden: false, title: '', alt: '', src: '', dir: '', tabIndex: 0,
    style: { setProperty(k, v) { this[k] = String(v); } },
    dataset: {}, focused: false, parentNode: null,
    appendChild(c) {
      if (c.parentNode && c.parentNode !== this && typeof c.parentNode.removeChild === 'function') c.parentNode.removeChild(c);
      else if (c.parentNode === this) { const i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); }
      c.parentNode = this; this.children.push(c); return c;
    },
    removeChild(c) {
      const i = this.children.indexOf(c);
      if (i >= 0) this.children.splice(i, 1);
      if (c.parentNode === this) c.parentNode = null;
      return c;
    },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    removeAttribute(k) { delete this.attrs[k]; },
    addEventListener(t, f) { this.listeners[t] = f; },
    removeEventListener(t) { delete this.listeners[t]; },
    focus() { this.focused = true; },
    classList: {
      add(c) { if (!String(this._el.className).split(/\s+/).includes(c)) this._el.className = (this._el.className + ' ' + c).trim(); },
      remove(c) { this._el.className = String(this._el.className).split(/\s+/).filter(x => x && x !== c).join(' '); },
      toggle(c, on) { if (on) this.add(c); else this.remove(c); },
      contains(c) { return String(this._el.className).split(/\s+/).includes(c); }
    }
  };
  el.classList._el = el;
  Object.defineProperty(el, 'innerHTML', {
    get() { return this._html || ''; },
    set(v) { this._html = String(v); if (v === '') this.children = []; }
  });
  return el;
}

function harness(opts) {
  const elements = new Map();
  function byId(id) {
    if (!elements.has(id)) elements.set(id, makeElement('div'));
    return elements.get(id);
  }
  const document = {
    getElementById: byId,
    createElement(tag) { return makeElement(tag); },
    createTextNode(t) { return { nodeType: 3, nodeValue: String(t), textContent: String(t) }; },
    querySelector() { return null; },
    querySelectorAll(selector) {
      if (String(selector).indexOf('#globalTargetsList') >= 0) {
        const out = [];
        const visit = n => {
          if (n && n.type === 'checkbox') out.push(n);
          (n && n.children || []).forEach(visit);
        };
        visit(byId('globalTargetsList'));
        return out;
      }
      return [];
    },
    activeElement: null,
    addEventListener() {},
    removeEventListener() {}
  };
  const model = {
    calls: [], confirm: true, targetsPostGate: null, targetsPostError: null,
    statusGetGate: null, statusGetError: null, statusSnapshotAtStart: false,
    enabledGet: { enabled: true }, enabledGetError: null, enabledSetError: null,
    intervalSetError: null,
    globalStatus: { providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true },
    lastTargetsBody: null
  };
  const context = vm.createContext({
    document,
    window: { addEventListener() {}, localStorage: { getItem() { return null; }, setItem() {} } },
    console, Promise, Date, setTimeout, clearTimeout,
    GLOBAL_CATALOG: CATALOG.map(e => Object.assign({}, e)),
    GLOBAL_DEFAULT_TARGETS: ['codexcli', 'opencode'],
    currentLang: 'ja', localizedText: { ja: new Map(), en: new Map(), 'zh-CN': new Map() }, I18N: {},
    L(key, vars) {
      return String(key).replace(/\{([^{}]+)\}/g, (m, k) =>
        vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
    },
    stateJa(s) { return s; },
    resultJa(s) { return s; },
    globalResultJa(s) { return s; },
    renderGlobalTable() {}, applySearchFilter() {}, renderGlobalLog() {}, updateCommonSyncState() {},
    showConfirm: async () => model.confirm,
    showNotify: async () => {},
    safeFocus() {},
    esc(s) { return String(s == null ? '' : s); },
    diffLinesLocal() { return { same: true, lines: [] }; },
    renderDiffFrag() { return {}; },
    setMsg(id, msg, ok) {
      const d = byId(id);
      d.textContent = '';
      d.children = [];
      const p = makeElement('p');
      p.className = ok ? 'ok' : 'err';
      p.textContent = msg;
      d.appendChild(p);
    },
    api: async (ep, method, body) => {
      model.calls.push({ ep, method, body });
      if (ep === '/api/global-status') {
        const snapshot = model.statusSnapshotAtStart ? JSON.parse(JSON.stringify(model.globalStatus)) : null;
        const gate = typeof model.statusGetGate === 'function' ? model.statusGetGate() : model.statusGetGate;
        if (gate) await gate;
        if (model.statusGetError) throw model.statusGetError;
        return snapshot || JSON.parse(JSON.stringify(model.globalStatus));
      }
      if (ep === '/api/global-targets-set') {
        model.lastTargetsBody = body;
        if (model.targetsPostGate) await model.targetsPostGate;
        if (model.targetsPostError) throw model.targetsPostError;
        model.globalStatus.targets = ((body && body.targets) || []).slice();
        return { ok: true, targets: model.globalStatus.targets };
      }
      if (ep === '/api/global-enabled-get') {
        if (model.enabledGetError) throw model.enabledGetError;
        return model.enabledGet;
      }
      if (ep === '/api/global-enabled-set') {
        if (model.enabledSetError) throw model.enabledSetError;
        model.globalStatus.taskEnabled = body.enabled;
        return { ok: true, enabled: body.enabled };
      }
      if (ep === '/api/global-interval-get') return { minutes: model.globalStatus.intervalMinutes };
      if (ep === '/api/global-interval-set') {
        if (model.intervalSetError) throw model.intervalSetError;
        model.globalStatus.intervalMinutes = body.minutes;
        return { ok: true, minutes: body.minutes };
      }
      return {};
    }
  });
  const code = logoLine() + '\n' + mainBlock() + '\n' +
    assignmentBlock('btnGlobalTargetsAll') + '\n' +
    assignmentBlock('btnGlobalTargetsNone') + '\n' +
    assignmentBlock('btnGlobalTargets') + '\n' +
    assignmentBlock('btnGlobalReload') + '\n' +
    assignmentBlock('btnGlobalIntervalSet') + '\n' +
    assignmentBlock('btnGlobalEnabled') + '\n' +
    ';globalThis.__gs={renderGlobalTargetsUI:renderGlobalTargetsUI,' +
    'renderGlobalTargetChoices:renderGlobalTargetChoices,globalTargetsSetAll:globalTargetsSetAll,' +
    'markGlobalTargetsDirty:markGlobalTargetsDirty,globalSelectedTargets:globalSelectedTargets,' +
    'globalTargetCheckboxes:globalTargetCheckboxes,updateGlobalUI:updateGlobalUI,' +
    'renderGlobalStatus:renderGlobalStatus,globalProviderLogo:globalProviderLogo,' +
    'globalLogoInitials:globalLogoInitials,renderGlobalTargetsUI:renderGlobalTargetsUI,' +
    'globalSavedTargets:globalSavedTargets,globalTargetsDirty:globalTargetsDirty,' +
    'globalTargetsSaving:globalTargetsSaving,globalEnabledInflight:globalEnabledInflight,' +
    'lastGlobalPlan:lastGlobalPlan};';
  vm.runInContext(code, context);
  if (!(opts && opts.uninitializedStatus)) {
    context.currentGlobalStatus = JSON.parse(JSON.stringify(model.globalStatus));
    context.__gs.renderGlobalTargetsUI();
  }
  const checks = () => {
    const out = [];
    const visit = n => {
      if (n && n.type === 'checkbox') out.push(n);
      (n && n.children || []).forEach(visit);
    };
    visit(byId('globalTargetsList'));
    return out;
  };
  const checkFor = id => checks().filter(c => c.value === id)[0];
  const state = () => ({
    saved: Array.from(context.globalSavedTargets || []),
    dirty: context.globalTargetsDirty,
    selected: Array.from(context.globalSelectedTargets()),
    saving: context.globalTargetsSaving,
    inflight: context.globalEnabledInflight
  });
  return { context, model, document, byId, checks, checkFor, state, gs: context.__gs, elements };
}

// --- static markup / CSS / logo contract ----------------------------------
test('Global settings markup exposes the card list, toolbar, save state and switch', () => {
  const html = sectionHtml();
  must(/<div id="globalTargetsList" class="gs-grid" role="group"/.test(html), 'card grid with group role');
  must(/id="globalTargetsCount"[^>]*aria-live="polite"/.test(html), 'translated live count');
  must(/id="btnGlobalTargetsAll"[^>]*disabled[^>]*data-i18n="すべて選択"/.test(html), 'select all starts disabled');
  must(/id="btnGlobalTargetsNone"[^>]*disabled[^>]*data-i18n="すべて解除"/.test(html), 'clear all starts disabled');
  must(/id="btnGlobalTargets"[^>]*disabled/.test(html), 'save starts disabled');
  must(/id="globalTargetsDirty"[^>]*role="status"/.test(html), 'dirty status');
  must(/id="btnGlobalEnabled"[^>]*role="switch"[^>]*aria-checked="false"/.test(html), 'real accessible switch');
  must(/id="globalSyncPill"/.test(html), 'status pill');
  must(/id="globalEnabledState"/.test(html), 'current sync state text');
  must(/id="numGlobalInterval"[^>]*min="5"[^>]*max="1440"/.test(html), 'actual interval range 5..1440');
  must(!/id="numGlobalInterval"[^>]*min="1"/.test(html), 'demo interval min=1 not used');
  must(/id="msgGlobalInterval"[^>]*role="status"/.test(html), 'interval status message');
});

test('Global settings styles are scoped, scroll-bounded, responsive and reduced-motion aware', () => {
  const css = gsCss();
  must(/max-height:272px/.test(css), '272px bounded height');
  must(/overflow-y:auto/.test(css), 'vertical scroll');
  must(/repeat\(auto-fill,minmax\(230px,1fr\)\)/.test(css), 'responsive columns');
  must(/:focus-visible \+ \.gs-card/.test(css), 'keyboard focus ring on card');
  must(/prefers-reduced-motion:reduce/.test(css), 'reduced motion');
  must(!/\n\s*\.(?:card|grid|path|provider|toolbar|switch)\s*\{/.test(css), 'new generic classes are not unscoped');
  const selectors = [];
  const noComments = css.replace(/\/\*[\s\S]*?\*\//g, '');
  for (const part of noComments.split('}')) {
    const brace = part.indexOf('{');
    if (brace < 0) continue;
    const sel = part.slice(0, brace).trim();
    if (sel) selectors.push(sel);
  }
  must(selectors.length > 0, 'css rules found');
  for (const sel of selectors) {
    if (sel.startsWith('@media')) continue;
    must(sel.indexOf('#gsettings') >= 0, 'rule is scoped: ' + sel);
  }
});

test('logo map is fixed, self-contained and covers the supplied CommandCode asset', () => {
  const map = logos();
  const expected = ['codexcli', 'opencode', 'claudecode', 'cline', 'copilotcli', 'antigravity-cli',
    'commandcode', 'roo', 'goose', 'devin', 'zed', 'codebuddy', 'kimi-code', 'qoder', 'pi'].sort();
  const keys = Object.keys(map).sort();
  must(keys.join('|') === expected.join('|'), 'exact canonical logo keys: ' + keys.join(','));
  must(Object.prototype.hasOwnProperty.call(map, 'commandcode'), 'CommandCode logo is embedded');
  must(!Object.prototype.hasOwnProperty.call(map, 'continue'), 'missing logo is not fabricated');
  must(!Object.prototype.hasOwnProperty.call(map, 'crush'), 'missing logo is not fabricated');
  must(!Object.prototype.hasOwnProperty.call(map, 'vibe'), 'missing logo is not fabricated');
  for (const key of keys) {
    const url = map[key];
    must(/^data:image\/svg\+xml;base64,[A-Za-z0-9+/=]+$/.test(url), key + ' is a fixed data URL');
    const svg = Buffer.from(url.split(',')[1], 'base64').toString('utf8');
    must(/<svg[\s>]/.test(svg), key + ' has an svg root');
    must(!/<script/i.test(svg), key + ' has no script');
    must(!/<foreignObject/i.test(svg), key + ' has no foreignObject');
    must(!/href\s*=/i.test(svg) && !/xlink:href/i.test(svg), key + ' has no external href');
    must(!/<image/i.test(svg), key + ' has no embedded image');
    must(!/@import/i.test(svg), key + ' has no css import');
    must(!/url\(\s*['"]?(?:https?:|\/\/|data:)/i.test(svg), key + ' has no external url()');
    must(!/<style/i.test(svg), key + ' has no embedded style (logo tile is decorative)');
  }
});

test('card renderer keeps canonical IDs, decorative logos and deterministic initials fallback', () => {
  const h = harness();
  const boxes = h.checks();
  must(boxes.length === 18, '18 canonical provider checkboxes');
  must(boxes.map(b => b.value).join('|') === CATALOG.map(e => e.id).join('|'), 'catalog order and canonical IDs preserved');
  for (const box of boxes) {
    const label = box.parentNode;
    must(label && label.className === 'gs-provider', box.value + ' is wrapped by a keyboard label');
    const card = label.children[1];
    must(card && card.className === 'gs-card', box.value + ' has a scoped card');
    must(card.children[0] && card.children[0].className.indexOf('gs-logo') === 0, box.value + ' has a logo tile');
    must(card.children[2] && card.children[2].className === 'gs-check', box.value + ' has a visual check');
  }
  const codex = h.checkFor('codexcli').parentNode.children[1];
  must(codex.children[0].children[0] && codex.children[0].children[0].tagName === 'IMG', 'mapped logo uses img');
  must(codex.children[0].children[0].alt === '', 'logo img is decorative alt=""');
  must(/^data:image\/svg\+xml;base64,/.test(codex.children[0].children[0].src), 'logo uses data URL only');
  must(codex.children[0].getAttribute('aria-hidden') === 'true', 'logo tile is aria-hidden');
  const cc = h.checkFor('commandcode').parentNode.children[1];
  must(cc.children[0].children[0] && cc.children[0].children[0].tagName === 'IMG', 'commandcode logo uses img');
  for (const [id, initials] of [['continue', 'CO'], ['crush', 'CR'], ['vibe', 'VI']]) {
    const card = h.checkFor(id).parentNode.children[1];
    must(card.children[0].children.length === 0, id + ' has no fabricated image');
    must(card.children[0].textContent === initials, id + ' initials fallback');
  }
  const failTile = makeElement('span');
  const failed = h.gs.globalProviderLogo({ id: 'goose', label: 'Goose', rel: 'x' });
  const img = failed.children[0];
  must(img && img.tagName === 'IMG', 'goose maps to an image');
  failed.appendChild(failTile);
  if (img.onerror) img.onerror();
  must(failed.children.indexOf(img) < 0 || failed.children.length === 0, 'failed logo image is removed');
  must(failed.textContent === 'GO', 'failed logo keeps initials fallback');
  must(failed.className.indexOf('gs-has-img') < 0, 'failed logo drops image styling');
});

// --- selection / dirty / preview -----------------------------------------
test('count, select all/none, revert and preview invalidation share one change path', () => {
  const h = harness();
  const count = h.byId('globalTargetsCount');
  must(count.textContent === '2 / 18 件を選択中', 'initial translated count: ' + count.textContent);
  must(h.byId('btnGlobalTargets').disabled === true, 'initial save disabled');
  h.context.lastGlobalPlan = { id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', names: ['codexcli', 'opencode'] };
  h.byId('btnGlobalTargetsAll').onclick();
  must(h.state().selected.length === 18, 'select all selects 18');
  must(count.textContent === '18 / 18 件を選択中', 'select all count');
  must(h.state().dirty === true, 'select all marks dirty');
  must(h.byId('btnGlobalTargets').disabled === false, 'select all enables save');
  must(h.context.lastGlobalPlan === null, 'select all invalidates approved preview');
  h.context.lastGlobalPlan = { id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', names: CATALOG.map(e => e.id) };
  h.byId('btnGlobalTargetsNone').onclick();
  must(h.state().selected.length === 0, 'clear all clears selection');
  must(count.textContent === '0 / 18 件を選択中', 'clear all count');
  must(h.state().dirty === true, 'clear all marks dirty for editing');
  must(h.byId('btnGlobalTargets').disabled === true, 'empty selection cannot save');
  must(h.context.lastGlobalPlan === null, 'clear all invalidates approved preview');
  h.checkFor('codexcli').checked = true;
  h.checkFor('opencode').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(h.state().dirty === false, 'reverting to saved selection clears dirty');
  must(h.byId('btnGlobalTargets').disabled === true, 'reverted state disables save');
  must(h.context.lastGlobalPlan === null, 'revert still keeps preview invalidated');
});

const cardOrder = h => h.checks().map(c => c.value);
function adopt(h, targets) {
  h.gs.updateGlobalUI({ providers: [], targets: targets.slice(), syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true });
}

test('saved selection is pinned to the top while toggling keeps the card order', () => {
  const h = harness();
  adopt(h, ['claudecode', 'pi']);
  must(cardOrder(h).slice(0, 2).join('|') === 'claudecode|pi', 'adopted baseline pins selected cards: ' + cardOrder(h).slice(0, 6).join(','));
  must(cardOrder(h).slice(2, 4).join('|') === 'codexcli|opencode', 'unselected cards keep catalog order');
  const afterAdopt = cardOrder(h).join('|');
  h.checkFor('zed').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(cardOrder(h).join('|') === afterAdopt, 'checking a new provider does not move cards');
  h.checkFor('claudecode').checked = false;
  h.gs.markGlobalTargetsDirty();
  must(cardOrder(h).join('|') === afterAdopt, 'unchecking a pinned provider does not move cards');
  h.checkFor('claudecode').checked = true;
  h.checkFor('zed').checked = false;
  h.gs.markGlobalTargetsDirty();
  must(cardOrder(h).join('|') === afterAdopt, 'reverting the edit keeps the established order');
});

await testAsync('an ordinary clean poll pins its adopted baseline', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['qoder', 'goose'];
  await h.context.refreshGlobal();
  must(cardOrder(h).slice(0, 2).join('|') === 'goose|qoder', 'clean poll reorders to the saved baseline');
  must(h.state().saved.join('|') === 'qoder|goose', 'clean poll adopts the baseline');
});

await testAsync('a status response racing an edit moves the baseline without moving cards', async () => {
  const h = harness();
  adopt(h, ['claudecode', 'pi']);
  const before = cardOrder(h).join('|');
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  h.model.globalStatus.targets = ['qoder', 'claudecode'];
  const poll = h.context.refreshGlobal();
  h.checkFor('zed').checked = true;
  h.gs.markGlobalTargetsDirty();
  release();
  await poll;
  must(h.state().saved.join('|') === 'qoder|claudecode', 'the raced response becomes the baseline');
  must(cardOrder(h).join('|') === before, 'the raced response leaves card order alone');
  must(h.state().dirty === true, 'the edit stays dirty against the new baseline');
  must(h.checkFor('zed').checked === true, 'the edit survives the raced response');
});

await testAsync('explicit reload pins the adopted baseline and keeps order under a concurrent edit', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const first = h.byId('btnGlobalReload').onclick();
  release();
  await first;
  must(cardOrder(h).slice(0, 2).join('|') === 'claudecode|pi', 'reload pins the adopted baseline');
  const before = cardOrder(h).join('|');
  h.model.globalStatus.targets = ['qoder', 'goose'];
  let release2;
  h.model.statusGetGate = new Promise(resolve => { release2 = resolve; });
  const second = h.byId('btnGlobalReload').onclick();
  h.checkFor('zed').checked = true;
  h.gs.markGlobalTargetsDirty();
  release2();
  await second;
  must(h.state().saved.join('|') === 'qoder|goose', 'the reload response is the new baseline');
  must(cardOrder(h).join('|') === before, 'an edit during reload keeps the established card order');
});

await testAsync('a successful save pins the saved selection to the top', async () => {
  const h = harness();
  h.checkFor('codexcli').checked = false;
  h.checkFor('opencode').checked = false;
  h.checkFor('claudecode').checked = true;
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  await h.byId('btnGlobalTargets').onclick();
  must(h.state().saved.join('|') === 'claudecode|pi', 'the save moves the baseline');
  must(cardOrder(h).slice(0, 2).join('|') === 'claudecode|pi', 'saved cards are pinned: ' + cardOrder(h).slice(0, 6).join(','));
  must(cardOrder(h).slice(2, 4).join('|') === 'codexcli|opencode', 'unsaved cards keep catalog order');
});

test('reordering moves the existing nodes and restores focus', () => {
  const h = harness();
  adopt(h, ['claudecode', 'pi']);
  const box = h.byId('globalTargetsList');
  const active = h.checkFor('codexcli');
  active.checked = true;
  h.document.activeElement = active;
  const append = box.appendChild.bind(box);
  box.appendChild = function (card) {
    if (h.document.activeElement === active) h.document.activeElement = null;
    return append(card);
  };
  h.context.globalSavedTargets = ['qoder'];
  h.gs.renderGlobalTargetsUI(true);
  must(cardOrder(h)[0] === 'qoder', 'the forced order uses the new baseline');
  must(h.checkFor('codexcli') === active, 'the same checkbox node is retained');
  must(active.checked === true, 'checked state survives the move');
  must(active.focused === true, 'focus is restored after the move');
});

test('dirty selection survives status polls and locale rerenders; clean polls adopt saved state', () => {
  const h = harness();
  h.checkFor('codexcli').checked = false;
  h.checkFor('opencode').checked = false;
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(h.state().dirty === true, 'unsaved pi selection is dirty');
  h.gs.updateGlobalUI({ providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true });
  must(h.state().selected.join('|') === 'pi', 'poll does not clobber unsaved selection');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'poll does not move the saved baseline while dirty');
  must(h.checkFor('pi').checked === true, 'pi stays checked after poll');
  h.context.L = (key, vars) => String(key)
    .replace('{selected} / {total} 件を選択中', '{selected} / {total} selected')
    .replace('未保存の変更があります', 'You have unsaved changes.')
    .replace(/\{([^{}]+)\}/g, (m, k) => vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
  h.gs.renderGlobalTargetsUI();
  must(h.byId('globalTargetsCount').textContent === '1 / 18 selected', 'count follows the locale');
  must(h.byId('globalTargetsDirty').textContent === 'You have unsaved changes.', 'dirty text follows the locale');
  must(h.checkFor('pi').checked === true, 'locale rerender keeps unsaved selection');
  h.context.L = (key, vars) => String(key).replace(/\{([^{}]+)\}/g, (m, k) => vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
  h.checkFor('codexcli').checked = true;
  h.checkFor('opencode').checked = true;
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  must(h.state().dirty === false, 'revert after locale change clears dirty');
  h.gs.updateGlobalUI({ providers: [], targets: ['pi'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true });
  must(h.state().saved.join('|') === 'pi', 'clean poll adopts server saved selection');
  must(h.checkFor('pi').checked === true && h.checkFor('codexcli').checked === false, 'clean poll updates selection');
  must(h.state().dirty === false && h.byId('btnGlobalTargets').disabled === true, 'clean poll keeps save disabled');
});

await testAsync('explicit reload adopts the saved selection only after a successful GET', async () => {
  const h = harness();
  h.checkFor('opencode').checked = false;
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(h.state().selected.join('|') === 'codexcli|pi', 'setup: unsaved selection');
  must(h.state().dirty === true, 'setup: dirty');
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-status').length === 1, 'reload issues one GET before adopting');
  must(h.state().selected.join('|') === 'codexcli|pi', 'in-flight reload does not adopt early');
  must(h.state().dirty === true, 'in-flight reload keeps unsaved dirty');
  must(h.checkFor('pi').checked === true, 'in-flight reload keeps edited checkbox');
  release();
  await pending;
  must(h.state().saved.join('|') === 'claudecode|pi', 'successful reload adopts saved baseline');
  must(h.state().selected.join('|') === 'claudecode|pi', 'successful reload replaces the selection');
  must(h.checkFor('claudecode').checked === true && h.checkFor('pi').checked === true && h.checkFor('codexcli').checked === false, 'successful reload replaces checkboxes');
  must(h.state().dirty === false, 'successful reload clears dirty');
  must(h.byId('globalTargetsDirty').textContent === '', 'successful reload clears the dirty status');
  must(h.byId('globalTargetsCount').textContent === '2 / 18 件を選択中', 'successful reload updates the count');
  must(h.byId('btnGlobalTargets').disabled === true, 'successful reload disables save');
  h.checkFor('claudecode').checked = false;
  h.checkFor('qoder').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.gs.updateGlobalUI({ providers: [], targets: ['codexcli'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true });
  must(h.state().selected.join('|') === 'qoder|pi', 'normal poll keeps editing after a reload');
  h.gs.renderGlobalTargetsUI();
  must(h.checkFor('qoder').checked === true && h.checkFor('claudecode').checked === false, 'locale rerender keeps editing after a reload');
  h.model.statusGetGate = null;
  h.model.statusGetError = new Error('status GET failed');
  const savedBefore = h.state().saved.join('|');
  const selectedBefore = h.state().selected.join('|');
  await h.byId('btnGlobalReload').onclick();
  must(h.state().selected.join('|') === selectedBefore, 'failed reload keeps the current selection');
  must(h.state().saved.join('|') === savedBefore, 'failed reload does not fake a saved baseline');
  must(h.state().dirty === true, 'failed reload keeps dirty');
  must(h.checkFor('qoder').checked === true && h.checkFor('claudecode').checked === false, 'failed reload keeps checkboxes');
  must(h.byId('btnGlobalTargets').disabled === false, 'failed reload keeps save available');
});

await testAsync('a target edit made while reload is pending survives the reload response', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  release();
  await pending;
  must(h.state().selected.join('|') === 'codexcli|opencode|pi', 'target edit made during the GET is kept');
  must(h.state().saved.join('|') === 'claudecode|pi', 'the response becomes the saved baseline');
  must(h.state().dirty === true, 'the surviving target edit stays dirty');
  must(h.checkFor('claudecode').checked === false, 'the response does not check the server target');
  must(String(h.byId('numGlobalInterval').value) === '30', 'the untouched interval is still adopted');
});

await testAsync('an interval edit made while reload is pending survives while targets still adopt', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  const input = h.byId('numGlobalInterval');
  input.value = '45';
  input.listeners.input();
  release();
  await pending;
  must(String(input.value) === '45', 'interval edit made during the GET is kept');
  must(h.state().saved.join('|') === 'claudecode|pi', 'untouched targets adopt the response');
  must(h.state().selected.join('|') === 'claudecode|pi', 'untouched checkboxes follow the response');
  must(h.state().dirty === false, 'adopted targets clear dirty');
  h.gs.updateGlobalUI({ providers: [], targets: ['claudecode', 'pi'], syncState: 'idle', intervalMinutes: 30, taskEnabled: true, githubConfigured: true });
  must(String(input.value) === '45', 'a later poll keeps the unsaved interval');
});

await testAsync('target and interval edits made while reload is pending are both preserved', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  const input = h.byId('numGlobalInterval');
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  input.value = '45';
  input.listeners.input();
  release();
  await pending;
  must(h.state().selected.join('|') === 'codexcli|opencode|pi', 'target edit made during the GET is kept');
  must(h.state().saved.join('|') === 'claudecode|pi', 'the response becomes the saved baseline');
  must(h.state().dirty === true, 'the target edit stays dirty');
  must(String(input.value) === '45', 'interval edit made during the GET is kept');
});

await testAsync('a reload with no edits during the GET still adopts targets and interval', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  release();
  await pending;
  must(h.state().selected.join('|') === 'claudecode|pi', 'targets adopt when untouched through the GET');
  must(h.state().saved.join('|') === 'claudecode|pi', 'the saved target baseline moves');
  must(h.state().dirty === false, 'dirty clears after untouched adoption');
  must(String(h.byId('numGlobalInterval').value) === '30', 'interval adopts when untouched through the GET');
});

await testAsync('a reverted edit made during reload keeps the UI but adopts the response baseline', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  release();
  await pending;
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the reverted selection is kept');
  must(h.checkFor('claudecode').checked === false, 'the response is not adopted after an edit-then-revert');
  must(h.state().saved.join('|') === 'claudecode|pi', 'the saved baseline moves to the response');
  must(h.state().dirty === true, 'the kept UI differs from the response baseline');
  must(h.byId('btnGlobalTargets').disabled === false, 'save is available for the difference');
  must(String(h.byId('numGlobalInterval').value) === '30', 'the untouched interval is still adopted');
});

await testAsync('a preserved reload edit survives polls and locale redraw and can be saved', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  release();
  await pending;
  must(h.state().selected.join('|') === 'codexcli|opencode', 'reload response keeps the edited UI');
  must(h.state().saved.join('|') === 'claudecode|pi', 'reload response becomes the saved baseline');
  must(h.state().dirty === true, 'the difference is dirty after the response');
  must(h.byId('btnGlobalTargets').disabled === false, 'save is enabled after the response');
  h.model.statusGetGate = null;
  await h.context.refreshGlobal();
  must(h.state().selected.join('|') === 'codexcli|opencode', 'a normal poll keeps the preserved selection');
  must(h.checkFor('codexcli').checked === true && h.checkFor('opencode').checked === true, 'a normal poll keeps the preserved checkboxes');
  must(h.checkFor('claudecode').checked === false && h.checkFor('pi').checked === false, 'a normal poll does not restore the old server targets');
  must(h.state().saved.join('|') === 'claudecode|pi', 'a normal poll leaves the response baseline while dirty');
  h.context.L = (key, vars) => String(key)
    .replace('未保存の変更があります', 'You have unsaved changes.')
    .replace(/\{([^{}]+)\}/g, (m, k) => vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
  h.gs.renderGlobalTargetsUI();
  must(h.checkFor('codexcli').checked === true && h.checkFor('opencode').checked === true, 'a locale redraw keeps the preserved checkboxes');
  must(h.byId('globalTargetsDirty').textContent === 'You have unsaved changes.', 'the locale redraw shows the dirty state');
  must(h.byId('btnGlobalTargets').disabled === false, 'the locale redraw keeps save enabled');
  await h.byId('btnGlobalTargets').onclick();
  const posts = h.model.calls.filter(c => c.ep === '/api/global-targets-set');
  must(posts.length === 1, 'the user can save the preserved selection');
  must(JSON.stringify(posts[0].body) === JSON.stringify({ targets: ['codexcli', 'opencode'], confirm: true }), 'save sends the preserved canonical payload');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'the save moves the baseline to the preserved selection');
  must(h.state().dirty === false && h.byId('btnGlobalTargets').disabled === true, 'the save clears the difference');
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the save refresh keeps the saved selection');
});

await testAsync('a preserved reload edit equal to the response stays clean', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['codexcli', 'opencode'];
  let release;
  h.model.statusGetGate = new Promise(resolve => { release = resolve; });
  const pending = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  release();
  await pending;
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the reverted selection is kept');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'the equal response is the baseline');
  must(h.state().dirty === false, 'equal selections are clean');
  must(h.byId('btnGlobalTargets').disabled === true, 'equal selections keep save disabled');
});

// --- response ordering races ---------------------------------------------
function statusGates(h) {
  const gates = [];
  h.model.statusGetGate = () => new Promise(resolve => gates.push(resolve));
  return gates;
}
const tick = () => new Promise(resolve => setTimeout(resolve, 0));

await testAsync('a stale ordinary response cannot overwrite a reverted edit protected by a pending reload', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  h.model.globalStatus.intervalMinutes = 30;
  const gates = statusGates(h);
  const poll = h.context.refreshGlobal();
  const reload = h.byId('btnGlobalReload').onclick();
  must(gates.length === 2, 'the ordinary poll and explicit reload are both in flight');
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  must(h.state().dirty === false, 'setup: the toggled edit is reverted to the saved baseline');
  gates[0]();
  await tick();
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the stale poll keeps the reverted UI');
  must(h.checkFor('claudecode').checked === false && h.checkFor('pi').checked === false, 'the stale poll does not apply the server targets');
  must(h.state().saved.join('|') === 'claudecode|pi', 'the successful poll is still the server baseline');
  must(h.state().dirty === true, 'the kept UI differs from the poll baseline');
  must(h.byId('btnGlobalTargets').disabled === false, 'save is available for the kept UI');
  gates[1]();
  await Promise.all([poll, reload]);
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the reload response keeps the reverted UI');
  must(h.state().saved.join('|') === 'claudecode|pi', 'the reload response is the baseline');
  must(h.state().dirty === true, 'the reverted UI is dirty against the server');
  must(h.byId('btnGlobalTargets').disabled === false, 'save stays available after the reload');
  h.model.statusGetGate = null;
  await h.context.refreshGlobal();
  must(h.state().selected.join('|') === 'codexcli|opencode', 'a later poll keeps the reverted UI');
  must(h.state().saved.join('|') === 'claudecode|pi', 'a later poll keeps the server baseline');
  h.gs.renderGlobalTargetsUI();
  must(h.checkFor('codexcli').checked === true && h.checkFor('opencode').checked === true, 'locale redraw keeps the reverted UI');
  must(h.byId('btnGlobalTargets').disabled === false, 'locale redraw keeps save available');
  await h.byId('btnGlobalTargets').onclick();
  const posts = h.model.calls.filter(c => c.ep === '/api/global-targets-set');
  must(posts.length === 1 && JSON.stringify(posts[0].body.targets) === JSON.stringify(['codexcli', 'opencode']), 'the kept UI saves its canonical selection');
  must(h.state().saved.join('|') === 'codexcli|opencode' && h.state().dirty === false, 'saving the kept UI makes it the baseline');
  h.model.globalStatus.targets = ['pi'];
  await h.context.refreshGlobal();
  must(h.state().saved.join('|') === 'pi' && h.state().selected.join('|') === 'pi', 'a clean ordinary poll still adopts server targets');
  must(h.state().dirty === false, 'a clean ordinary poll stays clean');
});

await testAsync('a stale ordinary response equal to the kept edit stays clean', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['codexcli', 'opencode'];
  const gates = statusGates(h);
  const poll = h.context.refreshGlobal();
  const reload = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  gates[0]();
  await tick();
  must(h.state().saved.join('|') === 'codexcli|opencode', 'the equal poll response is the baseline');
  must(h.state().selected.join('|') === 'codexcli|opencode' && h.state().dirty === false, 'the equal stale response stays clean');
  must(h.byId('btnGlobalTargets').disabled === true, 'the equal stale response keeps save disabled');
  gates[1]();
  await Promise.all([poll, reload]);
  must(h.state().saved.join('|') === 'codexcli|opencode' && h.state().dirty === false, 'the equal reload response also stays clean');
});

await testAsync('a poll started after the edit cannot bypass a pending reload protection', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  const gates = statusGates(h);
  const oldPoll = h.context.refreshGlobal();
  const reload = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  const newPoll = h.context.refreshGlobal();
  must(gates.length === 3, 'a new poll starts after the reverted edit while the reload is still pending');
  gates[2]();
  await tick();
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the newer poll does not apply server targets under a pending reload');
  must(h.checkFor('claudecode').checked === false && h.checkFor('pi').checked === false, 'the newer poll keeps the reverted checkboxes');
  must(h.state().dirty === false, 'the newer poll does not fake a dirty selection');
  gates[1]();
  await reload;
  must(h.state().saved.join('|') === 'claudecode|pi', 'the reload response is the baseline');
  must(h.state().selected.join('|') === 'codexcli|opencode' && h.state().dirty === true, 'the reload preserves the reverted UI against the baseline');
  gates[0]();
  await Promise.all([oldPoll, newPoll]);
  must(h.state().saved.join('|') === 'claudecode|pi', 'the old poll does not roll the baseline back');
  must(h.state().selected.join('|') === 'codexcli|opencode' && h.state().dirty === true, 'the old poll keeps the reload-protected UI');
});

await testAsync('a newer reload response is not rolled back by an older poll response', async () => {
  const h = harness();
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  const gates = statusGates(h);
  const poll = h.context.refreshGlobal();
  const reload = h.byId('btnGlobalReload').onclick();
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('pi').checked = false;
  h.gs.markGlobalTargetsDirty();
  h.model.globalStatus.targets = ['qoder', 'pi'];
  gates[1]();
  await reload;
  must(h.state().saved.join('|') === 'qoder|pi', 'the reload response becomes the baseline');
  must(h.state().selected.join('|') === 'codexcli|opencode' && h.state().dirty === true, 'the reload keeps the reverted UI');
  h.model.globalStatus.targets = ['claudecode', 'pi'];
  gates[0]();
  await poll;
  must(h.state().saved.join('|') === 'qoder|pi', 'the older poll cannot move the baseline back');
  must(h.state().selected.join('|') === 'codexcli|opencode' && h.state().dirty === true, 'the older poll keeps the newer baseline');
});

await testAsync('an older poll cannot roll back the interval adopted by a newer reload', async () => {
  const h = harness();
  h.model.globalStatus.intervalMinutes = 15;
  const gates = statusGates(h);
  const poll = h.context.refreshGlobal();
  const reload = h.byId('btnGlobalReload').onclick();
  h.model.globalStatus.intervalMinutes = 30;
  gates[1]();
  await reload;
  const input = h.byId('numGlobalInterval');
  must(String(input.value) === '30', 'the newer reload adopts its interval');
  h.model.globalStatus.intervalMinutes = 15;
  gates[0]();
  await poll;
  must(String(input.value) === '30', 'the older poll cannot roll the interval back');
});

// --- save flow -----------------------------------------------------------
await testAsync('save sends only a real changed nonempty canonical selection', async () => {
  const h = harness();
  h.byId('btnGlobalTargets').onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 0, 'unchanged selection never posts');
  h.byId('btnGlobalTargetsNone').onclick();
  h.byId('btnGlobalTargets').onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 0, 'empty selection never posts');
  must(h.state().dirty === true, 'empty save keeps dirty for editing');
  must(/1つ以上/.test(h.byId('msgGlobalTargets').children[0].textContent), 'empty save is refused with a message');
  h.checkFor('codexcli').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.checkFor('claudecode').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.model.confirm = false;
  await h.byId('btnGlobalTargets').onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 0, 'cancel never posts');
  must(h.state().dirty === true, 'cancel keeps dirty');
  h.model.confirm = true;
  await h.byId('btnGlobalTargets').onclick();
  const post = h.model.calls.filter(c => c.ep === '/api/global-targets-set')[0];
  must(post && post.method === 'POST', 'confirmed change posts once');
  must(JSON.stringify(post.body) === JSON.stringify({ targets: ['codexcli', 'claudecode'], confirm: true }), 'canonical payload and confirm flag');
  must(h.state().saved.join('|') === 'codexcli|claudecode', 'success moves the saved baseline');
  must(h.state().dirty === false && h.byId('btnGlobalTargets').disabled === true, 'success clears dirty');
});

await testAsync('save failure keeps dirty and the current selection', async () => {
  const h = harness();
  h.checkFor('codexcli').checked = false;
  h.checkFor('opencode').checked = false;
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  h.model.targetsPostError = new Error('save failed hard');
  await h.byId('btnGlobalTargets').onclick();
  must(h.state().dirty === true, 'failure keeps dirty');
  must(h.state().selected.join('|') === 'pi', 'failure keeps current selection');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'failure keeps saved baseline');
  must(h.byId('btnGlobalTargets').disabled === false, 'failure keeps save available');
  must(/save failed hard/.test(h.byId('msgGlobalTargets').children[0].textContent), 'failure message shown');
});

await testAsync('an in-flight save never loses toggles made while the backend is running', async () => {
  const h = harness();
  let release;
  h.model.targetsPostGate = new Promise(resolve => { release = resolve; });
  h.checkFor('opencode').checked = false;
  h.gs.markGlobalTargetsDirty();
  const pending = h.byId('btnGlobalTargets').onclick();
  await new Promise(resolve => setTimeout(resolve, 0));
  must(h.byId('btnGlobalTargets').disabled === true, 'save disabled while in flight');
  must(h.checkFor('pi').disabled === false, 'provider toggles stay editable while saving');
  h.checkFor('pi').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(h.state().dirty === true, 'in-flight toggle marks dirty again');
  release({ ok: true });
  await pending;
  const post = h.model.calls.filter(c => c.ep === '/api/global-targets-set')[0];
  must(JSON.stringify(post.body.targets) === JSON.stringify(['codexcli']), 'in-flight payload stays the confirmed set');
  must(h.state().saved.join('|') === 'codexcli', 'saved baseline is the confirmed set');
  must(h.state().selected.join('|') === 'codexcli|pi', 'toggle made during save survives');
  must(h.checkFor('pi').checked === true, 'in-flight toggle checkbox survives the response');
  must(h.state().dirty === true, 'remaining difference keeps dirty after success');
  must(h.byId('btnGlobalTargets').disabled === false, 'save stays available for the remaining change');
});

await testAsync('background status during an in-flight save never overwrites a reverted selection', async () => {
  const h = harness();
  let release;
  h.model.targetsPostGate = new Promise(resolve => { release = resolve; });
  h.checkFor('opencode').checked = false;
  h.gs.markGlobalTargetsDirty();
  const pending = h.byId('btnGlobalTargets').onclick();
  await new Promise(resolve => setTimeout(resolve, 0));
  must(h.state().saving === true, 'save is in flight');
  h.checkFor('opencode').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(h.state().dirty === false, 'revert to the saved selection looks clean');
  h.gs.updateGlobalUI({ providers: [], targets: ['codexcli'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true });
  must(h.state().selected.join('|') === 'codexcli|opencode', 'status poll does not overwrite the reverted selection');
  must(h.checkFor('opencode').checked === true, 'status poll does not uncheck the reverted provider');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'status poll does not move the saved baseline while saving');
  must(h.state().dirty === false, 'status poll never fakes a dirty revert');
  release({ ok: true });
  await pending;
  const post = h.model.calls.filter(c => c.ep === '/api/global-targets-set')[0];
  must(JSON.stringify(post.body.targets) === JSON.stringify(['codexcli']), 'in-flight payload stays the confirmed set');
  must(h.state().saved.join('|') === 'codexcli', 'successful POST moves the saved baseline to the confirmed set');
  must(h.state().selected.join('|') === 'codexcli|opencode', 'reverted selection is retained after success');
  must(h.checkFor('opencode').checked === true, 'reverted checkbox survives the save response');
  must(h.state().dirty === true, 'reverted selection differs from the new saved baseline');
  must(h.byId('btnGlobalTargets').disabled === false, 'save stays available for the reverted difference');
  must(h.byId('globalTargetsCount').textContent === '2 / 18 件を選択中', 'count still reflects the retained selection');
});

await testAsync('a successful save invalidates target responses started before it', async () => {
  const h = harness();
  h.model.statusSnapshotAtStart = true;
  const gates = statusGates(h);
  const oldPoll = h.context.refreshGlobal();
  must(gates.length === 1, 'setup: a pre-save target GET is in flight');
  h.checkFor('opencode').checked = false;
  h.gs.markGlobalTargetsDirty();
  must(h.state().selected.join('|') === 'codexcli', 'setup: the save selection is B');
  const saving = h.byId('btnGlobalTargets').onclick();
  await tick();
  must(gates.length === 2, 'the successful save issued its own target GET');
  must(h.state().saving === true, 'the save is still in flight when its own GET completes');
  gates[1]();
  await saving;
  must(h.state().saved.join('|') === 'codexcli', 'the save moves the baseline to B');
  must(h.state().dirty === false, 'setup: the save leaves a clean B');
  h.checkFor('opencode').checked = true;
  h.gs.markGlobalTargetsDirty();
  must(h.state().selected.join('|') === 'codexcli|opencode', 'setup: the next edit restores A in the UI');
  must(h.state().dirty === true && h.byId('btnGlobalTargets').disabled === false, 'setup: A is dirty against B');
  gates[0]();
  await oldPoll;
  must(h.state().saved.join('|') === 'codexcli', 'the pre-save response cannot move the baseline back to A');
  must(h.state().selected.join('|') === 'codexcli|opencode', 'the pre-save response cannot replace the current edit');
  must(h.checkFor('opencode').checked === true, 'the pre-save response cannot uncheck the current edit');
  must(h.state().dirty === true, 'the current edit stays dirty after the pre-save response');
  must(h.byId('btnGlobalTargets').disabled === false, 'the current edit stays saveable after the pre-save response');
  h.model.statusGetGate = null;
  await h.context.refreshGlobal();
  must(h.state().saved.join('|') === 'codexcli', 'a later ordinary poll keeps the saved baseline B');
  must(h.state().selected.join('|') === 'codexcli|opencode', 'a later ordinary poll keeps the current edit A');
  must(h.state().dirty === true, 'a later ordinary poll keeps A dirty against B');
  h.context.L = (key, vars) => String(key)
    .replace('{selected} / {total} 件を選択中', '{selected} / {total} selected')
    .replace('未保存の変更があります', 'You have unsaved changes.')
    .replace(/\{([^{}]+)\}/g, (m, k) => vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
  h.gs.renderGlobalTargetsUI();
  must(h.byId('globalTargetsCount').textContent === '2 / 18 selected', 'the locale redraw keeps the current edit count');
  must(h.byId('globalTargetsDirty').textContent === 'You have unsaved changes.', 'the locale redraw keeps the dirty state');
  must(h.checkFor('opencode').checked === true, 'the locale redraw keeps the current edit checked');
  must(h.byId('btnGlobalTargets').disabled === false, 'the locale redraw keeps the current edit saveable');
  await h.byId('btnGlobalTargets').onclick();
  const posts = h.model.calls.filter(c => c.ep === '/api/global-targets-set');
  must(posts.length === 2, 'the current edit is the second successful save');
  must(JSON.stringify(posts[1].body) === JSON.stringify({ targets: ['codexcli', 'opencode'], confirm: true }), 'the current edit saves A');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'saving the current edit makes A the baseline');
  must(h.state().dirty === false && h.byId('btnGlobalTargets').disabled === true, 'saving the current edit clears the difference');
});

await testAsync('a save boundary only invalidates older target responses, not their interval', async () => {
  const h = harness();
  h.model.statusSnapshotAtStart = true;
  h.model.globalStatus.intervalMinutes = 30;
  const gates = statusGates(h);
  const oldPoll = h.context.refreshGlobal();
  h.model.globalStatus.intervalMinutes = 45;
  h.checkFor('opencode').checked = false;
  h.gs.markGlobalTargetsDirty();
  const saving = h.byId('btnGlobalTargets').onclick();
  await tick();
  must(gates.length === 2, 'setup: the save issued its own target GET');
  gates[0]();
  await oldPoll;
  must(String(h.byId('numGlobalInterval').value) === '30', 'the pre-save response still applies its untouched interval');
  must(h.state().saved.join('|') === 'codexcli', 'the pre-save target response stays invalidated');
  must(h.state().selected.join('|') === 'codexcli' && h.state().dirty === false, 'the saved target selection stays authoritative');
  gates[1]();
  await saving;
  must(String(h.byId('numGlobalInterval').value) === '45', 'the save response applies the newer interval');
  must(h.state().saved.join('|') === 'codexcli' && h.state().dirty === false, 'the save completes with its own baseline');
});

await testAsync('save cancel, deferred failure and repeated clicks preserve the edited selection', async () => {
  const h = harness();
  h.checkFor('opencode').checked = false;
  h.gs.markGlobalTargetsDirty();
  h.model.confirm = false;
  await h.byId('btnGlobalTargets').onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 0, 'cancel never posts');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'cancel keeps the saved baseline');
  must(h.state().selected.join('|') === 'codexcli', 'cancel keeps the edited selection');
  must(h.state().dirty === true, 'cancel keeps dirty');
  h.model.confirm = true;
  let release;
  h.model.targetsPostGate = new Promise(resolve => { release = resolve; });
  h.model.targetsPostError = new Error('save failed after in-flight');
  const pending = h.byId('btnGlobalTargets').onclick();
  await new Promise(resolve => setTimeout(resolve, 0));
  must(h.state().saving === true, 'deferred save reports in flight');
  await h.byId('btnGlobalTargets').onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 1, 'repeated click is ignored while saving');
  release();
  await pending;
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 1, 'failed save posts only once');
  must(h.state().saved.join('|') === 'codexcli|opencode', 'failure keeps the saved baseline');
  must(h.state().selected.join('|') === 'codexcli', 'failure keeps the edited selection');
  must(h.state().dirty === true, 'failure keeps dirty');
  must(h.state().saving === false, 'failure releases the in-flight lock');
  must(h.byId('btnGlobalTargets').disabled === false, 'failure keeps save available');
  must(/save failed after in-flight/.test(h.byId('msgGlobalTargets').children[0].textContent), 'failure message is shown');
});

// --- automatic sync switch ----------------------------------------------
await testAsync('switch reports known state, stays disabled when unknown and never fakes a toggle', async () => {
  const h = harness();
  h.context.currentGlobalStatus = { providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true };
  h.gs.renderGlobalStatus();
  const sw = h.byId('btnGlobalEnabled');
  must(sw.getAttribute('aria-checked') === 'true' && sw.disabled === false, 'enabled state reflected');
  must(/有効/.test(sw.getAttribute('aria-label')), 'switch name includes the current state');
  must(h.byId('globalSyncPill').className.indexOf('on') >= 0, 'enabled pill');
  h.context.currentGlobalStatus = { providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: null, githubConfigured: true };
  h.gs.renderGlobalStatus();
  must(sw.getAttribute('aria-checked') === 'false' && sw.disabled === true, 'unknown state is never shown as on');
  must(/状態不明/.test(sw.getAttribute('aria-label')), 'unknown state is named');
  must(/取得できません/.test(h.byId('globalEnabledState').textContent), 'unknown state pill text');
  const before = h.model.calls.length;
  sw.onclick();
  must(h.model.calls.length === before, 'unknown switch is not actionable');
  h.context.currentGlobalStatus = { providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: false, githubConfigured: true };
  h.gs.renderGlobalStatus();
  must(sw.getAttribute('aria-checked') === 'false' && sw.disabled === false, 'paused state reflected');
  must(/休止中/.test(h.byId('globalEnabledState').textContent), 'paused pill text');
});

await testAsync('confirmed enable flow toggles only after success; cancel and errors keep the old state', async () => {
  const h = harness();
  h.context.currentGlobalStatus = { providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true };
  h.gs.renderGlobalStatus();
  const sw = h.byId('btnGlobalEnabled');
  h.model.confirm = false;
  await sw.onclick();
  must(sw.getAttribute('aria-checked') === 'true', 'cancel keeps the current state');
  must(h.model.calls.filter(c => c.ep === '/api/global-enabled-set').length === 0, 'cancel never posts');
  h.model.confirm = true;
  h.model.enabledSetError = new Error('switch failed');
  await sw.onclick();
  must(sw.getAttribute('aria-checked') === 'true', 'error keeps the current state');
  must(/switch failed/.test(h.byId('msgGlobalInterval').children[0].textContent), 'switch error is shown');
  h.model.enabledSetError = null;
  h.model.confirm = true;
  const postedBeforeSuccess = h.model.calls.filter(c => c.ep === '/api/global-enabled-set').length;
  await sw.onclick();
  const enabledPosts = h.model.calls.filter(c => c.ep === '/api/global-enabled-set');
  must(enabledPosts.length === postedBeforeSuccess + 1, 'confirmed change posts once');
  must(enabledPosts[postedBeforeSuccess].body.enabled === false, 'confirmed payload disables sync');
  must(sw.getAttribute('aria-checked') === 'false', 'success reflects the refreshed status');
});

await testAsync('switch shows in-flight lock and releases it on cancel', async () => {
  const h = harness();
  h.context.currentGlobalStatus = { providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true };
  h.gs.renderGlobalStatus();
  const sw = h.byId('btnGlobalEnabled');
  let resolveConfirm;
  h.context.showConfirm = () => new Promise(resolve => { resolveConfirm = resolve; });
  const pending = sw.onclick();
  await new Promise(resolve => setTimeout(resolve, 0));
  must(sw.disabled === true, 'switch disabled while confirming');
  resolveConfirm(false);
  await pending;
  must(sw.disabled === false, 'switch released after cancel');
  must(sw.getAttribute('aria-checked') === 'true', 'cancel did not toggle');
});

// --- interval controls ---------------------------------------------------
await testAsync('interval controls validate the real 5..1440 range and never apply the demo minimum', async () => {
  const h = harness();
  const input = h.byId('numGlobalInterval');
  const btn = h.byId('btnGlobalIntervalSet');
  input.value = '4';
  await btn.onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-interval-set').length === 0, '4 minutes refused');
  must(input.focused === true, 'invalid interval focuses the input');
  input.focused = false;
  input.value = '1441';
  await btn.onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-interval-set').length === 0, '1441 minutes refused');
  input.focused = false;
  input.value = '5';
  await btn.onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-interval-set').length === 1, '5 minutes applied');
  must(h.model.calls.filter(c => c.ep === '/api/global-interval-set')[0].body.minutes === 5, 'actual 5-minute value sent');
  input.value = '1440';
  await btn.onclick();
  must(h.model.calls.filter(c => c.ep === '/api/global-interval-set').length === 2, '1440 minutes applied');
  must(h.model.calls.filter(c => c.ep === '/api/global-interval-set')[1].body.minutes === 1440, 'actual 1440-minute value sent');
});

// --- GitHub link gate -----------------------------------------------------
await testAsync('GitHub未連携時は対象の選択と保存をロックし、連携後は解除する', async () => {
  const assertLocked = (h, label) => {
    const cs = h.checks();
    must(cs.length === 18, label + ': 18 target checkboxes rendered, got ' + cs.length);
    must(cs.every(c => c.disabled === true), label + ': all checkboxes disabled');
    must(h.byId('btnGlobalTargetsAll').disabled === true, label + ': select-all disabled');
    must(h.byId('btnGlobalTargetsNone').disabled === true, label + ': clear-all disabled');
    must(h.byId('btnGlobalTargets').disabled === true, label + ': save disabled');
    must(h.byId('globalTargetsDirty').textContent === 'GitHubと連携すると対象を選択できます', label + ': GitHub hint replaces the dirty text');
    must(h.byId('globalTargetsDirty').className.indexOf('on') < 0, label + ': hint is not styled as a dirty change');
  };
  const assertClicksIgnored = async (h, label) => {
    h.byId('btnGlobalTargetsAll').onclick();
    h.byId('btnGlobalTargetsNone').onclick();
    await h.byId('btnGlobalTargets').onclick();
    must(h.state().selected.join('|') === 'codexcli|opencode', label + ': locked buttons never change the selection');
    must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 0, label + ': locked save never posts');
  };

  // Fail closed before /api/global-status resolves: no status yet means locked.
  const h0 = harness({ uninitializedStatus: true });
  must(h0.context.currentGlobalStatus == null, 'status starts uninitialized');
  assertLocked(h0, 'pre-status');
  await assertClicksIgnored(h0, 'pre-status');
  // A failed initial status GET must not open the lock either.
  h0.model.statusGetError = new Error('initial status failed');
  await h0.context.refreshGlobal();
  must(h0.context.currentGlobalStatus == null, 'failed status keeps the lock closed');
  assertLocked(h0, 'failed status');
  await assertClicksIgnored(h0, 'failed status');

  const h = harness();
  h.gs.updateGlobalUI({ providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: false });
  const cs = h.checks();
  assertLocked(h, 'github off');
  await assertClicksIgnored(h, 'github off');

  h.gs.updateGlobalUI({ providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: true });
  must(cs.every(c => c.disabled === false), 'checkboxes unlocked once GitHub is configured');
  must(h.byId('btnGlobalTargetsAll').disabled === false, 'select-all unlocked');
  must(h.byId('btnGlobalTargetsNone').disabled === false, 'clear-all unlocked');
  h.byId('btnGlobalTargetsAll').onclick();
  must(h.state().selected.length === 18, 'select-all works again: ' + h.state().selected.length);

  // A status poll can close the GitHub lock while the confirm dialog is open.
  let resolveConfirm;
  h.context.showConfirm = () => new Promise(resolve => { resolveConfirm = resolve; });
  const pendingSave = h.byId('btnGlobalTargets').onclick();
  await new Promise(resolve => setTimeout(resolve, 0));
  h.gs.updateGlobalUI({ providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 15, taskEnabled: true, githubConfigured: false });
  resolveConfirm(true);
  await pendingSave;
  must(h.model.calls.filter(c => c.ep === '/api/global-targets-set').length === 0, 'race: confirming after the lock closes never posts');
  must(h.state().saving === false, 'race: saving released');
  must(h.byId('btnGlobalTargets').disabled === true, 'race: save stays disabled');
});

// --- shared rule editor (#rules) ------------------------------------------
test('rule editor markup reuses the real screen grid and hides without .cols2', () => {
  must(/<div id="rules" hidden>/.test(src), 'rules screen container exists');
  const start = src.indexOf('<div id="rules" hidden>');
  const end = src.indexOf('<div id="backups" hidden>', start);
  must(start >= 0 && end > start, 'rules screen slice missing');
  const html = src.slice(start, end);
  must(/class="rules-grid"/.test(html), 'editor uses the dedicated grid');
  must(!/class="cols2"/.test(html), 'editor does not reuse the projects columns');
  must(/id="rulesGate"/.test(html) && /id="ruleText"/.test(html) && /id="selRuleKind"/.test(html), 'gate, textarea and kind select exist');
  must(/const SCREENS=\["top","projects","global","rules"/.test(src), 'rules is a routed screen');
});

function rulesBlock() {
  const start = src.indexOf('function rulesLockedByGitHub(){');
  const end = src.indexOf('async function pollGlobalUntilDone', start);
  must(start >= 0 && end > start, 'rules UI block missing');
  return src.slice(start, end);
}

function rulesHarness() {
  const elements = new Map();
  function byId(id) {
    if (!elements.has(id)) elements.set(id, makeElement('div'));
    return elements.get(id);
  }
  byId('selRuleKind').value = 'project';
  const model = {
    calls: [], confirm: true, onConfirm: null, loadError: null, saveError: null, getGate: null,
    get: { ok: true, kind: 'project', path: 'rules/project.md', repo: 'Fizor-drm/Shirube', branch: 'main', sha: 'sha-1', text: 'text-1', redacted: false },
    saveR: { ok: true, sha: 'sha-2', path: 'rules/project.md', repo: 'Fizor-drm/Shirube', branch: 'main', kind: 'project' }
  };
  const context = vm.createContext({
    document: { getElementById: byId, querySelectorAll() { return []; }, querySelector() { return null; } },
    console, Promise, Date, setTimeout,
    currentGlobalStatus: null,
    L(key, vars) {
      return String(key).replace(/\{([^{}]+)\}/g, (m, k) =>
        vars && Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : m);
    },
    setMsg(id, msg, okFlag) {
      const d = byId(id);
      d.textContent = msg;
      d.okFlag = !!okFlag;
    },
    showConfirm: async () => { if (model.onConfirm) await model.onConfirm(); return model.confirm; },
    api: async (ep, method, body) => {
      model.calls.push({ ep, method, body });
      if (ep === '/api/github-rule-get') {
        if (model.loadError) throw model.loadError;
        if (model.getGate) await model.getGate;
        return Object.assign({}, model.get);
      }
      if (ep === '/api/github-rule-save') {
        if (model.saveError) throw model.saveError;
        return Object.assign({}, model.saveR);
      }
      return {};
    }
  });
  vm.runInContext(rulesBlock() +
    ';globalThis.__r={rulesLockedByGitHub:rulesLockedByGitHub,renderRulesLock:renderRulesLock,' +
    'ruleLoad:ruleLoad,ruleSave:ruleSave,ruleKind:ruleKind,renderRuleMeta:renderRuleMeta,' +
    'state:function(){return ruleLoaded;},busy:function(){return ruleBusy;}};', context);
  return { context, model, byId, r: context.__r };
}

await testAsync('rule editor stays locked until GitHub is configured', async () => {
  const h = rulesHarness();
  h.r.renderRulesLock();
  must(h.r.rulesLockedByGitHub() === true, 'no status means locked');
  must(h.byId('ruleText').disabled === true, 'textarea disabled while locked');
  must(h.byId('rulesGate').hidden === false, 'gate notice shown');
  must(h.byId('btnRuleLoad').disabled === true && h.byId('btnRuleSave').disabled === true, 'buttons disabled');
  await h.r.ruleLoad();
  must(h.model.calls.length === 0, 'locked load sends no request');

  h.context.currentGlobalStatus = { githubConfigured: true };
  h.r.renderRulesLock();
  must(h.byId('ruleText').disabled === false && h.byId('btnRuleLoad').disabled === false, 'unlocked after configuration');
  must(h.byId('btnRuleSave').disabled === true, 'save waits for a successful load');
});

await testAsync('rule load stores the sha and save posts the edited text with it', async () => {
  const h = rulesHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  await h.r.ruleLoad();
  must(h.model.calls[0].ep === '/api/github-rule-get' && h.model.calls[0].body.kind === 'project', 'loads the selected kind');
  must(h.byId('ruleText').value === 'text-1', 'fetched text rendered');
  must(h.byId('btnRuleSave').disabled === false, 'save enabled after load');
  must(/sha-1/.test(h.byId('ruleMeta').textContent), 'meta shows the loaded sha');
  must(/Fizor-drm\/Shirube@main/.test(h.byId('ruleMeta').textContent), 'meta shows the loaded repo and branch');
  must(h.r.state().repo === 'Fizor-drm/Shirube' && h.r.state().branch === 'main' && h.r.state().path === 'rules/project.md', 'load pins the origin');

  h.byId('ruleText').value = 'edited';
  await h.r.ruleSave();
  const post = h.model.calls[1];
  must(post.ep === '/api/github-rule-save' && post.body.text === 'edited' && post.body.sha === 'sha-1', 'save posts text and read sha');
  must(post.body.repo === 'Fizor-drm/Shirube' && post.body.branch === 'main' && post.body.path === 'rules/project.md', 'save posts the pinned origin');
  must(h.r.state().sha === 'sha-2', 'new sha adopted');
  must(/sha-2/.test(h.byId('ruleMeta').textContent), 'meta refreshed after save');
});

await testAsync('a reload that moves the rule origin during confirmation aborts the save', async () => {
  const h = rulesHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  await h.r.ruleLoad();
  h.model.get = { ok: true, kind: 'project', path: 'other/project.md', repo: 'other/repo', branch: 'dev', sha: 'sha-1', text: 'text-1', redacted: false };
  h.model.onConfirm = async () => { await h.r.ruleLoad(); };
  await h.r.ruleSave();
  must(h.model.calls.filter(c => c.ep === '/api/github-rule-save').length === 0, 'origin change during confirm never saves');
});

await testAsync('changing the kind invalidates the loaded rule before saving', async () => {
  const h = rulesHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  await h.r.ruleLoad();
  h.byId('selRuleKind').value = 'global';
  h.byId('selRuleKind').onchange();
  must(h.r.state() === null, 'kind change clears the loaded state');
  await h.r.ruleSave();
  must(h.model.calls.filter(c => c.ep === '/api/github-rule-save').length === 0, 'stale kind never posts');
});

await testAsync('a status poll that closes GitHub while confirming aborts the save', async () => {
  const h = rulesHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  await h.r.ruleLoad();
  h.model.onConfirm = () => { h.context.currentGlobalStatus = { githubConfigured: false }; };
  await h.r.ruleSave();
  must(h.model.calls.filter(c => c.ep === '/api/github-rule-save').length === 0, 'race: no save after the lock closes');
});

await testAsync('a load in flight blocks another load and the save', async () => {
  const h = rulesHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  let openGate;
  h.model.getGate = new Promise(resolve => { openGate = resolve; });
  const pendingLoad = h.r.ruleLoad();
  await new Promise(resolve => setTimeout(resolve, 0));
  must(h.r.busy() === true, 'load marks the editor busy');
  must(h.byId('btnRuleLoad').disabled === true && h.byId('btnRuleSave').disabled === true, 'busy disables load and save');
  await h.r.ruleLoad();
  await h.r.ruleSave();
  must(h.model.calls.filter(c => c.ep === '/api/github-rule-get').length === 1, 'the second load is ignored');
  must(h.model.calls.filter(c => c.ep === '/api/github-rule-save').length === 0, 'the save is ignored while loading');
  openGate();
  await pendingLoad;
  must(h.r.busy() === false, 'busy released after the load');
  must(h.byId('btnRuleLoad').disabled === false && h.byId('btnRuleSave').disabled === false, 'load and save re-enable');
});

await testAsync('a reload finishing during confirmation aborts the save', async () => {
  const h = rulesHarness();
  h.context.currentGlobalStatus = { githubConfigured: true };
  await h.r.ruleLoad();
  h.byId('ruleText').value = 'edited';
  h.model.get = { ok: true, kind: 'project', path: 'rules/project.md', sha: 'sha-9', text: 'newer', redacted: false };
  let pendingLoad = null;
  h.model.onConfirm = () => { pendingLoad = h.r.ruleLoad(); };
  await h.r.ruleSave();
  await pendingLoad;
  must(h.model.calls.filter(c => c.ep === '/api/github-rule-save').length === 0, 'reload during confirm never saves');
  must(h.r.state().sha === 'sha-9' && h.byId('ruleText').value === 'newer', 'the reloaded content is kept');
  must(h.r.busy() === false, 'busy released after the aborted save');
});

console.log(failures.length ? 'FAILURES: ' + failures.join('; ') : 'ALL GLOBAL SETTINGS DESIGN CHECKS PASSED');
process.exitCode = failures.length ? 1 : 0;
