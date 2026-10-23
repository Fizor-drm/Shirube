# Self-check for Sync-ProjectRules.ps1. Uses dummy gh/npx shims + fake preview/projects.
# Never touches real repos, real preview, or real CLI. Dummy secrets only.
$ErrorActionPreference = 'Stop'

$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$origPath = $env:PATH
$origDummyDir = $env:DUMMY_DIR
$origDummyGhExit = $env:DUMMY_GH_EXIT
$origDummyGhToken = $env:DUMMY_GH_TOKEN
$origDummyGhStderr = $env:DUMMY_GH_STDERR
$origDummyExpect = $env:DUMMY_EXPECT_TOKEN
$initCwd = (Get-Location).Path

$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Get-Full([string]$P) { return [System.IO.Path]::GetFullPath($P) }
function Test-Contained([string]$Candidate, [string]$Root) {
  $c = Get-Full $Candidate
  $r = Get-Full $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}
# Windows PowerShell 5.1 New-Item -ItemType SymbolicLink requires admin even in Developer Mode;
# the kernel flag 0x2 (ALLOW_UNPRIVILEGED_CREATE) does not. That flag needs Windows 10 Creators Update,
# so on ERROR_INVALID_PARAMETER (87) retry with flags=0, which admin hosts before it still accept.
function New-FileSymlink([string]$Path, [string]$Target) {
  if (-not ('SyncProjectRulesTest.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace SyncProjectRulesTest {
  public static class Native {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateSymbolicLinkW")]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool CreateSymbolicLink(string path, string target, uint flags);
  }
}
'@
  }
  if ([SyncProjectRulesTest.Native]::CreateSymbolicLink($Path, $Target, 2)) { return }
  $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  if ($err -eq 87) {
    if ([SyncProjectRulesTest.Native]::CreateSymbolicLink($Path, $Target, 0)) { return }
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  }
  throw ([System.ComponentModel.Win32Exception]::new($err))
}

try {
  $devAuto = Split-Path -Parent $PSScriptRoot
  $testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'SyncProjectRulesTest'
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $runId = [System.Guid]::NewGuid().ToString('N')
  $scratch = Join-Path $testBase ("run-" + $runId)
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  Assert (Test-Contained $scratch $testBase) 'T0 GUID scratch contained in base'
  Assert ($scratch -match 'run-[0-9a-f]{32}$') 'T0 scratch uses GUID suffix'

  $auto = Join-Path $scratch 'auto'
  $preview = Join-Path $scratch 'project-common-preview'
  $bin = Join-Path $scratch 'bin'
  $projA = Join-Path $scratch 'projA'
  $projB = Join-Path $scratch 'projB'
  New-Item -ItemType Directory -Force -Path $auto, $bin, $projA, $projB | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $preview '.rulesync\rules\.curated') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $projA '.rulesync\rules') | Out-Null
  Assert (Test-Contained $auto $scratch) 'T0 auto contained in scratch'

  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-ProjectRules.ps1') -Destination (Join-Path $auto 'Sync-ProjectRules.ps1') -Force
  $scriptText = Get-Content -LiteralPath (Join-Path $auto 'Sync-ProjectRules.ps1') -Raw
  Assert ($scriptText.IndexOf('SYNC_PROJECT_RULES_TEST') -lt 0) 'T0 production test-override removed'
  Assert ($scriptText.Contains('--input-roots') -and $scriptText.Contains('--output-roots')) 'T0 input/output roots used'
  Assert ($scriptText.Contains('Test-FrontmatterFlag') -and $scriptText.Contains('localRoot') -and $scriptText.Contains("'root'")) 'T0 frontmatter-scope marker gate (no body bypass, no YAML parser)'
  Assert ($scriptText.IndexOf("IndexOf('localRoot") -lt 0) 'T0 raw string marker search removed'
  Assert ($scriptText.Contains('^[ \t]') -and $scriptText.Contains('[|>]')) 'T0 strict gate rejects indented keys and block scalars'
  Assert ($scriptText.Contains('hits') -and $scriptText.Contains('-ne 1')) 'T0 strict gate requires exactly one true (no duplicates)'
  Assert ($scriptText.Contains("'^root") -and $scriptText.Contains("'^localRoot")) 'T0 strict gate forbids mixed root/localRoot'
  Assert ($scriptText.Contains('seenTargets') -and $scriptText.Contains('^description')) 'T0 strict allowlist (quoted/unknown rejected, fixed keys only)'
  Assert ($scriptText.Contains('AgentsFull') -and $scriptText.Contains('.Equals(')) 'T0 dry-run plan requires exact AgentsPath match'
  Assert ($scriptText.Contains('$planned')) 'T0 empty plan stops before generate'
  Assert ($scriptText.Contains('Test-FullyQualified')) 'T0 fully-qualified path check (no drive-relative)'
  Assert ($scriptText.Contains('Test-SafeName')) 'T0 safe single-basename registry names'
  Assert ($scriptText.Contains('backup escaped root')) 'T0 backup containment enforced'
  Assert ($scriptText.Contains('snapCreated') -and $scriptText.Contains('refusing reuse')) 'T0 snapshot ownership (own cleanup only)'
  Assert ($scriptText.Contains("'snapshots'") -and ($scriptText.IndexOf('GetTempPath') -lt 0)) 'T0 dedicated snapshot root under AutoDir (not shared TEMP)'
  Assert ($scriptText.Contains('snapshot root is a reparse') -and $scriptText.Contains('snapshot escaped snapshot root')) 'T0 snapshot root containment+reparse checked'
  Assert ($scriptText.Contains('refusing reparse AGENTS') -and $scriptText.Contains('refusing reparse local rule') -and $scriptText.Contains('refusing reparse parent')) 'T0 reparse refusal (AGENTS/local/parents)'
  Assert ($scriptText.Contains('ReparsePoint')) 'T0 reparse refusal present'
  Assert ($scriptText.IndexOf('--global') -lt 0) 'T0 never global mode'
  Assert ($scriptText.IndexOf('--delete') -lt 0) 'T0 never delete mode'

  Set-Content -LiteralPath (Join-Path $preview 'rulesync.jsonc') '{"targets":["codexcli","opencode"],"features":["rules"],"outputRoots":["output"],"delete":false,"global":false,"sources":[]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
  $regJson = '[{"name":"projA","path":"' + ($projA -replace '\\', '\\') + '"},{"name":"projB","path":"' + ($projB -replace '\\', '\\') + '"}]'
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') $regJson -Encoding Ascii

  Set-Content -LiteralPath (Join-Path $bin 'npx.cmd') @'
@echo off
setlocal EnableDelayedExpansion
set D=%DUMMY_DIR%
echo npx %* [cwd=%CD%]>> "%D%\calls.log"
if defined DUMMY_EXPECT_TOKEN (
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "if ($env:GITHUB_TOKEN -ceq $env:DUMMY_EXPECT_TOKEN) { exit 0 } else { exit 1 }" >nul 2>&1
  if errorlevel 1 (
    echo MOCK-TOKEN-MISMATCH 1>&2
    endlocal & exit /b 99
  )
)
set /p N=<"%D%\counter.txt"
set F=%D%\exit_!N!.txt
set CODE=0
if exist "!F!" set /p CODE=<"!F!"
set FO=%D%\stdout_!N!.txt
if exist "!FO!" type "!FO!"
set FS=%D%\stderr_!N!.txt
if exist "!FS!" type "!FS!" 1>&2
set /a M=!N!+1
echo !M!>"%D%\counter.txt"
endlocal & exit /b %CODE%
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bin 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
if defined DUMMY_GH_STDERR echo %DUMMY_GH_STDERR% 1>&2
if "%DUMMY_GH_EXIT%"=="1" exit /b 1
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii

  $env:PATH = ($bin + ';' + $env:PATH)
  $env:DUMMY_DIR = $scratch
  . (Join-Path $auto 'Sync-ProjectRules.ps1')
  Assert ((Get-Command Invoke-ProjectSync -ErrorAction SilentlyContinue) -ne $null) 'dot-source guard exposes Invoke-ProjectSync'

  function Reset-Case([int[]]$Exits) {
    foreach ($nm in @('calls.log', 'counter.txt')) {
      $p = Join-Path $script:scratch $nm
      if (-not (Test-Contained $p $script:scratch)) { throw ("Refusing to touch outside scratch: " + $p) }
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    $files = @(Get-ChildItem -LiteralPath $script:scratch -Filter '*.txt' -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      if (-not (Test-Contained $f.FullName $script:scratch)) { throw ("Refusing to delete outside scratch: " + $f.FullName) }
      if ($f.Name -match '^exit_[0-9]+\.txt$' -or $f.Name -match '^stderr_[0-9]+\.txt$' -or $f.Name -match '^stdout_[0-9]+\.txt$') {
        Remove-Item -LiteralPath $f.FullName -Force
      }
    }
    foreach ($d in @((Join-Path $script:auto 'logs'), (Join-Path $script:auto 'backups'))) {
      if (-not (Test-Contained $d $script:auto)) { throw ("Refusing to touch outside auto: " + $d) }
      if (-not ([System.IO.Path]::IsPathRooted($d))) { throw ("Refusing relative delete: " + $d) }
      $di = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
      if ($di -and (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { throw ("Refusing reparse-point delete: " + $d) }
      if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    $lp = Join-Path $script:auto 'Sync-ProjectRules.lock'
    if ((Test-Path -LiteralPath $lp) -and (-not (Get-Item -LiteralPath $lp -ErrorAction SilentlyContinue).PSIsContainer)) {
      Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue
    }
    # Never sweep shared TEMP here: other runs' ProjectSyncSnap-* dirs are not ours.
    # Ownership is verified by the other-run sentinel (created once below).
    Set-Content -LiteralPath (Join-Path $script:scratch 'counter.txt') '0' -Encoding Ascii
    for ($i = 0; $i -lt $Exits.Count; $i++) {
      $nm = "exit_$i.txt"
      if ($nm -notmatch '^exit_[0-9]+\.txt$') { throw 'bad fixture name' }
      $p = Join-Path $script:scratch $nm
      if (-not (Test-Contained $p $script:scratch)) { throw 'fixture outside scratch' }
      Set-Content -LiteralPath $p ([string]$Exits[$i]) -Encoding Ascii
    }
    Set-Content -LiteralPath (Join-Path $script:projA 'AGENTS.md') 'agents-A' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:projB 'AGENTS.md') 'agents-B' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:projA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-A" -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
    if ($script:env:DUMMY_GH_STDERR) { Remove-Item Env:DUMMY_GH_STDERR -ErrorAction SilentlyContinue }
  }
  function Set-Stderr([int]$Idx, [string]$Text) {
    $p = Join-Path $script:scratch ("stderr_$Idx.txt")
    if (-not (Test-Contained $p $script:scratch)) { throw 'stderr fixture outside scratch' }
    Set-Content -LiteralPath $p $Text -Encoding Ascii
  }
  function Set-Stdout([int]$Idx, [string]$Text) {
    $p = Join-Path $script:scratch ("stdout_$Idx.txt")
    if (-not (Test-Contained $p $script:scratch)) { throw 'stdout fixture outside scratch' }
    Set-Content -LiteralPath $p $Text -Encoding Ascii
  }
  function Get-Calls() {
    $p = Join-Path $script:scratch 'calls.log'
    if (-not (Test-Contained $p $script:scratch)) { throw 'calls.log outside scratch' }
    if (Test-Path -LiteralPath $p) { return @(Get-Content -LiteralPath $p) }
    return @()
  }
  function Get-Logs() {
    $d = Join-Path $script:auto 'logs'
    if (-not (Test-Contained $d $script:auto)) { throw 'logs outside auto' }
    if (-not (Test-Path -LiteralPath $d)) { return '' }
    return ((Get-ChildItem -LiteralPath $d | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
  }

  $env:DUMMY_GH_EXIT = '0'
  $env:DUMMY_GH_TOKEN = 'unused'
  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:GH_TOKEN = $null
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'

  # Other-run sentinel: proves Reset-Case/cleanup never touch TEMP entries we do not own.
  $otherSnap = Join-Path ([System.IO.Path]::GetTempPath()) ("ProjectSyncSnap-" + [System.Guid]::NewGuid().ToString('N'))
  if (-not (Test-Contained $otherSnap ([System.IO.Path]::GetTempPath()))) { throw 'sentinel outside temp refused' }
  New-Item -ItemType Directory -Force -Path $otherSnap | Out-Null
  Set-Content -LiteralPath (Join-Path $otherSnap 'sentinel.txt') 'other-run' -Encoding Ascii

  # T1: shared install fails -> full stop, no project calls, no backup.
  Reset-Case @(1)
  $c0 = (Get-Location).Path
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T1 install-fail exits 1'
  $calls = @(Get-Calls)
  Assert (($calls.Count -eq 1) -and ($calls[0].Contains('install'))) 'T1 only install called'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T1 no backup'
  Assert ($env:GITHUB_TOKEN -eq 'dummy-pre-token-AAA') 'T1 pre-existing token kept'
  Assert (((Get-Location).Path) -eq $c0) 'T1 cwd restored'

  # T2: both clean -> exit 0, install+2 checks only, no backup.
  Reset-Case @(0, 0, 0)
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T2 no-change exits 0'
  Assert ($calls.Count -eq 3) 'T2 install+2 checks only'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T2 no backup'
  Assert ((Get-Calls | Where-Object { $_ -like '*project-common-preview*' }).Count -eq 3) 'T2 all runs in preview cwd'

  # T3: A drifts -> A backup+generate, B untouched. Snapshot used for A only.
  # Dry-run plans exactly the root AGENTS.md (normal root plan).
  Reset-Case @(0, 1, 0, 0, 0, 0)
  Set-Stdout 2 ('Would write: ' + (Join-Path $projA 'AGENTS.md'))
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T3 drift exits 0'
  Assert ($calls.Count -eq 6) 'T3 six calls'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 1) 'T3 one backup dir'
  if ($bdirs.Count -eq 1) {
    Assert ($bdirs[0].Name.Contains('projA')) 'T3 backup dir names the project'
    Assert ((Get-Content -LiteralPath (Join-Path $bdirs[0].FullName 'AGENTS.md') -Raw).Contains('agents-A')) 'T3 backup content matches (before generate)'
  }
  $checkA = @($calls | Where-Object { $_ -like '*--check*' })[0]
  Assert ($checkA -like '*ProjectSyncSnap*') 'T3 A check uses local snapshot'
  $checkB = @($calls | Where-Object { $_ -like '*--check*' })[-1]
  Assert ($checkB -notlike '*ProjectSyncSnap*') 'T3 B check uses common root only'
  Assert (((Get-Location).Path) -eq $c0) 'T3 cwd restored'

  # T4: A generate fails -> B still processed, overall non-zero, A backup kept.
  Reset-Case @(0, 1, 0, 2, 0)
  Set-Stdout 2 ('Would write: ' + (Join-Path $projA 'AGENTS.md'))
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T4 isolation exits 1'
  Assert ($calls.Count -eq 5) 'T4 B still checked after A failure'
  Assert ((Get-Calls | Where-Object { $_ -like '*--check*' }).Count -eq 2) 'T4 both projects checked'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 1) 'T4 A backup kept (before failed generate)'

  # T5: -DryRun with drift -> no backup, no real generate.
  Reset-Case @(0, 1, 0, 0)
  Set-Stdout 2 ('Would write: ' + (Join-Path $projA 'AGENTS.md'))
  $code = Invoke-ProjectSync -DryRun
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T5 dryrun-switch exits 0'
  Assert ($calls.Count -eq 4) 'T5 no real generate'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T5 no backup'
  Assert ((Get-Logs).Contains('DRYRUN')) 'T5 logs dryrun skip'
  Assert (Test-Path -LiteralPath (Join-Path $otherSnap 'sentinel.txt')) 'T5 other-run sentinel survives'

  # T6: lock held -> skip 0, no calls.
  Reset-Case @(0, 0, 0)
  $lock = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try { $code = Invoke-ProjectSync }
  finally { $lock.Close() }
  Assert ($code -eq 0) 'T6 locked run exits 0'
  Assert ((Get-Calls).Count -eq 0) 'T6 no calls while locked'
  Assert ((Get-Logs).Contains('SKIP')) 'T6 logs skip'

  # R5P1: actual held lock with -ReportSkip returns 75 (skipped), default stays 0.
  # Existing periodic exit-0 skip behavior is preserved; dashboard uses the flag.
  Reset-Case @(0, 0, 0)
  $lockR5 = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $codeR5a = Invoke-ProjectSync -ReportSkip
    $callsR5a = @(Get-Calls)
    Assert ($codeR5a -eq 75) 'R5P1 held lock with ReportSkip exits 75 (skipped, not success)'
    Assert ($callsR5a.Count -eq 0) 'R5P1 no calls while locked with ReportSkip'
    Assert ((Get-Logs).Contains('SKIP')) 'R5P1 logs skip with ReportSkip'
  } finally { $lockR5.Close() }
  Reset-Case @(0, 0, 0)
  $lockR5b = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try { $codeR5b = Invoke-ProjectSync }
  finally { $lockR5b.Close() }
  Assert ($codeR5b -eq 0) 'R5P1 held lock without flag still exits 0 (periodic preserved)'
  $scrR5 = Get-Content -LiteralPath (Join-Path $auto 'Sync-ProjectRules.ps1') -Raw
  Assert ($scrR5.Contains('ReportSkip') -and $scrR5.Contains('return 75')) 'R5P1 minimal optional flag present'

  # T7: stderr on success still exits 0 (PS5.1 native handling).
  Reset-Case @(0, 0, 0)
  Set-Stderr 1 'warn-check-stderr-T7'
  $code = Invoke-ProjectSync
  Assert ($code -eq 0) 'T7 stderr-success exits 0'
  Assert ((Get-Logs).Contains('warn-check-stderr-T7')) 'T7 stderr captured in log'
  Assert (-not ((Get-Logs).Contains('NativeCommandError'))) 'T7 stderr does not log NativeCommandError'
  Assert (((Get-Location).Path) -eq $c0) 'T7 cwd restored'

  # T8: token leaking via npx stdout is redacted.
  Reset-Case @(0, 0, 0)
  Set-Stdout 1 'leak-stdout-T8-dummy-pre-token-AAA'
  $code = Invoke-ProjectSync
  Assert ($code -eq 0) 'T8 leak-redacted exits 0'
  Assert (-not ((Get-Logs).Contains('dummy-pre-token-AAA'))) 'T8 no token leak in logs'
  Assert ((Get-Logs).Contains('***')) 'T8 token redacted to ***'

  # T9: dry-run naming a non-registered path -> safe stop, no backup/generate for A.
  Reset-Case @(0, 1, 0, 0)
  Set-Stdout 2 ('Would write: ' + (Join-Path $scratch 'evil\AGENTS.md'))
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T9 evil-path exits 1'
  Assert ($calls.Count -eq 4) 'T9 stops before real generate'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 0) 'T9 no backup on refusal'
  Assert (Test-Path -LiteralPath (Join-Path $otherSnap 'sentinel.txt')) 'T9 other-run sentinel survives'

  # T9b: nested tools/AGENTS.md inside the repo is NOT the root AGENTS.md -> refuse.
  Reset-Case @(0, 1, 0, 0)
  Set-Stdout 2 ('Would write: ' + (Join-Path $projA 'tools\AGENTS.md'))
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T9b nested-plan exits 1'
  Assert ($calls.Count -eq 4) 'T9b stops before real generate'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 0) 'T9b no backup on nested refusal'
  Assert (-not (Test-Path -LiteralPath (Join-Path $projA 'tools\AGENTS.md'))) 'T9b nested file never written'

  # T9c: dry-run plans zero writes -> stop, never run real generate.
  Reset-Case @(0, 1, 0, 0)
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T9c empty-plan exits 1'
  Assert ($calls.Count -eq 4) 'T9c stops before real generate'
  Assert ((Get-Logs).Contains('planned no writes')) 'T9c logs empty-plan refusal'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 0) 'T9c no backup on empty plan'

  # T10a: common curated without root:true -> full stop after install.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') 'no-marker-here' -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10a bad-common exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10a only install ran'

  # T10b: local file without localRoot:true -> that project fails, B still clean.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') 'no-marker-here' -Encoding Ascii
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T10b bad-local exits 1'
  Assert ($calls.Count -eq 2) 'T10b A skipped, B checked'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T10b no backup'

  # T10c: localRoot:true only in body text (frontmatter lacks it) -> still fails.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`ntargets: [`"codexcli`", `"opencode`"]`n---`n`ncomment localRoot: true here" -Encoding Ascii
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T10c body-marker exits 1'
  Assert ($calls.Count -eq 2) 'T10c A skipped, B checked'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T10c no backup'

  # T10d: block scalar "description: |" with indented localRoot:true -> refused.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`ntargets: [`"codexcli`", `"opencode`"]`ndescription: |`n  localRoot: true`n---`n`nlocal-A" -Encoding Ascii
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T10d indented-block-scalar exits 1'
  Assert ($calls.Count -eq 2) 'T10d A skipped, B checked'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T10d no backup'

  # T10e: localRoot:false with root:true is a root rule, not a local rule -> refused.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`nlocalRoot: false`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-A" -Encoding Ascii
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T10e false-plus-root exits 1'
  Assert ($calls.Count -eq 2) 'T10e A skipped, B checked'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T10e no backup'

  # T10f: common curated mixing localRoot is ambiguous -> full stop.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10f mixed-common exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10f only install ran'

  # T10g: common root:true plus quoted "localRoot":true bypasses naive mixed check -> full stop.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`n`"localRoot`": true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10g quoted-mixed-common exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10g only install ran'

  # T10h: local localRoot:true plus quoted "root":true -> that project fails, B still clean.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`n`"root`": true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlocal-A" -Encoding Ascii
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T10h quoted-mixed-local exits 1'
  Assert ($calls.Count -eq 2) 'T10h A skipped, B checked'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T10h no backup'

  # T10i: unknown key in local frontmatter -> refused.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`nfoo: bar`n---`n`nlocal-A" -Encoding Ascii
  $code = Invoke-ProjectSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T10i unknown-key exits 1'
  Assert ($calls.Count -eq 2) 'T10i A skipped, B checked'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T10i no backup'

  # T10j: real fixed 3-line shape (flag+targets+description) passes.
  Reset-Case @(0, 0, 0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`ndescription: `"shared-desc`"`n---`n`nshared-body" -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`ndescription: `"local-desc`"`n---`n`nlocal-A" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 0) 'T10j real-shape exits 0'
  Assert ((Get-Calls).Count -eq 3) 'T10j install+2 checks only'

  # T10j2: trailing whitespace on frontmatter values is valid YAML and must pass.
  Reset-Case @(0, 0, 0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true  `ntargets: [`"codexcli`", `"opencode`"]  `ndescription: `"shared-desc`"  `n---`n`nshared-body" -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') "---`nlocalRoot: true  `ntargets: [`"codexcli`", `"opencode`"]  `n---`n`nlocal-A" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 0) 'T10j2 trailing-whitespace exits 0'
  Assert ((Get-Calls).Count -eq 3) 'T10j2 install+2 checks only'

  # T10j3: a comment still needs whitespace before `#`.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true#comment`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10j3 comment without whitespace exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10j3 only install ran'

  # T10k: targets appended by Update-GitHubRuleTargets (extra provider) still pass.
  Reset-Case @(0, 0, 0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`", `"antigravity-cli`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 0) 'T10k extra-target exits 0'
  Assert ((Get-Calls).Count -eq 3) 'T10k install+2 checks only'

  # T10l: targets missing opencode -> full stop after install.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10l missing-opencode exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10l only install ran'

  # T10m: duplicate targets -> full stop after install.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`", `"codexcli`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10m duplicate-target exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10m only install ran'

  # T10n: uppercase targets -> full stop after install (case-sensitive targets check).
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $preview '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`", `"ANTIGRAVITY-CLI`", `"ANTIGRAVITY-CLI`"]`n---`n`nshared-body" -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T10n uppercase-target exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T10n only install ran'

  # T11a: registry name traversal -> project refused, backup cannot escape root.
  $origReg = Get-Content -LiteralPath (Join-Path $auto 'projects.json') -Raw
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') ('[{"name":"..\\evil","path":"' + ($projA -replace '\\', '\\') + '"}]') -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T11a traversal-name exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T11a only install ran'
  Assert ((Get-Logs).Contains('unsafe registry name')) 'T11a logs unsafe name'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 0) 'T11a no backup on unsafe name'
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') $origReg -Encoding Ascii

  # T11b: drive-relative path (C:repo passes IsPathRooted) -> refused as non-absolute.
  Reset-Case @(0)
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[{"name":"projA","path":"C:relpath"}]' -Encoding Ascii
  $code = Invoke-ProjectSync
  Assert ($code -eq 1) 'T11b drive-relative exits 1'
  Assert ((Get-Calls).Count -eq 1) 'T11b only install ran'
  Assert ((Get-Logs).Contains('fully-qualified')) 'T11b logs fully-qualified refusal'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T11b no backup'
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') $origReg -Encoding Ascii
  Assert (Test-Path -LiteralPath (Join-Path $otherSnap 'sentinel.txt')) 'T11 other-run sentinel survives'

  # T13a: existing AGENTS.md symlink -> refused just before write (best-effort, not guaranteed).
  # Developer Mode unprivileged symlinks; a skip is recorded as failure, never as pass.
  Reset-Case @(0, 1, 0, 0)
  Set-Stdout 2 ('Would write: ' + (Join-Path $projA 'AGENTS.md'))
  $beforeB = Get-Content -LiteralPath (Join-Path $projB 'AGENTS.md') -Raw -Encoding UTF8
  $linkOk = $true
  try {
    Remove-Item -LiteralPath (Join-Path $projA 'AGENTS.md') -Force
    New-FileSymlink (Join-Path $projA 'AGENTS.md') (Join-Path $projB 'AGENTS.md')
  }
  catch { $linkOk = $false; Write-Host 'SKIP: T13a symlink needs privilege' }
  Assert ($linkOk) 'T13a symlink privilege available (skip is not a pass)'
  if ($linkOk) {
    $code = Invoke-ProjectSync
    Assert ($code -eq 1) 'T13a symlink-AGENTS exits 1'
    Assert ((Get-Logs).Contains('reparse AGENTS')) 'T13a logs reparse refusal'
    $bdirs = @()
    if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
    Assert ($bdirs.Count -eq 0) 'T13a no backup on symlink refusal'
    Assert ((Get-Content -LiteralPath (Join-Path $projB 'AGENTS.md') -Raw -Encoding UTF8) -eq $beforeB) 'T13a link target untouched (before/after match)'
    Remove-Item -LiteralPath (Join-Path $projA 'AGENTS.md') -Force
  }

  # T13b: symlinked local input file -> refused before snapshot (same unprivileged symlink path).
  # Skip is recorded as failure, never as pass.
  Reset-Case @(0, 0)
  $localOk = $true
  try {
    $lf = Join-Path $projA '.rulesync\rules\project-local.md'
    Remove-Item -LiteralPath $lf -Force
    New-FileSymlink $lf (Join-Path $projB 'AGENTS.md')
  }
  catch { $localOk = $false; Write-Host 'SKIP: T13b symlink needs privilege' }
  Assert ($localOk) 'T13b symlink privilege available (skip is not a pass)'
  if ($localOk) {
    $code = Invoke-ProjectSync
    $calls = @(Get-Calls)
    Assert ($code -eq 1) 'T13b symlink-local exits 1'
    Assert ($calls.Count -eq 2) 'T13b A skipped, B checked'
    Assert ((Get-Logs).Contains('reparse local rule')) 'T13b logs reparse refusal'
    Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T13b no backup'
    Remove-Item -LiteralPath (Join-Path $projA '.rulesync\rules\project-local.md') -Force
  }

  # T13c: repo dir behind a junction -> refused at entry (junctions need no privilege).
  Reset-Case @(0)
  $juncOk = $true
  $juncPath = Join-Path $scratch 'projLink'
  try { New-Item -ItemType Junction -Path $juncPath -Target $projA -ErrorAction Stop | Out-Null }
  catch { $juncOk = $false; Write-Host 'SKIP: T13c junction unsupported' }
  if ($juncOk) {
    Set-Content -LiteralPath (Join-Path $auto 'projects.json') ('[{"name":"projLink","path":"' + ($juncPath -replace '\\', '\\') + '"}]') -Encoding Ascii
    $code = Invoke-ProjectSync
    Assert ($code -eq 1) 'T13c junction-repo exits 1'
    Assert ((Get-Logs).Contains('reparse point')) 'T13c logs reparse refusal'
    Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T13c no backup'
    Set-Content -LiteralPath (Join-Path $auto 'projects.json') $origReg -Encoding Ascii
    [System.IO.Directory]::Delete($juncPath)
  }

  # T13d: native CreateSymbolicLinkW returns a one-byte BOOLEAN; 4-byte bool marshalling can read a
  # failed create as success. Assert the U1 contract (the ERROR_INVALID_PARAMETER retry needs a pre-Creators-Update host).
  $retParam = [SyncProjectRulesTest.Native].GetMethod('CreateSymbolicLink').ReturnParameter
  $masAttr = @($retParam.GetCustomAttributes([System.Runtime.InteropServices.MarshalAsAttribute], $false))
  Assert ($masAttr.Count -eq 1 -and $masAttr[0].Value -eq [System.Runtime.InteropServices.UnmanagedType]::U1) 'T13d native BOOLEAN return marshalled as U1'

  # T12: own snapshot root leaks nothing; other-run TEMP sentinel survives (no shared-TEMP sweep).
  # Only own GUID scratch is inspected, so parallel runs cannot cause false failures.
  $snapRoot = Join-Path $auto 'snapshots'
  $leftOwn = @()
  if (Test-Path -LiteralPath $snapRoot) {
    $leftOwn = @(Get-ChildItem -LiteralPath $snapRoot -Filter 'ProjectSyncSnap-*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'ProjectSyncSnap-[0-9a-f]{32}$' })
  }
  Assert ($leftOwn.Count -eq 0) 'T12 no own snapshot dirs leak'
  Assert (Test-Path -LiteralPath (Join-Path $otherSnap 'sentinel.txt')) 'T12 other-run sentinel survives all resets'
  Assert (((Get-Location).Path) -eq $initCwd) 'T12 cwd restored at end'
  Assert (Test-Path -LiteralPath $scratch) 'T12 scratch exists before cleanup'
  function Test-ReparseLocal([string]$P) {
    $it = Get-Item -LiteralPath $P -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $false }
    return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  }
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    if (-not ([System.IO.Path]::IsPathRooted($scratch))) { throw 'cleanup relative path refused' }
    if (Test-ReparseLocal $scratch) { throw 'cleanup refuses reparse-point scratch' }
    if (Test-ReparseLocal $testBase) { throw 'cleanup refuses reparse-point base' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'T12 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $testBase) 'T12 base dir left intact'
  if (-not (Test-Contained $otherSnap ([System.IO.Path]::GetTempPath()))) { throw 'sentinel cleanup outside temp refused' }
  if (Test-ReparseLocal $otherSnap) { throw 'sentinel cleanup refuses reparse-point sentinel' }
  Remove-Item -LiteralPath $otherSnap -Recurse -Force
  Assert (-not (Test-Path -LiteralPath $otherSnap)) 'T12 owner removes own sentinel'
  Assert (Test-Path -LiteralPath $testBase) 'T12 base dir still intact'
}
finally {
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  $env:DUMMY_DIR = $origDummyDir
  if ($null -eq $origDummyDir) { Remove-Item Env:DUMMY_DIR -ErrorAction SilentlyContinue }
  $env:DUMMY_GH_EXIT = $origDummyGhExit
  if ($null -eq $origDummyGhExit) { Remove-Item Env:DUMMY_GH_EXIT -ErrorAction SilentlyContinue }
  $env:DUMMY_GH_TOKEN = $origDummyGhToken
  if ($null -eq $origDummyGhToken) { Remove-Item Env:DUMMY_GH_TOKEN -ErrorAction SilentlyContinue }
  $env:DUMMY_GH_STDERR = $origDummyGhStderr
  if ($null -eq $origDummyGhStderr) { Remove-Item Env:DUMMY_GH_STDERR -ErrorAction SilentlyContinue }
  $env:DUMMY_EXPECT_TOKEN = $origDummyExpect
  if ($null -eq $origDummyExpect) { Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue }
  if ((Test-Path 'variable:otherSnap') -and $otherSnap -and (Test-Path -LiteralPath $otherSnap)) {
    Remove-Item -LiteralPath $otherSnap -Recurse -Force -ErrorAction SilentlyContinue
  }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL SELF-CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
