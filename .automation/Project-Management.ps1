# Project-Management.ps1 - proposal-15 project management helpers (dev source).
# Dashboard-Server.ps1 から dot-source される純粋関数群。listen なし、任意コマンドなし。
# 前提: Dashboard-Server.ps1 の helper (Get-NormPath / Test-Contained / Test-FullyQualified /
# Test-SafeName / Test-Reparse / Test-ParentReparse / Test-PathHasShellMeta /
# Test-FrontmatterFlag / Get-Registry / Write-RegistryAtomicLocked / Get-FileHashHex /
# Get-CommonBody) が先に定義済み。tests も同順で dot-source する。
# 変更系は registry の原子書換のみ。共有 GitHub 側の取得・巻戻しは一切行わない。
# UI から使う end-to-end 用。秘密情報は扱わない。
$ErrorActionPreference = 'Stop'

# 個人設定 (settings.json) は Settings.ps1 経由。Settings.ps1 が無い単体コピー
# (scratch 配備) でも既定値で動くよう、その場合だけ既定値スタブを置く。
$shirubeSettingsScript = Join-Path $PSScriptRoot 'Settings.ps1'
if (Test-Path -LiteralPath $shirubeSettingsScript -PathType Leaf) { . $shirubeSettingsScript }
if (-not (Get-Command Get-ShirubeSetting -ErrorAction SilentlyContinue)) { function Get-ShirubeSetting { param([string]$Name = '', $Default = $null) return $Default } }

function Get-MgmtField($Obj, [string]$Key) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [hashtable]) {
    if ($Obj.ContainsKey($Key)) { return $Obj[$Key] }
    return $null
  }
  try {
    $pr = $Obj.PSObject.Properties[$Key]
    if ($pr) { return $pr.Value }
  } catch {}
  return $null
}

function Test-MgmtHasField($Obj, [string]$Key) {
  if ($null -eq $Obj) { return $false }
  if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Key) }
  try { return ($null -ne $Obj.PSObject.Properties[$Key]) } catch { return $false }
}

function Get-MgmtEffectiveEnabled($Entry) {
  try {
    if ($Entry -and $Entry.PSObject.Properties['enabled']) {
      if ($Entry.enabled -is [bool]) { return [bool]$Entry.enabled }
    }
  } catch {}
  return $true
}

# Display name is Unicode free text shown in UI/export; internal name stays the
# stable identifier for registry/status/backup association and never changes.
function Get-MgmtDisplayName($Entry) {
  try {
    $d = [string](Get-MgmtField $Entry 'displayName')
    if ($d -and ($d.Trim() -ne '')) { return $d }
  } catch {}
  try { return [string](Get-MgmtField $Entry 'name') } catch {}
  return ''
}

function Test-MgmtDisplayNameValid([string]$D) {
  if ($null -eq $D) { return $false }
  $t = $D.Trim()
  if (($t.Length -lt 1) -or ($t.Length -gt 64)) { return $false }
  if ($t -match '[\x00-\x1F\x7F]') { return $false }
  return $true
}

function Get-MgmtRegistryEntry([string]$AutoDir, [string]$Name) {
  if (-not (Test-SafeName $Name)) { throw '名前が不正です。' }
  $reg = @(Get-Registry $AutoDir)
  $hit = @($reg | Where-Object { [string]$_.name -ceq $Name })
  if ($hit.Count -eq 0) { throw '登録が見つかりません。' }
  if ($hit.Count -ne 1) { throw '同名の登録が複数あります。手動で整理してください。' }
  return $hit[0]
}

function Set-MgmtEnabled([string]$AutoDir, [string]$Name, [bool]$Enabled) {
  [void](Get-MgmtRegistryEntry $AutoDir $Name)
  $reg = @(Get-Registry $AutoDir)
  $new = @()
  foreach ($e in $reg) {
    if ([string]$e.name -ceq $Name) { $new += [pscustomobject]@{ name = [string]$e.name; path = [string]$e.path; enabled = $Enabled; displayName = (Get-MgmtDisplayName $e) } }
    else { $new += $e }
  }
  Write-RegistryAtomicLocked $AutoDir $new
  return @{ ok = $true; name = $Name; enabled = $Enabled }
}

# Rename changes only the display name. The internal name is stable so existing
# backups/status/history stay associated; no key migration is performed.
function Rename-MgmtProject([string]$AutoDir, [string]$Old, [string]$NewDisplay) {
  if (-not (Test-SafeName $Old)) { throw '名前が不正です。' }
  if (-not (Test-MgmtDisplayNameValid $NewDisplay)) { throw '表示名が不正です。(1〜64文字、制御文字なし)' }
  $nd = $NewDisplay.Trim()
  $ent = Get-MgmtRegistryEntry $AutoDir $Old
  $reg = @(Get-Registry $AutoDir)
  foreach ($e in $reg) {
    if (([string]$e.name -cne $Old)) {
      if (([string]$e.name -ceq $nd) -or ((Get-MgmtDisplayName $e) -eq $nd)) { throw '表示名が競合しました。別の表示名にしてください。' }
    }
  }
  if (([string]$ent.name -ceq $nd) -or ((Get-MgmtDisplayName $ent) -eq $nd)) { throw '同一名への変更はできません。' }
  $outRows = @()
  foreach ($e in $reg) {
    if ([string]$e.name -ceq $Old) {
      $row = @{ name = [string]$e.name; path = [string]$e.path; displayName = $nd }
      if ($e.PSObject.Properties['enabled']) { $row.enabled = (Get-MgmtEffectiveEnabled $e) }
      $outRows += [pscustomobject]$row
    }
    else { $outRows += $e }
  }
  Write-RegistryAtomicLocked $AutoDir $outRows
  return @{ ok = $true; name = $Old; displayName = $nd; path = [string]$ent.path }
}

function Move-MgmtProjectPath([string]$AutoDir, [string]$Name, [string]$NewRawPath) {
  $ent = Get-MgmtRegistryEntry $AutoDir $Name
  if ([string]::IsNullOrWhiteSpace($NewRawPath)) { throw '移動先のパスを入力してください。' }
  $p = $NewRawPath.Trim()
  if (-not (Test-FullyQualified $p)) { throw '絶対パスで入力してください。(例 C:\Project\MyRepo)' }
  if (Test-PathHasShellMeta $p) { throw 'パスに記号が含まれているため移動できません。' }
  try { $full = Get-NormPath $p } catch { throw 'パスを解釈できませんでした。' }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw 'フォルダが存在しません。先にフォルダを作成してください。' }
  if (Test-Reparse $full) { throw 'リンク・ジャンクションのフォルダには移動できません。' }
  $reg = @(Get-Registry $AutoDir)
  foreach ($e in $reg) {
    if (([string]$e.name -cne $Name)) {
      try { if ((Get-NormPath ([string]$e.path)).Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) { throw '既に登録されています。' } } catch { if ($_.Exception.Message.Contains('既に登録')) { throw } }
    }
  }
  $new = @()
  foreach ($e in $reg) {
    if ([string]$e.name -ceq $Name) {
      $row = @{ name = [string]$e.name; path = $full; displayName = (Get-MgmtDisplayName $e) }
      if ($e.PSObject.Properties['enabled']) { $row.enabled = (Get-MgmtEffectiveEnabled $e) }
      $new += [pscustomobject]$row
    }
    else { $new += $e }
  }
  Write-RegistryAtomicLocked $AutoDir $new
  return @{ ok = $true; name = $Name; path = $full }
}

function Get-MgmtBackupIdPattern { return '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' }

function New-MgmtBackupDir([string]$AutoDir, [string]$Name) {
  $broot = Join-Path $AutoDir 'backups'
  $bdir = $null
  try {
    New-Item -ItemType Directory -Force -Path $broot | Out-Null
    if (Test-Reparse $broot) { throw 'バックアップ先を確認できませんでした。' }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bdir = Join-Path $broot ($ts + '-' + $Name)
    $n = 0
    while (Test-Path -LiteralPath $bdir) { $n++; $bdir = Join-Path $broot ($ts + '-' + $Name + '-' + $n) }
    if (-not (Test-Contained $bdir $broot)) { throw 'バックアップ先を確認できませんでした。' }
    New-Item -ItemType Directory -Force -Path $bdir | Out-Null
    if (Test-Reparse $bdir) { throw 'バックアップ先を確認できませんでした。' }
    return $bdir
  } catch {
    try { if ($bdir -and (Test-Path -LiteralPath $bdir)) { Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    throw
  }
}

function Test-MgmtPrivateFileAcl([string]$File) {
  try {
    $fi = New-Object System.IO.FileInfo($File)
    $acl = $fi.GetAccessControl()
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $expected = @{}
    $sids = @()
    try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch {}
    try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' } catch {}
    try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544' } catch {}
    foreach ($sid in @($sids | Where-Object { $_ -ne $null })) { $expected[$sid.Value] = $true }
    if ($expected.Count -lt 2) { return $false }
    foreach ($r in @($acl.Access)) {
      try { $v = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return $false }
      if (-not $expected.ContainsKey($v)) { return $false }
      if ($r.AccessControlType -ne 'Allow') { return $false }
    }
    foreach ($k in $expected.Keys) {
      $found = $false
      foreach ($r in @($acl.Access)) {
        try { $v = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if (($v -ceq $k) -and ($r.FileSystemRights -eq [System.Security.AccessControl.FileSystemRights]::FullControl)) { $found = $true; break }
      }
      if (-not $found) { return $false }
    }
    return $true
  } catch { return $false }
}
function Copy-MgmtVerified([string]$Src, [string]$Dst) {
  if (Test-Reparse $Src) { throw 'リンクから複写しません。' }
  if ((Test-Path -LiteralPath $Dst) -and (Test-Reparse $Dst)) { throw 'リンクへ複写しません。' }
  $bytes = [System.IO.File]::ReadAllBytes($Src)
  $h = [System.Security.Cryptography.SHA256]::Create()
  try { $hex = (($h.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $h.Dispose() }
  try { if (Test-Path -LiteralPath $Dst) { Remove-Item -LiteralPath $Dst -Force -ErrorAction Stop } } catch {}
  Write-MgmtFileAtomicBytes $Dst $bytes
  $got = Get-FileHashHex $Dst
  if ((-not $got) -or ($got -cne $hex)) { throw '複写の検証に失敗しました。' }
  if (-not (Test-MgmtPrivateFileAcl $Dst)) { throw 'ACL検証に失敗しました。' }
}

# Single-read verified publish: reads the source bytes ONCE, hashes THOSE
# bytes against the immutable expected hash, publishes EXACTLY those bytes
# atomically, and confirms the result against the same hash. The source path
# is never reopened after the hash (no validate/use gap for a concurrent swap
# to exploit). Shared by restore and rollback.
function Copy-MgmtExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What) {
  if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { throw ('バックアップの検証情報がありません。復元しません: ' + $What) }
  if (Test-Reparse $Src) { throw ('リンクから復元しません: ' + $What) }
  if ((Test-Path -LiteralPath $Dst) -and (Test-Reparse $Dst)) { throw ('リンクへ復元しません: ' + $What) }
  $bytes = [System.IO.File]::ReadAllBytes($Src)
  $h = [System.Security.Cryptography.SHA256]::Create()
  try { $hex = (($h.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $h.Dispose() }
  if ($hex -cne $ExpectedHash) { throw ('バックアップが破損しているため復元しません: ' + $What) }
  Write-MgmtFileAtomicBytes $Dst $bytes
  $got = Get-FileHashHex $Dst
  if ($got -cne $ExpectedHash) { throw ('復元結果が一致しません: ' + $What) }
}

function Write-MgmtFileAtomicBytes([string]$File, [byte[]]$Bytes) {
  if (Test-Reparse $File) { throw 'リンクへの書込みはできません。' }
  $dir = Split-Path $File -Parent
  $tmp = Join-Path $dir ('.mgmt-tmp-' + [System.Guid]::NewGuid().ToString('N'))
  if (-not (Test-Contained $tmp $dir)) { throw '一時先を確認できませんでした。' }
  $sec = New-Object System.Security.AccessControl.FileSecurity
  $sec.SetAccessRuleProtection($true, $false)
  try { $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch { $me = $null }
  $sids = @()
  if ($me) { $sids += $me }
  $sids += (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18')
  $sids += (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544')
  foreach ($sid in $sids) { $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow'))) }
  $fs = [System.IO.File]::Create($tmp, 4096, [System.IO.FileOptions]::None, $sec)
  try { $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Dispose() }
  try {
    if (Test-Path -LiteralPath $File) {
      $bak = Join-Path $dir ('.mgmt-bak-' + [System.Guid]::NewGuid().ToString('N'))
      [System.IO.File]::Replace($tmp, $File, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch {}
    }
    else { [System.IO.File]::Move($tmp, $File) | Out-Null }
  }
  catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    throw
  }
}

function Write-MgmtPrivateJson([string]$Path, $Value) {
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Value -Depth 12))
  Write-MgmtFileAtomicBytes $Path $bytes
}

function Write-MgmtTextAtomic([string]$File, [string]$Text) {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  $bytes = $utf8bom.GetBytes($Text)
  Write-MgmtFileAtomicBytes $File $bytes
}

function Get-MgmtAgentsImportPreview([string]$AutoDir, [string]$RawPath, [string]$CommonBody) {
  if ([string]::IsNullOrWhiteSpace($RawPath)) { return @{ ok = $false; error = 'フォルダのパスを入力してください。' } }
  $p = $RawPath.Trim()
  if (-not (Test-FullyQualified $p)) { return @{ ok = $false; error = '絶対パスで入力してください。' } }
  if (Test-PathHasShellMeta $p) { return @{ ok = $false; error = 'パスに記号が含まれているため取り込めません。' } }
  try { $full = Get-NormPath $p } catch { return @{ ok = $false; error = 'パスを解釈できませんでした。' } }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { return @{ ok = $false; error = 'フォルダが存在しません。' } }
  if (Test-Reparse $full) { return @{ ok = $false; error = 'リンク・ジャンクションのフォルダは取り込めません。' } }
  $reg = @(Get-Registry $AutoDir)
  foreach ($e in $reg) {
    try { if ((Get-NormPath ([string]$e.path)).Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) { return @{ ok = $false; error = ('既に登録されています: ' + ([string]$e.name)) } } } catch {}
  }
  $agents = Join-Path $full 'AGENTS.md'
  $hasAgents = (Test-Path -LiteralPath $agents) -and (-not (Get-Item -LiteralPath $agents -Force -ErrorAction SilentlyContinue).PSIsContainer)
  if (-not $hasAgents) { return @{ ok = $false; error = 'AGENTS.md がありません。通常の新規登録を使ってください。' } }
  if (Test-Reparse $agents) { return @{ ok = $false; error = 'AGENTS.md がリンクになっています。実体に戻してから取り込んでください。' } }
  $local = Join-Path $full '.rulesync\rules\project-local.md'
  $hasLocal = (Test-Path -LiteralPath $local) -and (-not (Get-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue).PSIsContainer)
  if ($hasLocal -and (Test-Reparse $local)) { return @{ ok = $false; error = 'project-local.md がリンクになっています。' } }
  if ($hasLocal -and (Test-ParentReparse $local $full)) { return @{ ok = $false; error = 'project-local.md の親フォルダがリンクになっています。' } }
  $localBody = ''
  if ($hasLocal) {
    $lt = Get-Content -LiteralPath $local -Raw -Encoding UTF8
    if (-not (Test-FrontmatterFlag $lt 'localRoot')) { return @{ ok = $false; error = '既存 project-local.md の先頭形式が不正です。直してから取り込んでください。' } }
    $localBody = Get-BodyWithoutFrontmatter $lt
  }
  $agentsText = [System.IO.File]::ReadAllText($agents, [System.Text.Encoding]::UTF8)
  $rest = $agentsText
  if ($CommonBody -and ($CommonBody.Trim() -ne '')) {
    $cb = $CommonBody.Trim()
    $ix = $rest.IndexOf($cb, [System.StringComparison]::Ordinal)
    if ($ix -ge 0) { $rest = ($rest.Substring(0, $ix) + $rest.Substring($ix + $cb.Length)) }
  }
  if (($localBody.Trim() -ne '')) {
    $ix2 = $rest.IndexOf($localBody.Trim(), [System.StringComparison]::Ordinal)
    if ($ix2 -ge 0) { $rest = ($rest.Substring(0, $ix2) + $rest.Substring($ix2 + $localBody.Trim().Length)) }
  }
  $rest = $rest.Trim()
  if ($rest -eq '') { return @{ ok = $false; error = '固有内容がありません。AGENTS.md を手動で整理（移動または削除）して通常登録してください。' } }
  $name = Suggest-SafeName $full $reg
  $head = $agentsText
  if ($head.Length -gt 2000) { $head = $head.Substring(0, 2000) + "`n...(省略)..." }
  return @{
    ok = $true; kind = 'import'; name = $name; path = $full
    agentsHead = $head; agentsHash = (Get-FileHashHex $agents)
    hasLocal = [bool]$hasLocal; localHash = (Get-FileHashHex $local)
    transcription = $rest
  }
}

# Explicit import approval: computed once at preview time (transcription +
# its common-body dependency and source hashes) and passed down, never
# recomputed as approval inside the register step.
function New-MgmtImportApproval([string]$AutoDir, [string]$RawPath) {
  $common = Get-CommonBodyStrict $AutoDir
  $pv = Get-MgmtAgentsImportPreview $AutoDir $RawPath $common
  if (-not $pv.ok) { throw $pv.error }
  return @{ path = [string]$pv.path; name = [string]$pv.name; agentsHash = [string]$pv.agentsHash; localHash = [string]$pv.localHash; hasLocal = [bool]$pv.hasLocal; transcription = [string]$pv.transcription; commonBody = [string]$common }
}

# True when current files still match the passed approval (entry and
# pre-write gates share this; no approval is ever derived here).
function Test-MgmtImportApproval([string]$AutoDir, [string]$RawPath, $Approved) {
  try {
    $apTrans = [string](Get-MgmtField $Approved 'transcription')
    $apCommon = [string](Get-MgmtField $Approved 'commonBody')
    $apPath = [string](Get-MgmtField $Approved 'path')
    $apName = [string](Get-MgmtField $Approved 'name')
    if (($apTrans -eq '') -or ($apPath -eq '') -or ($apName -eq '')) { return $false }
    $curCommon = $null
    try { $curCommon = Get-CommonBodyStrict $AutoDir } catch { return $false }
    $v = Get-MgmtAgentsImportPreview $AutoDir $RawPath $curCommon
    if (-not $v.ok) { return $false }
    if ([string]$v.transcription -cne $apTrans) { return $false }
    if ($curCommon -cne $apCommon) { return $false }
    if ([string]$v.path -cne $apPath) { return $false }
    if ([string]$v.name -cne $apName) { return $false }
    if ([string]$v.agentsHash -cne [string](Get-MgmtField $Approved 'agentsHash')) { return $false }
    if ([string]$v.localHash -cne [string](Get-MgmtField $Approved 'localHash')) { return $false }
    return $true
  } catch { return $false }
}

function Register-MgmtImport([string]$AutoDir, [string]$RawPath, [string]$Name, [bool]$Confirm, $Approved) {
  if (-not $Confirm) { throw '確認チェックを入れてください。' }
  if ($null -eq $Approved) { throw '承認内容がありません。プレビューからやり直してください。' }
  $apName = ([string](Get-MgmtField $Approved 'name')).Trim()
  $apPath = [string](Get-MgmtField $Approved 'path')
  $apTrans = [string](Get-MgmtField $Approved 'transcription')
  if (($apName -eq '') -or ($apPath -eq '') -or ($apTrans -eq '')) { throw '承認内容が不正です。プレビューからやり直してください。' }
  if ($Name -and ($Name -cne $apName)) { throw 'プレビューと名前が一致しません。もう一度プレビューしてください。' }
  if (-not (Test-MgmtImportApproval $AutoDir $RawPath $Approved)) { throw '内容が変化したため、もう一度プレビューしてください。' }
  $apAgentsH = [string](Get-MgmtField $Approved 'agentsHash')
  $apLocalH = [string](Get-MgmtField $Approved 'localHash')
  $apHasLocal = $false
  try { $apHasLocal = [bool](Get-MgmtField $Approved 'hasLocal') } catch {}
  $reg = @(Get-Registry $AutoDir)
  foreach ($e in $reg) {
    if (([string]$e.name) -ceq $apName) { throw '名前が競合しました。もう一度プレビューしてください。' }
    try { if ((Get-NormPath ([string]$e.path)).Equals($apPath, [System.StringComparison]::OrdinalIgnoreCase)) { throw '既に登録されています。' } } catch { if ($_.Exception.Message.Contains('既に登録')) { throw } }
  }
  $bdir = New-MgmtBackupDir $AutoDir $apName
  try { Copy-MgmtVerified (Join-Path $apPath 'AGENTS.md') (Join-Path $bdir 'AGENTS.md') }
  catch { try { Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}; throw }
  $localFile = Join-Path $apPath '.rulesync\rules\project-local.md'
  $localExisted = $false
  try {
    if ($apHasLocal) { Copy-MgmtVerified $localFile (Join-Path $bdir 'project-local.md'); $localExisted = $true }
    $mf = @{ schemaVersion = 1; name = $apName; displayName = $apName; path = $apPath; createdAt = ([DateTime]::UtcNow.ToString('o')); agentsPresent = $true; localPresent = $localExisted; agentsHash = $apAgentsH; localHash = $apLocalH; imported = $true }
    Write-MgmtPrivateJson (Join-Path $bdir 'manifest.json') $mf
  }
  catch { try { Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction SilentlyContinue } catch {}; throw }
  Assert-MgmtLocalParentClean $apPath
  # Late re-verify immediately before writing, then write the approved
  # transcription itself (never a recomputed value).
  if (-not (Test-MgmtImportApproval $AutoDir $RawPath $Approved)) { throw '内容が変化したため、もう一度プレビューしてください。' }
  $origLocalText = $null
  $createdLocal = $false
  if ($localExisted) {
    $cur = [System.IO.File]::ReadAllText($localFile, [System.Text.Encoding]::UTF8)
    $origLocalText = $cur
    Write-MgmtTextAtomic $localFile ($cur.TrimEnd() + "`r`n`r`n" + $apTrans + "`r`n")
  }
  else {
    $ld = Split-Path $localFile -Parent
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    $fm = "---`r`nlocalRoot: true`r`ntargets: [`"codexcli`", `"opencode`"]`r`ndescription: `"AGENTS.md から取り込み`"`r`n---`r`n`r`n" + $apTrans + "`r`n"
    Write-MgmtTextAtomic $localFile $fm
    $createdLocal = $true
  }
  $reg2 = $null
  try {
    # The registry re-read, row build, and publish all live inside the
    # rollback scope: a read failure after the local write still restores
    # the original state (or deletes the created file) instead of leaving
    # a partial import behind.
    $reg2 = @(Get-Registry $AutoDir)
    $reg2 += [pscustomobject]@{ name = $apName; path = $apPath; displayName = $apName }
    Write-RegistryAtomicLocked $AutoDir $reg2
  }
  catch {
    # Roll back the local edit so a retry sees the original state (existing
    # content restored, created file removed). The backup dir is kept.
    # A rollback failure is reported explicitly instead of silently masking.
    $pubErr = $_.Exception.Message
    try {
      if ($createdLocal) { if (Test-Path -LiteralPath $localFile) { Remove-Item -LiteralPath $localFile -Force } }
      elseif ($null -ne $origLocalText) { Write-MgmtTextAtomic $localFile $origLocalText }
    } catch { throw ('取込に失敗し、ローカルファイルの巻戻しも失敗しました。手動で確認してください。') }
    throw $pubErr
  }
  return @{ ok = $true; name = $apName; path = $apPath; backup = $bdir }
}

function Get-MgmtLocalRuleFile([string]$AutoDir, [string]$Name) {
  $ent = Get-MgmtRegistryEntry $AutoDir $Name
  $full = ''
  try { $full = Get-NormPath ([string]$ent.path) } catch { throw 'パスを解釈できませんでした。' }
  Assert-MgmtLocalParentClean $full
  $lf = Join-Path $full '.rulesync\rules\project-local.md'
  if (Test-Reparse $lf) { throw 'project-local.md がリンクになっています。' }
  return $lf
}

# Parent-chain guard for local rule writes/deletes. Every ancestor level from
# the repo root to the rules dir is validated whether anything exists or not:
# a missing file under a junctioned ancestor would otherwise escape the repo.
function Assert-MgmtLocalParentClean([string]$RepoFull) {
  $repo = ''
  try { $repo = Get-NormPath $RepoFull } catch { throw 'パスを解釈できませんでした。' }
  if (-not (Test-Path -LiteralPath $repo -PathType Container)) { throw 'フォルダが存在しません。' }
  if (Test-Reparse $repo) { throw 'リンク・ジャンクションのフォルダは編集できません。' }
  $levels = @()
  $cur = Get-NormPath (Join-Path $repo '.rulesync\rules')
  $guard = 0
  while (($cur -cne $repo) -and (Test-Contained $cur $repo) -and ($guard -lt 16)) {
    $levels += $cur
    try { $cur = Get-NormPath (Split-Path $cur -Parent) } catch { throw 'ローカル配置を確認できませんでした。' }
    $guard++
  }
  if ($cur -cne $repo) { throw 'ローカル配置を確認できませんでした。' }
  foreach ($lv in $levels) {
    if ((Test-Path -LiteralPath $lv) -and (Test-Reparse $lv)) { throw 'project-local.md の親フォルダがリンクになっています。' }
  }
}

function Get-MgmtLocalRule([string]$AutoDir, [string]$Name) {
  $lf = Get-MgmtLocalRuleFile $AutoDir $Name
  if (-not (Test-Path -LiteralPath $lf -PathType Leaf)) { throw 'project-local.md がありません。' }
  $t = [System.IO.File]::ReadAllText($lf, [System.Text.Encoding]::UTF8)
  return @{ name = $Name; path = $lf; text = $t; hash = (Get-FileHashHex $lf) }
}

function Save-MgmtLocalRule([string]$AutoDir, [string]$Name, [string]$Text, [string]$ExpectedHash) {
  $lf = Get-MgmtLocalRuleFile $AutoDir $Name
  if (-not (Test-Path -LiteralPath $lf -PathType Leaf)) { throw 'project-local.md がありません。' }
  $curHash = Get-FileHashHex $lf
  if ([string]::IsNullOrWhiteSpace($ExpectedHash) -or ($curHash -cne $ExpectedHash.Trim().ToLowerInvariant())) {
    throw '内容が変化したため保存しませんでした。取得し直してください。'
  }
  if (-not (Test-FrontmatterFlag $Text 'localRoot')) { throw '先頭形式が不正です。localRoot/targets/description の形式を保ってください。' }
  $bdir = New-MgmtBackupDir $AutoDir ($Name + '-localrule')
  try {
    Copy-MgmtVerified $lf (Join-Path $bdir 'project-local.md')
    $entS = Get-MgmtRegistryEntry $AutoDir $Name
    $repoS = Get-NormPath ([string]$entS.path)
    Write-MgmtPrivateJson (Join-Path $bdir 'manifest.json') @{ schemaVersion = 1; scope = 'local'; name = $Name; displayName = (Get-MgmtDisplayName $entS); path = $repoS; createdAt = ([DateTime]::UtcNow.ToString('o')); agentsPresent = $false; localPresent = $true; localHash = $curHash }
  } catch {
    try {
      $brootF2 = Join-Path $AutoDir 'backups'
      $nb = [System.IO.Path]::GetFullPath($bdir)
      $nr = [System.IO.Path]::GetFullPath($brootF2)
      if ($nb.StartsWith($nr + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $bdir)) {
        Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction Stop
      }
    } catch {}
    throw
  }
  $norm = $Text -replace "`r`n", "`n"
  $norm = $norm -replace "`r", "`n"
  $norm = $norm -replace "`n", "`r`n"
  Write-MgmtTextAtomic $lf $norm
  return @{ ok = $true; name = $Name; hash = (Get-FileHashHex $lf); backup = $bdir }
}

function Get-MgmtDupCandidates([string]$CommonBody, [string]$LocalBody) {
  $out = @()
  if ((-not $CommonBody) -or (-not $LocalBody)) { return $out }
  $set = @{}
  foreach ($ln in ($CommonBody -replace "`r`n", "`n" -split "`n")) {
    $t = $ln.Trim()
    if ($t.Length -ge 4) { $set[$t] = $true }
  }
  $seen = @{}
  foreach ($ln in ($LocalBody -replace "`r`n", "`n" -split "`n")) {
    $t = $ln.Trim()
    if (($t.Length -ge 4) -and $set.ContainsKey($t) -and (-not $seen.ContainsKey($t))) {
      $seen[$t] = $true
      $out += @{ kind = '重複候補'; line = $t }
      if ($out.Count -ge 50) { break }
    }
  }
  return $out
}

function Get-MgmtContradictionCandidates([string]$CommonBody, [string]$LocalBody) {
  $out = @()
  if ((-not $CommonBody) -or (-not $LocalBody)) { return $out }
  $negs = @('ない', '禁止', 'しない', 'せず', '不可', 'ダメ', 'やめる', '停止', '除外')
  $commons = @()
  foreach ($ln in ($CommonBody -replace "`r`n", "`n" -split "`n")) {
    $t = $ln.Trim()
    if ($t.Length -ge 10) { $commons += $t }
    if ($commons.Count -ge 500) { break }
  }
  $n = 0
  foreach ($ln in ($LocalBody -replace "`r`n", "`n" -split "`n")) {
    $t = $ln.Trim()
    if ($t.Length -lt 4) { continue }
    $hasNeg = $false
    foreach ($g in $negs) { if ($t.Contains($g)) { $hasNeg = $true; break } }
    if (-not $hasNeg) { continue }
    foreach ($c in $commons) {
      $hit = $false
      $maxw = [Math]::Min(30, $c.Length - 9)
      for ($i = 0; $i -lt $maxw; $i++) {
        $w = $c.Substring($i, 10)
        if ($t.Contains($w)) { $hit = $true; break }
      }
      if ($hit) { $out += @{ kind = '矛盾候補'; common = $c; local = $t }; break }
    }
    $n++
    if (($out.Count -ge 20) -or ($n -ge 500)) { break }
  }
  return $out
}

function Get-MgmtProjectStatus([string]$AutoDir) {  $f = Join-Path $AutoDir 'project-status.json'
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @{ schemaVersion = 1; projects = @{} } }
  if (Test-Reparse $f) { throw '状態ファイルを確認できませんでした。' }
  try {
    $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $o.PSObject.Properties['projects']) { return @{ schemaVersion = 1; projects = @{} } }
    return $o
  } catch { return @{ schemaVersion = 1; projects = @{} } }
}

function Get-MgmtBackupName([string]$Id, $Manifest) {
  try { if ($Manifest -and $Manifest.PSObject.Properties['name'] -and ([string]$Manifest.name).Trim() -ne '') { return [string]$Manifest.name } } catch {}
  # No trusted manifest: target is unknown. Never guess from the id suffix
  # (e.g. 'Repo-2' must not resolve to 'Repo' and be compared/restored
  # against the wrong repo). List shows unknown, diff/restore refuse.
  return ''
}

function Get-MgmtBackupList([string]$AutoDir, [string]$Name) {
  $out = @()
  $broot = Join-Path $AutoDir 'backups'
  if (-not (Test-Path -LiteralPath $broot -PathType Container)) { return $out }
  $dispMap = @{}
  try {
    foreach ($re in @(Get-Registry $AutoDir)) { $dispMap[[string]$re.name] = (Get-MgmtDisplayName $re) }
  } catch {}
  $pat = Get-MgmtBackupIdPattern
  $dirs = @(Get-ChildItem -LiteralPath $broot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  foreach ($d in $dirs) {
    $id = $d.Name
    if ($id -cnotmatch $pat) { continue }
    $full = $d.FullName
    if (-not (Test-Contained $full $broot)) { continue }
    if (Test-Reparse $full) { continue }
    $mf = $null
    $mfPath = Join-Path $full 'manifest.json'
    if ((Test-Path -LiteralPath $mfPath -PathType Leaf) -and (-not (Test-Reparse $mfPath))) {
      try { $mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $mf = $null }
    }
    # Global (home-wide) backups share this folder. They are not project rows:
    # only full/local/legacy project backups are listed here (the Global list
    # applies the inverse scope filter).
    $isGlobalRow = $false
    try { if ($mf -and $mf.PSObject.Properties['scope'] -and ([string]$mf.scope -ceq 'global')) { $isGlobalRow = $true } } catch {}
    if ($isGlobalRow) { continue }
    $bn = Get-MgmtBackupName $id $mf
    if ($Name -and ($Name.Trim() -ne '') -and ($bn -cne $Name)) { continue }
    $agF = Join-Path $full 'AGENTS.md'
    $lcF = Join-Path $full 'project-local.md'
    $row = @{ id = $id; name = $bn; path = ''; createdAt = ''; agentsPresent = $false; localPresent = $false; hasAgentsFile = $false; hasLocalFile = $false; commonSha = ''; commonCommit = ''; agentsHash = ''; localHash = ''; displayName = $bn }
    if (($null -eq $mf) -and ($bn -ceq '')) { $row.displayName = '(対象不明)' }
    try {
      if ($mf) {
        try { $row.path = [string]$mf.path } catch {}
        try { if (([string]$mf.displayName).Trim() -ne '') { $row.displayName = [string]$mf.displayName } } catch {}
        try { $row.createdAt = [string]$mf.createdAt } catch {}
        try { if ($mf.agentsPresent) { $row.agentsPresent = $true } } catch {}
        try { if ($mf.localPresent) { $row.localPresent = $true } } catch {}
        try { $row.commonSha = [string]$mf.commonSha } catch {}
        try { $row.commonCommit = [string]$mf.commonCommit } catch {}
        try { $row.agentsHash = [string]$mf.agentsHash } catch {}
        try { $row.localHash = [string]$mf.localHash } catch {}
      }
      if (($row.displayName -ceq $row.name) -and ($dispMap.ContainsKey($bn))) {
        try { if (([string]$dispMap[$bn]).Trim() -ne '') { $row.displayName = [string]$dispMap[$bn] } } catch {}
      }
    } catch {}
    if ((Test-Path -LiteralPath $agF -PathType Leaf)) { $row.hasAgentsFile = $true }
    if ((Test-Path -LiteralPath $lcF -PathType Leaf)) { $row.hasLocalFile = $true }
    $out += $row
  }
  return $out
}

function Mgmt-SimpleDiff([string[]]$Old, [string[]]$New) {
  $o = @($Old)
  $w = @($New)
  $pre = 0
  while (($pre -lt $o.Count) -and ($pre -lt $w.Count) -and ($o[$pre] -ceq $w[$pre])) { $pre++ }
  $suf = 0
  while (($suf -lt ($o.Count - $pre)) -and ($suf -lt ($w.Count - $pre)) -and ($o[$o.Count - 1 - $suf] -ceq $w[$w.Count - 1 - $suf])) { $suf++ }
  $lines = @()
  for ($i = $pre; $i -lt ($o.Count - $suf); $i++) { $lines += @{ t = '-'; text = [string]$o[$i] } }
  for ($i = $pre; $i -lt ($w.Count - $suf); $i++) { $lines += @{ t = '+'; text = [string]$w[$i] } }
  return @{ same = (($o.Count -eq $w.Count) -and ($pre -eq $o.Count)); prefix = $pre; suffix = $suf; lines = $lines }
}

function Mgmt-DiffTextPair($OldText, $NewText) {
  if (($null -eq $OldText) -and ($null -eq $NewText)) { return @{ same = $true; lines = @(); truncated = $false } }
  $o = @()
  $w = @()
  if ($null -ne $OldText) { $o = @($OldText -split "`r?`n") }
  if ($null -ne $NewText) { $w = @($NewText -split "`r?`n") }
  $truncated = $false
  if (($o.Count -gt 4000) -or ($w.Count -gt 4000)) {
    $o = @($o | Select-Object -First 4000)
    $w = @($w | Select-Object -First 4000)
    $truncated = $true
  }
  $same = $false
  $lines = @()
  if (($null -ne $OldText) -and ($null -ne $NewText)) {
    $d = Mgmt-SimpleDiff $o $w
    $same = [bool]$d.same
    $lines = @($d.lines | Select-Object -First 300)
    if (@($d.lines).Count -gt 300) { $truncated = $true }
  }
  else {
    foreach ($ln in $o) { $lines += @{ t = '-'; text = [string]$ln } }
    foreach ($ln in $w) { $lines += @{ t = '+'; text = [string]$ln } }
    $lines = @($lines | Select-Object -First 300)
    if ((($o.Count + $w.Count) -gt 300)) { $truncated = $true }
  }
  return @{ same = $same; lines = $lines; truncated = $truncated }
}

function Get-MgmtBackupDiff([string]$AutoDir, [string]$BackupId) {
  if ($BackupId -cnotmatch (Get-MgmtBackupIdPattern)) { throw 'バックアップ指定が不正です。' }
  $broot = Join-Path $AutoDir 'backups'
  $bdir = Join-Path $broot $BackupId
  if (-not (Test-Contained $bdir $broot)) { throw 'バックアップ指定が不正です。' }
  if ((-not (Test-Path -LiteralPath $bdir -PathType Container)) -or (Test-Reparse $bdir)) { throw 'バックアップが見つかりません。' }
  $mf = $null
  $mfPath = Join-Path $bdir 'manifest.json'
  if ((Test-Path -LiteralPath $mfPath -PathType Leaf) -and (-not (Test-Reparse $mfPath))) {
    try { $mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $mf = $null }
  }
  $bn = Get-MgmtBackupName $BackupId $mf
  if (-not $bn) { throw 'バックアップの対象が分かりません（旧形式のため対象不明）。推測した登録との比較はしません。' }
  $ent = Get-MgmtRegistryEntry $AutoDir $bn
  $repoFull = Get-NormPath ([string]$ent.path)
  $curAgents = Join-Path $repoFull 'AGENTS.md'
  $bakAgents = Join-Path $bdir 'AGENTS.md'
  $oldText = $null
  if ((Test-Path -LiteralPath $bakAgents -PathType Leaf) -and (-not (Test-Reparse $bakAgents))) { $oldText = [System.IO.File]::ReadAllText($bakAgents, [System.Text.Encoding]::UTF8) }
  $newText = $null
  if ((Test-Path -LiteralPath $curAgents -PathType Leaf) -and (-not (Test-Reparse $curAgents))) { $newText = [System.IO.File]::ReadAllText($curAgents, [System.Text.Encoding]::UTF8) }
  $da = Mgmt-DiffTextPair $oldText $newText
  $same = [bool]$da.same
  $lines = @($da.lines)
  $truncated = [bool]$da.truncated
  $curLocal = Join-Path $repoFull '.rulesync\rules\project-local.md'
  $bakLocal = Join-Path $bdir 'project-local.md'
  $oldLocal = $null
  if ((Test-Path -LiteralPath $bakLocal -PathType Leaf) -and (-not (Test-Reparse $bakLocal))) { $oldLocal = [System.IO.File]::ReadAllText($bakLocal, [System.Text.Encoding]::UTF8) }
  $newLocal = $null
  if ((Test-Path -LiteralPath $curLocal -PathType Leaf) -and (-not (Test-Reparse $curLocal))) { $newLocal = [System.IO.File]::ReadAllText($curLocal, [System.Text.Encoding]::UTF8) }
  $dl = Mgmt-DiffTextPair $oldLocal $newLocal
  $localSame = [bool]$dl.same
  $localLines = @($dl.lines)
  if ([bool]$dl.truncated) { $truncated = $true }
  $same = ($same -and $localSame)
  return @{
    id = $BackupId; name = $bn; same = $same; lines = $lines; truncated = $truncated
    localSame = $localSame; localLines = $localLines
    backupHasAgents = ($null -ne $oldText)
    currentHasAgents = ($null -ne $newText)
    backupHasLocal = ($null -ne $oldLocal)
    currentHasLocal = ($null -ne $newLocal)
  }
}

function Restore-MgmtBackup([string]$AutoDir, [string]$BackupId, [bool]$Confirm) {
  if (-not $Confirm) { throw '確認チェックを入れてください。' }
  if ($BackupId -cnotmatch (Get-MgmtBackupIdPattern)) { throw 'バックアップ指定が不正です。' }
  $broot = Join-Path $AutoDir 'backups'
  $bdir = Join-Path $broot $BackupId
  if (-not (Test-Contained $bdir $broot)) { throw 'バックアップ指定が不正です。' }
  if ((-not (Test-Path -LiteralPath $bdir -PathType Container)) -or (Test-Reparse $bdir)) { throw 'バックアップが見つかりません。' }
  $mf = $null
  $mfPath = Join-Path $bdir 'manifest.json'
  if ((Test-Path -LiteralPath $mfPath -PathType Leaf) -and (-not (Test-Reparse $mfPath))) {
    try { $mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $mf = $null }
  }
  $bn = Get-MgmtBackupName $BackupId $mf
  if (-not $bn) { throw 'バックアップの対象を信頼できません。名前と場所の記録がないため復元しません。' }
  # Restore requires trusted identity: manifest with safe internal name and
  # non-empty repo path. Legacy backups without it stay listable but are
  # never restored or diffed against a guessed repo (no wrong-repo overwrite,
  # no suffix inference).
  $trustName = ''
  $trustPath = ''
  try {
    if ($mf -and $mf.PSObject.Properties['name']) { $trustName = ([string]$mf.name).Trim() }
    if ($mf -and $mf.PSObject.Properties['path']) { $trustPath = ([string]$mf.path).Trim() }
  } catch {}
  if ((-not (Test-SafeName $trustName)) -or ($trustPath -eq '')) { throw 'バックアップの対象を信頼できません。名前と場所の記録がないため復元しません。' }
  $bn = $trustName
  $ent = Get-MgmtRegistryEntry $AutoDir $bn
  $repoFull = Get-NormPath ([string]$ent.path)
  $mfFull = ''
  try { $mfFull = Get-NormPath $trustPath } catch { $mfFull = '' }
  if (($mfFull -eq '') -or (-not ($mfFull.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase)))) {
    throw 'バックアップの対象と登録先が一致しません。別プロジェクト・移動後のため復元しません。'
  }
  if (-not (Test-Path -LiteralPath $repoFull -PathType Container)) { throw 'フォルダが存在しません。' }
  if (Test-Reparse $repoFull) { throw 'リンク・ジャンクションのフォルダには戻せません。' }
  # Scope: local-only backups (localrule saves with scope manifest) restore
  # only the local file and never touch AGENTS.md.
  $scope = 'full'
  try { if ($mf -and $mf.PSObject.Properties['scope'] -and ([string]$mf.scope -ceq 'local')) { $scope = 'local' } } catch {}
  $warn = ''
  $curAgents = Join-Path $repoFull 'AGENTS.md'
  $curLocal = Join-Path $repoFull '.rulesync\rules\project-local.md'
  $bakAgents = Join-Path $bdir 'AGENTS.md'
  $bakLocal = Join-Path $bdir 'project-local.md'
  # Plan every mutation first; refuse before touching anything.
  $steps = @()
  if ($scope -ceq 'local') {
    if (-not ((Test-Path -LiteralPath $bakLocal -PathType Leaf) -and (-not (Test-Reparse $bakLocal)))) { throw 'バックアップに project-local.md がありません。' }
    Assert-MgmtLocalParentClean $repoFull
    if (Test-Reparse $curLocal) { throw 'project-local.md がリンクになっています。' }
    $steps += @{ kind = 'copy'; src = $bakLocal; dst = $curLocal; mkdir = (-not (Test-Path -LiteralPath (Split-Path $curLocal -Parent) -PathType Container)); which = 'local' }
  }
  else {
    $bakHasAgents = ((Test-Path -LiteralPath $bakAgents -PathType Leaf) -and (-not (Test-Reparse $bakAgents)))
    $manifestSaysNoAgents = $false
    try { if ($mf -and $mf.PSObject.Properties['agentsPresent'] -and (-not [bool]$mf.agentsPresent)) { $manifestSaysNoAgents = $true } } catch {}
    if ($bakHasAgents) {
      if (Test-Reparse $curAgents) { throw 'AGENTS.md がリンクになっています。' }
      $steps += @{ kind = 'copy'; src = $bakAgents; dst = $curAgents; mkdir = $false; which = 'agents' }
    }
    elseif ($manifestSaysNoAgents) {
      if ((Test-Path -LiteralPath $curAgents) -and (Test-Reparse $curAgents)) { throw 'AGENTS.md がリンクになっています。' }
      if (Test-Path -LiteralPath $curAgents) { $steps += @{ kind = 'delete'; dst = $curAgents } }
    }
    else { throw 'バックアップに AGENTS.md がありません。' }
    $bakHasLocal = ((Test-Path -LiteralPath $bakLocal -PathType Leaf) -and (-not (Test-Reparse $bakLocal)))
    $manifestSaysNoLocal = $false
    try { if ($mf -and $mf.PSObject.Properties['localPresent'] -and (-not [bool]$mf.localPresent)) { $manifestSaysNoLocal = $true } } catch {}
    if ($bakHasLocal) {
      Assert-MgmtLocalParentClean $repoFull
      if (Test-Reparse $curLocal) { throw 'project-local.md がリンクになっています。' }
      $steps += @{ kind = 'copy'; src = $bakLocal; dst = $curLocal; mkdir = (-not (Test-Path -LiteralPath (Split-Path $curLocal -Parent) -PathType Container)); which = 'local' }
    }
    elseif ($manifestSaysNoLocal) {
      Assert-MgmtLocalParentClean $repoFull
      if ((Test-Path -LiteralPath $curLocal) -and (Test-Reparse $curLocal)) { throw 'project-local.md がリンクになっています。' }
      if (Test-Path -LiteralPath $curLocal) { $steps += @{ kind = 'delete'; dst = $curLocal } }
    }
    else { $warn = 'localSource はバックアップにないため現状維持しました。次回同期で上書きされる場合があります。' }
  }
  # Trust anchor: every copy source must match the manifest hash recorded at
  # backup time (before any mutation). A post-backup corruption is refused
  # here; a mutation between this check and the copy is caught by the
  # post-copy check below and rolled back. Missing expected hash fails closed.
  foreach ($st in $steps) {
    if ([string]$st.kind -cne 'copy') { continue }
    $expH = ''
    try {
      if ([string]$st.which -ceq 'local') { $expH = [string]$mf.localHash }
      else { $expH = [string]$mf.agentsHash }
    } catch { $expH = '' }
    if ([string]::IsNullOrWhiteSpace($expH)) { throw 'バックアップの検証情報がありません。復元しません。' }
    $st.exp = $expH
    $srcH = Get-FileHashHex ([string]$st.src)
    if ($srcH -cne $expH) { throw 'バックアップが破損しているため復元しません。' }
  }
  # Pause first so a failure can never leave a half-restored repo enabled.
  Set-MgmtEnabled $AutoDir $bn $false | Out-Null
  # Trust anchors: hash the current files BEFORE sheltering. The shelter
  # capture, every rollback source, and every rollback result are validated
  # against these immutable values (never a fresh, possibly corrupt read).
  $origAgentsPresent = (Test-Path -LiteralPath $curAgents -PathType Leaf)
  $origLocalPresent = (Test-Path -LiteralPath $curLocal -PathType Leaf)
  $origAgentsH = Get-FileHashHex $curAgents
  $origLocalH = Get-FileHashHex $curLocal
  $origMap = @{
    'AGENTS.md' = @{ present = [bool]$origAgentsPresent; hash = [string]$origAgentsH }
    'project-local.md' = @{ present = [bool]$origLocalPresent; hash = [string]$origLocalH }
  }
  # Shelter current state (lossless) for rollback and history.
  $pre = New-MgmtBackupDir $AutoDir ($bn + '-before-restore')
  if ($origAgentsPresent) { Copy-MgmtVerified $curAgents (Join-Path $pre 'AGENTS.md') }
  if ($origLocalPresent) { Copy-MgmtVerified $curLocal (Join-Path $pre 'project-local.md') }
  Write-MgmtPrivateJson (Join-Path $pre 'manifest.json') @{ schemaVersion = 1; name = $bn; displayName = (Get-MgmtDisplayName $ent); path = $repoFull; createdAt = ([DateTime]::UtcNow.ToString('o')); restoredFrom = $BackupId; agentsPresent = (Test-Path -LiteralPath $curAgents -PathType Leaf); localPresent = (Test-Path -LiteralPath $curLocal -PathType Leaf); agentsHash = (Get-FileHashHex $curAgents); localHash = (Get-FileHashHex $curLocal) }
  # Verify the shelter capture before any restore step runs.
  if ($origAgentsPresent) {
    if ((Get-FileHashHex (Join-Path $pre 'AGENTS.md')) -cne [string]$origAgentsH) { throw '退避の検証に失敗しました。復元しません。' }
  }
  if ($origLocalPresent) {
    if ((Get-FileHashHex (Join-Path $pre 'project-local.md')) -cne [string]$origLocalH) { throw '退避の検証に失敗しました。復元しません。' }
  }
  $applied = @()
  try {
    foreach ($st in $steps) {
      # Journal before operating so even a failed step itself is rolled back.
      if ([string]$st.kind -ceq 'delete') {
        $hadFile = (Test-Path -LiteralPath ([string]$st.dst) -PathType Leaf)
        $applied += @{ kind = 'delete'; dst = ([string]$st.dst); had = [bool]$hadFile }
        Remove-Item -LiteralPath ([string]$st.dst) -Force
      }
      else {
        $applied += @{ kind = 'copy'; dst = ([string]$st.dst) }
        if ([bool]$st.mkdir) { New-Item -ItemType Directory -Force -Path (Split-Path ([string]$st.dst) -Parent) | Out-Null }
        Copy-MgmtExpectedBytes ([string]$st.src) ([string]$st.dst) ([string]$st.exp) (Split-Path ([string]$st.dst) -Leaf)
      }
    }
  } catch {
    # Rollback validates every target against the pre-shelter trust anchors:
    # a corrupt shelter never overwrites the current file, and every target
    # is still attempted (one failure never suppresses the others).
    $rbErrs = @()
    try {
      foreach ($a in $applied) {
        try {
          $leaf = Split-Path ([string]$a.dst) -Leaf
          $exp = $null
          try { if ($origMap.ContainsKey($leaf)) { $exp = $origMap[$leaf] } } catch {}
          if ($null -eq $exp) { throw ('巻戻し対象が不明です: ' + $leaf) }
          $shelter = Join-Path $pre $leaf
          if ([bool]$exp.present) {
            if (-not (Test-Path -LiteralPath $shelter -PathType Leaf)) { throw ('退避がありません: ' + $leaf) }
            Copy-MgmtExpectedBytes $shelter ([string]$a.dst) ([string]$exp.hash) $leaf
          }
          else {
            if (Test-Path -LiteralPath ([string]$a.dst)) { Remove-Item -LiteralPath ([string]$a.dst) -Force }
            if (Test-Path -LiteralPath ([string]$a.dst)) { throw ('巻戻しで削除できません: ' + $leaf) }
          }
        } catch { $rbErrs += ($leaf + ': ' + $_.Exception.Message) }
      }
    } catch { $rbErrs += $_.Exception.Message }
    if ($rbErrs.Count -gt 0) { throw ('復元に失敗し、巻戻しも失敗しました。休止中のままです。先の退避を確認してください。: ' + ($rbErrs -join '; ')) }
    throw
  }
  return @{ ok = $true; name = $bn; backup = $pre; warning = $warn }
}

function Test-MgmtIntervalValid([int]$Minutes) {
  return (($Minutes -ge 5) -and ($Minutes -le 1440))
}

# Pure plan-input comparison (no I/O): verifies a plan-bound apply still sees
# exactly the approved registry/path/enabled/common SHA+text/local/AGENTS
# +existence/config/targets inputs for the requested names.
# Returns @{ok=$true} or @{ok=$false; error='...'} (first mismatch only).
# Pure inputs comparison (no I/O): flat base vs flat live must agree on
# common SHA+text/config/targets and every requested entry (path/enabled/
# local/AGENTS+existence+hash). Returns @{ok} or @{ok; error} (first mismatch).
function Test-MgmtInputsMatch($Base, $Live, [string[]]$Names) {
  try {
    if ([string](Get-MgmtField $Live 'commonSha') -cne [string](Get-MgmtField $Base 'commonSha')) { return @{ ok = $false; error = '共通ルールが変化しました。' } }
    if ([string](Get-MgmtField $Live 'commonText') -cne [string](Get-MgmtField $Base 'commonText')) { return @{ ok = $false; error = '共通ルールが変化しました。' } }
    if ([string](Get-MgmtField $Live 'configHash') -cne [string](Get-MgmtField $Base 'configHash')) { return @{ ok = $false; error = '設定が変化しました。' } }
    if ([string](Get-MgmtField $Live 'targets') -cne [string](Get-MgmtField $Base 'targets')) { return @{ ok = $false; error = '対象が変化しました。' } }
    $baseEntries = @()
    try { $baseEntries = @(Get-MgmtField $Base 'entries') } catch {}
    $liveEntries = @()
    try { $liveEntries = @(Get-MgmtField $Live 'entries') } catch {}
    foreach ($nm in @($Names)) {
      $pe = @($baseEntries | Where-Object { [string](Get-MgmtField $_ 'name') -ceq [string]$nm })
      $le = @($liveEntries | Where-Object { [string](Get-MgmtField $_ 'name') -ceq [string]$nm })
      if (($pe.Count -ne 1) -or ($le.Count -ne 1)) { return @{ ok = $false; error = ('対象がプランにありません: ' + [string]$nm) } }
      if ([string](Get-MgmtField $pe[0] 'path') -cne [string](Get-MgmtField $le[0] 'path')) { return @{ ok = $false; error = ('移動先が変化しました: ' + [string]$nm) } }
      if ([bool](Get-MgmtField $pe[0] 'enabled') -cne [bool](Get-MgmtField $le[0] 'enabled')) { return @{ ok = $false; error = ('有効/無効が変化しました: ' + [string]$nm) } }
      foreach ($ex in @('localExists', 'agentsExists')) {
        if ([bool](Get-MgmtField $pe[0] $ex) -cne [bool](Get-MgmtField $le[0] $ex)) { return @{ ok = $false; error = ('ファイルの有無が変化しました: ' + [string]$nm) } }
      }
      foreach ($hx in @('localHash', 'agentsHash')) {
        if ([string](Get-MgmtField $pe[0] $hx) -cne [string](Get-MgmtField $le[0] $hx)) {
          if ($hx -ceq 'localHash') { return @{ ok = $false; error = ('ローカル内容が変化しました: ' + [string]$nm) } }
          return @{ ok = $false; error = ('AGENTS内容が変化しました: ' + [string]$nm) }
        }
      }
    }
    return @{ ok = $true; error = '' }
  } catch { return @{ ok = $false; error = '入力照合に失敗しました。' } }
}

# Plan-bound apply verdict: plan must carry inputs, every requested project
# must have an approved successful output, and inputs must still match live.
function Test-MgmtPlanMatch($Plan, $Live, [string[]]$Names) {
  try {
    if ($null -eq $Plan) { return @{ ok = $false; error = 'プランがありません。' } }
    $schemaV = 0
    try { $schemaV = [int](Get-MgmtField $Plan 'schemaVersion') } catch {}
    if ($schemaV -ne 2) { return @{ ok = $false; error = '古いプランのため適用できません。反映前差分から作り直してください。' } }
    $hasInputs = $false
    try { $hasInputs = ($null -ne (Get-MgmtField $Plan 'inputs')) } catch {}
    if (-not $hasInputs) { return @{ ok = $false; error = '古いプランのため適用できません。反映前差分から作り直してください。' } }
    $planProjects = @()
    try { $planProjects = @(Get-MgmtField $Plan 'projects') } catch {}
    $planInputEntries = @()
    try { $planInputEntries = @(Get-MgmtField (Get-MgmtField $Plan 'inputs') 'entries') } catch {}
    foreach ($nm in @($Names)) {
      $pj = @($planProjects | Where-Object { [string](Get-MgmtField $_ 'name') -ceq [string]$nm })
      if (($pj.Count -ne 1) -or ([string](Get-MgmtField $pj[0] 'result') -cne 'success') -or ([string](Get-MgmtField $pj[0] 'generatedText') -eq '')) {
        return @{ ok = $false; error = ('承認済みの生成結果がありません: ' + [string]$nm) }
      }
      # The approved output must belong to the approved input entry: a plan
      # mixing an old output path with a new input path is never applicable.
      $pe = @($planInputEntries | Where-Object { [string](Get-MgmtField $_ 'name') -ceq [string]$nm })
      if ($pe.Count -ne 1) { return @{ ok = $false; error = ('対象がプランにありません: ' + [string]$nm) } }
      $outP = ''; $inP = ''
      try { $outP = ([string](Get-MgmtField $pj[0] 'path') -replace '/', '\') } catch { $outP = '' }
      try { $inP = ([string](Get-MgmtField $pe[0] 'path') -replace '/', '\') } catch { $inP = '' }
      if (($outP -eq '') -or ($inP -eq '') -or (-not $outP.Equals($inP, [System.StringComparison]::OrdinalIgnoreCase))) {
        return @{ ok = $false; error = ('承認済み生成結果と入力が一致しません: ' + [string]$nm) }
      }
      # Consumed-hash binding (schema v2): the pin and every output must
      # carry actual valid hashes (64 lowercase hex). Anything missing,
      # empty, or malformed refuses (re-preview required); a null localHash
      # is allowed only with an explicit boolean localExists=false input
      # (absent local), never general unknown presence.
      $planCommon = ''; $planCfg = ''
      try { $planCommon = [string](Get-MgmtField $Plan 'commonSha') } catch {}
      try { $planCfg = [string](Get-MgmtField $Plan 'configHash') } catch {}
      if (($planCommon -cnotmatch '^[0-9a-f]{64}$') -or ($planCfg -cnotmatch '^[0-9a-f]{64}$')) {
        return @{ ok = $false; error = ('承認済み生成結果と入力が一致しません: ' + [string]$nm) }
      }
      $ovCommon = ''
      try { if (Test-MgmtHasField $pj[0] 'commonSha') { $ovCommon = [string](Get-MgmtField $pj[0] 'commonSha') } } catch {}
      $ovCfg = ''
      try { if (Test-MgmtHasField $pj[0] 'configHash') { $ovCfg = [string](Get-MgmtField $pj[0] 'configHash') } } catch {}
      if (($ovCommon -cne $planCommon) -or ($ovCfg -cne $planCfg)) {
        return @{ ok = $false; error = ('承認済み生成結果と入力が一致しません: ' + [string]$nm) }
      }
      # localHash is checked on raw presence and raw-null identity (never a
      # [string] cast, which would conflate missing/empty/whitespace/null).
      # Both sides must carry the field; absence is allowed only when both
      # raw values are JSON null with an explicit boolean localExists=false.
      $hasInLoc = $false; $hasOvLoc = $false
      $rawInLoc = $null; $rawOvLoc = $null
      try { $hasInLoc = Test-MgmtHasField $pe[0] 'localHash'; if ($hasInLoc) { $rawInLoc = Get-MgmtField $pe[0] 'localHash' } } catch {}
      try { $hasOvLoc = Test-MgmtHasField $pj[0] 'localHash'; if ($hasOvLoc) { $rawOvLoc = Get-MgmtField $pj[0] 'localHash' } } catch {}
      if ($hasInLoc -and $hasOvLoc -and ($null -eq $rawInLoc) -and ($null -eq $rawOvLoc)) {
        $lfAbs = $null
        $absentOk = $false
        try { $lfAbs = Get-MgmtField $pe[0] 'localExists'; if (($lfAbs -is [bool]) -and (-not $lfAbs)) { $absentOk = $true } } catch {}
        if (-not $absentOk) {
          return @{ ok = $false; error = ('承認済み生成結果と入力が一致しません: ' + [string]$nm) }
        }
      }
      else {
        $inH = ''; $ovH = ''
        try { if ($null -ne $rawInLoc) { $inH = [string]$rawInLoc } } catch {}
        try { if ($null -ne $rawOvLoc) { $ovH = [string]$rawOvLoc } } catch {}
        if (($inH -cnotmatch '^[0-9a-f]{64}$') -or ($ovH -cnotmatch '^[0-9a-f]{64}$') -or ($ovH -cne $inH)) {
          return @{ ok = $false; error = ('承認済み生成結果と入力が一致しません: ' + [string]$nm) }
        }
      }
    }
    $flatPlan = @{
      commonSha = [string](Get-MgmtField $Plan 'commonSha'); commonText = [string](Get-MgmtField $Plan 'commonText')
      configHash = [string](Get-MgmtField $Plan 'configHash'); targets = [string](Get-MgmtField $Plan 'targets')
      entries = @()
    }
    try { $flatPlan.entries = @(Get-MgmtField (Get-MgmtField $Plan 'inputs') 'entries') } catch {}
    return (Test-MgmtInputsMatch $flatPlan $Live $Names)
  } catch { return @{ ok = $false; error = 'プラン照合に失敗しました。' } }
}

# Live input snapshot for plan comparison (server side; dashboard helpers).
function Get-MgmtPlanLive([string]$AutoDir) {
  $reg = @(Get-Registry $AutoDir)
  $prevDir = Join-Path (Split-Path $AutoDir -Parent) 'project-common-preview'
  $curated = Join-Path $prevDir '.rulesync\rules\.curated\project.md'
  $cfg = Join-Path $prevDir 'rulesync.jsonc'
  $ct = ''
  $sha = ''
  if ((Test-Path -LiteralPath $curated -PathType Leaf) -and (-not (Test-Reparse $curated))) {
    try { $ct = [System.IO.File]::ReadAllText($curated, [System.Text.Encoding]::UTF8) } catch { $ct = '' }
    if ($ct -ne '') { try { $sha = Get-FileHashHex $curated } catch { $sha = '' } }
  }
  $cfgHash = ''
  if ((Test-Path -LiteralPath $cfg -PathType Leaf) -and (-not (Test-Reparse $cfg))) {
    try { $cfgHash = Get-FileHashHex $cfg } catch { $cfgHash = '' }
  }
  $ents = @()
  foreach ($e in $reg) {
    $nm = [string]$e.name
    $rp = ''
    try { $rp = Get-NormPath ([string]$e.path) } catch { $rp = [string]$e.path }
    $lf = Join-Path $rp '.rulesync\rules\project-local.md'
    $af = Join-Path $rp 'AGENTS.md'
    $lh = $null; $ah = $null; $le = $false; $ae = $false
    try { if ((Test-Path -LiteralPath $lf -PathType Leaf) -and (-not (Test-Reparse $lf))) { $le = $true; $lh = Get-FileHashHex $lf } } catch {}
    try { if ((Test-Path -LiteralPath $af -PathType Leaf) -and (-not (Test-Reparse $af))) { $ae = $true; $ah = Get-FileHashHex $af } } catch {}
    $ents += @{ name = $nm; path = $rp; enabled = (Get-MgmtEffectiveEnabled $e); localExists = [bool]$le; localHash = $lh; agentsExists = [bool]$ae; agentsHash = $ah }
  }
  return @{ commonSha = $sha; commonText = $ct; configHash = $cfgHash; targets = 'codexcli,opencode'; entries = $ents }
}

function Parse-MgmtInterval([string]$Iso) {
  if ((-not $Iso) -or ($Iso -cnotmatch '^PT(?:(\d+)H)?(?:(\d+)M)?$')) { return $null }
  $h = 0
  $m = 0
  if ($Matches[1]) { $h = [int]$Matches[1] }
  if ($Matches[2]) { $m = [int]$Matches[2] }
  $t = ($h * 60 + $m)
  if ($t -le 0) { return $null }
  return $t
}

function Format-MgmtInterval([int]$Minutes) {
  return ('PT' + $Minutes + 'M')
}

# Project 同期タスク名は1箇所に固定する (任意タスク名は受け付けない)。
# 値は settings.json (taskNameProject) で変更できる。既定は Shirube の現行値。
function Get-MgmtProjectTaskName { return (Get-ShirubeSetting -Name 'taskNameProject' -Default 'Shirube Project Auto Sync') }

# Pre-rename installs keep working until their task is migrated: the legacy
# task is used only when the new default is absent. Custom settings never fall back.
function Get-MgmtProjectScheduledTask([string]$TaskName) {
  if ([string]::IsNullOrWhiteSpace($TaskName)) { $TaskName = Get-MgmtProjectTaskName }
  try { return @{ name = $TaskName; task = (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) } }
  catch {
    $original = $_
    if ($TaskName -cne 'Shirube Project Auto Sync') { throw $original }
    # Only a missing task means "not migrated yet"; access denied etc. must surface.
    if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) { throw $original }
    $legacy = 'Rulesync Project Auto Sync'
    try { return @{ name = $legacy; task = (Get-ScheduledTask -TaskName $legacy -ErrorAction Stop) } }
    catch {
      # A missing legacy task keeps the new-name error; any other failure is real.
      if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { throw $original }
      throw
    }
  }
}

function Get-MgmtProjectInterval([string]$TaskName) {
  # An empty name keeps the existing behavior (resolve from settings now).
  $t = (Get-MgmtProjectScheduledTask $TaskName).task
  foreach ($tr in $t.Triggers) {
    try {
      if ($tr.CimClass.CimClassName -ceq 'MSFT_TaskTimeTrigger') {
        $v = Parse-MgmtInterval ([string]$tr.Repetition.Interval)
        if ($v) { return $v }
      }
    } catch {}
  }
  throw 'Project同期タスクの間隔を取得できませんでした。'
}

function Set-MgmtProjectInterval([string]$TaskName, [int]$Minutes) {
  # One read per operation: validate and mutate the same task name.
  $allowed = Get-MgmtProjectTaskName
  if ($TaskName -cne $allowed) { throw 'Project同期タスクのみ変更できます。(Global は対象外)' }
  if (-not (Test-MgmtIntervalValid $Minutes)) { throw '間隔は5〜1440分で指定してください。' }
  $r = Get-MgmtProjectScheduledTask $TaskName
  $TaskName = [string]$r.name
  $t = $r.task
  $trs = @($t.Triggers)
  $found = $false
  foreach ($tr in $trs) {
    if ($tr.CimClass.CimClassName -ceq 'MSFT_TaskTimeTrigger') {
      $tr.Repetition.Interval = (Format-MgmtInterval $Minutes)
      $found = $true
    }
  }
  if (-not $found) { throw 'Project同期タスクに時刻トリガーがありません。' }
  Set-ScheduledTask -TaskName $TaskName -Trigger $trs -ErrorAction Stop | Out-Null
  return @{ ok = $true; minutes = $Minutes }
}

function Get-MgmtExport([string]$AutoDir) {
  $reg = @(Get-Registry $AutoDir)
  $projs = @()
  foreach ($e in $reg) {
    $projs += @{ name = [string]$e.name; path = [string]$e.path; enabled = (Get-MgmtEffectiveEnabled $e); displayName = (Get-MgmtDisplayName $e) }
  }
  $iv = $null
  try { $iv = Get-MgmtProjectInterval } catch { $iv = $null }
  return @{ schemaVersion = 1; exportedAt = ([DateTime]::UtcNow.ToString('o')); projects = $projs; intervalMinutes = $iv }
}

function Get-MgmtImportPreview([string]$AutoDir, $Data, [string]$TaskName) {
  $items = @()
  try {
    $pv = Get-MgmtField $Data 'projects'
    if ($pv) { $items = @($pv) }
  } catch {}
  $reg = @(Get-Registry $AutoDir)
  $byName = @{}
  $byPath = @{}
  $byDisplay = @{}
  foreach ($e in $reg) {
    $byName[[string]$e.name] = $true
    try { $byDisplay[([string](Get-MgmtDisplayName $e)).ToLowerInvariant()] = [string]$e.name } catch {}
    try { $byPath[(Get-NormPath ([string]$e.path))] = [string]$e.name } catch {}
  }
  $add = @()
  $skip = @()
  $conflict = @()
  $invalid = @()
  foreach ($it in $items) {    $nm = [string](Get-MgmtField $it 'name')
    $ph = [string](Get-MgmtField $it 'path')
    $en = Get-MgmtField $it 'enabled'
    if (-not (Test-SafeName $nm)) { $invalid += @{ name = $nm; path = $ph; reason = '名前が不正です。' }; continue }
    if ([string]::IsNullOrWhiteSpace($ph)) { $invalid += @{ name = $nm; path = $ph; reason = 'パスが空です。' }; continue }
    if (-not (Test-FullyQualified $ph.Trim())) { $invalid += @{ name = $nm; path = $ph; reason = '絶対パスではありません。' }; continue }
    if (Test-PathHasShellMeta $ph) { $invalid += @{ name = $nm; path = $ph; reason = 'パスに記号が含まれています。' }; continue }
    if (($null -ne $en) -and ($en -isnot [bool])) { $invalid += @{ name = $nm; path = $ph; reason = 'enabled は true/false で指定してください。' }; continue }
    $dn = Get-MgmtField $it 'displayName'
    if ($null -eq $dn) { $dn = $nm }
    else { $dn = ([string]$dn).Trim() }
    if (-not (Test-MgmtDisplayNameValid $dn)) { $invalid += @{ name = $nm; path = $ph; reason = '表示名が不正です。' }; continue }
    $norm = ''
    try { $norm = Get-NormPath ($ph.Trim()) } catch { $invalid += @{ name = $nm; path = $ph; reason = 'パスを解釈できません。' }; continue }
    $warn = ''
    if (-not (Test-Path -LiteralPath $norm -PathType Container)) { $warn = 'フォルダが存在しません。作成後に同期してください。' }
    elseif (Test-Reparse $norm) { $warn = 'リンク・ジャンクションの可能性があります。実体を確認してください。' }
    if ($byName.ContainsKey($nm)) {
      $cur = @($reg | Where-Object { [string]$_.name -ceq $nm })[0]
      $curNorm = ''
      try { $curNorm = Get-NormPath ([string]$cur.path) } catch {}
      if ($curNorm.Equals($norm, [System.StringComparison]::OrdinalIgnoreCase)) { $skip += @{ name = $nm; path = $norm; reason = '同一のため維持します。' } }
      else { $conflict += @{ name = $nm; path = $norm; reason = '同名の登録が別のパスを指しています。'; current = [string]$cur.path } }
      continue
    }
    if ($byPath.ContainsKey($norm)) { $conflict += @{ name = $nm; path = $norm; reason = '同パスの登録があります。'; current = $byPath[$norm] }; continue }
    $dnKey = $dn.ToLowerInvariant()
    if ($byDisplay.ContainsKey($dnKey)) { $conflict += @{ name = $nm; path = $norm; reason = '同表示名の登録があります。'; current = $byDisplay[$dnKey] }; continue }
    $row = @{ name = $nm; path = $norm; displayName = $dn }
    if ($null -ne $en) { $row.enabled = [bool]$en }
    if ($warn -ne '') { $row.warning = $warn }
    $add += $row
    $byName[$nm] = $true
    $byPath[$norm] = $nm
    $byDisplay[$dnKey] = $nm
  }
  # Interval travels with the export but applies only to the Project task (Global never changes).
  $ivIn = Get-MgmtField $Data 'intervalMinutes'
  $ivCur = $null
  try { $ivCur = Get-MgmtProjectInterval $TaskName } catch { $ivCur = $null }
  $ivInfo = @{ current = $ivCur; incoming = $null; valid = $true; willChange = $false; reason = '' }
  if ($null -ne $ivIn) {
    $ivNum = 0
    $ivOk = $false
    try { $ivNum = [int]$ivIn; $ivOk = (Test-MgmtIntervalValid $ivNum) } catch { $ivOk = $false }
    if (-not $ivOk) {
      $invalid += @{ name = '(interval)'; path = ''; reason = '間隔は5〜1440分の整数で指定してください。' }
      $ivInfo.valid = $false
      $ivInfo.reason = '間隔は5〜1440分の整数で指定してください。'
    }
    else {
      $ivInfo.incoming = $ivNum
      $ivInfo.willChange = ($ivCur -ne $ivNum)
    }
  }
  return @{ add = $add; skip = $skip; conflict = $conflict; invalid = $invalid; interval = $ivInfo }
}

function Import-MgmtRegistry([string]$AutoDir, $Data, [bool]$Confirm) {
  if (-not $Confirm) { throw '確認チェックを入れてください。' }
  # Pin the target task for the whole import (preview, apply, rollback, verify).
  $taskName = Get-MgmtProjectTaskName
  $prev = Get-MgmtImportPreview $AutoDir $Data $taskName
  if ($prev.invalid.Count -gt 0) { throw '不正な項目があります。修正してから取り込んでください。' }
  if ($prev.conflict.Count -gt 0) { throw '競合があります。個別に整理してから取り込んでください。' }
  $reg = @(Get-Registry $AutoDir)
  $regBefore = @($reg)
  $added = 0
  foreach ($a in $prev.add) {
    $row = @{ name = [string](Get-MgmtField $a 'name'); path = [string](Get-MgmtField $a 'path'); displayName = [string](Get-MgmtField $a 'displayName') }
    if (Test-MgmtHasField $a 'enabled') { $row.enabled = [bool](Get-MgmtField $a 'enabled') }
    $reg += [pscustomobject]$row
    $added++
  }
  if ($added -gt 0) { Write-RegistryAtomicLocked $AutoDir $reg }
  $ivApplied = $false
  if ($prev.interval.willChange) {
    try { Set-MgmtProjectInterval $taskName ([int]$prev.interval.incoming) | Out-Null; $ivApplied = $true }
    catch {
      $applyErr = $_.Exception.Message
      # Roll back the just-added entries so a scheduler failure never leaves
      # a partial apply (registry changed, interval not). Old rows are kept.
      $rbErr = $null
      if ($added -gt 0) {
        try { Write-RegistryAtomicLocked $AutoDir $regBefore }
        catch { $rbErr = $_.Exception.Message }
      }
      if ($rbErr) { throw ('間隔の適用に失敗し、登録の巻戻しも失敗しました。手動で確認してください。') }
      # Post-write scheduler failure may have changed the interval before
      # throwing: restore the previous value and verify, else report the
      # partial state explicitly instead of claiming it was restored.
      $prevIv = $prev.interval.current
      if (($null -ne $prevIv) -and (Test-MgmtIntervalValid ([int]$prevIv))) {
        $curIv = $null
        $curReadFailed = $false
        try { $curIv = Get-MgmtProjectInterval $taskName } catch { $curReadFailed = $true }
        # A failed re-read never skips the restore: the previous value is
        # known, so attempt it and report verification explicitly.
        if ($curReadFailed -or ($null -eq $curIv) -or ($curIv -ne [int]$prevIv)) {
          try { Set-MgmtProjectInterval $taskName ([int]$prevIv) | Out-Null }
          catch { throw ('間隔の適用に失敗し、間隔の巻戻しも失敗しました。登録は取り消しましたが間隔を手動で確認してください。') }
          $chkIv = $null
          try { $chkIv = Get-MgmtProjectInterval $taskName } catch { $chkIv = $null }
          if ($chkIv -ne [int]$prevIv) { throw ('間隔の適用に失敗し、間隔の巻戻しを確認できませんでした。登録は取り消しましたが間隔を手動で確認してください。') }
          throw ('間隔の適用に失敗したため、登録と間隔を取り消しました（元の間隔に戻しました）。再試行してください。')
        }
      }
      elseif ($null -eq $prevIv) {
        throw ('間隔の適用に失敗したため登録を取り消しましたが、変更前の間隔が不明のため間隔を手動で確認してください。')
      }
      throw ('間隔の適用に失敗したため、登録を取り消しました。再試行してください。')
    }
  }
  return @{ ok = $true; added = $added; skipped = ($prev.skip.Count); intervalApplied = $ivApplied; intervalMinutes = $prev.interval.incoming }
}
