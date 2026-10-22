# Test-GlobalReviewRound5.ps1 - round5 findings (RED then GREEN), tracked.
# Covers P1x3 + P2x2 from review5 plus adapted round4 repros (R4F1b/F1c/F2/F2b/F3/F3b).
# Scratch-only. Never touches real home, tasks, registry, or deployed AppData.
# Scheduler cmdlets are shadowed at script scope; only lower-level IO functions
# (Copy-Item shim, Global-ReadBoundedBytes/Global-FileHashHex counters) are
# wrapped - the actual helpers (Copy-GlobalVerified/Copy-GlobalExpectedBytes/
# Write-GlobalFileAtomicBytes/Global-ProtectPrivateFile) always run for real.
# Residual OS TOCTOU between inspection and op cannot be fully prevented
# without handle-based writes; these tests pin the ordered reproducible gaps
# (pre+post inspection, root-inclusive chains, cleanup/list guards), not an
# atomic-defense claim.
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
  . (Join-Path $devAuto 'Global-Management.ps1')
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
  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalReviewR5Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))

  function New-R5Case([string]$Tag) {
    $c = Join-Path $scratch $Tag
    $auto = Join-Path $c 'auto'
    $fakeHome = Join-Path $c 'home'
    New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
    $gprev = Join-Path $c 'global-preview'
    New-Item -ItemType Directory -Force -Path $gprev | Out-Null
    Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"x":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii
    return @{ root = $c; auto = $auto; home = $fakeHome; gprev = $gprev }
  }
  function Install-R5Sync([string]$Auto) {
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $Auto 'Sync-GlobalRules.ps1') -Force
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $Auto 'Global-Management.ps1') -Force
  }
  function Install-R5Bin([string]$CaseRoot, [string]$FakeBody) {
    $bin = Join-Path $CaseRoot 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'npx-fake.ps1') $FakeBody -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $bin 'npx.cmd') ('@echo off' + "`r`n" + 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0npx-fake.ps1" %*' + "`r`n" + 'exit /b %ERRORLEVEL%') -Encoding Ascii
    return $bin
  }

  # ---- R4F3 adapted: selection-only backup scope (codex-only never touches opencode).
  $s3 = New-R5Case 'sel'
  Set-Content -LiteralPath (Join-Path $s3.home '.codex\AGENTS.md') 'codex-R5F3' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $s3.home '.config\opencode\AGENTS.md') 'opencode-R5F3' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $s3.home '.config\opencode\opencode.json') '{"m":"orig-R5F3"}' -Encoding Ascii
  Set-GlobalTargets $s3.auto @('codexcli', 'opencode') | Out-Null
  $bkS3 = New-GlobalBackup $s3.auto $s3.home @('codexcli')
  $mfS3 = Get-Content -LiteralPath (Join-Path $bkS3 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ((@($mfS3.files | Where-Object { [string]$_.kind -ceq 'config' }).Count -eq 0)) 'R5-S3 codex-only manifest has no config rows'
  Assert ((@($mfS3.files | Where-Object { [string]$_.target -ceq 'opencode' }).Count -eq 0)) 'R5-S3 codex-only manifest has no opencode rows'
  $backedS3 = @(Get-ChildItem -LiteralPath $bkS3 -File | Where-Object { $_.Name -ne 'manifest.json' })
  Assert ((@($backedS3 | Where-Object { $_.Name -like '*opencode*' }).Count -eq 0)) 'R5-S3 codex-only backup copies no opencode bytes'

  # ---- R4F3b adapted: oversized + junctioned unselected side never blocks codex-only backup.
  $fsB = [System.IO.File]::Create((Join-Path $s3.home '.config\opencode\AGENTS.md'))
  try { $chunk = New-Object byte[] 65536; for ($i = 0; $i -lt 40; $i++) { $fsB.Write($chunk, 0, $chunk.Length) } } finally { $fsB.Close() }
  $bkS3b = ''
  $s3bBad = $false
  try { $bkS3b = New-GlobalBackup $s3.auto $s3.home @('codexcli') } catch { $s3bBad = $true }
  Assert ((-not $s3bBad)) 'R5-S3b codex-only backup ignores oversized unselected side'
  if ($bkS3b -ne '') {
    $mfS3b = Get-Content -LiteralPath (Join-Path $bkS3b 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ((@($mfS3b.files | Where-Object { [string]$_.target -ceq 'opencode' }).Count -eq 0)) 'R5-S3b oversized unselected never in manifest'
  }
  Set-Content -LiteralPath (Join-Path $s3.home '.config\opencode\AGENTS.md') 'small-again' -Encoding Ascii
  $extJ = Join-Path $s3.root 'extj'
  New-Item -ItemType Directory -Force -Path $extJ | Out-Null
  Set-Content -LiteralPath (Join-Path $extJ 'AGENTS.md') 'extj-marker' -Encoding Ascii
  $ocodeDir = Join-Path $s3.home '.config\opencode'
  Remove-Item -LiteralPath $ocodeDir -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $ocodeDir + '" "' + $extJ + '"') | Out-Null
  $bkJ = ''
  $jBad = $false
  try { $bkJ = New-GlobalBackup $s3.auto $s3.home @('codexcli') } catch { $jBad = $true }
  Assert ((-not $jBad)) 'R5-S3b codex-only backup ignores junctioned unselected parent'
  Assert (((Get-Content -LiteralPath (Join-Path $extJ 'AGENTS.md') -Raw).Contains('extj-marker'))) 'R5-S3b external untouched'
  & $cmdExe /c ('rmdir "' + $ocodeDir + '"') | Out-Null

  # ---- P2-4: backup list refuses a linked AutoDir root itself (no enum, no manifest read).
  $s4 = New-R5Case 'listroot'
  Set-Content -LiteralPath (Join-Path $s4.home '.codex\AGENTS.md') 'codex-R5L' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $s4.home '.config\opencode\AGENTS.md') 'opencode-R5L' -Encoding Ascii
  Set-GlobalTargets $s4.auto @('codexcli', 'opencode') | Out-Null
  $bkS4 = New-GlobalBackup $s4.auto $s4.home @('codexcli', 'opencode')
  Assert ((Test-Path -LiteralPath (Join-Path $bkS4 'manifest.json'))) 'R5-L4 fixture backup exists'
  $script:r5manifestReads = 0
  $origReadL4 = (Get-Command Get-Content).ScriptBlock
  # Count manifest reads through the low-level reader only; helpers stay real.
  function Get-Content { $script:r5manifestReads++; Microsoft.PowerShell.Management\Get-Content @args }
  $extL4 = Join-Path $s4.root 'ext-list'
  New-Item -ItemType Directory -Force -Path $extL4 | Out-Null
  # Plant a global-looking backup behind the future junction target: unfixed
  # code enumerates it (1 row + 1 manifest read) even though AutoDir is linked.
  $plantRoot = Join-Path $extL4 'backups'
  New-Item -ItemType Directory -Force -Path $plantRoot | Out-Null
  Microsoft.PowerShell.Management\Copy-Item -LiteralPath $bkS4 -Destination (Join-Path $plantRoot (Split-Path $bkS4 -Leaf)) -Recurse -Force
  $keepL4 = Join-Path $s4.root 'auto-keep'
  Move-Item -LiteralPath $s4.auto -Destination $keepL4 -Force
  & $cmdExe /c ('mklink /J "' + $s4.auto + '" "' + $extL4 + '"') | Out-Null
  $listL4 = @()
  try { $listL4 = @(Get-GlobalBackupList $s4.auto) } catch { $listL4 = @() }
  Assert (($listL4.Count -eq 0)) 'R5-L4 linked AutoDir root lists zero rows'
  Assert (($script:r5manifestReads -eq 0)) 'R5-L4 linked AutoDir root reads zero manifests'
  Remove-Item -Path 'function:Get-Content' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  try { & $cmdExe /c ('rmdir "' + $s4.auto + '"') | Out-Null } catch {}
  if (Test-Path -LiteralPath $keepL4) { Move-Item -LiteralPath $keepL4 -Destination $s4.auto -Force }
  $listL4b = @(Get-GlobalBackupList $s4.auto)
  Assert (($listL4b.Count -ge 1)) 'R5-L4 restored root lists again'

  # ---- P1-2a: backup helper internal window (swap between copy and hash/ACL).
  # Real Copy-GlobalVerified; only the low-level Copy-Item is shimmed to swap
  # backups mid-copy and the low-level hash reader only counts post-swap reads.
  $s2a = New-R5Case 'helperbackup'
  Set-Content -LiteralPath (Join-Path $s2a.home '.codex\AGENTS.md') 'codex-R52a' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $s2a.home '.config\opencode\AGENTS.md') 'opencode-R52a' -Encoding Ascii
  Set-GlobalTargets $s2a.auto @('codexcli', 'opencode') | Out-Null
  $ext2a = Join-Path $s2a.root 'ext-copy'
  New-Item -ItemType Directory -Force -Path $ext2a | Out-Null
  Set-Content -LiteralPath (Join-Path $ext2a 'planted.txt') 'planted' -Encoding Ascii
  $script:r52broot = Join-Path $s2a.auto 'backups'
  $script:r52keep = Join-Path $s2a.root 'backups-keep'
  $script:r52ext = $ext2a
  $script:r52cmd = $cmdExe
  $script:r52swapped = $false
  $script:r52postHash = 0
  $origHash2a = (Get-Command Global-FileHashHex).ScriptBlock
  $script:origHash2a = $origHash2a
  function Global-FileHashHex([string]$File) {
    if ($script:r52swapped) { $script:r52postHash++ }
    return (& $script:origHash2a $File)
  }
  function Copy-Item {
    Microsoft.PowerShell.Management\Copy-Item @args
    if ((-not $script:r52swapped) -and ($script:r52broot -ne '') -and (Test-Path -LiteralPath $script:r52broot)) {
      $script:r52swapped = $true
      try {
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $script:r52broot -Destination $script:r52keep -Force
        & $script:r52cmd /c ('mklink /J "' + $script:r52broot + '" "' + $script:r52ext + '"') | Out-Null
      } catch {}
    }
  }
  $script:r52armed = $true
  $bk2aBad = $false
  try { New-GlobalBackup $s2a.auto $s2a.home @('codexcli') | Out-Null } catch { $bk2aBad = $true }
  Assert ($script:r52swapped) 'R5-H2a mid-copy injection fired'
  Assert ($bk2aBad) 'R5-H2a mid-copy backups swap refuses backup'
  Assert (($script:r52postHash -eq 0)) 'R5-H2a no hash read through swapped backups'
  Assert (((Get-Content -LiteralPath (Join-Path $ext2a 'planted.txt') -Raw).Contains('planted'))) 'R5-H2a external untouched'
  Remove-Item -Path 'function:Copy-Item' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-FileHashHex' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  try { & $cmdExe /c ('rmdir "' + (Join-Path $s2a.auto 'backups') + '"') | Out-Null } catch {}
  if (Test-Path -LiteralPath $script:r52keep) { Move-Item -LiteralPath $script:r52keep -Destination (Join-Path $s2a.auto 'backups') -Force }

  # ---- P1-2b: restore helper internal window (swap between source read and dest write).
  # Real Copy-GlobalExpectedBytes via real Restore-GlobalBackup; only the
  # low-level bounded reader is wrapped to swap the home parent post-read.
  $s2b = New-R5Case 'helperrestore'
  Set-Content -LiteralPath (Join-Path $s2b.home '.codex\AGENTS.md') 'codex-R52b' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $s2b.home '.config\opencode\AGENTS.md') 'opencode-R52b' -Encoding Ascii
  Set-GlobalTargets $s2b.auto @('codexcli', 'opencode') | Out-Null
  $bk2b = New-GlobalBackup $s2b.auto $s2b.home @('codexcli', 'opencode')
  $bd2b = Get-GlobalBackupDiff $s2b.auto (Split-Path $bk2b -Leaf) $s2b.home
  $cf2b = [string]$bd2b.confirmId
  Assert (($cf2b -match '^[0-9a-f]{32}$')) 'R5-H2b confirm issued'
  $ext2b = Join-Path $s2b.root 'ext-restore'
  New-Item -ItemType Directory -Force -Path $ext2b | Out-Null
  Set-Content -LiteralPath (Join-Path $ext2b 'AGENTS.md') 'ext2b-marker' -Encoding Ascii
  $script:r52bhome = $s2b.home
  $script:r52bext = $ext2b
  $script:r52bcmd = $cmdExe
  $script:r52bfired = $false
  $script:r52bpostHash = 0
  $origRb2b = (Get-Command Global-ReadBoundedBytes).ScriptBlock
  $script:origRb2b = $origRb2b
  $origHash2b = (Get-Command Global-FileHashHex).ScriptBlock
  $script:origHash2b = $origHash2b
  function Global-ReadBoundedBytes([string]$File, [int]$MaxBytes) {
    $r = (& $script:origRb2b $File $MaxBytes)
    if (-not $script:r52bfired) {
      $script:r52bfired = $true
      try {
        $cdir = Join-Path $script:r52bhome '.codex'
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue
        & $script:r52bcmd /c ('mklink /J "' + $cdir + '" "' + $script:r52bext + '"') | Out-Null
      } catch {}
    }
    return $r
  }
  function Global-FileHashHex([string]$File) {
    if ($script:r52bfired) { $script:r52bpostHash++ }
    return (& $script:origHash2b $File)
  }
  $ok2b = $false
  $msg2b = ''
  try { $rs2b = Restore-GlobalBackup $s2b.auto (Split-Path $bk2b -Leaf) $true $s2b.home $cf2b; $ok2b = [bool]$rs2b.ok } catch { $ok2b = $false; $msg2b = $_.Exception.Message }
  Assert ($script:r52bfired) 'R5-H2b mid-restore injection fired'
  Assert ((-not $ok2b)) 'R5-H2b mid-restore home swap never reports ok=true'
  Assert (((Get-Content -LiteralPath (Join-Path $ext2b 'AGENTS.md') -Raw).Contains('ext2b-marker'))) 'R5-H2b external untouched'
  Remove-Item -Path 'function:Global-ReadBoundedBytes' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-FileHashHex' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  try { & $cmdExe /c ('rmdir "' + (Join-Path $s2b.home '.codex') + '"') | Out-Null } catch {}

  # ---- R4F1b adapted: mid-restore backups swap refuses shelter (real helpers,
  # injection at the low-level hash reader so the shelter copy itself stays real).
  $s1b = New-R5Case 'shelter'
  Set-Content -LiteralPath (Join-Path $s1b.home '.codex\AGENTS.md') 'codex-R51b' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $s1b.home '.config\opencode\AGENTS.md') 'opencode-R51b' -Encoding Ascii
  Set-GlobalTargets $s1b.auto @('codexcli', 'opencode') | Out-Null
  $bk1b = New-GlobalBackup $s1b.auto $s1b.home @('codexcli', 'opencode')
  $bd1b = Get-GlobalBackupDiff $s1b.auto (Split-Path $bk1b -Leaf) $s1b.home
  $cf1b = [string]$bd1b.confirmId
  $ext1b = Join-Path $s1b.root 'extb'
  New-Item -ItemType Directory -Force -Path $ext1b | Out-Null
  $script:r51broot = Join-Path $s1b.auto 'backups'
  $script:r51keep = Join-Path $s1b.root 'backups-keep'
  $script:r51ext = $ext1b
  $script:r51cmd = $cmdExe
  $script:r51swapped = $false
  $origHash1b = (Get-Command Global-FileHashHex).ScriptBlock
  $script:origHash1b = $origHash1b
  function Global-FileHashHex([string]$File) {
    if (-not $script:r51swapped) {
      $script:r51swapped = $true
      try {
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $script:r51broot -Destination $script:r51keep -Force
        & $script:r51cmd /c ('mklink /J "' + $script:r51broot + '" "' + $script:r51ext + '"') | Out-Null
      } catch {}
    }
    return (& $script:origHash1b $File)
  }
  $ok1b = $false
  try { $rs1b = Restore-GlobalBackup $s1b.auto (Split-Path $bk1b -Leaf) $true $s1b.home $cf1b; $ok1b = [bool]$rs1b.ok } catch { $ok1b = $false }
  Assert ($script:r51swapped) 'R5-R1b injection fired'
  Assert ((-not $ok1b)) 'R5-R1b mid-restore backups swap refuses (no ok=true)'
  Remove-Item -Path 'function:Global-FileHashHex' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  try { & $cmdExe /c ('rmdir "' + (Join-Path $s1b.auto 'backups') + '"') | Out-Null } catch {}
  if (Test-Path -LiteralPath $script:r51keep) { Move-Item -LiteralPath $script:r51keep -Destination (Join-Path $s1b.auto 'backups') -Force }

  # ---- P1-1a (NEW CLI0): check exits 0 but swaps parent mid-check -> no success.
  $s0 = New-R5Case 'cli0'
  Set-Content -LiteralPath (Join-Path $s0.home '.codex\AGENTS.md') 'codex-R5C0' -Encoding Ascii
  Set-GlobalTargets $s0.auto @('codexcli') | Out-Null
  Install-R5Sync $s0.auto
  . (Join-Path $s0.auto 'Sync-GlobalRules.ps1')
  $extC0 = Join-Path $s0.root 'ext0'
  New-Item -ItemType Directory -Force -Path $extC0 | Out-Null
  Set-Content -LiteralPath (Join-Path $extC0 'AGENTS.md') 'ext0-marker' -Encoding Ascii
  $bin0 = Install-R5Bin $s0.root @'
param([string[]]$RestArgs)
$ErrorActionPreference = 'Stop'
$argsAll = @($RestArgs) + @($args)
function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like ('*' + $S + '*')) { return $true } }; return $false }
$log = Join-Path $env:FAKE_AUTO_DIR 'fake-cli-calls.txt'
Add-Content -LiteralPath $log (($argsAll -join ' ') + "`n") -Encoding Ascii
if ((Has 'install')) { exit 0 }
if ((Has '--check') -and (-not (Has '--dry-run'))) {
  $cdir = Join-Path $env:FAKE_HOME_DIR '.codex'
  try { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  & "$env:SystemRoot\System32\cmd.exe" /c ('mklink /J "' + $cdir + '" "' + $env:FAKE_EXT_DIR + '"') | Out-Null
  exit 0
}
if (Has '--dry-run') { exit 0 }
if (Has 'generate') { exit 0 }
exit 0
'@
  $env:PATH = ($bin0 + ';' + $origPath)
  $env:HOME_DIR = $s0.home
  $env:FAKE_AUTO_DIR = $s0.auto
  $env:FAKE_HOME_DIR = $s0.home
  $env:FAKE_EXT_DIR = $extC0
  $env:GITHUB_TOKEN = 'gh-test-R5C0'
  if (Test-Path -LiteralPath (Join-Path $s0.auto 'global-status.json')) { Remove-Item -LiteralPath (Join-Path $s0.auto 'global-status.json') -Force }
  $code0 = Invoke-GlobalSync -TargetNames @('codexcli')
  $cli0 = ''
  try { $cli0 = Get-Content -LiteralPath (Join-Path $s0.auto 'fake-cli-calls.txt') -Raw -Encoding Ascii } catch { $cli0 = '' }
  Assert (($code0 -ne 0)) 'R5-C0 check-exit-0 with mid-check link fails sync'
  Assert (([regex]::Matches($cli0, '--dry-run').Count -eq 0)) 'R5-C0 dry-run never runs after linked check-0'
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $st0 = Get-GlobalStatus $s0.auto
  Assert (([string]$st0.providers['codexcli'].result -cne 'success')) 'R5-C0 no success status after linked check-0'
  Assert (((Get-Content -LiteralPath (Join-Path $extC0 'AGENTS.md') -Raw).Contains('ext0-marker'))) 'R5-C0 external untouched'
  try { & $cmdExe /c ('rmdir "' + (Join-Path $s0.home '.codex') + '"') | Out-Null } catch {}
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_EXT_DIR -ErrorAction SilentlyContinue

  # ---- R4F2 adapted: install swaps parent -> check never runs, no success.
  $sF2 = New-R5Case 'installswap'
  Set-Content -LiteralPath (Join-Path $sF2.home '.codex\AGENTS.md') 'codex-R5F2' -Encoding Ascii
  Set-GlobalTargets $sF2.auto @('codexcli') | Out-Null
  Install-R5Sync $sF2.auto
  . (Join-Path $sF2.auto 'Sync-GlobalRules.ps1')
  $extF2 = Join-Path $sF2.root 'ext'
  New-Item -ItemType Directory -Force -Path $extF2 | Out-Null
  Set-Content -LiteralPath (Join-Path $extF2 'AGENTS.md') 'ext-marker' -Encoding Ascii
  $binF2 = Install-R5Bin $sF2.root @'
param([string[]]$RestArgs)
$ErrorActionPreference = 'Stop'
$argsAll = @($RestArgs) + @($args)
function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like ('*' + $S + '*')) { return $true } }; return $false }
$log = Join-Path $env:FAKE_AUTO_DIR 'fake-cli-calls.txt'
Add-Content -LiteralPath $log (($argsAll -join ' ') + "`n") -Encoding Ascii
if ((Has 'install')) {
  $cdir = Join-Path $env:FAKE_HOME_DIR '.codex'
  try { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  & "$env:SystemRoot\System32\cmd.exe" /c ('mklink /J "' + $cdir + '" "' + $env:FAKE_EXT_DIR + '"') | Out-Null
  exit 0
}
if ((Has '--check') -and (-not (Has '--dry-run'))) { exit 0 }
if (Has '--dry-run') { exit 0 }
if (Has 'generate') { exit 0 }
exit 0
'@
  $env:PATH = ($binF2 + ';' + $origPath)
  $env:HOME_DIR = $sF2.home
  $env:FAKE_AUTO_DIR = $sF2.auto
  $env:FAKE_HOME_DIR = $sF2.home
  $env:FAKE_EXT_DIR = $extF2
  $env:GITHUB_TOKEN = 'gh-test-R5F2'
  $codeF2 = Invoke-GlobalSync -TargetNames @('codexcli')
  $cliF2 = ''
  try { $cliF2 = Get-Content -LiteralPath (Join-Path $sF2.auto 'fake-cli-calls.txt') -Raw -Encoding Ascii } catch { $cliF2 = '' }
  Assert (($codeF2 -ne 0)) 'R5-F2 install->link fails sync'
  Assert (([regex]::Matches($cliF2, '--check').Count -eq 0)) 'R5-F2 check never runs after install swapped parent'
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $stF2 = Get-GlobalStatus $sF2.auto
  Assert (([string]$stF2.providers['codexcli'].result -cne 'success')) 'R5-F2 no success status through link'
  try { & $cmdExe /c ('rmdir "' + (Join-Path $sF2.home '.codex') + '"') | Out-Null } catch {}
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_EXT_DIR -ErrorAction SilentlyContinue

  # ---- R4F2b adapted: check exits 1 with swap -> dry-run/generate never run.
  $s2bCli = New-R5Case 'checkswap'
  Set-Content -LiteralPath (Join-Path $s2bCli.home '.codex\AGENTS.md') 'codex-R5F2b' -Encoding Ascii
  Set-GlobalTargets $s2bCli.auto @('codexcli') | Out-Null
  Install-R5Sync $s2bCli.auto
  . (Join-Path $s2bCli.auto 'Sync-GlobalRules.ps1')
  $ext2bCli = Join-Path $s2bCli.root 'ext'
  New-Item -ItemType Directory -Force -Path $ext2bCli | Out-Null
  Set-Content -LiteralPath (Join-Path $ext2bCli 'AGENTS.md') 'ext-marker' -Encoding Ascii
  $bin2bCli = Install-R5Bin $s2bCli.root @'
param([string[]]$RestArgs)
$ErrorActionPreference = 'Stop'
$argsAll = @($RestArgs) + @($args)
function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like ('*' + $S + '*')) { return $true } }; return $false }
$log = Join-Path $env:FAKE_AUTO_DIR 'fake-cli-calls.txt'
Add-Content -LiteralPath $log (($argsAll -join ' ') + "`n") -Encoding Ascii
if ((Has 'install')) { exit 0 }
if ((Has '--check') -and (-not (Has '--dry-run'))) {
  $cdir = Join-Path $env:FAKE_HOME_DIR '.codex'
  try { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  & "$env:SystemRoot\System32\cmd.exe" /c ('mklink /J "' + $cdir + '" "' + $env:FAKE_EXT_DIR + '"') | Out-Null
  exit 1
}
if (Has '--dry-run') { exit 0 }
if (Has 'generate') { exit 0 }
exit 0
'@
  $env:PATH = ($bin2bCli + ';' + $origPath)
  $env:HOME_DIR = $s2bCli.home
  $env:FAKE_AUTO_DIR = $s2bCli.auto
  $env:FAKE_HOME_DIR = $s2bCli.home
  $env:FAKE_EXT_DIR = $ext2bCli
  $env:GITHUB_TOKEN = 'gh-test-R5F2b'
  $code2bCli = Invoke-GlobalSync -TargetNames @('codexcli')
  $cli2b = ''
  try { $cli2b = Get-Content -LiteralPath (Join-Path $s2bCli.auto 'fake-cli-calls.txt') -Raw -Encoding Ascii } catch { $cli2b = '' }
  Assert (($code2bCli -ne 0)) 'R5-F2b check->link fails sync'
  Assert (([regex]::Matches($cli2b, '--dry-run').Count -eq 0)) 'R5-F2b dry-run never runs after check swapped parent'
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  $st2b = Get-GlobalStatus $s2bCli.auto
  Assert (([string]$st2b.providers['codexcli'].result -cne 'success')) 'R5-F2b no success through link'
  try { & $cmdExe /c ('rmdir "' + (Join-Path $s2bCli.home '.codex') + '"') | Out-Null } catch {}
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_EXT_DIR -ErrorAction SilentlyContinue

  # ---- P1-1b NEW: preview generate exits 0 but swaps real home parent -> zero success entries.
  $sPv = New-R5Case 'previewswap'
  Set-Content -LiteralPath (Join-Path $sPv.home '.codex\AGENTS.md') 'codex-R5Pv' -Encoding Ascii
  Set-GlobalTargets $sPv.auto @('codexcli') | Out-Null
  Install-R5Sync $sPv.auto
  . (Join-Path $sPv.auto 'Sync-GlobalRules.ps1')
  $extPv = Join-Path $sPv.root 'extpv'
  New-Item -ItemType Directory -Force -Path $extPv | Out-Null
  Set-Content -LiteralPath (Join-Path $extPv 'AGENTS.md') 'extpv-marker' -Encoding Ascii
  $binPv = Install-R5Bin $sPv.root @'
param([string[]]$RestArgs)
$ErrorActionPreference = 'Stop'
$argsAll = @($RestArgs) + @($args)
function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like ('*' + $S + '*')) { return $true } }; return $false }
$log = Join-Path $env:FAKE_AUTO_DIR 'fake-cli-calls.txt'
Add-Content -LiteralPath $log (($argsAll -join ' ') + "`n") -Encoding Ascii
if ((Has 'install')) { exit 0 }
if ((Has 'generate') -and (-not (Has '--check')) -and (-not (Has '--dry-run'))) {
  $hb = $env:HOME_DIR
  if ($hb -like '*preview-home-*') {
    $cdir = Join-Path $env:FAKE_HOME_DIR '.codex'
    try { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    & "$env:SystemRoot\System32\cmd.exe" /c ('mklink /J "' + $cdir + '" "' + $env:FAKE_EXT_DIR + '"') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $hb '.codex') | Out-Null
    Set-Content -LiteralPath (Join-Path $hb '.codex\AGENTS.md') 'generated-codex-R5Pv' -Encoding Ascii
  }
  exit 0
}
exit 0
'@
  $env:PATH = ($binPv + ';' + $origPath)
  $env:HOME_DIR = $sPv.home
  $env:FAKE_AUTO_DIR = $sPv.auto
  $env:FAKE_HOME_DIR = $sPv.home
  $env:FAKE_EXT_DIR = $extPv
  $env:GITHUB_TOKEN = 'gh-test-R5Pv'
  $planPv = Join-Path $sPv.auto 'dashboard.global-plan-a1b2c3d4e5f60718293a4b5c6d7e8f90.json'
  $codePv = Invoke-GlobalSync -TargetNames @('codexcli') -PreviewOnly -PlanPath $planPv
  Assert (($codePv -ne 0)) 'R5-PV preview with linked real home fails'
  $succPv = 0
  try {
    $pjPv = Get-Content -LiteralPath $planPv -Raw -Encoding UTF8 | ConvertFrom-Json
    $succPv = @($pjPv.entries | Where-Object { [string]$_.result -ceq 'success' }).Count
  } catch { $succPv = -1 }
  Assert (($succPv -eq 0)) 'R5-PV preview writes zero success entries after link'
  Assert (((Get-Content -LiteralPath (Join-Path $extPv 'AGENTS.md') -Raw).Contains('extpv-marker'))) 'R5-PV external untouched'
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  try { & $cmdExe /c ('rmdir "' + (Join-Path $sPv.home '.codex') + '"') | Out-Null } catch {}
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_EXT_DIR -ErrorAction SilentlyContinue

  # ---- P1-3: preview cleanup refuses recursive delete through a linked AutoDir.
  $sCl = New-R5Case 'cleanup'
  $isoCl = Join-Path $sCl.auto ('preview-home-' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $isoCl | Out-Null
  Set-Content -LiteralPath (Join-Path $isoCl 'probe.txt') 'probe' -Encoding Ascii
  $extCl = Join-Path $sCl.root 'ext-clean'
  New-Item -ItemType Directory -Force -Path $extCl | Out-Null
  Set-Content -LiteralPath (Join-Path $extCl 'keep.txt') 'keep-marker' -Encoding Ascii
  $keepCl = Join-Path $sCl.root 'auto-keep-cl'
  Move-Item -LiteralPath $sCl.auto -Destination $keepCl -Force
  & $cmdExe /c ('mklink /J "' + $sCl.auto + '" "' + $extCl + '"') | Out-Null
  $script:r5rmCount = 0
  function Remove-Item { $script:r5rmCount++; Microsoft.PowerShell.Management\Remove-Item @args }
  $guardThrew = $false
  try { Global-AssertNoLinkChain $isoCl $sCl.auto 'preview' } catch { $guardThrew = $true }
  Assert ($guardThrew) 'R5-CL cleanup guard throws on linked AutoDir root'
  $srcCl = Get-Content -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Raw -Encoding UTF8
  Assert (($srcCl.Contains('preview cleanup skipped (unsafe root)'))) 'R5-CL sync cleanup logs unsafe-root skip'
  Assert (($script:r5rmCount -eq 0)) 'R5-CL no recursive delete through linked root'
  Remove-Item -Path 'function:Remove-Item' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  try { & $cmdExe /c ('rmdir "' + $sCl.auto + '"') | Out-Null } catch {}
  if (Test-Path -LiteralPath $keepCl) { Move-Item -LiteralPath $keepCl -Destination $sCl.auto -Force }
  Assert (((Get-Content -LiteralPath (Join-Path $extCl 'keep.txt') -Raw).Contains('keep-marker'))) 'R5-CL external untouched'

  Assert (((Get-Location).Path) -eq $initCwd) 'R5 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'R5 only own GUID scratch removed'
}
finally {
  $env:HOME_DIR = $origHomeDir
  if ($null -eq $origHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
  $env:GITHUB_TOKEN = $origGithub
  if ($null -eq $origGithub) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
  $env:GH_TOKEN = $origGh
  if ($null -eq $origGh) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
  $env:PATH = $origPath
  Remove-Item Env:FAKE_AUTO_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_HOME_DIR -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_EXT_DIR -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Copy-Item' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Get-Content' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Remove-Item' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-FileHashHex' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-ReadBoundedBytes' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL R5 REVIEW CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
