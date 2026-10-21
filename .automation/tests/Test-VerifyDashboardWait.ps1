# Test-VerifyDashboardWait.ps1 - regression tests for Verify-Dashboard.ps1 Wait branch.
$ErrorActionPreference = 'Stop'
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot
$vfyPath = Join-Path $devAuto 'Verify-Dashboard.ps1'

# Scenario A: missing server -> timeout -> 1
. $vfyPath
$script:now = [datetime]::new(2020,1,1,0,0,0)
function Get-Date { return $script:now }
function Start-Sleep { param($Milliseconds) if ($Milliseconds -gt 0) { $script:now = $script:now.AddMilliseconds($Milliseconds) } }
function Invoke-WebRequest { param($Uri, [int]$TimeoutSec, [switch]$UseBasicParsing) throw 'no server' }
function Test-VerifyOnce { return 0 }
$rcA = Wait-Verify -AutoDir 'C:\dummy\auto' -Port 18799 -WaitSec 1 -PollMs 250
Assert ($rcA -eq 1) 'Wait missing-server: timeout exit 1'

# Scenario B: late ready -> timeout -> 1
. $vfyPath
$script:now = [datetime]::new(2020,1,1,0,0,0)
$script:readyAt = $script:now.AddSeconds(2)
function Get-Date { return $script:now }
function Start-Sleep { param($Milliseconds) if ($Milliseconds -gt 0) { $script:now = $script:now.AddMilliseconds($Milliseconds) } }
function Invoke-WebRequest { param($Uri, [int]$TimeoutSec, [switch]$UseBasicParsing) if ($script:now -ge $script:readyAt) { $r = New-Object PSObject; $r | Add-Member -NotePropertyName StatusCode -NotePropertyValue 200; return $r } else { throw 'not ready' } }
function Test-VerifyOnce { return 0 }
$rcB = Wait-Verify -AutoDir 'C:\dummy\auto' -Port 18799 -WaitSec 1 -PollMs 250
Assert ($rcB -eq 1) 'Wait late-ready: timeout exit 1'

# Scenario C: deadline-crossing verify -> 1
. $vfyPath
$script:now = [datetime]::new(2020,1,1,0,0,0)
function Get-Date { return $script:now }
function Start-Sleep { param($Milliseconds) if ($Milliseconds -gt 0) { $script:now = $script:now.AddMilliseconds($Milliseconds) } }
function Invoke-WebRequest { param($Uri, [int]$TimeoutSec, [switch]$UseBasicParsing) $r = New-Object PSObject; $r | Add-Member -NotePropertyName StatusCode -NotePropertyValue 200; return $r }
function Test-VerifyOnce { $script:now = $script:now.AddSeconds(5); return 0 }
$rcC = Wait-Verify -AutoDir 'C:\dummy\auto' -Port 18799 -WaitSec 1 -PollMs 250
Assert ($rcC -eq 1) 'Wait deadline-crossing verify: exit 1'

# Scenario D: success in time -> 0
. $vfyPath
$script:now = [datetime]::new(2020,1,1,0,0,0)
function Get-Date { return $script:now }
function Start-Sleep { param($Milliseconds) if ($Milliseconds -gt 0) { $script:now = $script:now.AddMilliseconds($Milliseconds) } }
function Invoke-WebRequest { param($Uri, [int]$TimeoutSec, [switch]$UseBasicParsing) $r = New-Object PSObject; $r | Add-Member -NotePropertyName StatusCode -NotePropertyValue 200; return $r }
function Test-VerifyOnce { return 0 }
$rcD = Wait-Verify -AutoDir 'C:\dummy\auto' -Port 18799 -WaitSec 1 -PollMs 250
Assert ($rcD -eq 0) 'Wait success in time: exit 0'

if ($failures.Count -gt 0) {
  Write-Host ("FAILURES: " + ($failures -join ', '))
  exit 1
}
Write-Host 'ALL WAIT TESTS PASSED'
exit 0