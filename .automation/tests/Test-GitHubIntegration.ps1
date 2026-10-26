# Self-check for GitHub-Management.ps1 (GitHub integration).
# No network, no real token, no real home: Invoke-RestMethod is stubbed.
# Never touches the deployed %LOCALAPPDATA%\Shirube tree.
$ErrorActionPreference = 'Stop'

$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ('PASS: ' + $Name) }
  else { Write-Host ('FAIL: ' + $Name); $script:failures += $Name }
}

$devAuto = Split-Path -Parent $PSScriptRoot
$base = Join-Path ([System.IO.Path]::GetTempPath()) ('ShirubeGitHubTest-' + [System.Guid]::NewGuid().ToString('N'))
$auto = Join-Path $base '.automation'
$gPrev = Join-Path $base 'global-preview'
$pPrev = Join-Path $base 'project-common-preview'
New-Item -ItemType Directory -Force -Path $auto, $gPrev, $pPrev | Out-Null
$bareDir = Join-Path $base 'bare-rules'
New-Item -ItemType Directory -Force -Path $bareDir | Out-Null

# Fake configs shaped like the deployed preview dirs.
$cfgHead = '{' + "`n" + '  "$schema": "https://github.com/dyoshikawa/rulesync/releases/latest/download/config-schema.json",' + "`n" + '  "targets": ["codexcli", "opencode"],' + "`n" + '  "features": ["rules"],' + "`n" + '  "outputRoots": ["output"],' + "`n" + '  "delete": false,' + "`n" + '  "global": false,' + "`n" + '  "sources": [' + "`n"
$cfgGlobal = $cfgHead + '    { "source": "old/rules", "rules": ["global"] }' + "`n" + '  ]' + "`n" + '}'
$cfgProject = $cfgHead + '    { "source": "old/rules", "rules": ["project"] }' + "`n" + '  ]' + "`n" + '}'
Set-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Value $cfgGlobal -Encoding UTF8
Set-Content -LiteralPath (Join-Path $pPrev 'rulesync.jsonc') -Value $cfgProject -Encoding UTF8

# HTTP stub: records calls, serves canned rule files, can fail writes.
$script:GhCalls = @()
$script:GhFailWrites = $false
$script:GhFiles = @{}
function Invoke-RestMethod {
  [CmdletBinding()]
  param(
    [string]$Method = 'GET',
    [string]$Uri = '',
    $Headers = $null,
    [int]$TimeoutSec = 20,
    [switch]$UseBasicParsing,
    [string]$ContentType = '',
    $Body = $null
  )
  $script:GhCalls += @{ method = $Method; uri = $Uri; headers = $Headers; body = $Body }
  if (($Method -ne 'GET') -and $script:GhFailWrites) { throw [System.Exception]::new('403 Forbidden') }
  if ($Method -eq 'GET') {
    $key = (($Uri -split '\?')[0])
    if (-not $script:GhFiles.ContainsKey($key)) { throw [System.Exception]::new('404 Not Found') }
    $f = $script:GhFiles[$key]
    return [pscustomobject]@{ sha = $f.sha; content = ($f.content + "`n"); encoding = 'base64' }
  }
  return [pscustomobject]@{ content = @{ sha = 'new-sha' }; commit = @{ sha = 'commit-sha' } }
}

try {
  . (Join-Path $devAuto 'GitHub-Management.ps1')

  $nl = "`n"
  $ruleGlobal = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli"]' + $nl + 'description: "global"' + $nl + '---' + $nl + '# global body' + $nl)
  $ruleProject = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "antigravity-cli"]' + $nl + '---' + $nl + '# project body' + $nl)

  # T1: validation and normalization.
  Assert ((ConvertTo-GitHubRepoSlug 'https://github.com/Fizor-drm/ai-agent-rules') -ceq 'Fizor-drm/ai-agent-rules') 'T1 URL normalizes to owner/repo'
  Assert ((ConvertTo-GitHubRepoSlug 'Fizor-drm/ai-agent-rules.git') -ceq 'Fizor-drm/ai-agent-rules') 'T1 .git suffix trimmed'
  Assert (Test-GitHubRepoSlug 'Fizor-drm/ai-agent-rules') 'T1 owner/repo accepted'
  Assert (-not (Test-GitHubRepoSlug 'no-slash')) 'T1 missing owner rejected'
  Assert (-not (Test-GitHubRepoSlug 'a/b/c')) 'T1 extra segment rejected'
  Assert (-not (Test-GitHubBranch 'has space')) 'T1 branch space rejected'
  Assert (-not (Test-GitHubBranch '-nope')) 'T1 branch leading dash rejected'
  Assert (-not (Test-GitHubBranch 'a..b')) 'T1 branch .. rejected'
  Assert (Test-GitHubBranch 'feature/rules') 'T1 branch slash accepted'
  Assert (-not (Test-GitHubRulesPath '../escape')) 'T1 rules path .. rejected'
  Assert (-not (Test-GitHubRulesPath '/abs')) 'T1 rules path absolute rejected'
  Assert (Test-GitHubRulesPath 'config/rules') 'T1 nested rules path accepted'
  Assert ((ConvertTo-GitHubRulesPath '') -ceq 'rules') 'T1 empty path falls back to rules'
  Assert ((ConvertTo-GitHubRulesPath 'rules/') -ceq 'rules') 'T1 trailing slash trimmed'
  Assert ((ConvertTo-GitHubRulesPath './') -ceq '.') 'T1 root path stays dot'

  # T2: settings defaults and round-trip.
  $s0 = Get-GitHubSettings $auto
  Assert (($s0.repo -eq '') -and ($s0.branch -ceq 'main') -and ($s0.rulesPath -ceq 'rules')) 'T2 defaults when unset'
  $sv = Save-GitHubSettings $auto 'https://github.com/Fizor-drm/ai-agent-rules' 'main' 'rules'
  Assert (($sv.repo -ceq 'Fizor-drm/ai-agent-rules') -and ($sv.rulesPath -ceq 'rules')) 'T2 save normalizes values'
  $s1 = Get-GitHubSettings $auto
  Assert (($s1.repo -ceq 'Fizor-drm/ai-agent-rules') -and ($s1.branch -ceq 'main')) 'T2 settings round-trip'
  Assert ((Test-Path -LiteralPath (Join-Path $auto 'github-settings.json') -PathType Leaf)) 'T2 settings file written'
  $bad = $false
  try { Save-GitHubSettings $auto 'not a repo' 'main' 'rules' | Out-Null } catch { $bad = $true }
  Assert $bad 'T2 invalid repo refused'

  # T3: both local source configs follow the settings.
  $gj = Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8 | ConvertFrom-Json
  $pj = Get-Content -LiteralPath (Join-Path $pPrev 'rulesync.jsonc') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ([string]$gj.sources[0].source -ceq 'Fizor-drm/ai-agent-rules@main') 'T3 global source repointed'
  Assert ([string]$pj.sources[0].source -ceq 'Fizor-drm/ai-agent-rules@main') 'T3 project source repointed'
  Assert ([string]$gj.sources[0].rules[0] -ceq 'global') 'T3 global rule name kept'
  Assert ([string]$pj.sources[0].rules[0] -ceq 'project') 'T3 project rule name kept'
  Assert (-not $gj.sources[0].PSObject.Properties['rulesPath']) 'T3 default rulesPath omitted'
  Assert (([string]$gj.targets[0] -ceq 'codexcli') -and ([string]$gj.features[0] -ceq 'rules')) 'T3 unrelated config keys preserved'
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'dev' 'config/rules' | Out-Null
  $gj2 = Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ([string]$gj2.sources[0].source -ceq 'Fizor-drm/ai-agent-rules@dev') 'T3 branch reflected'
  Assert ([string]$gj2.sources[0].rulesPath -ceq 'config/rules') 'T3 custom rulesPath written'
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'dev' '.' | Out-Null
  $gj3 = Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert ([string]$gj3.sources[0].rulesPath -ceq '.') 'T3 repo root written as dot'

  # T3b: a JSONC config keeps its comments and unrelated text through the save.
  $jsonc = ('{' + "`n" +
    '  // local overrides' + "`n" +
    '  "$schema": "schema.json",' + "`n" +
    '  "targets": ["codexcli"], /* keep */' + "`n" +
    '  "sources": [' + "`n" +
    '    { "source": "old/rules", "rules": ["global"] } // old' + "`n" +
    '  ]' + "`n" +
    '}' + "`n")
  Set-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Value $jsonc -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $pPrev 'rulesync.jsonc') -Value '{"targets":["pi"],"sources":[]}' -Encoding Ascii
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'main' 'rules' | Out-Null
  $gRaw = Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8
  Assert (($gRaw.Contains('// local overrides')) -and ($gRaw.Contains('/* keep */'))) 'T3b comments in the config survive the save'
  Assert ($gRaw.Contains('"targets": ["codexcli"]')) 'T3b unrelated keys and formatting survive the save'
  $gJ3b = $null
  if (Get-Command ConvertFrom-GitHubJsonc -ErrorAction SilentlyContinue) { $gJ3b = ConvertFrom-GitHubJsonc $gRaw }
  Assert (($null -ne $gJ3b) -and ([string]$gJ3b.sources[0].source -ceq 'Fizor-drm/ai-agent-rules@main')) 'T3b sources repointed in a JSONC config'

  foreach ($cfg in @(
    ('{"targets":["pi"] // keep' + "`n}"),
    '{"targets":["pi"]} // trailing }',
    ('// leading {' + "`n" + '{ /* empty } */ }'),
    '{"\u0073ources":[],"targets":["pi"]}'
  )) {
    $rewritten = Set-GitHubSourceConfigText $cfg @{ source = 'new/repo@main'; rules = @('global') }
    $parsed = ConvertFrom-GitHubJsonc $rewritten
    Assert (($null -ne $parsed) -and ([string]$parsed.sources[0].source -ceq 'new/repo@main')) 'T3b insertion and escaped keys produce valid JSONC'
    if ($cfg.Contains('\u0073ources')) {
      Assert (-not $rewritten.Contains('"sources"')) 'T3b escaped source key is replaced without adding a duplicate key'
    }
  }

  # T3c: every input is validated before the first write (all-or-nothing).
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'main' 'rules' | Out-Null
  $settingsBefore = Get-Content -LiteralPath (Join-Path $auto 'github-settings.json') -Raw -Encoding UTF8
  $gBefore = Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8
  $lockedCfg = $null
  $failedSave = $false
  try {
    $lockedCfg = [System.IO.File]::Open((Join-Path $pPrev 'rulesync.jsonc'), 'Open', 'ReadWrite', 'None')
    Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'other' 'rules2' | Out-Null
  } catch { $failedSave = $true } finally { if ($lockedCfg) { $lockedCfg.Close() } }
  Assert ($failedSave) 'T3c unreadable config refuses the save'
  Assert ((Get-Content -LiteralPath (Join-Path $auto 'github-settings.json') -Raw -Encoding UTF8) -ceq $settingsBefore) 'T3c failed save leaves the settings unchanged'
  Assert ((Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8) -ceq $gBefore) 'T3c failed save leaves the other config unchanged'

  # T3d: a write failure mid-transaction rolls back every file already written.
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'main' 'rules' | Out-Null
  $setBefore3d = Get-Content -LiteralPath (Join-Path $auto 'github-settings.json') -Raw -Encoding UTF8
  $gBefore3d = Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8
  $pBefore3d = Get-Content -LiteralPath (Join-Path $pPrev 'rulesync.jsonc') -Raw -Encoding UTF8
  $origWriteText = (Get-Item function:Write-GitHubPrivateText).ScriptBlock
  $script:ghWriteCalls = 0
  function Write-GitHubPrivateText { param([string]$Path, [string]$Text)
    $script:ghWriteCalls++
    if ($script:ghWriteCalls -eq 3) { throw 'injected-write-fail' }
    & $origWriteText $Path $Text
  }
  $midFail = $false
  try { Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'dev' 'other' | Out-Null }
  catch { $midFail = $true }
  finally { Set-Item -Path function:Write-GitHubPrivateText -Value $origWriteText -Force }
  Assert ($midFail) 'T3d mid-transaction write failure is reported'
  Assert ((Get-Content -LiteralPath (Join-Path $auto 'github-settings.json') -Raw -Encoding UTF8) -ceq $setBefore3d) 'T3d settings rolled back'
  Assert ((Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8) -ceq $gBefore3d) 'T3d first written config rolled back'
  Assert ((Get-Content -LiteralPath (Join-Path $pPrev 'rulesync.jsonc') -Raw -Encoding UTF8) -ceq $pBefore3d) 'T3d unwritten config unchanged'

  $script:ghWriteCalls = 0
  function Write-GitHubPrivateText { param([string]$Path, [string]$Text)
    $script:ghWriteCalls++
    & $origWriteText $Path $Text
    if ($script:ghWriteCalls -eq 3) { throw 'injected-after-publish-fail' }
  }
  $partialFail = $false
  try { Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'dev' 'other' | Out-Null }
  catch { $partialFail = $true }
  finally { Set-Item -Path function:Write-GitHubPrivateText -Value $origWriteText -Force }
  Assert $partialFail 'T3d failure after publication is reported'
  Assert ((Get-Content -LiteralPath (Join-Path $auto 'github-settings.json') -Raw -Encoding UTF8) -ceq $setBefore3d) 'T3d published failure restores settings'
  Assert ((Get-Content -LiteralPath (Join-Path $gPrev 'rulesync.jsonc') -Raw -Encoding UTF8) -ceq $gBefore3d) 'T3d published failure restores first config'
  Assert ((Get-Content -LiteralPath (Join-Path $pPrev 'rulesync.jsonc') -Raw -Encoding UTF8) -ceq $pBefore3d) 'T3d published failure restores the failing config too'

  # T4: token is encrypted at rest and never stored in plain text.
  Assert ((Get-GitHubToken $auto) -eq '') 'T4 no token by default'
  $tok = 'ghp_' + ('A' * 36)
  $badTok = $false
  try { Save-GitHubToken $auto 'short' | Out-Null } catch { $badTok = $true }
  Assert $badTok 'T4 malformed token refused'
  Save-GitHubToken $auto $tok | Out-Null
  $raw = Get-Content -LiteralPath (Join-Path $auto 'github-token.dat') -Raw -Encoding UTF8
  Assert (-not $raw.Contains($tok)) 'T4 token file holds no plain text'
  Assert ((Get-GitHubToken $auto) -ceq $tok) 'T4 token round-trip'
  Assert ((Get-GitHubTokenSource $auto) -ceq 'saved') 'T4 source reports saved token'
  $tok2 = 'ghp_' + ('B' * 36)
  Save-GitHubToken $auto $tok2 | Out-Null
  Assert ((Get-GitHubToken $auto) -ceq $tok2) 'T4b cached saved token follows a rewritten token file'
  Save-GitHubToken $auto $tok | Out-Null
  $script:GitHubCliTokenCache = @{ at = (Get-Date); value = 'cli-cached-value' }
  Assert ((Get-GitHubSyncToken $bareDir) -ceq 'cli-cached-value') 'T4b fresh CLI token cache avoids spawning gh again'
  $script:GitHubCliTokenCache = $null

  # T5: frontmatter targets edit (one-line array only).
  $r1 = Update-GitHubTargetsText $ruleGlobal @('codexcli', 'antigravity-cli')
  Assert ($r1.ok -and $r1.changed) 'T5 missing target added'
  Assert (($r1.added -join ',') -ceq 'antigravity-cli') 'T5 added list'
  Assert ($r1.text.Contains('targets: ["codexcli", "antigravity-cli"]')) 'T5 array rewritten'
  Assert ($r1.text.Contains('# global body')) 'T5 body preserved'
  $r2 = Update-GitHubTargetsText $ruleGlobal @('codexcli')
  Assert ($r2.ok -and (-not $r2.changed)) 'T5 existing target is a no-op'
  $r3 = Update-GitHubTargetsText ('---' + $nl + 'targets:' + $nl + '  - codexcli' + $nl + '---' + $nl) @('pi')
  Assert ((-not $r3.ok) -and ($r3.error -ne '')) 'T5 block list refused'
  $r4 = Update-GitHubTargetsText ('---' + $nl + 'root: true' + $nl + '---' + $nl) @('pi')
  Assert ((-not $r4.ok) -and ($r4.error -ne '')) 'T5 missing targets refused'
  $r5 = Update-GitHubTargetsText ('no frontmatter' + $nl) @('pi')
  Assert (-not $r5.ok) 'T5 missing frontmatter refused'
  $r6 = Update-GitHubTargetsText (('---' + "`r`n" + 'targets: ["a"]' + "`r`n" + '---' + "`r`n" + 'body' + "`r`n")) @('b')
  Assert ($r6.text.Contains("`r`n")) 'T5 CRLF preserved'
  $ruleWildcard = ('---' + $nl + 'root: true' + $nl + 'targets: ["*"]' + $nl + '---' + $nl + '# wildcard body' + $nl)
  Assert (Test-GitHubRuleFrontmatter $ruleWildcard 'global') 'T5 wildcard rule is editable before update'
  $r7 = Update-GitHubTargetsText $ruleWildcard @('codexcli', 'opencode')
  Assert ($r7.ok -and (-not $r7.changed)) 'T5 wildcard target is a no-op'
  Assert ([string]$r7.text -ceq $ruleWildcard) 'T5 wildcard text unchanged'
  Assert ($r7.added.Count -eq 0) 'T5 wildcard adds no target'
  Assert (Test-GitHubRuleFrontmatter $r7.text 'global') 'T5 wildcard rule stays editable after update'
  # T5b: the trailing comment the validator accepts must survive the rewrite.
  $ruleComment = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"] # base' + $nl + '---' + $nl + '# commented body' + $nl)
  $r8 = Update-GitHubTargetsText $ruleComment @('pi')
  Assert ($r8.ok -and $r8.changed) 'T5b rule with a trailing comment is editable'
  Assert ($r8.text.Contains('targets: ["codexcli", "opencode", "pi"] # base')) 'T5b trailing comment is preserved'
  Assert (Test-GitHubRuleFrontmatter $r8.text 'project') 'T5b rewritten text still passes the validator'

  # T6: adding targets commits only the file that changed.
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'dev' 'rules' | Out-Null
  $script:GhFiles = @{}
  $script:GhFiles['https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/global.md'] = @{ sha = 'sha-global'; content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ruleGlobal)) }
  $script:GhFiles['https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/project.md'] = @{ sha = 'sha-project'; content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ruleProject)) }
  $script:GhCalls = @()
  $up = Update-GitHubRuleTargets $auto @('codexcli', 'antigravity-cli')
  Assert $up.ok 'T6 update reports ok'
  Assert ($up.files.Count -eq 2) 'T6 both rule files inspected'
  $fGlobal = @($up.files | Where-Object { $_.name -ceq 'global' })[0]
  $fProject = @($up.files | Where-Object { $_.name -ceq 'project' })[0]
  Assert (($fGlobal.added -join ',') -ceq 'antigravity-cli') 'T6 global target added'
  Assert ($fProject.added.Count -eq 0) 'T6 project file already covers the target'
  $puts = @($script:GhCalls | Where-Object { $_.method -ne 'GET' })
  Assert ($puts.Count -eq 1) 'T6 only the changed file is committed'
  Assert ($puts[0].uri -ceq 'https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/global.md') 'T6 commit hits the rule path'
  $putBody = [string]$puts[0].body | ConvertFrom-Json
  Assert ([string]$putBody.branch -ceq 'dev') 'T6 commit targets the configured branch'
  Assert ([string]$putBody.sha -ceq 'sha-global') 'T6 commit uses the fetched sha'
  Assert (([string]$putBody.message).Contains('antigravity-cli')) 'T6 commit message names the target'
  $sent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$putBody.content))
  Assert ($sent.Contains('targets: ["codexcli", "antigravity-cli"]')) 'T6 committed content has the target'
  Assert (-not ([string]$putBody.content).Contains($tok)) 'T6 token never written into the commit'

  # T6g: a fetched rule the validator rejects must never be committed.
  $ruleDup = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "codexcli"]' + $nl + '---' + $nl + '# dup body' + $nl)
  $ruleProjectPi = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode", "pi"]' + $nl + '---' + $nl + '# project body' + $nl)
  $script:GhFiles = @{}
  $script:GhFiles['https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/global.md'] = @{ sha = 'sha-global'; content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ruleDup)) }
  $script:GhFiles['https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/project.md'] = @{ sha = 'sha-project'; content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ruleProjectPi)) }
  $script:GhCalls = @()
  $upDup = Update-GitHubRuleTargets $auto @('pi')
  Assert (-not $upDup.ok) 'T6g duplicate-target rule reports a failure'
  Assert (@($script:GhCalls | Where-Object { ($_.method -ne 'GET') -and ($_.uri -like '*global.md') }).Count -eq 0) 'T6g invalid rewritten frontmatter is never committed'

  # T6b: rule editor frontmatter contract.
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project') 'T6b project frontmatter accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["pi"]' + $nl + '---' + $nl) 'global') 'T6b global frontmatter accepted'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b missing root rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets:' + $nl + '  - pi' + $nl + '---' + $nl) 'global')) 'T6b block targets rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["Pi"]' + $nl + '---' + $nl) 'global')) 'T6b uppercase slug rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["pi", "pi"]' + $nl + '---' + $nl) 'global')) 'T6b duplicate targets rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli"]' + $nl + '---' + $nl) 'project')) 'T6b project missing a base target rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('body' + $nl + '---' + $nl + 'root: true' + $nl + 'targets: ["pi"]' + $nl + '---' + $nl) 'global')) 'T6b leading text rejected'
  # README standard: global.md may omit targets (all targets implied by root: true)
  # or use the ["*"] wildcard.
  $ruleGlobalBare = ('---' + $nl + 'root: true' + $nl + 'description: "global"' + $nl + '---' + $nl + '# global body' + $nl)
  Assert (Test-GitHubRuleFrontmatter $ruleGlobalBare 'global') 'T6b global without targets accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["*"]' + $nl + '---' + $nl) 'global') 'T6b global wildcard target accepted'
  Assert (-not (Test-GitHubRuleFrontmatter $ruleGlobalBare 'project')) 'T6b project still requires targets'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["*"]' + $nl + '---' + $nl) 'project')) 'T6b project wildcard rejected'
  # Same quoting and slug contract as Sync-ProjectRules.ps1:126.
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + "targets: ['codexcli', 'opencode']" + $nl + '---' + $nl) 'project')) 'T6b single-quoted project targets rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: [codexcli, opencode]' + $nl + '---' + $nl) 'project')) 'T6b unquoted project targets rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codex_cli", "opencode"]' + $nl + '---' + $nl) 'global')) 'T6b underscore slug rejected'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"] # base' + $nl + '---' + $nl) 'project') 'T6b trailing comment accepted'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + '  targets: ["pi"]' + $nl + '---' + $nl) 'global')) 'T6b indented targets rejected'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "common"' + $nl + '---' + $nl) 'project') 'T6b quoted description accepted'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: common' + $nl + '---' + $nl) 'project')) 'T6b unquoted description rejected'
  # YAML requires a space after a mapping colon; `description:"x"` breaks the real parser at sync time.
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description:"common"' + $nl + '---' + $nl) 'project')) 'T6b description without space after colon rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root:true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b root without space after colon rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets:["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b targets without space after colon rejected'
  # An unescaped inner quote passes a greedy ".*" but is invalid YAML.
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "say "hello" to everyone"' + $nl + '---' + $nl) 'project')) 'T6b unescaped quote in description rejected'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "say \"hello\" to everyone"' + $nl + '---' + $nl) 'project') 'T6b escaped quote in description accepted'
  # Only YAML 1.2 escapes pass; anything else would fail the real parser at sync time.
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "bad \q escape"' + $nl + '---' + $nl) 'project')) 'T6b invalid \q escape rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "path C:\Users\test"' + $nl + '---' + $nl) 'project')) 'T6b bare backslash path rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "bad \xGG"' + $nl + '---' + $nl) 'project')) 'T6b invalid \xGG escape rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "bad \E escape"' + $nl + '---' + $nl) 'project')) 'T6b invalid uppercase \E escape rejected'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "quote \" slash \\ tab \t nl \n u \u3042 x \x20"' + $nl + '---' + $nl) 'project') 'T6b valid YAML 1.2 escapes accepted'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b duplicate root rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'localRoot: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b root/localRoot mix rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'foo: bar' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b unknown frontmatter key rejected'
  # YAML needs whitespace before an inline comment: `true#c` parses as the string "true#c".
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true#comment' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b root comment without whitespace rejected'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true # comment' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project') 'T6b root comment with whitespace accepted'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]#c' + $nl + '---' + $nl) 'project')) 'T6b targets comment without whitespace rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "common"#c' + $nl + '---' + $nl) 'project')) 'T6b description comment without whitespace rejected'
  # YAML keys are case-sensitive: `Root` is not `root`, so the required key would be missing.
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'Root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project')) 'T6b capitalized Root key rejected'
  # Trailing whitespace is valid YAML and must not reject an otherwise clean rule.
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true  ' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project') 'T6b root trailing whitespace accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]  ' + $nl + '---' + $nl) 'project') 'T6b targets trailing whitespace accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + 'description: "common"  ' + $nl + '---' + $nl) 'project') 'T6b description trailing whitespace accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["*"]  ' + $nl + '---' + $nl) 'global') 'T6b wildcard trailing whitespace accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true  # comment  ' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) 'project') 'T6b whitespace around a comment accepted'
  # rulesync 42.0.0 accepts only its ToolTarget enum: `claude-code` is not a
  # target (the canonical slug is `claudecode`) and breaks the next sync.
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode", "claude-code"]' + $nl + '---' + $nl) 'project')) 'T6b unsupported project target rejected'
  Assert (-not (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["claude-code"]' + $nl + '---' + $nl) 'global')) 'T6b unsupported global target rejected'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode", "claudecode"]' + $nl + '---' + $nl) 'project') 'T6b canonical claudecode target accepted'
  Assert (Test-GitHubRuleFrontmatter ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode", "androidstudio", "firebender", "opencodev1", "xum"]' + $nl + '---' + $nl) 'project') 'T6b rulesync 42 targets accepted'

  # T6c: read and write one rule file through the shared helpers.
  Save-GitHubSettings $auto 'Fizor-drm/ai-agent-rules' 'dev' 'rules' | Out-Null
  $script:GhFiles = @{}
  $script:GhFiles['https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/global.md'] = @{ sha = 'sha-global'; content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ruleGlobal)) }
  $script:GhFiles['https://api.github.com/repos/Fizor-drm/ai-agent-rules/contents/rules/project.md'] = @{ sha = 'sha-project'; content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ruleProject)) }
  $got = Get-GitHubRuleContent $auto 'global'
  Assert ($got.ok -and ($got.sha -ceq 'sha-global') -and ($got.path -ceq 'rules/global.md')) 'T6c get returns sha and path'
  Assert (($got.repo -ceq 'Fizor-drm/ai-agent-rules') -and ($got.branch -ceq 'dev')) 'T6c get returns the fetched origin'
  Assert ($got.text.Contains('# global body')) 'T6c get returns raw text'
  $missingKind = Get-GitHubRuleContent $auto 'other'
  Assert (-not $missingKind.ok) 'T6c unknown kind refused'
  $bare = Get-GitHubRuleContent $bareDir 'global'
  Assert (-not $bare.ok) 'T6c unconfigured integration fails closed'

  $script:GhCalls = @()
  $conflict = Save-GitHubRuleContent $auto 'global' $ruleGlobal 'sha-stale'
  Assert ((-not $conflict.ok) -and $conflict.conflict -and ($conflict.sha -ceq 'sha-global')) 'T6c stale sha reports the current sha'
  Assert (@($script:GhCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'T6c conflict never commits'

  $script:GhCalls = @()
  $saved = Save-GitHubRuleContent $auto 'global' $ruleGlobal 'sha-global'
  Assert ($saved.ok -and ($saved.path -ceq 'rules/global.md')) 'T6c save reports ok and path'
  $rulePut = @($script:GhCalls | Where-Object { $_.method -ne 'GET' })[0]
  $rulePutBody = [string]$rulePut.body | ConvertFrom-Json
  Assert ([string]$rulePutBody.sha -ceq 'sha-global') 'T6c save commits the read sha'
  $ruleSent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$rulePutBody.content))
  Assert ($ruleSent -ceq $ruleGlobal) 'T6c save writes the edited text verbatim'

  $script:GhCalls = @()
  $invalid = Save-GitHubRuleContent $auto 'global' 'no frontmatter' 'sha-global'
  Assert (-not $invalid.ok) 'T6c invalid frontmatter refused before commit'
  Assert (@($script:GhCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) 'T6c invalid frontmatter never commits'

  # A missing space after the colon is invalid YAML and would break the next sync.
  foreach ($case in @(
    @{ name = 'root without space after the colon'; text = ('---' + $nl + 'root:true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) },
    @{ name = 'targets without space after the colon'; text = ('---' + $nl + 'root: true' + $nl + 'targets:["codexcli", "opencode"]' + $nl + '---' + $nl) },
    @{ name = 'root comment without space before #'; text = ('---' + $nl + 'root: true#comment' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) },
    @{ name = 'capitalized Root key'; text = ('---' + $nl + 'Root: true' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl) }
  )) {
    $script:GhCalls = @()
    $noSpace = Save-GitHubRuleContent $auto 'project' ([string]$case.text) 'sha-project'
    Assert (-not $noSpace.ok) ('T6c ' + $case.name + ' refused before commit')
    Assert (@($script:GhCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 0) ('T6c ' + $case.name + ' never commits')
  }

  # The same comment with a space before `#` is valid YAML and must save.
  $script:GhCalls = @()
  $spacedComment = Save-GitHubRuleContent $auto 'project' ('---' + $nl + 'root: true # comment' + $nl + 'targets: ["codexcli", "opencode"]' + $nl + '---' + $nl + '# project body' + $nl) 'sha-project'
  Assert ($spacedComment.ok) 'T6c root comment with space before # saves'
  Assert (@($script:GhCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 1) 'T6c root comment with space before # commits'

  # T6e: an unsupported target is refused before any GitHub call.
  foreach ($case in @(
    @{ kind = 'global'; text = ('---' + $nl + 'root: true' + $nl + 'targets: ["claude-code"]' + $nl + '---' + $nl) },
    @{ kind = 'project'; text = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode", "claude-code"]' + $nl + '---' + $nl) }
  )) {
    $script:GhCalls = @()
    $badTarget = Save-GitHubRuleContent $auto ([string]$case.kind) ([string]$case.text) ('sha-' + [string]$case.kind)
    Assert (-not $badTarget.ok) ('T6e unsupported ' + $case.kind + ' target refused')
    Assert (@($script:GhCalls).Count -eq 0) ('T6e unsupported ' + $case.kind + ' target never touches GitHub')
  }
  $script:GhCalls = @()
  $canonical = Save-GitHubRuleContent $auto 'project' ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli", "opencode", "claudecode"]' + $nl + '---' + $nl) 'sha-project'
  Assert ($canonical.ok) 'T6e canonical claudecode target saves'
  Assert (@($script:GhCalls | Where-Object { $_.method -ne 'GET' }).Count -eq 1) 'T6e canonical claudecode target commits'

  $ruleGlobalWild = ('---' + $nl + 'root: true' + $nl + 'targets: ["*"]' + $nl + '---' + $nl + '# global body' + $nl)
  foreach ($case in @(@{ name = 'without targets'; text = $ruleGlobalBare }, @{ name = 'with a wildcard target'; text = $ruleGlobalWild })) {
    $script:GhCalls = @()
    $savedGlobal = Save-GitHubRuleContent $auto 'global' ([string]$case.text) 'sha-global'
    Assert ($savedGlobal.ok -and ($savedGlobal.kind -ceq 'global')) ('T6c global rule ' + $case.name + ' saves')
    $gPut = @($script:GhCalls | Where-Object { $_.method -ne 'GET' })[0]
    $gBody = [string]$gPut.body | ConvertFrom-Json
    $gSent = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$gBody.content))
    Assert ($gSent -ceq [string]$case.text) ('T6c saved global rule ' + $case.name + ' keeps its text')
  }

  # T6d: a save is bound to the origin it was loaded from.
  foreach ($bad in @(
    @{ name = 'repository'; repo = 'other/repo'; branch = 'dev'; path = 'rules/global.md' },
    @{ name = 'branch'; repo = 'Fizor-drm/ai-agent-rules'; branch = 'other'; path = 'rules/global.md' },
    @{ name = 'path'; repo = 'Fizor-drm/ai-agent-rules'; branch = 'dev'; path = 'other/global.md' }
  )) {
    $script:GhCalls = @()
    $badSave = Save-GitHubRuleContent $auto 'global' $ruleGlobal 'sha-global' ([string]$bad.repo) ([string]$bad.branch) ([string]$bad.path)
    Assert ((-not $badSave.ok) -and $badSave.conflict) ('T6d save into another ' + $bad.name + ' is refused')
    Assert (@($script:GhCalls).Count -eq 0) ('T6d refused ' + $bad.name + ' change never touches GitHub')
  }
  $script:GhCalls = @()
  $pinned = Save-GitHubRuleContent $auto 'global' $ruleGlobal 'sha-global' 'Fizor-drm/ai-agent-rules' 'dev' 'rules/global.md'
  Assert ($pinned.ok -and ($pinned.repo -ceq 'Fizor-drm/ai-agent-rules') -and ($pinned.branch -ceq 'dev')) 'T6d matching origin saves'

  # T7: a write failure is reported, does not throw, and leaks no token.
  $script:GhFailWrites = $true
  $script:GhCalls = @()
  $upBad = Update-GitHubRuleTargets $auto @('pi')
  Assert (-not $upBad.ok) 'T7 failure reported'
  Assert ($upBad.error -ne '') 'T7 failure carries a reason'
  Assert ($upBad.files.Count -eq 2) 'T7 both files still reported'
  Assert (-not ((ConvertTo-Json -InputObject $upBad -Depth 8).Contains($tok))) 'T7 failure payload has no token'
  Assert (@($script:GhCalls | Where-Object { $_.method -eq 'GET' }).Count -eq 2) 'T7 failure still read both files'
  $script:GhFailWrites = $false

  # T8: unconfigured / tokenless paths are reported, not thrown.
  $autoBare = Join-Path $base 'bare'
  New-Item -ItemType Directory -Force -Path $autoBare | Out-Null
  $u0 = Update-GitHubRuleTargets $autoBare @('pi')
  Assert ((-not $u0.ok) -and $u0.skipped) 'T8 unconfigured integration skipped cleanly'

  # T9: dashboard and sync wiring exists (static contract).
  $server = Get-Content -LiteralPath (Join-Path $devAuto 'Dashboard-Server.ps1') -Raw -Encoding UTF8
  Assert ($server.Contains("'/api/github-settings'") -and $server.Contains("'/api/github-test'")) 'T9 endpoints registered'
  Assert ($server.Contains("'/api/github-rule-get'") -and $server.Contains("'/api/github-rule-save'")) 'T9 rule editor endpoints registered'
  Assert ($server.Contains('Read-Body $req 262144')) 'T9 rule editor accepts the 256KB body'
  Assert ($server.Contains("Open-GlobalSyncLock `$AutoDir") -and $server.Contains("'Sync-ProjectRules.lock'")) 'T9 rule save honors both sync locks'
  Assert ($server.Contains('id="rulesGate"') -and $server.Contains('id="ruleText"') -and $server.Contains('class="rules-grid"')) 'T9 rule editor screen exists'
  $ghm = Get-Content -LiteralPath (Join-Path $devAuto 'GitHub-Management.ps1') -Raw -Encoding UTF8
  Assert (($ghm.Contains('GitHubCliTokenCache')) -and ($ghm.Contains('GitHubSavedTokenCache'))) 'T9 token lookups are cached'
  Assert ($server.Contains('Update-GitHubRuleTargets $AutoDir $tgNew')) 'T9 target save hooks the GitHub update'
  Assert ($server.Contains('Save-GitHubRuleContent $AutoDir $gk ([string]$body.text) ([string]$body.sha) $expRepo $expBranch $expPath')) 'T9 rule save forwards the loaded origin'
  Assert ($server.Contains('id="btnGitHub"') -and $server.Contains('id="ghOvl"') -and $server.Contains('id="ghToken"')) 'T9 topbar button and dialog exist'
  Assert ($server.Contains('href="https://github.com/settings/personal-access-tokens/new"')) 'T9 token creation link exists'
  Assert ($server.Contains('class="ghsecret"') -and $server.Contains('id="ghEyeOn"') -and $server.Contains('id="ghEyeOff"')) 'T9 inside-field token visibility toggle exists'
  Assert ($server.Contains('id="ghSummaryText"') -and $server.Contains('id="ghTree"') -and $server.Contains('id="ghCancel"')) 'T9 beginner-friendly summary tree and cancel button exist'
  Assert (-not $server.Contains('id="ghToken" value=')) 'T9 token field is never pre-filled'
  Assert (-not $server.Contains('id="ghBranch" class="mono" value=')) 'T9 branch field is not pre-filled'
  Assert (-not $server.Contains('ghEl("ghRepo").value = "Fizor-drm/Shirube"')) 'T9 repo field is not pre-filled with a sample'
  Assert ($server.Contains('ghEl("ghBranch").value.trim() || "main"')) 'T9 empty branch falls back to main'
  Assert ($server.Contains('toggleAttribute("hidden"') -and $server.Contains('on.hidden = !!show') -and $server.Contains('off.hidden = !show')) 'T9 eye icons toggle the hidden attribute on SVG'
  Assert ($server.Contains('global.md / project.md')) 'T9 tree preview names the real synced files'
  Assert ($server.Contains('color:#0b0b0c')) 'T9 recommended badge text uses the dark on-accent color'
  Assert ($server.Contains('customNorm === "./" ? ""')) 'T9 custom "." preview targets the repository root'
  $sg = Get-Content -LiteralPath (Join-Path $devAuto 'Sync-GlobalRules.ps1') -Raw -Encoding UTF8
  $sp = Get-Content -LiteralPath (Join-Path $devAuto 'Sync-ProjectRules.ps1') -Raw -Encoding UTF8
  Assert ($sg.Contains('Get-GitHubSyncToken') -and $sp.Contains('Get-GitHubSyncToken')) 'T9 both syncs prefer the stored token'

  # T9b: the save endpoint answers 409 when the origin changed after loading.
  $origPort = $env:DASHBOARD_PORT
  $origAutoDirEnv = $env:DASHBOARD_AUTODIR
  $env:DASHBOARD_PORT = '18801'
  $env:DASHBOARD_AUTODIR = $auto
  $srv = $null
  try {
    $srv = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $devAuto 'Dashboard-Server.ps1') -WindowStyle Hidden -PassThru
    $up2 = $false
    for ($i = 0; $i -lt 40; $i++) {
      Start-Sleep -Milliseconds 250
      try { if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18801/health').StatusCode -eq 200) { $up2 = $true; break } } catch {}
      if ($srv.HasExited) { break }
    }
    Assert ($up2) 'T9b scratch dashboard responds'
    if ($up2) {
      $dtok = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $hdr = @{ 'X-Dashboard-Token' = $dtok }
      foreach ($badOrigin in @(
        @{ name = 'repository'; repo = 'other/repo'; branch = 'dev'; path = 'rules/global.md' },
        @{ name = 'branch'; repo = 'Fizor-drm/ai-agent-rules'; branch = 'other'; path = 'rules/global.md' },
        @{ name = 'path'; repo = 'Fizor-drm/ai-agent-rules'; branch = 'dev'; path = 'other/global.md' }
      )) {
        $code = 0
        try {
          Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdr -ContentType 'application/json' -Body (@{ kind = 'global'; text = $ruleGlobal; sha = 'sha-global'; repo = [string]$badOrigin.repo; branch = [string]$badOrigin.branch; path = [string]$badOrigin.path } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18801/api/github-rule-save' | Out-Null
        } catch { $code = $_.Exception.Response.StatusCode.value__ }
        Assert ($code -eq 409) ('T9b save with a changed ' + $badOrigin.name + ' is a 409')
      }
      # A project sync holding the lock must answer 409 (busy), not 500.
      $heldProj = $null
      $codeProj = 0
      try {
        $heldProj = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
          Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdr -ContentType 'application/json' -Body (@{ kind = 'project'; text = $ruleProject; sha = 'sha-project'; repo = 'Fizor-drm/ai-agent-rules'; branch = 'dev'; path = 'rules/project.md' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18801/api/github-rule-save' | Out-Null
        } catch { $codeProj = $_.Exception.Response.StatusCode.value__ }
      } finally { if ($heldProj) { try { $heldProj.Close() } catch {} } }
      Assert ($codeProj -eq 409) 'T9b project save while the sync lock is held is a 409'
    }
  } finally {
    if ($srv -and (-not $srv.HasExited)) { try { Stop-Process -Id $srv.Id -Force } catch {} }
    $env:DASHBOARD_PORT = $origPort
    $env:DASHBOARD_AUTODIR = $origAutoDirEnv
  }

  # T10: no leftover plaintext token or settings in the test tree.
  $leak = @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object { $c = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8; ($null -ne $c) -and ([string]$c).Contains($tok) })
  Assert ($leak.Count -eq 0) 'T10 no token written outside the DPAPI file'
}
finally {
  try { Remove-Item -LiteralPath $base -Recurse -Force } catch {}
}

if ($failures.Count -gt 0) {
  Write-Host ('FAILURES: ' + ($failures -join '; '))
  exit 1
}
Write-Host 'ALL GITHUB INTEGRATION CHECKS PASSED'
