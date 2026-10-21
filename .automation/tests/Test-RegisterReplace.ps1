# Test-RegisterReplace.ps1 - isolated checks for force-replace register flow.
# Scratch-only. Never touches real registry, repos, tasks, or deployed AppData.
$ErrorActionPreference = 'Stop'
$initCwd = (Get-Location).Path
$failures = @()
$origAuto = $env:DASHBOARD_AUTODIR
$origPort = $env:DASHBOARD_PORT
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot
$srvPath = Join-Path $devAuto 'Dashboard-Server.ps1'
. $srvPath
$base = Join-Path ([System.IO.Path]::GetTempPath()) 'RegReplaceTest'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
$auto = Join-Path $scratch 'auto'
New-Item -ItemType Directory -Force -Path $auto | Out-Null
$curDir = Join-Path $scratch 'project-common-preview\.rulesync\rules\.curated'
New-Item -ItemType Directory -Force -Path $curDir | Out-Null
Set-Content -LiteralPath (Join-Path $curDir 'project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-body" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[]' -Encoding Ascii
$env:DASHBOARD_AUTODIR = $auto
$port = '18811'
$env:DASHBOARD_PORT = $port

# repo with existing AGENTS.md
$repoA = Join-Path $scratch 'AgentsRepo'
New-Item -ItemType Directory -Force -Path (Join-Path $repoA '.rulesync\rules') | Out-Null
$agentsContent = 'existing agents unique content 12345'
Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') $agentsContent -Encoding Ascii -NoNewline
# no project-local.md (hasLocal false) to avoid frontmatter edge cases

$tok = $null
$srv = $null
try {
  $srv = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$srvPath -WindowStyle Hidden -PassThru
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 ("http://127.0.0.1:$port/health"); if ($r.StatusCode -eq 200) { $ready = $true; break } } catch {}
    if ($srv.HasExited) { break }
  }
  Assert $ready 'server ready'
  $tok = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw).Trim()
  $hdrs = @{ 'X-Dashboard-Token' = $tok }

  # force off block: preview without forceReplace on repo with AGENTS -> 400
  $foOk = $true; $foCode = 0
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoA } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview" | Out-Null } catch { $foOk = $false; $foCode = $_.Exception.Response.StatusCode.value__ }
  Assert ((-not $foOk) -and ($foCode -eq 400)) 'force off: preview blocked (400)'

  # strict string false: forceReplace:"false" string -> treated false -> 400
  $ssOk = $true; $ssCode = 0
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoA; forceReplace = "false" } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview" | Out-Null } catch { $ssOk = $false; $ssCode = $_.Exception.Response.StatusCode.value__ }
  Assert ((-not $ssOk) -and ($ssCode -eq 400)) 'strict string false: treated as false (400)'

  # on permitted: preview with forceReplace:true -> 200
  $pvResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoA; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview"
  $pv = ($pvResp.Content | ConvertFrom-Json)
  Assert (($pvResp.StatusCode -eq 200) -and ($pv.ok -eq $true) -and ($pv.hasAgents -eq $true) -and ($pv.forceReplace -eq $true)) 'force on: preview permitted'

  # missing consent: register without forceReplace -> 400 consent
  $mcOk = $true; $mcCode = 0
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pv.path; previewId = $pv.previewId; confirm = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/register" | Out-Null } catch { $mcOk = $false; $mcCode = $_.Exception.Response.StatusCode.value__ }
  Assert ((-not $mcOk) -and ($mcCode -eq 400)) 'missing consent: register blocked (400)'

  # need fresh preview after invalidation? preview still valid (not consumed). Re-preview with force for consent test.
  $pv2Resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoA; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview"
  $pv2 = ($pv2Resp.Content | ConvertFrom-Json)

  # stale hash: modify AGENTS.md then register -> 400
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') 'changed after preview' -Encoding Ascii -NoNewline
  $stOk = $true; $stCode = 0
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pv2.path; previewId = $pv2.previewId; confirm = $true; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/register" | Out-Null } catch { $stOk = $false; $stCode = $_.Exception.Response.StatusCode.value__ }
  Assert ((-not $stOk) -and ($stCode -eq 400)) 'stale hash: register blocked (400)'
  Assert ((@(Get-Registry $auto)).Count -eq 0) 'stale hash: registry unchanged'

  # restore content for success test
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') $agentsContent -Encoding Ascii -NoNewline

  # success: preview + register with consent -> 200, backup exact bytes + manifest
  $pv3Resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoA; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview"
  $pv3 = ($pv3Resp.Content | ConvertFrom-Json)
  $rgResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pv3.path; previewId = $pv3.previewId; confirm = $true; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/register"
  $rg = ($rgResp.Content | ConvertFrom-Json)
  Assert (($rgResp.StatusCode -eq 200) -and ($rg.ok -eq $true)) 'success: register ok'
  Assert ((@(Get-Registry $auto)).Count -eq 1) 'success: registry has one'
  $backupDir = $rg.backup
  Assert ($backupDir -and (Test-Path -LiteralPath (Join-Path $backupDir 'AGENTS.md'))) 'success: backup AGENTS exists'
  $srcHash = (Get-FileHash -LiteralPath (Join-Path $repoA 'AGENTS.md') -Algorithm SHA256).Hash.ToLowerInvariant()
  # original remains (file still there)
  Assert (Test-Path -LiteralPath (Join-Path $repoA 'AGENTS.md')) 'success: original AGENTS remains'
  $backupHash = (Get-FileHash -LiteralPath (Join-Path $backupDir 'AGENTS.md') -Algorithm SHA256).Hash.ToLowerInvariant()
  Assert ($backupHash -eq $pv3.agentsHash.ToLowerInvariant()) 'success: backup hash equals consented preview hash'
  $mf = Get-Content -LiteralPath (Join-Path $backupDir 'manifest.json') -Raw | ConvertFrom-Json
  Assert ([string]$mf.agentsHash -eq $pv3.agentsHash) 'success: manifest agentsHash equals consented'
  Assert ([string]$mf.agentsHash -eq $backupHash) 'success: manifest agentsHash equals backup bytes'

  # lock busy: register returns 409 and registry unchanged
  $repoC = Join-Path $scratch 'LockRepo'
  New-Item -ItemType Directory -Force -Path $repoC | Out-Null
  $pvL = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoC } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview").Content | ConvertFrom-Json
  $held = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  $lkOk = $true; $lkCode = 0
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pvL.path; previewId = $pvL.previewId; confirm = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/register" | Out-Null } catch { $lkOk = $false; $lkCode = $_.Exception.Response.StatusCode.value__ }
  finally { $held.Close() }
  Assert ((-not $lkOk) -and ($lkCode -eq 409)) 'lockbusy: register 409'
  Assert ((@(Get-Registry $auto)).Count -eq 1) 'lockbusy: registry unchanged'

  # real backup failure: New-MgmtBackupDir fails when auto/backups is a regular file
  $repoE = Join-Path $scratch 'BackupFailRepo'
  New-Item -ItemType Directory -Force -Path (Join-Path $repoE '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoE 'AGENTS.md') 'existing agents for backup fail' -Encoding Ascii -NoNewline
  $pvE = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoE; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview").Content | ConvertFrom-Json
  $broot = Join-Path $auto 'backups'
  $brootSaved = Join-Path $auto 'backups.saved'
  if (Test-Path -LiteralPath $broot) { Rename-Item -LiteralPath $broot -NewName 'backups.saved' }
  Set-Content -LiteralPath $broot -Value 'not a directory' -Encoding Ascii -NoNewline
  $bfOk = $true; $bfCode = 0
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pvE.path; previewId = $pvE.previewId; confirm = $true; forceReplace = $true } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/register" | Out-Null } catch { $bfOk = $false; $bfCode = $_.Exception.Response.StatusCode.value__ }
  Remove-Item -LiteralPath $broot -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $brootSaved) { Rename-Item -LiteralPath $brootSaved -NewName 'backups' }
  Assert ((-not $bfOk) -and ($bfCode -eq 500)) 'backup failure: register 500'
  Assert ((@(Get-Registry $auto)).Count -eq 1) 'backup failure: registry unchanged'
  Assert ((Get-Content -LiteralPath (Join-Path $repoE 'AGENTS.md') -Raw) -eq 'existing agents for backup fail') 'backup failure: original unchanged'

  # batch block: item with existing AGENTS in batch -> 400
  $repoD = Join-Path $scratch 'BatchAgentsRepo'
  New-Item -ItemType Directory -Force -Path (Join-Path $repoD '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoD 'AGENTS.md') 'existing' -Encoding Ascii
  $pvB = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ paths = @($repoD) } | ConvertTo-Json -Compress) -Uri "http://127.0.0.1:$port/api/preview-batch").Content | ConvertFrom-Json
  # preview-batch may fail due to existing agents; check
  Assert ($pvB.results.Count -eq 1) 'batch: one result'
  Assert ($pvB.results[0].ok -eq $false) 'batch: existing-AGENTS item not ok'
  Assert ((@(Get-Registry $auto)).Count -eq 1) 'batch: registry unchanged'
} finally {
  if ($srv -and -not $srv.HasExited) { try { $srv.Kill() } catch {} }
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  $env:DASHBOARD_AUTODIR = $origAuto
  $env:DASHBOARD_PORT = $origPort
}
if ($failures.Count -gt 0) { Write-Host ("FAILURES: " + ($failures -join ', ')); exit 1 }
Write-Host 'ALL REGISTER-REPLACE CHECKS PASSED'
exit 0