# Extension-Management.ps1 - Global MCP / skills / plugins inventory and safe edits.
# Dot-sourced by Dashboard-Server.ps1. No listen, no external commands, no MCP
# execution, no package installation.
#
# Official sources used for the file formats:
#   Codex       ~/.codex/config.toml ([mcp_servers.<name>], enabled, http_headers)
#               ~/.agents/skills/<name>/SKILL.md
#   OpenCode    ~/.config/opencode/opencode.json (or opencode.jsonc; both are
#               edited as text so comments and unknown keys survive)
#               ~/.config/opencode/skills/<name>/SKILL.md
#               ~/.config/opencode/plugins/
#   Claude Code ~/.claude.json (user-scope mcpServers)
#               ~/.claude/skills/<name>/SKILL.md
#               ~/.claude/settings.json (enabledPlugins, skillOverrides)
#
# Writes are add-only or a documented enabled toggle. Every write is previewed,
# hash-checked, backed up, and atomically published. Comments and unknown keys
# are preserved by editing the JSON text and appending TOML tables instead of
# re-serializing whole files.
$ErrorActionPreference = 'Stop'

if (-not (Get-Variable -Name ExtensionPreviews -Scope Script -ErrorAction SilentlyContinue)) {
  $script:ExtensionPreviews = @{}
}

function Get-ExtensionProviderDefs {
  return @(
    [pscustomobject]@{
      id = 'codex'; label = 'Codex'; order = 0
      configRel = '.codex\config.toml'; configKind = 'toml'
      skillsRel = '.agents\skills'; skillDirs = @('.agents\skills')
      pluginReason = 'プラグインは公式のプラグイン管理（Codex の Plugins / $plugin-installer）で追加・削除してください。'
    },
    [pscustomobject]@{
      id = 'opencode'; label = 'OpenCode'; order = 1
      configRel = '.config\opencode\opencode.json'; configKind = 'json'
      skillsRel = '.config\opencode\skills'; skillDirs = @('.config\opencode\skills', '.claude\skills', '.agents\skills')
      pluginReason = 'プラグインは公式の設定（opencode.json の plugin 配列）または plugins フォルダで管理してください。この画面からは変更しません。'
    },
    [pscustomobject]@{
      id = 'claudecode'; label = 'Claude Code'; order = 2
      configRel = '.claude.json'; configKind = 'json'
      skillsRel = '.claude\skills'; skillDirs = @('.claude\skills')
      pluginReason = 'プラグインは公式の /plugin または claude plugin コマンドで管理してください。この画面からは変更しません。'
    }
  )
}

function Get-ExtensionProviderDef([string]$Id) {
  foreach ($d in @(Get-ExtensionProviderDefs)) {
    if ([string]$d.id -ceq $Id) { return $d }
  }
  return $null
}

function Get-ExtensionProviderLabel([string]$Id) {
  $d = Get-ExtensionProviderDef $Id
  if ($d) { return [string]$d.label }
  return $Id
}

function Ext-NormPath([string]$P) { return [System.IO.Path]::GetFullPath(($P -replace '/', '\')) }

function Ext-Contained([string]$Candidate, [string]$Root) {
  $c = Ext-NormPath $Candidate
  $r = Ext-NormPath $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

function Ext-Reparse([string]$P) {
  try {
    $it = Get-Item -LiteralPath $P -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $false }
    return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  } catch { return $false }
}

function Ext-RootCanonical([string]$P) {
  $p = Ext-NormPath $P
  if ($p -match '^[A-Za-z]:\\$') { return $p }
  return $p.TrimEnd('\')
}

function Ext-AssertNoLinkChain([string]$File, [string]$Root, [string]$What) {
  if ([string]::IsNullOrWhiteSpace($Root)) { throw ($What + 'の基準フォルダを確認できませんでした。') }
  $rootN = Ext-RootCanonical $Root
  $fileN = Ext-NormPath $File
  if (Ext-Reparse $rootN) { throw ($What + 'の基準フォルダがリンクになっています。') }
  if (($fileN -ine $rootN) -and (-not (Ext-Contained $fileN $rootN))) { throw ($What + 'が基準フォルダの外にあります。') }
  $cur = $fileN
  $guard = 0
  while ($guard -lt 64) {
    if (Ext-Reparse $cur) { throw ($What + 'がリンクになっています。') }
    if ($cur -ieq $rootN) { break }
    $parent = Split-Path $cur -Parent
    if ((-not $parent) -or ($parent -ieq $cur)) { break }
    $cur = Ext-RootCanonical $parent
    $guard++
  }
}

function Ext-HashBytes([byte[]]$Bytes) {
  $h = [System.Security.Cryptography.SHA256]::Create()
  try { return ((($h.ComputeHash($Bytes)) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $h.Dispose() }
}

function Ext-HashFile([string]$File) {
  try {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    return (Ext-HashBytes ([System.IO.File]::ReadAllBytes($File)))
  } catch { return $null }
}

function Ext-MaxConfigBytes { return 4194304 }
function Ext-MaxSkillBytes { return 65536 }

function Get-ExtensionFileInfo([string]$File) {
  $r = @{ exists = $false; link = $false; bytes = $null; text = ''; hash = $null; encoding = 'utf8'; bom = $false; newline = "`r`n"; error = ''; size = 0 }
  try {
    if (-not (Test-Path -LiteralPath $File)) { return $r }
    if (Ext-Reparse $File) { $r.link = $true; $r.error = 'リンクのため読み取りません。'; return $r }
    $len = (Get-Item -LiteralPath $File -Force -ErrorAction Stop).Length
    $r.size = [int][Math]::Min($len, [long][int]::MaxValue)
    if ($len -gt (Ext-MaxConfigBytes)) { $r.error = '設定ファイルが大きすぎるため読み取りません。'; return $r }
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $r.exists = $true
    $r.bytes = $bytes
    $r.hash = Ext-HashBytes $bytes
    if (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) {
      $r.encoding = 'utf8'; $r.bom = $true
      $r.text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, 3, ($bytes.Length - 3))
    } elseif (($bytes.Length -ge 2) -and ($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE)) {
      $r.encoding = 'unicode'; $r.bom = $true
      $r.text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, ($bytes.Length - 2))
    } elseif (($bytes.Length -ge 2) -and ($bytes[0] -eq 0xFE) -and ($bytes[1] -eq 0xFF)) {
      $r.encoding = 'bigendianunicode'; $r.bom = $true
      $r.text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, ($bytes.Length - 2))
    } else {
      $r.encoding = 'utf8'
      $r.text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    if ($r.text.IndexOf("`r`n") -ge 0) { $r.newline = "`r`n" } else { $r.newline = "`n" }
    return $r
  } catch {
    $r.error = '設定ファイルを読み取れませんでした。'
    return $r
  }
}

function Ext-SafeFileInfo([string]$File, [string]$HomeBase) {
  try { Ext-AssertNoLinkChain $File $HomeBase '設定ファイル' } catch {
    return @{ exists = $false; link = $true; bytes = $null; text = ''; hash = $null; encoding = 'utf8'; bom = $false; newline = "`r`n"; error = '設定の配置先を確認できませんでした。'; size = 0 }
  }
  return (Get-ExtensionFileInfo $File)
}

function Ext-EncodeText([string]$Text, $Info) {
  $enc = 'utf8'; $bom = $false
  if ($Info) { try { $enc = [string]$Info.encoding; $bom = [bool]$Info.bom } catch {} }
  if ($enc -eq 'unicode') { return [System.Text.Encoding]::Unicode.GetBytes($Text) }
  if ($enc -eq 'bigendianunicode') { return [System.Text.Encoding]::BigEndianUnicode.GetBytes($Text) }
  $body = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
  if (-not $bom) { return $body }
  $out = New-Object byte[] ($body.Length + 3)
  $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
  if ($body.Length -gt 0) { [System.Buffer]::BlockCopy($body, 0, $out, 3, $body.Length) }
  return $out
}

# Every value can appear raw, JSON-escaped, TOML-escaped, or wrapped in either
# quote style. Match the longest form first so an escaped value is never left
# half-replaced. Short plain raw values are skipped to keep the diff readable;
# their quoted forms are still redacted. A short value containing punctuation
# keeps its raw form because JSON serializers may escape those characters.
function Ext-RedactForms([string]$Value) {
  $v = [string]$Value
  if ($v.Length -eq 0) { return @() }
  $forms = @($v)
  try {
    $j = Ext-JsonQuote $v
    if (($j.Length -ge 2) -and ($j[0] -eq [char]'"') -and ($j[$j.Length - 1] -eq [char]'"')) {
      $jb = $j.Substring(1, ($j.Length - 2))
      $forms += $jb
      # JSON allows escaping "/" as "\/"; match that serialization too.
      if ($jb.IndexOf([char]'/') -ge 0) { $forms += $jb.Replace('/', '\/') }
    }
  } catch {}
  try {
    $t = Ext-TomlQuote $v
    if (($t.Length -ge 2) -and ($t[0] -eq [char]'"') -and ($t[$t.Length - 1] -eq [char]'"')) { $forms += $t.Substring(1, ($t.Length - 2)) }
  } catch {}
  $forms += ('"' + $v + '"')
  $forms += ("'" + $v + "'")
  return @($forms | Select-Object -Unique | Sort-Object -Property Length -Descending)
}

function Ext-RedactValues([string]$Text, $Values, [int]$MinRawLength) {
  $r = [string]$Text
  $forms = @()
  $entries = @()
  foreach ($item in @($Values)) {
    if ($null -eq $item) { continue }
    $sv = [string]$item
    if ($sv.Length -eq 0) { continue }
    $dq = '"' + $sv + '"'
    $sq = "'" + $sv + "'"
    foreach ($f in @(Ext-RedactForms $sv)) {
      $form = [string]$f
      if ($form.Length -eq 0) { continue }
      if (($form -ceq $sv) -and ($sv.Length -lt $MinRawLength)) {
        # Keep punctuation values so HTML-escaped JSON forms still match, but
        # never emit a raw form containing a quote or backslash: those always
        # appear escaped and a raw match could consume a JSON delimiter.
        if (($sv.Length -lt 3) -or ($sv -match '^[A-Za-z0-9_-]+$') -or ($sv.IndexOf([char]'"') -ge 0) -or ($sv.IndexOf([char]'\') -ge 0)) { continue }
      }
      if ($forms -ccontains $form) { continue }
      $out = '***'
      if ($form -ceq $dq) { $out = '"***"' }
      elseif ($form -ceq $sq) { $out = "'***'" }
      $forms += $form
      $entries += [pscustomobject]@{ form = $form; out = $out; len = $form.Length }
    }
  }
  foreach ($e in @($entries | Sort-Object -Property len -Descending)) {
    $r = $r.Replace([string]$e.form, [string]$e.out)
  }
  return $r
}

function Ext-Redact([string]$Text, [string]$Token, $ExtraSecrets = @(), $RawSecrets = @()) {
  $known = @()
  if ($Token) { $known += [string]$Token }
  if ($env:GITHUB_TOKEN) { $known += [string]$env:GITHUB_TOKEN }
  if ($env:GH_TOKEN) { $known += [string]$env:GH_TOKEN }
  $r = Ext-RedactValues ([string]$Text) $known 4
  # Configuration values are always quoted, so redact their quoted forms only.
  # Replacing a raw value such as "true" would also hit unrelated JSON literals.
  $extra = @()
  foreach ($x in @($ExtraSecrets)) { if ($x) { $extra += [string]$x } }
  $r = Ext-RedactValues $r $extra ([int]::MaxValue)
  # URL userinfo and query/fragment parts appear unquoted inside a URL string.
  $rawList = @()
  foreach ($x in @($RawSecrets)) { if ($x) { $rawList += [string]$x } }
  $r = Ext-RedactValues $r $rawList 4
  $q1 = '"***"'
  $q2 = "'***'"
  $r = [regex]::Replace($r, '(?i)(github_token|gh_token|bearer)([=:\s]+)"(?:[^"\\]|\\.)*"', '$1$2' + $q1)
  $r = [regex]::Replace($r, "(?i)(github_token|gh_token|bearer)([=:\s]+)'(?:[^']|'')*'", '$1$2' + $q2)
  $r = [regex]::Replace($r, '(?i)(github_token|gh_token|bearer)([=:\s]+)[^\s"'']+', '$1$2***')
  $r = [regex]::Replace($r, '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{8,}', '${1}_***')
  $r = [regex]::Replace($r, 'github_pat_[A-Za-z0-9_]{8,}', 'github_pat_***')
  $r = [regex]::Replace($r, '(?i)([?&](?:key|token|secret|password|auth|signature|sig|api[_-]?key|access[_-]?token)=)[^&\s"''<>]+', '$1***')
  $r = [regex]::Replace($r, '(?i)("?(?:token|secret|password|api[_-]?key|authorization)"?\s*[=:]\s*)"(?:[^"\\]|\\.)*"', '$1' + $q1)
  $r = [regex]::Replace($r, "(?i)(`"?(?:token|secret|password|api[_-]?key|authorization)`"?\s*[=:]\s*)'(?:[^']|'')*'", '$1' + $q2)
  $r = [regex]::Replace($r, '(?i)("?(?:token|secret|password|api[_-]?key|authorization)"?\s*[=:]\s*)[^\s,"'']+', '$1***')
  return $r
}

function Ext-SafeUrlDisplay([string]$Url) {
  $s = [string]$Url
  if ($s.Length -eq 0) { return '' }
  $u = $null
  try { $u = [System.Uri]::new($s) } catch { return '***' }
  if ((-not $u.IsAbsoluteUri) -or ([string]$u.Host -eq '')) { return '***' }
  $path = [string]$u.AbsolutePath
  $hasPath = (($path -ne '') -and ($path -ne '/'))
  if (([string]$u.UserInfo -eq '') -and (-not $hasPath) -and ($u.Query.Length -le 1) -and ($u.Fragment.Length -le 1)) { return $s }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($u.Scheme).Append('://').Append($u.Host)
  if (-not $u.IsDefaultPort) { [void]$sb.Append(':').Append($u.Port) }
  if ($hasPath) { [void]$sb.Append('/***') }
  if ($u.Query.Length -gt 1) { [void]$sb.Append('?***') }
  if ($u.Fragment.Length -gt 1) { [void]$sb.Append('#***') }
  return $sb.ToString()
}

function Ext-SimpleDiff([string[]]$Old, [string[]]$New) {
  $o = @($Old); $w = @($New)
  $pre = 0
  while (($pre -lt $o.Count) -and ($pre -lt $w.Count) -and ($o[$pre] -ceq $w[$pre])) { $pre++ }
  $suf = 0
  while (($suf -lt ($o.Count - $pre)) -and ($suf -lt ($w.Count - $pre)) -and ($o[$o.Count - 1 - $suf] -ceq $w[$w.Count - 1 - $suf])) { $suf++ }
  $lines = @()
  for ($i = $pre; $i -lt ($o.Count - $suf); $i++) { $lines += @{ t = '-'; text = [string]$o[$i] } }
  for ($i = $pre; $i -lt ($w.Count - $suf); $i++) { $lines += @{ t = '+'; text = [string]$w[$i] } }
  return @{ same = (($o.Count -eq $w.Count) -and ($pre -eq $o.Count)); lines = $lines; truncated = $false }
}

function Ext-Diff([string]$OldText, [string]$NewText, [string]$Token, $ExtraSecrets = @(), $RawSecrets = @()) {
  $d = $null
  if (Get-Command Global-DiffTextPair -ErrorAction SilentlyContinue) { $d = Global-DiffTextPair $OldText $NewText }
  else {
    $o = @(); $w = @()
    if ($null -ne $OldText) { $o = @($OldText -split "`r?`n") }
    if ($null -ne $NewText) { $w = @($NewText -split "`r?`n") }
    $d = Ext-SimpleDiff $o $w
  }
  $lines = @()
  foreach ($l in @($d.lines)) {
    $lines += @{ t = [string]$l.t; text = (Ext-Redact ([string]$l.text) $Token $ExtraSecrets $RawSecrets) }
  }
  return @{ same = [bool]$d.same; lines = $lines; truncated = [bool]$d.truncated }
}

# All MCP diffs are reduced to a structural summary. Raw TOML/JSON can contain
# command/args/env/header values whose syntax and escaping are too varied to
# mask safely, so only names, transport, key names, and enabled state are
# shown. The bytes written to disk still come from the real $after text.
function Ext-SafeMcpDiff([string]$Action, $V, $OldEnabled, [string]$RootLabel) {
  $lines = @()
  $name = [string]$V.name
  $root = [string]$RootLabel
  if ([string]::IsNullOrWhiteSpace($root)) { $root = 'mcp' }
  if ($Action -eq 'add') {
    $lines += @{ t = '+'; text = ('[' + $root + '.' + $name + ']') }
    $lines += @{ t = '+'; text = ('transport: ' + [string]$V.transport) }
    if ([string]$V.transport -eq 'remote') {
      $lines += @{ t = '+'; text = ('url: ' + (Ext-SafeUrlDisplay ([string]$V.url))) }
    } else {
      $lines += @{ t = '+'; text = 'command/args: hidden' }
    }
    $envKeys = @()
    foreach ($p in @($V.envPairs)) { if ([string]$p.key -ne '') { $envKeys += [string]$p.key } }
    $hdrKeys = @()
    foreach ($p in @($V.headerPairs)) { if ([string]$p.key -ne '') { $hdrKeys += [string]$p.key } }
    if ($envKeys.Count -gt 0) { $lines += @{ t = '+'; text = ('env keys: ' + ($envKeys -join ', ')) } }
    if ($hdrKeys.Count -gt 0) { $lines += @{ t = '+'; text = ('header keys: ' + ($hdrKeys -join ', ')) } }
  } else {
    $oldText = '?'
    if ($null -ne $OldEnabled) { $oldText = if ([bool]$OldEnabled) { 'true' } else { 'false' } }
    $newText = if ([bool]$V.enabled) { 'true' } else { 'false' }
    $lines += @{ t = '-'; text = ('[' + $root + '.' + $name + '] enabled: ' + $oldText) }
    $lines += @{ t = '+'; text = ('[' + $root + '.' + $name + '] enabled: ' + $newText) }
  }
  return @{ same = $false; lines = @($lines); truncated = $false }
}

function Ext-Field($Obj, [string]$Name, $Default = $null) {
  try {
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
  } catch {}
  return $Default
}

function Ext-StringArray($Value) {
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) {
    $sv = [string]$Value
    if ($sv.Trim().Length -eq 0) { return @() }
    return @($sv)
  }
  $out = @()
  try {
    foreach ($v in @($Value)) { if ($null -ne $v) { $out += [string]$v } }
  } catch {}
  return $out
}

# --- JSON / JSONC text editing ------------------------------------------------
# These helpers edit the original text in place so comments, key order, and
# unrelated formatting survive. They are not a general JSON parser: callers
# validate the result with ConvertFrom-ExtensionJsonc before a write.

function Ext-JsonSkipTrivia([string]$T, [int]$I) {
  $n = $T.Length
  while ($I -lt $n) {
    $c = $T[$I]
    if ([char]::IsWhiteSpace($c)) { $I++; continue }
    if (($c -eq [char]'/') -and (($I + 1) -lt $n) -and ($T[$I + 1] -eq [char]'/')) {
      $I += 2
      while (($I -lt $n) -and ($T[$I] -ne [char]"`n") -and ($T[$I] -ne [char]"`r")) { $I++ }
      continue
    }
    if (($c -eq [char]'/') -and (($I + 1) -lt $n) -and ($T[$I + 1] -eq [char]'*')) {
      $e = $T.IndexOf('*/', $I + 2, [System.StringComparison]::Ordinal)
      if ($e -lt 0) { return $n }
      $I = $e + 2
      continue
    }
    break
  }
  return $I
}

function Ext-JsonStringEnd([string]$T, [int]$I) {
  $n = $T.Length
  $I++
  while ($I -lt $n) {
    $c = $T[$I]
    if ($c -eq [char]'\') { $I += 2; continue }
    if ($c -eq [char]'"') { return ($I + 1) }
    $I++
  }
  return $n
}

function Ext-JsonValueEnd([string]$T, [int]$I) {
  $I = Ext-JsonSkipTrivia $T $I
  $n = $T.Length
  if ($I -ge $n) { return $I }
  $c = $T[$I]
  if ($c -eq [char]'"') { return (Ext-JsonStringEnd $T $I) }
  if (($c -eq [char]'{') -or ($c -eq [char]'[')) {
    $depth = 0
    while ($I -lt $n) {
      $I = Ext-JsonSkipTrivia $T $I
      if ($I -ge $n) { break }
      $ch = $T[$I]
      if ($ch -eq [char]'"') { $I = Ext-JsonStringEnd $T $I; continue }
      if (($ch -eq [char]'{') -or ($ch -eq [char]'[')) { $depth++; $I++; continue }
      if (($ch -eq [char]'}') -or ($ch -eq [char]']')) {
        $depth--
        $I++
        if ($depth -le 0) { return $I }
        continue
      }
      $I++
    }
    return $I
  }
  while ($I -lt $n) {
    $ch = $T[$I]
    if ([char]::IsWhiteSpace($ch) -or ($ch -eq [char]',') -or ($ch -eq [char]'}') -or ($ch -eq [char]']')) { break }
    if (($ch -eq [char]'/') -and (($I + 1) -lt $n) -and (($T[$I + 1] -eq [char]'/') -or ($T[$I + 1] -eq [char]'*'))) { break }
    $I++
  }
  return $I
}

function Ext-JsonRootStart([string]$T) {
  $i = Ext-JsonSkipTrivia $T 0
  if (($i -ge $T.Length) -or ($T[$i] -ne [char]'{')) { throw '設定のJSON構造を確認できませんでした。' }
  return $i
}

function Ext-JsonFindProps([string]$T, [int]$ObjStart, [string]$Name) {
  $i = Ext-JsonSkipTrivia $T $ObjStart
  if (($i -ge $T.Length) -or ($T[$i] -ne [char]'{')) { throw '設定のJSON構造を確認できませんでした。' }
  $n = $T.Length
  $i++
  $found = @()
  while ($i -lt $n) {
    $i = Ext-JsonSkipTrivia $T $i
    if ($i -ge $n) { break }
    if ($T[$i] -eq [char]'}') { break }
    if ($T[$i] -ne [char]'"') { throw '設定のJSON構造を確認できませんでした。' }
    $keyStart = $i
    $keyEnd = Ext-JsonStringEnd $T $i
    $keyRaw = $T.Substring($keyStart, ($keyEnd - $keyStart))
    $key = ''
    try { $key = [string](ConvertFrom-Json $keyRaw) } catch { throw '設定のJSONキーを読み取れませんでした。' }
    $i = Ext-JsonSkipTrivia $T $keyEnd
    if (($i -ge $n) -or ($T[$i] -ne [char]':')) { throw '設定のJSON構造を確認できませんでした。' }
    $i++
    $valStart = Ext-JsonSkipTrivia $T $i
    $valEnd = Ext-JsonValueEnd $T $valStart
    if ($key -ceq $Name) { $found += @{ keyStart = $keyStart; valueStart = $valStart; valueEnd = $valEnd } }
    $i = Ext-JsonSkipTrivia $T $valEnd
    if (($i -lt $n) -and ($T[$i] -eq [char]',')) { $i++; continue }
    break
  }
  return @($found)
}

function Ext-JsonQuote([string]$S) {
  return (ConvertTo-Json -InputObject ([string]$S) -Compress)
}

function Ext-JsonPropInsert([string]$T, [int]$ObjStart, [string]$Name, [string]$ValueJson) {
  $i = Ext-JsonSkipTrivia $T $ObjStart
  if (($i -ge $T.Length) -or ($T[$i] -ne [char]'{')) { throw '設定のJSON構造を確認できませんでした。' }
  $nl = "`n"
  if ($T.IndexOf("`r`n") -ge 0) { $nl = "`r`n" }
  $multi = ($T.IndexOf("`n") -ge 0)
  $lineStart = $T.LastIndexOf("`n", $ObjStart)
  if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
  $baseIndent = ''
  if ($lineStart -lt $ObjStart) {
    $prefix = $T.Substring($lineStart, ($ObjStart - $lineStart))
    $m = [regex]::Match($prefix, '^[ \t]*')
    if ($m.Success) { $baseIndent = $m.Value }
  }
  $indent = $baseIndent + '  '
  $j = Ext-JsonSkipTrivia $T ($ObjStart + 1)
  $empty = (($j -lt $T.Length) -and ($T[$j] -eq [char]'}'))
  $prop = (Ext-JsonQuote $Name) + ': ' + $ValueJson
  if ($multi) {
    if ($empty) { $ins = $nl + $indent + $prop + $nl + $baseIndent }
    else { $ins = $nl + $indent + $prop + ',' }
  } else {
    if ($empty) { $ins = $prop }
    else { $ins = $prop + ',' }
  }
  return $T.Insert($ObjStart + 1, $ins)
}

function Ext-JsonPropSetBool([string]$T, [int]$ObjStart, [string]$Name, [bool]$Value) {
  $props = @(Ext-JsonFindProps $T $ObjStart $Name)
  $lit = if ($Value) { 'true' } else { 'false' }
  if ($props.Count -gt 1) { throw '同じキーが複数あるため変更しません。' }
  if ($props.Count -eq 1) {
    $p = $props[0]
    return $T.Substring(0, $p.valueStart) + $lit + $T.Substring($p.valueEnd)
  }
  return (Ext-JsonPropInsert $T $ObjStart $Name $lit)
}

function Ext-JsonStripComments([string]$T) {
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  $n = $T.Length
  while ($i -lt $n) {
    $c = $T[$i]
    if ($c -eq [char]'"') {
      $e = Ext-JsonStringEnd $T $i
      [void]$sb.Append($T.Substring($i, ($e - $i)))
      $i = $e
      continue
    }
    if (($c -eq [char]'/') -and (($i + 1) -lt $n) -and ($T[$i + 1] -eq [char]'/')) {
      while (($i -lt $n) -and ($T[$i] -ne [char]"`n") -and ($T[$i] -ne [char]"`r")) { $i++ }
      continue
    }
    if (($c -eq [char]'/') -and (($i + 1) -lt $n) -and ($T[$i + 1] -eq [char]'*')) {
      $e = $T.IndexOf('*/', $i + 2, [System.StringComparison]::Ordinal)
      if ($e -lt 0) { $i = $n; continue }
      $i = $e + 2
      continue
    }
    [void]$sb.Append($c)
    $i++
  }
  return $sb.ToString()
}

function Ext-JsonStripTrailingCommas([string]$T) {
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  $n = $T.Length
  while ($i -lt $n) {
    $c = $T[$i]
    if ($c -eq [char]'"') {
      $e = Ext-JsonStringEnd $T $i
      [void]$sb.Append($T.Substring($i, ($e - $i)))
      $i = $e
      continue
    }
    if ($c -eq [char]',') {
      $j = Ext-JsonSkipTrivia $T ($i + 1)
      if (($j -lt $n) -and (($T[$j] -eq [char]'}') -or ($T[$j] -eq [char]']'))) {
        $i++
        continue
      }
    }
    [void]$sb.Append($c)
    $i++
  }
  return $sb.ToString()
}

function Ext-JsonHasComments([string]$Text) {
  $t = [string]$Text
  return ((Ext-JsonStripComments $t) -cne $t)
}

function Ext-JsonHasTrailingComma([string]$Text) {
  $t = Ext-JsonStripComments ([string]$Text)
  return ((Ext-JsonStripTrailingCommas $t) -cne $t)
}

function ConvertFrom-ExtensionJsonc([string]$Text) {
  $t = Ext-JsonStripComments $Text
  $t = Ext-JsonStripTrailingCommas $t
  try { return ($t | ConvertFrom-Json) }
  catch { throw '設定のJSONを解析できませんでした。' }
}

function Ext-JsonHasProp($Obj, [string]$Name) {
  try { return ($null -ne $Obj.PSObject.Properties[$Name]) } catch { return $false }
}

function Ext-JsonGetProp($Obj, [string]$Name) {
  try {
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
  } catch {}
  return $null
}

# --- TOML helpers -------------------------------------------------------------

function Ext-TomlQuote([string]$S) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in ([string]$S).ToCharArray()) {
    $code = [int][char]$ch
    if ($ch -eq [char]'\') { [void]$sb.Append('\\') }
    elseif ($ch -eq [char]'"') { [void]$sb.Append('\"') }
    elseif ($ch -eq [char]"`b") { [void]$sb.Append('\b') }
    elseif ($ch -eq [char]"`t") { [void]$sb.Append('\t') }
    elseif ($ch -eq [char]"`n") { [void]$sb.Append('\n') }
    elseif ($ch -eq [char]"`f") { [void]$sb.Append('\f') }
    elseif ($ch -eq [char]"`r") { [void]$sb.Append('\r') }
    elseif (($code -lt 0x20) -or ($code -eq 0x7F)) { [void]$sb.Append(('\u{0:X4}' -f $code)) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Ext-TomlUnquote([string]$S) {
  $v = [string]$S
  if ($v.Length -lt 2) { return $v }
  if (($v[0] -eq [char]'"') -and ($v[$v.Length - 1] -eq [char]'"')) {
    $sb = New-Object System.Text.StringBuilder
    $i = 1
    $n = $v.Length - 1
    while ($i -lt $n) {
      $c = $v[$i]
      if (($c -ne [char]'\') -or (($i + 1) -ge $n)) { [void]$sb.Append($c); $i++; continue }
      $e = $v[$i + 1]
      if ($e -eq [char]'b') { [void]$sb.Append("`b"); $i += 2 }
      elseif ($e -eq [char]'t') { [void]$sb.Append("`t"); $i += 2 }
      elseif ($e -eq [char]'n') { [void]$sb.Append("`n"); $i += 2 }
      elseif ($e -eq [char]'f') { [void]$sb.Append("`f"); $i += 2 }
      elseif ($e -eq [char]'r') { [void]$sb.Append("`r"); $i += 2 }
      elseif ($e -eq [char]'"') { [void]$sb.Append('"'); $i += 2 }
      elseif ($e -eq [char]'\') { [void]$sb.Append('\'); $i += 2 }
      elseif ($e -eq [char]'u') {
        if (($i + 5) -lt $v.Length) {
          $hex = $v.Substring($i + 2, 4)
          try { [void]$sb.Append([char][Convert]::ToInt32($hex, 16)); $i += 6 } catch { [void]$sb.Append($e); $i += 2 }
        } else { [void]$sb.Append($e); $i += 2 }
      } else { [void]$sb.Append($e); $i += 2 }
    }
    return $sb.ToString()
  }
  if (($v[0] -eq [char]"'") -and ($v[$v.Length - 1] -eq [char]"'")) {
    # TOML literal strings have no escape sequences; keep the content as-is.
    return $v.Substring(1, ($v.Length - 2))
  }
  return $v
}

function Ext-TomlStringValue([string]$Raw) {
  $m = [regex]::Match([string]$Raw, '^\s*("(?:[^"\\]|\\.)*"|''[^'']*'')')
  if (-not $m.Success) { return $null }
  return (Ext-TomlUnquote $m.Groups[1].Value)
}

function Ext-TomlHeaderInfo([string]$Line) {
  $m = [regex]::Match($Line, '^\s*\[\s*mcp_servers\s*\.\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)''|([A-Za-z0-9_-]+))\s*(?:\.\s*([^\]]*?))?\s*\]\s*(?:#.*)?$')
  if ($m.Success) {
    $name = ''
    if ($m.Groups[1].Success) { $name = Ext-TomlUnquote ('"' + $m.Groups[1].Value + '"') }
    elseif ($m.Groups[2].Success) { $name = Ext-TomlUnquote ("'" + $m.Groups[2].Value + "'") }
    else { $name = $m.Groups[3].Value }
    $sub = ''
    if ($m.Groups[4].Success) {
      $sub = $m.Groups[4].Value.Trim()
      if (($sub.Length -ge 2) -and ((($sub[0] -eq [char]'"') -and ($sub[$sub.Length - 1] -eq [char]'"')) -or (($sub[0] -eq [char]"'") -and ($sub[$sub.Length - 1] -eq [char]"'")))) {
        $sub = Ext-TomlUnquote $sub
      }
    }
    return @{ kind = 'mcp'; name = $name; sub = $sub }
  }
  $m2 = [regex]::Match($Line, '^\s*\[\s*plugins\s*\.\s*(?:"((?:[^"\\]|\\.)*)"|''([^'']*)''|([A-Za-z0-9_.@-]+))\s*(?:\.\s*([^\]]*?))?\s*\]\s*(?:#.*)?$')
  if ($m2.Success) {
    $name2 = ''
    if ($m2.Groups[1].Success) { $name2 = Ext-TomlUnquote ('"' + $m2.Groups[1].Value + '"') }
    elseif ($m2.Groups[2].Success) { $name2 = Ext-TomlUnquote ("'" + $m2.Groups[2].Value + "'") }
    else { $name2 = $m2.Groups[3].Value }
    return @{ kind = 'plugin'; name = $name2; sub = '' }
  }
  if ([regex]::IsMatch($Line, '^\s*\[\[\s*skills\s*\.\s*config\s*\]\]\s*(?:#.*)?$')) { return @{ kind = 'skill'; name = ''; sub = '' } }
  if ([regex]::IsMatch($Line, '^\s*\[\s*mcp_servers\s*\]\s*(?:#.*)?$')) { return @{ kind = 'mcp_root'; name = ''; sub = '' } }
  if ([regex]::IsMatch($Line, '^\s*\[\[\s*mcp_servers(?:\s*\.|\s*\]\])')) { return @{ kind = 'mcp_root_array'; name = ''; sub = '' } }
  if ([regex]::IsMatch($Line, '^\s*\[\s*(?:"mcp_servers"|''mcp_servers'')\s*(?:\.|\])')) { return @{ kind = 'mcp_quoted_root'; name = ''; sub = '' } }
  if ([regex]::IsMatch($Line, '^\s*\[\[\s*(?:"mcp_servers"|''mcp_servers'')\s*(?:\.|\])')) { return @{ kind = 'mcp_quoted_root'; name = ''; sub = '' } }
  if ([regex]::IsMatch($Line, '^\s*\[')) { return @{ kind = 'other'; name = ''; sub = '' } }
  return $null
}

function Ext-ParseCodexToml([string]$Text) {
  $servers = @()
  $plugins = @()
  $skillConfigs = @()
  $subTables = @()
  $unsupported = $false
  $cur = $null
  $lines = @([regex]::Split([string]$Text, "`r?`n"))
  foreach ($line in $lines) {
    # Multiline strings can contain fake table headers; the line parser cannot
    # track their state, so refuse writes to any config containing one.
    if (($line.IndexOf('"""') -ge 0) -or ($line.IndexOf("'''") -ge 0)) { $unsupported = $true }
    $h = Ext-TomlHeaderInfo $line
    if ($null -ne $h) {
      if ($null -ne $cur) {
        if ($cur.kind -eq 'mcp') {
          if ([string]$cur.sub -eq '') { $servers += $cur }
          else { $subTables += $cur }
        }
        elseif ($cur.kind -eq 'skill') { $skillConfigs += $cur }
      }
      if ($h.kind -eq 'mcp') {
        $cur = @{ kind = 'mcp'; name = [string]$h.name; sub = [string]$h.sub; command = ''; url = ''; enabled = $null; enabledInvalid = $false; hasArgs = $false; envKeys = @(); headerKeys = @(); envValues = @(); headerValues = @() }
      } elseif ($h.kind -eq 'skill') {
        $cur = @{ kind = 'skill'; path = ''; enabled = $null }
      } elseif ($h.kind -eq 'plugin') {
        if ($plugins -cnotcontains [string]$h.name) { $plugins += [string]$h.name }
        $cur = $null
      } elseif ($h.kind -eq 'mcp_root') {
        $cur = @{ kind = 'mcp_root' }
      } elseif ($h.kind -eq 'mcp_root_array') {
        $unsupported = $true
        $cur = $null
      } elseif ($h.kind -eq 'mcp_quoted_root') {
        $unsupported = $true
        $cur = $null
      } else {
        $cur = $null
      }
      continue
    }
    if ($null -eq $cur) {
      # Top-level dotted or inline definitions of mcp_servers are valid TOML
      # but beyond this parser; fail closed so a write cannot duplicate them.
      if ($line -match '^\s*(?:"mcp_servers"|''mcp_servers''|mcp_servers)\s*[=.]') { $unsupported = $true }
      continue
    }
    if ($cur.kind -eq 'mcp') {
      # Dotted keys and inline tables are valid TOML but not understood here;
      # fail closed rather than write beside them or miss their secret values.
      $um = [regex]::Match($line, '^\s*(?:"(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+)\s*([.=])\s*(.*)$')
      if ($um.Success) {
        if (($um.Groups[1].Value -eq '.') -or (($um.Groups[1].Value -eq '=') -and ($um.Groups[2].Value.TrimStart().StartsWith('{')))) { $unsupported = $true }
      }
      if ($cur.sub -eq '') {
        if ($line -match '^\s*command\s*=\s*("(?:[^"\\]|\\.)*"|''[^'']*'')') { $cur.command = Ext-TomlUnquote $matches[1] }
        elseif ($line -match '^\s*url\s*=\s*("(?:[^"\\]|\\.)*"|''[^'']*'')') { $cur.url = Ext-TomlUnquote $matches[1] }
        elseif ($line -match '^\s*args\s*=') { $cur.hasArgs = $true }
        elseif ($line -match '^\s*enabled\s*=\s*(true|false)\b') { $cur.enabled = ($matches[1] -ceq 'true') }
        elseif ($line -match '^\s*enabled\s*=') { $cur.enabledInvalid = $true }
      } elseif ($cur.sub -eq 'env') {
        $em = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
        if ($em.Success) {
          $cur.envKeys += $em.Groups[1].Value
          $ev = Ext-TomlStringValue $em.Groups[2].Value
          if ($null -ne $ev) { $cur.envValues += [string]$ev }
        }
      } elseif ($cur.sub -eq 'http_headers') {
        $hm = [regex]::Match($line, '^\s*(?:"([^"]*)"|''([^'']*)''|([A-Za-z0-9_-]+))\s*=\s*(.*)$')
        if ($hm.Success) {
          if ($hm.Groups[1].Success) { $cur.headerKeys += $hm.Groups[1].Value }
          elseif ($hm.Groups[2].Success) { $cur.headerKeys += $hm.Groups[2].Value }
          else { $cur.headerKeys += $hm.Groups[3].Value }
          $hv = Ext-TomlStringValue $hm.Groups[4].Value
          if ($null -ne $hv) { $cur.headerValues += [string]$hv }
        }
      }
    } elseif ($cur.kind -eq 'mcp_root') {
      # Inline tables (name = { ... }) and dotted keys (name.command = ...)
      # define servers the table parser cannot merge safely.
      if ($line -match '^\s*(?:"(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+)\s*(?:=|\.)') { $unsupported = $true }
    } elseif ($cur.kind -eq 'skill') {
      if ($line -match '^\s*path\s*=\s*("(?:[^"\\]|\\.)*"|''[^'']*'')') { $cur.path = Ext-TomlUnquote $matches[1] }
      elseif ($line -match '^\s*enabled\s*=\s*(true|false)\b') { $cur.enabled = ($matches[1] -ceq 'true') }
    }
  }
  if ($null -ne $cur) {
    if ($cur.kind -eq 'mcp') {
      if ([string]$cur.sub -eq '') { $servers += $cur }
      else { $subTables += $cur }
    }
    elseif ($cur.kind -eq 'skill') { $skillConfigs += $cur }
  }
  # Sub-tables may appear before their parent table. Resolve them after the
  # whole file is read so env/http_headers are attached either way.
  foreach ($sd in @($subTables)) {
    $nm = [string]$sd.name
    $targetIdx = -1
    for ($si = $servers.Count - 1; $si -ge 0; $si--) {
      if (([string]$servers[$si].kind -eq 'mcp') -and ([string]$servers[$si].sub -eq '') -and ([string]$servers[$si].name -ceq $nm)) { $targetIdx = $si; break }
    }
    if ($targetIdx -ge 0) {
      $servers[$targetIdx].envKeys = @($servers[$targetIdx].envKeys) + @($sd.envKeys)
      $servers[$targetIdx].headerKeys = @($servers[$targetIdx].headerKeys) + @($sd.headerKeys)
      $servers[$targetIdx].envValues = @($servers[$targetIdx].envValues) + @($sd.envValues)
      $servers[$targetIdx].headerValues = @($servers[$targetIdx].headerValues) + @($sd.headerValues)
    } elseif (([string]$sd.sub -eq 'env') -or ([string]$sd.sub -eq 'http_headers')) {
      # An orphan sub-table still implies an MCP server table. Surface it so
      # duplicate adds are rejected and its secrets can be hidden in diffs.
      $servers += @{ kind = 'mcp'; name = $nm; sub = ''; command = ''; url = ''; enabled = $null; enabledInvalid = $false; hasArgs = $false; envKeys = @($sd.envKeys); headerKeys = @($sd.headerKeys); envValues = @($sd.envValues); headerValues = @($sd.headerValues) }
    }
  }
  $counts = @{}
  foreach ($s in $servers) {
    $k = [string]$s.name
    if ($counts.ContainsKey($k)) { $counts[$k] = $counts[$k] + 1 } else { $counts[$k] = 1 }
  }
  $out = @()
  foreach ($s in $servers) {
    $s['duplicate'] = ($counts[[string]$s.name] -gt 1)
    $enVal = $true
    if ($null -ne $s.enabled) { $enVal = [bool]$s.enabled }
    $s['enabled'] = $enVal
    $out += $s
  }
  return @{ servers = $out; plugins = @($plugins); skillConfigs = @($skillConfigs); unsupported = $unsupported }
}

function Ext-CodexAddMcp([string]$Text, [string]$Name, [string]$Transport, [string]$Command, $ArgList, [string]$Url, $EnvPairs, $HeaderPairs) {
  $parsed = Ext-ParseCodexToml $Text
  if ([bool]$parsed.unsupported) { throw '未対応のMCP定義（インラインテーブル/ドットキー/配列テーブル/引用符付きルート/複数行文字列）があるため変更しません。手動で修正してください。' }
  foreach ($s in @($parsed.servers)) {
    if ([string]$s.name -ceq $Name) { throw '同名のMCPサーバーが既にあります。' }
  }
  $nl = "`n"
  if ($Text.IndexOf("`r`n") -ge 0) { $nl = "`r`n" }
  $block = @()
  $block += ('[mcp_servers.' + $Name + ']')
  if ($Transport -eq 'remote') {
    $block += ('url = ' + (Ext-TomlQuote $Url))
  } else {
    $block += ('command = ' + (Ext-TomlQuote $Command))
    $av = @($ArgList)
    if ($av.Count -gt 0) {
      $quoted = @()
      foreach ($a in $av) { $quoted += (Ext-TomlQuote ([string]$a)) }
      $block += ('args = [' + ($quoted -join ', ') + ']')
    }
    $ev = @($EnvPairs)
    if ($ev.Count -gt 0) {
      $block += ''
      $block += ('[mcp_servers.' + $Name + '.env]')
      foreach ($p in $ev) { $block += (([string]$p.key) + ' = ' + (Ext-TomlQuote ([string]$p.value))) }
    }
  }
  if ($Transport -eq 'remote') {
    $hv = @($HeaderPairs)
    if ($hv.Count -gt 0) {
      $block += ''
      $block += ('[mcp_servers.' + $Name + '.http_headers]')
      foreach ($p in $hv) { $block += ((Ext-TomlQuote ([string]$p.key)) + ' = ' + (Ext-TomlQuote ([string]$p.value))) }
    }
  }
  $sep = ''
  if ($Text.Trim().Length -gt 0) {
    if ($Text.EndsWith("`n")) { $sep = $nl } else { $sep = $nl + $nl }
  }
  return ($Text + $sep + ($block -join $nl) + $nl)
}

function Ext-CodexToggleMcp([string]$Text, [string]$Name, [bool]$Enabled) {
  $parsedAll = Ext-ParseCodexToml $Text
  if ([bool]$parsedAll.unsupported) { throw '未対応のMCP定義（インラインテーブル/ドットキー/配列テーブル/引用符付きルート/複数行文字列）があるため変更しません。手動で修正してください。' }
  $lineMatches = @([regex]::Matches($Text, '(?m)^[^\r\n]*'))
  $match = @()
  for ($i = 0; $i -lt $lineMatches.Count; $i++) {
    $h = Ext-TomlHeaderInfo $lineMatches[$i].Value
    if (($null -ne $h) -and ($h.kind -eq 'mcp') -and ([string]$h.name -ceq $Name) -and ([string]$h.sub -eq '')) { $match += $i }
  }
  if ($match.Count -eq 0) { throw 'MCPサーバーが見つかりません。' }
  if ($match.Count -gt 1) { throw '同名のMCPテーブルが重複しているため変更しません。' }
  $start = $match[0]
  $end = $lineMatches.Count
  for ($j = $start + 1; $j -lt $lineMatches.Count; $j++) {
    if ($null -ne (Ext-TomlHeaderInfo $lineMatches[$j].Value)) { $end = $j; break }
  }
  $lit = if ($Enabled) { 'true' } else { 'false' }
  $found = -1
  for ($j = $start + 1; $j -lt $end; $j++) {
    if ($lineMatches[$j].Value -match '^\s*enabled\s*=\s*(true|false)(.*)$') { $found = $j; break }
  }
  if ($found -ge 0) {
    $lm = $lineMatches[$found]
    $m2 = [regex]::Match($lm.Value, '^(\s*enabled\s*=\s*)(true|false)(.*)$')
    $newLine = $m2.Groups[1].Value + $lit + $m2.Groups[3].Value
    return ($Text.Substring(0, $lm.Index) + $newLine + $Text.Substring($lm.Index + $lm.Length))
  }
  $header = $lineMatches[$start]
  $insertAt = $header.Index + $header.Length
  $suffix = $Text.Substring($insertAt)
  $nl = "`r`n"
  if ($suffix.StartsWith("`r`n")) { $nl = "`r`n" }
  elseif ($suffix.StartsWith("`n")) { $nl = "`n" }
  return ($Text.Substring(0, $insertAt) + $nl + 'enabled = ' + $lit + $suffix)
}

# --- provider state -----------------------------------------------------------

function Get-ExtensionConfigTarget([string]$HomeBase, [string]$Provider) {
  $homePath = Ext-NormPath $HomeBase
  if ($Provider -ceq 'codex') { return @{ path = (Join-Path $homePath '.codex\config.toml'); kind = 'toml' } }
  if ($Provider -ceq 'claudecode') { return @{ path = (Join-Path $homePath '.claude.json'); kind = 'json'; rootProp = 'mcpServers' } }
  if ($Provider -ceq 'opencode') {
    $j = Join-Path $homePath '.config\opencode\opencode.json'
    $c = Join-Path $homePath '.config\opencode\opencode.jsonc'
    if (Test-Path -LiteralPath $j -PathType Leaf) { return @{ path = $j; kind = 'json'; rootProp = 'mcp' } }
    if (Test-Path -LiteralPath $c -PathType Leaf) { return @{ path = $c; kind = 'jsonc'; rootProp = 'mcp' } }
    return @{ path = $j; kind = 'json'; rootProp = 'mcp' }
  }
  throw '対象のCLIが不正です。'
}

function Ext-EmptyProviderDetail {
  return @{ configured = $false; state = 'missing'; enabled = $null; transport = ''; target = ''; path = ''; canToggle = $false; error = ''; note = ''; envKeys = @(); headerKeys = @() }
}

function Get-ExtensionMcpProviderState([string]$HomeBase, [string]$Provider, [string]$Token) {
  $homePath = Ext-NormPath $HomeBase
  $target = Get-ExtensionConfigTarget $homePath $Provider
  $out = @{ provider = $Provider; path = [string]$target.path; exists = $false; error = ''; readable = $true; servers = @(); mcpWritable = $true; mcpWriteReason = ''; mcpToggle = $false; toggleReason = '' }
  if ($Provider -ceq 'codex') { $out.mcpToggle = $true }
  if ($Provider -ceq 'opencode') { $out.mcpToggle = $true }
  if ($Provider -ceq 'claudecode') {
    $out.mcpToggle = $false
    $out.toggleReason = '無効化は公式の /mcp パネルでプロジェクト単位に行います。'
  }
  try { Ext-AssertNoLinkChain $target.path $homePath '設定ファイル' }
  catch {
    $out.error = '設定の配置先を確認できませんでした。'
    $out.readable = $false
    $out.mcpWritable = $false
    $out.mcpWriteReason = $out.error
    return $out
  }
  $info = Ext-SafeFileInfo $target.path $homePath
  $out.exists = [bool]$info.exists
  $out.error = [string]$info.error
  $out.readable = ($info.error -eq '')
  if (-not $out.readable) {
    $out.mcpWritable = $false
    $out.mcpWriteReason = [string]$info.error
    return $out
  }
  if (-not $out.exists) { return $out }
  if (($Provider -ne 'codex') -and ([string]$target.kind -eq 'json')) {
    # Strict .json is refused when it already contains JSONC syntax; .jsonc is
    # the supported comment-preserving target.
    $jsonIssue = ''
    if (Ext-JsonHasComments ([string]$info.text)) { $jsonIssue = '既存のJSONにコメントがあるため変更しません。手動で修正してください。' }
    elseif (Ext-JsonHasTrailingComma ([string]$info.text)) { $jsonIssue = '既存のJSONに末尾カンマがあるため変更しません。手動で修正してください。' }
    if ($jsonIssue) {
      $out.mcpWritable = $false
      $out.mcpWriteReason = $jsonIssue
      if ($Provider -ceq 'opencode') {
        $out.mcpToggle = $false
        $out.toggleReason = $jsonIssue
      }
    }
  }
  if ($Provider -ceq 'codex') {
    $parsed = $null
    try { $parsed = Ext-ParseCodexToml $info.text } catch { $out.error = '設定を解析できませんでした。'; $out.mcpWritable = $false; $out.mcpWriteReason = $out.error; return $out }
    if ([bool]$parsed.unsupported) {
      $out.mcpWritable = $false
      $out.mcpWriteReason = '未対応のMCP定義（インラインテーブル/ドットキー/配列テーブル/引用符付きルート/複数行文字列）があるため変更しません。手動で修正してください。'
      $out.mcpToggle = $false
      $out.toggleReason = $out.mcpWriteReason
    }
    foreach ($s in @($parsed.servers)) {
      $d = Ext-EmptyProviderDetail
      $d.configured = $true
      $d.path = [string]$target.path
      $hasUrl = -not [string]::IsNullOrWhiteSpace([string]$s.url)
      $d.transport = if ($hasUrl) { 'remote' } else { 'stdio' }
      if ($hasUrl) { $d.target = Ext-SafeUrlDisplay ([string]$s.url) }
      else { $d.target = '***' }
      $d.envKeys = @($s.envKeys)
      $d.headerKeys = @($s.headerKeys)
      $d.canToggle = -not [bool]$parsed.unsupported
      if ([bool]$parsed.unsupported) { $d.note = [string]$out.mcpWriteReason }
      if ([bool]$s.duplicate) {
        $d.enabled = $null
        $d.state = 'invalid'
        $d.canToggle = $false
        $d.error = '同名のMCPテーブルが重複しています。'
      } elseif ([bool]$s.enabledInvalid) {
        $d.enabled = $null
        $d.state = 'invalid'
        $d.canToggle = $false
        $d.error = 'enabled が true/false ではありません。'
      } elseif ((-not $hasUrl) -and [string]::IsNullOrWhiteSpace([string]$s.command)) {
        $d.enabled = $null
        $d.state = 'invalid'
        $d.canToggle = $false
        $d.error = 'command または url がありません。'
      } else {
        $d.enabled = [bool]$s.enabled
        $d.state = if ([bool]$s.enabled) { 'enabled' } else { 'disabled' }
      }
      $out.servers += @{ name = [string]$s.name; detail = $d }
    }
    return $out
  }
  # JSON providers. JSONC comments are preserved because writes splice the
  # original text instead of re-serializing it.
  $obj = $null
  try { $obj = ConvertFrom-ExtensionJsonc $info.text } catch {
    $out.error = '設定を解析できませんでした。'
    $out.mcpWritable = $false
    $out.mcpWriteReason = $out.error
    return $out
  }
  $root = Ext-JsonGetProp $obj ([string]$target.rootProp)
  if ($null -eq $root) { return $out }
  if ($root -isnot [System.Management.Automation.PSCustomObject]) {
    $out.error = 'MCP設定の形式を確認できませんでした。'
    $out.mcpWritable = $false
    $out.mcpWriteReason = $out.error
    return $out
  }
  foreach ($p in @($root.PSObject.Properties)) {
    if ($null -eq $p) { continue }
    $sv = $p.Value
    $d = Ext-EmptyProviderDetail
    $d.configured = $true
    $d.path = [string]$target.path
    $d.canToggle = [bool]$out.mcpToggle
    $d.note = [string]$out.toggleReason
    if ($sv -isnot [System.Management.Automation.PSCustomObject]) {
      $d.state = 'invalid'
      $d.error = '設定の形式を確認できませんでした。'
      $out.servers += @{ name = [string]$p.Name; detail = $d }
      continue
    }
    $url = Ext-JsonGetProp $sv 'url'
    $cmd = Ext-JsonGetProp $sv 'command'
    $type = Ext-JsonGetProp $sv 'type'
    $cmdArr = @(Ext-StringArray $cmd)
    if (($cmdArr.Count -gt 0) -and ([string]$cmdArr[0]).Trim().Length -eq 0) { $cmdArr = @() }
    $hasUrl = -not [string]::IsNullOrWhiteSpace([string]$url)
    $hasCmd = ($cmdArr.Count -gt 0)
    $hasType = -not [string]::IsNullOrWhiteSpace([string]$type)
    $d.transport = if ($hasUrl) { 'remote' } elseif ($hasCmd) { 'stdio' } elseif ($hasType) { [string]$type } else { 'stdio' }
    if ($hasUrl) { $d.target = Ext-SafeUrlDisplay ([string]$url) }
    elseif ($hasCmd) { $d.target = '***' }
    if ((-not $hasUrl) -and (-not $hasCmd)) {
      $d.state = 'invalid'
      $d.error = 'command または url がありません。'
      $d.canToggle = $false
      $out.servers += @{ name = [string]$p.Name; detail = $d }
      continue
    }
    $envProp = Ext-JsonGetProp $sv 'environment'
    if ($null -eq $envProp) { $envProp = Ext-JsonGetProp $sv 'env' }
    if ($envProp -is [System.Management.Automation.PSCustomObject]) {
      $keys = @()
      foreach ($ep in @($envProp.PSObject.Properties)) { $keys += [string]$ep.Name }
      $d.envKeys = $keys
    }
    $hdrProp = Ext-JsonGetProp $sv 'headers'
    if ($hdrProp -is [System.Management.Automation.PSCustomObject]) {
      $hkeys = @()
      foreach ($hp in @($hdrProp.PSObject.Properties)) { $hkeys += [string]$hp.Name }
      $d.headerKeys = $hkeys
    }
    $en = $true
    if (Ext-JsonHasProp $sv 'enabled') {
      $ev = Ext-JsonGetProp $sv 'enabled'
      if ($ev -is [bool]) { $en = [bool]$ev }
      else {
        $d.enabled = $null
        $d.state = 'invalid'
        $d.error = 'enabled が true/false ではありません。'
        $d.canToggle = $false
        $out.servers += @{ name = [string]$p.Name; detail = $d }
        continue
      }
    }
    $d.enabled = $en
    $d.state = if ($en) { 'enabled' } else { 'disabled' }
    $out.servers += @{ name = [string]$p.Name; detail = $d }
  }
  return $out
}

function Ext-ParseSkillFrontmatter([string]$Text) {
  $t = [string]$Text
  # Compare by character code: culture-aware StartsWith treats U+FEFF as
  # ignorable and can return true for an ordinary string, stripping its first
  # character.
  if (($t.Length -gt 0) -and ([int][char]$t[0] -eq 0xFEFF)) { $t = $t.Substring(1) }
  $lines = @([regex]::Split($t, "`r?`n"))
  if (($lines.Count -lt 2) -or ($lines[0].Trim() -ne '---')) {
    return @{ ok = $false; name = ''; description = ''; error = 'frontmatter がありません。' }
  }
  $end = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { $end = $i; break }
  }
  if ($end -lt 0) { return @{ ok = $false; name = ''; description = ''; error = 'frontmatter が閉じていません。' } }
  $name = ''
  $desc = ''
  for ($i = 1; $i -lt $end; $i++) {
    $line = $lines[$i]
    $m = [regex]::Match($line, '^([A-Za-z0-9_-]+)[ \t]*:[ \t]*(.*)$')
    if (-not $m.Success) { continue }
    $k = $m.Groups[1].Value
    $v = $m.Groups[2].Value.Trim()
    $block = [regex]::Match($v, '^([|>])([0-9+-]{0,2})[ \t]*(?:#.*)?$')
    if ($block.Success) {
      # YAML block scalar (| literal, > folded; optional chomping/indent).
      $style = $block.Groups[1].Value
      $indicator = $block.Groups[2].Value
      $strip = $indicator.Contains('-')
      $keep = $indicator.Contains('+')
      $keyIndent = $line.Length - $line.TrimStart().Length
      $indentSize = 0
      $dm = [regex]::Match($indicator, '[0-9]')
      if ($dm.Success) { $indentSize = [int]$dm.Value }
      $blockIndent = -1
      if ($indentSize -gt 0) { $blockIndent = $keyIndent + $indentSize }
      $raw = @()
      $j = $i + 1
      while ($j -lt $end) {
        $bl = $lines[$j]
        $blank = ($bl.Trim().Length -eq 0)
        $ind = $bl.Length - $bl.TrimStart().Length
        if ((-not $blank) -and ($ind -le $keyIndent)) { break }
        if ((-not $blank) -and ($blockIndent -lt 0)) { $blockIndent = $ind }
        $raw += $bl
        $j++
      }
      $i = $j - 1
      if ($blockIndent -lt 0) { $blockIndent = $keyIndent + 1 }
      $content = @()
      foreach ($bl in $raw) {
        if ($bl.Length -ge $blockIndent) { $content += $bl.Substring($blockIndent) }
        else { $content += '' }
      }
      $kept = $content.Count
      while (($kept -gt 0) -and ($content[$kept - 1].Trim().Length -eq 0)) { $kept-- }
      $trailing = $content.Count - $kept
      if ($kept -gt 0) { $content = @($content[0..($kept - 1)]) } else { $content = @() }
      if ($style -eq '>') {
        $folded = ''
        $started = $false
        $breaks = 0
        $prevMore = $false
        foreach ($cl in $content) {
          if ($cl.Trim().Length -eq 0) { $breaks++; continue }
          $more = $cl.StartsWith(' ') -or $cl.StartsWith("`t")
          if (-not $started) { $folded = $cl; $started = $true; $breaks = 0; $prevMore = $more; continue }
          if ($breaks -gt 0) { $folded += (("`n") * $breaks) }
          elseif ($more -or $prevMore) { $folded += "`n" }
          else { $folded += ' ' }
          $folded += $cl
          $breaks = 0
          $prevMore = $more
        }
        if ($started) {
          if ($keep) { $folded += (("`n") * ($trailing + 1)) }
          elseif (-not $strip) { $folded += "`n" }
        }
        $v = $folded
      } else {
        $literal = ($content -join "`n")
        if ($content.Count -gt 0) {
          if ($keep) { $literal += (("`n") * ($trailing + 1)) }
          elseif (-not $strip) { $literal += "`n" }
        }
        $v = $literal
      }
    } else {
      # YAML comments start at whitespace + "#"; a quoted scalar keeps its "#".
      $dq = [regex]::Match($v, '^"((?:[^"\\]|\\.)*)"')
      $sq = [regex]::Match($v, "^'((?:[^']|'')*)'")
      if ($dq.Success) {
        $v = $dq.Groups[1].Value.Replace('\"', '"').Replace('\\', '\')
      } elseif ($sq.Success) {
        $v = $sq.Groups[1].Value.Replace("''", "'")
      } else {
        $v = [regex]::Replace($v, '(^|\s+)#.*$', '$1').TrimEnd()
      }
    }
    if ($k -ceq 'name') { $name = $v }
    elseif ($k -ceq 'description') { $desc = $v }
  }
  return @{ ok = $true; name = $name; description = $desc; error = '' }
}

function Get-ExtensionCodexSkillConfig([string]$HomeBase) {
  $homePath = Ext-NormPath $HomeBase
  $cfg = Get-ExtensionConfigTarget $homePath 'codex'
  $info = Ext-SafeFileInfo $cfg.path $homePath
  if ((-not $info.exists) -or ($info.error -ne '')) { return @() }
  try { return @((Ext-ParseCodexToml $info.text).skillConfigs) } catch { return @() }
}

function Get-ExtensionClaudeOverrides([string]$HomeBase) {
  $homePath = Ext-NormPath $HomeBase
  $p = Join-Path $homePath '.claude\settings.json'
  $info = Ext-SafeFileInfo $p $homePath
  if ((-not $info.exists) -or ($info.error -ne '')) { return @{} }
  try {
    $o = ConvertFrom-ExtensionJsonc $info.text
    $ov = Ext-JsonGetProp $o 'skillOverrides'
    $map = @{}
    if ($ov -is [System.Management.Automation.PSCustomObject]) {
      foreach ($pr in @($ov.PSObject.Properties)) { $map[[string]$pr.Name] = [string]$pr.Value }
    }
    return $map
  } catch { return @{} }
}

function Get-ExtensionSkillProviderState([string]$HomeBase, [string]$Provider, [string]$Token, $CodexSkillConfigs, $ClaudeOverrides) {
  $def = Get-ExtensionProviderDef $Provider
  $entries = @()
  $errors = @()
  $homePath = Ext-NormPath $HomeBase
  foreach ($rel in @($def.skillDirs)) {
    $dir = Join-Path $homePath $rel
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    try { Ext-AssertNoLinkChain $dir $homePath 'スキルの配置先' } catch { $errors += ('スキルの配置先を確認できません: ' + $rel); continue }
    $children = @()
    try { $children = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Select-Object -First 500) } catch { $errors += ('スキル一覧を取得できませんでした: ' + $rel); continue }
    foreach ($child in $children) {
      $file = Join-Path $child.FullName 'SKILL.md'
      if (Ext-Reparse $child.FullName) { $errors += ('スキルのフォルダがリンクです: ' + $child.Name); continue }
      try { Ext-AssertNoLinkChain $file $homePath 'スキル' } catch { $errors += ('スキルを確認できません: ' + $child.Name); continue }
      if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
      if (Ext-Reparse $file) { $errors += ('スキルがリンクです: ' + $child.Name); continue }
      $info = Ext-SafeFileInfo $file $homePath
      if ($info.size -gt (Ext-MaxSkillBytes)) {
        $entries += @{ name = [string]$child.Name; path = $file; dir = [string]$child.Name; description = ''; state = 'invalid'; valid = $false; duplicate = $false; warnings = @('SKILL.md が大きすぎます。'); sourceRel = $rel }
        continue
      }
      if ($info.error -ne '') {
        $entries += @{ name = [string]$child.Name; path = $file; dir = [string]$child.Name; description = ''; state = 'invalid'; valid = $false; duplicate = $false; warnings = @([string]$info.error); sourceRel = $rel }
        continue
      }
      $fm = Ext-ParseSkillFrontmatter $info.text
      $name = if ($fm.name) { [string]$fm.name } else { [string]$child.Name }
      $rawDesc = [string]$fm.description
      $desc = Ext-Redact $rawDesc $Token
      $warnings = @()
      $valid = $true
      if (-not $fm.ok) {
        if ($Provider -ceq 'claudecode') { $warnings += [string]$fm.error }
        else { $valid = $false; $warnings += [string]$fm.error }
      }
      $nameOk = ($name -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$') -and ($name.Length -ge 1) -and ($name.Length -le 64)
      if (-not $nameOk) { $valid = $false; $warnings += 'name は 1〜64 文字の英小文字・数字・単一ハイフンで指定してください。' }
      if ($Provider -ne 'claudecode') {
        if (-not $fm.name) { $valid = $false; $warnings += 'frontmatter の name がありません。' }
        elseif ([string]$fm.name -ine [string]$child.Name) { $valid = $false; $warnings += 'フォルダ名と name が一致しません。' }
        if (($rawDesc.Length -lt 1) -or ($rawDesc.Length -gt 1024)) { $valid = $false; $warnings += 'description は 1〜1024 文字で指定してください。' }
      } else {
        if ($rawDesc.Length -gt 1024) { $warnings += 'description が 1024 文字を超えています（一覧では短縮されます）。' }
        if ($rawDesc.Length -lt 1) { $warnings += 'description がありません。' }
      }
      $disabled = $false
      if ($Provider -ceq 'codex') {
        foreach ($sc in @($CodexSkillConfigs)) {
          if ([string]$sc.path -eq '') { continue }
          $scPath = ''
          try { $scPath = Ext-NormPath ([string]$sc.path) } catch { $scPath = [string]$sc.path }
          if (($scPath -ieq (Ext-NormPath $file)) -and ($sc.enabled -eq $false)) { $disabled = $true; break }
        }
      } elseif ($Provider -ceq 'claudecode') {
        if ($ClaudeOverrides.ContainsKey($name) -and ([string]$ClaudeOverrides[$name] -ceq 'off')) { $disabled = $true }
      }
      $state = 'enabled'
      if ($disabled) { $state = 'disabled' }
      elseif (-not $valid) { $state = 'invalid' }
      $entries += @{ name = $name; path = $file; dir = [string]$child.Name; description = $desc; state = $state; valid = $valid; duplicate = $false; warnings = $warnings; sourceRel = $rel }
    }
  }
  $counts = @{}
  foreach ($e in $entries) {
    $k = [string]$e.name
    if ($counts.ContainsKey($k)) { $counts[$k] = $counts[$k] + 1 } else { $counts[$k] = 1 }
  }
  foreach ($e in $entries) {
    if ($counts[[string]$e.name] -gt 1) {
      $e.duplicate = $true
      if ($e.state -eq 'enabled') { $e.state = 'duplicate' }
      $e.warnings = @($e.warnings) + @('同名のスキルが複数の場所にあります。')
    }
  }
  return @{ provider = $Provider; entries = @($entries); error = (@($errors | Select-Object -Unique) -join ' ') }
}

function Get-ExtensionPluginProviderState([string]$HomeBase, [string]$Provider) {
  $homePath = Ext-NormPath $HomeBase
  $items = @()
  $err = ''
  if ($Provider -ceq 'claudecode') {
    $p = Join-Path $homePath '.claude\settings.json'
    $info = Ext-SafeFileInfo $p $homePath
    if ($info.exists -and ($info.error -eq '')) {
      try {
        $o = ConvertFrom-ExtensionJsonc $info.text
        $ep = Ext-JsonGetProp $o 'enabledPlugins'
        if ($ep -is [System.Management.Automation.PSCustomObject]) {
          foreach ($pr in @($ep.PSObject.Properties)) {
            $en = ($pr.Value -eq $true)
            $st = 'disabled'
            if ($en) { $st = 'enabled' }
            $items += @{ name = [string]$pr.Name; state = $st; source = 'settings'; path = $p; note = '' }
          }
        }
      } catch { $err = 'プラグイン設定を解析できませんでした。' }
    } elseif ($info.error -ne '') { $err = [string]$info.error }
    return @{ provider = $Provider; items = @($items); error = $err }
  }
  if ($Provider -ceq 'opencode') {
    $cfg = Get-ExtensionConfigTarget $homePath 'opencode'
    $info = Ext-SafeFileInfo $cfg.path $homePath
    if ($info.exists -and ($info.error -eq '')) {
      try {
        $o = ConvertFrom-ExtensionJsonc $info.text
        $pl = Ext-JsonGetProp $o 'plugin'
        foreach ($v in @(Ext-StringArray $pl)) {
          if ($v) { $items += @{ name = $v; state = 'enabled'; source = 'npm'; path = [string]$cfg.path; note = '' } }
        }
      } catch { $err = 'プラグイン設定を解析できませんでした。' }
    } elseif ($info.error -ne '') { $err = [string]$info.error }
    $pdir = Join-Path $homePath '.config\opencode\plugins'
    if (Test-Path -LiteralPath $pdir -PathType Container) {
      $pdirOk = $true
      try { Ext-AssertNoLinkChain $pdir $homePath 'プラグイン配置先' } catch { $pdirOk = $false }
      if (-not $pdirOk) { $err = (@($err, 'プラグイン配置先を確認できません。') | Where-Object { $_ } ) -join ' ' }
      else {
        try {
          $files = @(Get-ChildItem -LiteralPath $pdir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.js', '.ts', '.mjs', '.cjs') } | Select-Object -First 200)
          foreach ($f in $files) { $items += @{ name = [string]$f.Name; state = 'enabled'; source = 'local'; path = [string]$f.FullName; note = '' } }
        } catch { $err = (@($err, 'プラグイン一覧を取得できませんでした。') | Where-Object { $_ }) -join ' ' }
      }
    }
    return @{ provider = $Provider; items = @($items); error = $err }
  }
  if ($Provider -ceq 'codex') {
    $cfg = Get-ExtensionConfigTarget $homePath 'codex'
    $info = Ext-SafeFileInfo $cfg.path $homePath
    if ($info.exists -and ($info.error -eq '')) {
      try {
        $parsed = Ext-ParseCodexToml $info.text
        foreach ($n in @($parsed.plugins)) { $items += @{ name = [string]$n; state = 'configured'; source = 'config'; path = [string]$cfg.path; note = '有効状態は公式のプラグイン管理で確認してください。' } }
      } catch { $err = 'プラグイン設定を解析できませんでした。' }
    } elseif ($info.error -ne '') { $err = [string]$info.error }
    return @{ provider = $Provider; items = @($items); error = $err }
  }
  return @{ provider = $Provider; items = @(); error = '対象のCLIが不正です。' }
}

function Ext-AddIndex($Index, [string]$Name, [string]$Provider, $Detail) {
  if (-not $Index.ContainsKey($Name)) { $Index[$Name] = @{ name = $Name; providers = @{} } }
  $item = $Index[$Name]
  if ($item.providers.ContainsKey($Provider)) {
    $prev = $item.providers[$Provider]
    $prev['duplicate'] = $true
    if ($Detail.path) {
      $paths = @($prev.path)
      if ($paths -cnotcontains [string]$Detail.path) { $paths += [string]$Detail.path }
      $prev['paths'] = $paths
    }
    if (([string]$Detail.state -eq 'invalid') -or ([string]$Detail.state -eq 'error')) { $prev['state'] = [string]$Detail.state }
    return
  }
  $item.providers[$Provider] = $Detail
}

function Ext-IndexToArray($Index) {
  $out = @()
  foreach ($k in @($Index.Keys)) { $out += $Index[$k] }
  return @($out | Sort-Object -Property { [string]$_.name })
}

function Ext-ProviderCount($Items, [string]$Provider) {
  $n = 0
  foreach ($it in @($Items)) {
    if ($it.providers.ContainsKey($Provider)) { $n++ }
  }
  return $n
}

function Assert-ExtensionHome([string]$HomeBase) {
  if ([string]::IsNullOrWhiteSpace($HomeBase)) { throw 'ホームフォルダを確認できませんでした。' }
  $h = Ext-NormPath $HomeBase
  if (-not (($h -match '^[A-Za-z]:\\') -or ($h -match '^\\\\'))) { throw 'ホームフォルダの絶対パスを確認できませんでした。' }
  if (-not (Test-Path -LiteralPath $h -PathType Container)) { throw 'ホームフォルダを確認できませんでした。' }
  if (Ext-Reparse $h) { throw 'ホームフォルダがリンクのため操作しません。' }
  return $h
}

function Get-ExtensionSnapshot([string]$AutoDir, [string]$HomeBase, [string]$Token) {
  $homePath = Assert-ExtensionHome $HomeBase
  $defs = @(Get-ExtensionProviderDefs)
  $mcpIndex = @{}
  $skillIndex = @{}
  $pluginIndex = @{}
  $providerInfo = @()
  $warnings = @()
  $codexSkillConfigs = @(Get-ExtensionCodexSkillConfig $homePath)
  $claudeOverrides = Get-ExtensionClaudeOverrides $homePath
  foreach ($d in $defs) {
    $cfg = Get-ExtensionConfigTarget $homePath ([string]$d.id)
    $info = Ext-SafeFileInfo $cfg.path $homePath
    $mcpState = Get-ExtensionMcpProviderState $homePath ([string]$d.id) $Token
    foreach ($s in @($mcpState.servers)) {
      Ext-AddIndex $mcpIndex ([string]$s.name) ([string]$d.id) $s.detail
    }
    $skillState = Get-ExtensionSkillProviderState $homePath ([string]$d.id) $Token $codexSkillConfigs $claudeOverrides
    foreach ($se in @($skillState.entries)) {
      $dsc = [string]$se.description
      if ($dsc.Length -gt 500) { $dsc = $dsc.Substring(0, 500) + '...' }
      Ext-AddIndex $skillIndex ([string]$se.name) ([string]$d.id) @{
        configured = $true; state = [string]$se.state; path = [string]$se.path; paths = @([string]$se.path)
        description = $dsc; warnings = @($se.warnings); duplicate = [bool]$se.duplicate; valid = [bool]$se.valid
        enabled = ($se.state -eq 'enabled'); error = ''
      }
    }
    $pluginState = Get-ExtensionPluginProviderState $homePath ([string]$d.id)
    foreach ($pi in @($pluginState.items)) {
      Ext-AddIndex $pluginIndex ([string]$pi.name) ([string]$d.id) @{
        configured = $true; state = [string]$pi.state; path = [string]$pi.path; paths = @([string]$pi.path)
        source = [string]$pi.source; note = [string]$pi.note; error = ''
      }
    }
    $writeReason = ''
    $mcpWritable = [bool]$mcpState.mcpWritable
    if (-not $mcpWritable) { $writeReason = [string]$mcpState.mcpWriteReason }
    $providerInfo += @{
      id = [string]$d.id; label = [string]$d.label
      configPath = [string]$cfg.path; configExists = [bool]$info.exists
      configError = [string]$info.error
      mcpWritable = $mcpWritable; mcpWriteReason = $writeReason
      mcpToggle = [bool]$mcpState.mcpToggle; mcpToggleReason = [string]$mcpState.toggleReason
      skillWritable = $true; pluginWritable = $false
      pluginReason = [string]$d.pluginReason
      skillDirs = @(@($d.skillDirs) | ForEach-Object { Join-Path $homePath ([string]$_) })
    }
    if ([string]$mcpState.error) { $warnings += ([string]$d.label + ': ' + [string]$mcpState.error) }
    if ((-not $mcpWritable) -and $writeReason) { $warnings += ([string]$d.label + ': ' + $writeReason) }
    if ([string]$skillState.error) { $warnings += ([string]$d.label + ': ' + [string]$skillState.error) }
    if ([string]$pluginState.error) { $warnings += ([string]$d.label + ': ' + [string]$pluginState.error) }
  }
  $mcpItems = @(Ext-IndexToArray $mcpIndex)
  $skillItems = @(Ext-IndexToArray $skillIndex)
  $pluginItems = @(Ext-IndexToArray $pluginIndex)
  return @{
    ok = $true; homeBase = $homePath; generatedAt = ([DateTime]::UtcNow.ToString('o'))
    providers = @($providerInfo)
    mcp = @($mcpItems); skills = @($skillItems); plugins = @($pluginItems)
    warnings = @($warnings | Select-Object -Unique)
    stats = @{
      mcp = @{ total = $mcpItems.Count; codex = (Ext-ProviderCount $mcpItems 'codex'); opencode = (Ext-ProviderCount $mcpItems 'opencode'); claudecode = (Ext-ProviderCount $mcpItems 'claudecode') }
      skills = @{ total = $skillItems.Count; codex = (Ext-ProviderCount $skillItems 'codex'); opencode = (Ext-ProviderCount $skillItems 'opencode'); claudecode = (Ext-ProviderCount $skillItems 'claudecode') }
      plugins = @{ total = $pluginItems.Count; codex = (Ext-ProviderCount $pluginItems 'codex'); opencode = (Ext-ProviderCount $pluginItems 'opencode'); claudecode = (Ext-ProviderCount $pluginItems 'claudecode') }
    }
    backups = @(Get-ExtensionBackupList $AutoDir $homePath)
  }
}

# --- request validation -------------------------------------------------------

function Ext-ParsePairs([string]$Lines, [string]$Separator, [string]$What) {
  $out = @()
  $seen = @{}
  foreach ($raw in @([regex]::Split([string]$Lines, "`r?`n"))) {
    $line = ([string]$raw).Trim()
    if ($line -eq '') { continue }
    $idx = $line.IndexOf($Separator)
    if ($idx -lt 1) { throw ($What + 'は「KEY' + $Separator + 'VALUE」の形式で1行に1つ指定してください。') }
    $k = $line.Substring(0, $idx).Trim()
    $v = $line.Substring($idx + $Separator.Length).Trim()
    if ($k -eq '') { throw ($What + 'のキーが空です。') }
    if ($seen.ContainsKey($k)) { throw ($What + 'のキーが重複しています: ' + $k) }
    if ($v.IndexOf([char]"`r") -ge 0 -or $v.IndexOf([char]"`n") -ge 0 -or $v.IndexOf([char]0) -ge 0) { throw ($What + 'の値に改行やNULは使えません。') }
    if ($v.Length -gt 4096) { throw ($What + 'の値が長すぎます。') }
    $seen[$k] = $true
    $out += @{ key = $k; value = $v }
  }
  if ($out.Count -gt 64) { throw ($What + 'は64件までです。') }
  return @($out)
}

function Ext-ValidateMcpRequest($Req) {
  $name = ([string](Ext-Field $Req 'name' '')).Trim()
  if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw '名前は英数字・ハイフン・アンダースコアで1〜64文字にしてください。' }
  $transport = ([string](Ext-Field $Req 'transport' 'stdio')).Trim().ToLowerInvariant()
  if (($transport -ne 'stdio') -and ($transport -ne 'remote')) { throw '接続方式が不正です。' }
  $command = ([string](Ext-Field $Req 'command' '')).Trim()
  $url = ([string](Ext-Field $Req 'url' '')).Trim()
  $argList = @(Ext-StringArray (Ext-Field $Req 'args' @()))
  $envPairs = @()
  $headerPairs = @()
  if ($transport -eq 'stdio') {
    if ($command -eq '') { throw 'コマンドを入力してください。' }
    if ($command.IndexOf([char]0) -ge 0 -or $command.IndexOf([char]"`r") -ge 0 -or $command.IndexOf([char]"`n") -ge 0) { throw 'コマンドに改行やNULは使えません。' }
    foreach ($a in $argList) {
      if ($a.IndexOf([char]0) -ge 0 -or $a.IndexOf([char]"`r") -ge 0 -or $a.IndexOf([char]"`n") -ge 0) { throw '引数に改行やNULは使えません。' }
      if ($a.Length -gt 2048) { throw '引数が長すぎます。' }
    }
    if ($argList.Count -gt 64) { throw '引数は64件までです。' }
    $envPairs = @(Ext-ParsePairs ([string](Ext-Field $Req 'envLines' '')) '=' '環境変数')
    foreach ($p in $envPairs) {
      if ($p.key -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw ('環境変数名が不正です: ' + $p.key) }
    }
  } else {
    if ($url -cnotmatch '^https?://[^\s]+$') { throw 'URL は http:// または https:// で始まる形式にしてください。' }
    if ($url.Length -gt 2048) { throw 'URL が長すぎます。' }
    $headerPairs = @(Ext-ParsePairs ([string](Ext-Field $Req 'headerLines' '')) ':' 'ヘッダー')
    foreach ($p in $headerPairs) {
      if ($p.key -cnotmatch '^[A-Za-z0-9!#$%&''*+.^_`|~-]+$') { throw ('ヘッダー名が不正です: ' + $p.key) }
    }
  }
  return @{ name = $name; transport = $transport; command = $command; args = @($argList); url = $url; envPairs = @($envPairs); headerPairs = @($headerPairs) }
}

function Ext-ValidateSkillRequest($Req) {
  $name = ([string](Ext-Field $Req 'name' '')).Trim()
  if ($name -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw 'スキル名は英小文字・数字・単一ハイフンで指定してください。' }
  if (($name.Length -lt 1) -or ($name.Length -gt 64)) { throw 'スキル名は1〜64文字にしてください。' }
  $desc = ([string](Ext-Field $Req 'description' '')).Trim()
  if ($desc.Length -lt 1) { throw '説明を入力してください。' }
  if ($desc.Length -gt 1024) { throw '説明は1024文字までにしてください。' }
  foreach ($ch in $desc.ToCharArray()) {
    $code = [int][char]$ch
    if (($code -lt 0x20) -or ($code -eq 0x7F)) { throw '説明に改行や制御文字は使えません。' }
  }
  $body = [string](Ext-Field $Req 'body' '')
  if ($body.IndexOf([char]0) -ge 0) { throw '本文にNULは使えません。' }
  if ($body.Length -gt 200000) { throw '本文が長すぎます。' }
  if ($body.TrimStart().StartsWith('---')) { throw '本文に frontmatter を含めないでください（自動生成します）。' }
  return @{ name = $name; description = $desc; body = $body }
}

function Ext-BuildSkillContent([string]$Name, [string]$Description, [string]$Body) {
  $d = ([string]$Description).Replace('\', '\\').Replace('"', '\"')
  $b = ([string]$Body).Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n").TrimEnd()
  $nl = "`r`n"
  $s = '---' + $nl + 'name: ' + $Name + $nl + 'description: "' + $d + '"' + $nl + '---' + $nl + $nl + $b + $nl
  return $s
}

function Ext-JsonBuildMcpValue([string]$Provider, [string]$Transport, [string]$Command, $ArgList, [string]$Url, $EnvPairs, $HeaderPairs) {
  $parts = @()
  if ($Provider -ceq 'opencode') {
    if ($Transport -eq 'remote') {
      $parts += '"type":"remote"'
      $parts += ('"url":' + (Ext-JsonQuote $Url))
      if (@($HeaderPairs).Count -gt 0) {
        $hs = @()
        foreach ($p in @($HeaderPairs)) { $hs += ((Ext-JsonQuote ([string]$p.key)) + ':' + (Ext-JsonQuote ([string]$p.value))) }
        $parts += ('"headers":{' + ($hs -join ',') + '}')
      }
      $parts += '"enabled":true'
    } else {
      $parts += '"type":"local"'
      $cs = @(Ext-JsonQuote ([string]$Command))
      foreach ($a in @($ArgList)) { $cs += (Ext-JsonQuote ([string]$a)) }
      $parts += ('"command":[' + ($cs -join ',') + ']')
      if (@($EnvPairs).Count -gt 0) {
        $es = @()
        foreach ($p in @($EnvPairs)) { $es += ((Ext-JsonQuote ([string]$p.key)) + ':' + (Ext-JsonQuote ([string]$p.value))) }
        $parts += ('"environment":{' + ($es -join ',') + '}')
      }
      $parts += '"enabled":true'
    }
    return ('{' + ($parts -join ',') + '}')
  }
  if ($Provider -ceq 'claudecode') {
    if ($Transport -eq 'remote') {
      $parts += '"type":"http"'
      $parts += ('"url":' + (Ext-JsonQuote $Url))
      if (@($HeaderPairs).Count -gt 0) {
        $hs = @()
        foreach ($p in @($HeaderPairs)) { $hs += ((Ext-JsonQuote ([string]$p.key)) + ':' + (Ext-JsonQuote ([string]$p.value))) }
        $parts += ('"headers":{' + ($hs -join ',') + '}')
      }
    } else {
      $parts += ('"command":' + (Ext-JsonQuote $Command))
      if (@($ArgList).Count -gt 0) {
        $cs = @()
        foreach ($a in @($ArgList)) { $cs += (Ext-JsonQuote ([string]$a)) }
        $parts += ('"args":[' + ($cs -join ',') + ']')
      }
      if (@($EnvPairs).Count -gt 0) {
        $es = @()
        foreach ($p in @($EnvPairs)) { $es += ((Ext-JsonQuote ([string]$p.key)) + ':' + (Ext-JsonQuote ([string]$p.value))) }
        $parts += ('"env":{' + ($es -join ',') + '}')
      }
    }
    return ('{' + ($parts -join ',') + '}')
  }
  throw '対象のCLIが不正です。'
}

function Ext-JsonAddMcp([string]$Text, [string]$RootProp, [string]$Name, [string]$ServerJson) {
  $qname = Ext-JsonQuote $Name
  if ([string]::IsNullOrWhiteSpace($Text)) {
    $nl = "`r`n"
    if ($RootProp -ceq 'mcp') {
      return ('{' + $nl + '  "$schema": "https://opencode.ai/config.json",' + $nl + '  "mcp": {' + $nl + '    ' + $qname + ': ' + $ServerJson + $nl + '  }' + $nl + '}' + $nl)
    }
    return ('{' + $nl + '  ' + (Ext-JsonQuote $RootProp) + ': {' + $nl + '    ' + $qname + ': ' + $ServerJson + $nl + '  }' + $nl + '}' + $nl)
  }
  $rootStart = Ext-JsonRootStart $Text
  $props = @(Ext-JsonFindProps $Text $rootStart $RootProp)
  if ($props.Count -gt 1) { throw '同じMCP設定キーが複数あるため変更しません。' }
  if ($props.Count -eq 0) {
    $wrapper = '{' + $qname + ':' + $ServerJson + '}'
    return (Ext-JsonPropInsert $Text $rootStart $RootProp $wrapper)
  }
  $p = $props[0]
  $vStart = Ext-JsonSkipTrivia $Text $p.valueStart
  if (($vStart -ge $Text.Length) -or ($Text[$vStart] -ne [char]'{')) { throw 'MCP設定の形式を確認できませんでした。' }
  if (@(Ext-JsonFindProps $Text $vStart $Name).Count -gt 0) { throw '同名のMCPサーバーが既にあります。' }
  return (Ext-JsonPropInsert $Text $vStart $Name $ServerJson)
}

function Ext-JsonToggleMcp([string]$Text, [string]$RootProp, [string]$Name, [bool]$Enabled) {
  $rootStart = Ext-JsonRootStart $Text
  $props = @(Ext-JsonFindProps $Text $rootStart $RootProp)
  if ($props.Count -ne 1) { throw 'MCP設定の形式を確認できませんでした。' }
  $vStart = Ext-JsonSkipTrivia $Text $props[0].valueStart
  if (($vStart -ge $Text.Length) -or ($Text[$vStart] -ne [char]'{')) { throw 'MCP設定の形式を確認できませんでした。' }
  $sp = @(Ext-JsonFindProps $Text $vStart $Name)
  if ($sp.Count -eq 0) { throw 'MCPサーバーが見つかりません。' }
  if ($sp.Count -gt 1) { throw '同じMCPサーバー名が複数あるため変更しません。' }
  $svStart = Ext-JsonSkipTrivia $Text $sp[0].valueStart
  if (($svStart -ge $Text.Length) -or ($Text[$svStart] -ne [char]'{')) { throw 'MCP設定の形式を確認できませんでした。' }
  return (Ext-JsonPropSetBool $Text $svStart 'enabled' $Enabled)
}

function Ext-GetJsonMcpEnabled([string]$Text, [string]$RootProp, [string]$Name) {
  $obj = ConvertFrom-ExtensionJsonc $Text
  $root = Ext-JsonGetProp $obj $RootProp
  if ($null -eq $root) { return $null }
  $sv = Ext-JsonGetProp $root $Name
  if ($null -eq $sv) { return $null }
  if (Ext-JsonHasProp $sv 'enabled') { return (Ext-JsonGetProp $sv 'enabled') }
  return $true
}

# --- preview / apply ----------------------------------------------------------

function Ext-NewEntry([string]$Provider) {
  return @{ provider = $Provider; label = (Get-ExtensionProviderLabel $Provider); ok = $false; action = ''; path = ''; error = ''; warnings = @(); diff = @{ same = $false; lines = @(); truncated = $false }; coveredBy = '' }
}

function Ext-CleanupPreviews {
  $now = Get-Date
  $keys = @($script:ExtensionPreviews.Keys)
  foreach ($k in $keys) {
    try {
      $age = ($now - [datetime]$script:ExtensionPreviews[$k].createdAt).TotalMinutes
      if ($age -gt 10) { $script:ExtensionPreviews.Remove($k) | Out-Null }
    } catch { $script:ExtensionPreviews.Remove($k) | Out-Null }
  }
  while ($script:ExtensionPreviews.Count -gt 20) {
    $oldest = $null
    $oldestAt = $null
    foreach ($k in @($script:ExtensionPreviews.Keys)) {
      $at = $script:ExtensionPreviews[$k].createdAt
      if (($null -eq $oldestAt) -or ($at -lt $oldestAt)) { $oldest = $k; $oldestAt = $at }
    }
    if ($null -eq $oldest) { break }
    $script:ExtensionPreviews.Remove($oldest) | Out-Null
  }
}

function New-ExtensionPreview([string]$AutoDir, [string]$HomeBase, $Req, [string]$Token) {
  Ext-CleanupPreviews
  $homePath = Assert-ExtensionHome $HomeBase
  $kind = ([string](Ext-Field $Req 'kind' '')).Trim().ToLowerInvariant()
  $action = ([string](Ext-Field $Req 'action' 'add')).Trim().ToLowerInvariant()
  if (($kind -ne 'mcp') -and ($kind -ne 'skill')) { throw '種別が不正です。' }
  if (($action -ne 'add') -and ($action -ne 'toggle')) { throw '操作が不正です。' }
  if (($kind -eq 'skill') -and ($action -ne 'add')) { throw 'スキルは追加のみ対応しています。' }
  $providers = @(Ext-StringArray (Ext-Field $Req 'providers' @()))
  $validIds = @(@(Get-ExtensionProviderDefs) | ForEach-Object { [string]$_.id })
  $providers = @($providers | Select-Object -Unique)
  if ($providers.Count -eq 0) { throw '対象のCLIを1つ以上選んでください。' }
  foreach ($p in $providers) { if ($validIds -cnotcontains $p) { throw '対象のCLIが不正です。' } }
  if ($kind -eq 'mcp') {
    if ($action -eq 'add') { $v = Ext-ValidateMcpRequest $Req }
    else {
      $name = ([string](Ext-Field $Req 'name' '')).Trim()
      if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw '名前が不正です。' }
      $enabled = Ext-Field $Req 'enabled' $null
      if ($enabled -isnot [bool]) { throw 'enabled は true/false で指定してください。' }
      $v = @{ name = $name; enabled = [bool]$enabled }
    }
    $warnings = @()
  } else {
    $v = Ext-ValidateSkillRequest $Req
    $warnings = @()
    if (($providers -contains 'codex') -and ($providers -contains 'claudecode')) {
      $warnings += 'Codex と Claude Code の両方へ同じ名前で配布すると、OpenCode は ~/.agents/skills と ~/.claude/skills の両方を読み、同名スキルが重複して見えます。OpenCode の重複を避けるには、どちらか一方だけに配布してください。'
    }
  }
  $entries = @()
  $writeEntries = @()
  if ($kind -eq 'mcp') {
    foreach ($provId in $providers) {
      $entry = Ext-NewEntry $provId
      try {
        $target = Get-ExtensionConfigTarget $homePath $provId
        $info = Ext-SafeFileInfo $target.path $homePath
        if ($info.error -ne '') { throw [string]$info.error }
        if (Ext-Reparse $target.path) { throw '設定ファイルがリンクになっています。' }
        Ext-AssertNoLinkChain $target.path $homePath '設定ファイル'
        if (($provId -ne 'codex') -and ([string]$target.kind -eq 'json')) {
          # Strict .json is refused when it already contains JSONC syntax; .jsonc
          # is the supported comment-preserving target.
          if (Ext-JsonHasComments ([string]$info.text)) { throw '既存のJSONにコメントがあるため変更しません。手動で修正してください。' }
          if (Ext-JsonHasTrailingComma ([string]$info.text)) { throw '既存のJSONに末尾カンマがあるため変更しません。手動で修正してください。' }
        }
        if ($provId -ceq 'codex') {
          $preCheck = Ext-ParseCodexToml ([string]$info.text)
          if ([bool]$preCheck.unsupported) { throw '未対応のMCP定義（インラインテーブル/ドットキー/配列テーブル/引用符付きルート/複数行文字列）があるため変更しません。手動で修正してください。' }
          if ($action -eq 'add') {
            $after = Ext-CodexAddMcp ([string]$info.text) $v.name $v.transport $v.command $v.args $v.url $v.envPairs $v.headerPairs
          } else {
            $after = Ext-CodexToggleMcp ([string]$info.text) $v.name $v.enabled
          }
          $check = Ext-ParseCodexToml $after
          $hit = @($check.servers | Where-Object { [string]$_.name -ceq $v.name })
          if ($hit.Count -ne 1) { throw '変更後の設定を確認できませんでした。' }
          if ($action -eq 'toggle') {
            if ([bool]$hit[0].enabled -ne [bool]$v.enabled) { throw '変更後の有効状態を確認できませんでした。' }
          }
        } else {
          if ($action -eq 'toggle') {
            if ($provId -ceq 'claudecode') { throw 'この変更は公式の /mcp パネルで行ってください。' }
            $after = Ext-JsonToggleMcp ([string]$info.text) ([string]$target.rootProp) $v.name ([bool]$v.enabled)
            $got = Ext-GetJsonMcpEnabled $after ([string]$target.rootProp) $v.name
            if ($got -ne [bool]$v.enabled) { throw '変更後の有効状態を確認できませんでした。' }
          } else {
            $serverJson = Ext-JsonBuildMcpValue $provId $v.transport $v.command $v.args $v.url $v.envPairs $v.headerPairs
            $after = Ext-JsonAddMcp ([string]$info.text) ([string]$target.rootProp) $v.name $serverJson
          }
          $parsed = $null
          try { $parsed = ConvertFrom-ExtensionJsonc $after } catch { throw '変更後のJSONを解析できませんでした。' }
          $rootObj = Ext-JsonGetProp $parsed ([string]$target.rootProp)
          if ($rootObj -isnot [System.Management.Automation.PSCustomObject]) { throw '変更後のMCP設定を確認できませんでした。' }
          $svObj = Ext-JsonGetProp $rootObj $v.name
          if ($null -eq $svObj) { throw '変更後のMCPサーバーを確認できませんでした。' }
          if (($action -eq 'add') -and ($provId -ceq 'opencode') -and ([string]$v.transport -eq 'stdio')) {
            $gotCmd = @(Ext-StringArray (Ext-JsonGetProp $svObj 'command'))
            if (($gotCmd.Count -lt 1) -or ([string]$gotCmd[0] -cne [string]$v.command)) { throw '変更後のコマンドを確認できませんでした。' }
          }
          if (($action -eq 'toggle') -and ((-not (Ext-JsonHasProp $svObj 'enabled')) -or ((Ext-JsonGetProp $svObj 'enabled') -ne [bool]$v.enabled))) {
            throw '変更後の有効状態を確認できませんでした。'
          }
        }
        if ($after -ceq [string]$info.text) { throw '変更はありません。' }
        $entry.ok = $true
        $entry.action = if ($info.exists) { 'write' } else { 'create' }
        $entry.path = [string]$target.path
        $oldEnabled = $null
        if ($action -eq 'toggle') {
          if ($provId -ceq 'codex') {
            foreach ($s in @($preCheck.servers)) {
              if ([string]$s.name -ceq [string]$v.name) { $oldEnabled = [bool]$s.enabled; break }
            }
          } else {
            try { $oldEnabled = Ext-GetJsonMcpEnabled ([string]$info.text) ([string]$target.rootProp) ([string]$v.name) } catch {}
          }
        }
        $rootLabel = if ($provId -ceq 'codex') { 'mcp_servers' } else { [string]$target.rootProp }
        $entry.diff = Ext-SafeMcpDiff $action $v $oldEnabled $rootLabel
        $afterBytes = Ext-EncodeText $after $info
        $writeEntries += @{ provider = $provId; path = [string]$target.path; beforeExists = [bool]$info.exists; beforeHash = $info.hash; afterHash = (Ext-HashBytes $afterBytes); afterBytes = $afterBytes; kind = 'mcp'; action = $entry.action }
      } catch {
        $entry.ok = $false
        $entry.error = $_.Exception.Message
      }
      $entries += $entry
    }
  } else {
    $content = Ext-BuildSkillContent $v.name $v.description $v.body
    $contentBytes = Ext-EncodeText $content $null
    if ($contentBytes.Length -gt (Ext-MaxSkillBytes)) { throw 'スキルが大きすぎます。SKILL.md は64KB以下にしてください。' }
    $afterHash = Ext-HashBytes $contentBytes
    $sharedCodex = ($providers -contains 'codex')
    $sharedClaude = ($providers -contains 'claudecode')
    $covered = @{}
    if ($providers -contains 'opencode') {
      if ($sharedCodex) { $covered['opencode'] = 'codex' }
      elseif ($sharedClaude) { $covered['opencode'] = 'claudecode' }
    }
    foreach ($provId in $providers) {
      $entry = Ext-NewEntry $provId
      try {
        if ($covered.ContainsKey($provId)) {
          $by = [string]$covered[$provId]
          $byDef = Get-ExtensionProviderDef $by
          $byPath = Join-Path $homePath ([string]$byDef.skillsRel)
          $coveredDef = Get-ExtensionProviderDef $provId
          foreach ($sd in @(@($coveredDef.skillDirs) | ForEach-Object { Join-Path $homePath ([string]$_) })) {
            if (Test-Path -LiteralPath (Join-Path $sd $v.name)) { throw 'このCLIには同名のスキルが既にあります。' }
          }
          $entry.ok = $true
          $entry.action = 'covered'
          $entry.coveredBy = $by
          $entry.path = (Join-Path (Join-Path $byPath $v.name) 'SKILL.md')
          $entry.diff = @{ same = $true; lines = @(); truncated = $false }
          $entries += $entry
          continue
        }
        $def = Get-ExtensionProviderDef $provId
        $base = Join-Path $homePath ([string]$def.skillsRel)
        $dir = Join-Path $base $v.name
        $file = Join-Path $dir 'SKILL.md'
        Ext-AssertNoLinkChain $file $homePath 'スキル'
        if (Test-Path -LiteralPath $dir) { throw '同名のフォルダが既にあります。' }
        if (Test-Path -LiteralPath $file) { throw '同じスキルが既にあります。' }
        # Reject if the provider would discover an existing skill with this name elsewhere.
        $searchDirs = @(@($def.skillDirs) | ForEach-Object { Join-Path $homePath ([string]$_) })
        $foundElsewhere = $false
        foreach ($sd in $searchDirs) {
          if (Test-Path -LiteralPath (Join-Path $sd $v.name)) { $foundElsewhere = $true; break }
        }
        if ($foundElsewhere) { throw 'このCLIには同名のスキルが既にあります。' }
        $entry.ok = $true
        $entry.action = 'create'
        $entry.path = $file
        $entry.diff = Ext-Diff $null $content $Token @()
        $writeEntries += @{ provider = $provId; path = $file; beforeExists = $false; beforeHash = $null; afterHash = $afterHash; afterBytes = $contentBytes; kind = 'skill'; action = 'create'; dirPath = $dir }
      } catch {
        $entry.ok = $false
        $entry.error = $_.Exception.Message
      }
      $entries += $entry
    }
  }
  $anyOk = $false
  foreach ($e in $entries) { if ($e.ok) { $anyOk = $true; break } }
  $id = ''
  if ($anyOk) {
    $id = [System.Guid]::NewGuid().ToString('N')
    $script:ExtensionPreviews[$id] = @{
      id = $id; createdAt = (Get-Date); kind = $kind; action = $action; name = [string]$v.name
      providers = @($providers); warnings = @($warnings); entries = @($writeEntries)
    }
  }
  return @{ ok = $true; previewId = $id; kind = $kind; action = $action; name = [string]$v.name; entries = @($entries); warnings = @($warnings) }
}

function Open-ExtensionLock([string]$AutoDir) {
  try {
    return [System.IO.File]::Open((Join-Path $AutoDir 'Extensions.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  } catch {
    $e = $_.Exception
    while (($e -is [System.Management.Automation.MethodInvocationException]) -and ($e.InnerException)) { $e = $e.InnerException }
    if ($e -is [System.IO.IOException]) { throw '拡張機能の変更が実行中です。(busy)' }
    throw ('ロック取得に失敗しました: ' + $e.Message)
  }
}

function Ext-GetAcl([string]$File) {
  try { if (Test-Path -LiteralPath $File -PathType Leaf) { return (Get-Acl -LiteralPath $File) } } catch {}
  return $null
}

function Ext-RestoreAcl([string]$File, $Acl) {
  if ($null -eq $Acl) { return }
  try { Set-Acl -LiteralPath $File -AclObject $Acl } catch {}
}

function Ext-WriteAtomic([string]$File, [byte[]]$Bytes, [string]$Root) {
  # Preserve an existing file's ACL across the atomic replace. New files keep
  # the private ACL written by the shared helper.
  $oldAcl = Ext-GetAcl $File
  if (Get-Command Write-GlobalFileAtomicBytes -ErrorAction SilentlyContinue) {
    Write-GlobalFileAtomicBytes $File $Bytes $Root
    Ext-RestoreAcl $File $oldAcl
    return
  }
  Ext-AssertNoLinkChain $File $Root '出力先'
  $dir = Split-Path $File -Parent
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    if (-not (Ext-Contained $File $Root)) { throw '出力先を確認できませんでした。' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $tmp = Join-Path $dir ('.ext-tmp-' + [System.Guid]::NewGuid().ToString('N'))
  [System.IO.File]::WriteAllBytes($tmp, $Bytes)
  try {
    if (Test-Path -LiteralPath $File) {
      $bak = Join-Path $dir ('.ext-bak-' + [System.Guid]::NewGuid().ToString('N'))
      [System.IO.File]::Replace($tmp, $File, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch {}
    } else { [System.IO.File]::Move($tmp, $File) | Out-Null }
  } catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    throw
  }
  Ext-RestoreAcl $File $oldAcl
}

function Ext-CopyVerified([string]$Src, [string]$Dst, [string]$SrcRoot, [string]$DstRoot) {
  if (Get-Command Copy-GlobalVerified -ErrorAction SilentlyContinue) {
    Copy-GlobalVerified $Src $Dst $SrcRoot $DstRoot
    return
  }
  Ext-AssertNoLinkChain $Src $SrcRoot '複写元'
  Ext-AssertNoLinkChain $Dst $DstRoot '複写先'
  Copy-Item -LiteralPath $Src -Destination $Dst -Force
  $a = Ext-HashFile $Src; $b = Ext-HashFile $Dst
  if ((-not $a) -or ($a -cne $b)) { throw '複写の検証に失敗しました。' }
}

function Ext-WritePrivateJson([string]$Path, $Value) {
  if (Get-Command Write-GlobalPrivateJson -ErrorAction SilentlyContinue) {
    Write-GlobalPrivateJson $Path $Value
    return
  }
  $json = ConvertTo-Json -InputObject $Value -Depth 12
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ExtensionBackup([string]$AutoDir, [string]$HomeBase, [string]$Kind, [string]$Name, [string]$Action, $Entries) {
  $broot = Join-Path $AutoDir 'backups\.extensions'
  New-Item -ItemType Directory -Force -Path $broot | Out-Null
  if (Ext-Reparse $broot) { throw 'バックアップ先を確認できませんでした。' }
  Ext-AssertNoLinkChain $broot $AutoDir 'バックアップ先'
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $id = ($ts + '-ext-' + ([System.Guid]::NewGuid().ToString('N').Substring(0, 8)))
  $bdir = Join-Path $broot $id
  if (-not (Ext-Contained $bdir $broot)) { throw 'バックアップ先を確認できませんでした。' }
  New-Item -ItemType Directory -Force -Path $bdir | Out-Null
  if (Ext-Reparse $bdir) { throw 'バックアップ先を確認できませんでした。' }
  Ext-AssertNoLinkChain $bdir $AutoDir 'バックアップ先'
  $files = @()
  $i = 0
  foreach ($e in @($Entries)) {
    $bakName = ''
    if ([bool]$e.beforeExists) {
      $bakName = ('{0:D4}.bin' -f $i)
      $dst = Join-Path $bdir $bakName
      Ext-AssertNoLinkChain $dst $AutoDir 'バックアップ先'
      Ext-CopyVerified ([string]$e.path) $dst $HomeBase $AutoDir
      $h = Ext-HashFile $dst
      if ($h -cne [string]$e.beforeHash) { throw 'バックアップの検証に失敗しました。' }
    }
    $files += @{
      provider = [string]$e.provider; path = [string]$e.path; present = [bool]$e.beforeExists
      backupFile = $bakName; hashBefore = [string]$e.beforeHash; hashAfter = [string]$e.afterHash
      kind = [string]$e.kind; skillDir = [string]$e.dirPath
    }
    $i++
  }
  Ext-AssertNoLinkChain (Join-Path $bdir 'manifest.json') $AutoDir 'バックアップの記録'
  Ext-WritePrivateJson (Join-Path $bdir 'manifest.json') @{
    schemaVersion = 1; scope = 'extensions'; createdAt = ([DateTime]::UtcNow.ToString('o')); homeBase = $HomeBase
    kind = $Kind; name = $Name; action = $Action; files = @($files)
  }
  return $id
}

function Apply-ExtensionPreview([string]$AutoDir, [string]$HomeBase, [string]$PreviewId, [bool]$Confirm, [bool]$AcknowledgeWarnings) {
  if (-not $Confirm) { throw '確認チェックを入れてください。' }
  if ($PreviewId -cnotmatch '^[0-9a-f]{32}$') { throw 'プレビューIDが不正です。' }
  $pv = $null
  if ($script:ExtensionPreviews.ContainsKey($PreviewId)) { $pv = $script:ExtensionPreviews[$PreviewId] }
  if ($null -eq $pv) { throw 'プレビューが古いため、もう一度プレビューしてください。' }
  if (((Get-Date) - [datetime]$pv.createdAt).TotalMinutes -gt 10) {
    $script:ExtensionPreviews.Remove($PreviewId) | Out-Null
    throw 'プレビューが古いため、もう一度プレビューしてください。'
  }
  if ((@($pv.warnings).Count -gt 0) -and (-not $AcknowledgeWarnings)) { throw '注意事項の確認チェックを入れてください。' }
  $homePath = Assert-ExtensionHome $HomeBase
  $entries = @($pv.entries)
  if ($entries.Count -eq 0) { throw '適用する変更がありません。' }
  $lock = Open-ExtensionLock $AutoDir
  try {
    # Revalidate every target before touching anything.
    foreach ($e in $entries) {
      $path = [string]$e.path
      Ext-AssertNoLinkChain $path $homePath '変更対象'
      if (-not (Ext-Contained $path $homePath)) { throw '変更対象がホームフォルダの外にあります。' }
      if ([bool]$e.beforeExists) {
        $cur = Ext-SafeFileInfo $path $homePath
        if ((-not $cur.exists) -or ($cur.error -ne '')) { throw '変更対象が読み取れません。もう一度プレビューしてください。' }
        if ([string]$cur.hash -cne [string]$e.beforeHash) { throw 'プレビュー後にファイルが変化しました。もう一度プレビューしてください。' }
      } else {
        if (Test-Path -LiteralPath $path) { throw 'プレビュー後にファイルが作成されました。もう一度プレビューしてください。' }
        if (([string]$e.kind -eq 'skill') -and ([string]$e.dirPath) -and (Test-Path -LiteralPath ([string]$e.dirPath))) {
          throw 'プレビュー後にフォルダが作成されました。もう一度プレビューしてください。'
        }
      }
    }
    $backupId = New-ExtensionBackup $AutoDir $homePath ([string]$pv.kind) ([string]$pv.name) ([string]$pv.action) $entries
    $written = @()
    try {
      foreach ($e in $entries) {
        $curBytes = $null
        if ([bool]$e.beforeExists) {
          $cur = Ext-SafeFileInfo ([string]$e.path) $homePath
          if (($cur.hash -cne [string]$e.beforeHash) -or (-not $cur.exists)) { throw '変更対象が変化しました。もう一度プレビューしてください。' }
          $curBytes = [byte[]]$cur.bytes
        } else {
          if (Test-Path -LiteralPath ([string]$e.path)) { throw '変更対象が作成されました。もう一度プレビューしてください。' }
          if (([string]$e.kind -eq 'skill') -and ([string]$e.dirPath) -and (Test-Path -LiteralPath ([string]$e.dirPath))) {
            throw '変更対象のフォルダが作成されました。もう一度プレビューしてください。'
          }
        }
        Ext-WriteAtomic ([string]$e.path) ([byte[]]$e.afterBytes) $homePath
        $got = Ext-HashFile ([string]$e.path)
        if ($got -cne [string]$e.afterHash) { throw '書込み後の検証に失敗しました。' }
        $written += @{ path = [string]$e.path; beforeExists = [bool]$e.beforeExists; beforeBytes = $curBytes; afterHash = [string]$e.afterHash; dirPath = [string]$e.dirPath }
      }
    } catch {
      $err = $_.Exception.Message
      $rbOk = $true
      for ($i = $written.Count - 1; $i -ge 0; $i--) {
        $w = $written[$i]
        try {
          if ([bool]$w.beforeExists) {
            if ($null -eq $w.beforeBytes) { throw '復旧データがありません。' }
            Ext-WriteAtomic ([string]$w.path) ([byte[]]$w.beforeBytes) $homePath
          } else {
            $cur = Ext-SafeFileInfo ([string]$w.path) $homePath
            if ($cur.exists -and ([string]$cur.hash -ceq [string]$w.afterHash)) { Remove-Item -LiteralPath ([string]$w.path) -Force -ErrorAction Stop }
            $sd = [string]$w.dirPath
            $parentOfFile = Split-Path ([string]$w.path) -Parent
            if ($sd -and ($sd -ieq $parentOfFile) -and (Test-Path -LiteralPath $sd -PathType Container) -and (-not (Ext-Reparse $sd)) -and (Ext-Contained $sd $homePath)) {
              try { if (@(Get-ChildItem -LiteralPath $sd -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $sd -Force -ErrorAction SilentlyContinue } } catch {}
            }
          }
        } catch { $rbOk = $false }
      }
      $tail = if ($rbOk) { '（自動復旧しました）' } else { '（自動復旧も一部失敗しました。バックアップから手動で復元してください）' }
      throw ('適用に失敗しました。バックアップ: ' + $backupId + ' ' + $tail + ' 詳細: ' + $err)
    }
    $script:ExtensionPreviews.Remove($PreviewId) | Out-Null
    $results = @()
    foreach ($e in $entries) {
      $results += @{ provider = [string]$e.provider; path = [string]$e.path; action = [string]$e.action; ok = $true }
    }
    return @{ ok = $true; backupId = $backupId; results = @($results) }
  } finally {
    try { $lock.Close() } catch {}
  }
}

function Get-ExtensionBackupManifest([string]$AutoDir, [string]$BackupId) {
  if ($BackupId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'バックアップIDが不正です。' }
  $broot = Join-Path $AutoDir 'backups\.extensions'
  if (-not (Test-Path -LiteralPath $broot -PathType Container)) { throw 'バックアップがありません。' }
  if (Ext-Reparse $broot) { throw 'バックアップ先を確認できませんでした。' }
  $bdir = Join-Path $broot $BackupId
  if (-not (Ext-Contained $bdir $broot)) { throw 'バックアップIDが不正です。' }
  if (-not (Test-Path -LiteralPath $bdir -PathType Container)) { throw 'バックアップが見つかりません。' }
  if (Ext-Reparse $bdir) { throw 'バックアップがリンクになっています。' }
  Ext-AssertNoLinkChain $bdir $AutoDir 'バックアップ'
  $mf = Join-Path $bdir 'manifest.json'
  if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { throw 'バックアップの記録がありません。' }
  Ext-AssertNoLinkChain $mf $AutoDir 'バックアップの記録'
  $info = Ext-SafeFileInfo $mf $AutoDir
  if (($info.error -ne '') -or (-not $info.exists)) { throw 'バックアップの記録を読み取れませんでした。' }
  try { $m = ConvertFrom-ExtensionJsonc $info.text } catch { throw 'バックアップの記録を解析できませんでした。' }
  if ([string](Ext-Field $m 'scope' '') -cne 'extensions') { throw 'バックアップの種別が不正です。' }
  return @{ dir = $bdir; manifest = $m }
}

function Test-ExtensionBackupRestorable([string]$HomeBase, $Manifest) {
  $mh = [string](Ext-Field $Manifest 'homeBase' '')
  if ($mh -eq '') { return $false }
  try { return ((Ext-RootCanonical $mh) -ieq (Ext-RootCanonical $HomeBase)) } catch { return $false }
}

function Get-ExtensionBackupList([string]$AutoDir, [string]$HomeBase) {
  $out = @()
  $broot = Join-Path $AutoDir 'backups\.extensions'
  if (-not (Test-Path -LiteralPath $broot -PathType Container)) { return @() }
  if (Ext-Reparse $broot) { return @() }
  try { Ext-AssertNoLinkChain $broot $AutoDir 'バックアップ先' } catch { return @() }
  try { $dirs = @(Get-ChildItem -LiteralPath $broot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 30) } catch { return @() }
  foreach ($d in $dirs) {
    if ($d.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { continue }
    try {
      $g = Get-ExtensionBackupManifest $AutoDir $d.Name
      $m = $g.manifest
      if ([string](Ext-Field $m 'scope' '') -cne 'extensions') { continue }
      $files = @(Ext-Field $m 'files' @())
      $providers = @()
      foreach ($f in $files) {
        $p = [string](Ext-Field $f 'provider' '')
        if ($p -and ($providers -cnotcontains $p)) { $providers += $p }
      }
      $out += @{
        id = [string]$d.Name; createdAt = [string](Ext-Field $m 'createdAt' ''); kind = [string](Ext-Field $m 'kind' '')
        name = [string](Ext-Field $m 'name' ''); action = [string](Ext-Field $m 'action' '')
        fileCount = $files.Count; providers = @($providers)
        restorable = (Test-ExtensionBackupRestorable $HomeBase $m)
      }
    } catch { continue }
  }
  return @($out)
}

function Restore-ExtensionBackup([string]$AutoDir, [string]$HomeBase, [string]$BackupId, [bool]$Confirm) {
  if (-not $Confirm) { throw '確認チェックを入れてください。' }
  $homePath = Assert-ExtensionHome $HomeBase
  $g = Get-ExtensionBackupManifest $AutoDir $BackupId
  $m = $g.manifest
  $bdir = [string]$g.dir
  if (-not (Test-ExtensionBackupRestorable $homePath $m)) { throw 'このバックアップは別のホームフォルダ向けのため復元しません。' }
  $lock = Open-ExtensionLock $AutoDir
  try {
    $files = @(Ext-Field $m 'files' @())
    if ($files.Count -eq 0) { throw '復元するファイルがありません。' }
    $plan = @()
    foreach ($f in $files) {
      $path = [string](Ext-Field $f 'path' '')
      if ($path -eq '') { throw 'バックアップの対象が不正です。' }
      Ext-AssertNoLinkChain $path $homePath '復元先'
      if (-not (Ext-Contained $path $homePath)) { throw '復元先がホームフォルダの外にあります。' }
      $cur = Ext-SafeFileInfo $path $homePath
      if ((-not $cur.exists) -or ($cur.error -ne '')) { throw ('復元対象が見つかりません: ' + $path) }
      if ([string]$cur.hash -cne [string](Ext-Field $f 'hashAfter' '')) { throw ('適用後にファイルが変化しているため復元しません: ' + $path) }
      $present = [bool](Ext-Field $f 'present' $false)
      $bakFile = [string](Ext-Field $f 'backupFile' '')
      $hashBefore = [string](Ext-Field $f 'hashBefore' '')
      $hashAfter = [string](Ext-Field $f 'hashAfter' '')
      if ($present) {
        if ($bakFile -cnotmatch '^[0-9]{4}\.bin$') { throw 'バックアップの内容が不正です。' }
        $bak = Join-Path $bdir $bakFile
        if (-not (Ext-Contained $bak $bdir)) { throw 'バックアップの内容が不正です。' }
        Ext-AssertNoLinkChain $bak $AutoDir '復元元'
        $bi = Ext-SafeFileInfo $bak $AutoDir
        if ((-not $bi.exists) -or ($bi.error -ne '')) { throw 'バックアップの内容を読み取れません。' }
        if ([string]$bi.hash -cne $hashBefore) { throw 'バックアップが破損しているため復元しません。' }
      }
      $plan += @{ path = $path; present = $present; backupFile = $bakFile; hashBefore = $hashBefore; hashAfter = $hashAfter; currentBytes = [byte[]]$cur.bytes; skillDir = [string](Ext-Field $f 'skillDir' '') }
    }
    $done = @()
    try {
      foreach ($p in $plan) {
        $now = Ext-SafeFileInfo ([string]$p.path) $homePath
        if ((-not $now.exists) -or ([string]$now.hash -cne [string]$p.hashAfter)) { throw ('復元直前にファイルが変化しました: ' + [string]$p.path) }
        if ([bool]$p.present) {
          $bak = Join-Path $bdir ([string]$p.backupFile)
          $bytes = [System.IO.File]::ReadAllBytes($bak)
          Ext-WriteAtomic ([string]$p.path) $bytes $homePath
          $got = Ext-HashFile ([string]$p.path)
          if ($got -cne [string]$p.hashBefore) { throw '復元後の検証に失敗しました。' }
        } else {
          Remove-Item -LiteralPath ([string]$p.path) -Force -ErrorAction Stop
          $sd = [string]$p.skillDir
          if ($sd -and (Test-Path -LiteralPath $sd -PathType Container)) {
            try {
              $parentOfFile = Split-Path ([string]$p.path) -Parent
              $left = @(Get-ChildItem -LiteralPath $sd -Force -ErrorAction Stop)
              if (($left.Count -eq 0) -and (Ext-Contained $sd $homePath) -and ($sd -ieq $parentOfFile) -and (-not (Ext-Reparse $sd))) {
                Remove-Item -LiteralPath $sd -Force -ErrorAction SilentlyContinue
              }
            } catch {}
          }
        }
        $done += $p
      }
    } catch {
      $err = $_.Exception.Message
      $rbOk = $true
      for ($i = $done.Count - 1; $i -ge 0; $i--) {
        try { Ext-WriteAtomic ([string]$done[$i].path) ([byte[]]$done[$i].currentBytes) $homePath } catch { $rbOk = $false }
      }
      $tail = if ($rbOk) { '（復元前の状態に戻しました）' } else { '（一部の復元を取り消せませんでした）' }
      throw ('復元に失敗しました。' + $tail + ' 詳細: ' + $err)
    }
    return @{ ok = $true; restored = @($plan | Where-Object { [bool]$_.present } | ForEach-Object { [string]$_.path }); deleted = @($plan | Where-Object { -not [bool]$_.present } | ForEach-Object { [string]$_.path }) }
  } finally {
    try { $lock.Close() } catch {}
  }
}
