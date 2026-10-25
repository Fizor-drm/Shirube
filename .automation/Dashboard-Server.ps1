# Dashboard-Server.ps1 - Shirube project registry dashboard (dev source).
# Loopback-only HTTP UI: list / preview-register / unregister / sync-now / last result.
# No new deps: PowerShell 5.1 + .NET HttpListener only. No arbitrary shell/read APIs.
# Registry truth stays projects.json in AutoDir. Never touches AGENTS.md contents
# except backup + head-preview. Mutations cooperate with Sync-ProjectRules.lock
# and write atomically. Dot-sourced by tests (no listen); executed directly listens.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Project-Management.ps1')
. (Join-Path $PSScriptRoot 'Global-Management.ps1')
. (Join-Path $PSScriptRoot 'GitHub-Management.ps1')

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
    if ($ln -cmatch ('^' + $Key + '\s*:[ \t]+true([ \t]+#.*)?[ \t]*$')) { $hits++; continue }
    elseif ($ln -cmatch ('^' + $Key + '\s*:')) { return $false }
    if ($ln -cmatch '^targets\s*:[ \t]+\[(\s*"[a-z0-9][a-z0-9-]*"(?:\s*,\s*"[a-z0-9][a-z0-9-]*")*\s*)\]([ \t]+#.*)?[ \t]*$') {
      $tItems = @([regex]::Matches($Matches[1], '"([a-z0-9][a-z0-9-]*)"') | ForEach-Object { $_.Groups[1].Value })
      if (($tItems -cnotcontains 'codexcli') -or ($tItems -cnotcontains 'opencode')) { return $false }
      if ((@($tItems | Select-Object -Unique)).Count -ne $tItems.Count) { return $false }
      $seenTargets++; if ($seenTargets -gt 1) { return $false }; continue
    }
    elseif ($ln -cmatch '^targets\s*:') { return $false }
    # Only YAML 1.2 escapes: \0 \a \b \t \n \v \f \r \e \  \" \/ \\ \N \_ \L \P,
    # plus \xNN, \uNNNN, \UNNNNNNNN. A bare "\q" or "C:\Users" is refused.
    if ($ln -cmatch '^description\s*:[ \t]+"([^"\\]|\\[0abtnvfre " /\\N_LP]|\\x[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})*"([ \t]+#.*)?[ \t]*$') { $seenDesc++; if ($seenDesc -gt 1) { return $false }; continue }
    elseif ($ln -cmatch '^description\s*:') { return $false }
    return $false
  }
  if ($hits -ne 1) { return $false }
  if ($seenTargets -ne 1) { return $false }
  if ($Key -eq 'localRoot') { foreach ($ln in $lines) { if ($ln -cmatch '^root\s*:') { return $false } } }
  if ($Key -eq 'root') { foreach ($ln in $lines) { if ($ln -cmatch '^localRoot\s*:') { return $false } } }
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
  if (($sel.Count -gt 0) -and (-not (Test-GlobalTargetsValid $sel))) { throw '対象は一覧から1つ以上選んでください。' }
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
  if (-not (Test-GlobalTargetsValid $tg)) { $tg = @(Get-GlobalDefaultTargets) }
  $available = @()
  foreach ($ce in @(Get-GlobalProviderCatalog)) { $available += @{ id = [string]$ce.id; label = [string]$ce.label } }
  $st = Get-GlobalStatus $AutoDir
  $map = @{}
  if ($homeBase -ne '') { try { $map = Get-GlobalContentPaths $homeBase } catch {} }
  $rows = @()
  foreach ($t in $tg) {
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
  # One scheduled-task read serves both interval and enabled state.
  $iv = $null
  $en = $null
  try {
    $t0 = (Get-GlobalScheduledTask).task
    $en = ([string]$t0.State -cne 'Disabled')
    foreach ($tr in @($t0.Triggers)) {
      if ($tr.CimClass.CimClassName -ceq 'MSFT_TaskTimeTrigger') {
        $v = Global-ParseInterval ([string]$tr.Repetition.Interval)
        if ($v) { $iv = $v; break }
      }
    }
  } catch {}
  $ghOk = $false
  try {
    $ghCfg = Get-GitHubSettings $AutoDir
    if (([string]$ghCfg.repo -ne '') -and ([string]$ghCfg.branch -ne '')) {
      $ghOk = ((Get-GitHubTokenSource $AutoDir) -ne '')
    }
  } catch { $ghOk = $false }
  return @{
    homeBase = $homeBase; targets = $tg; providers = $rows; available = $available
    running = $sync.running; syncState = $sync.syncState; syncAt = $sync.syncAt; syncId = $sync.syncId
    logName = $sync.logName; logMtime = $sync.logMtime; finalLine = $sync.finalLine; tail = $sync.tail
    resultExit = $sync.resultExit; resultAt = $sync.resultAt
    intervalMinutes = $iv; taskEnabled = $en; githubConfigured = [bool]$ghOk
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

# Vendored rule-editor bundle (CodeMirror 6 + marked + DOMPurify) inlined at the
# head of the page script. Read once and cached; a missing bundle fails closed
# to the plain textarea editor with a localized notice (no CDN, no eval).
$script:RuleEditorVendor = $null
function Get-RuleEditorVendor {
  if ($null -eq $script:RuleEditorVendor) {
    $script:RuleEditorVendor = ''
    $vendorPath = Join-Path $PSScriptRoot 'vendor\rule-editor.bundle.js'
    if (Test-Path -LiteralPath $vendorPath) {
      try { $script:RuleEditorVendor = [System.IO.File]::ReadAllText($vendorPath) } catch { $script:RuleEditorVendor = '' }
    }
  }
  return $script:RuleEditorVendor
}
function Get-PageHtml {
  $html = @'
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
nav a svg,.topnav a svg{flex:none;vertical-align:-2px;margin-right:6px}
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
.summarybar .btnrow button{white-space:normal;padding:6px 9px}
.syncprogress{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin-top:4px;min-width:0}
.syncprogress progress{flex:1 1 100%;min-width:0;height:8px;accent-color:#8fd694}
.syncprogress .muted{margin:0;white-space:normal;overflow-wrap:anywhere;word-break:break-word}
.helper{display:inherit}
.topbar .sub{color:#9a9a9a;font-size:12px}
.lang{font-size:12px;color:#f5f5f5;background:#0a0a0a;border:1px solid #2a2a2a;border-radius:6px;padding:5px 10px;flex:none;width:auto;max-width:140px}
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
.rules-grid{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(0,1fr);gap:14px;margin-top:12px}
#ruleText{width:100%;min-height:340px;background:#0a0a0a;border:1px solid #2c2c2c;color:#fff;border-radius:6px;padding:10px 12px;font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:12px;line-height:1.6;resize:vertical}
#ruleText:disabled{opacity:.5;cursor:not-allowed}
#ruleText:focus{outline:2px solid #f5f5f5;outline-offset:1px}
#ruleText{overflow-wrap:anywhere}
#ruleText.cm-off{display:none}
.rule-modes{display:flex;gap:8px;margin:12px 0 0;flex-wrap:wrap}
.rmode{padding:6px 14px;font-size:12px}
.rmode[aria-pressed="true"]{background:#2563eb;border-color:#2563eb;color:#fff}
.rmode[aria-pressed="true"]:hover{background:#2563eb}
.rule-src,.rule-view{min-width:0}
.rules-grid.solo .rule-src,.rules-grid.solo .rule-view{grid-column:1/-1}
#ruleEditorWrap{min-height:340px;background:#0a0a0a;border:1px solid #2c2c2c;border-radius:6px;overflow:hidden;display:none}
#ruleEditorWrap.cm-on{display:block}
#ruleEditorWrap .cm-editor{background:#0a0a0a;color:#fff}
#ruleEditorWrap .cm-scroller{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:12px;line-height:1.6;overflow-wrap:anywhere}
#ruleEditorWrap .cm-gutters{background:#0a0a0a;border-right:1px solid #2c2c2c;color:#8b949e;flex:none}
#ruleEditorWrap .cm-content{padding:10px 12px}
#ruleEditorWrap .cm-line{padding:0 2px 0 0}
#ruleEditorWrap .rule-md-row{background:#111214;box-shadow:inset 0 1px 0 #1f1f1f,inset 0 -1px 0 #1f1f1f}
#ruleEditorWrap .rule-md-row.rule-md-row-alt{background:#17191c}
#rulePreview{min-height:340px;background:#0a0a0a;border:1px solid #2c2c2c;border-radius:6px;padding:10px 12px;font-size:13px;overflow-wrap:anywhere}
#rulePreview h1,#rulePreview h2,#rulePreview h3,#rulePreview h4,#rulePreview h5,#rulePreview h6{margin:14px 0 8px;color:#fff}
#rulePreview h1{font-size:20px}#rulePreview h2{font-size:17px}#rulePreview h3{font-size:15px}
#rulePreview p,#rulePreview ul,#rulePreview ol{margin:8px 0}
#rulePreview code{background:#1c1c1c;border:1px solid #2c2c2c;border-radius:4px;padding:1px 5px;font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:12px}
#rulePreview pre{background:#0d0d0d;border:1px solid #242424;border-radius:6px;padding:10px;overflow:auto}
#rulePreview pre code{background:none;border:none;padding:0}
#rulePreview table{border-collapse:collapse;margin:8px 0}
#rulePreview th,#rulePreview td{border:1px solid #2c2c2c;padding:6px 9px}
#rulePreview th{background:#181818;color:#fff;font-weight:700}
#rulePreview tbody tr:nth-child(odd){background:#101010}
#rulePreview tbody th[scope=row]{font-weight:700;text-align:left}
#rulePreview a{color:#7ab7ff}
.rpreview-scroll{overflow-x:auto;border-radius:6px}
.rpreview-scroll:focus{outline:2px solid #f5f5f5;outline-offset:1px}
@media(max-width:1000px){.row2,.cols2,.rules-grid{grid-template-columns:1fr}aside{display:none}.mainscroll{padding:20px 16px 32px}.summarybar{padding:8px 16px 6px}}
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
.targetlist{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:0 12px}
.targetlist label.chk{margin-top:6px}
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
/* GitHub integration: topbar button + source settings dialog */
.topbar-right{display:flex;align-items:center;gap:8px;flex:none}
.ghbtn{display:inline-flex;align-items:center;justify-content:center;width:30px;height:30px;padding:0;border-radius:6px;border:1px solid #2a2a2a;background:#0a0a0a;color:#f5f5f5;cursor:pointer;flex:none}
.ghbtn:hover{background:#161616;border-color:#3a3a3a}
.ghbtn:focus-visible{outline:2px solid #4c9aff;outline-offset:2px}
#ghOvl{--gh-surface:#111113;--gh-input-bg:#0a0a0a;--gh-text:#f5f5f5;--gh-muted:#9a9aa3;--gh-border:#2a2a30;--gh-accent:#4c9aff;--gh-accent-hover:#2b7bf0;--gh-accent-soft:rgba(76,154,255,.12);--gh-ok:#8fd694;--gh-err:#f0a3a3;--gh-code-bg:#17171a;--gh-backdrop:rgba(0,0,0,.72);position:fixed;inset:0;background:var(--gh-backdrop);display:flex;align-items:center;justify-content:center;z-index:60;padding:16px;font:14px/1.45 -apple-system,"Segoe UI","Hiragino Sans","Noto Sans JP",sans-serif;color:var(--gh-text)}
#ghOvl[hidden]{display:none}
#ghOvl *{box-sizing:border-box}
#ghOvl .ghbox{width:min(680px,calc(100vw - 32px));max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);overflow:auto;padding:0;border:1px solid var(--gh-border);border-radius:12px;background:var(--gh-surface);color:var(--gh-text);box-shadow:0 16px 48px rgba(0,0,0,.25)}
#ghOvl .gh-head{display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--gh-border)}
#ghOvl .gh-head svg{flex:none}
#ghOvl .gh-head h2{margin:0;font-size:15px;color:var(--gh-text)}
#ghOvl .gh-head p{margin:0;color:var(--gh-muted);font-size:12px}
#ghOvl .ghclose{margin-left:auto;border:0;background:none;color:var(--gh-muted);font-size:20px;line-height:1;padding:4px 8px;border-radius:6px;width:auto;height:auto;font-weight:400;display:inline-flex;align-items:center;justify-content:center;cursor:pointer}
#ghOvl .ghclose:hover{background:var(--gh-code-bg);color:var(--gh-text)}
#ghOvl form{padding:12px 16px;display:grid;gap:8px;margin:0}
#ghOvl .ghfield{margin:0;border:0;padding:0;min-width:0}
#ghOvl .ghfield>label,#ghOvl .ghfield>.ghlabel,#ghOvl #ghCustomWrap>label{display:block;font-weight:600;margin:0 0 2px;color:var(--gh-text);font-size:13px}
#ghOvl .ghfield>.ghlabel{margin-bottom:4px}
#ghOvl .ghfield .ghhint{color:var(--gh-muted);font-size:11.5px;margin:2px 0 0;line-height:1.35}
#ghOvl .ghfield .ghhint.error{color:var(--gh-err)}
#ghOvl .ghsecret{position:relative}
#ghOvl input[type=text],#ghOvl input[type=password]{width:100%;padding:6px 10px;border:1px solid var(--gh-border);border-radius:6px;background:var(--gh-input-bg);color:var(--gh-text);font:inherit;margin:0}
#ghOvl .gh-two{display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:12px}
#ghOvl .ghsecret input{padding-right:40px}
#ghOvl input.mono{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:13px}
#ghOvl input:focus,#ghOvl input:focus-visible,#ghOvl button:focus-visible{outline:2px solid var(--gh-accent);outline-offset:1px}
#ghOvl input[aria-invalid=true]{border-color:var(--gh-err)}
#ghOvl .gheye{position:absolute;top:50%;right:4px;transform:translateY(-50%);width:28px;height:28px;padding:0;display:grid;place-items:center;border:0;border-radius:6px;background:none;color:var(--gh-muted);cursor:pointer}
#ghOvl .gheye:hover{background:var(--gh-code-bg);color:var(--gh-text)}
#ghOvl .gheye[hidden],#ghOvl .gheye svg[hidden]{display:none}
#ghOvl fieldset{border:1px solid var(--gh-border);border-radius:8px;padding:8px 12px;margin:0;display:grid;gap:8px;min-width:0}
#ghOvl legend{padding:0 6px;font-weight:600;color:var(--gh-text);font-size:13px}
#ghOvl .ghext-link{display:inline-flex;align-items:center;gap:4px;margin-top:2px;font-size:12px;color:var(--gh-accent);text-decoration:none}
#ghOvl .ghext-link:hover{text-decoration:underline}
#ghOvl .ghext-link:focus-visible{outline:2px solid var(--gh-accent);outline-offset:2px;border-radius:2px}
#ghOvl .ghsr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
#ghOvl .ghlead{margin:0;color:var(--gh-muted);font-size:12px;line-height:1.35}
#ghOvl .ghchoices{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}
#ghOvl .ghchoice{display:flex;gap:6px;align-items:flex-start;padding:6px 8px;margin:0;border:1px solid var(--gh-border);border-radius:8px;cursor:pointer;font-weight:400;color:var(--gh-text)}
#ghOvl .ghchoice:hover{background:var(--gh-code-bg)}
#ghOvl .ghchoice:has(input:checked){background:var(--gh-accent-soft);border-color:var(--gh-accent);box-shadow:0 0 0 1px var(--gh-accent) inset}
#ghOvl .ghchoice:has(input:focus-visible){outline:2px solid var(--gh-accent);outline-offset:1px}
#ghOvl .ghchoice input{margin-top:4px;accent-color:var(--gh-accent);width:auto;height:auto}
#ghOvl .ghchoice b{font-weight:600;font-size:13px}
#ghOvl .ghchoice small{display:block;color:var(--gh-muted);font-size:11.5px;line-height:1.3}
#ghOvl .ghchoice em{font-style:normal;font-size:11px;margin-left:6px;padding:1px 6px;border-radius:999px;background:var(--gh-accent);color:#0b0b0c;font-weight:600;vertical-align:1px;white-space:nowrap;display:inline-block}
#ghOvl #ghCustomWrap{margin-top:6px}
#ghOvl .ghsummary{background:var(--gh-code-bg);border-radius:8px;padding:8px 10px}
#ghOvl .ghsummary-title{font-size:11.5px;font-weight:600;color:var(--gh-muted);margin-bottom:2px}
#ghOvl .ghsummary p{margin:0 0 4px;color:var(--gh-text);font-size:12.5px;line-height:1.35}
#ghOvl .ghtree{font:11.5px/1.4 ui-monospace,"SF Mono",Menlo,Consolas,monospace;overflow-x:auto;color:var(--gh-text)}
#ghOvl .ghtree .row{white-space:nowrap}
#ghOvl .ghtree .target{color:var(--gh-accent);font-weight:600}
#ghOvl .ghtree .note{margin-left:8px;font-family:inherit;font-size:12px;font-weight:400;color:var(--gh-accent);border:0;padding:0}
#ghOvl .ghstatus{min-height:16px;font-size:12px;margin:0;color:var(--gh-muted);word-break:break-word}
#ghOvl .ghstatus.ok{color:var(--gh-ok)}
#ghOvl .ghstatus.err{color:var(--gh-err)}
#ghOvl .ghfoot{display:flex;gap:8px;justify-content:space-between;align-items:center;padding-top:2px;flex-wrap:wrap}
#ghOvl .ghfoot .right{display:flex;gap:8px}
#ghOvl .ghbtn-act{padding:6px 14px;border-radius:6px;border:1px solid var(--gh-border);background:var(--gh-surface);color:var(--gh-text);font:inherit;font-weight:400}
#ghOvl .ghbtn-act:hover{background:var(--gh-code-bg)}
#ghOvl .ghbtn-act.primary{background:#1f6feb;border-color:#1f6feb;color:#fff;font-weight:400}
#ghOvl .ghbtn-act.primary:hover{background:var(--gh-accent-hover)}
#ghOvl .ghbtn-act:disabled{opacity:.5;cursor:not-allowed}
@media(max-width:560px){#ghOvl .gh-two{grid-template-columns:1fr}#ghOvl .ghchoices{grid-template-columns:1fr}}
/* #gsettings card selector */
#gsettings{--gs-accent:#4c9aff;--gs-accent-soft:rgba(76,154,255,.12);--gs-card:#17171a;--gs-card-hover:#1d1d21;--gs-border:#2a2a30;--gs-muted:#9a9aa3;--gs-text:#e8e8ea;--gs-ok:#3fb950;--gs-off:#6b6b75;--gs-on-accent:#0b0b0c}
#gsettings .gs-toolbar{display:flex;align-items:center;gap:4px;margin:16px 0 12px;flex-wrap:wrap}
#gsettings .gs-count{font-size:13px;color:var(--gs-muted);margin-right:auto}
#gsettings .gs-ghost{border-color:transparent;background:none;color:var(--gs-accent);padding:4px 8px;font-size:13px}
#gsettings .gs-ghost:hover{background:var(--gs-accent-soft)}
#gsettings .gs-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:10px;max-height:272px;overflow-y:auto;overscroll-behavior:contain;padding:4px 8px 4px 4px;margin:-4px;scrollbar-width:thin;scrollbar-color:var(--gs-border) transparent}
#gsettings .gs-grid::-webkit-scrollbar{width:8px}
#gsettings .gs-grid::-webkit-scrollbar-thumb{background:var(--gs-border);border-radius:8px}
#gsettings .gs-grid::-webkit-scrollbar-track{background:transparent}
#gsettings .gs-provider{position:relative;display:block;cursor:pointer}
#gsettings .gs-provider input{position:absolute;opacity:0;inset:0;width:100%;height:100%;margin:0;cursor:pointer}
#gsettings .gs-card{display:flex;gap:12px;align-items:center;padding:12px;height:100%;background:var(--gs-card);border:1px solid var(--gs-border);border-radius:10px;transition:background .15s,border-color .15s,box-shadow .15s;color:var(--gs-text)}
#gsettings .gs-provider:hover .gs-card{background:var(--gs-card-hover)}
#gsettings .gs-provider input:checked + .gs-card{border-color:var(--gs-accent);background:var(--gs-accent-soft);box-shadow:0 0 0 1px var(--gs-accent) inset}
#gsettings .gs-provider input:focus-visible + .gs-card{outline:2px solid var(--gs-accent);outline-offset:2px}
#gsettings .gs-logo{flex:none;width:40px;height:40px;border-radius:10px;display:grid;place-items:center;font-size:13px;font-weight:700;letter-spacing:.02em;overflow:hidden;background:hsl(var(--gs-h,210) 40% 22%);color:hsl(var(--gs-h,210) 80% 78%)}
#gsettings .gs-logo.gs-has-img{background:#fff;border:1px solid rgba(255,255,255,.08);padding:7px}
#gsettings .gs-logo img{width:100%;height:100%;object-fit:contain;display:block}
#gsettings .gs-meta{min-width:0;flex:1}
#gsettings .gs-name{display:block;font-weight:600;line-height:1.3}
#gsettings .gs-path{display:block;margin-top:2px;font:11px/1.4 ui-monospace,"SF Mono",Menlo,Consolas,monospace;color:var(--gs-muted);word-break:break-all}
#gsettings .gs-check{flex:none;width:20px;height:20px;border-radius:6px;border:1.5px solid var(--gs-border);display:grid;place-items:center;color:transparent;transition:background .15s,border-color .15s,color .15s;font-size:12px;line-height:1}
#gsettings .gs-provider input:checked + .gs-card .gs-check{background:var(--gs-accent);border-color:var(--gs-accent);color:var(--gs-on-accent)}
#gsettings .gs-saverow{display:flex;align-items:center;gap:12px;margin-top:16px;flex-wrap:wrap}
#gsettings .gs-dirty{font-size:12px;color:var(--gs-muted)}
#gsettings .gs-dirty.on{color:var(--gs-accent)}
#gsettings .gs-divider{border-top:1px solid #1d1d1d;margin:18px 0 14px}
#gsettings .gs-synchead{display:flex;align-items:flex-start;gap:16px}
#gsettings .gs-synctext{flex:1;min-width:0}
#gsettings .gs-synctext .muted{margin:0 0 6px}
#gsettings .gs-pill{display:inline-flex;align-items:center;gap:6px;margin-top:6px;padding:3px 10px;border-radius:999px;font-size:12px;border:1px solid var(--gs-border);background:var(--gs-card);color:var(--gs-text)}
#gsettings .gs-pill i{width:8px;height:8px;border-radius:50%;background:var(--gs-off)}
#gsettings .gs-pill.on i{background:var(--gs-ok);box-shadow:0 0 0 3px rgba(63,185,80,.25)}
#gsettings .gs-switch{position:relative;flex:none;width:46px;height:26px;border-radius:999px;border:1px solid var(--gs-border);background:var(--gs-card);padding:0;transition:background .2s,border-color .2s}
#gsettings .gs-switch::after{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:var(--gs-off);transition:transform .2s,background .2s}
#gsettings .gs-switch[aria-checked=true]{background:var(--gs-accent);border-color:var(--gs-accent)}
#gsettings .gs-switch[aria-checked=true]::after{transform:translateX(20px);background:var(--gs-on-accent)}
#gsettings .gs-switch:disabled{cursor:not-allowed}
#gsettings .gs-ghost:disabled{opacity:.45;cursor:not-allowed;background:none}
#gsettings .gs-provider input:disabled{cursor:not-allowed}
#gsettings .gs-provider input:disabled + .gs-card{opacity:.5;cursor:not-allowed}
#gsettings .gs-provider:hover input:disabled + .gs-card{background:var(--gs-card)}
#gsettings .gs-interval{display:flex;align-items:center;gap:8px;margin-top:16px;flex-wrap:wrap}
#gsettings .gs-interval label{color:var(--gs-muted);font-size:13px}
#gsettings .gs-interval input{width:72px}
@media(max-width:600px){#gsettings .gs-grid{grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}}
@media(prefers-reduced-motion:reduce){#gsettings .gs-card,#gsettings .gs-switch,#gsettings .gs-switch::after,#gsettings .gs-check{transition:none!important}}
</style>
</head>
<body>
<div class="wrap">
<aside>
<div class="brand">Shirube Console</div>
<nav>
<a href="#top" class="active" aria-current="page"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/></svg><span data-i18n="概要">概要</span></a>
<a href="#projects"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg><span data-i18n="プロジェクト">プロジェクト</span></a>
<a href="#global"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/></svg><span data-i18n="Global同期">Global同期</span></a>
<a href="#rules"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M15 12h-5"/><path d="M15 8h-5"/><path d="M19 17V5a2 2 0 0 0-2-2H4"/><path d="M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3"/></svg><span data-i18n="ルール">ルール</span></a>
<a href="#backups"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg><span data-i18n="バックアップ">バックアップ</span></a>
<a href="#local"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/></svg><span data-i18n="ローカル編集">ローカル編集</span></a>
<a href="#logs"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/></svg><span data-i18n="同期ログ">同期ログ</span></a>
<a href="#settings"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg><span data-i18n="設定・ヘルプ">設定・ヘルプ</span></a>
</nav>
<div class="side-note"><span data-i18n="このPC専用。外部送信なし。">このPC専用。外部送信なし。</span><br><span data-i18n="AGENTS.md は直接編集しません。">AGENTS.md は直接編集しません。</span></div>
</aside>
<main>
<div class="topbar"><div><strong data-i18n="Shirube 管理">Shirube 管理</strong> <span class="sub" data-i18n="プロジェクト同期ダッシュボード">プロジェクト同期ダッシュボード</span></div><div class="topbar-right"><button type="button" id="btnGitHub" class="ghbtn" aria-label="GitHub連携" data-i18n-aria="GitHub連携" title="GitHub連携"><svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" focusable="false"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg></button><select id="selLang" class="lang" aria-label="表示言語" data-i18n-aria="表示言語"><option value="ja">日本語</option><option value="en">English</option><option value="zh-CN">简体中文</option></select></div></div>
<nav class="topnav" aria-label="画面切替" data-i18n-aria="画面切替">
<a href="#top" class="active" aria-current="page"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/></svg><span data-i18n="概要">概要</span></a>
<a href="#projects"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg><span data-i18n="プロジェクト">プロジェクト</span></a>
<a href="#global"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/></svg><span data-i18n="Global同期">Global同期</span></a>
<a href="#rules"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M15 12h-5"/><path d="M15 8h-5"/><path d="M19 17V5a2 2 0 0 0-2-2H4"/><path d="M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3"/></svg><span data-i18n="ルール">ルール</span></a>
<a href="#backups"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg><span data-i18n="バックアップ">バックアップ</span></a>
<a href="#local"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/></svg><span data-i18n="ローカル編集">ローカル編集</span></a>
<a href="#logs"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M3 6h.01"/><path d="M3 12h.01"/><path d="M3 18h.01"/></svg><span data-i18n="同期ログ">同期ログ</span></a>
<a href="#settings"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/></svg><span data-i18n="設定・ヘルプ">設定・ヘルプ</span></a>
</nav>
<div class="summarybar">
<section aria-label="summary">
<div class="grid3">
<div class="card"><h2 data-i18n="登録プロジェクト数">登録プロジェクト数</h2><p class="big" id="stCount">読込中</p><p class="muted helper" data-i18n="projects.json が正本です">projects.json が正本です</p></div>
<div class="card"><h2 data-i18n="同期状態">同期状態</h2><p class="big" id="stRun">読込中</p><p class="muted helper" id="stLog">-</p><div class="syncprogress"><progress id="syncProgress" max="2" value="0" aria-label="同期進捗" aria-valuetext="0/2 待機中" data-i18n-aria="同期進捗"></progress><span class="muted" id="syncProgressText" aria-live="polite">0/2 待機中</span></div></div>
<div class="card"><h2 data-i18n="最終結果">最終結果</h2><p class="muted" id="stTail">読込中</p><div class="btnrow"><button id="btnSync" class="primary" data-i18n="すべて同期">すべて同期</button><button id="btnSyncGlobalOnly" data-i18n="Globalのみ">Globalのみ</button><button id="btnSyncProjectOnly" data-i18n="Projectのみ">Projectのみ</button></div></div>
</div>
<p class="muted helper" id="ovGlobal">Global同期: 読込中</p>
</section>
</div>
<div class="mainscroll">
<div id="top">
<h1 data-i18n="プロジェクト同期ダッシュボード">プロジェクト同期ダッシュボード</h1>
<p class="lead" data-i18n="登録一覧の管理と今すぐ同期を行います。配布ファイルの直接編集はしません。開始した処理はUIを閉じても継続しますが、両方の完了確認には画面を開いたままにしてください。">登録一覧の管理と今すぐ同期を行います。配布ファイルの直接編集はしません。開始した処理はUIを閉じても継続しますが、両方の完了確認には画面を開いたままにしてください。</p>
</div>
<div id="projects" hidden>
<div class="cols2">
<section>
<div class="card"><h2 data-i18n="プロジェクト一覧">プロジェクト一覧</h2>
<p class="muted" id="emptyProj" hidden data-i18n="まだ登録がありません。右の新規登録から追加してください。">まだ登録がありません。右の新規登録から追加してください。</p>
<div class="searchrow"><input type="text" id="inpSearch" placeholder="検索で絞り込み（名前・パス）" data-i18n-placeholder="検索で絞り込み（名前・パス）" autocomplete="off"></div>
<div class="tablewrap"><table id="tbl" hidden><thead><tr><th data-i18n="選択">選択</th><th data-i18n="名前">名前</th><th data-i18n="パス">パス</th><th data-i18n="有効">有効</th><th data-i18n="操作">操作</th></tr></thead><tbody id="rows"></tbody></table></div>
<p class="muted" data-i18n="解除は一覧からのみ削除し、リポジトリ内のファイルは削除しません。「開く」で登録フォルダを開けます。">解除は一覧からのみ削除し、リポジトリ内のファイルは削除しません。「開く」で登録フォルダを開けます。</p>
<div class="btnrow"><a href="#register" class="btnlink" data-i18n="新規登録へ">新規登録へ</a></div>
<div id="msgList" role="status"></div>
</div>
</section>
<section id="register">
<div class="card"><h2 data-i18n="新規登録">新規登録</h2>
<p class="muted" data-i18n="フォルダのパスを入力するか「参照」で選択し、プレビューで内容を確認してから登録します。選択だけでは登録されません。既存 AGENTS.md がある場合は原則登録停止します（手動整理が必要）。登録後の同期で AGENTS.md は生成・再生成されます。">フォルダのパスを入力するか「参照」で選択し、プレビューで内容を確認してから登録します。選択だけでは登録されません。既存 AGENTS.md がある場合は原則登録停止します（手動整理が必要）。登録後の同期で AGENTS.md は生成・再生成されます。</p>
<div class="pathrow"><input type="text" id="inpPath" placeholder="例 C:\Project\MyRepo" data-i18n-placeholder="例 C:\Project\MyRepo" autocomplete="off"><button id="btnBrowse" data-i18n="参照...">参照...</button></div>
<label class="chk"><input type="checkbox" id="ckForceReplace"> <span data-i18n="既存 AGENTS.md の置き換えを許可（バックアップ後、同期で再生成）">既存 AGENTS.md の置き換えを許可（バックアップ後、同期で再生成）</span></label>
<div class="btnrow"><button id="btnPrev" class="primary" data-i18n="プレビュー">プレビュー</button></div>
<div id="browseArea" class="muted"></div>
<div id="prevArea"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted" data-i18n="複数まとめて登録（1行1パス、最大20件。新規のみ。AGENTS.md ありは個別取込）。">複数まとめて登録（1行1パス、最大20件。新規のみ。AGENTS.md ありは個別取込）。</p>
<textarea id="inpBatch" placeholder="例 C:\Project\A" data-i18n-placeholder="例 C:\Project\A"></textarea>
<div class="btnrow"><button id="btnBatchPrev" data-i18n="まとめてプレビュー">まとめてプレビュー</button></div>
<div id="batchArea"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted" data-i18n="既存 AGENTS.md の取込（無損失：原本を退避し固有分を project-local.md へ転記）。">既存 AGENTS.md の取込（無損失：原本を退避し固有分を project-local.md へ転記）。</p>
<div class="btnrow"><button id="btnImportPrev" data-i18n="取込プレビュー">取込プレビュー</button></div>
<div id="importArea"></div>
</div>
</section>
</div>
<section id="status">
<div class="card"><h2 data-i18n="状態と再試行">状態と再試行</h2>
<p class="muted" data-i18n="最終試行・最終成功・取得SHA・失敗理由の一覧です。選択した同期・差分はチェック欄で選びます。">最終試行・最終成功・取得SHA・失敗理由の一覧です。選択した同期・差分はチェック欄で選びます。</p>
<div class="btnrow"><button id="btnStatusReload" data-i18n="状態を更新">状態を更新</button><button id="btnSyncSel" class="primary" data-i18n="選択を同期">選択を同期</button><button id="btnPlanSel" data-i18n="選択の反映前差分">選択の反映前差分</button></div>
<div class="tablewrap"><table id="tblStatus" hidden><thead><tr><th data-i18n="選択">選択</th><th data-i18n="名前">名前</th><th data-i18n="有効">有効</th><th data-i18n="最終試行">最終試行</th><th data-i18n="最終成功">最終成功</th><th data-i18n="取得SHA">取得SHA</th><th data-i18n="結果">結果</th><th data-i18n="失敗理由">失敗理由</th></tr></thead><tbody id="statusRows"></tbody></table></div>
<p class="muted" id="emptyStatus" data-i18n="まだ同期状態がありません。今すぐ同期で初回実行できます。">まだ同期状態がありません。今すぐ同期で初回実行できます。</p>
<div id="msgStatus" role="status"></div>
<div id="planArea"></div>
</div>
</section>
</div>
<div id="global" hidden>
<div class="cols2">
<section>
<div class="card"><h2 data-i18n="Global同期（選択した対象へ配布）">Global同期（選択した対象へ配布）</h2>
<p class="muted" data-i18n="PC全体の共通ルールを配ります。Projectとは別の状態（最終成功・取得元・失敗理由）を持ちます。配布ファイルの直接編集はしません。">PC全体の共通ルールを配ります。Projectとは別の状態（最終成功・取得元・失敗理由）を持ちます。配布ファイルの直接編集はしません。</p>
<p class="muted" id="emptyGlobal" data-i18n="まだGlobal同期の状態がありません。今すぐ同期で初回実行できます。">まだGlobal同期の状態がありません。今すぐ同期で初回実行できます。</p>
<div class="tablewrap"><table id="tblGlobal" hidden><thead><tr><th data-i18n="対象">対象</th><th data-i18n="配置先">配置先</th><th data-i18n="最終試行">最終試行</th><th data-i18n="最終成功">最終成功</th><th data-i18n="取得元">取得元</th><th data-i18n="結果">結果</th><th data-i18n="失敗理由">失敗理由</th></tr></thead><tbody id="globalRows"></tbody></table></div>
<p class="muted" id="globalSummary">読込中</p>
<div class="btnrow"><button id="btnGlobalSync" class="primary" disabled data-i18n="プレビューを適用">プレビューを適用</button><button id="btnGlobalPreview" data-i18n="反映前プレビュー">反映前プレビュー</button><button id="btnGlobalReload" data-i18n="状態を更新">状態を更新</button></div>
<div id="msgGlobal" role="status"></div>
<div id="globalPlanArea"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<p class="muted" data-i18n="現在の内容と配置先（実ファイルの先頭のみ表示）。設定ファイルの中身は表示しません。">現在の内容と配置先（実ファイルの先頭のみ表示）。設定ファイルの中身は表示しません。</p>
<div class="btnrow"><button id="btnGlobalContent" data-i18n="内容を表示">内容を表示</button></div>
<pre id="globalContentPre">まだ表示していません。「内容を表示」で確認できます。</pre>
</div>
</section>
<section id="gsettings">
<div class="card"><h2 data-i18n="Global設定">Global設定</h2>
<p class="muted" data-i18n="配る対象の選択・自動同期の間隔と有効/無効を変えます。更新前バックアップと復元は「バックアップ」画面で行います。">配る対象の選択・自動同期の間隔と有効/無効を変えます。更新前バックアップと復元は「バックアップ」画面で行います。</p>
<div class="gs-toolbar">
<span id="globalTargetsCount" class="gs-count" aria-live="polite"></span>
<button id="btnGlobalTargetsAll" class="gs-ghost" disabled data-i18n="すべて選択">すべて選択</button>
<button id="btnGlobalTargetsNone" class="gs-ghost" disabled data-i18n="すべて解除">すべて解除</button>
</div>
<div id="globalTargetsList" class="gs-grid" role="group" aria-label="配る対象" data-i18n-aria="配る対象"></div>
<div class="gs-saverow">
<button id="btnGlobalTargets" class="primary" data-i18n="対象を保存" disabled>対象を保存</button>
<span id="globalTargetsDirty" class="gs-dirty" role="status"></span>
</div>
<div id="msgGlobalTargets" role="status"></div>
<div class="gs-divider"></div>
<div class="gs-synchead">
<div class="gs-synctext">
<p class="muted" data-i18n="自動同期（Shirube Global Auto Sync）。ログオン時＋一定間隔で裏で実行します。">自動同期（Shirube Global Auto Sync）。ログオン時＋一定間隔で裏で実行します。</p>
<span id="globalSyncPill" class="gs-pill"><i aria-hidden="true"></i><span id="globalEnabledState">読込中</span></span>
</div>
<button id="btnGlobalEnabled" class="gs-switch" type="button" role="switch" aria-checked="false" aria-label="自動同期の有効/無効" data-i18n-aria="自動同期の有効/無効"></button>
</div>
<div class="gs-interval">
<label for="numGlobalInterval" data-i18n="間隔（分）">間隔（分）</label>
<input type="number" id="numGlobalInterval" min="5" max="1440" step="1" value="15" inputmode="numeric">
<button id="btnGlobalIntervalGet" data-i18n="現在値">現在値</button>
<button id="btnGlobalIntervalSet" data-i18n="間隔を変更">間隔を変更</button>
</div>
<div id="msgGlobalInterval" role="status"></div>
</div>
</section>
</div>
</div>
<div id="rules" hidden>
<section>
<div class="card"><h2 data-i18n="共通ルール編集">共通ルール編集</h2>
<p class="muted" data-i18n="GitHub上の global.md / project.md を取得して編集・保存します。保存にはGitHub連携とトークンが必要です。取得時のSHAと一致した場合のみ更新します。">GitHub上の global.md / project.md を取得して編集・保存します。保存にはGitHub連携とトークンが必要です。取得時のSHAと一致した場合のみ更新します。</p>
<p class="muted warn" id="rulesGate" hidden data-i18n="GitHub連携が未設定のため編集できません。上部のGitHubボタンから設定してください。">GitHub連携が未設定のため編集できません。上部のGitHubボタンから設定してください。</p>
<div class="btnrow"><select id="selRuleKind" aria-label="ルール種別" data-i18n-aria="ルール種別"><option value="project">project.md</option><option value="global">global.md</option></select><button id="btnRuleLoad" data-i18n="取得">取得</button><button id="btnRuleSave" class="primary" data-i18n="保存">保存</button></div>
<p class="muted" id="ruleMeta"></p>
<div id="msgRule" role="status"></div>
<div class="rule-modes" role="group" aria-label="表示モード" data-i18n-aria="表示モード"><button type="button" id="btnRuleModeEdit" class="rmode" aria-pressed="false" data-i18n="編集">編集</button><button type="button" id="btnRuleModeSplit" class="rmode" aria-pressed="true" data-i18n="分割">分割</button><button type="button" id="btnRuleModePreview" class="rmode" aria-pressed="false" data-i18n="プレビュー">プレビュー</button></div>
<div class="rules-grid" id="rulesGrid">
<div class="rule-src" id="ruleSrcPane">
<textarea id="ruleText" spellcheck="false" aria-label="ルール本文" data-i18n-aria="ルール本文"></textarea>
<div id="ruleEditorWrap" class="rule-cm" aria-label="ルール本文" data-i18n-aria="ルール本文"></div>
</div>
<div class="rule-view" id="rulePreviewPane" aria-label="共通ルールプレビュー" data-i18n-aria="共通ルールプレビュー">
<div id="rulePreview" class="rpreview"></div>
</div>
</div>
</div>
</section>
</div>
<div id="backups" hidden>
<section>
<div class="card"><h2 data-i18n="バックアップと復元">バックアップと復元</h2>
<p class="muted" data-i18n="復元は AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。共通 GitHub 側の巻戻しはしません。">復元は AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。共通 GitHub 側の巻戻しはしません。</p>
<div class="btnrow"><button id="btnBackupsReload" data-i18n="一覧を更新">一覧を更新</button></div>
<div class="tablewrap"><table id="tblBackups" hidden><thead><tr><th>ID</th><th data-i18n="対象">対象</th><th data-i18n="作成">作成</th><th data-i18n="内容">内容</th><th data-i18n="操作">操作</th></tr></thead><tbody id="backupRows"></tbody></table></div>
<p class="muted" id="emptyBackups" data-i18n="バックアップがありません。">バックアップがありません。</p>
<div id="backupDiffArea"></div>
<div id="msgBackup" role="status"></div>
</div>
</section>
<section>
<div class="card"><h2 data-i18n="Globalバックアップと復元">Globalバックアップと復元</h2>
<p class="muted" data-i18n="復元前に Global 自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。差分で内容を確認してから復元します。">復元前に Global 自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。差分で内容を確認してから復元します。</p>
<div class="btnrow"><button id="btnGlobalBackups" data-i18n="一覧を更新">一覧を更新</button></div>
<div class="tablewrap"><table id="tblGlobalBackups" hidden><thead><tr><th>ID</th><th data-i18n="作成">作成</th><th data-i18n="対象">対象</th><th data-i18n="操作">操作</th></tr></thead><tbody id="globalBackupRows"></tbody></table></div>
<p class="muted" id="emptyGlobalBackups" data-i18n="バックアップがありません。">バックアップがありません。</p>
<div id="globalBackupDiffArea"></div>
<div id="msgGlobalBackup" role="status"></div>
</div>
</section>
</div>
<div id="local" hidden>
<section>
<div class="card"><h2 data-i18n="ローカルルール編集と検査">ローカルルール編集と検査</h2>
<p class="muted" data-i18n="project-local.md を形式検証付きで編集します。保存時は取得時ハッシュと一致した場合のみ書換えます。検査結果は候補であり断定ではありません。">project-local.md を形式検証付きで編集します。保存時は取得時ハッシュと一致した場合のみ書換えます。検査結果は候補であり断定ではありません。</p>
<div class="btnrow"><select id="selLocal" style="max-width:280px"></select><button id="btnLocalLoad" data-i18n="取得">取得</button><button id="btnCheck" data-i18n="重複・矛盾候補を検査">重複・矛盾候補を検査</button></div>
<div id="localArea"></div>
<div id="checkArea"></div>
<div id="msgLocal" role="status"></div>
</div>
</section>
</div>
<div id="logs" hidden>
<section>
<div class="card"><h2 data-i18n="Project同期ログ">Project同期ログ</h2>
<div class="btnrow"><button id="btnReload" data-i18n="更新">更新</button></div>
<pre id="logPre">読込中</pre>
</div>
</section>
<section>
<div class="card"><h2 data-i18n="Global同期ログ">Global同期ログ</h2>
<p class="muted" data-i18n="直近のみ表示。末尾の OK は成功、FAIL は失敗、SKIP は見送りです。">直近のみ表示。末尾の OK は成功、FAIL は失敗、SKIP は見送りです。</p>
<div class="btnrow"><button id="btnGlobalLogs" data-i18n="ログを更新">ログを更新</button></div>
<pre id="globalLogPre">読込中</pre>
</div>
</section>
</div>
<div id="settings" hidden>
<section>
<div class="card"><h2 data-i18n="設定（間隔・入出力）">設定（間隔・入出力）</h2>
<p class="muted" data-i18n="同期間隔は Project タスクのみ変更します（Global は不変）。エクスポート・インポートに秘密情報は含みません。">同期間隔は Project タスクのみ変更します（Global は不変）。エクスポート・インポートに秘密情報は含みません。</p>
<div class="btnrow"><label class="muted"><span data-i18n="Project 同期の間隔（分）">Project 同期の間隔（分）</span> <input type="number" id="numInterval" min="5" max="1440" step="1" value="15"></label><button id="btnIntervalGet" data-i18n="現在値">現在値</button><button id="btnIntervalSet" data-i18n="間隔を変更">間隔を変更</button></div>
<div id="msgInterval" role="status"></div>
<hr style="border:0;border-top:1px solid #1d1d1d;margin:16px 0">
<div class="btnrow"><button id="btnExport" data-i18n="設定をエクスポート（JSON保存）">設定をエクスポート（JSON保存）</button></div>
<p class="muted" data-i18n="取り込みはプレビューで合流内容を確認してから登録します（新規のみ追加・既存維持）。">取り込みはプレビューで合流内容を確認してから登録します（新規のみ追加・既存維持）。</p>
<textarea id="txtImport" placeholder="エクスポートしたJSONを貼り付け" data-i18n-placeholder="エクスポートしたJSONを貼り付け"></textarea>
<div class="btnrow"><button id="btnImportPrev2" data-i18n="取込プレビュー">取込プレビュー</button></div>
<div id="importRegArea"></div>
<div id="msgSettings" role="status"></div>
</div>
</section>
<section id="help">
<div class="card"><details class="help" id="helpDetail"><summary data-i18n="ヘルプ">ヘルプ</summary>
<p class="muted" data-i18n="管理バッチをダブルクリックするとこの画面が開きます。サーバーは 127.0.0.1 のみで待受けし、15分無操作で終了します。同期タスク自体はタスクスケジューラの設定どおり継続します。登録・解除は projects.json のみを変更します。">管理バッチをダブルクリックするとこの画面が開きます。サーバーは 127.0.0.1 のみで待受けし、15分無操作で終了します。同期タスク自体はタスクスケジューラの設定どおり継続します。登録・解除は projects.json のみを変更します。</p>
</details>
</div>
</section>
</div>
<footer data-i18n="Shirube 管理ダッシュボード (ローカルのみ、外部送信なし)">Shirube 管理ダッシュボード (ローカルのみ、外部送信なし)</footer>
</div>
</main>
</div>
<div class="ovl" id="ovl" hidden><div class="mbox" role="dialog" aria-modal="true" aria-labelledby="mTitle" aria-describedby="mMsg"><h3 id="mTitle"></h3><p id="mMsg"></p><div class="btnrow" id="mBtns"></div></div></div>
<div class="ghovl" id="ghOvl" hidden>
<div class="ghbox" role="dialog" aria-modal="true" aria-labelledby="ghTitle" aria-describedby="ghLead">
<div class="gh-head">
<svg width="28" height="28" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z"/>
</svg>
<div>
<h2 id="ghTitle" data-i18n="GitHub連携">GitHub連携</h2>
<p id="ghLead" data-i18n="ルールファイルの保存先リポジトリを設定します">ルールファイルの保存先リポジトリを設定します</p>
</div>
<button type="button" class="ghclose" id="ghClose" aria-label="閉じる" data-i18n-aria="閉じる">&times;</button>
</div>
<form id="ghForm" autocomplete="off" novalidate>
<div class="ghfield">
<label for="ghToken">Personal Access Token</label>
<div class="ghsecret">
<input type="password" id="ghToken" class="mono" placeholder="github_pat_xxxxxxxxxxxx" autocomplete="off" spellcheck="false" aria-describedby="ghTokenHint">
<button type="button" class="gheye" id="ghEye" aria-label="トークンを表示" data-i18n-aria="トークンを表示" aria-pressed="false" title="表示" data-i18n-title="表示">
<svg id="ghEyeOn" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z"/><circle cx="12" cy="12" r="3"/></svg>
<svg id="ghEyeOff" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" hidden><path d="M17.94 17.94A10.94 10.94 0 0112 19C5 19 1 12 1 12a18.5 18.5 0 015.06-5.94M9.9 4.24A10.9 10.9 0 0112 5c7 0 11 7 11 7a18.5 18.5 0 01-2.16 3.19M14.12 14.12a3 3 0 11-4.24-4.24"/><path d="M1 1l22 22"/></svg>
</button>
</div>
<div class="ghhint" id="ghTokenHint" data-i18n="必要な権限: Contents (Read and write)。Fine-grained トークンを推奨します。">必要な権限: Contents (Read and write)。Fine-grained トークンを推奨します。</div>
<a class="ghext-link" id="ghTokenLink" href="https://github.com/settings/personal-access-tokens/new" target="_blank" rel="noopener noreferrer">
<span data-i18n="GitHubでトークンを作成する">GitHubでトークンを作成する</span>
<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6"/><path d="M15 3h6v6"/><path d="M10 14L21 3"/></svg>
<span class="ghsr-only" data-i18n="(新しいタブで開きます)">(新しいタブで開きます)</span>
</a>
</div>
<fieldset>
<legend data-i18n="ルールの保存先">ルールの保存先</legend>
<p class="ghlead" data-i18n="GitHub上のどこにルールを保存するかを、3つの質問で決めます。">GitHub上のどこにルールを保存するかを、3つの質問で決めます。</p>
<div class="gh-two">
<div class="ghfield">
<label for="ghRepo" data-i18n="① どのリポジトリに保存しますか?">① どのリポジトリに保存しますか?</label>
<input type="text" id="ghRepo" class="mono" placeholder="例: Fizor-drm/Shirube" data-i18n-placeholder="例: Fizor-drm/Shirube" spellcheck="false" autocomplete="off">
<div class="ghhint" id="ghRepoHint" data-i18n="GitHubのURL(https://github.com/…)をそのまま貼り付けてもOKです。">GitHubのURL(https://github.com/…)をそのまま貼り付けてもOKです。</div>
</div>
<div class="ghfield">
<label for="ghBranch" data-i18n="② どのブランチに保存しますか?">② どのブランチに保存しますか?</label>
<input type="text" id="ghBranch" class="mono" placeholder="main" spellcheck="false" autocomplete="off">
<div class="ghhint" id="ghBranchHint" data-i18n="迷ったら「main」のままで大丈夫です。">迷ったら「main」のままで大丈夫です。</div>
</div>
</div>
<div class="ghfield">
<span class="ghlabel" id="ghFolderLabel" data-i18n="③ ルールをどのフォルダに入れますか?">③ ルールをどのフォルダに入れますか?</span>
<div class="ghchoices" role="radiogroup" aria-labelledby="ghFolderLabel">
<label class="ghchoice">
<input type="radio" name="ghFolder" value="rules" checked>
<span><b data-i18n="rules フォルダ">rules フォルダ</b><em data-i18n="おすすめ">おすすめ</em><small data-i18n="ルール専用のフォルダにまとめて保存します">ルール専用のフォルダにまとめて保存します</small></span>
</label>
<label class="ghchoice">
<input type="radio" name="ghFolder" value=".">
<span><b data-i18n="リポジトリの一番上">リポジトリの一番上</b><small data-i18n="フォルダを作らず、直接ファイルを置きます">フォルダを作らず、直接ファイルを置きます</small></span>
</label>
<label class="ghchoice">
<input type="radio" name="ghFolder" value="__custom">
<span><b data-i18n="別のフォルダを指定する">別のフォルダを指定する</b><small data-i18n="すでに使いたいフォルダがある場合はこちら">すでに使いたいフォルダがある場合はこちら</small></span>
</label>
</div>
<div id="ghCustomWrap" hidden>
<label for="ghFolderCustom" class="ghlabel" style="font-weight:500" data-i18n="フォルダの場所">フォルダの場所</label>
<input type="text" id="ghFolderCustom" class="mono" placeholder="例: config/shirube/rules" data-i18n-placeholder="例: config/shirube/rules" spellcheck="false" autocomplete="off">
<div class="ghhint" id="ghPathHint" data-i18n="「/」で区切ると、フォルダの中のフォルダも指定できます。まだ無いフォルダは自動で作られます。">「/」で区切ると、フォルダの中のフォルダも指定できます。まだ無いフォルダは自動で作られます。</div>
</div>
</div>
<div class="ghsummary" aria-live="polite">
<div class="ghsummary-title" data-i18n="この設定の場合">この設定の場合</div>
<p id="ghSummaryText"></p>
<div class="ghtree" id="ghTree" aria-hidden="true"></div>
</div>
</fieldset>
<div class="ghstatus" id="ghStatus" role="status" aria-live="polite"></div>
<div class="ghfoot">
<button type="button" class="ghbtn-act" id="ghTest" data-i18n="接続テスト">接続テスト</button>
<div class="right">
<button type="button" class="ghbtn-act" id="ghCancel" data-i18n="キャンセル">キャンセル</button>
<button type="submit" class="ghbtn-act primary" id="ghSave" data-i18n="保存">保存</button>
</div>
</div>
</form>
</div>
</div><script>
"use strict";
__RULE_EDITOR_VENDOR__
const TOKEN = "__TOKEN__";
const GLOBAL_CATALOG = (typeof __GLOBAL_CATALOG__ !== "undefined") ? __GLOBAL_CATALOG__ : [];
const GLOBAL_DEFAULT_TARGETS = ["codexcli", "opencode"];
const H = {"Content-Type":"application/json","X-Dashboard-Token":TOKEN};
const SCREENS=["top","projects","global","rules","backups","local","logs","settings"];
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
    if(e && e.name === "AbortError") throw new Error(L("要求がタイムアウトしました。少し待って更新ボタンで確認してください。"));
    throw e;
  }finally{ clearTimeout(timer); }
}
const LANG_KEY = "shirube.lang";
const LANGS = ["ja", "en", "zh-CN"];
const localizedText = {ja:new Map(),en:new Map(),"zh-CN":new Map()};
const I18N = {
  en: {
    " 既存 AGENTS.md はバックアップ後に同期で再生成されます（固有内容は自動転記されません）。": " An existing AGENTS.md is backed up and regenerated on sync (its unique content is not copied automatically).",
    "・": ", ",
    "、": ", ",
    "(ファイルなし)": "(no file)",
    "（一部省略）": " (partially truncated)",
    "（差分あり）": " (changes found)",
    "（差分なし）": " (no changes)",
    "(省略)": "(truncated)",
    "（同期間隔を{n}分に変更）": " (interval changed to {n} min)",
    "（未設定）": "(not set)",
    "{done}/2 Project同期: {state}": "{done}/2 Project sync: {state}",
    "{n} 件": "{n} items",
    "{selected} / {total} 件を選択中": "{selected} / {total} selected",
    "{n}件を登録し、非表示で同期します。よろしいですか。": "Register {n} project(s) and sync in the background. Continue?",
    "{n}件を登録し、非表示で同期することを理解した": "I understand that {n} project(s) will be registered and synced in the background",
    "{state}（対象 {targets}）": "{state} (targets: {targets})",
    "「{id}」を復元します。AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。よろしいですか。": "Restore \"{id}\"? AGENTS.md and localSource are restored together, and the target is paused (disabled) to prevent the next overwrite. Continue?",
    "「{id}」を復元します。復元前にGlobal自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。よろしいですか。": "Restore \"{id}\"? Global automatic sync is paused before restoring and stays paused afterwards (enable it to resume). Continue?",
    "「{name}」を一覧から解除します。ファイルは削除しません。よろしいですか。": "Remove \"{name}\" from the list? Files are not deleted. Continue?",
    "「{name}」を取り込んで登録し、非表示で同期します。よろしいですか。": "Import and register \"{name}\", then sync in the background. Continue?",
    "「{name}」を登録し、非表示で同期します。よろしいですか。": "Register \"{name}\" and sync in the background. Continue?",
    "【重複候補】{project}：{line}": "[Possible duplicate] {project}: {line}",
    "【矛盾候補】{project}：共通「{common}」/固有「{local}」": "[Possible conflict] {project}: shared \"{common}\" / local \"{local}\"",
    "0/2 Global同期: {state}": "0/2 Global sync: {state}",
    "0/2 Global同期: 開始できませんでした": "0/2 Global sync: could not start",
    "0/2 Global同期を実行中": "0/2 Running Global sync",
    "0/2 待機中": "0/2 Waiting",
    "0/2 同期に失敗しました": "0/2 Sync failed",
    "0/2 同期を確認しています": "0/2 Checking sync",
    "1/2 Global同期: {state} / Project同期を実行中": "1/2 Global sync: {state} / Running Project sync",
    "1/2 Project同期: {state}": "1/2 Project sync: {state}",
    "1/2 Project同期: 開始できませんでした": "1/2 Project sync: could not start",
    "1/1 Global同期: {state}": "1/1 Global sync: {state}",
    "1/1 Project同期: {state}": "1/1 Project sync: {state}",
    "AGENTS.md なし: 登録後の同期で新規生成されます。既存 AGENTS.md がある場合は登録停止します。": "No AGENTS.md: a new one is generated on the sync after registration. If an existing AGENTS.md is present, registration stops.",
    "AGENTS.md は直接編集しません。": "AGENTS.md is never edited directly.",
    "AGENTSあり": "AGENTS present",
    "AGENTSなし": "No AGENTS",
    "Globalバックアップと復元": "Global backup and restore",
    "Globalプレビュー適用中です。": "A Global preview is being applied.",
    "Global自動同期を休止します（裏の実行なし）。よろしいですか。": "Pause Global automatic sync (no background runs)?",
    "Global自動同期を有効にします。よろしいですか。": "Enable Global automatic sync?",
    "Global設定": "Global settings",
    "Global同期": "Global sync",
    "Global同期: {summary}": "Global sync: {summary}",
    "Global同期: 読込中": "Global sync: loading",
    "Global同期（選択した対象へ配布）": "Global sync (distribute to selected targets)",
    "Globalのみ": "Global only",
    "Globalのみ同期の確認": "Confirm Global-only sync",
    "Global同期（保存済み対象へ配布）を実行します。よろしいですか。": "Run Global sync (distribute to saved targets)?",
    "0/1 Global同期: {state}": "0/1 Global sync: {state}",
    "0/1 Global同期: 開始できませんでした": "0/1 Global sync: could not start",
    "0/1 Global同期を実行中": "0/1 Running Global sync",
    "Global同期（保存済み対象へ配布）を実行し、完了を確認した後、登録済みプロジェクトの同期を実行します。よろしいですか。": "Run Global sync (distribute to saved targets), confirm completion, then sync the registered projects. Continue?",
    "Global同期が{state}のため、Project同期は実行しませんでした。": "Global sync was {state}, so Project sync was not started.",
    "Global同期が失敗しました": "Global sync failed",
    "Global同期が失敗しました。ログを確認してください。": "Global sync failed. Check the log.",
    "Global同期が成功しました": "Global sync succeeded",
    "Global同期が成功しました。ログを確認してください。": "Global sync succeeded. Check the log.",
    "Global同期できませんでした": "Global sync could not run",
    "Global同期の確認": "Confirm Global sync",
    "Global同期の間隔を{n}分に変更します（Projectは不変）。よろしいですか。": "Change the Global sync interval to {n} minutes (Project is unchanged). Continue?",
    "Global同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。": "Global sync was skipped (another sync is running). Try again later.",
    "Global同期は見送りです": "Global sync skipped",
    "Global同期は未確認です": "Global sync unconfirmed",
    "Global同期は未確認です(起動待ち/継続中)。しばらくして状態を更新してください。": "Global sync is unconfirmed (waiting to start or still running). Refresh the status later.",
    "Global同期ログ": "Global sync log",
    "Global同期状態は未確認です。ログを確認してください。": "The Global sync state is unconfirmed. Check the log.",
    "Global復元の確認": "Confirm Global restore",
    "JSONを解釈できません。": "The JSON could not be parsed.",
    "localあり": "local present",
    "localなし": "no local",
    "NG: {path}：{error}": "NG: {path}: {error}",
    "OK: 「{name}」← {path}": "OK: \"{name}\" <- {path}",
    "PC全体の共通ルールを配ります。Projectとは別の状態（最終成功・取得元・失敗理由）を持ちます。配布ファイルの直接編集はしません。": "Distributes shared rules for the whole PC. Its state (last success, source, failure reason) is separate from Project. Distributed files are never edited directly.",
    "Project 同期の間隔（分）": "Project sync interval (minutes)",
    "Project 同期の間隔を{n}分に変更します（Global は不変）。よろしいですか。": "Change the Project sync interval to {n} minutes (Global is unchanged). Continue?",
    "project-local.md なし: 共通ルールのみで生成されます。": "No project-local.md: the file is generated from shared rules only.",
    "project-local.md を形式検証付きで編集します。保存時は取得時ハッシュと一致した場合のみ書換えます。検査結果は候補であり断定ではありません。": "Edit project-local.md with format validation. Saving writes only when the current hash matches the fetched hash. Check results are candidates, not definitive findings.",
    "projects.json が正本です": "projects.json is authoritative",
    "Project同期できませんでした": "Project sync could not run",
    "Project同期は未確認です": "Project sync unconfirmed",
    "Projectのみ": "Project only",
    "Projectのみ同期の確認": "Confirm Project-only sync",
    "Projectのみの同期を実行します。よろしいですか。": "Run Project-only sync?",
    "0/1 Project同期: {state}": "0/1 Project sync: {state}",
    "0/1 Project同期: 開始できませんでした": "0/1 Project sync: could not start",
    "0/1 Project同期を実行中": "0/1 Running Project sync",
    "Project同期ログ": "Project sync log",
    "Shirube 管理": "Shirube Console",
    "Shirube 管理ダッシュボード": "Shirube Dashboard",
    "Shirube 管理ダッシュボード (ローカルのみ、外部送信なし)": "Shirube management dashboard (local only, nothing sent externally)",
    "いずれも候補であり、断定ではありません。内容を確認して判断してください。": "These are candidates, not definitive findings. Review the content and decide.",
    "エクスプローラーで開きました: ": "Opened in Explorer: ",
    "エクスプローラーで開く": "Open in Explorer",
    "エクスプローラーで開きました: {name}": "Opened in Explorer: {name}",
    "エクスポートしたJSONを貼り付け": "Paste the exported JSON",
    "エクスポートしました（秘密情報なし）。": "Exported (no secrets included).",
    "キャンセルされました。登録は行いません。": "Cancelled. Nothing was registered.",
    "このPC専用。外部送信なし。": "This PC only. Nothing is sent externally.",
    "この内容でよければ「プレビューを適用」で反映します（反映前に再照合し、変化があれば拒否）。": "If this content is acceptable, use \"Apply preview\" to apply it (it is re-checked first and rejected if anything changed).",
    "すべて解除": "Clear all",
    "すべて選択": "Select all",
    "すべて同期": "Sync all",
    "すでにプレビュー適用中です。": "A preview is already being applied.",
    "すでに同期を実行中です。": "A sync is already running.",
    "パス": "Path",
    "パス: ": "Path: ",
    "パスを1行ずつ入力してください。": "Enter one path per line.",
    "バックアップ": "Backups",
    "バックアップがありません。": "No backups.",
    "バックアップと復元": "Backup and restore",
    "フォルダのパスを入力するか「参照」で選択し、プレビューで内容を確認してから登録します。選択だけでは登録されません。既存 AGENTS.md がある場合は原則登録停止します（手動整理が必要）。登録後の同期で AGENTS.md は生成・再生成されます。": "Enter a folder path or choose one with Browse, review it in the preview, then register. Selecting alone does not register. If an AGENTS.md already exists, registration normally stops (manual cleanup is required). The sync after registration generates or regenerates AGENTS.md.",
    "プランID: {id}（選択を変えず「プレビューを適用」でこのプランを適用）": "Plan ID: {id} (keep the selection and use \"Apply preview\" to apply this plan)",
    "プランID: {id}（選択を変えず「選択を同期」でこのプランを適用）": "Plan ID: {id} (keep the selection and use \"Sync selected\" to apply this plan)",
    "プラン作成中": "Creating plan",
    "プレビュー": "Preview",
    "プレビュー OK: 「{name}」として登録できます。": "Preview OK: can be registered as \"{name}\".",
    "プレビューが無効です。もう一度プレビューしてください。": "The preview is no longer valid. Run the preview again.",
    "プレビューをやり直してください。": "Run the preview again.",
    "プレビューを適用": "Apply preview",
    "プロジェクト": "Projects",
    "プロジェクト一覧": "Project list",
    "プロジェクト同期ダッシュボード": "Project sync dashboard",
    "ヘルプ": "Help",
    "まだGlobal同期の状態がありません。今すぐ同期で初回実行できます。": "No Global sync status yet. Use Sync now to run the first sync.",
    "まだ登録がありません。右の新規登録から追加してください。": "No projects registered yet. Add one from New project on the right.",
    "まだ同期状態がありません。今すぐ同期で初回実行できます。": "No sync status yet. Use Sync now to run the first sync.",
    "まだ表示していません。「内容を表示」で確認できます。": "Not shown yet. Use Show content to inspect it.",
    "まとめてプレビュー": "Preview all",
    "まとめて登録して同期": "Register all and sync",
    "やめる": "Cancel",
    "ローカルルール編集と検査": "Local rule editing and checks",
    "ローカル編集": "Local rules",
    "ログがありません。": "No log entries.",
    "ログなし": "No log",
    "ログを更新": "Refresh log",
    "移動": "Move",
    "移動先の再指定": "Change destination",
    "移動先を更新しました。": "Destination updated.",
    "維持：{name}（{reason}）": "Kept: {name} ({reason})",
    "一括登録の確認": "Confirm batch registration",
    "一覧を更新": "Refresh list",
    "画面切替": "Screen navigation",
    "解除": "Unregister",
    "解除しました。一覧のみ変更し、ファイルは削除していません。": "Unregistered. Only the list changed; files were not deleted.",
    "解除する": "Unregister",
    "解除の確認": "Confirm unregister",
    "解除は一覧からのみ削除し、リポジトリ内のファイルは削除しません。「開く」で登録フォルダを開けます。": "Unregistering only removes the entry from this list; files in the repository are not deleted. Open opens the registered folder.",
    "開く": "Open",
    "開けませんでした": "Could not open",
    "概要": "Overview",
    "確認チェックを入れてください。": "Check the confirmation box.",
    "確認済みプランで反映します（反映前に再照合し、変化があれば拒否）。よろしいですか。": "Apply the confirmed plan (it is re-checked first and rejected if anything changed). Continue?",
    "確認中": "Checking",
    "管理バッチをダブルクリックするとこの画面が開きます。サーバーは 127.0.0.1 のみで待受けし、15分無操作で終了します。同期タスク自体はタスクスケジューラの設定どおり継続します。登録・解除は projects.json のみを変更します。": "Double-click the management batch file to open this screen. The server listens only on 127.0.0.1 and exits after 15 minutes of inactivity. Sync tasks themselves continue according to Task Scheduler. Registering and unregistering only change projects.json.",
    "間隔（分）": "Interval (minutes)",
    "間隔の変更": "Change interval",
    "間隔を変更": "Change interval",
    "間隔を変更しました：{n}分": "Interval changed to {n} minutes",
    "間隔は5〜1440分の整数で指定してください。": "Enter a whole number of minutes between 5 and 1440.",
    "既存 AGENTS.md (sha256:{hash}) を退避し、固有分を project-local.md へ転記します。": "The existing AGENTS.md (sha256:{hash}) is preserved and its unique content is copied to project-local.md.",
    "既存 AGENTS.md の取込（無損失：原本を退避し固有分を project-local.md へ転記）。": "Import an existing AGENTS.md (lossless: keep the original and copy project-specific content to project-local.md).",
    "既存 AGENTS.md の置き換えを許可（バックアップ後、同期で再生成）": "Allow replacing an existing AGENTS.md (back up, then regenerate on sync)",
    "既存 AGENTS.md をバックアップ後に同期で再生成します。AGENTS.md の固有内容は自動転記されません。必要な内容は project-local.md に手動転記してください。": "The existing AGENTS.md is backed up and regenerated on sync. Its unique content is not copied automatically. Copy any needed content to project-local.md manually.",
    "既存 project-local.md あり(sha256:{hash}): 変更しません。": "Existing project-local.md found (sha256:{hash}): it will not be changed.",
    "起動待ち": "Waiting to start",
    "起動待ちです。子プロセスの起動を確認しています。": "Waiting to start. Checking that the child process started.",
    "休止しました。": "Paused.",
    "休止中": "Paused",
    "競合・不正があるため取り込めません。整理してから再実行してください。": "Cannot import because of conflicts or invalid entries. Resolve them and try again.",
    "競合：{name}（{reason}）": "Conflict: {name} ({reason})",
    "共通SHA: {sha} 取得GitSHA: {commit} 作成: {at}": "Shared SHA: {sha} fetched Git SHA: {commit} created: {at}",
    "決定": "OK",
    "結果": "Result",
    "検査中": "Checking",
    "検索で絞り込み（名前・パス）": "Filter by name or path",
    "検証して保存": "Validate and save",
    "見送り": "Skipped",
    "見送り: {name}（無効のため対象外）": "Skipped: {name} (disabled, out of scope)",
    "見送りです。別の同期が実行中のため今回は見送りました。しばらくして今すぐ同期でやり直してください。": "Skipped because another sync is running. Try Sync now again later.",
    "現在の間隔：{n}分（Global）": "Current interval: {n} minutes (Global)",
    "現在の間隔：{n}分（Project のみ）": "Current interval: {n} minutes (Project only)",
    "現在の内容と配置先（実ファイルの先頭のみ表示）。設定ファイルの中身は表示しません。": "Current content and destination (only the beginning of the actual file is shown). Configuration file contents are not shown.",
    "現在値": "Current value",
    "候補はありませんでした。": "No candidates were found.",
    "更新": "Refresh",
    "今すぐ同期": "Sync now",
    "今すぐ同期の確認": "Confirm Sync now",
    "今回のログ未確認": "This run's log is unconfirmed",
    "Global: {global} / Project: {project}": "Global: {global} / Project: {project}",
    "差分": "Diff",
    "差分あり": "Changes found",
    "差分なし": "No changes",
    "差分取得中": "Loading diff",
    "最終結果": "Latest result",
    "最終試行": "Last attempt",
    "最終試行・最終成功・取得SHA・失敗理由の一覧です。選択した同期・差分はチェック欄で選びます。": "Lists the last attempt, last success, fetched SHA and failure reason. Select projects for sync or diff with the checkboxes.",
    "最終成功": "Last success",
    "作成": "Created",
    "参照...": "Browse...",
    "時間切れのため選択を終了しました。登録は行いません。": "Selection timed out and was closed. Nothing was registered.",
    "自動同期（Shirube Global Auto Sync）。ログオン時＋一定間隔で裏で実行します。": "Automatic sync (Shirube Global Auto Sync). Runs in the background at logon and at a fixed interval.",
    "自動同期の状態を取得できませんでした。": "Could not retrieve the automatic sync state.",
    "自動同期は休止中です（裏の実行なし）。再開は切替ボタンで有効化してください。": "Automatic sync is paused (no background runs). Enable it with the toggle to resume.",
    "自動同期は有効です（次回も裏で実行）。": "Automatic sync is enabled (it will run in the background again).",
    "自動同期": "Automatic sync",
    "自動同期: {state}": "Automatic sync: {state}",
    "自動同期の有効/無効": "Automatic sync on/off",
    "状態不明": "Unknown state",
    "失敗": "Failed",
    "失敗: {name}：{error}": "Failed: {name}: {error}",
    "失敗: {tail}": "Failed: {tail}",
    "失敗: {target}：{error}": "Failed: {target}: {error}",
    "失敗理由": "Failure reason",
    "実行中": "Running",
    "取り込みはプレビューで合流内容を確認してから登録します（新規のみ追加・既存維持）。": "Import first shows a preview of the merged result, then registers it (adds new entries only, keeps existing ones).",
    "取り込みました。追加：{n}件": "Imported. Added: {n} item(s)",
    "取り込みました。追加：{n}件。同期間隔を{interval}分に変更しました。": "Imported {n} entries. The Project sync interval is now {interval} minutes.",
    "取り込む": "Import",
    "取り込んで登録・同期": "Import, register and sync",
    "取り込んで登録しました。": "Imported and registered.",
    "取込の確認": "Confirm import",
    "取込プレビュー": "Import preview",
    "取込プレビュー OK: 「{name}」として登録できます。": "Import preview OK: can be registered as \"{name}\".",
    "取込内容を確認し、退避と転記に同意する": "I reviewed the imported content and agree to preserving the original and copying content",
    "取得": "Load",
    "取得SHA": "Fetched SHA",
    "取得ハッシュ: {hash}（保存時に一致確認）": "Fetched hash: {hash} (checked when saving)",
    "取得元": "Source",
    "取得元: {commit} 作成: {at}": "Source: {commit} created: {at}",
    "取得失敗: ": "Failed to load: ",
    "取得中": "Loading",
    "重複・矛盾候補を検査": "Check for duplicate/conflict candidates",
    "状態と再試行": "Status and retry",
    "状態を更新": "Refresh status",
    "新しいフォルダの絶対パスを入力してください。": "Enter the absolute path of the new folder.",
    "新しい表示名を入力してください。（1〜64文字・制御文字なし）": "Enter a new display name (1-64 characters, no control characters).",
    "新規登録": "New project",
    "新規登録へ": "Go to New project",
    "成功": "Success",
    "成功: {tail}": "Succeeded: {tail}",
    "切り替える": "Toggle",
    "設定・ヘルプ": "Settings & help",
    "設定（間隔・入出力）": "Settings (interval and import/export)",
    "設定をエクスポート（JSON保存）": "Export settings (save JSON)",
    "先に差分確認をしてください。確認直後の復元のみ受け付けます。": "Check the diff first. Only restores immediately after that check are accepted.",
    "選択": "Select",
    "選択ダイアログを開きました。フォルダを選んでください。": "The selection dialog is open. Choose a folder.",
    "選択なし": "Nothing selected",
    "選択の反映前差分": "Preview selected changes",
    "選択をやめる": "Cancel selection",
    "選択を開けませんでした: ": "Could not open the selection dialog: ",
    "選択を開けませんでした: {error}": "Could not open the selection dialog: {error}",
    "選択を終了しました。登録は行いません。": "Selection closed. Nothing was registered.",
    "選択を同期": "Sync selected",
    "選択を反映しました。プレビューで確認してください。": "Selection applied. Review it in the preview.",
    "操作": "Actions",
    "対象": "Target",
    "対象: ": "Target: ",
    "対象: {id}": "Target: {id}",
    "対象の変更": "Change targets",
    "対象を保存": "Save targets",
    "対象を保存しました。": "Targets saved.",
    "対象は一覧から1つ以上選んでください。": "Select at least one target from the list.",
    "対象外": "Out of scope",
    "待機中": "Waiting",
    "直近のみ表示。末尾の OK は成功、FAIL は失敗、SKIP は見送りです。": "Shows recent entries only. A trailing OK means success, FAIL means failure, and SKIP means skipped.",
    "追加・変更がありません。": "Nothing to add or change.",
    "追加：{name}": "Add: {name}",
    "追加内容を確認した": "I reviewed the added content",
    "適用する": "Apply",
    "登録して非表示で同期": "Register and sync in the background",
    "登録しました：{names}": "Registered: {names}",
    "登録しました。同期が成功しました。ログを確認してください。": "Registered. Sync succeeded. Check the log.",
    "登録しました。同期を開始しました(開始 {at})。完了まで確認します(最大約60秒)。": "Registered. Sync started (started {at}). Waiting for completion (up to about 60 seconds).",
    "登録しました。同期状態は未確認です。ログを確認してください。": "Registered. The sync state is unconfirmed. Check the log.",
    "登録しましたが同期が失敗しました。ログを確認してください。": "Registered, but the sync failed. Check the log.",
    "登録しましたが同期は見送られました(別の同期が実行中)。しばらくして今すぐ同期でやり直してください。": "Registered, but the sync was skipped (another sync is running). Try Sync now again later.",
    "登録しましたが同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。": "Registered, but the sync is unconfirmed (waiting to start or still running). Refresh later to check success or failure.",
    "登録する": "Register",
    "登録の確認": "Confirm registration",
    "登録は完了しましたが同期の起動に失敗しました。「今すぐ同期」でやり直してください。": "Registration completed, but the sync could not start. Retry with Sync now.",
    "登録プロジェクト数": "Registered projects",
    "登録一覧の管理と今すぐ同期を行います。配布ファイルの直接編集はしません。開始した処理はUIを閉じても継続しますが、両方の完了確認には画面を開いたままにしてください。": "Manage the project registry and run an immediate sync. Distributed files are never edited directly. Started work continues if you close the UI, but keep this screen open to confirm both completions.",
    "登録後の同期で AGENTS.md が生成・再生成されることを理解した": "I understand that AGENTS.md is generated or regenerated by the sync after registration",
    "統合同期の実行中はプレビュー適用できません。": "A preview cannot be applied while the combined sync is running.",
    "統合同期の実行中は選択同期できません。": "Selected projects cannot be synced while the combined sync is running.",
    "同期IDを取得できませんでした。": "Could not retrieve the sync ID.",
    "同期が失敗しました": "Sync failed",
    "同期が失敗しました。ログを確認してください。": "Sync failed. Check the log.",
    "同期が成功しました": "Sync succeeded",
    "同期が成功しました。ログを確認してください。": "Sync succeeded. Check the log.",
    "同期する": "Sync",
    "同期するプロジェクトを選択してください（一覧または状態表の選択欄）。": "Select the projects to sync (in the list or in the status table).",
    "同期できませんでした": "Sync could not run",
    "同期の起動に失敗しました": "Sync failed to start",
    "同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。": "Sync was skipped (another sync is running). Try again later.",
    "同期は見送りです": "Sync skipped",
    "同期は未確認です": "Sync unconfirmed",
    "同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。": "Sync is unconfirmed (waiting to start or still running). Refresh later to check success or failure.",
    "同期ログ": "Sync logs",
    "同期を開始できませんでした。": "The sync could not be started.",
    "同期を中断しました": "Sync interrupted",
    "同期間隔: {current}分 → {next}分に変更します（Projectのみ、Global不変）。": "Sync interval: {current} minutes -> {next} minutes (Project only, Global unchanged).",
    "同期間隔: 未設定 → {next}分に変更します（Projectのみ、Global不変）。": "Sync interval: not set -> {next} minutes (Project only, Global unchanged).",
    "同期間隔: {reason}": "Sync interval: {reason}",
    "同期間隔は Project タスクのみ変更します（Global は不変）。エクスポート・インポートに秘密情報は含みません。": "Only the Project task interval is changed here (Global is unchanged). Export and import never include secrets.",
    "同期状態": "Sync status",
    "同期状態は未確認です。ログを確認してください。": "The sync state is unconfirmed. Check the log.",
    "同期進捗": "Sync progress",
    "同期中": "Syncing",
    "読込中": "Loading",
    "内容": "Contents",
    "内容を表示": "Show content",
    "配る対象": "Targets to distribute",
    "配る対象の選択・自動同期の間隔と有効/無効を変えます。更新前バックアップと復元は「バックアップ」画面で行います。": "Choose distribution targets and change the automatic sync interval and enable/disable state. Pre-update backups and restores are handled on the Backups screen.",
    "配る対象を「{targets}」に変更します。よろしいですか。": "Change distribution targets to \"{targets}\"?",
    "配置元: {base}": "Source location: {base}",
    "配置先": "Destination",
    "反映前プレビュー": "Preview before applying",
    "表示言語": "Display language",
    "表示名の変更": "Change display name",
    "不正": "Invalid",
    "不正：{name}（{reason}）": "Invalid: {name} ({reason})",
    "伏字表示中の内容はそのまま保存できません（原本保護）。再取得しても伏字のままの場合、そのまま保存しないでください。": "Redacted content cannot be saved as-is (original protection). If it is still redacted after reloading, do not save it as-is.",
    "復元": "Restore",
    "復元しました。休止中のため再開は有効化してください。": "Restored. The target is paused; enable it to resume.",
    "復元しました。休止中のため再開は有効化してください。{warning}": "Restored. The target is paused; enable it to resume.{warning}",
    "復元する": "Restore",
    "復元の確認": "Confirm restore",
    "復元は AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。共通 GitHub 側の巻戻しはしません。": "Restore brings back AGENTS.md and localSource together, then pauses (disables) the target to prevent the next overwrite. It does not roll back the shared GitHub repository.",
    "復元前に Global 自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。差分で内容を確認してから復元します。": "Global automatic sync is paused before restoring and remains paused afterwards (enable it to resume). Review the diff before restoring.",
    "複数まとめて登録（1行1パス、最大20件。新規のみ。AGENTS.md ありは個別取込）。": "Register multiple projects (one path per line, up to 20; new projects only; projects with AGENTS.md must be imported individually).",
    "分": " min",
    "閉じる": "Close",
    "変更あり: {name}": "Changed: {name}",
    "変更あり: {target}": "Changed: {target}",
    "変更する": "Change",
    "変更なし: {name}": "No change: {name}",
    "変更なし: {target}": "No change: {target}",
    "保存しました。": "Saved.",
    "未確認": "Unconfirmed",
    "未確認です。しばらくして「選択の反映前差分」で再取得してください。": "Unconfirmed. Use Preview selected changes again later.",
    "未確認です。しばらくして「反映前プレビュー」で再取得してください。": "Unconfirmed. Use Preview before applying again later.",
    "未確認です。今回の実行結果がまだありません。": "Unconfirmed. This run has no result yet.",
    "未実行": "Not run",
    "未保存の変更があります": "You have unsaved changes.",
    "GitHubと連携すると対象を選択できます": "Connect to GitHub to select targets",
    "未設定": "Not set",
    "無効": "Disabled",
    "無効にしました（次回同期は対象外）。": "Disabled (excluded from the next sync).",
    "名称を変更しました。": "Display name changed.",
    "名称変更": "Rename",
    "名前": "Name",
    "有効": "Enabled",
    "有効/無効の切替": "Toggle enabled/disabled",
    "有効/無効を切替": "Toggle enabled/disabled",
    "有効にしました。": "Enabled.",
    "要求がタイムアウトしました。少し待って更新ボタンで確認してください。": "The request timed out. Wait a moment and refresh to check.",
    "例 C:\\Project\\A": "e.g. C:\\Project\\A",
    "例 C:\\Project\\MyRepo": "e.g. C:\\Project\\MyRepo",
    "GitHub連携": "GitHub integration",
    "ルールの取得元リポジトリを設定します。": "Set the repository that holds the rules.",
    "リポジトリ": "Repository",
    "ブランチ": "Branch",
    "ルールフォルダ": "Rule folder",
    "rules/（既定）": "rules/ (default)",
    "リポジトリ直下": "Repository root",
    "カスタム": "Custom",
    "接続テスト": "Test connection",
    "保存": "Save",
    "トークンを表示": "Show token",
    "トークンを隠す": "Hide token",
    "保存済みのトークンを使用します。": "Using the saved token.",
    "gh CLI のトークンを使用します。": "Using the gh CLI token.",
    "トークンが未設定です。": "No token is configured.",
    "Contents: Read and write 権限が必要です。空欄なら保存済みのトークンを使います。": "Requires the Contents: Read and write permission. Leave blank to keep the saved token.",
    "リポジトリを入力してください。": "Enter a repository.",
    "ブランチを入力してください。": "Enter a branch.",
    "接続を確認しています…": "Checking the connection...",
    "接続できました。": "Connected.",
    "保存しています…": "Saving...",
    "GitHub: 対象を追記しました（{targets}）。": "GitHub: added {targets} to the rule targets.",
    "GitHub: 追記は不要でした。": "GitHub: already up to date.",
    "GitHub: {reason}": "GitHub: {reason}",
    "GitHubへの追記に失敗しました：{reason}": "Could not add targets on GitHub: {reason}",
    "連携が未設定です。": "not configured.",
    "ルールファイルの保存先リポジトリを設定します": "Configure the repository where rule files are stored",
    "表示": "Show",
    "隠す": "Hide",
    "必要な権限: Contents (Read and write)。Fine-grained トークンを推奨します。": "Required permission: Contents (Read and write). Fine-grained tokens are recommended.",
    "トークンの形式が正しくありません (ghp_ または github_pat_ で始まる文字列)。": "Invalid token format (must start with ghp_ or github_pat_).",
    "GitHubでトークンを作成する": "Create a token on GitHub",
    "(新しいタブで開きます)": "(opens in a new tab)",
    "ルールの保存先": "Where to save rules",
    "GitHub上のどこにルールを保存するかを、3つの質問で決めます。": "Answer three questions to choose where your rules are stored on GitHub.",
    "① どのリポジトリに保存しますか?": "1. Which repository do you want to save to?",
    "例: Fizor-drm/Shirube": "e.g. Fizor-drm/Shirube",
    "GitHubのURL(https://github.com/…)をそのまま貼り付けてもOKです。": "You can also paste a full GitHub URL (https://github.com/...).",
    "読み取れませんでした。「ユーザー名/リポジトリ名」(例: Fizor-drm/Shirube)の形か、GitHubのURLを入力してください。": "Could not read the repository. Enter owner/repo (e.g. Fizor-drm/Shirube) or a GitHub URL.",
    "② どのブランチに保存しますか?": "2. Which branch do you want to save to?",
    "迷ったら「main」のままで大丈夫です。": "If you are unsure, leave it as \"main\".",
    "ブランチ名を入力してください(わからなければ main)。": "Enter a branch name (use \"main\" if unsure).",
    "③ ルールをどのフォルダに入れますか?": "3. Which folder should hold the rules?",
    "rules フォルダ": "rules folder",
    "おすすめ": "Recommended",
    "ルール専用のフォルダにまとめて保存します": "Keep rule files together in a dedicated folder",
    "リポジトリの一番上": "Repository root",
    "フォルダを作らず、直接ファイルを置きます": "Place files directly at the top of the repository",
    "別のフォルダを指定する": "Specify another folder",
    "すでに使いたいフォルダがある場合はこちら": "Choose this if you already have a folder you want to use",
    "フォルダの場所": "Folder path",
    "例: config/shirube/rules": "e.g. config/shirube/rules",
    "「/」で区切ると、フォルダの中のフォルダも指定できます。まだ無いフォルダは自動で作られます。": "Separate nested folders with \"/\". Missing folders are created automatically.",
    "フォルダの場所を入力してください。": "Enter a folder path.",
    "「..」は使えません。フォルダ名だけを入力してください。": "\"..\" is not allowed. Enter folder names only.",
    "使えない文字が含まれています(< > : \" | ? * など)。": "Contains invalid characters (such as < > : \" | ? *).",
    "この設定の場合": "With these settings",
    "リポジトリ名": "repository",
    "「{repo}」の「{branch}」ブランチにある「{folder}」フォルダの中に、ルールが1つずつファイルとして保存されます。": "Rule files will be saved one by one inside the \"{folder}\" folder on the \"{branch}\" branch of \"{repo}\".",
    "「{repo}」の「{branch}」ブランチの一番上に、ルールが1つずつファイルとして保存されます。": "Rule files will be saved one by one at the top of the \"{branch}\" branch of \"{repo}\".",
    "← ここに保存されます": "<- saved here",
    "ルール名.yml": "rule-name.yml",
    "キャンセル": "Cancel",
    "入力内容を確認してください。": "Please check the highlighted fields.",
    "取得元: {path}（SHA {sha}）": "Source: {path} (SHA {sha})",
    "GitHub連携が未設定のため編集できません。": "Editing is unavailable because GitHub integration is not configured.",
    "伏字表示中の内容はそのまま保存できません。再取得しても伏字のままの場合、そのまま保存しないでください。": "Masked content cannot be saved as-is. If it stays masked after reloading, do not save it.",
    "取得しました。": "Loaded.",
    "GitHub連携が未設定のため保存できません。": "Cannot save because GitHub integration is not configured.",
    "先に取得してください。": "Load it first.",
    "種別が変わりました。先に取得してください。": "The type changed. Load it again first.",
    "保存の確認": "Confirm save",
    "{kind} をGitHubへ保存します。よろしいですか。": "Save {kind} to GitHub?",
    "保存する": "Save",
    "ルール": "Rules",
    "共通ルール編集": "Edit common rules",
    "GitHub上の global.md / project.md を取得して編集・保存します。保存にはGitHub連携とトークンが必要です。取得時のSHAと一致した場合のみ更新します。": "Fetch, edit, and save global.md / project.md on GitHub. Saving requires GitHub integration and a token. Updates are written only when the SHA matches the fetched version.",
    "GitHub連携が未設定のため編集できません。上部のGitHubボタンから設定してください。": "Editing is unavailable because GitHub integration is not configured. Configure it with the GitHub button at the top.",
    "読込中です。完了してから保存してください。": "Loading. Wait for it to finish before saving.",
    "内容が更新されました。取得し直してから保存してください。": "The content changed. Load it again before saving.",
    "ルール種別": "Rule type",
    "ルール本文": "Rule body",
    "表示モード": "View mode",
    "編集": "Edit",
    "分割": "Split",
    "共通ルールプレビュー": "Shared rule preview",
    "テーブル": "Table",
    "プレビューを表示できません。ソースのみ編集できます。": "The preview is unavailable. Only the source text can be edited.",
    "プレビューの表示中にエラーが発生しました。": "The preview could not be rendered.",
    "本文が大きいためプレビューを省略しました。": "The text is too large, so the preview was skipped."
  },
  "zh-CN": {
    " 既存 AGENTS.md はバックアップ後に同期で再生成されます（固有内容は自動転記されません）。": " 现有 AGENTS.md 会在备份后由同步重新生成（其中专有内容不会自动转写）。",
    "・": "、",
    "、": "、",
    "(ファイルなし)": "（无文件）",
    "（一部省略）": "（部分省略）",
    "（差分あり）": "（有差异）",
    "（差分なし）": "（无差异）",
    "(省略)": "（省略）",
    "（同期間隔を{n}分に変更）": "（同步间隔已改为 {n} 分钟）",
    "（未設定）": "（未设置）",
    "{done}/2 Project同期: {state}": "{done}/2 Project 同步：{state}",
    "{n} 件": "{n} 项",
    "{selected} / {total} 件を選択中": "已选择 {selected} / {total} 项",
    "{n}件を登録し、非表示で同期します。よろしいですか。": "将注册 {n} 个项目并在后台同步。是否继续？",
    "{n}件を登録し、非表示で同期することを理解した": "我了解将注册 {n} 个项目并在后台同步",
    "{state}（対象 {targets}）": "{state}（对象：{targets}）",
    "「{id}」を復元します。AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。よろしいですか。": "将恢复“{id}”。AGENTS.md 与 localSource 会一起恢复，并暂停（禁用）目标以防止下次覆盖。是否继续？",
    "「{id}」を復元します。復元前にGlobal自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。よろしいですか。": "将恢复“{id}”。恢复前会暂停 Global 自动同步，恢复后仍保持暂停（重新启用即可恢复）。是否继续？",
    "「{name}」を一覧から解除します。ファイルは削除しません。よろしいですか。": "将从列表中解除“{name}”。不会删除文件。是否继续？",
    "「{name}」を取り込んで登録し、非表示で同期します。よろしいですか。": "将导入并注册“{name}”，然后在后台同步。是否继续？",
    "「{name}」を登録し、非表示で同期します。よろしいですか。": "将注册“{name}”并在后台同步。是否继续？",
    "【重複候補】{project}：{line}": "【重复候选项】{project}：{line}",
    "【矛盾候補】{project}：共通「{common}」/固有「{local}」": "【矛盾候选项】{project}：共用“{common}”/专属“{local}”",
    "0/2 Global同期: {state}": "0/2 Global 同步：{state}",
    "0/2 Global同期: 開始できませんでした": "0/2 Global 同步：无法开始",
    "0/2 Global同期を実行中": "0/2 正在执行 Global 同步",
    "0/2 待機中": "0/2 等待中",
    "0/2 同期に失敗しました": "0/2 同步失败",
    "0/2 同期を確認しています": "0/2 正在确认同步",
    "1/2 Global同期: {state} / Project同期を実行中": "1/2 Global 同步：{state} / 正在执行 Project 同步",
    "1/2 Project同期: {state}": "1/2 Project 同步：{state}",
    "1/2 Project同期: 開始できませんでした": "1/2 Project 同步：无法开始",
    "1/1 Global同期: {state}": "1/1 Global 同步：{state}",
    "1/1 Project同期: {state}": "1/1 Project 同步：{state}",
    "AGENTS.md なし: 登録後の同期で新規生成されます。既存 AGENTS.md がある場合は登録停止します。": "没有 AGENTS.md：注册后的同步会新建。如果存在现有 AGENTS.md，则停止注册。",
    "AGENTS.md は直接編集しません。": "不会直接编辑 AGENTS.md。",
    "AGENTSあり": "有 AGENTS",
    "AGENTSなし": "无 AGENTS",
    "Globalバックアップと復元": "Global 备份与恢复",
    "Globalプレビュー適用中です。": "正在应用 Global 预览。",
    "Global自動同期を休止します（裏の実行なし）。よろしいですか。": "暂停 Global 自动同步（不再后台执行）。是否继续？",
    "Global自動同期を有効にします。よろしいですか。": "启用 Global 自动同步。是否继续？",
    "Global設定": "Global 设置",
    "Global同期": "Global 同步",
    "Global同期: {summary}": "Global 同步：{summary}",
    "Global同期: 読込中": "Global 同步：加载中",
    "Global同期（選択した対象へ配布）": "Global 同步（分发到所选对象）",
    "Globalのみ": "仅 Global",
    "Globalのみ同期の確認": "确认仅 Global 同步",
    "Global同期（保存済み対象へ配布）を実行します。よろしいですか。": "将执行 Global 同步（分发到已保存对象）。是否继续？",
    "0/1 Global同期: {state}": "0/1 Global 同步：{state}",
    "0/1 Global同期: 開始できませんでした": "0/1 Global 同步：无法开始",
    "0/1 Global同期を実行中": "0/1 正在执行 Global 同步",
    "Global同期（保存済み対象へ配布）を実行し、完了を確認した後、登録済みプロジェクトの同期を実行します。よろしいですか。": "将执行 Global 同步（分发到已保存的对象），确认完成后，再同步已注册的项目。是否继续？",
    "Global同期が{state}のため、Project同期は実行しませんでした。": "由于 Global 同步为{state}，未执行 Project 同步。",
    "Global同期が失敗しました": "Global 同步失败",
    "Global同期が失敗しました。ログを確認してください。": "Global 同步失败。请查看日志。",
    "Global同期が成功しました": "Global 同步成功",
    "Global同期が成功しました。ログを確認してください。": "Global 同步成功。请查看日志。",
    "Global同期できませんでした": "无法执行 Global 同步",
    "Global同期の確認": "确认 Global 同步",
    "Global同期の間隔を{n}分に変更します（Projectは不変）。よろしいですか。": "将 Global 同步间隔改为 {n} 分钟（Project 不变）。是否继续？",
    "Global同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。": "Global 同步已跳过（另一个同步正在执行）。请稍后重试。",
    "Global同期は見送りです": "Global 同步已跳过",
    "Global同期は未確認です": "Global 同步未确认",
    "Global同期は未確認です(起動待ち/継続中)。しばらくして状態を更新してください。": "Global 同步未确认（等待启动/仍在执行）。请稍后刷新状态。",
    "Global同期ログ": "Global 同步日志",
    "Global同期状態は未確認です。ログを確認してください。": "Global 同步状态未确认。请查看日志。",
    "Global復元の確認": "确认 Global 恢复",
    "JSONを解釈できません。": "无法解析 JSON。",
    "localあり": "有 local",
    "localなし": "无 local",
    "NG: {path}：{error}": "NG：{path}：{error}",
    "OK: 「{name}」← {path}": "OK：“{name}”← {path}",
    "PC全体の共通ルールを配ります。Projectとは別の状態（最終成功・取得元・失敗理由）を持ちます。配布ファイルの直接編集はしません。": "分发整台 PC 共用的规则。其状态（最近成功、获取来源、失败原因）与 Project 分开管理。不会直接编辑分发的文件。",
    "Project 同期の間隔（分）": "Project 同步间隔（分钟）",
    "Project 同期の間隔を{n}分に変更します（Global は不変）。よろしいですか。": "将 Project 同步间隔改为 {n} 分钟（Global 不变）。是否继续？",
    "project-local.md なし: 共通ルールのみで生成されます。": "没有 project-local.md：仅使用共用规则生成。",
    "project-local.md を形式検証付きで編集します。保存時は取得時ハッシュと一致した場合のみ書換えます。検査結果は候補であり断定ではありません。": "在带格式校验的情况下编辑 project-local.md。保存时仅在当前哈希与获取时一致时才写入。检查结果只是候选项，并非定论。",
    "projects.json が正本です": "以 projects.json 为准",
    "Project同期できませんでした": "无法执行 Project 同步",
    "Project同期は未確認です": "Project 同步未确认",
    "Projectのみ": "仅 Project",
    "Projectのみ同期の確認": "确认仅 Project 同步",
    "Projectのみの同期を実行します。よろしいですか。": "将执行仅 Project 同步。是否继续？",
    "0/1 Project同期: {state}": "0/1 Project 同步：{state}",
    "0/1 Project同期: 開始できませんでした": "0/1 Project 同步：无法开始",
    "0/1 Project同期を実行中": "0/1 正在执行 Project 同步",
    "Project同期ログ": "Project 同步日志",
    "Shirube 管理": "Shirube 管理",
    "Shirube 管理ダッシュボード": "Shirube 管理仪表板",
    "Shirube 管理ダッシュボード (ローカルのみ、外部送信なし)": "Shirube 管理仪表板（仅本地，不会对外发送）",
    "いずれも候補であり、断定ではありません。内容を確認して判断してください。": "这些只是候选项，并非定论。请确认内容后自行判断。",
    "エクスプローラーで開きました: ": "已在资源管理器中打开：",
    "エクスプローラーで開く": "在资源管理器中打开",
    "エクスプローラーで開きました: {name}": "已在资源管理器中打开：{name}",
    "エクスポートしたJSONを貼り付け": "粘贴导出的 JSON",
    "エクスポートしました（秘密情報なし）。": "已导出（不包含机密信息）。",
    "キャンセルされました。登録は行いません。": "已取消。未执行注册。",
    "このPC専用。外部送信なし。": "仅限本机。不会对外发送。",
    "この内容でよければ「プレビューを適用」で反映します（反映前に再照合し、変化があれば拒否）。": "如果内容无误，点击“应用预览”即可生效（生效前会重新核对，如有变化则拒绝）。",
    "すべて解除": "全部清除",
    "すべて選択": "全选",
    "すべて同期": "全部同步",
    "すでにプレビュー適用中です。": "已在应用预览。",
    "すでに同期を実行中です。": "已在执行同步。",
    "パス": "路径",
    "パス: ": "路径：",
    "パスを1行ずつ入力してください。": "请每行输入一个路径。",
    "バックアップ": "备份",
    "バックアップがありません。": "没有备份。",
    "バックアップと復元": "备份与恢复",
    "フォルダのパスを入力するか「参照」で選択し、プレビューで内容を確認してから登録します。選択だけでは登録されません。既存 AGENTS.md がある場合は原則登録停止します（手動整理が必要）。登録後の同期で AGENTS.md は生成・再生成されます。": "输入文件夹路径或用“浏览”选择，在预览中确认内容后再注册。仅选择不会注册。如果存在现有 AGENTS.md，原则上停止注册（需要手动整理）。注册后的同步会生成或重新生成 AGENTS.md。",
    "プランID: {id}（選択を変えず「プレビューを適用」でこのプランを適用）": "计划 ID：{id}（保持选择不变，点击“应用预览”应用此计划）",
    "プランID: {id}（選択を変えず「選択を同期」でこのプランを適用）": "计划 ID：{id}（保持选择不变，点击“同步所选”应用此计划）",
    "プラン作成中": "正在创建计划",
    "プレビュー": "预览",
    "プレビュー OK: 「{name}」として登録できます。": "预览 OK：可以作为“{name}”注册。",
    "プレビューが無効です。もう一度プレビューしてください。": "预览已失效。请重新预览。",
    "プレビューをやり直してください。": "请重新预览。",
    "プレビューを適用": "应用预览",
    "プロジェクト": "项目",
    "プロジェクト一覧": "项目列表",
    "プロジェクト同期ダッシュボード": "项目同步仪表板",
    "ヘルプ": "帮助",
    "まだGlobal同期の状態がありません。今すぐ同期で初回実行できます。": "尚无 Global 同步状态。使用“立即同步”可执行首次同步。",
    "まだ登録がありません。右の新規登録から追加してください。": "尚未注册任何项目。请从右侧的“新建注册”添加。",
    "まだ同期状態がありません。今すぐ同期で初回実行できます。": "尚无同步状态。使用“立即同步”可执行首次同步。",
    "まだ表示していません。「内容を表示」で確認できます。": "尚未显示。点击“显示内容”即可查看。",
    "まとめてプレビュー": "批量预览",
    "まとめて登録して同期": "批量注册并同步",
    "やめる": "取消",
    "ローカルルール編集と検査": "本地规则编辑与检查",
    "ローカル編集": "本地编辑",
    "ログがありません。": "没有日志。",
    "ログなし": "无日志",
    "ログを更新": "刷新日志",
    "移動": "移动",
    "移動先の再指定": "重新指定目标位置",
    "移動先を更新しました。": "已更新目标位置。",
    "維持：{name}（{reason}）": "保留：{name}（{reason}）",
    "一括登録の確認": "确认批量注册",
    "一覧を更新": "刷新列表",
    "画面切替": "页面切换",
    "解除": "解除",
    "解除しました。一覧のみ変更し、ファイルは削除していません。": "已解除。仅更改列表，未删除文件。",
    "解除する": "解除",
    "解除の確認": "确认解除",
    "解除は一覧からのみ削除し、リポジトリ内のファイルは削除しません。「開く」で登録フォルダを開けます。": "解除只会从列表中删除，不会删除仓库中的文件。点击“打开”可打开已注册的文件夹。",
    "開く": "打开",
    "開けませんでした": "无法打开",
    "概要": "概览",
    "確認チェックを入れてください。": "请勾选确认项。",
    "確認済みプランで反映します（反映前に再照合し、変化があれば拒否）。よろしいですか。": "将应用已确认的计划（应用前会重新核对，如有变化则拒绝）。是否继续？",
    "確認中": "确认中",
    "管理バッチをダブルクリックするとこの画面が開きます。サーバーは 127.0.0.1 のみで待受けし、15分無操作で終了します。同期タスク自体はタスクスケジューラの設定どおり継続します。登録・解除は projects.json のみを変更します。": "双击管理批处理文件即可打开此页面。服务器仅在 127.0.0.1 上监听，15 分钟无操作后退出。同步任务本身会按任务计划程序的设置继续运行。注册与解除仅更改 projects.json。",
    "間隔（分）": "间隔（分钟）",
    "間隔の変更": "更改间隔",
    "間隔を変更": "更改间隔",
    "間隔を変更しました：{n}分": "间隔已改为 {n} 分钟",
    "間隔は5〜1440分の整数で指定してください。": "请输入 5 到 1440 之间的整数分钟数。",
    "既存 AGENTS.md (sha256:{hash}) を退避し、固有分を project-local.md へ転記します。": "将保留现有 AGENTS.md（sha256:{hash}），并把专属内容转入 project-local.md。",
    "既存 AGENTS.md の取込（無損失：原本を退避し固有分を project-local.md へ転記）。": "导入现有 AGENTS.md（无损：保留原文件，并将项目专属内容转入 project-local.md）。",
    "既存 AGENTS.md の置き換えを許可（バックアップ後、同期で再生成）": "允许替换现有 AGENTS.md（备份后由同步重新生成）",
    "既存 AGENTS.md をバックアップ後に同期で再生成します。AGENTS.md の固有内容は自動転記されません。必要な内容は project-local.md に手動転記してください。": "现有 AGENTS.md 会在备份后由同步重新生成。其中专有内容不会自动转写。请将需要的内容手动转入 project-local.md。",
    "既存 project-local.md あり(sha256:{hash}): 変更しません。": "存在现有 project-local.md（sha256:{hash}）：不会更改。",
    "起動待ち": "等待启动",
    "起動待ちです。子プロセスの起動を確認しています。": "等待启动。正在确认子进程是否已启动。",
    "休止しました。": "已暂停。",
    "休止中": "已暂停",
    "競合・不正があるため取り込めません。整理してから再実行してください。": "存在冲突或无效项，无法导入。请整理后重试。",
    "競合：{name}（{reason}）": "冲突：{name}（{reason}）",
    "共通SHA: {sha} 取得GitSHA: {commit} 作成: {at}": "共用 SHA：{sha} 获取的 Git SHA：{commit} 创建：{at}",
    "決定": "确定",
    "結果": "结果",
    "検査中": "检查中",
    "検索で絞り込み（名前・パス）": "按名称或路径筛选",
    "検証して保存": "校验并保存",
    "見送り": "跳过",
    "見送り: {name}（無効のため対象外）": "跳过：{name}（已禁用，不在范围内）",
    "見送りです。別の同期が実行中のため今回は見送りました。しばらくして今すぐ同期でやり直してください。": "已跳过。由于另一个同步正在执行，本次未运行。请稍后重新使用“立即同步”。",
    "現在の間隔：{n}分（Global）": "当前间隔：{n} 分钟（Global）",
    "現在の間隔：{n}分（Project のみ）": "当前间隔：{n} 分钟（仅 Project）",
    "現在の内容と配置先（実ファイルの先頭のみ表示）。設定ファイルの中身は表示しません。": "当前内容与部署位置（仅显示实际文件的开头）。不显示配置文件的内容。",
    "現在値": "当前值",
    "候補はありませんでした。": "没有找到候选项。",
    "更新": "更新",
    "今すぐ同期": "立即同步",
    "今すぐ同期の確認": "确认立即同步",
    "今回のログ未確認": "本次日志未确认",
    "Global: {global} / Project: {project}": "Global：{global} / Project：{project}",
    "差分": "差异",
    "差分あり": "有差异",
    "差分なし": "无差异",
    "差分取得中": "正在获取差异",
    "最終結果": "最终结果",
    "最終試行": "最近尝试",
    "最終試行・最終成功・取得SHA・失敗理由の一覧です。選択した同期・差分はチェック欄で選びます。": "显示最近尝试、最近成功、获取的 SHA 和失败原因的列表。使用复选框选择要同步或比较差异的项目。",
    "最終成功": "最近成功",
    "作成": "创建时间",
    "参照...": "浏览...",
    "時間切れのため選択を終了しました。登録は行いません。": "选择已超时结束。未执行注册。",
    "自動同期（Shirube Global Auto Sync）。ログオン時＋一定間隔で裏で実行します。": "自动同步（Shirube Global Auto Sync）。在登录时以及按固定间隔在后台运行。",
    "自動同期の状態を取得できませんでした。": "无法获取自动同步状态。",
    "自動同期は休止中です（裏の実行なし）。再開は切替ボタンで有効化してください。": "自动同步已暂停（不再后台执行）。重新启用请使用切换按钮。",
    "自動同期は有効です（次回も裏で実行）。": "自动同步已启用（下次仍会在后台运行）。",
    "自動同期": "自动同步",
    "自動同期: {state}": "自动同步：{state}",
    "自動同期の有効/無効": "自动同步启用/禁用",
    "状態不明": "状态未知",
    "失敗": "失败",
    "失敗: {name}：{error}": "失败：{name}：{error}",
    "失敗: {tail}": "失败：{tail}",
    "失敗: {target}：{error}": "失败：{target}：{error}",
    "失敗理由": "失败原因",
    "実行中": "运行中",
    "取り込みはプレビューで合流内容を確認してから登録します（新規のみ追加・既存維持）。": "导入时先通过预览确认合并内容，再执行注册（仅添加新项，保留现有项）。",
    "取り込みました。追加：{n}件": "已导入。新增：{n} 项",
    "取り込みました。追加：{n}件。同期間隔を{interval}分に変更しました。": "已导入 {n} 项。Project 同步间隔已更改为 {interval} 分钟。",
    "取り込む": "导入",
    "取り込んで登録・同期": "导入、注册并同步",
    "取り込んで登録しました。": "已导入并注册。",
    "取込の確認": "确认导入",
    "取込プレビュー": "导入预览",
    "取込プレビュー OK: 「{name}」として登録できます。": "导入预览 OK：可以作为“{name}”注册。",
    "取込内容を確認し、退避と転記に同意する": "我已确认导入内容，同意保留原文件并转写内容",
    "取得": "获取",
    "取得SHA": "获取的 SHA",
    "取得ハッシュ: {hash}（保存時に一致確認）": "获取的哈希：{hash}（保存时核对一致）",
    "取得元": "来源",
    "取得元: {commit} 作成: {at}": "来源：{commit} 创建：{at}",
    "取得失敗: ": "获取失败：",
    "取得中": "获取中",
    "重複・矛盾候補を検査": "检查重复与矛盾候选项",
    "状態と再試行": "状态与重试",
    "状態を更新": "刷新状态",
    "新しいフォルダの絶対パスを入力してください。": "请输入新文件夹的绝对路径。",
    "新しい表示名を入力してください。（1〜64文字・制御文字なし）": "请输入新的显示名称（1〜64 个字符，不含控制字符）。",
    "新規登録": "新建注册",
    "新規登録へ": "前往新建注册",
    "成功": "成功",
    "成功: {tail}": "成功：{tail}",
    "切り替える": "切换",
    "設定・ヘルプ": "设置与帮助",
    "設定（間隔・入出力）": "设置（间隔与导入导出）",
    "設定をエクスポート（JSON保存）": "导出设置（保存 JSON）",
    "先に差分確認をしてください。確認直後の復元のみ受け付けます。": "请先确认差异。仅接受确认后立即执行的恢复。",
    "選択": "选择",
    "選択ダイアログを開きました。フォルダを選んでください。": "已打开选择对话框。请选择文件夹。",
    "選択なし": "未选择",
    "選択の反映前差分": "所选项目的应用前差异",
    "選択をやめる": "取消选择",
    "選択を開けませんでした: ": "无法打开选择对话框：",
    "選択を開けませんでした: {error}": "无法打开选择对话框：{error}",
    "選択を終了しました。登録は行いません。": "已结束选择。未执行注册。",
    "選択を同期": "同步所选",
    "選択を反映しました。プレビューで確認してください。": "已应用选择。请在预览中确认。",
    "操作": "操作",
    "対象": "对象",
    "対象: ": "对象：",
    "対象: {id}": "对象：{id}",
    "対象の変更": "更改对象",
    "対象を保存": "保存对象",
    "対象を保存しました。": "已保存对象。",
    "対象は一覧から1つ以上選んでください。": "请从列表中选择至少一个对象。",
    "対象外": "不在范围",
    "待機中": "等待中",
    "直近のみ表示。末尾の OK は成功、FAIL は失敗、SKIP は見送りです。": "仅显示最近记录。末尾 OK 表示成功，FAIL 表示失败，SKIP 表示跳过。",
    "追加・変更がありません。": "没有需要添加或更改的内容。",
    "追加：{name}": "新增：{name}",
    "追加内容を確認した": "我已确认新增内容",
    "適用する": "应用",
    "登録して非表示で同期": "注册并在后台同步",
    "登録しました：{names}": "已注册：{names}",
    "登録しました。同期が成功しました。ログを確認してください。": "已注册。同步成功。请查看日志。",
    "登録しました。同期を開始しました(開始 {at})。完了まで確認します(最大約60秒)。": "已注册。同步已开始（开始时间 {at}）。将确认完成情况（最长约 60 秒）。",
    "登録しました。同期状態は未確認です。ログを確認してください。": "已注册。同步状态未确认。请查看日志。",
    "登録しましたが同期が失敗しました。ログを確認してください。": "已注册，但同步失败。请查看日志。",
    "登録しましたが同期は見送られました(別の同期が実行中)。しばらくして今すぐ同期でやり直してください。": "已注册，但同步被跳过（另一个同步正在执行）。请稍后重新使用“立即同步”。",
    "登録しましたが同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。": "已注册，但同步未确认（等待启动/仍在执行）。请稍后刷新以确认成功或失败。",
    "登録する": "注册",
    "登録の確認": "确认注册",
    "登録は完了しましたが同期の起動に失敗しました。「今すぐ同期」でやり直してください。": "注册已完成，但同步启动失败。请使用“立即同步”重试。",
    "登録プロジェクト数": "已注册项目数",
    "登録一覧の管理と今すぐ同期を行います。配布ファイルの直接編集はしません。開始した処理はUIを閉じても継続しますが、両方の完了確認には画面を開いたままにしてください。": "管理注册列表并立即执行同步。不会直接编辑分发的文件。已开始的处理即使关闭界面也会继续，但确认两边都完成时请保持此页面打开。",
    "登録後の同期で AGENTS.md が生成・再生成されることを理解した": "我了解注册后的同步会生成或重新生成 AGENTS.md",
    "統合同期の実行中はプレビュー適用できません。": "统合同步执行期间无法应用预览。",
    "統合同期の実行中は選択同期できません。": "统合同步执行期间无法同步所选项目。",
    "同期IDを取得できませんでした。": "无法获取同步 ID。",
    "同期が失敗しました": "同步失败",
    "同期が失敗しました。ログを確認してください。": "同步失败。请查看日志。",
    "同期が成功しました": "同步成功",
    "同期が成功しました。ログを確認してください。": "同步成功。请查看日志。",
    "同期する": "同步",
    "同期するプロジェクトを選択してください（一覧または状態表の選択欄）。": "请选择要同步的项目（在列表或状态表的复选框中）。",
    "同期できませんでした": "无法执行同步",
    "同期の起動に失敗しました": "同步启动失败",
    "同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。": "同步已跳过（另一个同步正在执行）。请稍后重试。",
    "同期は見送りです": "同步已跳过",
    "同期は未確認です": "同步未确认",
    "同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。": "同步未确认（等待启动/仍在执行）。请稍后刷新以确认成功或失败。",
    "同期ログ": "同步日志",
    "同期を開始できませんでした。": "无法开始同步。",
    "同期を中断しました": "同步已中断",
    "同期間隔: {current}分 → {next}分に変更します（Projectのみ、Global不変）。": "同步间隔：{current} 分钟 → 将改为 {next} 分钟（仅 Project，Global 不变）。",
    "同期間隔: 未設定 → {next}分に変更します（Projectのみ、Global不変）。": "同步间隔：未设置 → 将改为 {next} 分钟（仅 Project，Global 不变）。",
    "同期間隔: {reason}": "同步间隔：{reason}",
    "同期間隔は Project タスクのみ変更します（Global は不変）。エクスポート・インポートに秘密情報は含みません。": "此处仅更改 Project 任务的间隔（Global 不变）。导出和导入不包含机密信息。",
    "同期状態": "同步状态",
    "同期状態は未確認です。ログを確認してください。": "同步状态未确认。请查看日志。",
    "同期進捗": "同步进度",
    "同期中": "同步中",
    "読込中": "加载中",
    "内容": "内容",
    "内容を表示": "显示内容",
    "配る対象": "分发对象",
    "配る対象の選択・自動同期の間隔と有効/無効を変えます。更新前バックアップと復元は「バックアップ」画面で行います。": "选择分发对象，并更改自动同步的间隔与启用/禁用状态。更新前备份和恢复在“备份”页面进行。",
    "配る対象を「{targets}」に変更します。よろしいですか。": "将分发对象改为“{targets}”。是否继续？",
    "配置元: {base}": "来源位置：{base}",
    "配置先": "部署位置",
    "反映前プレビュー": "应用前预览",
    "表示言語": "显示语言",
    "表示名の変更": "更改显示名称",
    "不正": "无效",
    "不正：{name}（{reason}）": "无效：{name}（{reason}）",
    "伏字表示中の内容はそのまま保存できません（原本保護）。再取得しても伏字のままの場合、そのまま保存しないでください。": "脱敏显示的内容不能直接保存（保护原文件）。如果重新获取后仍为脱敏状态，请不要直接保存。",
    "復元": "恢复",
    "復元しました。休止中のため再開は有効化してください。": "已恢复。目标处于暂停状态，请重新启用以继续。",
    "復元しました。休止中のため再開は有効化してください。{warning}": "已恢复。目标处于暂停状态，请重新启用以继续。{warning}",
    "復元する": "恢复",
    "復元の確認": "确认恢复",
    "復元は AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。共通 GitHub 側の巻戻しはしません。": "恢复会同时还原 AGENTS.md 与 localSource，并暂停（禁用）目标以防止下次覆盖。不会回滚 GitHub 上的共享仓库。",
    "復元前に Global 自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。差分で内容を確認してから復元します。": "恢复前会暂停 Global 自动同步，恢复后仍保持暂停（重新启用即可恢复）。请先通过差异确认内容再恢复。",
    "複数まとめて登録（1行1パス、最大20件。新規のみ。AGENTS.md ありは個別取込）。": "批量注册多个项目（每行一个路径，最多 20 个；仅限新项目；存在 AGENTS.md 的项目需单独导入）。",
    "分": " 分钟",
    "閉じる": "关闭",
    "変更あり: {name}": "有更改：{name}",
    "変更あり: {target}": "有更改：{target}",
    "変更する": "更改",
    "変更なし: {name}": "无更改：{name}",
    "変更なし: {target}": "无更改：{target}",
    "保存しました。": "已保存。",
    "未確認": "未确认",
    "未確認です。しばらくして「選択の反映前差分」で再取得してください。": "未确认。请稍后使用“所选项目的应用前差异”重新获取。",
    "未確認です。しばらくして「反映前プレビュー」で再取得してください。": "未确认。请稍后使用“应用前预览”重新获取。",
    "未確認です。今回の実行結果がまだありません。": "未确认。本次执行尚无结果。",
    "未実行": "未执行",
    "未保存の変更があります": "有未保存的更改",
    "GitHubと連携すると対象を選択できます": "连接 GitHub 后即可选择目标",
    "未設定": "未设置",
    "無効": "禁用",
    "無効にしました（次回同期は対象外）。": "已禁用（下次同步不在范围内）。",
    "名称を変更しました。": "已更改名称。",
    "名称変更": "更改名称",
    "名前": "名称",
    "有効": "启用",
    "有効/無効の切替": "切换启用/禁用",
    "有効/無効を切替": "切换启用/禁用",
    "有効にしました。": "已启用。",
    "要求がタイムアウトしました。少し待って更新ボタンで確認してください。": "请求超时。请稍等后使用刷新按钮确认。",
    "例 C:\\Project\\A": "例：C:\\Project\\A",
    "例 C:\\Project\\MyRepo": "例：C:\\Project\\MyRepo",
    "GitHub連携": "GitHub 集成",
    "ルールの取得元リポジトリを設定します。": "设置规则来源仓库。",
    "リポジトリ": "仓库",
    "ブランチ": "分支",
    "ルールフォルダ": "规则文件夹",
    "rules/（既定）": "rules/（默认）",
    "リポジトリ直下": "仓库根目录",
    "カスタム": "自定义",
    "接続テスト": "测试连接",
    "保存": "保存",
    "トークンを表示": "显示令牌",
    "トークンを隠す": "隐藏令牌",
    "保存済みのトークンを使用します。": "使用已保存的令牌。",
    "gh CLI のトークンを使用します。": "使用 gh CLI 的令牌。",
    "トークンが未設定です。": "未设置令牌。",
    "Contents: Read and write 権限が必要です。空欄なら保存済みのトークンを使います。": "需要 Contents: Read and write 权限。留空则使用已保存的令牌。",
    "リポジトリを入力してください。": "请输入仓库。",
    "ブランチを入力してください。": "请输入分支。",
    "接続を確認しています…": "正在检查连接…",
    "接続できました。": "连接成功。",
    "保存しています…": "正在保存…",
    "GitHub: 対象を追記しました（{targets}）。": "GitHub：已将 {targets} 添加到规则目标。",
    "GitHub: 追記は不要でした。": "GitHub：无需追加。",
    "GitHub: {reason}": "GitHub：{reason}",
    "GitHubへの追記に失敗しました：{reason}": "无法在 GitHub 中添加目标：{reason}",
    "連携が未設定です。": "未设置。",
    "ルールファイルの保存先リポジトリを設定します": "设置用于保存规则文件的仓库",
    "表示": "显示",
    "隠す": "隐藏",
    "必要な権限: Contents (Read and write)。Fine-grained トークンを推奨します。": "所需权限：Contents (Read and write)。推荐使用 Fine-grained 令牌。",
    "トークンの形式が正しくありません (ghp_ または github_pat_ で始まる文字列)。": "令牌格式不正确（应以 ghp_ 或 github_pat_ 开头）。",
    "GitHubでトークンを作成する": "在 GitHub 上创建令牌",
    "(新しいタブで開きます)": "（在新标签页中打开）",
    "ルールの保存先": "规则保存位置",
    "GitHub上のどこにルールを保存するかを、3つの質問で決めます。": "通过 3 个问题决定将规则保存在 GitHub 的哪个位置。",
    "① どのリポジトリに保存しますか?": "① 要保存到哪个仓库？",
    "例: Fizor-drm/Shirube": "例：Fizor-drm/Shirube",
    "GitHubのURL(https://github.com/…)をそのまま貼り付けてもOKです。": "也可以直接粘贴 GitHub 网址（https://github.com/…）。",
    "読み取れませんでした。「ユーザー名/リポジトリ名」(例: Fizor-drm/Shirube)の形か、GitHubのURLを入力してください。": "无法识别。请输入“用户名/仓库名”（例：Fizor-drm/Shirube）或 GitHub 网址。",
    "② どのブランチに保存しますか?": "② 要保存到哪个分支？",
    "迷ったら「main」のままで大丈夫です。": "如果不确定，保持“main”即可。",
    "ブランチ名を入力してください(わからなければ main)。": "请输入分支名称（不确定请填 main）。",
    "③ ルールをどのフォルダに入れますか?": "③ 要将规则放入哪个文件夹？",
    "rules フォルダ": "rules 文件夹",
    "おすすめ": "推荐",
    "ルール専用のフォルダにまとめて保存します": "集中保存在专门的规则文件夹中",
    "リポジトリの一番上": "仓库最顶层",
    "フォルダを作らず、直接ファイルを置きます": "不创建文件夹，直接放置文件",
    "別のフォルダを指定する": "指定其他文件夹",
    "すでに使いたいフォルダがある場合はこちら": "如果已有想使用的文件夹请选择此项",
    "フォルダの場所": "文件夹路径",
    "例: config/shirube/rules": "例：config/shirube/rules",
    "「/」で区切ると、フォルダの中のフォルダも指定できます。まだ無いフォルダは自動で作られます。": "用“/”分隔即可指定子文件夹。不存在的文件夹会自动创建。",
    "フォルダの場所を入力してください。": "请输入文件夹路径。",
    "「..」は使えません。フォルダ名だけを入力してください。": "不能使用“..”，请只输入文件夹名称。",
    "使えない文字が含まれています(< > : \" | ? * など)。": "包含不可用的字符（如 < > : \" | ? * 等）。",
    "この設定の場合": "当前设置效果",
    "リポジトリ名": "仓库名",
    "「{repo}」の「{branch}」ブランチにある「{folder}」フォルダの中に、ルールが1つずつファイルとして保存されます。": "规则将作为单独的文件保存在“{repo}”的“{branch}”分支下的“{folder}”文件夹中。",
    "「{repo}」の「{branch}」ブランチの一番上に、ルールが1つずつファイルとして保存されます。": "规则将作为单独的文件保存在“{repo}”的“{branch}”分支最顶层。",
    "← ここに保存されます": "← 保存在这里",
    "ルール名.yml": "规则名.yml",
    "キャンセル": "取消",
    "入力内容を確認してください。": "请检查输入内容。",
    "取得元: {path}（SHA {sha}）": "来源：{path}（SHA {sha}）",
    "GitHub連携が未設定のため編集できません。": "GitHub 集成未配置，无法编辑。",
    "伏字表示中の内容はそのまま保存できません。再取得しても伏字のままの場合、そのまま保存しないでください。": "掩码显示的内容无法原样保存。重新获取后仍为掩码时，请不要直接保存。",
    "取得しました。": "已获取。",
    "GitHub連携が未設定のため保存できません。": "GitHub 集成未配置，无法保存。",
    "先に取得してください。": "请先获取。",
    "種別が変わりました。先に取得してください。": "类型已更改。请先重新获取。",
    "保存の確認": "确认保存",
    "{kind} をGitHubへ保存します。よろしいですか。": "将 {kind} 保存到 GitHub？",
    "保存する": "保存",
    "ルール": "规则",
    "共通ルール編集": "编辑共用规则",
    "GitHub上の global.md / project.md を取得して編集・保存します。保存にはGitHub連携とトークンが必要です。取得時のSHAと一致した場合のみ更新します。": "获取并编辑、保存 GitHub 上的 global.md / project.md。保存需要 GitHub 集成与令牌。仅当 SHA 与获取时一致时才会更新。",
    "GitHub連携が未設定のため編集できません。上部のGitHubボタンから設定してください。": "由于未设置 GitHub 集成，无法编辑。请通过顶部的 GitHub 按钮进行设置。",
    "読込中です。完了してから保存してください。": "正在加载。请等待完成后再保存。",
    "内容が更新されました。取得し直してから保存してください。": "内容已更新。请重新获取后再保存。",
    "ルール種別": "规则类型",
    "ルール本文": "规则正文",
    "表示モード": "显示模式",
    "編集": "编辑",
    "分割": "分栏",
    "共通ルールプレビュー": "共通规则预览",
    "テーブル": "表格",
    "プレビューを表示できません。ソースのみ編集できます。": "无法显示预览。仅可编辑源文本。",
    "プレビューの表示中にエラーが発生しました。": "显示预览时发生错误。",
    "本文が大きいためプレビューを省略しました。": "文本过大，已跳过预览。"
  }
};
let currentLang = "ja";
function safeLang(v){ return LANGS.indexOf(v) >= 0 ? v : "ja"; }
function storedLang(){
  try{
    const v = window.localStorage.getItem(LANG_KEY);
    return safeLang(v);
  }catch(e){ return "ja"; }
}
function saveLang(v){
  try{ window.localStorage.setItem(LANG_KEY, safeLang(v)); }catch(e){}
}
function decodeEscapedText(s){ return String(s).replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&amp;/g,"&"); }
function L(key, vars){
  const dict = I18N[currentLang];
  let s = (dict && Object.prototype.hasOwnProperty.call(dict, key)) ? dict[key] : key;
  if(vars && typeof s === "string") s = s.replace(/\{([^{}]+)\}/g, function(match, k){ return Object.prototype.hasOwnProperty.call(vars, k) ? String(vars[k]) : match; });
  try{
    const recipe = {key:key, vars:vars ? Object.assign({}, vars) : null};
    localizedText[currentLang].set(s, recipe);
    const visible = decodeEscapedText(s);
    if(visible !== s){
      const visibleVars = recipe.vars ? Object.assign({}, recipe.vars) : null;
      if(visibleVars) Object.keys(visibleVars).forEach(function(k){ if(typeof visibleVars[k] === "string") visibleVars[k] = decodeEscapedText(visibleVars[k]); });
      localizedText[currentLang].set(visible, {key:key, vars:visibleVars});
    }
  }catch(e){}
  return s;
}
function localizeGeneratedUI(fromLang){
  const ids = ["ovl","msgList","browseArea","prevArea","batchArea","importArea","msgStatus","planArea","msgGlobal","globalPlanArea","backupDiffArea","msgBackup","globalBackupDiffArea","msgGlobalBackup","localArea","checkArea","msgLocal","msgInterval","msgSettings","importRegArea","msgGlobalTargets","msgGlobalInterval"];
  function visit(n){
    if(!n) return;
    if(n.nodeType === 3){
      const raw = n.nodeValue || "";
      const map = localizedText[fromLang];
      const trimmed = raw.trim();
      const exact = map && map.get(raw);
      const entry = exact || (map && map.get(trimmed));
      if(entry){
        const leading = /^\s*/.exec(raw)[0], trailing = /\s*$/.exec(raw)[0];
        const vars = entry.vars ? Object.assign({}, entry.vars) : null;
        if(vars && Object.prototype.hasOwnProperty.call(vars, "state")){
          const states = ["実行中","起動待ち","成功","失敗","見送り","未確認","待機中"];
          for(let i=0;i<states.length;i++) if(String(vars.state) === ((I18N[fromLang] && I18N[fromLang][states[i]]) || states[i])){ vars.state = L(states[i]); break; }
        }
        const translated = L(entry.key, vars);
        n.nodeValue = exact ? translated : leading + translated + trailing;
      }
      return;
    }
    if(n.nodeType === 1 && /^(PRE|TEXTAREA|INPUT|SELECT|CODE)$/.test(n.tagName || "")) return;
    if(n.nodeType === 1 && (n.id === "ruleEditorWrap" || n.id === "rulePreview" || n.id === "rulePreviewPane")) return;
    const children = n.childNodes || [];
    for(let i=0;i<children.length;i++) visit(children[i]);
  }
  for(let i=0;i<ids.length;i++) try{ visit(document.getElementById(ids[i])); }catch(e){}
  function visitActions(n){
    if(!n) return;
    if(n.nodeType === 1 && n.tagName === "BUTTON"){ visit(n); return; }
    const children = n.childNodes || [];
    for(let i=0;i<children.length;i++) visitActions(children[i]);
  }
  ["backupRows","globalBackupRows"].forEach(function(id){ try{ visitActions(document.getElementById(id)); }catch(e){} });
  const backupRows = document.getElementById("backupRows");
  if(backupRows) Array.from(backupRows.children || []).forEach(function(row){
    const cell = row.children[3];
    if(cell && cell.dataset && cell.dataset.hasAgentsFile !== undefined){
      cell.textContent = L(cell.dataset.hasAgentsFile === "true" ? "AGENTSあり" : "AGENTSなし") + " / " + L(cell.dataset.hasLocalFile === "true" ? "localあり" : "localなし");
    }
  });
}
function applyStaticLanguage(){
  const groups = [
    ["[data-i18n]", "textContent", "data-i18n"],
    ["[data-i18n-placeholder]", "placeholder", "data-i18n-placeholder"],
    ["[data-i18n-title]", "title", "data-i18n-title"],
    ["[data-i18n-aria]", "aria-label", "data-i18n-aria"],
    ["[data-i18n-aria-valuetext]", "aria-valuetext", "data-i18n-aria-valuetext"]
  ];
  for(let i=0;i<groups.length;i++){
    const g = groups[i];
    const nodes = document.querySelectorAll(g[0]) || [];
    for(let j=0;j<nodes.length;j++){
      const n = nodes[j];
      try{
        const key = n.getAttribute(g[2]);
        if(key === null) continue;
        if(g[1] === "textContent") n.textContent = L(key);
        else n.setAttribute(g[1], L(key));
      }catch(e){}
    }
  }
  const sm = document.querySelector && document.querySelector(".summarybar section");
  if(sm) try{ sm.setAttribute("aria-label", L("概要")); }catch(e){}
}
function applyLanguage(lang, reload){
  const previousLang = currentLang;
  currentLang = safeLang(lang);
  try{ document.documentElement.lang = currentLang; }catch(e){}
  try{ document.title = L("Shirube 管理ダッシュボード"); }catch(e){}
  applyStaticLanguage();
  localizeGeneratedUI(previousLang);
  try{ if(typeof renderSyncState === "function") renderSyncState(); }catch(e){}
  try{ if(typeof renderGlobalContent === "function") renderGlobalContent(); }catch(e){}
  try{ if(typeof renderGlobalStatus === "function") renderGlobalStatus(); }catch(e){}
  try{ if(typeof renderGlobalTargetsUI === "function") renderGlobalTargetsUI(); }catch(e){}
  try{ if(typeof renderRulesLock === "function") renderRulesLock(); }catch(e){}
  try{ if(typeof ruleRenderPreviewNow === "function") ruleRenderPreviewNow(); }catch(e){}
  try{ if(typeof ruleEditorSetAria === "function") ruleEditorSetAria(); }catch(e){}
  try{ if(typeof ghRenderPreview === "function") ghRenderPreview(); }catch(e){}
  try{ if(lastBackupDiff) renderBackupDiff(document.getElementById("backupDiffArea"), lastBackupDiff); }catch(e){}
  try{ if(lastGlobalBackupDiff) renderGlobalBackupDiff(lastGlobalBackupDiff.data); }catch(e){}
  try{ if(typeof renderProjectLog === "function") renderProjectLog(); }catch(e){}
  try{ if(typeof renderGlobalLog === "function") renderGlobalLog(); }catch(e){}
  try{ const c=document.getElementById("stCount"); if(c) c.textContent=lastProjectCount===null?L("読込中"):L("{n} 件",{n:lastProjectCount}); }catch(e){}
  if(previousLang !== currentLang && localizedText[previousLang]) localizedText[previousLang].clear();
  try{ const sel = document.getElementById("selLang"); if(sel) sel.value = currentLang; }catch(e){}
  if(!reload) return;
  try{ if(typeof refresh === "function") refresh(); }catch(e){}
  try{ if(typeof refreshGlobal === "function") refreshGlobal(); }catch(e){}
  try{
    const b = document.getElementById("backups");
    if(b && !b.hidden){
      if(typeof loadBackups === "function") loadBackups();
      if(typeof loadGlobalBackups === "function") loadGlobalBackups();
    }
  }catch(e){}
}
function initLanguage(){
  applyLanguage(storedLang(), false);
  const sel = document.getElementById("selLang");
  if(sel){
    sel.value = currentLang;
    sel.onchange = function(){
      saveLang(sel.value);
      applyLanguage(sel.value, true);
    };
  }
}
function esc(s){ return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }
function stateJa(s){
  if(s==="running") return L("実行中");
  if(s==="waiting") return L("起動待ち");
  if(s==="success") return L("成功");
  if(s==="failed") return L("失敗");
  if(s==="skipped") return L("見送り");
  if(s==="unconfirmed") return L("未確認");
  return L("待機中");
}
function renderGlobalLog(){
  const pre = document.getElementById("globalLogPre");
  if(!pre) return;
  pre.textContent = !globalLogState.loaded ? L("読込中") : globalLogState.error ? L("取得失敗: ") + globalLogState.error : globalLogState.tail || L("ログがありません。");
}
let lastProjectCount = null;
let syncDisplayState = null;
let projectLogState = {loaded:false, tail:"", error:null};
function renderProjectLog(){
  const pre = document.getElementById("logPre");
  if(!pre) return;
  pre.textContent = !projectLogState.loaded ? L("読込中") : projectLogState.error ? L("取得失敗: ") + projectLogState.error : projectLogState.tail || L("ログがありません。");
}
function updateSyncUI(s){
  lastProjectCount = (s.count == null ? 0 : s.count);
  projectLogState = {loaded:true, tail:s.tail || "", error:null};
  document.getElementById("stCount").textContent = L("{n} 件", {n:lastProjectCount});
  renderProjectLog();
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
    if(!id || id === String(expected || "")){ renderSyncState(); return; }
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
  if(current){
    syncDisplayState = {source:commonSyncSource,status:current.syncState || (current.running ? "running" : "idle"),logName:current.logName || "",logMtime:current.logMtime || "",finalLine:current.finalLine || "",tail:current.tail || ""};
    renderSyncState();
  }
}
function renderSyncState(){
  const run = document.getElementById("stRun");
  const current = commonSyncStates[commonSyncSource];
  const detail = syncDisplayState;
  const count = document.getElementById("stCount");
  if(count) count.textContent = lastProjectCount === null ? L("読込中") : L("{n} 件", {n:lastProjectCount});
  if(detail){
    const label = detail.source === "global" ? "Global" : "Project";
    const log = (detail.logName || (detail.unified ? L("今回のログ未確認") : L("ログなし"))) + (detail.logMtime ? " (" + detail.logMtime + ")" : "");
    document.getElementById("stLog").textContent = log;
    document.getElementById("stLog").title = log;
    const result = detail.unified
      ? L("Global: {global} / Project: {project}", {global:stateJa(detail.globalState || "unconfirmed"), project:detail.projectState ? stateJa(detail.projectState) : L("未実行")})
      : label + ": " + stateJa(detail.status) + (detail.finalLine || detail.tail ? " " + (detail.finalLine || detail.tail).slice(-220) : "");
    document.getElementById("stTail").textContent = result;
    document.getElementById("stTail").title = result;
  }
  if(unifiedFinalState){
    run.textContent = stateJa(unifiedFinalState);
    run.dataset.state = unifiedFinalState;
    renderUnifiedProgress();
    return;
  }
  if(unifiedSyncActive){
    run.textContent = stateJa("running");
    run.dataset.state = "running";
    renderUnifiedProgress();
    return;
  }
  if(!current){
    run.textContent = L("読込中");
    document.getElementById("stTail").textContent = L("読込中");
    renderUnifiedProgress();
    return;
  }
  const status = current.syncState || (current.running ? "running" : "idle");
  const label = commonSyncSource === "global" ? "Global" : "Project";
  run.textContent = stateJa(status);
  run.dataset.state = status;
  const terminal = status === "success" || status === "failed" || status === "skipped";
  setUnifiedProgress(terminal ? 1 : 0, 1, label + ": " + stateJa(status), status === "running" || status === "waiting");
}
function resultJa(r){
  if(r === "success") return L("成功");
  if(r === "failed") return L("失敗");
  if(r === "skipped") return L("見送り");
  return L("未実行");
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
function selectedNamesIn(selector){
  const names = new Set();
  const boxes = document.querySelectorAll(selector);
  for(let i=0;i<boxes.length;i++) if(boxes[i].checked) names.add(boxes[i].value);
  return names;
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
function renderStatusTable(list, selected){
  if(!selected){ try{ selected = selectedNamesIn("#statusRows input.selbox"); }catch(e){ selected = new Set(); } }
  const tb = document.getElementById("statusRows");
  tb.innerHTML = "";
  document.getElementById("tblStatus").hidden = list.length === 0;
  document.getElementById("emptyStatus").hidden = list.length !== 0;
  list.forEach(function(e){
    const tr = document.createElement("tr");
    try{ tr.dataset.search = (e.name + " " + (e.displayName || "") + " " + (e.error || "")).toLowerCase(); }catch(e2){}
    const td0 = document.createElement("td");
    const cb = document.createElement("input"); cb.type = "checkbox"; cb.className = "selbox"; cb.value = e.name;
    cb.checked = selected.has(e.name);
    td0.appendChild(cb);
    const td1 = document.createElement("td"); td1.textContent = e.displayName || e.name; td1.title = e.name;
    const tdE = document.createElement("td"); tdE.textContent = (e.enabled !== false) ? L("有効") : L("無効");
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
  let st = "unconfirmed";
  if(r && r.sync === "started"){
    const dl = Date.now() + 60000;
    await refresh(dl);
    st = await pollUntilDone(r.syncId, 120, 500, dl);
    if(Date.now() < dl) await refresh(dl);
    if(st === "success") await showNotify(L("同期が成功しました"), L("同期が成功しました。ログを確認してください。"));
    else if(st === "failed") await showNotify(L("同期が失敗しました"), L("同期が失敗しました。ログを確認してください。"));
    else if(st === "skipped") await showNotify(L("同期は見送りです"), L("同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。"));
    else await showNotify(L("同期は未確認です"), L("同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。"));
  } else {
    await refresh();
    await showNotify(L("同期は未確認です"), L("同期状態は未確認です。ログを確認してください。"));
  }
  return st;
}
async function refresh(deadline){
  try{
    let t = 8000;
    if(typeof deadline === "number"){ t = Math.min(8000, deadline - Date.now()); if(t <= 0) return; }
    const [s, p, st] = await Promise.all([
      api("/api/status", "GET", null, t),
      api("/api/projects", "GET", null, t),
      api("/api/project-status", "GET", null, t).catch(function(){ return null; })
    ]);
    updateSyncUI(s);
    let enMap = {};
    let stList = [];
    if(st){
      stList = st.projects || [];
      stList.forEach(function(r){ enMap[r.name] = r.enabled; });
    }
    const tb = document.getElementById("rows");
    let selected = new Set(), selectedStatus = new Set();
    try{ selected = selectedNamesIn("#rows input.selbox"); selectedStatus = selectedNamesIn("#statusRows input.selbox"); }catch(e){}
    tb.innerHTML = "";
    document.getElementById("tbl").hidden = p.projects.length === 0;
    document.getElementById("emptyProj").hidden = p.projects.length !== 0;
    p.projects.forEach(function(e){
      const tr = document.createElement("tr");
      try{ tr.dataset.search = (e.name + " " + (e.displayName || "") + " " + e.path).toLowerCase(); }catch(e2){}
      const td0 = document.createElement("td");
      const cb = document.createElement("input"); cb.type = "checkbox"; cb.className = "selbox"; cb.value = e.name;
      cb.checked = selected.has(e.name);
      td0.appendChild(cb);
      const td1 = document.createElement("td"); td1.textContent = e.displayName || e.name; td1.title = e.name;
      const td2 = document.createElement("td"); const c = document.createElement("code"); c.className = "path"; c.textContent = e.path; td2.appendChild(c);
      const tdE = document.createElement("td");
      const enB = document.createElement("button"); const en = (enMap[e.name] !== false);
      enB.textContent = en ? L("有効") : L("無効");
      enB.onclick = async function(){
        try{ await api("/api/enabled","POST",{name:e.name,enabled:!en}); setMsg("msgList",(en ? L("無効にしました（次回同期は対象外）。") : L("有効にしました。")),true); refresh(); }
        catch(err){ setMsg("msgList", err.message, false); }
      };
      tdE.appendChild(enB);
      const td3 = document.createElement("td");
      const acts = document.createElement("div"); acts.className = "acts";
      const bo = document.createElement("button"); bo.textContent = L("開く"); bo.title = L("エクスプローラーで開く"); bo.setAttribute("aria-label", L("エクスプローラーで開く")); bo.className = "opbtn";
      bo.onclick = async function(){
        try{ await api("/api/open","POST",{name:e.name}); setMsg("msgList",L("エクスプローラーで開きました: {name}",{name:e.name}),true); }
        catch(err){ await showNotify(L("開けませんでした"), err.message); }
      };
      const br2 = document.createElement("button"); br2.textContent = L("名称変更");
      br2.onclick = async function(){
        const nn = await showModalInput(L("表示名の変更"), L("新しい表示名を入力してください。（1〜64文字・制御文字なし）"), e.displayName || e.name);
        if(nn === null) return;
        try{ await api("/api/rename","POST",{oldName:e.name,newName:nn}); setMsg("msgList",L("名称を変更しました。"),true); refresh(); }
        catch(err){ setMsg("msgList", err.message, false); }
      };
      const bm = document.createElement("button"); bm.textContent = L("移動");
      bm.onclick = async function(){
        const np = await showModalInput(L("移動先の再指定"), L("新しいフォルダの絶対パスを入力してください。"), e.path);
        if(np === null) return;
        try{ await api("/api/move","POST",{name:e.name,newPath:np}); setMsg("msgList",L("移動先を更新しました。"),true); refresh(); }
        catch(err){ setMsg("msgList", err.message, false); }
      };
      const b = document.createElement("button"); b.textContent = L("解除"); b.className = "danger";
      b.onclick = async function(){
        const ok = await showConfirm(L("解除の確認"), L("「{name}」を一覧から解除します。ファイルは削除しません。よろしいですか。", {name:e.name}), L("解除する"), L("やめる"));
        if(!ok) return;
        try{ await api("/api/unregister","POST",{name:e.name}); setMsg("msgList",L("解除しました。一覧のみ変更し、ファイルは削除していません。"),true); refresh(); }catch(err){ setMsg("msgList", err.message, false); } };
      td3.appendChild(acts); acts.appendChild(bo); acts.appendChild(br2); acts.appendChild(bm); acts.appendChild(b);
      tr.appendChild(td0); tr.appendChild(td1); tr.appendChild(td2); tr.appendChild(tdE); tr.appendChild(td3); tb.appendChild(tr);
    });
    try{ renderStatusTable(stList, selectedStatus); }catch(e){}
    try{ applySearchFilter(); }catch(e2){}
    try{ fillLocalSelect(p.projects); }catch(e){}
  }catch(e){ projectLogState = {loaded:true, tail:"", error:e.message}; renderProjectLog(); }
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
  return showModal(title, msg, [{label:L("決定"), primary:true, useInput:true, value:null},{label:L("やめる"), primary:false, value:null}], (initial === undefined ? "" : initial));
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
function showNotify(title, msg){ return showModal(title, msg, [{label:L("閉じる"), primary:true, value:true}]); }
function showConfirm(title, msg, okLabel, cancelLabel){ return showModal(title, msg, [{label:okLabel, primary:true, value:true},{label:cancelLabel, primary:false, value:false}]); }
let lastPreview = null;
let lastPreviewGen = 0;
let previewGen = 0;
async function doPreview(pathVal){
  const myGen = ++previewGen;
  const pa = document.getElementById("prevArea"); pa.innerHTML = "<p class='muted'>"+L("確認中")+"</p>";
  try{
    const forceReplace = !!(document.getElementById("ckForceReplace") && document.getElementById("ckForceReplace").checked);
    const v = await api("/api/preview","POST",{path:pathVal, forceReplace:forceReplace});
    if(myGen !== previewGen){ return; }
    lastPreview = v;
    lastPreviewGen = myGen;
    let h = "<p class='ok'>"+L("プレビュー OK: 「{name}」として登録できます。", {name:esc(v.name)})+"</p>";
    h += "<p class='muted'>"+L("パス: ")+"<code class='path'>"+esc(v.path)+"</code></p>";
    if(v.hasAgents){
      h += "<p class='warn'>"+L("既存 AGENTS.md をバックアップ後に同期で再生成します。AGENTS.md の固有内容は自動転記されません。必要な内容は project-local.md に手動転記してください。")+"</p>";
    } else {
      h += "<p class='muted'>"+L("AGENTS.md なし: 登録後の同期で新規生成されます。既存 AGENTS.md がある場合は登録停止します。")+"</p>";
    }
    if(v.hasLocal) h += "<p class='muted'>"+L("既存 project-local.md あり(sha256:{hash}): 変更しません。", {hash:esc((v.localHash||"").slice(0,12))})+"</p>";
    else h += "<p class='muted'>"+L("project-local.md なし: 共通ルールのみで生成されます。")+"</p>";
    h += "<label class='chk'><input type='checkbox' id='ck1'> "+L("登録後の同期で AGENTS.md が生成・再生成されることを理解した")+"</label>";
    h += "<div class='btnrow'><button id='btnReg' class='primary'>"+L("登録して非表示で同期")+"</button></div><div id='msgReg' role='status'></div>";
    pa.innerHTML = h;
    document.getElementById("btnReg").onclick = async function(){
      const btn = document.getElementById("btnReg"); btn.disabled = true;
      try{
        if(!lastPreview || lastPreview !== v || previewGen !== lastPreviewGen) throw new Error(L("プレビューが無効です。もう一度プレビューしてください。"));
        if(!document.getElementById("ck1") || !document.getElementById("ck1").checked) throw new Error(L("確認チェックを入れてください。"));
        const warnMsg = v.hasAgents ? L(" 既存 AGENTS.md はバックアップ後に同期で再生成されます（固有内容は自動転記されません）。") : "";
        const okGo = await showConfirm(L("登録の確認"), L("「{name}」を登録し、非表示で同期します。よろしいですか。", {name:v.name}) + warnMsg, L("登録する"), L("やめる"));
        if(!okGo){ return; }
        if(!lastPreview || lastPreview !== v || previewGen !== lastPreviewGen) throw new Error(L("プレビューが無効です。もう一度プレビューしてください。"));
        if(!document.getElementById("ck1") || !document.getElementById("ck1").checked) throw new Error(L("確認チェックを入れてください。"));
        const fr = !!(document.getElementById("ckForceReplace") && document.getElementById("ckForceReplace").checked);
        const r = await api("/api/register","POST",{path:v.path,previewId:v.previewId,confirm:true,forceReplace:fr});
        if(r.sync === "started"){
          setMsgHtml("msgReg",true,L("登録しました。同期を開始しました(開始 {at})。完了まで確認します(最大約60秒)。", {at:(r.syncAt||"")}));
          document.getElementById("inpPath").value = ""; lastPreview = null; const _ck = document.getElementById("ckForceReplace"); if(_ck) _ck.checked = false;
          const dl = Date.now() + 60000;
          await refresh(dl);
          const st = await pollUntilDone(r.syncId, 120, 500, dl);
          if(st === "success"){ setMsgHtml("msgReg",true,L("登録しました。同期が成功しました。ログを確認してください。")); await showNotify(L("同期が成功しました"), L("登録しました。同期が成功しました。ログを確認してください。")); }
          else if(st === "failed"){ setMsgHtml("msgReg",false,L("登録しましたが同期が失敗しました。ログを確認してください。")); await showNotify(L("同期が失敗しました"), L("登録しましたが同期が失敗しました。ログを確認してください。")); }
          else if(st === "skipped"){ setMsgHtml("msgReg",false,L("登録しましたが同期は見送られました(別の同期が実行中)。しばらくして今すぐ同期でやり直してください。")); await showNotify(L("同期は見送りです"), L("登録しましたが同期は見送られました(別の同期が実行中)。しばらくして今すぐ同期でやり直してください。")); }
          else{ setMsgHtml("msgReg",false,L("登録しましたが同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。")); await showNotify(L("同期は未確認です"), L("登録しましたが同期は未確認です(起動待ち/継続中)。しばらくして更新ボタンで成功・失敗を確認してください。")); }
          if(Date.now() < dl) await refresh(dl);
        } else if(r.sync === "launch-failed"){
          setMsgHtml("msgReg",false,L("登録は完了しましたが同期の起動に失敗しました。「今すぐ同期」でやり直してください。"));
          await showNotify(L("同期の起動に失敗しました"), L("登録は完了しましたが同期の起動に失敗しました。「今すぐ同期」でやり直してください。"));
          document.getElementById("inpPath").value = ""; lastPreview = null; const _ck = document.getElementById("ckForceReplace"); if(_ck) _ck.checked = false; await refresh();
        } else {
          setMsgHtml("msgReg",false,L("登録しました。同期状態は未確認です。ログを確認してください。"));
          await showNotify(L("同期は未確認です"), L("登録しました。同期状態は未確認です。ログを確認してください。"));
          await refresh();
        }
      }catch(e){ setMsg("msgReg", e.message, false); }finally{ try{ btn.disabled = false; }catch(e2){} try{ safeFocus(btn); }catch(e3){} }
    };
  }catch(e){ if(myGen !== previewGen){ return; } pa.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; lastPreview = null; lastPreviewGen = 0; }
}
document.getElementById("btnPrev").onclick = async function(){ await doPreview(document.getElementById("inpPath").value); };
const ckForce = document.getElementById("ckForceReplace");
if(ckForce){ ckForce.onchange = function(){ lastPreview = null; lastPreviewGen = 0; previewGen++; const pa = document.getElementById("prevArea"); if(pa) pa.innerHTML = "<p class='muted'>"+L("プレビューをやり直してください。")+"</p>"; const br = document.getElementById("btnReg"); if(br) br.disabled = true; }; }
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
    ba.textContent = L("選択ダイアログを開きました。フォルダを選んでください。");
    const cb = document.createElement("button"); cb.textContent = L("選択をやめる"); cb.style.marginLeft = "8px";
    cb.onclick = async function(){ browseCancel = true; try{ await api("/api/browse/cancel","POST",{browseId:bid}); }catch(e){} };
    ba.appendChild(cb);
    const dl = Date.now() + 120000;
    const r = await pollBrowse(bid, dl, myGen);
    if(browseCancel || myGen !== browseGen){ ba.textContent = L("キャンセルされました。登録は行いません。"); return; }
    ba.textContent = "";
    if(r === "timeout"){
      try{ await api("/api/browse/cancel","POST",{browseId:bid}); }catch(e){}
      ba.textContent = L("時間切れのため選択を終了しました。登録は行いません。");
    } else if(r === "cancelled" || (r && r.status === "cancelled")){
      ba.textContent = L("キャンセルされました。登録は行いません。");
    } else if(r && r.status === "selected"){
      if(browseCancel || myGen !== browseGen){ ba.textContent = L("キャンセルされました。登録は行いません。"); return; }
      document.getElementById("inpPath").value = r.path || "";
      ba.textContent = L("選択を反映しました。プレビューで確認してください。");
      await doPreview(document.getElementById("inpPath").value);
    } else {
      ba.textContent = L("選択を終了しました。登録は行いません。");
    }
  }catch(e){ try{ ba.textContent = L("選択を開けませんでした: {error}",{error:e.message}); }catch(e2){} }
  finally{ try{ bb.disabled = false; }catch(e3){} try{ safeFocus(bb); }catch(e4){} }
};
document.getElementById("btnSync").onclick = async function(){
  const b = document.getElementById("btnSync");
  if(unifiedSyncActive){ await showNotify(L("同期中"), L("すでに同期を実行中です。")); return; }
  if(globalApplyInflight){ await showNotify(L("同期中"), L("Globalプレビュー適用中です。")); return; }
  unifiedSyncActive = true;
  let accepted = false;
  let finalGlobalState = null;
  let finalProjectState = null;
  const originallyDisabled = b.disabled;
  b.disabled = true;
  try{
    const okGo = await showConfirm(L("今すぐ同期の確認"), L("Global同期（保存済み対象へ配布）を実行し、完了を確認した後、登録済みプロジェクトの同期を実行します。よろしいですか。"), L("同期する"), L("やめる"));
    if(!okGo){ return; }
    accepted = true;
  unifiedBaselineProjectRunId = unifiedObservedProjectRunId;
  unifiedBaselineGlobalRunId = unifiedObservedGlobalRunId;
    unifiedStateLock = true;
    unifiedFinalState = null;
    unifiedProjectRunId = null;
    unifiedGlobalRunId = null;
    setUnifiedProgress(0, 2, L("0/2 同期を確認しています"), false);
    try{ const sr=document.getElementById("stRun"); sr.textContent=L("実行中"); sr.dataset.state="running"; }catch(e){}
    setUnifiedProgress(0, 2, L("0/2 Global同期を実行中"), false);
    let gr = null;
    try{ gr = await api("/api/global-sync","POST",{}); }catch(e){ setUnifiedProgress(0, 2, L("0/2 Global同期: 開始できませんでした"), false); await showNotify(L("Global同期できませんでした"), e.message); unifiedFinalState = "unconfirmed"; finalGlobalState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
    if(!gr || gr.sync !== "started"){ setUnifiedProgress(0, 2, L("0/2 Global同期: 開始できませんでした"), false); await showNotify(L("Global同期できませんでした"), L("同期を開始できませんでした。")); unifiedFinalState = "failed"; finalGlobalState = "failed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("failed"); sr.dataset.state="failed"; }catch(e2){} return; }
    if(!gr.syncId){ setUnifiedProgress(0, 2, L("0/2 Global同期: {state}", {state:stateJa("unconfirmed")}), false); await showNotify(L("Global同期は未確認です"), L("同期IDを取得できませんでした。")); unifiedFinalState = "unconfirmed"; finalGlobalState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
     unifiedGlobalRunId = gr.syncId;
    const gdl = Date.now() + 60000;
    await refreshGlobal(gdl);
    const gst = await pollGlobalUntilDone(gr.syncId, 120, 500, gdl);
    if(Date.now() < gdl) await refreshGlobal(gdl);
    const globalState = gst || "unconfirmed";
    finalGlobalState = globalState;
    if(globalState === "unconfirmed" || globalState === "skipped"){
      try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa(globalState); sr.dataset.state=globalState; }catch(e){}
      setUnifiedProgress(0, 2, L("0/2 Global同期: {state}", {state:stateJa(globalState)}), false);
      await showNotify(L("同期を中断しました"), L("Global同期が{state}のため、Project同期は実行しませんでした。", {state:stateJa(globalState)}));
      if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; }
      unifiedFinalState = globalState;
      return;
    }
    setUnifiedProgress(1, 2, L("1/2 Global同期: {state} / Project同期を実行中", {state:stateJa(globalState)}), false);
    let pr = null;
    try{ pr = await api("/api/sync","POST",{}); }catch(e){ setUnifiedProgress(1, 2, L("1/2 Project同期: 開始できませんでした"), false); await showNotify(L("Project同期できませんでした"), e.message); if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; } unifiedFinalState = "unconfirmed"; finalProjectState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
    if(!pr || pr.sync !== "started"){ setUnifiedProgress(1, 2, L("1/2 Project同期: 開始できませんでした"), false); await showNotify(L("Project同期できませんでした"), L("同期を開始できませんでした。")); unifiedFinalState = "failed"; finalProjectState = "failed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("failed"); sr.dataset.state="failed"; }catch(e2){} return; }
    if(!pr.syncId){ setUnifiedProgress(1, 2, L("1/2 Project同期: {state}", {state:stateJa("unconfirmed")}), false); await showNotify(L("Project同期は未確認です"), L("同期IDを取得できませんでした。")); unifiedFinalState = "unconfirmed"; finalProjectState = "unconfirmed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("unconfirmed"); sr.dataset.state="unconfirmed"; }catch(e2){} return; }
    unifiedProjectRunId = pr.syncId;
    const pdl = Date.now() + 60000;
    await refresh(pdl);
    const pst = await pollUntilDone(pr.syncId, 120, 500, pdl);
    if(Date.now() < pdl) await refresh(pdl);
    const projectState = pst || "unconfirmed";
    finalProjectState = projectState;
    let agg = "failed";
    if(globalState === "success" && projectState === "success") agg = "success";
    else if(projectState === "unconfirmed") agg = "unconfirmed";
    else if(projectState === "skipped") agg = "skipped";
    try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa(agg); sr.dataset.state=agg; }catch(e){}
    const projTerminal = (projectState === "success" || projectState === "failed" || projectState === "skipped");
    const projCompleted = projTerminal ? 2 : 1;
    setUnifiedProgress(projCompleted, 2, L("{done}/2 Project同期: {state}", {done:projCompleted, state:stateJa(projectState)}), false);
    if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; }
    unifiedFinalState = agg;
    const parts = L("Global: {global} / Project: {project}", {global:stateJa(globalState), project:stateJa(projectState)});
    const latestProject = commonSyncStates.project;
    if(latestProject){
      const log = (latestProject.logName || L("ログなし")) + (latestProject.logMtime ? " (" + latestProject.logMtime + ")" : "");
      document.getElementById("stLog").textContent = log;
      document.getElementById("stLog").title = log;
    }
    document.getElementById("stTail").textContent = parts;
    document.getElementById("stTail").title = parts;
    if(agg === "success") await showNotify(L("同期が成功しました"), parts);
    else if(agg === "skipped") await showNotify(L("同期は見送りです"), parts);
    else if(agg === "unconfirmed") await showNotify(L("同期は未確認です"), parts);
    else await showNotify(L("同期が失敗しました"), parts);
  }catch(e){ try{ await showNotify(L("同期できませんでした"), e.message); }catch(e2){} if(unifiedProjectRunId){ completedUnifiedRunIds[unifiedProjectRunId] = true; finalProjectState = finalProjectState || "unconfirmed"; } finalGlobalState = finalGlobalState || "failed"; unifiedFinalState = "failed"; try{ const sr=document.getElementById("stRun"); sr.textContent=stateJa("failed"); sr.dataset.state="failed"; }catch(e){} setUnifiedProgress(0, 2, L("0/2 同期に失敗しました"), false); }
  finally{
    if(accepted && unifiedFinalState){
      const global = commonSyncStates.global;
      const project = commonSyncStates.project;
      const globalMatches = global && unifiedGlobalRunId && global.syncId === unifiedGlobalRunId;
      const projectMatches = project && unifiedProjectRunId && project.syncId === unifiedProjectRunId;
      const logState = projectMatches ? project : (globalMatches ? global : null);
      syncDisplayState = {unified:true, status:unifiedFinalState,
        globalState:finalGlobalState || (globalMatches ? global.syncState : unifiedFinalState),
        projectState:finalProjectState,
        source:projectMatches ? "project" : "global",
        logName:logState ? (logState.logName || "") : "",
        logMtime:logState ? (logState.logMtime || "") : ""};
      renderSyncState();
    }
    unifiedSyncActive = false;
    unifiedStateLock = false;
    try{ b.disabled = originallyDisabled; }catch(e3){}
    try{ safeFocus(b); }catch(e4){}
  }
};
function singleSyncTerminal(st){ return st === "success" || st === "failed" || st === "skipped"; }
function beginSingleSyncScope(scope){
  unifiedBaselineProjectRunId = unifiedObservedProjectRunId;
  unifiedBaselineGlobalRunId = unifiedObservedGlobalRunId;
  unifiedFinalState = null;
  unifiedProjectRunId = null;
  unifiedGlobalRunId = null;
  unifiedStateLock = true;
  commonSyncSource = scope;
  setUnifiedProgress(0, 1, scope === "global" ? L("0/1 Global同期を実行中") : L("0/1 Project同期を実行中"), false);
  renderSyncState();
}
function finishSingleSyncScope(scope, started){
  if(started && unifiedFinalState){
    const cur = commonSyncStates[scope];
    const rid = scope === "global" ? unifiedGlobalRunId : unifiedProjectRunId;
    const match = cur && rid && cur.syncId === rid;
    syncDisplayState = {unified:false, source:scope, status:unifiedFinalState, logName:match?(cur.logName||""):"", logMtime:match?(cur.logMtime||""):""};
    renderSyncState();
  }
  unifiedSyncActive = false;
  unifiedStateLock = false;
}
document.getElementById("btnSyncGlobalOnly").onclick = async function(){
  const b = document.getElementById("btnSyncGlobalOnly");
  if(unifiedSyncActive){ await showNotify(L("同期中"), L("すでに同期を実行中です。")); return; }
  if(globalApplyInflight){ await showNotify(L("同期中"), L("Globalプレビュー適用中です。")); return; }
  const originallyDisabled = b.disabled;
  unifiedSyncActive = true;
  b.disabled = true;
  let started = false;
  try{
    const okGo = await showConfirm(L("Globalのみ同期の確認"), L("Global同期（保存済み対象へ配布）を実行します。よろしいですか。"), L("同期する"), L("やめる"));
    if(!okGo){ return; }
    started = true;
    beginSingleSyncScope("global");
    let gr = null;
    try{ gr = await api("/api/global-sync","POST",{}); }
    catch(e){
      setUnifiedProgress(0, 1, L("0/1 Global同期: 開始できませんでした"), false);
      await showNotify(L("Global同期できませんでした"), e.message);
      unifiedFinalState = "unconfirmed";
      return;
    }
    if(!gr || gr.sync !== "started"){
      setUnifiedProgress(0, 1, L("0/1 Global同期: 開始できませんでした"), false);
      await showNotify(L("Global同期できませんでした"), L("同期を開始できませんでした。"));
      unifiedFinalState = "failed";
      return;
    }
    if(!gr.syncId){
      setUnifiedProgress(0, 1, L("0/1 Global同期: {state}", {state:stateJa("unconfirmed")}), false);
      await showNotify(L("Global同期は未確認です"), L("同期IDを取得できませんでした。"));
      unifiedFinalState = "unconfirmed";
      return;
    }
    unifiedGlobalRunId = gr.syncId;
    const st = (await afterGlobalSyncNotify(gr)) || "unconfirmed";
    unifiedFinalState = st;
    if(singleSyncTerminal(st)) setUnifiedProgress(1, 1, L("1/1 Global同期: {state}", {state:stateJa(st)}), false);
    else setUnifiedProgress(0, 1, L("0/1 Global同期: {state}", {state:stateJa(st)}), false);
  }catch(e){
    try{ await showNotify(L("Global同期できませんでした"), e.message); }catch(e2){}
    unifiedFinalState = unifiedFinalState || "failed";
    try{ setUnifiedProgress(0, 1, L("0/1 Global同期: {state}", {state:stateJa(unifiedFinalState)}), false); }catch(e3){}
  }
  finally{
    finishSingleSyncScope("global", started);
    try{ b.disabled = originallyDisabled; }catch(e4){}
    try{ safeFocus(b); }catch(e5){}
  }
};
document.getElementById("btnSyncProjectOnly").onclick = async function(){
  const b = document.getElementById("btnSyncProjectOnly");
  if(unifiedSyncActive){ await showNotify(L("同期中"), L("すでに同期を実行中です。")); return; }
  if(globalApplyInflight){ await showNotify(L("同期中"), L("Globalプレビュー適用中です。")); return; }
  const originallyDisabled = b.disabled;
  unifiedSyncActive = true;
  b.disabled = true;
  let started = false;
  try{
    const okGo = await showConfirm(L("Projectのみ同期の確認"), L("Projectのみの同期を実行します。よろしいですか。"), L("同期する"), L("やめる"));
    if(!okGo){ return; }
    started = true;
    beginSingleSyncScope("project");
    let pr = null;
    try{ pr = await api("/api/sync","POST",{}); }
    catch(e){
      setUnifiedProgress(0, 1, L("0/1 Project同期: 開始できませんでした"), false);
      await showNotify(L("Project同期できませんでした"), e.message);
      unifiedFinalState = "unconfirmed";
      return;
    }
    if(!pr || pr.sync !== "started"){
      setUnifiedProgress(0, 1, L("0/1 Project同期: 開始できませんでした"), false);
      await showNotify(L("Project同期できませんでした"), L("同期を開始できませんでした。"));
      unifiedFinalState = "failed";
      return;
    }
    if(!pr.syncId){
      setUnifiedProgress(0, 1, L("0/1 Project同期: {state}", {state:stateJa("unconfirmed")}), false);
      await showNotify(L("Project同期は未確認です"), L("同期IDを取得できませんでした。"));
      unifiedFinalState = "unconfirmed";
      return;
    }
    unifiedProjectRunId = pr.syncId;
    const st = (await afterSyncNotify(pr)) || "unconfirmed";
    unifiedFinalState = st;
    if(singleSyncTerminal(st)) setUnifiedProgress(1, 1, L("1/1 Project同期: {state}", {state:stateJa(st)}), false);
    else setUnifiedProgress(0, 1, L("0/1 Project同期: {state}", {state:stateJa(st)}), false);
  }catch(e){
    try{ await showNotify(L("同期できませんでした"), e.message); }catch(e2){}
    unifiedFinalState = unifiedFinalState || "failed";
    try{ setUnifiedProgress(0, 1, L("0/1 Project同期: {state}", {state:stateJa(unifiedFinalState)}), false); }catch(e3){}
  }
  finally{
    finishSingleSyncScope("project", started);
    try{ b.disabled = originallyDisabled; }catch(e4){}
    try{ safeFocus(b); }catch(e5){}
  }
};
function renderBackupDiff(da, d){
  lastBackupDiff = d;
  da.innerHTML = "";
  const h = document.createElement("p"); h.className = "muted";
  h.textContent = L("対象: ")+ d.name + (d.same ? L("（差分なし）") : L("（差分あり）")) + (d.truncated ? L("（一部省略）") : "");
  da.appendChild(h);
  const pa = document.createElement("p"); pa.className = "muted";
  pa.textContent = "AGENTS.md: " + (((d.backupHasAgents || d.currentHasAgents)) ? (((d.lines || []).length) ? L("差分あり") : L("差分なし")) : L("対象外"));
  da.appendChild(pa);
  if((d.lines || []).length){
    const pre = document.createElement("pre");
    pre.appendChild(renderDiffFrag(d.lines));
    da.appendChild(pre);
  }
  const pl = document.createElement("p"); pl.className = "muted";
  pl.textContent = "localSource: " + (((d.backupHasLocal || d.currentHasLocal)) ? (((d.localLines || []).length) ? L("差分あり") : L("差分なし")) : L("対象外"));
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
  h.textContent = L("共通SHA: {sha} 取得GitSHA: {commit} 作成: {at}", {sha:(plan.commonSha||"").slice(0,12), commit:(plan.commonCommit||"").slice(0,12), at:(plan.createdAt||"")});
  pa.appendChild(h);
  (plan.projects||[]).forEach(function(pj){
    const t = document.createElement("p");
    if(pj.result === "failed"){ t.className = "err"; t.textContent = L("失敗: {name}：{error}", {name:pj.name, error:(pj.error||"")}); pa.appendChild(t); return; }
    if(pj.result === "skipped"){ t.className = "warn"; t.textContent = L("見送り: {name}（無効のため対象外）", {name:pj.name}); pa.appendChild(t); return; }
    const d = diffLinesLocal(pj.currentText||"", pj.generatedText||"");
    t.className = d.same ? "ok" : "warn";
    t.textContent = (d.same ? L("変更なし: {name}", {name:pj.name}) : L("変更あり: {name}", {name:pj.name}));
    pa.appendChild(t);
    if(!d.same){
      const pre = document.createElement("pre");
      pre.appendChild(renderDiffFrag(d.lines));
      if(d.truncated){ const n = document.createElement("span"); n.className="diff-note"; n.setAttribute("data-i18n", "(省略)"); n.textContent=L("(省略)"); pre.appendChild(n); }
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
  if(!names.length){ await showNotify(L("選択なし"), L("同期するプロジェクトを選択してください（一覧または状態表の選択欄）。")); return; }
  if(unifiedSyncActive){ await showNotify(L("同期中"), L("統合同期の実行中は選択同期できません。")); return; }
  if(globalApplyInflight){ await showNotify(L("同期中"), L("Globalプレビュー適用中です。")); return; }
  const b = document.getElementById("btnSyncSel");
  const originallyDisabled = b.disabled;
  b.disabled = true;
  unifiedSyncActive = true;
  try{
    unifiedFinalState = null;
    unifiedProjectRunId = null;
    const pid = planIdForSelection(names);
    const r = await api("/api/sync","POST",{projectNames:names, planId:pid});
    lastPlan = null;
    await afterSyncNotify(r);
  }catch(e){ try{ await showNotify(L("同期できませんでした"), e.message); }catch(e2){} }
  finally{ unifiedSyncActive = false; renderSyncState(); try{ b.disabled = originallyDisabled; }catch(e3){} try{ safeFocus(b); }catch(e4){} }
};
document.getElementById("btnPlanSel").onclick = async function(){
  const names = selectedNames();
  const pa = document.getElementById("planArea"); pa.innerHTML = "<p class='muted'>"+L("プラン作成中")+"</p>";
  try{
    const r = await api("/api/plan-start","POST",{projectNames:names});
    const dl = Date.now() + 90000;
    let plan = null;
    let planWait = 150;
    while(true){
      await new Promise(function(rs){ setTimeout(rs, planWait); });
      planWait = 400;
      if(Date.now() >= dl) break;
      const to = Math.min(8000, dl - Date.now());
      if(to <= 0) break;
      let g = null;
      try{ g = await api("/api/plan?id="+encodeURIComponent(r.planId),"GET",null,to); }catch(e){ continue; }
      if(g && g.status === "ready"){ plan = g; break; }
    }
    if(!plan){ pa.innerHTML = "<p class='warn'>"+L("未確認です。しばらくして「選択の反映前差分」で再取得してください。")+"</p>"; return; }
    renderPlan(plan);
    try{ lastPlan = {id: r.planId, names: names.slice()}; }catch(e){ lastPlan = null; }
    try{
      const ph = document.createElement("p"); ph.className = "muted";
      ph.textContent = L("プランID: {id}（選択を変えず「選択を同期」でこのプランを適用）", {id:String(r.planId).slice(0, 12)});
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
      const td3 = document.createElement("td"); td3.textContent = ((e.hasAgentsFile ? L("AGENTSあり") : L("AGENTSなし")) + " / " + (e.hasLocalFile ? L("localあり") : L("localなし")));
      td3.dataset.hasAgentsFile = e.hasAgentsFile ? "true" : "false";
      td3.dataset.hasLocalFile = e.hasLocalFile ? "true" : "false";
      const td4 = document.createElement("td");
      const acts = document.createElement("div"); acts.className = "acts";
      const bd = document.createElement("button"); bd.textContent = L("差分");
      bd.onclick = async function(){
        lastBackupDiff = null;
        const da = document.getElementById("backupDiffArea"); da.innerHTML = "<p class='muted'>"+L("差分取得中")+"</p>";
        try{
          const d = await api("/api/backup-diff","POST",{backupId:e.id});
          renderBackupDiff(da, d);
        }catch(err){ da.innerHTML = "<p class='err'>"+esc(err.message)+"</p>"; }
      };
      const br = document.createElement("button"); br.textContent = L("復元"); br.className = "danger";
      br.onclick = async function(){
        const okGo = await showConfirm(L("復元の確認"), L("「{id}」を復元します。AGENTS.md と localSource を一緒に復元し、次回上書き防止のため休止（無効）にします。よろしいですか。", {id:e.id}), L("復元する"), L("やめる"));
        if(!okGo) return;
        try{
          const r = await api("/api/restore","POST",{backupId:e.id, confirm:true});
          setMsg("msgBackup", L("復元しました。休止中のため再開は有効化してください。{warning}", {warning:(r.warning || "")}), true);
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
  try{ if(r && r.redacted) return L("伏字表示中の内容はそのまま保存できません（原本保護）。再取得しても伏字のままの場合、そのまま保存しないでください。"); }catch(e){}
  return "";
}
document.getElementById("btnLocalLoad").onclick = async function(){
  const nm = document.getElementById("selLocal").value;
  const la = document.getElementById("localArea"); la.innerHTML = "<p class='muted'>"+L("取得中")+"</p>";
  try{
    const r = await api("/api/localrule-get","POST",{name:nm});
    localHash = r.hash;
    la.innerHTML = "";
    const info = document.createElement("p"); info.className="muted"; info.textContent = L("取得ハッシュ: {hash}（保存時に一致確認）", {hash:(r.hash||"").slice(0,12)});
    la.appendChild(info);
    const nz = localRedactNotice(r);
    if(nz){ const nw = document.createElement("p"); nw.className = "warn"; nw.textContent = nz; la.appendChild(nw); }
    const ta = document.createElement("textarea"); ta.id = "txtLocal"; ta.style.minHeight = "160px"; ta.value = r.text;
    const row = document.createElement("div"); row.className = "btnrow";
    const sv = document.createElement("button"); sv.className = "primary"; sv.textContent = L("検証して保存");
    sv.onclick = async function(){
      try{
        const s = await api("/api/localrule-save","POST",{name:nm, text:ta.value, expectedHash:localHash});
        localHash = s.hash;
        setMsg("msgLocal", L("保存しました。"), true);
      }catch(err){ setMsg("msgLocal", err.message, false); }
    };
    row.appendChild(sv); la.appendChild(info); la.appendChild(ta); la.appendChild(row);
  }catch(e){ la.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnCheck").onclick = async function(){
  const nm = document.getElementById("selLocal").value;
  const ca = document.getElementById("checkArea"); ca.innerHTML = "<p class='muted'>"+L("検査中")+"</p>";
  try{
    const r = await api("/api/check","POST",{name:nm});
    ca.innerHTML = "";
    const n = document.createElement("p"); n.className="muted"; n.textContent = L("いずれも候補であり、断定ではありません。内容を確認して判断してください。");
    ca.appendChild(n);
    (r.duplicates||[]).forEach(function(d){
      const p = document.createElement("p"); p.textContent = L("【重複候補】{project}：{line}", {project:d.project, line:d.line}); ca.appendChild(p);
    });
    (r.contradictions||[]).forEach(function(c2){
      const p = document.createElement("p"); p.textContent = L("【矛盾候補】{project}：共通「{common}」/固有「{local}」", {project:c2.project, common:c2.common, local:c2.local}); ca.appendChild(p);
    });
    if(!(r.duplicates||[]).length && !(r.contradictions||[]).length){
      const p = document.createElement("p"); p.className="ok"; p.textContent = L("候補はありませんでした。"); ca.appendChild(p);
    }
  }catch(e){ ca.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnIntervalGet").onclick = async function(){
  try{
    const r = await api("/api/interval-get","GET");
    document.getElementById("numInterval").value = r.minutes;
    setMsg("msgInterval", L("現在の間隔：{n}分（Project のみ）", {n:r.minutes}), true);
  }catch(e){ setMsg("msgInterval", e.message, false); }
};
document.getElementById("btnIntervalSet").onclick = async function(){
  const m = parseInt(document.getElementById("numInterval").value, 10);
  const okGo = await showConfirm(L("間隔の変更"), L("Project 同期の間隔を{n}分に変更します（Global は不変）。よろしいですか。", {n:m}), L("変更する"), L("やめる"));
  if(!okGo) return;
  try{
    await api("/api/interval-set","POST",{minutes:m, confirm:true});
    setMsg("msgInterval", L("間隔を変更しました：{n}分", {n:m}), true);
  }catch(e){ setMsg("msgInterval", e.message, false); }
};
document.getElementById("btnExport").onclick = async function(){
  try{
    const r = await api("/api/export","GET");
    const blob = new Blob([JSON.stringify(r, null, 2)], {type:"application/json"});
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "shirube-settings.json";
    document.body.appendChild(a); a.click();
    try{ URL.revokeObjectURL(a.href); }catch(e){}
    a.remove();
    setMsg("msgSettings", L("エクスポートしました（秘密情報なし）。"), true);
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
  const ia = document.getElementById("importRegArea"); ia.innerHTML = "<p class='muted'>"+L("確認中")+"</p>";
  try{
    const raw = document.getElementById("txtImport").value;
    let data = null;
    try{ data = JSON.parse(raw); }catch(e){ throw new Error(L("JSONを解釈できません。")); }
    const v = await api("/api/registry-import-preview","POST",{data:data});
    let h = "";
    (v.add||[]).forEach(function(a){ h += "<p class='ok'>"+L("追加：{name}", {name:esc(a.name)})+"</p>"; });
    (v.skip||[]).forEach(function(s){ h += "<p class='muted'>"+L("維持：{name}（{reason}）", {name:esc(s.name), reason:esc(s.reason||"")})+"</p>"; });
    (v.conflict||[]).forEach(function(c3){ h += "<p class='err'>"+L("競合：{name}（{reason}）", {name:esc(c3.name), reason:esc(c3.reason||"")})+"</p>"; });
    (v.invalid||[]).forEach(function(iv){ h += "<p class='err'>"+L("不正：{name}（{reason}）", {name:esc(iv.name), reason:esc(iv.reason||"")})+"</p>"; });
    if(v.interval){
      if(v.interval.incoming !== null && v.interval.incoming !== undefined){
        h += "<p class='muted'>" + ((v.interval.current === null || v.interval.current === undefined)
          ? L("同期間隔: 未設定 → {next}分に変更します（Projectのみ、Global不変）。", {next:v.interval.incoming})
          : L("同期間隔: {current}分 → {next}分に変更します（Projectのみ、Global不変）。", {current:esc(String(v.interval.current)), next:v.interval.incoming})) + "</p>";
      } else if(!v.interval.valid){
        h += "<p class='err'>"+L("同期間隔: {reason}", {reason:esc(v.interval.reason || L("不正"))})+"</p>";
      }
    }
    if(v.interval){
      if(v.interval.incoming !== null && v.interval.incoming !== undefined){
        h += "<p class='muted'>" + ((v.interval.current === null || v.interval.current === undefined)
          ? L("同期間隔: 未設定 → {next}分に変更します（Projectのみ、Global不変）。", {next:v.interval.incoming})
          : L("同期間隔: {current}分 → {next}分に変更します（Projectのみ、Global不変）。", {current:esc(String(v.interval.current)), next:v.interval.incoming})) + "</p>";
      } else if(!v.interval.valid){
        h += "<p class='err'>"+L("同期間隔: {reason}", {reason:esc(v.interval.reason || L("不正"))})+"</p>";
      }
    }
    if(canShowImportButton(v)){
      h += "<label class='chk'><input type='checkbox' id='ckImp2'> "+L("追加内容を確認した")+"</label>";
      h += "<div class='btnrow'><button id='btnImpGo' class='primary'>"+L("取り込む")+"</button></div><div id='msgImpGo' role='status'></div>";
    } else if(((v.conflict||[]).length) || ((v.invalid||[]).length)){
      h += "<p class='muted'>"+L("競合・不正があるため取り込めません。整理してから再実行してください。")+"</p>";
    } else {
      h += "<p class='muted'>"+L("追加・変更がありません。")+"</p>";
    }
    ia.innerHTML = h;
    const go = document.getElementById("btnImpGo");
    if(go) go.onclick = async function(){
      go.disabled = true;
      try{
        if(!document.getElementById("ckImp2") || !document.getElementById("ckImp2").checked) throw new Error(L("確認チェックを入れてください。"));
        const r2 = await api("/api/import","POST",{data:data, confirm:true});
        const doneMsg = r2.intervalApplied
          ? L("取り込みました。追加：{n}件。同期間隔を{interval}分に変更しました。", {n:r2.added, interval:r2.intervalMinutes})
          : L("取り込みました。追加：{n}件", {n:r2.added});
        setMsg("msgImpGo", doneMsg, true);
        await refresh();
      }catch(e){ setMsg("msgImpGo", e.message, false); }finally{ try{ go.disabled = false; }catch(e2){} try{ safeFocus(go); }catch(e3){} }
    };
  }catch(e){ ia.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnBatchPrev").onclick = async function(){
  const ba = document.getElementById("batchArea"); ba.innerHTML = "<p class='muted'>"+L("確認中")+"</p>";
  try{
    const lines = document.getElementById("inpBatch").value.split("\n").map(function(s){ return s.trim(); }).filter(function(s){ return s !== ""; });
    if(!lines.length) throw new Error(L("パスを1行ずつ入力してください。"));
    const v = await api("/api/preview-batch","POST",{paths:lines});
    let h = "";
    const oks = [];
    v.results.forEach(function(r){
      if(r.ok){ h += "<p class='ok'>"+L("OK: 「{name}」← {path}", {name:esc(r.name), path:esc(r.path)})+"</p>"; oks.push({previewId:r.previewId, path:r.path}); }
      else{ h += "<p class='err'>"+L("NG: {path}：{error}", {path:esc(r.path), error:esc(r.error)})+"</p>"; }
    });
    if(oks.length){
      h += "<label class='chk'><input type='checkbox' id='ckBatch'> "+L("{n}件を登録し、非表示で同期することを理解した", {n:oks.length})+"</label>";
      h += "<div class='btnrow'><button id='btnBatchReg' class='primary'>"+L("まとめて登録して同期")+"</button></div><div id='msgBatch' role='status'></div>";
    }
    ba.innerHTML = h;
    const rb = document.getElementById("btnBatchReg");
    if(rb) rb.onclick = async function(){
      rb.disabled = true;
      try{
        if(!document.getElementById("ckBatch") || !document.getElementById("ckBatch").checked) throw new Error(L("確認チェックを入れてください。"));
        const okGo = await showConfirm(L("一括登録の確認"), L("{n}件を登録し、非表示で同期します。よろしいですか。", {n:oks.length}), L("登録する"), L("やめる"));
        if(!okGo){ return; }
        const r = await api("/api/register-batch","POST",{items:oks, confirm:true});
        setMsg("msgBatch", L("登録しました：{names}", {names:r.registered.join(L("、"))}), true);
        document.getElementById("inpBatch").value = "";
        await afterSyncNotify(r);
      }catch(e){ setMsg("msgBatch", e.message, false); }finally{ try{ rb.disabled = false; }catch(e2){} try{ safeFocus(rb); }catch(e3){} }
    };
  }catch(e){ ba.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; }
};
document.getElementById("btnImportPrev").onclick = async function(){
  const ia = document.getElementById("importArea"); ia.innerHTML = "<p class='muted'>"+L("確認中")+"</p>";
  try{
    const v = await api("/api/import-preview","POST",{path:document.getElementById("inpPath").value});
    let h = "<p class='ok'>"+L("取込プレビュー OK: 「{name}」として登録できます。", {name:esc(v.name)})+"</p>";
    h += "<p class='muted'>"+L("既存 AGENTS.md (sha256:{hash}) を退避し、固有分を project-local.md へ転記します。", {hash:esc((v.agentsHash||"").slice(0,12))})+"</p>";
    h += "<pre>"+esc((v.transcription||"").slice(0,2000))+"</pre>";
    h += "<label class='chk'><input type='checkbox' id='ckImp'> "+L("取込内容を確認し、退避と転記に同意する")+"</label>";
    h += "<div class='btnrow'><button id='btnImpReg' class='primary'>"+L("取り込んで登録・同期")+"</button></div><div id='msgImp' role='status'></div>";
    ia.innerHTML = h;
    document.getElementById("btnImpReg").onclick = async function(){
      const btn = document.getElementById("btnImpReg"); btn.disabled = true;
      try{
        if(!document.getElementById("ckImp") || !document.getElementById("ckImp").checked) throw new Error(L("確認チェックを入れてください。"));
        const okGo = await showConfirm(L("取込の確認"), L("「{name}」を取り込んで登録し、非表示で同期します。よろしいですか。", {name:v.name}), L("取り込む"), L("やめる"));
        if(!okGo){ return; }
        const r = await api("/api/register","POST",{path:v.path,previewId:v.previewId,confirm:true,importConfirm:true});
        setMsg("msgImp", L("取り込んで登録しました。"), true);
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
  if(r === "success") return L("成功");
  if(r === "failed") return L("失敗");
  if(r === "skipped") return L("見送り");
  return L("未確認");
}
function renderGlobalTable(list){
  const tb = document.getElementById("globalRows");
  tb.innerHTML = "";
  document.getElementById("tblGlobal").hidden = list.length === 0;
  document.getElementById("emptyGlobal").hidden = list.length !== 0;
  list.forEach(function(e){
    const tr = document.createElement("tr");
    try{ tr.dataset.search = (e.target + " " + (e.path || "") + " " + (e.error || "")).toLowerCase(); }catch(e2){}
    const tdT = document.createElement("td"); tdT.textContent = globalProviderLabel(e.target);
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
const GLOBAL_LOGOS = Object.freeze({
  "codexcli":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgaGVpZ2h0PSIxZW0iIHN0eWxlPSJmbGV4Om5vbmU7bGluZS1oZWlnaHQ6MSIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMWVtIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjx0aXRsZT5PcGVuQUk8L3RpdGxlPjxwYXRoIGQ9Ik05LjIwNSA4LjY1OHYtMi4yNmMwLS4xOS4wNzItLjMzMy4yMzgtLjQyOGw0LjU0My0yLjYxNmMuNjE5LS4zNTcgMS4zNTYtLjUyMyAyLjExNy0uNTIzIDIuODU0IDAgNC42NjIgMi4yMTIgNC42NjIgNC41NjYgMCAuMTY3IDAgLjM1Ny0uMDI0LjU0N2wtNC43MS0yLjc1OWEuNzk3Ljc5NyAwIDAwLS44NTYgMGwtNS45NyAzLjQ3M3ptMTAuNjA5IDguOFYxMi4wNmMwLS4zMzMtLjE0My0uNTctLjQyOS0uNzM3bC01Ljk3LTMuNDczIDEuOTUtMS4xMThhLjQzMy40MzMgMCAwMS40NzYgMGw0LjU0MyAyLjYxN2MxLjMwOS43NiAyLjE4OSAyLjM3OCAyLjE4OSAzLjk0OCAwIDEuODA4LTEuMDcgMy40NzMtMi43NiA0LjE2M3pNNy44MDIgMTIuNzAzbC0xLjk1LTEuMTQyYy0uMTY3LS4wOTUtLjIzOS0uMjM4LS4yMzktLjQyOFY1Ljg5OWMwLTIuNTQ1IDEuOTUtNC40NzIgNC41OTEtNC40NzIgMSAwIDEuOTI3LjMzMyAyLjcxMi45MjhMOC4yMyA1LjA2N2MtLjI4NS4xNjYtLjQyOC40MDQtLjQyOC43Mzd2Ni44OTh6TTEyIDE1LjEyOGwtMi43OTUtMS41N3YtMy4zM0wxMiA4LjY1OGwyLjc5NSAxLjU3djMuMzNMMTIgMTUuMTI4em0xLjc5NiA3LjIzYy0xIDAtMS45MjctLjMzMi0yLjcxMi0uOTI3bDQuNjg2LTIuNzEyYy4yODUtLjE2Ni40MjgtLjQwNC40MjgtLjczN3YtNi44OThsMS45NzQgMS4xNDJjLjE2Ny4wOTUuMjM4LjIzOC4yMzguNDI4djUuMjMzYzAgMi41NDUtMS45NzQgNC40NzItNC42MTQgNC40NzJ6bS01LjYzNy01LjMwM2wtNC41NDQtMi42MTdjLTEuMzA4LS43NjEtMi4xODgtMi4zNzgtMi4xODgtMy45NDhBNC40ODIgNC40ODIgMCAwMTQuMjEgNi4zMjd2NS40MjNjMCAuMzMzLjE0My41NzEuNDI4LjczOGw1Ljk0NyAzLjQ0OS0xLjk1IDEuMTE4YS40MzIuNDMyIDAgMDEtLjQ3NiAwem0tLjI2MiAzLjljLTIuNjg4IDAtNC42NjItMi4wMjEtNC42NjItNC41MTkgMC0uMTkuMDI0LS4zOC4wNDctLjU3bDQuNjg2IDIuNzFjLjI4Ni4xNjcuNTcxLjE2Ny44NTYgMGw1Ljk3LTMuNDQ4djIuMjZjMCAuMTktLjA3LjMzMy0uMjM3LjQyOGwtNC41NDMgMi42MTZjLS42MTkuMzU3LTEuMzU2LjUyMy0yLjExNy41MjN6bTUuODk5IDIuODNhNS45NDcgNS45NDcgMCAwMDUuODI3LTQuNzU2QzIyLjI4NyAxOC4zMzkgMjQgMTUuODQgMjQgMTMuMjk2YzAtMS42NjUtLjcxMy0zLjI4Mi0xLjk5OC00LjQ0OC4xMTktLjUuMTktLjk5OS4xOS0xLjQ5OCAwLTMuNDAxLTIuNzU5LTUuOTQ3LTUuOTQ2LTUuOTQ3LS42NDIgMC0xLjI2LjA5NS0xLjg4LjMxQTUuOTYyIDUuOTYyIDAgMDAxMC4yMDUgMGE1Ljk0NyA1Ljk0NyAwIDAwLTUuODI3IDQuNzU3QzEuNzEzIDUuNDQ3IDAgNy45NDUgMCAxMC40OWMwIDEuNjY2LjcxMyAzLjI4MyAxLjk5OCA0LjQ0OC0uMTE5LjUtLjE5IDEtLjE5IDEuNDk5IDAgMy40MDEgMi43NTkgNS45NDYgNS45NDYgNS45NDYuNjQyIDAgMS4yNi0uMDk1IDEuODgtLjMwOWE1Ljk2IDUuOTYgMCAwMDQuMTYyIDEuNzEzeiI+PC9wYXRoPjwvc3ZnPg==",
  "opencode":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgaGVpZ2h0PSIxZW0iIHN0eWxlPSJmbGV4Om5vbmU7bGluZS1oZWlnaHQ6MSIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMWVtIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjx0aXRsZT5vcGVuY29kZTwvdGl0bGU+PHBhdGggZD0iTTE2IDZIOHYxMmg4VjZ6bTQgMTZINFYyaDE2djIweiI+PC9wYXRoPjwvc3ZnPg==",
  "claudecode":"data:image/svg+xml;base64,PHN2ZyBoZWlnaHQ9IjFlbSIgc3R5bGU9ImZsZXg6bm9uZTtsaW5lLWhlaWdodDoxIiB2aWV3Qm94PSIwIDAgMjQgMjQiIHdpZHRoPSIxZW0iIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHRpdGxlPkNsYXVkZTwvdGl0bGU+PHBhdGggZD0iTTQuNzA5IDE1Ljk1NWw0LjcyLTIuNjQ3LjA4LS4yMy0uMDgtLjEyOEg5LjJsLS43OS0uMDQ4LTIuNjk4LS4wNzMtMi4zMzktLjA5Ny0yLjI2Ni0uMTIyLS41NzEtLjEyMUwwIDExLjc4NGwuMDU1LS4zNTIuNDgtLjMyMS42ODYuMDYgMS41Mi4xMDMgMi4yNzguMTU4IDEuNjUyLjA5NyAyLjQ0OS4yNTVoLjM4OWwuMDU1LS4xNTctLjEzNC0uMDk4LS4xMDMtLjA5Ny0yLjM1OC0xLjU5Ni0yLjU1Mi0xLjY4OC0xLjMzNi0uOTcyLS43MjQtLjQ5MS0uMzY0LS40NjItLjE1OC0xLjAwOC42NTYtLjcyMi44ODEuMDYuMjI1LjA2MS44OTMuNjg2IDEuOTA4IDEuNDc2IDIuNDkxIDEuODMzLjM2NS4zMDQuMTQ1LS4xMDMuMDE5LS4wNzMtLjE2NC0uMjc0LTEuMzU1LTIuNDQ2LTEuNDQ2LTIuNDktLjY0NC0xLjAzMi0uMTctLjYxOWEyLjk3IDIuOTcgMCAwMS0uMTA0LS43MjlMNi4yODMuMTM0IDYuNjk2IDBsLjk5Ni4xMzQuNDIuMzY0LjYyIDEuNDE0IDEuMDAyIDIuMjI5IDEuNTU1IDMuMDMuNDU2Ljg5OC4yNDMuODMyLjA5MS4yNTVoLjE1OFY5LjAxbC4xMjgtMS43MDYuMjM3LTIuMDk1LjIzLTIuNjk1LjA4LS43Ni4zNzYtLjkxLjc0Ny0uNDkyLjU4NC4yOC40OC42ODUtLjA2Ny40NDQtLjI4NiAxLjg1MS0uNTU5IDIuOTAzLS4zNjQgMS45NDJoLjIxMmwuMjQzLS4yNDIuOTg1LTEuMzA2IDEuNjUyLTIuMDY0LjczLS44Mi44NS0uOTA0LjU0Ny0uNDMxaDEuMDMzbC43NiAxLjEyOS0uMzQgMS4xNjYtMS4wNjQgMS4zNDctLjg4MSAxLjE0Mi0xLjI2NCAxLjctLjc5IDEuMzYuMDczLjExLjE4OC0uMDIgMi44NTYtLjYwNiAxLjU0My0uMjggMS44NDEtLjMxNS44MzMuMzg4LjA5MS4zOTUtLjMyOC44MDctMS45NjkuNDg2LTIuMzA5LjQ2Mi0zLjQzOS44MTMtLjA0Mi4wMy4wNDkuMDYxIDEuNTQ5LjE0Ni42NjIuMDM2aDEuNjIybDMuMDIuMjI1Ljc5LjUyMi40NzQuNjM4LS4wNzkuNDg1LTEuMjE1LjYyLTEuNjQtLjM4OS0zLjgyOS0uOTEtMS4zMTItLjMyOWgtLjE4MnYuMTFsMS4wOTMgMS4wNjggMi4wMDYgMS44MSAyLjUwOSAyLjMzLjEyNy41NzgtLjMyMi40NTUtLjM0LS4wNDktMi4yMDUtMS42NTctLjg1MS0uNzQ3LTEuOTI2LTEuNjJoLS4xMjh2LjE3bC40NDQuNjQ5IDIuMzQ1IDMuNTIxLjEyMiAxLjA4LS4xNy4zNTMtLjYwOC4yMTMtLjY2OC0uMTIyLTEuMzc0LTEuOTI1LTEuNDE1LTIuMTY3LTEuMTQzLTEuOTQzLS4xNC4wOC0uNjc0IDcuMjU0LS4zMTYuMzctLjcyOS4yOC0uNjA3LS40NjEtLjMyMi0uNzQ3LjMyMi0xLjQ3Ni4zODktMS45MjQuMzE1LTEuNTMuMjg2LTEuOS4xNy0uNjMyLS4wMTItLjA0Mi0uMTQuMDE4LTEuNDM0IDEuOTY3LTIuMTggMi45NDUtMS43MjYgMS44NDUtLjQxNC4xNjQtLjcxNy0uMzcuMDY3LS42NjIuNDAxLS41ODkgMi4zODgtMy4wMzYgMS40NC0xLjg4Mi45My0xLjA4Ni0uMDA2LS4xNThoLS4wNTVMNC4xMzIgMTguNTZsLTEuMTMuMTQ2LS40ODctLjQ1Ni4wNjEtLjc0Ni4yMzEtLjI0MyAxLjkwOC0xLjMxMi0uMDA2LjAwNnoiIGZpbGw9IiNEOTc3NTciIGZpbGwtcnVsZT0ibm9uemVybyI+PC9wYXRoPjwvc3ZnPg==",
  "cline":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgaGVpZ2h0PSIxZW0iIHN0eWxlPSJmbGV4Om5vbmU7bGluZS1oZWlnaHQ6MSIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMWVtIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjx0aXRsZT5DbGluZTwvdGl0bGU+PHBhdGggZD0iTTE3LjAzNSAzLjk5MWMyLjc1IDAgNC45OCAyLjI0IDQuOTggNS4wMDN2MS42NjdsMS40NSAyLjg5NmExLjAxIDEuMDEgMCAwMS0uMDAyLjkwOWwtMS40NDggMi44NjR2MS42NjhjMCAyLjc2Mi0yLjIzIDUuMDAyLTQuOTggNS4wMDJINy4wNzRjLTIuNzUxIDAtNC45OC0yLjI0LTQuOTgtNS4wMDJWMTcuMzNsLTEuNDgtMi44NTVhMS4wMSAxLjAxIDAgMDEtLjAwMy0uOTI3bDEuNDgyLTIuODg3VjguOTk0YzAtMi43NjMgMi4yMy01LjAwMyA0Ljk4LTUuMDAzaDkuOTYyek04LjI2NSA5LjZhMi4yNzQgMi4yNzQgMCAwMC0yLjI3NCAyLjI3NHY0LjA0MmEyLjI3NCAyLjI3NCAwIDAwNC41NDcgMHYtNC4wNDJBMi4yNzQgMi4yNzQgMCAwMDguMjY1IDkuNnptNy4zMjYgMGEyLjI3NCAyLjI3NCAwIDAwLTIuMjc0IDIuMjc0djQuMDQyYTIuMjc0IDIuMjc0IDAgMTA0LjU0OCAwdi00LjA0MkEyLjI3NCAyLjI3NCAwIDAwMTUuNTkgOS42eiI+PC9wYXRoPjxwYXRoIGQ9Ik0xMi4wNTQgNS41NThhMi43NzkgMi43NzkgMCAxMDAtNS41NTggMi43NzkgMi43NzkgMCAwMDAgNS41NTh6Ij48L3BhdGg+PC9zdmc+",
  "copilotcli":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgaGVpZ2h0PSIxZW0iIHN0eWxlPSJmbGV4Om5vbmU7bGluZS1oZWlnaHQ6MSIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMWVtIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjx0aXRsZT5HaXRodWJDb3BpbG90PC90aXRsZT48cGF0aCBkPSJNMTkuMjQ1IDUuMzY0YzEuMzIyIDEuMzYgMS44NzcgMy4yMTYgMi4xMSA1LjgxNy42MjIgMCAxLjIuMTM1IDEuNTkyLjY1NGwuNzMuOTY0Yy4yMS4yNzguMzIzLjYxLjMyMy45NTV2Mi42MmMwIC4zMzktLjE3My42NjktLjQ1My44NjhDMjAuMjM5IDE5LjYwMiAxNi4xNTcgMjEuNSAxMiAyMS41Yy00LjYgMC05LjIwNS0yLjU4My0xMS41NDctNC4yNTgtLjI4LS4yLS40NTItLjUzLS40NTMtLjg2OHYtMi42MmMwLS4zNDUuMTEzLS42NzkuMzIxLS45NTZsLjczLS45NjNjLjM5Mi0uNTE3Ljk3NC0uNjU0IDEuNTkzLS42NTRsLjAyOS0uMjk3Yy4yNS0yLjQ0Ni44MS00LjIxMyAyLjA4Mi01LjUyIDIuNDYxLTIuNTQgNS43MS0yLjg1MSA3LjE0Ni0yLjg2NGguMTk4YzEuNDM2LjAxMyA0LjY4NS4zMjMgNy4xNDYgMi44NjR6bS03LjI0NCA0LjMyOGMtLjI4NCAwLS42MTMuMDE2LS45NjIuMDUtLjEyMy40NDctLjMwNS44NS0uNTcgMS4xMDgtMS4wNSAxLjAyMy0yLjMxNiAxLjE4LTIuOTk0IDEuMTgtLjYzOCAwLTEuMzA2LS4xMy0xLjg1MS0uNDY0LS41MTYuMTY1LTEuMDEyLjQwMy0xLjA0NC45OTZhNjUuODgyIDY1Ljg4MiAwIDAwLS4wNjMgMi44ODRsLS4wMDIuNDhjLS4wMDIuNTYzLS4wMDUgMS4xMjYtLjAxMyAxLjY5LjAwMi4zMjYuMjA0LjYzLjUxLjc2NSAyLjQ4MiAxLjEwMiA0LjgzIDEuNjU3IDYuOTkgMS42NTcgMi4xNTYgMCA0LjUwNC0uNTU1IDYuOTg1LTEuNjU3YS44NTQuODU0IDAgMDAuNTEtLjc2NmMuMDMtMS42ODIuMDA2LTMuMzcyLS4wNzYtNS4wNTMtLjAzMS0uNTk2LS41MjgtLjgzLTEuMDQ2LS45OTYtLjU0Ni4zMzMtMS4yMTIuNDY0LTEuODUuNDY0LS42NzcgMC0xLjk0Mi0uMTU3LTIuOTkzLTEuMTgtLjI2Ni0uMjU4LS40NDctLjY2MS0uNTctMS4xMDgtLjMyLS4wMzItLjY0LS4wNDktLjk2LS4wNXptLTIuNTI1IDQuMDEzYy41MzkgMCAuOTc2LjQyNi45NzYuOTV2MS43NTNjMCAuNTI1LS40MzcuOTUtLjk3Ni45NWEuOTY0Ljk2NCAwIDAxLS45NzYtLjk1di0xLjc1MmMwLS41MjUuNDM3LS45NTEuOTc2LS45NTF6bTUgMGMuNTM5IDAgLjk3Ni40MjYuOTc2Ljk1djEuNzUzYzAgLjUyNS0uNDM3Ljk1LS45NzYuOTVhLjk2NC45NjQgMCAwMS0uOTc2LS45NXYtMS43NTJjMC0uNTI1LjQzNy0uOTUxLjk3Ni0uOTUxek03LjYzNSA1LjA4N2MtMS4wNS4xMDItMS45MzUuNDM4LTIuMzg1LjkwNi0uOTc1IDEuMDM3LS43NjUgMy42NjgtLjIxIDQuMjI0LjQwNS4zOTQgMS4xNy42NTcgMS45OTUuNjU3aC4wOWMuNjQ5LS4wMTMgMS43ODUtLjE3NiAyLjczLTEuMTEuNDM1LS40MS43MDUtMS40MzMuNjc1LTIuNDctLjAzLS44MzQtLjI3LTEuNTItLjYzLTEuODEzLS4zOS0uMzM2LTEuMjc1LS40ODItMi4yNjUtLjM5NHptNi40NjUuMzk0Yy0uMzYuMjkyLS42Ljk4LS42MyAxLjgxMy0uMDMgMS4wMzcuMjQgMi4wNi42NzUgMi40Ny45NjguOTU3IDIuMTM2IDEuMTA0IDIuNzc2IDEuMTFoLjA0NGMuODI1IDAgMS41OS0uMjYzIDEuOTk1LS42NTcuNTU1LS41NTYuNzY1LTMuMTg3LS4yMS00LjIyNC0uNDUtLjQ2OC0xLjMzNS0uODA0LTIuMzg1LS45MDYtLjk5LS4wODgtMS44NzUuMDU4LTIuMjY1LjM5NHpNMTIgNy42MTVjLS4yNCAwLS41MjUuMDE1LS44NC4wNDQuMDMuMTYuMDQ1LjMzNi4wNi41MjZsLS4wMDEuMTU5YTIuOTQgMi45NCAwIDAxLS4wMTQuMjVjLjIyNS0uMDIyLjQyNS0uMDI3LjYxMi0uMDI4aC4zNjZjLjE4NyAwIC4zODcuMDA2LjYxMi4wMjgtLjAxNS0uMTQ2LS4wMTUtLjI3Ny0uMDE1LS40MDkuMDE1LS4xOS4wMy0uMzY1LjA2LS41MjZhOS4yOSA5LjI5IDAgMDAtLjg0LS4wNDR6Ij48L3BhdGg+PC9zdmc+",
  "antigravity-cli":"data:image/svg+xml;base64,PHN2ZyBoZWlnaHQ9IjFlbSIgc3R5bGU9ImZsZXg6bm9uZTtsaW5lLWhlaWdodDoxIiB2aWV3Qm94PSIwIDAgMjQgMjQiIHdpZHRoPSIxZW0iIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHRpdGxlPkFudGlncmF2aXR5PC90aXRsZT48bWFzayBoZWlnaHQ9IjIzIiBpZD0ibG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0wLV9SXzBfIiBtYXNrVW5pdHM9InVzZXJTcGFjZU9uVXNlIiB3aWR0aD0iMjQiIHg9IjAiIHk9IjEiPjxwYXRoIGQ9Ik0yMS43NTEgMjIuNjA3YzEuMzQgMS4wMDUgMy4zNS4zMzUgMS41MDgtMS41MDhDMTcuNzMgMTUuNzQgMTguOTA0IDEgMTIuMDM3IDEgNS4xNyAxIDYuMzQyIDE1Ljc0LjgxNSAyMS4xYy0yLjAxIDIuMDA5LjE2NyAyLjUxMSAxLjUwNyAxLjUwNiA1LjE5Mi0zLjUxNyA0Ljg1Ny05LjcxNCA5LjcxNS05LjcxNCA0Ljg1NyAwIDQuNTIyIDYuMTk3IDkuNzE0IDkuNzE1eiIgZmlsbD0iI2ZmZiI+PC9wYXRoPjwvbWFzaz48ZyBtYXNrPSJ1cmwoI2xvYmUtaWNvbnMtYW50aWdyYXZpdHktMC1fUl8wXykiPjxnIGZpbHRlcj0idXJsKCNsb2JlLWljb25zLWFudGlncmF2aXR5LTEtX1JfMF8pIj48cGF0aCBkPSJNLTEuMDE4LTMuOTkyYy0uNDA4IDMuNTkxIDIuNjg2IDYuODkgNi45MSA3LjM3IDQuMjI1LjQ4IDcuOTgtMi4wNDMgOC4zODctNS42MzMuNDA4LTMuNTktMi42ODYtNi44OS02LjkxLTcuMzctNC4yMjUtLjQ3OS03Ljk4IDIuMDQzLTguMzg3IDUuNjMzeiIgZmlsbD0iI0ZGRTQzMiI+PC9wYXRoPjwvZz48ZyBmaWx0ZXI9InVybCgjbG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0yLV9SXzBfKSI+PHBhdGggZD0iTTE1LjI2OSA3Ljc0N2MxLjA1OCA0LjU1NyA1LjY5MSA3LjM3NCAxMC4zNDggNi4yOTMgNC42NTctMS4wODIgNy41NzUtNS42NTMgNi41MTYtMTAuMjEtMS4wNTgtNC41NTYtNS42OTEtNy4zNzQtMTAuMzQ4LTYuMjkyLTQuNjU3IDEuMDgyLTcuNTc1IDUuNjUzLTYuNTE2IDEwLjIxeiIgZmlsbD0iI0ZDNDEzRCI+PC9wYXRoPjwvZz48ZyBmaWx0ZXI9InVybCgjbG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0zLV9SXzBfKSI+PHBhdGggZD0iTS0xMi40NDMgMTAuODA0YzEuMzM4IDQuNzAzIDcuMzYgNy4xMSAxMy40NTMgNS4zNzggNi4wOTItMS43MzMgOS45NDctNi45NSA4LjYxLTExLjY1MkM4LjI4Mi0uMTczIDIuMjYtMi41OC0zLjgzMy0uODQ4LTkuOTI1Ljg4NC0xMy43OCA2LjEtMTIuNDQzIDEwLjgwNHoiIGZpbGw9IiMwMEI5NUMiPjwvcGF0aD48L2c+PGcgZmlsdGVyPSJ1cmwoI2xvYmUtaWNvbnMtYW50aWdyYXZpdHktNC1fUl8wXykiPjxwYXRoIGQ9Ik0tMTIuNDQzIDEwLjgwNGMxLjMzOCA0LjcwMyA3LjM2IDcuMTEgMTMuNDUzIDUuMzc4IDYuMDkyLTEuNzMzIDkuOTQ3LTYuOTUgOC42MS0xMS42NTJDOC4yODItLjE3MyAyLjI2LTIuNTgtMy44MzMtLjg0OC05LjkyNS44ODQtMTMuNzggNi4xLTEyLjQ0MyAxMC44MDR6IiBmaWxsPSIjMDBCOTVDIj48L3BhdGg+PC9nPjxnIGZpbHRlcj0idXJsKCNsb2JlLWljb25zLWFudGlncmF2aXR5LTUtX1JfMF8pIj48cGF0aCBkPSJNLTcuNjA4IDE0LjcwM2MzLjM1MiAzLjQyNCA5LjEyNiAzLjIwOCAxMi44OTYtLjQ4MyAzLjc3LTMuNjkgNC4xMDgtOS40NTkuNzU2LTEyLjg4M0MyLjY5LTIuMDg3LTMuMDgzLTEuODcxLTYuODUzIDEuODJjLTMuNzcgMy42OS00LjEwOCA5LjQ1OC0uNzU1IDEyLjg4M3oiIGZpbGw9IiMwMEI5NUMiPjwvcGF0aD48L2c+PGcgZmlsdGVyPSJ1cmwoI2xvYmUtaWNvbnMtYW50aWdyYXZpdHktNi1fUl8wXykiPjxwYXRoIGQ9Ik05LjkzMiAyNy42MTdjMS4wNCA0LjQ4MiA1LjM4NCA3LjMwMyA5LjcgNi4zIDQuMzE2LTEuMDAyIDYuOTcxLTUuNDQ4IDUuOTMtOS45My0xLjA0LTQuNDgzLTUuMzg0LTcuMzA0LTkuNy02LjMwMS00LjMxNiAxLjAwMi02Ljk3MSA1LjQ0OC01LjkzIDkuOTN6IiBmaWxsPSIjMzE4NkZGIj48L3BhdGg+PC9nPjxnIGZpbHRlcj0idXJsKCNsb2JlLWljb25zLWFudGlncmF2aXR5LTctX1JfMF8pIj48cGF0aCBkPSJNMi41NzItOC4xODVDLjM5Mi0zLjMyOSAyLjc3OCAyLjQ3MiA3LjkgNC43NzFjNS4xMjIgMi4zIDExLjA0Mi4yMjcgMTMuMjIyLTQuNjMgMi4xOC00Ljg1NS0uMjA1LTEwLjY1Ni01LjMyNy0xMi45NTUtNS4xMjItMi4zLTExLjA0Mi0uMjI3LTEzLjIyMiA0LjYzeiIgZmlsbD0iI0ZCQkMwNCI+PC9wYXRoPjwvZz48ZyBmaWx0ZXI9InVybCgjbG9iZS1pY29ucy1hbnRpZ3Jhdml0eS04LV9SXzBfKSI+PHBhdGggZD0iTS0zLjI2NyAzOC42ODZjLTUuMjc3LTIuMDcyIDMuNzQyLTE5LjExNyA1Ljk4NC0yNC44MyAyLjI0My01LjcxMiA4LjM0LTguNjY0IDEzLjYxNi02LjU5MiA1LjI3OCAyLjA3MSAxMS41MzMgMTMuNDgyIDkuMjkgMTkuMTk1LTIuMjQyIDUuNzEzLTIzLjYxMyAxNC4yOTgtMjguODkgMTIuMjI3eiIgZmlsbD0iIzMxODZGRiI+PC9wYXRoPjwvZz48ZyBmaWx0ZXI9InVybCgjbG9iZS1pY29ucy1hbnRpZ3Jhdml0eS05LV9SXzBfKSI+PHBhdGggZD0iTTI4LjcxIDE3LjQ3MWMtMS40MTMgMS42NDktNS4xLjgwOC04LjIzNi0xLjg3OC0zLjEzNS0yLjY4Ny00LjUzMS02LjIwMS0zLjExOC03Ljg1IDEuNDEyLTEuNjQ5IDUuMS0uODA4IDguMjM1IDEuODc4czQuNTMyIDYuMiAzLjExOSA3Ljg1eiIgZmlsbD0iIzc0OUJGRiI+PC9wYXRoPjwvZz48ZyBmaWx0ZXI9InVybCgjbG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0xMC1fUl8wXykiPjxwYXRoIGQ9Ik0xOC4xNjMgOS4wNzdjNS44MSAzLjkzIDEyLjUwMiA0LjE5IDE0Ljk0Ni41NzcgMi40NDMtMy42MTItLjI4Ny05LjcyNy02LjA5OC0xMy42NTgtNS44MS0zLjkzMS0xMi41MDItNC4xOS0xNC45NDYtLjU3Ny0yLjQ0MyAzLjYxMi4yODcgOS43MjcgNi4wOTggMTMuNjU4eiIgZmlsbD0iI0ZDNDEzRCI+PC9wYXRoPjwvZz48ZyBmaWx0ZXI9InVybCgjbG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0xMS1fUl8wXykiPjxwYXRoIGQ9Ik0tLjkxNSAyLjY4NGMtMS40NCAzLjQ3My0uOTcgNi45NjcgMS4wNSA3LjgwNCAyLjAyLjgzNyA0LjgyNC0xLjMgNi4yNjQtNC43NzIgMS40NC0zLjQ3My45Ny02Ljk2Ny0xLjA1LTcuODA0LTIuMDItLjgzNy00LjgyNCAxLjMtNi4yNjQgNC43NzJ6IiBmaWxsPSIjRkZFRTQ4Ij48L3BhdGg+PC9nPjwvZz48ZGVmcz48ZmlsdGVyIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiIgZmlsdGVyVW5pdHM9InVzZXJTcGFjZU9uVXNlIiBoZWlnaHQ9IjE3LjU4NyIgaWQ9ImxvYmUtaWNvbnMtYW50aWdyYXZpdHktMS1fUl8wXyIgd2lkdGg9IjE5LjgzOCIgeD0iLTMuMjg4IiB5PSItMTEuOTE3Ij48ZmVGbG9vZCBmbG9vZC1vcGFjaXR5PSIwIiByZXN1bHQ9IkJhY2tncm91bmRJbWFnZUZpeCI+PC9mZUZsb29kPjxmZUJsZW5kIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJzaGFwZSI+PC9mZUJsZW5kPjxmZUdhdXNzaWFuQmx1ciByZXN1bHQ9ImVmZmVjdDFfZm9yZWdyb3VuZEJsdXJfOTc3XzExNSIgc3RkRGV2aWF0aW9uPSIxLjExNyI+PC9mZUdhdXNzaWFuQmx1cj48L2ZpbHRlcj48ZmlsdGVyIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiIgZmlsdGVyVW5pdHM9InVzZXJTcGFjZU9uVXNlIiBoZWlnaHQ9IjM4LjU2NSIgaWQ9ImxvYmUtaWNvbnMtYW50aWdyYXZpdHktMi1fUl8wXyIgd2lkdGg9IjM4LjkiIHg9IjQuMjUxIiB5PSItMTMuNDkzIj48ZmVGbG9vZCBmbG9vZC1vcGFjaXR5PSIwIiByZXN1bHQ9IkJhY2tncm91bmRJbWFnZUZpeCI+PC9mZUZsb29kPjxmZUJsZW5kIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJzaGFwZSI+PC9mZUJsZW5kPjxmZUdhdXNzaWFuQmx1ciByZXN1bHQ9ImVmZmVjdDFfZm9yZWdyb3VuZEJsdXJfOTc3XzExNSIgc3RkRGV2aWF0aW9uPSI1LjQiPjwvZmVHYXVzc2lhbkJsdXI+PC9maWx0ZXI+PGZpbHRlciBjb2xvci1pbnRlcnBvbGF0aW9uLWZpbHRlcnM9InNSR0IiIGZpbHRlclVuaXRzPSJ1c2VyU3BhY2VPblVzZSIgaGVpZ2h0PSIzNi41MTciIGlkPSJsb2JlLWljb25zLWFudGlncmF2aXR5LTMtX1JfMF8iIHdpZHRoPSI0MC45NTUiIHg9Ii0yMS44ODkiIHk9Ii0xMC41OTIiPjxmZUZsb29kIGZsb29kLW9wYWNpdHk9IjAiIHJlc3VsdD0iQmFja2dyb3VuZEltYWdlRml4Ij48L2ZlRmxvb2Q+PGZlQmxlbmQgaW49IlNvdXJjZUdyYXBoaWMiIGluMj0iQmFja2dyb3VuZEltYWdlRml4IiByZXN1bHQ9InNoYXBlIj48L2ZlQmxlbmQ+PGZlR2F1c3NpYW5CbHVyIHJlc3VsdD0iZWZmZWN0MV9mb3JlZ3JvdW5kQmx1cl85NzdfMTE1IiBzdGREZXZpYXRpb249IjQuNTkxIj48L2ZlR2F1c3NpYW5CbHVyPjwvZmlsdGVyPjxmaWx0ZXIgY29sb3ItaW50ZXJwb2xhdGlvbi1maWx0ZXJzPSJzUkdCIiBmaWx0ZXJVbml0cz0idXNlclNwYWNlT25Vc2UiIGhlaWdodD0iMzYuNTE3IiBpZD0ibG9iZS1pY29ucy1hbnRpZ3Jhdml0eS00LV9SXzBfIiB3aWR0aD0iNDAuOTU1IiB4PSItMjEuODg5IiB5PSItMTAuNTkyIj48ZmVGbG9vZCBmbG9vZC1vcGFjaXR5PSIwIiByZXN1bHQ9IkJhY2tncm91bmRJbWFnZUZpeCI+PC9mZUZsb29kPjxmZUJsZW5kIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJzaGFwZSI+PC9mZUJsZW5kPjxmZUdhdXNzaWFuQmx1ciByZXN1bHQ9ImVmZmVjdDFfZm9yZWdyb3VuZEJsdXJfOTc3XzExNSIgc3RkRGV2aWF0aW9uPSI0LjU5MSI+PC9mZUdhdXNzaWFuQmx1cj48L2ZpbHRlcj48ZmlsdGVyIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiIgZmlsdGVyVW5pdHM9InVzZXJTcGFjZU9uVXNlIiBoZWlnaHQ9IjM2LjU5NSIgaWQ9ImxvYmUtaWNvbnMtYW50aWdyYXZpdHktNS1fUl8wXyIgd2lkdGg9IjM2LjYzMiIgeD0iLTE5LjA5OSIgeT0iLTEwLjI3OCI+PGZlRmxvb2QgZmxvb2Qtb3BhY2l0eT0iMCIgcmVzdWx0PSJCYWNrZ3JvdW5kSW1hZ2VGaXgiPjwvZmVGbG9vZD48ZmVCbGVuZCBpbj0iU291cmNlR3JhcGhpYyIgaW4yPSJCYWNrZ3JvdW5kSW1hZ2VGaXgiIHJlc3VsdD0ic2hhcGUiPjwvZmVCbGVuZD48ZmVHYXVzc2lhbkJsdXIgcmVzdWx0PSJlZmZlY3QxX2ZvcmVncm91bmRCbHVyXzk3N18xMTUiIHN0ZERldmlhdGlvbj0iNC41OTEiPjwvZmVHYXVzc2lhbkJsdXI+PC9maWx0ZXI+PGZpbHRlciBjb2xvci1pbnRlcnBvbGF0aW9uLWZpbHRlcnM9InNSR0IiIGZpbHRlclVuaXRzPSJ1c2VyU3BhY2VPblVzZSIgaGVpZ2h0PSIzNC4wODciIGlkPSJsb2JlLWljb25zLWFudGlncmF2aXR5LTYtX1JfMF8iIHdpZHRoPSIzMy41MzMiIHg9Ii45ODEiIHk9IjguNzU4Ij48ZmVGbG9vZCBmbG9vZC1vcGFjaXR5PSIwIiByZXN1bHQ9IkJhY2tncm91bmRJbWFnZUZpeCI+PC9mZUZsb29kPjxmZUJsZW5kIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJzaGFwZSI+PC9mZUJsZW5kPjxmZUdhdXNzaWFuQmx1ciByZXN1bHQ9ImVmZmVjdDFfZm9yZWdyb3VuZEJsdXJfOTc3XzExNSIgc3RkRGV2aWF0aW9uPSI0LjM2MyI+PC9mZUdhdXNzaWFuQmx1cj48L2ZpbHRlcj48ZmlsdGVyIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiIgZmlsdGVyVW5pdHM9InVzZXJTcGFjZU9uVXNlIiBoZWlnaHQ9IjM1LjI3NiIgaWQ9ImxvYmUtaWNvbnMtYW50aWdyYXZpdHktNy1fUl8wXyIgd2lkdGg9IjM1Ljk3OCIgeD0iLTYuMTQzIiB5PSItMjEuNjU5Ij48ZmVGbG9vZCBmbG9vZC1vcGFjaXR5PSIwIiByZXN1bHQ9IkJhY2tncm91bmRJbWFnZUZpeCI+PC9mZUZsb29kPjxmZUJsZW5kIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJzaGFwZSI+PC9mZUJsZW5kPjxmZUdhdXNzaWFuQmx1ciByZXN1bHQ9ImVmZmVjdDFfZm9yZWdyb3VuZEJsdXJfOTc3XzExNSIgc3RkRGV2aWF0aW9uPSIzLjk1NCI+PC9mZUdhdXNzaWFuQmx1cj48L2ZpbHRlcj48ZmlsdGVyIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiIgZmlsdGVyVW5pdHM9InVzZXJTcGFjZU9uVXNlIiBoZWlnaHQ9IjQ2LjUyMyIgaWQ9ImxvYmUtaWNvbnMtYW50aWdyYXZpdHktOC1fUl8wXyIgd2lkdGg9IjQ1LjExNCIgeD0iLTExLjk2IiB5PSItLjQ2Ij48ZmVGbG9vZCBmbG9vZC1vcGFjaXR5PSIwIiByZXN1bHQ9IkJhY2tncm91bmRJbWFnZUZpeCI+PC9mZUZsb29kPjxmZUJsZW5kIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJzaGFwZSI+PC9mZUJsZW5kPjxmZUdhdXNzaWFuQmx1ciByZXN1bHQ9ImVmZmVjdDFfZm9yZWdyb3VuZEJsdXJfOTc3XzExNSIgc3RkRGV2aWF0aW9uPSIzLjUzMSI+PC9mZUdhdXNzaWFuQmx1cj48L2ZpbHRlcj48ZmlsdGVyIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiIgZmlsdGVyVW5pdHM9InVzZXJTcGFjZU9uVXNlIiBoZWlnaHQ9IjI0LjA1NCIgaWQ9ImxvYmUtaWNvbnMtYW50aWdyYXZpdHktOS1fUl8wXyIgd2lkdGg9IjI1LjA5NCIgeD0iMTAuNDg1IiB5PSIuNTgiPjxmZUZsb29kIGZsb29kLW9wYWNpdHk9IjAiIHJlc3VsdD0iQmFja2dyb3VuZEltYWdlRml4Ij48L2ZlRmxvb2Q+PGZlQmxlbmQgaW49IlNvdXJjZUdyYXBoaWMiIGluMj0iQmFja2dyb3VuZEltYWdlRml4IiByZXN1bHQ9InNoYXBlIj48L2ZlQmxlbmQ+PGZlR2F1c3NpYW5CbHVyIHJlc3VsdD0iZWZmZWN0MV9mb3JlZ3JvdW5kQmx1cl85NzdfMTE1IiBzdGREZXZpYXRpb249IjMuMTU5Ij48L2ZlR2F1c3NpYW5CbHVyPjwvZmlsdGVyPjxmaWx0ZXIgY29sb3ItaW50ZXJwb2xhdGlvbi1maWx0ZXJzPSJzUkdCIiBmaWx0ZXJVbml0cz0idXNlclNwYWNlT25Vc2UiIGhlaWdodD0iMzAuMDA3IiBpZD0ibG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0xMC1fUl8wXyIgd2lkdGg9IjMzLjUwOCIgeD0iNS44MzMiIHk9Ii0xMi40NjciPjxmZUZsb29kIGZsb29kLW9wYWNpdHk9IjAiIHJlc3VsdD0iQmFja2dyb3VuZEltYWdlRml4Ij48L2ZlRmxvb2Q+PGZlQmxlbmQgaW49IlNvdXJjZUdyYXBoaWMiIGluMj0iQmFja2dyb3VuZEltYWdlRml4IiByZXN1bHQ9InNoYXBlIj48L2ZlQmxlbmQ+PGZlR2F1c3NpYW5CbHVyIHJlc3VsdD0iZWZmZWN0MV9mb3JlZ3JvdW5kQmx1cl85NzdfMTE1IiBzdGREZXZpYXRpb249IjIuNjY5Ij48L2ZlR2F1c3NpYW5CbHVyPjwvZmlsdGVyPjxmaWx0ZXIgY29sb3ItaW50ZXJwb2xhdGlvbi1maWx0ZXJzPSJzUkdCIiBmaWx0ZXJVbml0cz0idXNlclNwYWNlT25Vc2UiIGhlaWdodD0iMjYuMTUxIiBpZD0ibG9iZS1pY29ucy1hbnRpZ3Jhdml0eS0xMS1fUl8wXyIgd2lkdGg9IjIyLjE5NCIgeD0iLTguMzU1IiB5PSItOC44NzYiPjxmZUZsb29kIGZsb29kLW9wYWNpdHk9IjAiIHJlc3VsdD0iQmFja2dyb3VuZEltYWdlRml4Ij48L2ZlRmxvb2Q+PGZlQmxlbmQgaW49IlNvdXJjZUdyYXBoaWMiIGluMj0iQmFja2dyb3VuZEltYWdlRml4IiByZXN1bHQ9InNoYXBlIj48L2ZlQmxlbmQ+PGZlR2F1c3NpYW5CbHVyIHJlc3VsdD0iZWZmZWN0MV9mb3JlZ3JvdW5kQmx1cl85NzdfMTE1IiBzdGREZXZpYXRpb249IjMuMzAzIj48L2ZlR2F1c3NpYW5CbHVyPjwvZmlsdGVyPjwvZGVmcz48L3N2Zz4=",
  "commandcode":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJub25lIiBoZWlnaHQ9IjEzNyIgdmlld0JveD0iMCAwIDEzNyAxMzciIHdpZHRoPSIxMzciIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHBhdGggZD0ibTAgNjYuNzk1OWMwLTMxLjQ4NzkgMC00Ny4yMzE4IDkuNzgyMDQtNTcuMDEzODYgOS43ODIwNi05Ljc4MjA0IDI1LjUyNTk2LTkuNzgyMDQgNTcuMDEzOTYtOS43ODIwNGgyLjUzNTdjMzEuNDg4MyAwIDQ3LjIzMjMgMCA1Ny4wMTQzIDkuNzgyMDQgOS43ODIgOS43ODIwNiA5Ljc4MiAyNS41MjU5NiA5Ljc4MiA1Ny4wMTM5NnYyLjUzNTdjMCAzMS40ODgzIDAgNDcuMjMyMy05Ljc4MiA1Ny4wMTQzcy0yNS41MjYgOS43ODItNTcuMDE0NCA5Ljc4MmgtMi41MzU3Yy0zMS40ODc5IDAtNDcuMjMxOCAwLTU3LjAxMzg2LTkuNzgyLTkuNzgyMDQtOS43ODItOS43ODIwNC0yNS41MjYtOS43ODIwNC01Ny4wMTQ0eiIgZmlsbD0iIzAwMCIvPjxnIGZpbGw9IiNmZmYiPjxwYXRoIGNsaXAtcnVsZT0iZXZlbm9kZCIgZD0ibTY5LjMzMTcgNS41NjYzM2gtMi41MzU3Yy0xNS45MDE0IDAtMjcuMjY3NC4wMTE4Mi0zNS45MDUgMS4xNzMxMi04LjQ3NzUgMS4xMzk3Ny0xMy40ODg2IDMuMjk0MTUtMTcuMTczIDYuOTc4NTVzLTUuODM4NzggOC42OTU1LTYuOTc4NTUgMTcuMTczYy0xLjE2MTMgOC42Mzc2LTEuMTczMTIgMjAuMDAzNi0xLjE3MzEyIDM1LjkwNDl2Mi41MzU3YzAgMTUuOTAxNC4wMTE4MiAyNy4yNjc0IDEuMTczMTIgMzUuOTA1NCAxLjEzOTc3IDguNDc3IDMuMjk0MTUgMTMuNDg4IDYuOTc4NTUgMTcuMTczIDMuNjg0NCAzLjY4NCA4LjY5NTUgNS44MzggMTcuMTczIDYuOTc4IDguNjM3NiAxLjE2MSAyMC4wMDM2IDEuMTczIDM1LjkwNDkgMS4xNzNoMi41MzU3YzE1LjkwMTQgMCAyNy4yNjc0LS4wMTIgMzUuOTA1NC0xLjE3MyA4LjQ3Ny0xLjE0IDEzLjQ4OC0zLjI5NCAxNy4xNzMtNi45NzggMy42ODQtMy42ODUgNS44MzgtOC42OTYgNi45NzgtMTcuMTczIDEuMTYxLTguNjM4IDEuMTczLTIwLjAwNCAxLjE3My0zNS45MDUzdi0yLjUzNTdjMC0xNS45MDE0LS4wMTItMjcuMjY3NC0xLjE3My0zNS45MDUtMS4xNC04LjQ3NzUtMy4yOTQtMTMuNDg4Ni02Ljk3OC0xNy4xNzMtMy42ODUtMy42ODQ0LTguNjk2LTUuODM4NzgtMTcuMTczLTYuOTc4NTUtOC42MzgtMS4xNjEzLTIwLjAwNC0xLjE3MzEyLTM1LjkwNTMtMS4xNzMxMnptLTU5LjU0OTY2IDQuMjE1NzFjLTkuNzgyMDQgOS43ODIwNi05Ljc4MjA0IDI1LjUyNTk2LTkuNzgyMDQgNTcuMDEzODZ2Mi41MzU3YzAgMzEuNDg4NCAwIDQ3LjIzMjQgOS43ODIwNCA1Ny4wMTQ0IDkuNzgyMDYgOS43ODIgMjUuNTI1OTYgOS43ODIgNTcuMDEzODYgOS43ODJoMi41MzU3YzMxLjQ4ODQgMCA0Ny4yMzI0IDAgNTcuMDE0NC05Ljc4MnM5Ljc4Mi0yNS41MjYgOS43ODItNTcuMDE0M3YtMi41MzU3YzAtMzEuNDg4IDAtNDcuMjMxOS05Ljc4Mi01Ny4wMTM5Ni05Ljc4Mi05Ljc4MjA0LTI1LjUyNi05Ljc4MjA0LTU3LjAxNDMtOS43ODIwNGgtMi41MzU3Yy0zMS40ODggMC00Ny4yMzE5IDAtNTcuMDEzOTYgOS43ODIwNHoiIGZpbGwtcnVsZT0iZXZlbm9kZCIvPjxwYXRoIGQ9Im05My42NjA0IDI2LjE3ODRjLTguOTgyIDAtMTYuMjg4NyA3LjMwNjctMTYuMjg4NyAxNi4yODg4djYuOTgwOWgtMTguNjE1OHYtNi45ODA5YzAtOC45ODIxLTcuMzA2Ny0xNi4yODg4LTE2LjI4ODctMTYuMjg4OC04Ljk4MjEgMC0xNi4yODg4IDcuMzA2Ny0xNi4yODg4IDE2LjI4ODhzNy4zMDY3IDE2LjI4ODcgMTYuMjg4OCAxNi4yODg3aDYuOTgwOXYxOC42MTU4aC02Ljk4MDljLTguOTgyMSAwLTE2LjI4ODggNy4zMDY3LTE2LjI4ODggMTYuMjg4OCAwIDguOTgyNSA3LjMwNjcgMTYuMjg4NSAxNi4yODg4IDE2LjI4ODUgOC45ODIgMCAxNi4yODg3LTcuMzA2IDE2LjI4ODctMTYuMjg4NXYtNi45ODFoMTguNjE1OHY2Ljk4MWMwIDguOTgyNSA3LjMwNjcgMTYuMjg4NSAxNi4yODg3IDE2LjI4ODUgOC45ODI2IDAgMTYuMjg4Ni03LjMwNiAxNi4yODg2LTE2LjI4ODUgMC04Ljk4MjEtNy4zMDYtMTYuMjg4OC0xNi4yODg2LTE2LjI4ODhoLTYuOTgwOXYtMTguNjE1OGg2Ljk4MDljOC45ODI2IDAgMTYuMjg4Ni03LjMwNjYgMTYuMjg4Ni0xNi4yODg3cy03LjMwNi0xNi4yODg4LTE2LjI4ODYtMTYuMjg4OHptLTYuOTgwOSAyMy4yNjk3di02Ljk4MDljMC0zLjg2MjggMy4xMTgyLTYuOTgwOSA2Ljk4MDktNi45ODA5IDMuODYyOCAwIDYuOTgwNiAzLjExODEgNi45ODA2IDYuOTgwOSAwIDMuODYyNy0zLjExNzggNi45ODA5LTYuOTgwNiA2Ljk4MDl6bS00NC4yMTIzIDBjLTMuODYyOCAwLTYuOTgwOS0zLjExODItNi45ODA5LTYuOTgwOSAwLTMuODYyOCAzLjExODEtNi45ODA5IDYuOTgwOS02Ljk4MDkgMy44NjI3IDAgNi45ODA5IDMuMTE4MSA2Ljk4MDkgNi45ODA5djYuOTgwOXptMTYuMjg4NyAyNy45MjM2di0xOC42MTU4aDE4LjYxNTh2MTguNjE1OHptMzQuOTA0NSAyMy4yNjkzYy0zLjg2MjcgMC02Ljk4MDktMy4xMTc4LTYuOTgwOS02Ljk4MDV2LTYuOTgxaDYuOTgwOWMzLjg2MjggMCA2Ljk4MDYgMy4xMTgyIDYuOTgwNiA2Ljk4MSAwIDMuODYyNy0zLjExNzggNi45ODA1LTYuOTgwNiA2Ljk4MDV6bS01MS4xOTMyIDBjLTMuODYyOCAwLTYuOTgwOS0zLjExNzgtNi45ODA5LTYuOTgwNSAwLTMuODYyOCAzLjExODEtNi45ODEgNi45ODA5LTYuOTgxaDYuOTgwOXY2Ljk4MWMwIDMuODYyNy0zLjExODIgNi45ODA1LTYuOTgwOSA2Ljk4MDV6Ii8+PC9nPjwvc3ZnPg==",
  "roo":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgaGVpZ2h0PSIxZW0iIHN0eWxlPSJmbGV4Om5vbmU7bGluZS1oZWlnaHQ6MSIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMWVtIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjx0aXRsZT5Sb29Db2RlPC90aXRsZT48cGF0aCBkPSJNMjAuMTEzIDUuNWwtLjQ0MiAxLjU1N2EuMTU3LjE1NyAwIDAxLS4xOTYuMTA2bC03LjQxNC0yLjE1N2EuMTYuMTYgMCAwMC0uMTQzLjAyOGwtNy4zNDIgNS43NGEuMTU5LjE1OSAwIDAxLS4wNzQuMDMybC00LjM3LjY1NmEuMTU0LjE1NCAwIDAwLS4xMzIuMTYybC4wMi4yNDVjLjAwNS4wNzguMDcxLjE0LjE1Mi4xNDFsNS4wNzQuMTI4LjA1OC4wMDIgMy43NS0xLjk1M2EuMTYuMTYgMCAwMS4xNjQuMDFsMi42NTcgMS44NDdhLjE1Mi4xNTIgMCAwMS4wNjYuMTI1bC0uMDIzIDIuNDVjMCAuMDMyLjAxLjA2My4wMjguMDg5bDMuNzM3IDUuMjI3Yy4wMy4wNC4wNzcuMDY1LjEyOS4wNjVoMS4xODJhLjE1My4xNTMgMCAwMC4xNC0uMjI0bC0yLjY2NC00LjkxOWEuMTUuMTUgMCAwMS4wMDUtLjE1MmwxLjM4OS0yLjE2OWEuMTU2LjE1NiAwIDAxLjA2Mi0uMDU1bDQuOTY1LTIuNDU2YS4xNi4xNiAwIDAxLjE1OC4wMWwxLjQxOC45MjFhLjE2LjE2IDAgMDAuMDg3LjAyNmgxLjI4OWMuMTI1IDAgLjItLjEzNi4xMy0uMjM3bC0zLjU3OC01LjI5Yy0uMDc0LS4xMDktLjI0Ni0uMDgyLS4yODIuMDQ0eiI+PC9wYXRoPjwvc3ZnPg==",
  "goose":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgaGVpZ2h0PSIxZW0iIHN0eWxlPSJmbGV4Om5vbmU7bGluZS1oZWlnaHQ6MSIgdmlld0JveD0iMCAwIDI0IDI0IiB3aWR0aD0iMWVtIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjx0aXRsZT5Hb29zZTwvdGl0bGU+PHBhdGggZD0iTTIxLjU5NSAyMy42MWMxLjE2Ny0uMjU0IDIuNDA1LS45NDQgMi40MDUtLjk0NGwtMi4xNjctMS43ODRhMTIuMTI0IDEyLjEyNCAwIDAxLTIuNjk1LTMuMTMxIDEyLjEyNyAxMi4xMjcgMCAwMC0zLjk3LTQuMDQ5bC0uNzk0LS40NjJhMS4xMTUgMS4xMTUgMCAwMS0uNDg4LS44MTUuODQ0Ljg0NCAwIDAxLjE1NC0uNTc1Yy40MTMtLjU4MiAyLjU0OC0zLjExNSAyLjk0LTMuNDQuNTAzLS40MTYgMS4wNjUtLjc2MiAxLjU4Ni0xLjE1OS4wNzQtLjA1Ni4xNDgtLjExMi4yMjEtLjE3LjAwMy0uMDAyLjAwNy0uMDA0LjAwOS0uMDA3LjE2Ny0uMTMxLjMyNS0uMjcyLjQ1LS40MzguNDUzLS41MjQuNTYzLS45ODguNTktMS4xOTMtLjA2MS0uMTk3LS4yNDQtLjYzOS0uNzUzLTEuMTQ4LjMxOS4wMi43MDUuMjcyIDEuMDU2LjU2OS4yMzUtLjM3Ni40ODEtLjc3My43MjctMS4xNzEuMTY1LS4yNjYtLjA4LS40NjUtLjA4Ni0uNDcxaC0uMDAxVjMuMjJjLS4wMDctLjAwNy0uMjA2LS4yNS0uNDcxLS4wODYtLjU2Ny4zNS0xLjEzNC43MDItMS42MzkgMS4wMjEgMCAwLS41OTctLjAxMi0xLjMwNS41OTlhMi40NjQgMi40NjQgMCAwMC0uNDM4LjQ1bC0uMDA3LjAwOWMtLjA1OC4wNzItLjExNC4xNDctLjE3LjIyMS0uMzk3LjUyMS0uNzQzIDEuMDgzLTEuMTYgMS41ODctLjMyMy4zOTEtMi44NTcgMi41MjYtMy40NCAyLjk0YS44NDIuODQyIDAgMDEtLjU3NC4xNTMgMS4xMTUgMS4xMTUgMCAwMS0uODE1LS40ODhsLS40NjItLjc5NGExMi4xMjMgMTIuMTIzIDAgMDAtNC4wNDktMy45NyAxMi4xMzMgMTIuMTMzIDAgMDEtMy4xMy0yLjY5NUwxLjMzMiAwUy42NDMgMS4yMzguMzkgMi40MDVjLjM1Mi40MjggMS4yNyAxLjQ5IDIuMzQgMi4zMDJDMS41OCA0LjE2Ny43MyAzLjc1LjA2IDMuNGMtLjEwMy43NjUtLjA2MyAxLjkyLjA0MyAyLjgxNi43MjYuMzE3IDEuOTYxLjgwNiAzLjIxOSAxLjA2Ni0xLjAwNi4yMzYtMi4xMS4yNzgtMi45NjEuMjYyLjE1LjU1NC4zNTggMS4xMTkuNjQgMS42ODguMTE5LjI2My4yNS41Mi4zOS43Ny40NTIuMTI1IDIuMjIyLjM4MyAzLjE2NC4xNzFsLTIuNTEuODk3YTI3Ljc3NiAyNy43NzYgMCAwMDIuNTQ0IDIuNzI2YzIuMDMxLTEuMDkyIDIuNDk0LTEuMjQxIDQuMDE4LTIuMjM4LTIuNDY3IDIuMDA4LTMuMTA4IDIuODI4LTMuOCAzLjY3bC0uNDgzLjY3OGMtLjI1LjM1MS0uNDY5LjcyNS0uNjUgMS4xMTctLjYxIDEuMzEtMS40NyA0LjEtMS40NyA0LjEtLjE1NC40ODYuMjAyLjg0Mi42NzQuNjc0IDAgMCAyLjc5LS44NjEgNC4xLTEuNDcuMzkyLS4xODIuNzY2LS40IDEuMTE4LS42NWwuNjc3LS40ODNjLjIyNy0uMTg3LjQ1My0uMzcuNzAxLS41ODYgMCAwIDEuNzA1IDIuMDIgMy40NTggMy4zNDlsLjg5Ni0yLjUxMWMtLjIxMS45NDIuMDQ2IDIuNzEyLjE3IDMuMTYzLjI1Mi4xNDIuNTA5LjI3Mi43NzIuMzkyLjU2OS4yOCAxLjEzNC40OSAxLjY4OC42NC0uMDE2LS44NTMuMDI2LTEuOTU2LjI2MS0yLjk2Mi4yNiAxLjI1OC43NSAyLjQ5MyAxLjA2NyAzLjIxOS44OTUuMTA2IDIuMDUxLjE0NiAyLjgxNi4wNDNhNzMuODcgNzMuODcgMCAwMS0xLjMwOC0yLjY3Yy44MTEgMS4wNyAxLjg3NCAxLjk4OCAyLjMwMiAyLjM0aC0uMDAxeiI+PC9wYXRoPjwvc3ZnPg==",
  "devin":"data:image/svg+xml;base64,PHN2ZyBoZWlnaHQ9IjFlbSIgc3R5bGU9ImZsZXg6bm9uZTtsaW5lLWhlaWdodDoxIiB2aWV3Qm94PSIwIDAgMjQgMjQiIHdpZHRoPSIxZW0iIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHRpdGxlPkRldmluPC90aXRsZT48cGF0aCBkPSJNMi4wMzMgOS44NjdsMi41NTQgMS40ODNhLjU4OS41ODkgMCAwMC41OTIgMGwyLjU1NC0xLjQ4My4wMS0uMDA4YS42MDguNjA4IDAgMDAuMTEtLjA4NGwuMDEzLS4wMTVhLjYzMS42MzEgMCAwMC4wNzYtLjFjLjAwMy0uMDA1LjAwOC0uMDEuMDEtLjAxNmEuNTU4LjU1OCAwIDAwLjA1Mi0uMTI1bC4wMDctLjAyOGEuNjExLjYxMSAwIDAwLjAxOS0uMTRWNy44NjhjMC0uNTcyLjMwNy0xLjEwNS44LTEuMzkyYTEuNTk1IDEuNTk1IDAgMDExLjU5OCAwbDEuMjc3Ljc0MmEuNTQuNTQgMCAwMC4xMjkuMDUzbC4wMjguMDFjLjA0NC4wMS4wODguMDE1LjEzMy4wMTZoLjAwNmwuMDEzLS4wMDJhLjU4Ny41ODcgMCAwMC4yNy0uMDc0bC4wMTEtLjAwNCAyLjU1NC0xLjQ4M2EuNTk2LjU5NiAwIDAwLjI5Ny0uNTE2VjIuMjUzYS41OTUuNTk1IDAgMDAtLjI5Ny0uNTE2TDEyLjI5My4yNTdhLjU4Ny41ODcgMCAwMC0uNTkxIDBMOS4xNDggMS43MzdsLS4wMS4wMWEuNjA5LjYwOSAwIDAwLS4xMDkuMDgzbC0uMDE0LjAxNWEuNjMyLjYzMiAwIDAwLS4wNzYuMWMtLjAwMy4wMDUtLjAwOC4wMS0uMDEuMDE2YS41Ny41NyAwIDAwLS4wNTIuMTI0bC0uMDA3LjAyOGEuNjEyLjYxMiAwIDAwLS4wMTguMTR2MS40ODNjMCAuNTcyLS4zMDcgMS4xMDUtLjggMS4zOTNhMS41OTcgMS41OTcgMCAwMS0xLjU5OSAwbC0xLjI3Ni0uNzQyYS42MDMuNjAzIDAgMDAtLjEzLS4wNTNsLS4wMjgtLjAwOGEuNjU4LjY1OCAwIDAwLS4xMzMtLjAxOGgtLjAyYS41Ny41NyAwIDAwLS4yNjkuMDc0Yy0uMDAzLjAwMi0uMDA4LjAwMi0uMDEyLjAwNUwyLjAzMyA1Ljg3MmEuNTk2LjU5NiAwIDAwLS4yOTcuNTE1djIuOTY2YzAgLjIxMy4xMTMuNDEuMjk3LjUxNXoiIGZpbGw9IiMzOTY5Q0EiPjwvcGF0aD48cGF0aCBkPSJNMTUuOTQzIDEwLjYwN2ExLjU5NiAxLjU5NiAwIDAxMS41OTkgMGwxLjI3Ni43NGMuMDQxLjAyNS4wODUuMDQuMTMuMDU1bC4wMjguMDA4Yy4wNDMuMDEuMDg4LjAxNi4xMzMuMDE4aC4wMDVjLjAwNSAwIC4wMS0uMDAyLjAxNC0uMDAzYS40NzQuNDc0IDAgMDAuMTIyLS4wMTZsLjAyMS0uMDA1YS42MTYuNjE2IDAgMDAuMTI2LS4wNTJjLjAwNC0uMDAyLjAwOS0uMDAyLjAxMy0uMDA1bDIuNTU0LTEuNDgyYS41OTcuNTk3IDAgMDAuMjk3LS41MTZWNi4zODNhLjU5Ni41OTYgMCAwMC0uMjk3LS41MTVsLTIuNTUyLTEuNDgzYS41ODcuNTg3IDAgMDAtLjU5MiAwbC0yLjU1MyAxLjQ4Mi0uMDExLjAwOGEuNjEuNjEgMCAwMC0uMTA4LjA4NGwtLjAxNC4wMTZhLjYzNy42MzcgMCAwMC0uMDc2LjFjLS4wMDMuMDA1LS4wMDguMDEtLjAxLjAxNmEuNTcuNTcgMCAwMC0uMDUyLjEyNGwtLjAwNy4wMjlhLjYxMi42MTIgMCAwMC0uMDE4LjE0djEuNDgyYzAgLjU3Mi0uMzA3IDEuMTA1LS44IDEuMzkzYTEuNTk3IDEuNTk3IDAgMDEtMS41OTkgMGwtMS4yNzYtLjc0MmEuNTg0LjU4NCAwIDAwLS4xMy0uMDUzbC0uMDI4LS4wMDhhLjYyLjYyIDAgMDAtLjEzMy0uMDE4aC0uMDJhLjU4Ny41ODcgMCAwMC0uMjY5LjA3NGwtLjAxMi4wMDRMOS4xNSAxMGEuNTk2LjU5NiAwIDAwLS4yOTYuNTE2djIuOTY2YzAgLjIxMi4xMTIuNDA5LjI5Ni41MTVsMi41NTQgMS40ODNzLjAwOC4wMDIuMDEyLjAwNWMuMDQuMDIyLjA4Mi4wNC4xMjYuMDUybC4wMi4wMDRhLjU3LjU3IDAgMDAuMTIzLjAxN2wuMDE0LjAwMmguMDA2Yy4wNTQgMCAuMTA4LS4wMS4xNi0uMDI1YS41ODcuNTg3IDAgMDAuMTMtLjA1NGwxLjI3Ny0uNzQxYTEuNTk3IDEuNTk3IDAgMDEyLjM5OCAxLjM5MnYxLjQ4MmMwIC4wNDkuMDA3LjA5NS4wMTkuMTRsLjAwNy4wMjhhLjYxOS42MTkgMCAwMC4wNTEuMTI1Yy4wMDQuMDA2LjAwOC4wMS4wMS4wMTZhLjYuNiAwIDAwLjA3Ni4xbC4wMTQuMDE1Yy4wMzMuMDMyLjA2OS4wNi4xMDguMDg0LjAwNC4wMDIuMDA2LjAwNi4wMTEuMDA4bDIuNTU0IDEuNDgzYS41OS41OSAwIDAwLjU5MyAwbDIuNTU0LTEuNDgzYS41OTcuNTk3IDAgMDAuMjk2LS41MTZ2LTIuOTY1YS41OTUuNTk1IDAgMDAtLjI5Ni0uNTE2bC0yLjU1NC0xLjQ4M3MtLjAwOC0uMDAyLS4wMTItLjAwNWEuNTQuNTQgMCAwMC0uMTI2LS4wNTFjLS4wMDctLjAwMy0uMDEzLS4wMDMtLjAyLS4wMDVhLjYzNS42MzUgMCAwMC0uMTI1LS4wMTdoLS4wMThhLjU1Ny41NTcgMCAwMC0uMTYuMDI2LjU4OC41ODggMCAwMC0uMTMuMDUzbC0xLjI3Ni43NDJhMS41OTUgMS41OTUgMCAwMS0xLjU5OCAwIDEuNjE1IDEuNjE1IDAgMDEwLTIuNzg1bC0uMDA1LS4wMDF6IiBmaWxsPSIjMjFDMTlBIj48L3BhdGg+PHBhdGggZD0iTTE0Ljg0OCAxOC4yNjVsLTIuNTU0LTEuNDgyLS4wMTItLjAwNWEuNTI2LjUyNiAwIDAwLS4xMjYtLjA1MmMtLjAwNy0uMDAyLS4wMTQtLjAwMi0uMDItLjAwNWEuNjQuNjQgMCAwMC0uMTI0LS4wMTdoLS4wMmEuNTYuNTYgMCAwMC0uMTYuMDI2LjU4OC41ODggMCAwMC0uMTMuMDUzbC0xLjI3Ni43NDJhMS41OTQgMS41OTQgMCAwMS0xLjU5OCAwYy0uNDkzLS4yODYtLjgtLjgyLS44LTEuMzkzVjE0LjY1YS41NjMuNTYzIDAgMDAtLjAxOC0uMTRsLS4wMDgtLjAyOGEuNjA0LjYwNCAwIDAwLS4wNTEtLjEyNGwtLjAxLS4wMTdhLjYwMy42MDMgMCAwMC0uMDc2LS4xbC0uMDE0LS4wMTVhLjU5Ni41OTYgMCAwMC0uMTA5LS4wODRjLS4wMDMtLjAwMi0uMDA1LS4wMDYtLjAxLS4wMDhMNS4xNzggMTIuNjVhLjU4Ny41ODcgMCAwMC0uNTkxIDBsLTIuNTU0IDEuNDgzYS41OTYuNTk2IDAgMDAtLjI5Ny41MTZ2Mi45NjVjMCAuMjEzLjExMy40MS4yOTcuNTE2bDIuNTU0IDEuNDgzLjAxMi4wMDRhLjYxOC42MTggMCAwMC4yNjcuMDc0bC4wMTYuMDAyaC4wMDdhLjU1LjU1IDAgMDAuMTYtLjAyNi41ODQuNTg0IDAgMDAuMTI5LS4wNTNsMS4yNzctLjc0MmExLjU5NyAxLjU5NyAwIDAxMi4zOTggMS4zOTN2MS40ODJjMCAuMDUuMDA3LjA5NS4wMTkuMTRsLjAwNy4wMjhjLjAxMy4wNDQuMDMuMDg1LjA1MS4xMjVsLjAxLjAxNmMuMDIyLjAzNi4wNDcuMDcuMDc2LjFsLjAxNC4wMTVjLjAzMi4wMzIuMDY5LjA2LjEwOS4wODRsLjAxLjAwOCAyLjU1NCAxLjQ4M2EuNTg3LjU4NyAwIDAwLjU5MyAwbDIuNTU0LTEuNDgzYS41OTYuNTk2IDAgMDAuMjk2LS41MTV2LTIuOTY2YS41OTYuNTk2IDAgMDAtLjI5Ni0uNTE2aC0uMDAyeiIgZmlsbD0iIzAyOTRERSI+PC9wYXRoPjwvc3ZnPg==",
  "zed":"data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI5NiIgaGVpZ2h0PSI5NiIgZmlsbD0ibm9uZSIgdmlld0JveD0iMCAwIDk2IDk2Ij48ZyBjbGlwLXBhdGg9InVybCgjemVkX2xvZ29fX2EpIj48cGF0aCBmaWxsPSJjdXJyZW50Q29sb3IiIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0iTTkgNmEzIDMgMCAwIDAtMyAzdjY2SDBWOWE5IDkgMCAwIDEgOS05aDgwLjM3OWM0LjAwOSAwIDYuMDE2IDQuODQ3IDMuMTgyIDcuNjgyTDQzLjA1NSA1Ny4xODdINTdWNTFoNnY3LjY4OGE0LjUgNC41IDAgMCAxLTQuNSA0LjVIMzcuMDU1TDI2Ljc0MyA3My41SDczLjVWMzZoNnYzNy41YTYgNiAwIDAgMS02IDZIMjAuNzQzTDEwLjI0MyA5MEg4N2EzIDMgMCAwIDAgMy0zVjIxaDZ2NjZhOSA5IDAgMCAxLTkgOUg2LjYyMWMtNC4wMDkgMC02LjAxNi00Ljg0Ny0zLjE4Mi03LjY4Mkw1Mi43NTcgMzlIMzl2NmgtNnYtNy41YTQuNSA0LjUgMCAwIDEgNC41LTQuNWgyMS4yNTdsMTAuNS0xMC41SDIyLjVWNjBoLTZWMjIuNWE2IDYgMCAwIDEgNi02aDUyLjc1N0w4NS43NTcgNkg5WiIgY2xpcC1ydWxlPSJldmVub2RkIi8+PC9nPjxkZWZzPjxjbGlwUGF0aCBpZD0iemVkX2xvZ29fX2EiPjxwYXRoIGZpbGw9IiNmZmYiIGQ9Ik0wIDBoOTZ2OTZIMHoiLz48L2NsaXBQYXRoPjwvZGVmcz48L3N2Zz4=",
  "codebuddy":"data:image/svg+xml;base64,PHN2ZyBoZWlnaHQ9IjFlbSIgc3R5bGU9ImZsZXg6bm9uZTtsaW5lLWhlaWdodDoxIiB2aWV3Qm94PSIwIDAgMjQgMjQiIHdpZHRoPSIxZW0iIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHRpdGxlPkNvZGVCdWRkeTwvdGl0bGU+PHBhdGggZD0iTTE4LjgyMSAwSDUuMThBNS4xNzkgNS4xNzkgMCAwMDAgNS4xNzlWMTguODJBNS4xNzkgNS4xNzkgMCAwMDUuMTc5IDI0SDE4LjgyQTUuMTc5IDUuMTc5IDAgMDAyNCAxOC44MjFWNS4xOEE1LjE3OSA1LjE3OSAwIDAwMTguODIxIDB6IiBmaWxsPSJ1cmwoI2xvYmUtaWNvbnMtY29kZS1idWRkeS1fUl8wXykiPjwvcGF0aD48cGF0aCBkPSJNMTguNzc3IDEuNjQ3Yy4yOC0uMDIuNTM2LjExNC45NzIuNTEgMS4wMTguOTI2IDIuNDM3IDIuODI4IDMuMzE4IDQuNDUybC4zNC42MzEuNDgyLjI0LjExLjA2djMuNjM4YTUuMjA2IDUuMjA2IDAgMDAtNS4zMi0xLjIzYy0uNDkxLjE2Ni0xLjAyMS40NzEtMi4wOCAxLjA4MmwtNi4wOSAzLjUxNmMtMS4wNTcuNjEtMS41ODYuOTE2LTEuOTc1IDEuMjU5YTUuMjA4IDUuMjA4IDAgMDAtMS40OTMgNS41NzJjLjE2NS40OS40NzEgMS4wMiAxLjA4MiAyLjA4bC4zMTUuNTQzaC0zLjI2Yy0uNjg1IDAtMS4zNC0uMTM1LTEuOTM5LS4zNzctLjE2OS0uOTU2LS4wMDktMS43ODkuNDY5LTIuMzM1LjE1OC0uMTguMTY0LS4xODkuMTMtLjQ5M2ExMS44NDYgMTEuODQ2IDAgMDEtLjA1Ny0xLjcxMWwuMDItLjQ0NC0uNjY3LTEuMThDMi4xIDE1LjYyMiAxLjQ0NSAxNC4wNzggMS4xOTIgMTIuOWMtLjEzMy0uNjQ3LS4xMjUtLjkzNC4wNC0xLjE0Ni4xLS4xMjguNDI3LS4yNjEuODIyLS4zMzQuOTk0LS4xNzUgMy4xNjItLjAxNyA1LjU3NS40MWwuMjUuMDQzLjU1MS0uNDg3Yy45MTUtLjgxIDEuNTIyLTEuMjY0IDIuNjQxLTEuOTYyIDEuMTY3LS43MyAyLjQ4NC0xLjMzMSAzLjk2Ny0xLjgwN2wuNDc2LS4xNTIuMjYxLS42ODhjLjkzNy0yLjQ3MSAxLjg5Ni00LjI5MyAyLjU4LTQuOS4yMzUtLjIxLjI1LS4yMi40MjItLjIzeiIgZmlsbD0iI2ZmZiI+PC9wYXRoPjxwYXRoIGQ9Ik0xMi4xMzkgMTguMmExLjIwMyAxLjIwMyAwIDAxMS42NDIuNDRsMS4yOTYgMi4yNDNhMS4yMDQgMS4yMDQgMCAwMS0yLjA4MyAxLjIwM2wtMS4yOTYtMi4yNDNhMS4yMDMgMS4yMDMgMCAwMS40NC0xLjY0NHpNMTguNjI5IDE0LjQ1MmExLjIwMyAxLjIwMyAwIDAxMS42NDIuNDRsMS4yOTUgMi4yNDRhMS4yMDMgMS4yMDMgMCAxMS0yLjA4MyAxLjIwM2wtMS4yOTUtMi4yNDNhMS4yMDMgMS4yMDMgMCAwMS40NC0xLjY0NHoiIGZpbGw9IiNmZmYiPjwvcGF0aD48ZGVmcz48cmFkaWFsR3JhZGllbnQgY3g9IjAiIGN5PSIwIiBncmFkaWVudFRyYW5zZm9ybT0ibWF0cml4KC05LjAwMDA5IC0xNiAxNiAtOS4wMDAwOSAyMSAyNC41KSIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiIGlkPSJsb2JlLWljb25zLWNvZGUtYnVkZHktX1JfMF8iIHI9IjEiPjxzdG9wIHN0b3AtY29sb3I9IiMyRUE5OUQiPjwvc3RvcD48c3RvcCBvZmZzZXQ9IjEiIHN0b3AtY29sb3I9IiM2QzRERkYiPjwvc3RvcD48L3JhZGlhbEdyYWRpZW50PjwvZGVmcz48L3N2Zz4=",
  "kimi-code":"data:image/svg+xml;base64,PHN2ZyBoZWlnaHQ9IjFlbSIgc3R5bGU9ImZsZXg6bm9uZTtsaW5lLWhlaWdodDoxIiB2aWV3Qm94PSIwIDAgMjQgMjQiIHdpZHRoPSIxZW0iIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHRpdGxlPktpbWk8L3RpdGxlPjxwYXRoIGQ9Ik0yMS44NDYgMGExLjkyMyAxLjkyMyAwIDExMCAzLjg0NkgyMC4xNWEuMjI2LjIyNiAwIDAxLS4yMjctLjIyNlYxLjkyM0MxOS45MjMuODYxIDIwLjc4NCAwIDIxLjg0NiAweiIgZmlsbD0iIzE3ODNGRiI+PC9wYXRoPjxwYXRoIGQ9Ik0xMS4wNjUgMTEuMTk5bDcuMjU3LTcuMmMuMTM3LS4xMzYuMDYtLjQxLS4xMTYtLjQxSDE0LjNhLjE2NC4xNjQgMCAwMC0uMTE3LjA1MWwtNy44MiA3Ljc1NmMtLjEyMi4xMi0uMzAyLjAxMy0uMzAyLS4xNzlWMy44MmMwLS4xMjctLjA4My0uMjMtLjE4NS0uMjNIMy4xODZjLS4xMDMgMC0uMTg2LjEwMy0uMTg2LjIzVjE5Ljc3YzAgLjEyOC4wODMuMjMuMTg2LjIzaDIuNjljLjEwMyAwIC4xODYtLjEwMi4xODYtLjIzdi0zLjI1YzAtLjA2OS4wMjUtLjEzNS4wNjktLjE3OGwyLjQyNC0yLjQwNmEuMTU4LjE1OCAwIDAxLjIwNS0uMDIzbDYuNDg0IDQuNzcyYTcuNjc3IDcuNjc3IDAgMDAzLjQ1MyAxLjI4M2MuMTA4LjAxMi4yLS4wOTUuMi0uMjN2LTMuMDZjMC0uMTE3LS4wNy0uMjEyLS4xNjQtLjIyN2E1LjAyOCA1LjAyOCAwIDAxLTIuMDI3LS44MDdsLTUuNjEzLTQuMDY0Yy0uMTE3LS4wNzgtLjEzMi0uMjc5LS4wMjgtLjM4MXoiIGZpbGw9ImN1cnJlbnRDb2xvciI+PC9wYXRoPjwvc3ZnPg==",
  "qoder":"data:image/svg+xml;base64,PHN2ZyBmaWxsPSJjdXJyZW50Q29sb3IiIGhlaWdodD0iMWVtIiBzdHlsZT0iZmxleDpub25lO2xpbmUtaGVpZ2h0OjEiIHZpZXdCb3g9IjAgMCAyNCAyNCIgd2lkdGg9IjFlbSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48dGl0bGU+UW9kZXI8L3RpdGxlPjxwYXRoIGQ9Ik0yMy4zNzYgMTQuNDU4di00LjA1NmMwLTIuMzA0LTEuMDAzLTQuMTU0LTIuNzQ4LTUuMDc1TDExLjYxMi41NzRsLS4wNDYuMDg2LS4wNDUuMDg2YzEuNjguODg2IDIuNjQ0IDIuNjczIDIuNjQ0IDQuOTAydjQuMDU2YTcuOTI4IDcuOTI4IDAgMDEtLjAxNC40NTRsLS4wMDUuMDYxYy0uMDA1LjA4MS0uMDEuMTY0LS4wMTguMjQ1YTQuODk3IDQuODk3IDAgMDEtLjAxMS4xbC0uMDEuMDc2Yy0uMDA4LjA2OC0uMDE1LjEzNS0uMDI1LjIwM2wtLjAxOC4xMTMtLjAxLjA1OGE5Ljk5IDkuOTkgMCAwMS0uMDk4LjUxM2wtLjAwNy4wM2E3LjIwOSA3LjIwOSAwIDAxLS4wNzQuMjk0bC0uMDI0LjA4NmMtLjAyNy4wOTktLjA1Ni4xOTctLjA4Ny4yOTZsLS4wMjcuMDg1YTkuNTkyIDkuNTkyIDAgMDEtLjExMS4zMjNsLS4wMzMuMDg1LS4wMTguMDQ2Yy0uMDMyLjA4Mi0uMDY0LjE2Ni0uMDk4LjI0OC0uMDE5LjA0OC0uMDQuMDk2LS4wNjEuMTQ1bC0uMDA3LjAxN2E2IDYgMCAwMS0uMDg0LjE4N2MtLjAyNC4wNTYtLjA1LjExLS4wNzcuMTY1LS4wMy4wNjEtLjA1OC4xMjItLjA4OS4xODJhOS40MjMgOS40MjMgMCAwMS0uMTc2LjMzMmMtLjAzLjA1Ni0uMDYyLjExMS0uMDk0LjE2Ny0uMDMxLjA1My0uMDYyLjEwOC0uMDk1LjE2LS4wMzMuMDU1LS4wNjYuMTEtLjEwMS4xNjQtLjAzMy4wNTMtLjA2NS4xMDQtLjEuMTU1LS4wMzQuMDU1LS4wNy4xMDctLjExMS4xNjlsLS4wOTkuMTQ0YTE1LjE5MyAxNS4xOTMgMCAwMS0uMzQuNDU3Yy0uMDQuMDUtLjA4LjEwMi0uMTIxLjE1MWwtLjEwNy4xMjgtLjAwNy4wMDhhNi45ODcgNi45ODcgMCAwMS0uMjYyLjI5OGwtLjE0OS4xNi0uMTE2LjEyYTkuNTYyIDkuNTYyIDAgMDEtLjIwNC4xOThsLS4wMy4wMy0uMDcyLjA2OWE5LjA1IDkuMDUgMCAwMS0uMjYzLjIzNWwtLjAyNS4wMjItLjAyOS4wMjYtLjA0Mi4wMzVhMTEuNyAxMS43IDAgMDEtLjIyLjE4bC0uMDcuMDU1LS4wMTguMDEzYTguOTA0IDguOTA0IDAgMDEtLjE5NC4xNDZjLS4wMjkuMDItLjA1Ny4wNDItLjA4Ni4wNjNhNy43IDcuNyAwIDAxLS4yMi4xNTJsLS4wNTcuMDRhOC44NjUgOC44NjUgMCAwMS0uMjkzLjE4NWwtLjA2Mi4wMzdhMTAuNDI0IDEwLjQyNCAwIDAxLS4zMDcuMTczbC0uMDM3LjAyLS4xOTYuMTAzLS4xMDguMDUyLS4wMTIuMDA2YTYuMTk2IDYuMTk2IDAgMDEtLjMxNS4xNDNjLS4wNjUuMDI4LS4xMy4wNTQtLjE5Ni4wOGwtLjAzNS4wMTQtLjA4Ni4wMzRjLS4wNy4wMjYtLjE0My4wNS0uMjE1LjA3NWwtLjAzOS4wMTQtLjA2NC4wMjNhOC4wNTYgOC4wNTYgMCAwMS0uMzIzLjA5N2wtLjYzLjE3M2E3LjI4NSA3LjI4NSAwIDAxLS4zMy4wOGwtLjA3LjAxNWMtLjA1My4wMTItLjEwNC4wMjMtLjE1Ny4wMzJsLS4wNjUuMDExLS4wODUuMDE1YTIuMzMyIDIuMzMyIDAgMDEtLjE5NC4wMjdsLS4wODUuMDFhNC43MTUgNC43MTUgMCAwMS0uMTYuMDE4bC0uMDM0LjAwM2E0Ljg2MSA0Ljg2MSAwIDAxLS4yNDYuMDE2aC0uMDMzYTIuNzE0IDIuNzE0IDAgMDEtLjE1NS4wMDVoLS4xMDZhMy4zODQgMy4zODQgMCAwMS0uMjI1LS4wMDdINC44NmwtLjE1LS4wMTItLjA2Ni0uMDA2YTUuNTg2IDUuNTg2IDAgMDEtLjE4Ny0uMDJsLS4wNC0uMDA1YTUuMTQgNS4xNCAwIDAxLS4yMTktLjAzNWwtLjA1NC0uMDFhNi45NDMgNi45NDMgMCAwMS0uMzQ3LS4wODJsLS4wMy0uMDA4LS4wMzgtLjAxYTUuMDM0IDUuMDM0IDAgMDEtLjI2OS0uMDg2bC0uMDYzLS4wMjNhNC4yMTYgNC4yMTYgMCAwMS0uMTg4LS4wNzNsLS4wNzEtLjAzMS0uMDE2LS4wMDdhNC45NTkgNC45NTkgMCAwMS0uMTYtLjA3NGwtLjAyNi0uMDEzYS4xNjQuMTY0IDAgMDAtLjAxNC0uMDA3bC0uNjcxLS4zNTEuNDg2LjQ4NmguMDE2bDguOTk1IDQuNzQyLjA5My4wNDguMDMuMDE0LjAyLjAxYy4wNTYuMDI2LjExMS4wNTIuMTY5LjA3NmwuMDE2LjAwOC4wNzMuMDMyLjE5NS4wNzYuMDIyLjAwOGEuNzE4LjcxOCAwIDAxLjAzLjAxMmwuMDE0LjAwNGE0LjY5MyA0LjY5MyAwIDAwLjMyMy4xbC4wMjcuMDA3Yy4wNzMuMDIuMTQ3LjAzOC4yMi4wNTVsLjAxOC4wMDQuMDI3LjAwNi4wNjYuMDEzLjA4OC4wMTZjLjA3NS4wMTQuMTUuMDI2LjIyNi4wMzhsLjA0Mi4wMDRjLjA2NC4wMDkuMTI4LjAxNi4xOTMuMDIybC4xMjYuMDEyLjA2LjAwMy4wNS4wMDIuMDk4LjAwNWMuMDQ2LjAwMi4wOTQuMDAyLjE0LjAwM2guMTJjLjA1IDAgLjEtLjAwMi4xNjEtLjAwNWguMDMzbC4wNy0uMDA0YTYuMTcgNi4xNyAwIDAwLjE4NC0uMDE0bC4wMzMtLjAwM2EuNzUzLjc1MyAwIDAwLjA1OC0uMDA1bC4xMDgtLjAxMi4wODEtLjAxLjA4LS4wMS4xMjktLjAyMS4wODItLjAxNC4wNzEtLjAxMmMuMDU0LS4wMS4xMDctLjAyMS4xNi0uMDMzbC4wNjYtLjAxMy4wNTktLjAxM2MuMDk2LS4wMjIuMTkyLS4wNDYuMjg3LS4wNzNsLjYzLS4xNzJhNy4zNTQgNy4zNTQgMCAwMC4zOTctLjEyMmwuMDQtLjAxNWMuMDc1LS4wMjUuMTQ5LS4wNTEuMjIyLS4wNzguMDMyLS4wMTEuMDYyLS4wMjQuMDkzLS4wMzdsLjAzLS4wMTJjLjA2Ny0uMDI3LjEzNS0uMDU0LjItLjA4MmwuMTI4LS4wNTYuMTk1LS4wOS4wMjEtLjAxLjEwMi0uMDVjLjA2OC0uMDM0LjEzNS0uMDY5LjIwMi0uMTA1bC4wMzctLjAyLjA3My0uMDM4Yy4wOC0uMDQ0LjE2LS4wOTIuMjQtLjEzOWwuMDI2LS4wMTVhOC4wODYgOC4wODYgMCAwMC4zMjItLjJsLjA2NS0uMDQ1IDEuOTguOTAyYTEuNzQ4IDEuNzQ4IDAgMDAyLjQ3Mi0xLjU5di03LjMzbC4wMDQuMDA0eiIgZmlsbD0iIzJBREI1QyI+PC9wYXRoPjxwYXRoIGQ9Ik0xMS42MTcuNTc2YTMuOTA0IDMuOTA0IDAgMDAtLjA5My0uMDQ3Yy0uMDE2LS4wMDktLjAzMy0uMDE2LS4wNS0uMDI0YTUuODU0IDUuODU0IDAgMDAtLjE2Ni0uMDc3bC0uMDktLjA0YTQuMDk0IDQuMDk0IDAgMDAtLjE5NC0uMDc0Yy0uMDE3LS4wMDYtLjAzNS0uMDE1LS4wNTMtLjAybC0uMDEzLS4wMDVhNS4xOCA1LjE4IDAgMDAtLjI3Ny0uMDg4bC0uMDctLjAxOWE0LjAzNCA0LjAzNCAwIDAwLS4yMTktLjA1M2MtLjAxNS0uMDAzLS4wMy0uMDA4LS4wNDQtLjAxMkwxMC4yNTMuMWwtLjA1Ny0uMDExYTUuMTc3IDUuMTc3IDAgMDAtLjIyNS0uMDM2TDkuOTI4LjA0N2E1Ljk3MiA1Ljk3MiAwIDAwLS4xOTEtLjAyMkw5LjY2OS4wMmExLjMzIDEuMzMgMCAwMC0uMDU4LS4wMDVMOS41MTUuMDA5YTQuMDU4IDQuMDU4IDAgMDAtLjExMS0uMDA1QzkuMzU0IDAgOS4zMDQgMCA5LjI1NCAwaC0uMTA5Yy0uMDUyIDAtLjEwNi4wMDQtLjE2LjAwNEw4Ljg4NC4wMUE1LjMyIDUuMzIgMCAwMDguNy4wMjJsLS4wODMuMDA2aC0uMDA4Yy0uMDUuMDA1LS4xLjAxMy0uMTUuMDE5bC0uMTIuMDE0Yy0uMDU2LjAwOC0uMTEyLjAxOC0uMTY5LjAyOC0uMDM3LjAwNi0uMDc0LjAxMS0uMTEuMDE4YTcuMDU0IDcuMDU0IDAgMDAtLjU3Mi4xMzNsLS42My4xNzJjLS4xMTEuMDMxLS4yMi4wNjQtLjMzLjEtLjAzNy4wMTEtLjA3Mi4wMjUtLjEwOC4wMzdhMTIuOTEgMTIuOTEgMCAwMC0uMzQ1LjEyNmMtLjA2Ny4wMjctLjEzMy4wNTQtLjIuMDgzbC0uMTI4LjA1NWExMS45MTYgMTEuOTE2IDAgMDAtLjMxOC4xNSA3LjM3NiA3LjM3NiAwIDAwLS4zMTEuMTYzYy0uMDgyLjA0NS0uMTYuMDkyLS4yNC4xNGE5LjQyNCA5LjQyNCAwIDAwLS4zNS4yMThsLS4wMTYuMDEtLjA2LjA0YTkuMjQyIDkuMjQyIDAgMDAtLjUxLjM3IDEyLjU0IDEyLjU0IDAgMDAtLjMxNS4yNTRsLS4wNDMuMDM0LS4wMS4wMDctLjA0NS4wNDFjLS4wOS4wNzgtLjE4LjE1OC0uMjY4LjI0bC0uMTA2LjEwMWMtLjA3LjA2Ny0uMTM5LjEzNS0uMjA3LjIwNGwtLjA1Ni4wNTQtLjA2My4wNjctLjE1My4xNjQtLjEyLjEzMy0uMTQ4LjE3Yy0uMDI0LjAzLS4wNDkuMDU3LS4wNzMuMDg2bC0uMDQzLjA1M2E1Ljk2IDUuOTYgMCAwMC0uMTIzLjE1NWwtLjExOC4xNTFjLS4wNC4wNTMtLjA4LjEwNi0uMTE4LjE2bC0uMDc1LjEwMS0uMDM4LjA1Ni0uMTA3LjE1NS0uMTEuMTY0YTkuOTEgOS45MSAwIDAwLS4xNjguMjY1Yy0uMDEyLjAyLS4wMjMuMDQzLS4wMzcuMDYzYTEyLjQzIDEyLjQzIDAgMDAtLjE5Mi4zMzVsLS4wOS4xNjhjLS4wMTkuMDM0LS4wNC4wNy0uMDU3LjEwNS0uMDExLjAyMi0uMDIuMDQzLS4wMzIuMDY1bC0uMDkyLjE4OC0uMDguMTY3YTE5LjE1IDE5LjE1IDAgMDAtLjA4My4xOTJjLS4wMTcuMDM4LS4wMzUuMDc2LS4wNS4xMTUtLjAwOC4wMTYtLjAxNC4wMzQtLjAyMS4wNTEtLjAzNS4wODMtLjA2Ny4xNjctLjEuMjUzbC0uMDUxLjEzNGMtLjA0LjExLS4wNzcuMjItLjExMy4zM2wtLjAyLjA1N2MwIC4wMDIgMCAuMDA1LS4wMDIuMDA3bC0uMDA4LjAyNmMtLjAzMi4xLS4wNi4yLS4wOS4zMDFsLS4wMjMuMDg5Yy0uMDI3LjEtLjA1Mi4yLS4wNzUuMzAxbC0uMDA3LjAzYTcuNjMgNy42MyAwIDAwLS4wNTcuMjY3bC0uMDA4LjA0OGMtLjAxNS4wNzQtLjAyNi4xNDgtLjAzOC4yMjNMLjA4MiA4LjRjLS4wMTEuMDc4LS4wMi4xNTYtLjAyOS4yMzQtLjAwNi4wNTEtLjAxMy4xMDMtLjAxNy4xNTRhNi41NyA2LjU3IDAgMDAtLjAyLjI2Yy0uMDAzLjA0NC0uMDA3LjA4Ni0uMDA5LjEzLS4wMDQuMTI4LS4wMDcuMjU3LS4wMDcuMzg2djQuMDU2YzAgMS40NzguNDIgMi43NDEgMS4xMzggMy42OTJBNC43NSA0Ljc1IDAgMDAyLjczIDE4LjY3bDkuMDE1IDQuNzUzYy0xLjY1Ni0uODc0LTIuNzI4LTIuNjg1LTIuNzMtNS4wNTF2LTQuMDU2YzAtLjEzLjAwNC0uMjYuMDEtLjM5LjAwMi0uMDQzLjAwNi0uMDg1LjAxLS4xMjguMDA1LS4wODguMDEtLjE3NC4wMTktLjI2MWwuMDE3LS4xNTVjLjAxLS4wNzcuMDE4LS4xNTUuMDI5LS4yMzRsLjAyNi0uMTY0Yy4wMTMtLjA3NC4wMjUtLjE1LjAzOS0uMjIzLjAyLS4xMDUuMDQtLjIxLjA2NC0uMzEzbC4wMDgtLjAzMWMuMDIzLS4xLjA0OC0uMjAxLjA3NS0uMzAxbC4wMjMtLjA4OGMuMDI4LS4xLjA1OC0uMjAyLjA5LS4zMDJsLjAwOC0uMDI1LjAyMS0uMDYzYy4wMzYtLjExLjA3My0uMjIuMTEzLS4zM2wuMDUyLS4xMzRjLjAzMS0uMDg1LjA2NS0uMTY5LjEtLjI1My4wMjItLjA1Ni4wNDctLjExMS4wNy0uMTY2YTEzLjg1NiAxMy44NTYgMCAwMS4xNjQtLjM1OGMuMDMtLjA2My4wNi0uMTI2LjA5Mi0uMTg4bC4wODgtLjE3MmE5LjIyIDkuMjIgMCAwMS4xODctLjMzOGwuMDk2LS4xNjRjLjAzNC0uMDU3LjA2OS0uMTEyLjEwNC0uMTY4bC4xLS4xNTlhMTAuNDkgMTAuNDkgMCAwMS41NjctLjc4NmwuMTIzLS4xNTUuMTE2LS4xMzljLjA1LS4wNTcuMDk4LS4xMTUuMTQ4LS4xNzFhMTQuMDkyIDE0LjA5MiAwIDAxLjI3Mi0uMjk3IDkuNzA2IDkuNzA2IDAgMDEuNDMyLS40MjVjLjA4OC0uMDgzLjE3Ny0uMTYzLjI2OC0uMjQxbC4wNTQtLjA0OGExMC4wOCAxMC4wOCAwIDAxLjU1My0uNDM1bC4wOTItLjA2OGMuMDc1LS4wNTMuMTUtLjEwNS4yMjYtLjE1Ni4wMTktLjAxMy4wMzgtLjAyOC4wNi0uMDRhOS4xOCA5LjE4IDAgMDEuMzYyLS4yMjdjLjA4LS4wNDcuMTYtLjA5NC4yNDEtLjEzOWwuMTEtLjA1OGE3LjY0MyA3LjY0MyAwIDAxLjUyMS0uMjU2bC4xMjYtLjA1NmE3LjUwOSA3LjUwOSAwIDAxLjU0Ni0uMjA4bC4xMDctLjAzN2MuMTEtLjAzNi4yMi0uMDY5LjMzLS4xbC42My0uMTcyYy4wOTUtLjAyNi4xOTEtLjA1LjI4Ny0uMDcybC4wOTctLjAyYy4wNjItLjAxNC4xMjUtLjAyOS4xODctLjA0bC4xMTQtLjAxOGMuMDU1LS4wMS4xMS0uMDIuMTY2LS4wMjguMDQtLjAwNi4wOC0uMDEuMTItLjAxNC4wNTMtLjAwNy4xMDUtLjAxNC4xNTctLjAxOWwuMDgzLS4wMDZjLjA2MS0uMDA1LjEyMy0uMDEuMTg0LS4wMTMuMDM0LS4wMDMuMDY3LS4wMDMuMTAxLS4wMDRsLjE2LS4wMDZoLjExYTMuMTg3IDMuMTg3IDAgMDEuMjYxLjAwOGwuMTUzLjAxLjA2Ny4wMDdjLjA2NC4wMDYuMTI4LjAxMy4xOTIuMDIybC4wNDMuMDA1YTUuMjMyIDUuMjMyIDAgMDEuMjgxLjA0N2wuMTQxLjAzYy4wNzMuMDE2LjE0Ni4wMzUuMjE4LjA1M2wuMDcuMDE5Yy4wOTQuMDI2LjE4Ny4wNTUuMjc4LjA4N2wuMDY3LjAyNWE0LjMyNiA0LjMyNiAwIDAxLjQ0OS4xOWwuMTQzLjA3MkwxMS42MTcuNTc2eiI+PC9wYXRoPjwvc3ZnPg==",
  "pi":"data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA4MDAgODAwIj4KICAKICAKICA8cGF0aCBjbGFzcz0ibG9nby1tYXJrIiBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGQ9IgogICAgTTE2NS4yOSAxNjUuMjkKICAgIEg1MTcuMzYKICAgIFY0MDAKICAgIEg0MDAKICAgIFY1MTcuMzYKICAgIEgyODIuNjUKICAgIFY2MzQuNzIKICAgIEgxNjUuMjkKICAgIFoKICAgIE0yODIuNjUgMjgyLjY1CiAgICBWNDAwCiAgICBINDAwCiAgICBWMjgyLjY1CiAgICBaCiAgIi8+CiAgCiAgPHBhdGggY2xhc3M9ImxvZ28tbWFyayIgZD0iTTUxNy4zNiA0MDAgSDYzNC43MiBWNjM0LjcyIEg1MTcuMzYgWiIvPgo8L3N2Zz4=",
});
function updateGlobalUI(g){
  const adoptGuard = arguments.length > 1 && arguments[1] && typeof arguments[1] === "object" ? arguments[1] : null;
  const forceAdopt = !!(adoptGuard && adoptGuard.force);
  // Every status GET carries the edit generations it saw when it started. A
  // response may only adopt a field the user has not touched since then.
  const targetsEdited = !!(adoptGuard && adoptGuard.targetsGen !== undefined && adoptGuard.targetsGen !== globalTargetsEditGen);
  const intervalEdited = !!(adoptGuard && adoptGuard.intervalGen !== undefined && adoptGuard.intervalGen !== globalIntervalEditGen);
  const targetsStale = !!(adoptGuard && adoptGuard.seq !== undefined && adoptGuard.seq < globalTargetsAppliedSeq);
  const intervalStale = !!(adoptGuard && adoptGuard.seq !== undefined && adoptGuard.seq < globalIntervalAppliedSeq);
  currentGlobalStatus = g;
  try{ if(typeof renderRulesLock === "function") renderRulesLock(); }catch(eR){}
  updateCommonSyncState("global", g);
  renderGlobalTable(g.providers || []);
  try{ applySearchFilter(); }catch(e){}
  globalLogState = {loaded:true, tail:g.tail || "", error:null};
  renderGlobalStatus();
  renderGlobalLog();
  // Poll-driven status must never clobber unsaved edits: dirty inputs are
  // refreshed only after save or explicit reload. A missed change event still
  // shows up as a real difference, so detect it before adopting the server state.
  try{ if(!forceAdopt && !globalTargetsDirty && globalTargetsDirtyNow()){ globalTargetsDirty = true; lastGlobalPlan = null; } }catch(e0){}
  if(!globalTargetsSaving && !targetsStale){
    try{
      if(targetsEdited){
        // Keep the user's checkboxes, but the successful response is the new server truth to diff against.
        globalSavedTargets = (g.targets || []).slice();
        globalTargetsDirty = globalTargetsDirtyNow();
        if(adoptGuard) globalTargetsAppliedSeq = adoptGuard.seq;
      } else if(forceAdopt || (!globalTargetsDirty && !(adoptGuard && globalReloadProtectsTargets()))){
        const wanted = (g.targets || []).slice();
        const cs = globalTargetCheckboxes();
        for(let i=0;i<cs.length;i++){ cs[i].checked = wanted.indexOf(cs[i].value) >= 0; }
        globalSavedTargets = wanted;
        if(forceAdopt){ globalTargetsDirty = false; }
        if(adoptGuard) globalTargetsAppliedSeq = adoptGuard.seq;
      }
    }catch(e2){}
  }
  try{ renderGlobalTargetsUI(); }catch(e6){}
  const intervalAdoptable = !intervalStale && !(adoptGuard && !forceAdopt && globalReloadProtectsInterval()) && (!globalIntervalDirty || (forceAdopt && !globalTargetsSaving && !intervalEdited));
  try{
    if(g.intervalMinutes !== null && g.intervalMinutes !== undefined && intervalAdoptable){
      document.getElementById("numGlobalInterval").value = g.intervalMinutes;
      if(adoptGuard) globalIntervalAppliedSeq = adoptGuard.seq;
    }
  }catch(e4){}
  if(forceAdopt && !globalTargetsSaving && !intervalEdited && !intervalStale){ globalIntervalDirty = false; }
  try{ updateGlobalSyncApplyButton(); }catch(e5){}
}
function renderGlobalStatus(){
  const g = currentGlobalStatus;
  const sw = document.getElementById("btnGlobalEnabled");
  const pill = document.getElementById("globalSyncPill");
  if(!g){
    document.getElementById("globalSummary").textContent = L("読込中");
    document.getElementById("ovGlobal").textContent = L("Global同期: 読込中");
    document.getElementById("ovGlobal").title = L("Global同期: 読込中");
    document.getElementById("globalEnabledState").textContent = L("読込中");
    try{ sw.setAttribute("aria-checked", "false"); sw.setAttribute("aria-label", L("自動同期の有効/無効")); sw.disabled = true; }catch(e1){}
    try{ pill.classList.remove("on"); }catch(e2){}
    return;
  }
  let sum = L("待機中");
  const st = g.syncState || "idle";
  sum = L("{state}（対象 {targets}）", {state:stateJa(st), targets:(g.targets || []).map(globalProviderLabel).join(L("・"))});
  if(st === "success") sum = L("成功: {tail}", {tail:(g.finalLine || g.tail || "").slice(-160)});
  if(st === "failed") sum = L("失敗: {tail}", {tail:(g.finalLine || g.tail || "").slice(-160)});
  if(st === "skipped") sum = L("見送りです。別の同期が実行中のため今回は見送りました。しばらくして今すぐ同期でやり直してください。");
  if(st === "waiting") sum = L("起動待ちです。子プロセスの起動を確認しています。");
  if(st === "unconfirmed") sum = L("未確認です。今回の実行結果がまだありません。");
  document.getElementById("globalSummary").textContent = sum;
  document.getElementById("ovGlobal").textContent = L("Global同期: {summary}", {summary:sum});
  document.getElementById("ovGlobal").title = L("Global同期: {summary}", {summary:sum});
  try{
    const en = document.getElementById("globalEnabledState");
    const known = g.taskEnabled === true || g.taskEnabled === false;
    if(g.taskEnabled === true) en.textContent = L("自動同期は有効です（次回も裏で実行）。");
    else if(g.taskEnabled === false) en.textContent = L("自動同期は休止中です（裏の実行なし）。再開は切替ボタンで有効化してください。");
    else en.textContent = L("自動同期の状態を取得できませんでした。");
    const state = g.taskEnabled === true ? L("有効") : g.taskEnabled === false ? L("休止中") : L("状態不明");
    sw.setAttribute("aria-checked", g.taskEnabled === true ? "true" : "false");
    sw.setAttribute("aria-label", L("自動同期: {state}", {state:state}));
    sw.disabled = !known || !!globalEnabledInflight;
    if(g.taskEnabled === true) pill.classList.add("on"); else pill.classList.remove("on");
  }catch(e3){}
}
let commonSyncStates = { project: null, global: null };
let commonSyncSource = "project";
let lastGlobalPlan = null;
let currentGlobalStatus = null;
let globalLogState = {loaded:false, tail:"", error:null};
let globalContentState = null;
let lastBackupDiff = null;
let lastGlobalBackupDiff = null;
let unifiedSyncActive = false;
let unifiedStateLock = false;
let unifiedFinalState = null;
let unifiedProgressState = {completed:0,total:2,text:"0/2 待機中",key:"0/2 待機中",vars:null,indeterminate:false,lang:"ja"};
let unifiedProjectRunId = null;
let unifiedGlobalRunId = null;
let completedUnifiedRunIds = {};
let unifiedObservedProjectRunId = null;
let unifiedObservedGlobalRunId = null;
let unifiedBaselineProjectRunId = null;
let unifiedBaselineGlobalRunId = null;
let globalApplyInflight = false;
let globalTargetsDirty = false;
let globalTargetsSaving = false;
let globalSavedTargets = (GLOBAL_DEFAULT_TARGETS || []).slice();
let globalEnabledInflight = false;
let globalIntervalDirty = false;
let globalTargetsEditGen = 0;
let globalIntervalEditGen = 0;
let globalReloadGuards = [];
let globalStatusRequestSeq = 0;
let globalTargetsAppliedSeq = 0;
let globalIntervalAppliedSeq = 0;
function globalReloadProtectsTargets(){
  for(let i=0;i<globalReloadGuards.length;i++){
    if(globalReloadGuards[i].targetsGen !== globalTargetsEditGen) return true;
  }
  return false;
}
function globalReloadProtectsInterval(){
  for(let i=0;i<globalReloadGuards.length;i++){
    if(globalReloadGuards[i].intervalGen !== globalIntervalEditGen) return true;
  }
  return false;
}
function globalProviderEntry(id){
  try{
    for(let i=0;i<GLOBAL_CATALOG.length;i++){ if(GLOBAL_CATALOG[i] && GLOBAL_CATALOG[i].id === id) return GLOBAL_CATALOG[i]; }
  }catch(e){}
  return null;
}
function globalProviderLabel(id){
  const e = globalProviderEntry(id);
  return e ? (e.label || id) : id;
}
function globalLogoInitials(label){
  const text = String(label == null ? "" : label);
  const words = text.split(/\s+/).filter(Boolean);
  if(!words.length) return "";
  return (words.length > 1 ? words[0].charAt(0) + words[1].charAt(0) : text.slice(0, 2)).toUpperCase();
}
function globalProviderLogo(e){
  const tile = document.createElement("span"); tile.className = "gs-logo";
  try{ tile.setAttribute("aria-hidden", "true"); }catch(e1){}
  const initials = globalLogoInitials(e && (e.label || e.id) || "");
  tile.textContent = initials;
  const key = String(e && e.id || "");
  let h = 7;
  for(let i=0;i<key.length;i++) h = (h * 31 + key.charCodeAt(i)) % 360;
  try{ if(tile.style && tile.style.setProperty) tile.style.setProperty("--gs-h", String(h)); }catch(e2){}
  const src = (typeof GLOBAL_LOGOS !== "undefined" && GLOBAL_LOGOS[e.id]) ? GLOBAL_LOGOS[e.id] : null;
  if(src){
    const img = document.createElement("img");
    img.alt = ""; img.src = src;
    img.onerror = function(){
      try{ tile.removeChild(img); }catch(e3){}
      tile.className = "gs-logo";
      tile.textContent = initials;
    };
    tile.textContent = "";
    tile.className = "gs-logo gs-has-img";
    tile.appendChild(img);
  }
  return tile;
}
function renderGlobalTargetChoices(){
  const box = document.getElementById("globalTargetsList");
  if(!box) return;
  box.innerHTML = "";
  (GLOBAL_CATALOG || []).forEach(function(e){
    if(!e || !e.id) return;
    const l = document.createElement("label"); l.className = "gs-provider";
    if(e.rel) l.title = e.rel;
    const c = document.createElement("input"); c.type = "checkbox"; c.className = "global-target"; c.value = e.id;
    c.checked = globalSavedTargets.indexOf(e.id) >= 0;
    l.appendChild(c);
    const card = document.createElement("span"); card.className = "gs-card";
    card.appendChild(globalProviderLogo(e));
    const meta = document.createElement("span"); meta.className = "gs-meta";
    const name = document.createElement("span"); name.className = "gs-name"; name.textContent = e.label || e.id;
    const path = document.createElement("span"); path.className = "gs-path"; path.textContent = e.rel || "";
    meta.appendChild(name); meta.appendChild(path);
    card.appendChild(meta);
    const check = document.createElement("span"); check.className = "gs-check"; check.textContent = "✓";
    try{ check.setAttribute("aria-hidden", "true"); }catch(e2){}
    card.appendChild(check);
    l.appendChild(card);
    box.appendChild(l);
  });
  renderGlobalTargetsUI();
}
function globalTargetCheckboxes(){
  try{ return document.querySelectorAll("#globalTargetsList input[type=checkbox]"); }catch(e){ return []; }
}
function globalTargetsDirtyNow(){
  return globalSelectedTargets().slice().sort().join("|") !== globalSavedTargets.slice().sort().join("|");
}
function globalTargetsLockedByGitHub(){
  return !(currentGlobalStatus && currentGlobalStatus.githubConfigured === true);
}
function renderGlobalTargetsUI(){
  const total = (GLOBAL_CATALOG || []).length;
  const selected = globalSelectedTargets().length;
  const ghLocked = globalTargetsLockedByGitHub();
  try{ document.getElementById("globalTargetsCount").textContent = L("{selected} / {total} 件を選択中", {selected:selected, total:total}); }catch(e1){}
  try{
    const cs = globalTargetCheckboxes();
    for(let i=0;i<cs.length;i++) cs[i].disabled = ghLocked;
  }catch(e0){}
  try{
    document.getElementById("btnGlobalTargetsAll").disabled = ghLocked;
    document.getElementById("btnGlobalTargetsNone").disabled = ghLocked;
  }catch(e4){}
  try{
    const d = document.getElementById("globalTargetsDirty");
    if(ghLocked){
      d.textContent = L("GitHubと連携すると対象を選択できます");
      d.classList.remove("on");
    } else {
      d.textContent = globalTargetsDirty ? L("未保存の変更があります") : "";
      if(globalTargetsDirty) d.classList.add("on"); else d.classList.remove("on");
    }
  }catch(e2){}
  try{ document.getElementById("btnGlobalTargets").disabled = ghLocked || !globalTargetsDirty || selected === 0 || globalTargetsSaving; }catch(e3){}
}
function globalTargetsSetAll(on){
  if(globalTargetsLockedByGitHub()) return;
  const cs = globalTargetCheckboxes();
  for(let i=0;i<cs.length;i++) cs[i].checked = !!on;
  markGlobalTargetsDirty();
}
function markGlobalTargetsDirty(){
  globalTargetsEditGen++;
  globalTargetsDirty = globalTargetsDirtyNow();
  lastGlobalPlan = null;
  renderGlobalTargetsUI();
  updateGlobalSyncApplyButton();
}
function globalSelectedTargets(){
  const tg = [];
  try{
    const cs = globalTargetCheckboxes();
    for(let i=0;i<cs.length;i++){ if(cs[i].checked) tg.push(cs[i].value); }
  }catch(e){}
  return tg;
}
function globalPlanIdForSelection(names){
  try{
    if(!lastGlobalPlan || !lastGlobalPlan.id) return null;
    const a = ((names || []).slice().sort().join("|"));
    const b = (((lastGlobalPlan.names) || []).slice().sort().join("|"));
    if(a !== "" && a === b) return lastGlobalPlan.id;
  }catch(e){}
  return null;
}
try{
  const box = document.getElementById("globalTargetsList");
  if(box) box.addEventListener("change", function(ev){
    const t = ev && ev.target;
    if(!t || t.type !== "checkbox") return;
    if(globalTargetsLockedByGitHub()){
      t.checked = globalSavedTargets.indexOf(t.value) >= 0;
      return;
    }
    markGlobalTargetsDirty();
  });
}catch(eT1){}
renderGlobalTargetChoices();
try{ document.getElementById("numGlobalInterval").addEventListener("input", function(){ globalIntervalEditGen++; globalIntervalDirty = true; }); }catch(eT3){}
async function refreshGlobal(deadline, forceAdopt){
  const guard = {force:!!forceAdopt, targetsGen:globalTargetsEditGen, intervalGen:globalIntervalEditGen, seq:++globalStatusRequestSeq};
  if(guard.force) globalReloadGuards.push(guard);
  try{
    let t = 8000;
    if(typeof deadline === "number"){ t = Math.min(8000, deadline - Date.now()); if(t <= 0) return; }
    const g = await api("/api/global-status", "GET", null, t);
    updateGlobalUI(g, guard);
  }catch(e){ globalLogState = {loaded:true, tail:"", error:e.message}; renderGlobalLog(); }
  finally{
    if(guard.force){
      const i = globalReloadGuards.indexOf(guard);
      if(i >= 0) globalReloadGuards.splice(i, 1);
    }
  }
}
function rulesLockedByGitHub(){
  return !(currentGlobalStatus && currentGlobalStatus.githubConfigured === true);
}
// --- common rule Markdown editor/preview (vendored CM6 + marked + DOMPurify) ---
// The vendor bundle is inlined at the head of this script. Without it the
// editor fails closed to the plain textarea and the preview shows a notice.
const RULE_PREVIEW_MAX = 262144;
const RULE_PREVIEW_DEBOUNCE = 300;
let ruleCmView = null;
let ruleCmEditable = null;
let ruleCmAria = null;
let ruleCmStateBuilder = null;
let rulePurifierInstance = null;
let rulePreviewTimer = 0;
let ruleMode = "split";
function ruleVendorReady(){
  try{ return !!(globalThis.ShirubeRuleLib && ShirubeRuleLib.marked && ShirubeRuleLib.DOMPurify && ShirubeRuleLib.cm); }catch(e){ return false; }
}
function rulePurifier(){
  if(!rulePurifierInstance){ rulePurifierInstance = ShirubeRuleLib.DOMPurify(window); }
  return rulePurifierInstance;
}
function ruleBuildPreviewHtml(text){
  const rawHtml = ShirubeRuleLib.marked.parse(text, {gfm:true, breaks:false, async:false});
  // External Markdown is untrusted: parse, then sanitize with a minimal
  // allowlist. No svg/math/form/iframe/object/embed/style/script/media, no
  // images, no event/style/id/name attributes, http(s)/mailto links only.
  return rulePurifier().sanitize(rawHtml, {
    ALLOWED_TAGS: ["p","br","strong","em","b","i","del","s","code","pre","blockquote","ul","ol","li","h1","h2","h3","h4","h5","h6","table","thead","tbody","tr","th","td","hr","a"],
    ALLOWED_ATTR: ["href"],
    ALLOW_DATA_ATTR: false,
    ALLOWED_URI_REGEXP: /^(?:https?|mailto):/i,
    FORBID_TAGS: ["svg","math","form","iframe","object","embed","style","script","img","input","button","textarea","select","video","audio","source","track","link","meta","base"],
    FORBID_ATTR: ["style","id","name","class","src","srcset"]
  });
}
function ruleAugmentPreview(root){
  // Post-sanitization augmentation: only fixed known nodes/attributes.
  try{
    const tables = root.querySelectorAll("table");
    for(let i=0;i<tables.length;i++){
      const t = tables[i];
      const tb = t.querySelector("tbody");
      if(tb){
        const rows = tb.querySelectorAll("tr");
        for(let j=0;j<rows.length;j++){
          const row = rows[j];
          // The row's own first cell only: a direct child, never a cell of a
          // nested table, and an existing TH keeps its content.
          const first = (row.children && row.children[0]) || null;
          if(!first) continue;
          if(first.tagName === "TH"){
            first.setAttribute("scope","row");
          }else if(first.tagName === "TD"){
            const th = document.createElement("th");
            th.setAttribute("scope","row");
            while(first.firstChild) th.appendChild(first.firstChild);
            row.replaceChild(th, first);
          }
        }
      }
      if(t.parentNode){
        const w = document.createElement("div");
        w.className = "rpreview-scroll";
        w.setAttribute("role","region");
        w.setAttribute("aria-label", L("テーブル"));
        w.setAttribute("tabindex","0");
        t.parentNode.insertBefore(w, t);
        w.appendChild(t);
      }
    }
    const links = root.querySelectorAll("a[href]");
    for(let k=0;k<links.length;k++){
      links[k].setAttribute("target","_blank");
      links[k].setAttribute("rel","noopener noreferrer");
    }
  }catch(e){}
}
function ruleRenderPreviewNow(){
  const out = document.getElementById("rulePreview");
  if(!out) return;
  const ta = document.getElementById("ruleText");
  const text = ta ? String(ta.value || "") : "";
  if(text.length > RULE_PREVIEW_MAX){
    out.textContent = L("本文が大きいためプレビューを省略しました。");
    return;
  }
  if(!ruleVendorReady()){
    out.textContent = L("プレビューを表示できません。ソースのみ編集できます。");
    return;
  }
  try{
    out.textContent = "";
    out.innerHTML = ruleBuildPreviewHtml(text);
    ruleAugmentPreview(out);
  }catch(e){
    out.textContent = L("プレビューの表示中にエラーが発生しました。");
  }
}
function ruleSchedulePreview(immediate){
  if(immediate){ ruleRenderPreviewNow(); return; }
  if(rulePreviewTimer) clearTimeout(rulePreviewTimer);
  rulePreviewTimer = setTimeout(function(){ rulePreviewTimer = 0; ruleRenderPreviewNow(); }, RULE_PREVIEW_DEBOUNCE);
}
function ruleModeSet(mode){
  if(["edit","split","preview"].indexOf(mode) < 0) return;
  // Without the CodeMirror editor the preview cannot replace the source pane:
  // normalize preview to split so the textarea fallback stays visible.
  if(mode === "preview" && !ruleEditorReady()) mode = "split";
  ruleMode = mode;
  const map = {edit:"btnRuleModeEdit", split:"btnRuleModeSplit", preview:"btnRuleModePreview"};
  for(const k in map){
    try{ document.getElementById(map[k]).setAttribute("aria-pressed", k === mode ? "true" : "false"); }catch(e){}
  }
  try{
    document.getElementById("ruleSrcPane").hidden = (mode === "preview");
    document.getElementById("rulePreviewPane").hidden = (mode === "edit");
    const grid = document.getElementById("rulesGrid");
    if(grid && grid.classList){
      if(mode === "split") grid.classList.remove("solo"); else grid.classList.add("solo");
    }
  }catch(e2){}
  ruleSchedulePreview(true);
}
function ruleEditorReady(){ return !!ruleCmView; }
function ruleCmEditableExt(locked){
  const cm = ShirubeRuleLib.cm;
  return [
    cm.EditorView.editable.of(!locked),
    cm.EditorState.readOnly.of(locked),
    cm.EditorState.changeFilter.of(function(){ return !locked; })
  ];
}
function ruleEditorSetReadOnly(locked){
  if(!ruleCmView || !ruleCmEditable) return;
  try{ ruleCmView.dispatch({effects: ruleCmEditable.reconfigure(ruleCmEditableExt(locked))}); }catch(e){}
}
function ruleEditorApplyText(){
  const ta = document.getElementById("ruleText");
  if(!ta) return;
  if(ruleCmView && ruleCmStateBuilder){
    try{
      // Authoritative sync (ruleLoad / kind clear): always replace the state.
      // The new document is authoritative even while locked, and the undo
      // history resets on every load/clear — including when the text is
      // unchanged or empty — so another file's (or an older) text can never
      // come back through Ctrl+Z. User editing stays filtered.
      ruleCmView.setState(ruleCmStateBuilder(String(ta.value || "")));
    }catch(e){}
  }
  ruleSchedulePreview(true);
}
function ruleEditorSetAria(){
  if(!ruleCmView || !ruleCmAria) return;
  try{ ruleCmView.dispatch({effects: ruleCmAria.reconfigure(ShirubeRuleLib.cm.EditorView.contentAttributes.of({"aria-label": L("ルール本文")}))}); }catch(e){}
}
function ruleEditorInit(){
  if(ruleCmView) return;
  const ta = document.getElementById("ruleText");
  if(!ta) return;
  // Fallback editor path: the textarea drives the (debounced) preview itself.
  try{ ta.addEventListener("input", function(){ ruleSchedulePreview(false); }); }catch(e0){}
  if(!ruleVendorReady()) return;
  try{
    const wrap = document.getElementById("ruleEditorWrap");
    if(!wrap) return;
    const cm = ShirubeRuleLib.cm;
    const hl = cm.HighlightStyle.define([
      {tag: cm.tags.heading, color:"#60a5fa", fontWeight:"bold"},
      {tag: cm.tags.monospace, color:"#fbbf24"},
      {tag: cm.tags.processingInstruction, color:"#8b949e"},
      {tag: cm.tags.contentSeparator, color:"#8b949e"},
      {tag: cm.tags.link, color:"#60a5fa"},
      {tag: cm.tags.url, color:"#8b949e"},
      {tag: cm.tags.quote, color:"#9a9a9a"}
    ]);
    // Table source rows: inset rules + alternating backgrounds per logical line,
    // so a row stays separated even when soft-wrapped. Rows come from the GFM
    // syntax tree, so tables without leading/trailing pipes are decorated too,
    // while pipe lookalikes inside fenced code are not.
    const rowDecos = function(view){
      const doc = view.state.doc;
      const decos = [];
      let tree = null;
      try{ tree = cm.ensureSyntaxTree(view.state, doc.length, 50) || cm.syntaxTree(view.state); }catch(e1){ tree = cm.syntaxTree(view.state); }
      if(tree){
        tree.iterate({
          enter: function(node){
            if(node.name !== "Table") return undefined;
            let idx = 0;
            let child = node.node.firstChild;
            while(child){
              if(child.name === "TableHeader" || child.name === "TableDelimiter" || child.name === "TableRow"){
                const fromLine = doc.lineAt(child.from).number;
                const toLine = doc.lineAt(child.to).number;
                for(let n=fromLine; n<=toLine; n++){
                  decos.push(cm.Decoration.line({class:"rule-md-row" + (idx % 2 === 1 ? " rule-md-row-alt" : "")}).range(doc.line(n).from));
                }
                idx++;
              }
              child = child.nextSibling;
            }
            return false;
          }
        });
      }
      return cm.Decoration.set(decos);
    };
    const tableRows = cm.ViewPlugin.fromClass(
      function TableRowDecos(view){ this.decos = rowDecos(view); this.update = function(v){ this.decos = rowDecos(v); }; },
      {decorations: function(v){ return v.decos; }}
    );
    // Dark theme so the caret, selection and focus ring stay visible on #0a0a0a.
    const cmTheme = cm.EditorView.theme({
      "&": {backgroundColor:"#0a0a0a", color:"#fff"},
      ".cm-content": {caretColor:"#fff"},
      ".cm-cursor, .cm-dropCursor": {borderLeftColor:"#fff", borderLeftWidth:"2px"},
      ".cm-selectionBackground, &.cm-focused .cm-selectionBackground, .cm-content ::selection": {backgroundColor:"#264f78"},
      "&.cm-focused": {outline:"1px solid #f5f5f5"}
    }, {dark:true});
    // The lock must hold for commands (undo/delete) too, so editable is paired
    // with a readOnly facet and a change filter that rejects doc mutations.
    ruleCmEditable = new cm.Compartment();
    ruleCmAria = new cm.Compartment();
    ruleCmStateBuilder = function(txt){
      return cm.EditorState.create({
        doc: String(txt || ""),
        extensions: [
          cm.lineNumbers(),
          cm.history(),
          cm.keymap.of(cm.defaultKeymap.concat(cm.historyKeymap, [cm.indentWithTab])),
          cm.EditorView.lineWrapping,
          cmTheme,
          cm.markdownLanguage,
          cm.syntaxHighlighting(hl),
          tableRows,
          ruleCmEditable.of(ruleCmEditableExt(rulesLockedByGitHub())),
          ruleCmAria.of(cm.EditorView.contentAttributes.of({"aria-label": L("ルール本文")})),
          cm.EditorView.updateListener.of(function(v){
            if(v.docChanged){
              ta.value = v.state.doc.toString();
              ruleSchedulePreview(false);
            }
          })
        ]
      });
    };
    const state = ruleCmStateBuilder(ta.value);
    ruleCmView = new cm.EditorView({state: state, parent: wrap});
    ta.classList.add("cm-off");
    wrap.classList.add("cm-on");
  }catch(e){ ruleCmView = null; }
}
let ruleLoaded = null;
let ruleBusy = false;
function renderRulesLock(){
  const locked = rulesLockedByGitHub();
  try{ const g = document.getElementById("rulesGate"); if(g) g.hidden = !locked; }catch(e0){}
  try{ const t = document.getElementById("ruleText"); if(t) t.disabled = locked; }catch(e1){}
  try{ document.getElementById("selRuleKind").disabled = locked || ruleBusy; }catch(e2){}
  try{ document.getElementById("btnRuleLoad").disabled = locked || ruleBusy; }catch(e3){}
  try{ document.getElementById("btnRuleSave").disabled = locked || ruleBusy || !ruleLoaded; }catch(e4){}
  try{ ruleEditorSetReadOnly(locked); }catch(e5){}
}
function ruleKind(){
  try{ return document.getElementById("selRuleKind").value === "global" ? "global" : "project"; }catch(e){ return "project"; }
}
function renderRuleMeta(r){
  const p = document.getElementById("ruleMeta");
  if(!p) return;
  const origin = (r && r.repo) ? (" — " + String(r.repo) + "@" + String(r.branch || "")) : "";
  p.textContent = L("取得元: {path}（SHA {sha}）", {path:(r && r.path ? r.path : ""), sha:(r && r.sha ? String(r.sha).slice(0,12) : "-")}) + origin;
}
async function ruleLoad(){
  if(ruleBusy) return;
  if(rulesLockedByGitHub()){ renderRulesLock(); setMsg("msgRule", L("GitHub連携が未設定のため編集できません。"), false); return; }
  ruleBusy = true;
  renderRulesLock();
  setMsg("msgRule", L("読込中"), true);
  try{
    const kind = ruleKind();
    const r = await api("/api/github-rule-get", "POST", {kind:kind}, 30000);
    ruleLoaded = {kind:kind, sha:String(r.sha || ""), repo:String(r.repo || ""), branch:String(r.branch || ""), path:String(r.path || "")};
    document.getElementById("ruleText").value = String(r.text || "");
    ruleEditorApplyText();
    renderRuleMeta(r);
    if(r.redacted) setMsg("msgRule", L("伏字表示中の内容はそのまま保存できません。再取得しても伏字のままの場合、そのまま保存しないでください。"), false);
    else setMsg("msgRule", L("取得しました。"), true);
  }catch(e){ ruleLoaded = null; setMsg("msgRule", e.message, false); }
  finally{ ruleBusy = false; renderRulesLock(); }
}
async function ruleSave(){
  if(ruleBusy) return;
  if(rulesLockedByGitHub()){ renderRulesLock(); setMsg("msgRule", L("GitHub連携が未設定のため保存できません。"), false); return; }
  if(!ruleLoaded){ setMsg("msgRule", L("先に取得してください。"), false); return; }
  const targetKind = ruleLoaded.kind;
  const targetSha = ruleLoaded.sha;
  const targetRepo = ruleLoaded.repo;
  const targetBranch = ruleLoaded.branch;
  const targetPath = ruleLoaded.path;
  const targetText = document.getElementById("ruleText").value;
  if(ruleKind() !== targetKind){ ruleLoaded = null; renderRulesLock(); setMsg("msgRule", L("種別が変わりました。先に取得してください。"), false); return; }
  const okGo = await showConfirm(L("保存の確認"), L("{kind} をGitHubへ保存します。よろしいですか。", {kind:(targetKind === "global" ? "global.md" : "project.md")}), L("保存する"), L("やめる"));
  if(!okGo) return;
  if(ruleBusy){ renderRulesLock(); setMsg("msgRule", L("読込中です。完了してから保存してください。"), false); return; }
  if(rulesLockedByGitHub()){ renderRulesLock(); setMsg("msgRule", L("GitHub連携が未設定のため保存できません。"), false); return; }
  if(!ruleLoaded || ruleLoaded.kind !== targetKind || ruleLoaded.sha !== targetSha || ruleLoaded.repo !== targetRepo || ruleLoaded.branch !== targetBranch || ruleLoaded.path !== targetPath){
    renderRulesLock();
    setMsg("msgRule", L("内容が更新されました。取得し直してから保存してください。"), false);
    return;
  }
  ruleBusy = true;
  renderRulesLock();
  setMsg("msgRule", L("保存しています…"), true);
  try{
    const r = await api("/api/github-rule-save", "POST", {kind:targetKind, text:targetText, sha:targetSha, repo:targetRepo, branch:targetBranch, path:targetPath}, 30000);
    ruleLoaded = {kind:targetKind, sha:String(r.sha || ""), repo:String(r.repo || targetRepo), branch:String(r.branch || targetBranch), path:String(r.path || targetPath)};
    renderRuleMeta(r);
    setMsg("msgRule", L("保存しました。"), true);
  }catch(e){ setMsg("msgRule", e.message, false); }
  finally{ ruleBusy = false; renderRulesLock(); }
}
try{ document.getElementById("btnRuleLoad").onclick = function(){ ruleLoad(); }; }catch(eL){}
try{ document.getElementById("btnRuleSave").onclick = function(){ ruleSave(); }; }catch(eS){}
try{
  document.getElementById("selRuleKind").onchange = function(){
    ruleLoaded = null;
    document.getElementById("ruleText").value = "";
    document.getElementById("ruleMeta").textContent = "";
    ruleEditorApplyText();
    renderRulesLock();
  };
}catch(eK){}
try{ document.getElementById("btnRuleModeEdit").onclick = function(){ ruleModeSet("edit"); }; }catch(eM1){}
try{ document.getElementById("btnRuleModeSplit").onclick = function(){ ruleModeSet("split"); }; }catch(eM2){}
try{ document.getElementById("btnRuleModePreview").onclick = function(){ ruleModeSet("preview"); }; }catch(eM3){}
renderRulesLock();
ruleModeSet("split");
ruleEditorInit();
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
    const guard = {force:false, targetsGen:globalTargetsEditGen, intervalGen:globalIntervalEditGen, seq:++globalStatusRequestSeq};
    let s = null;
    try{ s = await api("/api/global-status?runId="+encodeURIComponent(syncId), "GET", null, to); }catch(e){ continue; }
    try{ updateGlobalUI(s, guard); }catch(e){}
    if(!s || !s.syncId || !syncId) continue;
    if(s.syncId !== syncId) continue;
    if(s.syncState === "success" || s.syncState === "failed" || s.syncState === "skipped") return s.syncState;
  }
  return "unconfirmed";
}
async function afterGlobalSyncNotify(r){
  let st = "unconfirmed";
  if(r && r.sync === "started"){
    const dl = Date.now() + 60000;
    await refreshGlobal(dl);
    st = await pollGlobalUntilDone(r.syncId, 120, 500, dl);
    if(Date.now() < dl) await refreshGlobal(dl);
    if(st === "success") await showNotify(L("Global同期が成功しました"), L("Global同期が成功しました。ログを確認してください。"));
    else if(st === "failed") await showNotify(L("Global同期が失敗しました"), L("Global同期が失敗しました。ログを確認してください。"));
    else if(st === "skipped") await showNotify(L("Global同期は見送りです"), L("Global同期は見送られました(別の同期が実行中)。しばらくしてやり直してください。"));
    else await showNotify(L("Global同期は未確認です"), L("Global同期は未確認です(起動待ち/継続中)。しばらくして状態を更新してください。"));
  } else {
    await refreshGlobal();
    await showNotify(L("Global同期は未確認です"), L("Global同期状態は未確認です。ログを確認してください。"));
  }
  return st;
}
function setUnifiedProgress(completed, total, text, indeterminate){
  const recipe = localizedText[currentLang].get(text || "");
  unifiedProgressState = {completed:completed,total:total || 2,text:text || "",key:recipe ? recipe.key : null,vars:recipe ? recipe.vars : null,indeterminate:!!indeterminate,lang:currentLang};
  renderUnifiedProgress();
}
function renderUnifiedProgress(){
  try{
    const state = unifiedProgressState;
    let text = state.text || "";
    if(state.key){
      const vars = state.vars ? Object.assign({}, state.vars) : null;
      if(vars && Object.prototype.hasOwnProperty.call(vars, "state")){
        const states = ["実行中","起動待ち","成功","失敗","見送り","未確認","待機中"];
        for(let i=0;i<states.length;i++) if(String(vars.state) === ((I18N[state.lang] && I18N[state.lang][states[i]]) || states[i])){ vars.state = L(states[i]); break; }
      }
      text = L(state.key, vars);
    }
    const p = document.getElementById("syncProgress");
    const t = document.getElementById("syncProgressText");
    if(p){
      if(state.indeterminate){ p.removeAttribute("value"); }
      else { p.value = state.completed; }
      p.max = state.total || 2;
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
  h.textContent = L("取得元: {commit} 作成: {at}", {commit:((plan.sourceCommit||"").slice(0,12) || "-"), at:(plan.createdAt||"")});
  pa.appendChild(h);
  (plan.entries||[]).forEach(function(en){
    if(en.result === "failed"){ const t = document.createElement("p"); t.className = "err"; t.textContent = L("失敗: {target}：{error}", {target:globalProviderLabel(en.target), error:(en.error||"")}); pa.appendChild(t); return; }
    const d = diffLinesLocal(en.currentText||"", en.generatedText||"");
    const t = document.createElement("p");
    t.className = d.same ? "ok" : "warn";
    t.textContent = (d.same ? L("変更なし: {target}", {target:globalProviderLabel(en.target)}) : L("変更あり: {target}", {target:globalProviderLabel(en.target)}));
    pa.appendChild(t);
    if(!d.same){
      const pre = document.createElement("pre");
      pre.appendChild(renderDiffFrag(d.lines));
      if(d.truncated){ const n = document.createElement("span"); n.className="diff-note"; n.setAttribute("data-i18n", "(省略)"); n.textContent=L("(省略)"); pre.appendChild(n); }
      pa.appendChild(pre);
    }
  });
  try{
    const ph = document.createElement("p"); ph.className = "muted";
    ph.textContent = L("この内容でよければ「プレビューを適用」で反映します（反映前に再照合し、変化があれば拒否）。");
    pa.appendChild(ph);
  }catch(e2){}
}
document.getElementById("btnGlobalReload").onclick = function(){ return refreshGlobal(undefined, true); };
document.getElementById("btnGlobalSync").onclick = async function(){
  const b = document.getElementById("btnGlobalSync");
  const originallyDisabled = b.disabled;
  const names = globalSelectedTargets();
  const pid = globalPlanIdForSelection(names);
  if(!pid){ b.disabled = true; return; }
  if(unifiedSyncActive){ await showNotify(L("同期中"), L("統合同期の実行中はプレビュー適用できません。")); return; }
  if(globalApplyInflight){ await showNotify(L("同期中"), L("すでにプレビュー適用中です。")); return; }
  globalApplyInflight = true;
  b.disabled = true;
  try{
    const okGo = await showConfirm(L("Global同期の確認"), L("確認済みプランで反映します（反映前に再照合し、変化があれば拒否）。よろしいですか。"), L("適用する"), L("やめる"));
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
  }catch(e){ try{ await showNotify(L("Global同期できませんでした"), e.message); }catch(e2){} try{ lastGlobalPlan = null; }catch(e3){} try{ updateGlobalSyncApplyButton(); }catch(e4){} }
  finally{ globalApplyInflight = false; try{ b.disabled = originallyDisabled ? true : globalSyncApplyEnabled() ? false : true; }catch(e3){} try{ safeFocus(b); }catch(e4){} }
};
document.getElementById("btnGlobalPreview").onclick = async function(){
  const b = document.getElementById("btnGlobalPreview"); b.disabled = true;
  const pa = document.getElementById("globalPlanArea"); pa.innerHTML = "<p class='muted'>"+L("プラン作成中")+"</p>";
  const sel = globalSelectedTargets();
  try{
    const r = await api("/api/global-preview-start","POST",{targetNames:sel});
    const dl = Date.now() + 90000;
    let plan = null;
    let planWait = 150;
    while(true){
      await new Promise(function(rs){ setTimeout(rs, planWait); });
      planWait = 400;
      if(Date.now() >= dl) break;
      const to = Math.min(8000, dl - Date.now());
      if(to <= 0) break;
      let g = null;
      try{ g = await api("/api/global-plan?id="+encodeURIComponent(r.planId),"GET",null,to); }catch(e){ continue; }
      if(g && g.status === "ready"){ plan = g; break; }
    }
    if(!plan){ pa.innerHTML = "<p class='warn'>"+L("未確認です。しばらくして「反映前プレビュー」で再取得してください。")+"</p>"; return; }
    renderGlobalPlan(plan);
    try{ lastGlobalPlan = {id: r.planId, names: sel.slice()}; }catch(e){ lastGlobalPlan = null; }
    try{ updateGlobalSyncApplyButton(); }catch(e2){}
    try{
      const ph = document.createElement("p"); ph.className = "muted";
      ph.textContent = L("プランID: {id}（選択を変えず「プレビューを適用」でこのプランを適用）", {id:String(r.planId).slice(0, 12)});
      pa.appendChild(ph);
    }catch(e2){}
  }catch(e){ pa.innerHTML = "<p class='err'>"+esc(e.message)+"</p>"; try{ lastGlobalPlan = null; }catch(e2){} try{ updateGlobalSyncApplyButton(); }catch(e3){} }
  finally{ try{ b.disabled = false; }catch(e3){} try{ safeFocus(b); }catch(e4){} }
};
document.getElementById("btnGlobalContent").onclick = async function(){
  globalContentState = {loading:true}; renderGlobalContent();
  try{
    globalContentState = await api("/api/global-content","GET");
    renderGlobalContent();
  }catch(e){ globalContentState = {error:e.message}; renderGlobalContent(); }
};
function renderGlobalContent(){
  const pre = document.getElementById("globalContentPre");
  if(!pre) return;
  if(globalContentState === null){ pre.textContent = L("まだ表示していません。「内容を表示」で確認できます。"); return; }
  if(globalContentState.loading){ pre.textContent = L("取得中"); return; }
  if(globalContentState.error){ pre.textContent = L("取得失敗: ") + globalContentState.error; return; }
  const g = globalContentState;
  let h = L("配置元: {base}", {base:(g.homeBase || "-")}) + "\n";
  (g.files||[]).forEach(function(f){
    h += "--- " + f.target + " (" + f.path + ") ---\n";
    if(!f.exists){ h += L("(ファイルなし)") + "\n"; return; }
    h += (f.head || "") + "\n";
  });
  pre.textContent = h;
}
document.getElementById("btnGlobalLogs").onclick = async function(){
  globalLogState = {loaded:false, tail:"", error:null}; renderGlobalLog();
  try{
    const g = await api("/api/global-logs","GET");
    globalLogState = {loaded:true, tail:g.tail || "", error:null}; renderGlobalLog();
  }catch(e){ globalLogState = {loaded:true, tail:"", error:e.message}; renderGlobalLog(); }
};
document.getElementById("btnGlobalTargetsAll").onclick = function(){ globalTargetsSetAll(true); };
document.getElementById("btnGlobalTargetsNone").onclick = function(){ globalTargetsSetAll(false); };
document.getElementById("btnGlobalTargets").onclick = async function(){
  const b = document.getElementById("btnGlobalTargets");
  if(globalTargetsSaving) return;
  if(globalTargetsLockedByGitHub()) return;
  const tg = globalSelectedTargets();
  if(tg.length === 0){ setMsg("msgGlobalTargets", L("対象は一覧から1つ以上選んでください。"), false); return; }
  if(!globalTargetsDirty) return;
  globalTargetsSaving = true; b.disabled = true;
  const confirmed = tg.slice();
  try{
    const names = confirmed.map(globalProviderLabel);
    const okGo = await showConfirm(L("対象の変更"), L("配る対象を「{targets}」に変更します。よろしいですか。", {targets:names.join(L("・"))}), L("変更する"), L("やめる"));
    // A status poll can close the GitHub lock while the dialog is open.
    if(!okGo || globalTargetsLockedByGitHub()){ return; }
    const tr = await api("/api/global-targets-set","POST",{targets:confirmed, confirm:true});
    // The successful POST is newer than every status GET already in flight.
    globalTargetsAppliedSeq = ++globalStatusRequestSeq;
    globalSavedTargets = confirmed.slice();
    globalTargetsDirty = globalTargetsDirtyNow();
    const gh0 = (tr && tr.github) ? tr.github : null;
    let ghNote = "";
    let ghHardFail = false;
    if(gh0){
      if(gh0.ok){
        const added = [];
        (gh0.files || []).forEach(function(f){ (f.added || []).forEach(function(t){ added.push(t); }); });
        ghNote = added.length ? L("GitHub: 対象を追記しました（{targets}）。", {targets: added.join(L("・"))}) : L("GitHub: 追記は不要でした。");
      }
      else if(gh0.skipped){ ghNote = L("GitHub: {reason}", {reason: gh0.error || L("連携が未設定です。")}); }
      else { ghHardFail = true; ghNote = L("GitHubへの追記に失敗しました：{reason}", {reason: gh0.error || ""}); }
    }
    setMsg("msgGlobalTargets", L("対象を保存しました。") + (ghNote ? " " + ghNote : ""), !ghHardFail);
    renderGlobalTargetsUI();
    await refreshGlobal();
  }catch(e){ setMsg("msgGlobalTargets", e.message, false); }
  finally{ globalTargetsSaving = false; try{ renderGlobalTargetsUI(); }catch(e2){} try{ safeFocus(b); }catch(e3){} }
};
document.getElementById("btnGlobalIntervalGet").onclick = async function(){
  try{
    const r = await api("/api/global-interval-get","GET");
    document.getElementById("numGlobalInterval").value = r.minutes;
    setMsg("msgGlobalInterval", L("現在の間隔：{n}分（Global）", {n:r.minutes}), true);
  }catch(e){ setMsg("msgGlobalInterval", e.message, false); }
};
document.getElementById("btnGlobalIntervalSet").onclick = async function(){
  const input = document.getElementById("numGlobalInterval");
  const m = Number(input.value);
  if(!Number.isInteger(m) || m < 5 || m > 1440){
    setMsg("msgGlobalInterval", L("間隔は5〜1440分の整数で指定してください。"), false);
    try{ input.focus(); }catch(e){}
    return;
  }
  const okGo = await showConfirm(L("間隔の変更"), L("Global同期の間隔を{n}分に変更します（Projectは不変）。よろしいですか。", {n:m}), L("変更する"), L("やめる"));
  if(!okGo) return;
  try{
    await api("/api/global-interval-set","POST",{minutes:m, confirm:true});
    globalIntervalDirty = false;
    setMsg("msgGlobalInterval", L("間隔を変更しました：{n}分", {n:m}), true);
  }catch(e){ setMsg("msgGlobalInterval", e.message, false); }
};
document.getElementById("btnGlobalEnabled").onclick = async function(){
  const b = document.getElementById("btnGlobalEnabled");
  if(globalEnabledInflight) return;
  if(!currentGlobalStatus || (currentGlobalStatus.taskEnabled !== true && currentGlobalStatus.taskEnabled !== false)) return;
  globalEnabledInflight = true; b.disabled = true;
  try{
    const cur = await api("/api/global-enabled-get","GET");
    const next = !(cur.enabled);
    const okGo = await showConfirm(L("有効/無効の切替"), next ? L("Global自動同期を有効にします。よろしいですか。") : L("Global自動同期を休止します（裏の実行なし）。よろしいですか。"), L("切り替える"), L("やめる"));
    if(!okGo){ return; }
    await api("/api/global-enabled-set","POST",{enabled:next});
    setMsg("msgGlobalInterval", next ? L("有効にしました。") : L("休止しました。"), true);
    await refreshGlobal();
  }catch(e){ setMsg("msgGlobalInterval", e.message, false); }
  finally{ globalEnabledInflight = false; try{ renderGlobalStatus(); }catch(e2){} try{ safeFocus(b); }catch(e3){} }
};
var globalRestoreConfirms = {};
async function globalBackupDiff(id){
  lastGlobalBackupDiff = null;
  const da = document.getElementById("globalBackupDiffArea"); da.innerHTML = "<p class='muted'>"+L("差分取得中")+"</p>";
  try{
    const d = await api("/api/global-backup-diff","POST",{backupId:id});
    try{ if(d && d.confirmId) globalRestoreConfirms[id] = d.confirmId; }catch(e2){}
    lastGlobalBackupDiff = {id:id,data:d};
    renderGlobalBackupDiff(d);
    return d;
  }catch(err){ da.innerHTML = "<p class='err'>"+esc(err.message)+"</p>"; throw err; }
}
function renderGlobalBackupDiff(d){
  const da = document.getElementById("globalBackupDiffArea");
  da.innerHTML = "";
  const h = document.createElement("p"); h.className = "muted";
  h.textContent = L("対象: {id}", {id:(d.id || "")}) + (d.same ? L("（差分なし）") : L("（差分あり）")) + (d.truncated ? L("（一部省略）") : "");
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
}
async function globalBackupRestore(id){
  const cid = globalRestoreConfirms[id];
  if(!cid || !/^[0-9a-f]{32}$/.test(cid)){
    setMsg("msgGlobalBackup", L("先に差分確認をしてください。確認直後の復元のみ受け付けます。"), false);
    return;
  }
  const okGo = await showConfirm(L("Global復元の確認"), L("「{id}」を復元します。復元前にGlobal自動同期を休止し、復元後も休止のまま残ります（再開は有効化）。よろしいですか。", {id:id}), L("復元する"), L("やめる"));
  if(!okGo) return;
  try{
    const r = await api("/api/global-restore","POST",{backupId:id, confirm:true, confirmId:cid});
    try{ delete globalRestoreConfirms[id]; }catch(e2){}
    setMsg("msgGlobalBackup", L("復元しました。休止中のため再開は有効化してください。"), true);
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
      const td2 = document.createElement("td"); td2.textContent = (e.targets || []).map(globalProviderLabel).join(L("・"));
      const td3 = document.createElement("td");
      const acts = document.createElement("div"); acts.className = "acts";
      const bd = document.createElement("button"); bd.textContent = L("差分");
      bd.onclick = function(){ globalBackupDiff(e.id); };
      const br = document.createElement("button"); br.textContent = L("復元"); br.className = "danger";
      br.onclick = function(){ globalBackupRestore(e.id); };
      acts.appendChild(bd); acts.appendChild(br); td3.appendChild(acts);
      tr.appendChild(td0); tr.appendChild(td1); tr.appendChild(td2); tr.appendChild(td3);
      tb.appendChild(tr);
    });
    try{ applySearchFilter(); }catch(e2){}
  }catch(e){ setMsg("msgGlobalBackup", e.message, false); }
}
document.getElementById("btnGlobalBackups").onclick = function(){ loadGlobalBackups(); };
initLanguage();
showHash();refresh();refreshGlobal();
/* --- GitHub integration (topbar dialog) --------------------------------- */
const ghState = {open:false, busy:false, restore:null, tokenSource:""};
function ghEl(id){ return document.getElementById(id); }
function ghSetStatus(msg, kind){
  const s = ghEl("ghStatus");
  if(!s) return;
  s.textContent = msg || "";
  s.className = "ghstatus" + (kind ? " " + kind : "");
}
function ghNormalizePath(v){
  let p = String(v || "").trim().replace(/\\/g, "/").replace(/\/{2,}/g, "/").replace(/^\/+/, "");
  if(p && !p.endsWith("/")) p += "/";
  return p;
}
function ghPathError(v){
  const p = String(v || "").trim();
  if(/(^|\/)\.\.(\/|$)/.test(p)) return L("「..」は使えません。フォルダ名だけを入力してください。");
  if(/[<>:"|?*\x00-\x1f]/.test(p)) return L('使えない文字が含まれています(< > : " | ? * など)。');
  return "";
}
function ghNormalizeRepo(){
  const r = ghEl("ghRepo");
  if(!r) return;
  const m = r.value.trim().match(/^(?:https?:\/\/)?(?:www\.)?github\.com\/([^\/\s]+)\/([^\/\s#?]+)/i);
  if(m) r.value = m[1] + "/" + m[2].replace(/\.git$/i, "");
}
function ghFolderMode(){
  const r = document.querySelector('input[name="ghFolder"]:checked');
  return r ? r.value : "rules";
}
function ghFolderFromUI(){
  const mode = ghFolderMode();
  if(mode === "__custom"){
    const p = ghNormalizePath(ghEl("ghFolderCustom").value).replace(/\/+$/g, "");
    return p || "rules";
  }
  return mode;
}
function ghRenderPreview(){
  const mode = ghFolderMode();
  const wrap = ghEl("ghCustomWrap");
  if(wrap) wrap.hidden = (mode !== "__custom");
  const r = (ghEl("ghRepo") && ghEl("ghRepo").value.trim()) || L("リポジトリ名");
  const b = (ghEl("ghBranch") && ghEl("ghBranch").value.trim()) || "main";
  const customNorm = ghNormalizePath(ghEl("ghFolderCustom").value);
  const folderRaw = (mode === "__custom") ? (customNorm === "./" ? "" : (customNorm || "rules/")) : (mode === "." ? "" : "rules/");
  const parts = folderRaw.split("/").filter(Boolean);
  const folderText = parts.join("/");
  const sum = ghEl("ghSummaryText");
  if(sum){
    sum.textContent = parts.length
      ? L("「{repo}」の「{branch}」ブランチにある「{folder}」フォルダの中に、ルールが1つずつファイルとして保存されます。", {repo:r, branch:b, folder:folderText})
      : L("「{repo}」の「{branch}」ブランチの一番上に、ルールが1つずつファイルとして保存されます。", {repo:r, branch:b});
  }
  const tree = ghEl("ghTree");
  if(!tree) return;
  while(tree.firstChild) tree.removeChild(tree.firstChild);
  function row(depth, icon, label, target){
    const el = document.createElement("div");
    el.className = "row" + (target ? " target" : "");
    el.style.paddingLeft = (depth * 20) + "px";
    el.textContent = (depth ? "└ " : "") + icon + " " + label;
    if(target){
      const note = document.createElement("span");
      note.className = "note";
      note.textContent = L("← ここに保存されます");
      el.appendChild(note);
    }
    tree.appendChild(el);
  }
  const repoLeaf = r.split("/").pop() || r;
  row(0, "\uD83D\uDCC1", repoLeaf, parts.length === 0);
  parts.forEach(function(p, i){ row(i + 1, "\uD83D\uDCC1", p, i === parts.length - 1); });
  row(parts.length + 1, "\uD83D\uDCC4", "global.md / project.md", false);
}
function ghApplyFolder(path){
  const v = String(path || "rules").replace(/\\/g, "/").replace(/\/+$/g, "");
  const custom = ghEl("ghFolderCustom");
  let hit = null;
  document.querySelectorAll('input[name="ghFolder"]').forEach(function(x){ if(x.value === v) hit = x; });
  if(hit){
    hit.checked = true;
    custom.value = "";
  } else {
    document.querySelector('input[name="ghFolder"][value="__custom"]').checked = true;
    custom.value = (v === ".") ? "" : ghNormalizePath(v);
  }
  ghRenderPreview();
}
function ghSetTokenVisible(show){
  const t = ghEl("ghToken"), b = ghEl("ghEye"), on = ghEl("ghEyeOn"), off = ghEl("ghEyeOff");
  if(!t || !b) return;
  t.type = show ? "text" : "password";
  if(on){ on.toggleAttribute("hidden", !!show); on.hidden = !!show; }
  if(off){ off.toggleAttribute("hidden", !show); off.hidden = !show; }
  b.setAttribute("aria-pressed", show ? "true" : "false");
  b.setAttribute("aria-label", L(show ? "トークンを隠す" : "トークンを表示"));
  b.title = L(show ? "隠す" : "表示");
}
function ghResetValidation(){
  ["ghToken","ghRepo","ghBranch","ghFolderCustom"].forEach(function(id){
    const el = ghEl(id);
    if(el) el.removeAttribute("aria-invalid");
  });
  ["ghTokenHint","ghRepoHint","ghBranchHint","ghPathHint"].forEach(function(id){
    const el = ghEl(id);
    if(el && el.classList) el.classList.remove("error");
  });
  if(ghEl("ghTokenHint")) ghEl("ghTokenHint").textContent = L("必要な権限: Contents (Read and write)。Fine-grained トークンを推奨します。");
  if(ghEl("ghRepoHint")) ghEl("ghRepoHint").textContent = L("GitHubのURL(https://github.com/…)をそのまま貼り付けてもOKです。");
  if(ghEl("ghBranchHint")) ghEl("ghBranchHint").textContent = L("迷ったら「main」のままで大丈夫です。");
  if(ghEl("ghPathHint")) ghEl("ghPathHint").textContent = L("「/」で区切ると、フォルダの中のフォルダも指定できます。まだ無いフォルダは自動で作られます。");
}
function ghValidate(){
  ghNormalizeRepo();
  ghRenderPreview();
  let ok = true;
  const tokenEl = ghEl("ghToken"), repoEl = ghEl("ghRepo"), branchEl = ghEl("ghBranch"), pathEl = ghEl("ghFolderCustom");
  const t = tokenEl.value.trim();
  const tOk = (t === "") ? true : /^(ghp_|github_pat_|gho_|ghu_|ghs_)[A-Za-z0-9_]{20,}$/.test(t);
  tokenEl.setAttribute("aria-invalid", String(!tOk));
  ghEl("ghTokenHint").classList.toggle("error", !tOk);
  ghEl("ghTokenHint").textContent = L(tOk
    ? "必要な権限: Contents (Read and write)。Fine-grained トークンを推奨します。"
    : "トークンの形式が正しくありません (ghp_ または github_pat_ で始まる文字列)。");
  ok = ok && tOk;

  const rOk = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repoEl.value.trim());
  repoEl.setAttribute("aria-invalid", String(!rOk));
  ghEl("ghRepoHint").classList.toggle("error", !rOk);
  ghEl("ghRepoHint").textContent = L(rOk
    ? "GitHubのURL(https://github.com/…)をそのまま貼り付けてもOKです。"
    : "読み取れませんでした。「ユーザー名/リポジトリ名」(例: Fizor-drm/Shirube)の形か、GitHubのURLを入力してください。");
  ok = ok && rOk;

  // 空欄は main 扱い(placeholder が main)。
  branchEl.removeAttribute("aria-invalid");
  ghEl("ghBranchHint").classList.remove("error");
  ghEl("ghBranchHint").textContent = L("迷ったら「main」のままで大丈夫です。");

  const custom = ghFolderMode() === "__custom";
  const customNorm = ghNormalizePath(pathEl.value).replace(/\/+$/g, "");
  const pe = custom ? (customNorm ? ghPathError(pathEl.value) : L("フォルダの場所を入力してください。")) : "";
  pathEl.setAttribute("aria-invalid", String(!!pe));
  ghEl("ghPathHint").classList.toggle("error", !!pe);
  ghEl("ghPathHint").textContent = pe || L("「/」で区切ると、フォルダの中のフォルダも指定できます。まだ無いフォルダは自動で作られます。");
  ok = ok && !pe;
  return ok;
}
async function ghOpen(){
  if(ghState.open) return;
  ghState.open = true;
  ghState.restore = document.activeElement;
  ghEl("ghToken").value = "";
  ghSetTokenVisible(false);
  ghEl("ghRepo").value = "";
  ghEl("ghBranch").value = "";
  ghApplyFolder("rules");
  ghResetValidation();
  ghSetStatus("");
  ghEl("ghOvl").hidden = false;
  try{
    const g = await api("/api/github-settings", "GET", null, 15000);
    ghState.tokenSource = g.tokenSource || "";
    ghEl("ghRepo").value = g.repo || "";
    ghEl("ghBranch").value = g.repo ? (g.branch || "") : "";
    ghApplyFolder(g.rulesPath || "rules");
  }catch(e){ ghSetStatus(e.message, "err"); }
  try{ ghEl("ghToken").focus(); }catch(e){}
}
function ghClose(){
  if(!ghState.open) return;
  ghState.open = false;
  ghEl("ghOvl").hidden = true;
  ghEl("ghToken").value = "";
  ghSetTokenVisible(false);
  const r = ghState.restore;
  ghState.restore = null;
  try{ if(r && r.focus) r.focus(); }catch(e){}
}
async function ghTest(){
  if(ghState.busy) return;
  if(!ghValidate()){ ghSetStatus(L("入力内容を確認してください。"), "err"); return; }
  const repo = ghEl("ghRepo").value.trim();
  const branch = ghEl("ghBranch").value.trim() || "main";
  ghState.busy = true;
  ghEl("ghTest").disabled = true;
  ghEl("ghSave").disabled = true;
  ghSetStatus(L("接続を確認しています…"));
  try{
    const r = await api("/api/github-test", "POST", {repo:repo, branch:branch, token:ghEl("ghToken").value.trim()}, 25000);
    const sha = String(r.sha || "").slice(0, 7);
    ghSetStatus(L("接続できました。") + " " + String(r.repo || repo) + "@" + String(r.branch || branch) + (sha ? " (" + sha + ")" : ""), "ok");
  }catch(e){ ghSetStatus(e.message, "err"); }
  finally{
    ghState.busy = false;
    ghEl("ghTest").disabled = false;
    ghEl("ghSave").disabled = false;
  }
}
async function ghSave(ev){
  if(ev && ev.preventDefault) ev.preventDefault();
  if(ghState.busy) return;
  if(!ghValidate()){ ghSetStatus(L("入力内容を確認してください。"), "err"); return; }
  const repo = ghEl("ghRepo").value.trim();
  const branch = ghEl("ghBranch").value.trim() || "main";
  const folder = ghFolderFromUI();
  ghState.busy = true;
  ghEl("ghTest").disabled = true;
  ghEl("ghSave").disabled = true;
  ghSetStatus(L("保存しています…"));
  try{
    const r = await api("/api/github-settings", "POST", {repo:repo, branch:branch, rulesPath:folder, token:ghEl("ghToken").value.trim()}, 30000);
    ghEl("ghToken").value = "";
    ghState.tokenSource = r.tokenSource || "";
    ghSetStatus(L("保存しました。") + " " + String(r.repo || repo) + "@" + String(r.branch || branch), "ok");
    try{ if(currentGlobalStatus && r && r.repo && r.hasToken){ currentGlobalStatus.githubConfigured = true; renderGlobalTargetsUI(); } }catch(e1){}
    try{ if(typeof refreshGlobal === "function") await refreshGlobal(); }catch(e2){}
  }catch(e){ ghSetStatus(e.message, "err"); }
  finally{
    ghState.busy = false;
    ghEl("ghTest").disabled = false;
    ghEl("ghSave").disabled = false;
  }
}
document.getElementById("btnGitHub").onclick = function(){ ghOpen(); };
document.getElementById("ghClose").onclick = function(){ ghClose(); };
document.getElementById("ghCancel").onclick = function(){ ghClose(); };
document.getElementById("ghTest").onclick = function(){ ghTest(); };
document.getElementById("ghForm").onsubmit = function(ev){ ghSave(ev); };
document.getElementById("ghEye").onclick = function(){
  ghSetTokenVisible(ghEl("ghToken").type === "password");
};
["ghRepo","ghBranch","ghFolderCustom"].forEach(function(id){
  ghEl(id).addEventListener("input", function(){ ghRenderPreview(); });
});
ghEl("ghRepo").addEventListener("blur", function(){ ghNormalizeRepo(); ghRenderPreview(); });
ghEl("ghRepo").addEventListener("paste", function(){ setTimeout(function(){ ghNormalizeRepo(); ghRenderPreview(); }, 0); });
ghEl("ghFolderCustom").addEventListener("blur", function(){ ghEl("ghFolderCustom").value = ghNormalizePath(ghEl("ghFolderCustom").value); ghRenderPreview(); });
document.querySelectorAll('input[name="ghFolder"]').forEach(function(x){
  x.addEventListener("change", function(){
    ghRenderPreview();
    if(ghFolderMode() === "__custom") try{ ghEl("ghFolderCustom").focus(); }catch(e){}
  });
});
document.getElementById("ghOvl").onclick = function(ev){ if(ev.target === this) ghClose(); };
document.addEventListener("keydown", function(ev){
  if(!ghState.open) return;
  if(ev.key === "Escape"){ ev.preventDefault(); ghClose(); }
});
ghRenderPreview();</script>
</body>
</html>
'@
  return $html.Replace('__RULE_EDITOR_VENDOR__', (Get-RuleEditorVendor))
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
        $catalogJson = ConvertTo-Json -InputObject @(Get-GlobalProviderCatalog) -Depth 3 -Compress
        Send-Text $ctx 200 ((Get-PageHtml).Replace('__TOKEN__', $Token).Replace('__GLOBAL_CATALOG__', $catalogJson)) 'text/html; charset=utf-8'
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
          $tgG = @(Get-GlobalDefaultTargets)
          try { $tgG = @((Get-GlobalSettings $AutoDir).targets) } catch {}
          Send-Json $ctx 200 (Get-GlobalContent $homeG $Token $tgG)
        }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/global-targets-get' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try {
          $gsGet = Get-GlobalSettings $AutoDir
          $availGet = @()
          foreach ($ceG in @(Get-GlobalProviderCatalog)) { $availGet += @{ id = [string]$ceG.id; label = [string]$ceG.label } }
          Send-Json $ctx 200 @{ schemaVersion = [int]$gsGet.schemaVersion; targets = @($gsGet.targets); available = $availGet }
        }
        catch { Send-Json $ctx 500 @{ error = $_.Exception.Message } }
        continue
      }
      if ($path -eq '/api/github-settings' -and $method -eq 'GET') {
        if ($req.Headers['X-Dashboard-Token'] -cne $Token) { Send-Json $ctx 403 @{ error = 'token 不正のため拒否しました。' }; continue }
        try {
          $gsGH = Get-GitHubSettings $AutoDir
          $srcGH = Get-GitHubTokenSource $AutoDir
          Send-Json $ctx 200 @{ ok = $true; repo = [string]$gsGH.repo; branch = [string]$gsGH.branch; rulesPath = [string]$gsGH.rulesPath; hasToken = ($srcGH -ne ''); tokenSource = $srcGH; updatedAt = [string]$gsGH.updatedAt }
        }
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
        try { $bodyText = Read-Body $req 262144 } catch { Send-Json $ctx 413 @{ error = '要求が大きすぎます。' }; continue }
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
        if ($path -eq '/api/github-rule-get') {
          try {
            $gr0 = Get-GitHubRuleContent $AutoDir ([string]$body.kind)
            if (-not $gr0.ok) { Send-Json $ctx 400 @{ error = [string]$gr0.error }; continue }
            $gr0.redacted = $false
            try {
              $grT = Redact-Text ([string]$gr0.text) $Token
              $gr0.redacted = ($grT -cne [string]$gr0.text)
              $gr0.text = $grT
            } catch {}
            Send-Json $ctx 200 $gr0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message } }
          continue
        }
        if ($path -eq '/api/github-rule-save') {
          $gk = [string]$body.kind
          if (($gk -cne 'project') -and ($gk -cne 'global')) { Send-Json $ctx 400 @{ error = '種別が不正です。' }; continue }
          $glock = $null
          try {
            if ($gk -ceq 'global') { $glock = Open-GlobalSyncLock $AutoDir }
            else { $glock = Open-SyncLock $AutoDir }
          } catch {
            # Unwrap: File::Open surfaces a MethodInvocationException whose message
            # has no 'busy', so a held project lock must be typed, not string-matched.
            $eg = $_.Exception
            while (($eg -is [System.Management.Automation.MethodInvocationException]) -and ($eg.InnerException)) { $eg = $eg.InnerException }
            if (($eg -is [System.IO.IOException]) -or ([string]$eg.Message).Contains('busy')) {
              Send-Json $ctx 409 @{ error = '同期実行中のため、終了後にやり直してください。(busy)' }
              continue
            }
            Send-Json $ctx 500 @{ error = [string]$eg.Message }; continue
          }
          try {
            $expRepo = [string]$body.repo
            $expBranch = [string]$body.branch
            $expPath = [string]$body.path
            if (-not (Test-GitHubRuleSaveOrigin $AutoDir $gk $expRepo $expBranch $expPath)) {
              Send-Json $ctx 409 @{ ok = $false; conflict = $true; error = 'GitHub連携設定（リポジトリ／ブランチ／パス）が変更されたため保存できません。再取得してください。' }
              continue
            }
            $curG = Get-GitHubRuleContent $AutoDir $gk
            if (-not $curG.ok) { Send-Json $ctx 400 @{ error = [string]$curG.error }; continue }
            $curGT = [string]$curG.text
            # Same rule as localrule-save: masked text is never written back.
            if (((Redact-Text $curGT $Token) -cne $curGT) -and ([string]$body.text -cne $curGT)) {
              Send-Json $ctx 409 @{ error = '伏字表示中の内容はそのまま保存できません。原本が変化した可能性があります。再取得してください。' }
              continue
            }
            $gs0 = Save-GitHubRuleContent $AutoDir $gk ([string]$body.text) ([string]$body.sha) $expRepo $expBranch $expPath
            if (-not $gs0.ok) {
              if ($gs0.conflict) { Send-Json $ctx 409 $gs0 } else { Send-Json $ctx 400 $gs0 }
              continue
            }
            Send-Json $ctx 200 $gs0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($glock) { try { $glock.Close() } catch {} } }
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
          if (($selNames.Count -gt 0) -and (-not (Test-GlobalTargetsValid $selNames))) { Send-Json $ctx 400 @{ error = '対象は一覧から1つ以上選んでください。' }; continue }
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
          if (($selP.Count -gt 0) -and (-not (Test-GlobalTargetsValid $selP))) { Send-Json $ctx 400 @{ error = '対象は一覧から1つ以上選んでください。' }; continue }
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
          if (-not (Test-GlobalTargetsValid $tgNew)) { Send-Json $ctx 400 @{ error = '対象は一覧から1つ以上選んでください。' }; continue }
          $tlock = $null
          try { $tlock = Open-GlobalSyncLock $AutoDir }
          catch {
            $emT = $_.Exception.Message
            if ($emT.Contains('(busy)')) { Send-Json $ctx 409 @{ error = $emT }; continue }
            Send-Json $ctx 500 @{ error = $emT }; continue
          }
          try {
            $tr0 = Set-GlobalTargets $AutoDir $tgNew
            # Keep the source repo's rule frontmatter in step with the selection.
            # Add-only, and a GitHub failure never rolls back the local save.
            $gh0 = $null
            try { $gh0 = Update-GitHubRuleTargets $AutoDir $tgNew }
            catch { $gh0 = @{ ok = $false; files = @(); error = $_.Exception.Message } }
            $tr0['github'] = $gh0
            Send-Json $ctx 200 $tr0
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message }
          } finally { if ($tlock) { try { $tlock.Close() } catch {} } }
          continue
        }
        if ($path -eq '/api/github-test') {
          $rGT = ''
          $bGT = ''
          $tGT = ''
          try { $rGT = [string]$body.repo } catch {}
          try { $bGT = [string]$body.branch } catch {}
          try { $tGT = [string]$body.token } catch {}
          try {
            $gt0 = Test-GitHubConnection $AutoDir $rGT $bGT $tGT
            if ($gt0.ok) { Send-Json $ctx 200 @{ ok = $true; repo = [string]$gt0.repo; branch = [string]$gt0.branch; sha = [string]$gt0.sha } }
            else { Send-Json $ctx 400 @{ ok = $false; error = [string]$gt0.error } }
          } catch { Send-Json $ctx 500 @{ ok = $false; error = $_.Exception.Message } }
          continue
        }
        if ($path -eq '/api/github-settings') {
          $rGS = ''
          $bGS = ''
          $pGS = ''
          $tGS = ''
          $clearGS = $false
          try { $rGS = [string]$body.repo } catch {}
          try { $bGS = [string]$body.branch } catch {}
          try { $pGS = [string]$body.rulesPath } catch {}
          try { $tGS = [string]$body.token } catch {}
          try { $clearGS = ($body.clearToken -eq $true) } catch {}
          $newTokGH = $tGS.Trim()
          if (($newTokGH -ne '') -and (-not (Test-GitHubTokenFormat $newTokGH))) { Send-Json $ctx 400 @{ error = 'トークンの形式が正しくありません（ghp_ または github_pat_ で始まる文字列）。' }; continue }
          # Verify first: a wrong repo/branch/token must never replace working settings.
          $chkGH = $null
          try { $chkGH = Test-GitHubConnection $AutoDir $rGS $bGS $newTokGH } catch { $chkGH = @{ ok = $false; error = $_.Exception.Message } }
          if (-not $chkGH.ok) { Send-Json $ctx 400 @{ error = [string]$chkGH.error }; continue }
          try {
            if ($clearGS) { Remove-GitHubToken $AutoDir }
            elseif ($newTokGH -ne '') { Save-GitHubToken $AutoDir $newTokGH | Out-Null }
            $svGH = Save-GitHubSettings $AutoDir $rGS $bGS $pGS
            $srcGS = Get-GitHubTokenSource $AutoDir
            Send-Json $ctx 200 @{ ok = $true; repo = [string]$svGH.repo; branch = [string]$svGH.branch; rulesPath = [string]$svGH.rulesPath; updatedAt = [string]$svGH.updatedAt; hasToken = ($srcGS -ne ''); tokenSource = $srcGS; sha = [string]$chkGH.sha }
          } catch { Send-Json $ctx 400 @{ error = $_.Exception.Message } }
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
