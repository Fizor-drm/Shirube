# Verify-Dashboard.ps1 - bat helper: prove 127.0.0.1:PORT owner is our AutoDir dashboard before token use.
# No new deps: PS5.1 + netstat + Invoke-WebRequest only. Exit 0=verified, 1=mismatch.
# r4: HttpListener uses HTTP.sys, so LISTENING owner is PID 4 (System), not the server PID.
# Do not compare every netstat line (client ESTABLISHED lines are foreign PIDs by design).
# Instead: LISTENING must exist with PID 4 or our PID; health instance nonce (unpredictable
# GUID in state) must match. Session token is never sent here.
# Optional cold-start wait: -WaitSec > 0 polls in-process (no repeated PS startup).
param([string]$AutoDir = '', [int]$Port = 18721, [int]$WaitSec = 0, [int]$PollMs = 250)
$ErrorActionPreference = 'Stop'

function Test-VerifyOnce {
  try {
    if (-not $AutoDir) { $script:_ad = Join-Path $env:LOCALAPPDATA 'Rulesync\.automation' } else { $script:_ad = $AutoDir }
    $ad = $script:_ad
    $sf = Join-Path $ad 'dashboard.state.json'
    if (-not (Test-Path -LiteralPath $sf)) { Write-Host 'NG: state missing'; return 1 }
    $st = Get-Content -LiteralPath $sf -Raw -Encoding Ascii | ConvertFrom-Json
    if ([int]$st.port -ne [int]$Port) { Write-Host 'NG: port mismatch'; return 1 }
    if ([string]$st.instance -notmatch '^[0-9a-f]{32}-[0-9]+$') { Write-Host 'NG: instance format'; return 1 }
    $spid = [int]$st.pid
    try { $normAuto = [System.IO.Path]::GetFullPath($ad) } catch { Write-Host 'NG: autodir'; return 1 }
    try { $normSt = [System.IO.Path]::GetFullPath([string]$st.autodir) } catch { Write-Host 'NG: state autodir'; return 1 }
    if (-not $normAuto.Equals($normSt, [System.StringComparison]::OrdinalIgnoreCase)) { Write-Host 'NG: autodir mismatch'; return 1 }
    $proc = $null
    try { $proc = Get-Process -Id $spid -ErrorAction Stop } catch { Write-Host 'NG: pid not alive'; return 1 }
    if ($proc.Name -notmatch 'powershell') { Write-Host 'NG: owner not powershell'; return 1 }
    $pst = ''
    try { $pst = $proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { Write-Host 'NG: starttime'; return 1 }
    if ($pst -cne [string]$st.startTime) { Write-Host 'NG: pid reused (starttime mismatch)'; return 1 }
    $netstat = Join-Path $env:SystemRoot 'System32\netstat.exe'
    if (-not (Test-Path -LiteralPath $netstat)) { Write-Host 'NG: netstat absolute missing'; return 1 }
    $ns = & $netstat -ano -p TCP 2>$null | Out-String
    $foundListen = $false; $foreignListen = $false
    foreach ($ln in ($ns -split "`r?`n")) {
      if ($ln -notmatch 'LISTENING') { continue }
      if ($ln -match ':\s*' + $Port + '\b') {
        $m = [regex]::Match($ln, '(\d+)\s*$')
        if ($m.Success) {
          $o = [int]$m.Groups[1].Value
          if (($o -eq 4) -or ($o -eq $spid)) { $foundListen = $true } else { $foreignListen = $true }
        }
      }
    }
    if ($foreignListen) { Write-Host 'NG: foreign listener on port'; return 1 }
    if (-not $foundListen) { Write-Host 'NG: tcp listener missing'; return 1 }
    $h = $null
    try { $h = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 ("http://127.0.0.1:" + $Port + "/health") } catch { Write-Host 'NG: health unreachable'; return 1 }
    if ($h.StatusCode -ne 200) { Write-Host 'NG: health not 200'; return 1 }
    $hj = $h.Content | ConvertFrom-Json
    if (($hj.instance -cne [string]$st.instance) -or ([int]$hj.port -ne [int]$Port) -or ([int]$hj.pid -ne $spid)) { Write-Host 'NG: health identity mismatch'; return 1 }
    Write-Host 'OK: verified'
    return 0
  } catch { Write-Host ('NG: ' + $_.Exception.Message); return 1 }
}

function Wait-Verify {
  param([string]$AutoDir = '', [int]$Port = 18721, [int]$WaitSec = 0, [int]$PollMs = 250)
  if ($WaitSec -le 0) { return (Test-VerifyOnce) }
  if ($PollMs -le 0) { $PollMs = 250 }
  $deadline = (Get-Date).AddSeconds($WaitSec)
  $ad = if ($AutoDir) { $AutoDir } else { Join-Path $env:LOCALAPPDATA 'Rulesync\.automation' }
  # expose to Test-VerifyOnce (which reads script/caller scope)
  $script:AutoDir = $ad
  $script:Port = $Port
  $AutoDir = $ad
  $healthUrl = "http://127.0.0.1:$Port/health"
  while ($true) {
    $now = Get-Date
    if ($now -ge $deadline) { break }
    $remainingMs = [int](($deadline - $now).TotalMilliseconds)
    if ($remainingMs -le 0) { break }
    # bound HTTP timeout to remaining (at least 1s for Invoke-WebRequest)
    $httpTimeoutSec = 2
    if ($remainingMs -lt ($httpTimeoutSec * 1000)) {
      $httpTimeoutSec = [Math]::Max(1, [int][Math]::Ceiling($remainingMs / 1000.0))
    }
    $ok = $false
    try {
      $hr = Invoke-WebRequest -UseBasicParsing -TimeoutSec $httpTimeoutSec $healthUrl
      if ($hr.StatusCode -eq 200) { $ok = $true }
    } catch { $ok = $false }
    # before verification check
    $now2 = Get-Date
    if ($now2 -ge $deadline) { break }
    if ($ok) {
      $rc = Test-VerifyOnce
      # after verification check
      $now3 = Get-Date
      if ($now3 -ge $deadline) { break }
      if ($rc -eq 0) { return 0 }
    }
    $now4 = Get-Date
    if ($now4 -ge $deadline) { break }
    $sleepMs = [Math]::Min($PollMs, [int](($deadline - $now4).TotalMilliseconds))
    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
  }
  return 1
}

# aliases for test convenience
Set-Alias -Name Invoke-VerifyWait -Value Wait-Verify -Scope Script
Set-Alias -Name Test-VerifyWait -Value Wait-Verify -Scope Script

if ($MyInvocation.InvocationName -ne '.') {
  if ($WaitSec -le 0) {
    $rc = Test-VerifyOnce
    exit $rc
  }
  $rc = Wait-Verify -AutoDir $AutoDir -Port $Port -WaitSec $WaitSec -PollMs $PollMs
  exit $rc
}
