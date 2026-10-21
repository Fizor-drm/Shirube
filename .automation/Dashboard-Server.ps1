# Dashboard-Server.ps1 - Rulesync project registry dashboard (dev source).
# Loopback-only HTTP UI: list / preview-register / unregister / sync-now / last result.
# No new deps: PowerShell 5.1 + .NET HttpListener only. No arbitrary shell/read APIs.
# Registry truth stays projects.json in AutoDir. Never touches AGENTS.md contents
# except backup + head-preview. Mutations cooperate with Sync-ProjectRules.lock
# and write atomically. Dot-sourced by tests (no listen); executed directly listens.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Project-Management.ps1')
. (Join-Path $PSScriptRoot 'Global-Management.ps1')

function Get-AutoDir { return $PSScriptRoot }
function Get-DashboardPort {
  if ($env:DASHBOARD_PORT -match '^[0-9]{2,5}$') { return [int]$env:DASHBOARD_PORT }
  return 18721
}
function Get-DashboardAutoDir {
  if ($env:DASHBOARD_AUTODIR -and (Test-Path -LiteralPath $env:DASHBOARD_AUTODIR -PathType Container)) {
    return $env:DASHBOARD_AUTODIR
  }
  return (Get-AutoDir)
}
function Get-NormPath([string]$P) { return [System.IO.Path]::GetFullPath(($P -replace '/', '\')) }
function Test-Contained([string]$Candidate, [string]$Root) {
  $c = Get-NormPath $Candidate; $r = Get-NormPath $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}
function Test-FullyQualified([string]$P) { return ($P -match '^[A-Za-z]:\\') -or ($P -match '^\\\\') }
function Test-SafeName([string]$N) { return ($N -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') }
function Test-Reparse([string]$P) {
  $it = Get-Item -LiteralPath $P -Force -ErrorAction SilentlyContinue
  if (-not $it) { return $false }
  return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}
# Sync parity: walk parents of $File up to (not incl.) $RepoFull, refuse any reparse.
function Test-ParentReparse([string]$File, [string]$RepoFull) {
  try {
    $pd = Get-NormPath (Split-Path $File -Parent)
    $guard = 0
    while (($pd -cne $RepoFull) -and (Test-Contained $pd $RepoFull) -and ($guard -lt 16)) {
      if (Test-Reparse $pd) { return $true }
      $pd = Get-NormPath (Split-Path $pd -Parent)
      $guard++
    }
  } catch { return $false }
  return $false
}
function Test-PathHasShellMeta([string]$P) {
  if ($P -match '[\*\?]') { return $true }
  if ($P -match '[&|;<>^%!`$()''"]') { return $true }
  return $false
}
# r7: token/state/lastsync は親ACL継承で他principalに読まれるため私的ACLに限定。
# 本人SID/SYSTEM/AdminのみFullControl、継承無効(除外)。sandbox等の他者は含めない。
# 既存ファイルも検証/修復する(本番の適用は親が行う)。secret自体は出力しない。
function Get-PrivateAclSids {
  $sids = @()
  try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544' } catch {}
  return @($sids | Where-Object { $_ -ne $null })
}
function Set-PrivateFileAcl([string]$File) {
  $acl = Get-Acl -LiteralPath $File
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($r in @($acl.Access)) { try { [void]$acl.RemoveAccessRule($r) } catch {} }
  foreach ($sid in (Get-PrivateAclSids)) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
    [void]$acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $File -AclObject $acl
}
function Test-PrivateFileAcl([string]$File) {
  try {
    $acl = Get-Acl -LiteralPath $File
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $expected = @{}
    foreach ($sid in (Get-PrivateAclSids)) { $expected[$sid.Value] = $true }
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
        if (($v -ceq $k) -and (($r.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)) { $found = $true; break }
      }
      if (-not $found) { return $false }
    }
    return $true
  } catch { return $false }
}
# r7b: 新規作成時から私的ACLで作り、他principalに読める時間を避ける。
# 既存は修復後に上書き(ACL維持のため読める時間なし)。PS5.1組込のみ。
function New-PrivateFileSecurity {
  $sec = New-Object System.Security.AccessControl.FileSecurity
  $sec.SetAccessRuleProtection($true, $false)
  foreach ($sid in (Get-PrivateAclSids)) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
    $sec.AddAccessRule($rule)
  }
  return $sec
}
function Write-PrivateText([string]$File, [string]$Content) {
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($Content)
  if (Test-Path -LiteralPath $File) {
    if (-not (Test-PrivateFileAcl $File)) { Set-PrivateFileAcl $File }
    $fs = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    if (-not (Test-PrivateFileAcl $File)) { Set-PrivateFileAcl $File }
  }
  else {
    try {
      $sec = New-PrivateFileSecurity
      $fs = [System.IO.File]::Create($File, 4096, [System.IO.FileOptions]::None, $sec)
      try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    }
    catch [System.IO.IOException] {
      if (-not (Test-PrivateFileAcl $File)) { Set-PrivateFileAcl $File }
      $fs2 = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
      try { $fs2.Write($bytes, 0, $bytes.Length) } finally { $fs2.Close() }
    }
  }
}
function Get-FileHashHex([string]$File) {
  try {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return ((($h.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')) }
    finally { $h.Dispose() }
  } catch { return $null }
}
function Get-BodyWithoutFrontmatter([string]$Text) {
  $norm = $Text -replace "`r`n", "`n"; $norm = $norm -replace "`r", "`n"
  $b = [regex]::Replace($norm, '\A---[ \t]*\n.*?\n---[ \t]*(?:\n|\Z)', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  return $b.Trim()
}
function Open-SyncLock([string]$AutoDir) {
  $lp = Join-Path $AutoDir 'Sync-ProjectRules.lock'
  try { return [System.IO.File]::Open($lp, 'OpenOrCreate', 'ReadWrite', 'None') }
  catch {
    $e = $_.Exception
    while (($e -is [System.Management.Automation.MethodInvocationException]) -and ($e.InnerException)) { $e = $e.InnerException }
    if ($e -is [System.IO.IOException]) { throw '同期実行中のため、終了後にやり直してください。(busy)' }
    throw
  }
}
function Test-FrontmatterFlag([string]$Text, [string]$Key) {
  $norm = $Text -replace "`r`n", "`n"; $norm = $norm -replace "`r", "`n"
  if ($norm -notmatch '\A---[ \t]*\n') { return $false }
  $m = [regex]::Match($norm, '\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { return $false }
  $lines = ($m.Groups[1].Value -split "`n")
  $hits = 0; $seenTargets = 0; $seenDesc = 0
  foreach ($ln in $lines) {
    if ($ln -match '^[ \t]*$') { continue }
    if ($ln -match '^[ \t]') { return $false }
    if ($ln -match ':\s*[|>]\s*(#.*)?$') { return $false }
    if ($ln -match ('^' + $Key + '\s*:\s*true\s*(#.*)?$')) { $hits++; continue }
    elseif ($ln -match ('^' + $Key + '\s*:')) { return $false }
    if ($ln -match '^targets\s*:\s*\[\s*"codexcli"\s*,\s*"opencode"\s*\]\s*(#.*)?$') { $seenTargets++; if ($seenTargets -gt 1) { return $false }; continue }
    elseif ($ln -match '^targets\s*:') { return $false }
    if ($ln -match '^description\s*:\s*".*"\s*(#.*)?$') { $seenDesc++; if ($seenDesc -gt 1) { return $false }; continue }
    elseif ($ln -match '^description\s*:') { return $false }
    return $false
  }
  if ($hits -ne 1) { return $false }
  if ($seenTargets -ne 1) { return $false }
  if ($Key -eq 'localRoot') { foreach ($ln in $lines) { if ($ln -match '^root\s*:') { return $false } } }
  if ($Key -eq 'root') { foreach ($ln in $lines) { if ($ln -match '^localRoot\s*:') { return $false } } }
  return $true
}

function Get-Registry([string]$AutoDir) {
  $f = Join-Path $AutoDir 'projects.json'
  if (-not (Test-Path -LiteralPath $f)) { return @() }
  $arr = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($arr -isnot [array]) { $arr = @($arr) }
  return $arr
}
function Test-SyncLocked([string]$AutoDir) {
  $lp = Join-Path $AutoDir 'Sync-ProjectRules.lock'
  try { $s = [System.IO.File]::Open($lp, 'OpenOrCreate', 'ReadWrite', 'None'); $s.Close(); return $false }
  catch {
    $e = $_.Exception
    while (($e -is [System.Management.Automation.MethodInvocationException]) -and ($e.InnerException)) { $e = $e.InnerException }
    if ($e -is [System.IO.IOException]) { return $true }
    throw
  }
}
function Write-RegistryAtomicLocked([string]$AutoDir, [array]$Entries) {
  $f = Join-Path $AutoDir 'projects.json'
  $tmp = Join-Path $AutoDir ('projects.json.tmp-' + [System.Guid]::NewGuid().ToString('N'))
  if (-not (Test-Contained $tmp $AutoDir)) { throw 'tmp escaped autodir.' }
  $json = ConvertTo-Json -InputObject $Entries -Depth 5 -Compress
  [void](New-Object System.Object) # no-op keep PS5.1 parser calm
  Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -NoNewline
  $check = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($check -isnot [array]) { $check = @($check) }
  if ($check.Count -ne $Entries.Count) { Remove-Item -LiteralPath $tmp -Force; throw 'registry verify failed, not written.' }
  # r4: Move-Item -Force is delete-then-move (non-atomic, original can be lost).
  # Existing destination -> File.Replace (atomic); new file -> File.Move.
  # PS5.1/.NET FW needs a real backup path (null is rejected), so use a sibling
  # backup and delete it on success. Failure keeps the original.
  try {
    if (Test-Path -LiteralPath $f) {
      $bak = Join-Path $AutoDir ('projects.json.bak-' + [System.Guid]::NewGuid().ToString('N'))
      if (-not (Test-Contained $bak $AutoDir)) { throw 'backup escaped autodir.' }
      [System.IO.File]::Replace($tmp, $f, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch {}
    }
    else { [System.IO.File]::Move($tmp, $f) | Out-Null }
  }
  catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    throw ('registry replace failed, original kept: ' + $_.Exception.Message)
  }
}
function Write-RegistryAtomic([string]$AutoDir, [array]$Entries) {
  if (Test-SyncLocked $AutoDir) { throw '同期実行中のため、終了後にやり直してください。(busy)' }
  Write-RegistryAtomicLocked $AutoDir $Entries
}
function Suggest-SafeName([string]$RepoFull, [array]$Registry) {
  $base = Split-Path -Leaf $RepoFull
  if (-not $base) { $base = 'project' }
  $cand = $base
  if (-not (Test-SafeName $cand)) {
    $cand = ([regex]::Replace($cand, '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-').Trim('.', '-', ' ')
    if (($cand.Length -lt 2) -or ($cand -notmatch '^[A-Za-z0-9]')) { $cand = 'project' }
    if ($cand.Length -gt 48) { $cand = $cand.Substring(0, 48) }
  }
  $taken = @{}
  foreach ($e in $Registry) { $taken[[string]$e.name] = $true }
  if (-not $taken.ContainsKey($cand)) { return $cand }
  for ($i = 2; $i -le 99; $i++) {
    $n = "$cand-$i"
    if ($n.Length -gt 64) { $n = ($cand.Substring(0, 64 - ($i.ToString().Length + 1)) + "-$i") }
    if (-not $taken.ContainsKey($n)) { return $n }
  }
  throw 'name exhausted.'
}
function Get-CommonBody([string]$AutoDir) {
  $cur = Join-Path (Split-Path $AutoDir -Parent) 'project-common-preview\.rulesync\rules\.curated\project.md'
  if (-not (Test-Path -LiteralPath $cur)) { return $null }
  $t = Get-Content -LiteralPath $cur -Raw -Encoding UTF8
  if (-not (Test-FrontmatterFlag $t 'root')) { return $null }
  $body = [regex]::Replace($t, '\A---[ \t]*\r?\n.*?\r?\n---[ \t]*(?:\r?\n|\Z)', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  return $body.Trim()
}
# Strict variant: a valid empty body (frontmatter-only file) is returned as
# ''; missing/malformed/reparse/unreadable dependencies throw so callers can
# never mistake failure for an empty body.
function Get-CommonBodyStrict([string]$AutoDir) {
  $cur = Join-Path (Split-Path $AutoDir -Parent) 'project-common-preview\.rulesync\rules\.curated\project.md'
  if ((-not (Test-Path -LiteralPath $cur -PathType Leaf)) -or (Test-Reparse $cur)) { throw '共通ルールを確認できませんでした。' }
  $t = ''
  try { $t = [System.IO.File]::ReadAllText($cur, [System.Text.Encoding]::UTF8) } catch { throw '共通ルールを確認できませんでした。' }
  if (-not (Test-FrontmatterFlag $t 'root')) { throw '共通ルールを確認できませんでした。' }
  $body = [regex]::Replace($t, '\A---[ \t]*\r?\n.*?\r?\n---[ \t]*(?:\r?\n|\Z)', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  return $body.Trim()
}
# Plain .NET read: Get-Content -Raw keeps ETS props (PSPath etc.) that explode ConvertTo-Json.
function Read-Head([string]$File, [int]$MaxChars = 2000) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  $t = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
  if ($t.Length -gt $MaxChars) { return $t.Substring(0, $MaxChars) + "`n...(省略)..." }
  return $t
}
function Redact-Text([string]$Text, [string]$Token) {
  $r = $Text
  $vals = @()
  if ($Token) { $vals += $Token }
  foreach ($e in @($env:GITHUB_TOKEN, $env:GH_TOKEN)) {
    if ($e -and ([string]$e).Trim() -ne '') { $vals += [string]$e }
  }
  foreach ($v in @($vals | Select-Object -Unique)) { $r = $r.Replace($v, '***') }
  $r = [regex]::Replace($r, '(?i)(github_token|gh_token|bearer)[=:\s]+\S+', '$1=***')
  $r = [regex]::Replace($r, '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{8,}', '${1}_***')
  $r = [regex]::Replace($r, 'github_pat_[A-Za-z0-9_]{8,}', 'github_pat_***')
  return $r
}

# Preview: validates path, never writes. Returns hashtable (ok / error / fields).
# Existing AGENTS.md is never auto-converted: transcription-needed or duplicate-suspect stops registration.
function Get-RegisterPreview([string]$AutoDir, [string]$RawPath, [bool]$AllowReplaceAgents = $false) {
  $allowReplaceAgents = [bool]$AllowReplaceAgents
  if ([string]::IsNullOrWhiteSpace($RawPath)) { return @{ ok = $false; error = 'フォルダのパスを入力してください。(例 C:\Project\MyRepo)' } }
  $p = $RawPath.Trim()
  if (-not (Test-FullyQualified $p)) { return @{ ok = $false; error = '絶対パスで入力してください。(例 C:\Project\MyRepo、 drive相対 C:repo は不可)' } }
  if (Test-PathHasShellMeta $p) { return @{ ok = $false; error = 'パスに & ; | などの記号が含まれています。同期コマンド経由の安全性が未確定のため登録できません。記号のないフォルダ名にしてください。' } }
  try { $full = Get-NormPath $p } catch { return @{ ok = $false; error = 'パスを解釈できませんでした。' } }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { return @{ ok = $false; error = 'フォルダが存在しません。先にフォルダを作成してください。' } }
  if (Test-Reparse $full) { return @{ ok = $false; error = 'リンク・ジャンクションのフォルダは登録できません。実体フォルダを指定してください。' } }
  $reg = @(Get-Registry $AutoDir)
  foreach ($e in $reg) {
    try { if ((Get-NormPath ([string]$e.path)).Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) { return @{ ok = $false; error = ('既に登録されています: ' + ([string]$e.name)) } } } catch {}
  }
  $name = Suggest-SafeName $full $reg
  $agents = Join-Path $full 'AGENTS.md'
  $local = Join-Path $full '.rulesync\rules\project-local.md'
  $hasAgents = (Test-Path -LiteralPath $agents) -and (-not (Get-Item -LiteralPath $agents -Force -ErrorAction SilentlyContinue).PSIsContainer)
  $agentsReparse = $false
  if ($hasAgents) { $agentsReparse = Test-Reparse $agents }
  if ($agentsReparse) { return @{ ok = $false; error = 'AGENTS.md がリンクになっています。実体ファイルに戻してから登録してください。' } }
  $hasLocal = (Test-Path -LiteralPath $local) -and (-not (Get-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue).PSIsContainer)
  if ($hasLocal -and (Test-Reparse $local)) { return @{ ok = $false; error = 'project-local.md がリンクになっています。実体ファイルに戻してから登録してください。' } }
  if ($hasLocal -and (Test-ParentReparse $local $full)) { return @{ ok = $false; error = 'project-local.md の親フォルダがリンク・ジャンクションになっています。実体フォルダに戻してから登録してください。' } }
  if ($hasLocal) {
    $lt = Get-Content -LiteralPath $local -Raw -Encoding UTF8
    if (-not (Test-FrontmatterFlag $lt 'localRoot')) {
      return @{ ok = $false; error = '既存 project-local.md の先頭形式が不正です。安全のため停止します。形式を直すか、内容を確認してから登録してください。' }
    }
  }
  # r3: existing AGENTS.md stops by default. Force-replace is opt-in (backup then regenerate).
  # Lossless: extra unique content in AGENTS would be lost by regenerate, so require manual整理 first unless consent.
  if ($hasAgents -and -not $allowReplaceAgents) {
    return @{ ok = $false; error = '既存 AGENTS.md があります。登録後の同期で再生成されるため固有内容が失われます。必要な内容を project-local.md に手動転記し、AGENTS.md を手動で整理（移動または削除）してから登録してください。自動変換はしません。' }
  }
  $localHead = $null
  if ($hasLocal) { $localHead = Read-Head $local }
  $localHash = $null
  if ($hasLocal) { $localHash = Get-FileHashHex $local }
  $agentsHead = $null
  $agentsHash = $null
  if ($hasAgents) { $agentsHead = Read-Head $agents; $agentsHash = Get-FileHashHex $agents }
  return @{
    ok = $true; name = $name; path = $full; hasAgents = [bool]$hasAgents; hasLocal = [bool]$hasLocal
    agentsHead = $agentsHead; localHead = $localHead; agentsHash = $agentsHash; localHash = $localHash
    duplicateSuspect = $false; needsManual = $false; forceReplace = [bool]$allowReplaceAgents
  }
}

function Get-SessionToken([string]$AutoDir) {
  $f = Join-Path $AutoDir 'dashboard.token'
  if (Test-Path -LiteralPath $f) {
    $t = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).Trim()
    if ($t -match '^[0-9a-f]{64}$') {
      if (-not (Test-PrivateFileAcl $f)) { Set-PrivateFileAcl $f }
      return $t
    }
  }
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  $b = New-Object byte[] 32
  $rng.GetBytes($b); $rng.Dispose()
  $t = -join ($b | ForEach-Object { $_.ToString('x2') })
  Write-PrivateText $f $t
  return $t
}
function Test-HostValid([string]$HostHeader, [int]$Port) {
  if (-not $HostHeader) { return $false }
  $h = $HostHeader.Trim().ToLowerInvariant()
  return ($h -eq "127.0.0.1:$Port") -or ($h -eq "localhost:$Port")
}
function Test-OriginValid([string]$Origin, [int]$Port) {
  if (-not $Origin) { return $false }
  $o = $Origin.Trim().ToLowerInvariant().TrimEnd('/')
  return ($o -eq "http://127.0.0.1:$Port") -or ($o -eq "http://localhost:$Port")
}
function Write-SyncRequest([string]$AutoDir) {
  $id = [System.Guid]::NewGuid().ToString('N')
  $at = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $rf = Join-Path $AutoDir 'dashboard.lastsync.txt'
  Write-PrivateText $rf ($at + '|' + $id)
  return @{ at = $at; id = $id }
}
function Get-SyncRequest([string]$AutoDir) {
  $f = Join-Path $AutoDir 'dashboard.lastsync.txt'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $t = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).Trim()
    if ($t -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\|([0-9a-f]{32})$') { return @{ at = $Matches[1]; id = $Matches[2] } }
    if ($t -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') { return @{ at = $t; id = $null } }
    return $null
  } catch { return $null }
}
# r4: real child result bound to runID. Result file per request; log tail is display-only.
function Get-SyncResultFile([string]$AutoDir, [string]$RunId) {
  if ($RunId -cnotmatch '^[0-9a-f]{32}$') { return $null }
  $rf = Join-Path $AutoDir ("dashboard.sync-" + $RunId + ".json")
  if (-not (Test-Contained $rf $AutoDir)) { return $null }
  return $rf
}
function Get-SyncResult([string]$AutoDir, [string]$RunId) {
  $rf = Get-SyncResultFile $AutoDir $RunId
  if ((-not $rf) -or (-not (Test-Path -LiteralPath $rf))) { return $null }
  try {
    $o = Get-Content -LiteralPath $rf -Raw -Encoding Ascii | ConvertFrom-Json
    if ([string]$o.runId -cne $RunId) { return $null }
    return $o
  } catch { return $null }
}
# Browse: one request ID, fixed STA helper in a separate visible process.
# The HttpListener loop never waits for the dialog; the page polls with a bound.
function Get-BrowseResultFile([string]$AutoDir, [string]$BrowseId) {
  if ($BrowseId -cnotmatch '^[0-9a-f]{32}$') { return $null }
  $rf = Join-Path $AutoDir ("dashboard.browse-" + $BrowseId + ".json")
  if (-not (Test-Contained $rf $AutoDir)) { return $null }
  return $rf
}
function Get-BrowseResult([string]$AutoDir, [string]$BrowseId) {
  $rf = Get-BrowseResultFile $AutoDir $BrowseId
  if ((-not $rf) -or (-not (Test-Path -LiteralPath $rf))) { return $null }
  try {
    $o = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$o.browseId -cne $BrowseId) { return $null }
    if (([string]$o.status -cne 'selected') -and ([string]$o.status -cne 'cancelled')) { return $null }
    return $o
  } catch { return $null }
}
# Browse result holds Japanese paths, so UTF8 with BOM (PS5.1 CP932 would corrupt BOM-less). Private ACL same as token.
function Write-BrowseResultPrivate([string]$File, [string]$Content) {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  $bytes = $utf8bom.GetPreamble() + $utf8bom.GetBytes($Content)
  if (Test-Path -LiteralPath $File) {
    if (-not (Test-PrivateFileAcl $File)) { Set-PrivateFileAcl $File }
    $fs = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    if (-not (Test-PrivateFileAcl $File)) { Set-PrivateFileAcl $File }
  }
  else {
    try {
      $sec = New-PrivateFileSecurity
      $fs = [System.IO.File]::Create($File, 4096, [System.IO.FileOptions]::None, $sec)
      try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    }
    catch [System.IO.IOException] {
      if (-not (Test-PrivateFileAcl $File)) { Set-PrivateFileAcl $File }
      $fs2 = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
      try { $fs2.Write($bytes, 0, $bytes.Length) } finally { $fs2.Close() }
    }
  }
}
function Remove-OldBrowseFiles([string]$AutoDir) {
  try {
    $olds = @()
    $olds += @(Get-ChildItem -LiteralPath $AutoDir -Filter 'dashboard.browse-*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 60 })
    $olds += @(Get-ChildItem -LiteralPath $AutoDir -Filter 'dashboard.browse-*.tmp-*' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 60 })
    foreach ($f in @($olds)) {
      try {
        $full = $f.FullName
        if (Test-Contained $full $AutoDir) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
      } catch {}
    }
  } catch {}
}
# Browse owner capture (foregroundfix r2): server-side GetForegroundWindow at click time.
# Best-effort only: OS may refuse foreground rights; Show(owner) stays z-order basis.
# Trust boundary: owner is never taken from HTTP body (injection prevents arbitrary
# HWND). Only this server-side capture is passed as -OwnerHwnd/-OwnerPid/-OwnerStart data.
# r2 fixes: (1) interop pre-compiled at startup (no AddType delay in request path),
# (2) capture as early as possible at API reception (before body/cleanup),
# (3) [r3] all browsers need process+class AND known Dashboard title (Shirube),
# different-title window is owner 0 (process+class alone never adopts),
# (4) HWND+PID+start identity kept for helper (HWND reuse/PID reuse reject).
# r3 capture order: auth, then early capture before body, then proc cleanup
# (pre-auth expiry skipped for browse/start; Start-BrowseRequest cleans post-capture).
# x86 HWND width is intentional (int.MaxValue on x86, long.MaxValue on x64).
function Initialize-BrowseOwnerNative {
  try {
    try { $null = [DashboardBrowseNative]; return } catch {}
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DashboardBrowseNative {
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  public static long GetForegroundWindowForTest() {
    try { return GetForegroundWindow().ToInt64(); } catch { return 0; }
  }
  public static int GetWindowPidForTest(IntPtr h) {
    try {
      if (h == IntPtr.Zero) { return 0; }
      uint pid = 0;
      GetWindowThreadProcessId(h, out pid);
      if (pid == 0) { return 0; }
      if (pid > (uint)int.MaxValue) { return 0; }
      return (int)pid;
    } catch { return 0; }
  }
  public static string GetWindowClassForTest(IntPtr h) {
    try {
      if (h == IntPtr.Zero) { return ""; }
      StringBuilder sb = new StringBuilder(512);
      int n = GetClassName(h, sb, sb.Capacity);
      if (n <= 0) { return ""; }
      return sb.ToString();
    } catch { return ""; }
  }
  public static string GetWindowTitleForTest(IntPtr h) {
    try {
      if (h == IntPtr.Zero) { return ""; }
      StringBuilder sb = new StringBuilder(512);
      GetWindowText(h, sb, sb.Capacity);
      return sb.ToString();
    } catch { return ""; }
  }
}
'@ -ErrorAction Stop
  } catch { if ($_.Exception.Message -notmatch 'already exists') { throw } }
}
# Browser/owner allow check (pure, testable, no popup): all browsers need Chromium/Firefox
# process+class AND the known Dashboard title (Shirube); T3/Electron via Shirube title+proc.
# A different-title browser tab/window is never adopted (owner 0). Arbitrary apps excluded.
function Test-BrowseOwnerAllowed([string]$ProcName, [string]$ClassName, [string]$Title) {
  try {
    $p = ''
    try { $p = ([string]$ProcName).Trim().ToLowerInvariant() } catch { $p = '' }
    $c = ''
    try { $c = ([string]$ClassName).Trim() } catch { $c = '' }
    $t = ''
    try { $t = ([string]$Title) } catch { $t = '' }
    $hasShirube = $false
    try { if ($t -and ($t.ToLowerInvariant().Contains('shirube'))) { $hasShirube = $true } } catch {}
    if (-not $hasShirube) { return $false }
    if (($p -ceq 'chrome') -or ($p -ceq 'chromium') -or ($p -ceq 'msedge')) {
      if (($c -eq '') -or ($c -ceq 'Chrome_WidgetWin_1')) { return $true }
    }
    if ($p -ceq 'firefox') {
      if (($c -eq '') -or ($c -ceq 'MozillaWindowClass')) { return $true }
    }
    if ($p -and (($p.Contains('electron')) -or ($p.Contains('t3')))) { return $true }
    return $false
  } catch { return $false }
}
function Get-BrowseOwnerCapture {
  try {
    try { $null = [DashboardBrowseNative] } catch { try { Initialize-BrowseOwnerNative } catch {} }
    [long]$v = 0
    try { $v = [DashboardBrowseNative]::GetForegroundWindowForTest() } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    if ($v -le 0) { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    try {
      [long]$max = [long]::MaxValue
      if ([System.IntPtr]::Size -eq 4) { $max = [long][int]::MaxValue }
      if ($v -gt $max) { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    [IntPtr]$h = [IntPtr]::Zero
    try { $h = New-Object System.IntPtr($v) } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    [int]$opid = 0
    try { $opid = [DashboardBrowseNative]::GetWindowPidForTest($h) } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    if ($opid -le 0) { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    [string]$cls = ''
    [string]$ttl = ''
    try { $cls = [DashboardBrowseNative]::GetWindowClassForTest($h) } catch {}
    try { $ttl = [DashboardBrowseNative]::GetWindowTitleForTest($h) } catch {}
    [string]$proc = ''
    [string]$start = ''
    try {
      $p0 = [System.Diagnostics.Process]::GetProcessById($opid)
      try {
        try { $proc = [string]$p0.ProcessName } catch {}
        try { $start = $p0.StartTime.ToString('o') } catch {}
      } finally { try { $p0.Dispose() } catch {} }
    } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    try { if (-not (Test-BrowseOwnerAllowed $proc $cls $ttl)) { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } } } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
    return @{ Hwnd = $v; Pid = $opid; Start = $start }
  } catch { return @{ Hwnd = [long]0; Pid = [int]0; Start = '' } }
}
function Get-BrowseOwnerHwndLong {
  try {
    $c0 = Get-BrowseOwnerCapture
    if ($c0 -and ([long]$c0.Hwnd) -gt 0) { return [long]$c0.Hwnd }
    return [long]0
  } catch { return [long]0 }
}
try { Initialize-BrowseOwnerNative } catch {}
# r2: owned browse helper process per request ID + deadline. Cancel/timeout/server-exit
# stops only the owned Process object, never an unrelated process. GUID tmp files are covered above.
# r4: PS5.1 Start-Process -PassThru の返却直後に native handle ($proc.Handle) を取得保持し
# ハンドル寿命を確保する。停止は保持した Process オブジェクトの Kill のみで行い、
# Stop-Process -Id によるPID指定の代替手段は撤去した(PID再利用で別procを止める恐れ)。
# Handle取得前のProcess Disposeは禁止。所有管理(expiry/cancel/server-exit)は維持。
function Stop-OwnedBrowseProcess([string]$BrowseId) {
  try {
    if (-not $script:BrowseProcs.ContainsKey($BrowseId)) { return }
    $ent = $script:BrowseProcs[$BrowseId]
    $script:BrowseProcs.Remove($BrowseId) | Out-Null
    try {
      $proc = $null
      try { $proc = $ent.Proc } catch {}
      if ($proc -ne $null) {
        # 所有オブジェクトのみKill+待機。Process自体のDisposeはしない(呼び出し側のHasExited参照を壊さない最小化)。
        try { if (-not $proc.HasExited) { try { $proc.Kill() } catch {} } } catch {}
        try { $proc.WaitForExit(2000) } finally { try { $proc.Dispose() } catch {} }
      }
      # NOTE: Pid-only entry intentionally stops nothing (PID reuse risk; no ID-based stop).
    } catch {}
  } catch {}
}
function Clear-ExpiredBrowseRequests([string]$AutoDir) {
  try {
    foreach ($k in @($script:BrowseProcs.Keys)) {
      try {
        $ent = $script:BrowseProcs[$k]
        if ($ent -and $ent.Expires -and ((Get-Date) -gt [datetime]$ent.Expires)) {
          try { Write-BrowseCancelled $AutoDir $k | Out-Null } catch {}
        }
      } catch {}
    }
  } catch {}
}
function Start-BrowseRequest([string]$AutoDir, [string]$Hint, [hashtable]$PreCaptured = $null) {
  $id = [System.Guid]::NewGuid().ToString('N')
  # r3: early API capture only (after auth, before body). No late fallback: a different-title
  # window at click time stays owner 0 instead of re-picking later. Trust boundary: $PreCaptured
  # is server-side capture only, never HTTP body.
  $cap = $null
  try { if ($PreCaptured -and ([long]$PreCaptured.Hwnd) -gt 0) { $cap = $PreCaptured } } catch {}
  Remove-OldBrowseFiles $AutoDir
  Clear-ExpiredBrowseRequests $AutoDir
  $helper = Join-Path $AutoDir 'Browse-Folder.ps1'
  if (-not (Test-Path -LiteralPath $helper)) { throw '選択ヘルパーが見つかりません。(Browse-Folder.ps1 未配置)' }
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $ps)) { throw 'powershell absolute missing.' }
  # Console stays hidden; the folder dialog itself is visible and interactive (explicit user request).
  $args = @('-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"", '-AutoDir', "`"$AutoDir`"", '-BrowseId', "`"$id`"")
  # Foreground basis: server-captured HWND+PID+start as owner data. Helper validates
  # live+visible+identity on its STA thread, falls back to Zero when not a browser
  # window. Invalid/zero keeps current parentless behavior (safe).
  try {
    if ($cap -and ([long]$cap.Hwnd) -gt 0) {
      $args += @('-OwnerHwnd', "`"$([long]$cap.Hwnd)`"")
      try { if ([int]$cap.Pid -gt 0) { $args += @('-OwnerPid', "`"$([int]$cap.Pid)`"") } } catch {}
      try { $s0 = [string]$cap.Start; if ($s0 -and ($s0.Trim() -ne '')) { $args += @('-OwnerStart', "`"$s0`"") } } catch {}
    }
  } catch {}
  $h = ''
  if ($Hint -and ($Hint.Trim() -ne '')) {
    try {
      $h = Get-NormPath ($Hint.Trim())
      if ((Test-Path -LiteralPath $h -PathType Container)) { $args += @('-InitialPath', "`"$h`"") }
    } catch {}
  }
  $proc = Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden -PassThru
  # r4: 起動直後に native handle を取得保持(Disposeは取得後のみ)。PIDのみ保存では再利用で別procを止める。
  try { $null = $proc.Handle } catch {}
  $h = [System.IntPtr]::Zero
  try { $h = $proc.Handle } catch {}
  $script:BrowseProcs[$id] = @{ Proc = $proc; Handle = $h; Expires = (Get-Date).AddSeconds(150) }
  return @{ browseId = $id }
}
function Write-BrowseCancelled([string]$AutoDir, [string]$BrowseId) {
  $rf = Get-BrowseResultFile $AutoDir $BrowseId
  if (-not $rf) { throw 'browse id が不正です。' }
  $cur = Get-BrowseResult $AutoDir $BrowseId
  if ($cur) { try { Stop-OwnedBrowseProcess $BrowseId } catch {}; return $cur }
  $at = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $o = @{ browseId = $BrowseId; status = 'cancelled'; finishedAt = $at }
  $j = ConvertTo-Json -InputObject $o -Depth 3 -Compress
  Write-BrowseResultPrivate $rf $j
  try { Stop-OwnedBrowseProcess $BrowseId } catch {}
  return $o
}
# Explorer: re-resolve the absolute path from the registered name. No arbitrary path API.
function Get-RegisteredFolderPath([string]$AutoDir, [string]$Name) {
  if (-not (Test-SafeName $Name)) { throw '名前が不正です。' }
  $reg = @(Get-Registry $AutoDir)
  $hit = @($reg | Where-Object { [string]$_.name -ceq $Name })
  if ($hit.Count -eq 0) { throw '登録が見つかりません。' }
  $full = ''
  try { $full = Get-NormPath ([string]$hit[0].path) } catch { throw 'パスを解釈できませんでした。' }
  if (-not (Test-FullyQualified $full)) { throw '登録パスが絶対パスではありません。' }
  if (Test-PathHasShellMeta $full) { throw '登録パスに記号が含まれているため開けません。' }
  if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw 'フォルダが存在しません。' }
  if (Test-Reparse $full) { throw 'リンク・ジャンクションのフォルダは開けません。' }
  return $full
}
function Get-LastProjectLog([string]$AutoDir) {
  $logs = Join-Path $AutoDir 'logs'
  if (-not (Test-Path -LiteralPath $logs)) { return $null }
  $files = Get-ChildItem -LiteralPath $logs -Filter 'Sync-ProjectRules-*.log' -ErrorAction SilentlyContinue | Sort-Object Name -Descending
  if (-not $files -or $files.Count -eq 0) { return $null }
  $f = $files[0]
  return @{ name = $f.Name; full = $f.FullName; mtime = $f.LastWriteTime }
}
# r3: lock-only is not completion.
# r4: success/failed only from real child result file bound to runID (Watch-Sync.ps1).
# r5: busy skip (exit 75 / result skipped) is distinct from success. Periodic
# without -ReportSkip still exits 0; dashboard child uses -ReportSkip via Watch.
# Log final lines are display-only; old or fresh logs never imply this run completed.
# r6: runID-confirmed result wins over lock. running stays an independent field;
# state is running only when no confirmed result exists for this runID. This lets
# a 75/skipped child result report skipped even while another run holds the lock.
# states: running / waiting / success / failed / skipped / unconfirmed / idle
function Get-SyncState([string]$AutoDir, [string]$Token) {
  $running = Test-SyncLocked $AutoDir
  $req = Get-SyncRequest $AutoDir
  $syncAt = $null; $syncId = $null
  if ($req) { $syncAt = $req.at; $syncId = $req.id }
  $logName = ''; $logMtimeStr = ''; $final = ''; $tail = ''; $logMtime = $null
  $li = Get-LastProjectLog $AutoDir
  if ($li) {
    $logName = $li.name; $logMtime = $li.mtime
    $logMtimeStr = $li.mtime.ToString('yyyy-MM-dd HH:mm:ss')
    try {
      $lines = @(Get-Content -LiteralPath $li.full -Tail 60 -Encoding UTF8 -ErrorAction SilentlyContinue)
      if ($lines -and $lines.Count -gt 0) {
        $tail = Redact-Text ($lines -join "`n") $Token
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
          $ln = [string]$lines[$i]
          if ($ln.Contains('OK:')) { $final = $ln; break }
          if ($ln.Contains('FAIL:')) { $final = $ln; break }
          if ($ln.Contains('SKIP:')) { $final = $ln; break }
        }
      }
    } catch {}
  }
  $state = 'idle'
  $resExit = $null; $resAt = ''
  # r6: confirmed runID result first; lock/running never hides it.
  $resConfirmed = $false
  if ($syncId) {
    $res0 = Get-SyncResult $AutoDir $syncId
    if ($res0) {
      try { $resExit = [int]$res0.exitCode } catch { $resExit = 1 }
      try { $resAt = [string]$res0.finishedAt } catch {}
      $resResult = ''
      try { $resResult = [string]$res0.result } catch {}
      if (($resExit -eq 75) -or ($resResult -ceq 'skipped')) { $state = 'skipped'; $resConfirmed = $true }
      elseif ($resExit -eq 0) { $state = 'success'; $resConfirmed = $true }
      else { $state = 'failed'; $resConfirmed = $true }
    }
  }
  if (-not $resConfirmed) {
    if ($running) { $state = 'running' }
    elseif (-not $req) { $state = 'idle' }
    elseif (-not $syncId) { $state = 'unconfirmed' }
    elseif (-not $li) { $state = 'waiting' }
    else { $state = 'unconfirmed' }
  }
  return @{ running = $running; syncState = $state; syncAt = $syncAt; syncId = $syncId; logName = $logName; logMtime = $logMtimeStr; finalLine = $final; tail = $tail; resultExit = $resExit; resultAt = $resAt }
}
function Get-Status([string]$AutoDir, [string]$Token) {
  $s = Get-SyncState $AutoDir $Token
  $reg = @(Get-Registry $AutoDir)
  $s['count'] = $reg.Count
  $s['instance'] = $script:InstanceId
  $s['port'] = (Get-DashboardPort)
  return $s
}
function Start-HiddenSync([string]$AutoDir, [string[]]$ProjectNames = @(), [bool]$PreviewOnly = $false, [string]$PlanPath = '', [string]$PlanId = '') {
  $vbs = Join-Path $AutoDir 'Run-ProjectRules.vbs'
  if (-not (Test-Path -LiteralPath $vbs)) { throw 'hidden task launcher missing.' }
  if ($ProjectNames -and ($ProjectNames.Count -gt 0)) {
    $reg = @(Get-Registry $AutoDir)
    foreach ($sn in $ProjectNames) {
      if ((-not (Test-SafeName ([string]$sn))) -or (@($reg | Where-Object { [string]$_.name -ceq ([string]$sn) }).Count -ne 1)) { throw 'unknown or ambiguous selected project.' }
    }
  }
  if (($PlanId -ne '') -and ($PlanId -cnotmatch '^[0-9a-f]{32}$')) { throw 'invalid plan id.' }
  $req = Write-SyncRequest $AutoDir
  # Selection/preview travel in a request file the fixed sync script reads.
  # previewOnly runs never touch repos: Sync writes only the plan file.
  $reqFile = Join-Path $AutoDir ("dashboard.request-" + $req.id + ".json")
  if (-not (Test-Contained $reqFile $AutoDir)) { throw 'request escaped autodir.' }
  $reqObj = @{ projectNames = @($ProjectNames); previewOnly = [bool]$PreviewOnly; planPath = [string]$PlanPath; planId = [string]$PlanId }
  Write-BrowseResultPrivate $reqFile (ConvertTo-Json -InputObject $reqObj -Depth 5 -Compress)
  # r5: hidden monitor runs the fixed sync script with -ReportSkip (via Watch-Sync.ps1)
  # and records the real exit code bound to runID (0 success / 75 skipped / else failed).
  # No fallback guess: without a result file the state stays waiting/unconfirmed, never success.
  # r7: CWD乗っ取り防止のため固定absoluteのみ。裸fallbackなし(欠品は起動失敗)。
  $watch = Join-Path $AutoDir 'Watch-Sync.ps1'
  if (Test-Path -LiteralPath $watch) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { throw 'powershell absolute missing.' }
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$watch`"", '-AutoDir', "`"$AutoDir`"", '-RunId', "`"$($req.id)`"", '-RequestPath', "`"$reqFile`"" -WindowStyle Hidden | Out-Null
  } else {
    if ($ProjectNames.Count -gt 0 -or $PreviewOnly) { throw '選択・プレビュー同期には Watch-Sync.ps1 が必要です。' }
    $w = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $w)) { throw 'wscript absolute missing.' }
    Start-Process -FilePath $w -ArgumentList '//B', '//Nologo', "`"$vbs`"" -WindowStyle Hidden | Out-Null
  }
  return $req
}
function Clear-OldGlobalRequestFiles([string]$AutoDir) {
  try {
    $olds = @()
    $olds += @(Get-ChildItem -LiteralPath $AutoDir -Filter 'dashboard.global-request-*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 120 })
    $olds += @(Get-ChildItem -LiteralPath $AutoDir -Filter 'dashboard.global-plan-*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 120 })
    foreach ($f in @($olds)) {
      try {
        $full = $f.FullName
        if (Test-Contained $full $AutoDir) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
      } catch {}
    }
  } catch {}
}
# Global hidden sync: same lock file the scheduled task uses, request file the
# fixed sync script reads, Watch-GlobalSync monitor for runID-bound results.
# The HttpListener loop never waits: Start-Process returns immediately.
function Start-HiddenGlobalSync([string]$AutoDir, [string[]]$TargetNames = @(), [bool]$PreviewOnly = $false, [string]$PlanId = '') {
  $sel = @()
  if ($TargetNames) { $sel = @($TargetNames | ForEach-Object { [string]$_ }) }
  if (($sel.Count -gt 0) -and (-not (Test-GlobalTargetsValid $sel))) { throw '対象は Codex/OpenCode から1つ以上選んでください。' }
  if (($PlanId -ne '') -and ($PlanId -cnotmatch '^[0-9a-f]{32}$')) { throw 'plan id が不正です。' }
  $req = Write-GlobalSyncRequest $AutoDir
  $reqFile = Join-Path $AutoDir ("dashboard.global-request-" + $req.id + ".json")
  if (-not (Test-Contained $reqFile $AutoDir)) { throw 'request escaped autodir.' }
  $reqObj = @{ targetNames = @($sel); previewOnly = [bool]$PreviewOnly; planPath = ''; planId = [string]$PlanId }
  Write-BrowseResultPrivate $reqFile (ConvertTo-Json -InputObject $reqObj -Depth 5 -Compress)
  $watch = Join-Path $AutoDir 'Watch-GlobalSync.ps1'
  if (Test-Path -LiteralPath $watch) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { throw 'powershell absolute missing.' }
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$watch`"", '-AutoDir', "`"$AutoDir`"", '-RunId', "`"$($req.id)`"", '-RequestPath', "`"$reqFile`"" -WindowStyle Hidden | Out-Null
  } else {
    if ($sel.Count -gt 0 -or $PreviewOnly -or ($PlanId -ne '')) { throw '選択・プレビュー同期には Watch-GlobalSync.ps1 が必要です。' }
    $vbs = Join-Path $AutoDir 'Run-GlobalRules.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { throw 'hidden task launcher missing.' }
    $w = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $w)) { throw 'wscript absolute missing.' }
    Start-Process -FilePath $w -ArgumentList '//B', '//Nologo', "`"$vbs`"" -WindowStyle Hidden | Out-Null
  }
  return $req
}
# Global status response: per-provider rows (last success/source/error) plus the
# runID-bound sync state. Project status is never mixed in here.
function Get-GlobalStatusResponse([string]$AutoDir, [string]$Token, [string]$RunId = '') {
  $homeBase = ''
  try { $homeBase = Resolve-GlobalHomeBase } catch { $homeBase = '' }
  $tg = @('codexcli', 'opencode')
  try { $tg = @((Get-GlobalSettings $AutoDir).targets) } catch {}
  $st = Get-GlobalStatus $AutoDir
  $map = @{}
  if ($homeBase -ne '') { try { $map = Get-GlobalContentPaths $homeBase } catch {} }
  $rows = @()
  foreach ($t in @('codexcli', 'opencode')) {
    $pr = $st.providers[$t]
    $p = ''
    try { if ($map.ContainsKey($t)) { $p = [string]$map[$t] } } catch {}
    $ex = $false
    if (($p -ne '') -and (Test-Path -LiteralPath $p -PathType Leaf) -and (-not (Test-Reparse $p))) { $ex = $true }
    $rows += @{
      target = $t; path = $p; exists = $ex; selected = ($tg -contains $t)
      lastAttemptAt = [string]$pr.lastAttemptAt; lastSuccessAt = [string]$pr.lastSuccessAt
      result = [string]$pr.result; sourceCommit = [string]$pr.sourceCommit
      error = (Redact-Text ([string]$pr.error) $Token); backupId = [string]$pr.backupId
    }
  }
  $sync = Get-GlobalSyncState $AutoDir $Token $RunId
  $iv = $null
  try { $iv = Get-GlobalInterval } catch {}
  $en = $null
  try { $en = Get-GlobalTaskEnabled } catch {}
  return @{
    homeBase = $homeBase; targets = $tg; providers = $rows
    running = $sync.running; syncState = $sync.syncState; syncAt = $sync.syncAt; syncId = $sync.syncId
    logName = $sync.logName; logMtime = $sync.logMtime; finalLine = $sync.finalLine; tail = $sync.tail
    resultExit = $sync.resultExit; resultAt = $sync.resultAt
    intervalMinutes = $iv; taskEnabled = $en
    instance = $script:InstanceId; port = (Get-DashboardPort)
  }
}
function Clear-OldRequestFiles([string]$AutoDir) {  try {
    $olds = @()
    $olds += @(Get-ChildItem -LiteralPath $AutoDir -Filter 'dashboard.request-*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 120 })
    $olds += @(Get-ChildItem -LiteralPath $AutoDir -Filter 'dashboard.plan-*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 120 })
    foreach ($f in @($olds)) {
      try {
        $full = $f.FullName
        if (Test-Contained $full $AutoDir) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue }
      } catch {}
    }
  } catch {}
}
function Write-DashboardState([string]$AutoDir, [int]$Port, [string]$Instance) {
  $st = 'unknown'
  try { $st = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
  $o = @{ instance = $Instance; pid = $PID; startTime = $st; port = $Port; autodir = $AutoDir }
  $j = ConvertTo-Json -InputObject $o -Depth 3 -Compress
  $sf = Join-Path $AutoDir 'dashboard.state.json'
  Write-PrivateText $sf $j
}
function Get-DashboardState([string]$AutoDir) {
  $f = Join-Path $AutoDir 'dashboard.state.json'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try { return (Get-Content -LiteralPath $f -Raw -Encoding Ascii | ConvertFrom-Json) } catch { return $null }
}

$script:Previews = @{}
$script:BrowseProcs = @{}
$script:InstanceId = ([System.Guid]::NewGuid().ToString('N') + '-' + $PID)

function Get-PageHtml {
  return @'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shirube 管理ダッシュボード</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:#000;color:#f5f5f5;font-family:"Segoe UI","Hiragino Kaku Gothic ProN",Meiryo,sans-serif;font-size:14px;line-height:1.7;overflow:hidden}
a{color:#f5f5f5}
.wrap{display:flex;height:100vh;height:100dvh;padding:12px;gap:12px}
aside{width:232px;flex:none;background:#0a0a0a;border:1px solid #1f1f1f;border-radius:14px;padding:20px 14px;height:calc(100vh - 24px);height:calc(100dvh - 24px);overflow:auto}
.brand{font-weight:700;font-size:15px;padding:4px 10px 16px}
nav a{display:block;padding:8px 10px;border-radius:6px;text-decoration:none;color:#cfcfcf}
nav a.active{background:#161616;color:#fff;border:1px solid #2a2a2a}
nav a:hover{background:#141414}
.side-note{margin-top:24px;padding:10px;font-size:12px;color:#9a9a9a;border-top:1px solid #1d1d1d}
main{flex:1;min-width:0;display:flex;flex-direction:column;background:#0a0a0a;border:1px solid #1f1f1f;border-radius:14px;height:calc(100vh - 24px);height:calc(100dvh - 24px);overflow:hidden;padding:0}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:12px;flex:none;border-bottom:1px solid #1d1d1d;padding:16px 28px 14px}
.mainscroll{flex:1;min-height:0;overflow:auto;padding:22px 28px 40px;scrollbar-gutter:stable}
.mainscroll{min-height:96px}
.summarybar{flex:0 0 auto;min-height:0;padding:10px 28px 8px;border-bottom:1px solid #1d1d1d;background:#0a0a0a}
.summarybar .grid3{margin-bottom:0;gap:10px;grid-template-columns:minmax(0,1fr) minmax(0,1fr) minmax(0,1fr)}
.summarybar .card{padding:10px 14px;min-width:0;overflow-wrap:anywhere;word-break:break-all}
.summarybar .big{font-size:20px}
.summarybar .muted{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden;overflow-wrap:anywhere;word-break:break-all}
.summarybar .btnrow button{white-space:nowrap}
.syncprogress{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-top:4px;min-width:0}
.syncprogress progress{flex:1 1 100%;min-width:0;height:8px;accent-color:#8fd694}
.syncprogress .muted{margin:0;white-space:normal;overflow-wrap:anywhere;word-break:break-word}
.helper{display:inherit}
.topbar .sub{color:#9a9a9a;font-size:12px}
.lang{font-size:12px;color:#cfcfcf;border:1px solid #2a2a2a;border-radius:6px;padding:5px 10px;flex:none}
h1{font-size:22px;margin:0 0 6px}
.lead{color:#b5b5b5;margin:0 0 14px}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-bottom:14px}
.card{background:#0d0d0d;border:1px solid #242424;border-radius:8px;padding:16px 18px}
.card h2{font-size:13px;color:#9a9a9a;margin:0 0 8px;font-weight:600}
.big{font-size:24px;margin:0}
.muted{color:#9a9a9a;font-size:12px}
.row2{display:grid;grid-template-columns:1.4fr 1fr;gap:14px}
.cols2{display:grid;grid-template-columns:1.55fr 1fr;gap:14px;margin:0 0 14px}
.cols2>section{margin:0;min-width:0}
@media(max-width:1000px){.row2,.cols2{grid-template-columns:1fr}aside{display:none}.mainscroll{padding:20px 16px 32px}.summarybar{padding:8px 16px 6px}}
@media(max-width:480px){.summarybar{padding:8px 12px 6px}.summarybar .grid3{gap:6px}.summarybar .card{padding:8px 10px}.summarybar .btnrow button{padding:2px 5px;font-size:10px}}
@media(max-height:520px){.topbar{padding:3px 10px 2px}.topnav{padding:2px 8px!important}.topnav a{padding:2px 5px!important;font-size:11px!important}.summarybar{padding:2px 10px 1px}.summarybar .card{padding:2px 6px}.summarybar .card h2{margin:0 0 2px;font-size:11px}.summarybar .grid3{gap:3px}.summarybar .big{font-size:13px}.summarybar .muted{font-size:10px;-webkit-line-clamp:1}.summarybar .btnrow{margin-top:2px}.summarybar .btnrow button{padding:2px 5px;font-size:10px}.helper{display:none!important}.mainscroll{padding:6px 10px 10px}}
[hidden]{display:none!important}
section{width:100%;min-width:0;margin:0 0 14px}
.topnav{display:none;flex:none;gap:8px;flex-wrap:wrap;align-items:center;border-bottom:1px solid #1d1d1d;padding:10px 16px}
.topnav a{padding:7px 10px;border-radius:6px;text-decoration:none;color:#cfcfcf;border:1px solid transparent;font-size:13px}
.topnav a.active{background:#161616;color:#fff;border-color:#2a2a2a}
.btnlink{display:inline-block;padding:9px 16px;border:1px solid #333;border-radius:6px;background:#161616;color:#fff;text-decoration:none;font-size:13px}
.btnlink:hover{background:#222}
@media(max-width:1000px){.topnav{display:flex;flex-wrap:nowrap;overflow-x:auto}.topnav a{padding:11px 12px;white-space:nowrap}}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid #1f1f1f;vertical-align:top}
th{color:#9a9a9a;font-weight:600}
code.path{word-break:break-all;overflow-wrap:anywhere;font-size:12px;color:#e8e8e8}
input[type=text]{width:100%;background:#0a0a0a;border:1px solid #2c2c2c;color:#fff;border-radius:6px;padding:10px 12px;font-size:13px}
input[type=text]:focus{outline:2px solid #f5f5f5;outline-offset:1px}
button{cursor:pointer;border-radius:6px;font-size:13px;padding:9px 16px;border:1px solid #333;background:#161616;color:#fff}
button:hover{background:#222}
button.primary{background:#f5f5f5;color:#000;border-color:#f5f5f5;font-weight:700}
button.primary:hover{background:#fff}
button:disabled{opacity:.45;cursor:not-allowed}
button.danger{border-color:#5a2b2b;color:#f0b9b9}
.btnrow{display:flex;gap:10px;flex-wrap:wrap;margin-top:12px}
pre{background:#070707;border:1px solid #222;border-radius:6px;padding:12px;white-space:pre-wrap;word-break:break-all;font-size:12px;max-height:260px;overflow:auto;color:#d6d6d6}
.ok{color:#8fd694}.err{color:#f0a3a3}.warn{color:#e8c87a}
label.chk{display:flex;gap:8px;align-items:flex-start;margin-top:10px;font-size:13px;color:#d6d6d6}
footer{margin-top:34px;border-top:1px solid #1d1d1d;padding-top:12px;color:#8a8a8a;font-size:12px}
:focus-visible{outline:2px solid #f5f5f5;outline-offset:2px}
.pathrow{display:flex;gap:8px}
.pathrow input{flex:1;min-width:0}
.tablewrap{overflow-x:auto}
.tablewrap table{width:100%}
#prevArea{min-width:0;overflow-wrap:anywhere;word-break:break-all}
#prevArea p{overflow-wrap:anywhere;word-break:break-all}
details.help{margin:0}
details.help summary{cursor:pointer;padding:4px 0;font-weight:600;color:#cfcfcf;font-size:13px}
.ovl{position:fixed;inset:0;background:rgba(0,0,0,.72);display:flex;align-items:center;justify-content:center;z-index:50}
.ovl[hidden]{display:none}
.mbox{background:#0d0d0d;border:1px solid #2a2a2a;border-radius:8px;padding:20px 22px;max-width:460px;width:calc(100% - 40px)}
.mbox h3{margin:0 0 8px;font-size:15px}
.mbox p{margin:0 0 14px;color:#d6d6d6;font-size:13px;white-space:pre-wrap;word-break:break-all}
.acts{display:flex;gap:16px;flex-wrap:wrap;align-items:center}
.acts button{white-space:nowrap;flex:none}
#tbl .acts{gap:6px;align-items:center}
#tbl button{padding:4px 8px;min-height:30px;font-size:12px;white-space:nowrap}
@media(pointer:coarse){#tbl button{min-height:44px;padding:10px 12px}}
textarea{width:100%;background:#0a0a0a;border:1px solid #2c2c2c;color:#fff;border-radius:6px;padding:10px 12px;font-size:12px;font-family:Consolas,"MS Gothic",monospace;min-height:90px}
select{width:100%;background:#0a0a0a;border:1px solid #2c2c2c;color:#fff;border-radius:6px;padding:9px 12px;font-size:13px}
input[type=number]{width:120px;background:#0a0a0a;border:1px solid #2c2c2c;color:#fff;border-radius:6px;padding:9px 12px;font-size:13px}
.diff-add{color:#8fd694}.diff-del{color:#f0a3a3}.diff-note{color:#9a9a9a}
#ovl input[type=text]{margin-bottom:12px}
.searchrow{display:flex;gap:8px;margin:0 0 10px}
</style>
</head>
<body>
<div class="wrap">
<aside>
<div class="brand">Shirube Console</div>
<nav>
<a href="#top" class="active" aria-current="page">概要</a>
<a href="#projects">プロジェクト</a>
<a href="#global">Global同期</a>
<a href="#backups">バックアップ</a>
<a href="#local">ローカル編集</a>
<a href="#logs">同期ログ</a>
<a href="#settings">設定・ヘルプ</a>
</nav>
<div class="side-note">このPC専用。外部送信なし。<br>AGENTS.md は直接編集しません。</div>
</aside>
<main>
<div class="topbar"><div><strong>Shirube 管理</strong> <span class="sub">プロジェクト同期ダッシュボード</span></div><span class="lang">日本語</span></div>
<nav class="topnav" aria-label="画面切替">
<a href="#top" class="active" aria-current="page">概要</a>
<a href="#projects">プロジェクト</a>
<a href="#global">Global同期</a>
<a href="#backups">バックアップ</a>
<a href="#local">ローカル編集</a>
<a href="#logs">同期ログ</a>
<a href="#settings">設定・ヘルプ</a>
</nav>
<div class="summarybar">
<section aria-label="summary">
<div class="grid3">
<div class="card"><h2>登録プロジェクト数</h2><p class="big" id="stCount">読込中</p><p class="muted helper">projects.json が正本です</p></div>
<div class="card"><h2>同期状態</h2><p class="big" id="stRun">読込中</p><p class="muted helper" id="stLog">-</p><div class="syncprogress"><progress id="syncProgress" max="2" value="0" aria-label="同期進捗" aria-valuetext="0/2 待機中"></progress><span class="muted" id="syncProgressText" aria-live="polite">0/2 待機中</span></div></div>
<div class="card"><h2>最終結果</h2><p class="muted" id="stTail">読込中</p><div class="btnrow"><button id="btnSync" class="primary">今すぐ同期</button></div></div>
</div>
<p class="muted helper" id="ovGlobal">Global同期: 読込中</p>
</section>
</div>
<div class="mainscroll">
<div id="top">
<h1>プロジェクト同期ダッシュボード</h1>
<p class="lead">登録一覧の管理と今すぐ同期を行います。配布ファイルの直接編集はしません。開始した処理はUIを閉じても継続しますが、両方の完了確認には画面を開いたままにしてください。</p>
</div>
<div id="projects" hidden>
<div class="cols2">
<section>
<div class="card"><h2>プロジェクト一覧</h2>
<p class="muted" id="emptyProj" hidden>まだ登録がありません。右の新規登録から追加してください。</p>
<div class="searchrow"><input type="text" id="inpSearch" placeholder="検索で絞り込み（名前・パス）" autocomplete="off"></div>
<div class="tablewrap"><table id="tbl" hidden><thead><tr><th>選択</th><th>名前</th><th>パス</th><th>有効</th><th>操作</th></tr></thead><tbody id="rows"></tbody></table></div>
<p class="muted">解除は一覧からのみ削除し、リポジトリ内のファイルは削除しません。「開く」で登録フォルダを開けます。</p>
<div class="btnrow"><a href="#register" class="btnlink">新規登録へ</a></div>
<div id="msgList" role="status"></div>
</div>
</section>
<section id="register">
<div class="card"><h2>新規登録</h2>
<p class="muted">フォルダのパスを入力するか「参照」で選択し、プレビューで内容を確認してから登録します。選択だけでは登録されません。既存 AGENTS.md がある場合は原則登録停止します（手動整理が必要）。登録後の同期で AGENTS.md は生成・再生成されます。</p>
<div class="pathrow"><input type="text" id="inpPath" placeholder="例 C:\Project\MyRepo" autocomplete="off"><button id="btnBrowse">参照...</button></div>
<label class="chk"><input type="checkbox" id="ckForceReplace"> 既存 AGENTS.md の置き換えを許可（バックアップ後、同期で再生成）</label>
<div class="btnrow"><button id="btnPrev" class="primary">プレビュー</button></div>
<div id="browseArea" class="muted"></div>
<div id="prevArea"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted">複数まとめて登録（1行1パス、最大20件。新規のみ。AGENTS.md ありは個別取込）。</p>
<textarea id="inpBatch" placeholder="例 C:\Project\A"></textarea>
<div class="btnrow"><button id="btnBatchPrev">まとめてプレビュー</button></div>
<div id="batchArea"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted">既存 AGENTS.md の取込（無損失：原本を退避し固有分を project-local.md へ転記）。</p>
<div class="btnrow"><button id="btnImportPrev">取込プレビュー</button></div>
<div id="importArea"></div>
</div>
</section>
</div>
<section id="status">
<div class="card"><h2>状態と再試行</h2>
<p class="muted">最終試行・最終成功・取得SHA・失敗理由の一覧です。選択した同期・差分はチェック欄で選びます。</p>
<div class="btnrow"><button id="btnStatusReload">状態を更新</button><button id="btnSyncSel" class="primary">選択を同期</button><button id="btnPlanSel">選択の反映前差分</button></div>
<div class="tablewrap"><table id="tblStatus" hidden><thead><tr><th>選択</th><th>名前</th><th>有効</th><th>最終試行</th><th>最終成功</th><th>取得SHA</th><th>結果</th><th>失敗理由</th></tr></thead><tbody id="statusRows"></tbody></table></div>
<p class="muted" id="emptyStatus">まだ同期状態がありません。今すぐ同期で初回実行できます。</p>
<div id="msgStatus" role="status"></div>
<div id="planArea"></div>
</div>
</section>
</div>
<div id="global" hidden>
<div class="cols2">
<section>
<div class="card"><h2>Global同期（Codex/OpenCode 共通）</h2>
<p class="muted">PC全体の共通ルールを配ります。Projectとは別の状態（最終成功・取得元・失敗理由）を持ちます。配布ファイルの直接編集はしません。</p>
<p class="muted" id="emptyGlobal">まだGlobal同期の状態がありません。今すぐ同期で初回実行できます。</p>
<div class="tablewrap"><table id="tblGlobal" hidden><thead><tr><th>対象</th><th>配置先</th><th>最終試行</th><th>最終成功</th><th>取得元</th><th>結果</th><th>失敗理由</th></tr></thead><tbody id="globalRows"></tbody></table></div>
<p class="muted" id="globalSummary">読込中</p>
<div class="btnrow"><button id="btnGlobalSync" class="primary" disabled>プレビューを適用</button><button id="btnGlobalPreview">反映前プレビュー</button><button id="btnGlobalReload">状態を更新</button></div>
<div id="msgGlobal" role="status"></div>
<div id="globalPlanArea"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted">現在の内容と配置先（実ファイルの先頭のみ表示）。設定ファイルの中身は表示しません。</p>
<div class="btnrow"><button id="btnGlobalContent">内容を表示</button></div>
<pre id="globalContentPre">まだ表示していません。「内容を表示」で確認できます。</pre>
</div>
</section>
<section id="gsettings">
<div class="card"><h2>Global設定</h2>
<p class="muted">配る対象の選択・自動同期の間隔と有効/無効を変えます。更新前バックアップと復元は「バックアップ」画面で行います。</p>
<label class="chk"><input type="checkbox" id="ckTCodex" checked> Codex（.codex/AGENTS.md）</label>
<label class="chk"><input type="checkbox" id="ckTOpenCode" checked> OpenCode（.config/opencode/AGENTS.md）</label>
<div class="btnrow"><button id="btnGlobalTargets" class="primary">対象を保存</button></div>
<div id="msgGlobalTargets" role="status"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted">自動同期（Rulesync Global Auto Sync）。ログオン時＋一定間隔で裏で実行します。</p>
<p class="muted" id="globalEnabledState">読込中</p>
<div class="btnrow"><button id="btnGlobalEnabled">有効/無効を切替</button></div>
<div class="btnrow"><label class="muted">間隔（分） <input type="number" id="numGlobalInterval" min="5" max="1440" step="1" value="15"></label><button id="btnGlobalIntervalGet">現在値</button><button id="btnGlobalIntervalSet">間隔を変更</button></div>
<div id="msgGlobalInterval" role="status"></div>
</div>
</section>
</div>
</div>
<div id="backups" hidden>
<section>
<div class="card"><h2>バックアップと復元</h2>
<p class="muted">復元は AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。共通 GitHub 側の巻戻しはしません。</p>
<div class="btnrow"><button id="btnBackupsReload">一覧を更新</button></div>
<div class="tablewrap"><table id="tblBackups" hidden><thead><tr><th>ID</th><th>対象</th><th>作成</th><th>内容</th><th>操作</th></tr></thead><tbody id="backupRows"></tbody></table></div>
<p class="muted" id="emptyBackups">バックアップがありません。</p>
<div id="backupDiffArea"></div>
<div id="msgBackup" role="status"></div>
</div>
</section>
<section>
<div class="card"><h2>Globalバックアップと復元</h2>
<p class="muted">復元前に Global 自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。差分で内容を確認してから復元します。</p>
<div class="btnrow"><button id="btnGlobalBackups">一覧を更新</button></div>
<div class="tablewrap"><table id="tblGlobalBackups" hidden><thead><tr><th>ID</th><th>作成</th><th>対象</th><th>操作</th></tr></thead><tbody id="globalBackupRows"></tbody></table></div>
<p class="muted" id="emptyGlobalBackups">バックアップがありません。</p>
<div id="globalBackupDiffArea"></div>
<div id="msgGlobalBackup" role="status"></div>
</div>
</section>
</div>
<div id="local" hidden>
<section>
<div class="card"><h2>ローカルルール編集と検査</h2>
<p class="muted">project-local.md を形式検証付きで編集します。保存時は取得時ハッシュと一致した場合のみ書換えます。検査結果は候補であり断定ではありません。</p>
<div class="btnrow"><select id="selLocal" style="max-width:280px"></select><button id="btnLocalLoad">取得</button><button id="btnCheck">重複・矛盾候補を検査</button></div>
<div id="localArea"></div>
<div id="checkArea"></div>
<div id="msgLocal" role="status"></div>
</div>
</section>
</div>
<div id="logs" hidden>
<section>
<div class="card"><h2>Project同期ログ</h2>
<div class="btnrow"><button id="btnReload">更新</button></div>
<pre id="logPre">読込中</pre>
</div>
</section>
<section>
<div class="card"><h2>Global同期ログ</h2>
<p class="muted">直近のみ表示。末尾の OK は成功、FAIL は失敗、SKIP は見送りです。</p>
<div class="btnrow"><button id="btnGlobalLogs">ログを更新</button></div>
<pre id="globalLogPre">読込中</pre>
</div>
</section>
</div>
<div id="settings" hidden>
<section>
<div class="card"><h2>設定（間隔・入出力）</h2>
<p class="muted">同期間隔は Project タスクのみ変更します（Global は不変）。エクスポート・インポートに秘密情報は含みません。</p>
<div class="btnrow"><label class="muted">Project 同期の間隔（分） <input type="number" id="numInterval" min="5" max="1440" step="1" value="15"></label><button id="btnIntervalGet">現在値</button><button id="btnIntervalSet">間隔を変更</button></div>
<div id="msgInterval" role="status"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<div class="btnrow"><button id="btnExport">設定をエクスポート（JSON保存）</button></div>
<p class="muted">取り込みはプレビューで合流内容を確認してから登録します（新規のみ追加・既存維持）。</p>
<textarea id="txtImport" placeholder="导出したJSONを貼り付け"></textarea>
<div class="btnrow"><button id="btnImportPrev2">取込プレビュー</button></div>
<div id="importRegArea"></div>
<div id="msgSettings" role="status"></div>
</div>
</section>
<section id="help">
<div class="card"><details class="help" id="helpDetail"><summary>ヘルプ</summary>
<p class="muted">管理バッチをダブルクリックするとこの画面が開きます。サーバーは 127.0.0.1 のみで待受けし、15分無操作で終了します。同期タスク自体はタスクスケジューラの設定どおり継続します。登録・解除は projects.json のみを変更します。</p>
</details>
</div>
</section>
</div>
<footer>Shirube 管理ダッシュボード (ローカルのみ、外部送信なし)</footer>
</div>
</main>
</div>
<div class="ovl" id="ovl" hidden><div class="mbox" role="dialog" aria-modal="true" aria-labelledby="mTitle" aria-describedby="mMsg"><h3 id="mTitle"></h3><p id="mMsg"></p><div class="btnrow" id="mBtns"></div></div></div>
<script>
"use strict";
const TOKEN = "__TOKEN__";
const H = {"Content-Type":"application/json","X-Dashboard-Token":TOKEN};
const SCREENS=["top","projects","global","backups","local","logs","settings"];
const LEGACY=Object.assign(Object.create(null),{"register":"projects","status":"projects","gsettings":"global","help":"settings"});
function rawHash(){var h="";try{h=(location.hash||"").split("?")[0];}catch(e){}if(h.charAt(0)==="#")h=h.slice(1);return h;}
function targetId(){var h=rawHash();if(SCREENS.indexOf(h)>=0)return h;if(LEGACY[h])return LEGACY[h];return "top";}
function syncHelp(id){try{var d=null;try{d=document.getElementById("helpDetail");}catch(e){}if(d&&id==="help"&&!d.open){d.open=true;}}catch(e2){}}
function setActive(id){try{var links=document.querySelectorAll("aside nav a,.topnav a");for(var j=0;j<links.length;j++){var a=links[j];var hn="";try{hn=a.getAttribute("href")||"";}catch(e){}if(hn==="#"+id){try{a.classList.add("active");}catch(e){}try{a.setAttribute("aria-current","page");}catch(e2){}}else{try{a.classList.remove("active");}catch(e){}try{a.removeAttribute("aria-current");}catch(e3){}}}}catch(e){}}
function applyScreen(id){try{var s=(SCREENS.indexOf(id)>=0)?id:(LEGACY[id]||"top");for(var i=0;i<SCREENS.length;i++){var el=null;try{el=document.getElementById(SCREENS[i]);}catch(e){}if(el)el.hidden=(SCREENS[i]!==s);}try{var ms=document.querySelector(".mainscroll");if(ms)ms.scrollTop=0;}catch(e2){}setActive(s);}catch(e3){}}
function showHash(){try{var h=rawHash();applyScreen(h);syncHelp(h);}catch(e){}}
window.addEventListener("hashchange",function(){showHash();});
function isShown(el){try{if(!el||!el.isConnected||el.disabled)return false;var cs=null;try{cs=getComputedStyle(el);}catch(e){}if(cs&&cs.display==="none")return false;try{if(el.offsetParent===null){var pos="";try{pos=cs?cs.position:"";}catch(e2){}if(pos!=="fixed")return false;}}catch(e){}try{var r=el.getBoundingClientRect();if(r&&(r.width===0&&r.height===0))return false;}catch(e){}return true;}catch(e){return false;}}
function focusVisible(el){try{return isShown(el)&&safeFocus(el);}catch(e){return false;}}
function focusVisibleNav(){try{var c=document.querySelectorAll("aside nav a.active,.topnav a.active");for(var i=0;i<c.length;i++){if(focusVisible(c[i]))return true;}}catch(e){}return false;}
async function api(path, method, body, timeoutMs){
  const ctrl = new AbortController();
  const ms = timeoutMs || 8000;
  const timer = setTimeout(function(){ ctrl.abort(); }, ms);
  try{
    const o = {method:method||"GET", headers:H, signal:ctrl.signal};
    if(body) o.body = JSON.stringify(body);
    const r = await fetch(path, o);
    const t = await r.text();
    let j = null; try{ j = JSON.parse(t); }catch(e){}
    if(!r.ok) throw new Error((j && j.error) || ("HTTP "+r.status));
    return j;
  }catch(e){
    if(e && e.name === "AbortError") throw new Error("要求がタイムアウトしました。少し待って更新ボタンで確認してください。");
    throw e;
  }finally{ clearTimeout(timer); }
}
function esc(s){ return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }
function stateJa(s){
  if(s==="running") return "実行中";
  if(s==="waiting") return "起動待ち";
  if(s==="success") return "成功";
  if(s==="failed") return "失敗";
  if(s==="skipped") return "見送り";
  if(s==="unconfirmed") return "未確認";
  return "待機中";
}
function updateSyncUI(s){
  document.getElementById("stCount").textContent = (s.count == null ? 0 : s.count) + " 件";
  document.getElementById("logPre").textContent = s.tail || "ログがありません。";
  updateCommonSyncState("project", s);
}
function updateCommonSyncState(kind, state){
  const previous = commonSyncStates[kind];
  const id = state.syncId ? String(state.syncId) : "";
  commonSyncStates[kind] = state;
  if(kind === "project" && id) unifiedObservedProjectRunId = id;
  if(kind === "global" && id) unifiedObservedGlobalRunId = id;
  if(unifiedStateLock) return;
  if(unifiedFinalState){
    const expected = kind === "project"
      ? (unifiedProjectRunId || unifiedBaselineProjectRunId)
      : (unifiedGlobalRunId || unifiedBaselineGlobalRunId);
    if(!id || id === String(expected || "")) return;
    unifiedFinalState = null;
    commonSyncSource = kind;
  } else if(id && previous && id !== String(previous.syncId || "")){
    commonSyncSource = kind;
  } else if(!previous){
    const project = commonSyncStates.project;
    const global = commonSyncStates.global;
    const active = s => s && (s.running || s.syncState === "running" || s.syncState === "waiting");
    const time = s => s ? (Date.parse(s.syncAt || s.resultAt || "") || 0) : 0;
    if(!project) commonSyncSource = "global";
    else if(!global) commonSyncSource = "project";
    else if(!!active(project) !== !!active(global)) commonSyncSource = active(project) ? "project" : "global";
    else commonSyncSource = time(global) > time(project) ? "global" : "project";
  }
  const current = commonSyncStates[commonSyncSource];
  if(!current) return;
  const status = current.syncState || (current.running ? "running" : "idle");
  const label = commonSyncSource === "global" ? "Global" : "Project";
  const run = document.getElementById("stRun");
  run.textContent = stateJa(status);
  run.dataset.state = status;
  const log = (current.logName || "ログなし") + (current.logMtime ? " (" + current.logMtime + ")" : "");
  document.getElementById("stLog").textContent = log;
  document.getElementById("stLog").title = log;
  const result = label + ": " + stateJa(status) + (current.finalLine || current.tail ? " " + (current.finalLine || current.tail).slice(-220) : "");
  document.getElementById("stTail").textContent = result;
  document.getElementById("stTail").title = result;
  const terminal = status === "success" || status === "failed" || status === "skipped";
  setUnifiedProgress(terminal ? 1 : 0, 1, label + ": " + stateJa(status), status === "running" || status === "waiting");
}
function resultJa(r){
  if(r === "success") return "成功";
  if(r === "failed") return "失敗";
  if(r === "skipped") return "見送り";
  return "未実行";
}
function applySearchFilter(){
  const q = (document.getElementById("inpSearch").value || "").toLowerCase();
  const ids = ["rows", "statusRows"];
  for(let k=0;k<ids.length;k++){
    const tb = document.getElementById(ids[k]);
    if(!tb) continue;
    for(let i=0;i<tb.children.length;i++){
      const tr = tb.children[i];
      const hay = tr.dataset.search || "";
      tr.style.display = (!q || hay.indexOf(q) >= 0) ? "" : "none";
    }
  }
}
function selectedNames(){
  const out = [];
  const seen = new Set();
  const boxes = document.querySelectorAll("#statusRows input.selbox");
  for(let i=0;i<boxes.length;i++){ if(boxes[i].checked && !seen.has(boxes[i].value)){ seen.add(boxes[i].value); out.push(boxes[i].value); } }
  const boxes2 = document.querySelectorAll("#rows input.selbox");
  for(let j=0;j<boxes2.length;j++){ if(boxes2[j].checked && !seen.has(boxes2[j].value)){ seen.add(boxes2[j].value); out.push(boxes2[j].value); } }
  return out;
}
function renderStatusTable(list){
  const tb = document.getElementById("statusRows");
  tb.innerHTML = "";
  document.getElementById("tblStatus").hidden = list.length === 0;
  document.getElementById("emptyStatus").hidden = list.length !== 0;
  list.forEach(function(e){
    const tr = document.createElement("tr");
    try{ tr.dataset.search = (e.name + " " + (e.displayName || "") + " " + (e.error || "")).toLowerCase(); }catch(e2){}
    const td0 = document.createElement("td");
    const cb = document.createElement("input"); cb.type = "checkbox"; cb.className = "selbox"; cb.value = e.name;
    td0.appendChild(cb);
    const td1 = document.createElement("td"); td1.textContent = e.displayName || e.name; td1.title = e.name;
    const tdE = document.createElement("td"); tdE.textContent = (e.enabled !== false) ? "有効" : "無効";
    const tdA = document.createElement("td"); tdA.textContent = e.lastAttemptAt || "-";
    const tdS = document.createElement("td"); tdS.textContent = e.lastSuccessAt || "-";
    const tdH = document.createElement("td"); const hc = document.createElement("code"); hc.className = "path";
    hc.textContent = ((e.commonCommit || e.commonSha || "").slice(0,12) || "-"); tdH.appendChild(hc);
    const tdR = document.createElement("td"); tdR.textContent = resultJa(e.result);
    const tdF = document.createElement("td"); tdF.textContent = (e.error || "").slice(0,120);
    tr.appendChild(td0); tr.appendChild(td1); tr.appendChild(tdE); tr.appendChild(tdA);
    tr.appendChild(tdS); tr.appendChild(tdH); tr.appendChild(tdR); tr.appendChild(tdF);
    tb.appendChild(tr);
  });
}
async function afterSyncNotify(r){
  if(r && r.sync === "started"){
    const dl = Date.now() + 60000;
    await refresh(dl);
    const st = await pollUntilDone(r.syncId, 30, 2000, dl);
    if(Date.now() < dl) await refresh(dl);
    if(st === "success") await showNotify("同期が成功しました", "同期が成功しました。ログを確認してください。");
    else if(st === "failed") await showNotify("同期が失敗しました", "同期が失敗しました。ログを確認してください。");
    else if(st === "skipped") await showNotify("同期は見送りです", "同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。");
    else await showNotify("同期は未確認です", "同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。");
  } else {
    await refresh();
    await showNotify("同期は未確認です", "同期状態は未確認です。ログを確認してください。");
  }
}
async function refresh(deadline){
  try{
    let t = 8000;
    if(typeof deadline === "number"){ t = Math.min(8000, deadline - Date.now()); if(t <= 0) return; }
    const s = await api("/api/status", "GET", null, t);
    updateSyncUI(s);
    let t2 = 8000;
    if(typeof deadline === "number"){ t2 = Math.min(8000, deadline - Date.now()); if(t2 <= 0) return; }
    const p = await api("/api/projects", "GET", null, t2);
    let enMap = {};
    let stList = [];
    try{
      let t3 = 8000;
      if(typeof deadline === "number"){ t3 = Math.min(8000, deadline - Date.now()); if(t3 <= 0) return; }
      const st = await api("/api/project-status", "GET", null, t3);
      stList = st.projects || [];
      stList.forEach(function(r){ enMap[r.name] = r.enabled; });
    }catch(e){}
    const tb = document.getElementById("rows");
    tb.innerHTML = "";
    document.getElementById("tbl").hidden = p.projects.length === 0;
    document.getElementById("emptyProj").hidden = p.projects.length !== 0;
    p.projects.forEach(function(e){
      const tr = document.createElement("tr");
      try{ tr.dataset.search = (e.name + " " + (e.displayName || "") + " " + e.path).toLowerCase(); }catch(e2){}
      const td0 = document.createElement("td");
      const cb = document.createElement("input"); cb.type = "checkbox"; cb.className = "selbox"; cb.value = e.name;
      td0.appendChild(cb);
      const td1 = document.createElement("td"); td1.textContent = e.displayName || e.name; td1.title = e.name;
      const td2 = document.createElement("td"); const c = document.createElement("code"); c.className = "path"; c.textContent = e.path; td2.appendChild(c);
      const tdE = document.createElement("td");
      const enB = document.createElement("button"); const en = (enMap[e.name] !== false);
      enB.textContent = en ? "有効" : "無効";
      enB.onclick = async function(){
        try{ await api("/api/enabled","POST",{name:e.name,enabled:!en}); setMsg("msgList",(en ? "無効にしました（次回同期は対象外）。" : "有効にしました。"),true); refresh(); }
        catch(err){ setMsg("msgList", err.message, false); }
      };
      tdE.appendChild(enB);
      const td3 = document.createElement("td");
      const acts = document.createElement("div"); acts.className = "acts";
      const bo = document.createElement("button"); bo.textContent = "開く"; bo.title = "エクスプローラーで開く"; bo.setAttribute("aria-label", "エクスプローラーで開く"); bo.className = "opbtn";
      bo.onclick = async function(){
        try{ await api("/api/open","POST",{name:e.name}); setMsg("msgList","エクスプローラーで開きました: "+e.name,true); }
        catch(err){ await showNotify("開けませんでした", err.message); }
      };
      const br2 = document.createElement("button"); br2.textContent = "名称変更";
      br2.onclick = async function(){
        const nn = await showModalInput("表示名の変更", "新しい表示名を入力してください。（1〜64文字・制御文字なし）", e.displayName || e.name);
        if(nn === null) return;
        try{ await api("/api/rename","POST",{oldName:e.name,newName:nn}); setMsg("msgList","名称を変更しました。",true); refresh(); }
        catch(err){ setMsg("msgList", err.message, false); }
      };
      const bm = document.createElement("button"); bm.textContent = "移動";
      bm.onclick = async function(){
        const np = await showModalInput("移動先の再指定", "新しいフォルダの絶対パスを入力してください。", e.path);
        if(np === null) return;
        try{ await api("/api/move","POST",{name:e.name,newPath:np}); setMsg("msgList","移動先を更新しました。",true); refresh(); }
        catch(err){ setMsg("msgList", err.message, false); }
      };
      const b = document.createElement("button"); b.textContent = "解除"; b.className = "danger";
      b.onclick = async function(){
        const ok = await showConfirm("解除の確認", "「"+e.name+"」を一覧から解除します。ファイルは削除しません。よろしいですか。", "解除する", "やめる");
        if(!ok) return;
        try{ await api("/api/unregister","POST",{name:e.name}); setMsg("msgList","解除しました。一覧のみ変更し、ファイルは削除していません。",true); refresh(); }catch(err){ setMsg("msgList", err.message, false); } };
      td3.appendChild(acts); acts.appendChild(bo); acts.appendChild(br2); acts.appendChild(bm); acts.appendChild(b);
      tr.appendChild(td0); tr.appendChild(td1); tr.appendChild(td2); tr.appendChild(tdE); tr.appendChild(td3); tb.appendChild(tr);
    });
    try{ renderStatusTable(stList); }catch(e){}
    try{ applySearchFilter(); }catch(e2){}
    try{ fillLocalSelect(p.projects); }catch(e){}
  }catch(e){ document.getElementById("logPre").textContent = "取得失敗: "+e.message; }
}
async function pollUntilDone(syncId, tries, delayMs, deadline){
  const dl = deadline || (Date.now() + 60000);
  for(let i=0;i<tries;i++){
    if(i > 0){
      let rem = dl - Date.now();
      if(rem <= 0) return "unconfirmed";
      const wait = Math.min(delayMs, rem);
      await new Promise(function(r){ setTimeout(r, wait); });
    }
    let rem2 = dl - Date.now();
    if(rem2 <= 0) return "unconfirmed";
    const to = Math.min(8000, rem2);
    let s = null;
    try{ s = await api("/api/status", "GET", null, to); }catch(e){ continue; }
    try{ updateSyncUI(s); }catch(e){}
    if(!s || !s.syncId || !syncId) continue;
    if(s.syncId !== syncId) continue;
    if(s.syncState === "success" || s.syncState === "failed" || s.syncState === "skipped") return s.syncState;
  }
  return "unconfirmed";
}
function setMsg(id, msg, ok){ const d = document.getElementById(id); d.textContent = ""; const p = document.createElement("p"); p.className = ok?"ok":"err"; p.textContent = msg; d.appendChild(p); }
function setMsgHtml(id, htmlOk, msg){ const d = document.getElementById(id); d.innerHTML = "<p class='"+(htmlOk?"ok":"err")+"'>"+esc(msg)+"</p>"; }
let lastFocus = null;
let modalRestoreTarget = null;
let modalQueue = Promise.resolve();
function safeFocus(el){
  try{
    if(!el || !el.focus) return false;
    if(!el.isConnected) return false;
    if(el.disabled) return false;
    try{
      var tn = ((el.tagName || "").toLowerCase());
      if(tn === "body" || tn === "html") return false;
      if(typeof document !== "undefined" && document){
        if(el === document.body || el === document.documentElement) return false;
      }
    }catch(e2){}
    el.focus();
    try{
      if(typeof document !== "undefined" && document && ("activeElement" in document)){
        return (document.activeElement === el);
      }
    }catch(e3){ return false; }
    return true;
  }catch(e){ return false; }
}
function showModal(title, msg, buttons, inputInitial){
  const callerFocus = document.activeElement;
  let resolveOuter;
  const outer = new Promise(function(r){ resolveOuter = r; });
  modalQueue = modalQueue.then(function(){ return showModalInner(title, msg, buttons, callerFocus, inputInitial).then(function(v){ resolveOuter(v); }); });
  modalQueue = modalQueue.catch(function(){});
  return outer;
}
function showModalInput(title, msg, initial){
  return showModal(title, msg, [{label:"決定", primary:true, useInput:true, value:null},{label:"やめる", primary:false, value:null}], (initial === undefined ? "" : initial));
}
function showModalInner(title, msg, buttons, callerFocus, inputInitial){
  return new Promise(function(resolve){
    const ovl = document.getElementById("ovl");
    const t = document.getElementById("mTitle");
    const m = document.getElementById("mMsg");
    const bs = document.getElementById("mBtns");
    t.textContent = title; m.textContent = msg; bs.innerHTML = "";
    let restoreTarget = callerFocus;
    try{
      if(restoreTarget && ovl && ovl.contains(restoreTarget)) restoreTarget = modalRestoreTarget;
    }catch(e){}
    if(!restoreTarget || !restoreTarget.isConnected || restoreTarget.disabled){
      try{
        if(modalRestoreTarget && modalRestoreTarget.isConnected && !modalRestoreTarget.disabled) restoreTarget = modalRestoreTarget;
      }catch(e){}
    }
    try{
      let inside = false;
      try{ inside = !!(ovl && callerFocus && ovl.contains(callerFocus)); }catch(e){}
      if(!inside && callerFocus && callerFocus.isConnected) modalRestoreTarget = callerFocus;
      if(!modalRestoreTarget && restoreTarget && restoreTarget.isConnected && !restoreTarget.disabled) modalRestoreTarget = restoreTarget;
    }catch(e){}
    lastFocus = restoreTarget;
    const wrap = document.querySelector(".wrap");
    if(wrap){ try{ wrap.inert = true; }catch(e){} wrap.setAttribute("aria-hidden","true"); }
    const btns = [];
    let inp = null;
    if(inputInitial !== undefined){
      inp = document.createElement("input");
      inp.type = "text";
      inp.value = inputInitial || "";
      try{ m.parentNode.insertBefore(inp, bs); }catch(e){ try{ bs.appendChild(inp); }catch(e2){} }
      btns.push(inp);
    }
    buttons.forEach(function(bd){
      const b = document.createElement("button");
      b.textContent = bd.label;
      if(bd.primary) b.className = "primary";
      if(bd.danger) b.className = "danger";
      b.onclick = function(){ if(bd.useInput && inp){ close(inp.value); } else { close(bd.value); } };
      bs.appendChild(b); btns.push(b);
    });
    function onKey(e){
      if(e.key === "Escape"){ e.preventDefault(); close(null); }
      else if(e.key === "Enter" && inp && document.activeElement === inp){ e.preventDefault(); close(inp.value); }
      else if(e.key === "Tab"){
        e.preventDefault();
        if(!btns.length) return;
        const i = btns.indexOf(document.activeElement);
        const n = (i + (e.shiftKey ? -1 : 1) + btns.length) % btns.length;
        if(btns[n]) try{ btns[n].focus(); }catch(err){}
      }
    }
    function close(v){
      document.removeEventListener("keydown", onKey, true);
      try{ if(inp && inp.parentNode) inp.parentNode.removeChild(inp); }catch(e0){}
      inp = null;
      ovl.hidden = true;
      if(wrap){ try{ wrap.inert = false; }catch(e){} wrap.removeAttribute("aria-hidden"); }
      try{
        const lf = restoreTarget || callerFocus || lastFocus;
        if(!focusVisible(lf)){
          let done=false;
          try{if(modalRestoreTarget&&modalRestoreTarget!==lf)done=focusVisible(modalRestoreTarget);}catch(e){}
          if(!done){done=focusVisibleNav();}
          if(!done){try{const fb=document.getElementById("btnPrev");if(!focusVisible(fb)){try{if(fb&&isShown(fb))fb.focus();}catch(e2){}}}catch(e){}}
        }
      }catch(e){}
      resolve(v);
    }
    document.addEventListener("keydown", onKey, true);
    ovl.hidden = false;
    if(btns[0]) try{ btns[0].focus(); }catch(e){}
  });
}
function showNotify(title, msg){ return showModal(title, msg, [{label:"閉じる", primary:true, value:true}]); }
function showConfirm(title, msg, okLabel, cancelLabel){ return showModal(title, msg, [{label:okLabel, primary:true, value:true},{label:cancelLabel, primary:false, value:false}]); }
let lastPreview = null;
let lastPreviewGen = 0;
let previewGen = 0;
async function doPreview(pathVal){
  const myGen = ++previewGen;
  const pa = document.getElementById("prevArea"); pa.innerHTML = "<p class='muted'>確認中</p>";
  try{
    const forceReplace = !!(document.getElementById("ckForceReplace") && document.getElementById("ckForceReplace").checked);
    const v = await api("/api/preview","POST",{path:pathVal, forceReplace:forceReplace});
    if(myGen !== previewGen){ return; }
    lastPreview = v;
    lastPreviewGen = myGen;
    let h = "<p class='ok'>プレビュー OK: 「"+esc(v.name)+"」として登録できます。</p>";
    h += "<p class='muted'>パス: <code class='path'>"+esc(v.path)+"</code></p>";
    if(v.hasAgents){
      h += "<p class='warn'>既存 AGENTS.md をバックアップ後に同期で再生成します。AGENTS.md の固有内容は自動転記されません。必要な内容は project-local.md に手動転記してください。</p>";
    } else {
      h += "<p class='muted'>AGENTS.md なし: 登録後の同期で新規生成されます。既存 AGENTS.md がある場合は登録停止します。</p>";
    }
    if(v.hasLocal) h += "<p class='muted'>既存 project-local.md あり(sha256:"+esc((v.localHash||"").slice(0,12))+"): 変更しません。</p>";
    else h += "<p class='muted'>project-local.md なし: 共通ルールのみで生成されます。</p>";
    h += "<label class='chk'><input type='checkbox' id='ck1'> 登録後の同期で AGENTS.md が生成・再生成されることを理解した</label>";
    h += "<div class='btnrow'><button id='btnReg' class='primary'>登録して非表示で同期</button></div><div id='msgReg' role='status'></div>";
    pa.innerHTML = h;
    document.getElementById("btnReg").onclick = async function(){
      const btn = document.getElementById("btnReg"); btn.disabled = true;
      try{
        if(!lastPreview || lastPreview !== v || previewGen !== lastPreviewGen) throw new Error("プレビューが無効です。もう一度プレビューしてください。");
        if(!document.getElementById("ck1") || !document.getElementById("ck1").checked) throw new Error("確認チェックを入れてください。");
        const warnMsg = v.hasAgents ? " 既存 AGENTS.md はバックアップ後に同期で再生成されます（固有内容は自動転記されません）。" : "";
        const okGo = await showConfirm("登録の確認", "「"+v.name+"」を登録し、非表示で同期します。よろしいですか。" + warnMsg, "登録する", "やめる");
        if(!okGo){ return; }
        if(!lastPreview || lastPreview !== v || previewGen !== lastPreviewGen) throw new Error("プレビューが無効です。もう一度プレビューしてください。");
        if(!document.getElementById("ck1") || !document.getElementById("ck1").checked) throw new Error("確認チェックを入れてください。");
        const fr = !!(document.getElementById("ckForceReplace") && document.getElementById("ckForceReplace").checked);
        const r = await api("/api/register","POST",{path:v.path,previewId:v.previewId,confirm:true,forceReplace:fr});
        if(r.sync === "started"){
          setMsgHtml("msgReg",true,"登録しました。同期を開始しました(開始 "+(r.syncAt||"")+")。完了まで確認します(最大約60秒)。");
          document.getElementById("inpPath").value = ""; lastPreview = null; const _ck = document.getElementById("ckForceReplace"); if(_ck) _ck.checked = false;
          const dl = Date.now() + 60000;
          await refresh(dl);
          const st = await pollUntilDone(r.syncId, 30, 2000, dl);
          if(st === "success"){ setMsgHtml("msgReg",true,"登録しました。同期が成功しました。ログを確認してください。"); await showNotify("同期が成功しました", "登録しました。同期が成功しました。ログを確認してください。"); }
          else if(st === "failed"){ setMsgHtml("msgReg",false,"登録しましたが同期が失敗しました。ログを確認してください。"); await showNotify("同期が失敗しました", "登録しましたが同期が失敗しました。ログを確認してください。"); }
          else if(st === "skipped"){ setMsgHtml("msgReg",false,"登録しましたが同期は見送られました(別の同期が実行中)。しばらくして今すぐ同期でやり直してください。"); await showNotify("同期は見送りです", "登録しましたが同期は見送られました(別の同期が実行中)。しばらくして今すぐ同期でやり直してください。"); }
          else{ setMsgHtml("msgReg",false,"登録しましたが同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。"); await showNotify("同期は未確認です", "登録しましたが同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。"); }
          if(Date.now() < dl) await refresh(dl);
        } else if(r.sync === "launch-failed"){
          setMsgHtml("msgReg",false,"登録は完了しましたが同期の起動に失敗しました。「今すぐ同期」でやり直してください。");
          await showNotify("同期の起動に失敗しました", "登録は完了しましたが同期の起動に失敗しました。「今すぐ同期」でやり直してください。");
          document.getElementById("inpPath").value = ""; lastPreview = null; const _ck = document.getElementById("ckForceReplace"); if(_ck) _ck.checked = false; await refresh();
        } else {
          setMsgHtml("msgReg",false,"登録しました。同期状態は未確認です。ログを確認してください。");
          await showNotify("同期は未確認です", "登録しました。同期状態は未確認です。ログを確認してください。");
          await refresh();
        }
      }catch(e){ setMsg("msgReg", e.message, false); }finally{ try{ btn.disabled = false; }catch(e2){} try{ safeFocus(btn); }catch(e3){} }
    };
  }catch(e){ if(myGen !== previewGen){ return; } pa.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; lastPreview = null; lastPreviewGen = 0; }
}
document.getElementById("btnPrev").onclick = async function(){ await doPreview(document.getElementById("inpPath").value); };
const ckForce = document.getElementById("ckForceReplace");
if(ckForce){ ckForce.onchange = function(){ lastPreview = null; lastPreviewGen = 0; previewGen++; const pa = document.getElementById("prevArea"); if(pa) pa.innerHTML = "<p class='muted'>プレビューをやり直してください。</p>"; const br = document.getElementById("btnReg"); if(br) br.disabled = true; }; }
const inpPathEl = document.getElementById("inpPath");
if(inpPathEl){ inpPathEl.addEventListener("input", function(){ lastPreview = null; lastPreviewGen = 0; previewGen++; const br = document.getElementById("btnReg"); if(br) br.disabled = true; }); }
let browseCancel = false;
let browseGen = 0;
async function pollBrowse(browseId, deadline, myGen){
  const dl = deadline || (Date.now() + 120000);
  while(true){
    if(myGen !== browseGen) return "cancelled";
    let rem = dl - Date.now();
    if(rem <= 0) return "timeout";
    const to = Math.min(8000, rem);
    let s = null;
    try{ s = await api("/api/browse?id="+encodeURIComponent(browseId), "GET", null, to); }catch(e){ s = null; }
    if(browseCancel || myGen !== browseGen) return "cancelled";
    rem = dl - Date.now();
    if(rem <= 0) return "timeout";
    if(s && s.browseId === browseId && (s.status === "selected" || s.status === "cancelled")) return s;
    rem = dl - Date.now();
    if(rem <= 0) return "timeout";
    const wait = Math.min(450, rem);
    await new Promise(function(r){ setTimeout(r, wait); });
    if(browseCancel || myGen !== browseGen) return "cancelled";
  }
}
document.getElementById("btnBrowse").onclick = async function(){
  const bb = document.getElementById("btnBrowse"); bb.disabled = true; browseCancel = false;
  const myGen = ++browseGen;
  const ba = document.getElementById("browseArea");
  ba.textContent = "";
  try{
    const st = await api("/api/browse/start","POST",{hint:document.getElementById("inpPath").value});
    const bid = st.browseId;
    ba.textContent = "選択ダイアログを開きました。フォルダを選んでください。";
    const cb = document.createElement("button"); cb.textContent = "選択をやめる"; cb.style.marginLeft = "8px";
    cb.onclick = async function(){ browseCancel = true; try{ await api("/api/browse/cancel","POST",{browseId:bid}); }catch(e){} };
    ba.appendChild(cb);
    const dl = Date.now() + 120000;
    const r = await pollBrowse(bid, dl, myGen);
    if(browseCancel || myGen !== browseGen){ ba.textContent = "キャンセルされました。登録は行いません。"; return; }
    ba.textContent = "";
    if(r === "timeout"){
      try{ await api("/api/browse/cancel","POST",{browseId:bid}); }catch(e){}
      ba.textContent = "時間切れのため選択を終了しました。登録は行いません。";
    } else if(r === "cancelled" || (r && r.status === "cancelled")){
      ba.textContent = "キャンセルされました。登録は行いません。";
    } else if(r && r.status === "selected"){
      if(browseCancel || myGen !== browseGen){ ba.textContent = "キャンセルされました。登録は行いません。"; return; }
      document.getElementById("inpPath").value = r.path || "";
      ba.textContent = "選択を反映しました。プレビューで確認してください。";
      await doPreview(document.getElementById("inpPath").value);
    } else {
      ba.textContent = "選択を終了しました。登録は行いません。";
    }
  }catch(e){ try{ ba.textContent = "選択を開けませんでした: "+e.message; }catch(e2){} }
  finally{ try{ bb.disabled = false; }catch(e3){} try{ safeFocus(bb); }catch(e4){} }
};
document.getElementById("btnSync").onclick = async function(){
  const b = document.getElementById("btnSync");
  if(unifiedSyncActive){ await showNotify("同期中", "すでに同期を実行中です。"); return; }
  if(globalApplyInflight){ await showNotify("同期中", "Globalプレビュー適用中です。"); return; }
  unifiedSyncActive = true;
  let accepted = false;
  const originallyDisabled = b.disabled;
  b.disabled = true;
  try{
    const okGo = await showConfirm("今すぐ同期の確認", "Global同期（保存済み対象へ配布）を実行し、完了を確認した後、登録済みプロジェクトの同期を実行します。よろしいですか。", "同期する", "やめる");
    if(!okGo){ return; }
    accepted = true;
  unifiedBaselineProjectRunId = unifiedObservedProjectRunId;
  unifiedBaselineGlobalRunId = unifiedObservedGlobalRunId;
    unifiedStateLock = true;
    unifiedFinalState = null;
    unifiedProjectRunId = null;
    unifiedGlobalRunId = null;
    setUnifiedProgress(0, 2, "0/2 同期を確認しています", false);
    try{ const sr=document.getElementById("stRun"); sr.textContent="実行中"; sr.dataset.state="running"; }catch(e){}
    setUnifiedProgress(0, 2, "0/2 Global同期を実行中", false);
    let gr = null;
    try{ gr = await api("/api/global-sync","POST",{}); }catch(e){ setUnifiedProgress(0, 2, "0/2 Global同期: 開始できませんでした", false); await showNotify("Global同期できませんでした", e.message); unifiedFinalState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
    if(!gr || gr.sync !== "started"){ setUnifiedProgress(0, 2, "0/2 Global同期: 開始できませんでした", false); await showNotify("Global同期できませんでした", "同期を開始できませんでした。"); unifiedFinalState = "failed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("failed"); sr.dataset.state="failed"; }catch(e2){} return; }
    if(!gr.syncId){ setUnifiedProgress(0, 2, "0/2 Global同期: " + stateJa("unconfirmed"), false); await showNotify("Global同期は未確認です", "同期IDを取得できませんでした。"); unifiedFinalState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
     unifiedGlobalRunId = gr.syncId;
    const gdl = Date.now() + 60000;
    await refreshGlobal(gdl);
    const gst = await pollGlobalUntilDone(gr.syncId, 30, 2000, gdl);
    if(Date.now() < gdl) await refreshGlobal(gdl);
    const globalState = gst || "unconfirmed";
    if(globalState === "unconfirmed" || globalState === "skipped"){
      try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa(globalState); sr.dataset.state=globalState; }catch(e){}
      setUnifiedProgress(0, 2, "0/2 Global同期: " + stateJa(globalState), false);
      await showNotify("同期を中断しました", "Global同期が" + stateJa(globalState) + "のため、Project同期は実行しませんでした。");
      if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; }
      unifiedFinalState = globalState;
      return;
    }
    setUnifiedProgress(1, 2, "1/2 Global同期: " + stateJa(globalState) + " / Project同期を実行中", false);
    let pr = null;
    try{ pr = await api("/api/sync","POST",{}); }catch(e){ setUnifiedProgress(1, 2, "1/2 Project同期: 開始できませんでした", false); await showNotify("Project同期できませんでした", e.message); if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; } unifiedFinalState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
    if(!pr || pr.sync !== "started"){ setUnifiedProgress(1, 2, "1/2 Project同期: 開始できませんでした", false); await showNotify("Project同期できませんでした", "同期を開始できませんでした。"); unifiedFinalState = "failed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("failed"); sr.dataset.state="failed"; }catch(e2){} return; }
    if(!pr.syncId){ setUnifiedProgress(1, 2, "1/2 Project同期: " + stateJa("unconfirmed"), false); await showNotify("Project同期は未確認です", "同期IDを取得できませんでした。"); unifiedFinalState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
    unifiedProjectRunId = pr.syncId;
    const pdl = Date.now() + 60000;
    await refresh(pdl);
    const pst = await pollUntilDone(pr.syncId, 30, 2000, pdl);
    if(Date.now() < pdl) await refresh(pdl);
    const projectState = pst || "unconfirmed";
    let agg = "failed";
    if(globalState === "success" && projectState === "success") agg = "success";
    else if(projectState === "unconfirmed") agg = "unconfirmed";
    else if(projectState === "skipped") agg = "skipped";
    try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa(agg); sr.dataset.state=agg; }catch(e){}
    const projTerminal = (projectState === "success" || projectState === "failed" || projectState === "skipped");
    const projCompleted = projTerminal ? 2 : 1;
    setUnifiedProgress(projCompleted, 2, projCompleted + "/2 Project同期: " + stateJa(projectState), false);
    if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; }
    unifiedFinalState = agg;
    const parts = "Global: " + stateJa(globalState) + " / Project: " + stateJa(projectState);
    const latestProject = commonSyncStates.project;
    if(latestProject){
      const log = (latestProject.logName || "ログなし") + (latestProject.logMtime ? " (" + latestProject.logMtime + ")" : "");
      document.getElementById("stLog").textContent = log;
      document.getElementById("stLog").title = log;
    }
    document.getElementById("stTail").textContent = parts;
    document.getElementById("stTail").title = parts;
    if(agg === "success") await showNotify("同期が成功しました", parts);
    else if(agg === "skipped") await showNotify("同期は見送りです", parts);
    else if(agg === "unconfirmed") await showNotify("同期は未確認です", parts);
    else await showNotify("同期が失敗しました", parts);
  }catch(e){ try{ await showNotify("同期できませんでした", e.message); }catch(e2){} if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; } unifiedFinalState = "failed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("failed"); sr.dataset.state="failed"; }catch(e){} setUnifiedProgress(0, 2, "0/2 同期に失敗しました", false); }
  finally{
    if(accepted && unifiedFinalState && !unifiedProjectRunId){
      const global = commonSyncStates.global;
      const matches = global && unifiedGlobalRunId && global.syncId === unifiedGlobalRunId;
      const status = matches ? stateJa(global.syncState || "unconfirmed") : stateJa("unconfirmed");
      const parts = "Global: " + status + " / Project: 未実行";
      const log = matches ? (global.logName || "今回のログ未確認") : "今回のログ未確認";
      document.getElementById("stTail").textContent = parts;
      document.getElementById("stTail").title = parts;
      document.getElementById("stLog").textContent = log;
      document.getElementById("stLog").title = log;
    }
    unifiedSyncActive = false;
    unifiedStateLock = false;
    try{ b.disabled = originallyDisabled; }catch(e3){}
    try{ safeFocus(b); }catch(e4){}
  }
};
function renderBackupDiff(da, d){
  da.innerHTML = "";
  const h = document.createElement("p"); h.className = "muted";
  h.textContent = "対象: " + d.name + (d.same ? "（差分なし）" : "（差分あり）") + (d.truncated ? "（一部省略）" : "");
  da.appendChild(h);
  const pa = document.createElement("p"); pa.className = "muted";
  pa.textContent = "AGENTS.md: " + (((d.backupHasAgents || d.currentHasAgents)) ? (((d.lines || []).length) ? "差分あり" : "差分なし") : "対象外");
  da.appendChild(pa);
  if((d.lines || []).length){
    const pre = document.createElement("pre");
    pre.appendChild(renderDiffFrag(d.lines));
    da.appendChild(pre);
  }
  const pl = document.createElement("p"); pl.className = "muted";
  pl.textContent = "localSource: " + (((d.backupHasLocal || d.currentHasLocal)) ? (((d.localLines || []).length) ? "差分あり" : "差分なし") : "対象外");
  da.appendChild(pl);
  if((d.localLines || []).length){
    const pre2 = document.createElement("pre");
    pre2.appendChild(renderDiffFrag(d.localLines));
    da.appendChild(pre2);
  }
}
function renderDiffFrag(lines){
  const frag = document.createDocumentFragment();
  (lines || []).forEach(function(l){
    const sp = document.createElement("span");
    sp.className = (l.t === "+") ? "diff-add" : "diff-del";
    sp.textContent = l.t + " " + l.text + "\n";
    frag.appendChild(sp);
  });
  return frag;
}
function diffLinesLocal(a, b){
  const o = String(a).split("\n"), w = String(b).split("\n");
  let pre = 0;
  while(pre < o.length && pre < w.length && o[pre] === w[pre]) pre++;
  let suf = 0;
  while(suf < (o.length - pre) && suf < (w.length - pre) && o[o.length-1-suf] === w[w.length-1-suf]) suf++;
  const out = [];
  for(let i=pre;i<o.length-suf;i++) out.push({t:"-", text:o[i]});
  for(let i=pre;i<w.length-suf;i++) out.push({t:"+", text:w[i]});
  return {same:(o.length===w.length&&pre===o.length), lines:out.slice(0,300), truncated:(out.length>300)};
}
function renderPlan(plan){
  const pa = document.getElementById("planArea");
  pa.innerHTML = "";
  const h = document.createElement("p"); h.className = "muted";
  h.textContent = "共通SHA: " + ((plan.commonSha||"").slice(0,12)) + " 取得GitSHA: " + ((plan.commonCommit||"").slice(0,12)) + " 作成: " + (plan.createdAt||"");
  pa.appendChild(h);
  (plan.projects||[]).forEach(function(pj){
    const t = document.createElement("p");
    if(pj.result === "failed"){ t.className = "err"; t.textContent = "失敗: " + pj.name + "：" + (pj.error||""); pa.appendChild(t); return; }
    if(pj.result === "skipped"){ t.className = "warn"; t.textContent = "見送り: " + pj.name + "（無効のため対象外）"; pa.appendChild(t); return; }
    const d = diffLinesLocal(pj.currentText||"", pj.generatedText||"");
    t.className = d.same ? "ok" : "warn";
    t.textContent = (d.same ? "変更なし: " : "変更あり: ") + pj.name;
    pa.appendChild(t);
    if(!d.same){
      const pre = document.createElement("pre");
      pre.appendChild(renderDiffFrag(d.lines));
      if(d.truncated){ const n = document.createElement("span"); n.className="diff-note"; n.textContent="(省略)"; pre.appendChild(n); }
      pa.appendChild(pre);
    }
  });
}
document.getElementById("btnStatusReload").onclick = function(){ refresh(); };
let lastPlan = null;
function planIdForSelection(names){
  try{
    if(!lastPlan || !lastPlan.id) return null;
    const a = ((names || []).slice().sort().join(""));
    const b = (((lastPlan.names) || []).slice().sort().join(""));
    if(a !== "" && a === b) return lastPlan.id;
  }catch(e){}
  return null;
}
document.getElementById("btnSyncSel").onclick = async function(){
  const names = selectedNames();
  if(!names.length){ await showNotify("選択なし", "同期するプロジェクトを選択してください（一覧または状態表の選択欄）。"); return; }
  if(unifiedSyncActive){ await showNotify("同期中", "統合同期の実行中は選択同期できません。"); return; }
  const b = document.getElementById("btnSyncSel");
  const originallyDisabled = b.disabled;
  b.disabled = true;
  try{
    unifiedFinalState = null;
    unifiedProjectRunId = null;
    const pid = planIdForSelection(names);
    const r = await api("/api/sync","POST",{projectNames:names, planId:pid});
    lastPlan = null;
    await afterSyncNotify(r);
  }catch(e){ try{ await showNotify("同期できませんでした", e.message); }catch(e2){} }
  finally{ try{ b.disabled = originallyDisabled; }catch(e3){} try{ safeFocus(b); }catch(e4){} }
};
document.getElementById("btnPlanSel").onclick = async function(){
  const names = selectedNames();
  const pa = document.getElementById("planArea"); pa.innerHTML = "<p class='muted'>プラン作成中</p>";
  try{
    const r = await api("/api/plan-start","POST",{projectNames:names});
    const dl = Date.now() + 90000;
    let plan = null;
    while(true){
      await new Promise(function(rs){ setTimeout(rs, 2000); });
      if(Date.now() >= dl) break;
      const to = Math.min(8000, dl - Date.now());
      if(to <= 0) break;
      let g = null;
      try{ g = await api("/api/plan?id="+encodeURIComponent(r.planId),"GET",null,to); }catch(e){ continue; }
      if(g && g.status === "ready"){ plan = g; break; }
    }
    if(!plan){ pa.innerHTML = "<p class='warn'>未確認です。しばらくして「選択の反映前差分」で再取得してください。</p>"; return; }
    renderPlan(plan);
    try{ lastPlan = {id: r.planId, names: names.slice()}; }catch(e){ lastPlan = null; }
    try{
      const ph = document.createElement("p"); ph.className = "muted";
      ph.textContent = "プランID: " + String(r.planId).slice(0, 12) + "（選択を変えず「選択を同期」でこのプランを適用）";
      pa.appendChild(ph);
    }catch(e2){}
  }catch(e){ pa.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnStatusReload").onclick = function(){ refresh(); };
async function loadBackups(){
  const tb = document.getElementById("backupRows");
  try{
    const b = await api("/api/backups","GET");
    tb.innerHTML = "";
    document.getElementById("tblBackups").hidden = b.backups.length === 0;
    document.getElementById("emptyBackups").hidden = b.backups.length !== 0;
    b.backups.forEach(function(e){
      const tr = document.createElement("tr");
      try{ tr.dataset.search = (e.id + " " + (e.name || "") + " " + (e.displayName || "")).toLowerCase(); }catch(e2){}
      const td0 = document.createElement("td"); const c0 = document.createElement("code"); c0.className="path"; c0.textContent = e.id; td0.appendChild(c0);
      const td1 = document.createElement("td"); td1.textContent = e.displayName || e.name || "-"; td1.title = e.name || "";
      const td2 = document.createElement("td"); td2.textContent = e.createdAt || "-";
      const td3 = document.createElement("td"); td3.textContent = ((e.hasAgentsFile ? "AGENTSあり" : "AGENTSなし") + " / " + (e.hasLocalFile ? "localあり" : "localなし"));
      const td4 = document.createElement("td");
      const acts = document.createElement("div"); acts.className = "acts";
      const bd = document.createElement("button"); bd.textContent = "差分";
      bd.onclick = async function(){
        const da = document.getElementById("backupDiffArea"); da.innerHTML = "<p class='muted'>差分取得中</p>";
        try{
          const d = await api("/api/backup-diff","POST",{backupId:e.id});
          renderBackupDiff(da, d);
        }catch(err){ da.innerHTML = "<p class='err'>"+esc(err.message)+"</p>"; }
      };
      const br = document.createElement("button"); br.textContent = "復元"; br.className = "danger";
      br.onclick = async function(){
        const okGo = await showConfirm("復元の確認", "「"+e.id+"」を復元します。AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。よろしいですか。", "復元する", "やめる");
        if(!okGo) return;
        try{
          const r = await api("/api/restore","POST",{backupId:e.id, confirm:true});
          setMsg("msgBackup", "復元しました。休止中のため再開は有効化してください。" + (r.warning ? r.warning : ""), true);
          await refresh();
        }catch(err){ setMsg("msgBackup", err.message, false); }
      };
      acts.appendChild(bd); acts.appendChild(br); td4.appendChild(acts);
      tr.appendChild(td0); tr.appendChild(td1); tr.appendChild(td2); tr.appendChild(td3); tr.appendChild(td4);
      tb.appendChild(tr);
    });
    try{ applySearchFilter(); }catch(e2){}
  }catch(e){ setMsg("msgBackup", e.message, false); }
}
document.getElementById("btnBackupsReload").onclick = function(){ loadBackups(); };
function fillLocalSelect(list){
  const sel = document.getElementById("selLocal");
  if(!sel) return;
  const cur = sel.value;
  sel.innerHTML = "";
  (list||[]).forEach(function(e){
    const o = document.createElement("option");
    const nm = (e && e.name) || e;
    o.value = nm; o.textContent = (e && e.displayName) || nm;
    sel.appendChild(o);
  });
  if(cur) sel.value = cur;
}
let localHash = "";
function localRedactNotice(r){
  try{ if(r && r.redacted) return "伏字表示中の内容はそのまま保存できません（原本保護）。再取得しても伏字のままの場合、そのまま保存しないでください。"; }catch(e){}
  return "";
}
document.getElementById("btnLocalLoad").onclick = async function(){
  const nm = document.getElementById("selLocal").value;
  const la = document.getElementById("localArea"); la.innerHTML = "<p class='muted'>取得中</p>";
  try{
    const r = await api("/api/localrule-get","POST",{name:nm});
    localHash = r.hash;
    la.innerHTML = "";
    const info = document.createElement("p"); info.className="muted"; info.textContent = "取得ハッシュ: "+(r.hash||"").slice(0,12)+"（保存時に一致確認）";
    la.appendChild(info);
    const nz = localRedactNotice(r);
    if(nz){ const nw = document.createElement("p"); nw.className = "warn"; nw.textContent = nz; la.appendChild(nw); }
    const ta = document.createElement("textarea"); ta.id = "txtLocal"; ta.style.minHeight = "160px"; ta.value = r.text;
    const row = document.createElement("div"); row.className = "btnrow";
    const sv = document.createElement("button"); sv.className = "primary"; sv.textContent = "検証して保存";
    sv.onclick = async function(){
      try{
        const s = await api("/api/localrule-save","POST",{name:nm, text:ta.value, expectedHash:localHash});
        localHash = s.hash;
        setMsg("msgLocal", "保存しました。", true);
      }catch(err){ setMsg("msgLocal", err.message, false); }
    };
    row.appendChild(sv); la.appendChild(info); la.appendChild(ta); la.appendChild(row);
  }catch(e){ la.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnCheck").onclick = async function(){
  const nm = document.getElementById("selLocal").value;
  const ca = document.getElementById("checkArea"); ca.innerHTML = "<p class='muted'>検査中</p>";
  try{
    const r = await api("/api/check","POST",{name:nm});
    ca.innerHTML = "";
    const n = document.createElement("p"); n.className="muted"; n.textContent = "いずれも候補であり、断定ではありません。内容を確認して判断してください。";
    ca.appendChild(n);
    (r.duplicates||[]).forEach(function(d){
      const p = document.createElement("p"); p.textContent = "【重複候補】" + d.project + "：" + d.line; ca.appendChild(p);
    });
    (r.contradictions||[]).forEach(function(c2){
      const p = document.createElement("p"); p.textContent = "【矛盾候補】" + c2.project + "：共通「" + c2.common + "」/固有「" + c2.local + "」"; ca.appendChild(p);
    });
    if(!(r.duplicates||[]).length && !(r.contradictions||[]).length){
      const p = document.createElement("p"); p.className="ok"; p.textContent = "候補はありませんでした。"; ca.appendChild(p);
    }
  }catch(e){ ca.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnIntervalGet").onclick = async function(){
  try{
    const r = await api("/api/interval-get","GET");
    document.getElementById("numInterval").value = r.minutes;
    setMsg("msgInterval", "現在の間隔："+r.minutes+"分（Project のみ）", true);
  }catch(e){ setMsg("msgInterval", e.message, false); }
};
document.getElementById("btnIntervalSet").onclick = async function(){
  const m = parseInt(document.getElementById("numInterval").value, 10);
  const okGo = await showConfirm("間隔の変更", "Project 同期の間隔を"+m+"分に変更します（Global は不変）。よろしいですか。", "変更する", "やめる");
  if(!okGo) return;
  try{
    await api("/api/interval-set","POST",{minutes:m, confirm:true});
    setMsg("msgInterval", "間隔を変更しました："+m+"分", true);
  }catch(e){ setMsg("msgInterval", e.message, false); }
};
document.getElementById("btnExport").onclick = async function(){
  try{
    const r = await api("/api/export","GET");
    const blob = new Blob([JSON.stringify(r, null, 2)], {type:"application/json"});
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "rulesync-settings.json";
    document.body.appendChild(a); a.click();
    try{ URL.revokeObjectURL(a.href); }catch(e){}
    a.remove();
    setMsg("msgSettings", "エクスポートしました（秘密情報なし）。", true);
  }catch(e){ setMsg("msgSettings", e.message, false); }
};
function canShowImportButton(v){
  try{
    if(!v) return false;
    if(((v.conflict || []).length) || ((v.invalid || []).length)) return false;
    if((v.add || []).length) return true;
    if(v.interval && v.interval.willChange) return true;
  }catch(e){}
  return false;
}
document.getElementById("btnImportPrev2").onclick = async function(){
  const ia = document.getElementById("importRegArea"); ia.innerHTML = "<p class='muted'>確認中</p>";
  try{
    const raw = document.getElementById("txtImport").value;
    let data = null;
    try{ data = JSON.parse(raw); }catch(e){ throw new Error("JSONを解釈できません。"); }
    const v = await api("/api/registry-import-preview","POST",{data:data});
    let h = "";
    (v.add||[]).forEach(function(a){ h += "<p class='ok'>追加："+esc(a.name)+"</p>"; });
    (v.skip||[]).forEach(function(s){ h += "<p class='muted'>維持："+esc(s.name)+"（"+esc(s.reason||"")+"）</p>"; });
    (v.conflict||[]).forEach(function(c3){ h += "<p class='err'>競合："+esc(c3.name)+"（"+esc(c3.reason||"")+"）</p>"; });
    (v.invalid||[]).forEach(function(iv){ h += "<p class='err'>不正："+esc(iv.name)+"（"+esc(iv.reason||"")+"）</p>"; });
    if(v.interval){
      if(v.interval.incoming !== null && v.interval.incoming !== undefined){
        const curIv = (v.interval.current === null || v.interval.current === undefined) ? "未設定" : v.interval.current + "分";
        h += "<p class='muted'>同期間隔: "+esc(String(curIv))+" → "+v.interval.incoming+"分に変更します（Projectのみ、Global不変）。</p>";
      } else if(!v.interval.valid){
        h += "<p class='err'>同期間隔: "+esc(v.interval.reason || "不正")+"</p>";
      }
    }
    if(v.interval){
      if(v.interval.incoming !== null && v.interval.incoming !== undefined){
        const curIv = (v.interval.current === null || v.interval.current === undefined) ? "（未設定）" : v.interval.current + "分";
        h += "<p class='muted'>同期間隔: " + esc(String(curIv)) + " → " + v.interval.incoming + "分に変更します（Projectのみ、Global不変）。</p>";
      } else if(!v.interval.valid){
        h += "<p class='err'>同期間隔: " + esc(v.interval.reason || "不正") + "</p>";
      }
    }
    if(canShowImportButton(v)){
      h += "<label class='chk'><input type='checkbox' id='ckImp2'> 追加内容を確認した</label>";
      h += "<div class='btnrow'><button id='btnImpGo' class='primary'>取り込む</button></div><div id='msgImpGo' role='status'></div>";
    } else if(((v.conflict||[]).length) || ((v.invalid||[]).length)){
      h += "<p class='muted'>競合・不正があるため取り込めません。整理してから再実行してください。</p>";
    } else {
      h += "<p class='muted'>追加・変更がありません。</p>";
    }
    ia.innerHTML = h;
    const go = document.getElementById("btnImpGo");
    if(go) go.onclick = async function(){
      go.disabled = true;
      try{
        if(!document.getElementById("ckImp2") || !document.getElementById("ckImp2").checked) throw new Error("確認チェックを入れてください。");
        const r2 = await api("/api/import","POST",{data:data, confirm:true});
        let doneMsg = "取り込みました。追加："+r2.added+"件";
        if(r2.intervalApplied) doneMsg += "（同期間隔を"+r2.intervalMinutes+"分に変更）";
        setMsg("msgImpGo", doneMsg, true);
        await refresh();
      }catch(e){ setMsg("msgImpGo", e.message, false); }finally{ try{ go.disabled = false; }catch(e2){} try{ safeFocus(go); }catch(e3){} }
    };
  }catch(e){ ia.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnBatchPrev").onclick = async function(){
  const ba = document.getElementById("batchArea"); ba.innerHTML = "<p class='muted'>確認中</p>";
  try{
    const lines = document.getElementById("inpBatch").value.split("\n").map(function(s){ return s.trim(); }).filter(function(s){ return s !== ""; });
    if(!lines.length) throw new Error("パスを1行ずつ入力してください。");
    const v = await api("/api/preview-batch","POST",{paths:lines});
    let h = "";
    const oks = [];
    v.results.forEach(function(r){
      if(r.ok){ h += "<p class='ok'>OK: 「"+esc(r.name)+"」← "+esc(r.path)+"</p>"; oks.push({previewId:r.previewId, path:r.path}); }
      else{ h += "<p class='err'>NG: "+esc(r.path)+"："+esc(r.error)+"</p>"; }
    });
    if(oks.length){
      h += "<label class='chk'><input type='checkbox' id='ckBatch'> "+oks.length+"件を登録し、非表示で同期することを理解した</label>";
      h += "<div class='btnrow'><button id='btnBatchReg' class='primary'>まとめて登録して同期</button></div><div id='msgBatch' role='status'></div>";
    }
    ba.innerHTML = h;
    const rb = document.getElementById("btnBatchReg");
    if(rb) rb.onclick = async function(){
      rb.disabled = true;
      try{
        if(!document.getElementById("ckBatch") || !document.getElementById("ckBatch").checked) throw new Error("確認チェックを入れてください。");
        const okGo = await showConfirm("一括登録の確認", oks.length+"件を登録し、非表示で同期します。よろしいですか。", "登録する", "やめる");
        if(!okGo){ return; }
        const r = await api("/api/register-batch","POST",{items:oks, confirm:true});
        setMsg("msgBatch", "登録しました："+r.registered.join("、"), true);
        document.getElementById("inpBatch").value = "";
        await afterSyncNotify(r);
      }catch(e){ setMsg("msgBatch", e.message, false); }finally{ try{ rb.disabled = false; }catch(e2){} try{ safeFocus(rb); }catch(e3){} }
    };
  }catch(e){ ba.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnImportPrev").onclick = async function(){
  const ia = document.getElementById("importArea"); ia.innerHTML = "<p class='muted'>確認中</p>";
  try{
    const v = await api("/api/import-preview","POST",{path:document.getElementById("inpPath").value});
    let h = "<p class='ok'>取込プレビュー OK: 「"+esc(v.name)+"」として登録できます。</p>";
    h += "<p class='muted'>既存 AGENTS.md (sha256:"+esc((v.agentsHash||"").slice(0,12))+") を退避し、固有分を project-local.md へ転記します。</p>";
    h += "<pre>"+esc((v.transcription||"").slice(0,2000))+"</pre>";
    h += "<label class='chk'><input type='checkbox' id='ckImp'> 取込内容を確認し、退避と転記に同意する</label>";
    h += "<div class='btnrow'><button id='btnImpReg' class='primary'>取り込んで登録・同期</button></div><div id='msgImp' role='status'></div>";
    ia.innerHTML = h;
    document.getElementById("btnImpReg").onclick = async function(){
      const btn = document.getElementById("btnImpReg"); btn.disabled = true;
      try{
        if(!document.getElementById("ckImp") || !document.getElementById("ckImp").checked) throw new Error("確認チェックを入れてください。");
        const okGo = await showConfirm("取込の確認", "「"+v.name+"」を取り込んで登録し、非表示で同期します。よろしいですか。", "取り込む", "やめる");
        if(!okGo){ return; }
        const r = await api("/api/register","POST",{path:v.path,previewId:v.previewId,confirm:true,importConfirm:true});
        setMsg("msgImp", "取り込んで登録しました。", true);
        document.getElementById("inpPath").value = "";
        await afterSyncNotify(r);
      }catch(e){ setMsg("msgImp", e.message, false); }finally{ try{ btn.disabled = false; }catch(e2){} try{ safeFocus(btn); }catch(e3){} }
    };
  }catch(e){ ia.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("inpSearch").addEventListener("input", function(){ try{ applySearchFilter(); }catch(e){} });
document.getElementById("btnReload").onclick = function(){ refresh(); };
document.getElementById("btnReload").onclick = function(){ refresh(); };
function globalResultJa(r){
  if(r === "success") return "成功";
  if(r === "failed") return "失敗";
  if(r === "skipped") return "見送り";
  return "未確認";
}
function renderGlobalTable(list){
  const tb = document.getElementById("globalRows");
  tb.innerHTML = "";
  document.getElementById("tblGlobal").hidden = list.length === 0;
  document.getElementById("emptyGlobal").hidden = list.length !== 0;
  list.forEach(function(e){
    const tr = document.createElement("tr");
    try{ tr.dataset.search = (e.target + " " + (e.path || "") + " " + (e.error || "")).toLowerCase(); }catch(e2){}
    const tdT = document.createElement("td"); tdT.textContent = (e.target === "codexcli") ? "Codex" : "OpenCode";
    const tdP = document.createElement("td"); const c = document.createElement("code"); c.className = "path"; c.textContent = e.path || "-"; tdP.appendChild(c);
    const tdA = document.createElement("td"); tdA.textContent = e.lastAttemptAt || "-";
    const tdS = document.createElement("td"); tdS.textContent = e.lastSuccessAt || "-";
    const tdH = document.createElement("td"); const hc = document.createElement("code"); hc.className = "path"; hc.textContent = ((e.sourceCommit || "").slice(0,12) || "-"); tdH.appendChild(hc);
    const tdR = document.createElement("td"); tdR.textContent = globalResultJa(e.result);
    const tdF = document.createElement("td"); tdF.textContent = (e.error || "").slice(0,120);
    tr.appendChild(tdT); tr.appendChild(tdP); tr.appendChild(tdA); tr.appendChild(tdS); tr.appendChild(tdH); tr.appendChild(tdR); tr.appendChild(tdF);
    tb.appendChild(tr);
  });
}
function updateGlobalUI(g){
  updateCommonSyncState("global", g);
  renderGlobalTable(g.providers || []);
  try{ applySearchFilter(); }catch(e){}
  let sum = "待機中";
  const st = g.syncState || "idle";
  sum = stateJa(st) + "（対象 " + (g.targets || []).join("・") + "）";
  if(st === "success") sum = "成功: " + ((g.finalLine || g.tail || "").slice(-160));
  if(st === "failed") sum = "失敗: " + ((g.finalLine || g.tail || "").slice(-160));
  if(st === "skipped") sum = "見送りです。別の同期が実行中のため今回は見送りました。しばらくして今すぐ同期でやり直してください。";
  if(st === "waiting") sum = "起動待ちです。子プロセスの起動を確認しています。";
  if(st === "unconfirmed") sum = "未確認です。今回の実行結果がまだありません。";
  document.getElementById("globalSummary").textContent = sum;
  document.getElementById("ovGlobal").textContent = "Global同期: " + sum;
  document.getElementById("ovGlobal").title = "Global同期: " + sum;
  document.getElementById("globalLogPre").textContent = g.tail || "ログがありません。";
  // Poll-driven status must never clobber unsaved edits: dirty inputs are
  // refreshed only after save or explicit reload.
  if(!globalTargetsDirty){
    try{
      document.getElementById("ckTCodex").checked = (g.targets || []).indexOf("codexcli") >= 0;
      document.getElementById("ckTOpenCode").checked = (g.targets || []).indexOf("opencode") >= 0;
    }catch(e2){}
  }
  try{
    const en = document.getElementById("globalEnabledState");
    if(g.taskEnabled === true) en.textContent = "自動同期は有効です（次回も裏で実行）。";
    else if(g.taskEnabled === false) en.textContent = "自動同期は休止中です（裏の実行なし）。再開は切替ボタンで有効化してください。";
    else en.textContent = "自動同期の状態を取得できませんでした。";
  }catch(e3){}
  try{ if(g.intervalMinutes !== null && g.intervalMinutes !== undefined && !globalIntervalDirty) document.getElementById("numGlobalInterval").value = g.intervalMinutes; }catch(e4){}
  try{ updateGlobalSyncApplyButton(); }catch(e5){}
}
let commonSyncStates = { project: null, global: null };
let commonSyncSource = "project";
let lastGlobalPlan = null;
let unifiedSyncActive = false;
let unifiedStateLock = false;
let unifiedFinalState = null;
let unifiedProjectRunId = null;
let unifiedGlobalRunId = null;
let completedUnifiedRunIds = {};
let unifiedObservedProjectRunId = null;
let unifiedObservedGlobalRunId = null;
let unifiedBaselineProjectRunId = null;
let unifiedBaselineGlobalRunId = null;
let globalApplyInflight = false;
let globalTargetsDirty = false;
let globalIntervalDirty = false;
function globalSelectedTargets(){
  const tg = [];
  try{ if(document.getElementById("ckTCodex").checked) tg.push("codexcli"); }catch(e){}
  try{ if(document.getElementById("ckTOpenCode").checked) tg.push("opencode"); }catch(e){}
  return tg;
}
function globalPlanIdForSelection(names){
  try{
    if(!lastGlobalPlan || !lastGlobalPlan.id) return null;
    const a = ((names || []).slice().sort().join(""));
    const b = (((lastGlobalPlan.names) || []).slice().sort().join(""));
    if(a !== "" && a === b) return lastGlobalPlan.id;
  }catch(e){}
  return null;
}
try{ document.getElementById("ckTCodex").addEventListener("change", function(){ globalTargetsDirty = true; updateGlobalSyncApplyButton(); }); }catch(eT1){}
try{ document.getElementById("ckTOpenCode").addEventListener("change", function(){ globalTargetsDirty = true; updateGlobalSyncApplyButton(); }); }catch(eT2){}
try{ document.getElementById("numGlobalInterval").addEventListener("input", function(){ globalIntervalDirty = true; }); }catch(eT3){}
async function refreshGlobal(deadline){
  try{
    let t = 8000;
    if(typeof deadline === "number"){ t = Math.min(8000, deadline - Date.now()); if(t <= 0) return; }
    const g = await api("/api/global-status", "GET", null, t);
    updateGlobalUI(g);
  }catch(e){ document.getElementById("globalLogPre").textContent = "取得失敗: "+e.message; }
}
async function pollGlobalUntilDone(syncId, tries, delayMs, deadline){
  const dl = deadline || (Date.now() + 60000);
  for(let i=0;i<tries;i++){
    if(i > 0){
      let rem0 = dl - Date.now();
      if(rem0 <= 0) return "unconfirmed";
      const wait0 = Math.min(delayMs, rem0);
      await new Promise(function(r){ setTimeout(r, wait0); });
    }
    let rem = dl - Date.now();
    if(rem <= 0) return "unconfirmed";
    const to = Math.min(8000, rem);
    let s = null;
    try{ s = await api("/api/global-status?runId="+encodeURIComponent(syncId), "GET", null, to); }catch(e){ continue; }
    try{ updateGlobalUI(s); }catch(e){}
    if(!s || !s.syncId || !syncId) continue;
    if(s.syncId !== syncId) continue;
    if(s.syncState === "success" || s.syncState === "failed" || s.syncState === "skipped") return s.syncState;
  }
  return "unconfirmed";
}
async function afterGlobalSyncNotify(r){
  if(r && r.sync === "started"){
    const dl = Date.now() + 60000;
    await refreshGlobal(dl);
    const st = await pollGlobalUntilDone(r.syncId, 30, 2000, dl);
    if(Date.now() < dl) await refreshGlobal(dl);
    if(st === "success") await showNotify("Global同期が成功しました", "Global同期が成功しました。ログを確認してください。");
    else if(st === "failed") await showNotify("Global同期が失敗しました", "Global同期が失敗しました。ログを確認してください。");
    else if(st === "skipped") await showNotify("Global同期は見送りです", "Global同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。");
    else await showNotify("Global同期は未確認です", "Global同期は未確認です(起動待ち/継続中)。しばらくして状態を更新してください。");
  } else {
    await refreshGlobal();
    await showNotify("Global同期は未確認です", "Global同期状態は未確認です。ログを確認してください。");
  }
}
function setUnifiedProgress(completed, total, text, indeterminate){
  try{
    const p = document.getElementById("syncProgress");
    const t = document.getElementById("syncProgressText");
    if(p){
      if(indeterminate){ p.removeAttribute("value"); }
      else { p.value = completed; }
      p.max = total || 2;
      p.setAttribute("aria-valuetext", text || "");
    }
    if(t) t.textContent = text || "";
  }catch(e){}
}
function globalSyncApplyEnabled(){
  try{ return !!globalPlanIdForSelection(globalSelectedTargets()); }catch(e){ return false; }
}
function updateGlobalSyncApplyButton(){
  try{
    const b = document.getElementById("btnGlobalSync");
    if(b) b.disabled = !globalSyncApplyEnabled();
  }catch(e){}
}
function renderGlobalPlan(plan){
  const pa = document.getElementById("globalPlanArea");
  pa.innerHTML = "";
  const h = document.createElement("p"); h.className = "muted";
  h.textContent = "取得元: " + ((plan.sourceCommit||"").slice(0,12) || "-") + " 作成: " + (plan.createdAt||"");
  pa.appendChild(h);
  (plan.entries||[]).forEach(function(en){
    if(en.result === "failed"){ const t = document.createElement("p"); t.className = "err"; t.textContent = "失敗: " + en.target + "：" + (en.error||""); pa.appendChild(t); return; }
    const d = diffLinesLocal(en.currentText||"", en.generatedText||"");
    const t = document.createElement("p");
    t.className = d.same ? "ok" : "warn";
    t.textContent = (d.same ? "変更なし: " : "変更あり: ") + en.target;
    pa.appendChild(t);
    if(!d.same){
      const pre = document.createElement("pre");
      pre.appendChild(renderDiffFrag(d.lines));
      if(d.truncated){ const n = document.createElement("span"); n.className="diff-note"; n.textContent="(省略)"; pre.appendChild(n); }
      pa.appendChild(pre);
    }
  });
  try{
    const ph = document.createElement("p"); ph.className = "muted";
    ph.textContent = "この内容でよければ「プレビューを適用」で反映します（反映前に再照合し、変化があれば拒否）。";
    pa.appendChild(ph);
  }catch(e2){}
}
document.getElementById("btnGlobalReload").onclick = function(){ globalTargetsDirty = false; globalIntervalDirty = false; refreshGlobal(); };
document.getElementById("btnGlobalSync").onclick = async function(){
  const b = document.getElementById("btnGlobalSync");
  const originallyDisabled = b.disabled;
  const names = globalSelectedTargets();
  const pid = globalPlanIdForSelection(names);
  if(!pid){ b.disabled = true; return; }
  if(unifiedSyncActive){ await showNotify("同期中", "統合同期の実行中はプレビュー適用できません。"); return; }
  if(globalApplyInflight){ await showNotify("同期中", "すでにプレビュー適用中です。"); return; }
  globalApplyInflight = true;
  b.disabled = true;
  try{
    const okGo = await showConfirm("Global同期の確認", "確認済みプランで反映します（反映前に再照合し、変化があれば拒否）。よろしいですか。", "適用する", "やめる");
    if(!okGo){ return; }
  unifiedBaselineProjectRunId = unifiedObservedProjectRunId;
  unifiedBaselineGlobalRunId = unifiedObservedGlobalRunId;
    commonSyncSource = "global";
    unifiedFinalState = null;
    unifiedProjectRunId = null;
    unifiedGlobalRunId = null;
    const r = await api("/api/global-sync","POST",{targetNames:names, planId:pid});
    lastGlobalPlan = null;
    updateGlobalSyncApplyButton();
    await afterGlobalSyncNotify(r);
  }catch(e){ try{ await showNotify("Global同期できませんでした", e.message); }catch(e2){} try{ lastGlobalPlan = null; }catch(e3){} try{ updateGlobalSyncApplyButton(); }catch(e4){} }
  finally{ globalApplyInflight = false; try{ b.disabled = originallyDisabled ? true : globalSyncApplyEnabled() ? false : true; }catch(e3){} try{ safeFocus(b); }catch(e4){} }
};
document.getElementById("btnGlobalPreview").onclick = async function(){
  const b = document.getElementById("btnGlobalPreview"); b.disabled = true;
  const pa = document.getElementById("globalPlanArea"); pa.innerHTML = "<p class='muted'>プラン作成中</p>";
  const sel = globalSelectedTargets();
  try{
    const r = await api("/api/global-preview-start","POST",{targetNames:sel});
    const dl = Date.now() + 90000;
    let plan = null;
    while(true){
      await new Promise(function(rs){ setTimeout(rs, 2000); });
      if(Date.now() >= dl) break;
      const to = Math.min(8000, dl - Date.now());
      if(to <= 0) break;
      let g = null;
      try{ g = await api("/api/global-plan?id="+encodeURIComponent(r.planId),"GET",null,to); }catch(e){ continue; }
      if(g && g.status === "ready"){ plan = g; break; }
    }
    if(!plan){ pa.innerHTML = "<p class='warn'>未確認です。しばらくして「反映前プレビュー」で再取得してください。</p>"; return; }
    renderGlobalPlan(plan);
    try{ lastGlobalPlan = {id: r.planId, names: sel.slice()}; }catch(e){ lastGlobalPlan = null; }
    try{ updateGlobalSyncApplyButton(); }catch(e2){}
    try{
      const ph = document.createElement("p"); ph.className = "muted";
      ph.textContent = "プランID: " + String(r.planId).slice(0, 12) + "（選択を変えず「プレビューを適用」でこのプランを適用）";
      pa.appendChild(ph);
    }catch(e2){}
  }catch(e){ pa.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; try{ lastGlobalPlan = null; }catch(e2){} try{ updateGlobalSyncApplyButton(); }catch(e3){} }
  finally{ try{ b.disabled = false; }catch(e3){} try{ safeFocus(b); }catch(e4){} }
};
document.getElementById("btnGlobalContent").onclick = async function(){
  const pre = document.getElementById("globalContentPre"); pre.textContent = "取得中";
  try{
    const g = await api("/api/global-content","GET");
    let h = "配置元: " + (g.homeBase || "-") + "\n";
    (g.files||[]).forEach(function(f){
      h += "--- " + f.target + " (" + f.path + ") ---\n";
      if(!f.exists){ h += "(ファイルなし)\n"; return; }
      h += (f.head || "") + "\n";
    });
    pre.textContent = h;
  }catch(e){ pre.textContent = "取得失敗: "+e.message; }
};
document.getElementById("btnGlobalLogs").onclick = async function(){
  const pre = document.getElementById("globalLogPre"); pre.textContent = "取得中";
  try{
    const g = await api("/api/global-logs","GET");
    pre.textContent = g.tail || "ログがありません。";
  }catch(e){ pre.textContent = "取得失敗: "+e.message; }
};
document.getElementById("btnGlobalTargets").onclick = async function(){
  const b = document.getElementById("btnGlobalTargets"); b.disabled = true;
  try{
    const tg = [];
    if(document.getElementById("ckTCodex").checked) tg.push("codexcli");
    if(document.getElementById("ckTOpenCode").checked) tg.push("opencode");
    const okGo = await showConfirm("対象の変更", "配る対象を「"+tg.join("・")+"」に変更します。よろしいですか。", "変更する", "やめる");
    if(!okGo){ return; }
    await api("/api/global-targets-set","POST",{targets:tg, confirm:true});
    globalTargetsDirty = false;
    setMsg("msgGlobalTargets", "対象を保存しました。", true);
    await refreshGlobal();
  }catch(e){ setMsg("msgGlobalTargets", e.message, false); }
  finally{ try{ b.disabled = false; }catch(e2){} try{ safeFocus(b); }catch(e3){} }
};
document.getElementById("btnGlobalIntervalGet").onclick = async function(){
  try{
    const r = await api("/api/global-interval-get","GET");
    document.getElementById("numGlobalInterval").value = r.minutes;
    setMsg("msgGlobalInterval", "現在の間隔："+r.minutes+"分（Global）", true);
  }catch(e){ setMsg("msgGlobalInterval", e.message, false); }
};
document.getElementById("btnGlobalIntervalSet").onclick = async function(){
  const m = parseInt(document.getElementById("numGlobalInterval").value, 10);
  const okGo = await showConfirm("間隔の変更", "Global同期の間隔を"+m+"分に変更します（Projectは不変）。よろしいですか。", "変更する", "やめる");
  if(!okGo) return;
  try{
    await api("/api/global-interval-set","POST",{minutes:m, confirm:true});
    globalIntervalDirty = false;
    setMsg("msgGlobalInterval", "間隔を変更しました："+m+"分", true);
  }catch(e){ setMsg("msgGlobalInterval", e.message, false); }
};
document.getElementById("btnGlobalEnabled").onclick = async function(){
  const b = document.getElementById("btnGlobalEnabled"); b.disabled = true;
  try{
    const cur = await api("/api/global-enabled-get","GET");
    const next = !(cur.enabled);
    const okGo = await showConfirm("有効/無効の切替", next ? "Global自動同期を有効にします。よろしいですか。" : "Global自動同期を休止します（裏の実行なし）。よろしいですか。", "切り替える", "やめる");
    if(!okGo){ return; }
    await api("/api/global-enabled-set","POST",{enabled:next});
    setMsg("msgGlobalInterval", next ? "有効にしました。" : "休止しました。", true);
    await refreshGlobal();
  }catch(e){ setMsg("msgGlobalInterval", e.message, false); }
  finally{ try{ b.disabled = false; }catch(e2){} try{ safeFocus(b); }catch(e3){} }
};
var globalRestoreConfirms = {};
async function globalBackupDiff(id){
  const da = document.getElementById("globalBackupDiffArea"); da.innerHTML = "<p class='muted'>差分取得中</p>";
  try{
    const d = await api("/api/global-backup-diff","POST",{backupId:id});
    try{ if(d && d.confirmId) globalRestoreConfirms[id] = d.confirmId; }catch(e2){}
    da.innerHTML = "";
    const h = document.createElement("p"); h.className = "muted";
    h.textContent = "対象: " + (d.id || "") + (d.same ? "（差分なし）" : "（差分あり）") + (d.truncated ? "（一部省略）" : "");
    da.appendChild(h);
    if((d.lines || []).length){
      const pre = document.createElement("pre");
      const frag = document.createDocumentFragment();
      (d.lines || []).forEach(function(l){
        const sp = document.createElement("span");
        sp.className = (l.t === "+") ? "diff-add" : "diff-del";
        sp.textContent = "[" + (l.target || "") + "] " + l.t + " " + l.text + "\n";
        frag.appendChild(sp);
      });
      pre.appendChild(frag);
      da.appendChild(pre);
    }
    return d;
  }catch(err){ da.innerHTML = "<p class='err'>"+esc(err.message)+"</p>"; throw err; }
}
async function globalBackupRestore(id){
  const cid = globalRestoreConfirms[id];
  if(!cid || !/^[0-9a-f]{32}$/.test(cid)){
    setMsg("msgGlobalBackup", "先に差分確認をしてください。確認直後の復元のみ受け付けます。", false);
    return;
  }
  const okGo = await showConfirm("Global復元の確認", "「"+id+"」を復元します。復元前にGlobal自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。よろしいですか。", "復元する", "やめる");
  if(!okGo) return;
  try{
    const r = await api("/api/global-restore","POST",{backupId:id, confirm:true, confirmId:cid});
    try{ delete globalRestoreConfirms[id]; }catch(e2){}
    setMsg("msgGlobalBackup", "復元しました。休止中のため再開は有効化してください。", true);
    await refreshGlobal();
    return r;
  }catch(err){ setMsg("msgGlobalBackup", err.message, false); throw err; }
}
async function loadGlobalBackups(){
  const tb = document.getElementById("globalBackupRows");
  try{
    const b = await api("/api/global-backups","GET");
    tb.innerHTML = "";
    document.getElementById("tblGlobalBackups").hidden = b.backups.length === 0;
    document.getElementById("emptyGlobalBackups").hidden = b.backups.length !== 0;
    b.backups.forEach(function(e){
      const tr = document.createElement("tr");
      var gbid = "";
      try{ gbid = e.id; }catch(e2){}
      try{ tr.dataset.search = (gbid + " " + (e.targets || []).join(" ")).toLowerCase(); }catch(e3){}
      const td0 = document.createElement("td"); const c0 = document.createElement("code"); c0.className="path"; c0.textContent = e.id; td0.appendChild(c0);
      const td1 = document.createElement("td"); td1.textContent = e.createdAt || "-";
      const td2 = document.createElement("td"); td2.textContent = (e.targets || []).join("・");
      const td3 = document.createElement("td");
      const acts = document.createElement("div"); acts.className = "acts";
      const bd = document.createElement("button"); bd.textContent = "差分";
      bd.onclick = function(){ globalBackupDiff(e.id); };
      const br = document.createElement("button"); br.textContent = "復元"; br.className = "danger";
      br.onclick = function(){ globalBackupRestore(e.id); };
      acts.appendChild(bd); acts.appendChild(br); td3.appendChild(acts);
      tr.appendChild(td0); tr.appendChild(td1); tr.appendChild(td2); tr.appendChild(td3);
      tb.appendChild(tr);
    });
    try{ applySearchFilter(); }catch(e2){}
  }catch(e){ setMsg("msgGlobalBackup", e.message, false); }
}
document.getElementById("btnGlobalBackups").onclick = function(){ loadGlobalBackups(); };
showHash();refresh();refreshGlobal();
</script>
</body>
</html>
'@
}
function Send-Json($Ctx, [int]$Code, $Obj) {
  $j = ConvertTo-Json -InputObject $Obj -Depth 6 -Compress
  $b = [System.Text.Encoding]::UTF8.GetBytes($j)
  $r = $Ctx.Response
  $r.StatusCode = $Code; $r.ContentType = 'application/json; charset=utf-8'
  $r.ContentLength64 = $b.Length
  $r.OutputStream.Write($b, 0, $b.Length); $r.OutputStream.Close()
}
function Send-Text($Ctx, [int]$Code, [string]$Text, [string]$Type) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $r = $Ctx.Response
  $r.StatusCode = $Code; $r.ContentType = $Type
  $r.ContentLength64 = $b.Length
  $r.OutputStream.Write($b, 0, $b.Length); $r.OutputStream.Close()
}
function Read-Body([System.Net.HttpListenerRequest]$Req, [int]$MaxBytes = 16384) {
  if ($Req.ContentLength64 -gt $MaxBytes) { throw 'body-too-large' }
  if (-not $Req.HasEntityBody) { return '' }
  $ms = New-Object System.IO.MemoryStream
  $buf = New-Object byte[] 4096
  $total = 0
  while ($true) {
    $n = $Req.InputStream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $total += $n
    if ($total -gt $MaxBytes) { throw 'body-too-large' }
    $ms.Write($buf, 0, $n)
  }
  return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Start-Dashboard {
  $AutoDir = Get-DashboardAutoDir
  $Port = Get-DashboardPort
  # r2: interop pre-compiled before listen (no AddType delay in request path).
  try { Initialize-BrowseOwnerNative } catch {}
  # r4: listen first (port is the start mutex; loser exits). Token/state only after win,
  # so simultaneous first starts cannot overwrite each other's token. Loser cleans nothing.
  $l = New-Object System.Net.HttpListener
  $l.Prefixes.Add("http://127.0.0.1:$Port/")
  try { $l.Start() } catch { Write-Host ("FAIL: listen failed on 127.0.0.1:" + $Port); exit 1 }
  $Token = Get-SessionToken $AutoDir
  try { Write-DashboardState $AutoDir $Port $script:InstanceId } catch { Write-Host ("WARN: state write failed: " + $_.Exception.Message) }
  Write-Host ("Dashboard on http://127.0.0.1:" + $Port)
  $last = Get-Date
  try {
  while ($l.IsListening) {
    $ar = $l.BeginGetContext($null, $null)
    $waited = 0
    # tickは約30秒ごと、所有期限は約150秒、画面poll期限は約120秒。期限切れは要求間・tick・終了時に掃除(正直doc)。
    while (-not $ar.AsyncWaitHandle.WaitOne(1000)) {
      $waited++
      if (($waited % 30) -eq 0) { try { Clear-ExpiredBrowseRequests $AutoDir } catch {} }
      if (((Get-Date) - $last).TotalMinutes -ge 15) { try { $ar.AsyncWaitHandle.Close() } catch {}; $l.Stop(); return }
      if ($waited -gt 3600) { try { $ar.AsyncWaitHandle.Close() } catch {}; $l.Stop(); return }
    }
    try { $ctx = $l.EndGetContext($ar) } catch { try { $ar.AsyncWaitHandle.Close() } catch {}; continue }
    try { $ar.AsyncWaitHandle.Close() } catch {}
    $req0 = $null; $path0 = ''; $method0 = ''
    try { $req0 = $ctx.Request; $path0 = $req0.Url.AbsolutePath; $method0 = $req0.HttpMethod.ToUpperInvariant() } catch {}
    # r3: capture before proc cleanup for browse/start (early capture runs after auth before body;
    # this pre-auth expiry would block up to 2s and let the foreground change). Other paths clean here;
    # browse/start expiry runs inside Start-BrowseRequest after the early capture instead.
    $isBrowseStart0 = (($path0 -ceq '/api/browse/start') -and ($method0 -ceq 'POST'))
    if (-not $isBrowseStart0) { try { Clear-ExpiredBrowseRequests $AutoDir } catch {} }
    $last = Get-Date
    $waited = 0
    try {
      $req = $ctx.Request
      $path = $req.Url.AbsolutePath
      $method = $req.HttpMethod.ToUpperInvariant()
      if (-not (Test-HostValid $req.Headers['Host'] $Port)) { Send-Json $ctx 403 @{ error = 'host 不正のため拒否しました。' }; continue }
      if ($path -eq '/health' -and $method -eq 'GET') { Send-Json $ctx 200 @{ ok = $true; port = $Port; instance = $script:InstanceId; pid = $PID }; continue }
      if ($path -eq '/' -and $method -eq 'GET') {
        $tok = $req.QueryString['token']
        if ($tok -cne $Token) { Send-Text $ctx 403 'token が不正です。管理バッチから開き直してください。' 'text/plain; charset=utf-8'; continue }
        Send-Text $ctx 200 ((Get-PageHtml) -replace '__TOKEN__', $Token) 'text/html; charset=utf-8'
        continue
      }
      if ($path -eq '/api/status' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        Send-Json $ctx 200 (Get-Status $AutoDir $Token); continue
      }
      if ($path -eq '/api/projects' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        Send-Json $ctx 200 @{ projects = @(Get-Registry $AutoDir) }; continue
      }
      if ($path -eq '/api/browse' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $bid = [string]$req.QueryString['id']
        if (-not $bid) { $bid = [string]$req.QueryString['browseId'] }
        if ($bid -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = 'browse id が不正です。' }; continue }
        $br = Get-BrowseResult $AutoDir $bid
        if (-not $br) { Send-Json $ctx 200 @{ status = 'waiting'; browseId = $bid }; continue }
        if ([string]$br.status -ceq 'selected') { Send-Json $ctx 200 @{ status = 'selected'; browseId = $bid; path = [string]$br.path }; continue }
        Send-Json $ctx 200 @{ status = 'cancelled'; browseId = $bid }; continue
      }
      if ($path -eq '/api/project-status' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $regS = @(Get-Registry $AutoDir)
        $stS = Get-MgmtProjectStatus $AutoDir
        $rows = @()
        foreach ($eS in $regS) {
          $nmS = [string]$eS.name
          $srow = $null
          try { if ($stS.projects.PSObject.Properties[$nmS]) { $srow = $stS.projects.$nmS } } catch {}
          $oneRow = @{
            name = $nmS; path = [string]$eS.path; enabled = (Get-MgmtEffectiveEnabled $eS)
            displayName = (Get-MgmtDisplayName $eS)
            lastAttemptAt = ''; lastSuccessAt = ''; result = ''; commonSha = ''; commonCommit = ''; error = ''; backupId = ''
          }
          if ($srow) {
            try { $oneRow.lastAttemptAt = [string]$srow.lastAttemptAt } catch {}
            try { $oneRow.lastSuccessAt = [string]$srow.lastSuccessAt } catch {}
            try { $oneRow.result = [string]$srow.result } catch {}
            try { $oneRow.commonSha = [string]$srow.commonSha } catch {}
            try { $oneRow.commonCommit = [string]$srow.commonCommit } catch {}
            try { $oneRow.error = (Redact-Text ([string]$srow.error) $Token) } catch {}
            try { $oneRow.backupId = [string]$srow.backupId } catch {}
          }
          $rows += $oneRow
        }
        Send-Json $ctx 200 @{ projects = $rows }; continue
      }
      if ($path -eq '/api/backups' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $fn = ''
        try { $fn = [string]$req.QueryString['name'] } catch {}
        Send-Json $ctx 200 @{ backups = @(Get-MgmtBackupList $AutoDir $fn) }; continue
      }
      if ($path -eq '/api/export' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        Send-Json $ctx 200 (Get-MgmtExport $AutoDir); continue
      }
      if ($path -eq '/api/interval-get' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try { Send-Json $ctx 200 @{ minutes = (Get-MgmtProjectInterval) } }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-status' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $ridG = ''
        try { $ridG = [string]$req.QueryString['runId'] } catch {}
        try { Send-Json $ctx 200 (Get-GlobalStatusResponse $AutoDir $Token $ridG) }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-content' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try {
          $homeG = Resolve-GlobalHomeBase
          Send-Json $ctx 200 (Get-GlobalContent $homeG $Token)
        }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-targets-get' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try { Send-Json $ctx 200 (Get-GlobalSettings $AutoDir) }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-logs' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        Send-Json $ctx 200 (Get-GlobalLogTail $AutoDir $Token); continue
      }
      if ($path -eq '/api/global-backups' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        Send-Json $ctx 200 @{ backups = @(Get-GlobalBackupList $AutoDir) }; continue
      }
      if ($path -eq '/api/global-interval-get' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try { Send-Json $ctx 200 @{ minutes = (Get-GlobalInterval) } }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-enabled-get' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try { Send-Json $ctx 200 @{ enabled = (Get-GlobalTaskEnabled) } }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-plan' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $gpid = ''
        try { $gpid = [string]$req.QueryString['id'] } catch {}
        if ($gpid -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = 'plan id が不正です。' }; continue }
        $gplanFile = Join-Path $AutoDir ("dashboard.global-plan-" + $gpid + ".json")
        if ((-not (Test-Contained $gplanFile $AutoDir)) -or (Test-Reparse $gplanFile)) { Send-Json $ctx 400 @{ error = 'plan id が不正です。' }; continue }
        if (Test-Path -LiteralPath $gplanFile -PathType Leaf) {
          try { Assert-GlobalPlanFileSize $gplanFile }
          catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }; continue }
          try {
            $gpl = Get-Content -LiteralPath $gplanFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $gprojs = @()
            foreach ($ge in @($gpl.entries)) {
              $gprojs += @{
                target = [string]$ge.target; path = [string]$ge.path; result = [string]$ge.result
                currentText = (Redact-Text ([string]$ge.currentText) $Token)
                generatedText = (Redact-Text ([string]$ge.generatedText) $Token)
                currentHash = [string]$ge.currentHash; generatedHash = [string]$ge.generatedHash
                error = (Redact-Text ([string]$ge.error) $Token)
              }
            }
            Send-Json $ctx 200 @{ status = 'ready'; planId = $gpid; sourceCommit = [string]$gpl.sourceCommit; targets = @($gpl.targets); createdAt = [string]$gpl.createdAt; entries = $gprojs }
          } catch { Send-Json $ctx 500 @{ error = 'プランを読めませんでした。' } }
          continue
        }
        Send-Json $ctx 200 @{ status = 'waiting'; planId = $gpid }; continue
      }
      if ($path -eq '/api/plan' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $pid0 = ''
        try { $pid0 = [string]$req.QueryString['id'] } catch {}
        if ($pid0 -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = 'plan id が不正です。' }; continue }
        $planFile0 = Join-Path $AutoDir ("dashboard.plan-" + $pid0 + ".json")
        if ((-not (Test-Contained $planFile0 $AutoDir)) -or (Test-Reparse $planFile0)) { Send-Json $ctx 400 @{ error = 'plan id が不正です。' }; continue }
        if (Test-Path -LiteralPath $planFile0 -PathType Leaf) {
          try {
            $pl0 = Get-Content -LiteralPath $planFile0 -Raw -Encoding UTF8 | ConvertFrom-Json
            $projs0 = @()
            foreach ($pp in @($pl0.projects)) {
              $projs0 += @{
                name = [string]$pp.name; path = [string]$pp.path; result = [string]$pp.result
                currentText = (Redact-Text ([string]$pp.currentText) $Token)
                generatedText = (Redact-Text ([string]$pp.generatedText) $Token)
                agentsHash = [string]$pp.agentsHash; localHash = [string]$pp.localHash
                commonSha = [string]$pp.commonSha; commonCommit = [string]$pp.commonCommit
                error = (Redact-Text ([string]$pp.error) $Token)
              }
            }
            Send-Json $ctx 200 @{ status = 'ready'; planId = $pid0; commonSha = [string]$pl0.commonSha; commonCommit = [string]$pl0.commonCommit; createdAt = [string]$pl0.createdAt; projects = $projs0 }
          } catch { Send-Json $ctx 500 @{ error = 'プランを読めませんでした。' } }
          continue
        }
        Send-Json $ctx 200 @{ status = 'waiting'; planId = $pid0 }; continue
      }
      if ($path.StartsWith('/api/')) {
        if ($method -cne 'POST') { Send-Json $ctx 405 @{ error = 'この操作はPOSTのみです。画面のボタンから実行してください。' }; continue }
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        $origin = $req.Headers['Origin']
        if ($origin -and (-not (Test-OriginValid $origin $Port))) { Send-Json $ctx 403 @{ error = 'origin 不正のため拒否しました。' }; continue }
        # r2: capture foreground as early as possible at API reception (before body/cleanup).
        # Server-side only; HTTP body owner is never trusted.
        $earlyBrowseCap = $null
        if ($path -ceq '/api/browse/start') { try { $earlyBrowseCap = Get-BrowseOwnerCapture } catch {} }
        try { $bodyText = Read-Body $req } catch { Send-Json $ctx 413 @{ error = '要求が大きすぎます。' }; continue }
        $body = @{}
        if ($bodyText.Trim() -ne '') {
          try { $body = $bodyText | ConvertFrom-Json } catch { Send-Json $ctx 400 @{ error = 'JSONを解釈できません。' }; continue }
        }
        if ($path -eq '/api/preview') {
          $forceReplace = $false
          try { $fv = $body.forceReplace; if ($fv -is [bool] -and $fv) { $forceReplace = $true } } catch {}
          $v = Get-RegisterPreview $AutoDir ([string]$body.path) $forceReplace
          if (-not $v.ok) { Send-Json $ctx 400 @{ error = $v.error }; continue }
          $id = [System.Guid]::NewGuid().ToString('N')
          $script:Previews[$id] = @{ kind = 'new'; path = $v.path; name = $v.name; agentsHash = $v.agentsHash; localHash = $v.localHash; hasAgents = $v.hasAgents; hasLocal = $v.hasLocal; forceReplace = [bool]$forceReplace; ts = (Get-Date) }
          $v['previewId'] = $id
          Send-Json $ctx 200 $v; continue
        }
        if ($path -eq '/api/register') {
          $id = [string]$body.previewId
          $p = [string]$body.path
          if (($body.confirm -ne $true) -or (-not $id) -or (-not $script:Previews.ContainsKey($id))) {
            Send-Json $ctx 400 @{ error = '先にプレビューで確認してください。' }; continue
          }
          $pv = $script:Previews[$id]
          if ([string]$pv.kind -ceq 'import') {
            if ($body.importConfirm -ne $true) { Send-Json $ctx 400 @{ error = '取込内容の確認チェックを入れてください。' }; continue }
            $pNormI = $null
            try { $pNormI = Get-NormPath ($p.Trim()) } catch { $script:Previews.Remove($id) | Out-Null; Send-Json $ctx 400 @{ error = 'パスを解釈できませんでした。もう一度プレビューしてください。' }; continue }
            if (($pv.path -cne $pNormI) -or (((Get-Date) - $pv.ts).TotalMinutes -gt 10)) {
              $script:Previews.Remove($id) | Out-Null
              Send-Json $ctx 400 @{ error = 'プレビューが古いため、もう一度プレビューしてください。' }; continue
            }
            $ilock = $null
            $iErr = $null
            try { $ilock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch {
              $ei0 = $_.Exception
              while (($ei0 -is [System.Management.Automation.MethodInvocationException]) -and ($ei0.InnerException)) { $ei0 = $ei0.InnerException }
              if ($ei0 -is [System.IO.IOException]) { $iErr = '同期実行中のため、終了後にやり直してください。(busy)' }
              else { $iErr = ('ロック取得に失敗しました: ' + $ei0.Message) }
            }
            if ($iErr) { Send-Json $ctx 409 @{ error = $iErr }; continue }
            $iReg = $null
            try {
              $commonI = ''
              try { $commonI = Get-CommonBody $AutoDir } catch { $commonI = '' }
              $vI = Get-MgmtAgentsImportPreview $AutoDir $p $commonI
              if (-not $vI.ok) { $script:Previews.Remove($id) | Out-Null; Send-Json $ctx 400 @{ error = $vI.error }; continue }
              if (($vI.agentsHash -cne $pv.agentsHash) -or ($vI.localHash -cne $pv.localHash) -or ($vI.path -cne $pv.path) -or ($vI.name -cne $pv.name) -or ($vI.transcription -cne $pv.transcription) -or ($commonI -cne $pv.commonBody)) {
                $script:Previews.Remove($id) | Out-Null
                Send-Json $ctx 400 @{ error = '内容が変化したため、もう一度プレビューしてください。' }; continue
              }
              $iReg = Register-MgmtImport $AutoDir $p $vI.name $true $pv
              $script:Previews.Remove($id) | Out-Null
            } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }; continue }
            finally { if ($ilock) { try { $ilock.Close() } catch {} } }
            if (-not $iReg) { continue }
            $srI = $null
            try { $srI = Start-HiddenSync $AutoDir } catch { Send-Json $ctx 200 @{ ok = $true; name = $iReg.name; backup = $iReg.backup; imported = $true; sync = 'launch-failed' }; continue }
            Send-Json $ctx 200 @{ ok = $true; name = $iReg.name; backup = $iReg.backup; imported = $true; sync = 'started'; syncId = $srI.id; syncAt = $srI.at }
            continue
          }
          $pNorm = $null
          try { $pNorm = Get-NormPath ($p.Trim()) } catch { $script:Previews.Remove($id) | Out-Null; Send-Json $ctx 400 @{ error = 'パスを解釈できませんでした。もう一度プレビューしてください。' }; continue }
          if (($pv.path -cne $pNorm) -or (((Get-Date) - $pv.ts).TotalMinutes -gt 10)) {
            $script:Previews.Remove($id) | Out-Null
            Send-Json $ctx 400 @{ error = 'プレビューが古いため、もう一度プレビューしてください。' }; continue
          }
          $bodyForce = $false
          try { $bf = $body.forceReplace; if ($bf -is [bool] -and $bf) { $bodyForce = $true } } catch {}
          $lockStream = $null
          $regName = $null; $backup = $null; $bdir = $null
          $mutErr = $null; $mutCode = 409
          try {
            try { $lockStream = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch {
              $e0 = $_.Exception
              while (($e0 -is [System.Management.Automation.MethodInvocationException]) -and ($e0.InnerException)) { $e0 = $e0.InnerException }
              if ($e0 -is [System.IO.IOException]) { $mutErr = '同期実行中のため、終了後にやり直してください。(busy)' }
              else { $mutErr = ('ロック取得に失敗しました: ' + $e0.Message) }
            }
            if ($mutErr) { Send-Json $ctx $mutCode @{ error = $mutErr }; continue }
            $v = Get-RegisterPreview $AutoDir $p ([bool]$pv.forceReplace)
            if (-not $v.ok) { $script:Previews.Remove($id) | Out-Null; Send-Json $ctx 400 @{ error = $v.error }; continue }
            if ($pv.hasAgents -and ((-not [bool]$pv.forceReplace) -or (-not $bodyForce))) {
              $script:Previews.Remove($id) | Out-Null
              Send-Json $ctx 400 @{ error = '既存 AGENTS.md の置き換えには同意チェックが必要です。プレビューからやり直してください。' }; continue
            }
            if (($v.hasAgents -ne $pv.hasAgents) -or ($v.hasLocal -ne $pv.hasLocal) -or ($v.agentsHash -cne $pv.agentsHash) -or ($v.localHash -cne $pv.localHash) -or ($v.path -cne $pv.path) -or ($v.name -cne $pv.name) -or ($v.forceReplace -ne $pv.forceReplace)) {
              $script:Previews.Remove($id) | Out-Null
              Send-Json $ctx 400 @{ error = '内容が変化したため、もう一度プレビューしてください。' }; continue
            }
            if ($v.hasAgents) {
              $agentsP = Join-Path $v.path 'AGENTS.md'
              if (Test-Reparse $agentsP) { Send-Json $ctx 400 @{ error = 'AGENTS.md がリンクになっています。実体ファイルに戻してから登録してください。' }; continue }
              $localP = Join-Path $v.path '.rulesync\rules\project-local.md'
              try {
                $bdir = New-MgmtBackupDir $AutoDir $v.name
                $curAgentsHash = Get-FileHashHex $agentsP
                if ($curAgentsHash -cne $pv.agentsHash) { throw 'source changed since preview' }
                Copy-MgmtVerified $agentsP (Join-Path $bdir 'AGENTS.md')
                $backupAgentsHash = Get-FileHashHex (Join-Path $bdir 'AGENTS.md')
                if ($backupAgentsHash -cne $pv.agentsHash) { throw 'backup hash mismatch with consented preview' }
                $localExisted = $false
                if ($v.hasLocal -and (Test-Path -LiteralPath $localP -PathType Leaf) -and (-not (Test-Reparse $localP))) {
                  $curLocalHash = Get-FileHashHex $localP
                  if ($curLocalHash -cne $pv.localHash) { throw 'local source changed since preview' }
                  Copy-MgmtVerified $localP (Join-Path $bdir 'project-local.md')
                  $backupLocalHash = Get-FileHashHex (Join-Path $bdir 'project-local.md')
                  if ($backupLocalHash -cne $pv.localHash) { throw 'local backup hash mismatch' }
                  $localExisted = $true
                }
                $mf = @{ schemaVersion = 1; name = $v.name; displayName = $v.name; path = $v.path; createdAt = ([DateTime]::UtcNow.ToString('o')); agentsPresent = $true; localPresent = $localExisted; agentsHash = $pv.agentsHash; localHash = $pv.localHash; imported = $false }
                Write-MgmtPrivateJson (Join-Path $bdir 'manifest.json') $mf
                # verify manifest agentsHash equals copied backup hash
                $mfRead = Get-Content -LiteralPath (Join-Path $bdir 'manifest.json') -Raw | ConvertFrom-Json
                if ([string]$mfRead.agentsHash -cne $backupAgentsHash) { throw 'manifest hash mismatch' }
                $backup = $bdir
              } catch {
                try { if ($bdir) { Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
                $backup = $null
                Send-Json $ctx 500 @{ error = 'バックアップに失敗したため登録しませんでした。registryは不変です。' }; continue
              }
            }
            try {
              $reg = @(Get-Registry $AutoDir)
              foreach ($e in $reg) {
                if (([string]$e.name) -ceq $v.name) { throw '名前が競合しました。もう一度プレビューしてください。' }
                $dupHit = $false
                try { $dupHit = (Get-NormPath ([string]$e.path)).Equals($v.path, [System.StringComparison]::OrdinalIgnoreCase) } catch { $dupHit = $false }
                if ($dupHit) { throw '既に登録されています。もう一度プレビューしてください。' }
              }
              $reg += [pscustomobject]@{ name = $v.name; path = $v.path }
              Write-RegistryAtomicLocked $AutoDir $reg
              $regName = $v.name
            } catch {
              try {
                $brootF1 = Join-Path $AutoDir 'backups'
                $nb = [System.IO.Path]::GetFullPath($bdir)
                $nr = [System.IO.Path]::GetFullPath($brootF1)
                if ($bdir -and $nb.StartsWith($nr + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $bdir -PathType Container) -and (-not (Test-Reparse $bdir))) {
                  Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction Stop
                }
              } catch {}
              try { $script:Previews.Remove($id) | Out-Null } catch {}
              Send-Json $ctx 409 @{ error = $_.Exception.Message }; continue
            }
            $script:Previews.Remove($id) | Out-Null
          } finally { if ($lockStream) { try { $lockStream.Close() } catch {} } }
          $sr = $null
          try { $sr = Start-HiddenSync $AutoDir } catch { Send-Json $ctx 200 @{ ok = $true; name = $regName; backup = $backup; sync = 'launch-failed' }; continue }
          Send-Json $ctx 200 @{ ok = $true; name = $regName; backup = $backup; sync = 'started'; syncId = $sr.id; syncAt = $sr.at }
          continue
        }
        if ($path -eq '/api/unregister') {
          $nm = [string]$body.name
          if (-not (Test-SafeName $nm)) { Send-Json $ctx 400 @{ error = '名前が不正です。' }; continue }
          $ulock = $null
          $uErr = $null
          try {
            try { $ulock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch {
              $eu = $_.Exception
              while (($eu -is [System.Management.Automation.MethodInvocationException]) -and ($eu.InnerException)) { $eu = $eu.InnerException }
              if ($eu -is [System.IO.IOException]) { $uErr = '同期実行中のため、終了後にやり直してください。(busy)' }
              else { $uErr = ('ロック取得に失敗しました: ' + $eu.Message) }
            }
            if ($uErr) { Send-Json $ctx 409 @{ error = $uErr }; continue }
            try {
              $reg = @(Get-Registry $AutoDir)
              $hit = @($reg | Where-Object { [string]$_.name -ceq $nm })
              if ($hit.Count -eq 0) { Send-Json $ctx 404 @{ error = '登録が見つかりません。' }; continue }
              $rest = @($reg | Where-Object { [string]$_.name -cne $nm })
              if ($null -eq $rest) { $rest = @() }
              Write-RegistryAtomicLocked $AutoDir $rest
            } catch { Send-Json $ctx 409 @{ error = $_.Exception.Message }; continue }
          } finally { if ($ulock) { try { $ulock.Close() } catch {} } }
          Send-Json $ctx 200 @{ ok = $true }; continue
        }
        if ($path -eq '/api/sync') {
          # r5: pre-busy only stays as 409 conflict. Post-launch race is reported
          # as skipped via the runID-bound result file (Watch -ReportSkip), not 409.
          if (Test-SyncLocked $AutoDir) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
          $selNames = @()
          try { if ($body.projectNames) { $selNames = @($body.projectNames | ForEach-Object { [string]$_ }) } } catch {}
          $planIdS = ''
          try { if ($body.planId) { $planIdS = ([string]$body.planId).Trim() } } catch {}
          $sr2 = $null
          try {
            try { Clear-OldRequestFiles $AutoDir } catch {}
            if ($planIdS -ne '') {
              if ($planIdS -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = 'plan id が不正です。' }; continue }
              $planFileS = Join-Path $AutoDir ("dashboard.plan-" + $planIdS + ".json")
              if ((-not (Test-Contained $planFileS $AutoDir)) -or (-not (Test-Path -LiteralPath $planFileS -PathType Leaf)) -or (Test-Reparse $planFileS)) { Send-Json $ctx 400 @{ error = 'プランが見つかりません。反映前差分から作り直してください。' }; continue }
              if (((Get-Date) - (Get-Item -LiteralPath $planFileS).LastWriteTime).TotalMinutes -gt 120) { Send-Json $ctx 400 @{ error = 'プランが古いため適用できません。反映前差分から作り直してください。' }; continue }
              try { $planS = Get-Content -LiteralPath $planFileS -Raw -Encoding UTF8 | ConvertFrom-Json }
              catch { Send-Json $ctx 400 @{ error = 'プランを読めませんでした。' }; continue }
              $liveS = $null
              try { $liveS = Get-MgmtPlanLive $AutoDir } catch { Send-Json $ctx 500 @{ error = '現在値を取得できませんでした。' }; continue }
              $mchkS = Test-MgmtPlanMatch $planS $liveS $selNames
              if (-not $mchkS.ok) { Send-Json $ctx 400 @{ error = $mchkS.error }; continue }
              $sr2 = Start-HiddenSync $AutoDir $selNames $false '' $planIdS
            }
            else {
              $sr2 = Start-HiddenSync $AutoDir $selNames
            }
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }; continue }
          $respS = @{ ok = $true; sync = 'started'; syncId = $sr2.id; syncAt = $sr2.at }
          if ($planIdS -ne '') { $respS.planId = $planIdS }
          Send-Json $ctx 200 $respS; continue
        }
        if ($path -eq '/api/browse/start') {
          $hint = ''
          try { $hint = [string]$body.hint } catch {}
          if (-not $hint) { try { $hint = [string]$body.path } catch {} }
          # Trust boundary: owner is server-captured only (early API capture), never from request JSON.
          try { $br0 = Start-BrowseRequest $AutoDir $hint $earlyBrowseCap }
          catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }; continue }
          Send-Json $ctx 200 @{ ok = $true; browseId = $br0.browseId }; continue
        }
        if ($path -eq '/api/browse/cancel') {
          $bid2 = ''
          try { $bid2 = [string]$body.browseId } catch {}
          if (-not $bid2) { try { $bid2 = [string]$body.id } catch {} }
          if ($bid2 -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = 'browse id が不正です。' }; continue }
          try { $bc = Write-BrowseCancelled $AutoDir $bid2 }
          catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }; continue }
          Send-Json $ctx 200 @{ ok = $true; status = [string]$bc.status; browseId = $bid2 }; continue
        }
        if ($path -eq '/api/preview-batch') {
          $paths = @()
          try { if ($body.paths) { $paths = @($body.paths | ForEach-Object { [string]$_ }) } } catch {}
          if (($paths.Count -lt 1) -or ($paths.Count -gt 20)) { Send-Json $ctx 400 @{ error = 'パスは1〜20件で指定してください。' }; continue }
          $results = @()
          $reserved0 = @()
          $regSnap0 = @()
          try { $regSnap0 = @(Get-Registry $AutoDir) } catch { $regSnap0 = @() }
          foreach ($bp0 in $paths) {
            try {
              $v0 = Get-RegisterPreview $AutoDir $bp0
              if (-not $v0.ok) { $results += @{ ok = $false; path = $bp0; error = $v0.error }; continue }
              # Reserve internal names across the batch: same-basename paths
              # get deterministic unique names (Repo, Repo-2, ...) using the
              # existing naming rule over registry + already-reserved names.
              $assigned0 = [string]$v0.name
              $taken0 = @(@($regSnap0 | ForEach-Object { [string]$_.name }) + @($reserved0 | ForEach-Object { [string]$_.name }))
              if ($taken0 -ccontains $assigned0) {
                $combined0 = @(@($regSnap0) + @($reserved0 | ForEach-Object { [pscustomobject]@{ name = [string]$_.name } }))
                $assigned0 = Suggest-SafeName ([string]$v0.path) $combined0
                $v0.name = $assigned0
              }
              $reserved0 += @{ name = $assigned0 }
              $id0 = [System.Guid]::NewGuid().ToString('N')
              $script:Previews[$id0] = @{ kind = 'new'; path = $v0.path; name = $assigned0; agentsHash = $v0.agentsHash; localHash = $v0.localHash; hasAgents = $v0.hasAgents; hasLocal = $v0.hasLocal; ts = (Get-Date) }
              $v0['previewId'] = $id0
              $results += $v0
            } catch { $results += @{ ok = $false; path = $bp0; error = $_.Exception.Message } }
          }
          Send-Json $ctx 200 @{ results = $results }; continue
        }
        if ($path -eq '/api/register-batch') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '先にプレビューで確認してください。' }; continue }
          $items = @()
          try { if ($body.items) { $items = @($body.items) } } catch {}
          if (($items.Count -lt 1) -or ($items.Count -gt 20)) { Send-Json $ctx 400 @{ error = '登録項目は1〜20件で指定してください。' }; continue }
          $block = $null
          try { $block = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $eb = $_.Exception
            while (($eb -is [System.Management.Automation.MethodInvocationException]) -and ($eb.InnerException)) { $eb = $eb.InnerException }
            if ($eb -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $eb.Message) }; continue
          }
          $doneNames = @()
          try {
            # Validate every item first; a single response and a single publish.
            # A mixed batch is refused as a whole: nothing is registered and no
            # preview is consumed, so fixing the bad item and retrying works.
            $toAdd = @()
            $firstErr = $null
            foreach ($it0 in $items) {
              $id0 = [string]$it0.previewId
              $p0 = [string]$it0.path
              if ((-not $id0) -or (-not $script:Previews.ContainsKey($id0))) { $firstErr = '先にプレビューで確認してください。'; break }
              $pv0 = $script:Previews[$id0]
              if ([string]$pv0.kind -cne 'new') { $firstErr = '一括登録は新規のみです。取込は個別に行ってください。'; break }
              $pNorm0 = $null
              try { $pNorm0 = Get-NormPath ($p0.Trim()) } catch { $firstErr = 'パスを解釈できませんでした。もう一度プレビューしてください。'; break }
              if (($pv0.path -cne $pNorm0) -or (((Get-Date) - $pv0.ts).TotalMinutes -gt 10)) {
                $firstErr = 'プレビューが古いため、もう一度プレビューしてください。'; break
              }
              $v0 = Get-RegisterPreview $AutoDir $p0
              if (-not $v0.ok) { $firstErr = $v0.error; break }
              # Content/path change detection only: the committed name is the
              # exact reserved preview name (never regenerated here), and the
              # commit loop below validates it is still free.
              if (($v0.hasAgents -ne $pv0.hasAgents) -or ($v0.hasLocal -ne $pv0.hasLocal) -or ($v0.agentsHash -cne $pv0.agentsHash) -or ($v0.localHash -cne $pv0.localHash) -or ($v0.path -cne $pv0.path)) {
                $firstErr = '内容が変化したため、もう一度プレビューしてください。'; break
              }
              if (-not (Test-SafeName ([string]$pv0.name))) { $firstErr = 'プレビュー名が不正です。もう一度プレビューしてください。'; break }
              if ($v0.hasAgents) { $firstErr = '既存 AGENTS.md があるため一括登録できません。個別に取り込んでください。'; break }
              $toAdd += @{ pv = $pv0; id = $id0 }
            }
            if ($firstErr) { Send-Json $ctx 400 @{ error = $firstErr }; continue }
            try {
              $reg0 = @(Get-Registry $AutoDir)
              foreach ($t0 in $toAdd) {
                foreach ($e0 in $reg0) {
                  if (([string]$e0.name) -ceq ([string]$t0.pv.name)) { throw '名前が競合しました。もう一度プレビューしてください。' }
                  $dh0 = $false
                  try { $dh0 = (Get-NormPath ([string]$e0.path)).Equals([string]$t0.pv.path, [System.StringComparison]::OrdinalIgnoreCase) } catch { $dh0 = $false }
                  if ($dh0) { throw '既に登録されています。もう一度プレビューしてください。' }
                }
                $reg0 += [pscustomobject]@{ name = [string]$t0.pv.name; path = [string]$t0.pv.path }
              }
              Write-RegistryAtomicLocked $AutoDir $reg0
              foreach ($t0 in $toAdd) { $script:Previews.Remove([string]$t0.id) | Out-Null; $doneNames += [string]$t0.pv.name }
            } catch { Send-Json $ctx 409 @{ error = $_.Exception.Message }; continue }
          } finally { if ($block) { try { $block.Close() } catch {} } }
          $srB = $null
          try { $srB = Start-HiddenSync $AutoDir } catch { Send-Json $ctx 200 @{ ok = $true; registered = $doneNames; sync = 'launch-failed' }; continue }
          Send-Json $ctx 200 @{ ok = $true; registered = $doneNames; sync = 'started'; syncId = $srB.id; syncAt = $srB.at }
          continue
        }
        if ($path -eq '/api/import-preview') {
          $common0 = $null
          try { $common0 = Get-CommonBodyStrict $AutoDir } catch { Send-Json $ctx 400 @{ error = '共通ルールを確認できませんでした。' }; continue }
          $vI = Get-MgmtAgentsImportPreview $AutoDir ([string]$body.path) $common0
          if (-not $vI.ok) { Send-Json $ctx 400 @{ error = $vI.error }; continue }
          $idI = [System.Guid]::NewGuid().ToString('N')
          # Pin the approved transcription and its common-body dependency so a
          # later common change cannot be transcribed without fresh preview.
          $script:Previews[$idI] = @{ kind = 'import'; path = $vI.path; name = $vI.name; agentsHash = $vI.agentsHash; localHash = $vI.localHash; hasLocal = $vI.hasLocal; transcription = $vI.transcription; commonBody = $common0; ts = (Get-Date) }
          $vI['previewId'] = $idI
          Send-Json $ctx 200 $vI; continue
        }
        if ($path -eq '/api/rename') {
          $mlock = $null
          try { $mlock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $em = $_.Exception
            while (($em -is [System.Management.Automation.MethodInvocationException]) -and ($em.InnerException)) { $em = $em.InnerException }
            if ($em -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $em.Message) }; continue
          }
          try {
            $rr = Rename-MgmtProject $AutoDir ([string]$body.oldName) ([string]$body.newName)
            Send-Json $ctx 200 $rr
          } catch {
            $em2 = $_.Exception.Message
            if ($em2.Contains('見つかりません')) { Send-Json $ctx 404 @{ error = $em2 } }
            else { Send-Json $ctx 400 @{ error = $em2 } }
          } finally { if ($mlock) { try { $mlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/enabled') {
          $elock = $null
          try { $elock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $ee = $_.Exception
            while (($ee -is [System.Management.Automation.MethodInvocationException]) -and ($ee.InnerException)) { $ee = $ee.InnerException }
            if ($ee -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $ee.Message) }; continue
          }
          try {
            if (-not (Test-MgmtHasField $body 'enabled')) { Send-Json $ctx 400 @{ error = 'enabled は true/false で指定してください。' }; continue }
            $en0 = $false
            try { $en0 = [bool](Get-MgmtField $body 'enabled') } catch { Send-Json $ctx 400 @{ error = 'enabled は true/false で指定してください。' }; continue }
            $er0 = Set-MgmtEnabled $AutoDir ([string]$body.name) $en0
            Send-Json $ctx 200 $er0
          } catch {
            $em3 = $_.Exception.Message
            if ($em3.Contains('見つかりません')) { Send-Json $ctx 404 @{ error = $em3 } }
            else { Send-Json $ctx 400 @{ error = $em3 } }
          } finally { if ($elock) { try { $elock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/move') {
          $vlock = $null
          try { $vlock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $ev = $_.Exception
            while (($ev -is [System.Management.Automation.MethodInvocationException]) -and ($ev.InnerException)) { $ev = $ev.InnerException }
            if ($ev -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $ev.Message) }; continue
          }
          try {
            $mv0 = Move-MgmtProjectPath $AutoDir ([string]$body.name) ([string]$body.newPath)
            Send-Json $ctx 200 $mv0
          } catch {
            $em4 = $_.Exception.Message
            if ($em4.Contains('見つかりません')) { Send-Json $ctx 404 @{ error = $em4 } }
            else { Send-Json $ctx 400 @{ error = $em4 } }
          } finally { if ($vlock) { try { $vlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/plan-start') {
          if (Test-SyncLocked $AutoDir) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
          $selP = @()
          try { if ($body.projectNames) { $selP = @($body.projectNames | ForEach-Object { [string]$_ }) } } catch {}
          $planId = [System.Guid]::NewGuid().ToString('N')
          $planFile = Join-Path $AutoDir ("dashboard.plan-" + $planId + ".json")
          if (-not (Test-Contained $planFile $AutoDir)) { Send-Json $ctx 500 @{ error = 'プラン先を確認できませんでした。' }; continue }
          $srP = $null
          try {
            try { Clear-OldRequestFiles $AutoDir } catch {}
            $srP = Start-HiddenSync $AutoDir $selP $true $planFile
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }; continue }
          Send-Json $ctx 200 @{ ok = $true; planId = $planId; syncId = $srP.id; syncAt = $srP.at }; continue
        }
        if ($path -eq '/api/backup-diff') {
          try {
            $bd0 = Get-MgmtBackupDiff $AutoDir ([string]$body.backupId)
            $bd0.lines = @($bd0.lines | ForEach-Object { @{ t = [string]$_.t; text = (Redact-Text ([string]$_.text) $Token) } })
            $bd0.localLines = @($bd0.localLines | ForEach-Object { @{ t = [string]$_.t; text = (Redact-Text ([string]$_.text) $Token) } })
            Send-Json $ctx 200 $bd0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message } }
          continue
        }
        if ($path -eq '/api/restore') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '確認チェックを入れてください。' }; continue }
          $rlock = $null
          try { $rlock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $erl = $_.Exception
            while (($erl -is [System.Management.Automation.MethodInvocationException]) -and ($erl.InnerException)) { $erl = $erl.InnerException }
            if ($erl -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $erl.Message) }; continue
          }
          try {
            $rs0 = Restore-MgmtBackup $AutoDir ([string]$body.backupId) $true
            Send-Json $ctx 200 $rs0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($rlock) { try { $rlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/localrule-get') {
          try {
            $lg0 = Get-MgmtLocalRule $AutoDir ([string]$body.name)
            $lg0.redacted = $false
            try {
              $redT = Redact-Text ([string]$lg0.text) $Token
              $lg0.redacted = ($redT -cne [string]$lg0.text)
              $lg0.text = $redT
            } catch {}
            Send-Json $ctx 200 $lg0
          } catch {
            $em5 = $_.Exception.Message
            if ($em5.Contains('見つかりません')) { Send-Json $ctx 404 @{ error = $em5 } }
            elseif ($em5.Contains('ありません')) { Send-Json $ctx 404 @{ error = $em5 } }
            else { Send-Json $ctx 400 @{ error = $em5 } }
          }
          continue
        }
        if ($path -eq '/api/localrule-save') {
          $llock = $null
          try { $llock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $ell = $_.Exception
            while (($ell -is [System.Management.Automation.MethodInvocationException]) -and ($ell.InnerException)) { $ell = $ell.InnerException }
            if ($ell -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $ell.Message) }; continue
          }
          try {
            # Masked display must never be saved as original: when redaction
            # changed anything, only a byte-identical save is allowed.
            $curT = $null
            try { $curT = [string](Get-MgmtLocalRule $AutoDir ([string]$body.name)).text } catch { $curT = $null }
            if ($null -ne $curT) {
              $redT2 = Redact-Text $curT $Token
              if (($redT2 -cne $curT) -and ([string]$body.text -cne $curT)) {
                Send-Json $ctx 409 @{ error = '伏字表示中の内容はそのまま保存できません。原本が変化した可能性があります。再取得してください。' }
                continue
              }
            }
            $ls0 = Save-MgmtLocalRule $AutoDir ([string]$body.name) ([string]$body.text) ([string]$body.expectedHash)
            Send-Json $ctx 200 $ls0
          } catch {
            $em6 = $_.Exception.Message
            if ($em6.Contains('変化した')) { Send-Json $ctx 409 @{ error = $em6 } }
            elseif ($em6.Contains('見つかりません') -or $em6.Contains('ありません')) { Send-Json $ctx 404 @{ error = $em6 } }
            else { Send-Json $ctx 400 @{ error = $em6 } }
          } finally { if ($llock) { try { $llock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/check') {
          try {
            $common1 = ''
            try { $common1 = Get-CommonBody $AutoDir } catch { $common1 = '' }
            $targets = @()
            if ($body.name -and ([string]$body.name).Trim() -ne '') { $targets = @([string]$body.name) }
            else { $targets = @((@(Get-Registry $AutoDir) | ForEach-Object { [string]$_.name })) }
            if ($targets.Count -gt 20) { $targets = @($targets | Select-Object -First 20) }
            $dups1 = @()
            $cons1 = @()
            foreach ($tn in $targets) {
              $lb = ''
              try { $lb = Get-BodyWithoutFrontmatter ([string](Get-MgmtLocalRule $AutoDir $tn).text) } catch { continue }
              foreach ($dd in @(Get-MgmtDupCandidates $common1 $lb)) { $dups1 += @{ project = $tn; kind = [string]$dd.kind; line = [string]$dd.line } }
              foreach ($cc in @(Get-MgmtContradictionCandidates $common1 $lb)) { $cons1 += @{ project = $tn; kind = [string]$cc.kind; common = [string]$cc.common; local = [string]$cc.local } }
              if (($dups1.Count + $cons1.Count) -ge 100) { break }
            }
            Send-Json $ctx 200 @{ duplicates = $dups1; contradictions = $cons1; note = 'いずれも候補であり、断定ではありません。内容を確認して判断してください。' }
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message } }
          continue
        }
        if ($path -eq '/api/registry-import-preview') {
          try { Send-Json $ctx 200 (Get-MgmtImportPreview $AutoDir $body.data) }
          catch { Send-Json $ctx 400 @{ error = $_.Exception.Message } }
          continue
        }
        if ($path -eq '/api/import') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '確認チェックを入れてください。' }; continue }
          $ilock = $null
          try { $ilock = [System.IO.File]::Open((Join-Path $AutoDir 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
          catch {
            $ei = $_.Exception
            while (($ei -is [System.Management.Automation.MethodInvocationException]) -and ($ei.InnerException)) { $ei = $ei.InnerException }
            if ($ei -is [System.IO.IOException]) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
            Send-Json $ctx 500 @{ error = ('ロック取得に失敗しました: ' + $ei.Message) }; continue
          }
          try {
            $im0 = Import-MgmtRegistry $AutoDir $body.data $true
            Send-Json $ctx 200 $im0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($ilock) { try { $ilock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/interval-set') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '確認チェックを入れてください。' }; continue }
          $mins = 0
          try { $mins = [int]$body.minutes } catch { Send-Json $ctx 400 @{ error = '間隔は5〜1440分の整数で指定してください。' }; continue }
          if (-not (Test-MgmtIntervalValid $mins)) { Send-Json $ctx 400 @{ error = '間隔は5〜1440分で指定してください。' }; continue }
          try {
            $is0 = Set-MgmtProjectInterval (Get-MgmtProjectTaskName) $mins
            Send-Json $ctx 200 $is0
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
          continue
        }
        if ($path -eq '/api/global-sync') {
          # Pre-busy only stays 409. Post-launch races surface as skipped via
          # the runID-bound result file, never as success.
          if (Test-GlobalSyncLocked $AutoDir) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
          $selNames = @()
          try { if ($body.targetNames) { $selNames = @($body.targetNames | ForEach-Object { [string]$_ }) } } catch {}
          if (($selNames.Count -gt 0) -and (-not (Test-GlobalTargetsValid $selNames))) { Send-Json $ctx 400 @{ error = '対象は Codex/OpenCode から1つ以上選んでください。' }; continue }
          $planIdS = ''
          try { if ($body.planId) { $planIdS = ([string]$body.planId).Trim() } } catch {}
          $sr2 = $null
          try {
            try { Clear-OldGlobalRequestFiles $AutoDir } catch {}
            if ($planIdS -ne '') {
              if ($planIdS -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = 'plan id が不正です。' }; continue }
              $planFileS = Join-Path $AutoDir ("dashboard.global-plan-" + $planIdS + ".json")
              if ((-not (Test-Contained $planFileS $AutoDir)) -or (-not (Test-Path -LiteralPath $planFileS -PathType Leaf)) -or (Test-Reparse $planFileS)) { Send-Json $ctx 400 @{ error = 'プランが見つかりません。反映前プレビューから作り直してください。' }; continue }
              if (((Get-Date) - (Get-Item -LiteralPath $planFileS).LastWriteTime).TotalMinutes -gt 120) { Send-Json $ctx 400 @{ error = 'プランが古いため適用できません。反映前プレビューから作り直してください。' }; continue }
              try { Assert-GlobalPlanFileSize $planFileS }
              catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }; continue }
              try { $planS = Get-Content -LiteralPath $planFileS -Raw -Encoding UTF8 | ConvertFrom-Json }
              catch { Send-Json $ctx 400 @{ error = 'プランを読めませんでした。' }; continue }
              $homeS = ''
              try { $homeS = Resolve-GlobalHomeBase } catch { Send-Json $ctx 500 @{ error = '配置先を確認できませんでした。' }; continue }
              $liveS = $null
              $namesS = $selNames
              if ($namesS.Count -eq 0) { try { $namesS = @($planS.targets | ForEach-Object { [string]$_ }) } catch { $namesS = @() } }
              try { $liveS = Get-GlobalPlanLive $AutoDir $homeS $namesS } catch { Send-Json $ctx 500 @{ error = '現在値を取得できませんでした。' }; continue }
              $mchkS = Test-GlobalPlanMatch $planS $liveS $namesS
              if (-not $mchkS.ok) { Send-Json $ctx 400 @{ error = $mchkS.error }; continue }
              $sr2 = Start-HiddenGlobalSync $AutoDir $namesS $false $planIdS
            }
            else {
              $sr2 = Start-HiddenGlobalSync $AutoDir $selNames
            }
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }; continue }
          $respS = @{ ok = $true; sync = 'started'; syncId = $sr2.id; syncAt = $sr2.at }
          if ($planIdS -ne '') { $respS.planId = $planIdS }
          Send-Json $ctx 200 $respS; continue
        }
        if ($path -eq '/api/global-preview-start') {
          if (Test-GlobalSyncLocked $AutoDir) { Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }; continue }
          $selP = @()
          try { if ($body.targetNames) { $selP = @($body.targetNames | ForEach-Object { [string]$_ }) } } catch {}
          if (($selP.Count -gt 0) -and (-not (Test-GlobalTargetsValid $selP))) { Send-Json $ctx 400 @{ error = '対象は Codex/OpenCode から1つ以上選んでください。' }; continue }
          $gplanId = [System.Guid]::NewGuid().ToString('N')
          $srP = $null
          try {
            try { Clear-OldGlobalRequestFiles $AutoDir } catch {}
            $srP = Start-HiddenGlobalSync $AutoDir $selP $true $gplanId
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }; continue }
          Send-Json $ctx 200 @{ ok = $true; planId = $gplanId; syncId = $srP.id; syncAt = $srP.at }; continue
        }
        if ($path -eq '/api/global-targets-set') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '確認チェックを入れてください。' }; continue }
          $tgNew = @()
          try { if ($body.targets) { $tgNew = @($body.targets | ForEach-Object { [string]$_ }) } } catch {}
          if (-not (Test-GlobalTargetsValid $tgNew)) { Send-Json $ctx 400 @{ error = '対象は Codex/OpenCode から1つ以上選んでください。' }; continue }
          $tlock = $null
          try { $tlock = Open-GlobalSyncLock $AutoDir }
          catch {
            $emT = $_.Exception.Message
            if ($emT.Contains('(busy)')) { Send-Json $ctx 409 @{ error = $emT }; continue }
            Send-Json $ctx 500 @{ error = $emT }; continue
          }
          try {
            $tr0 = Set-GlobalTargets $AutoDir $tgNew
            Send-Json $ctx 200 $tr0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($tlock) { try { $tlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/global-interval-set') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '確認チェックを入れてください。' }; continue }
          $gmins = 0
          try { $gmins = [int]$body.minutes } catch { Send-Json $ctx 400 @{ error = '間隔は5〜1440分の整数で指定してください。' }; continue }
          if (-not (Test-GlobalIntervalValid $gmins)) { Send-Json $ctx 400 @{ error = '間隔は5〜1440分で指定してください。' }; continue }
          $gilock = $null
          try { $gilock = Open-GlobalSyncLock $AutoDir }
          catch {
            $emGI = $_.Exception.Message
            if ($emGI.Contains('(busy)')) { Send-Json $ctx 409 @{ error = $emGI }; continue }
            Send-Json $ctx 500 @{ error = $emGI }; continue
          }
          try {
            $gi0 = Set-GlobalInterval $gmins
            Send-Json $ctx 200 $gi0
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }
          } finally { if ($gilock) { try { $gilock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/global-enabled-set') {
          # JSON boolean only: PowerShell [bool]'false' is $true, so a string
          # must never enable auto sync. Validated before lock/scheduler touch.
          if (($null -eq $body.PSObject.Properties['enabled']) -or ($body.enabled -isnot [bool])) { Send-Json $ctx 400 @{ error = 'enabled は true/false で指定してください。' }; continue }
          $en0 = [bool]$body.enabled
          $gelock = $null
          try { $gelock = Open-GlobalSyncLock $AutoDir }
          catch {
            $emGE = $_.Exception.Message
            if ($emGE.Contains('(busy)')) { Send-Json $ctx 409 @{ error = $emGE }; continue }
            Send-Json $ctx 500 @{ error = $emGE }; continue
          }
          try {
            $ge0 = Set-GlobalTaskEnabled $en0
            Send-Json $ctx 200 $ge0
          } catch { Send-Json $ctx 500 @{ error = $_.Exception.Message }
          } finally { if ($gelock) { try { $gelock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/global-backup-diff') {
          $dlock = $null
          try { $dlock = Open-GlobalSyncLock $AutoDir }
          catch {
            $emD = $_.Exception.Message
            if ($emD.Contains('(busy)')) { Send-Json $ctx 409 @{ error = $emD }; continue }
            Send-Json $ctx 500 @{ error = $emD }; continue
          }
          try {
            $homeD = Resolve-GlobalHomeBase
            $bd0 = Get-GlobalBackupDiff $AutoDir ([string]$body.backupId) $homeD
            $bd0.lines = @($bd0.lines | ForEach-Object { @{ t = [string]$_.t; text = (Redact-Text ([string]$_.text) $Token); target = [string]$_.target } })
            Send-Json $ctx 200 $bd0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($dlock) { try { $dlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/global-restore') {
          if ($body.confirm -ne $true) { Send-Json $ctx 400 @{ error = '確認チェックを入れてください。' }; continue }
          $cfId = ''
          try { $cfId = [string]$body.confirmId } catch {}
          if ($cfId -cnotmatch '^[0-9a-f]{32}$') { Send-Json $ctx 400 @{ error = '先に差分確認をしてください。確認直後の復元のみ受け付けます。' }; continue }
          $rlock = $null
          try { $rlock = Open-GlobalSyncLock $AutoDir }
          catch {
            $emRL = $_.Exception.Message
            if ($emRL.Contains('(busy)')) { Send-Json $ctx 409 @{ error = $emRL }; continue }
            Send-Json $ctx 500 @{ error = $emRL }; continue
          }
          try {
            $homeR = ''
            try { $homeR = Resolve-GlobalHomeBase } catch { Send-Json $ctx 500 @{ error = '配置先を確認できませんでした。' }; continue }
            $rs0 = Restore-GlobalBackup $AutoDir ([string]$body.backupId) $true $homeR $cfId
            Send-Json $ctx 200 $rs0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($rlock) { try { $rlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/open') {
          $nm2 = ''
          try { $nm2 = [string]$body.name } catch {}
          $full2 = ''
          try { $full2 = Get-RegisteredFolderPath $AutoDir $nm2 }
          catch {
            $em = $_.Exception.Message
            if ($em.Contains('見つかりません')) { Send-Json $ctx 404 @{ error = $em }; continue }
            Send-Json $ctx 400 @{ error = $em }; continue
          }
          # Fixed absolute explorer only. FilePath is never user input; the folder
          # goes through -ArgumentList as data (spaces/meta/Japanese safe). No shell.
          $explorer = Join-Path $env:SystemRoot 'explorer.exe'
          if (-not (Test-Path -LiteralPath $explorer)) { Send-Json $ctx 500 @{ error = 'エクスプローラーが見つかりません。' }; continue }
          try { Start-Process -FilePath $explorer -ArgumentList $full2 | Out-Null }
          catch { Send-Json $ctx 500 @{ error = 'エクスプローラーの起動に失敗しました。' }; continue }
          Send-Json $ctx 200 @{ ok = $true }; continue
        }
        Send-Json $ctx 404 @{ error = 'unknown api' }; continue
      }
      Send-Text $ctx 404 'not found' 'text/plain; charset=utf-8'
    } catch { try { Send-Json $ctx 500 @{ error = '内部エラー。入力を確認してください。' } } catch {} }
  }
  } finally {
    try { foreach ($k in @($script:BrowseProcs.Keys)) { try { Stop-OwnedBrowseProcess $k } catch {} } } catch {}
    try { $l.Stop() } catch {}
  }
}

if ($MyInvocation.InvocationName -ne '.') { Start-Dashboard }
