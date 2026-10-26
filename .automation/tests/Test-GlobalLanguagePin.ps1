# Self-check for the Claude language config race in Sync-GlobalRules.ps1.
# A fake npx mutates rulesync.local.jsonc AFTER the initial language check
# (during install, or during the drift check) and emulates rulesync reading
# the resolved base+local config it is actually given. Real home is never used.
$ErrorActionPreference = 'Stop'

$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$origPath = $env:PATH
$origHomeDir = $env:HOME_DIR
$origKimiHome = $env:KIMI_CODE_HOME
$origDummyDir = $env:DUMMY_DIR
$origDummyNodeHome = $env:DUMMY_NODE_HOME
$origDummyAddLanguage = $env:DUMMY_ADD_LANGUAGE_ON
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
  $testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalLanguagePinTest'
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $scratch = Join-Path $testBase ("run-" + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  Assert (Test-Contained $scratch $testBase) 'L0 GUID scratch contained in base'

  $auto = Join-Path $scratch 'auto'
  $preview = Join-Path $scratch 'global-preview'
  $fakeHome = Join-Path $scratch 'home'
  $bin = Join-Path $scratch 'bin'
  New-Item -ItemType Directory -Force -Path $auto, $preview, $bin | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude') | Out-Null
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.lock') '{"lockfileVersion":1,"sources":{"example-org/team-rules":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii

  # Fake CLI: logs argv/cwd, applies queued exits, optionally adds a language to
  # the LIVE rulesync.local.jsonc, and (for a real generate) reads the config
  # path it was given plus that file's sibling local config. A language found
  # there patches Claude settings exactly as rulesync 42 does.
  Set-Content -LiteralPath (Join-Path $bin 'fake-npx.ps1') @'
$D = $env:DUMMY_DIR
$argv = @($args)
Add-Content -LiteralPath (Join-Path $D 'calls.log') -Value ('npx ' + ($argv -join ' ') + ' [cwd=' + (Get-Location).Path + ']')
if ($env:DUMMY_EXPECT_TOKEN -and ($env:GITHUB_TOKEN -cne $env:DUMMY_EXPECT_TOKEN)) { [Console]::Error.WriteLine('MOCK-TOKEN-MISMATCH'); exit 99 }
$n = 0
$cp = Join-Path $D 'counter.txt'
if (Test-Path -LiteralPath $cp) { $n = [int]((Get-Content -LiteralPath $cp -Raw).Trim()) }
$code = 0
$ep = Join-Path $D ('exit_' + $n + '.txt')
if (Test-Path -LiteralPath $ep) { $code = [int]((Get-Content -LiteralPath $ep -Raw).Trim()) }
Set-Content -LiteralPath $cp -Value ([string]($n + 1)) -Encoding Ascii
function Get-Opt([string]$Name) {
  for ($i = 0; $i -lt $argv.Count; $i++) {
    if ($argv[$i] -ceq $Name) { if (($i + 1) -lt $argv.Count) { return [string]$argv[$i + 1] } }
  }
  return $null
}
$isInstall = ($argv -ccontains 'install')
$isGenerate = ($argv -ccontains 'generate')
$isCheck = ($argv -ccontains '--check')
$isDry = ($argv -ccontains '--dry-run')
$mutate = $env:DUMMY_ADD_LANGUAGE_ON
if (($mutate -eq 'install') -and $isInstall) {
  Set-Content -LiteralPath (Join-Path (Get-Location).Path 'rulesync.local.jsonc') '{ "language": "ja" }' -Encoding UTF8
}
if (($mutate -eq 'check') -and $isGenerate -and $isCheck) {
  Set-Content -LiteralPath (Join-Path (Get-Location).Path 'rulesync.local.jsonc') '{ "language": "ja" }' -Encoding UTF8
}
if ($isGenerate -and (-not $isCheck) -and (-not $isDry)) {
  $configPath = Get-Opt '--config'
  if (-not $configPath) { $configPath = Join-Path (Get-Location).Path 'rulesync.jsonc' }
  $targets = Get-Opt '--targets'
  $hasLanguage = $false
  foreach ($cf in @($configPath, (Join-Path (Split-Path -Parent $configPath) 'rulesync.local.jsonc'))) {
    if ((Test-Path -LiteralPath $cf -PathType Leaf) -and ((Get-Content -LiteralPath $cf -Raw -Encoding UTF8) -match '"language"\s*:')) { $hasLanguage = $true }
  }
  if ($hasLanguage -and ([string]$targets -match 'claudecode')) {
    $sd = Join-Path $env:HOME_DIR '.claude'
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $sp = Join-Path $sd 'settings.json'
    if (Test-Path -LiteralPath $sp -PathType Leaf) { $o = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json }
    else { $o = New-Object psobject }
    $o | Add-Member -NotePropertyName language -NotePropertyValue 'japanese' -Force
    $o | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sp -Encoding UTF8
  }
  $map = @{ 'codexcli' = '.codex\AGENTS.md'; 'opencode' = '.config\opencode\AGENTS.md'; 'claudecode' = '.claude\CLAUDE.md'; 'pi' = '.pi\agent\AGENTS.md' }
  foreach ($t in ([string]$targets -split ',')) {
    if ($map.ContainsKey($t)) {
      $p = Join-Path $env:HOME_DIR $map[$t]
      New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
      Set-Content -LiteralPath $p -Value ('generated-' + $t + '-marker-' + $n) -Encoding Ascii
    }
  }
}
exit $code
'@ -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $bin 'npx.cmd') @'
@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake-npx.ps1" %*
exit /b %ERRORLEVEL%
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bin 'gh.cmd') @'
@echo off
if "%DUMMY_GH_EXIT%"=="1" exit /b 1
echo dummy-gh-token
exit /b 0
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bin 'node.cmd') @'
@echo off
echo %DUMMY_NODE_HOME%
exit /b 0
'@ -Encoding Ascii

  $env:PATH = ($bin + ';' + $env:PATH)
  Remove-Item Env:KIMI_CODE_HOME -ErrorAction SilentlyContinue
  $env:DUMMY_DIR = $scratch
  $env:DUMMY_NODE_HOME = $fakeHome
  $env:HOME_DIR = $fakeHome
  $env:GITHUB_TOKEN = 'dummy-pin-token'
  $env:GH_TOKEN = $null
  . (Join-Path $auto 'Sync-GlobalRules.ps1')

  $safeConfig = @'
{
  "features": ["rules"]
}
'@
  function Read-Status() {
    $p = Join-Path $script:auto 'global-status.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
  }
  function Get-Calls() {
    $p = Join-Path $script:scratch 'calls.log'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p)
  }
  function Get-GenerateCalls() {
    return @(Get-Calls | Where-Object { $_.Contains('generate') -and (-not $_.Contains('--check')) -and (-not $_.Contains('--dry-run')) })
  }
  function Reset-Case([int[]]$Exits, [string]$Target, [string]$Mutate) {
    foreach ($nm in @('calls.log', 'counter.txt')) {
      $p = Join-Path $script:scratch $nm
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:scratch -Filter '*.txt' -ErrorAction SilentlyContinue)) {
      if ($f.Name -match '^(exit|stdout|stderr)_[0-9]+\.txt$') { Remove-Item -LiteralPath $f.FullName -Force }
    }
    foreach ($d in @((Join-Path $script:auto 'logs'), (Join-Path $script:auto 'backups'))) {
      if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    foreach ($sf in @('global-status.json', 'global-settings.json', 'Sync-GlobalRules.lock')) {
      $p = Join-Path $script:auto $sf
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    foreach ($pat in @('preview-home-*', 'preview-config-*', 'dashboard.global-plan-*')) {
      foreach ($o in @(Get-ChildItem -LiteralPath $script:auto -Filter $pat -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $o.FullName -Recurse -Force
      }
    }
    Set-Content -LiteralPath (Join-Path $script:auto 'global-settings.json') ('{"schemaVersion":1,"targets":["' + $Target + '"]}') -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:scratch 'counter.txt') '0' -Encoding Ascii
    for ($i = 0; $i -lt $Exits.Count; $i++) {
      Set-Content -LiteralPath (Join-Path $script:scratch ("exit_" + $i + ".txt")) ([string]$Exits[$i]) -Encoding Ascii
    }
    Remove-Item -LiteralPath (Join-Path $script:preview 'rulesync.local.jsonc') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $script:preview 'rulesync.jsonc') $script:safeConfig -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.claude\CLAUDE.md') 'fake-claude-agents' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.claude\settings.json') '{"sentinel":"keep","permissions":{"allow":["Bash"]}}' -Encoding Ascii
    $env:DUMMY_ADD_LANGUAGE_ON = $Mutate
  }

  # L1: install adds a language to the live local config after the initial
  # check. The real apply must stop before ANY later generate call, keep the
  # sentinel settings byte-identical, write no backup, and record failure.
  Reset-Case @(0, 1, 0, 0, 0) 'claudecode' 'install'
  $before1 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $code1 = Invoke-GlobalSync
  $calls1 = @(Get-Calls)
  Assert ($code1 -eq 1) 'L1 unsafe post-install config exits 1'
  Assert ((@($calls1 | Where-Object { $_.Contains('install') }).Count -eq 1)) 'L1 install ran after the initial safe check'
  Assert ((@($calls1 | Where-Object { $_.Contains('generate') }).Count -eq 0)) 'L1 no generate/check/dry-run after the language appears'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $before1) 'L1 sentinel settings exact'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\CLAUDE.md') -Raw).Trim() -ceq 'fake-claude-agents') 'L1 Claude rule untouched'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'L1 no backup/apply'
  $st1 = Read-Status
  $c1 = $st1.providers.PSObject.Properties['claudecode'].Value
  Assert (([string]$c1.result -ceq 'failed') -and ([string]$c1.error -match 'language')) 'L1 status records the language failure'

  # L2: the same mutation must also stop the isolated-preview path before it
  # writes a plan or runs the isolated generation.
  Reset-Case @(0, 0) 'claudecode' 'install'
  $before2 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $planId2 = [System.Guid]::NewGuid().ToString('N')
  $plan2 = Join-Path $auto ('dashboard.global-plan-' + $planId2 + '.json')
  $code2 = Invoke-GlobalSync -PreviewOnly -PlanPath $plan2
  $calls2 = @(Get-Calls)
  Assert ($code2 -eq 1) 'L2 unsafe post-install preview exits 1'
  Assert ((@($calls2 | Where-Object { $_.Contains('generate') }).Count -eq 0)) 'L2 no isolated preview generation'
  Assert (-not (Test-Path -LiteralPath $plan2)) 'L2 no plan written'
  Assert ((@(Get-ChildItem -LiteralPath $auto -Filter 'preview-home-*' -ErrorAction SilentlyContinue).Count -eq 0)) 'L2 no isolated home left'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $before2) 'L2 sentinel settings exact'

  # L3: the live local config changes during the drift check, AFTER the config
  # was pinned. The real generate must still read the verified pinned config,
  # so Claude settings stay untouched and the run succeeds.
  Reset-Case @(0, 1, 0, 0, 0) 'claudecode' 'check'
  $before3 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $code3 = Invoke-GlobalSync
  $gen3 = @(Get-GenerateCalls)
  Assert ($code3 -eq 0) 'L3 safe pinned apply succeeds after a live config change'
  Assert ((@($gen3).Count -ge 1)) 'L3 real generation ran'
  Assert (($gen3[0] -match '--config (.+?) \[cwd=')) 'L3 real generation uses an explicit config'
  if ($gen3[0] -match '--config (.+?) \[cwd=') {
    Assert (Test-Contained $Matches[1] $preview) 'L3 pinned config lives under the preview cwd'
  }
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $before3) 'L3 sentinel settings exact'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\CLAUDE.md') -Raw).Contains('generated-claudecode-marker')) 'L3 Claude rule written'
  $st3 = Read-Status
  Assert ([string]$st3.providers.claudecode.result -ceq 'success') 'L3 Claude status success'

  # L4: the normal no-language Claude apply still succeeds.
  Reset-Case @(0, 1, 0, 0, 0) 'claudecode' ''
  $before4 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $code4 = Invoke-GlobalSync
  Assert ($code4 -eq 0) 'L4 normal Claude apply exits 0'
  Assert ((@(Get-GenerateCalls).Count -ge 1)) 'L4 normal Claude generation ran'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $before4) 'L4 sentinel settings exact'
  $st4 = Read-Status
  Assert ([string]$st4.providers.claudecode.result -ceq 'success') 'L4 Claude status success'

  # L5: a language added by install never blocks another selected provider.
  Reset-Case @(0, 1, 0, 0, 0) 'codexcli' 'install'
  $before5 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $code5 = Invoke-GlobalSync
  Assert ($code5 -eq 0) 'L5 unselected Claude language does not block Codex'
  Assert ((@(Get-GenerateCalls).Count -ge 1)) 'L5 Codex generation ran'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $before5) 'L5 Claude settings untouched'
  $st5 = Read-Status
  Assert ([string]$st5.providers.codexcli.result -ceq 'success') 'L5 Codex status success'

  Assert (((Get-Location).Path) -eq $initCwd) 'L6 cwd restored at end'
  Assert (Test-Path -LiteralPath $scratch) 'L6 scratch exists before cleanup'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'L6 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $testBase) 'L6 base dir left intact'
}
finally {
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:KIMI_CODE_HOME = $origKimiHome
  if ($null -eq $origKimiHome) { Remove-Item Env:KIMI_CODE_HOME -ErrorAction SilentlyContinue }
  $env:DUMMY_DIR = $origDummyDir
  if ($null -eq $origDummyDir) { Remove-Item Env:DUMMY_DIR -ErrorAction SilentlyContinue }
  $env:DUMMY_NODE_HOME = $origDummyNodeHome
  if ($null -eq $origDummyNodeHome) { Remove-Item Env:DUMMY_NODE_HOME -ErrorAction SilentlyContinue }
  $env:DUMMY_ADD_LANGUAGE_ON = $origDummyAddLanguage
  if ($null -eq $origDummyAddLanguage) { Remove-Item Env:DUMMY_ADD_LANGUAGE_ON -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL GLOBAL LANGUAGE PIN CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
