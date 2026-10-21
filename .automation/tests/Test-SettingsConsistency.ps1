# Test-SettingsConsistency.ps1 - one task name and one rulesync version per operation.
# Scratch-only: Settings.ps1 and the management modules are copied into a temp
# directory, and ScheduledTasks calls are stubbed in this test scope. The real
# settings.json and the real scheduled tasks are never read or changed.
$ErrorActionPreference = 'Stop'
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot

$testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'SettingsConsistencyTest'
New-Item -ItemType Directory -Force -Path $testBase | Out-Null
$scratch = Join-Path $testBase ('run-' + [System.Guid]::NewGuid().ToString('N'))
$auto = Join-Path $scratch 'auto'
New-Item -ItemType Directory -Force -Path $auto | Out-Null

$script:settingsPath = Join-Path $auto 'settings.json'
$script:taskCalls = @()
$script:setCalls = @()
$script:onGet = $null
$script:onSet = $null
$script:throwTask = ''
$script:intervals = @{}

function Set-TestSettings([string]$Global, [string]$Project, [string]$Version) {
  $o = [ordered]@{ taskNameGlobal = $Global; taskNameProject = $Project; rulesyncVersion = $Version }
  Set-Content -LiteralPath $script:settingsPath -Value ($o | ConvertTo-Json -Compress) -Encoding UTF8
}
# The import interval path never needs the dashboard registry helpers.
function Get-Registry([string]$AutoDir) { return @() }
# Shadows the ScheduledTasks cmdlets for this test scope only.
function Get-ScheduledTask {
  [CmdletBinding()] param([string]$TaskName)
  $script:taskCalls += $TaskName
  if ($script:onGet) { $cb = $script:onGet; $script:onGet = $null; & $cb }
  $iv = 15
  if ($script:intervals.ContainsKey($TaskName)) { $iv = [int]$script:intervals[$TaskName] }
  $tr = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = [pscustomobject]@{ Interval = ('PT' + $iv + 'M') } }
  return [pscustomobject]@{ TaskName = $TaskName; State = 'Ready'; Triggers = @($tr) }
}
function Set-ScheduledTask {
  [CmdletBinding()] param([string]$TaskName, $Trigger)
  $script:setCalls += $TaskName
  foreach ($t in @($Trigger)) {
    $m = [regex]::Match([string]$t.Repetition.Interval, '^PT(?:(\d+)H)?(?:(\d+)M)?$')
    if ($m.Success -and $script:intervals.ContainsKey($TaskName)) {
      $h = 0
      $mi = 0
      if ($m.Groups[1].Success) { $h = [int]$m.Groups[1].Value }
      if ($m.Groups[2].Success) { $mi = [int]$m.Groups[2].Value }
      $script:intervals[$TaskName] = ($h * 60 + $mi)
    }
  }
  if ($script:onSet) { & $script:onSet $TaskName }
  if ($script:throwTask -ceq $TaskName) { $script:throwTask = ''; throw 'simulated post-write scheduler failure' }
  return [pscustomobject]@{ TaskName = $TaskName }
}

try {
  foreach ($f in @('Settings.ps1', 'Global-Management.ps1', 'Project-Management.ps1')) {
    Copy-Item -LiteralPath (Join-Path $devAuto $f) -Destination (Join-Path $auto $f) -Force
  }
  . (Join-Path $auto 'Global-Management.ps1')
  . (Join-Path $auto 'Project-Management.ps1')

  # Count settings reads without changing Settings.ps1 itself.
  $script:realGetSetting = ${function:Get-ShirubeSetting}
  $script:settingReads = @()
  function Get-ShirubeSetting {
    param([string]$Name = '', $Default = $null)
    $script:settingReads += [string]$Name
    return (& $script:realGetSetting -Name $Name -Default $Default)
  }

  # T1: Set-GlobalInterval reads the task name once; a settings change between
  # Get-ScheduledTask and Set-ScheduledTask must not retarget the task.
  Set-TestSettings 'Rulesync Global Auto Sync' 'Rulesync Project Auto Sync' '32.0.0'
  $script:taskCalls = @()
  $script:setCalls = @()
  $script:settingReads = @()
  $script:onGet = { Set-TestSettings 'Changed Global Task' 'Rulesync Project Auto Sync' '9.9.9' }
  Set-GlobalInterval 30 | Out-Null
  $allNames = @($script:taskCalls + $script:setCalls)
  $globalReads = @($script:settingReads | Where-Object { $_ -ceq 'taskNameGlobal' }).Count
  $ok = (($globalReads -eq 1) -and (@($allNames | Select-Object -Unique).Count -eq 1) -and ($allNames[0] -ceq 'Rulesync Global Auto Sync'))
  Assert $ok 'T1 Set-GlobalInterval reads one name and cannot retarget mid-operation'

  # T2: Set-MgmtProjectInterval enables exactly one task-name read per call and
  # keeps Get-ScheduledTask and Set-ScheduledTask on the same name.
  Set-TestSettings 'Rulesync Global Auto Sync' 'Rulesync Project Auto Sync' '32.0.0'
  $script:taskCalls = @()
  $script:setCalls = @()
  $script:settingReads = @()
  $script:onGet = { Set-TestSettings 'Rulesync Global Auto Sync' 'Changed Project Task' '9.9.9' }
  Set-MgmtProjectInterval 'Rulesync Project Auto Sync' 45 | Out-Null
  $allNames = @($script:taskCalls + $script:setCalls)
  $projectReads = @($script:settingReads | Where-Object { $_ -ceq 'taskNameProject' }).Count
  $ok = (($projectReads -eq 1) -and (@($allNames | Select-Object -Unique).Count -eq 1) -and ($allNames[0] -ceq 'Rulesync Project Auto Sync'))
  Assert $ok 'T2 Set-MgmtProjectInterval reads one name and keeps one target'

  # T3: an explicit version is used as-is; omitting it keeps the settings read.
  Set-TestSettings 'Rulesync Global Auto Sync' 'Rulesync Project Auto Sync' '9.9.9'
  $script:settingReads = @()
  $argvPinned = @(Get-GlobalGenerateArgv 'codexcli,opencode' 'check' '1.2.3')
  $versionReads = @($script:settingReads | Where-Object { $_ -ceq 'rulesyncVersion' }).Count
  $ok = (($argvPinned -contains 'rulesync@1.2.3') -and (-not ($argvPinned -contains 'rulesync@9.9.9')) -and ($versionReads -eq 0))
  Assert $ok 'T3 explicit version is used without a settings read'
  $script:settingReads = @()
  $argvDefault = @(Get-GlobalGenerateArgv 'codexcli,opencode' 'check')
  $versionReads = @($script:settingReads | Where-Object { $_ -ceq 'rulesyncVersion' }).Count
  $ok = (($argvDefault -contains 'rulesync@9.9.9') -and ($versionReads -eq 1))
  Assert $ok 'T3 omitted version still reads settings once (existing behavior)'
  Set-TestSettings 'Rulesync Global Auto Sync' 'Rulesync Project Auto Sync' '32.0.0'
  $argvFallback = @(Get-GlobalGenerateArgv 'codexcli,opencode' 'dry-run')
  Assert ($argvFallback -contains 'rulesync@32.0.0') 'T3 default version is unchanged'

  # T4: one operation resolves the version once; later settings edits do not
  # leak into check/dry-run/generate argv.
  $runVersion = [string](Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0')
  Set-TestSettings 'Rulesync Global Auto Sync' 'Rulesync Project Auto Sync' '9.9.9'
  $versions = @()
  foreach ($mode in @('', 'check', 'dry-run')) {
    foreach ($a in @(Get-GlobalGenerateArgv 'codexcli,opencode' $mode $runVersion)) {
      $m = [regex]::Match([string]$a, '^rulesync@(.+)$')
      if ($m.Success) { $versions += $m.Groups[1].Value }
    }
  }
  $ok = ((@($versions | Select-Object -Unique).Count -eq 1) -and ($versions[0] -ceq '32.0.0'))
  Assert $ok 'T4 one operation keeps a single generate version'

  # T5: the sync entry points pin that version for every generate call.
  $sgTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Raw
  $sgCalls = [regex]::Matches($sgTxt, 'Get-GlobalGenerateArgv\s+\$Targets')
  $sgPinned = [regex]::Matches($sgTxt, 'Get-GlobalGenerateArgv\s+\$Targets\s+''[^'']*''\s+\$RulesyncVersion')
  Assert (($sgCalls.Count -eq 5) -and ($sgPinned.Count -eq 5)) 'T5 every global generate call pins the run version'
  $spTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Sync-ProjectRules.ps1') -Raw
  Assert (([regex]::Matches($spTxt, "Get-ShirubeSetting -Name 'rulesyncVersion'")).Count -eq 1) 'T5 project sync resolves the version once per run'
  Assert (([regex]::Matches($sgTxt, "Get-ShirubeSetting -Name 'rulesyncVersion'")).Count -eq 1) 'T5 global sync resolves the version once per run'

  # T6: an import pins the Project task for preview, apply, verification and
  # rollback. If settings switch A->B mid-apply, B's interval must never be the
  # reason to skip the rollback check on A (review repro: A=15, B=15, apply 30).
  Set-TestSettings 'Rulesync Global Auto Sync' 'TaskA' '32.0.0'
  $script:intervals = @{ TaskA = 15; TaskB = 15 }
  $script:taskCalls = @()
  $script:setCalls = @()
  $script:settingReads = @()
  $script:onGet = $null
  $script:throwTask = 'TaskA'
  $script:onSet = {
    param([string]$TaskName)
    if (($TaskName -ceq 'TaskA') -and ([int]$script:intervals['TaskA'] -eq 30)) {
      Set-TestSettings 'Rulesync Global Auto Sync' 'TaskB' '32.0.0'
    }
  }
  $impErr = $null
  try { Import-MgmtRegistry $auto @{ schemaVersion = 1; projects = @(); intervalMinutes = 30 } $true | Out-Null }
  catch { $impErr = $_.Exception.Message }
  $script:onSet = $null
  $script:throwTask = ''
  $allNames = @($script:taskCalls + $script:setCalls)
  $ok = (($allNames.Count -ge 2) -and (@($allNames | Where-Object { $_ -cne 'TaskA' }).Count -eq 0))
  Assert $ok 'T6 import preview/apply/verify touch only the pinned task A'
  $ok = (($impErr -ne $null) -and $impErr.Contains('手動で確認'))
  Assert $ok 'T6 a mid-apply switch to B never hides the uncompensated A interval'
  Assert ([int]$script:intervals['TaskA'] -eq 30) 'T6 the A write is the only scheduler change'
  Assert ([int]$script:intervals['TaskB'] -eq 15) 'T6 B stays untouched by the import'
}
finally {
  if (Test-Path -LiteralPath $scratch) {
    if (-not $scratch.StartsWith($testBase, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

if ($failures.Count -gt 0) {
  Write-Host ("FAILURES: " + ($failures -join ', '))
  exit 1
}
Write-Host 'ALL SETTINGS CONSISTENCY TESTS PASSED'
exit 0
