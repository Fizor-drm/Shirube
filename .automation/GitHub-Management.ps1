# GitHub-Management.ps1 - GitHub integration for the rules source.
# Stores repo/branch/rulesPath, keeps the rulesync source config in step, and
# commits selected targets into the rule files' frontmatter.
# Dot-sourced by Dashboard-Server.ps1 and both sync scripts. Self-contained:
# no listen, no arbitrary shell, no dependency on the other management files.
# The stored token is DPAPI-encrypted for the current Windows user and is never
# returned to the page (callers only see whether a token exists).
$ErrorActionPreference = 'Stop'

function Get-GitHubPrivateSids {
  $sids = @()
  try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544' } catch {}
  return @($sids | Where-Object { $_ -ne $null })
}

function Test-GitHubReparse([string]$Path) {
  $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $it) { return $false }
  return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Read-GitHubText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  if (Test-GitHubReparse $Path) { throw 'ファイルを確認できませんでした。' }
  return [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

# Atomic publish with an explicit owner-only ACL (same policy as the other
# private files: current user, SYSTEM and Administrators).
function Write-GitHubPrivateText([string]$Path, [string]$Text) {
  $dir = Split-Path -Path $Path -Parent
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-GitHubReparse $Path) { throw 'リンクへの書込みはできません。' }
  $tmp = Join-Path $dir ('.gh-tmp-' + [System.Guid]::NewGuid().ToString('N'))
  $sec = New-Object System.Security.AccessControl.FileSecurity
  $sec.SetAccessRuleProtection($true, $false)
  foreach ($sid in (Get-GitHubPrivateSids)) {
    $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
  }
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$Text)
  $fs = [System.IO.File]::Create($tmp, 4096, [System.IO.FileOptions]::None, $sec)
  try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  }
  catch {
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } } catch {}
    throw
  }
}

function Get-GitHubSettingsPath([string]$AutoDir) { return (Join-Path $AutoDir 'github-settings.json') }
function Get-GitHubTokenPath([string]$AutoDir) { return (Join-Path $AutoDir 'github-token.dat') }

function Get-GitHubSettings([string]$AutoDir) {
  $out = @{ repo = ''; branch = 'main'; rulesPath = 'rules'; updatedAt = '' }
  $f = Get-GitHubSettingsPath $AutoDir
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $out }
  if (Test-GitHubReparse $f) { throw 'GitHub設定を確認できませんでした。' }
  try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { throw 'GitHub設定を読み取れませんでした。' }
  foreach ($k in @('repo', 'branch', 'rulesPath', 'updatedAt')) {
    try { if ($o.PSObject.Properties[$k]) { $out[$k] = [string]$o.$k } } catch {}
  }
  if ($out.branch -eq '') { $out.branch = 'main' }
  if ($out.rulesPath -eq '') { $out.rulesPath = 'rules' }
  return $out
}

# owner/repo, tolerating a pasted https://github.com/<owner>/<repo> URL.
function ConvertTo-GitHubRepoSlug([string]$Repo) {
  $r = [string]$Repo
  $r = $r.Trim()
  if ($r -match '^(?:https?://)?(?:www\.)?github\.com/([^/\s#?]+)/([^/\s#?]+)') {
    $r = $Matches[1] + '/' + $Matches[2]
  }
  $r = ($r -replace '\.git$', '')
  return $r
}
function Test-GitHubRepoSlug([string]$Repo) {
  return ([string]$Repo -cmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$')
}
function Test-GitHubBranch([string]$Branch) {
  $b = [string]$Branch
  if ($b.Length -lt 1) { return $false }
  if ($b.Length -gt 100) { return $false }
  if ($b -match '[\s~^:?*\[\\]') { return $false }
  if ($b.StartsWith('-')) { return $false }
  if ($b.Contains('..')) { return $false }
  return $true
}
function Test-GitHubRulesPath([string]$Path) {
  $p = ([string]$Path).Trim().Replace('\', '/')
  if (($p -eq '') -or ($p -eq '.') -or ($p -eq './')) { return $true }
  if ($p.StartsWith('/')) { return $false }
  if ($p -match '(^|/)\.\.(/|$)') { return $false }
  if ($p -match '[<>:"|?*\x00-\x1f]') { return $false }
  return $true
}
# Repo-relative folder without a trailing slash; '.' means the repository root
# and an empty value falls back to rulesync's default ('rules').
function ConvertTo-GitHubRulesPath([string]$Path) {
  $p = ([string]$Path).Trim().Replace('\', '/')
  while ($p.StartsWith('/')) { $p = $p.Substring(1) }
  while ($p.EndsWith('/')) { $p = $p.Substring(0, $p.Length - 1) }
  if (($p -eq '.') -or ($p -eq './')) { return '.' }
  if ($p -eq '') { return 'rules' }
  return $p
}

# Saves the settings and repoints both local rulesync source configs.
function Save-GitHubSettings([string]$AutoDir, [string]$Repo, [string]$Branch, [string]$RulesPath) {
  $r = ConvertTo-GitHubRepoSlug $Repo
  if (-not (Test-GitHubRepoSlug $r)) { throw 'リポジトリは owner/repo の形式で指定してください。' }
  $b = ([string]$Branch).Trim()
  if (-not (Test-GitHubBranch $b)) { throw 'ブランチ名が不正です。' }
  $p = ([string]$RulesPath).Trim()
  if (-not (Test-GitHubRulesPath $p)) { throw 'フォルダの場所が不正です（.. や使えない文字は指定できません）。' }
  $p = ConvertTo-GitHubRulesPath $p
  $o = [ordered]@{ schemaVersion = 1; repo = $r; branch = $b; rulesPath = $p; updatedAt = ([DateTime]::UtcNow.ToString('o')) }
  Write-GitHubPrivateText (Get-GitHubSettingsPath $AutoDir) (ConvertTo-Json -InputObject $o -Depth 4)
  Update-GitHubSourceConfig $AutoDir $o
  return @{ ok = $true; repo = $r; branch = $b; rulesPath = $p; updatedAt = [string]$o.updatedAt }
}

function Test-GitHubTokenFormat([string]$Token) {
  return ([string]$Token -cmatch '^(ghp_|github_pat_|gho_|ghu_|ghs_)[A-Za-z0-9_]{20,}$')
}
function Save-GitHubToken([string]$AutoDir, [string]$Token) {
  $t = ([string]$Token).Trim()
  if ($t -eq '') { return $false }
  if (-not (Test-GitHubTokenFormat $t)) {
    throw 'トークンの形式が正しくありません（ghp_ または github_pat_ で始まる文字列）。'
  }
  $sec = ConvertTo-SecureString -String $t -AsPlainText -Force
  $enc = ConvertFrom-SecureString -SecureString $sec
  Write-GitHubPrivateText (Get-GitHubTokenPath $AutoDir) $enc
  return $true
}
function Remove-GitHubToken([string]$AutoDir) {
  $f = Get-GitHubTokenPath $AutoDir
  if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force }
}
# DPAPI (CurrentUser): only this Windows account can decrypt the stored blob.
function Get-GitHubToken([string]$AutoDir) {
  $f = Get-GitHubTokenPath $AutoDir
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $script:GitHubSavedTokenCache = $null; return '' }
  $stamp = ''
  try { $stamp = [string](Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks } catch { $stamp = '' }
  $c = $script:GitHubSavedTokenCache
  if ($c -and ($stamp -ne '') -and ($c.path -ceq $f) -and ($c.stamp -ceq $stamp)) { return [string]$c.value }
  try {
    $enc = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).Trim()
    if ($enc -eq '') { return '' }
    $sec = ConvertTo-SecureString -String $enc
    $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $v = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    if ($stamp -ne '') { $script:GitHubSavedTokenCache = @{ path = $f; stamp = $stamp; value = $v } }
    return $v
  }
  catch { return '' }
}
# Sync scripts: stored token first, then the gh CLI (previous behavior).
function Get-GitHubSyncToken([string]$AutoDir) {
  $t = Get-GitHubToken $AutoDir
  if ($t -ne '') { return $t }
  # Status polls hit this per request; spawning gh each time dominates latency.
  $c = $script:GitHubCliTokenCache
  if ($c) {
    $ttl = 300
    if ($c.value -eq '') { $ttl = 30 }
    if (((Get-Date) - $c.at).TotalSeconds -lt $ttl) { return [string]$c.value }
  }
  $g = Get-Command 'gh' -ErrorAction SilentlyContinue
  if (-not $g) { $script:GitHubCliTokenCache = @{ at = (Get-Date); value = '' }; return '' }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    $out = (& $g.Source auth token 2>$null | Out-String).Trim()
    $code = $LASTEXITCODE
    if (($code -eq 0) -and ($out -ne '')) {
      $script:GitHubCliTokenCache = @{ at = (Get-Date); value = $out }
      return $out
    }
  }
  catch {}
  finally { $ErrorActionPreference = $prev }
  $script:GitHubCliTokenCache = @{ at = (Get-Date); value = '' }
  return ''
}
function Get-GitHubTokenSource([string]$AutoDir) {
  if ((Get-GitHubToken $AutoDir) -ne '') { return 'saved' }
  if ((Get-GitHubSyncToken $AutoDir) -ne '') { return 'gh' }
  return ''
}

# Maps an Invoke-RestMethod failure to a message without the request headers
# (the Authorization header must never reach a log or the page).
function ConvertTo-GitHubError($Err) {
  $code = 0
  try { $code = [int]$Err.Exception.Response.StatusCode } catch {}
  $msg = ''
  try {
    $stream = $Err.Exception.Response.GetResponseStream()
    if ($stream) {
      $reader = New-Object System.IO.StreamReader($stream)
      $raw = $reader.ReadToEnd()
      try { $msg = [string](($raw | ConvertFrom-Json).message) } catch { $msg = '' }
    }
  }
  catch {}
  switch ($code) {
    401 { return 'トークンが無効です（401）。トークンを保存し直してください。' }
    403 { return 'GitHubの権限が不足しています（403）。Contents: Read and write を付与してください。' }
    404 { return 'リポジトリ・ブランチ・ファイルが見つかりません（404）。' }
    409 { return '更新が競合しました（409）。もう一度保存してください。' }
    422 { return 'GitHubが更新を拒否しました（422）。' }
  }
  if ($code -gt 0) { return ('GitHub API エラー（' + $code + '）: ' + $msg) }
  if ($msg -eq '') { $msg = [string]$Err.Exception.Message }
  return ('GitHubに接続できませんでした: ' + $msg)
}

function Invoke-GitHubApi([string]$Token, [string]$Method, [string]$ApiPath, $Body = $null) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $params = @{
    Method = $Method
    Uri = ('https://api.github.com' + $ApiPath)
    Headers = @{
      Authorization = ('Bearer ' + $Token)
      Accept = 'application/vnd.github+json'
      'X-GitHub-Api-Version' = '2022-11-28'
      'User-Agent' = 'Shirube'
    }
    TimeoutSec = 20
    ErrorAction = 'Stop'
    UseBasicParsing = $true
  }
  if ($null -ne $Body) {
    $params['ContentType'] = 'application/json; charset=utf-8'
    $params['Body'] = (ConvertTo-Json -InputObject $Body -Depth 6 -Compress)
  }
  try { return @{ ok = $true; data = (Invoke-RestMethod @params) } }
  catch { return @{ ok = $false; error = (ConvertTo-GitHubError $_) } }
}

function Test-GitHubConnection([string]$AutoDir, [string]$Repo, [string]$Branch, [string]$TokenOverride = '') {
  $r = ConvertTo-GitHubRepoSlug $Repo
  $b = ([string]$Branch).Trim()
  if (-not (Test-GitHubRepoSlug $r)) { return @{ ok = $false; error = 'リポジトリは owner/repo の形式で指定してください。' } }
  if (-not (Test-GitHubBranch $b)) { return @{ ok = $false; error = 'ブランチ名が不正です。' } }
  $tok = ([string]$TokenOverride).Trim()
  if ($tok -eq '') { $tok = Get-GitHubSyncToken $AutoDir }
  if ($tok -eq '') { return @{ ok = $false; error = 'トークンが未設定です。' } }
  $res = Invoke-GitHubApi $tok 'GET' ('/repos/' + $r + '/branches/' + [uri]::EscapeDataString($b))
  if (-not $res.ok) { return $res }
  $sha = ''
  try { $sha = [string]$res.data.commit.sha } catch {}
  return @{ ok = $true; repo = $r; branch = $b; sha = $sha }
}

# Rewrites sources in both local rulesync configs. Other keys stay untouched;
# the integration owns the source entry once configured.
function Update-GitHubSourceConfig([string]$AutoDir, $Settings) {
  $root = Split-Path $AutoDir -Parent
  $specs = @(
    @{ dir = (Join-Path $root 'global-preview'); rule = 'global' },
    @{ dir = (Join-Path $root 'project-common-preview'); rule = 'project' }
  )
  $src = ([string]$Settings.repo + '@' + [string]$Settings.branch)
  $path = [string]$Settings.rulesPath
  foreach ($s in $specs) {
    $f = Join-Path $s.dir 'rulesync.jsonc'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    if (Test-GitHubReparse $f) { throw 'rulesync.jsonc を確認できませんでした。' }
    try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'rulesync.jsonc を読み取れませんでした。' }
    $entry = [ordered]@{ source = $src; rules = @([string]$s.rule) }
    if (($path -ne '') -and ($path -ne 'rules')) { $entry['rulesPath'] = $path }
    $newObj = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) {
      if ($p.Name -eq 'sources') { $newObj['sources'] = @($entry) } else { $newObj[$p.Name] = $p.Value }
    }
    if (-not $newObj.Contains('sources')) { $newObj['sources'] = @($entry) }
    $json = (ConvertTo-Json -InputObject $newObj -Depth 8) + "`r`n"
    Write-GitHubPrivateText $f $json
  }
}

# Adds missing targets to one rule file's inline frontmatter array.
# Returns @{ ok; changed; text; added } and never rewrites an unknown shape.
# shortcut: only the one-line `targets: [..]` form is supported; upgrade if a
# rule file starts using a block-style YAML list.
function Update-GitHubTargetsText([string]$Text, [string[]]$Targets) {
  $src = [string]$Text
  if (($src.Length -gt 0) -and ($src[0] -eq [char]0xFEFF)) { $src = $src.Substring(1) }
  $nl = "`n"
  if ($src.Contains("`r`n")) { $nl = "`r`n" }
  $lines = @($src -split "`r?`n")
  if (($lines.Count -lt 3) -or ($lines[0].Trim() -ne '---')) {
    return @{ ok = $false; error = 'frontmatter が見つかりません。' }
  }
  $close = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { $close = $i; break }
  }
  if ($close -lt 0) { return @{ ok = $false; error = 'frontmatter の終端が見つかりません。' } }
  $idx = -1
  $items = @()
  for ($i = 1; $i -lt $close; $i++) {
    if ($lines[$i] -match '^(\s*)targets\s*:\s*\[(.*)\]\s*$') {
      $idx = $i
      $inner = [string]$Matches[2]
      foreach ($m in [regex]::Matches($inner, '"([^"]*)"|''([^'']*)''|([^,\s]+)')) {
        $v = ($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value)
        if ($v -ne '') { $items += $v }
      }
      break
    }
    if ($lines[$i] -match '^\s*targets\s*:') {
      return @{ ok = $false; error = 'targets は1行の配列 [..] のみ対応しています。' }
    }
  }
  if ($idx -lt 0) { return @{ ok = $false; error = 'frontmatter に targets がありません。' } }
  $add = @()
  foreach ($t in @($Targets)) {
    $tt = ([string]$t).Trim()
    if (($tt -ne '') -and ($items -notcontains $tt)) { $add += $tt }
  }
  if ($add.Count -eq 0) { return @{ ok = $true; changed = $false; text = $src; added = @() } }
  $all = @($items) + @($add)
  $lead = ''
  if ($lines[$idx] -match '^(\s*)') { $lead = [string]$Matches[1] }
  $lines[$idx] = $lead + 'targets: [' + (($all | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']'
  return @{ ok = $true; changed = $true; text = ($lines -join $nl); added = @($add) }
}

function Get-GitHubRuleRelPath([string]$RulesPath, [string]$Name) {
  $p = ConvertTo-GitHubRulesPath $RulesPath
  if (($p -eq '.') -or ($p -eq '')) { return ($Name + '.md') }
  return ($p + '/' + $Name + '.md')
}

# Reads one file from the configured branch. Fails closed when the integration
# or token is missing, so callers never reach the API unconfigured.
function Get-GitHubFile([string]$AutoDir, [string]$RelPath) {
  $s = Get-GitHubSettings $AutoDir
  if (([string]$s.repo -eq '') -or ([string]$s.branch -eq '')) {
    return @{ ok = $false; error = 'GitHub連携が未設定です。' }
  }
  $tok = Get-GitHubSyncToken $AutoDir
  if ($tok -eq '') { return @{ ok = $false; error = 'GitHubのトークンが未設定です。' } }
  $rel = ([string]$RelPath).TrimStart('/')
  if ($rel -eq '') { return @{ ok = $false; error = 'ファイルの場所が不正です。' } }
  $get = Invoke-GitHubApi $tok 'GET' ('/repos/' + [string]$s.repo + '/contents/' + $rel + '?ref=' + [uri]::EscapeDataString([string]$s.branch))
  if (-not $get.ok) { return $get }
  $sha = ''
  $b64 = ''
  try {
    $sha = [string]$get.data.sha
    $b64 = ([string]$get.data.content -replace '\s', '')
  } catch {}
  if (($sha -eq '') -or ($b64 -eq '')) { return @{ ok = $false; error = 'ファイルの内容を取得できませんでした。' } }
  try { $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
  catch { return @{ ok = $false; error = '内容を復号できませんでした。' } }
  return @{ ok = $true; sha = $sha; text = $text; path = $rel }
}

# Commits text to one file. The caller passes the sha it read, so an
# out-of-date write is rejected by GitHub (409) instead of overwriting.
function Set-GitHubFile([string]$AutoDir, [string]$RelPath, [string]$Text, [string]$Sha, [string]$Message) {
  $s = Get-GitHubSettings $AutoDir
  if (([string]$s.repo -eq '') -or ([string]$s.branch -eq '')) {
    return @{ ok = $false; error = 'GitHub連携が未設定です。' }
  }
  $tok = Get-GitHubSyncToken $AutoDir
  if ($tok -eq '') { return @{ ok = $false; error = 'GitHubのトークンが未設定です。' } }
  $rel = ([string]$RelPath).TrimStart('/')
  if ($rel -eq '') { return @{ ok = $false; error = 'ファイルの場所が不正です。' } }
  $put = Invoke-GitHubApi $tok 'PUT' ('/repos/' + [string]$s.repo + '/contents/' + $rel) @{
    message = [string]$Message
    content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Text))
    sha = [string]$Sha
    branch = [string]$s.branch
  }
  if (-not $put.ok) { return $put }
  $newSha = ''
  try { $newSha = [string]$put.data.content.sha } catch {}
  return @{ ok = $true; sha = $newSha; path = $rel }
}

# Rule editor frontmatter contract: one-line targets array, lowercase slugs,
# no duplicates, and root: true. project.md must keep both base targets.
function Test-GitHubRuleFrontmatter([string]$Text, [string]$Kind) {
  $src = [string]$Text
  if ($src.Length -eq 0) { return $false }
  if ([System.Text.Encoding]::UTF8.GetByteCount($src) -gt 262144) { return $false }
  if ($src[0] -eq [char]0xFEFF) { $src = $src.Substring(1) }
  $lines = @($src -split "`r?`n")
  if (($lines.Count -lt 3) -or ($lines[0].Trim() -ne '---')) { return $false }
  $close = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { $close = $i; break }
  }
  if ($close -lt 0) { return $false }
  $rootOk = $false
  $targetsOk = $false
  $items = @()
  for ($i = 1; $i -lt $close; $i++) {
    $ln = $lines[$i]
    if ($ln -match '^\s*root\s*:\s*(.+?)\s*$') {
      if ($Matches[1] -ceq 'true') { $rootOk = $true }
      continue
    }
    if ($ln -match '^\s*targets\s*:') {
      if ($ln -notmatch '^\s*targets\s*:\s*\[(.*)\]\s*$') { return $false }
      $inner = [string]$Matches[1]
      foreach ($m in [regex]::Matches($inner, '"([^"]*)"|''([^'']*)''|([^,\s]+)')) {
        $v = ($m.Groups[1].Value + $m.Groups[2].Value + $m.Groups[3].Value)
        if ($v -eq '') { continue }
        if ($v -cnotmatch '^[a-z][a-z0-9_-]*$') { return $false }
        if ($items -ccontains $v) { return $false }
        $items += $v
      }
      $targetsOk = $true
    }
  }
  if ((-not $rootOk) -or (-not $targetsOk) -or ($items.Count -eq 0)) { return $false }
  if ([string]$Kind -ceq 'project') {
    if (-not ($items -ccontains 'codexcli')) { return $false }
    if (-not ($items -ccontains 'opencode')) { return $false }
  }
  return $true
}

function Get-GitHubRuleContent([string]$AutoDir, [string]$Kind) {
  $k = [string]$Kind
  if (($k -cne 'project') -and ($k -cne 'global')) { return @{ ok = $false; error = '種別が不正です。' } }
  $s = Get-GitHubSettings $AutoDir
  if (([string]$s.repo -eq '') -or ([string]$s.branch -eq '')) {
    return @{ ok = $false; error = 'GitHub連携が未設定です。' }
  }
  $rel = Get-GitHubRuleRelPath ([string]$s.rulesPath) $k
  $r = Get-GitHubFile $AutoDir $rel
  if (-not $r.ok) { return $r }
  $r['kind'] = $k
  return $r
}

function Save-GitHubRuleContent([string]$AutoDir, [string]$Kind, [string]$Text, [string]$ExpectedSha) {
  $k = [string]$Kind
  if (($k -cne 'project') -and ($k -cne 'global')) { return @{ ok = $false; error = '種別が不正です。' } }
  if (-not (Test-GitHubRuleFrontmatter ([string]$Text) $k)) {
    return @{ ok = $false; error = 'frontmatter が不正です（root: true、1行の targets 配列、小文字スラッグ、重複なしが必要です）。' }
  }
  $cur = Get-GitHubRuleContent $AutoDir $k
  if (-not $cur.ok) { return $cur }
  if ([string]$cur.sha -cne [string]$ExpectedSha) {
    return @{ ok = $false; conflict = $true; sha = [string]$cur.sha; error = '他の変更と競合しました（409）。再取得してください。' }
  }
  $s = Get-GitHubSettings $AutoDir
  $rel = Get-GitHubRuleRelPath ([string]$s.rulesPath) $k
  $put = Set-GitHubFile $AutoDir $rel ([string]$Text) ([string]$ExpectedSha) ('chore: update ' + $k + ' rule')
  if (-not $put.ok) { return $put }
  return @{ ok = $true; sha = [string]$put.sha; path = $rel; kind = $k }
}

# Adds the selected targets to global.md and project.md in the source repo and
# commits each changed file. Add-only: deselected targets are never removed.
# Returns per-file results; callers decide whether to surface the failure.
function Update-GitHubRuleTargets([string]$AutoDir, [string[]]$Targets) {
  $s = Get-GitHubSettings $AutoDir
  if (([string]$s.repo -eq '') -or ([string]$s.branch -eq '')) {
    return @{ ok = $false; skipped = $true; files = @(); error = 'GitHub連携が未設定です。' }
  }
  $tok = Get-GitHubSyncToken $AutoDir
  if ($tok -eq '') {
    return @{ ok = $false; skipped = $true; files = @(); error = 'GitHubのトークンが未設定です。' }
  }
  $files = @()
  $fail = ''
  foreach ($name in @('global', 'project')) {
    $rel = Get-GitHubRuleRelPath ([string]$s.rulesPath) $name
    $get = Invoke-GitHubApi $tok 'GET' ('/repos/' + [string]$s.repo + '/contents/' + $rel + '?ref=' + [uri]::EscapeDataString([string]$s.branch))
    if (-not $get.ok) {
      if ($fail -eq '') { $fail = [string]$get.error }
      $files += @{ name = $name; path = $rel; added = @(); ok = $false; error = [string]$get.error }
      continue
    }
    $sha = ''
    $b64 = ''
    try {
      $sha = [string]$get.data.sha
      $b64 = ([string]$get.data.content -replace '\s', '')
    }
    catch {}
    if (($sha -eq '') -or ($b64 -eq '')) {
      if ($fail -eq '') { $fail = ($name + '.md の内容を取得できませんでした。') }
      $files += @{ name = $name; path = $rel; added = @(); ok = $false; error = '内容を取得できませんでした。' }
      continue
    }
    try { $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
    catch {
      if ($fail -eq '') { $fail = ($name + '.md の内容を復号できませんでした。') }
      $files += @{ name = $name; path = $rel; added = @(); ok = $false; error = '内容を復号できませんでした。' }
      continue
    }
    $upd = Update-GitHubTargetsText $text $Targets
    if (-not $upd.ok) {
      if ($fail -eq '') { $fail = ([string]$upd.error + ' (' + $name + '.md)') }
      $files += @{ name = $name; path = $rel; added = @(); ok = $false; error = [string]$upd.error }
      continue
    }
    if (-not $upd.changed) {
      $files += @{ name = $name; path = $rel; added = @(); ok = $true; error = '' }
      continue
    }
    $addedList = @($upd.added)
    $put = Invoke-GitHubApi $tok 'PUT' ('/repos/' + [string]$s.repo + '/contents/' + $rel) @{
      message = ('chore: add ' + ($addedList -join ', ') + ' to ' + $name + ' rule targets')
      content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$upd.text))
      sha = $sha
      branch = [string]$s.branch
    }
    if (-not $put.ok) {
      if ($fail -eq '') { $fail = [string]$put.error }
      $files += @{ name = $name; path = $rel; added = @(); ok = $false; error = [string]$put.error }
      continue
    }
    $files += @{ name = $name; path = $rel; added = $addedList; ok = $true; error = '' }
  }
  return @{ ok = ($fail -eq ''); files = $files; error = $fail }
}

# Dot-sourced by self-checks and by the dashboard/sync scripts (no exit).
if ($MyInvocation.InvocationName -ne '.') { Write-Host 'GitHub-Management loaded.' }
