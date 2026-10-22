# Self-check for Sync-GlobalRules.ps1 NEW behavior (status/settings/preview/plan/ReportSkip).
# Uses dummy gh/npx/node shims + fake home. Never touches real home or real CLI.
# Existing Test-SyncGlobalRules.ps1 covers the base flow and keeps passing.
$ErrorActionPreference = 'Stop'

$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$origPath = $env:PATH
$origHomeDir = $env:HOME_DIR
$origKimiHome = $env:KIMI_CODE_HOME
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
  $testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'SyncGlobalStatusTest'
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $runId = [System.Guid]::NewGuid().ToString('N')
  $scratch = Join-Path $testBase ("run-" + $runId)
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  Assert (Test-Contained $scratch $testBase) 'S0 GUID scratch contained in base'

  $auto = Join-Path $scratch 'auto'
  $preview = Join-Path $scratch 'global-preview'
  $fakeHome = Join-Path $scratch 'home'
  $bin = Join-Path $scratch 'bin'
  New-Item -ItemType Directory -Force -Path $auto, $preview, $bin | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.codex') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.config\opencode') | Out-Null
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  $scriptText = Get-Content -LiteralPath (Join-Path $auto 'Sync-GlobalRules.ps1') -Raw
  Assert ($scriptText.Contains('Global-Management.ps1')) 'S0 sync reuses shared global helpers'
  # Seeded preview lock gives the source commit recorded in status/plan.
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.lock') '{"lockfileVersion":1,"sources":{"example-org/team-rules":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii

  # Dummy npx.cmd: token check + queued exits + materializes real generate
  # outputs into the CURRENT HOME_DIR (proves isolated-home preview writes).
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
set ISGEN=0
echo %* | findstr /C:"generate" >nul
if not errorlevel 1 set ISGEN=1
if !ISGEN! equ 1 (
  echo %* | findstr /C:"--check" >nul
  if not errorlevel 1 set ISGEN=0
)
if !ISGEN! equ 1 (
  echo %* | findstr /C:"--dry-run" >nul
  if not errorlevel 1 set ISGEN=0
)
if !ISGEN! equ 1 (
  if not "%HOME_DIR%"=="" (
    if not exist "%HOME_DIR%\.codex" mkdir "%HOME_DIR%\.codex" >nul 2>&1
    echo generated-codex-marker-!N! > "%HOME_DIR%\.codex\AGENTS.md"
    if not exist "%HOME_DIR%\.config\opencode" mkdir "%HOME_DIR%\.config\opencode" >nul 2>&1
    echo generated-opencode-marker-!N! > "%HOME_DIR%\.config\opencode\AGENTS.md"
    if not exist "%HOME_DIR%\.pi\agent" mkdir "%HOME_DIR%\.pi\agent" >nul 2>&1
    echo generated-pi-marker-!N! > "%HOME_DIR%\.pi\agent\AGENTS.md"
    if not exist "%HOME_DIR%\.claude" mkdir "%HOME_DIR%\.claude" >nul 2>&1
    echo generated-claude-marker-!N! > "%HOME_DIR%\.claude\CLAUDE.md"
  )
)
endlocal & exit /b %CODE%
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bin 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
if "%DUMMY_GH_EXIT%"=="1" exit /b 1
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $bin 'node.cmd') @'
@echo off
echo node %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_NODE_HOME%
exit /b 0
'@ -Encoding Ascii

  $env:PATH = ($bin + ';' + $env:PATH)
  Remove-Item Env:KIMI_CODE_HOME -ErrorAction SilentlyContinue
  $env:DUMMY_DIR = $scratch
  $env:HOME_DIR = $fakeHome
  $env:DUMMY_NODE_HOME = $fakeHome
  $env:DUMMY_GH_EXIT = '0'
  $env:DUMMY_GH_TOKEN = 'unused'
  . (Join-Path $auto 'Sync-GlobalRules.ps1')
  Assert ((Get-Command Invoke-GlobalSync -ErrorAction SilentlyContinue) -ne $null) 'S0 dot-source exposes Invoke-GlobalSync'

  function Reset-Case([int[]]$Exits) {
    foreach ($nm in @('calls.log', 'counter.txt')) {
      $p = Join-Path $script:scratch $nm
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    $files = @(Get-ChildItem -LiteralPath $script:scratch -Filter '*.txt' -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      if ($f.Name -match '^exit_[0-9]+\.txt$' -or $f.Name -match '^stderr_[0-9]+\.txt$' -or $f.Name -match '^stdout_[0-9]+\.txt$') {
        Remove-Item -LiteralPath $f.FullName -Force
      }
    }
    foreach ($d in @((Join-Path $script:auto 'logs'), (Join-Path $script:auto 'backups'))) {
      if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    foreach ($sf in @('global-status.json', 'global-settings.json')) {
      $p = Join-Path $script:auto $sf
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    foreach ($cf in @('rulesync.jsonc', 'rulesync.local.jsonc')) {
      $p = Join-Path $script:preview $cf
      if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    $lp = Join-Path $script:auto 'Sync-GlobalRules.lock'
    if (Test-Path -LiteralPath $lp) { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue }
    $olds = @(Get-ChildItem -LiteralPath $script:auto -Filter 'dashboard.global-*.json' -ErrorAction SilentlyContinue)
    foreach ($o in $olds) { Remove-Item -LiteralPath $o.FullName -Force }
    $olds2 = @(Get-ChildItem -LiteralPath $script:auto -Filter 'preview-home-*' -ErrorAction SilentlyContinue)
    foreach ($o in $olds2) { Remove-Item -LiteralPath $o.FullName -Recurse -Force }
    Set-Content -LiteralPath (Join-Path $script:scratch 'counter.txt') '0' -Encoding Ascii
    for ($i = 0; $i -lt $Exits.Count; $i++) {
      Set-Content -LiteralPath (Join-Path $script:scratch ("exit_" + $i + ".txt")) ([string]$Exits[$i]) -Encoding Ascii
    }
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.codex\AGENTS.md') 'fake-codex-agents' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.config\opencode\AGENTS.md') 'fake-opencode-agents' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.config\opencode\opencode.jsonc') '{"fake":2}' -Encoding Ascii
    New-Item -ItemType Directory -Force -Path (Join-Path $script:fakeHome '.pi\agent') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.pi\agent\AGENTS.md') 'fake-pi-agents' -Encoding Ascii
    New-Item -ItemType Directory -Force -Path (Join-Path $script:fakeHome '.claude') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.claude\CLAUDE.md') 'fake-claude-agents' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $script:fakeHome '.claude\settings.json') '{"sentinel":"keep","permissions":{"allow":["Bash"]}}' -Encoding Ascii
  }
  function Get-Calls() {
    $p = Join-Path $script:scratch 'calls.log'
    if (Test-Path -LiteralPath $p) { return @(Get-Content -LiteralPath $p) }
    return @()
  }
  function Read-Status() {
    $p = Join-Path $script:auto 'global-status.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
  }

  $env:GITHUB_TOKEN = 'dummy-pre-token-AAA'
  $env:GH_TOKEN = $null
  $env:DUMMY_EXPECT_TOKEN = 'dummy-pre-token-AAA'

  # S1: busy lock -> 75 with -ReportSkip, 0 by default (periodic compat).
  Reset-Case @(0, 0)
  $lock = [System.IO.File]::Open((Join-Path $auto 'Sync-GlobalRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $cSkip = Invoke-GlobalSync -ReportSkip
    $cDef = Invoke-GlobalSync
  }
  finally { $lock.Close() }
  Assert ($cSkip -eq 75) 'S1 busy with ReportSkip exits 75'
  Assert ($cDef -eq 0) 'S1 busy default still exits 0'

  # S2: settings single target honored; per-provider status with source commit.
  Reset-Case @(0, 1, 0, 0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["codexcli"]}' -Encoding Ascii
  $code = Invoke-GlobalSync
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'S2 single-target update exits 0'
  $genLines = @($calls | Where-Object { $_.Contains('generate') -and (-not $_.Contains('--check')) -and (-not $_.Contains('--dry-run')) })
  Assert ((@($genLines).Count -ge 1) -and ($genLines[0].Contains('--targets codexcli')) -and (-not ($genLines[0].Contains('opencode')))) 'S2 generate uses selected targets only'
  $st = Read-Status
  Assert (($null -ne $st) -and ([string]$st.providers.codexcli.result -ceq 'success')) 'S2 codexcli success recorded'
  Assert (([string]$st.providers.codexcli.sourceCommit -ceq '0123456789abcdef0123456789abcdef01234567')) 'S2 source commit recorded from preview lock'
  Assert (([string]$st.providers.codexcli.backupId -ne '')) 'S2 backup id recorded'
  $oc2 = $st.providers.PSObject.Properties['opencode'].Value
  Assert (($null -ne $oc2) -and ([string]$oc2.result -ceq 'unknown')) 'S2 unselected provider kept as unknown history'
  $bdirs = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups'))
  Assert ((@($bdirs).Count -eq 1) -and (Test-Path -LiteralPath (Join-Path $bdirs[0].FullName 'manifest.json'))) 'S2 backup carries manifest'

  # S3: invalid settings rejected before any home write.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":[]}' -Encoding Ascii
  $code = Invoke-GlobalSync
  Assert ($code -eq 1) 'S3 empty settings exits 1'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'S3 no backup on invalid settings'
  Assert ($null -eq (Read-Status)) 'S3 no status rows without known targets'

  # S4: request file targets override stored settings.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["opencode"]}' -Encoding Ascii
  $reqId = [System.Guid]::NewGuid().ToString('N')
  $reqFile = Join-Path $auto ("dashboard.global-request-" + $reqId + ".json")
  Set-Content -LiteralPath $reqFile '{"targetNames":["codexcli"],"previewOnly":false,"planPath":"","planId":""}' -Encoding Ascii
  $code = Invoke-GlobalSync -RequestPath $reqFile
  $calls = @(Get-Calls)
  Assert ($code -eq 0) 'S4 request override exits 0'
  Assert (((Get-Calls) -join '|' ).Contains('--targets codexcli')) 'S4 request targets win over settings'
  $st = Read-Status
  Assert ([string]$st.providers.codexcli.result -ceq 'success') 'S4 request target recorded'
  $reqBad = Join-Path $scratch 'outside.json'
  Set-Content -LiteralPath $reqBad '{"targetNames":["codexcli"]}' -Encoding Ascii
  Reset-Case @(0, 0)
  $code = Invoke-GlobalSync -RequestPath $reqBad
  Assert ($code -eq 1) 'S4 request outside autodir refused'
  Reset-Case @(0, 0)
  $reqEvil = Join-Path $auto ("dashboard.global-request-" + [System.Guid]::NewGuid().ToString('N') + ".json")
  Set-Content -LiteralPath $reqEvil '{"targetNames":["evil"]}' -Encoding Ascii
  $code = Invoke-GlobalSync -RequestPath $reqEvil
  Assert ($code -eq 1) 'S4 arbitrary request targets refused'

  # S5: no-change run records success without backup.
  Reset-Case @(0, 0)
  $code = Invoke-GlobalSync
  Assert ($code -eq 0) 'S5 no-change exits 0'
  $st = Read-Status
  Assert (([string]$st.providers.codexcli.result -ceq 'success') -and ([string]$st.providers.opencode.result -ceq 'success')) 'S5 both providers success on no-change'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'S5 no backup on no-change'

  # S6: preview writes plan only; real home untouched; env restored.
  Reset-Case @(0, 0)
  $beforeCodex = Get-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Raw
  $planId = [System.Guid]::NewGuid().ToString('N')
  $planFile = Join-Path $auto ("dashboard.global-plan-" + $planId + ".json")
  $code = Invoke-GlobalSync -PreviewOnly -PlanPath $planFile
  $afterCodex = Get-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Raw
  Assert ($code -eq 0) 'S6 preview exits 0'
  Assert ($beforeCodex -ceq $afterCodex) 'S6 real home untouched by preview'
  Assert ($env:HOME_DIR -ceq $fakeHome) 'S6 HOME_DIR restored after preview'
  Assert ((Test-Path -LiteralPath $planFile) -and (-not (Test-Path -LiteralPath (Join-Path $auto 'backups')))) 'S6 plan written, no backup'
  $plan = Get-Content -LiteralPath $planFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (([int]$plan.schemaVersion -eq 1) -and ([string]$plan.sourceCommit -ceq '0123456789abcdef0123456789abcdef01234567')) 'S6 plan carries source commit'
  $pe = @($plan.entries | Where-Object { [string]$_.target -ceq 'codexcli' })
  Assert ((@($pe).Count -eq 1) -and ([string]$pe[0].result -ceq 'success') -and ([string]$pe[0].generatedText).Contains('generated-codex-marker')) 'S6 plan entry holds isolated generate output'
  Assert (([string]$pe[0].currentText).Contains('fake-codex-agents')) 'S6 plan entry holds actual current text'
  $left = @(Get-ChildItem -LiteralPath $auto -Filter 'preview-home-*' -ErrorAction SilentlyContinue)
  Assert ((@($left).Count -eq 0)) 'S6 isolated home cleaned up'

  # S7: stale plan refuses writes (no backup, stops after install).
  Reset-Case @(0, 0)
  $planId7 = [System.Guid]::NewGuid().ToString('N')
  $planFile7 = Join-Path $auto ("dashboard.global-plan-" + $planId7 + ".json")
  $liveH = (Get-FileHash -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Algorithm SHA256).Hash.ToLowerInvariant()
  $planObj = @{ schemaVersion = 1; createdAt = ([DateTime]::UtcNow.ToString('o')); sourceCommit = '0123456789abcdef0123456789abcdef01234567'; targets = @('codexcli', 'opencode'); entries = @(
    @{ target = 'codexcli'; path = (Join-Path $fakeHome '.codex\AGENTS.md'); currentHash = 'stale-hash'; generatedHash = 'g'; generatedText = 'gen'; currentText = 'cur'; result = 'success'; error = '' }
  ) }
  Set-Content -LiteralPath $planFile7 (ConvertTo-Json -InputObject $planObj -Depth 8 -Compress) -Encoding UTF8
  $reqId7 = [System.Guid]::NewGuid().ToString('N')
  $reqFile7 = Join-Path $auto ("dashboard.global-request-" + $reqId7 + ".json")
  Set-Content -LiteralPath $reqFile7 ('{"targetNames":["codexcli"],"previewOnly":false,"planPath":"","planId":"' + $planId7 + '"}') -Encoding Ascii
  $code = Invoke-GlobalSync -RequestPath $reqFile7
  Assert ($code -eq 1) 'S7 stale plan exits 1'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'S7 stale plan writes nothing'
  Assert ((@(Get-Calls).Count -eq 1)) 'S7 stale plan stops after shared fetch'
  $st = Read-Status
  Assert ([string]$st.providers.codexcli.result -ceq 'failed') 'S7 stale plan records failure'

  # S8: new catalog provider uses the same isolated preview -> apply -> backup path.
  Reset-Case @(0, 0, 0, 1, 0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["pi"]}' -Encoding Ascii
  $planId8 = [System.Guid]::NewGuid().ToString('N')
  $planFile8 = Join-Path $auto ("dashboard.global-plan-" + $planId8 + ".json")
  $beforePi8 = Get-Content -LiteralPath (Join-Path $fakeHome '.pi\agent\AGENTS.md') -Raw
  $code = Invoke-GlobalSync -PreviewOnly -PlanPath $planFile8
  $plan8 = Get-Content -LiteralPath $planFile8 -Raw -Encoding UTF8 | ConvertFrom-Json
  $pe8 = @($plan8.entries | Where-Object { [string]$_.target -ceq 'pi' })
  Assert ((($code -eq 0) -and (@($plan8.targets).Count -eq 1) -and ([string]$plan8.targets[0] -ceq 'pi'))) 'S8 preview targets new provider only'
  $pe8ok = (@($pe8).Count -eq 1) -and ([string]$pe8[0].result -ceq 'success') -and ([string]$pe8[0].generatedText).Contains('generated-pi-marker')
  Assert $pe8ok 'S8 isolated generate reads nested catalog path'
  Assert (([string]$pe8[0].currentText).Contains('fake-pi-agents')) 'S8 preview reads current new-provider text'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.pi\agent\AGENTS.md') -Raw) -ceq $beforePi8) 'S8 preview leaves new-provider file untouched'
  $code = Invoke-GlobalSync
  $afterPi8 = Get-Content -LiteralPath (Join-Path $fakeHome '.pi\agent\AGENTS.md') -Raw
  Assert ((($code -eq 0) -and ($afterPi8.Contains('generated-pi-marker')))) 'S8 apply writes generated new-provider file'
  $bdirs8 = @(Get-ChildItem -LiteralPath (Join-Path $auto 'backups') -Directory | Sort-Object Name)
  $mf8 = $null
  if (@($bdirs8).Count -gt 0) { $mf8 = Get-Content -LiteralPath (Join-Path $bdirs8[-1].FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert (($null -ne $mf8) -and ([string]$mf8.targets[0] -ceq 'pi') -and (Test-Path -LiteralPath (Join-Path $bdirs8[-1].FullName '.pi_agent_AGENTS.md'))) 'S8 apply backs up new provider with flattened rel'
  Assert (((Get-Content -LiteralPath (Join-Path $bdirs8[-1].FullName '.pi_agent_AGENTS.md') -Raw).Contains('fake-pi-agents'))) 'S8 backup holds pre-apply bytes'

  # S9: install failure records per-provider failure, token kept.
  Reset-Case @(1)
  $code = Invoke-GlobalSync
  Assert ($code -eq 1) 'S9 install-fail exits 1'
  $st = Read-Status
  Assert (([string]$st.providers.codexcli.result -ceq 'failed') -and ([string]$st.providers.opencode.result -ceq 'failed')) 'S9 both providers failed'
  Assert ($env:GITHUB_TOKEN -eq 'dummy-pre-token-AAA') 'S9 pre-existing token kept'

  # S11: selected Kimi Code with KIMI_CODE_HOME fails closed before any CLI
  # or pre-preview write; the external override and fake home stay untouched.
  Reset-Case @(0, 0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["kimi-code"]}' -Encoding Ascii
  $extKimi = Join-Path $scratch 'kimi-external'
  New-Item -ItemType Directory -Force -Path $extKimi | Out-Null
  $sentinel11 = Join-Path $extKimi 'AGENTS.md'
  Set-Content -LiteralPath $sentinel11 'external-sentinel-S11' -Encoding Ascii
  $env:KIMI_CODE_HOME = $extKimi
  $planId11 = [System.Guid]::NewGuid().ToString('N')
  $planFile11 = Join-Path $auto ("dashboard.global-plan-" + $planId11 + ".json")
  $codePrev11 = Invoke-GlobalSync -PreviewOnly -PlanPath $planFile11
  Assert ($codePrev11 -eq 1) 'S11 preview with KIMI_CODE_HOME exits 1'
  Assert ((@(Get-Calls).Count -eq 0)) 'S11 preview launches no CLI'
  Assert (-not (Test-Path -LiteralPath $planFile11)) 'S11 preview writes no plan'
  Assert ((@(Get-ChildItem -LiteralPath $auto -Filter 'preview-home-*' -ErrorAction SilentlyContinue).Count -eq 0)) 'S11 preview creates no isolated home'
  $codeApply11 = Invoke-GlobalSync
  Assert ($codeApply11 -eq 1) 'S11 apply with KIMI_CODE_HOME exits 1'
  Assert ((@(Get-Calls).Count -eq 0)) 'S11 apply launches no CLI'
  Assert ((Get-Content -LiteralPath $sentinel11 -Raw).Trim() -ceq 'external-sentinel-S11') 'S11 external override untouched'
  Assert (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.kimi-code'))) 'S11 fake home Kimi path untouched'
  $st11 = Read-Status
  $k11 = $st11.providers.PSObject.Properties['kimi-code'].Value
  Assert (([string]$k11.result -ceq 'failed') -and ([string]$k11.error -match 'KIMI_CODE_HOME')) 'S11 apply records failed status with env reason'

  # S12: only a meaningful override conflicts, and an unselected Kimi never
  # blocks the other selected providers.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["codexcli"]}' -Encoding Ascii
  $env:KIMI_CODE_HOME = $extKimi
  $code12a = Invoke-GlobalSync
  $st12a = Read-Status
  $k12a = $st12a.providers.PSObject.Properties['kimi-code'].Value
  Assert ((($code12a -eq 0) -and (@(Get-Calls).Count -gt 0) -and ([string]$st12a.providers.codexcli.result -ceq 'success'))) 'S12 unselected Kimi conflict does not block other providers'
  Assert (($null -eq $k12a) -or ([string]$k12a.result -cne 'success')) 'S12 unselected Kimi is not marked success'
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["kimi-code"]}' -Encoding Ascii
  $env:KIMI_CODE_HOME = '   '
  $code12b = Invoke-GlobalSync
  $st12b = Read-Status
  $k12b = $st12b.providers.PSObject.Properties['kimi-code'].Value
  Assert ((($code12b -eq 0) -and (@(Get-Calls).Count -gt 0) -and ($null -ne $k12b) -and ([string]$k12b.result -ceq 'success'))) 'S12 whitespace override is not a conflict'

  # S13: a top-level JSONC language setting makes Claude write its shared
  # settings file, so the whole run must stop before any CLI or home write.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["claudecode"]}' -Encoding Ascii
  $cfg13 = @'
{
  // a comment must not hide the real key below
  "features": ["rules"],
  "language": "ja",
}
'@
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.jsonc') $cfg13 -Encoding UTF8
  $beforeSettings13 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $beforeClaude13 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\CLAUDE.md') -Raw
  $planId13 = [System.Guid]::NewGuid().ToString('N')
  $planFile13 = Join-Path $auto ("dashboard.global-plan-" + $planId13 + ".json")
  $codePrev13 = Invoke-GlobalSync -PreviewOnly -PlanPath $planFile13
  Assert ($codePrev13 -eq 1) 'S13 language config rejects Claude preview'
  Assert ((@(Get-Calls).Count -eq 0)) 'S13 preview launches no CLI'
  Assert (-not (Test-Path -LiteralPath $planFile13)) 'S13 preview writes no plan'
  Assert ((@(Get-ChildItem -LiteralPath $auto -Filter 'preview-home-*' -ErrorAction SilentlyContinue).Count -eq 0)) 'S13 preview creates no isolated home'
  $codeApply13 = Invoke-GlobalSync
  Assert ($codeApply13 -eq 1) 'S13 language config rejects Claude apply'
  Assert ((@(Get-Calls).Count -eq 0)) 'S13 apply launches no CLI'
  Assert (-not (Test-Path -LiteralPath (Join-Path $auto 'backups'))) 'S13 apply writes no backup'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $beforeSettings13) 'S13 settings sentinel untouched'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\CLAUDE.md') -Raw) -ceq $beforeClaude13) 'S13 Claude rule untouched'
  $st13 = Read-Status
  $c13 = $st13.providers.PSObject.Properties['claudecode'].Value
  Assert (([string]$c13.result -ceq 'failed') -and ([string]$c13.error -match 'language')) 'S13 status records language reason'

  # S14: rulesync.local.jsonc is merged into the resolved config, and a base
  # language still applies when the local file does not override it.
  $cfgBase14 = @'
{
  "features": ["rules"]
}
'@
  $cfgLocal14 = @'
{
  // local override still counts
  "language": "ja",
}
'@
  $cfgBase14B = @'
{
  "features": ["rules"],
  "language": "ja",
}
'@
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["claudecode"]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.jsonc') $cfgBase14 -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.local.jsonc') $cfgLocal14 -Encoding UTF8
  $code14a = Invoke-GlobalSync
  Assert ($code14a -eq 1) 'S14 local language override rejects Claude'
  Assert ((@(Get-Calls).Count -eq 0)) 'S14 local language launches no CLI'
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["claudecode"]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.jsonc') $cfgBase14B -Encoding UTF8
  $code14b = Invoke-GlobalSync
  Assert ($code14b -eq 1) 'S14 base language without local override rejects Claude'
  Assert ((@(Get-Calls).Count -eq 0)) 'S14 base language launches no CLI'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -match 'sentinel') 'S14 settings sentinel kept'

  # S15: comment text, nested keys and quoted strings are not a language
  # setting; the normal Claude rules path must still generate and back up.
  Reset-Case @(0, 1, 0, 0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["claudecode"]}' -Encoding Ascii
  $cfg15 = @'
{
  "features": ["rules"],
  // "language": "ja",
  "note": "\"language\": \"ja\"",
  "nested": { "language": "ja" }
}
'@
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.jsonc') $cfg15 -Encoding UTF8
  $beforeSettings15 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $code15 = Invoke-GlobalSync
  $calls15 = @(Get-Calls)
  $gen15 = @($calls15 | Where-Object { $_.Contains('generate') -and (-not $_.Contains('--check')) -and (-not $_.Contains('--dry-run')) })
  Assert ($code15 -eq 0) 'S15 decoy language text does not block normal Claude sync'
  Assert (@($gen15).Count -ge 1) 'S15 normal Claude generation ran'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\CLAUDE.md') -Raw).Contains('generated-claude-marker')) 'S15 Claude rule written'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $beforeSettings15) 'S15 settings sentinel untouched'
  Assert ((@(Get-ChildItem -LiteralPath (Join-Path $auto 'backups') -Directory -ErrorAction SilentlyContinue).Count -eq 1)) 'S15 Claude apply backed up'
  $st15 = Read-Status
  Assert ([string]$st15.providers.claudecode.result -ceq 'success') 'S15 Claude status success'

  # S16: an unselected Claude target never blocks other selected providers.
  Reset-Case @(0, 0)
  Set-Content -LiteralPath (Join-Path $auto 'global-settings.json') '{"schemaVersion":1,"targets":["codexcli"]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $preview 'rulesync.jsonc') $cfgBase14B -Encoding UTF8
  $beforeSettings16 = Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw
  $code16 = Invoke-GlobalSync
  $st16 = Read-Status
  Assert ((($code16 -eq 0) -and (@(Get-Calls).Count -gt 0) -and ([string]$st16.providers.codexcli.result -ceq 'success'))) 'S16 unselected Claude language does not block other providers'
  Assert ((Get-Content -LiteralPath (Join-Path $fakeHome '.claude\settings.json') -Raw) -ceq $beforeSettings16) 'S16 unselected Claude settings untouched'

  Assert (((Get-Location).Path) -eq $initCwd) 'S10 cwd restored at end'
  Assert ($env:HOME_DIR -eq $fakeHome) 'S10 HOME_DIR kept for harness restore'
  Assert (Test-Path -LiteralPath $scratch) 'S10 scratch exists before cleanup'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'S10 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $testBase) 'S10 base dir left intact'
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
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL GLOBAL SYNC CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
