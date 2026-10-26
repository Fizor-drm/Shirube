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

# Removes // and /* */ comments outside strings so ConvertFrom-Json can read a
# JSONC file. Returns $null when the text is not a JSON object.
function ConvertFrom-GitHubJsonc([string]$Text) {
  $src = [string]$Text
  if (($src.Length -gt 0) -and ($src[0] -eq [char]0xFEFF)) { $src = $src.Substring(1) }
  $out = New-Object System.Text.StringBuilder
  $i = 0
  $n = $src.Length
  while ($i -lt $n) {
    $c = $src[$i]
    if ($c -eq [char]'"') {
      $j = $i + 1
      [void]$out.Append($c)
      while ($j -lt $n) {
        $cj = $src[$j]
        [void]$out.Append($cj)
        if (($cj -eq [char]'\') -and (($j + 1) -lt $n)) { $j++; [void]$out.Append($src[$j]); $j++; continue }
        if ($cj -eq [char]'"') { $j++; break }
        $j++
      }
      $i = $j
      continue
    }
    if (($c -eq [char]'/') -and (($i + 1) -lt $n) -and ($src[$i + 1] -eq [char]'/')) {
      while (($i -lt $n) -and ($src[$i] -ne [char]"`n")) { $i++ }
      continue
    }
    if (($c -eq [char]'/') -and (($i + 1) -lt $n) -and ($src[$i + 1] -eq [char]'*')) {
      $i += 2
      while ((($i + 1) -lt $n) -and -not (($src[$i] -eq [char]'*') -and ($src[$i + 1] -eq [char]'/'))) { $i++ }
      $i += 2
      continue
    }
    [void]$out.Append($c)
    $i++
  }
  try { $o = ($out.ToString() | ConvertFrom-Json) } catch { return $null }
  if (($null -eq $o) -or ($o -is [array])) { return $null }
  return $o
}

# Span of the value of a root-level JSONC key (@{ start; end }), or $null.
# Used for in-place rewrites: everything outside the span stays byte-identical.
function Find-GitHubJsoncValue([string]$Text, [string]$Key) {
  $src = [string]$Text
  $n = $src.Length
  $i = 0
  if (($n -gt 0) -and ($src[0] -eq [char]0xFEFF)) { $i = 1 }
  $depth = 0
  $last = ''
  while ($i -lt $n) {
    $c = $src[$i]
    if ($c -eq [char]'"') {
      $sb = New-Object System.Text.StringBuilder
      $j = $i + 1
      while ($j -lt $n) {
        $cj = $src[$j]
        if (($cj -eq [char]'\') -and (($j + 1) -lt $n)) { [void]$sb.Append($src[$j + 1]); $j += 2; continue }
        if ($cj -eq [char]'"') { $j++; break }
        [void]$sb.Append($cj)
        $j++
      }
      $last = ConvertFrom-Json $src.Substring($i, $j - $i)
      $i = $j
      continue
    }
    if (($c -eq [char]'/') -and (($i + 1) -lt $n) -and ($src[$i + 1] -eq [char]'/')) {
      while (($i -lt $n) -and ($src[$i] -ne [char]"`n")) { $i++ }
      continue
    }
    if (($c -eq [char]'/') -and (($i + 1) -lt $n) -and ($src[$i + 1] -eq [char]'*')) {
      $i += 2
      while ((($i + 1) -lt $n) -and -not (($src[$i] -eq [char]'*') -and ($src[$i + 1] -eq [char]'/'))) { $i++ }
      $i += 2
      continue
    }
    if (($c -eq [char]'{') -or ($c -eq [char]'[')) { $depth++; $last = ''; $i++; continue }
    if (($c -eq [char]'}') -or ($c -eq [char]']')) { $depth--; $last = ''; $i++; continue }
    if (($c -eq [char]':') -and ($depth -eq 1) -and ($last -ceq $Key)) {
      $j = $i + 1
      while ($j -lt $n) {
        $cj = $src[$j]
        if ([char]::IsWhiteSpace($cj)) { $j++; continue }
        if (($cj -eq [char]'/') -and (($j + 1) -lt $n) -and ($src[$j + 1] -eq [char]'/')) {
          while (($j -lt $n) -and ($src[$j] -ne [char]"`n")) { $j++ }
          continue
        }
        if (($cj -eq [char]'/') -and (($j + 1) -lt $n) -and ($src[$j + 1] -eq [char]'*')) {
          $j += 2
          while ((($j + 1) -lt $n) -and -not (($src[$j] -eq [char]'*') -and ($src[$j + 1] -eq [char]'/'))) { $j++ }
          $j += 2
          continue
        }
        break
      }
      if ($j -ge $n) { return $null }
      $start = $j
      $end = -1
      $q = $src[$j]
      if ($q -eq [char]'"') {
        $j++
        while ($j -lt $n) {
          if (($src[$j] -eq [char]'\') -and (($j + 1) -lt $n)) { $j += 2; continue }
          if ($src[$j] -eq [char]'"') { $end = $j + 1; break }
          $j++
        }
      }
      elseif (($q -eq [char]'{') -or ($q -eq [char]'[')) {
        $d = 0
        while ($j -lt $n) {
          $cj = $src[$j]
          if ($cj -eq [char]'"') {
            $j++
            while ($j -lt $n) {
              if (($src[$j] -eq [char]'\') -and (($j + 1) -lt $n)) { $j += 2; continue }
              if ($src[$j] -eq [char]'"') { $j++; break }
              $j++
            }
            continue
          }
          if (($cj -eq [char]'/') -and (($j + 1) -lt $n) -and ($src[$j + 1] -eq [char]'/')) {
            while (($j -lt $n) -and ($src[$j] -ne [char]"`n")) { $j++ }
            continue
          }
          if (($cj -eq [char]'/') -and (($j + 1) -lt $n) -and ($src[$j + 1] -eq [char]'*')) {
            $j += 2
            while ((($j + 1) -lt $n) -and -not (($src[$j] -eq [char]'*') -and ($src[$j + 1] -eq [char]'/'))) { $j++ }
            $j += 2
            continue
          }
          if (($cj -eq [char]'{') -or ($cj -eq [char]'[')) { $d++; $j++; continue }
          if (($cj -eq [char]'}') -or ($cj -eq [char]']')) {
            $d--
            $j++
            if ($d -eq 0) { $end = $j; break }
            continue
          }
          $j++
        }
      }
      else {
        while ($j -lt $n) {
          $cj = $src[$j]
          if (($cj -eq [char]',') -or ($cj -eq [char]'}') -or ($cj -eq [char]']') -or [char]::IsWhiteSpace($cj)) { break }
          $j++
        }
        $end = $j
      }
      if ($end -lt 0) { return $null }
      return @{ start = $start; end = $end }
    }
    if (-not [char]::IsWhiteSpace($c)) { $last = '' }
    $i++
  }
  return $null
}

# Rewrites only the root-level `sources` value; other keys, comments, spacing
# and line endings stay as the user wrote them.
function Set-GitHubSourceConfigText([string]$Text, $Entry) {
  $src = [string]$Text
  $parsed = ConvertFrom-GitHubJsonc $src
  $root = [regex]::Match($src, '\A(?:\uFEFF|\s|//[^\r\n]*(?:\r?\n|$)|/\*[\s\S]*?\*/)*\{')
  if (($null -eq $parsed) -or (-not $root.Success)) { throw 'rulesync.jsonc を読み取れませんでした。' }
  $nl = "`n"
  if ($src.Contains("`r`n")) { $nl = "`r`n" }
  $entryJson = (ConvertTo-Json -InputObject $Entry -Depth 6 -Compress)
  $arr = '[' + $nl + '    ' + $entryJson + $nl + '  ]'
  $span = Find-GitHubJsoncValue $src 'sources'
  if ($span) { $result = $src.Substring(0, [int]$span.start) + $arr + $src.Substring([int]$span.end) }
  else {
    # Insert before existing properties so a final line comment cannot swallow the comma.
    $comma = ''
    if (@($parsed.PSObject.Properties).Count -gt 0) { $comma = ',' }
    $result = $src.Insert($root.Length, $nl + '  "sources": ' + $arr + $comma + $nl)
  }
  if ($null -eq (ConvertFrom-GitHubJsonc $result)) { throw 'rulesync.jsonc の更新内容を確認できませんでした。' }
  return $result
}

# Prepares both config rewrites without writing: every input is validated and
# every new text is built before Save-GitHubSettings touches the disk.
function Get-GitHubSourceConfigChanges([string]$AutoDir, $Settings) {
  $root = Split-Path $AutoDir -Parent
  $specs = @(
    @{ dir = (Join-Path $root 'global-preview'); rule = 'global' },
    @{ dir = (Join-Path $root 'project-common-preview'); rule = 'project' }
  )
  $src = ([string]$Settings.repo + '@' + [string]$Settings.branch)
  $path = [string]$Settings.rulesPath
  $changes = @()
  foreach ($s in $specs) {
    $f = Join-Path $s.dir 'rulesync.jsonc'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    if (Test-GitHubReparse $f) { throw 'rulesync.jsonc を確認できませんでした。' }
    try { $old = Read-GitHubText $f } catch { throw 'rulesync.jsonc を読み取れませんでした。' }
    if (-not ([string]$old).Trim()) { throw 'rulesync.jsonc を読み取れませんでした。' }
    $entry = [ordered]@{ source = $src; rules = @([string]$s.rule) }
    if (($path -ne '') -and ($path -ne 'rules')) { $entry['rulesPath'] = $path }
    $changes += @{ path = $f; old = $old; text = (Set-GitHubSourceConfigText $old $entry) }
  }
  return $changes
}

# Saves the settings and repoints both local rulesync source configs as one
# transaction: if any write fails, every touched file is restored.
function Save-GitHubSettings([string]$AutoDir, [string]$Repo, [string]$Branch, [string]$RulesPath) {
  $r = ConvertTo-GitHubRepoSlug $Repo
  if (-not (Test-GitHubRepoSlug $r)) { throw 'リポジトリは owner/repo の形式で指定してください。' }
  $b = ([string]$Branch).Trim()
  if (-not (Test-GitHubBranch $b)) { throw 'ブランチ名が不正です。' }
  $p = ([string]$RulesPath).Trim()
  if (-not (Test-GitHubRulesPath $p)) { throw 'フォルダの場所が不正です（.. や使えない文字は指定できません）。' }
  $p = ConvertTo-GitHubRulesPath $p
  $o = [ordered]@{ schemaVersion = 1; repo = $r; branch = $b; rulesPath = $p; updatedAt = ([DateTime]::UtcNow.ToString('o')) }
  $changes = @(Get-GitHubSourceConfigChanges $AutoDir $o)
  $settingsPath = Get-GitHubSettingsPath $AutoDir
  $settingsExisted = Test-Path -LiteralPath $settingsPath -PathType Leaf
  $settingsOld = $null
  if ($settingsExisted) { $settingsOld = [System.IO.File]::ReadAllBytes($settingsPath) }
  $written = @()
  try {
    $written += $settingsPath
    Write-GitHubPrivateText $settingsPath (ConvertTo-Json -InputObject $o -Depth 4)
    foreach ($ch in $changes) {
      $written += [string]$ch.path
      Write-GitHubPrivateText ([string]$ch.path) ([string]$ch.text)
    }
  }
  catch {
    $applyErr = $_
    $rbErrs = @()
    foreach ($wp in $written) {
      try {
        if ($wp -ceq $settingsPath) {
          if ($settingsExisted) { [System.IO.File]::WriteAllBytes($wp, $settingsOld) }
          elseif (Test-Path -LiteralPath $wp) { Remove-Item -LiteralPath $wp -Force }
        }
        else {
          $oldCh = @($changes | Where-Object { [string]$_.path -ceq $wp })[0]
          if ($oldCh) { Write-GitHubPrivateText $wp ([string]$oldCh.old) }
        }
      } catch { $rbErrs += $_.Exception.Message }
    }
    if ($rbErrs.Count -gt 0) {
      throw ($applyErr.Exception.Message + '（巻戻しにも失敗しました。保存内容を確認してください: ' + ($rbErrs -join '; ') + '）')
    }
    throw $applyErr
  }
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
  $trail = ''
  for ($i = 1; $i -lt $close; $i++) {
    # Same shape as Test-GitHubRuleFrontmatter: a trailing comment is allowed.
    if ($lines[$i] -match '^(\s*)targets\s*:\s*\[([^\]]*)\]([ \t]+#.*)?\s*$') {
      $idx = $i
      $inner = [string]$Matches[2]
      $trail = [string]$Matches[3]
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
  # A wildcard already covers every target; appending slugs would mix "*" with
  # concrete targets, which Test-GitHubRuleFrontmatter refuses.
  if ($items -contains '*') { return @{ ok = $true; changed = $false; text = $src; added = @() } }
  $add = @()
  foreach ($t in @($Targets)) {
    $tt = ([string]$t).Trim()
    if (($tt -ne '') -and ($items -notcontains $tt)) { $add += $tt }
  }
  if ($add.Count -eq 0) { return @{ ok = $true; changed = $false; text = $src; added = @() } }
  $all = @($items) + @($add)
  $lead = ''
  if ($lines[$idx] -match '^(\s*)') { $lead = [string]$Matches[1] }
  $lines[$idx] = $lead + 'targets: [' + (($all | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']' + $trail
  return @{ ok = $true; changed = $true; text = ($lines -join $nl); added = @($add) }
}

function Get-GitHubRuleRelPath([string]$RulesPath, [string]$Name) {
  $p = ConvertTo-GitHubRulesPath $RulesPath
  if (($p -eq '.') -or ($p -eq '')) { return ($Name + '.md') }
  return ($p + '/' + $Name + '.md')
}

# Binds a save to the origin the editor loaded from, so changing the GitHub
# settings mid-edit can never commit into another repository, branch, or path.
function Test-GitHubRuleSaveOrigin([string]$AutoDir, [string]$Kind, [string]$Repo, [string]$Branch, [string]$Path) {
  $s = Get-GitHubSettings $AutoDir
  $rel = Get-GitHubRuleRelPath ([string]$s.rulesPath) $Kind
  if (([string]$Repo -ne '') -and ([string]$s.repo -cne [string]$Repo)) { return $false }
  if (([string]$Branch -ne '') -and ([string]$s.branch -cne [string]$Branch)) { return $false }
  if (([string]$Path -ne '') -and ($rel -cne [string]$Path)) { return $false }
  return $true
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

# rulesync 42.0.0 ToolTarget enum (dist/index.d.ts). A target outside this list
# (for example `claude-code`; the canonical slug is `claudecode`) makes the
# pinned CLI reject the rule, so the editor refuses it before the PUT.
# shortcut: pinned to 42.0.0; refresh when rulesyncVersion moves past 42.
$script:GitHubRuleTargets = @(
  'agentsmd', 'agentsskills', 'aiassistant', 'amp', 'androidstudio',
  'antigravity-cli', 'antigravity-ide', 'antigravity-plugin',
  'augmentcode', 'augmentcode-legacy', 'augmentcode-plugin', 'bob',
  'claudecode', 'claudecode-legacy', 'claudecode-plugin', 'cline',
  'codebuddy', 'codebuff', 'codewhale', 'codexcli', 'commandcode',
  'continue', 'copilot', 'copilotcli', 'cortexcode', 'crush', 'cursor',
  'deepagents', 'devin', 'devin-plugin', 'dsh', 'factorydroid',
  'firebender', 'gitlabduo', 'goose', 'grokcli', 'hermesagent', 'junie', 'kilo',
  'kimi-code', 'kimi-code-plugin', 'kiro', 'kiro-cli', 'kiro-ide',
  'lettacode', 'mimocode', 'musecode', 'omp', 'openclaw', 'opencode',
  'opencodev1', 'pi', 'pool', 'qoder', 'qwencode', 'reasonix', 'replit', 'roo',
  'rovodev', 'tabnine', 'takt', 'trae', 'vibe', 'vibe-plugin', 'warp',
  'warpcli', 'xum', 'zcode', 'zcode-plugin', 'zed', 'zoocode'
)

# Rule editor frontmatter contract: the same strict line gate as
# Sync-ProjectRules.ps1 Test-FrontmatterFlag. root: true exactly once, no
# localRoot mix, one-line targets array with double-quoted lowercase slugs and
# no duplicates, at most one double-quoted description, no unknown keys.
# project.md must keep both base targets; global.md may omit targets (all
# targets) or use the ["*"] wildcard.
function Test-GitHubRuleFrontmatter([string]$Text, [string]$Kind) {
  $src = [string]$Text
  if ($src.Length -eq 0) { return $false }
  if ([System.Text.Encoding]::UTF8.GetByteCount($src) -gt 262144) { return $false }
  if ($src[0] -eq [char]0xFEFF) { $src = $src.Substring(1) }
  $norm = $src -replace "`r`n", "`n"
  $norm = $norm -replace "`r", "`n"
  if ($norm -notmatch '\A---[ \t]*\n') { return $false }
  $m = [regex]::Match($norm, '\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { return $false }
  $proj = ([string]$Kind -ceq 'project')
  $rootHits = 0
  $seenTargets = 0
  $seenDesc = 0
  $items = @()
  $wildcard = $false
  foreach ($ln in ($m.Groups[1].Value -split "`n")) {
    if ($ln -match '^[ \t]*$') { continue }
    if ($ln -match '^[ \t]') { return $false }
    if ($ln -match ':\s*[|>]\s*(#.*)?$') { return $false }
    if ($ln -cmatch '^root\s*:[ \t]+true([ \t]+#.*)?[ \t]*$') { $rootHits++; continue }
    if ($ln -cmatch '^root\s*:') { return $false }
    if ($ln -cmatch '^localRoot\s*:') { return $false }
    # Same contract as Sync-ProjectRules.ps1:126.
    if ($ln -cmatch '^targets\s*:[ \t]+\[(\s*"[a-z0-9][a-z0-9-]*"(?:\s*,\s*"[a-z0-9][a-z0-9-]*")*\s*)\]([ \t]+#.*)?[ \t]*$') {
      $seenTargets++
      if ($seenTargets -gt 1) { return $false }
      foreach ($tm in [regex]::Matches([string]$Matches[1], '"([a-z0-9][a-z0-9-]*)"')) {
        $v = [string]$tm.Groups[1].Value
        if ($items -ccontains $v) { return $false }
        if ($script:GitHubRuleTargets -cnotcontains $v) { return $false }
        $items += $v
      }
      if ($proj) {
        if (-not ($items -ccontains 'codexcli')) { return $false }
        if (-not ($items -ccontains 'opencode')) { return $false }
      }
      continue
    }
    if ($ln -cmatch '^targets\s*:[ \t]+\[\s*"\*"\s*\]([ \t]+#.*)?[ \t]*$') {
      $seenTargets++
      if ($seenTargets -gt 1) { return $false }
      if ($proj) { return $false }
      $wildcard = $true
      continue
    }
    if ($ln -cmatch '^targets\s*:') { return $false }
    # No unescaped quote inside: `"say "hi""` is invalid YAML and would break the next sync.
    # Only YAML 1.2 escapes: \0 \a \b \t \n \v \f \r \e \  \" \/ \\ \N \_ \L \P,
    # plus \xNN, \uNNNN, \UNNNNNNNN. A bare "\q" or "C:\Users" is refused.
    if ($ln -cmatch '^description\s*:[ \t]+"([^"\\]|\\[0abtnvfre " /\\N_LP]|\\x[0-9a-fA-F]{2}|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})*"([ \t]+#.*)?[ \t]*$') { $seenDesc++; if ($seenDesc -gt 1) { return $false }; continue }
    if ($ln -cmatch '^description\s*:') { return $false }
    return $false
  }
  if ($rootHits -ne 1) { return $false }
  if ($proj -and (($seenTargets -ne 1) -or $wildcard)) { return $false }
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
  $r['repo'] = [string]$s.repo
  $r['branch'] = [string]$s.branch
  return $r
}

function Save-GitHubRuleContent([string]$AutoDir, [string]$Kind, [string]$Text, [string]$ExpectedSha, [string]$ExpectedRepo = '', [string]$ExpectedBranch = '', [string]$ExpectedPath = '') {
  $k = [string]$Kind
  if (($k -cne 'project') -and ($k -cne 'global')) { return @{ ok = $false; error = '種別が不正です。' } }
  if (-not (Test-GitHubRuleFrontmatter ([string]$Text) $k)) {
    return @{ ok = $false; error = 'frontmatter が不正です（root: true、1行の targets 配列（global は省略可）、rulesync が対応するターゲット、重複なしが必要です）。' }
  }
  $originConflict = @{ ok = $false; conflict = $true; error = 'GitHub連携設定（リポジトリ／ブランチ／パス）が変更されたため保存できません。再取得してください。' }
  if (-not (Test-GitHubRuleSaveOrigin $AutoDir $k $ExpectedRepo $ExpectedBranch $ExpectedPath)) { return $originConflict }
  $cur = Get-GitHubRuleContent $AutoDir $k
  if (-not $cur.ok) { return $cur }
  if ([string]$cur.sha -cne [string]$ExpectedSha) {
    return @{ ok = $false; conflict = $true; sha = [string]$cur.sha; error = '他の変更と競合しました（409）。再取得してください。' }
  }
  # Re-check after the fetch: a settings change during the request must not
  # retarget the commit that Set-GitHubFile resolves from the current settings.
  if (-not (Test-GitHubRuleSaveOrigin $AutoDir $k $ExpectedRepo $ExpectedBranch $ExpectedPath)) { return $originConflict }
  $s = Get-GitHubSettings $AutoDir
  $rel = Get-GitHubRuleRelPath ([string]$s.rulesPath) $k
  $put = Set-GitHubFile $AutoDir $rel ([string]$Text) ([string]$ExpectedSha) ('chore: update ' + $k + ' rule')
  if (-not $put.ok) { return $put }
  return @{ ok = $true; sha = [string]$put.sha; path = $rel; kind = $k; repo = [string]$s.repo; branch = [string]$s.branch }
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
    # The rewrite repairs quoting but must never commit a file the validator
    # rejects (duplicate/unsupported slugs in the fetched text).
    if (-not (Test-GitHubRuleFrontmatter ([string]$upd.text) $name)) {
      $msg = '更新後のfrontmatterが不正です。'
      if ($fail -eq '') { $fail = ($msg + ' (' + $name + '.md)') }
      $files += @{ name = $name; path = $rel; added = @(); ok = $false; error = $msg }
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
