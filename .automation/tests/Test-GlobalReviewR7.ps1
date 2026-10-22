# Test-GlobalReviewR7.ps1 - regression tests for review round R7 findings F1-F13 (b85045a).
# Scratch-only. Never touches real home, tasks, registry, or deployed AppData.
# Scheduler cmdlets are shadowed; live scheduler writes are never tested.
# Real Sync-GlobalRules.ps1 is exercised via fake CLI shims (npx/gh), never stubbed
# for the Dashboard->Watch->Sync preview path.
$ErrorActionPreference = 'Stop'
$initCwd = (Get-Location).Path
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Get-Full([string]$P) { return [System.IO.Path]::GetFullPath($P) }
function Test-ContainedLocal([string]$Candidate, [string]$Root) {
  $c = Get-Full $Candidate; $r = Get-Full $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}
$origAuto = $env:DASHBOARD_AUTODIR
$origPort = $env:DASHBOARD_PORT
$origHomeDir = $env:HOME_DIR
$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$origPath = $env:PATH
$devAuto = Split-Path -Parent $PSScriptRoot
try {
  . (Join-Path $devAuto 'Global-Management.ps1')
  Assert ((Get-Command Get-GlobalSettings -ErrorAction SilentlyContinue) -ne $null) 'R7-0 module dot-sourced (no listen)'

  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalReviewR7Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  $fakeHome = Join-Path $scratch 'home'
  New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
  $gprev = Join-Path $scratch 'global-preview'
  New-Item -ItemType Directory -Force -Path $gprev | Out-Null
  Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"example-org/team-rules":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R7' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R7' -Encoding Ascii
  Set-GlobalTargets $auto @('codexcli', 'opencode') | Out-Null
  # Scheduler shadowing MUST live at test script scope: functions defined inside
  # a helper vanish with its scope and the real task would be touched.
  # Get-ScheduledTask stays mocked too: autoloading ScheduledTasks re-registers
  # its cmdlets and would let the real Disable-ScheduledTask replace the mock.
  function Get-ScheduledTask {
    param([string]$TaskName)
    if ($TaskName -ceq 'Rulesync Global Auto Sync') { return [pscustomobject]@{ TaskName = $TaskName; State = 'Ready'; Triggers = @() } }
    throw ('Task not found: ' + $TaskName)
  }
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }

  # F7: fine-grained github_pat_ + known env tokens redacted on display paths.
  $env:GITHUB_TOKEN = 'gh-test-env-token-R7AAA'
  $env:GH_TOKEN = 'gh-test-env-token-R7BBB'
  $patToken = 'github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ_123456'
  $red7 = Redact-GlobalText ('leak ' + $patToken + ' and gh-test-env-token-R7AAA and gh-test-env-token-R7BBB end') 'dash-tok-R7'
  Assert ((($red7.Contains($patToken) -eq $false) -and ($red7.Contains('gh-test-env-token-R7AAA') -eq $false) -and ($red7.Contains('gh-test-env-token-R7BBB') -eq $false) -and ($red7.Contains('***')))) 'R7-F7 fine-grained pat + env tokens redacted'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') ('codex-cur-R7 ' + $patToken + ' gh-test-env-token-R7AAA') -Encoding Ascii
  $gc7 = Get-GlobalContent $fakeHome 'dash-tok-R7'
  $cx7 = @($gc7.files | Where-Object { [string]$_.target -ceq 'codexcli' })
  Assert ((($cx7[0].head.Contains($patToken) -eq $false) -and ($cx7[0].head.Contains('gh-test-env-token-R7AAA') -eq $false))) 'R7-F7 content head redacted'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R7' -Encoding Ascii
  $logDir7 = Join-Path $auto 'logs'
  New-Item -ItemType Directory -Force -Path $logDir7 | Out-Null
  Set-Content -LiteralPath (Join-Path $logDir7 'Sync-GlobalRules-20200107.log') ('2020-01-07 00:00:00 FAIL: ' + $patToken + ' gh-test-env-token-R7BBB') -Encoding UTF8
  $gl7 = Get-GlobalLogTail $auto 'dash-tok-R7'
  Assert ((($gl7.tail.Contains($patToken) -eq $false) -and ($gl7.tail.Contains('gh-test-env-token-R7BBB') -eq $false))) 'R7-F7 log tail redacted'

  # F9: empty source / unreadable hashes fail closed (never match).
  $live9 = Get-GlobalPlanLive $auto $fakeHome
  $plan9ok = @{ schemaVersion = 1; createdAt = 't'; sourceCommit = [string]$live9.sourceCommit; targets = @('codexcli'); entries = @(@{ target = 'codexcli'; path = [string](@($live9.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].path; exists = $true; currentHash = [string](@($live9.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].currentHash; generatedHash = 'g'; generatedText = 'gen'; currentText = 'cur'; result = 'success'; error = '' }) }
  Assert ((Test-GlobalPlanMatch $plan9ok $live9 @('codexcli')).ok) 'R7-F9 sane plan still matches'
  $liveEmptySrc = @{ sourceCommit = ''; targets = @('codexcli'); entries = @($live9.entries) }
  $planEmptySrc = @{ schemaVersion = 1; createdAt = 't'; sourceCommit = ''; targets = @('codexcli'); entries = @($plan9ok.entries) }
  Assert (((Test-GlobalPlanMatch $planEmptySrc $liveEmptySrc @('codexcli')).ok -eq $false)) 'R7-F9 empty source commits never match'
  $liveBadHash = @{ sourceCommit = [string]$live9.sourceCommit; targets = @('codexcli'); entries = @(@{ target = 'codexcli'; path = [string](@($live9.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].path; exists = $true; currentHash = $null }) }
  Assert (((Test-GlobalPlanMatch $plan9ok $liveBadHash @('codexcli')).ok -eq $false)) 'R7-F9 unreadable live hash never matches readable pin'
  $planBadHash = @{ schemaVersion = 1; createdAt = 't'; sourceCommit = [string]$live9.sourceCommit; targets = @('codexcli'); entries = @(@{ target = 'codexcli'; path = [string](@($live9.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].path; exists = $true; currentHash = $null; generatedHash = 'g'; generatedText = 'gen'; currentText = 'cur'; result = 'success'; error = '' }) }
  Assert (((Test-GlobalPlanMatch $planBadHash $live9 @('codexcli')).ok -eq $false)) 'R7-F9 unreadable pinned hash never matches'

  # F10: explicit request targets drive live entries (not stored settings alone).
  Set-GlobalTargets $auto @('opencode') | Out-Null
  $live10 = Get-GlobalPlanLive $auto $fakeHome @('codexcli')
  Assert ((@($live10.entries | Where-Object { [string]$_.target -ceq 'codexcli' }).Count -eq 1)) 'R7-F10 explicit codexcli present in live entries'
  $plan10 = @{ schemaVersion = 1; createdAt = 't'; sourceCommit = [string]$live10.sourceCommit; targets = @('codexcli'); entries = @(@{ target = 'codexcli'; path = [string](@($live10.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].path; exists = $true; currentHash = [string](@($live10.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].currentHash; generatedHash = 'g'; generatedText = 'gen'; currentText = 'cur'; result = 'success'; error = '' }) }
  Assert ((Test-GlobalPlanMatch $plan10 $live10 @('codexcli')).ok) 'R7-F10 explicit-target plan applies without touching stored selection'
  Set-GlobalTargets $auto @('codexcli', 'opencode') | Out-Null

  # F5: codex-only backup carries no config; restore never writes opencode.json.
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\opencode.json') '{"marker":"json-R7-orig"}' -Encoding Ascii
  $bk5 = New-GlobalBackup $auto $fakeHome @('codexcli')
  $mf5 = Get-Content -LiteralPath (Join-Path $bk5 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ((@($mf5.files | Where-Object { [string]$_.kind -ceq 'config' }).Count -eq 0)) 'R7-F5 codex-only backup has no config entries'
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\opencode.json') '{"marker":"json-R7-drifted"}' -Encoding Ascii
  $cf5 = New-GlobalRestoreConfirm $auto (Split-Path $bk5 -Leaf) $fakeHome
  $rs5 = Restore-GlobalBackup $auto (Split-Path $bk5 -Leaf) $true $fakeHome $cf5
  Assert (($rs5.ok -eq $true)) 'R7-F5 codex-only restore succeeds'
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\opencode.json') -Raw).Contains('json-R7-drifted'))) 'R7-F5 restore leaves opencode.json untouched'
  $bd5 = Get-GlobalBackupDiff $auto (Split-Path $bk5 -Leaf) $fakeHome
  $cfgJson5 = @($bd5.configChanges | Where-Object { [string]$_.file -like '*opencode.json*' })
  Assert ((@($cfgJson5).Count -eq 0)) 'R7-F5 codex-only diff reports no config rows'
  # both-targets backup reports config presence without content.
  $bk5b = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\opencode.json') '{"marker":"json-R7-drifted2"}' -Encoding Ascii
  $bd5b = Get-GlobalBackupDiff $auto (Split-Path $bk5b -Leaf) $fakeHome
  Assert ((@($bd5b.configChanges).Count -ge 1)) 'R7-F5 both-targets diff shows config presence row'
  Assert ((-not (($bd5b | ConvertTo-Json -Depth 6 -Compress).Contains('json-R7')))) 'R7-F5 config content never exposed in diff'
  $cf5b = New-GlobalRestoreConfirm $auto (Split-Path $bk5b -Leaf) $fakeHome
  Restore-GlobalBackup $auto (Split-Path $bk5b -Leaf) $true $fakeHome $cf5b | Out-Null
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\opencode.json') -Raw).Contains('json-R7-drifted2'))) 'R7-F5 both-targets restore still never writes config'
  # backup bytes are privately ACLed.
  $acl5 = Get-Acl -LiteralPath (Join-Path $bk5b '.codex_AGENTS.md')
  Assert (($acl5.AreAccessRulesProtected -eq $true)) 'R7-F5 backup bytes privately ACLed'

  # F3: delete steps sheltered; rollback restores deleted current content.
  Remove-Item -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Force
  $bk3 = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-current-R7F3' -Encoding Ascii
  $origExp3 = (Get-Command Copy-GlobalExpectedBytes).ScriptBlock
  function Copy-GlobalExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What, [string]$SrcRoot = "", [string]$DstRoot = "") {
    if ([string]$Dst -like '*opencode\AGENTS.md') { throw 'injected-opencode-copy-fail' }
    if (($SrcRoot -ne '') -or ($DstRoot -ne '')) { & $script:origExp3 $Src $Dst $ExpectedHash $What $SrcRoot $DstRoot }
    else { & $script:origExp3 $Src $Dst $ExpectedHash $What }
  }
  $script:origExp3 = $origExp3
  $cf3 = New-GlobalRestoreConfirm $auto (Split-Path $bk3 -Leaf) $fakeHome
  $f3bad = $true
  try { Restore-GlobalBackup $auto (Split-Path $bk3 -Leaf) $true $fakeHome $cf3 | Out-Null; $f3bad = $false } catch { $f3bad = ($_.Exception.Message.Contains('injected-opencode-copy-fail')) }
  Assert ($f3bad) 'R7-F3 injected copy failure aborts restore'
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Raw).Contains('codex-current-R7F3'))) 'R7-F3 rollback restores deleted codex current content'
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') -Raw).Contains('opencode-cur-R7'))) 'R7-F3 rollback keeps opencode current content'
  Remove-Item -Path 'function:Copy-GlobalExpectedBytes' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')

  # F4: restore requires fresh server-issued diff confirmation bound to hashes.
  $bk4 = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  $noCf = $true
  try { Restore-GlobalBackup $auto (Split-Path $bk4 -Leaf) $true $fakeHome | Out-Null; $noCf = $false } catch { $noCf = ($_.Exception.Message.Contains('差分')) }
  Assert ($noCf) 'R7-F4 restore without diff confirmation refused'
  $bd4 = Get-GlobalBackupDiff $auto (Split-Path $bk4 -Leaf) $fakeHome
  Assert (([string]$bd4.confirmId -match '^[0-9a-f]{32}$')) 'R7-F4 diff issues confirm id'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-drifted-after-diff-R7' -Encoding Ascii
  $staleCf = $true
  try { Restore-GlobalBackup $auto (Split-Path $bk4 -Leaf) $true $fakeHome ([string]$bd4.confirmId) | Out-Null; $staleCf = $false } catch { $staleCf = ($_.Exception.Message.Contains('変化')) }
  Assert ($staleCf) 'R7-F4 stale confirm after current change refused'
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Raw).Contains('codex-drifted-after-diff-R7'))) 'R7-F4 refused restore leaves current files'
  $bd4b = Get-GlobalBackupDiff $auto (Split-Path $bk4 -Leaf) $fakeHome
  $rs4 = Restore-GlobalBackup $auto (Split-Path $bk4 -Leaf) $true $fakeHome ([string]$bd4b.confirmId)
  Assert (($rs4.ok -eq $true)) 'R7-F4 fresh confirm restores'

  # F8: pre-restore shelter uses the same restorable manifest (diff+restore work).
  $preId = Split-Path ([string]$rs4.backup) -Leaf
  $bl8 = @(Get-GlobalBackupList $auto | Where-Object { [string]$_.id -ceq $preId })
  Assert ((@($bl8).Count -eq 1)) 'R7-F8 pre-restore shelter listed as global backup'
  $bd8 = Get-GlobalBackupDiff $auto $preId $fakeHome
  Assert (($null -ne $bd8)) 'R7-F8 pre-restore shelter diffable'
  $rs8 = Restore-GlobalBackup $auto $preId $true $fakeHome ([string]$bd8.confirmId)
  Assert (($rs8.ok -eq $true)) 'R7-F8 restore from pre-restore shelter succeeds'
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Raw).Contains('codex-drifted-after-diff-R7'))) 'R7-F8 shelter roundtrip brings back sheltered content'

  # F6: parent-dir junctions inspected on read/backup/restore/delete.
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $ext6 = Join-Path $scratch 'ext6'
  New-Item -ItemType Directory -Force -Path $ext6 | Out-Null
  Set-Content -LiteralPath (Join-Path $ext6 'AGENTS.md') 'ext6-marker' -Encoding Ascii
  $codexDir = Join-Path $fakeHome '.codex'
  $codexKeep = Get-Content -LiteralPath (Join-Path $codexDir 'AGENTS.md') -Raw -Encoding UTF8
  Remove-Item -LiteralPath $codexDir -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $codexDir + '" "' + $ext6 + '"') | Out-Null
  Assert ((Get-Item -LiteralPath $codexDir -Force).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) 'R7-F6 junction fixture ready'
  $gc6 = Get-GlobalContent $fakeHome 'dash-tok-R7'
  $cx6 = @($gc6.files | Where-Object { [string]$_.target -ceq 'codexcli' })
  Assert ((($cx6[0].exists -eq $false) -and ($null -eq $cx6[0].hash) -and ($null -eq $cx6[0].head))) 'R7-F6 junctioned parent reads as absent (no bytes through link)'
  $bk6bad = $true
  try { New-GlobalBackup $auto $fakeHome @('codexcli') | Out-Null; $bk6bad = $false } catch { $bk6bad = $true }
  Assert ($bk6bad) 'R7-F6 backup refuses junctioned parent'
  $rs6bad = $true
  try { $cf6 = New-GlobalRestoreConfirm $auto (Split-Path $bk4 -Leaf) $fakeHome; Restore-GlobalBackup $auto (Split-Path $bk4 -Leaf) $true $fakeHome $cf6 | Out-Null; $rs6bad = $false } catch { $rs6bad = $true }
  Assert ($rs6bad) 'R7-F6 restore refuses junctioned parent'
  Assert (((Get-Content -LiteralPath (Join-Path $ext6 'AGENTS.md') -Raw).Contains('ext6-marker'))) 'R7-F6 external dir untouched'
  & $cmdExe /c ('rmdir "' + $codexDir + '"') | Out-Null
  New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
  Set-Content -LiteralPath (Join-Path $codexDir 'AGENTS.md') $codexKeep -Encoding UTF8

  # F12: size pre-limits (no full allocation; oversize never applicable).
  $bigFile = Join-Path $fakeHome '.config\opencode\AGENTS.md'
  $bigKeep = Get-Content -LiteralPath $bigFile -Raw -Encoding UTF8
  $fs12 = [System.IO.File]::Create($bigFile)
  try { $chunk = New-Object byte[] 65536; for ($i12 = 0; $i12 -lt 40; $i12++) { $fs12.Write($chunk, 0, $chunk.Length) } } finally { $fs12.Close() }
  $gc12 = Get-GlobalContent $fakeHome 'dash-tok-R7'
  $op12 = @($gc12.files | Where-Object { [string]$_.target -ceq 'opencode' })
  Assert (([string]$op12[0].head).Length -le 4200) 'R7-F12 oversize head bounded without full read'
  Assert (([string]$op12[0].hash -match '^[0-9a-f]{64}$')) 'R7-F12 oversize file still hashed via stream'
  Assert ((Test-GlobalTextSizeOk 'x') -and (-not (Test-GlobalTextSizeOk ([string]::new('y', (2 * 1024 * 1024)))))) 'R7-F12 plan-text size gate trips on oversize'
  Set-Content -LiteralPath $bigFile $bigKeep -Encoding UTF8

  # F2+F11 UI: served JS sends approved planId+selection; dirty inputs survive polls.
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  Assert (($null -ne $nodeExe) -and ($nodeExe -ne '')) 'R7 node available for UI harness'
  if ($nodeExe) {
    $uijs = Join-Path $scratch 'r7-ui.js'
    Set-Content -LiteralPath $uijs @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
function sliceFn(a, b) {
  var i = src.indexOf(a), j = src.indexOf(b, i);
  if (i < 0 || j < 0) throw new Error('slice miss: ' + a);
  return src.substring(i, j);
}
var UI_END = 'document.getElementById("btnGlobalContent")';
function mkEl(id) {
  var el = { id: id, checked: false, value: '', textContent: '', className: '', hidden: false,
    children: [], onclick: null, parentNode: null, dataset: {}, _l: {},
    addEventListener: function (t, f) { this._l[t] = f; },
    fire: function (t) { if (this._l[t]) this._l[t](); },
    appendChild: function (c) { c.parentNode = this; this.children.push(c); return c; } };
  Object.defineProperty(el, 'innerHTML', { get: function () { return this._h || ''; },
    set: function (v) { this._h = v; this.children = []; } });
  return el;
}
var ckC = mkEl('ckTCodex'), ckO = mkEl('ckTOpenCode'), numI = mkEl('numGlobalInterval');
numI.value = '15';
var planArea = mkEl('globalPlanArea');
var byId = { ckTCodex: ckC, ckTOpenCode: ckO, numGlobalInterval: numI,
  globalPlanArea: planArea, globalSummary: mkEl('gs'), globalLogPre: mkEl('gl'),
  globalRows: mkEl('gr'), tblGlobal: mkEl('tg'), emptyGlobal: mkEl('eg'),
  globalEnabledState: mkEl('es') };
global.document = { getElementById: function (id) {
    if (!byId[id]) byId[id] = mkEl(id);
    return byId[id]; },
  createElement: function (t) { return mkEl(''); }, activeElement: null,
  addEventListener: function () {}, removeEventListener: function () {},
  querySelectorAll: function () { return []; } };
global.window = { addEventListener: function () {} };
var sent = [];
global.api = async function (ep, m, b) {
  sent.push({ ep: ep, m: m, b: b });
  if (ep === '/api/global-preview-start') return { ok: true, planId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90', syncId: 's' };
  if (ep.indexOf('/api/global-plan') === 0) return { status: 'ready', planId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90', sourceCommit: 'c', createdAt: 't', targets: ['codexcli'], entries: [] };
  if (ep === '/api/global-sync') return { ok: true, sync: 'started', syncId: 's' };
  if (ep.indexOf('/api/global-status') === 0) return { syncId: 's', syncState: 'success', providers: [], targets: ['codexcli'] };
  return {};
};
global.showConfirm = async function () { return true; };
global.showNotify = async function () {};
global.safeFocus = function () {};
global.esc = function (s) { return s; };
global.setMsg = function () {};
global.refreshGlobal = async function () {};
global.pollGlobalUntilDone = async function () { return 'success'; };
global.diffLinesLocal = function () { return { same: true, lines: [] }; };
global.renderDiffFrag = function () { return {}; };
global.applySearchFilter = function () {};
global.stateJa = function (s) { return s; };
global.globalResultJa = function (s) { return s; };
global.renderGlobalTable = function () {};
var commonSyncStates = { project: null, global: null }, commonSyncSource = 'project';
eval(sliceFn('function updateCommonSyncState', '\nfunction resultJa'));
eval(sliceFn('let lastGlobalPlan', UI_END).split('let ').join('var '));
eval(sliceFn('function updateGlobalUI(g){', '\nasync function refreshGlobal').split('let ').join('var '));
(async function () {
  ckC.checked = true; ckO.checked = false;
  await document.getElementById('btnGlobalPreview').onclick();
  ok(lastGlobalPlan && lastGlobalPlan.id === 'a1b2c3d4e5f60718293a4b5c6d7e8f90', 'R7-F2 preview stores approved plan id');
  ok((lastGlobalPlan.names || []).join(',') === 'codexcli', 'R7-F2 preview stores approved selection');
  sent = sent.filter(function (s) { return s.ep === '/api/global-sync'; });
  await document.getElementById('btnGlobalSync').onclick();
  var syncCall = sent.filter(function (s) { return s.ep === '/api/global-sync'; })[0];
  ok(syncCall && syncCall.b && syncCall.b.planId === 'a1b2c3d4e5f60718293a4b5c6d7e8f90', 'R7-F2 sync sends approved plan id');
  ok(syncCall && syncCall.b && (syncCall.b.targetNames || []).join(',') === 'codexcli', 'R7-F2 sync sends approved selection');
  ckO.checked = true;
  updateGlobalSyncApplyButton();
  await document.getElementById('btnGlobalSync').onclick();
  var syncCalls2 = sent.filter(function (s) { return s.ep === '/api/global-sync'; });
  ok(syncCalls2.length === 1, 'R7-F2 changed selection does not apply stale plan');
  ckC.checked = true; ckO.checked = false;
  ckC.fire('change');
  ckC.checked = false;
  updateGlobalUI({ providers: [], targets: ['codexcli', 'opencode'], syncState: 'idle', intervalMinutes: 30, taskEnabled: true });
  ok(ckC.checked === false, 'R7-F11 dirty checkboxes survive status poll');
  numI.value = '99'; numI.fire('input');
  numI.value = '77';
  updateGlobalUI({ providers: [], targets: ['codexcli'], syncState: 'idle', intervalMinutes: 30, taskEnabled: true });
  ok(numI.value === '77', 'R7-F11 dirty interval survives status poll');
  if (fails.length) process.exit(1);
  console.log('ALL R7 UI CHECKS PASSED');
})().catch(function (e) { console.log('FAIL: harness ' + (e && e.stack || e)); process.exit(1); });
'@ -Encoding UTF8
    & $nodeExe $uijs (Join-Path $devAuto 'Dashboard-Server.ps1')
    Assert ($LASTEXITCODE -eq 0) 'R7-F2/F11 UI harness (plan id sent, dirty retained)'
  }

  # F1+F2-server+F13: live scratch server, REAL Sync via fake CLI shims.
  $bin = Join-Path $scratch 'bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  Set-Content -LiteralPath (Join-Path $bin 'npx-fake.ps1') @'
param([string[]]$RestArgs)
$ErrorActionPreference = 'Stop'
$argsAll = @($RestArgs) + @($args)
$auto = $env:FAKE_AUTO_DIR
$hb = $env:HOME_DIR
function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like ('*' + $S + '*')) { return $true } }; return $false }
if ((Has 'install')) { exit 0 }
if ((Has '--check') -and (-not (Has '--dry-run')) -and (-not (Has 'generate --global --check marker'))) {
  $cntFile = Join-Path $auto 'fake-check-count.txt'
  $n = 0
  if (Test-Path -LiteralPath $cntFile) { try { $n = [int](Get-Content -LiteralPath $cntFile -Raw) } catch { $n = 0 } }
  $n++
  Set-Content -LiteralPath $cntFile ([string]$n) -Encoding Ascii
  if ($n -eq 1) { exit 1 }
  exit 0
}
if (Has '--dry-run') { exit 0 }
if (Has 'generate') {
  New-Item -ItemType Directory -Force -Path (Join-Path $hb '.codex'), (Join-Path $hb '.config\opencode') | Out-Null
  Set-Content -LiteralPath (Join-Path $hb '.codex\AGENTS.md') 'generated-codex-R7' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $hb '.config\opencode\AGENTS.md') 'generated-opencode-R7' -Encoding UTF8
  exit 0
}
exit 0
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bin 'npx.cmd') ('@echo off' + "`r`n" + 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0npx-fake.ps1" %*' + "`r`n" + 'exit /b %ERRORLEVEL%') -Encoding Ascii
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Watch-GlobalSync.ps1') -Destination (Join-Path $auto 'Watch-GlobalSync.ps1') -Force
  Set-Content -LiteralPath (Join-Path $auto 'Run-GlobalRules.vbs') "' dummy launcher" -Encoding Ascii
  $env:PATH = ($bin + ';' + $origPath)
  $env:HOME_DIR = $fakeHome
  $env:FAKE_AUTO_DIR = $auto
  $env:GITHUB_TOKEN = 'gh-test-fake-cli-token'
  $env:DASHBOARD_AUTODIR = $auto
  $env:DASHBOARD_PORT = '18797'
  $srv = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $devAuto 'Dashboard-Server.ps1') -WindowStyle Hidden -PassThru
  try {
    $okSrv = $false
    for ($iS = 0; $iS -lt 40; $iS++) {
      Start-Sleep -Milliseconds 500
      try {
        $hS = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18797/health'
        if ($hS.StatusCode -eq 200) { $okSrv = $true; break }
      } catch {}
      if ($srv.HasExited) { break }
    }
    Assert ($okSrv) 'R7-F1 scratch server health'
    if ($okSrv -and (-not $srv.HasExited)) {
      $tok = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $script:hdrs = @{ 'X-Dashboard-Token' = $tok }
      function GetR7([string]$Ep) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $script:hdrs -Uri ('http://127.0.0.1:18797' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      function PostR7([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $script:hdrs -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18797' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      # F1: preview through Dashboard->Watch->REAL Sync succeeds (plan ready, both targets).
      $pv = PostR7 '/api/global-preview-start' @{ targetNames = @('codexcli', 'opencode') }
      Assert (([string]$pv.planId -match '^[0-9a-f]{32}$')) 'R7-F1 preview start returns output plan id'
      $ready = $null
      for ($pi = 0; $pi -lt 30; $pi++) {
        Start-Sleep -Milliseconds 1000
        try {
          $plW = GetR7 ('/api/global-plan?id=' + [string]$pv.planId)
          if ([string]$plW.status -ceq 'ready') { $ready = $plW; break }
        } catch {}
      }
      Assert (($null -ne $ready) -and (@($ready.entries).Count -eq 2)) 'R7-F1 preview plan ready via real Watch->Sync chain'
      # F2-server: stale plan apply refused after current drift.
      Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-drifted-R7F1' -Encoding Ascii
      $staleCode = 0; $staleRefused = $false
      try { PostR7 '/api/global-sync' @{ targetNames = @('codexcli', 'opencode'); planId = [string]$pv.planId } | Out-Null } catch { $staleCode = $_.Exception.Response.StatusCode.value__; $staleRefused = ($staleCode -eq 400) }
      Assert ($staleRefused) 'R7-F2 stale plan apply refused with 400'
      # F13: string "false" never enables auto sync.
      $enCode = 0; $enRefused = $false
      try { PostR7 '/api/global-enabled-set' @{ enabled = 'false' } | Out-Null } catch { $enCode = $_.Exception.Response.StatusCode.value__; $enRefused = ($enCode -eq 400) }
      Assert ($enRefused) 'R7-F13 string "false" rejected with 400'
    }
  } finally {
    try { if ($srv -and (-not $srv.HasExited)) { Stop-Process -Id $srv.Id -Force } } catch {}
    Start-Sleep -Milliseconds 500
  }

  Assert (((Get-Location).Path) -eq $initCwd) 'R7 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'R7 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $base) 'R7 base dir left intact'
}
finally {
  $env:DASHBOARD_AUTODIR = $origAuto
  if ($null -eq $origAuto) { Remove-Item Env:DASHBOARD_AUTODIR -ErrorAction SilentlyContinue }
  $env:DASHBOARD_PORT = $origPort
  if ($null -eq $origPort) { Remove-Item Env:DASHBOARD_PORT -ErrorAction SilentlyContinue }
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Copy-GlobalExpectedBytes' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL R7 REVIEW CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
