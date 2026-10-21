import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(new URL('../Dashboard-Server.ps1', import.meta.url), 'utf8');
function block(start) {
  assert.ok(start >= 0, 'actual source marker exists');
  let level = 0, end = src.indexOf('{', start);
  for (; end < src.length; end++) {
    if (src[end] === '{') level++;
    if (src[end] === '}' && --level === 0) break;
  }
  return src.slice(start, end + 1);
}
function actual(name) {
  const match = new RegExp('(async )?function ' + name + '\\(').exec(src);
  assert.ok(match, name + ' exists in production');
  return block(match.index);
}
function handler(id) {
  const marker = 'document.getElementById("' + id + '").onclick = ';
  const start = src.indexOf(marker) + marker.length;
  return block(start);
}
const names = ['stateJa', 'resultJa', 'updateSyncUI', 'updateCommonSyncState',
  'updateGlobalUI', 'renderGlobalTable', 'renderStatusTable', 'applySearchFilter',
  'refresh', 'refreshGlobal', 'pollUntilDone', 'pollGlobalUntilDone',
  'afterSyncNotify', 'afterGlobalSyncNotify', 'setUnifiedProgress',
  'globalSelectedTargets', 'globalPlanIdForSelection', 'globalSyncApplyEnabled',
  'updateGlobalSyncApplyButton'];
function setup() {
  const elements = new Map();
  function element() {
    return { textContent: '', title: '', innerHTML: '', value: '', checked: false,
      disabled: false, hidden: false, dataset: {}, style: {}, children: [],
      appendChild(c) { this.children.push(c); }, setAttribute(k,v) { this[k]=v; },
      removeAttribute(k) { delete this[k]; }, classList: {add(){},remove(){}} };
  }
  const document = { getElementById(id) {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  }, createElement: element, querySelectorAll: () => [] };
  let now = 1000;
  const model = {
    project: {syncId:'P0',syncState:'success',count:2,logName:'old-project',tail:'old project'},
    global: {syncId:'G0',syncState:'success',providers:[],targets:['codexcli'],logName:'old-global'},
    globalResult: 'success', projectResult: 'success', globalResponse: null, projectResponse: null,
    calls: [], notices: [], confirm: true, hook: null
  };
  const c = vm.createContext({ document, console, Promise,
    Date: { now:()=>now, parse:Date.parse }, setTimeout(cb,ms) { now+=ms; queueMicrotask(cb); },
    safeFocus(){}, esc:s=>String(s ?? ''),
    showConfirm: async()=> typeof model.confirm === 'function' ? model.confirm() : model.confirm,
    showNotify: async(title,text)=>{ model.notices.push({title,text}); if(model.hook) await model.hook(); },
    api: async(ep, method, body) => {
      model.calls.push({ep,method,body});
      if(ep === '/api/global-sync') {
        if(model.globalResponse instanceof Error) throw model.globalResponse;
        if(model.globalResponse) return model.globalResponse;
        model.global={...model.global,syncId:'G1',syncState:model.globalResult,logName:'new-global',tail:'global final'};
        return {sync:'started',syncId:'G1'};
      }
      if(ep === '/api/sync') {
        if(model.projectResponse instanceof Error) throw model.projectResponse;
        if(model.projectResponse) return model.projectResponse;
        model.project={...model.project,syncId:'P1',syncState:model.projectResult,logName:'new-project',tail:'project final'};
        return {sync:'started',syncId:'P1'};
      }
      if(ep.startsWith('/api/global-status')) return {...model.global};
      if(ep === '/api/status') return {...model.project};
      if(ep === '/api/projects' || ep === '/api/project-status') return {projects:[]};
      throw Error('Unexpected API: '+ep);
    }
  });
  vm.runInContext('var commonSyncStates={project:null,global:null}; var commonSyncSource="project";' +
    'var unifiedSyncActive=false,unifiedStateLock=false,unifiedFinalState=null;' +
    'var unifiedProjectRunId=null,unifiedGlobalRunId=null,completedUnifiedRunIds={};' +
    'var unifiedObservedProjectRunId=null,unifiedObservedGlobalRunId=null;' +
    'var unifiedBaselineProjectRunId=null,unifiedBaselineGlobalRunId=null;' +
    'var globalApplyInflight=false,globalTargetsDirty=false,globalIntervalDirty=false,lastGlobalPlan=null;' +
    names.map(actual).join('\n') +
    '\nvar startUnified='+handler('btnSync')+';var applyGlobal='+handler('btnGlobalSync')+';', c);
  return {c, model, document, el:id=>document.getElementById(id)};
}
async function test(name, f) { await f(); console.log('PASS: '+name); }
function noErrors(t) {
  assert.ok(!t.model.notices.some(n=>/できません/.test(n.title)), JSON.stringify(t.model.notices));
  assert.ok(!t.el('logPre').textContent.startsWith('取得失敗'),t.el('logPre').textContent);
  assert.ok(!t.el('globalLogPre').textContent.startsWith('取得失敗'),t.el('globalLogPre').textContent);
}
await test('both stages execute in order through actual refresh and notifications', async()=>{
  const t=setup(); await t.c.refresh(); await t.c.refreshGlobal(); await t.c.startUnified();
  assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),['/api/global-sync','/api/sync']);
  assert.equal(JSON.stringify(t.model.calls.find(x=>x.ep==='/api/global-sync').body),'{}');
  assert.equal(t.el('stRun').dataset.state,'success'); assert.equal(t.el('syncProgress').value,2);
  assert.ok(t.model.notices.some(n=>n.title==='同期が成功しました'));
  assert.equal(t.el('stLog').textContent,'new-project'); noErrors(t);
});
await test('mixed failure survives same-ID refresh even during final notification', async()=>{
  const t=setup(); t.model.globalResult='failed';
  t.model.hook=async()=>{ await t.c.refreshGlobal(); await t.c.refresh(); };
  await t.c.startUnified(); await t.c.refresh(); await t.c.refreshGlobal();
  assert.equal(t.c.unifiedFinalState,'failed'); assert.equal(t.el('stRun').dataset.state,'failed');
  assert.ok(t.el('stTail').textContent.includes('Global: 失敗')); noErrors(t);
});
await test('confirmation-time observations become the baseline on Global interruption',async()=>{
  const t=setup(); await t.c.refresh(); await t.c.refreshGlobal();
  t.model.confirm=async()=>{ t.model.project.syncId='P2'; await t.c.refresh(); return true; };
  t.model.globalResult='skipped'; await t.c.startUnified(); await t.c.refresh();
  assert.equal(t.el('stRun').dataset.state,'skipped'); assert.equal(t.c.unifiedFinalState,'skipped');
  assert.ok(!t.model.calls.some(x=>x.ep==='/api/sync'));
});
await test('cancel retains previous aggregate, IDs and progress without POST',async()=>{
  const t=setup(); t.model.globalResult='failed'; await t.c.startUnified();
  const saved=[t.c.unifiedFinalState,t.c.unifiedProjectRunId,t.c.unifiedGlobalRunId,t.el('syncProgress').value];
  t.model.calls=[]; t.model.confirm=false; await t.c.startUnified(); await t.c.refresh();
  assert.deepEqual([t.c.unifiedFinalState,t.c.unifiedProjectRunId,t.c.unifiedGlobalRunId,t.el('syncProgress').value],saved);
  assert.ok(!t.model.calls.some(x=>x.method==='POST'));
});
await test('new Global owns summary across old Project refresh and settles progress',async()=>{
  const t=setup(); await t.c.startUnified();
  t.model.global={...t.model.global,syncId:'G2',syncState:'running'};
  await t.c.refreshGlobal(); await t.c.refresh();
  assert.equal(t.el('stRun').dataset.state,'running'); assert.ok(!('value' in t.el('syncProgress')));
  t.model.global.syncState='failed'; await t.c.refreshGlobal(); await t.c.refresh();
  assert.equal(t.el('stRun').dataset.state,'failed'); assert.equal(t.el('syncProgress').value,1);
  assert.ok(t.el('syncProgressText').textContent.includes('失敗'));
});
await test('new Project execution clears old aggregate and settles progress',async()=>{
  const t=setup(); await t.c.startUnified();
  t.model.project={...t.model.project,syncId:'P2',syncState:'running'}; await t.c.refresh();
  assert.equal(t.el('stRun').dataset.state,'running');
  t.model.project.syncState='success'; await t.c.refresh();
  assert.equal(t.el('syncProgress').value,1); assert.ok(t.el('syncProgressText').textContent.includes('成功'));
});
for(const side of ['global','project']) {
  await test(side+' missing ID and network ambiguity remain unconfirmed',async()=>{
    for(const response of [{sync:'started'},new Error('response lost')]) {
      const t=setup(); t.model[side+'Response']=response; await t.c.startUnified();
      assert.equal(t.el('stRun').dataset.state,'unconfirmed');
      assert.equal(t.el('syncProgress').value,side==='global'?0:1);
      if(side==='global') assert.ok(!t.model.calls.some(x=>x.ep==='/api/sync'));
    }
  });
}
await test('Project timeout never reaches 2/2 and stale IDs cannot complete a poll',async()=>{
  const t=setup(); t.model.projectResult='running'; await t.c.startUnified();
  assert.equal(t.el('syncProgress').value,1); assert.equal(t.el('stRun').dataset.state,'unconfirmed');
  const result=await t.c.pollUntilDone('different',1,1,1000000); assert.equal(result,'unconfirmed');
});
await test('valid Global plan runs real after-notify and updates common state',async()=>{
  const t=setup(); t.model.globalResult='failed'; await t.c.startUnified();
  t.model.globalResult='success'; t.c.lastGlobalPlan={id:'approved',names:['codexcli']};
  t.el('ckTCodex').checked=true; await t.c.applyGlobal(); await t.c.refresh();
  assert.equal(t.el('stRun').dataset.state,'success');
  assert.ok(t.model.notices.some(n=>n.title==='Global同期が成功しました')); noErrors(t);
  assert.equal(t.c.lastGlobalPlan,null); assert.equal(t.el('btnGlobalSync').disabled,true);
});
await test('rejected plan is invalidated and duplicate starts are suppressed',async()=>{
  const t=setup(); t.c.lastGlobalPlan={id:'old',names:['codexcli']};t.el('ckTCodex').checked=true;
  t.model.globalResponse=new Error('invalid plan'); await t.c.applyGlobal();
  assert.equal(t.c.lastGlobalPlan,null);assert.equal(t.el('btnGlobalSync').disabled,true);
  t.model.calls=[]; t.c.unifiedSyncActive=true; await t.c.startUnified();
  assert.equal(t.model.calls.length,0);
});
await test('Global interruption replaces previous success result and log',async()=>{
  for(const result of ['skipped','running']) {
    const t=setup(); await t.c.startUnified();
    t.model.globalResult=result;
    await t.c.startUnified(); await t.c.refresh(); await t.c.refreshGlobal();
    assert.ok(t.el('stTail').textContent.includes('Project: 未実行'),t.el('stTail').textContent);
    assert.ok(!t.el('stTail').textContent.includes('Global: 成功'),t.el('stTail').textContent);
    assert.equal(t.el('stLog').textContent,'new-global');
  }
});
await test('initial summary selection ignores response order and respects running/time',async()=>{
  for(const order of [['project','global'],['global','project']]) {
    for(const active of ['project','global',null]) {
      const t=setup();
      t.model.project={...t.model.project,syncAt:'2026-10-18T10:00:00Z',syncState:active==='project'?'running':'success'};
      t.model.global={...t.model.global,syncAt:'2026-10-17T10:00:00Z',syncState:active==='global'?'running':'success'};
      for(const kind of order) await (kind==='project'?t.c.refresh():t.c.refreshGlobal());
      assert.equal(t.c.commonSyncSource,active||'project');
      assert.equal(t.el('stRun').dataset.state,active?'running':'success');
    }
  }
});
console.log('ALL UNIFIED SYNC CHECKS PASSED');
