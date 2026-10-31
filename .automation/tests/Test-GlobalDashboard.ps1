# Test-GlobalDashboard.ps1 - isolated self-checks for Global dashboard routes + UI.
# Scratch-only server on a scratch port with stub sync. Never touches real home,
# real tasks, or deployed AppData. Live scheduler writes are never tested.
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
$origHomeDir = $env:HOME_DIR
$devAuto = Split-Path -Parent $PSScriptRoot
try {
  . (Join-Path $devAuto 'Dashboard-Server.ps1')
  . (Join-Path $devAuto 'Global-Management.ps1')
  Assert ((Get-Command Start-HiddenGlobalSync -ErrorAction SilentlyContinue) -ne $null) 'D0 global sync entry dot-sourced (no listen)'

  $srvTxt = Get-Content -LiteralPath (Join-Path $devAuto 'Dashboard-Server.ps1') -Raw
  Assert ($srvTxt.Contains('Global-Management.ps1')) 'D0 dashboard dot-sources global module'
  foreach ($ep in @('/api/global-status', '/api/global-content', '/api/global-sync', '/api/global-preview-start', '/api/global-plan', '/api/global-targets-get', '/api/global-targets-set', '/api/global-interval-get', '/api/global-interval-set', '/api/global-enabled-get', '/api/global-enabled-set', '/api/global-logs', '/api/global-backups', '/api/global-backup-diff', '/api/global-restore')) {
    Assert ($srvTxt.Contains($ep)) ("D1 route present: " + $ep)
  }
  Assert (([regex]::Matches($srvTxt, 'alert\(')).Count -eq 0) 'D1 native alert still zero'
  Assert (([regex]::Matches($srvTxt, '(?<![A-Za-z0-9_$])confirm\(')).Count -eq 0) 'D1 native confirm still zero'
  Assert ($srvTxt.Contains('id="tblGlobal"')) 'D1 Global table in served page'
  Assert ($srvTxt.Contains('"global"') -and ($srvTxt.Contains('"gsettings"'))) 'D1 Global sections in scroll spy'
  Assert (($srvTxt.Contains('showConfirm') -and ($srvTxt.Contains('showModal')))) 'D1 modal helpers reused for Global'
  Assert ($srvTxt.Contains('Start-HiddenGlobalSync')) 'D1 hidden global launch (never blocks listener)'
  Assert ((-not ($srvTxt.Contains('WaitForExit'))) -or ($srvTxt.Contains('proc.WaitForExit'))) 'D1 listener never waits on sync child'

  try {
    $pe = $null; $pt = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $devAuto 'Dashboard-Server.ps1'), [ref]$pt, [ref]$pe)
    Assert (($pe.Count -eq 0)) 'D0 dashboard PS syntax ok'
  } catch { Assert ($false) 'D0 PS syntax check ran' }

  # D0b: dashboard display redaction covers all github token prefixes (API status/plan/diff/log/content paths).
  $oauthD0 = @('ghp_FAKE0123456789AB', 'gho_FAKE0123456789AB', 'ghu_FAKE0123456789AB', 'ghs_FAKE0123456789AB', 'ghr_FAKE0123456789AB', 'github_pat_FAKE0123456789_AB')
  $oauthD0ok = $true
  foreach ($s in $oauthD0) {
    $rrD0 = Redact-Text ('leak ' + $s + ' end') 'dash-tok-D0b'
    if (($rrD0.Contains($s)) -or (-not ($rrD0.Contains('***')))) { $oauthD0ok = $false }
  }
  Assert ($oauthD0ok) 'D0b dashboard redacts all token prefixes'

  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalDashboardTest'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  $fakeHome = Join-Path $scratch 'home'
  New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
  $gprev = Join-Path $scratch 'global-preview'
  New-Item -ItemType Directory -Force -Path $gprev | Out-Null
  Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"example-org/team-rules":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'live-codex-content-D' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'live-opencode-content-D' -Encoding Ascii
  $logDir = Join-Path $auto 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  Set-Content -LiteralPath (Join-Path $logDir 'Sync-GlobalRules-20200103.log') "2020-01-03 00:00:00 OK: seed-log-marker-D`n" -Encoding UTF8
  $env:DASHBOARD_AUTODIR = $auto
  $env:DASHBOARD_PORT = '18798'
  $env:HOME_DIR = $fakeHome

  # Chain stub: Watch forwards the request file; the stub writes a canned plan and exits 0.
  Copy-Item -LiteralPath (Join-Path $devAuto 'Watch-GlobalSync.ps1') -Destination (Join-Path $auto 'Watch-GlobalSync.ps1') -Force
  Set-Content -LiteralPath (Join-Path $auto 'Run-GlobalRules.vbs') "' dummy launcher" -Encoding Ascii
  $stubSync = @'
param([switch]$ReportSkip, [string]$RequestPath = '', [switch]$PreviewOnly, [string]$PlanPath = '')
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stub-args.txt') ("RequestPath=" + [string]$RequestPath + "|PreviewOnly=" + [string]$PreviewOnly + "|PlanPath=" + [string]$PlanPath) -Encoding Ascii
function G-Hash([string]$F) { return (Get-FileHash -LiteralPath $F -Algorithm SHA256).Hash.ToLowerInvariant() }
if ($PreviewOnly -and ($PlanPath -ne '')) {
  $hb = $env:HOME_DIR
  $codexP = Join-Path $hb '.codex\AGENTS.md'
  $openP = Join-Path $hb '.config\opencode\AGENTS.md'
  $ents = @(
    @{ target = 'codexcli'; path = $codexP; currentHash = (G-Hash $codexP); generatedHash = 'g1'; generatedText = 'same-text'; currentText = 'same-text'; result = 'success'; error = '' },
    @{ target = 'opencode'; path = $openP; currentHash = (G-Hash $openP); generatedHash = 'g2'; generatedText = 'same-text'; currentText = 'same-text'; result = 'success'; error = '' }
  )
  $plan = @{ schemaVersion = 1; createdAt = 't'; sourceCommit = '0123456789abcdef0123456789abcdef01234567'; targets = @('codexcli', 'opencode'); entries = $ents }
  Set-Content -LiteralPath $PlanPath (ConvertTo-Json -InputObject $plan -Depth 8 -Compress) -Encoding Ascii
}
exit 0
'@
  Set-Content -LiteralPath (Join-Path $auto 'Sync-GlobalRules.ps1') $stubSync -Encoding Ascii

  $srv = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $devAuto 'Dashboard-Server.ps1') -WindowStyle Hidden -PassThru
  try {
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18798/health'
        if ($r.StatusCode -eq 200) { $ok = $true; break }
      } catch {}
      if ($srv.HasExited) { break }
    }
    Assert ($ok) 'D2 health responds on scratch port'
    if ($ok) {
      $tok = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $script:hdrs = @{ 'X-Dashboard-Token' = $tok }
      function Get([string]$Ep) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers $script:hdrs -Uri ('http://127.0.0.1:18798' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      function Post([string]$Ep, $Body) {
        $wr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Method POST -Headers $script:hdrs -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress) -Uri ('http://127.0.0.1:18798' + $Ep)
        return ($wr.Content | ConvertFrom-Json)
      }
      # D3 targets roundtrip (stored selection)
      $tg0 = Get '/api/global-targets-get'
      Assert ((@($tg0.targets).Count -eq 2)) 'D3 default targets both'
      $avail0 = @($tg0.available)
      Assert (($avail0.Count -ge 19) -and (@($avail0 | Where-Object { [string]$_.id -ceq 'pi' }).Count -eq 1) -and (@($avail0 | Where-Object { [string]$_.id -ceq 'grokcli' }).Count -eq 1) -and (@($avail0 | Where-Object { [string]$_.id -ceq 'zed' }).Count -eq 1)) 'D3 available catalog includes new providers'
      $tg1 = Post '/api/global-targets-set' @{ targets = @('codexcli'); confirm = $true }
      Assert (($tg1.ok -eq $true) -and (@($tg1.targets).Count -eq 1)) 'D3 single target saved'
      Assert ((@( (Get '/api/global-targets-get').targets ).Count -eq 1)) 'D3 saved selection persists'
      $tgBad = $true; $tgCode = 0
      try { Post '/api/global-targets-set' @{ targets = @('evil'); confirm = $true } | Out-Null; $tgBad = $false } catch { $tgCode = $_.Exception.Response.StatusCode.value__ }
      Assert (($tgBad -and ($tgCode -eq 400))) 'D3 arbitrary targets are 400'
      $tgCase = $true; $tgCaseCode = 0
      try { Post '/api/global-targets-set' @{ targets = @('Pi'); confirm = $true } | Out-Null; $tgCase = $false } catch { $tgCaseCode = $_.Exception.Response.StatusCode.value__ }
      Assert (($tgCase -and ($tgCaseCode -eq 400))) 'D3 provider ids are case-sensitive'
      $tgNc = $true
      try { Post '/api/global-targets-set' @{ targets = @('codexcli') } | Out-Null; $tgNc = $false } catch { $tgNc = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($tgNc) 'D3 targets-set without confirm is 400'
      Post '/api/global-targets-set' @{ targets = @('pi'); confirm = $true } | Out-Null
      $gsPi = Get '/api/global-status'
      $rowPi = @($gsPi.providers)
      Assert ((@($rowPi).Count -eq 1) -and ([string]$rowPi[0].target -ceq 'pi') -and ((([string]$rowPi[0].path).EndsWith('.pi\agent\AGENTS.md')))) 'D3 status rows follow new provider selection'
      Post '/api/global-targets-set' @{ targets = @('codexcli', 'opencode'); confirm = $true } | Out-Null
      # D4 content: actual current bytes + confirmed paths, no config content
      $gc = Get '/api/global-content'
      Assert ((@($gc.files).Count -eq 2)) 'D4 two provider files'
      $cx = @($gc.files | Where-Object { [string]$_.target -ceq 'codexcli' })
      Assert ((([string]$cx[0].path).EndsWith('.codex\AGENTS.md') -and ([string]$cx[0].head).Contains('live-codex-content-D'))) 'D4 actual content with confirmed path'
      Assert ((-not (($gc | ConvertTo-Json -Depth 5 -Compress).Contains('opencode.jsonc')))) 'D4 config filename never a content path'
      # D5 status: distinct Global rows, unknown before structured results
      $gs = Get '/api/global-status'
      Assert ((@($gs.providers).Count -eq 2)) 'D5 two provider rows'
      Assert ((@($gs.providers | Where-Object { [string]$_.result -ceq 'unknown' }).Count -eq 2)) 'D5 unknown before structured status (no inference)'
      # D6 logs: seeded marker, bounded
      $gl = Get '/api/global-logs'
      Assert (([string]$gl.tail).Contains('seed-log-marker-D')) 'D6 global log tail served'
      # D7 hidden sync full chain: started with runID -> runID-bound success
      $sy = Post '/api/global-sync' @{}
      Assert (([string]$sy.sync -ceq 'started') -and ([string]$sy.syncId -match '^[0-9a-f]{32}$')) 'D7 hidden sync starts with runID'
      $syDone = $false
      for ($si = 0; $si -lt 20; $si++) {
        Start-Sleep -Milliseconds 1000
        try {
          $stW = Get ('/api/global-status?runId=' + [string]$sy.syncId)
          if (([string]$stW.syncId -ceq [string]$sy.syncId) -and ([string]$stW.syncState -ceq 'success')) { $syDone = $true; break }
        } catch {}
      }
      Assert ($syDone) 'D7 hidden sync completes as runID-bound success'
      # D8 preview chain: start -> ready plan -> plan-bound sync
      $pv = Post '/api/global-preview-start' @{}
      Assert (([string]$pv.planId -match '^[0-9a-f]{32}$')) 'D8 preview start returns planId'
      $ready = $null
      for ($pi = 0; $pi -lt 20; $pi++) {
        Start-Sleep -Milliseconds 1000
        try {
          $plW = Get ('/api/global-plan?id=' + [string]$pv.planId)
          if ([string]$plW.status -ceq 'ready') { $ready = $plW; break }
        } catch {}
      }
      Assert (($null -ne $ready) -and (@($ready.entries).Count -eq 2)) 'D8 plan ready carries both targets'
      $sy2 = Post '/api/global-sync' @{ planId = [string]$pv.planId }
      Assert ([string]$sy2.sync -ceq 'started') 'D8 plan-bound sync starts'
      $plBad = $true
      try { Get '/api/global-plan?id=bad' | Out-Null; $plBad = $false } catch { $plBad = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($plBad) 'D8 bad plan id is 400'
      # D9 validation-only guards (no scheduler writes)
      $ivBad = $true; $ivCode = 0
      try { Post '/api/global-interval-set' @{ minutes = 3; confirm = $true } | Out-Null; $ivBad = $false } catch { $ivCode = $_.Exception.Response.StatusCode.value__ }
      Assert (($ivBad -and ($ivCode -eq 400))) 'D9 out-of-range interval is 400 (no scheduler write)'
      $enBad = $true
      try { Post '/api/global-enabled-set' @{} | Out-Null; $enBad = $false } catch { $enBad = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($enBad) 'D9 enabled-set without field is 400'
      $rsNc = $true
      try { Post '/api/global-restore' @{ backupId = 'x' } | Out-Null; $rsNc = $false } catch { $rsNc = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($rsNc) 'D9 restore without confirm is 400'
      $bdBad = $true
      try { Post '/api/global-backup-diff' @{ backupId = 'bad id!' } | Out-Null; $bdBad = $false } catch { $bdBad = ($_.Exception.Response.StatusCode.value__ -eq 400) }
      Assert ($bdBad) 'D9 bad backup id is 400'
      # D10 busy pre-check holds the real global lock
      $lkSock = [System.IO.File]::Open((Join-Path $auto 'Sync-GlobalRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
      try {
        $busyOk = $true; $busyCode = 0
        try { Post '/api/global-sync' @{} | Out-Null; $busyOk = $false } catch { $busyCode = $_.Exception.Response.StatusCode.value__ }
        Assert (($busyOk -and ($busyCode -eq 409))) 'D10 busy global sync is 409'
      } finally { $lkSock.Close() }
      # D11 auth + method guards on new routes
      $fbd = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Headers @{ 'X-Dashboard-Token' = 'wrong' } 'http://127.0.0.1:18798/api/global-status' | Out-Null; $fbd = $false } catch { $fbd = ($_.Exception.Response.StatusCode.value__ -eq 403) }
      Assert ($fbd) 'D11 wrong token is 403'
      $m405 = $true
      try { Get '/api/global-sync' | Out-Null; $m405 = $false } catch { $m405 = ($_.Exception.Response.StatusCode.value__ -eq 405) }
      Assert ($m405) 'D11 GET on POST route is 405'
      # D12 served page: Global UI present, modal-only dialogs, JS parses
      $page = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 ("http://127.0.0.1:18798/?token=" + $tok)
      Assert (($page.Content.Contains('id="tblGlobal"') -and ($page.Content.Contains('id="btnGlobalSync')))) 'D12 served page has Global UI'
      $d12ok = ($page.Content.Contains('id="globalTargetsList"') -and $page.Content.Contains('id="btnSyncGlobalOnly"') -and $page.Content.Contains('id="btnSyncProjectOnly"') -and (-not $page.Content.Contains('id="ckTCodex"')))
      Assert $d12ok 'D12 provider choices and scope buttons are catalog-driven'
      Assert ((-not ($page.Content.Contains('__GLOBAL_CATALOG__'))) -and ($page.Content.Contains('"label":"Pi"'))) 'D12 catalog JSON injected into served page'
      try {
        $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $nodeExe) { $nodeExe = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
        if ($nodeExe) {
          $m = [regex]::Match($page.Content, '(?s)<script>(.*)</script>')
          if ($m.Success) {
            $jsTmp = Join-Path $scratch 'global-page-check.js'
            Set-Content -LiteralPath $jsTmp $m.Groups[1].Value -Encoding UTF8
            & $nodeExe --check $jsTmp
            Assert ($LASTEXITCODE -eq 0) 'D12 served JS parses (node --check)'
          } else { Assert ($false) 'D12 script block found' }
        } else { Assert ($true) 'D12 node missing skips parse check' }
      } catch { Assert ($false) 'D12 served JS parse check ran' }
    }
  } finally {
    try { if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force } } catch {}
  }

  Assert (((Get-Location).Path) -eq $initCwd) 'D13 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'D13 only own scratch removed'
  Assert (Test-Path -LiteralPath $base) 'D13 base left intact'
}
finally {
  $env:DASHBOARD_AUTODIR = $origAuto
  if ($null -eq $origAuto) { Remove-Item Env:DASHBOARD_AUTODIR -ErrorAction SilentlyContinue }
  $env:DASHBOARD_PORT = $origPort
  if ($null -eq $origPort) { Remove-Item Env:DASHBOARD_PORT -ErrorAction SilentlyContinue }
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL GLOBAL DASHBOARD CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
