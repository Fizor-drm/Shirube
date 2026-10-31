# Real pinned rulesync generation regression for Global rules.
# Invokes an already cached rulesync 42.0.0 directly (never npx/network) in a
# GUID scratch with isolated HOME_DIR/HOME/APPDATA/LOCALAPPDATA/XDG/Kimi and
# OpenCode env. Proves the documented Global frontmatter (no targets or ["*"])
# distributes to every catalog provider, that OpenCode V2 `mcp.servers`, mixed
# V1/V2, and old flat configs generate without schema errors and stay
# byte-identical, and that a language setting adds Claude's shared settings
# write that the sync guard must refuse. rulesync 32 is kept only as an
# explicit compatibility fixture documenting the V2 schema rejection.
$ErrorActionPreference = 'Stop'

$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Get-Full([string]$P) { return [System.IO.Path]::GetFullPath($P) }
function Test-Contained([string]$Candidate, [string]$Root) {
  $c = Get-Full $Candidate
  $r = Get-Full $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}

$devAuto = Split-Path -Parent $PSScriptRoot
. (Join-Path $devAuto 'Global-Management.ps1')
$catalog = @(Get-GlobalProviderCatalog)
$allTargets = @($catalog | ForEach-Object { [string]$_.id })

function Find-CachedRulesync([string]$Version = '42.0.0') {
  $roots = @()
  if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') }
  if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'npm-cache\_npx') }
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
      $pj = Join-Path $d.FullName 'node_modules\rulesync\package.json'
      $cli = Join-Path $d.FullName 'node_modules\rulesync\dist\cli\index.js'
      if ((-not (Test-Path -LiteralPath $pj -PathType Leaf)) -or (-not (Test-Path -LiteralPath $cli -PathType Leaf))) { continue }
      try { $v = [string](Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { continue }
      if ($v -ceq $Version) { return $cli }
    }
  }
  return $null
}

$nodeCmd = Get-Command 'node' -ErrorAction SilentlyContinue
$cli = Find-CachedRulesync '42.0.0'
if ((-not $nodeCmd) -or (-not $cli)) {
  Write-Host 'SKIP: cached rulesync 42.0.0 and/or node not found; no download attempted.'
  exit 77
}
$cli32 = Find-CachedRulesync '32.0.0'
$nodeExe = $nodeCmd.Source

$initCwd = (Get-Location).Path
$envNames = @('HOME_DIR', 'HOME', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'KIMI_CODE_HOME', 'USERPROFILE', 'OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_CONTENT')
$origEnv = @{}
foreach ($n in $envNames) { $origEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }

$testBase = Join-Path ([System.IO.Path]::GetTempPath()) 'GlobalRealGenerationTest'
$scratch = $null
try {
  New-Item -ItemType Directory -Force -Path $testBase | Out-Null
  $scratch = Join-Path $testBase ("run-" + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null
  Assert (Test-Contained $scratch $testBase) 'R0 GUID scratch contained in base'

  function New-IsolatedCase([string]$Name) {
    $root = Join-Path $script:scratch $Name
    $preview = Join-Path $root 'global-preview'
    $homeDir = Join-Path $root 'home'
    $appdata = Join-Path $root 'appdata'
    $localappdata = Join-Path $root 'localappdata'
    $xdg = Join-Path $root 'xdg'
    New-Item -ItemType Directory -Force -Path (Join-Path $preview '.rulesync\rules'), $homeDir, $appdata, $localappdata, $xdg | Out-Null
    $env:HOME_DIR = $homeDir
    $env:HOME = $homeDir
    $env:APPDATA = $appdata
    $env:LOCALAPPDATA = $localappdata
    $env:XDG_CONFIG_HOME = $xdg
    $env:KIMI_CODE_HOME = ''
    $env:USERPROFILE = $homeDir
    foreach ($ocn in @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_CONTENT')) { Remove-Item -Path ('Env:' + $ocn) -ErrorAction SilentlyContinue }
    return @{ root = $root; preview = $preview; home = $homeDir; appdata = $appdata; localappdata = $localappdata; xdg = $xdg }
  }
  function Set-CaseRule([hashtable]$Case, [string]$Frontmatter, [string]$Marker) {
    if ($Frontmatter -and (-not $Frontmatter.EndsWith("`n"))) { $Frontmatter += "`n" }
    $text = "---`nroot: true`n" + $Frontmatter + "---`n`n" + $Marker + "`n"
    Set-Content -LiteralPath (Join-Path $Case.preview '.rulesync\rules\global.md') $text -Encoding UTF8
  }
  function Set-CaseConfig([hashtable]$Case, [string]$Json) {
    Set-Content -LiteralPath (Join-Path $Case.preview 'rulesync.jsonc') $Json -Encoding UTF8
  }
  function Invoke-RealRulesyncCli([string]$Cli, [hashtable]$Case, [string[]]$Targets, [string]$ConfigPath = '', [string]$Mode = '') {
    $argv = @('generate', '--global', '--targets', ($Targets -join ','), '--features', 'rules')
    if ($ConfigPath) { $argv += @('--config', $ConfigPath) }
    if ($Mode) { $argv += @('--' + $Mode) }
    Push-Location -LiteralPath $Case.preview
    try {
      $prevEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $out = & $script:nodeExe $Cli @argv 2>&1 | Out-String
        $code = $LASTEXITCODE
      }
      finally { $ErrorActionPreference = $prevEap }
    }
    finally { Pop-Location }
    if ($null -eq $code) { $code = 1 }
    return @{ code = $code; out = $out }
  }
  function Invoke-RealRulesync([hashtable]$Case, [string[]]$Targets, [string]$ConfigPath = '', [string]$Mode = '') {
    return (Invoke-RealRulesyncCli $script:cli $Case $Targets $ConfigPath $Mode)
  }
  function Get-RelFiles([string]$Root) {
    $arr = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
      $arr += $f.FullName.Substring($Root.Length).TrimStart('\', '/')
    }
    return $arr
  }

  $quietConfig = @'
{
  "features": ["rules"]
}
'@
  $pinnedConfig = @'
{
  "targets": ["codexcli", "opencode"],
  "features": ["rules"]
}
'@

  # R1: omitted targets -> every catalog provider gets real content, with no
  # unbacked extra config files (notably no Claude settings.json).
  $c1 = New-IsolatedCase 'all-omitted'
  $marker1 = 'REAL-GLOBAL-OMIT-MARKER'
  Set-CaseRule $c1 '' $marker1
  Set-CaseConfig $c1 $quietConfig
  $r1 = Invoke-RealRulesync $c1 $allTargets
  Assert ($r1.code -eq 0) 'R1 all-catalog real generation exits 0'
  $expected1 = @{}
  foreach ($e in $catalog) {
    $p = Join-Path $c1.home ([string]$e.rel)
    $expected1[$p] = $true
    $ok = (Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-Content -LiteralPath $p -Raw -Encoding UTF8).Contains($marker1))
    Assert $ok ('R1 ' + [string]$e.id + ' receives documented Global content')
  }
  $actual1 = @(Get-ChildItem -LiteralPath $c1.home -Recurse -File -ErrorAction SilentlyContinue)
  Assert (@($actual1).Count -eq $catalog.Count) 'R1 exactly one file per catalog provider under HOME_DIR'
  $unexpected1 = @($actual1 | Where-Object { -not $expected1.ContainsKey($_.FullName) })
  Assert (@($unexpected1).Count -eq 0) 'R1 no extra home files (Claude settings untouched)'
  Assert (-not (Test-Path -LiteralPath (Join-Path $c1.home '.claude\settings.json'))) 'R1 no Claude settings side effect without language'
  Assert ((@(Get-RelFiles $c1.appdata).Count -eq 0) -and (@(Get-RelFiles $c1.localappdata).Count -eq 0) -and (@(Get-RelFiles $c1.xdg).Count -eq 0)) 'R1 no writes outside HOME_DIR'

  # R1b: rulesync 42 must accept OpenCode V2 `mcp.servers`, mixed V1/V2 and old
  # flat configs while only writing the catalog rule. Config bytes (including a
  # dummy secret) stay identical, and check/dry-run stay clean afterward.
  foreach ($cfgCase in @(
    @{ name = 'v2only'; json = '{"mcp":{"servers":{"dummy":{"type":"local","command":["not-executed"],"environment":{"DUMMY_SECRET":"dummy-secret-value"}}}}}' },
    @{ name = 'mixed'; json = '{"mcp":{"legacy":{"type":"local","command":["not-run"]},"servers":{"dummy":{"type":"local","command":["not-run"]}}}}' },
    @{ name = 'flat'; json = '{"mcp":{"legacy":{"type":"local","command":["not-run"]}}}' }
  )) {
    $cm = New-IsolatedCase ('mcp-' + [string]$cfgCase.name)
    Set-CaseRule $cm '' ('MCP42-MARKER-' + [string]$cfgCase.name)
    Set-CaseConfig $cm $quietConfig
    $cfgPath = Join-Path $cm.home '.config\opencode\opencode.jsonc'
    New-Item -ItemType Directory -Force -Path (Split-Path $cfgPath -Parent) | Out-Null
    [System.IO.File]::WriteAllText($cfgPath, [string]$cfgCase.json, (New-Object System.Text.ASCIIEncoding))
    $mr = Invoke-RealRulesync $cm @('opencode')
    Assert ($mr.code -eq 0) ('R1b ' + $cfgCase.name + ' MCP config generates with rulesync 42')
    Assert ((Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) -ceq [string]$cfgCase.json) ('R1b ' + $cfgCase.name + ' MCP config bytes unchanged')
    if ([string]$cfgCase.name -eq 'v2only') {
      Assert ((Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8).Contains('dummy-secret-value')) 'R1b V2 dummy secret preserved verbatim'
    }
    Assert ((Test-Path -LiteralPath (Join-Path $cm.home '.config\opencode\AGENTS.md') -PathType Leaf)) ('R1b ' + $cfgCase.name + ' catalog rule written')
    Assert (@(Get-ChildItem -LiteralPath $cm.home -Recurse -File -ErrorAction SilentlyContinue).Count -eq 2) ('R1b ' + $cfgCase.name + ' no extra files')
    $mchk = Invoke-RealRulesync $cm @('opencode') '' 'check'
    Assert ($mchk.code -eq 0) ('R1b ' + $cfgCase.name + ' check exits 0 after generate')
    $mdry = Invoke-RealRulesync $cm @('opencode') '' 'dry-run'
    Assert ($mdry.code -eq 0) ('R1b ' + $cfgCase.name + ' dry-run exits 0 after generate')
  }

  # R1c: rulesync 32 stays only as an explicit compatibility fixture. It reads
  # the V2 envelope as a single server named `servers` and fails schema
  # validation, which is why the shipped default is 42.
  if ($cli32) {
    $c32 = New-IsolatedCase 'mcp-v2only-rulesync32'
    Set-CaseRule $c32 '' 'MCP32-COMPAT-MARKER'
    Set-CaseConfig $c32 $quietConfig
    $cfg32 = Join-Path $c32.home '.config\opencode\opencode.jsonc'
    New-Item -ItemType Directory -Force -Path (Split-Path $cfg32 -Parent) | Out-Null
    $v2json = '{"mcp":{"servers":{"dummy":{"type":"local","command":["not-executed"]}}}}'
    [System.IO.File]::WriteAllText($cfg32, $v2json, (New-Object System.Text.ASCIIEncoding))
    $r32 = Invoke-RealRulesyncCli $script:cli32 $c32 @('opencode')
    Assert ($r32.code -ne 0) 'R1c rulesync 32 compatibility: V2 mcp.servers is rejected'
    Assert ($r32.out.Contains('Invalid input')) 'R1c rulesync 32 compatibility: schema error reproduced'
    Assert ((Get-Content -LiteralPath $cfg32 -Raw -Encoding UTF8) -ceq $v2json) 'R1c rulesync 32 leaves config bytes unchanged'
    Assert (-not (Test-Path -LiteralPath (Join-Path $c32.home '.config\opencode\AGENTS.md'))) 'R1c rulesync 32 writes no rule'
  }
  else { Write-Host 'SKIP: cached rulesync 32.0.0 compatibility fixture not found.' }

  # R1d: 42 still redirects global kimi-code output to KIMI_CODE_HOME, so the
  # sync-side fail-closed guard (Assert-GlobalProviderEnvironment) stays needed.
  $ck = New-IsolatedCase 'kimi-code-override'
  Set-CaseRule $ck '' 'KIMI42-OVERRIDE-MARKER'
  Set-CaseConfig $ck $quietConfig
  $otherKimi = Join-Path $ck.root 'other-kimi'
  New-Item -ItemType Directory -Force -Path $otherKimi | Out-Null
  $env:KIMI_CODE_HOME = $otherKimi
  try { $kr = Invoke-RealRulesync $ck @('kimi-code') } finally { $env:KIMI_CODE_HOME = '' }
  Assert ($kr.code -eq 0) 'R1d kimi-code generation exits 0 with KIMI_CODE_HOME'
  Assert (Test-Path -LiteralPath (Join-Path $otherKimi 'AGENTS.md') -PathType Leaf) 'R1d KIMI_CODE_HOME redirects output (guard required)'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ck.home '.kimi-code\AGENTS.md'))) 'R1d HOME_DIR is not used for kimi-code when override is set'

  # R2: explicit wildcard is the documented alternative and reaches Pi/Claude.
  # The example config's pinned targets do not matter because the dashboard
  # passes --targets explicitly, so the template needs no change.
  $c2 = New-IsolatedCase 'wildcard-pi-claude'
  $marker2 = 'REAL-GLOBAL-WILDCARD-MARKER'
  Set-CaseRule $c2 "targets: [`"*`"]`n" $marker2
  Set-CaseConfig $c2 $pinnedConfig
  $r2 = Invoke-RealRulesync $c2 @('pi', 'claudecode')
  Assert ($r2.code -eq 0) 'R2 wildcard generation exits 0'
  foreach ($id in @('pi', 'claudecode')) {
    $rel = [string](@($catalog | Where-Object { [string]$_.id -ceq $id })[0].rel)
    $p = Join-Path $c2.home $rel
    Assert ((Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-Content -LiteralPath $p -Raw -Encoding UTF8).Contains($marker2))) ('R2 ' + $id + ' receives wildcard content')
  }
  Assert (-not (Test-Path -LiteralPath (Join-Path $c2.home '.codex\AGENTS.md'))) 'R2 CLI targets override the template config targets'

  # R3: the old fixed frontmatter filters Pi/Claude out even when CLI --targets
  # names them; this is the migration the READMEs must call out.
  $c3 = New-IsolatedCase 'old-fixed'
  Set-CaseRule $c3 'targets: ["codexcli", "opencode"]' 'REAL-GLOBAL-OLD-MARKER'
  Set-CaseConfig $c3 $quietConfig
  $r3 = Invoke-RealRulesync $c3 @('pi', 'claudecode')
  Assert ($r3.code -eq 0) 'R3 old fixed filter exits 0'
  Assert (-not (Test-Path -LiteralPath (Join-Path $c3.home '.pi\agent\AGENTS.md'))) 'R3 pinned frontmatter gives Pi no output'
  Assert (-not (Test-Path -LiteralPath (Join-Path $c3.home '.claude\CLAUDE.md'))) 'R3 pinned frontmatter gives Claude no output'

  # R4: a language in merged rulesync.local.jsonc makes the rules feature write
  # Claude's shared settings file; the sync guard exists because this is not a
  # catalog rule path and is not previewed/backed up.
  $c4 = New-IsolatedCase 'claude-language-local'
  $marker4 = 'REAL-GLOBAL-CLAUDE-MARKER'
  Set-CaseRule $c4 '' $marker4
  Set-CaseConfig $c4 $quietConfig
  $settings4 = Join-Path $c4.home '.claude\settings.json'
  New-Item -ItemType Directory -Force -Path (Split-Path $settings4 -Parent) | Out-Null
  Set-Content -LiteralPath $settings4 '{"sentinel":"keep","permissions":{"allow":["Bash"]}}' -Encoding Ascii
  $local4 = @'
{
  // merged local config
  "language": "ja",
}
'@
  Set-Content -LiteralPath (Join-Path $c4.preview 'rulesync.local.jsonc') $local4 -Encoding UTF8
  $r4 = Invoke-RealRulesync $c4 @('claudecode')
  Assert ($r4.code -eq 0) 'R4 Claude language generation exits 0'
  $s4 = $null
  if (Test-Path -LiteralPath $settings4) { $s4 = Get-Content -LiteralPath $settings4 -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert (($null -ne $s4) -and ([string]$s4.language -ceq 'japanese')) 'R4 merged local language patches Claude settings'
  Assert (($null -ne $s4) -and ([bool]$s4.sentinel)) 'R4 existing Claude settings preserved'
  Assert ((Get-Content -LiteralPath (Join-Path $c4.home '.claude\CLAUDE.md') -Raw -Encoding UTF8).Contains($marker4)) 'R4 Claude rule content written'

  # R5: --config selects the base file AND rulesync merges rulesync.local.jsonc
  # from that file's directory (ConfigResolver). A safe pinned copy therefore
  # keeps a language-bearing live local config out of generation, and a local
  # next to the pinned base is still merged.
  $c5 = New-IsolatedCase 'pinned-config-resolution'
  $marker5 = 'REAL-GLOBAL-PIN-MARKER'
  Set-CaseRule $c5 '' $marker5
  Set-CaseConfig $c5 $quietConfig
  $local5 = @'
{
  "language": "ja"
}
'@
  Set-Content -LiteralPath (Join-Path $c5.preview 'rulesync.local.jsonc') $local5 -Encoding UTF8
  $pin5 = Join-Path $c5.preview ('.config-pin-' + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $pin5 | Out-Null
  Copy-Item -LiteralPath (Join-Path $c5.preview 'rulesync.jsonc') -Destination (Join-Path $pin5 'rulesync.jsonc') -Force
  $settings5 = Join-Path $c5.home '.claude\settings.json'
  $r5a = Invoke-RealRulesync $c5 @('claudecode') (Join-Path $pin5 'rulesync.jsonc')
  Assert ($r5a.code -eq 0) 'R5 pinned base generation exits 0'
  Assert ((Get-Content -LiteralPath (Join-Path $c5.home '.claude\CLAUDE.md') -Raw -Encoding UTF8).Contains($marker5)) 'R5 pinned base writes Claude rule'
  Assert (-not (Test-Path -LiteralPath $settings5)) 'R5 cwd local language is not merged from the pinned base directory'
  Copy-Item -LiteralPath (Join-Path $c5.preview 'rulesync.local.jsonc') -Destination (Join-Path $pin5 'rulesync.local.jsonc') -Force
  $r5b = Invoke-RealRulesync $c5 @('claudecode') (Join-Path $pin5 'rulesync.jsonc')
  Assert ($r5b.code -eq 0) 'R5 pinned base plus local exits 0'
  $s5 = $null
  if (Test-Path -LiteralPath $settings5) { $s5 = Get-Content -LiteralPath $settings5 -Raw -Encoding UTF8 | ConvertFrom-Json }
  Assert (($null -ne $s5) -and ([string]$s5.language -ceq 'japanese')) 'R5 local next to the pinned base is merged'
}
finally {
  foreach ($n in $envNames) {
    $v = $origEnv[$n]
    if ($null -eq $v) { Remove-Item -Path ("Env:" + $n) -ErrorAction SilentlyContinue }
    else { Set-Item -Path ("Env:" + $n) -Value $v }
  }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
  if ($scratch -and (Test-Path -LiteralPath $scratch)) {
    if (-not (Test-Contained $scratch $testBase)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
}

if ($failures.Count -eq 0) { Write-Host 'ALL REAL GLOBAL GENERATION CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
