# Self-check for Watch-GlobalSync.ps1 (hidden monitor for dashboard global sync).
# Scratch-only with a stub Sync-GlobalRules.ps1. Never touches real tasks/home.
$ErrorActionPreference = 'Stop'
$origExit = $env:WATCH_STUB_EXIT
$origMarker = $env:WATCH_STUB_MARKER
$initCwd = (Get-Location).Path
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Get-Full([string]$P) { return [System.IO.Path]::GetFullPath($P) }
function Test-Contained([string]$Candidate, [string]$Root) {
  $c = Get-Full $Candidate; $r = Get-Full $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}
try {
  $dev = Join-Path (Split-Path -Parent $PSScriptRoot) 'Watch-GlobalSync.ps1'
  Assert (Test-Path -LiteralPath $dev -PathType Leaf) 'W0 Watch-GlobalSync exists'
  $text = Get-Content -LiteralPath $dev -Raw
  Assert (($text.Contains('Sync-GlobalRules.ps1')) -and ($text.Contains('-ReportSkip'))) 'W0 runs fixed global sync with ReportSkip'
  Assert (($text.Contains('dashboard.global-sync-')) -and ($text -notmatch '[A-Za-z]:\\')) 'W0 global result filename, no hardcoded dev path'
  Assert ((-not ($text.Contains("'powershell.exe'")))) 'W0 no bare powershell fallback'

  $testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'WatchGlobalSyncTest'
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $scratch = Join-Path $testBase ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  New-Item -ItemType Directory -Force -Path $auto | Out-Null
  Assert (Test-Contained $scratch $testBase) 'W0 GUID scratch contained in base'
  Copy-Item -LiteralPath $dev -Destination (Join-Path $auto 'Watch-GlobalSync.ps1') -Force
  Set-Content -LiteralPath (Join-Path $auto 'Sync-GlobalRules.ps1') @'
param([switch]$ReportSkip, [string]$RequestPath = '', [switch]$PreviewOnly, [string]$PlanPath = '')
$ErrorActionPreference = 'Stop'
$m = $env:WATCH_STUB_MARKER
if ($m) { Set-Content -LiteralPath $m ("ReportSkip=" + [string]$ReportSkip + "|RequestPath=" + [string]$RequestPath + "|PreviewOnly=" + [string]$PreviewOnly + "|PlanPath=" + [string]$PlanPath) -Encoding Ascii }
exit ([int]$env:WATCH_STUB_EXIT)
'@ -Encoding Ascii
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $runId = [System.Guid]::NewGuid().ToString('N')
  $marker = Join-Path $scratch 'marker.txt'

  function Read-Result([string]$Id) {
    $p = Join-Path $script:auto ("dashboard.global-sync-" + $Id + ".json")
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding Ascii | ConvertFrom-Json)
  }

  # W1: stub exit 0 -> success result bound to run id, request passed through.
  $env:WATCH_STUB_EXIT = '0'
  $env:WATCH_STUB_MARKER = $marker
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  $reqFile = Join-Path $auto ("dashboard.global-request-" + $runId + ".json")
  Set-Content -LiteralPath $reqFile '{"targetNames":[]}' -Encoding Ascii
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $auto 'Watch-GlobalSync.ps1') -AutoDir $auto -RunId $runId -RequestPath $reqFile
  Assert ($LASTEXITCODE -eq 0) 'W1 watch exits 0 on stub success'
  $r1 = Read-Result $runId
  Assert (($null -ne $r1) -and ([string]$r1.runId -ceq $runId) -and ([int]$r1.exitCode -eq 0) -and ([string]$r1.result -ceq 'success')) 'W1 runID-bound success result'
  Assert (((Get-Content -LiteralPath $marker -Raw).Contains($reqFile))) 'W1 request path passed to sync'
  $acl1 = Get-Acl -LiteralPath (Join-Path $auto ("dashboard.global-sync-" + $runId + ".json"))
  Assert (($acl1.AreAccessRulesProtected) -eq $true) 'W1 result file privately ACLed'

  # W2: stub exit 75 -> skipped (never success).
  $runId2 = [System.Guid]::NewGuid().ToString('N')
  $env:WATCH_STUB_EXIT = '75'
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $auto 'Watch-GlobalSync.ps1') -AutoDir $auto -RunId $runId2
  $r2 = Read-Result $runId2
  Assert (([string]$r2.result -ceq 'skipped') -and ([int]$r2.exitCode -eq 75)) 'W2 exit 75 recorded as skipped'

  # W3: stub exit 1 -> failed.
  $runId3 = [System.Guid]::NewGuid().ToString('N')
  $env:WATCH_STUB_EXIT = '1'
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $auto 'Watch-GlobalSync.ps1') -AutoDir $auto -RunId $runId3
  $r3 = Read-Result $runId3
  Assert ([string]$r3.result -ceq 'failed') 'W3 exit 1 recorded as failed'

  # W4: bad run id refused, no result file.
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $auto 'Watch-GlobalSync.ps1') -AutoDir $auto -RunId 'bad-id'
  Assert ($LASTEXITCODE -eq 2) 'W4 bad run id exits 2'

  # W5: request outside auto refused.
  $runId5 = [System.Guid]::NewGuid().ToString('N')
  $outside = Join-Path $scratch 'outside.json'
  Set-Content -LiteralPath $outside '{}' -Encoding Ascii
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $auto 'Watch-GlobalSync.ps1') -AutoDir $auto -RunId $runId5 -RequestPath $outside
  Assert ($LASTEXITCODE -eq 2) 'W5 outside request exits 2'
  Assert ($null -eq (Read-Result $runId5)) 'W5 no result on refused request'

  # W7: preview request runs sync with -PreviewOnly and the plan path.
  $runId7 = [System.Guid]::NewGuid().ToString('N')
  $planId7 = [System.Guid]::NewGuid().ToString('N')
  $env:WATCH_STUB_EXIT = '0'
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  $reqPrev = Join-Path $auto ("dashboard.global-request-" + $runId7 + ".json")
  Set-Content -LiteralPath $reqPrev ('{"targetNames":[],"previewOnly":true,"planPath":"","planId":"' + $planId7 + '"}') -Encoding Ascii
  & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $auto 'Watch-GlobalSync.ps1') -AutoDir $auto -RunId $runId7 -RequestPath $reqPrev
  Assert ($LASTEXITCODE -eq 0) 'W7 preview watch exits 0'
  $mk7 = Get-Content -LiteralPath $marker -Raw
  Assert ((($mk7.Contains('PreviewOnly=True')) -and ($mk7.Contains("dashboard.global-plan-" + $planId7 + ".json")))) 'W7 preview args passed to sync'
  $r7 = Read-Result $runId7
  Assert ([string]$r7.result -ceq 'success') 'W7 preview run records result'

  Assert (((Get-Location).Path) -eq $initCwd) 'W6 cwd unchanged'
  Assert (Test-Path -LiteralPath $scratch) 'W6 scratch exists before cleanup'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'W6 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $testBase) 'W6 base dir left intact'
}
finally {
  $env:WATCH_STUB_EXIT = $origExit
  if ($null -eq $origExit) { Remove-Item Env:WATCH_STUB_EXIT -ErrorAction SilentlyContinue }
  $env:WATCH_STUB_MARKER = $origMarker
  if ($null -eq $origMarker) { Remove-Item Env:WATCH_STUB_MARKER -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL WATCH GLOBAL CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
