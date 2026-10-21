# Test-GlobalReviewRound7.ps1 - round7 finding (RED then GREEN), tracked.
# F1: a trusted root that ends with a separator (HOME_DIR='C:\...\home\') must
#     compare equal to the separator-less walk paths during missing-parent
#     recreation: both-provider-absent restore works with a trailing root, a
#     drive root keeps its separator (C:\ not C:), UNC spellings stay equal,
#     and a linked target still refuses with the external dir untouched.
# F2: sync rollback with a trailing-separator HOME_DIR recreates a provider
#     folder removed during generate and restores the pre-run bytes.
# Scratch-only. Never touches real home, tasks, registry, or deployed AppData.
# Scheduler cmdlets are shadowed at script scope; the product helpers always
# run for real.
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
$origPath = $env:PATH
$devAuto = Split-Path -Parent $PSScriptRoot
try {
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalReviewRound7Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))

  function New-R7Case([string]$Tag) {
    $c = Join-Path $scratch $Tag
    $auto = Join-Path $c 'auto'
    $fakeHome = Join-Path $c 'home'
    New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
    $gprev = Join-Path $c 'global-preview'
    New-Item -ItemType Directory -Force -Path $gprev | Out-Null
    Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"x":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $c 'outside.txt') 'outside-R7-marker' -Encoding Ascii
    return @{ root = $c; auto = $auto; home = $fakeHome; gprev = $gprev }
  }
  function Install-R7Sync([string]$Auto) {
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $Auto 'Sync-GlobalRules.ps1') -Force
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $Auto 'Global-Management.ps1') -Force
  }
  function Install-R7Bin([string]$CaseRoot, [string]$FakeBody) {
    $bin = Join-Path $CaseRoot 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'npx-fake.ps1') $FakeBody -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $bin 'npx.cmd') ('@echo off' + "`r`n" + 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0npx-fake.ps1" %*' + "`r`n" + 'exit /b %ERRORLEVEL%') -Encoding Ascii
    return $bin
  }
  function Get-R7Text([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    return (Get-Content -LiteralPath $File -Raw -Encoding UTF8)
  }

  # ---- F1a: trailing-separator home, both provider folders deleted after the
  # backup -> the diff binds absent current and restore recreates both folders.
  $sA = New-R7Case 'f1a'
  $trailA = $sA.home + '\'
  Set-Content -LiteralPath (Join-Path $sA.home '.codex\AGENTS.md') 'codex-F1a' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sA.home '.config\opencode\AGENTS.md') 'opencode-F1a' -Encoding Ascii
  $bkA = New-GlobalBackup $sA.auto $trailA @('codexcli', 'opencode')
  $idA = Split-Path $bkA -Leaf
  Remove-Item -LiteralPath (Join-Path $sA.home '.codex') -Recurse -Force
  Remove-Item -LiteralPath (Join-Path $sA.home '.config') -Recurse -Force
  $bdA = $null
  $bdAErr = ''
  try { $bdA = Get-GlobalBackupDiff $sA.auto $idA $trailA } catch { $bdAErr = $_.Exception.Message }
  Assert (($null -ne $bdA) -and ([string]$bdA.confirmId -match '^[0-9a-f]{32}$')) ('R7-F1a diff binds both providers absent under a trailing root (' + $bdAErr + ')')
  $rsA = $null
  $rsAErr = ''
  try { $rsA = Restore-GlobalBackup $sA.auto $idA $true $trailA ([string]$bdA.confirmId) } catch { $rsAErr = $_.Exception.Message }
  Assert (($null -ne $rsA) -and ($rsA.ok -eq $true)) ('R7-F1a trailing root restore recreates both missing provider folders (' + $rsAErr + ')')
  Assert ((Get-R7Text (Join-Path $sA.home '.codex\AGENTS.md')).Contains('codex-F1a')) 'R7-F1a codex bytes restored after folder recreation'
  Assert ((Get-R7Text (Join-Path $sA.home '.config\opencode\AGENTS.md')).Contains('opencode-F1a')) 'R7-F1a opencode bytes restored after folder recreation'
  $dA1 = Get-Item -LiteralPath (Join-Path $sA.home '.codex') -Force -ErrorAction SilentlyContinue
  $dA2 = Get-Item -LiteralPath (Join-Path $sA.home '.config\opencode') -Force -ErrorAction SilentlyContinue
  Assert (((($null -ne $dA1) -and ($null -ne $dA2)) -and ((($dA1.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) -and ((($dA2.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)))) 'R7-F1a recreated folders are real directories'
  Assert ((Get-R7Text (Join-Path $sA.root 'outside.txt')).Contains('outside-R7-marker')) 'R7-F1a outside home untouched'

  # ---- F1b: canonical comparison form: drive root keeps its separator, deep
  # and UNC roots compare equal with and without the trailing separator.
  $canonOk = $false
  $driveK = ''
  $deepT = ''
  $deepP = ''
  $uncT = ''
  $uncP = ''
  try {
    $driveK = [string](Global-RootCanonical 'C:\')
    $deepT = [string](Global-RootCanonical 'C:\Scratch\yy\')
    $deepP = [string](Global-RootCanonical 'C:\Scratch\yy')
    $uncT = [string](Global-RootCanonical '\\srv\share\')
    $uncP = [string](Global-RootCanonical '\\srv\share')
    $canonOk = $true
  } catch { $canonOk = $false }
  Assert ($canonOk) 'R7-F1b canonical helper available for drive and UNC roots'
  Assert (($canonOk -and ($driveK -ceq 'C:\'))) 'R7-F1b drive root keeps its separator (C:\ stays C:\)'
  Assert (($canonOk -and ($deepT -ceq 'C:\Scratch\yy'))) 'R7-F1b deep root drops only the trailing separator'
  Assert (($canonOk -and ($deepT -ceq $deepP))) 'R7-F1b deep root equal with and without trailing separator'
  Assert (($canonOk -and ($uncT -ceq $uncP))) 'R7-F1b UNC root equal with and without trailing separator'

  # ---- F1c: linked target still refuses under a trailing root, external dir untouched.
  $sC = New-R7Case 'f1c'
  $trailC = $sC.home + '\'
  Set-Content -LiteralPath (Join-Path $sC.home '.codex\AGENTS.md') 'codex-F1c' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sC.home '.config\opencode\AGENTS.md') 'opencode-F1c' -Encoding Ascii
  $bkC = New-GlobalBackup $sC.auto $trailC @('codexcli', 'opencode')
  $idC = Split-Path $bkC -Leaf
  $bdC = Get-GlobalBackupDiff $sC.auto $idC $trailC
  $extC = Join-Path $sC.root 'extC'
  New-Item -ItemType Directory -Force -Path $extC | Out-Null
  Set-Content -LiteralPath (Join-Path $extC 'AGENTS.md') 'extC-marker' -Encoding Ascii
  $ocodeC = Join-Path $sC.home '.config\opencode'
  Remove-Item -LiteralPath $ocodeC -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $ocodeC + '" "' + $extC + '"') | Out-Null
  $refC = $false
  $refCMsg = ''
  try { Restore-GlobalBackup $sC.auto $idC $true $trailC ([string]$bdC.confirmId) | Out-Null } catch { $refC = $true; $refCMsg = $_.Exception.Message }
  Assert ($refC) 'R7-F1c linked destination parent still refuses restore under a trailing root'
  Assert ($refCMsg.Contains('リンク')) ('R7-F1c refusal reason is the link (' + $refCMsg + ')')
  Assert ((Get-R7Text (Join-Path $extC 'AGENTS.md')).Contains('extC-marker')) 'R7-F1c external file never written through the link'
  Assert ((Get-R7Text (Join-Path $sC.home '.codex\AGENTS.md')).Contains('codex-F1c')) 'R7-F1c refused restore left the other target unapplied'
  & $cmdExe /c ('rmdir "' + $ocodeC + '"') | Out-Null

  # ---- F2: sync rollback with a trailing-separator HOME_DIR: generate removes
  # the provider folder, the final check fails, and the rollback must recreate
  # the folder and restore the pre-run bytes.
  $sB = New-R7Case 'f2rb'
  $trailB = $sB.home + '\'
  Set-Content -LiteralPath (Join-Path $sB.home '.codex\AGENTS.md') 'codex-R7rb-orig' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sB.home '.config\opencode\AGENTS.md') 'opencode-R7rb-orig' -Encoding Ascii
  Set-GlobalTargets $sB.auto @('codexcli', 'opencode') | Out-Null
  Install-R7Sync $sB.auto
  . (Join-Path $sB.auto 'Sync-GlobalRules.ps1')
  $binB = Install-R7Bin $sB.root @'
param([string[]]$RestArgs)
$ErrorActionPreference = 'Stop'
$argsAll = @($RestArgs) + @($args)
function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like ('*' + $S + '*')) { return $true } }; return $false }
$log = Join-Path $env:FAKE_AUTO_DIR 'fake-cli-calls.txt'
Add-Content -LiteralPath $log (($argsAll -join ' ') + "`n") -Encoding Ascii
if ((Has 'install')) { exit 0 }
if ((Has '--check') -and (-not (Has '--dry-run'))) { exit 1 }
if (Has '--dry-run') { exit 0 }
if (Has 'generate') {
  $cdir = Join-Path $env:FAKE_HOME_DIR '.codex'
  try { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  exit 0
}
exit 0
'@
  $env:PATH = ($binB + ';' + $origPath)
  $env:HOME_DIR = $trailB
  $env:FAKE_AUTO_DIR = $sB.auto
  $env:FAKE_HOME_DIR = $sB.home
  $env:GITHUB_TOKEN = 'gh-test-R7rb'
  $codeB = Invoke-GlobalSync -TargetNames @('codexcli', 'opencode')
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $stB = Get-GlobalStatus $sB.auto
  $errB = [string]$stB.providers['codexcli'].error
  Assert (($codeB -ne 0)) 'R7-F2 final check failure keeps sync failed'
  Assert ((Get-R7Text (Join-Path $sB.home '.codex\AGENTS.md')).Contains('codex-R7rb-orig')) 'R7-F2 rollback recreates the folder removed during generate and restores bytes'
  $dB = Get-Item -LiteralPath (Join-Path $sB.home '.codex') -Force -ErrorAction SilentlyContinue
  Assert ((($null -ne $dB) -and ((($dB.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)))) 'R7-F2 recreated folder is a real directory'
  Assert ((-not $errB.Contains('rollback also failed'))) ('R7-F2 rollback reports no failure (' + $errB + ')')
  Assert ($errB.Contains('restored backup')) ('R7-F2 status records the restored backup (' + $errB + ')')
  Assert ((Get-R7Text (Join-Path $sB.home '.config\opencode\AGENTS.md')).Contains('opencode-R7rb-orig')) 'R7-F2 untouched provider keeps its pre-run bytes'
  Assert ((Get-R7Text (Join-Path $sB.root 'outside.txt')).Contains('outside-R7-marker')) 'R7-F2 outside home untouched'
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue

  Assert (((Get-Location).Path) -eq $initCwd) 'R7 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'R7 only own GUID scratch removed'
}
finally {
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL R7 REVIEW CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
