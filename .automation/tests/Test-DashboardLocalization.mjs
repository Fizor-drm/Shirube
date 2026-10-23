// Dashboard language selector: ja (default), en, zh-CN. Runs the real i18n code
// against a small DOM/localStorage stub. No server start, no real browser data.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(new URL('../Dashboard-Server.ps1', import.meta.url), 'utf8');

function test(name, fn) { fn(); console.log('PASS: ' + name); }

// --- served page contract -------------------------------------------------
test('topbar carries a native language select with the three editions', () => {
  const topbar = /<div class="topbar">([\s\S]*?)<nav class="topnav"/.exec(src);
  assert.ok(topbar, 'topbar exists');
  const html = topbar[1];
  assert.match(html, /<select id="selLang" class="lang" aria-label="表示言語"/);
  assert.match(html, /<option value="ja">日本語<\/option>/);
  assert.match(html, /<option value="en">English<\/option>/);
  assert.match(html, /<option value="zh-CN">简体中文<\/option>/);
  assert.match(src, /<html lang="ja">/);
  assert.match(html, /data-i18n-aria="表示言語"/);
  assert.match(src, /shirube\.lang/);
});

// --- i18n harness ---------------------------------------------------------
const start = src.indexOf('const LANG_KEY');
const end = src.indexOf('\nfunction esc(s)', start);
assert.ok(start >= 0 && end > start, 'i18n block exists');

function makeElement(attrs) {
  return {
    attrs: Object.assign({}, attrs || {}),
    textContent: '',
    value: '',
    hidden: false,
    onchange: null,
    setAttribute(k, v) { this.attrs[k] = v; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; }
  };
}

function harness(storeValue, storageMode) {
  const dynamic = {};
  function textNode(value) { return { nodeType: 3, nodeValue: value }; }
  function elementNode(tag, children) {
    return { nodeType: 1, tagName: tag.toUpperCase(), childNodes: children || [], value: '', checked: false };
  }
  dynamic.prevArea = elementNode('div', []);
  dynamic.localArea = elementNode('div', []);
  dynamic.backupRows = elementNode('tbody', []);
  dynamic.globalBackupRows = elementNode('tbody', []);
  const els = {
    nav: makeElement({ 'data-i18n': '概要' }),
    placeholder: makeElement({ 'data-i18n-placeholder': '検索で絞り込み（名前・パス）' }),
    title: makeElement({ 'data-i18n-title': '同期進捗' }),
    aria: makeElement({ 'data-i18n-aria': '画面切替' }),
    summary: makeElement({ 'aria-label': 'summary' }),
    selLang: makeElement()
  };
  const grouped = {
    '[data-i18n]': [els.nav],
    '[data-i18n-placeholder]': [els.placeholder],
    '[data-i18n-title]': [els.title],
    '[data-i18n-aria]': [els.aria]
  };
  const writes = [];
  const storage = {
    getItem() {
      if (storageMode === 'throw') throw new Error('blocked');
      return storeValue === undefined ? null : storeValue;
    },
    setItem(k, v) { if (storageMode === 'throw') throw new Error('blocked'); writes.push([k, v]); }
  };
  const window = {};
  if (storageMode !== 'missing') window.localStorage = storage;
  const document = {
    title: '',
    documentElement: { lang: '' },
    getElementById(id) { return id === 'selLang' ? els.selLang : (dynamic[id] || null); },
    querySelector(sel) { return sel === '.summarybar section' ? els.summary : null; },
    querySelectorAll(sel) { return grouped[sel] || []; }
  };
  const context = {
    document, window, console,
    refresh() {}, refreshGlobal() {}, loadBackups() {}, loadGlobalBackups() {},
    __textNode: textNode, __elementNode: elementNode
  };
  vm.createContext(context);
  vm.runInContext(src.slice(start, end) +
    '\n;globalThis.__i18n={I18N:I18N,L:L,safeLang:safeLang,storedLang:storedLang,saveLang:saveLang,' +
    'applyLanguage:applyLanguage,initLanguage:initLanguage,currentLang:function(){return currentLang;}};', context);
  return { i18n: context.__i18n, document, els, dynamic, writes, window, context, textNode, elementNode };
}

test('stored language: valid value, missing, invalid and unavailable storage fall back to Japanese', () => {
  assert.equal(harness('en').i18n.storedLang(), 'en');
  assert.equal(harness('zh-CN').i18n.storedLang(), 'zh-CN');
  assert.equal(harness(undefined).i18n.storedLang(), 'ja');
  assert.equal(harness('fr').i18n.storedLang(), 'ja');
  assert.equal(harness('en', 'throw').i18n.storedLang(), 'ja');
  assert.equal(harness('en', 'missing').i18n.storedLang(), 'ja');
});

test('saving uses localStorage and never throws when storage is unavailable', () => {
  for (const value of ['en', 'zh-CN', 'ja']) {
    const h = harness(undefined);
    h.i18n.saveLang(value);
    assert.deepEqual(h.writes, [['shirube.lang', value]]);
  }
  const missing = harness(undefined, 'missing');
  missing.i18n.saveLang('en');
  const throwing = harness(undefined, 'throw');
  throwing.i18n.saveLang('en');
  assert.deepEqual(missing.writes, []);
  assert.deepEqual(throwing.writes, []);
});

test('applyLanguage updates html lang, title, text, placeholder, title and aria label', () => {
  const h = harness(undefined);
  h.i18n.applyLanguage('en', false);
  assert.equal(h.document.documentElement.lang, 'en');
  assert.equal(h.document.title, 'Shirube Dashboard');
  assert.equal(h.els.nav.textContent, 'Overview');
  assert.equal(h.els.placeholder.getAttribute('placeholder'), 'Filter by name or path');
  assert.equal(h.els.title.getAttribute('title'), 'Sync progress');
  assert.equal(h.els.aria.getAttribute('aria-label'), 'Screen navigation');
  assert.equal(h.els.summary.getAttribute('aria-label'), 'Overview');

  h.i18n.applyLanguage('zh-CN', false);
  assert.equal(h.document.documentElement.lang, 'zh-CN');
  assert.equal(h.document.title, 'Shirube 管理仪表板');
  assert.equal(h.els.nav.textContent, '概览');
  assert.equal(h.els.placeholder.getAttribute('placeholder'), '按名称或路径筛选');
  assert.equal(h.els.title.getAttribute('title'), '同步进度');
  assert.equal(h.els.aria.getAttribute('aria-label'), '页面切换');
  assert.equal(h.els.summary.getAttribute('aria-label'), '概览');
});

test('interpolation never reprocesses placeholders inside inserted source text', () => {
  const h = harness(undefined);
  const text = h.i18n.L('【矛盾候補】{project}：共通「{common}」/固有「{local}」', {
    project: 'Project A', common: 'literal {local} from source', local: 'local rule'
  });
  assert.equal(text, '【矛盾候補】Project A：共通「literal {local} from source」/固有「local rule」');
});

test('language changes re-render generated operation labels and preserve user input and confirmation state', () => {
  const h = harness(undefined);
  const preview = h.i18n.L('プレビュー OK: 「{name}」として登録できます。', { name: '案件 {local}' });
  h.dynamic.prevArea.childNodes = [h.elementNode('p', [h.textNode(preview.replace(/&amp;/g, '&'))])];
  const localText = h.elementNode('textarea');
  localText.value = 'user rules {local}';
  const confirmation = h.elementNode('input');
  confirmation.type = 'checkbox';
  confirmation.checked = true;
  const saveButton = h.elementNode('button', [h.textNode(h.i18n.L('検証して保存'))]);
  h.dynamic.localArea.childNodes = [localText, confirmation, saveButton];

  h.i18n.applyLanguage('en', false);

  assert.equal(h.dynamic.prevArea.childNodes[0].childNodes[0].nodeValue,
    'Preview OK: can be registered as "案件 {local}".');
  assert.equal(saveButton.childNodes[0].nodeValue, 'Validate and save');
  assert.equal(localText.value, 'user rules {local}');
  assert.equal(confirmation.checked, true);
});

test('generated text with HTML-escaped values and significant spaces follows the locale', () => {
  const h = harness(undefined);
  const preview = h.i18n.L('プレビュー OK: 「{name}」として登録できます。', { name: 'A &amp; B' });
  h.dynamic.prevArea.childNodes = [h.elementNode('p', [h.textNode(preview.replace(/&amp;/g, '&'))])];
  h.dynamic.localArea.childNodes = [h.textNode(h.i18n.L('パス: '))];

  h.i18n.applyLanguage('en', false);

  assert.equal(h.dynamic.prevArea.childNodes[0].childNodes[0].nodeValue,
    'Preview OK: can be registered as "A & B".');
  assert.equal(h.dynamic.localArea.childNodes[0].nodeValue, 'Path: ');
});

test('hidden backup rows and combined import completion text follow the locale', () => {
  const h = harness(undefined);
  h.dynamic.backupRows.childNodes = [h.elementNode('button', [h.textNode(h.i18n.L('差分'))])];
  h.dynamic.globalBackupRows.childNodes = [h.elementNode('button', [h.textNode(h.i18n.L('復元'))])];
  const combined = h.i18n.L('取り込みました。追加：{n}件。同期間隔を{interval}分に変更しました。', { n: 2, interval: 15 });
  h.dynamic.importArea = h.elementNode('div', [h.textNode(combined)]);

  h.i18n.applyLanguage('en', false);

  assert.equal(h.dynamic.backupRows.childNodes[0].childNodes[0].nodeValue, 'Diff');
  assert.equal(h.dynamic.globalBackupRows.childNodes[0].childNodes[0].nodeValue, 'Restore');
  assert.equal(h.dynamic.importArea.childNodes[0].nodeValue,
    'Imported 2 entries. The Project sync interval is now 15 minutes.');
});

test('static localization does not overwrite runtime status or fetched source content', () => {
  const h = harness(undefined);
  assert.match(src, /id="stRun">読込中<\/p>/);
  assert.match(src, /id="syncProgressText" aria-live="polite">0\/2 待機中<\/span>/);
  assert.match(src, /<pre id="globalContentPre">まだ表示していません。/);
  const status = makeElement();
  const progress = makeElement();
  const content = makeElement();
  h.dynamic.stRun = status;
  h.dynamic.syncProgressText = progress;
  h.dynamic.globalContentPre = content;
  status.textContent = '成功';
  progress.textContent = '2/2 Project同期: 成功';
  content.textContent = '配置元: C:\\Rules\n--- Codex (C:\\rules\\AGENTS.md) ---\nraw source';
  h.i18n.applyLanguage('en', false);
  assert.equal(status.textContent, '成功');
  assert.equal(progress.textContent, '2/2 Project同期: 成功');
  assert.equal(content.textContent, '配置元: C:\\Rules\n--- Codex (C:\\rules\\AGENTS.md) ---\nraw source');
});

test('hidden backup content and numeric import intervals follow language changes', () => {
  const h = harness(undefined);
  const content = h.elementNode('td', []);
  content.dataset = { hasAgentsFile: 'true', hasLocalFile: 'true' };
  content.textContent = 'AGENTSあり / localあり';
  const row = h.elementNode('tr', [h.elementNode('td'), h.elementNode('td'), h.elementNode('td'), content]);
  h.dynamic.backupRows.childNodes = [row];
  h.dynamic.backupRows.children = [row]; row.children = row.childNodes;
  const key = '同期間隔: {current}分 → {next}分に変更します（Projectのみ、Global不変）。';
  h.dynamic.importRegArea = h.elementNode('div', [h.textNode(h.i18n.L(key, {current:15,next:30}))]);
  h.i18n.applyLanguage('en', false);
  assert.equal(content.textContent, h.i18n.L('AGENTSあり') + ' / ' + h.i18n.L('localあり'));
  assert.match(h.dynamic.importRegArea.childNodes[0].nodeValue, /15 minutes.*30 minutes/);
  h.i18n.applyLanguage('zh-CN', false);
  assert.match(h.dynamic.importRegArea.childNodes[0].nodeValue, /15 分钟.*30 分钟/);
});

test('truncated diff notes follow language changes without translating diff source', () => {
  assert.equal((src.match(/n\.className="diff-note"; n\.setAttribute\("data-i18n", "\(省略\)"\)/g) || []).length, 2);
  const h = harness(undefined);
  const note = makeElement({'data-i18n':'(省略)'});
  const raw = h.textNode('raw (省略) {local}');
  h.dynamic.prevArea.childNodes = [h.elementNode('pre', [raw, note])];
  const query = h.document.querySelectorAll;
  h.document.querySelectorAll = selector => query(selector).concat(selector === '[data-i18n]' ? [note] : []);
  h.i18n.applyLanguage('en', false);
  assert.equal(note.textContent, '(truncated)');
  h.i18n.applyLanguage('zh-CN', false);
  assert.equal(note.textContent, '（省略）');
  assert.equal(raw.nodeValue, 'raw (省略) {local}');
});

test('invalid language falls back to Japanese; Japanese is the default', () => {
  const h = harness(undefined);
  h.i18n.initLanguage();
  assert.equal(h.i18n.currentLang(), 'ja');
  assert.equal(h.document.documentElement.lang, 'ja');
  assert.equal(h.els.selLang.value, 'ja');
  assert.equal(h.els.nav.textContent, '概要');
  h.i18n.applyLanguage('fr', false);
  assert.equal(h.i18n.currentLang(), 'ja');
  assert.equal(h.document.documentElement.lang, 'ja');
  assert.equal(h.els.nav.textContent, '概要');
});

test('stored English is restored and selector changes persist', () => {
  const h = harness('en');
  h.i18n.initLanguage();
  assert.equal(h.i18n.currentLang(), 'en');
  assert.equal(h.els.selLang.value, 'en');
  assert.equal(h.els.nav.textContent, 'Overview');
  h.els.selLang.value = 'zh-CN';
  h.els.selLang.onchange();
  assert.equal(h.i18n.currentLang(), 'zh-CN');
  assert.deepEqual(h.writes, [['shirube.lang', 'zh-CN']]);
  h.els.selLang.value = 'ja';
  h.els.selLang.onchange();
  assert.equal(h.i18n.currentLang(), 'ja');
});

test('selector still switches the current page when storage is unavailable', () => {
  const h = harness(undefined, 'missing');
  h.i18n.initLanguage();
  h.els.selLang.value = 'en';
  h.els.selLang.onchange();
  assert.equal(h.i18n.currentLang(), 'en');
  assert.equal(h.document.documentElement.lang, 'en');
  assert.equal(h.els.nav.textContent, 'Overview');
  assert.deepEqual(h.writes, []);
});

test('every used string key exists in English and Simplified Chinese', () => {
  const h = harness(undefined);
  const keys = new Set();
  for (const m of src.matchAll(/L\("((?:[^"\\]|\\.)*)"/g)) keys.add(m[1]);
  for (const m of src.matchAll(/data-i18n(?:-placeholder|-title|-aria)?="([^"]+)"/g)) keys.add(m[1]);
  assert.ok(keys.has('共通ルール編集'), 'plain data-i18n attributes are collected');
  assert.ok(keys.size > 100, 'expected a broad string inventory, got ' + keys.size);
  for (const key of keys) {
    assert.ok(Object.prototype.hasOwnProperty.call(h.i18n.I18N.en, key), 'English missing: ' + key);
    assert.ok(Object.prototype.hasOwnProperty.call(h.i18n.I18N['zh-CN'], key), 'Chinese missing: ' + key);
  }
});

test('rule editor strings exist and interpolate in every edition', () => {
  const h = harness(undefined);
  const keys = ['GitHub連携が未設定のため編集できません。', '取得しました。', '保存しました。',
    '保存の確認', '取得元: {path}（SHA {sha}）', 'ルール種別', 'ルール本文',
    'ルール', '共通ルール編集', '内容が更新されました。取得し直してから保存してください。'];
  for (const key of keys) {
    assert.ok(Object.prototype.hasOwnProperty.call(h.i18n.I18N.en, key), 'English missing: ' + key);
    assert.ok(Object.prototype.hasOwnProperty.call(h.i18n.I18N['zh-CN'], key), 'Chinese missing: ' + key);
  }
  h.i18n.applyLanguage('en', false);
  assert.equal(h.i18n.L('取得元: {path}（SHA {sha}）', { path: 'rules/global.md', sha: 'abc123' }),
    'Source: rules/global.md (SHA abc123)');
  assert.equal(h.i18n.L('取得しました。'), 'Loaded.');
  assert.equal(h.i18n.L('共通ルール編集'), 'Edit common rules');
  h.i18n.applyLanguage('zh-CN', false);
  assert.equal(h.i18n.L('取得しました。'), '已获取。');
  assert.equal(h.i18n.L('共通ルール編集'), '编辑共用规则');
});

// --- real rendering functions keep user data verbatim ---------------------
const names = ['stateJa', 'resultJa', 'globalResultJa', 'renderStatusTable', 'renderGlobalTable',
  'globalProviderEntry', 'globalProviderLabel',
  'updateSyncUI', 'updateCommonSyncState', 'renderSyncState', 'renderUnifiedProgress', 'setUnifiedProgress', 'renderGlobalContent', 'renderProjectLog', 'renderBackupDiff', 'renderGlobalBackupDiff'];
function block(pos) {
  let level = 0, i = src.indexOf('{', pos);
  for (; i < src.length; i++) {
    if (src[i] === '{') level++;
    else if (src[i] === '}' && --level === 0) break;
  }
  return src.slice(pos, i + 1);
}
function fn(name) {
  const m = new RegExp('function ' + name + '\\(').exec(src);
  assert.ok(m, name + ' exists');
  return block(m.index);
}
function renderHarness() {
  const elements = new Map();
  function element() {
    return { textContent: '', title: '', innerHTML: '', value: '', checked: false,
      className: '', style: {}, dataset: {}, children: [],
      appendChild(c) { this.children.push(c); }, setAttribute() {}, removeAttribute() {} };
  }
  const document = {
    getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); },
    createElement: element
  };
  const context = {
    document, console, Promise, Date,
    GLOBAL_CATALOG: [{id:'codexcli',label:'Codex'},{id:'opencode',label:'OpenCode'},{id:'pi',label:'Pi'}],
    commonSyncStates: { project: null, global: null }, commonSyncSource: 'project',
    unifiedStateLock: false, unifiedFinalState: null, unifiedProjectRunId: null,
    unifiedGlobalRunId: null, unifiedBaselineProjectRunId: null, unifiedBaselineGlobalRunId: null,
    unifiedObservedProjectRunId: null, unifiedObservedGlobalRunId: null,
    unifiedProgressState: {completed:0,total:2,text:'0/2 待機中',key:'0/2 待機中',vars:null,indeterminate:false,lang:'ja'},
    unifiedSyncActive: false, lastProjectCount: 2, syncDisplayState: null, globalContentState: null,
    projectLogState: {loaded:false,tail:'',error:null},
    setUnifiedProgress() {}, safeFocus() {}, esc(s) { return String(s == null ? '' : s); }
  };
  vm.createContext(context);
  vm.runInContext(src.slice(start, end) + '\n' + names.map(fn).join('\n') +
    '\n;globalThis.__ui={stateJa:stateJa,resultJa:resultJa,globalResultJa:globalResultJa,' +
    'renderStatusTable:renderStatusTable,renderGlobalTable:renderGlobalTable,' +
    'updateSyncUI:updateSyncUI,renderSyncState:renderSyncState,renderUnifiedProgress:renderUnifiedProgress,' +
    'setUnifiedProgress:setUnifiedProgress,renderGlobalContent:renderGlobalContent,renderBackupDiff:renderBackupDiff,' +
    'renderGlobalBackupDiff:renderGlobalBackupDiff,L:L,' +
    'setLang:function(v){currentLang=safeLang(v);},setFinalState:function(v){unifiedFinalState=v;},' +
    'setDisplayState:function(v){syncDisplayState=v;},' +
    'setGlobalContent:function(v){globalContentState=v;}};', context);
  return { ui: context.__ui, elements };
}

test('status labels follow the locale', () => {
  const h = renderHarness();
  assert.equal(h.ui.stateJa('success'), '成功');
  assert.equal(h.ui.resultJa('skipped'), '見送り');
  h.ui.setLang('en');
  assert.equal(h.ui.stateJa('success'), 'Success');
  assert.equal(h.ui.stateJa('waiting'), 'Waiting to start');
  assert.equal(h.ui.resultJa('skipped'), 'Skipped');
  h.ui.setLang('zh-CN');
  assert.equal(h.ui.stateJa('failed'), '失败');
  assert.equal(h.ui.globalResultJa('success'), '成功');
});

test('language change redraws retained final sync and progress state', () => {
  const h = renderHarness();
  h.ui.setDisplayState({source:'project',status:'success',logName:'run.log',logMtime:'',finalLine:'原文結果',tail:''});
  h.ui.setUnifiedProgress(1, 2, h.ui.L('1/2 Project同期: {state}', { state: h.ui.stateJa('success') }), false);
  h.ui.setFinalState('success');
  h.ui.setLang('en');
  h.ui.renderSyncState();
  assert.equal(h.elements.get('stRun').textContent, 'Success');
  assert.equal(h.elements.get('stRun').dataset.state, 'success');
  assert.equal(h.elements.get('syncProgressText').textContent, '1/2 Project sync: Success');
  assert.equal(h.elements.get('syncProgress').value, 1);
  assert.equal(h.elements.get('stTail').textContent, 'Project: Success 原文結果');
});

test('fetched Global content is re-framed in the selected language without changing source text', () => {
  const h = renderHarness();
  h.ui.setGlobalContent({homeBase:'C:\\Rules', files:[{target:'Codex',path:'C:\\Rules\\AGENTS.md',exists:true,head:'raw {local} source'}]});
  h.ui.renderGlobalContent();
  h.ui.setLang('en');
  h.ui.renderGlobalContent();
  const text = h.elements.get('globalContentPre').textContent;
  assert.match(text, /^Source location: C:\\Rules/);
  assert.match(text, /raw \{local\} source/);
  assert.match(text, /C:\\Rules\\AGENTS\.md/);
});

test('project and Global diff results re-render their localized framing from retained diff data', () => {
  const h = renderHarness();
  const area = () => ({
    textContent:'',title:'',innerHTML:'',value:'',checked:false,className:'',style:{},dataset:{},children:[],
    appendChild(c){this.children.push(c);},setAttribute(){},removeAttribute(){}
  });
  const projectDiff = {name:'Backup A',same:true,truncated:false,backupHasAgents:true,currentHasAgents:true,lines:[],backupHasLocal:true,currentHasLocal:true,localLines:[]};
  h.elements.set('backupDiffArea', area());
  h.ui.renderBackupDiff(h.elements.get('backupDiffArea'), projectDiff);
  h.ui.setLang('en');
  h.elements.set('backupDiffArea', area());
  h.ui.renderBackupDiff(h.elements.get('backupDiffArea'), projectDiff);
  assert.equal(h.elements.get('backupDiffArea').children[0].textContent, 'Target: Backup A (no changes)');
  assert.equal(h.elements.get('backupDiffArea').children[1].textContent, 'AGENTS.md: No changes');

  const globalDiff = {id:'G-1',same:false,truncated:false,lines:[]};
  h.ui.setLang('ja');
  h.elements.set('globalBackupDiffArea', area());
  h.ui.renderGlobalBackupDiff(globalDiff);
  h.ui.setLang('en');
  h.elements.set('globalBackupDiffArea', area());
  h.ui.renderGlobalBackupDiff(globalDiff);
  assert.equal(h.elements.get('globalBackupDiffArea').children[0].textContent, 'Target: G-1 (changes found)');
});

test('project rows translate framing but keep names, paths and errors verbatim', () => {
  const h = renderHarness();
  h.ui.setLang('en');
  h.ui.renderStatusTable([{
    name: '案件A', displayName: '案件A', enabled: false,
    lastAttemptAt: '2026-01-02 03:04:05', lastSuccessAt: '',
    commonCommit: 'abcdef1234567890', result: 'failed',
    error: '生のエラー <b> & そのまま'
  }]);
  const row = h.elements.get('statusRows').children[0];
  const cells = row.children;
  assert.equal(cells[1].textContent, '案件A');
  assert.equal(cells[2].textContent, 'Disabled');
  assert.equal(cells[6].textContent, 'Failed');
  assert.equal(cells[7].textContent, '生のエラー <b> & そのまま');
});

test('global rows keep source paths and errors verbatim', () => {
  const h = renderHarness();
  h.ui.setLang('zh-CN');
  h.ui.renderGlobalTable([{
    target: 'codexcli', path: 'C:\\日本語\\<repo>\\AGENTS.md',
    lastAttemptAt: '', lastSuccessAt: '', sourceCommit: 'abcdef1234567890',
    result: 'failed', error: '生のエラー <b>'
  }]);
  const cells = h.elements.get('globalRows').children[0].children;
  assert.equal(cells[0].textContent, 'Codex');
  assert.equal(cells[1].children[0].textContent, 'C:\\日本語\\<repo>\\AGENTS.md');
  assert.equal(cells[5].textContent, '失败');
  assert.equal(cells[6].textContent, '生のエラー <b>');
});

test('log bodies stay verbatim while their framing is translated', () => {
  const h = renderHarness();
  h.ui.setLang('en');
  h.ui.updateSyncUI({ count: 2, tail: '2026-01-02 OK: 生ログ <x>', syncState: 'success', syncId: 'P1', logName: 'run.log' });
  assert.equal(h.elements.get('logPre').textContent, '2026-01-02 OK: 生ログ <x>');
  assert.equal(h.elements.get('stCount').textContent, '2 items');
  assert.equal(h.elements.get('stRun').textContent, 'Success');
});

test('source reads/fetched heads are never passed through the translator', () => {
  assert.match(src, /h \+= \(f\.head \|\| ""\) \+ "\\n";/);
  assert.match(src, /globalLogState = \{loaded:true, tail:g\.tail \|\| "", error:null\};/);
  assert.match(src, /projectLogState = \{loaded:true, tail:s\.tail \|\| "", error:null\};/);
});

console.log('ALL DASHBOARD LOCALIZATION CHECKS PASSED');
