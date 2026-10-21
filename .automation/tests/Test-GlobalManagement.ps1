# Test-GlobalManagement.ps1 - isolated self-checks for Global-Management.ps1 (Global auto sync dashboard).
# Scratch-only. Never touches real home, tasks, registry, or deployed AppData.
# Scheduler cmdlets are shadowed (mocked); live scheduler writes are never tested.
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
$devAuto = Split-Path -Parent $PSScriptRoot
try {
  . (Join-Path $devAuto 'Global-Management.ps1')
  Assert ((Get-Command Get-GlobalSettings -ErrorAction SilentlyContinue) -ne $null) 'G0 module dot-sourced (no listen)'

  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalMgmtTest'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  $fakeHome = Join-Path $scratch 'home'
  New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
  # fake preview root: <scratch>\global-preview\rulesync.lock (sibling of auto)
  $gprev = Join-Path $scratch 'global-preview'
  New-Item -ItemType Directory -Force -Path $gprev | Out-Null
  Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"example-org/team-rules":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii

  # G1: targets validation (allowlist codexcli/opencode, non-empty, no arbitrary)
  Assert ((Test-GlobalTargetsValid @('codexcli', 'opencode')) -eq $true) 'G1 both targets valid'
  Assert ((Test-GlobalTargetsValid @('codexcli')) -eq $true) 'G1 single target valid'
  Assert ((Test-GlobalTargetsValid @()) -eq $false) 'G1 empty rejected'
  Assert ((Test-GlobalTargetsValid $null) -eq $false) 'G1 null rejected'
  Assert ((Test-GlobalTargetsValid @('foo')) -eq $false) 'G1 arbitrary rejected'
  Assert ((Test-GlobalTargetsValid @('codexcli', 'codexcli')) -eq $false) 'G1 duplicate rejected'
  Assert ((Test-GlobalTargetsValid @('codexcli', '')) -eq $false) 'G1 empty-string entry rejected'
  Assert ((Test-GlobalTargetsValid 'codexcli') -eq $true) 'G1 scalar single accepted'

  # G2: settings default + atomic set/get + invalid rejected, file stays private JSON
  $s0 = Get-GlobalSettings $auto
  Assert ((@($s0.targets).Count -eq 2) -and ($s0.targets -contains 'codexcli') -and ($s0.targets -contains 'opencode')) 'G2 default targets both'
  Set-GlobalTargets $auto @('opencode') | Out-Null
  $s1 = Get-GlobalSettings $auto
  Assert ((@($s1.targets).Count -eq 1) -and ($s1.targets[0] -ceq 'opencode')) 'G2 single target persists'
  $gBad = $true
  try { Set-GlobalTargets $auto @() | Out-Null; $gBad = $false } catch { $gBad = $true }
  Assert ($gBad) 'G2 empty targets refused'
  $gBad2 = $true
  try { Set-GlobalTargets $auto @('evil;rm') | Out-Null; $gBad2 = $false } catch { $gBad2 = $true }
  Assert ($gBad2) 'G2 arbitrary targets refused'
  Assert (((Get-GlobalSettings $auto).targets[0] -ceq 'opencode')) 'G2 refused write keeps old settings'
  Set-GlobalTargets $auto @('codexcli', 'opencode') | Out-Null

  # G3: status unknown before structured status exists (no lock/log inference)
  $st0 = Get-GlobalStatus $auto
  Assert (($null -ne $st0.providers['codexcli']) -and ($null -ne $st0.providers['opencode'])) 'G3 both provider rows present'
  Assert (($st0.providers['codexcli'].result -ceq 'unknown') -and ($null -eq $st0.providers['codexcli'].lastSuccessAt)) 'G3 unknown before status file exists'
  Save-GlobalProviderResult $auto 'codexcli' 'success' '' '0123456789abcdef0123456789abcdef01234567' | Out-Null
  $st1 = Get-GlobalStatus $auto
  Assert (([string]$st1.providers['codexcli'].result -ceq 'success') -and ([string]$st1.providers['codexcli'].sourceCommit -ceq '0123456789abcdef0123456789abcdef01234567')) 'G3 success with source commit persists'
  Assert (($null -ne [string]$st1.providers['codexcli'].lastSuccessAt) -and ([string]$st1.providers['opencode'].result -ceq 'unknown')) 'G3 per-provider last-success (no cross-fill)'
  Save-GlobalProviderResult $auto 'opencode' 'failed' 'boom-T9' '' | Out-Null
  $st2 = Get-GlobalStatus $auto
  Assert (([string]$st2.providers['opencode'].result -ceq 'failed') -and ([string]$st2.providers['opencode'].error -ceq 'boom-T9')) 'G3 failure with error persists'
  Assert (([string]$st2.providers['codexcli'].result -ceq 'success')) 'G3 sibling row untouched'
  $gStatBad = $true
  try { Save-GlobalProviderResult $auto 'evil' 'success' '' '' | Out-Null; $gStatBad = $false } catch { $gStatBad = $true }
  Assert ($gStatBad) 'G3 arbitrary provider refused'

  # G4: deployment paths resolved from current home (allowlist only, no traversal)
  $paths = Get-GlobalContentPaths $fakeHome
  Assert (($paths['codexcli'].EndsWith('.codex\AGENTS.md')) -and ($paths['opencode'].EndsWith('.config\opencode\AGENTS.md'))) 'G4 allowlisted provider paths'
  Assert ((-not $paths.ContainsKey('opencode.jsonc')) -and (-not $paths.ContainsKey('json'))) 'G4 config files never deployment paths'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-body-AAA' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-body-BBB' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\opencode.jsonc') '{"secret":"shhh-G4"}' -Encoding Ascii
  $gc = Get-GlobalContent $fakeHome 'dummy-token-G4'
  Assert ((@($gc.files).Count -eq 2)) 'G4 two provider files only'
  Assert (((@($gc.files | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].head.Contains('codex-body-AAA'))) 'G4 actual current content returned'
  Assert (((( @($gc.files | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].hash -match '^[0-9a-f]{64}$'))) 'G4 content hash present'
  Assert ((-not (($gc | ConvertTo-Json -Depth 5 -Compress).Contains('shhh-G4')))) 'G4 opencode.jsonc content never exposed'

  # G5: redaction (token + gh patterns, never raw secret)
  $red = Redact-GlobalText 'tok=dummy-token-G4 and ghp_abcdefgh12345678 end' 'dummy-token-G4'
  Assert ((($red.Contains('dummy-token-G4') -eq $false) -and ($red.Contains('ghp_abcdefgh12345678') -eq $false) -and ($red.Contains('***')))) 'G5 token+ghp redacted'

  # G5b: OAuth/user/server/refresh prefixes (unassigned pattern-only) redacted on display paths.
  $oauthSamples = @('ghp_FAKE0123456789AB', 'gho_FAKE0123456789AB', 'ghu_FAKE0123456789AB', 'ghs_FAKE0123456789AB', 'ghr_FAKE0123456789AB', 'github_pat_FAKE0123456789_AB')
  $oauthOk = $true
  foreach ($s in $oauthSamples) {
    $rr = Redact-GlobalText ('leak ' + $s + ' end') 'dash-tok-G5b'
    if (($rr.Contains($s)) -or (-not ($rr.Contains('***')))) { $oauthOk = $false }
  }
  Assert ($oauthOk) 'G5b all github token prefixes redacted'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') ('codex-cur-G5b ' + ($oauthSamples -join ' ')) -Encoding Ascii
  $gc5b = Get-GlobalContent $fakeHome 'dash-tok-G5b'
  $cx5b = @($gc5b.files | Where-Object { [string]$_.target -ceq 'codexcli' })
  $headOk = $true
  foreach ($s in $oauthSamples) { if ([string]$cx5b[0].head -match [regex]::Escape($s)) { $headOk = $false } }
  Assert ($headOk) 'G5b content head redacts all prefixes'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-body-AAA' -Encoding Ascii
  $logDir5b = Join-Path $auto 'logs'
  New-Item -ItemType Directory -Force -Path $logDir5b | Out-Null
  Set-Content -LiteralPath (Join-Path $logDir5b 'Sync-GlobalRules-20200100.log') ('2020-01-01 00:00:00 FAIL: leak ' + ($oauthSamples -join ' ') + ' end') -Encoding UTF8
  $gl5b = Get-GlobalLogTail $auto 'dash-tok-G5b'
  $tailOk = $true
  foreach ($s in $oauthSamples) { if ([string]$gl5b.tail -match [regex]::Escape($s)) { $tailOk = $false } }
  Assert ($tailOk) 'G5b log tail redacts all prefixes'

  # G6: global lock (same file Sync-GlobalRules.lock; busy message Japanese)
  $lk = Open-GlobalSyncLock $auto
  $busy = $true; $busyMsg = ''
  try { Open-GlobalSyncLock $auto | Out-Null; $busy = $false } catch { $busyMsg = $_.Exception.Message }
  try { $lk.Close() } catch {}
  Assert ($busy) 'G6 locked second open refused'
  Assert ($busyMsg.Contains('終了後にやり直してください')) 'G6 busy message Japanese'
  $lk2 = Open-GlobalSyncLock $auto
  try { $lk2.Close() } catch {}
  Assert ($true) 'G6 lock released and reopenable'

  # G7: logs (latest Sync-GlobalRules-*.log, bounded, redacted)
  $logDir = Join-Path $auto 'logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  Set-Content -LiteralPath (Join-Path $logDir 'Sync-GlobalRules-20200101.log') ("2020-01-01 00:00:00 OK: old`n") -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $logDir 'Sync-GlobalRules-20200102.log') ("2020-01-02 00:00:00 FAIL: leak dummy-token-G4 here`n") -Encoding UTF8
  $gl = Get-GlobalLogTail $auto 'dummy-token-G4'
  Assert ((($gl.name.Contains('20200102')) -and ($gl.tail.Contains('FAIL')) -and (-not ($gl.tail.Contains('dummy-token-G4'))))) 'G7 latest log bounded+redacted'

  # G8: plan live + match (source/target/hash; stale+failed refuse)
  $live = Get-GlobalPlanLive $auto $fakeHome
  Assert (([string]$live.sourceCommit -ceq '0123456789abcdef0123456789abcdef01234567')) 'G8 live source commit from preview lock'
  Assert ((@($live.entries).Count -eq 2)) 'G8 live entries per target'
  $plan = @{
    schemaVersion = 1; createdAt = ([DateTime]::UtcNow.ToString('o')); sourceCommit = [string]$live.sourceCommit
    targets = @('codexcli', 'opencode'); entries = @()
  }
  foreach ($e in @($live.entries)) {
    $plan.entries += @{ target = [string]$e.target; path = [string]$e.path; currentHash = [string]$e.currentHash; generatedHash = 'f'; generatedText = 'gen'; currentText = 'cur'; result = 'success'; error = '' }
  }
  $m0 = Test-GlobalPlanMatch $plan $live @('codexcli', 'opencode')
  Assert ($m0.ok) 'G8 fresh successful plan matches'
  $live2 = Get-GlobalPlanLive $auto $fakeHome
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-body-CHANGED' -Encoding Ascii
  $live3 = Get-GlobalPlanLive $auto $fakeHome
  $mStale = Test-GlobalPlanMatch $plan $live3 @('codexcli', 'opencode')
  Assert ((($mStale.ok -eq $false) -and ($mStale.error.Contains('変化')))) 'G8 changed current content refuses plan'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-body-AAA' -Encoding Ascii
  $planF = @{ schemaVersion = 1; createdAt = ([DateTime]::UtcNow.ToString('o')); sourceCommit = [string]$live.sourceCommit; targets = @('codexcli'); entries = @(@{ target = 'codexcli'; path = [string](@($live.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].path; currentHash = [string](@($live.entries | Where-Object { [string]$_.target -ceq 'codexcli' }))[0].currentHash; generatedHash = ''; generatedText = ''; currentText = ''; result = 'failed'; error = 'x' }) }
  $mFail = Test-GlobalPlanMatch $planF (Get-GlobalPlanLive $auto $fakeHome) @('codexcli')
  Assert ((($mFail.ok -eq $false) -and ($mFail.error.Contains('承認')))) 'G8 failed plan entry refuses apply'
  $mOld = Test-GlobalPlanMatch (@{ schemaVersion = 0 }) $live @('codexcli')
  Assert (($mOld.ok -eq $false)) 'G8 old schema refuses'

  # G9: backup with manifest + diff + restore (pause-first, rollback honest, tamper/traversal/legacy refuse)
  $bk = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  Assert ((Test-Path -LiteralPath (Join-Path $bk 'manifest.json')) -and (Test-Path -LiteralPath (Join-Path $bk '.codex_AGENTS.md'))) 'G9 backup dir with manifest+files'
  $bl = @(Get-GlobalBackupList $auto)
  Assert ((@($bl).Count -ge 1) -and ([string]$bl[0].id -ceq (Split-Path $bk -Leaf))) 'G9 backup listed'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-body-NEWER' -Encoding Ascii
  $bd = Get-GlobalBackupDiff $auto (Split-Path $bk -Leaf) $fakeHome
  Assert ((($bd.same -eq $false) -and ((@($bd.lines).Count) -gt 0))) 'G9 diff shows change'
  Assert ((@($bd.lines).Count -le 300)) 'G9 diff bounded'
  $script:pauseCalls = @()
  function Disable-ScheduledTask { param([string]$TaskName) $script:pauseCalls += ('disable:' + [string]$TaskName) }
  $cfG9 = New-GlobalRestoreConfirm $auto (Split-Path $bk -Leaf) $fakeHome
  $rs = Restore-GlobalBackup $auto (Split-Path $bk -Leaf) $true $fakeHome $cfG9
  Assert ((($rs.ok -eq $true) -and (@($script:pauseCalls).Count -eq 1) -and ([string]$script:pauseCalls[0] -ceq 'disable:Rulesync Global Auto Sync'))) 'G9 restore pauses global sync first (task disable)'
  Assert (((Get-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Raw).Contains('codex-body-AAA'))) 'G9 restore brings back backup content'
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  $rsNoConfirm = $true
  try { Restore-GlobalBackup $auto (Split-Path $bk -Leaf) $false $fakeHome | Out-Null; $rsNoConfirm = $false } catch { $rsNoConfirm = ($_.Exception.Message.Contains('確認')) }
  Assert ($rsNoConfirm) 'G9 restore without confirm refused'
  # tampered manifest: hash mismatch refuses
  $mfPath = Join-Path $bk 'manifest.json'
  $mfRaw = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8
  Set-Content -LiteralPath $mfPath ($mfRaw.Replace('codex-body-AAA', 'codex-body-AAA').Replace('"agentsHash"', '"agentsHash"').Substring(0, $mfRaw.Length)) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $bk '.codex_AGENTS.md') 'tampered-bytes' -Encoding Ascii
  function Disable-ScheduledTask { param([string]$TaskName) }
  $tamper = $true
  try { New-GlobalRestoreConfirm $auto (Split-Path $bk -Leaf) $fakeHome | Out-Null; $tamper = $false } catch { $tamper = ($_.Exception.Message.Contains('破損')) }
  Assert ($tamper) 'G9 tampered backup refused at diff confirmation'
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  # legacy backup without manifest refuses (never guesses)
  $legacyDir = Join-Path (Join-Path $auto 'backups') '20200101-000000-legacy'
  New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
  Set-Content -LiteralPath (Join-Path $legacyDir '.codex_AGENTS.md') 'legacy' -Encoding Ascii
  $leg = $true
  try { New-GlobalRestoreConfirm $auto '20200101-000000-legacy' $fakeHome | Out-Null; $leg = $false } catch { $leg = ($_.Exception.Message.Contains('信頼')) }
  Assert ($leg) 'G9 legacy backup without manifest refuses restore confirmation'
  $legDiff = $true
  try { Get-GlobalBackupDiff $auto '20200101-000000-legacy' $fakeHome | Out-Null; $legDiff = $false } catch { $legDiff = $true }
  Assert ($legDiff) 'G9 legacy backup without manifest refuses diff'

  # G10: interval validation + mocked scheduler (Global task only, 5..1440)
  Assert ((Test-GlobalIntervalValid 5) -and (Test-GlobalIntervalValid 1440) -and (-not (Test-GlobalIntervalValid 4)) -and (-not (Test-GlobalIntervalValid 1441))) 'G10 interval range 5..1440'
  $script:mockGInterval = 'PT15M'
  $script:mockGCalls = @()
  function Get-ScheduledTask { param([string]$TaskName)
    if ($TaskName -cne 'Rulesync Global Auto Sync') { throw 'task not found' }
    $rep = New-Object PSObject -Property @{ Interval = $script:mockGInterval }
    $tr = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskTimeTrigger' }; Repetition = $rep }
    return [pscustomobject]@{ Triggers = @($tr); State = 'Ready' }
  }
  function Set-ScheduledTask { param([string]$TaskName, $Trigger)
    $script:mockGCalls += [string]$TaskName
    $script:mockGInterval = [string]$Trigger[0].Repetition.Interval
  }
  function Disable-ScheduledTask { param([string]$TaskName) $script:mockGCalls += ('disable:' + [string]$TaskName); $script:mockGState = 'Disabled' }
  function Enable-ScheduledTask { param([string]$TaskName) $script:mockGCalls += ('enable:' + [string]$TaskName); $script:mockGState = 'Ready' }
  Assert (((Get-GlobalInterval) -eq 15)) 'G10 mocked interval reads 15'
  Set-GlobalInterval 30 | Out-Null
  Assert ((($script:mockGInterval -ceq 'PT30M') -and ((Get-GlobalInterval) -eq 30))) 'G10 interval set roundtrips mocked scheduler'
  Assert ((@($script:mockGCalls | Where-Object { ($_ -ne 'Rulesync Global Auto Sync') -and ($_ -notlike 'disable:*') -and ($_ -notlike 'enable:*') }).Count -eq 0)) 'G10 scheduler writes target Global task only'
  $ivBad = $true
  try { Set-GlobalInterval 3 | Out-Null; $ivBad = $false } catch { $ivBad = $true }
  Assert ($ivBad) 'G10 out-of-range interval refused before scheduler write'
  $script:mockGState = 'Ready'
  Assert (((Get-GlobalTaskEnabled) -eq $true)) 'G10 enabled reads Ready as true'
  Set-GlobalTaskEnabled $false | Out-Null
  Assert (($script:mockGState -ceq 'Disabled')) 'G10 disable pauses auto sync'
  Set-GlobalTaskEnabled $true | Out-Null
  Assert (($script:mockGState -ceq 'Ready')) 'G10 re-enable resumes auto sync'
  Assert ((Get-GlobalTaskName) -ceq 'Rulesync Global Auto Sync') 'G10 task name fixed (no arbitrary tasks)'
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Set-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue

  # G11: sync request/result binding (run ids, no stale success)
  $req = Write-GlobalSyncRequest $auto
  Assert (($req.id -match '^[0-9a-f]{32}$')) 'G11 request id is run id'
  $gst = Get-GlobalSyncState $auto 'dummy-token-G4' $req.id
  Assert (([string]$gst.syncState -ceq 'waiting') -or ([string]$gst.syncState -ceq 'running') -or ([string]$gst.syncState -ceq 'unconfirmed')) 'G11 no result file means never success'
  Assert (([string]$gst.syncState -cne 'success')) 'G11 stale success never inferred'
  Write-GlobalSyncResult $auto $req.id 0 | Out-Null
  $gst2 = Get-GlobalSyncState $auto 'dummy-token-G4' $req.id
  Assert ([string]$gst2.syncState -ceq 'success') 'G11 runID-bound result success'
  Write-GlobalSyncResult $auto $req.id 75 | Out-Null
  $gst3 = Get-GlobalSyncState $auto 'dummy-token-G4' $req.id
  Assert ([string]$gst3.syncState -ceq 'skipped') 'G11 exit 75 is skipped, not success'
  $gstBad = Get-GlobalSyncState $auto 'dummy-token-G4' 'bad-id'
  Assert (([string]$gstBad.syncState -cne 'success')) 'G11 bad run id never success'

  Assert (((Get-Location).Path) -eq $initCwd) 'G12 cwd unchanged'
  Assert (Test-Path -LiteralPath $scratch) 'G12 scratch exists before cleanup'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'G12 only own GUID scratch removed'
  Assert (Test-Path -LiteralPath $base) 'G12 base dir left intact'
}
finally {
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Set-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}

if ($failures.Count -eq 0) { Write-Host 'ALL GLOBALMGMT CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
