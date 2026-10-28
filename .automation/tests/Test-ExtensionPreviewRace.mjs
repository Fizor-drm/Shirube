import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../Dashboard-Server.ps1', import.meta.url), 'utf8');
const section = source.slice(source.indexOf('function exClearPreview(){'), source.indexOf('function exRenderPreview(r){'));
assert.ok(section.startsWith('function exClearPreview(){'));
assert.match(source, /textarea\.ex-secret\{-webkit-text-security:disc\}/);
assert.match(section, /id="exMcpEnv"[^>]*class="ex-secret"[^>]*hidden/);
assert.match(section, /id="exMcpHeaders"[^>]*class="ex-secret"[^>]*hidden/);
assert.match(section, /CSS\.supports\(/);
assert.match(source, /\[hidden\]\{display:none!important\}/);
assert.match(section, /id="exRevealSecrets"[^>]*aria-controls="exMcpEnv exMcpHeaders"/);

let resolveRequest;
const area = { innerHTML: '' };
const context = {
  document: { getElementById: id => id === 'exPreviewArea' ? area : null },
  extState: { preview: null, previewSeq: 0, form: '' },
  exFormProviders: () => ['codex'], exReadValue: () => '',
  extClearMsg: () => {}, extSetMsg: () => {}, L: value => value,
  api: () => new Promise(resolve => { resolveRequest = resolve; }),
  showConfirm: async () => true,
  exRenderPreview: result => { area.innerHTML = result.previewId; },
};
vm.createContext(context);
vm.runInContext(section, context);
async function checkMasking(supported) {
  const elements = {};
  for (const id of ['exMcpEnv', 'exMcpHeaders']) {
    elements[id] = { hidden: true, masked: true, classList: { toggle: (name, value) => { elements[id].masked = value; } } };
  }
  elements.exRevealSecrets = { checked: false };
  elements.exAddArea = { innerHTML: '' };
  elements.exMcpForm = { addEventListener() {} };
  context.document.getElementById = id => id === 'exPreviewArea' ? area : elements[id] || null;
  context.CSS = { supports: () => supported };
  context.EXT_PROVIDERS = [];
  context.exOpenMcpForm();
  for (const id of ['exMcpEnv', 'exMcpHeaders']) {
    assert.equal(elements[id].hidden, !supported, id + ' fails closed without masking support');
    assert.equal(elements[id].masked, true, id + ' starts masked');
  }
  elements.exRevealSecrets.checked = true;
  elements.exRevealSecrets.onchange();
  for (const id of ['exMcpEnv', 'exMcpHeaders']) {
    assert.equal(elements[id].hidden, false, id + ' opens only after explicit reveal');
    assert.equal(elements[id].masked, false, id + ' reveals only on request');
  }
  elements.exRevealSecrets.checked = false;
  elements.exRevealSecrets.onchange();
  for (const id of ['exMcpEnv', 'exMcpHeaders']) {
    assert.equal(elements[id].hidden, !supported, id + ' returns to its protected state');
    assert.equal(elements[id].masked, true, id + ' is masked again');
  }
}
await checkMasking(true);
await checkMasking(false);
context.document.getElementById = id => id === 'exPreviewArea' ? area : null;
for (const operation of ['exPreviewMcpAdd', 'exPreviewSkillAdd', 'exAskToggle']) {
  const pending = operation === 'exAskToggle'
    ? context[operation]('sample', 'codex', true)
    : context[operation]({ disabled: false });
  await Promise.resolve();
  context.exClearPreview();
  resolveRequest({ previewId: 'stale' });
  await pending;
  assert.equal(context.extState.preview, null, operation + ' must discard a stale response');
  assert.equal(area.innerHTML, '', operation + ' must not render a stale response');
}
const active = context.exPreviewSkillAdd({ disabled: false });
resolveRequest({ previewId: 'current' });
await active;
assert.equal(context.extState.preview.previewId, 'current');
assert.equal(area.innerHTML, 'current');

const applySection = source.slice(source.indexOf('async function exApplyPreview('), source.indexOf('async function exRestoreBackup('));
vm.runInContext(applySection, context);
let confirmApply;
let applied = false;
context.document.getElementById = id => id === 'ckExConfirm' ? { checked: true } : id === 'exPreviewArea' ? area : null;
context.showConfirm = () => new Promise(resolve => { confirmApply = resolve; });
context.api = async () => { applied = true; return {}; };
const pendingApply = context.exApplyPreview(context.extState.preview, { disabled: false }, false);
context.exClearPreview();
confirmApply(true);
await pendingApply;
assert.equal(applied, false, 'an invalidated preview cannot be applied after confirmation');
console.log('ALL EXTENSION PREVIEW RACE CHECKS PASSED');
