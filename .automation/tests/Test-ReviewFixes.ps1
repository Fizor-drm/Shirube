# Test-ReviewFixes.ps1 - regression tests for independent-review findings R1-R11.
# Scratch-only. Never touches real registry, repos, tasks, or deployed AppData.
# Scheduler writes are never tested live (mocked shadows only); Global task never touched.
# Conventions mirror Test-Management15.ps1 (dot-source order, own GUID scratch, owned cleanup).
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
$devAuto = Split-Path -Parent $PSScriptRoot
$srvPath = Join-Path $devAuto 'Dashboard-Server.ps1'
$mgmtPath = Join-Path $devAuto 'Project-Management.ps1'
$watchPath = Join-Path $devAuto 'Watch-Sync.ps1'
$syncPath = Join-Path $devAuto 'Sync-ProjectRules.ps1'
try {
  . $srvPath
  . $mgmtPath
  Assert ((Get-Command Restore-MgmtBackup -ErrorAction SilentlyContinue) -ne $null) 'R0 module dot-sourced (no listen)'

  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'ReviewFixesTest'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  New-Item -ItemType Directory -Force -Path $auto | Out-Null
  $curDir = Join-Path $scratch 'project-common-preview\.rulesync\rules\.curated'
  New-Item -ItemType Directory -Force -Path $curDir | Out-Null
  $commonBody = "shared-line-one`nshared-line-two"
  Set-Content -LiteralPath (Join-Path $curDir 'project.md') ("---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`n" + $commonBody) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $scratch 'project-common-preview\rulesync.jsonc') '{"targets":["codexcli","opencode"]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[]' -Encoding Ascii
  $env:DASHBOARD_AUTODIR = $auto

  function New-Repo([string]$Name) {
    $r = Join-Path $script:scratch $Name
    New-Item -ItemType Directory -Force -Path $r | Out-Null
    return $r
  }

  # R4: stable internal name + separate Unicode displayName.
  $repoR4 = New-Repo 'R4Repo'
  Write-RegistryAtomicLocked $auto @([pscustomobject]@{ name = 'R4'; path = $repoR4 })
  Assert ((Get-MgmtDisplayName @((Get-Registry $auto))[0]) -ceq 'R4') 'R4 missing displayName defaults to name'
  Rename-MgmtProject $auto 'R4' '日本語表示' | Out-Null
  $eR4 = @((Get-Registry $auto))[0]
  Assert (([string]$eR4.name -ceq 'R4')) 'R4 internal name stable after rename'
  Assert (([string]$eR4.displayName -ceq '日本語表示')) 'R4 displayName set (Unicode preserved)'
  $rBad = $true
  try { Rename-MgmtProject $auto 'R4' '   '; $rBad = $false } catch { $rBad = $true }
  Assert ($rBad) 'R4 empty display refused'
  $repoOther = New-Repo 'R4Other'
  Write-RegistryAtomicLocked $auto @(@((Get-Registry $auto)) + [pscustomobject]@{ name = 'Other'; path = $repoOther })
  Rename-MgmtProject $auto 'Other' '別表示' | Out-Null
  $rDup = $true
  try { Rename-MgmtProject $auto 'R4' '別表示'; $rDup = $false } catch { $rDup = ($_.Exception.Message.Contains('競合')) }
  Assert ($rDup) 'R4 duplicate display refused'
  # Registry rewrites preserve displayName.
  Set-MgmtEnabled $auto 'R4' $false
  Assert (([string](@((Get-Registry $auto)) | Where-Object { [string]$_.name -ceq 'R4' })[0].displayName -ceq '日本語表示')) 'R4 display survives enabled toggle'
  Set-MgmtEnabled $auto 'R4' $true
  $repoR4b = New-Repo 'R4MoveDst'
  Move-MgmtProjectPath $auto 'R4' $repoR4b
  $eR4m = @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'R4' })[0]
  Assert (([string]$eR4m.displayName -ceq '日本語表示') -and ($eR4m.path -ceq $repoR4b)) 'R4 display survives path move'
  Move-MgmtProjectPath $auto 'R4' $repoR4
  # Import backup stays associated by internal name across rename; restore works.
  $repoImp = New-Repo 'R4Imp'
  Set-Content -LiteralPath (Join-Path $repoImp 'AGENTS.md') ($commonBody + "`nimp-unique-R4") -Encoding Ascii
  $apprR4 = New-MgmtImportApproval $auto $repoImp
  $impR4 = Register-MgmtImport $auto $repoImp $null $true $apprR4
  Rename-MgmtProject $auto ([string]$impR4.name) '取込表示' | Out-Null
  $blR4 = @(Get-MgmtBackupList $auto ([string]$impR4.name))
  Assert (($blR4.Count -ge 1) -and ($blR4[0].name -ceq ([string]$impR4.name))) 'R4 backup stays on internal name after rename'
  $rsR4 = Restore-MgmtBackup $auto $blR4[0].id $true
  Assert (($rsR4.ok) -and ((Get-Content -LiteralPath (Join-Path $repoImp 'AGENTS.md') -Raw) -match 'imp-unique-R4')) 'R4 restore works after rename'
  # Old-name reuse with a different path must not receive the old backup.
  $repoHijack = New-Repo 'R4Hijack'
  $regHijack = @(@((Get-Registry $auto)) | Where-Object { [string]$_.name -cne ([string]$impR4.name) })
  $regHijack += [pscustomobject]@{ name = ([string]$impR4.name); path = $repoHijack; displayName = '別物' }
  Write-RegistryAtomicLocked $auto $regHijack
  $rsHijack = $true
  try { Restore-MgmtBackup $auto $blR4[0].id $true | Out-Null; $rsHijack = $false } catch { $rsHijack = $true }
  Assert ($rsHijack) 'R4 old-name reuse with different path refused'
  Assert (-not ((Get-Content -LiteralPath (Join-Path $repoHijack 'AGENTS.md') -Raw -ErrorAction SilentlyContinue) -match 'imp-unique-R4')) 'R4 hijack repo untouched'
  # Export/import roundtrip preserves displayName.
  $expR4 = Get-MgmtExport $auto
  $expRow = @($expR4.projects | Where-Object { [string]$_.name -ceq 'R4' })[0]
  Assert (([string]$expRow.displayName -ceq '日本語表示')) 'R4 export carries displayName'
  $auto2 = Join-Path $scratch 'auto2'
  New-Item -ItemType Directory -Force -Path $auto2 | Out-Null
  Set-Content -LiteralPath (Join-Path $auto2 'projects.json') '[]' -Encoding Ascii
  $impR4b = Import-MgmtRegistry $auto2 @{ schemaVersion = 1; projects = @(@{ name = 'R4'; path = $repoR4; displayName = '日本語表示' }) } $true
  Assert (($impR4b.added -eq 1) -and ([string](@((Get-Registry $auto2))[0].displayName) -ceq '日本語表示')) 'R4 import preserves displayName'

  # R3: missing-file and delete paths must also refuse junctioned parents (mklink /J needs no privilege).
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $extA = New-Repo 'R3ExtA'
  $repoJ = New-Repo 'R3Junc'
  Set-Content -LiteralPath (Join-Path $repoJ 'AGENTS.md') ($commonBody + "`njunc-unique-R3A") -Encoding Ascii
  & $cmdExe /c ('mklink /J "' + (Join-Path $repoJ '.rulesync') + '" "' + $extA + '"') | Out-Null
  Assert ((Test-Reparse (Join-Path $repoJ '.rulesync'))) 'R3 junction fixture ready'
  $jImp = $true
  $apprRJ = New-MgmtImportApproval $auto $repoJ
  try { Register-MgmtImport $auto $repoJ $null $true $apprRJ | Out-Null; $jImp = $false } catch { $jImp = $true }
  Assert ($jImp) 'R3 import refuses junctioned parent when local file is missing'
  Assert ((@(Get-ChildItem -LiteralPath $extA -Force -ErrorAction SilentlyContinue)).Count -eq 0) 'R3 external dir untouched by refused import'
  Assert ((@((Get-Registry $auto) | Where-Object { (Get-NormPath ([string]$_.path)) -eq (Get-NormPath $repoJ) })).Count -eq 0) 'R3 refused import registers nothing'
  & $cmdExe /c ('rmdir "' + (Join-Path $repoJ '.rulesync') + '"') | Out-Null
  # Restore must refuse when the local parent is a junction (backup has local file).
  $repoRL = New-Repo 'R3Restore'
  Set-Content -LiteralPath (Join-Path $repoRL 'AGENTS.md') ($commonBody + "`nrl-unique-R3B") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoRL '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoRL '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nrl-local-R3B") -Encoding UTF8
  $apprRL = New-MgmtImportApproval $auto $repoRL
  $impRL = Register-MgmtImport $auto $repoRL $null $true $apprRL
  $blRL = @(Get-MgmtBackupList $auto ([string]$impRL.name))
  $extB = New-Repo 'R3ExtB'
  Remove-Item -LiteralPath (Join-Path $repoRL '.rulesync') -Recurse -Force
  & $cmdExe /c ('mklink /J "' + (Join-Path $repoRL '.rulesync') + '" "' + $extB + '"') | Out-Null
  $jRs = $true
  try { Restore-MgmtBackup $auto $blRL[0].id $true | Out-Null; $jRs = $false } catch { $jRs = $true }
  Assert ($jRs) 'R3 restore refuses junctioned local parent'
  Assert ((@(Get-ChildItem -LiteralPath $extB -Force -ErrorAction SilentlyContinue)).Count -eq 0) 'R3 external dir untouched by refused restore'
  Assert ((Get-Content -LiteralPath (Join-Path $repoRL 'AGENTS.md') -Raw) -match 'rl-unique-R3B') 'R3 repo AGENTS unchanged by refused restore'
  & $cmdExe /c ('rmdir "' + (Join-Path $repoRL '.rulesync') + '"') | Out-Null
  # Delete branch: manifest says no local, current local sits under a junction.
  $repoRD = New-Repo 'R3Del'
  Set-Content -LiteralPath (Join-Path $repoRD 'AGENTS.md') ($commonBody + "`nrd-unique-R3C") -Encoding Ascii
  $apprRD = New-MgmtImportApproval $auto $repoRD
  $impRD = Register-MgmtImport $auto $repoRD $null $true $apprRD
  $blRD = @(Get-MgmtBackupList $auto ([string]$impRD.name))
  # Import backup for a repo without prior local already records localPresent=false.
  $extC = New-Repo 'R3ExtC'
  $realRules = Join-Path $repoRD '.rulesync\rules'
  $keepLocal = Get-Content -LiteralPath (Join-Path $realRules 'project-local.md') -Raw -Encoding UTF8
  Remove-Item -LiteralPath (Join-Path $repoRD '.rulesync') -Recurse -Force
  New-Item -ItemType Directory -Force -Path $extC | Out-Null
  Set-Content -LiteralPath (Join-Path $extC 'project-local.md') $keepLocal -Encoding UTF8
  & $cmdExe /c ('mklink /J "' + (Join-Path $repoRD '.rulesync') + '" "' + $extC + '"') | Out-Null
  $jDel = $true
  try { Restore-MgmtBackup $auto $blRD[0].id $true | Out-Null; $jDel = $false } catch { $jDel = $true }
  Assert ($jDel) 'R3 restore delete-branch refuses junctioned parent'
  Assert (Test-Path -LiteralPath (Join-Path $extC 'project-local.md') -PathType Leaf) 'R3 external local not deleted'
  & $cmdExe /c ('rmdir "' + (Join-Path $repoRD '.rulesync') + '"') | Out-Null

  # R11: mixed selection across both tables unions (shared by sync + plan callers).
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  Assert (($null -ne $nodeExe) -and ($nodeExe -ne '')) 'R11 node available for DOM check'
  if ($nodeExe) {
    $r11js = Join-Path $scratch 'r11-union.js'
    Set-Content -LiteralPath $r11js @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
var m = src.match(/function selectedNames\(\)\{[\s\S]*?\n\}/);
if (!m) { console.log('FAIL: selectedNames not found'); process.exit(1); }
eval(m[0]);
function box(v, checked) { return { value: v, checked: checked }; }
var statusBoxes = [box('A', true)];
var rowsBoxes = [box('B', true)];
global.document = { querySelectorAll: function (sel) {
  if (sel === '#statusRows input.selbox') return statusBoxes;
  if (sel === '#rows input.selbox') return rowsBoxes;
  return [];
} };
ok(selectedNames().slice().sort().join(',') === 'A,B', 'R11 mixed selection unions both tables');
statusBoxes = []; rowsBoxes = [box('C', true)];
ok(selectedNames().join(',') === 'C', 'R11 rows-only selection kept');
statusBoxes = [box('D', false)]; rowsBoxes = [box('E', true)];
ok(selectedNames().join(',') === 'E', 'R11 unchecked boxes ignored');
statusBoxes = [box('constructor', true)]; rowsBoxes = [box('toString', true)];
ok(selectedNames().slice().sort().join(',') === 'constructor,toString', 'R11 prototype ids kept');
statusBoxes = [box('constructor', true), box('constructor', true)]; rowsBoxes = [];
ok(selectedNames().join(',') === 'constructor', 'R11 prototype ids deduped');
if (fails.length) process.exit(1);
console.log('ALL R11 CHECKS PASSED');
'@ -Encoding UTF8
    & $nodeExe $r11js $srvPath
    Assert ($LASTEXITCODE -eq 0) 'R11 union selection via node harness'
  }

  # R9: modal input element must be removed on close (sequential modals accumulate otherwise).
  if ($nodeExe) {
    $r9js = Join-Path $scratch 'r9-modal.js'
    Set-Content -LiteralPath $r9js @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
function sliceFn(startMark, endMark) {
  var a = src.indexOf(startMark);
  var b = src.indexOf(endMark, a);
  if (a < 0 || b < 0) throw new Error('slice miss: ' + startMark);
  return src.substring(a, b);
}
function mkEl(tag) {
  var el = { tagName: (tag || 'div').toUpperCase(), type: '', value: '', textContent: '', hidden: false,
    disabled: false, isConnected: true, className: '', children: [], onclick: null, parentNode: null,
    dataset: {}, style: {},
    appendChild: function (c) { c.parentNode = this; this.children.push(c); return c; },
    insertBefore: function (c, ref) { c.parentNode = this; var i = this.children.indexOf(ref); if (i < 0) this.children.push(c); else this.children.splice(i, 0, c); return c; },
    removeChild: function (c) { var i = this.children.indexOf(c); if (i >= 0) this.children.splice(i, 1); c.parentNode = null; return c; },
    contains: function (x) { return this.children.indexOf(x) >= 0; },
    focus: function () { global.document.activeElement = this; } };
  return el;
}
var ovl = mkEl('div'); var mTitle = mkEl('div'); var mMsg = mkEl('div'); var mBtns = mkEl('div');
var mBox = mkEl('div'); mBox.appendChild(mMsg); mBox.appendChild(mBtns);
Object.defineProperty(mBtns, 'innerHTML', { get: function () { return this._h || ''; }, set: function (v) { this._h = v; this.children = []; } });
var byId = { ovl: ovl, mTitle: mTitle, mMsg: mMsg, mBtns: mBtns };
global.document = {
  activeElement: null,
  getElementById: function (id) { return byId[id] || null; },
  createElement: function (t) { return mkEl(t); },
  querySelector: function () { return null; },
  addEventListener: function () {}, removeEventListener: function () {}
};
var lastFocus = null, modalRestoreTarget = null, modalQueue = Promise.resolve();
function L(s) { return s; }
eval(sliceFn('function isShown(el)', '\nfunction focusVisible'));
eval(sliceFn('function focusVisible', '\nasync function api('));
eval(sliceFn('function safeFocus(el)', '\nfunction showModal('));
eval(sliceFn('function showModal(', '\nfunction showModalInput'));
eval(sliceFn('function showModalInput', '\nfunction showModalInner'));
eval(sliceFn('function showModalInner', '\nfunction showNotify'));
eval(sliceFn('function showConfirm', '\nlet lastPreview'));
function inputs() { return mBox.children.filter(function (c) { return c.tagName === 'INPUT'; }); }
function buttons() { return mBtns.children.filter(function (c) { return c.tagName === 'BUTTON'; }); }
function flush() { return new Promise(function (r) { setTimeout(r, 20); }); }
(async function () {
  var p1 = showModalInput('名称変更', 'msg', '旧名');
  await flush();
  ok(inputs().length === 1, 'R9 input modal shows one input');
  var b1 = buttons();
  ok(b1.length === 2, 'R9 input modal has two buttons');
  b1[0].onclick();
  var v1 = await p1;
  ok(v1 === '旧名', 'R9 decision returns input value');
  ok(inputs().length === 0, 'R9 input removed after decision');
  var p2 = showConfirm('解除の確認', 'msg', '解除する', 'やめる');
  await flush();
  ok(inputs().length === 0, 'R9 confirm modal has no leaked input');
  var b2 = buttons();
  b2[0].onclick();
  await p2;
  ok(inputs().length === 0, 'R9 still clean after confirm');
  var p3 = showModalInput('移動先', 'msg', 'C:\\X');
  await flush();
  ok(inputs().length === 1, 'R9 second input modal shows one input');
  var b3 = buttons();
  b3[1].onclick();
  var v3 = await p3;
  ok(v3 === null, 'R9 cancel returns null');
  ok(inputs().length === 0, 'R9 input removed after cancel');
  if (fails.length) process.exit(1);
  console.log('ALL R9 CHECKS PASSED');
})().catch(function (e) { console.log('FAIL: R9 harness error ' + (e && e.message)); process.exit(1); });
'@ -Encoding UTF8
    & $nodeExe $r9js $srvPath
    Assert ($LASTEXITCODE -eq 0) 'R9 modal cleanup via node harness'
  }

  # R5: batch register validates all items before any single publish (live server).
  $env:DASHBOARD_PORT = '18798'
  $srvR5 = $null
  try {
    Copy-Item -LiteralPath $watchPath -Destination (Join-Path $auto 'Watch-Sync.ps1') -Force
    Set-Content -LiteralPath (Join-Path $auto 'Sync-ProjectRules.ps1') 'exit 0' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $auto 'Run-ProjectRules.vbs') "' dummy launcher" -Encoding Ascii
    $srvR5 = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $srvPath -WindowStyle Hidden -PassThru
    $okR5 = $false
    for ($iR5 = 0; $iR5 -lt 40; $iR5++) {
      Start-Sleep -Milliseconds 500
      try {
        $hr5 = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18798/health'
        if ($hr5.StatusCode -eq 200) { $okR5 = $true; break }
      } catch {}
      if ($srvR5.HasExited) { break }
    }
    Assert ($okR5) 'R5 scratch server health'
    Assert (-not $srvR5.HasExited) 'R5 scratch server is ours (port bound)'
    if ($okR5 -and (-not $srvR5.HasExited)) {
      $tokR5 = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $hdrsR5 = @{ 'X-Dashboard-Token' = $tokR5 }
      function PostR5([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $hdrsR5 -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18798' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      $rb1 = Join-Path $scratch 'BatchR5a'; $rb2 = Join-Path $scratch 'BatchR5b'
      New-Item -ItemType Directory -Force -Path $rb1, $rb2 | Out-Null
      $bpR5 = PostR5 '/api/preview-batch' @{ paths = @($rb1, $rb2) }
      Assert (($bpR5.results.Count -eq 2) -and ($bpR5.results[0].ok -eq $true) -and ($bpR5.results[1].ok -eq $true)) 'R5 batch preview ok x2'
      $beforeR5 = @((Get-Registry $auto) | ForEach-Object { [string]$_.name })
      $mixItems = @(@{ previewId = $bpR5.results[0].previewId; path = $bpR5.results[0].path }, @{ previewId = ('0' * 32); path = $bpR5.results[1].path })
      $mixCode = 0; $mixRefused = $false
      try { PostR5 '/api/register-batch' @{ items = $mixItems; confirm = $true } | Out-Null } catch { $mixCode = $_.Exception.Response.StatusCode.value__; $mixRefused = ($mixCode -eq 400) }
      Assert ($mixRefused) 'R5 mixed valid+invalid batch refused with 400'
      $afterR5 = @((Get-Registry $auto) | ForEach-Object { [string]$_.name })
      Assert ((@(Compare-Object $beforeR5 $afterR5)).Count -eq 0) 'R5 refused batch leaves registry invariant'
      $bpR5b = PostR5 '/api/preview-batch' @{ paths = @($rb1, $rb2) }
      Assert (($bpR5b.results.Count -eq 2) -and ($bpR5b.results[0].ok -eq $true) -and ($bpR5b.results[1].ok -eq $true)) 'R5 re-preview ok x2'
      $okItems = @(@{ previewId = $bpR5b.results[0].previewId; path = $bpR5b.results[0].path }, @{ previewId = $bpR5b.results[1].previewId; path = $bpR5b.results[1].path })
      $okR5r = PostR5 '/api/register-batch' @{ items = $okItems; confirm = $true }
      Assert (($okR5r.ok -eq $true) -and ($okR5r.registered.Count -eq 2)) 'R5 all-valid batch registers both'
      # R7-batch: same basename in one batch reserves Repo, Repo-2 and commits both.
      $sb1 = Join-Path $scratch 'SameA\Repo'; $sb2 = Join-Path $scratch 'SameB\Repo'
      New-Item -ItemType Directory -Force -Path $sb1, $sb2 | Out-Null
      $bpSame = PostR5 '/api/preview-batch' @{ paths = @($sb1, $sb2) }
      Assert (($bpSame.results.Count -eq 2) -and ($bpSame.results[0].ok -eq $true) -and ($bpSame.results[1].ok -eq $true)) 'R7 same-basename preview ok x2'
      Assert (($bpSame.results[0].name -cne $bpSame.results[1].name)) 'R7 same-basename preview reserves distinct names'
      $sameItems = @(@{ previewId = $bpSame.results[0].previewId; path = $bpSame.results[0].path }, @{ previewId = $bpSame.results[1].previewId; path = $bpSame.results[1].path })
      $sameR = PostR5 '/api/register-batch' @{ items = $sameItems; confirm = $true }
      Assert (($sameR.ok -eq $true) -and ($sameR.registered.Count -eq 2) -and ($sameR.registered[0] -cne $sameR.registered[1])) 'R7 same-basename batch commits both exact names'
    }
  } finally {
    try { if ($srvR5 -and (-not $srvR5.HasExited)) { Stop-Process -Id $srvR5.Id -Force } } catch {}
    Start-Sleep -Milliseconds 500
    try {
      $aliveR5 = $false
      try { $aliveR5 = (-not (Get-Process -Id $srvR5.Id -ErrorAction Stop).HasExited) } catch { $aliveR5 = $false }
      Assert (-not $aliveR5) 'R5 scratch server stopped'
    } catch {}
  }

  # R14 (r4 #4): import transcription pinned at preview; common change after
  # preview refuses register (live server, own scratch port).
  $autoF4 = Join-Path $scratch 'f4\auto'
  $prevF4 = Join-Path $scratch 'f4\project-common-preview'
  New-Item -ItemType Directory -Force -Path $autoF4 | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $prevF4 '.rulesync\rules\.curated') | Out-Null
  Set-Content -LiteralPath (Join-Path $autoF4 'projects.json') '[]' -Encoding Ascii
  Copy-Item -LiteralPath $watchPath -Destination (Join-Path $autoF4 'Watch-Sync.ps1') -Force
  Set-Content -LiteralPath (Join-Path $autoF4 'Sync-ProjectRules.ps1') 'exit 0' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $autoF4 'Run-ProjectRules.vbs') "' dummy launcher" -Encoding Ascii
  $curF4 = Join-Path $prevF4 '.rulesync\rules\.curated\project.md'
  Set-Content -LiteralPath (Join-Path $prevF4 'rulesync.jsonc') '{"targets":["codexcli","opencode"]}' -Encoding Ascii
  Set-Content -LiteralPath $curF4 ("---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-old-marker") -Encoding UTF8
  $repoF4 = Join-Path $scratch 'ImpRepoF4'
  New-Item -ItemType Directory -Force -Path $repoF4 | Out-Null
  Set-Content -LiteralPath (Join-Path $repoF4 'AGENTS.md') ("shared-old-marker`n`nunique-rule-approved`n") -Encoding Ascii
  $prevAutoSave = $env:DASHBOARD_AUTODIR
  $env:DASHBOARD_AUTODIR = $autoF4
  $env:DASHBOARD_PORT = '18791'
  $srvF4 = $null
  try {
    $srvF4 = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $srvPath -WindowStyle Hidden -PassThru
    $okF4 = $false
    for ($iF4 = 0; $iF4 -lt 40; $iF4++) {
      Start-Sleep -Milliseconds 500
      try {
        $hF4 = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18791/health'
        if ($hF4.StatusCode -eq 200) { $okF4 = $true; break }
      } catch {}
      if ($srvF4.HasExited) { break }
    }
    Assert ($okF4) 'R14 import scratch server health'
    if ($okF4 -and (-not $srvF4.HasExited)) {
      $tokF4 = (Get-Content -LiteralPath (Join-Path $autoF4 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $hdrsF4 = @{ 'X-Dashboard-Token' = $tokF4 }
      function PostF4([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $hdrsF4 -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18791' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      $pvF4 = PostF4 '/api/import-preview' @{ path = $repoF4 }
      Assert ((($pvF4.ok -eq $true) -and ([string]$pvF4.transcription).Contains('unique-rule-approved'))) 'R14 import preview pins approved transcription'
      Set-Content -LiteralPath $curF4 ((Get-Content -LiteralPath $curF4 -Raw -Encoding UTF8) + "`nshared-new-drift") -Encoding UTF8
      $staleCode = 0; $staleRefused = $false
      try { PostF4 '/api/register' @{ previewId = $pvF4.previewId; path = $repoF4; confirm = $true; importConfirm = $true } | Out-Null } catch { $staleCode = $_.Exception.Response.StatusCode.value__; $staleRefused = ($staleCode -eq 400) }
      Assert ($staleRefused) 'R14 stale import after common change refused with 400'
      Assert (((Get-Content -LiteralPath (Join-Path $autoF4 'projects.json') -Raw -Encoding UTF8).Trim() -ceq '[]')) 'R14 refused import leaves registry invariant'
      Assert ((-not (Test-Path -LiteralPath (Join-Path $repoF4 '.rulesync\rules\project-local.md') -PathType Leaf))) 'R14 refused import writes no local file'
      $pvF4b = PostF4 '/api/import-preview' @{ path = $repoF4 }
      $okF4r = PostF4 '/api/register' @{ previewId = $pvF4b.previewId; path = $repoF4; confirm = $true; importConfirm = $true }
      Assert (($okF4r.ok -eq $true)) 'R14 fresh preview registers exact content'
      $curF4 = Join-Path $prevF4 '.rulesync\rules\.curated\project.md'
      $curBakF4 = Get-Content -LiteralPath $curF4 -Raw -Encoding UTF8
      $repoF4b = Join-Path $scratch 'ImpRepoF4b'
      New-Item -ItemType Directory -Force -Path $repoF4b | Out-Null
      Set-Content -LiteralPath (Join-Path $repoF4b 'AGENTS.md') ($curBakF4 + "`n`nf4b-unique") -Encoding Ascii
      Remove-Item -LiteralPath $curF4 -Force
      $missCode = 0; $missRefused = $false
      try { PostF4 '/api/import-preview' @{ path = $repoF4b } | Out-Null } catch { $missCode = $_.Exception.Response.StatusCode.value__; $missRefused = ($missCode -eq 400) }
      Assert ($missRefused) 'R16 missing common import-preview refused with 400'
      Set-Content -LiteralPath $curF4 $curBakF4 -Encoding UTF8
    }
  } finally {
    try { if ($srvF4 -and (-not $srvF4.HasExited)) { Stop-Process -Id $srvF4.Id -Force } } catch {}
    Start-Sleep -Milliseconds 500
    try {
      $aliveF4 = $false
      try { $aliveF4 = (-not (Get-Process -Id $srvF4.Id -ErrorAction Stop).HasExited) } catch { $aliveF4 = $false }
      Assert (-not $aliveF4) 'R14 scratch server stopped'
    } catch {}
    $env:DASHBOARD_AUTODIR = $prevAutoSave
  }

  # R8: backup diff carries local content diff, not just existence.
  $repoD8 = New-Repo 'R8Diff'
  Set-Content -LiteralPath (Join-Path $repoD8 'AGENTS.md') ($commonBody + "`nd8-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoD8 '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoD8 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nd8-local-v1") -Encoding UTF8
  $apprD8 = New-MgmtImportApproval $auto $repoD8
  $impD8 = Register-MgmtImport $auto $repoD8 $null $true $apprD8
  $blD8 = @(Get-MgmtBackupList $auto ([string]$impD8.name))
  Set-Content -LiteralPath (Join-Path $repoD8 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nd8-local-v2") -Encoding UTF8
  $bdD8 = Get-MgmtBackupDiff $auto $blD8[0].id
  Assert (($bdD8.same -eq $false)) 'R8 local-only change is not same'
  Assert (($bdD8.localSame -eq $false) -and (@($bdD8.localLines).Count -ge 1)) 'R8 local diff lines returned'
  Assert ((@($bdD8.localLines | Where-Object { $_.t -ceq '-' -and ([string]$_.text -match 'd8-local-v1') })).Count -ge 1) 'R8 local diff shows removed line'
  Assert ((@($bdD8.localLines | Where-Object { $_.t -ceq '+' -and ([string]$_.text -match 'd8-local-v2') })).Count -ge 1) 'R8 local diff shows added line'
  Assert (($bdD8.backupHasLocal -eq $true) -and ($bdD8.currentHasLocal -eq $true)) 'R8 local existence flags kept'
  # R8 UI: both file sections render with content.
  if ($nodeExe) {
    $r8js = Join-Path $scratch 'r8-render.js'
    Set-Content -LiteralPath $r8js @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
function sliceFn(startMark, endMark) {
  var a = src.indexOf(startMark);
  var b = src.indexOf(endMark, a);
  if (a < 0 || b < 0) throw new Error('slice miss: ' + startMark);
  return src.substring(a, b);
}
function mkEl(tag) {
  return { tagName: (tag || 'div').toUpperCase(), type: '', value: '', textContent: '', hidden: false,
    className: '', children: [], onclick: null, parentNode: null,
    appendChild: function (c) { c.parentNode = this; this.children.push(c); return c; } };
}
global.document = { createElement: function (t) { return mkEl(t); },
  createDocumentFragment: function () { return { children: [], appendChild: function (c) { this.children.push(c); return c; } }; } };
function L(s) { return s; }
eval(sliceFn('function renderBackupDiff(', '\nfunction renderDiffFrag('));
eval(sliceFn('function renderDiffFrag(', '\nfunction diffLinesLocal('));
function texts(el) {
  var out = [];
  (function walk(n) { if (n.textContent) out.push(n.textContent); (n.children || []).forEach(walk); })(el);
  return out.join('\n');
}
var da = mkEl('div'); da.innerHTML = '';
var d = { name: 'P', same: false, truncated: false, lines: [], backupHasAgents: true, currentHasAgents: true,
  localLines: [{ t: '-', text: 'old-line' }, { t: '+', text: 'new-line' }], backupHasLocal: true, currentHasLocal: true };
renderBackupDiff(da, d);
var t = texts(da);
ok(t.indexOf('差分あり') >= 0, 'R8 render shows overall change');
ok(t.indexOf('localSource') >= 0, 'R8 render has local section');
ok(t.indexOf('new-line') >= 0 && t.indexOf('old-line') >= 0, 'R8 render shows local lines');
ok(t.indexOf('AGENTS.md') >= 0, 'R8 render has agents section');
var da2 = mkEl('div'); da2.innerHTML = '';
var d2 = { name: 'Q', same: true, truncated: false, lines: [], backupHasAgents: true, currentHasAgents: true,
  localLines: [], backupHasLocal: true, currentHasLocal: true };
renderBackupDiff(da2, d2);
ok(texts(da2).indexOf('差分なし') >= 0, 'R8 render shows no-change');
var bSearch = src.split('\n').filter(function (l) { return l.indexOf('dataset.search') >= 0 && l.indexOf('e.id') >= 0; });
ok(bSearch.length === 1 && bSearch[0].indexOf('displayName') >= 0, 'R9 backup search includes displayName');
if (fails.length) process.exit(1);
console.log('ALL R8JS CHECKS PASSED');
'@ -Encoding UTF8
    & $nodeExe $r8js $srvPath
    Assert ($LASTEXITCODE -eq 0) 'R8 backup diff render via node harness'
  }

  # R7: local-rule save backups are restorable (local-only, AGENTS untouched).
  $repoL7 = New-Repo 'R7Local'
  Set-Content -LiteralPath (Join-Path $repoL7 'AGENTS.md') ($commonBody + "`nl7-agents-marker") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoL7 '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoL7 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nl7-local-v1") -Encoding UTF8
  $apprL7 = New-MgmtImportApproval $auto $repoL7
  $impL7 = Register-MgmtImport $auto $repoL7 $null $true $apprL7
  $lrL7 = Get-MgmtLocalRule $auto ([string]$impL7.name)
  Save-MgmtLocalRule $auto ([string]$impL7.name) ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nl7-local-v2") $lrL7.hash | Out-Null
  $blL7 = @(Get-MgmtBackupList $auto ([string]$impL7.name) | Where-Object { [string]$_.id -like '*-localrule*' })
  Assert (($blL7.Count -ge 1)) 'R7 local save appears in backup list'
  Set-Content -LiteralPath (Join-Path $repoL7 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nl7-local-v3-drifted") -Encoding UTF8
  $rsL7 = $null; $rsL7err = ''
  try { $rsL7 = Restore-MgmtBackup $auto $blL7[0].id $true } catch { $rsL7err = $_.Exception.Message }
  Assert (($null -ne $rsL7) -and ($rsL7.ok -eq $true)) 'R7 local-only restore succeeds'
  Assert ((Get-Content -LiteralPath (Join-Path $repoL7 '.rulesync\rules\project-local.md') -Raw) -match 'l7-local-v1') 'R7 local-only restore brings back pre-save content'
  Assert ((Get-Content -LiteralPath (Join-Path $repoL7 'AGENTS.md') -Raw) -match 'l7-agents-marker') 'R7 local-only restore leaves AGENTS untouched'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impL7.name) })[0]) -eq $false) 'R7 restore pauses project'
  Set-MgmtEnabled $auto ([string]$impL7.name) $true
  # Legacy backup without manifest is listable but never restored (safe refusal).
  $legDir = Join-Path $auto ('backups\' + $blL7[0].id)
  if (Test-Path -LiteralPath (Join-Path $legDir 'manifest.json')) { Remove-Item -LiteralPath (Join-Path $legDir 'manifest.json') -Force }
  Set-Content -LiteralPath (Join-Path $repoL7 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nl7-local-v4") -Encoding UTF8
  $rsLegBad = $true; $rsLegErr = ''
  try { Restore-MgmtBackup $auto $blL7[0].id $true | Out-Null; $rsLegBad = $false } catch { $rsLegErr = $_.Exception.Message }
  Assert (($rsLegBad -and ($rsLegErr.Contains('信頼できません')))) 'R7 legacy backup without manifest refused'
  Assert ((Get-Content -LiteralPath (Join-Path $repoL7 '.rulesync\rules\project-local.md') -Raw) -match 'l7-local-v4') 'R7 refused legacy restore leaves current files'
  Assert ((Get-Content -LiteralPath (Join-Path $repoL7 'AGENTS.md') -Raw) -match 'l7-agents-marker') 'R7 refused legacy restore leaves AGENTS'
  # R4-legacy: manifest-less full backup into same-name reuse is refused (no overwrite).
  $repoLeg = New-Repo 'RLegacy'
  Set-Content -LiteralPath (Join-Path $repoLeg 'AGENTS.md') ($commonBody + "`nleg-unique-R4L") -Encoding Ascii
  $apprLeg = New-MgmtImportApproval $auto $repoLeg
  $impLeg = Register-MgmtImport $auto $repoLeg $null $true $apprLeg
  $blLeg = @(Get-MgmtBackupList $auto ([string]$impLeg.name))
  Remove-Item -LiteralPath (Join-Path $auto ('backups\' + $blLeg[0].id + '\manifest.json')) -Force
  $repoLeg2 = New-Repo 'RLegacy2'
  $regLeg = @(@((Get-Registry $auto)) | Where-Object { [string]$_.name -cne ([string]$impLeg.name) })
  $regLeg += [pscustomobject]@{ name = ([string]$impLeg.name); path = $repoLeg2; displayName = '別物2' }
  Write-RegistryAtomicLocked $auto $regLeg
  $rsLeg2Bad = $true
  try { Restore-MgmtBackup $auto $blLeg[0].id $true | Out-Null; $rsLeg2Bad = $false } catch { $rsLeg2Bad = $true }
  Assert ($rsLeg2Bad) 'R4 legacy reuse without manifest refused'
  Assert (-not (Test-Path -LiteralPath (Join-Path $repoLeg2 'AGENTS.md') -PathType Leaf)) 'R4 legacy reuse target untouched'
  Assert ((Get-Content -LiteralPath (Join-Path $repoLeg 'AGENTS.md') -Raw) -match 'leg-unique-R4L') 'R4 legacy source repo untouched'
  # rawRepo-2 style: trailing number must never resolve to another internal id.
  $repoRaw = New-Repo 'RawRepoHome'
  Set-Content -LiteralPath (Join-Path $repoRaw 'AGENTS.md') ($commonBody + "`nraw-own-content") -Encoding Ascii
  Write-RegistryAtomicLocked $auto @(@((Get-Registry $auto)) | Where-Object { [string]$_.name -cne ([string]$impLeg.name) })
  $regRaw = @(Get-Registry $auto) + [pscustomobject]@{ name = 'rawRepo'; path = $repoRaw; displayName = 'rawRepo' }
  Write-RegistryAtomicLocked $auto $regRaw
  $rawDir = Join-Path $auto 'backups\20200101-010101-rawRepo-2'
  New-Item -ItemType Directory -Force -Path $rawDir | Out-Null
  Set-Content -LiteralPath (Join-Path $rawDir 'AGENTS.md') 'foreign-agents-content' -Encoding Ascii
  $rsRawBad = $true
  try { Restore-MgmtBackup $auto '20200101-010101-rawRepo-2' $true | Out-Null; $rsRawBad = $false } catch { $rsRawBad = $true }
  Assert ($rsRawBad) 'R4 numeric-suffix backup without manifest refused'
  Assert ((Get-Content -LiteralPath (Join-Path $repoRaw 'AGENTS.md') -Raw) -match 'raw-own-content') 'R4 numeric-suffix target untouched'
  Assert (([string](Get-MgmtBackupName '20200101-010101-rawRepo-2' $null) -ceq '')) 'R6 unknown suffix backup has no guessed name'
  Assert (([string](Get-MgmtBackupName '20200101-010101-Repo-2' $null) -ceq '')) 'R6 unknown Repo-2 backup has no guessed name'
  $blRawFiltered = @(Get-MgmtBackupList $auto 'rawRepo' | Where-Object { [string]$_.id -ceq '20200101-010101-rawRepo-2' })
  Assert ((@($blRawFiltered).Count -eq 0)) 'R6 unknown backup not attributed to rawRepo list'
  $diffRawBad = $true; $diffRawErr = ''
  try { Get-MgmtBackupDiff $auto '20200101-010101-rawRepo-2' | Out-Null; $diffRawBad = $false } catch { $diffRawErr = $_.Exception.Message }
  Assert (($diffRawBad)) 'R6 unknown backup diff refused'
  Assert (-not ((Get-Content -LiteralPath (Join-Path $repoRaw 'AGENTS.md') -Raw) -match 'foreign-agents-content')) 'R6 refused diff leaves repo untouched'

  # R2: restore is transactional (pause first, rollback, stay paused on rollback failure).
  $repoT2 = New-Repo 'R2Tx'
  Set-Content -LiteralPath (Join-Path $repoT2 'AGENTS.md') ($commonBody + "`nt2-agents-orig") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoT2 '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoT2 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nt2-local-orig") -Encoding UTF8
  $apprT2 = New-MgmtImportApproval $auto $repoT2
  $impT2 = Register-MgmtImport $auto $repoT2 $null $true $apprT2
  $blT2 = @(Get-MgmtBackupList $auto ([string]$impT2.name))
  Set-Content -LiteralPath (Join-Path $repoT2 'AGENTS.md') 't2-agents-drifted' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $repoT2 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nt2-local-drifted") -Encoding UTF8
  # Restore overridden module functions by re-dot-sourcing at script scope.
  # Write-RegistryAtomicLocked lives in Dashboard-Server.ps1, so both files
  # are reloaded in order. (Dot-sourcing inside a function would restore only
  # in that function scope, so the reload statements are inline, not a function.)
  $SrvModule = $srvPath
  $MgmtModule = $mgmtPath
  # (a) registry failure at pause: nothing mutates.
  function Write-RegistryAtomicLocked([string]$AutoDir, [array]$Entries) { throw 'injected-reg-fail' }
  $t2a = $true
  try { Restore-MgmtBackup $auto $blT2[0].id $true | Out-Null; $t2a = $false } catch { $t2a = $true }
  Assert ($t2a) 'R2 registry failure refuses restore'
  Assert ((Get-Content -LiteralPath (Join-Path $repoT2 'AGENTS.md') -Raw) -match 't2-agents-drifted') 'R2 registry failure leaves AGENTS'
  Assert ((Get-Content -LiteralPath (Join-Path $repoT2 '.rulesync\rules\project-local.md') -Raw) -match 't2-local-drifted') 'R2 registry failure leaves local'
  . $SrvModule
  . $MgmtModule
  # (b) second-copy failure: rollback restores pre-state, stays paused.
  # Verified publishes go through the narrow helper: shelter Copy #1-2 still
  # use Copy-MgmtVerified; restore/rollback publishes are helper calls H1+.
  # Mode 'once' fails H1 (nothing applied: clean abort).
  # Mode 'rb' fails H2 (apply local) and H3 (rollback AGENTS): partial + failed rollback.
  $script:copyFailMode = 'once'
  $script:expCalls = 0
  $origExpT2 = (Get-Command Copy-MgmtExpectedBytes).ScriptBlock
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    $script:expCalls++
    if (($script:copyFailMode -ceq 'once' -and $script:expCalls -eq 1) -or ($script:copyFailMode -ceq 'rb' -and $script:expCalls -ge 2)) { throw 'injected-copy-fail' }
    & $script:origExpT2 $Src $Dst $ExpectedHash $What
  }
  $script:origExpT2 = $origExpT2
  $t2b = $true
  try { Restore-MgmtBackup $auto $blT2[0].id $true | Out-Null; $t2b = $false } catch { $t2b = ($_.Exception.Message.Contains('injected-copy-fail')) }
  Assert ($t2b) 'R2 copy failure aborts restore'
  Assert ((Get-Content -LiteralPath (Join-Path $repoT2 'AGENTS.md') -Raw) -match 't2-agents-drifted') 'R2 rollback brings back AGENTS'
  Assert ((Get-Content -LiteralPath (Join-Path $repoT2 '.rulesync\rules\project-local.md') -Raw) -match 't2-local-drifted') 'R2 rollback brings back local'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impT2.name) })[0]) -eq $false) 'R2 failed restore stays paused'
  . $SrvModule
  . $MgmtModule
  Set-MgmtEnabled $auto ([string]$impT2.name) $true
  # (c) rollback failure: stays paused and reports rollback error.
  $script:copyFailMode = 'rb'
  $script:expCalls = 0
  $origExpT2c = (Get-Command Copy-MgmtExpectedBytes).ScriptBlock
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    $script:expCalls++
    if (($script:copyFailMode -ceq 'once' -and $script:expCalls -eq 1) -or ($script:copyFailMode -ceq 'rb' -and $script:expCalls -ge 2)) { throw 'injected-copy-fail' }
    & $script:origExpT2c $Src $Dst $ExpectedHash $What
  }
  $script:origExpT2c = $origExpT2c
  $t2c = $true
  try { Restore-MgmtBackup $auto $blT2[0].id $true | Out-Null; $t2c = $false } catch { $t2c = ($_.Exception.Message.Contains('巻戻し')) }
  Assert ($t2c) 'R2 rollback failure reports rollback error'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impT2.name) })[0]) -eq $false) 'R2 rollback failure stays paused'
  . $SrvModule
  . $MgmtModule
  # (d) prevalidation refusal changes nothing, not even pause state.
  $repoGone = New-Repo 'R2Gone'
  Set-Content -LiteralPath (Join-Path $repoGone 'AGENTS.md') ($commonBody + "`ngone-unique") -Encoding Ascii
  $apprGone = New-MgmtImportApproval $auto $repoGone
  $impGone = Register-MgmtImport $auto $repoGone $null $true $apprGone
  $blGone = @(Get-MgmtBackupList $auto ([string]$impGone.name))
  Remove-Item -LiteralPath $repoGone -Recurse -Force
  $t2d = $true
  try { Restore-MgmtBackup $auto $blGone[0].id $true | Out-Null; $t2d = $false } catch { $t2d = ($_.Exception.Message.Contains('存在しません')) }
  Assert ($t2d) 'R2 missing repo refuses restore'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impGone.name) })[0]) -eq $true) 'R2 prevalidation refusal keeps enabled'
  # (e) post-copy failure: the failed copy itself is journaled and rolled back.
  Set-Content -LiteralPath (Join-Path $repoT2 'AGENTS.md') 't2-agents-drifted' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $repoT2 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nt2-local-drifted") -Encoding UTF8
  Set-MgmtEnabled $auto ([string]$impT2.name) $true
  $script:copyFailMode = 'postonce'
  $script:expCalls = 0
  $origExpT2e = (Get-Command Copy-MgmtExpectedBytes).ScriptBlock
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    $script:expCalls++
    if (($script:copyFailMode -ceq 'postonce') -and ($script:expCalls -eq 1)) {
      [System.IO.File]::WriteAllBytes($Dst, [System.Text.Encoding]::UTF8.GetBytes('PARTIAL-RESTORE'))
      throw 'injected-postcopy-fail'
    }
    & $script:origExpT2e $Src $Dst $ExpectedHash $What
  }
  $script:origExpT2e = $origExpT2e
  $t2e = $true
  try { Restore-MgmtBackup $auto $blT2[0].id $true | Out-Null; $t2e = $false } catch { $t2e = ($_.Exception.Message.Contains('injected-postcopy-fail')) }
  Assert ($t2e) 'R2 post-copy failure aborts restore'
  Assert ((Get-Content -LiteralPath (Join-Path $repoT2 'AGENTS.md') -Raw) -match 't2-agents-drifted') 'R2 post-copy failure rolls back AGENTS'
  Assert ((Get-Content -LiteralPath (Join-Path $repoT2 '.rulesync\rules\project-local.md') -Raw) -match 't2-local-drifted') 'R2 post-copy failure rolls back local'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impT2.name) })[0]) -eq $false) 'R2 post-copy failure stays paused'
  . $SrvModule
  . $MgmtModule

  # R6: failed import rolls back the local edit so retry sees original state.
  $repoI6a = New-Repo 'R6Keep'
  Set-Content -LiteralPath (Join-Path $repoI6a 'AGENTS.md') ($commonBody + "`ni6a-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoI6a '.rulesync\rules') | Out-Null
  $origI6a = "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`ni6a-orig-local"
  Set-Content -LiteralPath (Join-Path $repoI6a '.rulesync\rules\project-local.md') $origI6a -Encoding UTF8
  function Write-RegistryAtomicLocked([string]$AutoDir, [array]$Entries) { throw 'injected-reg-fail' }
  $i6a = $true
  $apprI6a = New-MgmtImportApproval $auto $repoI6a
  try { Register-MgmtImport $auto $repoI6a $null $true $apprI6a | Out-Null; $i6a = $false } catch { $i6a = $true }
  Assert ($i6a) 'R6 registry failure refuses import'
  $afterI6a = Get-Content -LiteralPath (Join-Path $repoI6a '.rulesync\rules\project-local.md') -Raw -Encoding UTF8
  Assert ((($afterI6a -match 'i6a-orig-local') -and (-not ($afterI6a -match 'i6a-unique')))) 'R6 existing local restored on publish failure'
  Assert ((@((Get-Registry $auto) | Where-Object { (Get-NormPath ([string]$_.path)) -eq (Get-NormPath $repoI6a) })).Count -eq 0) 'R6 failed import registers nothing'
  . $SrvModule
  . $MgmtModule
  $repoI6b = New-Repo 'R6New'
  Set-Content -LiteralPath (Join-Path $repoI6b 'AGENTS.md') ($commonBody + "`ni6b-unique") -Encoding Ascii
  function Write-RegistryAtomicLocked([string]$AutoDir, [array]$Entries) { throw 'injected-reg-fail' }
  $i6b = $true
  $apprI6b = New-MgmtImportApproval $auto $repoI6b
  try { Register-MgmtImport $auto $repoI6b $null $true $apprI6b | Out-Null; $i6b = $false } catch { $i6b = $true }
  Assert ($i6b) 'R6 registry failure refuses import without prior local'
  Assert (-not (Test-Path -LiteralPath (Join-Path $repoI6b '.rulesync\rules\project-local.md') -PathType Leaf)) 'R6 created local removed on publish failure'
  . $SrvModule
  . $MgmtModule
  $reI6b = $null
  try { $reI6b = Register-MgmtImport $auto $repoI6b $null $true $apprI6b } catch {}
  Assert ((($null -ne $reI6b) -and ($reI6b.ok -eq $true)) -and ((Get-Content -LiteralPath (Join-Path $repoI6b '.rulesync\rules\project-local.md') -Raw) -match 'i6b-unique')) 'R6 retry after rollback succeeds with transcription'
  Assert ((@((Get-Registry $auto) | Where-Object { (Get-NormPath ([string]$_.path)) -eq (Get-NormPath $repoI6b) })).Count -eq 1) 'R6 retry registers entry'
  # (d) rollback failure itself is reported explicitly (not masked).
  $repoI6d = New-Repo 'R6RBFail'
  Set-Content -LiteralPath (Join-Path $repoI6d 'AGENTS.md') ($commonBody + "`ni6d-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoI6d '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoI6d '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`ni6d-orig") -Encoding UTF8
  $origTextWrite = (Get-Command Write-MgmtTextAtomic).ScriptBlock
  $script:textCallsRB = 0
  function Write-RegistryAtomicLocked([string]$AutoDir, [array]$Entries) { throw 'injected-reg-fail' }
  function Write-MgmtTextAtomic([string]$File, [string]$Text) {
    $script:textCallsRB++
    if ($script:textCallsRB -ge 2) { throw 'injected-text-fail' }
    & $script:origTextWrite $File $Text
  }
  $script:origTextWrite = $origTextWrite
  $i6d = $true; $i6dErr = ''
  $apprI6d = New-MgmtImportApproval $auto $repoI6d
  try { Register-MgmtImport $auto $repoI6d $null $true $apprI6d | Out-Null; $i6d = $false } catch { $i6dErr = $_.Exception.Message }
  Assert ((($i6d) -and ($i6dErr.Contains('巻戻し')))) 'R6 rollback failure reported explicitly'
  . $SrvModule
  . $MgmtModule
  # R17 (r7 #2): registry re-read failure after the local write still rolls
  # back, for both existing-local restore and new-local delete.
  $repoI6e = New-Repo 'R6RegRead'
  Set-Content -LiteralPath (Join-Path $repoI6e 'AGENTS.md') ($commonBody + "`ni6e-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoI6e '.rulesync\rules') | Out-Null
  $origI6e = "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`ni6e-orig-local"
  Set-Content -LiteralPath (Join-Path $repoI6e '.rulesync\rules\project-local.md') $origI6e -Encoding UTF8
  $apprI6e = New-MgmtImportApproval $auto $repoI6e
  $script:regReadCalls = 0
  $origGetReg6 = (Get-Command Get-Registry).ScriptBlock
  function Get-Registry([string]$AutoDir) {
    $script:regReadCalls++
    if ($script:regReadCalls -eq 4) { throw 'injected-registry-read-fail' }
    & $script:origGetReg6 $AutoDir
  }
  $script:origGetReg6 = $origGetReg6
  $i6e = $true; $i6eErr = ''
  try { Register-MgmtImport $auto $repoI6e $null $true $apprI6e | Out-Null; $i6e = $false } catch { $i6eErr = $_.Exception.Message }
  Assert ((($i6e) -and ($i6eErr.Contains('injected-registry-read-fail')))) 'R17 registry re-read failure refuses import'
  Assert ((((Get-Content -LiteralPath (Join-Path $repoI6e '.rulesync\rules\project-local.md') -Raw -Encoding UTF8) -match 'i6e-orig-local') -and (-not ((Get-Content -LiteralPath (Join-Path $repoI6e '.rulesync\rules\project-local.md') -Raw -Encoding UTF8) -match 'i6e-unique')))) 'R17 re-read failure restores existing local'
  Assert ((@((Get-Registry $auto) | Where-Object { (Get-NormPath ([string]$_.path)) -eq (Get-NormPath $repoI6e) })).Count -eq 0) 'R17 re-read failure registers nothing'
  . $SrvModule
  . $MgmtModule
  $repoI6f = New-Repo 'R6RegReadNew'
  Set-Content -LiteralPath (Join-Path $repoI6f 'AGENTS.md') ($commonBody + "`ni6f-unique") -Encoding Ascii
  $apprI6f = New-MgmtImportApproval $auto $repoI6f
  $script:regReadCalls = 0
  $origGetReg6b = (Get-Command Get-Registry).ScriptBlock
  function Get-Registry([string]$AutoDir) {
    $script:regReadCalls++
    if ($script:regReadCalls -eq 4) { throw 'injected-registry-read-fail' }
    & $script:origGetReg6b $AutoDir
  }
  $script:origGetReg6b = $origGetReg6b
  $i6f = $true
  try { Register-MgmtImport $auto $repoI6f $null $true $apprI6f | Out-Null; $i6f = $false } catch { $i6f = $true }
  Assert ($i6f) 'R17 re-read failure refuses new-local import'
  Assert (-not (Test-Path -LiteralPath (Join-Path $repoI6f '.rulesync\rules\project-local.md') -PathType Leaf)) 'R17 re-read failure deletes created local'
  Assert ((@((Get-Registry $auto) | Where-Object { (Get-NormPath ([string]$_.path)) -eq (Get-NormPath $repoI6f) })).Count -eq 0) 'R17 re-read failure registers nothing new'
  . $SrvModule
  . $MgmtModule

  # R10: export/import carries the Project sync interval (Global never touched).
  $script:mockSchedInterval = 'PT15M'
  $script:mockSchedCalls = @()
  $script:mockSchedGetCount = 0
  $script:mockSchedGetFailOn = @()
  # Configured name keeps this rollback test independent of personal settings.
  $script:projectTask = Get-MgmtProjectTaskName
  function Get-ScheduledTask { param([string]$TaskName)
    if ($TaskName -cne $script:projectTask) { throw 'task not found' }
    $script:mockSchedGetCount++
    if ($script:mockSchedGetFailOn -contains $script:mockSchedGetCount) { throw 'injected-get-fail' }
    $rep = New-Object PSObject -Property @{ Interval = $script:mockSchedInterval }
    $tr = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = $rep }
    return [pscustomobject]@{ Triggers = @($tr) }
  }
  function Set-ScheduledTask { param([string]$TaskName, $Trigger)
    $script:mockSchedCalls += [string]$TaskName
    if ($script:mockSchedThrow) { throw 'injected-sched-fail' }
    $newIv = [string]$Trigger[0].Repetition.Interval
    if ($script:mockSchedPostThrowCount -gt 0) {
      $script:mockSchedPostThrowCount--
      $script:mockSchedInterval = $newIv
      throw 'injected-sched-post-fail'
    }
    $script:mockSchedInterval = $newIv
  }
  try {
    $expI10 = Get-MgmtExport $auto
    Assert (($expI10.intervalMinutes -eq 15)) 'R10 export carries current interval'
    $pvI10 = Get-MgmtImportPreview $auto (@{ schemaVersion = 1; projects = @(); intervalMinutes = 30 })
    Assert ((($pvI10.interval.incoming -eq 30) -and ($pvI10.interval.willChange -eq $true))) 'R10 import preview assesses interval change'
    $pvI10b = Get-MgmtImportPreview $auto (@{ schemaVersion = 1; projects = @(); intervalMinutes = 3 })
    Assert ((@($pvI10b.invalid).Count -eq 1)) 'R10 invalid interval goes to invalid bucket'
    $pvI10c = Get-MgmtImportPreview $auto (@{ schemaVersion = 1; projects = @() })
    Assert (($pvI10c.interval.willChange -eq $false)) 'R10 missing interval is no-op'
    $autoI10 = Join-Path $scratch 'autoI10'
    New-Item -ItemType Directory -Force -Path $autoI10 | Out-Null
    Set-Content -LiteralPath (Join-Path $autoI10 'projects.json') '[]' -Encoding Ascii
    $repoI10 = New-Repo 'R10Imp'
    $imI10 = Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'R10x'; path = $repoI10 }); intervalMinutes = 30 }) $true
    Assert (($imI10.added -eq 1) -and ($script:mockSchedInterval -ceq 'PT30M')) 'R10 import applies interval to mocked scheduler'
    Assert ((@($script:mockSchedCalls | Where-Object { $_ -cne $script:projectTask })).Count -eq 0) 'R10 scheduler writes target Project task only'
    Assert ((Get-MgmtProjectInterval) -eq 30) 'R10 mocked scheduler roundtrip reads back'
    $callsBefore = @($script:mockSchedCalls).Count
    Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @() }) $true | Out-Null
    Assert ((@($script:mockSchedCalls).Count -eq $callsBefore)) 'R10 import without interval leaves scheduler alone'
    $gGuard = $true
    try { Set-MgmtProjectInterval 'Shirube Global Auto Sync' 30; $gGuard = $false } catch { $gGuard = ($_.Exception.Message.Contains('Project')) }
    Assert ($gGuard) 'R10 Global task interval change refused'
    $gLegacyGuard = $true
    try { Set-MgmtProjectInterval 'Rulesync Global Auto Sync' 30; $gLegacyGuard = $false } catch { $gLegacyGuard = ($_.Exception.Message.Contains('Project')) }
    Assert ($gLegacyGuard) 'R10 legacy Global task interval change refused'
    $script:mockSchedThrow = $true
    $repoI10b = New-Repo 'R10ImpB'
    $namesBefore = @((Get-Registry $auto) | ForEach-Object { [string]$_.name })
    $ivFail = $true; $ivErr = ''
    try { Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'R10y'; path = $repoI10b }); intervalMinutes = 45 }) $true | Out-Null; $ivFail = $false } catch { $ivErr = $_.Exception.Message }
    Assert (($ivFail -and ($ivErr.Contains('取り消しました')))) 'R10 scheduler failure refuses with rollback note'
    $namesAfter = @((Get-Registry $auto) | ForEach-Object { [string]$_.name })
    $ivDiff = Compare-Object $namesBefore $namesAfter
    Assert (($null -eq $ivDiff)) 'R10 scheduler failure rolls back added entry'
    Assert (($script:mockSchedInterval -ceq 'PT30M')) 'R10 failed interval apply keeps old value'
    $script:mockSchedThrow = $false
    # R10 post-write failure: scheduler changed then threw; import must
    # restore the previous interval + registry and verify (not leave PT45M).
    $script:mockSchedPostThrowCount = 1
    $repoI10c = New-Repo 'R10ImpC'
    $namesPre2 = @((Get-Registry $auto) | ForEach-Object { [string]$_.name })
    $ivFail2 = $true; $ivErr2 = ''
    try { Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'R10z'; path = $repoI10c }); intervalMinutes = 45 }) $true | Out-Null; $ivFail2 = $false } catch { $ivErr2 = $_.Exception.Message }
    Assert (($ivFail2 -and ($ivErr2.Contains('取り消しました')))) 'R10 post-write failure refuses with rollback note'
    Assert ((@(Compare-Object $namesPre2 @((Get-Registry $auto) | ForEach-Object { [string]$_.name })).Count -eq 0) -or ($null -eq (Compare-Object $namesPre2 @((Get-Registry $auto) | ForEach-Object { [string]$_.name })))) 'R10 post-write failure rolls back added entry'
    Assert (($script:mockSchedInterval -ceq 'PT30M')) 'R10 post-write failure restores previous interval'
    Assert (((Get-MgmtProjectInterval) -eq 30)) 'R10 restored interval reads back verified'
    # R10 restore-fail: interval rollback itself throws; must say so explicitly.
    $script:mockSchedPostThrowCount = 99
    $repoI10d = New-Repo 'R10ImpD'
    $ivFail3 = $true; $ivErr3 = ''
    try { Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'R10w'; path = $repoI10d }); intervalMinutes = 60 }) $true | Out-Null; $ivFail3 = $false } catch { $ivErr3 = $_.Exception.Message }
    Assert (($ivFail3 -and ($ivErr3.Contains('巻戻し')))) 'R10 interval rollback failure reported explicitly'
    $script:mockSchedPostThrowCount = 0
    $script:mockSchedInterval = 'PT30M'
    # R10 get-fail: re-read fails after a post-write; the known old value must
    # still be restored and verified (never silently skipped).
    $script:mockSchedGetCount = 0; $script:mockSchedGetFailOn = @(3)
    $script:mockSchedPostThrowCount = 1
    $repoI10e = New-Repo 'R10ImpE'
    $ivFail4 = $true; $ivErr4 = ''
    try { Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'R10v'; path = $repoI10e }); intervalMinutes = 45 }) $true | Out-Null; $ivFail4 = $false } catch { $ivErr4 = $_.Exception.Message }
    Assert (($ivFail4 -and ($ivErr4.Contains('元の間隔に戻しました')))) 'R10 reread-fail still restores with explicit note'
    Assert (($script:mockSchedInterval -ceq 'PT30M')) 'R10 reread-fail leaves restored value'
    $script:mockSchedGetCount = 0
    Assert (((Get-MgmtProjectInterval) -eq 30)) 'R10 reread-fail restore verified'
    # R10 verify-fail: restore writes but the verify read fails; the unknown
    # state must be explicit, never a plain retry claim.
    $script:mockSchedGetCount = 0; $script:mockSchedGetFailOn = @(3, 5)
    $script:mockSchedPostThrowCount = 1
    $repoI10f = New-Repo 'R10ImpF'
    $ivFail5 = $true; $ivErr5 = ''
    try { Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'R10u'; path = $repoI10f }); intervalMinutes = 50 }) $true | Out-Null; $ivFail5 = $false } catch { $ivErr5 = $_.Exception.Message }
    Assert (($ivFail5 -and ($ivErr5.Contains('確認できませんでした')))) 'R10 verify-fail reports verification unable'
    Assert (($script:mockSchedInterval -ceq 'PT30M')) 'R10 verify-fail still wrote restore value'
    $script:mockSchedGetFailOn = @(); $script:mockSchedPostThrowCount = 0
    $script:mockSchedInterval = 'PT30M'
  } finally {
    Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Set-ScheduledTask' -Force -ErrorAction SilentlyContinue
  }
  # R10 UI: interval-only import shows the button; all-skip shows neutral message.
  if ($nodeExe) {
    $r10js = Join-Path $scratch 'r10-button.js'
    Set-Content -LiteralPath $r10js @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
var m = src.match(/function canShowImportButton\(v\)\{[\s\S]*?\n\}/);
if (!m) { console.log('FAIL: canShowImportButton not found'); process.exit(1); }
eval(m[0]);
ok(canShowImportButton({ add: [{ name: 'A' }], conflict: [], invalid: [] }) === true, 'R10 button with adds');
ok(canShowImportButton({ add: [], conflict: [], invalid: [], interval: { willChange: true } }) === true, 'R10 button with interval-only change');
ok(canShowImportButton({ add: [], conflict: [], invalid: [] }) === false, 'R10 no button when nothing to do');
ok(canShowImportButton({ add: [{ name: 'A' }], conflict: [{ name: 'C' }], invalid: [] }) === false, 'R10 no button on conflict');
ok(canShowImportButton({ add: [], conflict: [], invalid: [{ name: 'x' }] }) === false, 'R10 no button on invalid');
ok(canShowImportButton(null) === false, 'R10 no button on null');
ok(src.indexOf('追加・変更がありません') >= 0, 'R10 neutral no-change message present');
if (fails.length) process.exit(1);
console.log('ALL R10UI CHECKS PASSED');
'@ -Encoding UTF8
    & $nodeExe $r10js $srvPath
    Assert ($LASTEXITCODE -eq 0) 'R10 import button via node harness'
  }

  # RJ: manifest+plan serialization completes bounded (no ETS blowup from file reads).
  $jsonRoot = Join-Path $scratch 'jsoncase'
  $autoJ = Join-Path $jsonRoot 'auto'
  $prevJ = Join-Path $jsonRoot 'project-common-preview'
  $binJ = Join-Path $jsonRoot 'bin'
  $projJA = Join-Path $jsonRoot 'projA'
  $projJB = Join-Path $jsonRoot 'projB'
  New-Item -ItemType Directory -Force -Path $autoJ, $binJ, $projJA, $projJB | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $prevJ '.rulesync\rules\.curated') | Out-Null
  Copy-Item -LiteralPath $syncPath -Destination (Join-Path $autoJ 'Sync-ProjectRules.ps1') -Force
  $commonJ = "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`njson-common-body"
  Set-Content -LiteralPath (Join-Path $prevJ 'rulesync.jsonc') '{"targets":["codexcli","opencode"],"features":["rules"],"outputRoots":["output"],"delete":false,"global":false,"sources":[]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $prevJ '.rulesync\rules\.curated\project.md') $commonJ -Encoding UTF8
  $regJ = '[{"name":"projA","path":"' + ($projJA -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($projJB -replace '\\', '\\') + '"}]'
  Set-Content -LiteralPath (Join-Path $autoJ 'projects.json') $regJ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $binJ 'npx.cmd') @'
@echo off
setlocal EnableDelayedExpansion
set D=%DUMMY_DIR%
echo npx %* [cwd=%CD%]>> "%D%\calls.log"
set /p N=<"%D%\counter.txt"
set F=%D%\exit_!N!.txt
set CODE=0
if exist "!F!" set /p CODE=<"!F!"
set OUTD=
set PREV=
for %%A in (%*) do (
  if "!PREV!"=="--output-roots" if not defined OUTD set OUTD=%%A
  set PREV=%%A
)
if defined OUTD echo Would write: !OUTD!\AGENTS.md
if defined OUTD if not exist "!OUTD!\AGENTS.md" echo dummy-generated> "!OUTD!\AGENTS.md"
set /a M=!N!+1
echo !M!>"%D%\counter.txt"
endlocal & exit /b %CODE%
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $binJ 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $projJA 'AGENTS.md') 'agents-A' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $projJB 'AGENTS.md') 'agents-B' -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $projJA '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $projJA '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-A") -Encoding Ascii
  $runnerJ = Join-Path $jsonRoot 'run-json.ps1'
  Set-Content -LiteralPath $runnerJ @'
$ErrorActionPreference = 'Stop'
$jr = Split-Path -Parent $MyInvocation.MyCommand.Path
$autoJ = Join-Path $jr 'auto'
$workJ = $jr
$env:PATH = ((Join-Path $workJ 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $workJ
$env:DUMMY_GH_EXIT = '0'
$env:DUMMY_GH_TOKEN = 'unused'
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
$env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $autoJ 'Sync-ProjectRules.ps1')
if ($args[0] -ceq 'preview') {
  $pp = Join-Path $autoJ 'dashboard.plan-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json'
  $pc = Invoke-ProjectSync -PreviewOnly -PlanPath $pp
  Set-Content -LiteralPath (Join-Path $workJ 'exitcode-prev.txt') ([string]$pc) -Encoding Ascii
  exit $pc
}
$fc = Invoke-ProjectSync
Set-Content -LiteralPath (Join-Path $workJ 'exitcode-full.txt') ([string]$fc) -Encoding Ascii
exit $fc
'@ -Encoding Ascii
  function Reset-JsonFixtures() {
    Set-Content -LiteralPath (Join-Path $jsonRoot 'counter.txt') '0' -Encoding Ascii
    $ex = @(0, 1, 0, 0, 0, 0)
    for ($i = 0; $i -lt $ex.Count; $i++) { Set-Content -LiteralPath (Join-Path $jsonRoot ("exit_$i.txt")) ([string]$ex[$i]) -Encoding Ascii }
    Set-Content -LiteralPath (Join-Path $projJA 'AGENTS.md') 'agents-A' -Encoding Ascii
  }
  function Reset-JsonPreviewFixtures() {
    # Preview calls: install(0), dry-run(0), preview-generate(0).
    Set-Content -LiteralPath (Join-Path $jsonRoot 'counter.txt') '0' -Encoding Ascii
    $ex = @(0, 0, 0)
    for ($i = 0; $i -lt $ex.Count; $i++) { Set-Content -LiteralPath (Join-Path $jsonRoot ("exit_$i.txt")) ([string]$ex[$i]) -Encoding Ascii }
    Get-ChildItem -LiteralPath $jsonRoot -Filter 'exit_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^exit_([3-9]|\d\d+)\.txt$' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $projJA 'AGENTS.md') 'agents-A' -Encoding Ascii
  }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Reset-JsonFixtures
  $rjFull = Start-Process -FilePath $psExe -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerJ -WindowStyle Hidden -RedirectStandardOutput (Join-Path $jsonRoot 'child-full.out') -RedirectStandardError (Join-Path $jsonRoot 'child-full.err') -PassThru
  $rjDone = $rjFull.WaitForExit(100000)
  try { if (-not $rjFull.HasExited) { Stop-Process -Id $rjFull.Id -Force } } catch {}
  $rjFullCode = ''
  try { $rjFullCode = (Get-Content -LiteralPath (Join-Path $jsonRoot 'exitcode-full.txt') -Raw -Encoding Ascii).Trim() } catch {}
  Assert (($rjDone -and ($rjFullCode -ceq '0'))) 'RJ full sync completes bounded (manifest JSON ok)'
  if (-not ($rjDone -and ($rjFullCode -ceq '0'))) {
    Write-Host '--- child-full.out ---'
    Get-Content -LiteralPath (Join-Path $jsonRoot 'child-full.out') -ErrorAction SilentlyContinue | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
  }
  $mfJ = @(Get-ChildItem -LiteralPath (Join-Path $autoJ 'backups') -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue)
  Assert (($mfJ.Count -ge 1)) 'RJ manifest written'
  $mfJ0 = $null
  if ($mfJ.Count -ge 1) { $mfJ0 = Get-Content -LiteralPath $mfJ[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert ((($null -ne $mfJ0) -and ([string]$mfJ0.commonText -ceq [string]([System.IO.File]::ReadAllText((Join-Path $prevJ '.rulesync\rules\.curated\project.md'), [System.Text.Encoding]::UTF8))))) 'RJ manifest commonText is plain content'
  Reset-JsonPreviewFixtures
  $rjPrev = Start-Process -FilePath $psExe -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerJ, 'preview' -WindowStyle Hidden -RedirectStandardOutput (Join-Path $jsonRoot 'child-prev.out') -RedirectStandardError (Join-Path $jsonRoot 'child-prev.err') -PassThru
  $rjPrevDone = $rjPrev.WaitForExit(100000)
  try { if (-not $rjPrev.HasExited) { Stop-Process -Id $rjPrev.Id -Force } } catch {}
  $rjPrevCode = ''
  try { $rjPrevCode = (Get-Content -LiteralPath (Join-Path $jsonRoot 'exitcode-prev.txt') -Raw -Encoding Ascii).Trim() } catch {}
  Assert (($rjPrevDone -and ($rjPrevCode -ceq '0'))) 'RJ preview completes bounded (plan JSON ok)'
  try { if (-not $rjPrev.HasExited) { Stop-Process -Id $rjPrev.Id -Force } } catch {}
  if (-not ($rjPrevDone -and ($rjPrevCode -ceq '0'))) {
    Write-Host '--- child-prev.out ---'
    Get-Content -LiteralPath (Join-Path $jsonRoot 'child-prev.out') -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
    Write-Host '--- child-prev.err ---'
    Get-Content -LiteralPath (Join-Path $jsonRoot 'child-prev.err') -ErrorAction SilentlyContinue | Select-Object -Last 5 | ForEach-Object { Write-Host $_ }
  }
  $planJ = Join-Path $autoJ 'dashboard.plan-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json'
  $plJ0 = $null
  if (Test-Path -LiteralPath $planJ -PathType Leaf) { $plJ0 = Get-Content -LiteralPath $planJ -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert ((($null -ne $plJ0) -and ([string]$plJ0.commonText -match 'json-common-body') -and (@($plJ0.projects).Count -eq 2))) 'RJ plan carries common text and projects'

  # R1: plan-bound apply validates every input (pure match + live builder).
  # Well-formed 64-hex pins (fictional short strings must not pass the gate).
  $hCommon = ('c' * 64); $hConfig = ('e' * 64); $hLocal = ('d' * 64)
  $planR1 = @{
    schemaVersion = 2
    commonSha = $hCommon; commonCommit = $null; commonText = 'ctext'; createdAt = 't'
    configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = @{ entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $true; localHash = $hLocal; agentsExists = $true; agentsHash = 'ah' }) }
    projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; commonSha = $hCommon; configHash = $hConfig })
  }
  $liveR1 = @{
    commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $true; localHash = $hLocal; agentsExists = $true; agentsHash = 'ah' })
  }
  Assert ((Test-MgmtPlanMatch $planR1 $liveR1 @('P')).ok -eq $true) 'R1 matching inputs verify ok'
  foreach ($mut in @(
    @{ k = 'commonSha'; v = 'zzz' }, @{ k = 'commonText'; v = 'zzz' },
    @{ k = 'configHash'; v = 'zzz' }, @{ k = 'targets'; v = 'zzz' }
  )) {
    $lm = @{ commonSha = $liveR1.commonSha; commonText = $liveR1.commonText; configHash = $liveR1.configHash; targets = $liveR1.targets; entries = $liveR1.entries }
    $lm[($mut.k)] = $mut.v
    Assert ((Test-MgmtPlanMatch $planR1 $lm @('P')).ok -eq $false) ('R1 top-level drift refused: ' + $mut.k)
  }
  foreach ($ek in @('path', 'enabled', 'localExists', 'agentsExists', 'localHash', 'agentsHash')) {
    $ee = @{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $true; localHash = $hLocal; agentsExists = $true; agentsHash = 'ah' }
    if ($ek -ceq 'path') { $ee.path = 'C:\R\Other' }
    elseif ($ek -ceq 'enabled') { $ee.enabled = $false }
    elseif ($ek -ceq 'localExists') { $ee.localExists = $false }
    elseif ($ek -ceq 'agentsExists') { $ee.agentsExists = $false }
    elseif ($ek -ceq 'localHash') { $ee.localHash = 'zz' }
    else { $ee.agentsHash = 'zz' }
    $lm2 = @{ commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'; entries = @($ee) }
    Assert ((Test-MgmtPlanMatch $planR1 $lm2 @('P')).ok -eq $false) ('R1 entry drift refused: ' + $ek)
  }
  Assert ((Test-MgmtPlanMatch $planR1 $liveR1 @('Nope')).ok -eq $false) 'R1 unknown requested name refused'
  $planOld = @{ schemaVersion = 1; projects = @() }
  Assert ((Test-MgmtPlanMatch $planOld $liveR1 @('P')).ok -eq $false) 'R1 plan without inputs refused as stale'
  $planFail = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; result = 'failed'; generatedText = '' })
  }
  Assert ((Test-MgmtPlanMatch $planFail $liveR1 @('P')).ok -eq $false) 'R1 failed plan output refused'
  $planMix = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\Old'; result = 'success'; generatedText = 'gen' })
  }
  Assert ((Test-MgmtPlanMatch $planMix $liveR1 @('P')).ok -eq $false) 'R15 mixed plan output/input path refused'
  # R17 (r7 #2/#3): schema v2 outputs must carry valid consumed hashes.
  $planNoLH = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planNoLH $liveR1 @('P')).ok -eq $false) 'R17 output missing localHash refused'
  $planNullLH = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $null; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planNullLH $liveR1 @('P')).ok -eq $false) 'R17 output null localHash refused'
  $planNoCommon = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planNoCommon $liveR1 @('P')).ok -eq $false) 'R17 output missing commonSha refused'
  $planNoCfg = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; commonSha = $hCommon })
  }
  Assert ((Test-MgmtPlanMatch $planNoCfg $liveR1 @('P')).ok -eq $false) 'R17 output missing configHash refused'
  # Explicit absent-local: null localHash allowed only with localExists=false.
  $liveNoLocal = @{
    commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $false; localHash = $null; agentsExists = $true; agentsHash = 'ah' })
  }
  $planNoLocal = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = @{ entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $false; localHash = $null; agentsExists = $true; agentsHash = 'ah' }) }
    projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $null; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planNoLocal $liveNoLocal @('P')).ok -eq $true) 'R17 explicit absent-local null hash allowed'
  $liveUnknownLoc = @{
    commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; agentsExists = $true; agentsHash = 'ah' })
  }
  $planUnknownLoc = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = @{ entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; agentsExists = $true; agentsHash = 'ah' }) }
    projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $null; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planUnknownLoc $liveUnknownLoc @('P')).ok -eq $false) 'R17 unknown-presence null hash refused'
  # Malformed / empty / missing pin, output, and live hashes all refuse.
  $planBadCommonOut = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; commonSha = 'zzz'; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planBadCommonOut $liveR1 @('P')).ok -eq $false) 'R17 malformed output commonSha refused'
  $planEmptyCfgOut = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; commonSha = $hCommon; configHash = '' })
  }
  Assert ((Test-MgmtPlanMatch $planEmptyCfgOut $liveR1 @('P')).ok -eq $false) 'R17 empty output configHash refused'
  $planEmptyPin = @{
    schemaVersion = 2; commonSha = ''; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; commonSha = ''; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planEmptyPin $liveR1 @('P')).ok -eq $false) 'R17 empty pin commonSha refused'
  $liveEmptyCfg = @{
    commonSha = $hCommon; commonText = 'ctext'; configHash = ''; targets = 'codexcli,opencode'
    entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $true; localHash = $hLocal; agentsExists = $true; agentsHash = 'ah' })
  }
  Assert ((Test-MgmtPlanMatch $planR1 $liveEmptyCfg @('P')).ok -eq $false) 'R17 empty live configHash refused'
  # localExists must be an actual boolean false to allow absence.
  $liveStrFlag = @{
    commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = 'false'; localHash = $null; agentsExists = $true; agentsHash = 'ah' })
  }
  $planStrFlag = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = @{ entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = 'false'; localHash = $null; agentsExists = $true; agentsHash = 'ah' }) }
    projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $null; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planStrFlag $liveStrFlag @('P')).ok -eq $false) 'R17 string localExists refused'
  $liveNullFlag = @{
    commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $null; localHash = $null; agentsExists = $true; agentsHash = 'ah' })
  }
  $planNullFlag = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = @{ entries = @(@{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $null; localHash = $null; agentsExists = $true; agentsHash = 'ah' }) }
    projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $null; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planNullFlag $liveNullFlag @('P')).ok -eq $false) 'R17 null localExists refused'
  # Old schema with inputs still requires re-preview.
  $planV1Inputs = @{
    schemaVersion = 1; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $hLocal; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planV1Inputs $liveR1 @('P')).ok -eq $false) 'R17 old schema with inputs refused'
  # R18 (r8): localHash field presence and raw-null identity through the real
  # JSON path. Both sides must carry the field; absence is allowed only when
  # both raw values are JSON null with an explicit boolean localExists=false.
  function New-R18Ent($Kind, $LocalMode, $LocalVal, $Exists, [bool]$HasExists) {
    $e = @{ name = 'P'; path = 'C:\R\P' }
    if ($Kind -cne 'output') { $e.enabled = $true }
    if ($HasExists) { $e.localExists = $Exists }
    if ($LocalMode -ceq 'present') { $e.localHash = $LocalVal }
    if ($Kind -cne 'output') { $e.agentsExists = $true; $e.agentsHash = 'ah' }
    else { $e.result = 'success'; $e.generatedText = 'gen'; $e.commonSha = $hCommon; $e.configHash = $hConfig }
    return $e
  }
  function Invoke-R18Case($InMode, $InVal, $OutMode, $OutVal, $Exists, [bool]$HasExists, [bool]$WantOk, [string]$Name) {
    $inE = New-R18Ent 'input' $InMode $InVal $Exists $HasExists
    $outE = New-R18Ent 'output' $OutMode $OutVal $Exists $HasExists
    $lvE = New-R18Ent 'live' $InMode $InVal $Exists $HasExists
    $plan = @{ schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'; inputs = @{ entries = @($inE) }; projects = @($outE) }
    $live = @{ commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'; entries = @($lvE) }
    $pj = ConvertTo-Json -InputObject $plan -Depth 8 -Compress | ConvertFrom-Json
    $lv = ConvertTo-Json -InputObject $live -Depth 8 -Compress | ConvertFrom-Json
    $r = Test-MgmtPlanMatch $pj $lv @('P')
    Assert (($r.ok -ceq $WantOk)) $Name
  }
  Invoke-R18Case 'missing' $null 'present' $null $false $true $false 'R18 input-missing output-null refused'
  Invoke-R18Case 'present' $null 'missing' $null $false $true $false 'R18 input-null output-missing refused'
  Invoke-R18Case 'present' '   ' 'present' $null $false $true $false 'R18 input-whitespace refused'
  Invoke-R18Case 'present' $null 'present' '   ' $false $true $false 'R18 output-whitespace refused'
  Invoke-R18Case 'present' $null 'present' $null $false $true $true 'R18 valid absent both-null passes'
  Invoke-R18Case 'present' $hLocal 'present' $hLocal $true $true $true 'R18 valid exists hash passes'
  Invoke-R18Case 'present' $hLocal 'present' $null $true $true $false 'R18 null vs hash refused'
  Invoke-R18Case 'missing' $null 'missing' $null $false $true $false 'R18 both-missing refused'
  Invoke-R18Case 'present' $null 'present' $null 'false' $true $false 'R18 string-exists null refused'
  $hInMiss = @{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $false; agentsExists = $true; agentsHash = 'ah' }
  $hOutNull = @{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'gen'; localHash = $null; commonSha = $hCommon; configHash = $hConfig }
  $hLiveMiss = @{ name = 'P'; path = 'C:\R\P'; enabled = $true; localExists = $false; agentsExists = $true; agentsHash = 'ah' }
  $planH = @{ schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'; inputs = @{ entries = @($hInMiss) }; projects = @($hOutNull) }
  $liveH = @{ commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'; entries = @($hLiveMiss) }
  Assert ((Test-MgmtPlanMatch $planH $liveH @('P')).ok -eq $false) 'R18 hashtable missing-field refused'
  $planUsedB = @{
    schemaVersion = 2; commonSha = $hCommon; commonText = 'ctext'; configHash = $hConfig; targets = 'codexcli,opencode'
    inputs = $planR1.inputs; projects = @(@{ name = 'P'; path = 'C:\R\P'; result = 'success'; generatedText = 'genB'; localHash = 'USED-B'; commonSha = $hCommon; configHash = $hConfig })
  }
  Assert ((Test-MgmtPlanMatch $planUsedB $liveR1 @('P')).ok -eq $false) 'R16 consumed-hash mismatch refused'
  # Live builder shape on scratch auto.
  $autoLB = Join-Path $scratch 'autoLB'
  $prevLB = Join-Path $scratch 'prevLB-proj'
  New-Item -ItemType Directory -Force -Path $autoLB | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $prevLB '.rulesync\rules\.curated') | Out-Null
  Set-Content -LiteralPath (Join-Path $autoLB 'projects.json') '[]' -Encoding Ascii
  $lb = Get-MgmtPlanLive $autoLB
  Assert ((($lb.entries.Count -eq 0) -and ($lb.targets -ceq 'codexcli,opencode'))) 'R1 live builder empty registry shape'
  # Live builder with a real entry (hashes + common text).
  $repoB1 = New-Repo 'R1B1'
  Set-Content -LiteralPath (Join-Path $repoB1 'AGENTS.md') 'b1-agents' -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoB1 '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoB1 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nb1-local") -Encoding UTF8
  Write-RegistryAtomicLocked $auto @(@((Get-Registry $auto)) + [pscustomobject]@{ name = 'RB1'; path = $repoB1 })
  $lvB = Get-MgmtPlanLive $auto
  $bEnt = @($lvB.entries | Where-Object { [string]$_.name -ceq 'RB1' })[0]
  Assert ((($null -ne $bEnt) -and ([bool]$bEnt.localExists) -and ([bool]$bEnt.agentsExists) -and (([string]$bEnt.localHash) -match '^[0-9a-f]{64}$'))) 'R1 live builder carries entry hashes'
  Assert (([string]$lvB.targets -ceq 'codexcli,opencode')) 'R1 live builder carries targets'
  Assert (([string]$lvB.commonText -match 'shared-line-one')) 'R1 live builder carries common text'

  # R1c: plan-bound apply at sync level (child process, crafted plan+request).
  $r1Root = Join-Path $scratch 'r1case'
  $autoR1 = Join-Path $r1Root 'auto'
  $prevR1 = Join-Path $r1Root 'project-common-preview'
  $binR1 = Join-Path $r1Root 'bin'
  $projRA = Join-Path $r1Root 'projA'
  New-Item -ItemType Directory -Force -Path $autoR1, $binR1, $projRA | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $prevR1 '.rulesync\rules\.curated') | Out-Null
  Copy-Item -LiteralPath $syncPath -Destination (Join-Path $autoR1 'Sync-ProjectRules.ps1') -Force
  Copy-Item -LiteralPath $mgmtPath -Destination (Join-Path $autoR1 'Project-Management.ps1') -Force
  $commonR1 = "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nr1-common-body"
  $cfgTextR1 = '{"targets":["codexcli","opencode"],"features":["rules"],"outputRoots":["output"],"delete":false,"global":false,"sources":[]}'
  Set-Content -LiteralPath (Join-Path $prevR1 'rulesync.jsonc') $cfgTextR1 -Encoding Ascii
  $curatedR1 = Join-Path $prevR1 '.rulesync\rules\.curated\project.md'
  Set-Content -LiteralPath $curatedR1 $commonR1 -Encoding UTF8
  $cfgR1 = Join-Path $prevR1 'rulesync.jsonc'
  $agentsRA = Join-Path $projRA 'AGENTS.md'
  $localRA = Join-Path $projRA '.rulesync\rules\project-local.md'
  New-Item -ItemType Directory -Force -Path (Join-Path $projRA '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $autoR1 'projects.json') ('[{"name":"projA","path":"' + ($projRA -replace '\\', '\\') + '"}]') -Encoding Ascii
  $stdShimR1 = @'
@echo off
setlocal EnableDelayedExpansion
set D=%DUMMY_DIR%
echo npx %* [cwd=%CD%]>> "%D%\calls.log"
set /p N=<"%D%\counter.txt"
set F=%D%\exit_!N!.txt
set CODE=0
if exist "!F!" set /p CODE=<"!F!"
set OUTD=
set PREV=
for %%A in (%*) do (
  if "!PREV!"=="--output-roots" if not defined OUTD set OUTD=%%A
  set PREV=%%A
)
if defined OUTD echo Would write: !OUTD!\AGENTS.md
if defined OUTD if not exist "!OUTD!\AGENTS.md" echo dummy-generated> "!OUTD!\AGENTS.md"
set /a M=!N!+1
echo !M!>"%D%\counter.txt"
endlocal & exit /b %CODE%
'@
  Set-Content -LiteralPath (Join-Path $binR1 'npx.cmd') $stdShimR1 -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $binR1 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
  $runnerR1 = Join-Path $r1Root 'run-r1.ps1'
  Set-Content -LiteralPath $runnerR1 @'
$ErrorActionPreference = 'Stop'
$rr = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = ((Join-Path $rr 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $rr
$env:DUMMY_GH_EXIT = '0'
$env:DUMMY_GH_TOKEN = 'unused'
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
$env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $rr 'auto\Sync-ProjectRules.ps1')
if ($args[0] -ceq 'request') {
  $c = Invoke-ProjectSync -RequestPath $args[1]
  Set-Content -LiteralPath (Join-Path $rr 'exitcode-r1.txt') ([string]$c) -Encoding Ascii
  exit $c
}
exit (Invoke-ProjectSync)
'@ -Encoding Ascii
  $psExeR1 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  function Get-R1Hex([string]$F) {
    if (-not (Test-Path -LiteralPath $F -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $F -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  function Reset-R1Fixtures() {
    Set-Content -LiteralPath (Join-Path $r1Root 'counter.txt') '0' -Encoding Ascii
    $ex = @(0, 1, 0, 0, 0, 0)
    for ($i = 0; $i -lt $ex.Count; $i++) { Set-Content -LiteralPath (Join-Path $r1Root ("exit_$i.txt")) ([string]$ex[$i]) -Encoding Ascii }
    Get-ChildItem -LiteralPath $r1Root -Filter 'exit_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^exit_([6-9]|\d\d+)\.txt$' } | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $r1Root 'exitcode-r1.txt') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $binR1 'npx.cmd') $stdShimR1 -Encoding Ascii
    Set-Content -LiteralPath $agentsRA 'agents-A-r1' -Encoding Ascii
    Set-Content -LiteralPath $localRA ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-A-r1") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $autoR1 'projects.json') ('[{"name":"projA","path":"' + ($projRA -replace '\\', '\\') + '"}]') -Encoding Ascii
    Set-Content -LiteralPath $curatedR1 $commonR1 -Encoding UTF8
    Set-Content -LiteralPath $cfgR1 $cfgTextR1 -Encoding Ascii
  }
  $planIdR1 = 'cccccccccccccccccccccccccccccccc'
  $reqIdR1 = 'dddddddddddddddddddddddddddddddd'
  function New-R1Plan() {
    $genText = [System.IO.File]::ReadAllText($agentsRA, [System.Text.Encoding]::UTF8)
    $plan = @{
      schemaVersion = 2
      commonSha = (Get-R1Hex $curatedR1); commonCommit = $null
      commonText = [System.IO.File]::ReadAllText($curatedR1, [System.Text.Encoding]::UTF8)
      configHash = (Get-R1Hex $cfgR1); targets = 'codexcli,opencode'
      createdAt = ([DateTime]::UtcNow.ToString('o'))
      inputs = @{ entries = @(@{ name = 'projA'; path = $projRA; enabled = $true; localExists = $true; localHash = (Get-R1Hex $localRA); agentsExists = $true; agentsHash = (Get-R1Hex $agentsRA) }) }
      projects = @(@{ name = 'projA'; path = $projRA; result = 'success'; currentText = $genText; generatedText = $genText; agentsHash = (Get-R1Hex $agentsRA); localHash = (Get-R1Hex $localRA); commonSha = (Get-R1Hex $curatedR1); commonCommit = $null; configHash = (Get-R1Hex $cfgR1); error = '' })
    }
    $pf = Join-Path $autoR1 ("dashboard.plan-" + $planIdR1 + ".json")
    Set-Content -LiteralPath $pf (ConvertTo-Json -InputObject $plan -Depth 8 -Compress) -Encoding Ascii
  }
  function New-R1Request() {
    $rf = Join-Path $autoR1 ("dashboard.request-" + $reqIdR1 + ".json")
    Set-Content -LiteralPath $rf (ConvertTo-Json -InputObject (@{ projectNames = @('projA'); previewOnly = $false; planPath = ''; planId = $planIdR1 }) -Depth 4 -Compress) -Encoding Ascii
    return $rf
  }
  function Invoke-R1Child([string]$Mode, [string]$Arg) {
    $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runnerR1)
    if ($Mode -ne '') { $a += $Mode }
    if ($Arg -ne '') { $a += $Arg }
    $p = Start-Process -FilePath $psExeR1 -ArgumentList $a -WindowStyle Hidden -RedirectStandardOutput (Join-Path $r1Root 'child.out') -RedirectStandardError (Join-Path $r1Root 'child.err') -PassThru
    $done = $p.WaitForExit(100000)
    try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch {}
    $code = 'timeout'
    if (Test-Path -LiteralPath (Join-Path $r1Root 'exitcode-r1.txt')) { $code = (Get-Content -LiteralPath (Join-Path $r1Root 'exitcode-r1.txt') -Raw -Encoding Ascii).Trim() }
    return @{ done = $done; code = $code }
  }
  function Get-R1BackupCount() {
    $bd = Join-Path $autoR1 'backups'
    if (-not (Test-Path -LiteralPath $bd -PathType Container)) { return 0 }
    return @((Get-ChildItem -LiteralPath $bd -Directory -ErrorAction SilentlyContinue)).Count
  }
  $planIdR1 = 'cccccccccccccccccccccccccccccccc'
  $reqIdR1 = 'dddddddddddddddddddddddddddddddd'
  function New-R1Plan() {
    $genText = [System.IO.File]::ReadAllText($agentsRA, [System.Text.Encoding]::UTF8)
    $plan = @{
      schemaVersion = 2
      commonSha = (Get-R1Hex $curatedR1); commonCommit = $null
      commonText = [System.IO.File]::ReadAllText($curatedR1, [System.Text.Encoding]::UTF8)
      configHash = (Get-R1Hex $cfgR1); targets = 'codexcli,opencode'
      createdAt = ([DateTime]::UtcNow.ToString('o'))
      inputs = @{ entries = @(@{ name = 'projA'; path = $projRA; enabled = $true; localExists = $true; localHash = (Get-R1Hex $localRA); agentsExists = $true; agentsHash = (Get-R1Hex $agentsRA) }) }
      projects = @(@{ name = 'projA'; path = $projRA; result = 'success'; currentText = $genText; generatedText = $genText; agentsHash = (Get-R1Hex $agentsRA); localHash = (Get-R1Hex $localRA); commonSha = (Get-R1Hex $curatedR1); commonCommit = $null; configHash = (Get-R1Hex $cfgR1); error = '' })
    }
    Set-Content -LiteralPath (Join-Path $autoR1 ("dashboard.plan-" + $planIdR1 + ".json")) (ConvertTo-Json -InputObject $plan -Depth 8 -Compress) -Encoding Ascii
  }
  function New-R1Request() {
    $rf = Join-Path $autoR1 ("dashboard.request-" + $reqIdR1 + ".json")
    Set-Content -LiteralPath $rf (ConvertTo-Json -InputObject (@{ projectNames = @('projA'); previewOnly = $false; planPath = ''; planId = $planIdR1 }) -Depth 4 -Compress) -Encoding Ascii
    return $rf
  }
  # P0 happy: matching plan applies with backup.
  Reset-R1Fixtures
  New-R1Plan
  $r0 = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($r0.done -and ($r0.code -ceq '0')))) 'R1 plan-bound happy applies'
  Assert (((Get-R1BackupCount) -ge 1)) 'R1 happy run backs up before generate'
  # Single-input drifts: refuse exit 1 with no new backup.
  $mutR1 = @(
    @{ n = 'common'; act = { Set-Content -LiteralPath $curatedR1 ($commonR1 + "`ndrift") -Encoding UTF8 } },
    @{ n = 'local'; act = { Set-Content -LiteralPath $localRA ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`ndrifted") -Encoding UTF8 } },
    @{ n = 'agents'; act = { Set-Content -LiteralPath $agentsRA 'drifted-agents' -Encoding Ascii } },
    @{ n = 'config'; act = { Set-Content -LiteralPath $cfgR1 ($cfgTextR1 + ' ') -Encoding Ascii } }
  )
  foreach ($mc in $mutR1) {
    Reset-R1Fixtures
    New-R1Plan
    & ($mc.act)
    $bb = Get-R1BackupCount
    $rr = Invoke-R1Child 'request' (New-R1Request)
    Assert ((($rr.done -and ($rr.code -ne '0')))) ('R1 drift refused: ' + $mc.n)
    Assert (((Get-R1BackupCount) -eq $bb)) ('R1 refusal creates no backup: ' + $mc.n)
  }
  Reset-R1Fixtures
  New-R1Plan
  $dstM = New-Repo 'R1Moved'
  Set-Content -LiteralPath (Join-Path $autoR1 'projects.json') ('[{"name":"projA","path":"' + ($dstM -replace '\\', '\\') + '"}]') -Encoding Ascii
  $rMv = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($rMv.done -and ($rMv.code -ne '0')))) 'R1 moved path refused'
  Reset-R1Fixtures
  New-R1Plan
  Set-Content -LiteralPath (Join-Path $autoR1 'projects.json') ('[{"name":"projA","path":"' + ($projRA -replace '\\', '\\') + '","enabled":false}]') -Encoding Ascii
  $rEn = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($rEn.done -and ($rEn.code -ne '0')))) 'R1 enabled toggle refused'
  Reset-R1Fixtures
  New-R1Plan
  Set-Content -LiteralPath (Join-Path $autoR1 'projects.json') '[]' -Encoding Ascii
  $rRm = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($rRm.done -and ($rRm.code -ne '0')))) 'R1 removed entry refused'
  Reset-R1Fixtures
  New-R1Plan
  $extraR1 = New-Repo 'R1Extra'
  Set-Content -LiteralPath (Join-Path $autoR1 'projects.json') ('[{"name":"projA","path":"' + ($projRA -replace '\\', '\\') + '"},{"name":"extra","path":"' + ($extraR1 -replace '\\', '\\') + '"}]') -Encoding Ascii
  $rXtra = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($rXtra.done -and ($rXtra.code -ceq '0')))) 'R1 unrelated addition keeps approved subset working'
  Reset-R1Fixtures
  $rfU = Join-Path $autoR1 ("dashboard.request-" + $reqIdR1 + ".json")
  Set-Content -LiteralPath $rfU (ConvertTo-Json -InputObject (@{ projectNames = @('projA'); previewOnly = $false; planPath = ''; planId = ('e' * 32) }) -Depth 4 -Compress) -Encoding Ascii
  $rUnk = Invoke-R1Child 'request' $rfU
  Assert ((($rUnk.done -and ($rUnk.code -ne '0')))) 'R1 unknown plan id refused'
  Reset-R1Fixtures
  New-R1Plan
  (Get-Item -LiteralPath (Join-Path $autoR1 ("dashboard.plan-" + $planIdR1 + ".json"))).LastWriteTime = ((Get-Date).AddMinutes(-130))
  $rStale = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($rStale.done -and ($rStale.code -ne '0')))) 'R1 stale plan refused'
  Reset-R1Fixtures
  New-R1Plan
  $preR1 = [System.IO.File]::ReadAllText($agentsRA, [System.Text.Encoding]::UTF8)
  $junkLine = 'if "!N!"=="3" echo JUNK-DRIFT>> "' + $agentsRA + '"'
  $junkShim = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + $junkLine)
  Set-Content -LiteralPath (Join-Path $binR1 'npx.cmd') $junkShim -Encoding Ascii
  $rJunk = Invoke-R1Child 'request' (New-R1Request)
  Assert ((($rJunk.done -and ($rJunk.code -ne '0')))) 'R1 post-generate mismatch fails'
  Assert (([System.IO.File]::ReadAllText($agentsRA, [System.Text.Encoding]::UTF8) -ceq $preR1)) 'R1 post-generate mismatch restores backup'
  if (-not ([System.IO.File]::ReadAllText($agentsRA, [System.Text.Encoding]::UTF8) -ceq $preR1)) {
    Write-Host '--- r1 child.out (junk case) ---'
    Get-Content -LiteralPath (Join-Path $r1Root 'child.out') -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    Write-Host ('--- autoJ log tail ---')
    Get-ChildItem -LiteralPath (Join-Path $autoR1 'logs') -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 8 | ForEach-Object { Write-Host $_ } }
  }
  Reset-R1Fixtures
  $ppW = Join-Path $autoR1 'dashboard.plan-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'
  Set-Content -LiteralPath (Join-Path $r1Root 'counter.txt') '0' -Encoding Ascii
  $exPrev = @(0, 0, 0)
  for ($i = 0; $i -lt $exPrev.Count; $i++) { Set-Content -LiteralPath (Join-Path $r1Root ("exit_$i.txt")) ([string]$exPrev[$i]) -Encoding Ascii }
  Get-ChildItem -LiteralPath $r1Root -Filter 'exit_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^exit_([3-9]|\d\d+)\.txt$' } | Remove-Item -Force -ErrorAction SilentlyContinue
  $pwRunner = Join-Path $r1Root 'run-prev.ps1'
  Set-Content -LiteralPath $pwRunner @'
$ErrorActionPreference = 'Stop'
$rr = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = ((Join-Path $rr 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $rr
$env:DUMMY_GH_EXIT = '0'
$env:DUMMY_GH_TOKEN = 'unused'
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
$env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $rr 'auto\Sync-ProjectRules.ps1')
$pp = Join-Path $rr 'auto\dashboard.plan-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'
$c = Invoke-ProjectSync -PreviewOnly -PlanPath $pp
Set-Content -LiteralPath (Join-Path $rr 'exitcode-prev.txt') ([string]$c) -Encoding Ascii
exit $c
'@ -Encoding Ascii
  $livePinH = @{ cur = (Get-R1Hex $curatedR1); cfg = (Get-R1Hex $cfgR1); loc = (Get-R1Hex $localRA); ag = (Get-R1Hex $agentsRA) }
  $pw = Start-Process -FilePath $psExeR1 -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $pwRunner -WindowStyle Hidden -RedirectStandardOutput (Join-Path $r1Root 'child-prev.out') -RedirectStandardError (Join-Path $r1Root 'child-prev.err') -PassThru
  $pwDone = $pw.WaitForExit(100000)
  try { if (-not $pw.HasExited) { Stop-Process -Id $pw.Id -Force } } catch {}
  $pwCode = 'timeout'
  if (Test-Path -LiteralPath (Join-Path $r1Root 'exitcode-prev.txt')) { $pwCode = (Get-Content -LiteralPath (Join-Path $r1Root 'exitcode-prev.txt') -Raw -Encoding Ascii).Trim() }
  Assert ((($pwDone -and ($pwCode -ceq '0')))) 'R1 preview writer completes'
  # R16 (r6 #2): generation consumes staged private copies only, and staging
  # never modifies the live inputs.
  $callLines = @()
  try {
    $callLines = @(Get-Content -LiteralPath (Join-Path $r1Root 'calls.log') -ErrorAction Stop | Where-Object { $_ -match '--config' } | ForEach-Object {
      $ln = [string]$_
      $ix = $ln.IndexOf('[cwd=')
      if ($ix -ge 0) { $ln = $ln.Substring(0, $ix) }
      $ln
    })
  } catch { $callLines = @() }
  Assert ((@($callLines).Count -ge 2)) 'R16 staged consumption calls logged'
  $stagedOnly = $true
  foreach ($cl in $callLines) {
    if (($cl -notmatch 'staged') -or ($cl -match 'project-common-preview')) { $stagedOnly = $false }
  }
  Assert ($stagedOnly) 'R16 CLI consumes staged inputs only'
  Assert ((((Get-R1Hex $curatedR1) -ceq $livePinH.cur) -and ((Get-R1Hex $cfgR1) -ceq $livePinH.cfg) -and ((Get-R1Hex $localRA) -ceq $livePinH.loc) -and ((Get-R1Hex $agentsRA) -ceq $livePinH.ag))) 'R16 staging leaves live inputs unmodified'
  $plW = $null
  if (Test-Path -LiteralPath $ppW -PathType Leaf) { $plW = Get-Content -LiteralPath $ppW -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert ((($null -ne $plW) -and ([int]$plW.schemaVersion -eq 2) -and ($null -ne $plW.inputs) -and (@($plW.inputs.entries).Count -eq 1) -and ([string]$plW.configHash -match '^[0-9a-f]{64}$'))) 'R1 preview plan carries inputs block'
  $plWSelfOk = $true
  foreach ($pp in @($plW.projects)) {
    if ([string]$pp.result -cne 'success') { continue }
    $pie = @(@($plW.inputs.entries) | Where-Object { [string]$_.name -ceq [string]$pp.name })
    if (($pie.Count -ne 1) -or (-not ([string]$pp.path).Equals([string]$pie[0].path, [System.StringComparison]::OrdinalIgnoreCase))) { $plWSelfOk = $false }
  }
  Assert ($plWSelfOk) 'R15 published plan outputs match approved inputs'
  # R1-race: cross-project edit during preview must refuse to publish the plan.
  $raceRoot = Join-Path $scratch 'r1race'
  $raceAuto = Join-Path $raceRoot 'auto'
  $racePrev = Join-Path $raceRoot 'project-common-preview'
  $raceBin = Join-Path $raceRoot 'bin'
  $raceA = Join-Path $raceRoot 'projA'
  $raceB = Join-Path $raceRoot 'projB'
  New-Item -ItemType Directory -Force -Path $raceAuto, $raceBin, $raceA, $raceB | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $racePrev '.rulesync\rules\.curated') | Out-Null
  Copy-Item -LiteralPath $syncPath -Destination (Join-Path $raceAuto 'Sync-ProjectRules.ps1') -Force
  Copy-Item -LiteralPath $mgmtPath -Destination (Join-Path $raceAuto 'Project-Management.ps1') -Force
  $raceCommon = "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nrace-common"
  Set-Content -LiteralPath (Join-Path $racePrev 'rulesync.jsonc') $cfgTextR1 -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $racePrev '.rulesync\rules\.curated\project.md') $raceCommon -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $raceAuto 'projects.json') ('[{"name":"projA","path":"' + ($raceA -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($raceB -replace '\\', '\\') + '"}]') -Encoding Ascii
  $raceShim = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="3" echo RACE-DRIFT>> "' + (Join-Path $raceA '.rulesync\rules\project-local.md') + '"')
  Set-Content -LiteralPath (Join-Path $raceBin 'npx.cmd') $raceShim -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $raceBin 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
  foreach ($rp in @($raceA, $raceB)) {
    Set-Content -LiteralPath (Join-Path $rp 'AGENTS.md') ('agents-' + (Split-Path $rp -Leaf)) -Encoding Ascii
    New-Item -ItemType Directory -Force -Path (Join-Path $rp '.rulesync\rules') | Out-Null
    Set-Content -LiteralPath (Join-Path $rp '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-" + (Split-Path $rp -Leaf)) -Encoding UTF8
  }
  Set-Content -LiteralPath (Join-Path $raceRoot 'counter.txt') '0' -Encoding Ascii
  $raceEx = @(0, 0, 0, 0, 0)
  for ($i = 0; $i -lt $raceEx.Count; $i++) { Set-Content -LiteralPath (Join-Path $raceRoot ("exit_$i.txt")) ([string]$raceEx[$i]) -Encoding Ascii }
  $raceRunner = Join-Path $raceRoot 'run-race.ps1'
  Set-Content -LiteralPath $raceRunner @'
$ErrorActionPreference = 'Stop'
$rr = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = ((Join-Path $rr 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $rr
$env:DUMMY_GH_EXIT = '0'
$env:DUMMY_GH_TOKEN = 'unused'
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
$env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $rr 'auto\Sync-ProjectRules.ps1')
$pp = Join-Path $rr 'auto\dashboard.plan-dddddddddddddddddddddddddddddddd.json'
$c = Invoke-ProjectSync -PreviewOnly -PlanPath $pp
Set-Content -LiteralPath (Join-Path $rr 'exitcode-race.txt') ([string]$c) -Encoding Ascii
exit $c
'@ -Encoding Ascii
  $raceP = Start-Process -FilePath $psExeR1 -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $raceRunner -WindowStyle Hidden -RedirectStandardOutput (Join-Path $raceRoot 'child.out') -RedirectStandardError (Join-Path $raceRoot 'child.err') -PassThru
  $raceDone = $raceP.WaitForExit(100000)
  try { if (-not $raceP.HasExited) { Stop-Process -Id $raceP.Id -Force } } catch {}
  $raceCode = 'timeout'
  if (Test-Path -LiteralPath (Join-Path $raceRoot 'exitcode-race.txt')) { $raceCode = (Get-Content -LiteralPath (Join-Path $raceRoot 'exitcode-race.txt') -Raw -Encoding Ascii).Trim() }
  Assert ((($raceDone -and ($raceCode -ne '0')))) 'R1 cross-project race refuses to publish plan'
  Assert ((-not (Test-Path -LiteralPath (Join-Path $raceAuto 'dashboard.plan-dddddddddddddddddddddddddddddddd.json') -PathType Leaf))) 'R1 raced preview writes no plan file'

  # R13 (r3 #1-3): preview pin, per-project write gate, post-mutation rollback.
  function New-R13Root([string]$Tag) {
    $t = Join-Path $scratch ('r13-' + $Tag + '-' + [System.Guid]::NewGuid().ToString('N'))
    $a = Join-Path $t 'auto'; $pv = Join-Path $t 'project-common-preview'
    $bn = Join-Path $t 'bin'; $pA = Join-Path $t 'projA'; $pB = Join-Path $t 'projB'
    New-Item -ItemType Directory -Force -Path $a, $bn, $pA, $pB | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $pv '.rulesync\rules\.curated') | Out-Null
    Copy-Item -LiteralPath $syncPath -Destination (Join-Path $a 'Sync-ProjectRules.ps1') -Force
    Copy-Item -LiteralPath $mgmtPath -Destination (Join-Path $a 'Project-Management.ps1') -Force
    Set-Content -LiteralPath (Join-Path $pv 'rulesync.jsonc') $cfgTextR1 -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $pv '.rulesync\rules\.curated\project.md') ("---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nr13-common") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $a 'projects.json') ('[{"name":"projA","path":"' + ($pA -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($pB -replace '\\', '\\') + '"}]') -Encoding Ascii
    foreach ($rp in @($pA, $pB)) {
      Set-Content -LiteralPath (Join-Path $rp 'AGENTS.md') ('agents-' + (Split-Path $rp -Leaf)) -Encoding Ascii
      New-Item -ItemType Directory -Force -Path (Join-Path $rp '.rulesync\rules') | Out-Null
      Set-Content -LiteralPath (Join-Path $rp '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-" + (Split-Path $rp -Leaf)) -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $bn 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $t 'counter.txt') '0' -Encoding Ascii
    return @{ root = $t; auto = $a; prev = $pv; bin = $bn; projA = $pA; projB = $pB }
  }
  function Set-R13Exits($h, [int[]]$Codes) {
    for ($i = 0; $i -lt $Codes.Count; $i++) { Set-Content -LiteralPath (Join-Path $h.root ("exit_$i.txt")) ([string]$Codes[$i]) -Encoding Ascii }
  }
  function New-R13Plan($h, [string]$PlanId, [string[]]$Names, $GenText) {
    $cur = Join-Path $h.prev '.rulesync\rules\.curated\project.md'
    $cfg = Join-Path $h.prev 'rulesync.jsonc'
    $ents = @(); $projs = @()
    foreach ($nm in $Names) {
      $rp = $h.projA; if ($nm -cne 'projA') { $rp = $h.projB }
      $lf = Join-Path $rp '.rulesync\rules\project-local.md'; $af = Join-Path $rp 'AGENTS.md'
      $cur2 = [System.IO.File]::ReadAllText($af, [System.Text.Encoding]::UTF8)
      $gt = $cur2; if ($GenText -is [hashtable] -and $GenText.ContainsKey($nm)) { $gt = [string]$GenText[$nm] }
      $ents += @{ name = $nm; path = $rp; enabled = $true; localExists = $true; localHash = (Get-R1Hex $lf); agentsExists = $true; agentsHash = (Get-R1Hex $af) }
      $projs += @{ name = $nm; path = $rp; result = 'success'; currentText = $cur2; generatedText = $gt; agentsHash = (Get-R1Hex $af); localHash = (Get-R1Hex $lf); commonSha = (Get-R1Hex $cur); commonCommit = $null; configHash = (Get-R1Hex $cfg); error = '' }
    }
    $plan = @{ schemaVersion = 2; commonSha = (Get-R1Hex $cur); commonCommit = $null; commonText = [System.IO.File]::ReadAllText($cur, [System.Text.Encoding]::UTF8); configHash = (Get-R1Hex $cfg); targets = 'codexcli,opencode'; createdAt = ([DateTime]::UtcNow.ToString('o')); inputs = @{ entries = $ents }; projects = $projs }
    Set-Content -LiteralPath (Join-Path $h.auto ("dashboard.plan-" + $PlanId + ".json")) (ConvertTo-Json -InputObject $plan -Depth 8 -Compress) -Encoding Ascii
  }
  function New-R13Request($h, [string]$ReqId, [string[]]$Names, [string]$PlanId) {
    $rf = Join-Path $h.auto ("dashboard.request-" + $ReqId + ".json")
    Set-Content -LiteralPath $rf (ConvertTo-Json -InputObject (@{ projectNames = $Names; previewOnly = $false; planPath = ''; planId = $PlanId }) -Depth 4 -Compress) -Encoding Ascii
    return $rf
  }
  function Invoke-R13Child($h, [string]$Runner, [string]$ExitFile) {
    $p = Start-Process -FilePath $psExeR1 -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Runner -WindowStyle Hidden -RedirectStandardOutput (Join-Path $h.root 'child.out') -RedirectStandardError (Join-Path $h.root 'child.err') -PassThru
    $done = $p.WaitForExit(100000)
    try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch {}
    $code = 'timeout'
    if (Test-Path -LiteralPath (Join-Path $h.root $ExitFile)) { $code = (Get-Content -LiteralPath (Join-Path $h.root $ExitFile) -Raw -Encoding Ascii).Trim() }
    return @{ done = $done; code = $code }
  }
  $r13PrevRunner = @'
$ErrorActionPreference = 'Stop'
$rr = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = ((Join-Path $rr 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $rr
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $rr 'auto\Sync-ProjectRules.ps1')
$pp = Join-Path $rr 'auto\dashboard.plan-13131313131313131313131313131313.json'
$c = Invoke-ProjectSync -PreviewOnly -PlanPath $pp
Set-Content -LiteralPath (Join-Path $rr 'exitcode-r13.txt') ([string]$c) -Encoding Ascii
exit $c
'@
  $r13ApplyRunner = @'
$ErrorActionPreference = 'Stop'
$rr = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = ((Join-Path $rr 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $rr
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $rr 'auto\Sync-ProjectRules.ps1')
$reqs = @(Get-ChildItem -LiteralPath (Join-Path $rr 'auto') -Filter 'dashboard.request-*.json')
$c = Invoke-ProjectSync -RequestPath $reqs[0].FullName
Set-Content -LiteralPath (Join-Path $rr 'exitcode-r13.txt') ([string]$c) -Encoding Ascii
exit $c
'@
  $h1a = New-R13Root 'pin-common'
  $shim1a = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="1" echo DRIFT-COMMON>> "' + (Join-Path $h1a.prev '.rulesync\rules\.curated\project.md') + '"')
  Set-Content -LiteralPath (Join-Path $h1a.bin 'npx.cmd') $shim1a -Encoding Ascii
  Set-R13Exits $h1a @(0, 0, 0, 0, 0)
  Set-Content -LiteralPath (Join-Path $h1a.root 'run-r13.ps1') $r13PrevRunner -Encoding Ascii
  $r1a = Invoke-R13Child $h1a (Join-Path $h1a.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r1a.done -and ($r1a.code -ne '0')))) 'R13 common drift mid-preview refused'
  Assert ((-not (Test-Path -LiteralPath (Join-Path $h1a.auto 'dashboard.plan-13131313131313131313131313131313.json') -PathType Leaf))) 'R13 drifted preview writes no plan file'
  $h1b = New-R13Root 'pin-registry'
  Set-Content -LiteralPath (Join-Path $h1b.root 'projects-drift.json') ('[{"name":"projA","path":"' + ($h1b.projA -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($h1b.projB -replace '\\', '\\') + '"},{"name":"ghost","path":"' + ((Join-Path $h1b.root 'ghost') -replace '\\', '\\') + '"}]') -Encoding Ascii
  $shim1b = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="1" copy /y "%D%\projects-drift.json" "%D%\auto\projects.json" >nul')
  Set-Content -LiteralPath (Join-Path $h1b.bin 'npx.cmd') $shim1b -Encoding Ascii
  Set-R13Exits $h1b @(0, 0, 0, 0, 0)
  Set-Content -LiteralPath (Join-Path $h1b.root 'run-r13.ps1') $r13PrevRunner -Encoding Ascii
  $r1b = Invoke-R13Child $h1b (Join-Path $h1b.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r1b.done -and ($r1b.code -ne '0')))) 'R13 registry drift mid-preview refused'
  Assert ((-not (Test-Path -LiteralPath (Join-Path $h1b.auto 'dashboard.plan-13131313131313131313131313131313.json') -PathType Leaf))) 'R13 registry-drifted preview writes no plan file'
  $h2a = New-R13Root 'writegate'
  $shim2a = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="4" echo B-DRIFT>> "' + (Join-Path $h2a.projB '.rulesync\rules\project-local.md') + '"')
  Set-Content -LiteralPath (Join-Path $h2a.bin 'npx.cmd') $shim2a -Encoding Ascii
  Set-R13Exits $h2a @(0, 1, 0, 0, 0, 1, 0, 0, 0)
  New-R13Plan $h2a 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA', 'projB') $null
  $req2a = New-R13Request $h2a 'cccccccccccccccccccccccccccccccc' @('projA', 'projB') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  Set-Content -LiteralPath (Join-Path $h2a.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r2a = Invoke-R13Child $h2a (Join-Path $h2a.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r2a.done -and ($r2a.code -ne '0')))) 'R13 B edit during A refused (overall failure)'
  $bk2a = 0
  if (Test-Path -LiteralPath (Join-Path $h2a.auto 'backups') -PathType Container) { $bk2a = @((Get-ChildItem -LiteralPath (Join-Path $h2a.auto 'backups') -Directory -ErrorAction SilentlyContinue)).Count }
  Assert (($bk2a -eq 1)) 'R13 refused B creates no backup (A only)'
  $st2a = Get-Content -LiteralPath (Join-Path $h2a.auto 'project-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ((([string]$st2a.projects.projA.result -ceq 'success') -and ([string]$st2a.projects.projB.result -ceq 'failed'))) 'R13 A applied, B failed'
  Assert ((-not ([System.IO.File]::ReadAllText((Join-Path $h2a.projB 'AGENTS.md'), [System.Text.Encoding]::UTF8).Contains('dummy-generated')))) 'R13 refused B leaves AGENTS intact'
  $h2b = New-R13Root 'selectedonly'
  $shim2b = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="2" echo B-DRIFT>> "' + (Join-Path $h2b.projB '.rulesync\rules\project-local.md') + '"')
  Set-Content -LiteralPath (Join-Path $h2b.bin 'npx.cmd') $shim2b -Encoding Ascii
  Set-R13Exits $h2b @(0, 1, 0, 0, 0)
  New-R13Plan $h2b 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA') $null
  $req2b = New-R13Request $h2b 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  Set-Content -LiteralPath (Join-Path $h2b.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r2b = Invoke-R13Child $h2b (Join-Path $h2b.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r2b.done -and ($r2b.code -ceq '0')))) 'R13 unselected drift keeps selected apply working'
  $h3a = New-R13Root 'genfail'
  $shim3a = $stdShimR1 -replace 'if defined OUTD echo Would write: !OUTD!\\AGENTS.md', ('$0' + "`r`n" + 'if "!N!"=="3" echo PARTIAL-DRIFT> "!OUTD!\AGENTS.md"')
  Set-Content -LiteralPath (Join-Path $h3a.bin 'npx.cmd') $shim3a -Encoding Ascii
  Set-R13Exits $h3a @(0, 1, 0, 2, 0)
  New-R13Plan $h3a 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA') $null
  $req3a = New-R13Request $h3a 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  $orig3a = [System.IO.File]::ReadAllText((Join-Path $h3a.projA 'AGENTS.md'), [System.Text.Encoding]::UTF8)
  Set-Content -LiteralPath (Join-Path $h3a.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r3a = Invoke-R13Child $h3a (Join-Path $h3a.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r3a.done -and ($r3a.code -ne '0')))) 'R13 generate failure fails'
  Assert (([System.IO.File]::ReadAllText((Join-Path $h3a.projA 'AGENTS.md'), [System.Text.Encoding]::UTF8) -ceq $orig3a)) 'R13 generate failure restores backup'
  $h3b = New-R13Root 'finalfail'
  $fixed3b = Join-Path $h3b.root 'fixed.txt'
  Set-Content -LiteralPath $fixed3b 'known-generated-bytes' -Encoding Ascii -NoNewline
  $shim3b = $stdShimR1 -replace 'if defined OUTD echo Would write: !OUTD!\\AGENTS.md', ('$0' + "`r`n" + 'if "!N!"=="3" copy /y "%D%\fixed.txt" "!OUTD!\AGENTS.md" >nul')
  Set-Content -LiteralPath (Join-Path $h3b.bin 'npx.cmd') $shim3b -Encoding Ascii
  Set-R13Exits $h3b @(0, 1, 0, 0, 1)
  New-R13Plan $h3b 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA') @{ projA = ([System.IO.File]::ReadAllText($fixed3b, [System.Text.Encoding]::UTF8)) }
  $req3b = New-R13Request $h3b 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  Set-Content -LiteralPath (Join-Path $h3b.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r3b = Invoke-R13Child $h3b (Join-Path $h3b.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r3b.done -and ($r3b.code -ne '0')))) 'R13 final-check failure fails'
  Assert ((-not ([System.IO.File]::ReadAllText((Join-Path $h3b.projA 'AGENTS.md'), [System.Text.Encoding]::UTF8).Contains('known-generated')))) 'R13 final-check failure restores backup'
  $st3b = Get-Content -LiteralPath (Join-Path $h3b.auto 'project-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (([string]$st3b.projects.projA.error).Contains('final check failed')) 'R13 final-check failure message kept'
  $h3c = New-R13Root 'rbfail'
  $shim3c = $stdShimR1 -replace 'if defined OUTD echo Would write: !OUTD!\\AGENTS.md', ('$0' + "`r`n" + 'if "!N!"=="3" echo PARTIAL-DRIFT> "!OUTD!\AGENTS.md"' + "`r`n" + 'if "!N!"=="3" rd /s /q "%D%\auto\backups"')
  Set-Content -LiteralPath (Join-Path $h3c.bin 'npx.cmd') $shim3c -Encoding Ascii
  Set-R13Exits $h3c @(0, 1, 0, 2, 0)
  New-R13Plan $h3c 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA') $null
  $req3c = New-R13Request $h3c 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  Set-Content -LiteralPath (Join-Path $h3c.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r3c = Invoke-R13Child $h3c (Join-Path $h3c.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r3c.done -and ($r3c.code -ne '0')))) 'R13 backup-loss failure fails'
  Assert ((Test-Path -LiteralPath (Join-Path $h3c.projA 'AGENTS.md') -PathType Leaf)) 'R13 backup-loss never deletes original'
  $st3c = Get-Content -LiteralPath (Join-Path $h3c.auto 'project-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (([string]$st3c.projects.projA.error).Contains('rollback also failed')) 'R13 rollback failure reported explicitly'
  # R14 (r4 #1): registry path change during install refuses preview+apply.
  $h4p = New-R13Root 'installrace-prev'
  $pA2x = Join-Path $h4p.root 'projA2'
  New-Item -ItemType Directory -Force -Path $pA2x | Out-Null
  Set-Content -LiteralPath (Join-Path $pA2x 'AGENTS.md') 'agents-projA2' -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $pA2x '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $pA2x '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-projA2") -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $h4p.root 'projects-drift.json') ('[{"name":"projA","path":"' + ($pA2x -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($h4p.projB -replace '\\', '\\') + '"}]') -Encoding Ascii
  $shim4p = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="0" copy /y "%D%\projects-drift.json" "%D%\auto\projects.json" >nul')
  Set-Content -LiteralPath (Join-Path $h4p.bin 'npx.cmd') $shim4p -Encoding Ascii
  Set-R13Exits $h4p @(0, 0, 0, 0, 0)
  Set-Content -LiteralPath (Join-Path $h4p.root 'run-r13.ps1') $r13PrevRunner -Encoding Ascii
  $r4p = Invoke-R13Child $h4p (Join-Path $h4p.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r4p.done -and ($r4p.code -ne '0')))) 'R14 install-time path change refuses preview'
  Assert ((-not (Test-Path -LiteralPath (Join-Path $h4p.auto 'dashboard.plan-13131313131313131313131313131313.json') -PathType Leaf))) 'R14 moved preview writes no mixed plan'
  # R14 apply: pinned new-path plan with stale old-path execution is refused.
  $h4a = New-R13Root 'installrace-apply'
  $pA2a = Join-Path $h4a.root 'projA2'
  New-Item -ItemType Directory -Force -Path $pA2a | Out-Null
  Set-Content -LiteralPath (Join-Path $pA2a 'AGENTS.md') 'agents-projA2' -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $pA2a '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $pA2a '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-projA2") -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $h4a.root 'projects-drift.json') ('[{"name":"projA","path":"' + ($pA2a -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($h4a.projB -replace '\\', '\\') + '"}]') -Encoding Ascii
  $fixed4a = Join-Path $h4a.root 'fixed.txt'
  Set-Content -LiteralPath $fixed4a 'applied-marker-bytes' -Encoding Ascii -NoNewline
  $shim4a = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="0" copy /y "%D%\projects-drift.json" "%D%\auto\projects.json" >nul')
  $shim4a = $shim4a -replace 'if defined OUTD echo Would write: !OUTD!\\AGENTS.md', ('$0' + "`r`n" + 'if "!N!"=="3" copy /y "%D%\fixed.txt" "!OUTD!\AGENTS.md" >nul')
  Set-Content -LiteralPath (Join-Path $h4a.bin 'npx.cmd') $shim4a -Encoding Ascii
  Set-R13Exits $h4a @(0, 1, 0, 0, 0)
  $mk4a = [System.IO.File]::ReadAllText($fixed4a, [System.Text.Encoding]::UTF8)
  $cur4a = Join-Path $h4a.prev '.rulesync\rules\.curated\project.md'
  $cfg4a = Join-Path $h4a.prev 'rulesync.jsonc'
  $lf4a = Join-Path $pA2a '.rulesync\rules\project-local.md'; $af4a = Join-Path $pA2a 'AGENTS.md'
  $plan4a = @{ schemaVersion = 2; commonSha = (Get-R1Hex $cur4a); commonCommit = $null; commonText = [System.IO.File]::ReadAllText($cur4a, [System.Text.Encoding]::UTF8); configHash = (Get-R1Hex $cfg4a); targets = 'codexcli,opencode'; createdAt = ([DateTime]::UtcNow.ToString('o')); inputs = @{ entries = @(@{ name = 'projA'; path = $pA2a; enabled = $true; localExists = $true; localHash = (Get-R1Hex $lf4a); agentsExists = $true; agentsHash = (Get-R1Hex $af4a) }) }; projects = @(@{ name = 'projA'; path = $pA2a; result = 'success'; currentText = 'x'; generatedText = $mk4a; agentsHash = (Get-R1Hex $af4a); localHash = (Get-R1Hex $lf4a); commonSha = (Get-R1Hex $cur4a); commonCommit = $null; configHash = (Get-R1Hex $cfg4a); error = '' }) }
  Set-Content -LiteralPath (Join-Path $h4a.auto 'dashboard.plan-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json') (ConvertTo-Json -InputObject $plan4a -Depth 8 -Compress) -Encoding Ascii
  $req4a = New-R13Request $h4a 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  Set-Content -LiteralPath (Join-Path $h4a.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r4a = Invoke-R13Child $h4a (Join-Path $h4a.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r4a.done -and ($r4a.code -ne '0')))) 'R14 stale execution path refused on apply'
  Assert ((-not ([System.IO.File]::ReadAllText((Join-Path $h4a.projA 'AGENTS.md'), [System.Text.Encoding]::UTF8).Contains('applied-marker')))) 'R14 stale old path not written'
  Assert ((-not ([System.IO.File]::ReadAllText($af4a, [System.Text.Encoding]::UTF8).Contains('applied-marker')))) 'R14 new path untouched on refusal'
  # R14 corrupt backup: post-backup corruption is rejected, original kept.
  $h4c = New-R13Root 'corruptbak'
  $shim4c = $stdShimR1 -replace 'set /p N=<"%D%\\counter.txt"', ('$0' + "`r`n" + 'if "!N!"=="3" for /d %%B in ("%D%\auto\backups\*") do echo CORRUPT-BACKUP> "%%B\AGENTS.md"')
  Set-Content -LiteralPath (Join-Path $h4c.bin 'npx.cmd') $shim4c -Encoding Ascii
  Set-R13Exits $h4c @(0, 1, 0, 2, 0)
  New-R13Plan $h4c 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA') $null
  $req4c = New-R13Request $h4c 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  $orig4c = [System.IO.File]::ReadAllText((Join-Path $h4c.projA 'AGENTS.md'), [System.Text.Encoding]::UTF8)
  Set-Content -LiteralPath (Join-Path $h4c.root 'run-r13.ps1') $r13ApplyRunner -Encoding Ascii
  $r4c = Invoke-R13Child $h4c (Join-Path $h4c.root 'run-r13.ps1') 'exitcode-r13.txt'
  Assert ((($r4c.done -and ($r4c.code -ne '0')))) 'R14 corrupt backup fails'
  Assert (([System.IO.File]::ReadAllText((Join-Path $h4c.projA 'AGENTS.md'), [System.Text.Encoding]::UTF8) -ceq $orig4c)) 'R14 corrupt backup keeps original'
  $st4c = Get-Content -LiteralPath (Join-Path $h4c.auto 'project-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (([string]$st4c.projects.projA.error).Contains('backup corrupt')) 'R14 corrupt backup reported truthfully'
  # R15 (r5 #1): manual restore validates every target against the manifest
  # hash before writing; corrupt bodies never overwrite current files.
  $repoM15a = New-Repo 'R15ManA'
  Set-Content -LiteralPath (Join-Path $repoM15a 'AGENTS.md') ($commonBody + "`nm15a-unique") -Encoding Ascii
  $apprM15a = New-MgmtImportApproval $auto $repoM15a
  $impM15a = Register-MgmtImport $auto $repoM15a $null $true $apprM15a
  $blM15a = @(Get-MgmtBackupList $auto ([string]$impM15a.name))
  $bdirM15a = Join-Path $auto ('backups\' + $blM15a[0].id)
  Set-Content -LiteralPath (Join-Path $bdirM15a 'AGENTS.md') 'CORRUPT-M15A-AGENTS' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bdirM15a 'project-local.md') 'CORRUPT-M15A-LOCAL' -Encoding Ascii
  $rsM15aBad = $true
  try { Restore-MgmtBackup $auto $blM15a[0].id $true | Out-Null; $rsM15aBad = $false } catch { $rsM15aBad = $true }
  Assert ($rsM15aBad) 'R15 corrupt manual restore refused'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM15a 'AGENTS.md') -Raw) -match 'm15a-unique') 'R15 corrupt restore keeps current AGENTS'
  Assert (-not ((Get-Content -LiteralPath (Join-Path $repoM15a '.rulesync\rules\project-local.md') -Raw) -match 'CORRUPT-M15A')) 'R15 corrupt restore keeps current local'
  # Post-copy mutation: shadowed copy corrupts the backup between validation
  # and copy; the post-copy check rolls back to the original, staying paused.
  $repoM15b = New-Repo 'R15ManB'
  Set-Content -LiteralPath (Join-Path $repoM15b 'AGENTS.md') ($commonBody + "`nm15b-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoM15b '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoM15b '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nm15b-local") -Encoding UTF8
  $apprM15b = New-MgmtImportApproval $auto $repoM15b
  $impM15b = Register-MgmtImport $auto $repoM15b $null $true $apprM15b
  $blM15b = @(Get-MgmtBackupList $auto ([string]$impM15b.name))
  Set-Content -LiteralPath (Join-Path $repoM15b '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nm15b-drifted") -Encoding UTF8
  $origExpM15 = (Get-Command Copy-MgmtExpectedBytes).ScriptBlock
  $script:copyCorruptOnce = $true
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    if ($script:copyCorruptOnce -and ([string]$Src -match '\\backups\\')) {
      $script:copyCorruptOnce = $false
      Set-Content -LiteralPath $Src 'CORRUPT-MID-COPY' -Encoding Ascii
    }
    & $script:origExpM15 $Src $Dst $ExpectedHash $What
  }
  $script:origExpM15 = $origExpM15
  $rsM15bBad = $true; $rsM15bErr = ''
  try { Restore-MgmtBackup $auto $blM15b[0].id $true | Out-Null; $rsM15bBad = $false } catch { $rsM15bErr = $_.Exception.Message }
  Assert ($rsM15bBad) 'R15 mid-copy corruption aborts restore'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM15b '.rulesync\rules\project-local.md') -Raw) -match 'm15b-drifted') 'R15 mid-copy corruption restores pre-restore state'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impM15b.name) })[0]) -eq $false) 'R15 failed restore stays paused'
  . $SrvModule
  . $MgmtModule
  # R15 (r5 #3 module path): stale approval after a common change is refused
  # with no registry/local/AGENTS changes.
  $repoM15c = New-Repo 'R15ImpC'
  $curMain = Join-Path $scratch 'project-common-preview\.rulesync\rules\.curated\project.md'
  $curBak15 = Get-Content -LiteralPath $curMain -Raw -Encoding UTF8
  $cbMain = Get-CommonBody $auto
  Set-Content -LiteralPath (Join-Path $repoM15c 'AGENTS.md') ($cbMain + "`n`nm15c-unique") -Encoding Ascii
  $apprM15c = New-MgmtImportApproval $auto $repoM15c
  Set-Content -LiteralPath $curMain ($curBak15 + "`nm15c-common-drift") -Encoding UTF8
  $rsM15cBad = $true
  try { Register-MgmtImport $auto $repoM15c $null $true $apprM15c | Out-Null; $rsM15cBad = $false } catch { $rsM15cBad = $true }
  Assert ($rsM15cBad) 'R15 stale approval after common change refused'
  Assert ((@((Get-Registry $auto) | Where-Object { (Get-NormPath ([string]$_.path)) -eq (Get-NormPath $repoM15c) })).Count -eq 0) 'R15 refused import registers nothing'
  Assert (-not (Test-Path -LiteralPath (Join-Path $repoM15c '.rulesync\rules\project-local.md') -PathType Leaf)) 'R15 refused import writes no local file'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM15c 'AGENTS.md') -Raw) -match 'm15c-unique') 'R15 refused import leaves AGENTS intact'
  Set-Content -LiteralPath $curMain $curBak15 -Encoding UTF8
  # R16 (r6 #3): missing/malformed common is never an empty approval; a valid
  # empty body is still accepted.
  $s16root = Join-Path $scratch 's16'
  $autoS16 = Join-Path $s16root 'auto'
  $prevS16 = Join-Path $s16root 'project-common-preview'
  New-Item -ItemType Directory -Force -Path $autoS16 | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $prevS16 '.rulesync\rules\.curated') | Out-Null
  Set-Content -LiteralPath (Join-Path $autoS16 'projects.json') '[]' -Encoding Ascii
  $repoS16 = Join-Path $scratch 'S16Repo'
  New-Item -ItemType Directory -Force -Path $repoS16 | Out-Null
  Set-Content -LiteralPath (Join-Path $repoS16 'AGENTS.md') 's16-unique-body' -Encoding Ascii
  $apprS16Bad = $true
  try { New-MgmtImportApproval $autoS16 $repoS16 | Out-Null; $apprS16Bad = $false } catch { $apprS16Bad = $true }
  Assert ($apprS16Bad) 'R16 missing common creates no approval'
  Set-Content -LiteralPath (Join-Path $prevS16 '.rulesync\rules\.curated\project.md') ("---`nnotroot: true`n---`n`nsome-body") -Encoding UTF8
  $apprS16Bad2 = $true
  try { New-MgmtImportApproval $autoS16 $repoS16 | Out-Null; $apprS16Bad2 = $false } catch { $apprS16Bad2 = $true }
  Assert ($apprS16Bad2) 'R16 malformed common creates no approval'
  Set-Content -LiteralPath (Join-Path $prevS16 '.rulesync\rules\.curated\project.md') ("---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n") -Encoding UTF8
  $apprS16e = $null
  try { $apprS16e = New-MgmtImportApproval $autoS16 $repoS16 } catch { $apprS16e = $null }
  Assert ((($null -ne $apprS16e) -and ([string]$apprS16e.transcription).Contains('s16-unique-body'))) 'R16 valid empty common approval accepted'
  $impS16e = Register-MgmtImport $autoS16 $repoS16 $null $true $apprS16e
  Assert ((($impS16e.ok -eq $true) -and (@((Get-Registry $autoS16) | Where-Object { [string]$_.name -ceq ([string]$impS16e.name) })).Count -eq 1)) 'R16 valid empty common registers'
  # R16 (r6 #1): corrupt shelter never overwrites current files on rollback.
  $repoM16a = New-Repo 'R16ShelterA'
  Set-Content -LiteralPath (Join-Path $repoM16a 'AGENTS.md') ($commonBody + "`nm16a-unique") -Encoding Ascii
  $apprM16a = New-MgmtImportApproval $auto $repoM16a
  $impM16a = Register-MgmtImport $auto $repoM16a $null $true $apprM16a
  $blM16a = @(Get-MgmtBackupList $auto ([string]$impM16a.name))
  $origExpM16 = (Get-Command Copy-MgmtExpectedBytes).ScriptBlock
  $script:expCalls16 = 0
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    $script:expCalls16++
    if ($script:expCalls16 -eq 1) {
      $sh = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*-before-restore' } | Sort-Object CreationTime -Descending | Select-Object -First 1)
      if ($sh) { Set-Content -LiteralPath (Join-Path $sh[0].FullName 'AGENTS.md') 'CORRUPT-SHELTER' -Encoding Ascii }
      throw 'injected-restore-copy-fail'
    }
    & $script:origExpM16 $Src $Dst $ExpectedHash $What
  }
  $script:origExpM16 = $origExpM16
  $rsM16aBad = $true; $rsM16aErr = ''
  try { Restore-MgmtBackup $auto $blM16a[0].id $true | Out-Null; $rsM16aBad = $false } catch { $rsM16aErr = $_.Exception.Message }
  Assert ($rsM16aBad) 'R16 shelter-corrupt restore fails'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM16a 'AGENTS.md') -Raw) -match 'm16a-unique') 'R16 corrupt shelter never overwrites AGENTS'
  Assert (-not ((Get-Content -LiteralPath (Join-Path $repoM16a 'AGENTS.md') -Raw) -match 'CORRUPT')) 'R16 no corrupt bytes in current file'
  Assert (($rsM16aErr.Contains('巻戻し'))) 'R16 rollback failure reported explicitly'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impM16a.name) })[0]) -eq $false) 'R16 failed restore stays paused'
  # Local shelter corruption is likewise refused (agents restore still attempted).
  $repoM16b = New-Repo 'R16ShelterB'
  Set-Content -LiteralPath (Join-Path $repoM16b 'AGENTS.md') ($commonBody + "`nm16b-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoM16b '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoM16b '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nm16b-local") -Encoding UTF8
  $apprM16b = New-MgmtImportApproval $auto $repoM16b
  $impM16b = Register-MgmtImport $auto $repoM16b $null $true $apprM16b
  $blM16b = @(Get-MgmtBackupList $auto ([string]$impM16b.name))
  Set-Content -LiteralPath (Join-Path $repoM16b '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nm16b-drifted") -Encoding UTF8
  $script:expCalls16 = 0
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    $script:expCalls16++
    if ($script:expCalls16 -eq 2) {
      $sh2 = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*-before-restore' } | Sort-Object CreationTime -Descending | Select-Object -First 1)
      if ($sh2) { Set-Content -LiteralPath (Join-Path $sh2[0].FullName 'project-local.md') 'CORRUPT-SHELTER' -Encoding Ascii }
      throw 'injected-restore-copy-fail'
    }
    & $script:origExpM16 $Src $Dst $ExpectedHash $What
  }
  $rsM16bBad = $true; $rsM16bErr = ''
  try { Restore-MgmtBackup $auto $blM16b[0].id $true | Out-Null; $rsM16bBad = $false } catch { $rsM16bErr = $_.Exception.Message }
  Assert ($rsM16bBad) 'R16 local shelter-corrupt restore fails'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM16b 'AGENTS.md') -Raw) -match 'm16b-unique') 'R16 agents rollback still applied'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM16b '.rulesync\rules\project-local.md') -Raw) -match 'm16b-drifted') 'R16 corrupt local shelter keeps pre-restore state'
  Assert (-not ((Get-Content -LiteralPath (Join-Path $repoM16b '.rulesync\rules\project-local.md') -Raw) -match 'CORRUPT')) 'R16 no corrupt bytes in local file'
  Assert (($rsM16bErr.Contains('巻戻し'))) 'R16 local rollback failure reported explicitly'
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq ([string]$impM16b.name) })[0]) -eq $false) 'R16 local failed restore stays paused'
  # R17 (r7 #1): only verified bytes are ever published. A lying hasher plus
  # corrupt backup bodies must still refuse with originals intact.
  $repoM17a = New-Repo 'R17LieA'
  Set-Content -LiteralPath (Join-Path $repoM17a 'AGENTS.md') ($commonBody + "`nm17a-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoM17a '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoM17a '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nm17a-local") -Encoding UTF8
  $apprM17a = New-MgmtImportApproval $auto $repoM17a
  $impM17a = Register-MgmtImport $auto $repoM17a $null $true $apprM17a
  # R17: reset any wrappers left by earlier cases so originals are captured.
  . $SrvModule
  . $MgmtModule
  . $SrvModule
  . $MgmtModule
  # Normal backup must exist before fault injection.
  $blM17a = @(Get-MgmtBackupList $auto ([string]$impM17a.name))
  $bdirM17a = Join-Path $auto ('backups\' + $blM17a[0].id)
  $mfM17a = Get-Content -LiteralPath (Join-Path $bdirM17a 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $expAgentsM17 = [string]$mfM17a.agentsHash
  $expLocalM17 = [string]$mfM17a.localHash
  # Corrupt the backup bodies only after the normal backup is created.
  Set-Content -LiteralPath (Join-Path $bdirM17a 'AGENTS.md') 'ZZZ-CORRUPT-A' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bdirM17a 'project-local.md') 'ZZZ-CORRUPT-L' -Encoding Ascii
  # Fault injection: only the corrupted backup's hash inquiry returns the
  # manifest's normal (expected) value; every other call delegates to the
  # real implementation. Restore therefore reaches Copy-MgmtExpectedBytes
  # (which hashes the actual bytes itself) instead of early-rejecting.
  $script:bdirM17a = $bdirM17a
  $script:expAgentsM17 = $expAgentsM17
  $script:expLocalM17 = $expLocalM17
  $origHashM17 = (Get-Command Get-FileHashHex).ScriptBlock
  $script:origHashM17 = $origHashM17
  function Get-FileHashHex([string]$File) {
    try { $full = [System.IO.Path]::GetFullPath($File) } catch { $full = [string]$File }
    $bdirFull = [System.IO.Path]::GetFullPath($script:bdirM17a)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($bdirFull + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
      $leaf = [System.IO.Path]::GetFileName($full)
      if ($leaf -ceq 'AGENTS.md') { return $script:expAgentsM17 }
      if ($leaf -ceq 'project-local.md') { return $script:expLocalM17 }
    }
    return & $script:origHashM17 $File
  }
  # Wrap Copy-MgmtExpectedBytes to record reach count, delegating to original.
  $origExpM17 = (Get-Command Copy-MgmtExpectedBytes).ScriptBlock
  $script:expCalls17 = 0
  $script:origExpM17 = $origExpM17
  function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
    $script:expCalls17++
    & $script:origExpM17 $Src $Dst $ExpectedHash $What
  }
  $rsM17aBad = $true; $rsM17aErr = ''
  try { Restore-MgmtBackup $auto $blM17a[0].id $true | Out-Null; $rsM17aBad = $false } catch { $rsM17aBad = $true; $rsM17aErr = $_.Exception.Message }
  Assert ($rsM17aBad) 'R17 lying-hasher corrupt restore refused'
  Assert ($script:expCalls17 -ge 1) 'R17 Copy-MgmtExpectedBytes reached'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM17a 'AGENTS.md') -Raw) -match 'm17a-unique') 'R17 verified-bytes-only keeps AGENTS'
  Assert ((Get-Content -LiteralPath (Join-Path $repoM17a '.rulesync\rules\project-local.md') -Raw) -match 'm17a-local') 'R17 verified-bytes-only keeps local'
  Assert ((-not ((Get-Content -LiteralPath (Join-Path $repoM17a 'AGENTS.md') -Raw) -match 'ZZZ-CORRUPT')) -and (-not ((Get-Content -LiteralPath (Join-Path $repoM17a '.rulesync\rules\project-local.md') -Raw) -match 'ZZZ-CORRUPT'))) 'R17 no corrupt bytes published'
  Assert ($rsM17aErr -match '破損|復元しません') 'R17 expected refusal error'
  Remove-Item -Path 'function:Get-FileHashHex' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Copy-MgmtExpectedBytes' -Force -ErrorAction SilentlyContinue
  . $SrvModule
  . $MgmtModule
  . $SrvModule
  . $MgmtModule

  # R7 (r7 #3): staged CLI runs from the directory containing UseConfig.
  # The guard shim mirrors the installed rulesync32 resolver: --config must be
  # contained in the process cwd (path-traversal guard). Staged preview/apply
  # runs from the install cwd are rejected; runs from the config dir succeed.
  # Literal .Replace (never -replace) carries the $env:/$c/$r/$s batch text.
  $guardR7 = 'set CFGG=' + "`r`n" + 'set PREV2=' + "`r`n" + 'for %%A in (%*) do (' + "`r`n" + '  if "!PREV2!"=="--config" set CFGG=%%A' + "`r`n" + '  set PREV2=%%A' + "`r`n" + ')' + "`r`n" + 'if defined CFGG (' + "`r`n" + '  set CFGGU=!CFGG:"=!' + "`r`n" + '  powershell.exe -NoProfile -NonInteractive -Command "$c=[IO.Path]::GetFullPath($env:CFGGU);$r=[IO.Path]::GetFullPath((Get-Location).Path);$s=[IO.Path]::DirectorySeparatorChar;if($r[$r.Length-1]-ne$s){$r+=$s};if(-not $c.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){exit 1}else{exit 0}" >nul 2>&1' + "`r`n" + '  if errorlevel 1 (' + "`r`n" + '    echo Path traversal detected: "!CFGG!" 1>&2' + "`r`n" + '    endlocal & exit /b 1' + "`r`n" + '  )' + "`r`n" + ')'
  $guardAnchorR7 = 'echo npx %* [cwd=%CD%]>> "%D%\calls.log"'
  $h7p = New-R13Root 'cwdguard-prev'
  $shim7p = $stdShimR1.Replace($guardAnchorR7, ($guardAnchorR7 + "`r`n" + $guardR7))
  Assert (($shim7p.Contains('Path traversal detected'))) 'R7 guard shim armed (behavior, not source text)'
  Set-Content -LiteralPath (Join-Path $h7p.bin 'npx.cmd') $shim7p -Encoding Ascii
  Set-R13Exits $h7p @(0, 0, 0, 0, 0)
  Set-Content -LiteralPath (Join-Path $h7p.root 'run-r7p.ps1') $r13PrevRunner -Encoding Ascii
  $r7p = Invoke-R13Child $h7p (Join-Path $h7p.root 'run-r7p.ps1') 'exitcode-r13.txt'
  Assert ((($r7p.done -and ($r7p.code -ceq '0')))) 'R7 staged preview exits 0 from config dir'
  $plan7p = $null
  if (Test-Path -LiteralPath (Join-Path $h7p.auto 'dashboard.plan-13131313131313131313131313131313.json') -PathType Leaf) { $plan7p = Get-Content -LiteralPath (Join-Path $h7p.auto 'dashboard.plan-13131313131313131313131313131313.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert ((($null -ne $plan7p) -and (@($plan7p.projects | Where-Object { [string]$_.result -ceq 'success' }).Count -eq 2))) 'R7 staged preview publishes both successes'
  $cfgLines7 = @()
  try { $cfgLines7 = @(Get-Content -LiteralPath (Join-Path $h7p.root 'calls.log') | Where-Object { $_ -match '--config' }) } catch { $cfgLines7 = @() }
  Assert ((@($cfgLines7).Count -ge 4)) 'R7 staged generate calls logged'
  $cwdOk7 = $true
  foreach ($cl7 in $cfgLines7) {
    $mCfg = [regex]::Match([string]$cl7, '--config\s+(\S+)')
    $mCwd = [regex]::Match([string]$cl7, '\[cwd=(.+?)\]')
    if ((-not $mCfg.Success) -or (-not $mCwd.Success)) { $cwdOk7 = $false; break }
    $cfgParent7 = [System.IO.Path]::GetFullPath((Split-Path $mCfg.Groups[1].Value -Parent))
    $callCwd7 = [System.IO.Path]::GetFullPath($mCwd.Groups[1].Value)
    if (-not $cfgParent7.Equals($callCwd7, [System.StringComparison]::OrdinalIgnoreCase)) { $cwdOk7 = $false; break }
  }
  Assert ($cwdOk7) 'R7 every generate cwd is its config dir (both projects)'
  $stagedOnly7 = $true
  foreach ($cl7 in $cfgLines7) {
    $args7 = [string]$cl7
    $ix7 = $args7.IndexOf('[cwd=')
    if ($ix7 -ge 0) { $args7 = $args7.Substring(0, $ix7) }
    if (($args7 -notmatch 'staged') -or ($args7 -match 'project-common-preview')) { $stagedOnly7 = $false }
  }
  Assert ($stagedOnly7) 'R7 CLI consumes staged inputs only'
  Assert ((@(Get-Content -LiteralPath (Join-Path $h7p.root 'calls.log') | Where-Object { $_ -match '--input-root ' }).Count -eq 0)) 'R7 no deprecated singular input-root'
  # Plan-bound apply with the guard: staged check/dry-run/generate/final-check.
  $h7a = New-R13Root 'cwdguard-apply'
  Set-Content -LiteralPath (Join-Path $h7a.bin 'npx.cmd') $shim7p -Encoding Ascii
  Set-R13Exits $h7a @(0, 1, 0, 0, 0)
  New-R13Plan $h7a 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' @('projA') $null
  $req7a = New-R13Request $h7a 'cccccccccccccccccccccccccccccccc' @('projA') 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  Set-Content -LiteralPath (Join-Path $h7a.root 'run-r7a.ps1') $r13ApplyRunner -Encoding Ascii
  $r7a = Invoke-R13Child $h7a (Join-Path $h7a.root 'run-r7a.ps1') 'exitcode-r13.txt'
  Assert ((($r7a.done -and ($r7a.code -ceq '0')))) 'R7 plan-bound apply exits 0 from config dir'
  Assert (((Get-Content -LiteralPath (Join-Path $h7a.projA 'AGENTS.md') -Raw) -match 'agents-projA')) 'R7 applied AGENTS intact'
  $bk7a = 0
  if (Test-Path -LiteralPath (Join-Path $h7a.auto 'backups') -PathType Container) { $bk7a = @((Get-ChildItem -LiteralPath (Join-Path $h7a.auto 'backups') -Directory -ErrorAction SilentlyContinue)).Count }
  Assert (($bk7a -eq 1)) 'R7 apply keeps one backup'
  $st7a = Get-Content -LiteralPath (Join-Path $h7a.auto 'project-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (([string]$st7a.projects.projA.result -ceq 'success')) 'R7 apply status success'
  # Failure path: cwd restored to the install location, snapshot cleaned, and
  # the real CLI detail (not a generic message) lands in the failed plan.
  $h7f = New-R13Root 'cwdguard-fail'
  $shim7f = $shim7p.Replace('endlocal & exit /b %CODE%', ('if not "!CODE!"=="0" echo R7-CLI-BOOM-MARKER 1>&2' + "`r`n" + 'endlocal & exit /b %CODE%'))
  Assert (($shim7f.Contains('R7-CLI-BOOM-MARKER'))) 'R7 detail marker armed'
  Set-Content -LiteralPath (Join-Path $h7f.bin 'npx.cmd') $shim7f -Encoding Ascii
  Set-R13Exits $h7f @(0, 2, 0, 0)
  Set-Content -LiteralPath (Join-Path $h7f.root 'run-r7f.ps1') @'
$ErrorActionPreference = 'Stop'
$rr = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PATH = ((Join-Path $rr 'bin') + ';' + $env:PATH)
$env:DUMMY_DIR = $rr
$env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
. (Join-Path $rr 'auto\Sync-ProjectRules.ps1')
$pp = Join-Path $rr 'auto\dashboard.plan-77777777777777777777777777777777.json'
$enter7f = (Get-Location).Path
$c = Invoke-ProjectSync -PreviewOnly -PlanPath $pp
Set-Content -LiteralPath (Join-Path $rr 'exitcode-r7f.txt') ([string]$c) -Encoding Ascii
Set-Content -LiteralPath (Join-Path $rr 'cwd-r7f.txt') ((Get-Location).Path) -Encoding Ascii
Set-Content -LiteralPath (Join-Path $rr 'enter-r7f.txt') $enter7f -Encoding Ascii
exit $c
'@ -Encoding Ascii
  $r7f = Invoke-R13Child $h7f (Join-Path $h7f.root 'run-r7f.ps1') 'exitcode-r7f.txt'
  Assert ((($r7f.done -and ($r7f.code -ne '0')))) 'R7 failed preview exits non-zero'
  $cwd7f = ''
  if (Test-Path -LiteralPath (Join-Path $h7f.root 'cwd-r7f.txt') -PathType Leaf) { $cwd7f = (Get-Content -LiteralPath (Join-Path $h7f.root 'cwd-r7f.txt') -Raw -Encoding Ascii).Trim() }
  $enter7f = ''
  if (Test-Path -LiteralPath (Join-Path $h7f.root 'enter-r7f.txt') -PathType Leaf) { $enter7f = (Get-Content -LiteralPath (Join-Path $h7f.root 'enter-r7f.txt') -Raw -Encoding Ascii).Trim() }
  Assert ((($cwd7f -ne '') -and ($enter7f -ne '') -and ([System.IO.Path]::GetFullPath($cwd7f).Equals([System.IO.Path]::GetFullPath($enter7f), [System.StringComparison]::OrdinalIgnoreCase)))) 'R7 cwd fully restored after failure (outer+inner balanced)'
  $cfgLines7f = @()
  try { $cfgLines7f = @(Get-Content -LiteralPath (Join-Path $h7f.root 'calls.log') | Where-Object { $_ -match '--config' }) } catch { $cfgLines7f = @() }
  $cwdOk7f = (@($cfgLines7f).Count -ge 1)
  foreach ($cl7 in $cfgLines7f) {
    $mCfg = [regex]::Match([string]$cl7, '--config\s+(\S+)')
    $mCwd = [regex]::Match([string]$cl7, '\[cwd=(.+?)\]')
    if ((-not $mCfg.Success) -or (-not $mCwd.Success)) { $cwdOk7f = $false; break }
    $cfgParent7 = [System.IO.Path]::GetFullPath((Split-Path $mCfg.Groups[1].Value -Parent))
    $callCwd7 = [System.IO.Path]::GetFullPath($mCwd.Groups[1].Value)
    if (-not $cfgParent7.Equals($callCwd7, [System.StringComparison]::OrdinalIgnoreCase)) { $cwdOk7f = $false; break }
  }
  Assert ($cwdOk7f) 'R7 failure-path generate cwds are their config dirs'
  $left7f = @()
  if (Test-Path -LiteralPath (Join-Path $h7f.auto 'snapshots') -PathType Container) { $left7f = @(Get-ChildItem -LiteralPath (Join-Path $h7f.auto 'snapshots') -Filter 'ProjectSyncSnap-*' -ErrorAction SilentlyContinue) }
  Assert ((@($left7f).Count -eq 0)) 'R7 no snapshot leaks after failure'
  $plan7f = $null
  if (Test-Path -LiteralPath (Join-Path $h7f.auto 'dashboard.plan-77777777777777777777777777777777.json') -PathType Leaf) { $plan7f = Get-Content -LiteralPath (Join-Path $h7f.auto 'dashboard.plan-77777777777777777777777777777777.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
  $row7fA = $null
  if ($null -ne $plan7f) { $row7fA = @($plan7f.projects | Where-Object { [string]$_.name -ceq 'projA' })[0] }
  Assert ((($null -ne $row7fA) -and ([string]$row7fA.result -cne 'success') -and ([string]$row7fA.error -match 'R7-CLI-BOOM-MARKER'))) 'R7 failed plan carries real CLI detail'
  Assert ((([string]$row7fA.error).Length -lt 1200)) 'R7 failure detail is bounded (no full dump)'
  Assert (-not (([string]$row7fA.error).Contains('dummy-pre-token-AAA'))) 'R7 failure detail carries no raw secret'
  $row7fB = @($plan7f.projects | Where-Object { [string]$_.name -ceq 'projB' })[0]
  Assert (([string]$row7fB.result -ceq 'success')) 'R7 sibling project still succeeds after failure'
  # R7e: installed rulesync32 offline fixture (direct node, no npx/network).
  # Same-drive non-ancestor cwd must fail the config guard; the config dir
  # must dry-run, generate one AGENTS artifact, and parse both markers.
  # Resolve node and the rulesync 32 package from this machine so the checkout
  # is not tied to one user profile. One `npx --yes rulesync@32.0.0` populates the cache.
  $nodeCmd7 = Get-Command node -ErrorAction SilentlyContinue
  $nodeExe7 = ''
  if ($null -ne $nodeCmd7) { $nodeExe7 = [string]$nodeCmd7.Source }
  # npm may keep its cache outside %LOCALAPPDATA% (npm_config_cache env or .npmrc),
  # so ask npm for the effective cache dir before falling back to the default.
  $cacheRoots7 = @()
  $npmCmd7 = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($null -eq $npmCmd7) { $npmCmd7 = Get-Command npm -ErrorAction SilentlyContinue }
  if ($null -ne $npmCmd7) {
    $prevEap7 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      foreach ($line7 in @(& $npmCmd7.Source config get cache 2>$null)) {
        $t7 = ([string]$line7).Trim()
        if ($t7.Length -gt 0) { $cacheRoots7 += $t7 }
      }
    } catch { } finally { $ErrorActionPreference = $prevEap7 }
  }
  $cacheRoots7 += (Join-Path $env:LOCALAPPDATA 'npm-cache')
  $cliJs7 = ''
  foreach ($cacheRoot7 in @($cacheRoots7 | Select-Object -Unique)) {
    $npxRoot7 = Join-Path $cacheRoot7 '_npx'
    if (-not (Test-Path -LiteralPath $npxRoot7 -PathType Container)) { continue }
    foreach ($d7 in @(Get-ChildItem -LiteralPath $npxRoot7 -Directory -ErrorAction SilentlyContinue)) {
      $pkgDir7 = Join-Path $d7.FullName 'node_modules\rulesync'
      $js7 = Join-Path $pkgDir7 'dist\cli\index.js'
      $json7 = Join-Path $pkgDir7 'package.json'
      if (-not ((Test-Path -LiteralPath $js7 -PathType Leaf) -and (Test-Path -LiteralPath $json7 -PathType Leaf))) { continue }
      $ver7 = ''
      try { $ver7 = [string](Get-Content -LiteralPath $json7 -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $ver7 = '' }
      if ($ver7 -like '32.*') { $cliJs7 = $js7; break }
    }
    if ($cliJs7) { break }
  }
  $have7 = (($nodeExe7.Length -gt 0) -and (Test-Path -LiteralPath $nodeExe7 -PathType Leaf) -and ($cliJs7.Length -gt 0) -and (Test-Path -LiteralPath $cliJs7 -PathType Leaf))
  if ($have7) { Assert $have7 'R7e installed rulesync32 tool present (offline)' }
  else { Write-Host 'SKIP: R7e installed rulesync32 tool present (offline) - node is not on PATH or rulesync 32 is not in the npx cache (run `npx --yes rulesync@32.0.0` once)' }
  if ($have7) {
    $fx7 = Join-Path $scratch ('cli32-' + [System.Guid]::NewGuid().ToString('N'))
    $st7 = Join-Path $fx7 'staged'
    $cm7 = Join-Path $st7 'common\.rulesync\rules\.curated'
    $ow7 = Join-Path $fx7 'out-wrong'
    $or7 = Join-Path $fx7 'out-right'
    New-Item -ItemType Directory -Force -Path (Join-Path $st7 'rules'), $cm7, $ow7, $or7 | Out-Null
    Assert ((Test-ContainedLocal $fx7 $scratch)) 'R7e fixture contained in own scratch'
    Set-Content -LiteralPath (Join-Path $st7 'rulesync.jsonc') '{"targets":["codexcli","opencode"],"features":["rules"],"outputRoots":["output"],"delete":false,"global":false,"sources":[]}' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $cm7 'project.md') ("---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nr7e-common-marker") -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $st7 'rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nr7e-local-marker") -Encoding UTF8
    $cfg7 = Join-Path $st7 'rulesync.jsonc'
    $r7root1 = Join-Path $st7 'common\.rulesync'
    Assert (([System.IO.Path]::GetPathRoot($fx7) -ceq [System.IO.Path]::GetPathRoot($env:SystemRoot))) 'R7e same-drive precondition for guard repro'
    # Native stderr arrives as error records: Continue keeps them captured
    # (same idiom as the module's own dry-run capture), Stop would abort here.
    $prevEap7 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $env:SystemRoot
    try { $wOut7 = & $nodeExe7 $cliJs7 @('generate', '--config', $cfg7, '--input-roots', $r7root1, $st7, '--output-roots', $ow7, '--targets', 'codexcli,opencode', '--features', 'rules', '--dry-run') 2>&1 | Out-String; $wCode7 = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap7; Pop-Location }
    if ($null -eq $wCode7) { $wCode7 = 1 }
    Assert ((($wCode7 -ne 0) -and ($wOut7 -match 'Path traversal'))) 'R7e wrong cwd fails config guard (repro)'
    Push-Location $st7
    $prevEap7 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $dOut7 = & $nodeExe7 $cliJs7 @('generate', '--config', $cfg7, '--input-roots', $r7root1, $st7, '--output-roots', $or7, '--targets', 'codexcli,opencode', '--features', 'rules', '--dry-run') 2>&1 | Out-String; $dCode7 = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap7; Pop-Location }
    if ($null -eq $dCode7) { $dCode7 = 1 }
    Assert ((($dCode7 -eq 0) -and ($dOut7 -match 'Would write:'))) 'R7e config-dir dry-run plans writes'
    Push-Location $st7
    $prevEap7 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $gOut7 = & $nodeExe7 $cliJs7 @('generate', '--config', $cfg7, '--input-roots', $r7root1, $st7, '--output-roots', $or7, '--targets', 'codexcli,opencode', '--features', 'rules') 2>&1 | Out-String; $gCode7 = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap7; Pop-Location }
    if ($null -eq $gCode7) { $gCode7 = 1 }
    $gen7 = Join-Path $or7 'AGENTS.md'
    $files7 = @(Get-ChildItem -LiteralPath $or7 -Recurse -Force -ErrorAction SilentlyContinue)
    Assert ((($gCode7 -eq 0) -and (@($files7).Count -eq 1) -and (Test-Path -LiteralPath $gen7 -PathType Leaf))) 'R7e config-dir generate writes one AGENTS artifact'
    $body7 = ''
    if (Test-Path -LiteralPath $gen7 -PathType Leaf) { $body7 = Get-Content -LiteralPath $gen7 -Raw -Encoding UTF8 }
    Assert ((($body7 -match 'r7e-common-marker') -and ($body7 -match 'r7e-local-marker'))) 'R7e generated artifact carries both markers'
    Assert (((Get-Location).Path -ceq $initCwd)) 'R7e fixture cwd restored'
    if (Test-Path -LiteralPath $fx7) {
      if (-not (Test-ContainedLocal $fx7 $scratch)) { throw 'R7e cleanup outside scratch refused' }
      Remove-Item -LiteralPath $fx7 -Recurse -Force
    }
    Assert (-not (Test-Path -LiteralPath $fx7)) 'R7e only own fixture removed'
  }

  # R1d: plan-bound sync through live HTTP (server pre-check).
  $repoRL1 = New-Repo 'R1Live'
  Set-Content -LiteralPath (Join-Path $repoRL1 'AGENTS.md') ($commonBody + "`nr1live-unique") -Encoding Ascii
  New-Item -ItemType Directory -Force -Path (Join-Path $repoRL1 '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoRL1 '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nr1live-local") -Encoding UTF8
  Write-RegistryAtomicLocked $auto @(@((Get-Registry $auto)) + [pscustomobject]@{ name = 'R1Live'; path = $repoRL1; displayName = 'R1Live' })
  $planIdL1 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  $liveL1 = Get-MgmtPlanLive $auto
  $entL1 = @($liveL1.entries | Where-Object { [string]$_.name -ceq 'R1Live' })[0]
  $planL1 = @{
    schemaVersion = 2
    commonSha = [string]$liveL1.commonSha; commonCommit = $null
    commonText = [string]$liveL1.commonText
    configHash = [string]$liveL1.configHash; targets = [string]$liveL1.targets
    createdAt = ([DateTime]::UtcNow.ToString('o'))
    inputs = @{ entries = @(@{ name = 'R1Live'; path = [string]$entL1.path; enabled = [bool]$entL1.enabled; localExists = [bool]$entL1.localExists; localHash = [string]$entL1.localHash; agentsExists = [bool]$entL1.agentsExists; agentsHash = [string]$entL1.agentsHash }) }
    projects = @(@{ name = 'R1Live'; path = [string]$entL1.path; result = 'success'; currentText = 'x'; generatedText = 'y'; agentsHash = [string]$entL1.agentsHash; localHash = [string]$entL1.localHash; commonSha = [string]$liveL1.commonSha; commonCommit = $null; configHash = [string]$liveL1.configHash; error = '' })
  }
  Set-Content -LiteralPath (Join-Path $auto ("dashboard.plan-" + $planIdL1 + ".json")) (ConvertTo-Json -InputObject $planL1 -Depth 8 -Compress) -Encoding Ascii
  $env:DASHBOARD_PORT = '18796'
  $srvR1 = $null
  try {
    $srvR1 = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $srvPath -WindowStyle Hidden -PassThru
    $okR1 = $false
    for ($iR1 = 0; $iR1 -lt 40; $iR1++) {
      Start-Sleep -Milliseconds 500
      try {
        $hr1 = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18796/health'
        if ($hr1.StatusCode -eq 200) { $okR1 = $true; break }
      } catch {}
      if ($srvR1.HasExited) { break }
    }
    Assert ($okR1) 'R1 live server health'
    Assert (-not $srvR1.HasExited) 'R1 live server is ours (port bound)'
    if ($okR1 -and (-not $srvR1.HasExited)) {
      $tokR1 = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $hdrsR1 = @{ 'X-Dashboard-Token' = $tokR1 }
      function PostR1([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $hdrsR1 -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18796' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      $syR1 = PostR1 '/api/sync' @{ projectNames = @('R1Live'); planId = $planIdL1 }
      Assert ((($syR1.sync -ceq 'started') -and ([string]$syR1.planId -ceq $planIdL1))) 'R1 plan-bound sync starts with plan id'
      Set-MgmtEnabled $auto 'R1Live' $false
      $syDis = $true; $syDisCode = 0
      try { PostR1 '/api/sync' @{ projectNames = @('R1Live'); planId = $planIdL1 } | Out-Null; $syDis = $false } catch { $syDisCode = $_.Exception.Response.StatusCode.value__; $syDis = ($syDisCode -eq 400) }
      Assert ($syDis) 'R1 live enabled drift refused with 400'
      Set-MgmtEnabled $auto 'R1Live' $true
      $curatedMain = Join-Path $scratch 'project-common-preview\.rulesync\rules\.curated\project.md'
      $curBak = Get-Content -LiteralPath $curatedMain -Raw -Encoding UTF8
      Set-Content -LiteralPath $curatedMain ($curBak + "`nr1live-drift") -Encoding UTF8
      $syCom = $true
      try { PostR1 '/api/sync' @{ projectNames = @('R1Live'); planId = $planIdL1 } | Out-Null; $syCom = $false } catch { $syCom = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($syCom) 'R1 live common drift refused with 400'
      Set-Content -LiteralPath $curatedMain $curBak -Encoding UTF8
      $syUnk = $true
      try { PostR1 '/api/sync' @{ projectNames = @('R1Live'); planId = ('f' * 32) } | Out-Null; $syUnk = $false } catch { $syUnk = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($syUnk) 'R1 live unknown plan id refused with 400'
      (Get-Item -LiteralPath (Join-Path $auto ("dashboard.plan-" + $planIdL1 + ".json"))).LastWriteTime = ((Get-Date).AddMinutes(-130))
      $syStale = $true
      try { PostR1 '/api/sync' @{ projectNames = @('R1Live'); planId = $planIdL1 } | Out-Null; $syStale = $false } catch { $syStale = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($syStale) 'R1 live stale plan refused with 400'
    }
  } finally {
    try { if ($srvR1 -and (-not $srvR1.HasExited)) { Stop-Process -Id $srvR1.Id -Force } } catch {}
    Start-Sleep -Milliseconds 500
    try {
      $aliveR1 = $false
      try { $aliveR1 = (-not (Get-Process -Id $srvR1.Id -ErrorAction Stop).HasExited) } catch { $aliveR1 = $false }
      Assert (-not $aliveR1) 'R1 live server stopped'
    } catch {}
  }
  # R1e: plan attach helper unions selection with the ready plan only on exact match.
  if ($nodeExe) {
    $r1ejs = Join-Path $scratch 'r1e-plan.js'
    Set-Content -LiteralPath $r1ejs @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
var m = src.match(/function planIdForSelection\(names\)\{[\s\S]*?\n\}/);
if (!m) { console.log('FAIL: planIdForSelection not found'); process.exit(1); }
var lastPlan = null;
eval(m[0]);
lastPlan = { id: 'pid1', names: ['B', 'A'] };
ok(planIdForSelection(['A', 'B']) === 'pid1', 'R1e matching selection attaches plan');
ok(planIdForSelection(['A']) === null, 'R1e subset does not attach');
ok(planIdForSelection(['A', 'C']) === null, 'R1e different selection does not attach');
ok(planIdForSelection([]) === null, 'R1e empty selection does not attach');
lastPlan = null;
ok(planIdForSelection(['A', 'B']) === null, 'R1e no plan does not attach');
if (fails.length) process.exit(1);
console.log('ALL R1E CHECKS PASSED');
'@ -Encoding UTF8
    & $nodeExe $r1ejs $srvPath
    Assert ($LASTEXITCODE -eq 0) 'R1 plan attach helper via node harness'
  }
  # R-new: redacted editor text must never be saved as original.
  $repoRN = New-Repo 'RNew'
  New-Item -ItemType Directory -Force -Path (Join-Path $repoRN '.rulesync\rules') | Out-Null
  Write-RegistryAtomicLocked $auto @(@((Get-Registry $auto)) + [pscustomobject]@{ name = 'RNew'; path = $repoRN; displayName = 'RNew' })
  $env:DASHBOARD_PORT = '18795'
  $srvRN = $null
  try {
    $srvRN = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $srvPath -WindowStyle Hidden -PassThru
    $okRN = $false
    for ($iRN = 0; $iRN -lt 40; $iRN++) {
      Start-Sleep -Milliseconds 500
      try {
        $hrn = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18795/health'
        if ($hrn.StatusCode -eq 200) { $okRN = $true; break }
      } catch {}
      if ($srvRN.HasExited) { break }
    }
    Assert ($okRN) 'R-new live server health'
    Assert (-not $srvRN.HasExited) 'R-new live server is ours (port bound)'
    if ($okRN -and (-not $srvRN.HasExited)) {
      $tokRN = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $hdrsRN = @{ 'X-Dashboard-Token' = $tokRN }
      function PostRN([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $hdrsRN -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18795' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      $ordText = "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nUse bearer authentication.`nplain-tail"
      Set-Content -LiteralPath (Join-Path $repoRN '.rulesync\rules\project-local.md') $ordText -Encoding UTF8
      $hashOrd = Get-FileHashHex (Join-Path $repoRN '.rulesync\rules\project-local.md')
      $getOrd = PostRN '/api/localrule-get' @{ name = 'RNew' }
      Assert ((($getOrd.text -match '\*\*\*') -and ($getOrd.redacted -eq $true))) 'R-new ordinary bearer line is masked with flag'
      $svOrdBad = $true
      try { PostRN '/api/localrule-save' @{ name = 'RNew'; text = [string]$getOrd.text; expectedHash = [string]$getOrd.hash } | Out-Null; $svOrdBad = $false } catch { $svOrdBad = ($_.Exception.Response.StatusCode.value__ -eq 409) }
      Assert ($svOrdBad) 'R-new masked roundtrip refused with 409'
      Assert (((Get-FileHashHex (Join-Path $repoRN '.rulesync\rules\project-local.md')) -ceq $hashOrd)) 'R-new refused save leaves original intact'
      $plainText = "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`njust ordinary lines here"
      Set-Content -LiteralPath (Join-Path $repoRN '.rulesync\rules\project-local.md') $plainText -Encoding UTF8
      $getPl = PostRN '/api/localrule-get' @{ name = 'RNew' }
      Assert ((($getPl.redacted -eq $false) -and ([string]$getPl.text -match 'ordinary lines'))) 'R-new unmasked fetch carries flag false'
      $svPl = PostRN '/api/localrule-save' @{ name = 'RNew'; text = ([string]$getPl.text + "`nappended"); expectedHash = [string]$getPl.hash }
      Assert ((($svPl.ok -eq $true) -and ((Get-Content -LiteralPath (Join-Path $repoRN '.rulesync\rules\project-local.md') -Raw) -match 'appended'))) 'R-new unmasked edit saves'
      $secText = "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nnote with secret " + $tokRN + " inside"
      Set-Content -LiteralPath (Join-Path $repoRN '.rulesync\rules\project-local.md') $secText -Encoding UTF8
      $hashSec = Get-FileHashHex (Join-Path $repoRN '.rulesync\rules\project-local.md')
      $getSec = PostRN '/api/localrule-get' @{ name = 'RNew' }
      Assert ((($getSec.redacted -eq $true) -and ([string]$getSec.text -match '\*\*\*'))) 'R-new token masked with flag'
      Assert ((-not ([string]$getSec.text).Contains($tokRN))) 'R-new token absent from display text'
      $svSecBad = $true
      try { PostRN '/api/localrule-save' @{ name = 'RNew'; text = [string]$getSec.text; expectedHash = [string]$getSec.hash } | Out-Null; $svSecBad = $false } catch { $svSecBad = ($_.Exception.Response.StatusCode.value__ -eq 409) }
      Assert ($svSecBad) 'R-new masked secret save refused with 409'
      Assert (((Get-FileHashHex (Join-Path $repoRN '.rulesync\rules\project-local.md')) -ceq $hashSec)) 'R-new refused save preserves secret file'
    }
  } finally {
    try { if ($srvRN -and (-not $srvRN.HasExited)) { Stop-Process -Id $srvRN.Id -Force } } catch {}
    Start-Sleep -Milliseconds 500
    try {
      $aliveRN = $false
      try { $aliveRN = (-not (Get-Process -Id $srvRN.Id -ErrorAction Stop).HasExited) } catch { $aliveRN = $false }
      Assert (-not $aliveRN) 'R-new live server stopped'
    } catch {}
  }
  if ($nodeExe) {
    $rnewjs = Join-Path $scratch 'rnew-notice.js'
    Set-Content -LiteralPath $rnewjs @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
var m = src.match(/function localRedactNotice\(r\)\{[\s\S]*?\n\}/);
if (!m) { console.log('FAIL: localRedactNotice not found'); process.exit(1); }
function L(s) { return s; }
eval(m[0]);
ok(localRedactNotice({ redacted: true }).length > 0, 'R-new notice shown when redacted');
ok(localRedactNotice({ redacted: false }) === '', 'R-new no notice when clean');
ok(localRedactNotice(null) === '', 'R-new no notice on null');
if (fails.length) process.exit(1);
console.log('ALL RNEW CHECKS PASSED');
'@ -Encoding UTF8
    & $nodeExe $rnewjs $srvPath
    Assert ($LASTEXITCODE -eq 0) 'R-new notice helper via node harness'
  }
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'only own scratch removed'
  Assert (Test-Path -LiteralPath $base) 'base left intact'
}
finally {
  $env:DASHBOARD_AUTODIR = $origAuto
  if ($null -eq $origAuto) { Remove-Item Env:DASHBOARD_AUTODIR -ErrorAction SilentlyContinue }
  $env:DASHBOARD_PORT = $origPort
  if ($null -eq $origPort) { Remove-Item Env:DASHBOARD_PORT -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL REVIEWFIX CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
