# Test-GlobalReviewRound6.ps1 - round6 findings (RED then GREEN), tracked.
# F1: backup diff/confirm/restore read and pin current bytes only for the
#     verified manifest's agents targets; an unselected provider (oversize,
#     linked parent, or edited after the diff) never blocks, while a changed
#     selected target is still refused.
# F2: the atomic writer recreates missing trusted parents (.codex /
#     .config\opencode) during restore; linked parents still refuse and the
#     rollback path is unchanged.
# F3: the project backup list excludes shared scope=global rows while
#     full/local/legacy project rows stay.
# Scratch-only. Never touches real home, tasks, registry, or deployed AppData.
# Scheduler cmdlets are shadowed at script scope; only the product functions
# are wrapped where a deterministic mid-flight failure is needed.
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
$origHomeDir = $env:HOME_DIR
$origGithub = $env:GITHUB_TOKEN
$origGh = $env:GH_TOKEN
$origPath = $env:PATH
$devAuto = Split-Path -Parent $PSScriptRoot
try {
  . (Join-Path $devAuto 'Dashboard-Server.ps1')
  # Get-ScheduledTask stays mocked too: autoloading ScheduledTasks re-registers
  # its cmdlets and would let the real Disable-ScheduledTask replace the mock.
  function Get-ScheduledTask {
    param([string]$TaskName)
    if ($TaskName -ceq 'Rulesync Global Auto Sync') { return [pscustomobject]@{ TaskName = $TaskName; State = 'Ready'; Triggers = @() } }
    throw ('Task not found: ' + $TaskName)
  }
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalReviewR6Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))

  function New-R6Case([string]$Tag) {
    $c = Join-Path $scratch $Tag
    $auto = Join-Path $c 'auto'
    $fakeHome = Join-Path $c 'home'
    New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
    Set-Content -LiteralPath (Join-Path $c 'outside.txt') 'outside-R6-marker' -Encoding Ascii
    return @{ root = $c; auto = $auto; home = $fakeHome }
  }
  function New-R6OverSize([string]$File) {
    $fs = [System.IO.File]::Create($File)
    try {
      $chunk = New-Object byte[] 65536
      for ($i = 0; $i -lt 40; $i++) { $fs.Write($chunk, 0, $chunk.Length) }
    } finally { $fs.Close() }
  }
  function Get-R6Text([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    return (Get-Content -LiteralPath $File -Raw -Encoding UTF8)
  }

  # ---- F1a: codex-only backup: oversize unselected opencode never blocks the
  # diff, its post-confirm edit never blocks the restore, and a changed
  # selected codex is still refused.
  $sA = New-R6Case 'f1a'
  Set-Content -LiteralPath (Join-Path $sA.home '.codex\AGENTS.md') 'codex-F1a' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sA.home '.config\opencode\AGENTS.md') 'opencode-F1a' -Encoding Ascii
  $bkA = New-GlobalBackup $sA.auto $sA.home @('codexcli')
  $idA = Split-Path $bkA -Leaf
  New-R6OverSize (Join-Path $sA.home '.config\opencode\AGENTS.md')
  $bdA = $null
  $bdAErr = ''
  try { $bdA = Get-GlobalBackupDiff $sA.auto $idA $sA.home } catch { $bdAErr = $_.Exception.Message }
  Assert (($null -ne $bdA) -and ([string]$bdA.confirmId -match '^[0-9a-f]{32}$')) ('R6-F1a oversize unselected opencode never blocks diff (' + $bdAErr + ')')
  Set-Content -LiteralPath (Join-Path $sA.home '.config\opencode\AGENTS.md') 'opencode-F1a-2' -Encoding Ascii
  $rsA = $null
  $rsAErr = ''
  try { $rsA = Restore-GlobalBackup $sA.auto $idA $true $sA.home ([string]$bdA.confirmId) } catch { $rsAErr = $_.Exception.Message }
  Assert (($null -ne $rsA) -and ($rsA.ok -eq $true)) ('R6-F1a post-confirm edit of unselected opencode never blocks restore (' + $rsAErr + ')')
  Assert ((Get-R6Text (Join-Path $sA.home '.codex\AGENTS.md')).Contains('codex-F1a')) 'R6-F1a selected codex restored from backup'
  Assert ((Get-R6Text (Join-Path $sA.home '.config\opencode\AGENTS.md')).Contains('opencode-F1a-2')) 'R6-F1a unselected opencode edit left as-is'
  New-R6OverSize (Join-Path $sA.home '.config\opencode\AGENTS.md')
  $bdA2 = $null
  $bdA2Err = ''
  try { $bdA2 = Get-GlobalBackupDiff $sA.auto $idA $sA.home } catch { $bdA2Err = $_.Exception.Message }
  Assert (($null -ne $bdA2) -and ([string]$bdA2.confirmId -match '^[0-9a-f]{32}$')) ('R6-F1a re-diff with oversize unselected opencode still issues confirm (' + $bdA2Err + ')')
  Set-Content -LiteralPath (Join-Path $sA.home '.codex\AGENTS.md') 'codex-F1a-changed' -Encoding Ascii
  $selRefA = $false
  try { Restore-GlobalBackup $sA.auto $idA $true $sA.home ([string]$bdA2.confirmId) | Out-Null } catch { $selRefA = $true }
  Assert ($selRefA) 'R6-F1a changed selected codex still refused'
  Assert ((Get-R6Text (Join-Path $sA.home '.codex\AGENTS.md')).Contains('codex-F1a-changed')) 'R6-F1a refused restore leaves selected file as-is'

  # ---- F1b: mirror direction (opencode-only backup ignores abnormal codex).
  $sB = New-R6Case 'f1b'
  Set-Content -LiteralPath (Join-Path $sB.home '.codex\AGENTS.md') 'codex-F1b' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sB.home '.config\opencode\AGENTS.md') 'opencode-F1b' -Encoding Ascii
  $bkB = New-GlobalBackup $sB.auto $sB.home @('opencode')
  $idB = Split-Path $bkB -Leaf
  New-R6OverSize (Join-Path $sB.home '.codex\AGENTS.md')
  $bdB = $null
  $bdBErr = ''
  try { $bdB = Get-GlobalBackupDiff $sB.auto $idB $sB.home } catch { $bdBErr = $_.Exception.Message }
  Assert (($null -ne $bdB) -and ([string]$bdB.confirmId -match '^[0-9a-f]{32}$')) ('R6-F1b oversize unselected codex never blocks diff (' + $bdBErr + ')')
  Set-Content -LiteralPath (Join-Path $sB.home '.codex\AGENTS.md') 'codex-F1b-2' -Encoding Ascii
  $rsB = $null
  $rsBErr = ''
  try { $rsB = Restore-GlobalBackup $sB.auto $idB $true $sB.home ([string]$bdB.confirmId) } catch { $rsBErr = $_.Exception.Message }
  Assert (($null -ne $rsB) -and ($rsB.ok -eq $true)) ('R6-F1b post-confirm edit of unselected codex never blocks restore (' + $rsBErr + ')')
  Assert ((Get-R6Text (Join-Path $sB.home '.config\opencode\AGENTS.md')).Contains('opencode-F1b')) 'R6-F1b selected opencode restored from backup'
  Assert ((Get-R6Text (Join-Path $sB.home '.codex\AGENTS.md')).Contains('codex-F1b-2')) 'R6-F1b unselected codex edit left as-is'
  $bdB2 = $null
  $bdB2Err = ''
  try { $bdB2 = Get-GlobalBackupDiff $sB.auto $idB $sB.home } catch { $bdB2Err = $_.Exception.Message }
  Assert (($null -ne $bdB2) -and ([string]$bdB2.confirmId -match '^[0-9a-f]{32}$')) ('R6-F1b re-diff with oversize unselected codex still issues confirm (' + $bdB2Err + ')')
  Set-Content -LiteralPath (Join-Path $sB.home '.config\opencode\AGENTS.md') 'opencode-F1b-changed' -Encoding Ascii
  $selRefB = $false
  try { Restore-GlobalBackup $sB.auto $idB $true $sB.home ([string]$bdB2.confirmId) | Out-Null } catch { $selRefB = $true }
  Assert ($selRefB) 'R6-F1b changed selected opencode still refused'

  # ---- F1c: codex-only backup with a junctioned unselected opencode parent:
  # diff/restore never read through the link; the external dir stays intact.
  $sC = New-R6Case 'f1c'
  Set-Content -LiteralPath (Join-Path $sC.home '.codex\AGENTS.md') 'codex-F1c' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sC.home '.config\opencode\AGENTS.md') 'opencode-F1c' -Encoding Ascii
  $bkC = New-GlobalBackup $sC.auto $sC.home @('codexcli')
  $idC = Split-Path $bkC -Leaf
  $extC = Join-Path $sC.root 'extC'
  New-Item -ItemType Directory -Force -Path $extC | Out-Null
  Set-Content -LiteralPath (Join-Path $extC 'AGENTS.md') 'extC-marker' -Encoding Ascii
  $ocodeC = Join-Path $sC.home '.config\opencode'
  Remove-Item -LiteralPath $ocodeC -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $ocodeC + '" "' + $extC + '"') | Out-Null
  $bdC = $null
  $bdCErr = ''
  try { $bdC = Get-GlobalBackupDiff $sC.auto $idC $sC.home } catch { $bdCErr = $_.Exception.Message }
  Assert (($null -ne $bdC) -and ([string]$bdC.confirmId -match '^[0-9a-f]{32}$')) ('R6-F1c junctioned unselected opencode never blocks diff (' + $bdCErr + ')')
  $rsC = $null
  $rsCErr = ''
  try { $rsC = Restore-GlobalBackup $sC.auto $idC $true $sC.home ([string]$bdC.confirmId) } catch { $rsCErr = $_.Exception.Message }
  Assert (($null -ne $rsC) -and ($rsC.ok -eq $true)) ('R6-F1c junctioned unselected opencode never blocks restore (' + $rsCErr + ')')
  Assert ((Get-R6Text (Join-Path $sC.home '.codex\AGENTS.md')).Contains('codex-F1c')) 'R6-F1c selected codex restored through junction surroundings'
  Assert ((Get-R6Text (Join-Path $extC 'AGENTS.md')).Contains('extC-marker')) 'R6-F1c external dir untouched'
  & $cmdExe /c ('rmdir "' + $ocodeC + '"') | Out-Null

  # ---- F1d: mirror direction (opencode-only backup, junctioned codex parent).
  $sD = New-R6Case 'f1d'
  Set-Content -LiteralPath (Join-Path $sD.home '.codex\AGENTS.md') 'codex-F1d' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sD.home '.config\opencode\AGENTS.md') 'opencode-F1d' -Encoding Ascii
  $bkD = New-GlobalBackup $sD.auto $sD.home @('opencode')
  $idD = Split-Path $bkD -Leaf
  $extD = Join-Path $sD.root 'extD'
  New-Item -ItemType Directory -Force -Path $extD | Out-Null
  Set-Content -LiteralPath (Join-Path $extD 'AGENTS.md') 'extD-marker' -Encoding Ascii
  $codexD = Join-Path $sD.home '.codex'
  Remove-Item -LiteralPath $codexD -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $codexD + '" "' + $extD + '"') | Out-Null
  $bdD = $null
  $bdDErr = ''
  try { $bdD = Get-GlobalBackupDiff $sD.auto $idD $sD.home } catch { $bdDErr = $_.Exception.Message }
  Assert (($null -ne $bdD) -and ([string]$bdD.confirmId -match '^[0-9a-f]{32}$')) ('R6-F1d junctioned unselected codex never blocks diff (' + $bdDErr + ')')
  $rsD = $null
  $rsDErr = ''
  try { $rsD = Restore-GlobalBackup $sD.auto $idD $true $sD.home ([string]$bdD.confirmId) } catch { $rsDErr = $_.Exception.Message }
  Assert (($null -ne $rsD) -and ($rsD.ok -eq $true)) ('R6-F1d junctioned unselected codex never blocks restore (' + $rsDErr + ')')
  Assert ((Get-R6Text (Join-Path $sD.home '.config\opencode\AGENTS.md')).Contains('opencode-F1d')) 'R6-F1d selected opencode restored through junction surroundings'
  Assert ((Get-R6Text (Join-Path $extD 'AGENTS.md')).Contains('extD-marker')) 'R6-F1d external dir untouched'
  & $cmdExe /c ('rmdir "' + $codexD + '"') | Out-Null

  # ---- F2a: both provider folders deleted after the backup -> the diff binds
  # absent current and restore recreates the folders inside the trusted home.
  $sE = New-R6Case 'f2a'
  Set-Content -LiteralPath (Join-Path $sE.home '.codex\AGENTS.md') 'codex-F2a' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sE.home '.config\opencode\AGENTS.md') 'opencode-F2a' -Encoding Ascii
  $bkE = New-GlobalBackup $sE.auto $sE.home @('codexcli', 'opencode')
  $idE = Split-Path $bkE -Leaf
  Remove-Item -LiteralPath (Join-Path $sE.home '.codex') -Recurse -Force
  Remove-Item -LiteralPath (Join-Path $sE.home '.config') -Recurse -Force
  $bdE = $null
  $bdEErr = ''
  try { $bdE = Get-GlobalBackupDiff $sE.auto $idE $sE.home } catch { $bdEErr = $_.Exception.Message }
  Assert (($null -ne $bdE) -and ([string]$bdE.confirmId -match '^[0-9a-f]{32}$')) ('R6-F2a diff binds both providers absent (' + $bdEErr + ')')
  $rsE = $null
  $rsEErr = ''
  try { $rsE = Restore-GlobalBackup $sE.auto $idE $true $sE.home ([string]$bdE.confirmId) } catch { $rsEErr = $_.Exception.Message }
  Assert (($null -ne $rsE) -and ($rsE.ok -eq $true)) ('R6-F2a restore recreates both missing provider folders (' + $rsEErr + ')')
  Assert ((Get-R6Text (Join-Path $sE.home '.codex\AGENTS.md')).Contains('codex-F2a')) 'R6-F2a codex bytes restored after folder recreation'
  Assert ((Get-R6Text (Join-Path $sE.home '.config\opencode\AGENTS.md')).Contains('opencode-F2a')) 'R6-F2a opencode bytes restored after folder recreation'
  $dE1 = Get-Item -LiteralPath (Join-Path $sE.home '.codex') -Force -ErrorAction SilentlyContinue
  $dE2 = Get-Item -LiteralPath (Join-Path $sE.home '.config\opencode') -Force -ErrorAction SilentlyContinue
  Assert (((($null -ne $dE1) -and ($null -ne $dE2)) -and ((($dE1.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) -and ((($dE2.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)))) 'R6-F2a recreated folders are real directories'
  Assert ((Get-R6Text (Join-Path $sE.root 'outside.txt')).Contains('outside-R6-marker')) 'R6-F2a outside home untouched'

  # ---- F2b: mid-ancestor missing (.config exists, opencode removed).
  $sF = New-R6Case 'f2b'
  Set-Content -LiteralPath (Join-Path $sF.home '.codex\AGENTS.md') 'codex-F2b' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sF.home '.config\opencode\AGENTS.md') 'opencode-F2b' -Encoding Ascii
  $bkF = New-GlobalBackup $sF.auto $sF.home @('codexcli', 'opencode')
  $idF = Split-Path $bkF -Leaf
  Remove-Item -LiteralPath (Join-Path $sF.home '.config\opencode') -Recurse -Force
  $bdF = $null
  $bdFErr = ''
  try { $bdF = Get-GlobalBackupDiff $sF.auto $idF $sF.home } catch { $bdFErr = $_.Exception.Message }
  Assert (($null -ne $bdF) -and ([string]$bdF.confirmId -match '^[0-9a-f]{32}$')) ('R6-F2b diff binds missing mid ancestor (' + $bdFErr + ')')
  $rsF = $null
  $rsFErr = ''
  try { $rsF = Restore-GlobalBackup $sF.auto $idF $true $sF.home ([string]$bdF.confirmId) } catch { $rsFErr = $_.Exception.Message }
  Assert (($null -ne $rsF) -and ($rsF.ok -eq $true)) ('R6-F2b restore recreates the missing mid ancestor (' + $rsFErr + ')')
  Assert ((Get-R6Text (Join-Path $sF.home '.config\opencode\AGENTS.md')).Contains('opencode-F2b')) 'R6-F2b opencode bytes restored below recreated ancestor'
  Assert ((Get-R6Text (Join-Path $sF.home '.codex\AGENTS.md')).Contains('codex-F2b')) 'R6-F2b codex untouched by mid-ancestor recreation'

  # ---- F2c: a linked destination parent still refuses before any write.
  $sG = New-R6Case 'f2c'
  Set-Content -LiteralPath (Join-Path $sG.home '.codex\AGENTS.md') 'codex-F2c' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sG.home '.config\opencode\AGENTS.md') 'opencode-F2c' -Encoding Ascii
  $bkG = New-GlobalBackup $sG.auto $sG.home @('codexcli', 'opencode')
  $idG = Split-Path $bkG -Leaf
  $bdG = Get-GlobalBackupDiff $sG.auto $idG $sG.home
  $extG = Join-Path $sG.root 'extG'
  New-Item -ItemType Directory -Force -Path $extG | Out-Null
  Set-Content -LiteralPath (Join-Path $extG 'AGENTS.md') 'extG-marker' -Encoding Ascii
  $ocodeG = Join-Path $sG.home '.config\opencode'
  Remove-Item -LiteralPath $ocodeG -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $ocodeG + '" "' + $extG + '"') | Out-Null
  $refG = $false
  try { Restore-GlobalBackup $sG.auto $idG $true $sG.home ([string]$bdG.confirmId) | Out-Null } catch { $refG = $true }
  Assert ($refG) 'R6-F2c linked destination parent still refuses restore'
  Assert ((Get-R6Text (Join-Path $extG 'AGENTS.md')).Contains('extG-marker')) 'R6-F2c external file never written through the link'
  Assert ((Get-R6Text (Join-Path $sG.home '.codex\AGENTS.md')).Contains('codex-F2c')) 'R6-F2c refused restore left the other target unapplied'
  & $cmdExe /c ('rmdir "' + $ocodeG + '"') | Out-Null

  # ---- F2d: rollback is unchanged: an injected second-copy failure rolls the
  # first applied target back to its pre-restore bytes.
  $sH = New-R6Case 'f2d'
  Set-Content -LiteralPath (Join-Path $sH.home '.codex\AGENTS.md') 'codex-F2d-orig' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sH.home '.config\opencode\AGENTS.md') 'opencode-F2d-orig' -Encoding Ascii
  $bkH = New-GlobalBackup $sH.auto $sH.home @('codexcli', 'opencode')
  $idH = Split-Path $bkH -Leaf
  Set-Content -LiteralPath (Join-Path $sH.home '.codex\AGENTS.md') 'codex-F2d-live' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $sH.home '.config\opencode\AGENTS.md') 'opencode-F2d-live' -Encoding Ascii
  $bdH = Get-GlobalBackupDiff $sH.auto $idH $sH.home
  $script:origR6Exp = (Get-Command Copy-GlobalExpectedBytes).ScriptBlock
  $script:r6F2dCalls = 0
  function Copy-GlobalExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What, [string]$SrcRoot = "", [string]$DstRoot = "") {
    $script:r6F2dCalls++
    if ($script:r6F2dCalls -eq 2) { throw 'injected-r6f2d' }
    return (& $script:origR6Exp $Src $Dst $ExpectedHash $What $SrcRoot $DstRoot)
  }
  $threwH = $false
  try { Restore-GlobalBackup $sH.auto $idH $true $sH.home ([string]$bdH.confirmId) | Out-Null } catch { $threwH = $true }
  Remove-Item -Path 'function:Copy-GlobalExpectedBytes' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  Assert ($threwH) 'R6-F2d injected second-copy failure aborts restore'
  Assert (($script:r6F2dCalls -eq 4)) 'R6-F2d rollback uses the real copy path after the injected failure'
  Assert ((Get-R6Text (Join-Path $sH.home '.codex\AGENTS.md')).Contains('codex-F2d-live')) 'R6-F2d rollback restores pre-restore codex bytes'
  Assert ((Get-R6Text (Join-Path $sH.home '.config\opencode\AGENTS.md')).Contains('opencode-F2d-live')) 'R6-F2d failed copy target left untouched'

  # ---- F3: shared backups folder: project list keeps full/local/legacy rows
  # and excludes scope=global rows (Global's own list filters the inverse).
  $sI = New-R6Case 'f3'
  $autoI = $sI.auto
  $brootI = Join-Path $autoI 'backups'
  $projRowI = '20260101-000001-RepF3'
  $localRowI = '20260101-000002-RepF3-localrule'
  $globalRowI = '20260101-000003-global'
  $legacyRowI = '20200101-000000-legacy'
  foreach ($rI in @($projRowI, $localRowI, $globalRowI, $legacyRowI)) { New-Item -ItemType Directory -Force -Path (Join-Path $brootI $rI) | Out-Null }
  Set-Content -LiteralPath (Join-Path (Join-Path $brootI $projRowI) 'manifest.json') ((@{ schemaVersion = 1; name = 'RepF3'; path = 'C:\scratch\RepF3'; createdAt = '2026-01-01T00:00:00Z'; agentsPresent = $true; localPresent = $false; agentsHash = ''; localHash = '' } | ConvertTo-Json -Depth 6 -Compress)) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path (Join-Path $brootI $localRowI) 'manifest.json') ((@{ schemaVersion = 1; scope = 'local'; name = 'RepF3'; path = 'C:\scratch\RepF3'; createdAt = '2026-01-01T00:00:01Z'; agentsPresent = $false; localPresent = $true; localHash = '' } | ConvertTo-Json -Depth 6 -Compress)) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path (Join-Path $brootI $globalRowI) 'manifest.json') ((@{ schemaVersion = 1; scope = 'global'; homeBase = 'C:\scratch\home'; targets = @('codexcli'); createdAt = '2026-01-01T00:00:02Z'; files = @(@{ target = 'codexcli'; kind = 'agents'; rel = '_codex_AGENTS.md'; present = $false; hash = '' }) } | ConvertTo-Json -Depth 8 -Compress)) -Encoding UTF8
  Set-Content -LiteralPath (Join-Path (Join-Path $brootI $legacyRowI) 'AGENTS.md') 'legacy-F3' -Encoding Ascii
  $listI = @(Get-MgmtBackupList $autoI '')
  $idsI = @($listI | ForEach-Object { [string]$_.id })
  Assert (($idsI -contains $projRowI)) 'R6-F3 full project backup still listed'
  Assert (($idsI -contains $localRowI)) 'R6-F3 localrule backup still listed'
  Assert (($idsI -contains $legacyRowI)) 'R6-F3 legacy backup (no manifest) still listed'
  Assert ((-not ($idsI -contains $globalRowI))) 'R6-F3 scope=global row excluded from project list'
  Assert ((@($idsI).Count -eq 3)) 'R6-F3 project list carries exactly the project rows'
  $filteredI = @(Get-MgmtBackupList $autoI 'RepF3' | ForEach-Object { [string]$_.id })
  Assert ((($filteredI.Count -eq 2) -and ($filteredI -contains $projRowI) -and ($filteredI -contains $localRowI))) 'R6-F3 name filter unchanged for project rows'

  Assert (((Get-Content -LiteralPath (Join-Path $sA.root 'outside.txt') -Raw).Contains('outside-R6-marker'))) 'R6-F1 outside scratch untouched'
  Assert (((Get-Location).Path) -eq $initCwd) 'R6 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'R6 only own GUID scratch removed'
}
finally {
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL R6 REVIEW CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
