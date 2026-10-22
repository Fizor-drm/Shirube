# Test-GlobalReviewR8.ps1 - round2 findings (RED then GREEN).
# Scratch-only. Never touches real home, tasks, registry.
# Scheduler cmdlets shadowed at script scope (see R7 scope bug: helper-scope
# functions vanish and the real task would be touched).
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
$origHomeDir = $env:HOME_DIR
$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$devAuto = Split-Path -Parent $PSScriptRoot
try {
  . (Join-Path $devAuto 'Global-Management.ps1')
  # Get-ScheduledTask stays mocked too: autoloading ScheduledTasks re-registers
  # its cmdlets and would let the real Disable-ScheduledTask replace the mock.
  function Get-ScheduledTask {
    param([string]$TaskName)
    if ($TaskName -ceq 'Rulesync Global Auto Sync') { return [pscustomobject]@{ TaskName = $TaskName; State = 'Ready'; Triggers = @() } }
    throw ([System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('Task not found: ' + $TaskName),
      'CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask',
      [System.Management.Automation.ErrorCategory]::ObjectNotFound,
      $TaskName))
  }
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalReviewR8Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  $fakeHome = Join-Path $scratch 'home'
  New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
  $gprev = Join-Path $scratch 'global-preview'
  New-Item -ItemType Directory -Force -Path $gprev | Out-Null
  Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"x":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R8' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R8' -Encoding Ascii
  Set-GlobalTargets $auto @('codexcli', 'opencode') | Out-Null
  $srvSrc = Get-Content -LiteralPath (Join-Path $devAuto 'Dashboard-Server.ps1') -Raw -Encoding UTF8

  # R8-1: UI restore sends confirmId stored per backup from diff.
  $hasStore = $srvSrc.Contains('globalRestoreConfirms')
  $diffStores = (($srvSrc.Contains('confirmId') -and $hasStore))
  Assert ($hasStore) 'R8-1 UI keeps per-backup confirmId map'
  $restoreSends = $false
  try {
    $ri = $srvSrc.IndexOf('/api/global-restore')
    $seg = $srvSrc.Substring($ri, [Math]::Min(600, $srvSrc.Length - $ri))
    $restoreSends = $seg.Contains('confirmId')
  } catch { $restoreSends = $false }
  Assert ($restoreSends) 'R8-1 UI restore sends confirmId'
  # actual UI functions exist and wire diff->restore
  $hasDiffFn = ($srvSrc.Contains('function globalBackupDiff') -or $srvSrc.Contains('globalBackupDiff ='))
  $hasRestoreFn = ($srvSrc.Contains('function globalBackupRestore') -or $srvSrc.Contains('globalBackupRestore ='))
  Assert (($hasDiffFn -and $hasRestoreFn)) 'R8-1 actual UI diff/restore functions exist'
  # node harness: call actual UI restore fn, confirmId must be sent
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($nodeExe) {
    $uijs = Join-Path $scratch 'r8-ui.js'
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
var byId = { globalBackupDiffArea: mkEl('da'), msgGlobalBackup: mkEl('m'), globalBackupRows: mkEl('r'),
  tblGlobalBackups: mkEl('t'), emptyGlobalBackups: mkEl('e') };
global.document = { getElementById: function (id) { if (!byId[id]) byId[id] = mkEl(id); return byId[id]; },
  createElement: function (t) { return mkEl(''); }, activeElement: null,
  addEventListener: function () {}, removeEventListener: function () {},
  querySelectorAll: function () { return []; }, createDocumentFragment: function () { return mkEl('frag'); } };
global.window = { addEventListener: function () {} };
var sent = [];
global.api = async function (ep, m, b) {
  sent.push({ ep: ep, m: m, b: b });
  if (ep === '/api/global-backup-diff') return { id: 'bk1', same: false, lines: [], truncated: false, configChanges: [], confirmId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90' };
  if (ep === '/api/global-restore') {
    if (!b || !b.confirmId || !/^[0-9a-f]{32}$/.test(b.confirmId)) { var e = new Error('diff-required'); throw e; }
    return { ok: true };
  }
  return {};
};
global.showConfirm = async function () { return true; };
global.showNotify = async function () {};
global.safeFocus = function () {};
global.esc = function (s) { return s; };
global.setMsg = function () {};
global.refreshGlobal = async function () {};
global.applySearchFilter = function () {};
eval(sliceFn('var globalRestoreConfirms', 'document.getElementById("btnGlobalBackups")').split('let lastGlobalPlan').join('var lastGlobalPlan').split('let globalTargetsDirty').join('var globalTargetsDirty').split('let globalIntervalDirty').join('var globalIntervalDirty'));
(async function () {
  await globalBackupDiff('bk1');
  var r = await globalBackupRestore('bk1');
  var rc = sent.filter(function (s) { return s.ep === '/api/global-restore'; })[0];
  ok(rc && rc.b && rc.b.confirmId === 'a1b2c3d4e5f60718293a4b5c6d7e8f90', 'R8-1 harness restore sends stored confirmId');
  sent = [];
  var refused = false;
  try { await globalBackupRestore('bk-no-diff'); } catch (e) { refused = /diff-required/.test(e.message); }
  ok(refused || sent.filter(function (s) { return s.ep === '/api/global-restore'; }).length === 0, 'R8-1 harness restore without diff refused');
  if (fails.length) process.exit(1);
  console.log('ALL R8 UI CHECKS PASSED');
})().catch(function (e) { console.log('FAIL: harness ' + (e && e.stack || e)); process.exit(1); });
'@ -Encoding UTF8
    & $nodeExe $uijs (Join-Path $devAuto 'Dashboard-Server.ps1')
    Assert ($LASTEXITCODE -eq 0) 'R8-1 node harness diff->restore confirmId wiring'
  }

  # R8-2: sync + backup-ROOT parent chains inspected (all callers, not helper only).
  $syncSrc = Get-Content -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Raw -Encoding UTF8
  $syncAsserts = ([regex]::Matches($syncSrc, 'Global-AssertNoLinkChain').Count)
  Assert (($syncAsserts -ge 4)) 'R8-2 sync asserts parent chains on read/backup/generate paths'
  # production Sync parent junction: fake home with junctioned .codex parent must not read through
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $ext8 = Join-Path $scratch 'ext8'
  New-Item -ItemType Directory -Force -Path $ext8 | Out-Null
  Set-Content -LiteralPath (Join-Path $ext8 'AGENTS.md') 'ext8-marker' -Encoding Ascii
  $codexDir = Join-Path $fakeHome '.codex'
  $codexKeep = Get-Content -LiteralPath (Join-Path $codexDir 'AGENTS.md') -Raw -Encoding UTF8
  Remove-Item -LiteralPath $codexDir -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $codexDir + '" "' + $ext8 + '"') | Out-Null
  $gc8 = Get-GlobalContent $fakeHome 'tok'
  $cx8 = @($gc8.files | Where-Object { [string]$_.target -ceq 'codexcli' })
  Assert ((($cx8[0].exists -eq $false) -and ($null -eq $cx8[0].head))) 'R8-2 junctioned parent reads as absent'
  $bk8bad = $true
  try { New-GlobalBackup $auto $fakeHome @('codexcli') | Out-Null; $bk8bad = $false } catch { $bk8bad = $true }
  Assert ($bk8bad) 'R8-2 backup refuses junctioned parent'
  # backup ROOT parent chain: backups dir itself junctioned must fail closed (see below)
  & $cmdExe /c ('rmdir "' + $codexDir + '"') | Out-Null
  New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
  Set-Content -LiteralPath (Join-Path $codexDir 'AGENTS.md') $codexKeep -Encoding UTF8
  # backup ROOT parent chain in isolation (separate auto dir so existing rows never matter).
  $autoRoot = Join-Path $scratch 'autoRoot'
  New-Item -ItemType Directory -Force -Path $autoRoot | Out-Null
  Set-GlobalTargets $autoRoot @('codexcli') | Out-Null
  $broot2 = Join-Path $autoRoot 'backups'
  New-Item -ItemType Directory -Force -Path $broot2 | Out-Null
  $brootKeep = Join-Path $scratch 'broot-keep'
  New-Item -ItemType Directory -Force -Path $brootKeep | Out-Null
  Remove-Item -LiteralPath $broot2 -Force
  & $cmdExe /c ('mklink /J "' + $broot2 + '" "' + $brootKeep + '"') | Out-Null
  $brootJunctioned = (Get-Item -LiteralPath $broot2 -Force).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
  Assert ($brootJunctioned) 'R8-2 backup-root junction fixture ready'
  $bkRootBad = $true
  try { New-GlobalBackup $autoRoot $fakeHome @('codexcli') | Out-Null; $bkRootBad = $false } catch { $bkRootBad = $true }
  Assert ($bkRootBad) 'R8-2 backup refuses junctioned backup ROOT'
  $lst = @()
  try { $lst = @(Get-GlobalBackupList $autoRoot) } catch { $lst = @('threw') }
  Assert ((($lst.Count -eq 0) -or (($lst.Count -eq 1) -and ($lst[0] -ceq 'threw')))) 'R8-2 backup list fail-closed on junctioned ROOT'
  & $cmdExe /c ('rmdir "' + $broot2 + '"') | Out-Null
  New-Item -ItemType Directory -Force -Path $broot2 | Out-Null
  Assert (((Get-Content -LiteralPath (Join-Path $ext8 'AGENTS.md') -Raw).Contains('ext8-marker'))) 'R8-2 external dir untouched'

  # R8-3: immutable manifest target set + entries; duplicates/extra irrespective present=false rejected.
  $bkR3 = New-GlobalBackup $auto $fakeHome @('codexcli')
  $idR3 = Split-Path $bkR3 -Leaf
  $bdR3 = Get-GlobalBackupDiff $auto $idR3 $fakeHome
  $cfR3 = [string]$bdR3.confirmId
  Assert (($cfR3 -match '^[0-9a-f]{32}$')) 'R8-3 diff issues confirm'
  # tamper: add unapproved delete entry (opencode present=false) to manifest copy
  $mfPathR3 = Join-Path $bkR3 'manifest.json'
  $mfR3 = Get-Content -LiteralPath $mfPathR3 -Raw -Encoding UTF8 | ConvertFrom-Json
  $mfR3.files += [pscustomobject]@{ target = 'opencode'; kind = 'agents'; rel = ''; present = $false; hash = '' }
  $mfR3 | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $mfPathR3 -Encoding UTF8
  $tamperRefused = $true
  try { Restore-GlobalBackup $auto $idR3 $true $fakeHome $cfR3 | Out-Null; $tamperRefused = $false } catch { $tamperRefused = $true }
  Assert ($tamperRefused) 'R8-3 added present=false entry refused (end-to-end)'
  # confirm binding itself must reject the injected entry (direct unit check)
  $bdR3x = Get-GlobalBackupDiff $auto (Split-Path (New-GlobalBackup $auto $fakeHome @('codexcli')) -Leaf) $fakeHome
  $cfR3x = [string]$bdR3x.confirmId
  $bkR3x = Join-Path (Join-Path $auto 'backups') $bdR3x.id
  $mfX = Get-Content -LiteralPath (Join-Path $bkR3x 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $mfX.files += [pscustomobject]@{ target = 'opencode'; kind = 'agents'; rel = ''; present = $false; hash = '' }
  $mfX | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath (Join-Path $bkR3x 'manifest.json') -Encoding UTF8
  $cfDirect = $true
  try { Test-GlobalRestoreConfirm $auto $bdR3x.id $fakeHome $cfR3x | Out-Null; $cfDirect = $false } catch { $cfDirect = $true }
  Assert ($cfDirect) 'R8-3 confirm binding rejects added present=false entry'
  # tamper2: duplicate first entry
  $bkR3b = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  $idR3b = Split-Path $bkR3b -Leaf
  $bdR3b = Get-GlobalBackupDiff $auto $idR3b $fakeHome
  $cfR3b = [string]$bdR3b.confirmId
  $mfPathR3b = Join-Path $bkR3b 'manifest.json'
  $mfR3b = Get-Content -LiteralPath $mfPathR3b -Raw -Encoding UTF8 | ConvertFrom-Json
  $mfR3b.files += $mfR3b.files[0]
  $mfR3b | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $mfPathR3b -Encoding UTF8
  $dupRefused = $true
  try { Test-GlobalRestoreConfirm $auto $idR3b $fakeHome $cfR3b | Out-Null; $dupRefused = $false } catch { $dupRefused = $true }
  Assert ($dupRefused) 'R8-3 confirm binding rejects duplicated manifest entry'
  # tamper3: target set alteration (drop opencode from targets but keep files)
  $bkR3c = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  $idR3c = Split-Path $bkR3c -Leaf
  $bdR3c = Get-GlobalBackupDiff $auto $idR3c $fakeHome
  $cfR3c = [string]$bdR3c.confirmId
  $mfPathR3c = Join-Path $bkR3c 'manifest.json'
  $mfR3c = Get-Content -LiteralPath $mfPathR3c -Raw -Encoding UTF8 | ConvertFrom-Json
  $mfR3c.targets = @('codexcli')
  $mfR3c | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $mfPathR3c -Encoding UTF8
  $tsetRefused = $true
  try { Test-GlobalRestoreConfirm $auto $idR3c $fakeHome $cfR3c | Out-Null; $tsetRefused = $false } catch { $tsetRefused = $true }
  Assert ($tsetRefused) 'R8-3 confirm binding rejects target-set alteration'
  # unknown kind must fail closed with NO confirmId
  $bkR3d = New-GlobalBackup $auto $fakeHome @('codexcli')
  $idR3d = Split-Path $bkR3d -Leaf
  $mfPathR3d = Join-Path $bkR3d 'manifest.json'
  $mfR3d = Get-Content -LiteralPath $mfPathR3d -Raw -Encoding UTF8 | ConvertFrom-Json
  $mfR3d.files += [pscustomobject]@{ target = 'codexcli'; kind = 'mystery'; rel = 'x'; present = $true; hash = 'abc' }
  $mfR3d | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $mfPathR3d -Encoding UTF8
  $unkNoConfirm = $false
  try { Get-GlobalBackupDiff $auto $idR3d $fakeHome | Out-Null } catch { $unkNoConfirm = $true }
  Assert ($unkNoConfirm) 'R8-3 unknown manifest item fails closed with no confirm'

  # R8-4: diff byte/hash same snapshot under lock (displayed A cannot restore as B).
  # ensure home files exist (earlier malicious-restore repro may have deleted one pre-fix).
  if (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -PathType Leaf)) { Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R8' -Encoding Ascii }
  if (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') -PathType Leaf)) { Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R8' -Encoding Ascii }
  $bkR4 = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  $idR4 = Split-Path $bkR4 -Leaf
  $bdR4 = Get-GlobalBackupDiff $auto $idR4 $fakeHome
  $cfR4 = [string]$bdR4.confirmId
  # current changes after diff: stale confirm must refuse (already in R7) AND
  # confirm must bind exact displayed bytes: simulate B drift then check hash pin
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-B-after-display-R8' -Encoding Ascii
  $stale4 = $true
  try { Restore-GlobalBackup $auto $idR4 $true $fakeHome $cfR4 | Out-Null; $stale4 = $false } catch { $stale4 = $true }
  Assert ($stale4) 'R8-4 displayed-A confirm cannot restore drifted-B current'
  # dashboard diff route must hold the global lock (checked inside the route segment,
  # not anywhere in the file: a lock held by another route does not close the window).
  $holdsLock = $false
  try {
    $di = $srvSrc.IndexOf("if (`$path -eq '/api/global-backup-diff')")
    if ($di -lt 0) { $di = $srvSrc.LastIndexOf('/api/global-backup-diff') }
    $segLock = $srvSrc.Substring($di, [Math]::Min(1500, $srvSrc.Length - $di))
    $holdsLock = $segLock.Contains('Open-GlobalSyncLock')
  } catch { $holdsLock = $false }
  Assert ($holdsLock) 'R8-4 diff route holds global lock'
  # diff must single-read: display bytes hash equals pinned confirm hash
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R8' -Encoding Ascii
  $bdR4b = Get-GlobalBackupDiff $auto $idR4 $fakeHome
  Assert (([string]$bdR4b.confirmId -match '^[0-9a-f]{32}$')) 'R8-4 fresh diff re-issues confirm'

  # R8-5: size bounds before allocation + during reads; overlarge fails closed no confirm/apply.
  if (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') -PathType Leaf)) { Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R8' -Encoding Ascii }
  $bigFile = Join-Path $fakeHome '.config\opencode\AGENTS.md'
  $bigKeep = Get-Content -LiteralPath $bigFile -Raw -Encoding UTF8
  $fsB = [System.IO.File]::Create($bigFile)
  try { $chunk = New-Object byte[] 65536; for ($iB = 0; $iB -lt 40; $iB++) { $fsB.Write($chunk, 0, $chunk.Length) } } finally { $fsB.Close() }
  $overNoConfirm = $false
  try { Get-GlobalBackupDiff $auto $idR4 $fakeHome | Out-Null } catch { $overNoConfirm = $true }
  Assert ($overNoConfirm) 'R8-5 overlarge current fails closed with no confirm'
  # bounded helper exists and caps allocation
  $hasBounded = ((Get-Command Global-ReadBoundedBytes -ErrorAction SilentlyContinue) -ne $null)
  Assert ($hasBounded) 'R8-5 bounded byte reader exists'
  if ($hasBounded) {
    $rb = Global-ReadBoundedBytes $bigFile 1048576
    Assert (([bool]$rb.truncated -eq $true)) 'R8-5 bounded read flags truncation without full alloc'
    Assert ((([byte[]]$rb.bytes).Length -le 1048576)) 'R8-5 bounded read caps bytes'
  }
  # restore of overlarge backup bytes refused: manifest hash updated to match the
  # enlarged bytes (streaming hash, no full alloc) so only the size gate can refuse.
  $bkOver = New-GlobalBackup $auto $fakeHome @('codexcli')
  $idOver = Split-Path $bkOver -Leaf
  $mfOver = Get-Content -LiteralPath (Join-Path $bkOver 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $relOver = [string](@($mfOver.files | Where-Object { [string]$_.kind -ceq 'agents' })[0].rel)
  if ($relOver -ne '') {
    $fsO = [System.IO.File]::Create((Join-Path $bkOver $relOver))
    try { $chunk = New-Object byte[] 65536; for ($iO = 0; $iO -lt 40; $iO++) { $fsO.Write($chunk, 0, $chunk.Length) } } finally { $fsO.Close() }
    $bigH = (Get-FileHash -LiteralPath (Join-Path $bkOver $relOver) -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($fe in @($mfOver.files)) { if ([string]$fe.kind -ceq 'agents') { $fe.hash = $bigH } }
    $mfOver | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath (Join-Path $bkOver 'manifest.json') -Encoding UTF8
  }
  Set-Content -LiteralPath $bigFile $bigKeep -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R8' -Encoding Ascii
  $overRestoreRefused = $false
  try {
    $bdOver = Get-GlobalBackupDiff $auto $idOver $fakeHome
    Restore-GlobalBackup $auto $idOver $true $fakeHome ([string]$bdOver.confirmId) | Out-Null
  } catch { $overRestoreRefused = $true }
  Assert ($overRestoreRefused) 'R8-5 overlarge backup bytes never restored'
  # sync source uses bounded reads (no raw ReadAllText on home paths)
  $rawReads = ([regex]::Matches($syncSrc, '\[System\.IO\.File\]::ReadAllText\(\[string\]\$ContentPaths').Count)
  Assert (($rawReads -eq 0)) 'R8-5 sync has no unbounded home reads'

  Assert (((Get-Location).Path) -eq $initCwd) 'R8 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'R8 only own GUID scratch removed'
}
finally {
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL R8 REVIEW CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
