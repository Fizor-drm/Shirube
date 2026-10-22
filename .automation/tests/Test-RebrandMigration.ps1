# Test-RebrandMigration.ps1 - Shirube rename invariants: task defaults, legacy
# task fallback, AppData launcher paths, and migration documentation.
# Scratch-only. Scheduler cmdlets are shadowed; no real task or AppData is read.
$ErrorActionPreference = 'Stop'
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot
$devRoot = Split-Path -Parent $devAuto
$testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'RebrandMigrationTest'
New-Item -ItemType Directory -Force -Path $testBase | Out-Null
$scratch = Join-Path $testBase ('run-' + [System.Guid]::NewGuid().ToString('N'))
$auto = Join-Path $scratch 'auto'
New-Item -ItemType Directory -Force -Path $auto | Out-Null
$script:taskIntervals = @{}
$script:taskErrors = @{}
$script:taskCalls = @()
$script:setCalls = @()
$script:enabledCalls = @()

# Shadows the ScheduledTasks cmdlets for this test scope only.
function Get-ScheduledTask {
  [CmdletBinding()] param([string]$TaskName)
  $script:taskCalls += $TaskName
  if ($script:taskErrors.ContainsKey($TaskName)) { throw $script:taskErrors[$TaskName] }
  if (-not $script:taskIntervals.ContainsKey($TaskName)) {
    throw ([System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('No MSFT_ScheduledTask objects found with property TaskName equal to ' + $TaskName),
      'CmdletizationQuery_NotFound_TaskName,Get-ScheduledTask',
      [System.Management.Automation.ErrorCategory]::ObjectNotFound,
      $TaskName))
  }
  $rep = New-Object PSObject -Property @{ Interval = ('PT' + [int]$script:taskIntervals[$TaskName] + 'M') }
  $tr = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = $rep }
  return [pscustomobject]@{ TaskName = $TaskName; State = 'Ready'; Triggers = @($tr) }
}
function Set-ScheduledTask {
  [CmdletBinding()] param([string]$TaskName, $Trigger)
  $script:setCalls += $TaskName
  $m = [regex]::Match([string]$Trigger[0].Repetition.Interval, '^PT(?:(\d+)H)?(?:(\d+)M)?$')
  if ($m.Success) {
    $h = 0; $mi = 0
    if ($m.Groups[1].Success) { $h = [int]$m.Groups[1].Value }
    if ($m.Groups[2].Success) { $mi = [int]$m.Groups[2].Value }
    $script:taskIntervals[$TaskName] = ($h * 60 + $mi)
  }
  return [pscustomobject]@{ TaskName = $TaskName }
}
function Disable-ScheduledTask { param([string]$TaskName) $script:enabledCalls += ('disable:' + $TaskName) }
function Enable-ScheduledTask { param([string]$TaskName) $script:enabledCalls += ('enable:' + $TaskName) }
function Set-TestSettings([string]$Text) {
  Set-Content -LiteralPath (Join-Path $auto 'settings.json') -Value $Text -Encoding UTF8
}

$origLocal = $env:LOCALAPPDATA
try {
  foreach ($f in @('Settings.ps1', 'Global-Management.ps1', 'Project-Management.ps1')) {
    Copy-Item -LiteralPath (Join-Path $devAuto $f) -Destination (Join-Path $auto $f) -Force
  }
  . (Join-Path $auto 'Global-Management.ps1')
  . (Join-Path $auto 'Project-Management.ps1')

  # R1: renamed defaults, one source of truth in the example settings.
  Assert ((Get-GlobalTaskName) -ceq 'Shirube Global Auto Sync') 'R1 global task default is Shirube'
  Assert ((Get-MgmtProjectTaskName) -ceq 'Shirube Project Auto Sync') 'R1 project task default is Shirube'
  $ex = Get-Content -LiteralPath (Join-Path $devAuto 'settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert (([string]$ex.taskNameGlobal -ceq 'Shirube Global Auto Sync') -and ([string]$ex.taskNameProject -ceq 'Shirube Project Auto Sync')) 'R1 example settings match the defaults'

  # R2: Global falls back to the pre-rename task only when the new default is absent.
  $script:taskIntervals = @{ 'Rulesync Global Auto Sync' = 15 }
  Assert ((Get-GlobalInterval) -eq 15) 'R2 global legacy task is found when the new default is absent'
  $script:setCalls = @()
  Set-GlobalInterval 30 | Out-Null
  Assert ((@($script:setCalls).Count -eq 1) -and ([string]$script:setCalls[0] -ceq 'Rulesync Global Auto Sync')) 'R2 global legacy task is updated in place'
  $script:taskIntervals = @{ 'Rulesync Global Auto Sync' = 15; 'Shirube Global Auto Sync' = 25 }
  $script:setCalls = @()
  Assert ((Get-GlobalInterval) -eq 25) 'R2 new global task wins when both exist'
  Set-GlobalInterval 40 | Out-Null
  Assert ((@($script:setCalls).Count -eq 1) -and ([string]$script:setCalls[0] -ceq 'Shirube Global Auto Sync')) 'R2 new global task is updated when both exist'
  $script:enabledCalls = @()
  Set-GlobalTaskEnabled $false | Out-Null
  Assert ([string]$script:enabledCalls[0] -ceq 'disable:Shirube Global Auto Sync') 'R2 global enable toggle resolves the new default first'

  # Access denied on the new default must not be mistaken for "task absent".
  $script:taskIntervals = @{ 'Rulesync Global Auto Sync' = 15 }
  $script:taskErrors = @{ 'Shirube Global Auto Sync' = [System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('Access is denied.'), 'TaskLookupDenied,Get-ScheduledTask',
      [System.Management.Automation.ErrorCategory]::PermissionDenied, 'Shirube Global Auto Sync') }
  $script:taskCalls = @()
  $deniedGlobal = $false
  try { Get-GlobalInterval | Out-Null } catch { $deniedGlobal = $_.Exception.Message.Contains('Access is denied') }
  Assert $deniedGlobal 'R2 global access-denied lookup propagates the original error'
  Assert (-not (@($script:taskCalls) -contains 'Rulesync Global Auto Sync')) 'R2 global access-denied lookup never falls back to legacy'
  $script:taskErrors = @{}

  # R3: Project has the same fallback; custom configured names never fall back.
  Remove-Item -LiteralPath (Join-Path $auto 'settings.json') -Force -ErrorAction SilentlyContinue
  $script:taskIntervals = @{ 'Rulesync Project Auto Sync' = 15 }
  Assert ((Get-MgmtProjectInterval) -eq 15) 'R3 project legacy task is found when the new default is absent'
  $script:setCalls = @()
  Set-MgmtProjectInterval 'Shirube Project Auto Sync' 30 | Out-Null
  Assert ((@($script:setCalls).Count -eq 1) -and ([string]$script:setCalls[0] -ceq 'Rulesync Project Auto Sync')) 'R3 project legacy task is updated in place'

  $script:taskIntervals = @{ 'Rulesync Project Auto Sync' = 15 }
  $script:taskErrors = @{ 'Shirube Project Auto Sync' = [System.Management.Automation.ErrorRecord]::new(
      [System.Exception]::new('Access is denied.'), 'TaskLookupDenied,Get-ScheduledTask',
      [System.Management.Automation.ErrorCategory]::PermissionDenied, 'Shirube Project Auto Sync') }
  $script:taskCalls = @()
  $deniedProject = $false
  try { Get-MgmtProjectInterval | Out-Null } catch { $deniedProject = $_.Exception.Message.Contains('Access is denied') }
  Assert $deniedProject 'R3 project access-denied lookup propagates the original error'
  Assert (-not (@($script:taskCalls) -contains 'Rulesync Project Auto Sync')) 'R3 project access-denied lookup never falls back to legacy'
  $script:taskErrors = @{}
  $script:taskIntervals = @{ 'Rulesync Project Auto Sync' = 15; 'Shirube Project Auto Sync' = 25 }
  $script:setCalls = @()
  Assert ((Get-MgmtProjectInterval) -eq 25) 'R3 new project task wins when both exist'
  Set-MgmtProjectInterval 'Shirube Project Auto Sync' 35 | Out-Null
  Assert ((@($script:setCalls).Count -eq 1) -and ([string]$script:setCalls[0] -ceq 'Shirube Project Auto Sync')) 'R3 new project task is updated when both exist'
  $gGuard = $true
  try { Set-MgmtProjectInterval 'Shirube Global Auto Sync' 30; $gGuard = $false } catch { $gGuard = ($_.Exception.Message.Contains('Project')) }
  Assert $gGuard 'R3 global task is still refused by the project interval setter'
  Set-TestSettings '{"taskNameGlobal":"Custom Global Task","taskNameProject":"Custom Project Task"}'
  $script:taskIntervals = @{ 'Rulesync Project Auto Sync' = 15; 'Shirube Project Auto Sync' = 25 }
  $customThrew = $false
  try { Get-MgmtProjectInterval | Out-Null } catch { $customThrew = $true }
  Assert $customThrew 'R3 custom project name never falls back to legacy'
  $script:taskIntervals = @{ 'Custom Project Task' = 10 }
  Assert ((Get-MgmtProjectInterval) -eq 10) 'R3 custom project name is used as configured'
  $script:taskIntervals = @{ 'Rulesync Global Auto Sync' = 15; 'Shirube Global Auto Sync' = 25 }
  $customGlobalThrew = $false
  try { Get-GlobalInterval | Out-Null } catch { $customGlobalThrew = $true }
  Assert $customGlobalThrew 'R3 custom global name never falls back to Shirube or legacy'
  $script:taskIntervals = @{ 'Custom Global Task' = 10 }
  Assert ((Get-GlobalInterval) -eq 10) 'R3 custom global name is used as configured'

  # R4: Verify-Dashboard defaults to Shirube but keeps a safe legacy path fallback.
  . (Join-Path $devAuto 'Verify-Dashboard.ps1')
  $lad = Join-Path $scratch 'lad'
  $newAuto = Join-Path $lad 'Shirube\.automation'
  $oldAuto = Join-Path $lad 'Rulesync\.automation'
  New-Item -ItemType Directory -Force -Path $newAuto, $oldAuto | Out-Null
  $env:LOCALAPPDATA = $lad
  Assert ((Get-DefaultAutoDir) -ceq $newAuto) 'R4 Shirube AppData path is preferred when both exist'
  Remove-Item -LiteralPath (Join-Path $lad 'Shirube') -Recurse -Force
  Assert ((Get-DefaultAutoDir) -ceq $oldAuto) 'R4 legacy AppData path is used only when Shirube is absent'
  Remove-Item -LiteralPath (Join-Path $lad 'Rulesync') -Recurse -Force
  Assert ((Get-DefaultAutoDir) -ceq $newAuto) 'R4 Shirube AppData path remains the default for a fresh install'

  # R5: launcher filename and AppData target follow the rename.
  $batNew = Join-Path $devRoot 'Shirube-Manager.bat'
  $batOld = Join-Path $devRoot 'Rulesync-Manager.bat'
  Assert ((Test-Path -LiteralPath $batNew -PathType Leaf) -and (-not (Test-Path -LiteralPath $batOld))) 'R5 launcher is renamed to Shirube-Manager.bat'
  foreach ($bp in @($batNew, (Join-Path $devRoot ([string][char]0x7BA1 + [char]0x7406 + '.bat')))) {
    $bt = Get-Content -LiteralPath $bp -Raw -Encoding UTF8
    Assert (($bt.Contains('%LOCALAPPDATA%\Shirube\.automation')) -and (-not $bt.Contains('%LOCALAPPDATA%\Rulesync\.automation'))) ('R5 launcher targets Shirube AppData: ' + (Split-Path $bp -Leaf))
  }

  # R6: README keeps a migration path that preserves user data and previews.
  $readme = Get-Content -LiteralPath (Join-Path $devRoot 'README.md') -Raw -Encoding UTF8
  Assert (($readme.Contains('%LOCALAPPDATA%\Rulesync')) -and ($readme.Contains('%LOCALAPPDATA%\Shirube'))) 'R6 README documents both old and new AppData paths'
  Assert (($readme.Contains('projects.json')) -and ($readme.Contains('global-preview')) -and ($readme.Contains('project-common-preview'))) 'R6 README preserves registry and preview configuration in migration'
  Assert (($readme.Contains('実際のタスク名')) -and ($readme.Contains('有効/無効状態を記録'))) 'R6 README identifies the configured task names and records their state before stopping'
  Assert ($readme.Contains('元が有効なら有効化')) 'R6 README restores the recorded task state after verification'
  Assert (($readme.Contains('.automation\*.ps1') -and $readme.Contains('%LOCALAPPDATA%\Shirube\.automation') -and $readme.Contains('`管理.bat` と `Shirube-Manager.bat` は `%LOCALAPPDATA%\Shirube`'))) 'R6 README places scripts under .automation and both launchers at the Shirube root'
} finally {
  $env:LOCALAPPDATA = $origLocal
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Set-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $scratch) {
    if (-not $scratch.StartsWith($testBase, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}
if ($failures.Count -gt 0) {
  Write-Host ('FAILURES: ' + ($failures -join '; '))
  exit 1
}
Write-Host 'ALL REBRAND MIGRATION CHECKS PASSED'
exit 0
