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

# Scenario E: launch defaults, health-before-netstat and the single-call launcher.
$vTxt = Get-Content -LiteralPath $vfyPath -Raw -Encoding UTF8
Assert (($vTxt.Contains('[switch]$EnsureRunning')) -and ($vTxt.Contains('[string]$ServerScript'))) 'EnsureRunning and ServerScript parameters exist'
Assert ($vTxt.Contains('[int]$PollMs = 80')) 'default poll interval is 80ms'
$fnS = $vTxt.IndexOf('function Start-DashboardServer')
$fnSEnd = $vTxt.IndexOf('Set-Alias -Name Invoke-VerifyWait')
Assert (($fnS -ge 0) -and ($fnSEnd -gt $fnS)) 'Start-DashboardServer slice located'
$startTxt = $vTxt.Substring($fnS, $fnSEnd - $fnS)
Assert ($startTxt.Contains('"`"$Script`""')) 'server launch quotes a script path that contains spaces'
$fnStart = $vTxt.IndexOf('function Test-VerifyOnce')
$fnEnd = $vTxt.IndexOf('function Wait-Verify')
Assert (($fnStart -ge 0) -and ($fnEnd -gt $fnStart)) 'VerifyOnce slice located'
$fnTxt = $vTxt.Substring($fnStart, $fnEnd - $fnStart)
Assert (($fnTxt.IndexOf('/health') -ge 0) -and ($fnTxt.IndexOf('/health') -lt $fnTxt.IndexOf('netstat.exe'))) 'health is checked before netstat'
$emptyThrew = $false
try { Start-DashboardServer '' } catch { $emptyThrew = $true }
Assert $emptyThrew 'Start-DashboardServer refuses an empty path'
$missingThrew = $false
try { Start-DashboardServer (Join-Path $devAuto 'no-such-launcher.vbs') } catch { $missingThrew = $true }
Assert $missingThrew 'Start-DashboardServer refuses a missing script'
$devRoot = Split-Path -Parent $devAuto
foreach ($bn in @('Shirube-Manager.bat', ([string][char]0x7BA1 + [char]0x7406 + '.bat'))) {
  $bp = Join-Path $devRoot $bn
  Assert (Test-Path -LiteralPath $bp -PathType Leaf) ('launcher exists: ' + $bn)
  $bt = Get-Content -LiteralPath $bp -Raw -Encoding UTF8
  Assert (([regex]::Matches($bt, '"%PS%"')).Count -eq 1) ('one PowerShell startup: ' + $bn)
  Assert (($bt.Contains('-EnsureRunning')) -and ($bt.Contains('-ServerScript')) -and ($bt.Contains('-WaitSec 20'))) ('launcher delegates start and wait: ' + $bn)
  Assert ((-not $bt.Contains(':checkhealth')) -and (-not $bt.Contains(':start'))) ('old multi-step launch removed: ' + $bn)
}

if ($failures.Count -gt 0) {
  Write-Host ("FAILURES: " + ($failures -join ', '))
  exit 1
}
Write-Host 'ALL WAIT TESTS PASSED'
exit 0