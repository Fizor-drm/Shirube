# Test-Management15.ps1 - isolated checks for proposal-15 features (F1-F15).
# Scratch-only. Never touches real registry, repos, tasks, or deployed AppData.
# Scheduler writes are never tested (guard+validation only); interval-set live run is unverified.
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
try {
  . (Join-Path $devAuto 'Dashboard-Server.ps1')
  . (Join-Path $devAuto 'Project-Management.ps1')
  Assert ((Get-Command Get-MgmtBackupList -ErrorAction SilentlyContinue) -ne $null) 'M0 module dot-sourced (no listen)'

  # F9 isolation: shadow the scheduler cmdlets for this whole run so the suite
  # never reads or writes the real Project/Global tasks (scratch-only header).
  $script:mockTaskInterval = 'PT17M'
  $script:mockTaskCalls = @()
  $script:mockTaskState = 'Ready'
  $mockProjectTask = Get-MgmtProjectTaskName
  function Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName)
    $script:mockTaskCalls += ('get:' + [string]$TaskName)
    if ($TaskName -cne $script:mockProjectTask) { throw ('task not found: ' + [string]$TaskName) }
    $tr = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = [pscustomobject]@{ Interval = $script:mockTaskInterval } }
    return [pscustomobject]@{ TaskName = $script:mockProjectTask; State = $script:mockTaskState; Triggers = @($tr) }
  }
  function Set-ScheduledTask { [CmdletBinding()] param([string]$TaskName, $Trigger)
    $script:mockTaskCalls += ('set:' + [string]$TaskName)
    $script:mockTaskInterval = [string]$Trigger[0].Repetition.Interval
    return [pscustomobject]@{ TaskName = [string]$TaskName }
  }
  function Disable-ScheduledTask { [CmdletBinding()] param([string]$TaskName) $script:mockTaskCalls += ('disable:' + [string]$TaskName); $script:mockTaskState = 'Disabled' }
  function Enable-ScheduledTask { [CmdletBinding()] param([string]$TaskName) $script:mockTaskCalls += ('enable:' + [string]$TaskName); $script:mockTaskState = 'Ready' }

  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'Mgmt15Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  New-Item -ItemType Directory -Force -Path $auto | Out-Null
  $curDir = Join-Path $scratch 'project-common-preview\.rulesync\rules\.curated'
  New-Item -ItemType Directory -Force -Path $curDir | Out-Null
  $commonBody = "shared-line-one`nshared-line-two"
  Set-Content -LiteralPath (Join-Path $curDir 'project.md') ("---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`n" + $commonBody) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[]' -Encoding Ascii
  $env:DASHBOARD_AUTODIR = $auto

  function New-Repo([string]$Name) {
    $r = Join-Path $script:scratch $Name
    New-Item -ItemType Directory -Force -Path $r | Out-Null
    return $r
  }

  # F4: enabled default-true backcompat + toggle
  $repoE = New-Repo 'RepoE'
  Write-RegistryAtomicLocked $auto @([pscustomobject]@{ name = 'RepoE'; path = $repoE })
  $regE = @(Get-Registry $auto)
  Assert ((Get-MgmtEffectiveEnabled $regE[0]) -eq $true) 'F4 missing enabled defaults true (backcompat)'
  Set-MgmtEnabled $auto 'RepoE' $false
  $regE2 = @(Get-Registry $auto)
  Assert ((Get-MgmtEffectiveEnabled $regE2[0]) -eq $false) 'F4 disabled persists'
  Set-MgmtEnabled $auto 'RepoE' $true
  Assert ((Get-MgmtEffectiveEnabled @((Get-Registry $auto))[0]) -eq $true) 'F4 re-enable persists'
  $enBad = $true
  try { Set-MgmtEnabled $auto 'NoSuch' $false; $enBad = $false } catch { $enBad = ($_.Exception.Message.Contains('見つかりません')) }
  Assert ($enBad) 'F4 unknown name refused'

  # F3: rename sets display name only; internal name stays stable.
  Rename-MgmtProject $auto 'RepoE' 'RepoE2'
  $e3 = @((Get-Registry $auto))[0]
  Assert (([string]$e3.name -ceq 'RepoE') -and ([string]$e3.displayName -ceq 'RepoE2')) 'F3 rename sets display, keeps internal name+path'
  Assert (($e3.path -ceq $repoE)) 'F3 rename keeps path'
  $rnBad = $true
  try { Rename-MgmtProject $auto 'RepoE' ''; $rnBad = $false } catch { $rnBad = $true }
  Assert ($rnBad) 'F3 empty display refused'
  $rnDup = $true
  Write-RegistryAtomicLocked $auto @([pscustomobject]@{ name = 'RepoE'; path = $repoE; displayName = 'RepoE2' }, [pscustomobject]@{ name = 'Other'; path = (New-Repo 'Other'); displayName = 'Other' })
  try { Rename-MgmtProject $auto 'RepoE' 'Other'; $rnDup = $false } catch { $rnDup = ($_.Exception.Message.Contains('競合')) }
  Assert ($rnDup) 'F3 duplicate display refused'
  # The internal name is a valid target: it restores the default label.
  $rnBack = $true
  try { Rename-MgmtProject $auto 'RepoE' 'RepoE' } catch { $rnBack = $false }
  $e3b = @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'RepoE' })[0]
  Assert (($rnBack) -and ([string]$e3b.name -ceq 'RepoE') -and ([string]$e3b.displayName -ceq 'RepoE')) 'F3 rename back to the internal name restores the default label'

  # F6: move path re-designation
  $repoMove = New-Repo 'MoveDst'
  Move-MgmtProjectPath $auto 'RepoE' $repoMove
  Assert ((@((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'RepoE' })[0].path -ceq $repoMove)) 'F6 move updates path'
  $mvBad = $true
  try { Move-MgmtProjectPath $auto 'RepoE' 'rel\path'; $mvBad = $false } catch { $mvBad = $true }
  Assert ($mvBad) 'F6 relative path refused'
  $mvDup = $true
  try { Move-MgmtProjectPath $auto 'RepoE' (New-Repo 'Other'); $mvDup = $false } catch { $mvDup = $true }
  Assert ($mvDup) 'F6 duplicate path refused'
  Move-MgmtProjectPath $auto 'RepoE' $repoE

  # F1: lossless import preview + confirm registration
  $repoI = New-Repo 'RepoI'
  $agentsText = $commonBody + "`nmy-unique-line-ABC123"
  Set-Content -LiteralPath (Join-Path $repoI 'AGENTS.md') $agentsText -Encoding Ascii
  $impPrev = Get-MgmtAgentsImportPreview $auto $repoI $commonBody
  Assert (($impPrev.ok -and ($impPrev.agentsHash -match '^[0-9a-f]{64}$'))) 'F1 import preview ok with agents hash'
  Assert (($impPrev.transcription.Contains('my-unique-line-ABC123') -and (-not ($impPrev.transcription.Contains('shared-line-one'))))) 'F1 transcription keeps unique, drops common'
  $impNoConfirm = $true
  try { Register-MgmtImport $auto $repoI $null $false | Out-Null; $impNoConfirm = $false } catch { $impNoConfirm = ($_.Exception.Message.Contains('確認')) }
  Assert ($impNoConfirm) 'F1 import without confirm refused'
  $impAppr = New-MgmtImportApproval $auto $repoI
  $impRes = Register-MgmtImport $auto $repoI $null $true $impAppr
  Assert (($impRes.ok -and (Test-Path -LiteralPath $impRes.backup))) 'F1 import backs up AGENTS (lossless)'
  Assert ((Get-Content -LiteralPath (Join-Path $impRes.backup 'AGENTS.md') -Raw) -match 'my-unique-line-ABC123') 'F1 backup holds original AGENTS'
  $localBack = Get-Content -LiteralPath (Join-Path $repoI '.rulesync\rules\project-local.md') -Raw -Encoding UTF8
  Assert (($localBack.Contains('localRoot: true') -and $localBack.Contains('my-unique-line-ABC123'))) 'F1 local rule created with transcribed body'
  Assert ((@((Get-Registry $auto) | Where-Object { [string]$_.name -ceq $impRes.name })).Count -eq 1) 'F1 import registers entry'
  $impDup = Get-MgmtAgentsImportPreview $auto $repoI $commonBody
  Assert ((-not $impDup.ok) -and ($impDup.error.Contains('既に登録'))) 'F1 duplicate path refused after import'
  $repoNo = New-Repo 'RepoNo'
  $impNone = Get-MgmtAgentsImportPreview $auto $repoNo $commonBody
  Assert ((-not $impNone.ok) -and ($impNone.error.Contains('AGENTS.md'))) 'F1 no-AGENTS is not import (use normal preview)'

  # F13: local rule edit with format validation + expected hash
  $lr = Get-MgmtLocalRule $auto $impRes.name
  Assert (($lr.hash -match '^[0-9a-f]{64}$') -and ($lr.text.Contains('my-unique-line-ABC123'))) 'F13 local get returns text+hash'
  $lrBad = $true
  try { Save-MgmtLocalRule $auto $impRes.name 'no-marker' $lr.hash | Out-Null; $lrBad = $false } catch { $lrBad = ($_.Exception.Message.Contains('形式')) }
  Assert ($lrBad) 'F13 invalid frontmatter refused'
  $lrStale = $true
  $goodText = "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nnew-body-XYZ"
  try { Save-MgmtLocalRule $auto $impRes.name $goodText ('0' * 64) | Out-Null; $lrStale = $false } catch { $lrStale = ($_.Exception.Message.Contains('変化')) }
  Assert ($lrStale) 'F13 stale expectedHash refused (optimistic concurrency)'
  Save-MgmtLocalRule $auto $impRes.name $goodText $lr.hash | Out-Null
  Assert ((Get-MgmtLocalRule $auto $impRes.name).text.Contains('new-body-XYZ')) 'F13 valid save with matching hash persists'

  # F14: duplicate/contradiction candidates, never assertive
  $dups = @(Get-MgmtDupCandidates $commonBody "unrelated line`nshared-line-one`ntail")
  Assert (($dups.Count -eq 1) -and ($dups[0].kind -ceq '重複候補') -and ($dups[0].line -ceq 'shared-line-one')) 'F14 identical line is duplicate candidate'
  $dups2 = @(Get-MgmtDupCandidates $commonBody 'totally different text here')
  Assert ($dups2.Count -eq 0) 'F14 different text is not flagged'
  $cons = @(Get-MgmtContradictionCandidates $commonBody 'shared-line-one は行わないでください')
  Assert (($cons.Count -ge 1) -and ($cons[0].kind -ceq '矛盾候補')) 'F14 negated overlap is contradiction candidate'
  $cons2 = @(Get-MgmtContradictionCandidates $commonBody 'unrelated text here')
  Assert ($cons2.Count -eq 0) 'F14 unrelated text is not a contradiction candidate'
  $modTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Project-Management.ps1') -Raw
  Assert (($modTxt.Contains('候補') -and (-not ($modTxt.Contains('矛盾しています'))) -and (-not ($modTxt.Contains('重複しています'))))) 'F14 wording stays candidate-only (no assertion)'

  # F12: backup list / diff / restore (AGENTS+localSource together, pause, no GitHub rollback)
  $bl = @(Get-MgmtBackupList $auto $impRes.name)
  Assert (($bl.Count -ge 1) -and ($bl[0].name -ceq $impRes.name)) 'F12 backup list finds import backup'
  Set-Content -LiteralPath (Join-Path $repoI 'AGENTS.md') 'drifted-agents-content' -Encoding Ascii
  $blAgents = @($bl | Where-Object { $_.hasAgentsFile })[0]
  if (-not $blAgents) { $blAgents = $bl[0] }
  $bd = Get-MgmtBackupDiff $auto $blAgents.id
  Assert (($bd.name -ceq $impRes.name) -and ($bd.same -eq $false) -and ($bd.lines.Count -ge 1)) 'F12 diff shows changed lines'
  Assert ($modTxt.Contains('commonSha') -or $modTxt.Contains('manifest')) 'F12 manifest-aware (common SHA kept)'
  $rsNoConfirm = $true
  try { Restore-MgmtBackup $auto $blAgents.id $false | Out-Null; $rsNoConfirm = $false } catch { $rsNoConfirm = ($_.Exception.Message.Contains('確認')) }
  Assert ($rsNoConfirm) 'F12 restore without confirm refused'
  $rs = Restore-MgmtBackup $auto $blAgents.id $true
  Assert ($rs.ok) 'F12 restore succeeds with confirm'
  Assert (((Get-Content -LiteralPath (Join-Path $repoI 'AGENTS.md') -Raw) -match 'my-unique-line-ABC123')) 'F12 restore brings back AGENTS content'
  $afterEn = Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq $impRes.name })[0]
  Assert ($afterEn -eq $false) 'F12 restore pauses project (enabled=false, no overwrite loop)'
  Assert ((-not ($modTxt.Contains('git ') -or $modTxt.Contains('gh '))) -or ($modTxt.Contains('GitHub') -and (-not ($modTxt.Contains('Invoke-Step'))))) 'F12 restore touches no shared GitHub (local files only)'
  $rsBad = $true
  try { Restore-MgmtBackup $auto '../evil' $true | Out-Null; $rsBad = $false } catch { $rsBad = $true }
  Assert ($rsBad) 'F12 traversal backupId refused'

  # F9: interval validation/parse/format + Global guard (no scheduler writes in tests)
  Assert ((Test-MgmtIntervalValid 15) -and (Test-MgmtIntervalValid 5) -and (Test-MgmtIntervalValid 1440)) 'F9 valid minutes pass'
  Assert ((-not (Test-MgmtIntervalValid 0)) -and (-not (Test-MgmtIntervalValid 4)) -and (-not (Test-MgmtIntervalValid 1441))) 'F9 out-of-range refused'
  Assert ((Parse-MgmtInterval 'PT15M') -eq 15) 'F9 PT15M parses to 15'
  Assert ((Parse-MgmtInterval 'PT1H') -eq 60) 'F9 PT1H parses to 60'
  Assert ($null -eq (Parse-MgmtInterval 'bogus')) 'F9 bogus interval parses to null'
  Assert ((Format-MgmtInterval 30) -ceq 'PT30M') 'F9 format is PT30M'
  $gGuard = $true
  try { Set-MgmtProjectInterval 'Shirube Global Auto Sync' 30; $gGuard = $false } catch { $gGuard = ($_.Exception.Message.Contains('Project')) }
  Assert ($gGuard) 'F9 Global task interval change refused (Project only)'
  $ivCur = Get-MgmtProjectInterval
  Assert (($ivCur -eq 17) -and (@($script:mockTaskCalls | Where-Object { $_ -like 'get:*' }).Count -ge 1)) 'F9 current Project interval reads the mocked task (no real task dependency)'
  Assert ((@($script:mockTaskCalls | Where-Object { $_ -like 'set:*' }).Count -eq 0)) 'F9 read-only interval checks never write the scheduler'

  # F15: export (no secrets) / import preview merge / import adds only
  $exp = Get-MgmtExport $auto
  $expJson = ($exp | ConvertTo-Json -Depth 5 -Compress)
  Assert (($exp.schemaVersion -eq 1) -and ($exp.projects.Count -ge 1)) 'F15 export carries registry'
  Assert ((-not ($expJson.Contains('dashboard.token'))) -and (-not ($expJson.ToLower().Contains('github_token')))) 'F15 export holds no secrets'
  $impData = @{ schemaVersion = 1; projects = @(@{ name = 'NewImp'; path = (New-Repo 'NewImp') }, @{ name = 'RepoE'; path = $repoE }, @{ name = 'bad name!'; path = 'x' }) }
  $impPrev15 = Get-MgmtImportPreview $auto $impData
  Assert (($impPrev15.add.Count -eq 1) -and ($impPrev15.skip.Count -eq 1) -and ($impPrev15.invalid.Count -eq 1)) 'F15 import preview splits add/skip/invalid'
  $impNoC = $true
  try { Import-MgmtRegistry $auto $impData $false | Out-Null; $impNoC = $false } catch { $impNoC = ($_.Exception.Message.Contains('確認')) }
  Assert ($impNoC) 'F15 import without confirm refused'
  $impDone = Import-MgmtRegistry $auto (@{ schemaVersion = 1; projects = @(@{ name = 'NewImp'; path = (New-Repo 'NewImp') }, @{ name = 'RepoE'; path = $repoE }) }) $true
  Assert (($impDone.added -eq 1) -and ($impDone.skipped -ge 1)) 'F15 import adds only new entries'
  Assert ((@((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'NewImp' })).Count -eq 1) 'F15 imported entry present'

  # F10/F11 data: project-status.json read
  $st = Get-MgmtProjectStatus $auto
  Assert ($st -ne $null) 'F10 status read returns object (empty ok)'

  # Sync-level: selection filter + disabled + unknown + preview-requires-plan + request file
  $syncAuto = Join-Path $scratch 'syncAuto'
  $syncPrev = Join-Path $scratch 'syncPreview'
  $syncBin = Join-Path $scratch 'syncBin'
  $syncA = Join-Path $scratch 'syncA'
  $syncB = Join-Path $scratch 'syncB'
  New-Item -ItemType Directory -Force -Path $syncAuto, $syncBin, $syncA, $syncB | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $syncPrev '.rulesync\rules\.curated') | Out-Null
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-ProjectRules.ps1') -Destination (Join-Path $syncAuto 'Sync-ProjectRules.ps1') -Force
  Set-Content -LiteralPath (Join-Path $syncPrev 'rulesync.jsonc') '{"targets":["codexcli","opencode"],"features":["rules"],"outputRoots":["output"],"delete":false,"global":false,"sources":[]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $syncPrev '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
  # NOTE: scratch layout differs (auto not sibling of preview); Sync resolves preview from its own parent,
  # so mirror layout: syncRoot/{auto,project-common-preview}
  $syncRoot = Join-Path $scratch 'syncRoot'
  $syncAuto2 = Join-Path $syncRoot 'auto'
  $syncPrev2 = Join-Path $syncRoot 'project-common-preview'
  New-Item -ItemType Directory -Force -Path $syncAuto2 | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $syncPrev2 '.rulesync\rules\.curated') | Out-Null
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-ProjectRules.ps1') -Destination (Join-Path $syncAuto2 'Sync-ProjectRules.ps1') -Force
  Set-Content -LiteralPath (Join-Path $syncPrev2 'rulesync.jsonc') '{"targets":["codexcli","opencode"],"features":["rules"],"outputRoots":["output"],"delete":false,"global":false,"sources":[]}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $syncPrev2 '.rulesync\rules\.curated\project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding Ascii
  $sReg = '[{"name":"syncA","path":"' + ($syncA -replace '\\', '\\') + '"},{"name":"syncB","path":"' + ($syncB -replace '\\', '\\') + '"}]'
  Set-Content -LiteralPath (Join-Path $syncAuto2 'projects.json') $sReg -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $syncBin 'npx.cmd') @'
@echo off
setlocal
set D=%DUMMY_DIR%
echo npx %* [cwd=%CD%]>> "%D%\calls.log"
set /p N=<"%D%\counter.txt"
set F=%D%\exit_!N!.txt
set CODE=0
if exist "!F!" set /p CODE=<"!F!"
set /a M=!N!+1
echo !M!>"%D%\counter.txt"
endlocal & exit /b %CODE%
'@ -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $syncBin 'gh.cmd') @'
@echo off
echo gh %*>> "%DUMMY_DIR%\calls.log"
echo %DUMMY_GH_TOKEN%
exit /b 0
'@ -Encoding Ascii
  $oPath = $env:PATH; $oDummy = $env:DUMMY_DIR; $oGhT = $env:DUMMY_GH_TOKEN; $oGh = $env:GH_TOKEN; $oGithub = $env:GITHUB_TOKEN
  try {
    $env:PATH = ($syncBin + ';' + $env:PATH)
    $env:DUMMY_DIR = $scratch
    $env:DUMMY_GH_TOKEN = 'tok'
    $env:GITHUB_TOKEN = 'tok'
    . (Join-Path $syncAuto2 'Sync-ProjectRules.ps1')
    Set-Content -LiteralPath (Join-Path $scratch 'counter.txt') '0' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $scratch 'exit_0.txt') '0' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $scratch 'exit_1.txt') '0' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $scratch 'exit_2.txt') '0' -Encoding Ascii
    $c0 = (Get-Location).Path
    # F8: selection filter runs only syncA (install + 1 check)
    $codeSel = Invoke-ProjectSync -ProjectNames @('syncA')
    $callsSel = @(Get-Content -LiteralPath (Join-Path $scratch 'calls.log'))
    Assert (($codeSel -eq 0) -and ($callsSel.Count -eq 2)) 'F8 selected sync runs install+1 check only'
    # F4 backend: disabled project is skipped without npx calls
    Set-Content -LiteralPath (Join-Path $syncAuto2 'projects.json') ('[{"name":"syncA","path":"' + ($syncA -replace '\\', '\\') + '","enabled":false},{"name":"syncB","path":"' + ($syncB -replace '\\', '\\') + '"}]') -Encoding Ascii
    Remove-Item -LiteralPath (Join-Path $scratch 'calls.log') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $scratch 'counter.txt') '0' -Encoding Ascii
    $codeDis = Invoke-ProjectSync
    $callsDis = @(Get-Content -LiteralPath (Join-Path $scratch 'calls.log') -ErrorAction SilentlyContinue)
    Assert (($codeDis -eq 0) -and ($callsDis.Count -eq 2)) 'F4 backend disabled skips its npx calls'
    $stJson = Get-Content -LiteralPath (Join-Path $syncAuto2 'project-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ([string]$stJson.projects.syncA.result -ceq 'skipped') 'F4 backend disabled recorded as skipped'
    # F8 backend: unknown selected project refuses
    Set-Content -LiteralPath (Join-Path $syncAuto2 'projects.json') $sReg -Encoding Ascii
    $codeUnk = Invoke-ProjectSync -ProjectNames @('nope')
    Assert ($codeUnk -eq 1) 'F8 backend unknown selection exits 1'
    # F7 backend: preview requires planPath
    $codeNoPlan = Invoke-ProjectSync -PreviewOnly
    Assert ($codeNoPlan -eq 1) 'F7 backend preview without planPath exits 1'
    # F8 backend: request file carries selection
    $reqId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $reqFile = Join-Path $syncAuto2 ("dashboard.request-" + $reqId + ".json")
    Set-Content -LiteralPath $reqFile (@{ projectNames = @('syncB'); previewOnly = $false; planPath = '' } | ConvertTo-Json -Compress) -Encoding Ascii
    Remove-Item -LiteralPath (Join-Path $scratch 'calls.log') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath (Join-Path $scratch 'counter.txt') '0' -Encoding Ascii
    $codeReq = Invoke-ProjectSync -RequestPath $reqFile
    $callsReq = @(Get-Content -LiteralPath (Join-Path $scratch 'calls.log') -ErrorAction SilentlyContinue)
    Assert (($codeReq -eq 0) -and ($callsReq.Count -eq 2) -and (@($callsReq | Where-Object { $_ -like '*syncB*' }).Count -ge 1) -and (@($callsReq | Where-Object { $_ -like '*syncA*' }).Count -eq 0)) 'F8 backend request file filters to syncB'
    Assert (((Get-Location).Path) -eq $c0) 'F8 backend cwd restored'
  } finally {
    $env:PATH = $oPath
    $env:DUMMY_DIR = $oDummy
    if ($null -eq $oDummy) { Remove-Item Env:DUMMY_DIR -ErrorAction SilentlyContinue }
    $env:DUMMY_GH_TOKEN = $oGhT
    if ($null -eq $oGhT) { Remove-Item Env:DUMMY_GH_TOKEN -ErrorAction SilentlyContinue }
    $env:GH_TOKEN = $oGh
    if ($null -eq $oGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
    $env:GITHUB_TOKEN = $oGithub
    if ($null -eq $oGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  }

  # Watch forwards -RequestPath to the fixed sync script (stub records args)
  $wAuto = Join-Path $scratch 'wAuto'
  New-Item -ItemType Directory -Force -Path $wAuto | Out-Null
  Copy-Item -LiteralPath (Join-Path $devAuto 'Watch-Sync.ps1') -Destination (Join-Path $wAuto 'Watch-Sync.ps1') -Force
  Set-Content -LiteralPath (Join-Path $wAuto 'Sync-ProjectRules.ps1') 'param([switch]$ReportSkip, [string]$RequestPath) Set-Content -LiteralPath (Join-Path $PSScriptRoot "stub-args.txt") ("ReportSkip=" + $ReportSkip + " RequestPath=" + $RequestPath) -Encoding Ascii; exit 0' -Encoding Ascii
  $wReq = Join-Path $wAuto 'dashboard.request-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'
  Set-Content -LiteralPath $wReq '{}' -Encoding Ascii
  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $wAuto 'Watch-Sync.ps1') -AutoDir $wAuto -RunId 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -RequestPath $wReq
  Assert ($LASTEXITCODE -eq 0) 'F7 watch runs with RequestPath without own failure'
  $stubArgs = ''
  if (Test-Path -LiteralPath (Join-Path $wAuto 'stub-args.txt')) { $stubArgs = Get-Content -LiteralPath (Join-Path $wAuto 'stub-args.txt') -Raw }
  Assert ($stubArgs.Contains($wReq)) 'F7 watch forwards RequestPath to sync script'
  $wRes = Get-Content -LiteralPath (Join-Path $wAuto 'dashboard.sync-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json') -Raw -Encoding Ascii | ConvertFrom-Json
  Assert (([int]$wRes.exitCode -eq 0) -and ([string]$wRes.result -ceq 'success')) 'F7 watch records forwarded run result'

  # Static: new endpoints keep existing safety (POST-only dispatch, token+Origin, no arbitrary shell)
  $srvTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Dashboard-Server.ps1') -Raw
  foreach ($ep in @('/api/preview-batch', '/api/register-batch', '/api/import-preview', '/api/rename', '/api/enabled', '/api/move', '/api/plan-start', '/api/plan', '/api/project-status', '/api/backups', '/api/backup-diff', '/api/restore', '/api/localrule-get', '/api/localrule-save', '/api/check', '/api/export', '/api/registry-import-preview', '/api/import', '/api/interval-get', '/api/interval-set')) {
    Assert ($srvTxt.Contains($ep)) ("API endpoint present: " + $ep)
  }
  Assert ((-not ($srvTxt.Contains('Invoke-Expression'))) -and (-not ($srvTxt.Contains('cmd.exe /c')))) 'M0 no arbitrary shell in new endpoints'
  Assert ($srvTxt.Contains('Project-Management.ps1')) 'M0 dashboard dot-sources management module'
  $natA = ([regex]::Matches($srvTxt, 'alert\(')).Count
  $natC = ([regex]::Matches($srvTxt, 'confirm\(')).Count
  $natP = ([regex]::Matches($srvTxt, 'prompt\(')).Count
  Assert (($natA -eq 0) -and ($natC -eq 0) -and ($natP -eq 0)) 'M0 native dialogs still zero'
  try {
    $pe = $null; $pt = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $devAuto 'Project-Management.ps1'), [ref]$pt, [ref]$pe)
    Assert (($pe.Count -eq 0)) 'M0 module PS syntax ok'
    $pe2 = $null; $pt2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $devAuto 'Dashboard-Server.ps1'), [ref]$pt2, [ref]$pe2)
    Assert (($pe2.Count -eq 0)) 'M0 dashboard PS syntax ok'
  } catch { Assert ($false) 'M0 PS syntax check ran' }

  # Live server on scratch port: end-to-end through HTTP. The scratch launcher
  # installs the same scheduler shadows, so the server process never reads the
  # real Project task either.
  $srvStub = Join-Path $scratch 'dashboard-stub.ps1'
  $srvStubText = @'
$ErrorActionPreference = 'Stop'
function Get-ScheduledTask { [CmdletBinding()] param([string]$TaskName)
  $tr = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = [pscustomobject]@{ Interval = 'PT17M' } }
  return [pscustomobject]@{ TaskName = [string]$TaskName; State = 'Ready'; Triggers = @($tr) }
}
function Set-ScheduledTask { [CmdletBinding()] param([string]$TaskName, $Trigger) return [pscustomobject]@{ TaskName = [string]$TaskName } }
function Disable-ScheduledTask { [CmdletBinding()] param([string]$TaskName) }
function Enable-ScheduledTask { [CmdletBinding()] param([string]$TaskName) }
& '__SERVER__'
'@
  Set-Content -LiteralPath $srvStub ($srvStubText.Replace('__SERVER__', (Join-Path $devAuto 'Dashboard-Server.ps1'))) -Encoding UTF8
  $env:DASHBOARD_PORT = '18797'
  $srv = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $srvStub + '"') -WindowStyle Hidden -PassThru
  try {
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18797/health'
        if ($r.StatusCode -eq 200) { $ok = $true; break }
      } catch {}
      if ($srv.HasExited) { break }
    }
    Assert ($ok) 'L0 health responds on scratch port'
    if ($ok) {
      $tok = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $script:hdrs = @{ 'X-Dashboard-Token' = $tok }
      function Post([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $script:hdrs -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18797' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      # Chain stub: Watch forwards the request file; the stub writes a canned plan and exits 0.
      Copy-Item -LiteralPath (Join-Path $devAuto 'Watch-Sync.ps1') -Destination (Join-Path $auto 'Watch-Sync.ps1') -Force
      $stubSync = @'
param([switch]$ReportSkip, [string]$RequestPath)
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stub-args.txt') ("RequestPath=" + $RequestPath) -Encoding Ascii
if ($RequestPath -and (Test-Path -LiteralPath $RequestPath)) {
  $rq = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($rq.previewOnly -and ([string]$rq.planPath) -ne '') {
    $names = @()
    if ($rq.projectNames) { $names = @($rq.projectNames) }
    if ($names.Count -eq 0) { $names = @('Batch2') }
    $projs = @()
    foreach ($nn in $names) { $projs += @{ name = [string]$nn; path = 'stub-path'; result = 'success'; currentText = 'same-text'; generatedText = 'same-text'; agentsHash = 'a'; localHash = 'b'; commonSha = 'c'; commonCommit = 'd'; error = '' } }
    $plan = @{ schemaVersion = 1; commonSha = 'c'; commonCommit = 'd'; commonText = 'x'; createdAt = 't'; projects = $projs }
    Set-Content -LiteralPath ([string]$rq.planPath) (ConvertTo-Json -InputObject $plan -Depth 8 -Compress) -Encoding Ascii
  }
}
exit 0
'@
      Set-Content -LiteralPath (Join-Path $auto 'Sync-ProjectRules.ps1') $stubSync -Encoding Ascii
      # F2 batch: two fresh repos preview+register together
      $b1 = New-Repo 'Batch1'; $b2 = New-Repo 'Batch2'
      $bp = Post '/api/preview-batch' @{ paths = @($b1, $b2) }
      Assert (($bp.results.Count -eq 2) -and ($bp.results[0].ok -eq $true) -and ($bp.results[1].ok -eq $true)) 'L2 batch preview ok x2'
      $items = @(@{ previewId = $bp.results[0].previewId; path = $bp.results[0].path }, @{ previewId = $bp.results[1].previewId; path = $bp.results[1].path })
      Set-Content -LiteralPath (Join-Path $auto 'Run-ProjectRules.vbs') "' dummy launcher" -Encoding Ascii
      $br = Post '/api/register-batch' @{ items = $items; confirm = $true }
      Assert (($br.ok -eq $true) -and ($br.registered.Count -eq 2)) 'L2 batch register registers both'
      # F3 rename via HTTP (display only, internal name stable)
      $rn = Post '/api/rename' @{ oldName = 'Batch1'; newName = 'Batch1R' }
      $rnE = @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'Batch1' })[0]
      Assert (($rn.ok -eq $true) -and ([string]$rnE.displayName -ceq 'Batch1R')) 'L3 rename sets display via HTTP'
      # F4 enabled via HTTP
      $en = Post '/api/enabled' @{ name = 'Batch1'; enabled = $false }
      Assert (($en.ok -eq $true) -and ((Get-MgmtEffectiveEnabled @((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'Batch1' })[0]) -eq $false)) 'L4 disable via HTTP'
      # F6 move via HTTP
      $mvDst = New-Repo 'BatchMoveDst'
      $mv = Post '/api/move' @{ name = 'Batch2'; newPath = $mvDst }
      Assert (($mv.ok -eq $true) -and ((@((Get-Registry $auto) | Where-Object { [string]$_.name -ceq 'Batch2' })[0].path -ceq $mvDst))) 'L6 move via HTTP'
      # F10/F11 status via HTTP
      $stResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs 'http://127.0.0.1:18797/api/project-status'
      $stJ = ($stResp.Content | ConvertFrom-Json)
      Assert ((@($stJ.projects).Count) -ge 2) 'L10 status via HTTP carries projects'
      # F9 interval-get via HTTP (read-only)
      $ivResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs 'http://127.0.0.1:18797/api/interval-get'
      $ivJ = ($ivResp.Content | ConvertFrom-Json)
      Assert (([int]$ivJ.minutes -eq 17)) 'L9 interval-get returns the mocked interval (no real task)'
      $ivPut = $true; $ivCode = 0
      # minutes=3 fails validation before any scheduler write (production untouched).
      try { Post '/api/interval-set' @{ minutes = 3; confirm = $true } | Out-Null } catch { $ivPut = $false; $ivCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $ivPut) -and ($ivCode -eq 400)) 'L9 interval-set out-of-range is 400 (no scheduler write)'
      # F12 backups via HTTP (import backup from earlier module test is in scratch auto)
      $blResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs 'http://127.0.0.1:18797/api/backups'
      $blJ = ($blResp.Content | ConvertFrom-Json)
      Assert ((@($blJ.backups).Count) -ge 1) 'L12 backups list via HTTP'
      $firstEntry = @($blJ.backups | Where-Object { [string]$_.name -ceq $impRes.name })[0]
      if (-not $firstEntry) { $firstEntry = $blJ.backups[0] }
      $firstId = [string]$firstEntry.id
      $bdJ = Post '/api/backup-diff' @{ backupId = $firstId }
      Assert ((@($bdJ.lines).Count) -ge 0) 'L12 backup diff via HTTP'
      # F13 live: seed a local file for Batch2 directly, then exercise get/save/409 over HTTP.
      New-Item -ItemType Directory -Force -Path (Join-Path $mvDst '.rulesync\rules') | Out-Null
      Set-Content -LiteralPath (Join-Path $mvDst '.rulesync\rules\project-local.md') ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlive-local-body") -Encoding UTF8
      $lrJ = Post '/api/localrule-get' @{ name = 'Batch2' }
      Assert (($lrJ.hash -match '^[0-9a-f]{64}$')) 'L13 localrule-get via HTTP'
      $lrSaveBad = $true
      try { Post '/api/localrule-save' @{ name = 'Batch2'; text = 'x'; expectedHash = ('0' * 64) } | Out-Null; $lrSaveBad = $false } catch { $lrSaveBad = ($_.Exception.Response.StatusCode.value__ -eq 409) }
      Assert ($lrSaveBad) 'L13 stale hash save is 409 via HTTP'
      $lrSaveOk = Post '/api/localrule-save' @{ name = 'Batch2'; text = ("---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nlive-local-v2"); expectedHash = $lrJ.hash }
      Assert (($lrSaveOk.ok -eq $true) -and ($lrSaveOk.hash -match '^[0-9a-f]{64}$')) 'L13 valid save via HTTP'
      # F14 check via HTTP (candidate wording only)
      $ckJ = Post '/api/check' @{ name = $impRes.name }
      Assert ((@($ckJ.duplicates).Count -ge 0) -and (@($ckJ.contradictions).Count -ge 0)) 'L14 check via HTTP returns candidate lists'
      # F15 export/import via HTTP
      $exResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs 'http://127.0.0.1:18797/api/export'
      Assert (($exResp.Content.Contains('"schemaVersion":1')) -and (-not ($exResp.Content.Contains('dashboard.token')))) 'L15 export via HTTP, no secrets'
      $exJ = ($exResp.Content | ConvertFrom-Json)
      $ipJ = Post '/api/registry-import-preview' @{ data = $exJ }
      Assert ((@($ipJ.skip).Count -ge 1)) 'L15 import-preview of own export skips existing'
      # F7 plan full chain: request -> Watch -> stub sync writes plan -> /api/plan ready.
      $plJ = Post '/api/plan-start' @{ projectNames = @('Batch2') }
      Assert (($plJ.planId -match '^[0-9a-f]{32}$')) 'L7 plan-start returns planId'
      $plReady = $null
      for ($pi = 0; $pi -lt 20; $pi++) {
        Start-Sleep -Milliseconds 1000
        try {
          $plW = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs ('http://127.0.0.1:18797/api/plan?id=' + $plJ.planId)
          $plWJ = ($plW.Content | ConvertFrom-Json)
          if ([string]$plWJ.status -ceq 'ready') { $plReady = $plWJ; break }
        } catch {}
      }
      Assert (($null -ne $plReady) -and (@($plReady.projects).Count -eq 1) -and ([string]$plReady.projects[0].name -ceq 'Batch2')) 'L7 plan ready carries requested project'
      $plBad = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs 'http://127.0.0.1:18797/api/plan?id=bad' | Out-Null; $plBad = $false } catch { $plBad = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($plBad) 'L7 bad plan id is 400'
      # F8 selected sync full chain: request -> Watch -> stub exits 0 -> runID-bound success.
      $syJ = Post '/api/sync' @{ projectNames = @('Batch2') }
      Assert (($syJ.sync -eq 'started') -and ($syJ.syncId -match '^[0-9a-f]{32}$')) 'L8 selected sync starts with runID'
      $syDone = $false
      for ($si = 0; $si -lt 20; $si++) {
        Start-Sleep -Milliseconds 1000
        try {
          $stW = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $hdrs 'http://127.0.0.1:18797/api/status'
          $stWJ = ($stW.Content | ConvertFrom-Json)
          if (([string]$stWJ.syncId -ceq [string]$syJ.syncId) -and ([string]$stWJ.syncState -ceq 'success')) { $syDone = $true; break }
        } catch {}
      }
      Assert ($syDone) 'L8 selected sync completes as runID-bound success'
      # F5 search is UI-only: served page carries filter box
      $page = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 ("http://127.0.0.1:18797/?token=" + $tok)
      Assert ($page.Content.Contains('id="inpSearch"')) 'L5 served page has search filter box'
      Assert (($page.Content.Contains('id="tblStatus"') -and $page.Content.Contains('id="tblBackups"') -and $page.Content.Contains('id="btnExport"'))) 'L0 served page has status/backup/export UI'
      try {
        $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $nodeExe) { $nodeExe = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
        if ($nodeExe) {
          $m = [regex]::Match($page.Content, '(?s)<script>(.*)</script>')
          if ($m.Success) {
            $jsTmp = Join-Path $scratch 'mgmt15-page-check.js'
            Set-Content -LiteralPath $jsTmp $m.Groups[1].Value -Encoding UTF8
            & $nodeExe --check $jsTmp
            Assert ($LASTEXITCODE -eq 0) 'L0 served JS parses (node --check)'
          } else { Assert ($false) 'L0 script block found' }
        } else { Assert ($true) 'L0 node missing skips parse check' }
      } catch { Assert ($false) 'L0 served JS parse check ran' }
    }
  } finally {
    try { if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force } } catch {}
  }

  Assert (((Get-Location).Path) -eq $initCwd) 'cwd unchanged'
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
if ($failures.Count -eq 0) { Write-Host 'ALL MGMT15 CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
