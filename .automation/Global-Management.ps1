# Global-Management.ps1 - Global auto sync helpers (dev source).
# Dashboard-Server.ps1 / Sync-GlobalRules.ps1 から dot-source される純粋関数群。
# listen なし、任意コマンドなし。Project-Management.ps1 には依存しない
# (Sync-GlobalRules 単体 dot-source でも動作するよう自己完結)。
# 変更系は atomic private JSON のみ。secret は扱わない・出力しない。
$ErrorActionPreference = 'Stop'

# 個人設定 (settings.json) は Settings.ps1 経由。Settings.ps1 が無い単体コピー
# (scratch 配備) でも既定値で動くよう、その場合だけ既定値スタブを置く。
$shirubeSettingsScript = Join-Path $PSScriptRoot 'Settings.ps1'
if (Test-Path -LiteralPath $shirubeSettingsScript -PathType Leaf) { . $shirubeSettingsScript }
if (-not (Get-Command Get-ShirubeSetting -ErrorAction SilentlyContinue)) { function Get-ShirubeSetting { param([string]$Name = '', $Default = $null) return $Default } }

function Global-NormPath([string]$P) { return [System.IO.Path]::GetFullPath(($P -replace '/', '\')) }
function Global-Contained([string]$Candidate, [string]$Root) {
  $c = Global-NormPath $Candidate; $r = Global-NormPath $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}
# Canonical comparison form of a root: a trailing separator never changes
# identity (foo\ and foo are the same root) so it is dropped, but a drive root
# keeps its separator (C: alone is drive-relative). UNC share roots
# canonicalize the same way, keeping both spellings equal.
function Global-RootCanonical([string]$P) {
  $p = Global-NormPath $P
  if ($p -match '^[A-Za-z]:\\$') { return $p }
  return $p.TrimEnd('\')
}
function Global-FullyQualified([string]$P) { return ($P -match '^[A-Za-z]:\\') -or ($P -match '^\\\\') }
function Global-Reparse([string]$P) {
  $it = Get-Item -LiteralPath $P -Force -ErrorAction SilentlyContinue
  if (-not $it) { return $false }
  return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Global-FileHashHex([string]$File) {
  try {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return ((($h.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')) }
    finally { $h.Dispose() }
  } catch { return $null }
}
function Global-PrivateSids {
  $sids = @()
  try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544' } catch {}
  return @($sids | Where-Object { $_ -ne $null })
}
function Write-GlobalPrivateJson([string]$Path, $Value, [string]$TrustedRoot = "") {
  # Residual TOCTOU: chain inspection and the publish below are not a single
  # handle-based transaction; a swap in between still throws late or not at
  # all. Callers re-inspect immediately before each call and helpers re-check
  # right before temp creation and again before atomic publish.
  if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Path $TrustedRoot '出力先' }
  if (Global-Reparse $Path) { throw 'リンクへの書込みはできません。' }
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw '出力先フォルダがありません。' }
  if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $dir $TrustedRoot '出力先' }
  $tmp = Join-Path $dir ('.gmgmt-tmp-' + [System.Guid]::NewGuid().ToString('N'))
  if (-not (Global-Contained $tmp $dir)) { throw '一時先を確認できませんでした。' }
  $sec = New-Object System.Security.AccessControl.FileSecurity
  $sec.SetAccessRuleProtection($true, $false)
  foreach ($sid in (Global-PrivateSids)) { $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow'))) }
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Value -Depth 12))
  $fs = [System.IO.File]::Create($tmp, 4096, [System.IO.FileOptions]::None, $sec)
  try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  try {
    if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Path $TrustedRoot '出力先' }
    if (Test-Path -LiteralPath $Path) {
      $bak = Join-Path $dir ('.gmgmt-bak-' + [System.Guid]::NewGuid().ToString('N'))
      [System.IO.File]::Replace($tmp, $Path, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch {}
    }
    else { [System.IO.File]::Move($tmp, $Path) | Out-Null }
  }
  catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    throw
  }
}
function Global-KnownSecretValues([string]$Token) {
  $vals = @()
  if ($Token) { $vals += $Token }
  foreach ($e in @($env:GITHUB_TOKEN, $env:GH_TOKEN)) {
    if ($e -and ([string]$e).Trim() -ne '') { $vals += [string]$e }
  }
  return @($vals | Select-Object -Unique)
}
function Redact-GlobalText([string]$Text, [string]$Token) {
  $r = $Text
  foreach ($v in (Global-KnownSecretValues $Token)) { $r = $r.Replace($v, '***') }
  $r = [regex]::Replace($r, '(?i)(github_token|gh_token|bearer)[=:\s]+\S+', '$1=***')
  $r = [regex]::Replace($r, '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{8,}', '${1}_***')
  $r = [regex]::Replace($r, 'github_pat_[A-Za-z0-9_]{8,}', 'github_pat_***')
  return $r
}
function Global-ParentReparse([string]$File, [string]$Root) {
  try {
    $rf = Global-NormPath $Root
    $pd = Global-NormPath (Split-Path $File -Parent)
    $guard = 0
    while (($pd -cne $rf) -and (Global-Contained $pd $rf) -and ($guard -lt 32)) {
      if (Global-Reparse $pd) { return $true }
      $pd = Global-NormPath (Split-Path $pd -Parent)
      $guard++
    }
  } catch { return $false }
  return $false
}
function Global-AssertNoLinkChain([string]$File, [string]$Root, [string]$What) {
  if (Global-Reparse $Root) { throw ($What + 'の配置先がリンクになっています。') }
  if ((Test-Path -LiteralPath $File) -and (Global-Reparse $File)) { throw ($What + 'がリンクになっています。') }
  if (Global-ParentReparse $File $Root) { throw ($What + 'の親フォルダがリンクになっています。') }
}
function Global-MaxContentBytes { return 1048576 }
function Global-MaxPlanBytes { return 2097152 }
function Global-MaxPlanTextChars { return 524288 }
function Test-GlobalTextSizeOk([string]$Text) {
  if ($null -eq $Text) { return $true }
  return ([string]$Text).Length -le (Global-MaxPlanTextChars)
}
# Bounded read: at most MaxChars+1 chars allocated however large the file is.
function Global-ReadBoundedText([string]$File, [int]$MaxChars) {
  $sr = New-Object System.IO.StreamReader($File, [System.Text.Encoding]::UTF8, $true)
  try {
    $buf = New-Object char[] ($MaxChars + 1)
    $n = $sr.ReadBlock($buf, 0, ($MaxChars + 1))
    if ($n -gt $MaxChars) { return @{ text = (New-Object string($buf, 0, $MaxChars)); truncated = $true } }
    return @{ text = (New-Object string($buf, 0, $n)); truncated = $false }
  } finally { $sr.Close() }
}
# Bounded byte read: length pre-check before any allocation, then a capped
# streaming read so growth between check and read cannot over-allocate.
function Global-ReadBoundedBytes([string]$File, [int]$MaxBytes) {
  $len = (Get-Item -LiteralPath $File -Force -ErrorAction Stop).Length
  if ($len -gt $MaxBytes) { return @{ bytes = ([byte[]]@()); truncated = $true } }
  $fs = [System.IO.File]::OpenRead($File)
  try {
    $buf = New-Object byte[] ($MaxBytes + 1)
    $total = 0
    while ($total -le $MaxBytes) {
      $n = $fs.Read($buf, $total, ($MaxBytes + 1 - $total))
      if ($n -le 0) { break }
      $total += $n
    }
    if ($total -gt $MaxBytes) { return @{ bytes = ([byte[]]@()); truncated = $true } }
    $out = New-Object byte[] $total
    if ($total -gt 0) { [System.Buffer]::BlockCopy($buf, 0, $out, 0, $total) }
    return @{ bytes = $out; truncated = $false }
  } finally { $fs.Close() }
}
function Global-HashBytesHex([byte[]]$Bytes) {
  $h = [System.Security.Cryptography.SHA256]::Create()
  try { return ((($h.ComputeHash($Bytes)) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $h.Dispose() }
}
function Assert-GlobalPlanFileSize([string]$PlanFile) {
  $len = (Get-Item -LiteralPath $PlanFile -Force -ErrorAction Stop).Length
  if ($len -gt (Global-MaxPlanBytes)) { throw 'プランが大きすぎるため適用できません。反映前プレビューから作り直してください。' }
}
function Global-ProtectPrivateFile([string]$File, [string]$TrustedRoot = "") {
  if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $File $TrustedRoot '権限変更' }
  if (Global-Reparse $File) { throw 'リンクの権限は変更しません。' }
  $sec = New-Object System.Security.AccessControl.FileSecurity
  $sec.SetAccessRuleProtection($true, $false)
  foreach ($sid in (Global-PrivateSids)) { $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow'))) }
  Set-Acl -LiteralPath $File -AclObject $sec
}
function Copy-GlobalVerified([string]$Src, [string]$Dst, [string]$SrcRoot = "", [string]$DstRoot = "") {
  if (($SrcRoot -ne '') -and ($SrcRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Src $SrcRoot '複写元' }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Dst $DstRoot '複写先' }
  Copy-Item -LiteralPath $Src -Destination $Dst -Force
  if (($SrcRoot -ne '') -and ($SrcRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Src $SrcRoot '複写元' }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Dst $DstRoot '複写先' }
  $a = Global-FileHashHex $Src
  $b = Global-FileHashHex $Dst
  if ((-not $a) -or ($a -cne $b)) { throw '複写の検証に失敗しました。' }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Global-ProtectPrivateFile $Dst $DstRoot }
  else { Global-ProtectPrivateFile $Dst }
}
# Single-read verified publish (same contract as the project helper): hash the
# source bytes once, publish exactly those bytes atomically, confirm the result.
# Bounded: size pre-check plus a capped read, so overlarge sources fail closed
# without ever allocating the full content.
function Copy-GlobalExpectedBytes([string]$Src, [string]$Dst, [string]$ExpectedHash, [string]$What, [string]$SrcRoot = "", [string]$DstRoot = "") {
  if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { throw ('バックアップの検証情報がありません。復元しません: ' + $What) }
  if (($SrcRoot -ne '') -and ($SrcRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Src $SrcRoot '復元元' }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Dst $DstRoot '復元先' }
  if (Global-Reparse $Src) { throw ('リンクから復元しません: ' + $What) }
  if ((Test-Path -LiteralPath $Dst) -and (Global-Reparse $Dst)) { throw ('リンクへ復元しません: ' + $What) }
  $rb = Global-ReadBoundedBytes $Src (Global-MaxContentBytes)
  if ([bool]$rb.truncated) { throw ('大きすぎるため復元しません: ' + $What) }
  $bytes = [byte[]]$rb.bytes
  $hex = Global-HashBytesHex $bytes
  if ($hex -cne $ExpectedHash) { throw ('バックアップが破損しているため復元しません: ' + $What) }
  if (($SrcRoot -ne '') -and ($SrcRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Src $SrcRoot '復元元' }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Dst $DstRoot '復元先' }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Write-GlobalFileAtomicBytes $Dst $bytes $DstRoot }
  else { Write-GlobalFileAtomicBytes $Dst $bytes }
  if (($DstRoot -ne '') -and ($DstRoot.Trim() -ne '')) { Global-AssertNoLinkChain $Dst $DstRoot '復元先' }
  $got = Global-FileHashHex $Dst
  if ($got -cne $ExpectedHash) { throw ('復元結果が一致しません: ' + $What) }
}
function Write-GlobalFileAtomicBytes([string]$File, [byte[]]$Bytes, [string]$TrustedRoot = "") {
  if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $File $TrustedRoot '出力先' }
  if (Global-Reparse $File) { throw 'リンクへの書込みはできません。' }
  $dir = Split-Path $File -Parent
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    # Restore must be able to recreate a provider folder that was removed after
    # the verified diff (.codex / .config\opencode). Creation stays inside a
    # trusted, existing root and goes level by level; every existing ancestor is
    # re-inspected, so a linked parent still refuses (no write-through).
    if (($TrustedRoot -eq '') -or ($TrustedRoot.Trim() -eq '')) { throw '出力先フォルダがありません。' }
    if (-not (Global-Contained $File $TrustedRoot)) { throw '出力先を確認できませんでした。' }
    # Canonical root: a trailing separator on HOME_DIR (= ...\home\) must
    # compare equal to the separator-less walk paths, while a drive root keeps
    # its separator.
    $rootN = Global-RootCanonical $TrustedRoot
    if (-not (Test-Path -LiteralPath $rootN -PathType Container)) { throw '出力先フォルダがありません。' }
    $walk = Global-NormPath $dir
    $missing = @()
    $guard = 0
    while (($walk -ine $rootN) -and (Global-Contained $walk $rootN) -and ($guard -lt 64)) {
      if (Test-Path -LiteralPath $walk -PathType Container) {
        if (Global-Reparse $walk) { throw '出力先の親フォルダがリンクになっています。' }
      }
      else { $missing += $walk }
      $walk = Global-NormPath (Split-Path $walk -Parent)
      $guard++
    }
    if ($walk -ine $rootN) { throw '出力先を確認できませんでした。' }
    for ($mi = ($missing.Count - 1); $mi -ge 0; $mi--) {
      $mk = $missing[$mi]
      if (-not (Global-Contained $mk $rootN)) { throw '出力先を確認できませんでした。' }
      try { New-Item -ItemType Directory -Force -Path $mk | Out-Null } catch { throw '出力先フォルダがありません。' }
      if (Global-Reparse $mk) { throw '出力先の親フォルダがリンクになっています。' }
    }
    if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $File $TrustedRoot '出力先' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw '出力先フォルダがありません。' }
  }
  if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $dir $TrustedRoot '出力先' }
  $tmp = Join-Path $dir ('.gmgmt-tmp-' + [System.Guid]::NewGuid().ToString('N'))
  if (-not (Global-Contained $tmp $dir)) { throw '一時先を確認できませんでした。' }
  $sec = New-Object System.Security.AccessControl.FileSecurity
  $sec.SetAccessRuleProtection($true, $false)
  foreach ($sid in (Global-PrivateSids)) { $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow'))) }
  $fs = [System.IO.File]::Create($tmp, 4096, [System.IO.FileOptions]::None, $sec)
  try { $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Dispose() }
  try {
    if (($TrustedRoot -ne '') -and ($TrustedRoot.Trim() -ne '')) { Global-AssertNoLinkChain $File $TrustedRoot '出力先' }
    if (Test-Path -LiteralPath $File) {
      $bak = Join-Path $dir ('.gmgmt-bak-' + [System.Guid]::NewGuid().ToString('N'))
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
function Global-SimpleDiff([string[]]$Old, [string[]]$New) {
  $o = @($Old)
  $w = @($New)
  $pre = 0
  while (($pre -lt $o.Count) -and ($pre -lt $w.Count) -and ($o[$pre] -ceq $w[$pre])) { $pre++ }
  $suf = 0
  while (($suf -lt ($o.Count - $pre)) -and ($suf -lt ($w.Count - $pre)) -and ($o[$o.Count - 1 - $suf] -ceq $w[$w.Count - 1 - $suf])) { $suf++ }
  $lines = @()
  for ($i = $pre; $i -lt ($o.Count - $suf); $i++) { $lines += @{ t = '-'; text = [string]$o[$i] } }
  for ($i = $pre; $i -lt ($w.Count - $suf); $i++) { $lines += @{ t = '+'; text = [string]$w[$i] } }
  return @{ same = (($o.Count -eq $w.Count) -and ($pre -eq $o.Count)); lines = $lines }
}
function Global-DiffTextPair($OldText, $NewText) {
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
    $d = Global-SimpleDiff $o $w
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

# Fixed task name: no arbitrary task parameter exists anywhere in this module.
# 値は settings.json (taskNameGlobal) で変更できる。既定は Shirube の現行値。
function Get-GlobalTaskName { return (Get-ShirubeSetting -Name 'taskNameGlobal' -Default 'Shirube Global Auto Sync') }

# Pre-rename installs keep working until their task is migrated: the legacy
# task is used only when the new default is absent. Custom settings never fall back.
function Get-GlobalScheduledTask {
  $name = Get-GlobalTaskName
  try { return @{ name = $name; task = (Get-ScheduledTask -TaskName $name -ErrorAction Stop) } }
  catch {
    $original = $_
    if ($name -cne 'Shirube Global Auto Sync') { throw $original }
    # Only a missing task means "not migrated yet"; access denied etc. must surface.
    if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) { throw $original }
    $legacy = 'Rulesync Global Auto Sync'
    try { return @{ name = $legacy; task = (Get-ScheduledTask -TaskName $legacy -ErrorAction Stop) } }
    catch {
      # A missing legacy task keeps the new-name error; any other failure is real.
      if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { throw $original }
      throw
    }
  }
}

# Fixed provider catalog: one generated rules file per target. Paths are
# hard-coded (never derived from user input), so a request can only name an
# allowlisted ID. Order is display order; defaults stay codexcli/opencode.
function Get-GlobalProviderCatalog {
  return @(
    @{ id = 'codexcli'; label = 'Codex'; rel = '.codex\AGENTS.md' },
    @{ id = 'opencode'; label = 'OpenCode'; rel = '.config\opencode\AGENTS.md' },
    @{ id = 'claudecode'; label = 'Claude Code'; rel = '.claude\CLAUDE.md' },
    @{ id = 'cline'; label = 'Cline'; rel = '.agents\AGENTS.md' },
    @{ id = 'copilotcli'; label = 'GitHub Copilot CLI'; rel = '.copilot\copilot-instructions.md' },
    @{ id = 'antigravity-cli'; label = 'Antigravity CLI'; rel = '.gemini\GEMINI.md' },
    @{ id = 'continue'; label = 'Continue'; rel = '.continue\rules\AGENTS.md' },
    @{ id = 'roo'; label = 'Roo Code'; rel = '.roo\rules\AGENTS.md' },
    @{ id = 'goose'; label = 'Goose'; rel = '.config\goose\.goosehints' },
    @{ id = 'devin'; label = 'Devin'; rel = '.config\devin\AGENTS.md' },
    @{ id = 'zed'; label = 'Zed'; rel = 'AppData\Roaming\Zed\AGENTS.md' },
    @{ id = 'crush'; label = 'Crush'; rel = '.config\crush\CRUSH.md' },
    @{ id = 'codebuddy'; label = 'CodeBuddy'; rel = '.codebuddy\CODEBUDDY.md' },
    @{ id = 'commandcode'; label = 'CommandCode'; rel = '.commandcode\AGENTS.md' },
    @{ id = 'kimi-code'; label = 'Kimi Code'; rel = '.kimi-code\AGENTS.md' },
    @{ id = 'vibe'; label = 'Vibe'; rel = '.vibe\AGENTS.md' },
    @{ id = 'qoder'; label = 'Qoder'; rel = '.qoder\AGENTS.md' },
    @{ id = 'pi'; label = 'Pi'; rel = '.pi\agent\AGENTS.md' }
  )
}
function Get-GlobalProviderIds {
  $ids = @()
  foreach ($e in @(Get-GlobalProviderCatalog)) { $ids += [string]$e.id }
  return $ids
}
# Allowlisted generation targets only. Scalar singletons are accepted;
# empty/null/unknown/duplicates are rejected (no arbitrary values).
function Test-GlobalTargetsValid($Targets) {
  $arr = @()
  if ($Targets -is [string]) { $arr = @($Targets) }
  elseif ($null -ne $Targets) { $arr = @($Targets) }
  $ids = @(Get-GlobalProviderIds)
  if (($arr.Count -lt 1) -or ($arr.Count -gt $ids.Count)) { return $false }
  $seen = @{}
  foreach ($t in $arr) {
    if ($t -isnot [string]) { return $false }
    if (-not ($ids -ccontains [string]$t)) { return $false }
    if ($seen.ContainsKey([string]$t)) { return $false }
    $seen[[string]$t] = $true
  }
  return $true
}
function Get-GlobalDefaultTargets { return @('codexcli', 'opencode') }

# Settings: atomic private JSON read also by the scheduled sync.
# Missing file means first run (defaults). Corrupt/invalid content fails closed.
function Get-GlobalSettings([string]$AutoDir) {
  $f = Join-Path $AutoDir 'global-settings.json'
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @{ schemaVersion = 1; targets = (Get-GlobalDefaultTargets) } }
  if (Global-Reparse $f) { throw '設定ファイルを確認できませんでした。' }
  try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { throw '設定ファイルを確認できませんでした。' }
  $tg = @()
  try { if ($o.PSObject.Properties['targets']) { $tg = @($o.targets | ForEach-Object { [string]$_ }) } } catch {}
  if (-not (Test-GlobalTargetsValid $tg)) { throw '設定の対象が不正です。一覧から選び直してください。' }
  return @{ schemaVersion = 1; targets = $tg }
}
function Set-GlobalTargets([string]$AutoDir, $Targets) {
  $arr = @()
  if ($Targets -is [string]) { $arr = @($Targets) }
  elseif ($null -ne $Targets) { $arr = @($Targets | ForEach-Object { [string]$_ }) }
  if (-not (Test-GlobalTargetsValid $arr)) { throw '対象は一覧から1つ以上選んでください。' }
  Write-GlobalPrivateJson (Join-Path $AutoDir 'global-settings.json') @{ schemaVersion = 1; updatedAt = ([DateTime]::UtcNow.ToString('o')); targets = $arr } $AutoDir
  return @{ ok = $true; targets = $arr }
}
# Effective targets for a run: explicit request selection wins, then stored
# settings, then defaults. The applied value is always allowlist-validated.
function Get-GlobalEffectiveTargets([string]$AutoDir, $RequestTargets) {
  $req = @()
  if ($RequestTargets -is [string]) { $req = @($RequestTargets) }
  elseif ($null -ne $RequestTargets) { $req = @($RequestTargets | ForEach-Object { [string]$_ }) }
  if ($req.Count -gt 0) {
    if (-not (Test-GlobalTargetsValid $req)) { throw '対象は一覧から1つ以上選んでください。' }
    return $req
  }
  return @((Get-GlobalSettings $AutoDir).targets)
}
function Get-GlobalTargetsArg([string[]]$Targets) { return ($Targets -join ',') }

# Shared generate argv so sync and preview never duplicate fetch/generate logic.
# Version is resolved once per operation and passed in; omitted means read settings.
function Get-GlobalGenerateArgv([string]$TargetsArg, [string]$Mode, [string]$Version = '') {
  if (-not $Version) { $Version = [string](Get-ShirubeSetting -Name 'rulesyncVersion' -Default '42.0.0') }
  $Pkg = 'rulesync@' + $Version
  $base = @('--yes', $Pkg, 'generate', '--global', '--targets', $TargetsArg, '--features', 'rules')
  if ($Mode -ceq 'check') { return ($base + @('--check')) }
  if ($Mode -ceq 'dry-run') { return ($base + @('--dry-run')) }
  return $base
}

# Home resolution shared by dashboard and sync: HOME_DIR else node os.homedir().
function Resolve-GlobalHomeBase([string]$NodeExe = '') {
  if ($env:HOME_DIR -and ($env:HOME_DIR.Trim() -ne '')) { return $env:HOME_DIR }
  $node = $NodeExe
  if (-not $node) {
    $c = Get-Command 'node' -ErrorAction SilentlyContinue
    if (-not $c) { throw 'Failed to resolve home via node os.homedir().' }
    $node = $c.Source
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    $hb = (& $node -e "process.stdout.write(require('node:os').homedir())" 2>$null | Out-String).Trim()
    $code = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $prevEap }
  if (($null -eq $code) -or ($code -ne 0) -or (-not $hb)) { throw 'Failed to resolve home via node os.homedir().' }
  return $hb
}

# rulesync 42.0.0 resolves KIMI_CODE_HOME before HOME_DIR for global kimi-code
# output, so a set override would write outside the confirmed home. Fail closed
# before any CLI or preview write; whitespace is ignored by rulesync itself.
function Assert-GlobalProviderEnvironment([string[]]$Targets = @()) {
  if (-not (@($Targets) -ccontains 'kimi-code')) { return }
  $override = $env:KIMI_CODE_HOME
  if (($null -ne $override) -and (([string]$override).Trim() -ne '')) {
    throw 'Kimi Code は KIMI_CODE_HOME が設定されているため安全に同期できません。KIMI_CODE_HOME を解除してから再実行してください。'
  }
}

# Deployment paths resolved from the CURRENT home on every call (never cached).
# Only the catalog's generated rules files; config files are never deployment paths.
function Get-GlobalContentPaths([string]$HomeBase) {
  if ([string]::IsNullOrWhiteSpace($HomeBase)) { throw '配置先を確認できませんでした。' }
  $map = @{}
  foreach ($e in @(Get-GlobalProviderCatalog)) {
    $map[[string]$e.id] = Join-Path $HomeBase ([string]$e.rel)
  }
  return $map
}
function Get-GlobalBackupRel([string]$HomeBase, [string]$Full) {
  $rel = $Full.Substring($HomeBase.Length).TrimStart('\', '/') -replace '[\\/:]', '_'
  if ([string]::IsNullOrWhiteSpace($rel)) { throw 'バックアップ名を確認できませんでした。' }
  return $rel
}
# Actual current content with confirmed paths. Bounded heads; hashes for compare.
# opencode.json/jsonc are backup-only and their content is never returned here.
function Get-GlobalContent([string]$HomeBase, [string]$Token, $Targets = $null) {
  if (Global-Reparse $HomeBase) { throw '配置先を確認できませんでした。' }
  $map = Get-GlobalContentPaths $HomeBase
  $tg = @()
  if ($Targets -is [string]) { $tg = @($Targets) }
  elseif ($null -ne $Targets) { $tg = @($Targets | ForEach-Object { [string]$_ }) }
  if ($tg.Count -eq 0) { $tg = @(Get-GlobalDefaultTargets) }
  if (-not (Test-GlobalTargetsValid $tg)) { throw '対象は一覧から1つ以上選んでください。' }
  $files = @()
  foreach ($t in $tg) {
    $p = [string]$map[$t]
    # Junctioned parents never read through: fail closed as absent, no bytes exposed.
    $linked = ((Test-Path -LiteralPath $p) -and (Global-Reparse $p))
    if (-not $linked) {
      try { if (Global-ParentReparse $p $HomeBase) { $linked = $true } } catch { $linked = $true }
    }
    $exists = ((Test-Path -LiteralPath $p -PathType Leaf) -and (-not $linked))
    $hash = $null; $size = 0; $head = $null
    if ($exists) {
      $hash = Global-FileHashHex $p
      try {
        $len = (Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length
        $size = [int][Math]::Min($len, [long][int]::MaxValue)
        $rb = Global-ReadBoundedText $p 4000
        $head = [string]$rb.text
        if ([bool]$rb.truncated) { $head = $head + "`n...(省略)..." }
        $head = Redact-GlobalText $head $Token
      } catch { $head = $null }
    }
    $files += @{ target = $t; path = $p; exists = [bool]$exists; hash = $hash; size = [int]$size; head = $head }
  }
  return @{ homeBase = $HomeBase; files = $files }
}

# Structured per-provider status. Unknown until a structured result exists:
# lock timestamps, caches, and log tails never imply success.
function Get-GlobalStatus([string]$AutoDir) {
  # Persistence is catalog-wide so a target change never deletes history;
  # selection only filters the dashboard response. Old subset files merge in.
  $rows = @{}
  foreach ($t in @(Get-GlobalProviderIds)) {
    $rows[[string]$t] = @{ target = [string]$t; lastAttemptAt = $null; lastSuccessAt = $null; result = 'unknown'; sourceCommit = ''; error = ''; backupId = '' }
  }
  $f = Join-Path $AutoDir 'global-status.json'
  if ((Test-Path -LiteralPath $f -PathType Leaf) -and (-not (Global-Reparse $f))) {
    try {
      $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($t in @($rows.Keys)) {
        try {
          if ($o.providers.PSObject.Properties[$t]) {
            $r = $o.providers.$t
            try { $rows[$t].lastAttemptAt = [string]$r.lastAttemptAt } catch {}
            try { $rows[$t].lastSuccessAt = [string]$r.lastSuccessAt } catch {}
            try { if ([string]$r.result -ne '') { $rows[$t].result = [string]$r.result } } catch {}
            try { $rows[$t].sourceCommit = [string]$r.sourceCommit } catch {}
            try { $rows[$t].error = [string]$r.error } catch {}
            try { $rows[$t].backupId = [string]$r.backupId } catch {}
          }
        } catch {}
      }
    } catch {}
  }
  return @{ schemaVersion = 1; providers = $rows }
}
function Save-GlobalProviderResult([string]$AutoDir, [string]$Target, [string]$Result, [string]$ErrorText, [string]$SourceCommit, [string]$BackupId = '') {
  if (-not ((Get-GlobalProviderIds) -ccontains [string]$Target)) { throw '対象は一覧から選んでください。' }
  $cur = Get-GlobalStatus $AutoDir
  $at = ([DateTime]::UtcNow.ToString('o'))
  $prev = $cur.providers[$Target]
  $lastSuccess = $null
  try { $lastSuccess = [string]$prev.lastSuccessAt } catch {}
  if ($Result -ceq 'success') { $lastSuccess = $at }
  if ([string]::IsNullOrWhiteSpace($lastSuccess)) { $lastSuccess = $null }
  $cur.providers[$Target] = @{ target = $Target; lastAttemptAt = $at; lastSuccessAt = $lastSuccess; result = [string]$Result; sourceCommit = [string]$SourceCommit; error = [string]$ErrorText; backupId = [string]$BackupId }
  Write-GlobalPrivateJson (Join-Path $AutoDir 'global-status.json') @{ schemaVersion = 1; providers = $cur.providers } $AutoDir
  return @{ ok = $true; target = $Target; result = [string]$Result }
}

# Same global lock file the scheduled sync uses. Mutations (sync/preview/
# restore/config/task) all hold it so runs never overlap.
function Open-GlobalSyncLock([string]$AutoDir) {
  try { return [System.IO.File]::Open((Join-Path $AutoDir 'Sync-GlobalRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
  catch {
    $e = $_.Exception
    while (($e -is [System.Management.Automation.MethodInvocationException]) -and ($e.InnerException)) { $e = $e.InnerException }
    if ($e -is [System.IO.IOException]) { throw '同期実行中のため、終了後にやり直してください。(busy)' }
    throw ('ロック取得に失敗しました: ' + $e.Message)
  }
}
function Test-GlobalSyncLocked([string]$AutoDir) {
  try { $s = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-GlobalRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None'); $s.Close(); return $false }
  catch {
    $e = $_.Exception
    while (($e -is [System.Management.Automation.MethodInvocationException]) -and ($e.InnerException)) { $e = $e.InnerException }
    if ($e -is [System.IO.IOException]) { return $true }
    throw
  }
}

function Get-GlobalLogTail([string]$AutoDir, [string]$Token) {
  $logs = Join-Path $AutoDir 'logs'
  $out = @{ name = ''; mtime = ''; finalLine = ''; tail = '' }
  if (-not (Test-Path -LiteralPath $logs -PathType Container)) { return $out }
  $files = @(Get-ChildItem -LiteralPath $logs -Filter 'Sync-GlobalRules-*.log' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ((-not $files) -or ($files.Count -eq 0)) { return $out }
  $f = $files[0]
  $out.name = $f.Name
  try { $out.mtime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
  try {
    $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 60)
    if ($lines -and ($lines.Count -gt 0)) {
      $tail = Redact-GlobalText ($lines -join "`n") $Token
      if ($tail.Length -gt 16384) { $tail = $tail.Substring($tail.Length - 16384) }
      $out.tail = $tail
      for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $ln = [string]$lines[$i]
        if ($ln.Contains('OK:')) { $out.finalLine = $ln; break }
        if ($ln.Contains('FAIL:')) { $out.finalLine = $ln; break }
        if ($ln.Contains('SKIP:')) { $out.finalLine = $ln; break }
      }
      $out.finalLine = Redact-GlobalText ([string]$out.finalLine) $Token
    }
  } catch {}
  return $out
}

# Source commit parsed from the preview lockfile (resolvedRef preferred).
function Get-GlobalSourceCommit([string]$PreviewDir) {
  try {
    $lf = Join-Path $PreviewDir 'rulesync.lock'
    if (-not (Test-Path -LiteralPath $lf -PathType Leaf)) { return '' }
    $t = Get-Content -LiteralPath $lf -Raw -Encoding UTF8
    $m = [regex]::Match($t, '["'']resolvedRef["'']\s*:\s*["'']([0-9a-f]{40})["'']')
    if ($m.Success) { return $m.Groups[1].Value }
    $m2 = [regex]::Match($t, '["''](?:sha|commit|requestedRef)["'']\s*:\s*["'']([0-9a-f]{40})["'']')
    if ($m2.Success) { return $m2.Groups[1].Value }
  } catch {}
  return ''
}
# Live input snapshot for plan comparison: source commit + effective targets +
# current content hashes per target. Missing/unreadable sources fail closed.
function Get-GlobalPlanLive([string]$AutoDir, [string]$HomeBase, $RequestTargets = $null) {
  $prevDir = Join-Path (Split-Path $AutoDir -Parent) 'global-preview'
  $commit = Get-GlobalSourceCommit $prevDir
  $tg = @(Get-GlobalEffectiveTargets $AutoDir $RequestTargets)
  $map = Get-GlobalContentPaths $HomeBase
  $ents = @()
  foreach ($t in $tg) {
    $p = [string]$map[$t]
    $linked = ((Test-Path -LiteralPath $p) -and (Global-Reparse $p))
    if (-not $linked) {
      try { if (Global-ParentReparse $p $HomeBase) { $linked = $true } } catch { $linked = $true }
    }
    $ex = ((Test-Path -LiteralPath $p -PathType Leaf) -and (-not $linked))
    $h = $null
    if ($ex) { $h = Global-FileHashHex $p }
    $ents += @{ target = $t; path = $p; exists = [bool]$ex; currentHash = $h }
  }
  return @{ sourceCommit = $commit; targets = $tg; entries = $ents }
}
function Global-Field($Obj, [string]$Key) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [hashtable]) { if ($Obj.ContainsKey($Key)) { return $Obj[$Key] }; return $null }
  try { $pr = $Obj.PSObject.Properties[$Key]; if ($pr) { return $pr.Value } } catch {}
  return $null
}
# Plan-bound apply verdict: immutable plan, every requested target needs an
# approved successful output, and source/targets/current bytes must still match
# live. Failed or stale plans refuse writes.
function Test-GlobalPlanMatch($Plan, $Live, $Names) {
  try {
    if ($null -eq $Plan) { return @{ ok = $false; error = 'プランがありません。' } }
    $sv = 0
    try { $sv = [int](Global-Field $Plan 'schemaVersion') } catch {}
    if ($sv -ne 1) { return @{ ok = $false; error = '古いプランのため適用できません。反映前プレビューから作り直してください。' } }
    $planSrc = [string](Global-Field $Plan 'sourceCommit')
    $liveSrc = [string](Global-Field $Live 'sourceCommit')
    if (($planSrc -cnotmatch '^[0-9a-f]{40}$') -or ($liveSrc -cnotmatch '^[0-9a-f]{40}$')) {
      return @{ ok = $false; error = '取得元を確認できませんでした。反映前プレビューから作り直してください。' }
    }
    if ($planSrc -cne $liveSrc) {
      return @{ ok = $false; error = '取得元が変化しました。反映前プレビューから作り直してください。' }
    }
    $planProjects = @()
    try { $planProjects = @(Global-Field $Plan 'entries') } catch {}
    $liveEntries = @()
    try { $liveEntries = @(Global-Field $Live 'entries') } catch {}
    $req = @()
    if ($Names -is [string]) { $req = @($Names) }
    elseif ($null -ne $Names) { $req = @($Names | ForEach-Object { [string]$_ }) }
    # Aggregate + per-entry size gates: oversized outputs never apply, even if
    # an old plan file was crafted by hand.
    $totalGen = 0
    foreach ($pjAll in $planProjects) {
      try {
        $gt = [string](Global-Field $pjAll 'generatedText')
        if ($gt -ne '') {
          if (-not (Test-GlobalTextSizeOk $gt)) { return @{ ok = $false; error = '生成結果が大きすぎるため適用できません。反映前プレビューから作り直してください。' } }
          $totalGen += $gt.Length
        }
        $ct = [string](Global-Field $pjAll 'currentText')
        if (($ct -ne '') -and (-not (Test-GlobalTextSizeOk $ct))) { return @{ ok = $false; error = '現在の内容が大きすぎるため適用できません。反映前プレビューから作り直してください。' } }
      } catch {}
    }
    if ($totalGen -gt (Global-MaxPlanTextChars)) { return @{ ok = $false; error = 'プラン全体が大きすぎるため適用できません。反映前プレビューから作り直してください。' } }
    foreach ($nm in $req) {
      $pj = @($planProjects | Where-Object { [string](Global-Field $_ 'target') -ceq [string]$nm })
      if (($pj.Count -ne 1) -or ([string](Global-Field $pj[0] 'result') -cne 'success') -or ([string](Global-Field $pj[0] 'generatedText') -eq '')) {
        return @{ ok = $false; error = ('承認済みの生成結果がありません: ' + [string]$nm) }
      }
      $le = @($liveEntries | Where-Object { [string](Global-Field $_ 'target') -ceq [string]$nm })
      if ($le.Count -ne 1) { return @{ ok = $false; error = ('対象が現在値にありません: ' + [string]$nm) } }
      $outP = ''; $inP = ''
      try { $outP = ([string](Global-Field $pj[0] 'path') -replace '/', '\') } catch { $outP = '' }
      try { $inP = ([string](Global-Field $le[0] 'path') -replace '/', '\') } catch { $inP = '' }
      if (($outP -eq '') -or ($inP -eq '') -or (-not $outP.Equals($inP, [System.StringComparison]::OrdinalIgnoreCase))) {
        return @{ ok = $false; error = ('配置先が変化しました: ' + [string]$nm) }
      }
      $pinH = Global-Field $pj[0] 'currentHash'
      $liveH = Global-Field $le[0] 'currentHash'
      $ps = ''; $ls = ''
      if ($null -ne $pinH) { $ps = [string]$pinH }
      if ($null -ne $liveH) { $ls = [string]$liveH }
      # Fail closed: missing existence or unreadable hashes never count as a
      # match. Absent-on-both-sides is the only hashless match, and only when
      # both sides explicitly record absence.
      $pinEx = Global-Field $pj[0] 'exists'
      $liveEx = Global-Field $le[0] 'exists'
      if (($null -ne $pinEx) -and ($null -ne $liveEx)) {
        if ([bool]$pinEx -cne [bool]$liveEx) { return @{ ok = $false; error = ('存在状態が変化しました: ' + [string]$nm) } }
        if ([bool]$liveEx) {
          if ([string]::IsNullOrWhiteSpace($ps) -or [string]::IsNullOrWhiteSpace($ls)) {
            return @{ ok = $false; error = ('現在の内容を確認できませんでした: ' + [string]$nm) }
          }
        }
      }
      elseif ([string]::IsNullOrWhiteSpace($ps) -or [string]::IsNullOrWhiteSpace($ls)) {
        return @{ ok = $false; error = ('現在の内容を確認できませんでした: ' + [string]$nm) }
      }
      if ($ps -cne $ls) { return @{ ok = $false; error = ('現在の内容が変化しました: ' + [string]$nm) } }
    }
    return @{ ok = $true; error = '' }
  } catch { return @{ ok = $false; error = 'プラン照合に失敗しました。' } }
}

function Global-BackupIdPattern { return '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' }
function New-GlobalBackup([string]$AutoDir, [string]$HomeBase, $Targets) {
  $arr = @()
  if ($Targets -is [string]) { $arr = @($Targets) }
  elseif ($null -ne $Targets) { $arr = @($Targets | ForEach-Object { [string]$_ }) }
  if (-not (Test-GlobalTargetsValid $arr)) { throw '対象は一覧から1つ以上選んでください。' }
  $map = Get-GlobalContentPaths $HomeBase
  $extra = @{
    'opencode.json' = (Join-Path $HomeBase '.config\opencode\opencode.json')
    'opencode.jsonc' = (Join-Path $HomeBase '.config\opencode\opencode.jsonc')
  }
  $broot = Join-Path $AutoDir 'backups'
  New-Item -ItemType Directory -Force -Path $broot | Out-Null
  if (Global-Reparse $broot) { throw 'バックアップ先を確認できませんでした。' }
  if (Global-Reparse $AutoDir) { throw 'バックアップ先を確認できませんでした。' }
  if (Global-ParentReparse $broot $AutoDir) { throw 'バックアップ先の親フォルダがリンクになっています。' }
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bdir = Join-Path $broot ($ts + '-global')
  $n = 0
  while (Test-Path -LiteralPath $bdir) { $n++; $bdir = Join-Path $broot ($ts + '-global-' + $n) }
  if (-not (Global-Contained $bdir $broot)) { throw 'バックアップ先を確認できませんでした。' }
  New-Item -ItemType Directory -Force -Path $bdir | Out-Null
  if (Global-Reparse $bdir) { throw 'バックアップ先を確認できませんでした。' }
  Global-AssertNoLinkChain $bdir $AutoDir 'バックアップ先'
  if (Global-Reparse $HomeBase) { throw '配置先を確認できませんでした。' }
  $files = @()
  foreach ($t in $arr) {
    $src = [string]$map[$t]
    if (-not (Global-Contained $src $HomeBase)) { throw '配置先を確認できませんでした。' }
    Global-AssertNoLinkChain $src $HomeBase $t
    if ((Test-Path -LiteralPath $src -PathType Leaf) -and (-not (Global-Reparse $src))) {
      $rel = Get-GlobalBackupRel $HomeBase $src
      $dstB = Join-Path $bdir $rel
      if (-not (Global-Contained $dstB $bdir)) { throw 'バックアップ先を確認できませんでした。' }
      Global-AssertNoLinkChain $dstB $AutoDir 'バックアップ先'
      Copy-GlobalVerified $src $dstB $HomeBase $AutoDir
      $files += @{ target = $t; kind = 'agents'; rel = $rel; present = $true; hash = (Global-FileHashHex $src) }
    }
    else { $files += @{ target = $t; kind = 'agents'; rel = ''; present = $false; hash = $null } }
  }
  # Config bytes are a private precaution only when opencode is selected, and
  # are never restored or displayed (rule restore covers AGENTS files only).
  $wantConfig = ($arr -contains 'opencode')
  foreach ($k in @($extra.Keys)) {
    if (-not $wantConfig) { continue }
    $src = [string]$extra[$k]
    Global-AssertNoLinkChain $src $HomeBase '設定'
    if ((Test-Path -LiteralPath $src -PathType Leaf) -and (-not (Global-Reparse $src))) {
      $rel = Get-GlobalBackupRel $HomeBase $src
      $dstC = Join-Path $bdir $rel
      if (-not (Global-Contained $dstC $bdir)) { throw 'バックアップ先を確認できませんでした。' }
      Global-AssertNoLinkChain $dstC $AutoDir 'バックアップ先'
      Copy-GlobalVerified $src $dstC $HomeBase $AutoDir
      $files += @{ target = 'opencode'; kind = 'config'; rel = $rel; present = $true; hash = (Global-FileHashHex $src) }
    }
  }
  Global-AssertNoLinkChain (Join-Path $bdir 'manifest.json') $AutoDir 'バックアップの記録'
  Write-GlobalPrivateJson (Join-Path $bdir 'manifest.json') @{ schemaVersion = 1; scope = 'global'; createdAt = ([DateTime]::UtcNow.ToString('o')); homeBase = $HomeBase; targets = $arr; files = $files } $AutoDir
  return $bdir
}
function Get-GlobalBackupList([string]$AutoDir) {
  $out = @()
  # Root itself is untrusted too: a linked AutoDir must list nothing and read
  # no manifest bytes.
  if (Global-Reparse $AutoDir) { return $out }
  $broot = Join-Path $AutoDir 'backups'
  if (-not (Test-Path -LiteralPath $broot -PathType Container)) { return $out }
  if (Global-Reparse $broot) { return $out }
  try { if (Global-ParentReparse $broot $AutoDir) { return $out } } catch { return $out }
  $pat = Global-BackupIdPattern
  if (Global-Reparse $AutoDir) { return $out }
  $dirs = @(Get-ChildItem -LiteralPath $broot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  foreach ($d in $dirs) {
    $id = $d.Name
    if ($id -cnotmatch $pat) { continue }
    $full = $d.FullName
    if (-not (Global-Contained $full $broot)) { continue }
    if (Global-Reparse $full) { continue }
    try { if (Global-ParentReparse $full $AutoDir) { continue } } catch { continue }
    # Global backups carry scope=global manifests; project rows stay untouched.
    $mf = $null
    $mfPath = Join-Path $full 'manifest.json'
    try { Global-AssertNoLinkChain $mfPath $AutoDir 'バックアップの記録' } catch { continue }
    if ((Test-Path -LiteralPath $mfPath -PathType Leaf) -and (-not (Global-Reparse $mfPath))) {
      try { $mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $mf = $null }
    }
    $isGlobal = $false
    try { if ($mf -and $mf.PSObject.Properties['scope'] -and ([string]$mf.scope -ceq 'global')) { $isGlobal = $true } } catch {}
    if (-not $isGlobal) { continue }
    $row = @{ id = $id; createdAt = ''; targets = @(); hasManifest = ($null -ne $mf) }
    try { $row.createdAt = [string]$mf.createdAt } catch {}
    try { $row.targets = @($mf.targets | ForEach-Object { [string]$_ }) } catch {}
    $out += $row
  }
  return $out
}
# Manifest trust gate: allowlisted kinds/targets only, no duplicates, and every
# entry carries exactly the fields its presence state requires. Unknown,
# duplicated, or malformed entries fail closed (no diff, no confirm, no restore).
# present=false entries never carry bytes or hashes: an extra absent row would
# otherwise become an unapproved delete step.
function Test-GlobalManifestValid($Manifest) {
  try {
    if ($null -eq $Manifest) { return @{ ok = $false; error = 'manifest missing' } }
    $sv = 0
    try { $sv = [int](Global-Field $Manifest 'schemaVersion') } catch {}
    if ($sv -ne 1) { return @{ ok = $false; error = 'manifest schema' } }
    $scope = [string](Global-Field $Manifest 'scope')
    if ($scope -cne 'global') { return @{ ok = $false; error = 'manifest scope' } }
    $tg = @()
    try { $tg = @(Global-Field $Manifest 'targets' | ForEach-Object { [string]$_ }) } catch {}
    if (-not (Test-GlobalTargetsValid $tg)) { return @{ ok = $false; error = 'manifest targets' } }
    $files = @()
    try { $files = @(Global-Field $Manifest 'files') } catch {}
    if ($files.Count -eq 0) { return @{ ok = $false; error = 'manifest files' } }
    $ids = @(Get-GlobalProviderIds)
    $seen = @{}
    $canon = @()
    foreach ($fe in $files) {
      $kind = [string](Global-Field $fe 'kind')
      $t = [string](Global-Field $fe 'target')
      $rel = [string](Global-Field $fe 'rel')
      $present = $false
      try { $present = [bool](Global-Field $fe 'present') } catch {}
      $hash = [string](Global-Field $fe 'hash')
      if (($kind -cne 'agents') -and ($kind -cne 'config')) { return @{ ok = $false; error = 'manifest kind' } }
      if ($kind -ceq 'agents') {
        if (-not ($ids -ccontains $t)) { return @{ ok = $false; error = 'manifest target' } }
      }
      else {
        if ($t -cne 'opencode') { return @{ ok = $false; error = 'manifest target' } }
      }
      if ($present) {
        if ([string]::IsNullOrWhiteSpace($rel)) { return @{ ok = $false; error = 'manifest rel' } }
        if ($hash -cnotmatch '^[0-9a-f]{64}$') { return @{ ok = $false; error = 'manifest hash' } }
      }
      else {
        # Absent rows carry no bytes: the hash must be empty (a rel may remain
        # on older scheduler-written rows; the pinned canon still rejects adds).
        if (-not [string]::IsNullOrEmpty($hash)) { return @{ ok = $false; error = 'manifest hash' } }
      }
      $key = ($kind + '|' + $t + '|' + $rel)
      if ($seen.ContainsKey($key)) { return @{ ok = $false; error = 'manifest duplicate' } }
      $seen[$key] = $true
      $canon += ($key + '|' + ([bool]$present).ToString() + '|' + $hash)
    }
    $canon = @($canon | Sort-Object)
    $tgSorted = @($tg | Sort-Object)
    return @{ ok = $true; error = ''; targets = $tgSorted; canon = $canon }
  } catch { return @{ ok = $false; error = 'manifest unreadable' } }
}
# Agents targets of a validated manifest. Current bytes are read, pinned, and
# re-verified only for these providers: restore touches nothing else (config
# rows are never restored), so an unselected provider (oversize, linked parent,
# or edited after the diff) never blocks this backup's diff/confirm/restore.
# A changed selected target is still refused by the pin comparison.
function Global-AgentsTargets($Manifest) {
  $out = @()
  $ids = @(Get-GlobalProviderIds)
  foreach ($fe in @(Global-Field $Manifest 'files')) {
    $kind = ''
    try { $kind = [string](Global-Field $fe 'kind') } catch {}
    if ($kind -cne 'agents') { continue }
    $t = [string](Global-Field $fe 'target')
    if (($ids -ccontains $t) -and (-not ($out -contains $t))) { $out += $t }
  }
  return $out
}
function Get-GlobalBackupManifest([string]$AutoDir, [string]$BackupId) {
  if ($BackupId -cnotmatch (Global-BackupIdPattern)) { throw 'バックアップ指定が不正です。' }
  $broot = Join-Path $AutoDir 'backups'
  if (Global-Reparse $broot) { throw 'バックアップ先を確認できませんでした。' }
  if (Global-Reparse $AutoDir) { throw 'バックアップ先を確認できませんでした。' }
  if (Global-ParentReparse $broot $AutoDir) { throw 'バックアップ先の親フォルダがリンクになっています。' }
  $bdir = Join-Path $broot $BackupId
  if (-not (Global-Contained $bdir $broot)) { throw 'バックアップ指定が不正です。' }
  if ((-not (Test-Path -LiteralPath $bdir -PathType Container)) -or (Global-Reparse $bdir)) { throw 'バックアップが見つかりません。' }
  if (Global-ParentReparse $bdir $AutoDir) { throw 'バックアップの親フォルダがリンクになっています。' }
  $mf = $null
  $mfPath = Join-Path $bdir 'manifest.json'
  Global-AssertNoLinkChain $mfPath $AutoDir 'バックアップの記録'
  if ((Test-Path -LiteralPath $mfPath -PathType Leaf) -and (-not (Global-Reparse $mfPath))) {
    try { $mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $mf = $null }
  }
  if ($null -eq $mf) { throw 'バックアップの対象を信頼できません。名前と場所の記録がないため復元しません。(旧形式)' }
  $scope = ''
  try { $scope = [string]$mf.scope } catch {}
  if ($scope -cne 'global') { throw 'バックアップの対象を信頼できません。名前と場所の記録がないため復元しません。(旧形式)' }
  $chk = Test-GlobalManifestValid $mf
  if (-not [bool]$chk.ok) { throw 'バックアップの対象を信頼できません。記録の検証に失敗したため復元しません。' }
  return @{ dir = $bdir; manifest = $mf }
}
# Single-use confirm record from an already-validated snapshot. Callers must pass
# the exact bytes/hashes shown to the user; no re-read happens here.
function New-GlobalRestoreConfirmRecord([string]$BackupId, [string]$HomeBase, $TargetsSorted, $Canon, $Cur, $Bak) {
  try {
    $cut = (Get-Date).AddMinutes(-30)
    foreach ($k in @($script:GlobalRestoreConfirms.Keys)) {
      try { if ([datetime]$script:GlobalRestoreConfirms[$k].ts -lt $cut) { $script:GlobalRestoreConfirms.Remove($k) } } catch {}
    }
  } catch {}
  $id = [System.Guid]::NewGuid().ToString('N')
  $script:GlobalRestoreConfirms[$id] = @{ backupId = $BackupId; homeBase = $HomeBase; targets = @($TargetsSorted); canon = @($Canon); current = $Cur; backup = $Bak; ts = (Get-Date) }
  return $id
}
# Non-writing diff: backup bytes vs current bytes from ONE bounded snapshot.
# The same bytes feed both the displayed lines and the confirm hashes, so a
# mid-read change cannot bind display A to confirm B. Any oversize/truncation
# fails closed with NO confirm. Config file content never shown;
# config rows report presence/change only. Issues a fresh server-side restore
# confirmation bound to backup/current hashes (restore requires it in-lock).
function Get-GlobalBackupDiff([string]$AutoDir, [string]$BackupId, [string]$HomeBase) {
  $got = Get-GlobalBackupManifest $AutoDir $BackupId
  $bdir = [string]$got.dir
  $mf = $got.manifest
  $mfHome = ''
  try { $mfHome = [string]$mf.homeBase } catch {}
  if (($mfHome -eq '') -or (-not $mfHome.Equals($HomeBase, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'バックアップの対象と配置先が一致しません。別の配置のため復元しません。'
  }
  if (Global-Reparse $HomeBase) { throw '配置先を確認できませんでした。' }
  $chk0 = Test-GlobalManifestValid $mf
  if (-not [bool]$chk0.ok) { throw 'バックアップの対象を信頼できません。記録の検証に失敗したため復元しません。' }
  $canon0 = @($chk0.canon)
  $tgSorted0 = @($chk0.targets)
  $map = Get-GlobalContentPaths $HomeBase
  $ids = @(Get-GlobalProviderIds)
  # Snapshot current bytes once (bounded before/during reads) for the agents
  # targets of this verified manifest only: unselected providers are never read,
  # so their size/link/later edits cannot block this backup's diff.
  $curSnap = @{}
  $curText = @{}
  foreach ($t in @(Global-AgentsTargets $mf)) {
    $p = [string]$map[$t]
    Global-AssertNoLinkChain $p $HomeBase $t
    $ex = (Test-Path -LiteralPath $p -PathType Leaf)
    $h = $null; $txt = $null; $bb = $null
    if ($ex) {
      if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '大きすぎるため差分確認できません。' }
      $rb = Global-ReadBoundedBytes $p (Global-MaxContentBytes)
      if ([bool]$rb.truncated) { throw '大きすぎるため差分確認できません。' }
      $bb = [byte[]]$rb.bytes
      $h = Global-HashBytesHex $bb
      if ([string]::IsNullOrWhiteSpace([string]$h)) { throw '現在の内容を確認できませんでした。' }
      $txt = [System.Text.Encoding]::UTF8.GetString($bb)
      if (-not (Test-GlobalTextSizeOk $txt)) { throw '大きすぎるため差分確認できません。' }
    }
    $curSnap[$t] = @{ present = [bool]$ex; hash = $h }
    $curText[$t] = $txt
  }
  # Snapshot backup bytes once (bounded) and verify against manifest.
  $bakSnap = @{}
  $bakText = @{}
  foreach ($fe in @($mf.files)) {
    $kind = ''
    try { $kind = [string]$fe.kind } catch {}
    if ($kind -cne 'agents') { continue }
    $t = [string]$fe.target
    if (-not ($ids -ccontains $t)) { throw 'バックアップの対象を信頼できません。' }
    $rel = ''
    try { $rel = [string]$fe.rel } catch {}
    $present = $false
    try { $present = [bool]$fe.present } catch {}
    $expH = ''
    try { $expH = [string]$fe.hash } catch {}
    $btxt = $null
    if ($present) {
      if ($rel -eq '') { throw 'バックアップの検証情報がありません。復元しません。' }
      $bf = Join-Path $bdir $rel
      if (-not (Global-Contained $bf $bdir)) { throw 'バックアップ指定が不正です。' }
      Global-AssertNoLinkChain $bf $AutoDir 'バックアップ'
      if (-not (Test-Path -LiteralPath $bf -PathType Leaf)) { throw 'バックアップが破損しているため復元しません。' }
      if ((Get-Item -LiteralPath $bf -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '大きすぎるため差分確認できません。' }
      $rbb = Global-ReadBoundedBytes $bf (Global-MaxContentBytes)
      if ([bool]$rbb.truncated) { throw '大きすぎるため差分確認できません。' }
      $bbb = [byte[]]$rbb.bytes
      $sh = Global-HashBytesHex $bbb
      if (($null -eq $sh) -or ($sh -cne $expH)) { throw 'バックアップが破損しているため復元しません。' }
      $btxt = [System.Text.Encoding]::UTF8.GetString($bbb)
      if (-not (Test-GlobalTextSizeOk $btxt)) { throw '大きすぎるため差分確認できません。' }
    }
    $bakSnap[$t] = @{ present = [bool]$present; hash = $expH }
    $bakText[$t] = $btxt
  }
  $same = $true
  $lines = @()
  $truncated = $false
  $configChanges = @()
  foreach ($fe in @($mf.files)) {
    $kind = ''
    try { $kind = [string]$fe.kind } catch {}
    if ($kind -ceq 'config') {
      $rel = ''
      try { $rel = [string]$fe.rel } catch {}
      $bPresent = $false
      try { $bPresent = [bool]$fe.present } catch {}
      $curP = $null
      if (($rel -ne '') -and $bPresent) {
        $bf0 = Join-Path $bdir $rel
        if ((Global-Contained $bf0 $bdir) -and (Test-Path -LiteralPath $bf0 -PathType Leaf)) { $curP = $bf0 }
      }
      $cfgName = [string]$rel
      $backH = ''
      try { $backH = [string]$fe.hash } catch {}
      $curCfg = $null
      if ($cfgName -ne '') {
        foreach ($ck in @((Join-Path $HomeBase '.config\opencode\opencode.json'), (Join-Path $HomeBase '.config\opencode\opencode.jsonc'))) {
          $cr = ''
          try { $cr = Get-GlobalBackupRel $HomeBase $ck } catch {}
          if (($cr -ne '') -and ($cr -ceq $cfgName)) { $curCfg = $ck; break }
        }
      }
      $cPresent = $false
      $cHash = $null
      if (($null -ne $curCfg) -and (Test-Path -LiteralPath $curCfg -PathType Leaf)) {
        $cPresent = $true
        try {
          if (-not (Global-Reparse $curCfg) -and (-not (Global-ParentReparse $curCfg $HomeBase))) { $cHash = Global-FileHashHex $curCfg }
        } catch {}
      }
      $changed = ($bPresent -cne $cPresent) -or (($null -ne $cHash) -and ($backH -cne $cHash))
      if ($changed) { $same = $false }
      $configChanges += @{ file = $cfgName; backupPresent = [bool]$bPresent; currentPresent = [bool]$cPresent; changed = [bool]$changed }
      continue
    }
    if ($kind -cne 'agents') { throw 'バックアップの対象を信頼できません。' }
    $t = [string]$fe.target
    if (-not ($ids -ccontains $t)) { throw 'バックアップの対象を信頼できません。' }
    # Display reuses the exact snapshot bytes hashed for the confirm below.
    $oldText = $bakText[$t]
    $newText = $curText[$t]
    $d = Global-DiffTextPair $oldText $newText
    if (-not [bool]$d.same) { $same = $false }
    foreach ($ln in @($d.lines)) { $lines += @{ t = [string]$ln.t; text = [string]$ln.text; target = $t } }
    if ([bool]$d.truncated) { $truncated = $true }
    if ($lines.Count -gt 300) { $lines = @($lines | Select-Object -First 300); $truncated = $true }
  }
  # Omitted display never issues a confirm: the user did not see everything.
  if ([bool]$truncated) { throw '差分が大きいため確認できません。ファイルを小さくして作り直してください。' }
  $confirmId = New-GlobalRestoreConfirmRecord $BackupId $HomeBase $tgSorted0 $canon0 $curSnap $bakSnap
  return @{ id = $BackupId; same = [bool]$same; lines = $lines; truncated = $false; configChanges = $configChanges; confirmId = [string]$confirmId }
}
# Server-issued restore confirmation: binds backup id, home, targets, current
# presence/hashes and manifest backup hashes. Single-use, 10-minute fresh.
$script:GlobalRestoreConfirms = @{}
function New-GlobalRestoreConfirm([string]$AutoDir, [string]$BackupId, [string]$HomeBase) {
  $got = Get-GlobalBackupManifest $AutoDir $BackupId
  $bdir = [string]$got.dir
  $mf = $got.manifest
  $mfHome = ''
  try { $mfHome = [string]$mf.homeBase } catch {}
  if (($mfHome -eq '') -or (-not $mfHome.Equals($HomeBase, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'バックアップの対象と配置先が一致しません。別の配置のため復元しません。'
  }
  if (Global-Reparse $HomeBase) { throw 'リンク・ジャンクションの配置には戻せません。' }
  $chk = Test-GlobalManifestValid $mf
  if (-not [bool]$chk.ok) { throw 'バックアップの対象を信頼できません。記録の検証に失敗したため復元しません。' }
  $canon = @($chk.canon)
  $tgSorted = @($chk.targets)
  $map = Get-GlobalContentPaths $HomeBase
  $cur = @{}
  foreach ($t in @(Global-AgentsTargets $mf)) {
    $p = [string]$map[$t]
    Global-AssertNoLinkChain $p $HomeBase $t
    $ex = (Test-Path -LiteralPath $p -PathType Leaf)
    $h = $null
    if ($ex) {
      if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '大きすぎるため差分確認できません。' }
      $rb = Global-ReadBoundedBytes $p (Global-MaxContentBytes)
      if ([bool]$rb.truncated) { throw '大きすぎるため差分確認できません。' }
      $h = Global-HashBytesHex ([byte[]]$rb.bytes)
      if ([string]::IsNullOrWhiteSpace([string]$h)) { throw '現在の内容を確認できませんでした。' }
    }
    $cur[$t] = @{ present = [bool]$ex; hash = $h }
  }
  $bak = @{}
  foreach ($fe in @($mf.files)) {
    $kind = ''
    try { $kind = [string]$fe.kind } catch {}
    if ($kind -cne 'agents') { continue }
    $rel = ''
    try { $rel = [string]$fe.rel } catch {}
    $present = $false
    try { $present = [bool]$fe.present } catch {}
    $expH = ''
    try { $expH = [string]$fe.hash } catch {}
    if ($present -and ($rel -ne '')) {
      $bf = Join-Path $bdir $rel
      if (-not (Global-Contained $bf $bdir)) { throw 'バックアップ指定が不正です。' }
      Global-AssertNoLinkChain $bf $AutoDir 'バックアップ'
      if (-not (Test-Path -LiteralPath $bf -PathType Leaf)) { throw 'バックアップが破損しているため復元しません。' }
      if ((Get-Item -LiteralPath $bf -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '大きすぎるため差分確認できません。' }
      $rbb = Global-ReadBoundedBytes $bf (Global-MaxContentBytes)
      if ([bool]$rbb.truncated) { throw '大きすぎるため差分確認できません。' }
      $srcH = Global-HashBytesHex ([byte[]]$rbb.bytes)
      if (($null -eq $srcH) -or ($srcH -cne $expH)) { throw 'バックアップが破損しているため復元しません。' }
    }
    $bak[[string]$fe.target] = @{ present = [bool]$present; hash = $expH }
  }
  return (New-GlobalRestoreConfirmRecord $BackupId $HomeBase $tgSorted $canon $cur $bak)
}
function Get-GlobalRestoreVerified([string]$AutoDir, [string]$BackupId, [string]$HomeBase, [string]$ConfirmId) {
  if ([string]$ConfirmId -cnotmatch '^[0-9a-f]{32}$') { throw '先に差分確認をしてください。確認直後の復元のみ受け付けます。' }
  if (-not $script:GlobalRestoreConfirms.ContainsKey($ConfirmId)) { throw '先に差分確認をしてください。確認直後の復元のみ受け付けます。' }
  $bd = $script:GlobalRestoreConfirms[$ConfirmId]
  try { $script:GlobalRestoreConfirms.Remove($ConfirmId) } catch {}
  try { if (((Get-Date) - [datetime]$bd.ts).TotalMinutes -gt 10) { throw 'expired' } } catch { throw '差分確認が古いため、もう一度差分確認してください。' }
  if (([string]$bd.backupId -cne $BackupId) -or (-not ([string]$bd.homeBase).Equals($HomeBase, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw '差分確認と復元対象が一致しません。もう一度差分確認してください。'
  }
  $map = Get-GlobalContentPaths $HomeBase
  # Only the agents targets bound in the confirm record are re-verified: an
  # unselected provider changed after the diff never blocks the restore, while
  # a changed selected target still refuses through the pin comparison below.
  foreach ($t in @($bd.current.Keys)) {
    $p = [string]$map[$t]
    Global-AssertNoLinkChain $p $HomeBase $t
    $ex = (Test-Path -LiteralPath $p -PathType Leaf)
    $h = $null
    if ($ex) {
      if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '差分確認後に現在の内容が変化しました。もう一度差分確認してください。' }
      $rb = Global-ReadBoundedBytes $p (Global-MaxContentBytes)
      if ([bool]$rb.truncated) { throw '差分確認後に現在の内容が変化しました。もう一度差分確認してください。' }
      $h = Global-HashBytesHex ([byte[]]$rb.bytes)
    }
    $pin = $bd.current[$t]
    $wasPresent = $false
    $wasHash = $null
    try { $wasPresent = [bool]$pin.present } catch {}
    try { $wasHash = $pin.hash } catch {}
    if ([bool]$ex -cne $wasPresent) { throw '差分確認後に現在の内容が変化しました。もう一度差分確認してください。' }
    if ($ex -and (([string]$h) -cne ([string]$wasHash))) { throw '差分確認後に現在の内容が変化しました。もう一度差分確認してください。' }
    if ($ex -and ([string]::IsNullOrWhiteSpace([string]$h))) { throw '現在の内容を確認できませんでした。もう一度差分確認してください。' }
  }
  $got = Get-GlobalBackupManifest $AutoDir $BackupId
  $bdir = [string]$got.dir
  $mf = $got.manifest
  # Exact manifest pin: targets + every file row (incl absent) + no dup/unknown.
  $chkNow = Test-GlobalManifestValid $mf
  if (-not [bool]$chkNow.ok) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
  $nowCanon = @($chkNow.canon)
  $nowTg = @($chkNow.targets)
  $pinCanon = @()
  try { $pinCanon = @($bd.canon) } catch {}
  $pinTg = @()
  try { $pinTg = @($bd.targets) } catch {}
  if ($pinCanon.Count -ne $nowCanon.Count) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
  for ($ci = 0; $ci -lt $nowCanon.Count; $ci++) {
    if ([string]$pinCanon[$ci] -cne [string]$nowCanon[$ci]) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
  }
  if ($pinTg.Count -ne $nowTg.Count) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
  for ($ti = 0; $ti -lt $nowTg.Count; $ti++) {
    if ([string]$pinTg[$ti] -cne [string]$nowTg[$ti]) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
  }
  foreach ($fe in @($mf.files)) {
    $kind = ''
    try { $kind = [string]$fe.kind } catch {}
    if ($kind -cne 'agents') { continue }
    $rel = ''
    try { $rel = [string]$fe.rel } catch {}
    $present = $false
    try { $present = [bool]$fe.present } catch {}
    $expH = ''
    try { $expH = [string]$fe.hash } catch {}
    $pinB = $bd.backup[[string]$fe.target]
    try {
      if (([bool]$pinB.present -cne $present) -or ([string]$pinB.hash -cne [string]$expH)) { throw 'bind' }
    } catch { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
    if ($present -and ($rel -ne '')) {
      $bf = Join-Path $bdir $rel
      if (-not (Global-Contained $bf $bdir)) { throw 'バックアップ指定が不正です。' }
      Global-AssertNoLinkChain $bf $AutoDir 'バックアップ'
      if ((Get-Item -LiteralPath $bf -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
      $rbb = Global-ReadBoundedBytes $bf (Global-MaxContentBytes)
      if ([bool]$rbb.truncated) { throw '差分確認後にバックアップが変化しました。もう一度差分確認してください。' }
      $srcH = Global-HashBytesHex ([byte[]]$rbb.bytes)
      if (($null -eq $srcH) -or ($srcH -cne $expH)) { throw 'バックアップが破損しているため復元しません。' }
    }
  }
  return @{ ok = $true; dir = [string]$bdir; manifest = $mf }
}
function Test-GlobalRestoreConfirm([string]$AutoDir, [string]$BackupId, [string]$HomeBase, [string]$ConfirmId) {
  Get-GlobalRestoreVerified $AutoDir $BackupId $HomeBase $ConfirmId | Out-Null
  return $true
}
# Restore: pause the Global auto sync BEFORE touching files, verify every byte
# against the manifest, shelter current state first, roll back honestly.
# Config entries are never restored (AGENTS files of selected targets only).
# Requires a fresh server-issued diff confirmation bound to target/current/
# backup hashes; the binding is re-verified here while the caller holds the
# global lock.
function Restore-GlobalBackup([string]$AutoDir, [string]$BackupId, [bool]$Confirm, [string]$HomeBase, [string]$ConfirmId = '') {
  if (-not $Confirm) { throw '確認チェックを入れてください。' }
  # Verified snapshot is the ONLY manifest source: no re-read after compare,
  # so in-flight manifest adds cannot become unapproved steps.
  $ver = Get-GlobalRestoreVerified $AutoDir $BackupId $HomeBase $ConfirmId
  $bdir = [string]$ver.dir
  $mf = $ver.manifest
  $mfHome = ''
  try { $mfHome = [string]$mf.homeBase } catch {}
  if (($mfHome -eq '') -or (-not $mfHome.Equals($HomeBase, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'バックアップの対象と配置先が一致しません。別の配置のため復元しません。'
  }
  if (Global-Reparse $HomeBase) { throw 'リンク・ジャンクションの配置には戻せません。' }
  $map = Get-GlobalContentPaths $HomeBase
  $ids = @(Get-GlobalProviderIds)
  # Plan every mutation first; refuse before touching anything.
  $steps = @()
  foreach ($fe in @($mf.files)) {
    $kind = ''
    try { $kind = [string]$fe.kind } catch {}
    if ($kind -ceq 'config') { continue }
    if ($kind -cne 'agents') { throw 'バックアップの対象を信頼できません。' }
    $rel = ''
    try { $rel = [string]$fe.rel } catch {}
    $present = $false
    try { $present = [bool]$fe.present } catch {}
    $t = [string]$fe.target
    if (-not ($ids -ccontains $t)) { throw 'バックアップの対象を信頼できません。' }
    $dst = [string]$map[$t]
    if (-not (Global-Contained $dst $HomeBase)) { throw '配置先を確認できませんでした。' }
    if ($present) {
      if ($rel -eq '') { throw 'バックアップの検証情報がありません。復元しません。' }
      $src = Join-Path $bdir $rel
      if (-not (Global-Contained $src $bdir)) { throw 'バックアップ指定が不正です。' }
      Global-AssertNoLinkChain $src $AutoDir 'バックアップ'
      $expH = ''
      try { $expH = [string]$fe.hash } catch {}
      if ([string]::IsNullOrWhiteSpace($expH)) { throw 'バックアップの検証情報がありません。復元しません。' }
      $srcH = Global-FileHashHex $src
      if (($null -eq $srcH) -or ($srcH -cne $expH)) { throw 'バックアップが破損しているため復元しません。' }
      $steps += @{ kind = 'copy'; src = $src; dst = $dst; exp = $expH; which = $t; target = $t; ckind = 'agents' }
    }
    else {
      Global-AssertNoLinkChain $dst $HomeBase $t
      if (Test-Path -LiteralPath $dst) { $steps += @{ kind = 'delete'; dst = $dst; which = $t; target = $t; ckind = 'agents' } }
    }
  }
  # Validate the shelter root before pausing: a linked backups folder must not
  # leave automatic sync disabled.
  $broot = Join-Path $AutoDir 'backups'
  if (Global-Reparse $AutoDir) { throw 'バックアップ先を確認できませんでした。' }
  if (Global-Reparse $broot) { throw 'バックアップ先を確認できませんでした。' }
  if (Global-ParentReparse $broot $AutoDir) { throw 'バックアップ先の親フォルダがリンクになっています。' }
  # Pause the Global auto sync BEFORE updating files so a scheduled run can
  # never overwrite a half-restored home. A pause failure refuses the restore.
  $taskInfo = $null
  try { $taskInfo = Get-GlobalScheduledTask }
  catch { throw ('自動同期の休止に失敗したため復元しません: ' + $_.Exception.Message) }
  $taskName = [string]$taskInfo.name
  $wasEnabled = ([string]$taskInfo.task.State -cne 'Disabled')
  try { Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null }
  catch { throw ('自動同期の休止に失敗したため復元しません: ' + $_.Exception.Message) }
  # Shelter current state (lossless) for rollback and history. Nothing in home
  # changes here, so a failure restores the recorded task state instead of
  # leaving automatic sync silently paused.
  try {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $pre = Join-Path $broot ($ts + '-global-before-restore')
    $n = 0
    while (Test-Path -LiteralPath $pre) { $n++; $pre = Join-Path $broot ($ts + '-global-before-restore-' + $n) }
    if (-not (Global-Contained $pre $broot)) { throw 'バックアップ先を確認できませんでした。' }
    New-Item -ItemType Directory -Force -Path $pre | Out-Null
    if (Global-Reparse $pre) { throw 'バックアップ先を確認できませんでした。' }
    Global-AssertNoLinkChain $pre $AutoDir 'バックアップ先'
    # Trust anchors for every mutation target (copies AND deletes): hash current
    # bytes before sheltering so rollback restores exactly the pre-restore state.
    $origH = @{}
    $preFiles = @()
    foreach ($st in $steps) {
      $dst = [string]$st.dst
      if (Test-Path -LiteralPath $dst -PathType Leaf) {
        Global-AssertNoLinkChain $dst $HomeBase ([string]$st.which)
        $rel2 = Get-GlobalBackupRel $HomeBase $dst
        $dstPre = Join-Path $pre $rel2
        if (-not (Global-Contained $dstPre $pre)) { throw 'バックアップ先を確認できませんでした。' }
        Global-AssertNoLinkChain $dstPre $AutoDir 'バックアップ先'
        Copy-GlobalVerified $dst $dstPre $HomeBase $AutoDir
        $hh = Global-FileHashHex $dst
        if ([string]::IsNullOrWhiteSpace([string]$hh)) { throw '退避の検証に失敗しました。復元しません。' }
        if ((Global-FileHashHex $dstPre) -cne $hh) { throw '退避の検証に失敗しました。復元しません。' }
        $origH[$dst] = [string]$hh
        $preFiles += @{ target = ([string]$st.target); kind = ([string]$st.ckind); rel = $rel2; present = $true; hash = ([string]$hh) }
      }
      else {
        $origH[$dst] = $null
        $preFiles += @{ target = ([string]$st.target); kind = ([string]$st.ckind); rel = ''; present = $false; hash = $null }
      }
    }
    $mfTargets = @()
    try { $mfTargets = @($mf.targets | ForEach-Object { [string]$_ }) } catch {}
    Global-AssertNoLinkChain (Join-Path $pre 'manifest.json') $AutoDir 'バックアップの記録'
    Write-GlobalPrivateJson (Join-Path $pre 'manifest.json') @{ schemaVersion = 1; scope = 'global'; createdAt = ([DateTime]::UtcNow.ToString('o')); homeBase = $HomeBase; targets = $mfTargets; restoredFrom = $BackupId; files = $preFiles } $AutoDir
  }
  catch {
    $shelterErr = $_.Exception.Message
    if ($wasEnabled) {
      try { Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null }
      catch { throw ('復元前の準備に失敗し、自動同期の再開にも失敗しました（休止中のままです）: ' + $shelterErr + ' / ' + $_.Exception.Message) }
      throw ('復元前の準備に失敗しました。自動同期は元の有効状態に戻しました: ' + $shelterErr)
    }
    throw ('復元前の準備に失敗しました。自動同期は休止中のままです: ' + $shelterErr)
  }
  $applied = @()
  try {
    foreach ($st in $steps) {
      if ([string]$st.kind -ceq 'delete') {
        Global-AssertNoLinkChain ([string]$st.dst) $HomeBase ([string]$st.which)
        $applied += @{ kind = 'delete'; dst = ([string]$st.dst) }
        Global-AssertNoLinkChain ([string]$st.dst) $HomeBase ([string]$st.which)
        Remove-Item -LiteralPath ([string]$st.dst) -Force
      }
      else {
        Global-AssertNoLinkChain ([string]$st.src) $AutoDir 'バックアップ'
        Global-AssertNoLinkChain ([string]$st.dst) $HomeBase ([string]$st.which)
        $applied += @{ kind = 'copy'; dst = ([string]$st.dst) }
        Copy-GlobalExpectedBytes ([string]$st.src) ([string]$st.dst) ([string]$st.exp) (Split-Path ([string]$st.dst) -Leaf) $AutoDir $HomeBase
      }
    }
  } catch {
    $rbErrs = @()
    foreach ($a in $applied) {
      try {
        $dst = [string]$a.dst
        if ($origH.ContainsKey($dst) -and ($null -ne $origH[$dst])) {
          $shelter = Join-Path $pre (Get-GlobalBackupRel $HomeBase $dst)
          if (-not (Global-Contained $shelter $pre)) { throw ('巻戻し先を確認できません: ' + $dst) }
          Global-AssertNoLinkChain $shelter $AutoDir 'バックアップ'
          Global-AssertNoLinkChain $dst $HomeBase '巻戻し'
          Copy-GlobalExpectedBytes $shelter $dst ([string]$origH[$dst]) (Split-Path $dst -Leaf) $AutoDir $HomeBase
        }
        else {
          Global-AssertNoLinkChain $dst $HomeBase '巻戻し'
          if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
          if (Test-Path -LiteralPath $dst) { throw ('巻戻しで削除できません: ' + $dst) }
        }
      } catch { $rbErrs += $_.Exception.Message }
    }
    if ($rbErrs.Count -gt 0) { throw ('復元に失敗し、巻戻しも失敗しました。休止中のままです。先の退避を確認してください。: ' + ($rbErrs -join '; ')) }
    throw
  }
  return @{ ok = $true; backup = $pre; paused = $true }
}

function Global-ParseInterval([string]$Iso) {
  if ((-not $Iso) -or ($Iso -cnotmatch '^PT(?:(\d+)H)?(?:(\d+)M)?$')) { return $null }
  $h = 0
  $m = 0
  if ($Matches[1]) { $h = [int]$Matches[1] }
  if ($Matches[2]) { $m = [int]$Matches[2] }
  $t = ($h * 60 + $m)
  if ($t -le 0) { return $null }
  return $t
}
function Global-FormatInterval([int]$Minutes) { return ('PT' + $Minutes + 'M') }
function Test-GlobalIntervalValid([int]$Minutes) { return (($Minutes -ge 5) -and ($Minutes -le 1440)) }
# Project task is never touched here: the Global task name is fixed (no parameter).
function Get-GlobalInterval {
  $t = (Get-GlobalScheduledTask).task
  foreach ($tr in $t.Triggers) {
    try {
      if ($tr.CimClass.CimClassName -ceq 'MSFT_TaskTimeTrigger') {
        $v = Global-ParseInterval ([string]$tr.Repetition.Interval)
        if ($v) { return $v }
      }
    } catch {}
  }
  throw 'Global同期タスクの間隔を取得できませんでした。'
}
function Set-GlobalInterval([int]$Minutes) {
  if (-not (Test-GlobalIntervalValid $Minutes)) { throw '間隔は5〜1440分で指定してください。' }
  # One read per operation: Get and Set must target the same task.
  $r = Get-GlobalScheduledTask
  $taskName = [string]$r.name
  $t = $r.task
  $trs = @($t.Triggers)
  $found = $false
  foreach ($tr in $trs) {
    if ($tr.CimClass.CimClassName -ceq 'MSFT_TaskTimeTrigger') {
      $tr.Repetition.Interval = (Global-FormatInterval $Minutes)
      $found = $true
    }
  }
  if (-not $found) { throw 'Global同期タスクに時刻トリガーがありません。' }
  Set-ScheduledTask -TaskName $taskName -Trigger $trs -ErrorAction Stop | Out-Null
  return @{ ok = $true; minutes = $Minutes }
}
function Get-GlobalTaskEnabled {
  $t = (Get-GlobalScheduledTask).task
  try { if ([string]$t.State -ceq 'Disabled') { return $false } } catch {}
  return $true
}
function Set-GlobalTaskEnabled([bool]$Enabled) {
  $taskName = [string]((Get-GlobalScheduledTask).name)
  if ($Enabled) { Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null }
  else { Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null }
  return @{ ok = $true; enabled = [bool]$Enabled }
}

# Run-id-bound request/result so running/skipped/unknown track real runs.
function Write-GlobalSyncRequest([string]$AutoDir) {
  $id = [System.Guid]::NewGuid().ToString('N')
  $at = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-GlobalPrivateJson (Join-Path $AutoDir 'dashboard.global-lastsync.json') @{ at = $at; id = $id } $AutoDir
  return @{ at = $at; id = $id }
}
function Get-GlobalSyncRequest([string]$AutoDir) {
  $f = Join-Path $AutoDir 'dashboard.global-lastsync.json'
  if ((-not (Test-Path -LiteralPath $f -PathType Leaf)) -or (Global-Reparse $f)) { return $null }
  try {
    $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    if (([string]$o.at -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') -and ([string]$o.id -cmatch '^[0-9a-f]{32}$')) {
      return @{ at = [string]$o.at; id = [string]$o.id }
    }
    return $null
  } catch { return $null }
}
function Get-GlobalSyncResultFile([string]$AutoDir, [string]$RunId) {
  if ($RunId -cnotmatch '^[0-9a-f]{32}$') { return $null }
  $rf = Join-Path $AutoDir ("dashboard.global-sync-" + $RunId + ".json")
  if (-not (Global-Contained $rf $AutoDir)) { return $null }
  return $rf
}
function Write-GlobalSyncResult([string]$AutoDir, [string]$RunId, [int]$ExitCode) {
  $rf = Get-GlobalSyncResultFile $AutoDir $RunId
  if (-not $rf) { throw 'run id が不正です。' }
  $res = 'failed'
  if ($ExitCode -eq 0) { $res = 'success' }
  elseif ($ExitCode -eq 75) { $res = 'skipped' }
  Write-GlobalPrivateJson $rf @{ runId = $RunId; exitCode = [int]$ExitCode; finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); result = $res } $AutoDir
  return @{ ok = $true; runId = $RunId; result = $res }
}
function Get-GlobalSyncResult([string]$AutoDir, [string]$RunId) {
  $rf = Get-GlobalSyncResultFile $AutoDir $RunId
  if ((-not $rf) -or (-not (Test-Path -LiteralPath $rf -PathType Leaf))) { return $null }
  try {
    $o = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$o.runId -cne $RunId) { return $null }
    return $o
  } catch { return $null }
}
# states: running / waiting / success / failed / skipped / unconfirmed / idle.
# A confirmed runID result wins over the lock; without one, success is never claimed.
function Get-GlobalSyncState([string]$AutoDir, [string]$Token, [string]$RunId = '') {
  $running = Test-GlobalSyncLocked $AutoDir
  $req = Get-GlobalSyncRequest $AutoDir
  $syncAt = $null; $syncId = $null
  if ($req) { $syncAt = $req.at; $syncId = $req.id }
  if ($RunId -cmatch '^[0-9a-f]{32}$') { $syncId = $RunId }
  $log = Get-GlobalLogTail $AutoDir $Token
  $state = 'idle'
  $resExit = $null; $resAt = ''
  $confirmed = $false
  if ($syncId) {
    $res0 = Get-GlobalSyncResult $AutoDir $syncId
    if ($res0) {
      try { $resExit = [int]$res0.exitCode } catch { $resExit = 1 }
      try { $resAt = [string]$res0.finishedAt } catch {}
      $resResult = ''
      try { $resResult = [string]$res0.result } catch {}
      if (($resExit -eq 75) -or ($resResult -ceq 'skipped')) { $state = 'skipped'; $confirmed = $true }
      elseif ($resExit -eq 0) { $state = 'success'; $confirmed = $true }
      else { $state = 'failed'; $confirmed = $true }
    }
  }
  if (-not $confirmed) {
    if ($running) { $state = 'running' }
    elseif (-not $req) { $state = 'idle' }
    elseif (-not $syncId) { $state = 'unconfirmed' }
    elseif ([string]$log.name -eq '') { $state = 'waiting' }
    else { $state = 'unconfirmed' }
  }
  return @{
    running = [bool]$running; syncState = $state; syncAt = $syncAt; syncId = $syncId
    logName = [string]$log.name; logMtime = [string]$log.mtime
    finalLine = [string]$log.finalLine; tail = [string]$log.tail
    resultExit = $resExit; resultAt = $resAt
  }
}

# Dot-sourced by self-checks and by Sync-GlobalRules/Dashboard-Server (no exit).
if ($MyInvocation.InvocationName -ne '.') { Write-Host 'Global-Management loaded.' }
