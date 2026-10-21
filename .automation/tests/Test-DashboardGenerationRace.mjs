// Node harness for dashboard preview/register generation races.
// Extracts the ACTUAL doPreview from .automation/Dashboard-Server.ps1
// (no reimplementation) and runs it against a minimal DOM stub.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const failures = [];
function check(cond, name) {
  if (cond) console.log('PASS: ' + name);
  else { console.log('FAIL: ' + name); failures.push(name); }
}

function makeDeferred() {
  let resolve, reject;
  const p = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { p, resolve, reject };
}

const serverPath = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'Dashboard-Server.ps1');
const src = fs.readFileSync(serverPath, 'utf8');
const start = src.indexOf('async function doPreview(pathVal){');
if (start < 0) { console.error('doPreview not found'); process.exit(1); }
let i = src.indexOf('{', start);
let depth = 0;
for (; i < src.length; i++) {
  if (src[i] === '{') depth++;
  else if (src[i] === '}') { depth--; if (depth === 0) { break; } }
}
const fnText = src.slice(start, i + 1);

const prevArea = { innerHTML: '' };
const btnReg = { disabled: false, onclick: null };
const ck1 = { checked: true };
const ckForce = { checked: false };
const inpPath = { value: '' };

const document = {
  getElementById(id) {
    if (id === 'prevArea') return prevArea;
    if (id === 'inpPath') return inpPath;
    if (id === 'ckForceReplace') return ckForce;
    if (id === 'btnReg') return btnReg;
    if (id === 'ck1') return ck1;
    return { innerHTML: '', hidden: false, disabled: false, onclick: null,
      classList: { add(){}, remove(){} }, setAttribute(){}, removeAttribute(){},
      appendChild(){}, textContent: '' };
  }
};

const context = {
  console, setTimeout, clearTimeout, Promise, document,
  api: async () => ({}),
  esc: (s) => String(s == null ? '' : s),
  showConfirm: async () => true,
  showModal: () => {},
  setMsgHtml: () => {},
  setMsg: (id,msg,ok) => { context._lastMsg = msg; },
  refresh: async () => {},
  pollUntilDone: async () => 'success',
  safeFocus: () => {},
};
context._lastMsg = '';
// state vars as globals (var => context property)
const wrapper = `
var previewGen = 0;
var lastPreview = null;
var lastPreviewGen = 0;
${fnText}
`;
vm.runInNewContext(wrapper, context, { filename: 'Dashboard-Server.doPreview.js' });

async function run() {
  function reset() {
    context.previewGen = 0;
    context.lastPreview = null;
    context.lastPreviewGen = 0;
    btnReg.onclick = null;
    btnReg.disabled = false;
    ck1.checked = true;
    prevArea.innerHTML = '';
    ckForce.checked = false;
    context._lastMsg = '';
  }

  // Case 1: input changed after old register -> no POST.
  {
    reset();
    let posted = false;
    context.api = async (p, m, b) => {
      if (p === '/api/preview') return { name: 'OLD', path: '/old', previewId: 'old', hasAgents: false, hasLocal: false, localHash: '' };
      posted = true;
      return { sync: 'started' };
    };
    await context.doPreview('/old');
    context.previewGen++;
    context.lastPreview = null;
    context.lastPreviewGen = 0;
    const res = await btnReg.onclick();
    check(!posted, 'input changed after old register: no POST');
    check(String(context._lastMsg).includes('プレビューが無効'), 'input changed after old register: rejected');
  }

  // Case 2: input changed during modal await -> no POST.
  {
    reset();
    let posted = false;
    context.api = async (p, m, b) => {
      if (p === '/api/preview') return { name: 'MODAL', path: '/modal', previewId: 'modal', hasAgents: false, hasLocal: false, localHash: '' };
      posted = true;
      return { sync: 'started' };
    };
    const d = makeDeferred();
    context.showConfirm = () => d.p;
    await context.doPreview('/modal');
    const clickPromise = btnReg.onclick();
    context.previewGen++;
    context.lastPreview = null;
    context.lastPreviewGen = 0;
    d.resolve(true);
    const res = await clickPromise;
    check(!posted, 'input changed during modal await: no POST');
    check(String(context._lastMsg).includes('プレビューが無効'), 'input changed during modal await: rejected');
  }

  // Case 3: old preview delayed success preserves new preview.
  {
    reset();
    const oldD = makeDeferred();
    const newD = makeDeferred();
    context.api = async (p, m, b) => {
      if (p !== '/api/preview') return {};
      if (b && b.path === '/old') { await oldD.p; return { name: 'OLD', path: '/old', previewId: 'old', hasAgents: false, hasLocal: false, localHash: '' }; }
      await newD.p; return { name: 'NEW', path: '/new', previewId: 'new', hasAgents: false, hasLocal: false, localHash: '' };
    };
    const oldPromise = context.doPreview('/old');
    const newPromise = context.doPreview('/new');
    newD.resolve();
    await newPromise;
    oldD.resolve();
    await oldPromise;
    check(!!context.lastPreview && context.lastPreview.name === 'NEW', 'old delayed success preserves new preview');
  }

  // Case 4: old preview delayed failure preserves new preview.
  {
    reset();
    const oldD = makeDeferred();
    const newD = makeDeferred();
    context.api = async (p, m, b) => {
      if (p !== '/api/preview') return {};
      if (b && b.path === '/old') { await oldD.p; throw new Error('old fail'); }
      await newD.p; return { name: 'NEW', path: '/new', previewId: 'new', hasAgents: false, hasLocal: false, localHash: '' };
    };
    const oldPromise = context.doPreview('/old');
    const newPromise = context.doPreview('/new');
    newD.resolve();
    await newPromise;
    oldD.resolve();
    await oldPromise;
    check(!!context.lastPreview && context.lastPreview.name === 'NEW', 'old delayed failure preserves new preview');
  }

  if (failures.length) {
    console.error('FAILURES: ' + failures.join(', '));
    process.exit(1);
  }
  console.log('ALL DASHBOARD GENERATION RACE CHECKS PASSED');
}

run().catch((e) => { console.error(e); process.exit(1); });
