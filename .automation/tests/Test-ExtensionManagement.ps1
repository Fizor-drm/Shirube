# Test-ExtensionManagement.ps1 - regression checks for Extension-Management.ps1.
# Scratch-only: every home/auto path is created under the system temp folder.
$ErrorActionPreference = 'Stop'
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Assert-Throws([scriptblock]$Block, [string]$Name) {
  $threw = $false
  try { & $Block } catch { $threw = $true }
  Assert $threw $Name
}

$devAuto = Split-Path -Parent $PSScriptRoot
. (Join-Path $devAuto 'Extension-Management.ps1')

$testBase = Join-Path ([System.IO.Path]::GetTempPath()) ('ExtMgmtTest-' + [System.Guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $testBase 'home'
$auto = Join-Path $testBase 'auto'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.config\opencode') | Out-Null
New-Item -ItemType Directory -Force -Path $auto | Out-Null

$savedGh = $env:GITHUB_TOKEN
$savedGh2 = $env:GH_TOKEN
$env:GITHUB_TOKEN = $null
$env:GH_TOKEN = $null
try {
  # T1: OpenCode local MCP command array starts with the executable.
  $serverJson = Ext-JsonBuildMcpValue 'opencode' 'stdio' 'npx' @('-y', 'pkg') '' @() @()
  $server = $serverJson | ConvertFrom-Json
  Assert ($server.type -eq 'local') 'T1 type local'
  Assert (@($server.command).Count -eq 3) 'T1 command count'
  Assert ([string]$server.command[0] -eq 'npx') 'T1 command first element'
  $codexText = Ext-CodexAddMcp '' 'codex-srv' 'stdio' 'npx' @('-y', 'pkg') '' @() @()
  Assert ($codexText.Contains('args = ["-y", "pkg"]')) 'T1b Codex args preserved'
  $req = [pscustomobject]@{ name = 'reqsrv'; transport = 'stdio'; command = 'npx'; args = @('-y', 'pkg'); url = ''; envLines = ''; headerLines = '' }
  $validated = Ext-ValidateMcpRequest $req
  Assert (@($validated.args).Count -eq 2) 'T1c request args count'
  Assert (([string](@($validated.args)[1]) -eq 'pkg')) 'T1c request arg value'

  # T2: empty command strings/arrays are not treated as a valid command.
  Assert (@(Ext-StringArray '').Count -eq 0) 'T2 empty string becomes empty array'
  Assert (@(Ext-StringArray '   ').Count -eq 0) 'T2 whitespace string becomes empty array'
  $cfgPath = Join-Path $fakeHome '.config\opencode\opencode.json'
  $cfg = '{"mcp":{"empty":{"type":"local","command":""},"emptyarr":{"type":"local","command":[""]},"ok":{"type":"local","command":["npx"]}}}'
  [System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))
  $state = Get-ExtensionMcpProviderState $fakeHome 'opencode' ''
  $byName = @{}
  foreach ($s in @($state.servers)) { $byName[[string]$s.name] = $s.detail }
  Assert ([string]$byName['empty'].state -eq 'invalid') 'T2 empty string command is invalid'
  Assert ([string]$byName['emptyarr'].state -eq 'invalid') 'T2 empty array command is invalid'
  Assert ([string]$byName['ok'].state -eq 'enabled') 'T2 normal command stays enabled'
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.codex') | Out-Null
  $codexCfg = "[mcp_servers.blank]`ncommand = `"   `"`n"
  [System.IO.File]::WriteAllText((Join-Path $fakeHome '.codex\config.toml'), $codexCfg, (New-Object System.Text.UTF8Encoding($false)))
  $codexState = Get-ExtensionMcpProviderState $fakeHome 'codex' ''
  $codexByName = @{}
  foreach ($s in @($codexState.servers)) { $codexByName[[string]$s.name] = $s.detail }
  Assert ([string]$codexByName['blank'].state -eq 'invalid') 'T2 whitespace TOML command is invalid'

  # T3: TOML env/http_headers sub-tables resolve before or after the parent.
  $tomlEarly = "[mcp_servers.early.env]`nTOKEN = `"secret-early`"`n[mcp_servers.early]`ncommand = `"npx`"`n"
  $pEarly = Ext-ParseCodexToml $tomlEarly
  Assert (@($pEarly.servers).Count -eq 1) 'T3 early parent count'
  Assert ([string]$pEarly.servers[0].name -eq 'early') 'T3 early parent name'
  Assert ([string]$pEarly.servers[0].command -eq 'npx') 'T3 early parent command'
  Assert (@($pEarly.servers[0].envValues) -contains 'secret-early') 'T3 early env value'
  $tomlLate = "[mcp_servers.late]`ncommand = `"npx`"`n[mcp_servers.late.env]`nTOKEN = `"secret-late`"`n"
  $pLate = Ext-ParseCodexToml $tomlLate
  Assert (@($pLate.servers[0].envValues) -contains 'secret-late') 'T3 late env value'
  $tomlQuoted = "[mcp_servers.q.'http_headers']`n'X-Key' = `"hdr`"`n[mcp_servers.q]`nurl = `"https://example.com`"`n"
  $pQuoted = Ext-ParseCodexToml $tomlQuoted
  Assert (@($pQuoted.servers[0].headerKeys) -contains 'X-Key') 'T3 quoted header key'
  Assert (@($pQuoted.servers[0].headerValues) -contains 'hdr') 'T3 quoted header value'
  Assert ([string]$pQuoted.servers[0].url -eq 'https://example.com') 'T3 parent after quoted sub-table'

  # T5: URL credentials, query, and path are hidden from display and diff fixtures.
  $safe = Ext-SafeUrlDisplay 'https://user:pass@example.com/api?token=abc#frag'
  Assert ($safe -eq 'https://example.com/***?***#***') 'T5 safe URL display'
  Assert (-not $safe.Contains('/api')) 'T5 URL path hidden'
  $safePath = Ext-SafeUrlDisplay 'https://mcp.example.com/v1/auth/sk-live-123456/mcp?token=abc'
  Assert ($safePath -eq 'https://mcp.example.com/***?***') 'T5 URL path token hidden'

  # T6: skill creation cannot exceed the SKILL.md read limit.
  $smallReq = [pscustomobject]@{ kind = 'skill'; action = 'add'; providers = @('opencode'); name = 'small-skill'; description = 'desc'; body = ('a' * 1000) }
  $small = New-ExtensionPreview $auto $fakeHome $smallReq ''
  Assert ([bool]$small.ok) 'T6 small skill preview succeeds'
  $bigReq = [pscustomobject]@{ kind = 'skill'; action = 'add'; providers = @('opencode'); name = 'big-skill'; description = 'desc'; body = ('a' * 70000) }
  Assert-Throws { New-ExtensionPreview $auto $fakeHome $bigReq '' } 'T6 oversized skill preview is rejected'
  $mbBody = ([string][char]0x3042) * 30000
  $mbReq = [pscustomobject]@{ kind = 'skill'; action = 'add'; providers = @('opencode'); name = 'mb-skill'; description = 'desc'; body = $mbBody }
  Assert-Throws { New-ExtensionPreview $auto $fakeHome $mbReq '' } 'T6 multibyte oversized skill preview is rejected'

  # T7: JSONC preview uses a structural safe summary.
  $jsoncHome = Join-Path $testBase 'jsonc-home'
  New-Item -ItemType Directory -Force -Path (Join-Path $jsoncHome '.config\opencode') | Out-Null
  $jsoncPath = Join-Path $jsoncHome '.config\opencode\opencode.jsonc'
  $jsonc = '{ /* ABC123XYZ */ "mcp": { "keep": { "type":"local", "command":["a"], "environment":{"K":"v1"}, "headers":{"H":"h1"}, "enabled":true } } }'
  [System.IO.File]::WriteAllText($jsoncPath, $jsonc, (New-Object System.Text.UTF8Encoding($false)))
  $addReq = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('opencode'); name = 'newsrv'; transport = 'stdio'; command = 'npx'; args = @('-y', 'pkg'); url = ''; envLines = 'NEW=secretnew'; headerLines = '' }
  $addPv = New-ExtensionPreview $auto $jsoncHome $addReq ''
  Assert ([bool]$addPv.ok) 'T7 JSONC add preview ok'
  Assert ([bool]$addPv.entries[0].ok) 'T7 JSONC entry ok'
  $addJoined = (@($addPv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert ($addJoined.Contains('[mcp.newsrv]')) 'T7 summary server name'
  Assert ($addJoined.Contains('command/args: hidden')) 'T7 summary hides command'
  Assert ($addJoined.Contains('env keys: NEW')) 'T7 summary env keys'
  Assert (-not $addJoined.Contains('ABC123XYZ')) 'T7 JSONC comment secret hidden'
  Assert (-not $addJoined.Contains('v1')) 'T7 existing env value hidden'
  Assert (-not $addJoined.Contains('h1')) 'T7 existing header value hidden'
  Assert (-not $addJoined.Contains('secretnew')) 'T7 new env value hidden'
  Assert (-not $addJoined.Contains('npx')) 'T7 new command hidden'
  Assert (-not $addJoined.Contains('pkg')) 'T7 new arg hidden'
  $jsonToggleReq = [pscustomobject]@{ kind = 'mcp'; action = 'toggle'; providers = @('opencode'); name = 'keep'; enabled = $false }
  $jsonTogglePv = New-ExtensionPreview $auto $jsoncHome $jsonToggleReq ''
  Assert ([bool]$jsonTogglePv.ok) 'T7 JSONC toggle preview ok'
  $jsonToggleJoined = (@($jsonTogglePv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert ($jsonToggleJoined.Contains('enabled: true')) 'T7 toggle old state'
  Assert ($jsonToggleJoined.Contains('enabled: false')) 'T7 toggle new state'
  Assert (-not $jsonToggleJoined.Contains('v1')) 'T7 toggle hides env'
  Assert (-not $jsonToggleJoined.Contains('h1')) 'T7 toggle hides header'

  # T8: snapshot read path works and never returns env/header values.
  $snap = Get-ExtensionSnapshot $auto $fakeHome ''
  Assert ([bool]$snap.ok) 'T8 snapshot ok'
  Assert ([string]$snap.homeBase -ieq (Ext-NormPath $fakeHome)) 'T8 snapshot home base'
  $snapJson = $snap | ConvertTo-Json -Depth 12 -Compress
  Assert (-not $snapJson.Contains('v1')) 'T8 snapshot hides env value'
  Assert (-not $snapJson.Contains('h1')) 'T8 snapshot hides header value'
  $okItem = @($snap.mcp | Where-Object { [string]$_.name -eq 'ok' })[0]
  Assert ($null -ne $okItem) 'T8 snapshot contains ok server'
  Assert ($okItem.providers.ContainsKey('opencode')) 'T8 snapshot provider entry'
  Assert ([string]$okItem.providers['opencode'].target -eq '***') 'T8 snapshot target hidden'
  Assert (-not $snapJson.Contains('npx')) 'T8 snapshot hides command'

  # T9: apply then restore the JSONC preview against the scratch fixture.
  $apply = Apply-ExtensionPreview $auto $jsoncHome $addPv.previewId $true $false
  Assert ([bool]$apply.ok) 'T9 apply ok'
  Assert ([string]$apply.backupId -ne '') 'T9 backup id'
  $afterApply = [System.IO.File]::ReadAllText($jsoncPath)
  Assert ($afterApply.Contains('newsrv')) 'T9 applied server present'
  Assert ($afterApply.Contains('ABC123XYZ')) 'T9 comments stay in the written file'
  $restore = Restore-ExtensionBackup $auto $jsoncHome $apply.backupId $true
  Assert ([bool]$restore.ok) 'T9 restore ok'
  $afterRestore = [System.IO.File]::ReadAllText($jsoncPath)
  Assert ($afterRestore -ceq $jsonc) 'T9 restored original bytes'

  # T10: skill frontmatter block scalars, inline comments, and quoted hashes.
  $fmLiteral = Ext-ParseSkillFrontmatter "---`nname: yaml-skill`ndescription: |`n  line1`n  line2`n---`nbody`n"
  Assert ([bool]$fmLiteral.ok) 'T10 literal block ok'
  Assert ($fmLiteral.description.Contains('line1')) 'T10 literal block content'
  $fmFolded = Ext-ParseSkillFrontmatter "---`nname: yaml-skill`ndescription: >-`n  line1`n  line2`n---`n"
  Assert ([string]$fmFolded.description -eq 'line1 line2') 'T10 folded block content'
  $fmPlain = Ext-ParseSkillFrontmatter "---`nname: yaml-skill`ndescription: plain text # note`n---`n"
  Assert ([string]$fmPlain.description -eq 'plain text') 'T10 plain inline comment removed'
  $fmQuoted = Ext-ParseSkillFrontmatter "---`nname: yaml-skill`ndescription: `"quoted # keep`"`n---`n"
  Assert ([string]$fmQuoted.description -eq 'quoted # keep') 'T10 quoted hash preserved'
  $fmBom = Ext-ParseSkillFrontmatter ([string][char]0xFEFF + "---`nname: bom-skill`ndescription: bom`n---`n")
  Assert ([bool]$fmBom.ok) 'T10 BOM frontmatter ok'
  Assert ([string]$fmBom.name -eq 'bom-skill') 'T10 BOM name'

  # T11: orphan env/http_headers sub-tables are recognized and protected.
  $tomlOrphan = "[mcp_servers.orphan.env]`nTOKEN = `"secret-orphan`"`n[mcp_servers.orphan.http_headers]`n`"X-Key`" = `"hdr-orphan`"`n"
  $pOrphan = Ext-ParseCodexToml $tomlOrphan
  Assert (@($pOrphan.servers).Count -eq 1) 'T11 orphan server recognized'
  Assert ([string]$pOrphan.servers[0].name -eq 'orphan') 'T11 orphan name'
  Assert ([string]$pOrphan.servers[0].command -eq '') 'T11 orphan has no command'
  Assert (@($pOrphan.servers[0].envValues) -contains 'secret-orphan') 'T11 orphan env value'
  Assert (@($pOrphan.servers[0].headerKeys) -contains 'X-Key') 'T11 orphan header key'
  Assert (@($pOrphan.servers[0].headerValues) -contains 'hdr-orphan') 'T11 orphan header value'
  Assert-Throws { Ext-CodexAddMcp $tomlOrphan 'orphan' 'stdio' 'npx' @() '' @() @() } 'T11 orphan duplicate rejected'
  $orphanHome = Join-Path $testBase 'orphan-home'
  New-Item -ItemType Directory -Force -Path (Join-Path $orphanHome '.codex') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $orphanHome '.codex\config.toml'), $tomlOrphan, (New-Object System.Text.UTF8Encoding($false)))
  $orphanState = Get-ExtensionMcpProviderState $orphanHome 'codex' ''
  $orphanByName = @{}
  foreach ($s in @($orphanState.servers)) { $orphanByName[[string]$s.name] = $s.detail }
  Assert ([string]$orphanByName['orphan'].state -eq 'invalid') 'T11 orphan state invalid'

  # T12: TOML diffs are a safe structural summary, not raw config text.
  $codexPreviewHome = Join-Path $testBase 'codex-preview-home'
  New-Item -ItemType Directory -Force -Path (Join-Path $codexPreviewHome '.codex') | Out-Null
  $baseToml = "[mcp_servers.existing]`ncommand = `"npx server postgres://user:pass@host/db`"`nargs = [`"--api-key`", `"secret-arg`"]`nenabled = true`n"
  [System.IO.File]::WriteAllText((Join-Path $codexPreviewHome '.codex\config.toml'), $baseToml, (New-Object System.Text.UTF8Encoding($false)))
  $addCodexReq = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('codex'); name = 'newcodex'; transport = 'stdio'; command = 'npx'; args = @('-y', 'pkg'); url = ''; envLines = 'NEW=secretcodex'; headerLines = '' }
  $codexPv = New-ExtensionPreview $auto $codexPreviewHome $addCodexReq ''
  Assert ([bool]$codexPv.ok) 'T12 Codex add preview ok'
  $codexJoined = (@($codexPv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert ($codexJoined.Contains('[mcp_servers.newcodex]')) 'T12 summary server name'
  Assert ($codexJoined.Contains('command/args: hidden')) 'T12 summary hides command'
  Assert ($codexJoined.Contains('env keys: NEW')) 'T12 summary env keys'
  Assert (-not $codexJoined.Contains('npx')) 'T12 summary hides command value'
  Assert (-not $codexJoined.Contains('pkg')) 'T12 summary hides arg value'
  Assert (-not $codexJoined.Contains('secretcodex')) 'T12 summary hides env value'
  Assert (-not $codexJoined.Contains('user:pass')) 'T12 summary hides existing URI'
  $codexApply = Apply-ExtensionPreview $auto $codexPreviewHome $codexPv.previewId $true $false
  Assert ([bool]$codexApply.ok) 'T12 Codex apply ok'
  $codexWritten = [System.IO.File]::ReadAllText((Join-Path $codexPreviewHome '.codex\config.toml'))
  Assert ($codexWritten.Contains('command = "npx"')) 'T12 Codex written command kept'
  Assert ($codexWritten.Contains('postgres://user:pass@host/db')) 'T12 existing command kept'
  $codexRestore = Restore-ExtensionBackup $auto $codexPreviewHome $codexApply.backupId $true
  Assert ([bool]$codexRestore.ok) 'T12 Codex restore ok'
  $toggleReq = [pscustomobject]@{ kind = 'mcp'; action = 'toggle'; providers = @('codex'); name = 'existing'; enabled = $false }
  $togglePv = New-ExtensionPreview $auto $codexPreviewHome $toggleReq ''
  Assert ([bool]$togglePv.ok) 'T12 Codex toggle preview ok'
  $toggleJoined = (@($togglePv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert ($toggleJoined.Contains('enabled: true')) 'T12 toggle old state'
  Assert ($toggleJoined.Contains('enabled: false')) 'T12 toggle new state'
  Assert (-not $toggleJoined.Contains('user:pass')) 'T12 toggle hides command'
  Assert (-not $toggleJoined.Contains('secret-arg')) 'T12 toggle hides args'
  $codexRemoteReq = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('codex'); name = 'remotecodex'; transport = 'remote'; command = ''; args = @(); url = 'https://mcp.example.com/v1/auth/sk-live-1/mcp?token=abc'; envLines = ''; headerLines = 'Authorization: Bearer hdr2' }
  $codexRemotePv = New-ExtensionPreview $auto $codexPreviewHome $codexRemoteReq ''
  Assert ([bool]$codexRemotePv.ok) 'T12 Codex remote preview ok'
  $codexRemoteJoined = (@($codexRemotePv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert ($codexRemoteJoined.Contains('url: https://mcp.example.com/***?***')) 'T12 TOML remote safe URL'
  Assert (-not $codexRemoteJoined.Contains('sk-live')) 'T12 TOML remote path hidden'
  Assert (-not $codexRemoteJoined.Contains('hdr2')) 'T12 TOML remote header value hidden'
  Assert ($codexRemoteJoined.Contains('header keys: Authorization')) 'T12 TOML remote header key'

  # T13: Claude Code single-line JSON summary hides other account/MCP secrets.
  $claudeHome = Join-Path $testBase 'claude-home'
  New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
  $claudeCfg = '{"oauthToken":"oauth-secret","mcpServers":{"existing":{"command":["npx","postgres://user:pass@host/db"],"env":{"K":"v1"},"headers":{"H":"h1"},"enabled":true}}}'
  [System.IO.File]::WriteAllText((Join-Path $claudeHome '.claude.json'), $claudeCfg, (New-Object System.Text.UTF8Encoding($false)))
  $claudeReq = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('claudecode'); name = 'newclaude'; transport = 'stdio'; command = 'npx'; args = @('-y'); url = ''; envLines = 'NEW=secret-claude'; headerLines = '' }
  $claudePv = New-ExtensionPreview $auto $claudeHome $claudeReq ''
  Assert ([bool]$claudePv.ok) 'T13 Claude preview ok'
  Assert ([bool]$claudePv.entries[0].ok) 'T13 Claude entry ok'
  $claudeJoined = (@($claudePv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert ($claudeJoined.Contains('[mcpServers.newclaude]')) 'T13 summary server name'
  Assert ($claudeJoined.Contains('command/args: hidden')) 'T13 summary hides command'
  Assert ($claudeJoined.Contains('env keys: NEW')) 'T13 summary env keys'
  Assert (-not $claudeJoined.Contains('oauth-secret')) 'T13 other Claude secret hidden'
  Assert (-not $claudeJoined.Contains('user:pass')) 'T13 existing MCP URI hidden'
  Assert (-not $claudeJoined.Contains('v1')) 'T13 existing env hidden'
  Assert (-not $claudeJoined.Contains('h1')) 'T13 existing header hidden'
  Assert (-not $claudeJoined.Contains('secret-claude')) 'T13 new env value hidden'
  Assert (-not $claudeJoined.Contains('npx')) 'T13 command value hidden'

  # T14: remote URL path/token is hidden from the preview and snapshot.
  $remoteHome = Join-Path $testBase 'remote-home'
  New-Item -ItemType Directory -Force -Path (Join-Path $remoteHome '.config\opencode') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $remoteHome '.config\opencode\opencode.json'), '{"mcp":{}}', (New-Object System.Text.UTF8Encoding($false)))
  $remoteUrl = 'https://mcp.example.com/v1/auth/sk-live-123456/mcp?token=abc'
  $remoteReq = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('opencode'); name = 'remote-srv'; transport = 'remote'; command = ''; args = @(); url = $remoteUrl; envLines = ''; headerLines = 'Authorization: Bearer hdr-secret' }
  $remotePv = New-ExtensionPreview $auto $remoteHome $remoteReq ''
  Assert ([bool]$remotePv.ok) 'T14 remote preview ok'
  $remoteJoined = (@($remotePv.entries[0].diff.lines) | ForEach-Object { [string]$_.text }) -join "`n"
  Assert (-not $remoteJoined.Contains('sk-live')) 'T14 URL path token hidden'
  Assert (-not $remoteJoined.Contains('/v1/auth')) 'T14 URL path hidden'
  Assert (-not $remoteJoined.Contains('hdr-secret')) 'T14 header value hidden'
  $remoteApply = Apply-ExtensionPreview $auto $remoteHome $remotePv.previewId $true $false
  Assert ([bool]$remoteApply.ok) 'T14 remote apply ok'
  $remoteSnap = Get-ExtensionSnapshot $auto $remoteHome ''
  $remoteItem = @($remoteSnap.mcp | Where-Object { [string]$_.name -eq 'remote-srv' })[0]
  Assert ($null -ne $remoteItem) 'T14 remote server listed'
  Assert ([string]$remoteItem.providers['opencode'].target -eq 'https://mcp.example.com/***?***') 'T14 remote target path hidden'
  $remoteRestore = Restore-ExtensionBackup $auto $remoteHome $remoteApply.backupId $true
  Assert ([bool]$remoteRestore.ok) 'T14 remote restore ok'

  # T15: inline/dotted/array MCP definitions fail closed.
  $tomlInline = "[mcp_servers]`nfoo = { command = `"npx`", args = [`"-y`"] }`n"
  $pInline = Ext-ParseCodexToml $tomlInline
  Assert ([bool]$pInline.unsupported) 'T15 inline table unsupported'
  Assert-Throws { Ext-CodexAddMcp $tomlInline 'foo' 'stdio' 'npx' @() '' @() @() } 'T15 inline add rejected'
  $tomlDotted = "[mcp_servers]`nfoo.command = `"npx`"`nfoo.args = [`"-y`"]`n"
  $pDotted = Ext-ParseCodexToml $tomlDotted
  Assert ([bool]$pDotted.unsupported) 'T15 dotted key unsupported'
  Assert-Throws { Ext-CodexAddMcp $tomlDotted 'foo' 'stdio' 'npx' @() '' @() @() } 'T15 dotted add rejected'
  $tomlRootDotted = "mcp_servers.foo.command = `"npx`"`nmcp_servers.foo.args = [`"-y`"]`n"
  $pRootDotted = Ext-ParseCodexToml $tomlRootDotted
  Assert ([bool]$pRootDotted.unsupported) 'T15 top-level dotted unsupported'
  $tomlArrayTable = "[[mcp_servers]]`ncommand = `"npx`"`n"
  $pArrayTable = Ext-ParseCodexToml $tomlArrayTable
  Assert ([bool]$pArrayTable.unsupported) 'T15 array table unsupported'
  $tomlArrayName = "[[mcp_servers.myserver]]`ncommand = `"npx`"`n"
  $pArrayName = Ext-ParseCodexToml $tomlArrayName
  Assert ([bool]$pArrayName.unsupported) 'T15 per-server array table unsupported'
  $tomlInlineEnv = "[mcp_servers.foo]`ncommand = `"npx`"`nenv = { TOKEN = `"x`" }`n"
  $pInlineEnv = Ext-ParseCodexToml $tomlInlineEnv
  Assert ([bool]$pInlineEnv.unsupported) 'T15 inline env unsupported'
  $tomlDottedEnv = "[mcp_servers.foo]`ncommand = `"npx`"`nenv.TOKEN = `"x`"`n"
  $pDottedEnv = Ext-ParseCodexToml $tomlDottedEnv
  Assert ([bool]$pDottedEnv.unsupported) 'T15 dotted env unsupported'
  $tomlQuotedDot = "[mcp_servers.foo]`ncommand = `"npx`"`n`"a.b`" = `"x`"`n"
  $pQuotedDot = Ext-ParseCodexToml $tomlQuotedDot
  Assert (-not [bool]$pQuotedDot.unsupported) 'T15 quoted dotted key allowed'
  $tomlQuotedRoot = "[`"mcp_servers`".foo]`ncommand = `"npx`"`n"
  $pQuotedRoot = Ext-ParseCodexToml $tomlQuotedRoot
  Assert ([bool]$pQuotedRoot.unsupported) 'T15 quoted root unsupported'
  Assert-Throws { Ext-CodexAddMcp $tomlQuotedRoot 'foo' 'stdio' 'npx' @() '' @() @() } 'T15 quoted root add rejected'
  $tomlQuotedRootLit = "['mcp_servers'.foo]`ncommand = `"npx`"`n"
  $pQuotedRootLit = Ext-ParseCodexToml $tomlQuotedRootLit
  Assert ([bool]$pQuotedRootLit.unsupported) 'T15 literal quoted root unsupported'
  $tomlQuotedRootBare = "[`"mcp_servers`"]`nfoo = { command = `"npx`" }`n"
  $pQuotedRootBare = Ext-ParseCodexToml $tomlQuotedRootBare
  Assert ([bool]$pQuotedRootBare.unsupported) 'T15 quoted root table unsupported'
  $tomlMulti = "[other]`nnote = `"`"`"`n[mcp_servers.fake]`ncommand = `"npx`"`n`"`"`"`n"
  $pMulti = Ext-ParseCodexToml $tomlMulti
  Assert ([bool]$pMulti.unsupported) 'T15 multiline string unsupported'
  Assert-Throws { Ext-CodexToggleMcp $tomlMulti 'fake' $false } 'T15 multiline toggle rejected'
  $inlineHome = Join-Path $testBase 'inline-home'
  New-Item -ItemType Directory -Force -Path (Join-Path $inlineHome '.codex') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $inlineHome '.codex\config.toml'), $tomlInline, (New-Object System.Text.UTF8Encoding($false)))
  $inlineState = Get-ExtensionMcpProviderState $inlineHome 'codex' ''
  Assert (-not [bool]$inlineState.mcpWritable) 'T15 inline config not writable'
  Assert ([string]$inlineState.mcpWriteReason -ne '') 'T15 inline write reason'
  $inlineReq = [pscustomobject]@{ kind = 'mcp'; action = 'add'; providers = @('codex'); name = 'bar'; transport = 'stdio'; command = 'npx'; args = @(); url = ''; envLines = ''; headerLines = '' }
  $inlinePv = New-ExtensionPreview $auto $inlineHome $inlineReq ''
  Assert (-not [bool]$inlinePv.entries[0].ok) 'T15 inline preview rejected'
  Assert ([string]$inlinePv.entries[0].error -ne '') 'T15 inline preview reason'


  # T16: skill names follow the same lowercase rule used when creating skills.
  $caseHome = Join-Path $testBase 'case-skill-home'
  foreach ($skillName in @('Good-Skill', 'valid-skill')) {
    $skillDir = Join-Path $caseHome ('.agents\skills\' + $skillName)
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $skillDir 'SKILL.md'), "---`nname: $skillName`ndescription: example`n---`n", (New-Object System.Text.UTF8Encoding($false)))
  }
  $caseState = Get-ExtensionSkillProviderState $caseHome 'codex' '' @() @{}
  $upperSkill = @($caseState.entries | Where-Object { $_.name -ceq 'Good-Skill' })
  $validSkill = @($caseState.entries | Where-Object { $_.name -ceq 'valid-skill' })
  Assert ($upperSkill.Count -eq 1 -and -not $upperSkill[0].valid) 'T16 uppercase skill name invalid'
  Assert ($validSkill.Count -eq 1 -and $validSkill[0].valid) 'T16 lowercase skill name valid'

}
finally {
  $env:GITHUB_TOKEN = $savedGh
  $env:GH_TOKEN = $savedGh2
  Remove-Item -LiteralPath $testBase -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:failures.Count -gt 0) { throw ('FAILED: ' + ($script:failures -join ', ')) }
Write-Host 'ALL TESTS PASSED'
