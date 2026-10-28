# Test-ExtensionRecovery.ps1 - fault-injected apply/restore recovery checks.
# Scratch-only: every home/auto path is created under the system temp folder.
$ErrorActionPreference = 'Stop'
$script:failures = @()
$script:utf8 = New-Object System.Text.UTF8Encoding($false)
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Assert-Contains([string]$Text, [string]$Needle, [string]$Name) {
  Assert ($Text.Contains($Needle)) $Name
}
function Assert-ThrowsWith([scriptblock]$Block, [string]$Name) {
  try {
    & $Block | Out-Null
    Assert $false $Name
    return ''
  } catch {
    Assert $true $Name
    return $_.Exception.Message
  }
}
function Write-TextFile([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, $script:utf8)
}
function Read-TextFile([string]$Path) {
  return [System.IO.File]::ReadAllText($Path)
}
function Read-FileBytes([string]$Path) {
  return [System.IO.File]::ReadAllBytes($Path)
}
function Get-TextHash([string]$Text) {
  return (Ext-HashBytes ($script:utf8.GetBytes($Text)))
}

$devAuto = Split-Path -Parent $PSScriptRoot
. (Join-Path $devAuto 'Extension-Management.ps1')

# Replace the atomic writer with a controllable wrapper. The real writer is
# kept as a separate function so ordering and failure injection stay explicit.
$script:realWriter = (Get-Item Function:\Ext-WriteAtomic).Definition
Set-Item Function:\Ext-WriteAtomicReal -Value ([scriptblock]::Create($script:realWriter))
# The folder-creation race tests temporarily replace the ownership creator.
$script:realCreateOwned = (Get-Item Function:\Ext-CreateOwnedDirectory).Definition
$script:inject = @{}
$script:writeCounts = @{}
$script:writeAttempts = New-Object System.Collections.ArrayList
$script:onAfterWrite = $null
$script:onStagedWrite = $null
function Reset-Injection {
  $script:inject = @{}
  $script:writeCounts = @{}
  $script:writeAttempts = New-Object System.Collections.ArrayList
  $script:onAfterWrite = $null
  $script:onStagedWrite = $null
}
function Ext-WriteAtomic([string]$File, [byte[]]$Bytes, [string]$Root) {
  $key = Ext-NormPath $File
  $script:writeAttempts.Add($key) | Out-Null
  if (-not $script:writeCounts.ContainsKey($key)) { $script:writeCounts[$key] = 0 }
  $script:writeCounts[$key] = [int]$script:writeCounts[$key] + 1
  $n = [int]$script:writeCounts[$key]
  $inj = $script:inject[$key]
  if (($null -ne $inj) -and ($n -eq [int]$inj.at)) {
    if ([string]$inj.mode -eq 'before') { throw 'injected write failure (before)' }
    if ([string]$inj.mode -eq 'after') {
      Ext-WriteAtomicReal $File $Bytes $Root
      if ($null -ne $script:onAfterWrite) { & $script:onAfterWrite }
      throw 'injected write failure (after)'
    }
  }
  Ext-WriteAtomicReal $File $Bytes $Root
  if (($null -ne $script:onStagedWrite) -and ($key.Contains('.ext-new-'))) { & $script:onStagedWrite }
}

$testBase = Join-Path ([System.IO.Path]::GetTempPath()) ('ExtRecoveryTest-' + [System.Guid]::NewGuid().ToString('N'))
function New-Fixture([string]$Name) {
  $root = Join-Path $testBase $Name
  $homeDir = Join-Path $root 'home'
  $autoDir = Join-Path $root 'auto'
  New-Item -ItemType Directory -Force -Path (Join-Path $homeDir '.codex') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $homeDir '.config\opencode') | Out-Null
  New-Item -ItemType Directory -Force -Path $autoDir | Out-Null
  $opencode = Join-Path $homeDir '.config\opencode\opencode.json'
  $codex = Join-Path $homeDir '.codex\config.toml'
  Write-TextFile $opencode '{"mcp":{}}'
  Write-TextFile $codex "[mcp_servers.keep]`ncommand = `"npx keep`"`n"
  return @{ home = (Ext-NormPath $homeDir); auto = (Ext-NormPath $autoDir); opencode = (Ext-NormPath $opencode); codex = (Ext-NormPath $codex) }
}
function New-McpPreview($Fx, [string]$Name) {
  $req = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('opencode', 'codex'); name = $Name; transport = 'stdio'; command = 'npx'; args = @(); url = ''; envLines = ''; headerLines = '' }
  return (New-ExtensionPreview $Fx.auto $Fx.home $req '')
}
function New-SkillPreview($Fx, [string]$Name) {
  $req = [pscustomobject]@{ kind = 'skill'; action = 'add'; providers = @('codex'); name = $Name; description = 'desc'; body = 'body' }
  return (New-ExtensionPreview $Fx.auto $Fx.home $req '')
}
function Get-StoredEntry($Fx, $Pv, [string]$Path) {
  $stored = $script:ExtensionPreviews[$Pv.previewId]
  return @($stored.entries | Where-Object { [string]$_.path -ieq $Path })[0]
}
function Get-EntryOrder($Pv) {
  $stored = $script:ExtensionPreviews[$Pv.previewId]
  return @($stored.entries | ForEach-Object { [string]$_.path })
}
function Get-AttemptSequence {
  return (@($script:writeAttempts) -join '|')
}

try {
  # R1: a post-write verification failure still restores the target that was
  # just written. The expected hash is corrupted after the preview is stored,
  # so only the registered recovery record can identify our bytes.
  $fx = New-Fixture 'verify-failure'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  Assert ([bool]$pv.ok -and [string]$pv.previewId -ne '') 'R1 preview created'
  Assert (@($script:ExtensionPreviews[$pv.previewId].entries).Count -eq 2) 'R1 both targets planned'
  $order = Get-EntryOrder $pv
  $codexEntry = Get-StoredEntry $fx $pv $fx.codex
  $codexEntry.afterHash = Get-TextHash 'forced-mismatch'
  $origOpen = Read-FileBytes $fx.opencode
  $origCodex = Read-FileBytes $fx.codex
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'R1 apply fails on post-write verification'
  Assert-Contains $msg '書込み後の検証に失敗しました' 'R1 reports the verification failure'
  Assert-Contains $msg '自動復旧しました' 'R1 reports a complete recovery'
  Assert ((Ext-HashFile $fx.opencode) -ceq (Ext-HashBytes $origOpen)) 'R1 first target restored'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R1 failed-write target restored'
  $rev = @($order)
  [array]::Reverse($rev)
  $expected = @($order) + @($rev)
  Assert ((Get-AttemptSequence) -ceq ($expected -join '|')) 'R1 forward then reverse recovery order'

  # R2: an exception after a successful write triggers recovery of that target.
  $fx = New-Fixture 'after-write'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  $order = Get-EntryOrder $pv
  $origOpen = Read-FileBytes $fx.opencode
  $origCodex = Read-FileBytes $fx.codex
  $script:inject[$fx.codex] = @{ mode = 'after'; at = 1 }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'R2 apply fails after writing the second target'
  Assert-Contains $msg 'injected write failure (after)' 'R2 reports the injected failure'
  Assert-Contains $msg '自動復旧しました' 'R2 reports a complete recovery'
  Assert ((Ext-HashFile $fx.opencode) -ceq (Ext-HashBytes $origOpen)) 'R2 first target restored'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R2 written target restored'
  $rev = @($order)
  [array]::Reverse($rev)
  Assert ((Get-AttemptSequence) -ceq ((@($order) + @($rev)) -join '|')) 'R2 recovery attempted for both targets'

  # R3: a failure before the write of the current target still restores the
  # earlier target and leaves the unwritten target in its original state.
  $fx = New-Fixture 'before-write'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  $order = Get-EntryOrder $pv
  $origOpen = Read-FileBytes $fx.opencode
  $origCodex = Read-FileBytes $fx.codex
  $script:inject[$fx.codex] = @{ mode = 'before'; at = 1 }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'R3 apply fails before writing the second target'
  Assert-Contains $msg 'injected write failure (before)' 'R3 reports the injected failure'
  Assert-Contains $msg '自動復旧しました' 'R3 reports a complete recovery'
  Assert ((Ext-HashFile $fx.opencode) -ceq (Ext-HashBytes $origOpen)) 'R3 first target restored'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R3 unwritten target unchanged'
  $expected = @($order[0], $order[1], $order[0])
  Assert ((Get-AttemptSequence) -ceq ($expected -join '|')) 'R3 recovery continues after the failed write'

  # R4: a failed recovery is reported as a failure, not success, and the
  # remaining recovery attempts are still made.
  $fx = New-Fixture 'recovery-failure'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  $order = Get-EntryOrder $pv
  $origCodex = Read-FileBytes $fx.codex
  $script:inject[$fx.codex] = @{ mode = 'after'; at = 1 }
  $script:inject[$fx.opencode] = @{ mode = 'before'; at = 2 }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'R4 apply fails and recovery partly fails'
  Assert-Contains $msg '復旧失敗' 'R4 reports the failed recovery'
  Assert-Contains $msg 'injected write failure (after)' 'R4 keeps the original failure detail'
  Assert-Contains $msg $fx.opencode 'R4 names the unrecovered target'
  Assert (-not $msg.Contains('自動復旧しました')) 'R4 does not claim a complete recovery'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R4 recoverable target restored'
  Assert ((Read-TextFile $fx.opencode).Contains('recovsrv')) 'R4 unrecovered target keeps the applied state'
  $expected = @($order[0], $order[1], $order[1], $order[0])
  Assert ((Get-AttemptSequence) -ceq ($expected -join '|')) 'R4 remaining recovery attempt still executed'

  # R5: recovery does not overwrite a file that changed externally after our
  # write, and reports that target as failed.
  $fx = New-Fixture 'external-change'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  $order = Get-EntryOrder $pv
  $origCodex = Read-FileBytes $fx.codex
  $externalPath = $fx.opencode
  $script:onAfterWrite = { [System.IO.File]::WriteAllText($externalPath, 'EXTERNAL', $script:utf8) }
  $script:inject[$fx.codex] = @{ mode = 'after'; at = 1 }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'R5 apply fails after writing the second target'
  Assert-Contains $msg '復旧失敗' 'R5 reports the failed recovery'
  Assert-Contains $msg $fx.opencode 'R5 names the externally changed target'
  Assert ((Read-TextFile $fx.opencode) -ceq 'EXTERNAL') 'R5 external change is not overwritten'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R5 independent target restored'

  # R6: a multi-target change is rejected before any write when one target
  # changed after the preview.
  $fx = New-Fixture 'pre-validation'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  $origOpen = Read-FileBytes $fx.opencode
  Write-TextFile $fx.codex "[mcp_servers.keep]`ncommand = `"npx keep`"`n# changed`n"
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'R6 apply rejects a stale multi-target preview'
  Assert-Contains $msg 'プレビュー後にファイルが変化しました' 'R6 reports the stale target'
  Assert (@($script:writeAttempts).Count -eq 0) 'R6 no target is written before validation completes'
  Assert ((Ext-HashFile $fx.opencode) -ceq (Ext-HashBytes $origOpen)) 'R6 first target untouched'
  Assert ((Read-TextFile $fx.codex).Contains('# changed')) 'R6 externally changed target untouched'

  # R7: restore resumes an interrupted apply, restoring an applied target and
  # treating a never-applied target as already in its target state.
  $fx = New-Fixture 'interrupted-apply'
  Reset-Injection
  $pv = New-McpPreview $fx 'recovsrv'
  $origOpen = Read-FileBytes $fx.opencode
  $origCodex = Read-FileBytes $fx.codex
  $apply = Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false
  Assert ([bool]$apply.ok) 'R7 apply ok'
  [System.IO.File]::WriteAllBytes($fx.codex, $origCodex)
  $restore = Restore-ExtensionBackup $fx.auto $fx.home $apply.backupId $true
  Assert ([bool]$restore.ok) 'R7 interrupted apply is restorable'
  Assert ((Ext-HashFile $fx.opencode) -ceq (Ext-HashBytes $origOpen)) 'R7 applied target restored'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R7 never-applied target left in target state'
  Assert (@($restore.restored).Count -eq 2) 'R7 both targets reported as restored'
  $again = Restore-ExtensionBackup $fx.auto $fx.home $apply.backupId $true
  Assert ([bool]$again.ok) 'R7 restoring an already-restored backup is idempotent'
  Assert ((Ext-HashFile $fx.opencode) -ceq (Ext-HashBytes $origOpen)) 'R7 idempotent restore keeps the first target'
  Assert ((Ext-HashFile $fx.codex) -ceq (Ext-HashBytes $origCodex)) 'R7 idempotent restore keeps the second target'

  # R8: restore continues with independent targets after a target-specific
  # validation failure, and never overwrites an externally changed file.
  $fx = New-Fixture 'restore-mixed'
  Reset-Injection
  $homeDir = $fx.home
  $aPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\a.json')
  $bPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\b.json')
  $cPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\c.json')
  $dPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\d.json')
  $ePath = Ext-NormPath (Join-Path $homeDir '.config\opencode\e.json')
  $beforeA = 'A-before'; $afterA = 'A-after'
  $beforeB = 'B-before'; $afterB = 'B-after'
  $beforeC = 'C-before'; $afterC = 'C-after'
  $afterD = 'D-after'
  $afterE = 'E-after'
  Write-TextFile $aPath $beforeA
  Write-TextFile $bPath $beforeB
  Write-TextFile $cPath $beforeC
  $entries = @(
    @{ provider = 'opencode'; path = $aPath; beforeExists = $true; beforeHash = (Get-TextHash $beforeA); afterHash = (Get-TextHash $afterA); kind = 'mcp'; action = 'write'; dirPath = '' },
    @{ provider = 'opencode'; path = $bPath; beforeExists = $true; beforeHash = (Get-TextHash $beforeB); afterHash = (Get-TextHash $afterB); kind = 'mcp'; action = 'write'; dirPath = '' },
    @{ provider = 'opencode'; path = $cPath; beforeExists = $true; beforeHash = (Get-TextHash $beforeC); afterHash = (Get-TextHash $afterC); kind = 'mcp'; action = 'write'; dirPath = '' },
    @{ provider = 'opencode'; path = $dPath; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash $afterD); kind = 'mcp'; action = 'create'; dirPath = '' },
    @{ provider = 'opencode'; path = $ePath; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash $afterE); kind = 'mcp'; action = 'create'; dirPath = '' }
  )
  $backupId = New-ExtensionBackup $fx.auto $homeDir 'mcp' 'mixed' 'add' $entries
  Write-TextFile $aPath $afterA
  Write-TextFile $cPath 'C-external'
  Write-TextFile $dPath $afterD
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $homeDir $backupId $true } 'R8 restore reports the blocked target'
  Assert-Contains $msg $cPath 'R8 names the externally changed target'
  Assert-Contains $msg '適用後にファイルが変化しているため復元しません' 'R8 explains the blocked target'
  Assert-Contains $msg '一部の対象は復元済みです' 'R8 reports partial recovery'
  Assert ((Read-TextFile $aPath) -ceq $beforeA) 'R8 applied target restored despite the failure'
  Assert ((Read-TextFile $bPath) -ceq $beforeB) 'R8 unchanged target left alone'
  Assert ((Read-TextFile $cPath) -ceq 'C-external') 'R8 external change is not overwritten'
  Assert (-not (Test-Path -LiteralPath $dPath)) 'R8 created target deleted after the failure'
  Assert (-not (Test-Path -LiteralPath $ePath)) 'R8 absent target remains absent'

  # R9: a restore write failure rolls the current target back and continues
  # with the remaining independent target.
  $fx = New-Fixture 'restore-write-failure'
  Reset-Injection
  $homeDir = $fx.home
  $aPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\a.json')
  $dPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\d.json')
  $beforeA = 'A-before'; $afterA = 'A-after'; $afterD = 'D-after'
  Write-TextFile $aPath $beforeA
  $entries = @(
    @{ provider = 'opencode'; path = $aPath; beforeExists = $true; beforeHash = (Get-TextHash $beforeA); afterHash = (Get-TextHash $afterA); kind = 'mcp'; action = 'write'; dirPath = '' },
    @{ provider = 'opencode'; path = $dPath; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash $afterD); kind = 'mcp'; action = 'create'; dirPath = '' }
  )
  $backupId = New-ExtensionBackup $fx.auto $homeDir 'mcp' 'write-fail' 'add' $entries
  Write-TextFile $aPath $afterA
  Write-TextFile $dPath $afterD
  $script:inject[$aPath] = @{ mode = 'after'; at = 1 }
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $homeDir $backupId $true } 'R9 restore write failure is reported'
  Assert-Contains $msg $aPath 'R9 names the failed target'
  Assert-Contains $msg '復元前の状態に戻しました' 'R9 reports the pre-restore state was restored'
  Assert ((Read-TextFile $aPath) -ceq $afterA) 'R9 failed target returns to its applied state'
  Assert (-not (Test-Path -LiteralPath $dPath)) 'R9 later independent target still restored'
  Assert (@($script:writeAttempts).Count -eq 2) 'R9 write and recovery both attempted'

  # R10: an already-restored target does not need its backup copy, so a corrupt
  # copy there does not block restoring the remaining applied target.
  $fx = New-Fixture 'restore-corrupt-skip'
  Reset-Injection
  $homeDir = $fx.home
  $aPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\a.json')
  $bPath = Ext-NormPath (Join-Path $homeDir '.config\opencode\b.json')
  $beforeA = 'A-before'; $afterA = 'A-after'
  $beforeB = 'B-before'; $afterB = 'B-after'
  Write-TextFile $aPath $beforeA
  Write-TextFile $bPath $beforeB
  $entries = @(
    @{ provider = 'opencode'; path = $aPath; beforeExists = $true; beforeHash = (Get-TextHash $beforeA); afterHash = (Get-TextHash $afterA); kind = 'mcp'; action = 'write'; dirPath = '' },
    @{ provider = 'opencode'; path = $bPath; beforeExists = $true; beforeHash = (Get-TextHash $beforeB); afterHash = (Get-TextHash $afterB); kind = 'mcp'; action = 'write'; dirPath = '' }
  )
  $backupId = New-ExtensionBackup $fx.auto $homeDir 'mcp' 'corrupt-skip' 'add' $entries
  Write-TextFile $aPath $afterA
  $bdir = Join-Path (Join-Path $fx.auto 'backups\.extensions') $backupId
  $manifest = (Read-TextFile (Join-Path $bdir 'manifest.json')) | ConvertFrom-Json
  $bEntry = @($manifest.files | Where-Object { [string]$_.path -ieq $bPath })[0]
  Write-TextFile (Join-Path $bdir ([string]$bEntry.backupFile)) 'corrupt-backup'
  $restore = Restore-ExtensionBackup $fx.auto $homeDir $backupId $true
  Assert ([bool]$restore.ok) 'R10 already-restored target with a corrupt backup does not block restore'
  Assert ((Read-TextFile $aPath) -ceq $beforeA) 'R10 applied target still restored'
  Assert ((Read-TextFile $bPath) -ceq $beforeB) 'R10 already-restored target left in its target state'

  # S1: a failure while staging the skill file never creates the destination
  # folder. The staging folder is removed, the apply reports a complete
  # recovery, and the same skill can be applied again.
  $fx = New-Fixture 'skill-staging-failure'
  Reset-Injection
  function Write-GlobalFileAtomicBytes([string]$File, [byte[]]$Bytes, [string]$TrustedRoot = '') {
    throw 'injected staging failure'
  }
  $pv = New-SkillPreview $fx 'staging-fail-skill'
  Assert ([bool]$pv.ok -and ([string]$pv.previewId -ne '')) 'S1 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\staging-fail-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S1 apply fails while staging the skill file'
  Assert-Contains $msg 'injected staging failure' 'S1 reports the injected failure'
  Assert-Contains $msg '自動復旧しました' 'S1 reports a complete recovery'
  Assert (-not (Test-Path -LiteralPath $skillDir)) 'S1 no destination folder is created'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S1 no skill file is left behind'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $fx.home '.agents\skills') -Force -Filter '.ext-new-*').Count -eq 0) 'S1 no staging folder is left behind'
  $pv2 = New-SkillPreview $fx 'staging-fail-skill'
  Assert ([string]$pv2.previewId -ne '') 'S1 the same skill can be previewed again'
  Remove-Item Function:\Write-GlobalFileAtomicBytes -Force
  $applied = Apply-ExtensionPreview $fx.auto $fx.home $pv2.previewId $true $false
  Assert ([bool]$applied.ok) 'S1 the same skill can be applied again'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S1 retried skill file exists'

  # S2: a failure that leaves extra content inside the staging folder removes
  # only the staging folder this call created; the destination never appears.
  $fx = New-Fixture 'skill-staging-content'
  Reset-Injection
  function Write-GlobalFileAtomicBytes([string]$File, [byte[]]$Bytes, [string]$TrustedRoot = '') {
    $dir = Split-Path $File -Parent
    [System.IO.File]::WriteAllText((Join-Path $dir 'partial.tmp'), 'partial', $script:utf8)
    throw 'injected staging failure (with content)'
  }
  $pv = New-SkillPreview $fx 'staging-content-skill'
  Assert ([string]$pv.previewId -ne '') 'S2 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\staging-content-skill'
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S2 apply fails while staging the skill file'
  Assert-Contains $msg '自動復旧しました' 'S2 reports a complete recovery with nothing published'
  Assert (-not (Test-Path -LiteralPath $skillDir)) 'S2 no destination folder is created'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $fx.home '.agents\skills') -Force -Filter '.ext-new-*').Count -eq 0) 'S2 the staging folder is removed with its partial content'
  Remove-Item Function:\Write-GlobalFileAtomicBytes -Force

  # S3: a staged-file hash mismatch is caught before publication. Nothing
  # appears at the destination and the apply reports a complete recovery.
  $fx = New-Fixture 'skill-hash-mismatch'
  Reset-Injection
  $pv = New-SkillPreview $fx 'mismatch-skill'
  Assert ([string]$pv.previewId -ne '') 'S3 skill preview created'
  $stored = $script:ExtensionPreviews[$pv.previewId]
  $entry = @($stored.entries | Where-Object { [string]$_.kind -eq 'skill' })[0]
  $entry.afterHash = Get-TextHash 'forced-mismatch'
  $skillDir = Join-Path $fx.home '.agents\skills\mismatch-skill'
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S3 apply fails on staged verification'
  Assert-Contains $msg 'スキルファイルの検証に失敗しました' 'S3 reports the staging verification failure'
  Assert-Contains $msg '自動復旧しました' 'S3 reports a complete recovery'
  Assert (-not (Test-Path -LiteralPath $skillDir)) 'S3 no destination folder is created'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $fx.home '.agents\skills') -Force -Filter '.ext-new-*').Count -eq 0) 'S3 no staging folder is left behind'

  # S4: a failure after the folder and file are published (recording the backup)
  # is rolled back by removing only the folder this apply published, using its
  # ownership proof.
  $fx = New-Fixture 'skill-backup-failure'
  Reset-Injection
  function Write-GlobalPrivateJson([string]$Path, $Value, [string]$TrustedRoot = '') {
    throw 'injected backup failure'
  }
  $pv = New-SkillPreview $fx 'backup-fail-skill'
  Assert ([string]$pv.previewId -ne '') 'S4 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\backup-fail-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S4 apply fails after publication while recording the backup'
  Assert-Contains $msg 'injected backup failure' 'S4 reports the injected failure'
  Assert-Contains $msg '自動復旧しました' 'S4 reports a complete recovery'
  Assert (-not (Test-Path -LiteralPath $skillDir)) 'S4 the published folder is removed'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S4 the published file is removed with its folder'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $fx.home '.agents\skills') -Force -Filter '.ext-new-*').Count -eq 0) 'S4 no staging folder is left behind'
  Remove-Item Function:\Write-GlobalPrivateJson -Force

  # S5: an external process wins the creation race after the apply's absence
  # check. The OS no-replace publish refuses to adopt that folder, nothing is
  # written into it, and the folder is kept.
  $fx = New-Fixture 'skill-create-race'
  Reset-Injection
  $pv = New-SkillPreview $fx 'race-skill'
  Assert ([string]$pv.previewId -ne '') 'S5 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\race-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $foreign = Join-Path $skillDir 'external.txt'
  function Ext-CreateOwnedDirectory([string]$Dir, [string]$File, [string]$HomePath, [byte[]]$ContentBytes = $null, [string]$ExpectedHash = '') {
    # The external creator appears between the absence check and the publish.
    $dirN = Ext-NormPath $Dir
    New-Item -ItemType Directory -Force -Path $dirN | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dirN 'external.txt'), 'external', $script:utf8)
    return (& ([scriptblock]::Create($script:realCreateOwned)) $Dir $File $HomePath $ContentBytes $ExpectedHash)
  }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S5 apply rejects the externally created folder'
  Assert-Contains $msg '変更対象のフォルダが作成されました' 'S5 reports the folder race'
  Assert ((Read-TextFile $foreign) -ceq 'external') 'S5 external folder content is preserved'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S5 no file is written into the external folder'
  Assert (-not (Test-Path -LiteralPath (Join-Path $fx.auto 'backups\.extensions'))) 'S5 no backup is recorded for the rejected apply'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $fx.home '.agents\skills') -Force -Filter '.ext-new-*').Count -eq 0) 'S5 no temporary folder is left behind'
  Set-Item Function:\Ext-CreateOwnedDirectory -Value ([scriptblock]::Create($script:realCreateOwned))

  # S6: after publication another process replaces the folder with a copy that
  # holds an identical SKILL.md but no ownership marker. The apply reports the
  # unproven folder, never writes into it, and rollback keeps the copy instead of
  # deleting a same-hash file.
  $fx = New-Fixture 'skill-folder-replaced'
  Reset-Injection
  $pv = New-SkillPreview $fx 'replaced-skill'
  Assert ([string]$pv.previewId -ne '') 'S6 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\replaced-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  function Ext-CreateOwnedDirectory([string]$Dir, [string]$File, [string]$HomePath, [byte[]]$ContentBytes = $null, [string]$ExpectedHash = '') {
    $owner = & ([scriptblock]::Create($script:realCreateOwned)) $Dir $File $HomePath $ContentBytes $ExpectedHash
    # Another process replaces the published folder with a copy of the file but
    # without the ownership marker.
    $text = [System.IO.File]::ReadAllText((Join-Path $Dir 'SKILL.md'))
    Remove-Item -LiteralPath $Dir -Recurse -Force
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Dir 'SKILL.md'), $text, $script:utf8)
    return $owner
  }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S6 apply reports the replaced folder'
  Assert-Contains $msg '所有を確認できない' 'S6 explains the replaced folder'
  Assert-Contains $msg '復旧失敗' 'S6 does not claim a complete recovery'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S6 the identical copy is kept'
  Assert ((Read-TextFile $skillFile).Contains('replaced-skill')) 'S6 the copy content is preserved'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S6 replacement folder is kept'
  Set-Item Function:\Ext-CreateOwnedDirectory -Value ([scriptblock]::Create($script:realCreateOwned))

  # S7: restore removes an empty folder recorded by an older interrupted apply,
  # using the ownership marker recorded in the manifest.
  $fx = New-Fixture 'restore-owned-folder'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  New-Item -ItemType Directory -Force -Path $skillsBase | Out-Null
  $skillDir = Join-Path $skillsBase 'owned-empty-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $owner = Ext-CreateOwnedDirectory $skillDir $skillFile $fx.home
  $entries = @(
    @{ provider = 'codex'; path = $skillFile; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash 'never-written'); kind = 'skill'; action = 'create'; dirPath = $skillDir; dirOwner = $owner }
  )
  $backupId = New-ExtensionBackup $fx.auto $fx.home 'skill' 'owned-empty-skill' 'add' $entries
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S7 owned empty folder exists before restore'
  $restore = Restore-ExtensionBackup $fx.auto $fx.home $backupId $true
  Assert ([bool]$restore.ok) 'S7 restore succeeds for an interrupted apply'
  Assert (-not (Test-Path -LiteralPath $skillDir)) 'S7 owned empty folder is removed'

  # S8: an older backup without the folder ownership record cannot identify the
  # created SKILL.md (the folder may have been replaced by a copy), so restore
  # keeps both the file and the folder and reports the target as failed instead
  # of deleting user data on a hash match alone.
  $fx = New-Fixture 'restore-unowned-folder'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  $skillDir = Join-Path $skillsBase 'unowned-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  $afterText = 'owned-by-the-apply'
  Write-TextFile $skillFile $afterText
  [System.IO.File]::WriteAllText((Join-Path $skillDir 'notes.txt'), 'external', $script:utf8)
  $entries = @(
    @{ provider = 'codex'; path = $skillFile; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash $afterText); kind = 'skill'; action = 'create'; dirPath = $skillDir }
  )
  $backupId = New-ExtensionBackup $fx.auto $fx.home 'skill' 'unowned-skill' 'add' $entries
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $fx.home $backupId $true } 'S8 restore reports the unprovable created skill file'
  Assert-Contains $msg '所有を確認できないため削除しません' 'S8 explains why the file is kept'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S8 created file is kept'
  Assert ((Read-TextFile $skillFile) -ceq $afterText) 'S8 created file content is preserved'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S8 folder without ownership record is kept'
  Assert ((Read-TextFile (Join-Path $skillDir 'notes.txt')) -ceq 'external') 'S8 external content is preserved'

  # S9: a completed apply keeps the ownership marker, because creation time is
  # not ownership evidence. Restore removes the folder with its file by
  # verifying that marker.
  $fx = New-Fixture 'restore-applied-skill'
  Reset-Injection
  $pv = New-SkillPreview $fx 'applied-skill'
  Assert ([string]$pv.previewId -ne '') 'S9 skill preview created'
  $applied = Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false
  Assert ([bool]$applied.ok) 'S9 skill apply succeeds'
  $skillDir = Join-Path $fx.home '.agents\skills\applied-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S9 skill file exists'
  Assert (@(Get-ChildItem -LiteralPath $skillDir -Force -Filter '.ext-owner-*').Count -eq 1) 'S9 ownership marker is kept after success'
  $restore = Restore-ExtensionBackup $fx.auto $fx.home $applied.backupId $true
  Assert ([bool]$restore.ok) 'S9 applied skill is restorable'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S9 applied skill file is deleted'
  Assert (-not (Test-Path -LiteralPath $skillDir)) 'S9 created skill folder is removed with its marker proof'

  # S10: a recorded folder whose proof no longer verifies (the marker is gone)
  # is kept, and restore reports the incomplete cleanup instead of deleting a
  # folder it cannot prove it created.
  $fx = New-Fixture 'restore-unproven-folder'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  New-Item -ItemType Directory -Force -Path $skillsBase | Out-Null
  $skillDir = Join-Path $skillsBase 'unproven-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $owner = Ext-CreateOwnedDirectory $skillDir $skillFile $fx.home
  $entries = @(
    @{ provider = 'codex'; path = $skillFile; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash 'never-written'); kind = 'skill'; action = 'create'; dirPath = $skillDir; dirOwner = $owner }
  )
  $backupId = New-ExtensionBackup $fx.auto $fx.home 'skill' 'unproven-skill' 'add' $entries
  # The folder is replaced after the backup, so the marker is gone.
  Remove-Item -LiteralPath $skillDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $fx.home $backupId $true } 'S10 restore reports the unprovable folder'
  Assert-Contains $msg '所有を確認できないため削除しません' 'S10 explains why the unproven folder is kept'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S10 unproven folder is kept'

  # S11: a crash between publishing a folder and recording the backup leaves the
  # folder that was published atomically with its marker and SKILL.md. A
  # matching marker file name and content is not proof that this operation owns
  # the folder, because another process may still be writing it, a copy may
  # carry the marker, or another user may have created it. Preview refuses the
  # folder, preserves the folder, the marker, and the file, and only a manual
  # removal allows the apply to retry.
  $fx = New-Fixture 'crash-leftover-folder'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  New-Item -ItemType Directory -Force -Path $skillsBase | Out-Null
  $skillDir = Join-Path $skillsBase 'leftover-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $legacyText = "---`nname: leftover-skill`ndescription: x`n---`n"
  $old = Ext-CreateOwnedDirectory $skillDir $skillFile $fx.home ($script:utf8.GetBytes($legacyText)) (Get-TextHash $legacyText)
  Assert (@(Get-ChildItem -LiteralPath $skillDir -Force).Count -eq 2) 'S11 crash remnant holds the marker and SKILL.md'
  $markerPath = Join-Path $skillDir ([string]$old.marker)
  Assert ((Read-TextFile $markerPath) -ceq [string]$old.token) 'S11 remnant marker matches its recorded name and content'
  Assert ((Read-TextFile $skillFile) -ceq $legacyText) 'S11 remnant keeps the published SKILL.md'
  $pv = New-SkillPreview $fx 'leftover-skill'
  Assert ([string]$pv.previewId -eq '') 'S11 preview refuses the published remnant'
  $err = (@($pv.entries) | Where-Object { -not [bool]$_.ok } | ForEach-Object { [string]$_.error }) -join ' '
  Assert-Contains $err '同名のフォルダが既にあります' 'S11 explains the existing folder blocks the add'
  Assert-Contains $err '手動で削除' 'S11 asks for a manual check'
  Assert ((Read-TextFile $markerPath) -ceq [string]$old.token) 'S11 the matching marker is preserved'
  Assert ((Read-TextFile $skillFile) -ceq $legacyText) 'S11 the published SKILL.md is preserved'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S11 the remnant folder is preserved'
  Remove-Item -LiteralPath $skillDir -Recurse -Force
  $pv2 = New-SkillPreview $fx 'leftover-skill'
  Assert ([string]$pv2.previewId -ne '') 'S11 preview succeeds after the manual removal'
  $applied = Apply-ExtensionPreview $fx.auto $fx.home $pv2.previewId $true $false
  Assert ([bool]$applied.ok) 'S11 apply succeeds after the manual removal'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S11 skill file is published'

  # S11b: another process creates the folder with a matching marker after the
  # preview. Apply refuses it before writing, and both the folder and its
  # marker are preserved instead of being replaced.
  $fx = New-Fixture 'apply-marker-race'
  Reset-Injection
  $pv = New-SkillPreview $fx 'marker-race-skill'
  Assert ([string]$pv.previewId -ne '') 'S11b skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\marker-race-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  $token = [System.Guid]::NewGuid().ToString('N')
  $markerPath = Join-Path $skillDir ('.ext-owner-' + $token + '.tmp')
  Write-TextFile $markerPath $token
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S11b apply refuses the externally created folder'
  Assert-Contains $msg 'プレビュー後にフォルダが作成されました' 'S11b reports the folder race'
  Assert-Contains $msg '手動で削除' 'S11b asks for a manual check'
  Assert ((Read-TextFile $markerPath) -ceq $token) 'S11b the matching marker is preserved'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S11b the external folder is preserved'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S11b no file is written into the external folder'
  Assert (-not (Test-Path -LiteralPath (Join-Path $fx.auto 'backups\.extensions'))) 'S11b no backup is recorded for the rejected apply'

  # S12: a folder whose only file looks like a marker but does not verify may be
  # user data. Preview refuses it and both the folder and the file are kept.
  $fx = New-Fixture 'unproven-remnant'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  New-Item -ItemType Directory -Force -Path $skillsBase | Out-Null
  $skillDir = Join-Path $skillsBase 'unproven-remnant'
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  $token = [System.Guid]::NewGuid().ToString('N')
  $marker = Join-Path $skillDir ('.ext-owner-' + $token + '.tmp')
  Write-TextFile $marker 'not-the-token'
  $pv = New-SkillPreview $fx 'unproven-remnant'
  Assert ([string]$pv.previewId -eq '') 'S12 preview refuses an unproven remnant'
  $err = (@($pv.entries) | Where-Object { -not [bool]$_.ok } | ForEach-Object { [string]$_.error }) -join ' '
  Assert-Contains $err '同名のフォルダが既にあります' 'S12 explains the folder is not recognized'
  Assert ((Read-TextFile $marker) -ceq 'not-the-token') 'S12 the unproven marker is preserved'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S12 the folder is preserved'

  # S13: a folder with no marker is kept even when a manifest records a
  # matching creation time. Creation time is not ownership evidence.
  $fx = New-Fixture 'restore-time-only'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  New-Item -ItemType Directory -Force -Path $skillsBase | Out-Null
  $skillDir = Join-Path $skillsBase 'time-only-skill'
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $token = [System.Guid]::NewGuid().ToString('N')
  $owner = @{ dir = $skillDir; file = $skillFile; marker = ('.ext-owner-' + $token + '.tmp'); token = $token }
  $entries = @(
    @{ provider = 'codex'; path = $skillFile; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash 'never-written'); kind = 'skill'; action = 'create'; dirPath = $skillDir; dirOwner = $owner }
  )
  $backupId = New-ExtensionBackup $fx.auto $fx.home 'skill' 'time-only-skill' 'add' $entries
  $ticks = ([System.IO.Directory]::GetCreationTimeUtc($skillDir)).ToFileTimeUtc()
  $manifestPath = Join-Path (Join-Path $fx.auto ('backups\.extensions\' + $backupId)) 'manifest.json'
  $manifest = (Read-TextFile $manifestPath) | ConvertFrom-Json
  $manifestEntry = @($manifest.files)[0]
  $manifestEntry | Add-Member -NotePropertyName dirCreatedUtc -NotePropertyValue $ticks -Force
  Write-TextFile $manifestPath ($manifest | ConvertTo-Json -Depth 12)
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $fx.home $backupId $true } 'S13 restore reports the folder it cannot prove'
  Assert-Contains $msg '所有を確認できないため削除しません' 'S13 creation time alone does not authorize deletion'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S13 the folder is kept'

  # S14: a manifest that flags a created folder but is missing the ownership
  # token is incomplete. The created skill file cannot be identified, so restore
  # keeps both the file and the folder and reports the target as failed.
  $fx = New-Fixture 'restore-incomplete-owner'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  $skillDir = Join-Path $skillsBase 'incomplete-owner-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  $afterText = 'owned-by-the-apply'
  Write-TextFile $skillFile $afterText
  $entries = @(
    @{ provider = 'codex'; path = $skillFile; beforeExists = $false; beforeHash = ''; afterHash = (Get-TextHash $afterText); kind = 'skill'; action = 'create'; dirPath = $skillDir; dirOwner = @{ dir = $skillDir; file = $skillFile; marker = ''; token = '' } }
  )
  $backupId = New-ExtensionBackup $fx.auto $fx.home 'skill' 'incomplete-owner-skill' 'add' $entries
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $fx.home $backupId $true } 'S14 restore reports the incomplete ownership record'
  Assert-Contains $msg '所有を確認できないため削除しません' 'S14 explains why the file is kept'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S14 created file is kept'
  Assert ((Read-TextFile $skillFile) -ceq $afterText) 'S14 created file content is preserved'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S14 folder with incomplete ownership info is kept'

  # S15: restore must not delete the skill file when the recorded folder is no
  # longer proven to be the folder this apply published. The folder was replaced
  # by a normal folder that holds an identical SKILL.md but no marker.
  $fx = New-Fixture 'restore-replaced-owned'
  Reset-Injection
  $pv = New-SkillPreview $fx 'restore-replaced-skill'
  Assert ([string]$pv.previewId -ne '') 'S15 skill preview created'
  $applied = Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false
  Assert ([bool]$applied.ok) 'S15 skill apply succeeds'
  $skillDir = Join-Path $fx.home '.agents\skills\restore-replaced-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $appliedText = Read-TextFile $skillFile
  Remove-Item -LiteralPath $skillDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  Write-TextFile $skillFile $appliedText
  $msg = Assert-ThrowsWith { Restore-ExtensionBackup $fx.auto $fx.home $applied.backupId $true } 'S15 restore reports the unproven replacement'
  Assert-Contains $msg '所有を確認できない' 'S15 explains why the file is kept'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S15 file in the unproven folder is kept'
  Assert ((Test-Path -LiteralPath $skillFile -PathType Leaf) -and ((Read-TextFile $skillFile) -ceq $appliedText)) 'S15 file content is preserved'

  # S16: apply must not write into a published folder replaced by another
  # process before the write. The ownership marker is gone, so the folder is not
  # adopted and no file is created inside it.
  $fx = New-Fixture 'apply-replaced-owned'
  Reset-Injection
  $pv = New-SkillPreview $fx 'apply-replaced-skill'
  Assert ([string]$pv.previewId -ne '') 'S16 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\apply-replaced-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  function Ext-CreateOwnedDirectory([string]$Dir, [string]$File, [string]$HomePath, [byte[]]$ContentBytes = $null, [string]$ExpectedHash = '') {
    $owner = & ([scriptblock]::Create($script:realCreateOwned)) $Dir $File $HomePath $ContentBytes $ExpectedHash
    # Another process replaces the folder after the no-replace publish.
    Remove-Item -LiteralPath $Dir -Recurse -Force
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    return $owner
  }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S16 apply refuses the replaced folder'
  Assert-Contains $msg '所有を確認できない' 'S16 explains the replaced folder'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S16 no file is written into the replacement folder'
  Assert (Test-Path -LiteralPath $skillDir -PathType Container) 'S16 replacement folder is kept'
  Set-Item Function:\Ext-CreateOwnedDirectory -Value ([scriptblock]::Create($script:realCreateOwned))

  # S17: rollback must not delete the applied file when the recorded folder is
  # no longer proven. The replacement folder holds an identical file but no
  # marker, so the file is kept and the failure is reported.
  $fx = New-Fixture 'rollback-replaced-owned'
  Reset-Injection
  $skillsBase = Join-Path $fx.home '.agents\skills'
  New-Item -ItemType Directory -Force -Path $skillsBase | Out-Null
  $skillDir = Join-Path $skillsBase 'rollback-replaced-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $owner = Ext-CreateOwnedDirectory $skillDir $skillFile $fx.home
  $appliedText = 'applied-by-this-run'
  Write-TextFile $skillFile $appliedText
  $appliedHash = Ext-HashBytes ($script:utf8.GetBytes($appliedText))
  Remove-Item -LiteralPath $skillDir -Recurse -Force
  New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
  Write-TextFile $skillFile $appliedText
  $target = @{ path = $skillFile; beforeExists = $false; beforeBytes = $null; beforeHash = ''; afterHash = $appliedHash; appliedHash = $appliedHash; dirOwner = $owner }
  $r = Undo-ExtensionAppliedTarget $fx.home $target
  Assert (-not [bool]$r.ok) 'S17 rollback reports the unproven folder'
  Assert-Contains ([string]$r.reason) '所有を確認できない' 'S17 explains why the file is kept'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S17 file in the unproven folder is kept'
  Assert ((Test-Path -LiteralPath $skillFile -PathType Leaf) -and ((Read-TextFile $skillFile) -ceq $appliedText)) 'S17 file content is preserved'

  # S18: the no-replace folder publish refuses an existing destination, so a
  # folder that another process creates after the absence check is never
  # adopted and nothing is written into it.
  $fx = New-Fixture 'no-replace-publish'
  Reset-Injection
  $dir = Join-Path $fx.home '.agents\skills\existing-dir-skill'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $foreign = Join-Path $dir 'external.txt'
  Write-TextFile $foreign 'external'
  $dest = Join-Path $dir 'SKILL.md'
  $ours = $script:utf8.GetBytes('ours')
  $msg = Assert-ThrowsWith { Ext-CreateOwnedDirectory $dir $dest $fx.home $ours (Ext-HashBytes $ours) } 'S18 no-replace publish refuses an existing folder'
  Assert-Contains $msg '変更対象のフォルダが作成されました' 'S18 reports the existing folder'
  Assert ((Read-TextFile $foreign) -ceq 'external') 'S18 existing folder content is preserved'
  Assert (-not (Test-Path -LiteralPath $dest)) 'S18 no file is written into the existing folder'
  Assert (@(Get-ChildItem -LiteralPath (Split-Path $dir -Parent) -Force -Filter '.ext-new-*').Count -eq 0) 'S18 no staging folder is left behind'

  # S19: apply publishes the skill with the staged folder rename instead of
  # writing the destination path, so the destination is never written in place.
  $fx = New-Fixture 'skill-no-replace-path'
  Reset-Injection
  $pv = New-SkillPreview $fx 'no-replace-path-skill'
  Assert ([string]$pv.previewId -ne '') 'S19 skill preview created'
  $applied = Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false
  Assert ([bool]$applied.ok) 'S19 skill apply succeeds'
  $skillDir = Join-Path $fx.home '.agents\skills\no-replace-path-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  Assert (Test-Path -LiteralPath $skillFile -PathType Leaf) 'S19 the skill file is published'
  Assert (@(Get-ChildItem -LiteralPath $skillDir -Force -Filter '.ext-owner-*').Count -eq 1) 'S19 the ownership marker is published with the file'
  $attempts = @($script:writeAttempts | ForEach-Object { [string]$_ })
  Assert (-not ($attempts -contains (Ext-NormPath $skillFile))) 'S19 the destination is not written in place'
  $staged = @($attempts | Where-Object { $_.Contains('.ext-new-') -and $_.EndsWith('\SKILL.md') })
  Assert ($staged.Count -eq 1) 'S19 the file is written inside the staging folder'

  # S20: this is the reported race window. A folder appears after the absence
  # check and after the staged write, immediately before the no-replace rename.
  # The rename refuses to adopt it, nothing is written into it, and the staging
  # folder is removed. There is no later write that could be redirected into the
  # external folder.
  $fx = New-Fixture 'publish-race-window'
  Reset-Injection
  $pv = New-SkillPreview $fx 'publish-race-skill'
  Assert ([string]$pv.previewId -ne '') 'S20 skill preview created'
  $skillDir = Join-Path $fx.home '.agents\skills\publish-race-skill'
  $skillFile = Join-Path $skillDir 'SKILL.md'
  $foreign = Join-Path $skillDir 'external.txt'
  $script:onStagedWrite = {
    # Another process creates the destination between the absence check and the
    # publish rename.
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    [System.IO.File]::WriteAllText($foreign, 'external', $script:utf8)
  }
  $msg = Assert-ThrowsWith { Apply-ExtensionPreview $fx.auto $fx.home $pv.previewId $true $false } 'S20 apply refuses the folder created during publication'
  Assert-Contains $msg '変更対象のフォルダが作成されました' 'S20 reports the publish race'
  Assert ((Read-TextFile $foreign) -ceq 'external') 'S20 external folder content is preserved'
  Assert (-not (Test-Path -LiteralPath $skillFile)) 'S20 no SKILL.md is written into the external folder'
  Assert (@(Get-ChildItem -LiteralPath (Join-Path $fx.home '.agents\skills') -Force -Filter '.ext-new-*').Count -eq 0) 'S20 no staging folder is left behind'
  Assert (-not (Test-Path -LiteralPath (Join-Path $fx.auto 'backups\.extensions'))) 'S20 no backup is recorded for the rejected apply'
  Reset-Injection
} finally {
  Set-Item Function:\Ext-WriteAtomic -Value ([scriptblock]::Create($script:realWriter))
  Set-Item Function:\Ext-CreateOwnedDirectory -Value ([scriptblock]::Create($script:realCreateOwned))
  Remove-Item -LiteralPath $testBase -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count -gt 0) { throw ('FAILED: ' + ($script:failures -join ', ')) }
Write-Host 'ALL EXTENSION RECOVERY TESTS PASSED'
