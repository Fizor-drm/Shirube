# Self-check for Run-GlobalRules.vbs (hidden launcher). Scratch-only, harmless stub.
# Never touches the real Sync-GlobalRules.ps1, home, task, or deployed files.
$ErrorActionPreference = 'Stop'

$origExit = $env:LAUNCHER_STUB_EXIT
$origMarker = $env:LAUNCHER_STUB_MARKER
$origSleep = $env:LAUNCHER_STUB_SLEEP
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
function Invoke-Launcher([string]$Vbs, [switch]$NoWait) {
  # One pre-quoted argument string: Start-Process joins ArgumentList with spaces
  # without quoting, so a path containing spaces must carry its own quotes.
  if ($NoWait) {
    return (Start-Process -FilePath 'C:\Windows\System32\wscript.exe' -ArgumentList ('//B //Nologo "{0}"' -f $Vbs) -WindowStyle Hidden -PassThru)
  }
  return (Start-Process -FilePath 'C:\Windows\System32\wscript.exe' -ArgumentList ('//B //Nologo "{0}"' -f $Vbs) -WindowStyle Hidden -Wait -PassThru)
}

try {
  $devAuto = Split-Path -Parent $PSScriptRoot
  $dev = Join-Path $devAuto 'Run-GlobalRules.vbs'
  $text = Get-Content -LiteralPath $dev -Raw
  Assert ($text.Contains('Option Explicit')) 'S1 Option Explicit'
  Assert (($text.Contains('CreateObject("WScript.Shell")')) -and ($text.Contains('.Run('))) 'S2 Shell.Run used'
  Assert ($text.Contains(', 0, True)')) 'S3 hidden(0)+wait(True)'
  Assert ($text.Contains('WScript.Quit')) 'S4 exit code returned via Quit'
  Assert ($text.Contains('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')) 'S5 absolute System32 powershell'
  Assert (($text.Contains('-NoProfile')) -and ($text.Contains('-NonInteractive')) -and ($text.Contains('-WindowStyle Hidden')) -and ($text.Contains('-ExecutionPolicy Bypass')) -and ($text.Contains('-File'))) 'S6 original flags kept'
  Assert (($text.Contains('ScriptFullName')) -and ($text.Contains('GetParentFolderName')) -and ($text.Contains('Sync-GlobalRules.ps1'))) 'S7 sibling PS via own directory'
  Assert ((-not $text.Contains('G:\')) -and (-not $text.Contains('AppData'))) 'S7b no hardcoded dev/deployed path'
  Assert (($text -notmatch '(?i)\bcmd\.exe\b') -and ($text -notmatch '(?i)\bcmd\s+/c') -and ($text -notmatch '(?i)comspec') -and ($text -notmatch '(?i)\bstart\b')) 'S8 no cmd/start hop'
  Assert (($text.Contains('"""C:\Windows')) -and ($text.Contains('""" & ps & """"'))) 'S9 exe+script paths quoted'

  $testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'RunGlobalRulesLauncherTest'
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $scratch = Join-Path $testBase ('run ' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  Assert (Test-Contained $scratch $testBase) 'L0 GUID scratch contained in base'

  $vbs = Join-Path $scratch 'Run-GlobalRules.vbs'
  $stub = Join-Path $scratch 'Sync-GlobalRules.ps1'
  Assert (Test-Contained $vbs $scratch) 'L0 vbs contained in scratch'
  Assert (Test-Contained $stub $scratch) 'L0 stub contained in scratch'
  Copy-Item -LiteralPath $dev -Destination $vbs -Force
  Set-Content -LiteralPath $stub @'
$ErrorActionPreference = 'Stop'
$s = $env:LAUNCHER_STUB_SLEEP
if ($s) { Start-Sleep -Seconds ([int]$s) }
$m = $env:LAUNCHER_STUB_MARKER
if ($m) { Set-Content -LiteralPath $m 'stub-ran' -Encoding Ascii }
exit ([int]$env:LAUNCHER_STUB_EXIT)
'@ -Encoding Ascii

  $marker = Join-Path $scratch 'marker.txt'
  Assert (Test-Contained $marker $scratch) 'L0 marker contained in scratch'

  # Case exit 0: stub writes marker, launcher waits and propagates 0.
  $env:LAUNCHER_STUB_EXIT = '0'
  $env:LAUNCHER_STUB_MARKER = $marker
  $env:LAUNCHER_STUB_SLEEP = $null
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  $p = Invoke-Launcher $vbs
  Assert ($p.ExitCode -eq 0) 'L1 exit 0 propagated'
  Assert (((Get-Content -LiteralPath $marker -Raw) -replace '\s', '') -eq 'stub-ran') 'L1 stub marker written (waited)'

  # Case exit 7: non-zero propagation.
  $env:LAUNCHER_STUB_EXIT = '7'
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  $p = Invoke-Launcher $vbs
  Assert ($p.ExitCode -eq 7) 'L2 exit 7 propagated'
  Assert (((Get-Content -LiteralPath $marker -Raw) -replace '\s', '') -eq 'stub-ran') 'L2 stub marker written (waited)'

  # Window observation: own scratch process only, while stub sleeps.
  $env:LAUNCHER_STUB_EXIT = '0'
  $env:LAUNCHER_STUB_SLEEP = '3'
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  $w = Invoke-Launcher $vbs -NoWait
  Start-Sleep -Milliseconds 800
  $w.Refresh()
  $h = 0
  try { $h = [long]$w.MainWindowHandle } catch { $h = -1 }
  Write-Host ('OBSERVE: MainWindowHandle=' + $h)
  Assert ($h -eq 0) 'L3 no visible window on own scratch process'
  $w.WaitForExit()
  Assert ($w.ExitCode -eq 0) 'L3 sleep-stub exit 0 after wait'
  Assert (Test-Path -LiteralPath $marker) 'L3 marker written after wait'

  Assert (((Get-Location).Path) -eq $initCwd) 'L4 cwd unchanged'
  Assert (Test-Path -LiteralPath $scratch) 'L4 scratch exists before cleanup'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'L4 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $testBase) 'L4 base dir left intact'
}
finally {
  $env:LAUNCHER_STUB_EXIT = $origExit
  if ($null -eq $origExit) { Remove-Item Env:LAUNCHER_STUB_EXIT -ErrorAction SilentlyContinue }
  $env:LAUNCHER_STUB_MARKER = $origMarker
  if ($null -eq $origMarker) { Remove-Item Env:LAUNCHER_STUB_MARKER -ErrorAction SilentlyContinue }
  $env:LAUNCHER_STUB_SLEEP = $origSleep
  if ($null -eq $origSleep) { Remove-Item Env:LAUNCHER_STUB_SLEEP -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL LAUNCHER CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
