# Test-GlobalReviewRound3 - round3 findings F1-F5 (RED then GREEN).
# Scratch-only. Never touches real home, tasks, registry.
# Scheduler cmdlets shadowed at script scope. Fault injection on actual
# functions (call counts, file mutation, fake CLI), never string-presence.
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
function Write-FakeNpx([string]$Path, [string[]]$Lines) {
  Set-Content -LiteralPath $Path -Value ($Lines -join "`r`n") -Encoding Ascii
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
  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalReviewR3Test'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  $fakeHome = Join-Path $scratch 'home'
  New-Item -ItemType Directory -Force -Path $auto, (Join-Path $fakeHome '.codex'), (Join-Path $fakeHome '.config\opencode') | Out-Null
  $gprev = Join-Path $scratch 'global-preview'
  New-Item -ItemType Directory -Force -Path $gprev | Out-Null
  Set-Content -LiteralPath (Join-Path $gprev 'rulesync.lock') '{"lockfileVersion":1,"sources":{"x":{"resolvedRef":"0123456789abcdef0123456789abcdef01234567"}}}' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R3' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R3' -Encoding Ascii
  Set-GlobalTargets $auto @('codexcli', 'opencode') | Out-Null

  # F1: manifest mutation BETWEEN confirm check and restore steps must not add delete.
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-keep-R3F1' -Encoding Ascii
  $bk1 = New-GlobalBackup $auto $fakeHome @('codexcli')
  $id1 = Split-Path $bk1 -Leaf
  $bd1 = Get-GlobalBackupDiff $auto $id1 $fakeHome
  $cf1 = [string]$bd1.confirmId
  Assert (($cf1 -match '^[0-9a-f]{32}$')) 'R3-F1 diff issues confirm'
  $origGetManifest = (Get-Command Get-GlobalBackupManifest).ScriptBlock
  $script:r3f1calls = 0
  $script:r3f1bk = $bk1
  function Get-GlobalBackupManifest([string]$AutoDir, [string]$BackupId) {
    $script:r3f1calls++
    if ($script:r3f1calls -eq 2) {
      $mfP = Join-Path $script:r3f1bk 'manifest.json'
      try {
        $m = Get-Content -LiteralPath $mfP -Raw -Encoding UTF8 | ConvertFrom-Json
        $m.files += [pscustomobject]@{ target = 'opencode'; kind = 'agents'; rel = ''; present = $false; hash = '' }
        $m | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $mfP -Encoding UTF8
      } catch {}
    }
    return (& $script:origGetManifest $AutoDir $BackupId)
  }
  $script:origGetManifest = $origGetManifest
  $f1kept = $false
  try {
    Restore-GlobalBackup $auto $id1 $true $fakeHome $cf1 | Out-Null
  } catch {}
  try {
    if (Test-Path -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') -PathType Leaf) {
      $f1kept = ((Get-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') -Raw -Encoding UTF8).Contains('opencode-keep-R3F1'))
    } else { $f1kept = $false }
  } catch { $f1kept = $false }
  Assert ($f1kept) 'R3-F1 in-flight added delete never applied (opencode kept)'
  Remove-Item -Path 'function:Get-GlobalBackupManifest' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }

  # F2: rollback must re-inspect parent chains before each copy/delete.
  if (-not (Test-Path -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -PathType Leaf)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.codex') | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R3' -Encoding Ascii
  }
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R3F2' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R3F2' -Encoding Ascii
  $bk2 = New-GlobalBackup $auto $fakeHome @('codexcli', 'opencode')
  $id2 = Split-Path $bk2 -Leaf
  $bd2 = Get-GlobalBackupDiff $auto $id2 $fakeHome
  $cf2 = [string]$bd2.confirmId
  $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $ext2 = Join-Path $scratch 'ext2'
  New-Item -ItemType Directory -Force -Path $ext2 | Out-Null
  Set-Content -LiteralPath (Join-Path $ext2 'AGENTS.md') 'ext2-marker' -Encoding Ascii
  $origExp2 = (Get-Command Copy-GlobalExpectedBytes).ScriptBlock
  $script:origExp2 = $origExp2
  $script:r3f2home = $fakeHome
  $script:r3f2ext = $ext2
  $script:r3f2cmd = $cmdExe
  function Copy-GlobalExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What, [string]$SrcRoot = "", [string]$DstRoot = "") {
    if ([string]$Dst -like '*opencode\AGENTS.md') {
      $cdir = Join-Path $script:r3f2home '.codex'
      try { Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
      try { & $script:r3f2cmd /c ('mklink /J "' + $cdir + '" "' + $script:r3f2ext + '"') | Out-Null } catch {}
      throw 'injected-opencode-copy-fail-R3F2'
    }
    if (($SrcRoot -ne '') -or ($DstRoot -ne '')) { & $script:origExp2 $Src $Dst $ExpectedHash $What $SrcRoot $DstRoot }
    else { & $script:origExp2 $Src $Dst $ExpectedHash $What }
  }
  $rbFailed = $false
  $rbMsg = ''
  try { Restore-GlobalBackup $auto $id2 $true $fakeHome $cf2 | Out-Null } catch { $rbMsg = $_.Exception.Message; $rbFailed = $true }
  Assert ($rbFailed) 'R3-F2 injected failure aborts restore'
  $noThroughWrite = ((Get-Content -LiteralPath (Join-Path $ext2 'AGENTS.md') -Raw -Encoding UTF8).Contains('ext2-marker'))
  Assert ($noThroughWrite) 'R3-F2 rollback never writes through linked parent'
  $maki = ([char]0x5DFB).ToString()
  Assert (($rbMsg.Contains($maki))) 'R3-F2 rollback failure honestly reported'
  try { & $cmdExe /c ('rmdir "' + (Join-Path $fakeHome '.codex') + '"') | Out-Null } catch {}
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.codex') | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R3F2-restored' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R3F2' -Encoding Ascii
  Remove-Item -Path 'function:Copy-GlobalExpectedBytes' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }

  # F3/F4/F5 need real Sync-GlobalRules via fake CLI shims (scratch auto copy
  # so AutoDir/lock/status all stay inside scratch).
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  . (Join-Path $auto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  . (Join-Path $auto 'Sync-GlobalRules.ps1')
  $bin = Join-Path $scratch 'bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  Write-FakeNpx (Join-Path $bin 'npx-fake-f3.ps1') @(
    'param([string[]]$RestArgs)',
    '$ErrorActionPreference = ''Stop''',
    '$argsAll = @($RestArgs) + @($args)',
    'function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like (''*'' + $S + ''*'')) { return $true } }; return $false }',
    '$log = Join-Path $env:FAKE_AUTO_DIR ''fake-cli-calls.txt''',
    'Add-Content -LiteralPath $log (($argsAll -join '' '') + "`n") -Encoding Ascii',
    'if ((Has ''install'')) { exit 0 }',
    'if ((Has ''--check'') -and (-not (Has ''--dry-run''))) { exit 0 }',
    'if (Has ''--dry-run'') { exit 0 }',
    'if (Has ''generate'') { exit 0 }',
    'exit 0'
  )
  $npxCmd = '@echo off' + "`r`n" + 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0npx-fake-f3.ps1" %*' + "`r`n" + 'exit /b %ERRORLEVEL%'
  Set-Content -LiteralPath (Join-Path $bin 'npx.cmd') -Value $npxCmd -Encoding Ascii
  $env:PATH = ($bin + ';' + $origPath)

  # F3: normal sync must validate selected home parents BEFORE any CLI check.
  $codexDir3 = Join-Path $fakeHome '.codex'
  $keep3 = Get-Content -LiteralPath (Join-Path $codexDir3 'AGENTS.md') -Raw -Encoding UTF8
  $ext3 = Join-Path $scratch 'ext3'
  New-Item -ItemType Directory -Force -Path $ext3 | Out-Null
  Set-Content -LiteralPath (Join-Path $ext3 'AGENTS.md') 'ext3-marker' -Encoding Ascii
  Remove-Item -LiteralPath $codexDir3 -Recurse -Force
  & $cmdExe /c ('mklink /J "' + $codexDir3 + '" "' + $ext3 + '"') | Out-Null
  Assert ((Get-Item -LiteralPath $codexDir3 -Force).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) 'R3-F3 junction fixture ready'
  $env:HOME_DIR = $fakeHome
  $env:FAKE_AUTO_DIR = $auto
  $env:GITHUB_TOKEN = 'gh-test-fake-cli-token-R3F3'
  if (Test-Path -LiteralPath (Join-Path $auto 'fake-cli-calls.txt')) { Remove-Item -LiteralPath (Join-Path $auto 'fake-cli-calls.txt') -Force }
  if (Test-Path -LiteralPath (Join-Path $auto 'global-status.json')) { Remove-Item -LiteralPath (Join-Path $auto 'global-status.json') -Force }
  $code3 = Invoke-GlobalSync -TargetNames @('codexcli')
  $cliCalls = ''
  try { $cliCalls = Get-Content -LiteralPath (Join-Path $auto 'fake-cli-calls.txt') -Raw -Encoding Ascii } catch { $cliCalls = '' }
  $noCheckBeforeValidation = (-not $cliCalls.Contains('--check'))
  Assert (($code3 -ne 0)) 'R3-F3 junctioned parent fails sync (no false nochange success)'
  Assert ($noCheckBeforeValidation) 'R3-F3 CLI check never runs before parent validation'
  $st3 = Get-GlobalStatus $auto
  Assert (([string]$st3.providers['codexcli'].result -cne 'success')) 'R3-F3 no success status recorded through link'
  Assert (((Get-Content -LiteralPath (Join-Path $ext3 'AGENTS.md') -Raw).Contains('ext3-marker'))) 'R3-F3 external dir untouched'
  & $cmdExe /c ('rmdir "' + $codexDir3 + '"') | Out-Null
  New-Item -ItemType Directory -Force -Path $codexDir3 | Out-Null
  Set-Content -LiteralPath (Join-Path $codexDir3 'AGENTS.md') $keep3 -Encoding UTF8

  # F4: preview single-read (display bytes == hash bytes), no reopen hash.
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'current-A-R3F4' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R3F4' -Encoding Ascii
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  Write-FakeNpx (Join-Path $bin 'npx-fake-f3.ps1') @(
    'param([string[]]$RestArgs)',
    '$ErrorActionPreference = ''Stop''',
    '$argsAll = @($RestArgs) + @($args)',
    'function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like (''*'' + $S + ''*'')) { return $true } }; return $false }',
    'if ((Has ''install'')) { exit 0 }',
    'if ((Has ''--check'') -and (-not (Has ''--dry-run''))) { exit 1 }',
    'if (Has ''--dry-run'') { exit 0 }',
    'if (Has ''generate'') {',
    '  $hb = $env:HOME_DIR',
    '  New-Item -ItemType Directory -Force -Path (Join-Path $hb ''.codex''), (Join-Path $hb ''.config\opencode'') | Out-Null',
    '  Set-Content -LiteralPath (Join-Path $hb ''.codex\AGENTS.md'') ''generated-R3F4'' -Encoding Ascii',
    '  Set-Content -LiteralPath (Join-Path $hb ''.config\opencode\AGENTS.md'') ''generated-opencode-R3F4'' -Encoding Ascii',
    '  exit 0',
    '}',
    'exit 0'
  )
  . (Join-Path $auto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  . (Join-Path $auto 'Sync-GlobalRules.ps1')
  $origRB4b = (Get-Command Global-ReadBoundedBytes).ScriptBlock
  $script:origRB4 = $origRB4b
  $script:r3f4mutated = $false
  function Global-ReadBoundedBytes([string]$File, [int]$MaxBytes) {
    $r = (& $script:origRB4 $File $MaxBytes)
    if ((-not $script:r3f4mutated) -and ([string]$File -like '*.codex\AGENTS.md')) {
      try {
        $t0 = [System.Text.Encoding]::UTF8.GetString([byte[]]$r.bytes)
        if ($t0.Contains('current-A-R3F4')) {
          [System.IO.File]::WriteAllText($File, 'current-B-R3F4-after-read')
          $script:r3f4mutated = $true
        }
      } catch {}
    }
    return $r
  }
  $origFHH4b = (Get-Command Global-FileHashHex).ScriptBlock
  $script:origFHH4 = $origFHH4b
  $script:r3f4fileHashCalls = 0
  function Global-FileHashHex([string]$File) {
    if ([string]$File -like '*.codex\AGENTS.md') { $script:r3f4fileHashCalls++ }
    return (& $script:origFHH4 $File)
  }
  $env:HOME_DIR = $fakeHome
  $env:FAKE_AUTO_DIR = $auto
  $env:GITHUB_TOKEN = 'gh-test-fake-cli-token-R3F4'
  $plan4 = Join-Path $auto 'dashboard.global-plan-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json'
  if (Test-Path -LiteralPath $plan4) { Remove-Item -LiteralPath $plan4 -Force }
  $code4 = Invoke-GlobalSync -PreviewOnly -PlanPath $plan4 -TargetNames @('codexcli')
  Assert (($script:r3f4mutated -eq $true)) 'R3-F4 race fixture triggered (A to B between read and hash)'
  $pl4 = Get-Content -LiteralPath $plan4 -Raw -Encoding UTF8 | ConvertFrom-Json
  $en4 = @($pl4.entries | Where-Object { [string]$_.target -ceq 'codexcli' })[0]
  $txt4 = [string]$en4.currentText
  $h4 = [string]$en4.currentHash
  $reHash4 = ((([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($txt4))) | ForEach-Object { $_.ToString('x2') }) -join '')
  $expB = ((([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes('current-B-R3F4-after-read'))) | ForEach-Object { $_.ToString('x2') }) -join '')
  Assert (($txt4.Contains('current-A-R3F4'))) 'R3-F4 display shows A bytes'
  Assert ((($h4 -eq $reHash4) -and ($h4 -ne $expB))) 'R3-F4 approval hash from SAME displayed A bytes'
  Assert (($script:r3f4fileHashCalls -eq 0)) 'R3-F4 no reopen hash for preview current'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R3' -Encoding Ascii
  Remove-Item -Path 'function:Global-ReadBoundedBytes' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-FileHashHex' -Force -ErrorAction SilentlyContinue
  . (Join-Path $devAuto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  . (Join-Path $devAuto 'Sync-GlobalRules.ps1')

  # F5: overlarge aggregate JSON must publish small failed plan, never success.
  $qbig = (New-Object string([char]34, 500000))
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') -Value $qbig -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') -Value $qbig -Encoding Ascii
  Write-FakeNpx (Join-Path $bin 'npx-fake-f3.ps1') @(
    'param([string[]]$RestArgs)',
    '$ErrorActionPreference = ''Stop''',
    '$argsAll = @($RestArgs) + @($args)',
    'function Has([string]$S) { foreach ($a in $argsAll) { if ([string]$a -like (''*'' + $S + ''*'')) { return $true } }; return $false }',
    'if ((Has ''install'')) { exit 0 }',
    'if ((Has ''--check'') -and (-not (Has ''--dry-run''))) { exit 1 }',
    'if (Has ''--dry-run'') { exit 0 }',
    'if (Has ''generate'') {',
    '  $hb = $env:HOME_DIR',
    '  New-Item -ItemType Directory -Force -Path (Join-Path $hb ''.codex''), (Join-Path $hb ''.config\opencode'') | Out-Null',
    '  $g = (New-Object string([char]34, 200000))',
    '  Set-Content -LiteralPath (Join-Path $hb ''.codex\AGENTS.md'') -Value $g -Encoding Ascii',
    '  Set-Content -LiteralPath (Join-Path $hb ''.config\opencode\AGENTS.md'') -Value $g -Encoding Ascii',
    '  exit 0',
    '}',
    'exit 0'
  )
  Copy-Item -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Destination (Join-Path $auto 'Sync-GlobalRules.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $devAuto 'Global-Management.ps1') -Destination (Join-Path $auto 'Global-Management.ps1') -Force
  . (Join-Path $auto 'Global-Management.ps1')
  function Disable-ScheduledTask { param([string]$TaskName) }
  function Enable-ScheduledTask { param([string]$TaskName) }
  . (Join-Path $auto 'Sync-GlobalRules.ps1')
  $env:HOME_DIR = $fakeHome
  $env:FAKE_AUTO_DIR = $auto
  $env:GITHUB_TOKEN = 'gh-test-fake-cli-token-R3F5'
  $plan5 = Join-Path $auto 'dashboard.global-plan-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json'
  if (Test-Path -LiteralPath $plan5) { Remove-Item -LiteralPath $plan5 -Force }
  $code5 = Invoke-GlobalSync -PreviewOnly -PlanPath $plan5 -TargetNames @('codexcli', 'opencode')
  Assert (($code5 -ne 0)) 'R3-F5 overlarge aggregate preview fails (never success)'
  $len5 = (Get-Item -LiteralPath $plan5 -Force).Length
  Assert (($len5 -le 2097152)) 'R3-F5 published plan fits 2MiB fetch limit'
  $pl5 = Get-Content -LiteralPath $plan5 -Raw -Encoding UTF8 | ConvertFrom-Json
  $succ5 = @($pl5.entries | Where-Object { [string]$_.result -ceq 'success' }).Count
  Assert (($succ5 -eq 0)) 'R3-F5 overlarge entries all failed'
  $canFetch5 = $true
  try { Assert-GlobalPlanFileSize $plan5 } catch { $canFetch5 = $false }
  Assert ($canFetch5) 'R3-F5 published failed plan consumable by API gate'
  Set-Content -LiteralPath (Join-Path $fakeHome '.codex\AGENTS.md') 'codex-cur-R3' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $fakeHome '.config\opencode\AGENTS.md') 'opencode-cur-R3' -Encoding Ascii

  Assert (((Get-Location).Path) -eq $initCwd) 'R3 cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-ContainedLocal $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'R3 only own GUID scratch removed'
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
  Remove-Item -Path 'function:Copy-GlobalExpectedBytes' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Get-GlobalBackupManifest' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-ReadBoundedBytes' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Global-FileHashHex' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Get-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Disable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Remove-Item -Path 'function:Enable-ScheduledTask' -Force -ErrorAction SilentlyContinue
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL R3 REVIEW CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
