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
  'renderSyncState', 'renderUnifiedProgress', 'renderProjectLog', 'renderGlobalLog', 'renderGlobalStatus',
  'refresh', 'refreshGlobal', 'pollUntilDone', 'pollGlobalUntilDone',
  'afterSyncNotify', 'afterGlobalSyncNotify', 'setUnifiedProgress',
  'globalProviderEntry', 'globalProviderLabel', 'globalLogoInitials', 'globalProviderLogo',
  'globalReloadProtectsTargets', 'globalReloadProtectsInterval',
  'renderGlobalTargetChoices', 'renderGlobalTargetsUI', 'globalTargetsDirtyNow', 'globalTargetsSetAll',
  'globalTargetsLockedByGitHub',
  'globalTargetCheckboxes', 'markGlobalTargetsDirty', 'globalSelectedTargets', 'globalPlanIdForSelection',
  'globalSyncApplyEnabled', 'updateGlobalSyncApplyButton', 'singleSyncTerminal',
  'beginSingleSyncScope', 'finishSingleSyncScope', 'selectedNames', 'selectedNamesIn', 'planIdForSelection'];
function setup() {
  const elements = new Map();
  function element() {
    const el = { textContent: '', title: '', value: '', checked: false,
      disabled: false, hidden: false, dataset: {}, style: {}, children: [],
      appendChild(c) { this.children.push(c); }, setAttribute(k,v) { this[k]=v; },
      removeAttribute(k) { delete this[k]; }, classList: {add(){},remove(){}} };
    Object.defineProperty(el, 'innerHTML', { get(){return this._innerHTML || '';}, set(v){this._innerHTML=v; if(v === '') this.children=[];} });
    return el;
  }
  const document = { getElementById(id) {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  }, createElement(tag) { const el=element(); el.tagName=String(tag).toUpperCase(); return el; },
  createTextNode(text) { return { text: String(text) }; },
  querySelectorAll(selector) {
    const cls = (selector.includes('global-target') || selector.includes('#globalTargetsList')) ? 'global-target' : 'selbox';
    return selector.split(',').flatMap(part => {
      const id = /#([A-Za-z0-9_-]+)/.exec(part)?.[1];
      const root = id ? elements.get(id) : null;
      const found = [];
      const visit = n => { if(n && n.type === 'checkbox' && String(n.className).split(/\s+/).includes(cls)) found.push(n); (n && n.children || []).forEach(visit); };
      visit(root);
      return found;
    });
  } };
  let now = 1000;
  const model = {
    project: {syncId:'P0',syncState:'success',count:2,logName:'old-project',tail:'old project'},
    global: {syncId:'G0',syncState:'success',providers:[],targets:['codexcli'],logName:'old-global'},
    globalResult: 'success', projectResult: 'success', globalResponse: null, projectResponse: null,
    calls: [], notices: [], confirm: true, hook: null, projects: [], projectStatuses: [], postGate: null
  };
  const c = vm.createContext({ document, console, Promise,
    Date: { now:()=>now, parse:Date.parse }, setTimeout(cb,ms) { now+=ms; queueMicrotask(cb); },
    safeFocus(){}, esc:s=>String(s ?? ''), L:(s,vars)=>String(s).replace(/\{([^{}]+)\}/g,(m,k)=>vars&&Object.prototype.hasOwnProperty.call(vars,k)?String(vars[k]):m),
    showConfirm: async()=> typeof model.confirm === 'function' ? model.confirm() : model.confirm,
    showNotify: async(title,text)=>{ model.notices.push({title,text}); if(model.hook) await model.hook(); },
    api: async(ep, method, body) => {
      model.calls.push({ep,method,body});
      if(method === 'POST' && model.postGate) await model.postGate;
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
      if(ep === '/api/projects') return {projects:model.projects};
      if(ep === '/api/project-status') return {projects:model.projectStatuses};
      throw Error('Unexpected API: '+ep);
    }
  });
  vm.runInContext('var commonSyncStates={project:null,global:null}; var commonSyncSource="project";' +
    'var GLOBAL_CATALOG=[{id:"codexcli",label:"Codex",rel:".codex\\\\AGENTS.md"},{id:"opencode",label:"OpenCode",rel:".config\\\\opencode\\\\AGENTS.md"},{id:"pi",label:"Pi",rel:".pi\\\\agent\\\\AGENTS.md"}];' +
    'var GLOBAL_DEFAULT_TARGETS=["codexcli","opencode"];' +
    'var currentLang="ja",localizedText={ja:new Map(),en:new Map(),"zh-CN":new Map()},I18N={};' +
    'var lastProjectCount=null,syncDisplayState=null,projectLogState={loaded:false,tail:"",error:null};' +
    'var currentGlobalStatus=null,globalLogState={loaded:false,tail:"",error:null};' +
    'var globalContentState=null,lastBackupDiff=null,lastGlobalBackupDiff=null;' +
    'var unifiedSyncActive=false,unifiedStateLock=false,unifiedFinalState=null;' +
    'var unifiedProjectRunId=null,unifiedGlobalRunId=null,completedUnifiedRunIds={};' +
    'var unifiedObservedProjectRunId=null,unifiedObservedGlobalRunId=null;' +
    'var unifiedBaselineProjectRunId=null,unifiedBaselineGlobalRunId=null;' +
    'var globalApplyInflight=false,globalTargetsDirty=false,globalIntervalDirty=false,lastGlobalPlan=null,globalTargetsEditGen=0,globalIntervalEditGen=0;' +
    'var globalReloadGuards=[],globalStatusRequestSeq=0,globalTargetsAppliedSeq=0,globalIntervalAppliedSeq=0;' +
    'var globalSavedTargets=["codexcli","opencode"],globalTargetsSaving=false,globalEnabledInflight=false;' +
    'var unifiedProgressState={completed:0,total:2,text:"0/2 待機中",key:null,vars:null,indeterminate:false,lang:"ja"};var lastPlan=null;' +
    names.map(actual).join('\n') +
    '\nrenderGlobalTargetChoices();' +
    '\nvar startUnified='+handler('btnSync')+';var applyGlobal='+handler('btnGlobalSync')+';' +
    'var startGlobalOnly='+handler('btnSyncGlobalOnly')+';var startProjectOnly='+handler('btnSyncProjectOnly')+';' +
    'var startSelected='+handler('btnSyncSel')+';', c);
  return {c, model, document, el:id=>document.getElementById(id)};
}
async function test(name, f) { await f(); console.log('PASS: '+name); }
function selectProject(t, name) {
  const box=t.document.createElement('input'); box.type='checkbox'; box.className='selbox'; box.value=name||'A'; box.checked=true;
  t.el('statusRows').appendChild(box);
}
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
  assert.ok(t.el('stTail').textContent.includes('Global: 失敗'), t.el('stTail').textContent); noErrors(t);
});
await test('language redraw after unified sync keeps both results and the latest log', async()=>{
  const t=setup(); t.model.globalResult='failed'; await t.c.startUnified();
  const translations={'成功':'Success','失敗':'Failed','未実行':'Not run','Global: {global} / Project: {project}':'Global: {global} / Project: {project}'};
  t.c.currentLang='en';
  t.c.L=(key,vars)=>{let s=translations[key]||key; return s.replace(/\{([^{}]+)\}/g,(m,k)=>vars&&Object.prototype.hasOwnProperty.call(vars,k)?String(vars[k]):m);};
  t.c.renderSyncState();
  assert.equal(t.el('stRun').dataset.state,'failed');
  assert.equal(t.el('stLog').textContent,'new-project');
  assert.equal(t.el('stTail').textContent,'Global: Failed / Project: Success');
});
await test('refresh preserves project selections in both rebuilt tables',async()=>{
  const t=setup();
  t.model.projects=[{name:'A',displayName:'A',path:'C:\\A'}];
  t.model.projectStatuses=[{name:'A',displayName:'A',enabled:true,result:'success'}];
  await t.c.refresh();
  t.el('rows').children[0].children[0].children[0].checked=true;
  t.el('statusRows').children[0].children[0].children[0].checked=true;
  await t.c.refresh();
  assert.deepEqual(Array.from(t.c.selectedNames()),['A']);
  assert.equal(t.el('rows').children[0].children[0].children[0].checked,true);
  assert.equal(t.el('statusRows').children[0].children[0].children[0].checked,true);
});
await test('refresh does not copy a selection into the other project table',async()=>{
  const t=setup();
  t.model.projects=[{name:'A',displayName:'A',path:'C:\\A'}];
  t.model.projectStatuses=[{name:'A',displayName:'A',enabled:true,result:'success'}];
  await t.c.refresh();
  t.el('rows').children[0].children[0].children[0].checked=true;
  await t.c.refresh();
  assert.equal(t.el('rows').children[0].children[0].children[0].checked,true);
  assert.equal(t.el('statusRows').children[0].children[0].children[0].checked,false);
  t.el('rows').children[0].children[0].children[0].checked=false;
  assert.deepEqual(Array.from(t.c.selectedNames()),[]);
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
for(const scope of ['global','project']) {
  await test(scope+'-only cancel keeps the previous aggregate through refresh and language redraw',async()=>{
    const t=setup(); await t.c.startUnified();
    const saved={
      final:t.c.unifiedFinalState,
      display:JSON.parse(JSON.stringify(t.c.syncDisplayState)),
      projectId:t.c.unifiedProjectRunId,
      globalId:t.c.unifiedGlobalRunId,
      progressValue:t.el('syncProgress').value,
      progressMax:t.el('syncProgress').max,
      progressText:t.el('syncProgressText').textContent,
      run:t.el('stRun').dataset.state,
      log:t.el('stLog').textContent,
      tail:t.el('stTail').textContent
    };
    t.model.calls=[]; t.model.confirm=false;
    await (scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly());
    await t.c.refresh(); await t.c.refreshGlobal();
    assert.ok(!t.model.calls.some(x=>x.method==='POST'));
    assert.equal(t.c.unifiedFinalState,saved.final);
    assert.deepEqual(JSON.parse(JSON.stringify(t.c.syncDisplayState)),saved.display);
    assert.equal(t.c.unifiedProjectRunId,saved.projectId);
    assert.equal(t.c.unifiedGlobalRunId,saved.globalId);
    assert.equal(t.el('syncProgress').value,saved.progressValue);
    assert.equal(t.el('syncProgress').max,saved.progressMax);
    assert.equal(t.el('syncProgressText').textContent,saved.progressText);
    assert.equal(t.el('stRun').dataset.state,saved.run);
    assert.equal(t.el('stLog').textContent,saved.log);
    assert.equal(t.el('stTail').textContent,saved.tail);
    const translations={'成功':'Success','失敗':'Failed','未実行':'Not run','Global: {global} / Project: {project}':'Global: {global} / Project: {project}'};
    t.c.currentLang='en';
    t.c.L=(key,vars)=>{let s=translations[key]||key; return s.replace(/\{([^{}]+)\}/g,(m,k)=>vars&&Object.prototype.hasOwnProperty.call(vars,k)?String(vars[k]):m);};
    t.c.renderSyncState();
    assert.equal(t.el('stRun').dataset.state,saved.run);
    assert.equal(t.el('stLog').textContent,saved.log);
    assert.equal(t.el('stTail').textContent,'Global: Success / Project: Success');
    assert.equal(t.el('syncProgress').value,saved.progressValue);
  });
}
for(const scope of ['global','project']) {
  await test(scope+'-only cancel releases the guard so the same action can succeed',async()=>{
    const t=setup();
    t.model.confirm=false;
    await (scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly());
    assert.equal(t.c.unifiedSyncActive,false,'guard released after cancel');
    assert.equal(t.c.unifiedStateLock,false,'state lock released after cancel');
    assert.equal(t.el(scope==='global'?'btnSyncGlobalOnly':'btnSyncProjectOnly').disabled,false,'button re-enabled after cancel');
    t.model.calls=[]; t.model.confirm=true;
    await (scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly());
    assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),[scope==='global'?'/api/global-sync':'/api/sync']);
    assert.equal(t.el('stRun').dataset.state,'success');
  });
  await test(scope+'-only cancel lets all-scope sync run and succeed',async()=>{
    const t=setup();
    t.model.confirm=false;
    await (scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly());
    assert.equal(t.c.unifiedSyncActive,false,'guard released after cancel');
    t.model.calls=[]; t.model.confirm=true;
    await t.c.startUnified();
    assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),['/api/global-sync','/api/sync']);
    assert.equal(t.el('stRun').dataset.state,'success');
  });
  await test(scope+'-only cancel lets selected sync run and succeed',async()=>{
    const t=setup();
    const box=t.document.createElement('input'); box.type='checkbox'; box.className='selbox'; box.value='A'; box.checked=true;
    t.el('statusRows').appendChild(box);
    t.model.confirm=false;
    await (scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly());
    assert.equal(t.c.unifiedSyncActive,false,'guard released after cancel');
    t.model.calls=[]; t.model.confirm=true;
    await t.c.startSelected();
    const posts=t.model.calls.filter(x=>x.method==='POST');
    assert.deepEqual(posts.map(x=>x.ep),['/api/sync']);
    assert.deepEqual(Array.from(posts[0].body.projectNames),['A']);
    assert.equal(t.c.unifiedSyncActive,false,'guard released after selected sync');
    assert.equal(t.el('stRun').dataset.state,'success');
  });
  await test(scope+'-only cancel lets Global plan apply run and succeed',async()=>{
    const t=setup();
    t.model.confirm=false;
    await (scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly());
    assert.equal(t.c.unifiedSyncActive,false,'guard released after cancel');
    t.model.globalResult='success'; t.c.lastGlobalPlan={id:'approved',names:['codexcli']};
    t.model.global.targets=['codexcli']; await t.c.refreshGlobal();
    t.model.calls=[]; t.model.confirm=true;
    await t.c.applyGlobal();
    assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),['/api/global-sync']);
    assert.equal(t.el('stRun').dataset.state,'success');
  });
}
await test('selected sync shows running while its completion notification is deferred and settles without refresh',async()=>{
  const t=setup(); await t.c.refresh(); selectProject(t);
  let releaseNotify; const notifyGate=new Promise(r=>{releaseNotify=r;});
  t.model.hook=()=>notifyGate;
  const run=t.c.startSelected();
  for(let i=0;i<50 && !t.model.notices.length;i++) await Promise.resolve();
  assert.ok(t.model.notices.length,'terminal notification opened');
  assert.equal(t.el('stRun').dataset.state,'running');
  assert.equal(t.c.unifiedSyncActive,true,'guard held while notification is open');
  releaseNotify(); await run;
  assert.equal(t.el('stRun').dataset.state,'success');
  assert.equal(t.c.unifiedSyncActive,false,'guard released after selected sync');
  assert.equal(t.el('btnSyncSel').disabled,false,'button re-enabled after selected sync');
});
await test('selected sync renders terminal failure when its notification closes without refresh',async()=>{
  const t=setup(); selectProject(t); t.model.projectResult='failed';
  await t.c.startSelected();
  assert.equal(t.el('stRun').dataset.state,'failed');
  assert.ok(t.model.notices.some(n=>n.title==='同期が失敗しました'),JSON.stringify(t.model.notices));
  assert.equal(t.c.unifiedSyncActive,false,'guard released after selected sync');
  assert.equal(t.el('btnSyncSel').disabled,false,'button re-enabled after selected sync');
});
await test('selected sync cancel and request failure preserve the previous display and release the guard',async()=>{
  const t=setup(); await t.c.refresh();
  const before=t.el('stRun').dataset.state;
  await t.c.startSelected();
  assert.ok(t.model.notices.some(n=>n.title==='選択なし'),JSON.stringify(t.model.notices));
  assert.equal(t.el('stRun').dataset.state,before);
  assert.equal(t.c.unifiedSyncActive,false,'guard released after cancel');
  assert.equal(t.el('btnSyncSel').disabled,false,'button enabled after cancel');
  assert.ok(!t.model.calls.some(x=>x.method==='POST'));
  selectProject(t); t.model.projectResponse=new Error('request lost');
  await t.c.startSelected();
  assert.ok(t.model.notices.some(n=>n.title==='同期できませんでした'),JSON.stringify(t.model.notices));
  assert.equal(t.el('stRun').dataset.state,before);
  assert.equal(t.c.unifiedSyncActive,false,'guard released after request failure');
  assert.equal(t.el('btnSyncSel').disabled,false,'button re-enabled after request failure');
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
  t.model.global.targets=['codexcli']; await t.c.refreshGlobal(); await t.c.applyGlobal(); await t.c.refresh();
  assert.equal(t.el('stRun').dataset.state,'success');
  assert.ok(t.model.notices.some(n=>n.title==='Global同期が成功しました')); noErrors(t);
  assert.equal(t.c.lastGlobalPlan,null); assert.equal(t.el('btnGlobalSync').disabled,true);
});
await test('rejected plan is invalidated and duplicate starts are suppressed',async()=>{
  const t=setup(); t.c.lastGlobalPlan={id:'old',names:['codexcli']}; t.model.global.targets=['codexcli']; await t.c.refreshGlobal();
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
await test('Global-only scope posts only its endpoint with 1-step progress',async()=>{
  const t=setup(); await t.c.refreshGlobal(); await t.c.startGlobalOnly();
  assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),['/api/global-sync']);
  assert.equal(JSON.stringify(t.model.calls.find(x=>x.ep==='/api/global-sync').body),'{}');
  assert.equal(t.el('syncProgress').max,1);
  assert.equal(t.el('syncProgress').value,1);
  assert.equal(t.el('stRun').dataset.state,'success');
  assert.ok(t.model.notices.some(n=>n.title==='Global同期が成功しました'));
  noErrors(t);
});
await test('Project-only scope posts only its endpoint with 1-step progress',async()=>{
  const t=setup(); await t.c.startProjectOnly();
  assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),['/api/sync']);
  assert.equal(JSON.stringify(t.model.calls.find(x=>x.ep==='/api/sync').body),'{}');
  assert.equal(t.el('syncProgress').max,1);
  assert.equal(t.el('syncProgress').value,1);
  assert.equal(t.el('stRun').dataset.state,'success');
  assert.ok(t.model.notices.some(n=>n.title==='同期が成功しました'));
  noErrors(t);
});
for(const scope of ['global','project']) {
  await test(scope+'-only start shows running while its POST is still unresolved',async()=>{
    const t=setup(); await t.c.startUnified();
    assert.equal(t.el('stRun').dataset.state,'success');
    let release; const gate=new Promise(r=>{release=r;});
    t.model.postGate=gate; t.model.calls=[]; t.model.confirm=true;
    const run=scope==='global'?t.c.startGlobalOnly():t.c.startProjectOnly();
    for(let i=0;i<10 && !t.model.calls.some(x=>x.method==='POST');i++) await Promise.resolve();
    assert.ok(t.model.calls.some(x=>x.method==='POST'),'POST reached');
    assert.equal(t.el('stRun').dataset.state,'running');
    assert.equal(t.el('syncProgress').max,1);
    release();
    await run;
    assert.deepEqual(t.model.calls.filter(x=>x.method==='POST').map(x=>x.ep),[scope==='global'?'/api/global-sync':'/api/sync']);
    assert.equal(t.el('stRun').dataset.state,'success');
    assert.equal(t.el('syncProgress').value,1);
  });
}
await test('single-scope unknown and failure never become success',async()=>{
  const g=setup(); g.model.globalResult='running'; await g.c.startGlobalOnly();
  assert.equal(g.el('stRun').dataset.state,'unconfirmed');
  assert.equal(g.el('syncProgress').max,1); assert.equal(g.el('syncProgress').value,0);
  assert.ok(g.model.notices.some(n=>n.title==='Global同期は未確認です'));
  assert.ok(!g.model.notices.some(n=>n.title==='Global同期が成功しました'));
  const p=setup(); p.model.projectResult='failed'; await p.c.startProjectOnly();
  assert.equal(p.el('stRun').dataset.state,'failed');
  assert.equal(p.el('syncProgress').max,1); assert.equal(p.el('syncProgress').value,1);
  assert.ok(p.model.notices.some(n=>n.title==='同期が失敗しました'));
});
await test('single-scope starts share the active and apply guards',async()=>{
  const t=setup(); t.c.unifiedSyncActive=true; t.model.calls=[];
  await t.c.startGlobalOnly(); await t.c.startProjectOnly();
  assert.equal(t.model.calls.length,0);
  t.c.unifiedSyncActive=false; t.c.globalApplyInflight=true;
  await t.c.startGlobalOnly(); await t.c.startProjectOnly();
  assert.equal(t.model.calls.length,0);
});
await test('provider choices come from the catalog and preserve unsaved selection',async()=>{
  const t=setup();
  assert.equal(t.c.globalProviderLabel('pi'),'Pi');
  assert.deepEqual(Array.from(t.c.globalSelectedTargets()),['codexcli','opencode']);
  t.model.global.targets=['pi']; await t.c.refreshGlobal();
  assert.deepEqual(Array.from(t.c.globalSelectedTargets()),['pi']);
  assert.equal(Array.from(t.c.globalTargetCheckboxes()).find(c=>c.value==='pi').checked,true);
  const pi=Array.from(t.c.globalTargetCheckboxes()).find(c=>c.value==='pi');
  const codex=Array.from(t.c.globalTargetCheckboxes()).find(c=>c.value==='codexcli');
  pi.checked=false; codex.checked=true;
  t.c.lastGlobalPlan={id:'p',names:['pi']};
  t.c.markGlobalTargetsDirty();
  assert.equal(t.c.globalTargetsDirty,true);
  assert.equal(t.c.lastGlobalPlan,null);
  assert.equal(t.el('btnGlobalSync').disabled,true);
  t.model.global.targets=['pi']; await t.c.refreshGlobal();
  assert.equal(pi.checked,false); assert.equal(codex.checked,true);
  assert.deepEqual(Array.from(t.c.globalSelectedTargets()),['codexcli']);
});
await test('refresh starts status, projects and project-status together', async()=>{
  const t = setup();
  const started = [];
  let release;
  const gate = new Promise(r => { release = r; });
  t.c.api = async (ep) => {
    started.push(ep);
    await gate;
    if(ep === '/api/status') return {syncId:'P0',syncState:'success',count:2,logName:'l',tail:'t'};
    if(ep === '/api/projects') return {projects:[]};
    if(ep === '/api/project-status') return {projects:[]};
    throw Error('unexpected ' + ep);
  };
  const p = t.c.refresh();
  assert.deepEqual(started, ['/api/status','/api/projects','/api/project-status']);
  release();
  await p;
});

await test('status polling cadence is 120 tries at 500ms', async()=>{
  const t = setup();
  const waits = [];
  t.c.setTimeout = (cb, ms) => { waits.push(ms); cb(); };
  await t.c.pollUntilDone('P1', 2, 500, t.c.Date.now() + 60000);
  assert.deepEqual(waits, [500]);
  await t.c.pollGlobalUntilDone('G1', 2, 500, t.c.Date.now() + 60000);
  assert.deepEqual(waits, [500, 500]);
});

await test('plan polling waits 150ms first, then 400ms', ()=>{
  assert.equal((src.match(/let planWait = 150;/g) || []).length, 2);
  assert.equal((src.match(/planWait = 400;/g) || []).length, 2);
  assert.ok(!src.includes('setTimeout(rs, 2000)'));
  assert.equal((src.match(/, 120, 500, /g) || []).length, 5);
});

await test('Global status reads the scheduled task once per response', ()=>{
  const start = src.indexOf('function Get-GlobalStatusResponse');
  const end = src.indexOf('function Clear-OldRequestFiles', start);
  assert.ok(start >= 0 && end > start);
  const body = src.slice(start, end);
  assert.equal((body.match(/Get-GlobalScheduledTask/g) || []).length, 1);
  assert.ok(!/Get-GlobalInterval|Get-GlobalTaskEnabled/.test(body));
});
console.log('ALL UNIFIED SYNC CHECKS PASSED');
