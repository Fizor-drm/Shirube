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
  $ruleGlobal = ('---' + $nl + 'root: true' + $nl + 'targets: ["codexcli"]' + $nl + 'description: global' + $nl + '---' + $nl + '# global body' + $nl)
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
  Assert ($server.Contains('Update-GitHubRuleTargets $AutoDir $tgNew')) 'T9 target save hooks the GitHub update'
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

  # T10: no leftover plaintext token or settings in the test tree.
  $leak = @(Get-ChildItem -LiteralPath $base -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8).Contains($tok) })
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
