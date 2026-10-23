# Self-check for Sync-GlobalRules.ps1. Uses dummy gh/npx/node shims + fake home.
# Never touches real home or real CLI. Dummy secrets only.
$ErrorActionPreference = 'Stop'

$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$origPath = $env:PATH
$origHomeDir = $env:HOME_DIR
$origTestHomeLegacy = $env:SYNC_GLOBAL_RULES_TEST_HOME
$origDummyDir = $env:DUMMY_DIR
$origDummyGhExit = $env:DUMMY_GH_EXIT
$origDummyGhToken = $env:DUMMY_GH_TOKEN
$origDummyGhStderr = $env:DUMMY_GH_STDERR
$origDummyExpect = $env:DUMMY_EXPECT_TOKEN
$origDummyNodeHome = $env:DUMMY_NODE_HOME
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

$devAuto = Split-Path -Parent $PSScriptRoot
try {
  $testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'SyncGlobalRulesTest'
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $runId = [System.Guid]::NewGuid().ToString('N')
  $scratch = Join-Path $testBase ("run-" + $runId)
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  Assert (Test-Contained $scratch $testBase) 'T0 GUID scratch contained in base'
  Assert ($scratch -match 'run-[0-9a-f]{32}$') 'T0 scratch uses GUID suffix'
  Assert ((Get-Full $scratch).StartsWith((Get-Full $testBase), [System.StringComparison]::OrdinalIgnoreCase)) 'T0 absolute containment verified'

  $auto = Join-Path $scratch 'auto'
  $preview = Join-Path $scratch 'global-preview'
  $fakeHome = Join-Path $scratch 'home'
  $bin = Join-Path $scratch 'bin'
  New-Item -ItemType Directory -Force -Path $auto, $preview, $bin | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.codex') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.config\opencode') | Out-Null
  Assert (Test-Contained $auto $scratch) 'T0 auto contained in scratch'
  Assert (Test-Contained $fakeHome $scratch) 'T0 fakehome contained in scratch'
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  $scriptText = Get-Content -LiteralPath (Join-Path $auto 'Sync-GlobalRules.ps1') -Raw
  Assert ($scriptText.IndexOf('SYNC_GLOBAL_RULES_TEST_HOME') -lt 0) 'T0 production test-override removed'
  Assert ($scriptText.Contains('HOME_DIR') -and $scriptText.Contains("node:os")) 'T0 HOME_DIR or node os.homedir resolution present'

  # Dummy npx.cmd: verify GITHUB_TOKEN exact match, emit queued stdout/stderr, log args + cwd.
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
  # Dummy gh.cmd: stdout token only, optional stderr marker, controlled exit.
  Set-Content -LiteralPath (Join-Path $bin 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
if defined DUMMY_GH_STDERR echo %DUMMY_GH_STDERR% 1>&2
if "%DUMMY_GH_EXIT%"=="1" exit /b 1
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
  # Dummy node.cmd: returns fake home for os.homedir fallback.
  Set-Content -LiteralPath (Join-Path $bin 'node.cmd') @'
@echo off
echo node %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_NODE_HOME%
exit /b 0
'@ -Encoding Ascii

  $env:PATH = ($bin + ';' + $env:PATH)
  $env:DUMMY_DIR = $scratch
  $env:HOME_DIR = $fakeHome
  $env:DUMMY_NODE_HOME = $fakeHome
  $env:SYNC_GLOBAL_RULES_TEST_HOME = Join-Path $scratch 'bogus-home'
  . (Join-Path $auto 'Sync-GlobalRules.ps1')
  Assert ((Get-Command Invoke-GlobalSync -ErrorAction SilentlyContinue) -ne $null) 'dot-source guard exposes Invoke-GlobalSync'

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
      if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    $lp = Join-Path $script:auto 'Sync-GlobalRules.lock'
    if ((Test-Path -LiteralPath $lp) -and (-not (Get-Item -LiteralPath $lp -ErrorAction SilentlyContinue).PSIsContainer)) {
      Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue
    }
    Set-Content -LiteralPath (Join-Path $script:scratch 'counter.txt') '0' -Encoding Ascii
    for ($i = 0; $i -lt $Exits.Count; $i++) {
      $nm = "exit_$i.txt"
      if ($nm -notmatch '^exit_[0-9]+\.txt$') { throw 'bad fixture name' }
      $p = Join-Path $script:scratch $nm
      if (-not (Test-Contained $p $script:scratch)) { throw 'fixture outside scratch' }
      Set-Content -LiteralPath $p ([string]$Exits[$i]) -Encoding Ascii
    }
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.codex\AGENTS.md') 'fake-codex-agents' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.config\opencode\AGENTS.md') 'fake-opencode-agents' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.config\opencode\opencode.json') '{"fake":1}' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.config\opencode\opencode.jsonc') '{"fake":2}' -Encoding Ascii
    if ($script:env:DUMMY_GH_STDERR) { Remove-Item Env:DUMMY_GH_STDERR -ErrorAction SilentlyContinue }
  }
  function Set-Stderr([int]$Idx, [string]$Text) {
    $nm = "stderr_$Idx.txt"
    if ($nm -notmatch '^stderr_[0-9]+\.txt$') { throw 'bad stderr fixture name' }
    $p = Join-Path $script:scratch $nm
    if (-not (Test-Contained $p $script:scratch)) { throw 'stderr fixture outside scratch' }
    Set-Content -LiteralPath $p $Text -Encoding Ascii
  }
  function Set-Stdout([int]$Idx, [string]$Text) {
    $nm = "stdout_$Idx.txt"
    if ($nm -notmatch '^stdout_[0-9]+\.txt$') { throw 'bad stdout fixture name' }
    $p = Join-Path $script:scratch $nm
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

  # T1: install fails -> no generate, exit 1, token kept.
  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:GH_TOKEN = $null
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(1)
  $c0 = (Get-Location).Path
  $code = Invoke-GlobalSync
  Assert ($code -eq 1) 'T1 install-fail exits 1'
  $calls = @(Get-Calls)
  Assert (($calls.Count -eq 1) -and ($calls[0].Contains('install'))) 'T1 only install called'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T1 no backup'
  Assert ($env:GITHUB_TOKEN -eq 'dummy-pre-token-AAA') 'T1 pre-existing token kept'
  Assert (((Get-Location).Path) -eq $c0) 'T1 cwd restored'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T1 token exact-match passed'

  # T2: check 0 -> no backup, no real generate, exit 0.
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 0)
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T2 no-change exits 0'
  Assert ($calls.Count -eq 2) 'T2 install+check only'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T2 no backup'
  Assert ((Get-Calls | Where-Object { $_ -like '*global-preview*' }).Count -eq 2) 'T2 ran in global-preview cwd'
  Assert ((Get-Logs).Contains('no changes')) 'T2 logs no-changes'
  Assert (-not ((Get-Logs).Contains('dummy-pre-token-AAA'))) 'T2 no token leak in logs'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T2 token exact-match passed'

  # T3: update -> backup, generate, final check. HOME_DIR used, legacy override ignored.
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 1, 0, 0, 0)
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T3 update exits 0'
  Assert ($calls.Count -eq 5) 'T3 five calls'
  $joined = $calls -join '|'
  Assert (($joined.IndexOf('install') -lt $joined.IndexOf('--check')) -and ($joined.IndexOf('--dry-run') -lt $joined.LastIndexOf('generate'))) 'T3 call order install/check/dryrun/generate/check'
  $bdirs = @()
  if (Test-Path -LiteralPath (Join-Path $auto 'backups')) { $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups')) }
  Assert ($bdirs.Count -eq 1) 'T3 one backup dir'
  if ($bdirs.Count -eq 1) {
    $files = @(Get-ChildItem -LiteralPath $bdirs[0].FullName)
    Assert ($files.Count -eq 5) 'T3 four files backed up plus manifest'
    Assert ((Get-Content -LiteralPath (Join-Path $bdirs[0].FullName '.codex_AGENTS.md') -Raw).Contains('fake-codex-agents')) 'T3 backup content matches'
    $mf3 = Get-Content -LiteralPath (Join-Path $bdirs[0].FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert (([string]$mf3.scope -ceq 'global')) 'T3 backup manifest is global scope'
  }
  Assert (-not (Test-Path -LiteralPath (Join-Path $scratch 'bogus-home'))) 'T3 legacy SYNC_GLOBAL_RULES_TEST_HOME ignored'
  Assert (((Get-Location).Path) -eq $c0) 'T3 cwd restored'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T3 token exact-match passed'

  # T4: gh auth fails -> no npx, exit 1, tokens stay absent.
  $env:GITHUB_TOKEN = $null
  $env:GH_TOKEN = $null
  $env:DUMMY_GH_EXIT = '1'
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue
  Reset-Case @()
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T4 gh-fail exits 1'
  Assert (($calls.Count -eq 1) -and ($calls[0].StartsWith('gh '))) 'T4 only gh called'
  Assert ($null -eq $env:GITHUB_TOKEN) 'T4 GITHUB_TOKEN stays absent'
  Assert ($null -eq $env:GH_TOKEN) 'T4 GH_TOKEN stays absent'
  $env:DUMMY_GH_EXIT = '0'

  # T5: acquired token removed after run, never logged.
  $env:DUMMY_GH_TOKEN = 'dummy-acquired-TOKEN-zzz'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-acquired-TOKEN-zzz'
  Reset-Case @(0, 0)
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'T5 acquired-token run exits 0'
  Assert ($null -eq $env:GITHUB_TOKEN) 'T5 acquired token removed'
  Assert (-not ((Get-Logs).Contains('dummy-acquired-TOKEN-zzz'))) 'T5 no acquired-token leak in logs'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T5 token exact-match passed'

  # T6: check 1 but dry-run fails -> stop, no backup/generate.
  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:DUMMY_GH_TOKEN = 'unused'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 1, 1)
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 1) 'T6 dryrun-fail exits 1'
  Assert ($calls.Count -eq 3) 'T6 stops after dry-run'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T6 no backup'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T6 token exact-match passed'

  # T7: -DryRun stops before backup/generate.
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 1, 0)
  $code = Invoke-GlobalSync -DryRun
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T7 dryrun-switch exits 0'
  Assert ($calls.Count -eq 3) 'T7 no real generate'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'T7 no backup'
  Assert ((Get-Logs).Contains('DRYRUN')) 'T7 logs dryrun skip'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T7 token exact-match passed'

  # T8: lock held -> skip with exit 0, no calls.
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue
  Reset-Case @(0, 0)
  $lock = [System.IO.File]::Open((Join-Path $auto 'Sync-GlobalRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try { $code = Invoke-GlobalSync }
  finally { $lock.Close() }
  Assert ($code -eq 0) 'T8 locked run exits 0'
  Assert ((Get-Calls).Count -eq 0) 'T8 no calls while locked'
  Assert ((Get-Logs).Contains('SKIP')) 'T8 logs skip'

  # T8b: non-sharing lock error -> exit 1, no SKIP.
  Reset-Case @(0, 0)
  $lp = Join-Path $auto 'Sync-GlobalRules.lock'
  if (Test-Path -LiteralPath $lp) { Remove-Item -LiteralPath $lp -Force }
  New-Item -ItemType Directory -Force -Path $lp | Out-Null
  try { $code = Invoke-GlobalSync }
  finally { Remove-Item -LiteralPath $lp -Recurse -Force }
  Assert ($code -eq 1) 'T8b lock-dir exits 1'
  Assert ((Get-Calls).Count -eq 0) 'T8b no calls on lock failure'
  Assert ((Get-Logs).Contains('FAIL: lock failed')) 'T8b logs lock failure'
  Assert (-not ((Get-Logs).Contains('SKIP'))) 'T8b no false SKIP'

  # T9: native success with stderr still exits 0 (no NativeCommandError).
  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 0)
  Set-Stderr 1 'warn-check-stderr-T9'
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'T9 stderr-success exits 0'
  Assert ((Get-Logs).Contains('warn-check-stderr-T9')) 'T9 stderr captured in log'
  Assert (((Get-Location).Path) -eq $c0) 'T9 cwd restored'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T9 token exact-match passed'

  # T10: diff check with stderr still follows update path.
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 1, 0, 0, 0)
  Set-Stderr 1 'warn-diff-stderr-T10'
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T10 stderr-diff exits 0'
  Assert ($calls.Count -eq 5) 'T10 five calls despite stderr'
  Assert ((Get-Logs).Contains('warn-diff-stderr-T10')) 'T10 diff stderr logged'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T10 token exact-match passed'

  # T11: failing install with stderr -> exit 1 with fixed message, no NativeCommandError.
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(2)
  Set-Stderr 0 'fail-install-stderr-T11'
  $code = Invoke-GlobalSync
  Assert ($code -eq 1) 'T11 stderr-fail exits 1'
  Assert ((Get-Logs).Contains('fail-install-stderr-T11')) 'T11 failure stderr logged'
  Assert ((Get-Logs).Contains('install --update failed.')) 'T11 fixed failure message'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T11 token exact-match passed'

  # T12: gh stdout-only token; stderr junk ignored, run succeeds.
  $env:GITHUB_TOKEN = $null
  $env:GH_TOKEN = $null
  $env:DUMMY_GH_TOKEN = 'dummy-acquired-TOKEN-zzz'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-acquired-TOKEN-zzz'
  Reset-Case @(0, 0)
  $env:DUMMY_GH_STDERR = 'junk-gh-stderr-T12'
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'T12 gh-stderr run exits 0'
  Assert ($null -eq $env:GITHUB_TOKEN) 'T12 acquired token removed'
  Assert (-not ((Get-Logs).Contains('junk-gh-stderr-T12'))) 'T12 gh stderr not mixed into token/log'
  Assert (-not ((Get-Logs).Contains('dummy-acquired-TOKEN-zzz'))) 'T12 no token leak'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T12 token exact-match passed (stderr not mixed)'
  Remove-Item Env:DUMMY_GH_STDERR -ErrorAction SilentlyContinue
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue

  # T13: gh fail with stderr -> fixed message, no stderr leak.
  $env:GITHUB_TOKEN = $null
  $env:GH_TOKEN = $null
  $env:DUMMY_GH_EXIT = '1'
  Reset-Case @()
  $env:DUMMY_GH_STDERR = 'gh-fail-stderr-T13-marker'
  $code = Invoke-GlobalSync
  Assert ($code -eq 1) 'T13 gh-fail-stderr exits 1'
  Assert ((Get-Logs).Contains('GitHub auth failed')) 'T13 fixed auth failure message'
  Assert (-not ((Get-Logs).Contains('gh-fail-stderr-T13-marker'))) 'T13 gh stderr not leaked'
  $env:DUMMY_GH_EXIT = '0'
  Remove-Item Env:DUMMY_GH_STDERR -ErrorAction SilentlyContinue

  # T14: node fallback matches fake home when HOME_DIR absent.
  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:DUMMY_GH_TOKEN = 'unused'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  $savedHomeDir = $env:HOME_DIR
  $env:HOME_DIR = $null
  $env:DUMMY_NODE_HOME = $fakeHome
  Reset-Case @(0, 0)
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'T14 node-fallback exits 0'
  Assert ((($calls | Where-Object { $_.StartsWith('node ') }).Count) -ge 1) 'T14 node os.homedir called'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T14 token exact-match passed'
  $env:HOME_DIR = $savedHomeDir
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue

  # T16: npx stdout+stderr leaking pre-token are redacted, exact-match passes.
  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:GH_TOKEN = $null
  $env:DUMMY_GH_TOKEN = 'unused'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'
  Reset-Case @(0, 0)
  Set-Stdout 1 'leak-stdout-T16-dummy-pre-token-AAA'
  Set-Stderr 1 'leak-stderr-T16-dummy-pre-token-AAA'
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'T16 leak-redacted exits 0'
  Assert (-not ((Get-Logs).Contains('dummy-pre-token-AAA'))) 'T16 no pre-token leak in logs'
  Assert ((Get-Logs).Contains('***')) 'T16 token redacted to ***'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T16 token exact-match passed'
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue

  # T17: acquired token leaking via npx stdout+stderr is redacted and removed.
  $env:GITHUB_TOKEN = $null
  $env:GH_TOKEN = $null
  $env:DUMMY_GH_TOKEN = 'dummy-acquired-TOKEN-zzz'
  $env:DUMMY_EXPECT_TOKEN = 'dummy-acquired-TOKEN-zzz'
  Reset-Case @(0, 0)
  Set-Stdout 1 'leak-stdout-T17-dummy-acquired-TOKEN-zzz'
  Set-Stderr 1 'leak-stderr-T17-dummy-acquired-TOKEN-zzz'
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'T17 acquired-leak exits 0'
  Assert ($null -eq $env:GITHUB_TOKEN) 'T17 acquired token removed'
  Assert (-not ((Get-Logs).Contains('dummy-acquired-TOKEN-zzz'))) 'T17 no acquired leak in logs'
  Assert ((Get-Logs).Contains('***')) 'T17 acquired redacted to ***'
  Assert (-not ((Get-Logs).Contains('MOCK-TOKEN-MISMATCH'))) 'T17 token exact-match passed'
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue

  # T18: GH_TOKEN pre-existing redacted, GITHUB check skipped, GH kept.
  $env:GITHUB_TOKEN = $null
  $env:GH_TOKEN = 'dummy-gh-token-BBB'
  $env:DUMMY_GH_TOKEN = 'unused'
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue
  Reset-Case @(0, 0)
  Set-Stdout 1 'leak-stdout-T18-dummy-gh-token-BBB'
  Set-Stderr 1 'leak-stderr-T18-dummy-gh-token-BBB'
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'T18 GH_TOKEN run exits 0'
  Assert ($env:GH_TOKEN -eq 'dummy-gh-token-BBB') 'T18 GH_TOKEN kept'
  Assert (-not ((Get-Logs).Contains('dummy-gh-token-BBB'))) 'T18 no GH leak in logs'
  Assert ((Get-Logs).Contains('***')) 'T18 GH redacted to ***'

  # T19: check exits 0 but rulesync wrote nothing for a selected target
  # (no root rule for it in the source). A run-level exit 0 must not mark
  # that target success: the missing output is recorded per target.
  $env:GITHUB_TOKEN = $null
  $env:GH_TOKEN = 'dummy-gh-token-BBB'
  Remove-Item Env:DUMMY_EXPECT_TOKEN -ErrorAction SilentlyContinue
  $gem = Join-Path $script:fakeHome '.gemini\GEMINI.md'
  if (Test-Path -LiteralPath $gem) { Remove-Item -LiteralPath $gem -Force }
  Reset-Case @(0, 0)
  $code = Invoke-GlobalSync -TargetNames @('codexcli', 'opencode', 'antigravity-cli')
  Assert ($code -eq 0) 'T19 no-change still exits 0'
  $st19 = Get-Content -LiteralPath (Join-Path $script:auto 'global-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ([string]$st19.providers.codexcli.result -ceq 'success') 'T19 covered target stays success'
  Assert ([string]$st19.providers.opencode.result -ceq 'success') 'T19 second covered target stays success'
  Assert ([string]$st19.providers.'antigravity-cli'.result -ceq 'failed') 'T19 uncovered target recorded failed'
  Assert ($null -eq $st19.providers.'antigravity-cli'.lastSuccessAt) 'T19 uncovered target gets no success stamp'
  Assert (-not [string]::IsNullOrWhiteSpace([string]$st19.providers.'antigravity-cli'.error)) 'T19 uncovered target carries a reason'
  Assert ((Get-Logs).Contains('antigravity-cli')) 'T19 log names the uncovered target'

  Assert (((Get-Location).Path) -eq $initCwd) 'T15 cwd restored at end'
  Assert ($env:HOME_DIR -eq $fakeHome) 'T15 HOME_DIR kept for harness restore'
  Assert (Test-Path -LiteralPath $scratch) 'T15 scratch exists before cleanup'

  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'T15 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $testBase) 'T15 base dir left intact'
}
finally {
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:SYNC_GLOBAL_RULES_TEST_HOME = $origTestHomeLegacy
  if ($null -eq $origTestHomeLegacy) { Remove-Item Env:SYNC_GLOBAL_RULES_TEST_HOME -ErrorAction SilentlyContinue }
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
  $env:DUMMY_NODE_HOME = $origDummyNodeHome
  if ($null -eq $origDummyNodeHome) { Remove-Item Env:DUMMY_NODE_HOME -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL SELF-CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
