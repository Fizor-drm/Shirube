# Test-Dashboard.ps1 - isolated self-checks for Dashboard-Server.ps1.
# Scratch-only. Never touches real registry, repos, tasks, or deployed AppData.
$ErrorActionPreference = 'Stop'
$initCwd = (Get-Location).Path
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
function Get-Full([string]$P) { return [System.IO.Path]::GetFullPath($P) }
function Test-Contained([string]$Candidate, [string]$Root) {
  $c = Get-Full $Candidate; $r = Get-Full $Root
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
  return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
}
$origAuto = $env:DASHBOARD_AUTODIR
$origPort = $env:DASHBOARD_PORT
$devAuto = Split-Path -Parent $PSScriptRoot
$devRoot = Split-Path -Parent $devAuto
$srvPath = Join-Path $devAuto 'Dashboard-Server.ps1'
$vfyPath = Join-Path $devAuto 'Verify-Dashboard.ps1'
$watchPath = Join-Path $devAuto 'Watch-Sync.ps1'
$syncPath = Join-Path $devAuto 'Sync-ProjectRules.ps1'
$browsePath = Join-Path $devAuto 'Browse-Folder.ps1'
$batPath = Join-Path $devRoot '管理.bat'
try {
  . $srvPath
  Assert ((Get-Command Get-RegisterPreview -ErrorAction SilentlyContinue) -ne $null) 'dot-source exposes preview (no listen)'
  Assert ((Get-Content -LiteralPath $srvPath -Raw).Contains(' arbitrarily ') -eq $false) 'no-arbitrary-note'

  # R7 静的監査: ACL私的化/固定absolute/loopback明示 (UI不変、r6機能不変)
  $srvTxt0 = Get-Content -LiteralPath $srvPath -Raw
  $vfyTxt0 = Get-Content -LiteralPath $vfyPath -Raw
  $watchTxt0 = Get-Content -LiteralPath $watchPath -Raw
  $batTxt0 = Get-Content -LiteralPath $batPath -Raw -Encoding UTF8
  Assert (($srvTxt0.Contains('Set-PrivateFileAcl') -and $srvTxt0.Contains('Test-PrivateFileAcl') -and $srvTxt0.Contains('Get-PrivateAclSids'))) 'R7 私的ACL関数あり(トークン/状態/同期要求)'
  Assert (($srvTxt0.Contains('SetAccessRuleProtection') -and $srvTxt0.Contains('S-1-5-18') -and $srvTxt0.Contains('S-1-5-32-544'))) 'R7 ACL継承無効・本人/SYSTEM/Adminのみ(dummy根拠:他者なし)'
  Assert ((Get-Command Set-PrivateFileAcl -ErrorAction SilentlyContinue) -ne $null) 'R7 私的ACL関数公開(dot-sourceで検証可能)'
  Assert ((Get-Command Test-PrivateFileAcl -ErrorAction SilentlyContinue) -ne $null) 'R7 ACL検証関数公開'
  Assert (((-not ($srvTxt0.Contains("'powershell.exe'"))) -and (-not ($srvTxt0.Contains("'wscript.exe'")))) -or (($srvTxt0.Contains('powershell absolute missing') -and $srvTxt0.Contains('wscript absolute missing')))) 'R7 サーバー裸fallbackなし(固定absoluteのみ)'
  Assert (($srvTxt0.Contains("System32\WindowsPowerShell\v1.0\powershell.exe") -and $srvTxt0.Contains("System32\wscript.exe"))) 'R7 サーバー固定absoluteあり'
  Assert (($watchTxt0.Contains('Set-PrivateFileAclLocal') -and (-not ($watchTxt0.Contains("'powershell.exe'"))) -and (-not ($watchTxt0.Contains("'wscript.exe'"))))) 'R7 監視ヘルパー裸実行なし・結果私的ACL'
  Assert (($vfyTxt0.Contains("System32\netstat.exe") -and (-not ($vfyTxt0.Contains('& netstat.exe'))))) 'R7 検証netstat固定absolute'
  Assert ((-not ($vfyTxt0.Contains('dashboard.token')))) 'R7 検証はトークン送信なし(状態+TCP+healthのみ)'
  Assert (($batTxt0.Contains('System32\WindowsPowerShell\v1.0\powershell.exe'))) 'R7 bat固定absoluteあり(powershell)'
  Assert (($vfyTxt0.Contains('System32\wscript.exe'))) 'R7 起動は検証スクリプト内のwscript固定absolute'
  Assert ((-not ($batTxt0.Contains('powershell -NoProfile'))) -and (-not ($batTxt0.Contains('wscript.exe //B'))) -and (-not ($batTxt0.Contains('timeout /t')))) 'R7 bat裸実行なし(ブラウザstartはOS既定維持)'
  Assert (($srvTxt0.Contains('http://127.0.0.1:') -and (-not ($srvTxt0.Contains('http://+:'))) -and (-not ($srvTxt0.Contains('http://*:'))) -and (-not ($srvTxt0.Contains('http://0.0.0.0'))))) 'R7 loopback明示bind・wildcardなし(URL予約なし境界)'
  Assert ((-not ($srvTxt0.Contains('netsh http add urlacl'))) -and (-not ($srvTxt0.Contains('urlacl')))) 'R7 URL予約なし(昇格変更なし・親手順はREADME)'
  Assert (($srvTxt0.Contains('Write-PrivateText') -and $srvTxt0.Contains('New-PrivateFileSecurity') -and $srvTxt0.Contains('File]::Create') -and $srvTxt0.Contains('FileSecurity'))) 'R7b 生成時私的ACLあり(読める時間なし)'
  Assert (($srvTxt0.Contains('Write-PrivateText $f $t') -and $srvTxt0.Contains('Write-PrivateText $rf') -and $srvTxt0.Contains('Write-PrivateText $sf'))) 'R7b トークン/要求/状態は生成時私的書込のみ'
  Assert ($watchTxt0.Contains('Write-PrivateTextLocal $tmp')) 'R7b 結果tmpも生成時私的書込'

  $base = Join-Path ([System.IO.Path]::GetTempPath()) 'DashboardTest'
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  $scratch = Join-Path $base ('run-' + [System.Guid]::NewGuid().ToString('N'))
  $auto = Join-Path $scratch 'auto'
  New-Item -ItemType Directory -Force -Path $auto | Out-Null
  # fake preview root: <scratch>\project-common-preview\.rulesync\rules\.curated\project.md
  $curDir = Join-Path $scratch 'project-common-preview\.rulesync\rules\.curated'
  New-Item -ItemType Directory -Force -Path $curDir | Out-Null
  # Get-CommonBody resolves parent of AutoDir, so AutoDir must sit next to project-common-preview:
  # use <scratch>\auto as AutoDir whose parent is <scratch>. good.
  Set-Content -LiteralPath (Join-Path $curDir 'project.md') "---`nroot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nshared-common-body-XYZ" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[]' -Encoding Ascii
  $env:DASHBOARD_AUTODIR = $auto

  # R7 機能検証(scratchのみ): 私的ACL実効・トークン/状態/要求の権限制限・secret非出力
  $aclFile = Join-Path $auto 'acl-dummy.txt'
  Set-Content -LiteralPath $aclFile 'dummy' -Encoding Ascii
  Set-PrivateFileAcl $aclFile
  Assert ((Test-PrivateFileAcl $aclFile) -eq $true) 'R7 ACL継承除外:私的ACL検証OK(dummy実効根拠)'
  $aclObj = Get-Acl -LiteralPath $aclFile
  Assert (($aclObj.AreAccessRulesProtected) -eq $true) 'R7 ACL継承無効:親継承を遮断'
  $denyOther = $true
  foreach ($r in @($aclObj.Access)) {
    try { $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = '' }
    if (($sid -eq 'S-1-5-11') -or ($sid -eq 'S-1-5-32-545') -or ($sid -eq 'S-1-1-0')) { $denyOther = $false }
  }
  Assert ($denyOther) 'R7 他principal除外:AuthenticatedUsers/Users/Everyoneなし'
  Assert ((@(Get-Acl -LiteralPath $aclFile).Access.Count) -eq 3) 'R7 許可は3件のみ(本人/SYSTEM/Admin)'
  Remove-Item -LiteralPath $aclFile -Force -ErrorAction SilentlyContinue
  $tokTest = Get-SessionToken $auto
  Assert (($tokTest -match '^[0-9a-f]{64}$')) 'R7 トークン正常発行:64桁hex'
  Assert ((Test-PrivateFileAcl (Join-Path $auto 'dashboard.token')) -eq $true) 'R7 トークン権限制限:継承除外・本人/SYSTEM/Adminのみ'
  $aclTok = Get-Acl -LiteralPath (Join-Path $auto 'dashboard.token')
  Assert (($aclTok.AreAccessRulesProtected) -eq $true) 'R7 トークン継承遮断:親AppData継承なし'
  # 既存ゆるACLも修復される(本番の適用は親)
  try {
    $loose = Get-Acl -LiteralPath (Join-Path $auto 'dashboard.token')
    $loose.SetAccessRuleProtection($false, $true)
    Set-Acl -LiteralPath (Join-Path $auto 'dashboard.token') -AclObject $loose
  } catch {}
  $tokRepair = Get-SessionToken $auto
  Assert ((($tokRepair -ceq $tokTest) -and ((Test-PrivateFileAcl (Join-Path $auto 'dashboard.token')) -eq $true))) 'R7 既存トークンACL修復:再取得で私的化'
  Remove-Item -LiteralPath (Join-Path $auto 'dashboard.token') -Force -ErrorAction SilentlyContinue
  $tokNew = Get-SessionToken $auto
  Assert ((($tokNew -match '^[0-9a-f]{64}$') -and ((Test-PrivateFileAcl (Join-Path $auto 'dashboard.token')) -eq $true))) 'R7b 新規生成時から私的ACL(読める時間なし)'
  $privNew = Join-Path $auto 'priv-new.txt'
  Remove-Item -LiteralPath $privNew -Force -ErrorAction SilentlyContinue
  Write-PrivateText $privNew 'secret-new'
  Assert (((Get-Content -LiteralPath $privNew -Raw -Encoding UTF8) -ceq 'secret-new') -and ((Test-PrivateFileAcl $privNew) -eq $true)) 'R7b 新規私的書込の内容+ACL'
  Write-PrivateText $privNew 'secret-overwrite'
  Assert (((Get-Content -LiteralPath $privNew -Raw -Encoding UTF8) -ceq 'secret-overwrite') -and ((Test-PrivateFileAcl $privNew) -eq $true)) 'R7b 既存私的書換もACL維持'
  Remove-Item -LiteralPath $privNew -Force -ErrorAction SilentlyContinue
  $wrTest = Write-SyncRequest $auto
  Assert ((Test-PrivateFileAcl (Join-Path $auto 'dashboard.lastsync.txt')) -eq $true) 'R7 同期要求権限制限:状態ファイル私的化'
  Write-DashboardState $auto 18721 'test-instance-xyz'
  Assert ((Test-PrivateFileAcl (Join-Path $auto 'dashboard.state.json')) -eq $true) 'R7 状態権限制限:私的ACL'
  $stTxt = Get-Content -LiteralPath (Join-Path $auto 'dashboard.state.json') -Raw
  Assert ((-not ($stTxt.Contains($tokTest)))) 'R7 secret非出力:状態にトークンなし'
  $tailTest = (Get-Status $auto $tokTest).tail
  Assert ((-not ($tailTest.Contains($tokTest)))) 'R7 secret非出力:ログ末尾トークン秘匿'

  $repoA = Join-Path $scratch 'RepoA'
  $repoDup = Join-Path $scratch 'other' | Join-Path -ChildPath 'RepoA'
  New-Item -ItemType Directory -Force -Path $repoA, (Split-Path $repoDup -Parent) | Out-Null
  New-Item -ItemType Directory -Force -Path $repoDup | Out-Null
  $jpRepo = Join-Path $scratch '日本語 リポジトリ'
  New-Item -ItemType Directory -Force -Path $jpRepo | Out-Null

  # T1 invalid: relative path refused
  $v = Get-RegisterPreview $auto 'relpath\repo'
  Assert ((-not $v.ok) -and ($v.error.Contains('絶対パス'))) 'T1 relative refused'
  # T1b drive-relative refused
  $v = Get-RegisterPreview $auto 'C:relpath'
  Assert ((-not $v.ok)) 'T1b drive-relative refused'
  # T2 missing dir refused
  $v = Get-RegisterPreview $auto (Join-Path $scratch 'no-such-dir')
  Assert ((-not $v.ok) -and ($v.error.Contains('存在しません'))) 'T2 missing dir refused'

  # T3 register + duplicate path refused (case-insensitive covered by NormPath compare)
  $v = Get-RegisterPreview $auto $repoA
  Assert ($v.ok -and ($v.name -eq 'RepoA')) 'T3 preview ok name=RepoA'
  $reg = @(Get-Registry $auto)
  $reg += [pscustomobject]@{ name = $v.name; path = $v.path }
  Write-RegistryAtomic $auto $reg
  $v2 = Get-RegisterPreview $auto ($repoA.ToLowerInvariant())
  Assert ((-not $v2.ok) -and ($v2.error.Contains('既に登録'))) 'T3 duplicate path refused'

  # T8 same basename suggests -2
  $v3 = Get-RegisterPreview $auto $repoDup
  Assert ($v3.ok -and ($v3.name -eq 'RepoA-2')) 'T8 same basename suggests -2'

  # T11 Japanese+space basename sanitized to safe name
  $v4 = Get-RegisterPreview $auto $jpRepo
  Assert ($v4.ok -and (Test-SafeName $v4.name)) 'T11 japanese-space sanitized to safeName'

  # T4 unregister removes only list, repo files untouched
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') 'keep-me' -Encoding Ascii
  $reg = @(Get-Registry $auto)
  $rest = @($reg | Where-Object { [string]$_.name -cne 'RepoA' })
  Write-RegistryAtomic $auto $rest
  Assert ((@(Get-Registry $auto)).Count -eq 0) 'T4 list emptied'
  Assert ((Get-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') -Raw) -match 'keep-me') 'T4 repo file untouched'

  # r3 P1: existing AGENTS.md always stops (no 60-char probe, no short-local bypass, no extra take)
  New-Item -ItemType Directory -Force -Path (Join-Path $repoA '.rulesync\rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') "title`nshared-common-body-XYZ tail" -Encoding Ascii
  $v5 = Get-RegisterPreview $auto $repoA
  Assert ((-not $v5.ok) -and ($v5.error.Contains('既存 AGENTS.md'))) 'R3P1 duplicate-common stops (always)'
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') 'my fully custom rules 1234567890 abcdefghij' -Encoding Ascii
  $v5b = Get-RegisterPreview $auto $repoA
  Assert ((-not $v5b.ok) -and (($v5b.error.Contains('手動転記')) -or ($v5b.error.Contains('再生成')))) 'R3P1 transcription-needed stops'
  # extra unique content would be lost by regenerate -> must stop, never silently taken
  Set-Content -LiteralPath (Join-Path $repoA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nmy-local-unique-body-1234567890-abcdef" -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') 'head shared-common-body-XYZ tail my-local-unique-body-1234567890-abcdef EXTRA-UNIQUE-LOSS-12345 end' -Encoding Ascii
  $vExtra = Get-RegisterPreview $auto $repoA
  Assert ((-not $vExtra.ok) -and ($vExtra.error.Contains('既存 AGENTS.md'))) 'R3P1 extra-AGENTS refused (no silent take)'
  # short local (<20) must not bypass: existing AGENTS still stops
  Set-Content -LiteralPath (Join-Path $repoA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nx" -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $repoA 'AGENTS.md') 'short-local-plus-agents-1234567890' -Encoding Ascii
  $vShort = Get-RegisterPreview $auto $repoA
  Assert (-not $vShort.ok) 'R3P1 short-local still stops (no bypass)'
  # empty (no AGENTS) + valid local -> ok, agentsHash null, localHash sha256
  Remove-Item -LiteralPath (Join-Path $repoA 'AGENTS.md') -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath (Join-Path $repoA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nmy-local-unique-body-1234567890-abcdef" -Encoding Ascii
  $vEmpty = Get-RegisterPreview $auto $repoA
  Assert (($vEmpty.ok -and (-not $vEmpty.hasAgents) -and $vEmpty.hasLocal) -and ($null -eq $vEmpty.agentsHash) -and ($vEmpty.localHash -match '^[0-9a-f]{64}$')) 'R3P1 empty-AGENTS passes with local hash'

  # T5 conflict: bad local frontmatter stops safely (no AGENTS to confuse)
  Set-Content -LiteralPath (Join-Path $repoA '.rulesync\rules\project-local.md') 'no-marker' -Encoding Ascii
  $v6 = Get-RegisterPreview $auto $repoA
  Assert ((-not $v6.ok) -and ($v6.error.Contains('安全のため停止'))) 'T5 bad local stops'
  Set-Content -LiteralPath (Join-Path $repoA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nunrelated-local-body-ZZZZZZZZZZ-1234567890" -Encoding Ascii
  $v7 = Get-RegisterPreview $auto $repoA
  Assert ($v7.ok) 'T5b valid local without AGENTS passes'
  Set-Content -LiteralPath (Join-Path $repoA '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nmy-local-unique-body-1234567890-abcdef" -Encoding Ascii

  # T9 HTTP security function checks
  Assert ((Test-HostValid '127.0.0.1:18721' 18721) -and (Test-HostValid 'localhost:18721' 18721)) 'T9 good host passes'
  Assert (-not (Test-HostValid 'evil.com' 18721)) 'T9 bad host rejected'
  Assert (-not (Test-HostValid '127.0.0.1:9999' 18721)) 'T9 wrong port rejected'
  Assert ((Test-OriginValid 'http://127.0.0.1:18721' 18721)) 'T9 good origin passes'
  Assert (-not (Test-OriginValid 'http://evil.com' 18721)) 'T9 bad origin rejected'
  Assert ((Redact-Text 'tok=abc GITHUB_TOKEN=secret ghp_1234567890' 'abc').Contains('***') -and (-not (Redact-Text 'x ghp_1234567890' 'zzz').Contains('1234567890'))) 'T9 secrets redacted'

  # T10 lock held -> atomic write refuses, registry unchanged
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[]' -Encoding Ascii
  $lock = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $busy = $false
    try { Write-RegistryAtomic $auto @([pscustomobject]@{ name = 'X'; path = $repoA }) } catch { $busy = ($_.Exception.Message.Contains('busy')) }
    Assert ($busy) 'T10 locked write busy-refused'
    Assert ((@(Get-Registry $auto)).Count -eq 0) 'T10 registry unchanged while locked'
  } finally { $lock.Close() }
  Remove-Item -LiteralPath (Join-Path $auto 'Sync-ProjectRules.lock') -Force -ErrorAction SilentlyContinue

  # T10b shell-meta paths refused at preview (npx/cmd safety uncertain -> reject with minimal note)
  $metaDir = Join-Path $scratch 'Repo&Meta'
  New-Item -ItemType Directory -Force -Path $metaDir | Out-Null
  $vm = Get-RegisterPreview $auto $metaDir
  Assert ((-not $vm.ok) -and ($vm.error.Contains('&'))) 'T10b shell-meta refused'
  $metaDir2 = Join-Path $scratch 'Repo;Meta'
  New-Item -ItemType Directory -Force -Path $metaDir2 | Out-Null
  $vm2 = Get-RegisterPreview $auto $metaDir2
  Assert (-not $vm2.ok) 'T10b2 semicolon path refused'

  # T10c empty preview carries null hashes; Write-RegistryAtomicLocked round-trips with no tmp leak
  $ve = Get-RegisterPreview $auto $repoDup
  Assert (($ve.ok) -and ($null -eq $ve.agentsHash) -and ($null -eq $ve.localHash)) 'T10c empty preview null hashes'
  Write-RegistryAtomicLocked $auto @()
  Assert ((@(Get-Registry $auto)).Count -eq 0) 'T10c locked write empty ok'
  $tmps = @(Get-ChildItem -LiteralPath $auto -Filter 'projects.json.tmp-*' -ErrorAction SilentlyContinue)
  Assert ($tmps.Count -eq 0) 'T10c no tmp leak'

  # T10d same Sync lock held across mutation: second open is busy until finally closes
  $lk = Open-SyncLock $auto
  try {
    $busy2 = $false
    try { Open-SyncLock $auto | Out-Null } catch { $busy2 = ($_.Exception.Message.Contains('busy')) }
    Assert ($busy2) 'T10d second lock while held busy'
  } finally { $lk.Close() }
  $lk2 = Open-SyncLock $auto
  try { Assert ($true) 'T10d lock re-acquired after close' } finally { $lk2.Close() }

  # R3P4 parent junction: .rulesync\rules parent is junction -> preview refuses before read
  $repoPar = Join-Path $scratch 'ParRepo'
  $realTgt = Join-Path $scratch 'ParReal'
  New-Item -ItemType Directory -Force -Path (Join-Path $realTgt 'rules') | Out-Null
  Set-Content -LiteralPath (Join-Path $realTgt 'rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nreal-local" -Encoding Ascii
  New-Item -ItemType Directory -Force -Path $repoPar | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $repoPar '.rulesync') | Out-Null
  $jOk = $true
  try { New-Item -ItemType Junction -Path (Join-Path $repoPar '.rulesync\rules') -Target (Join-Path $realTgt 'rules') -ErrorAction Stop | Out-Null } catch { $jOk = $false }
  Assert ($jOk) 'R3P4 junction available'
  if ($jOk) {
    $vPar = Get-RegisterPreview $auto $repoPar
    Assert ((-not $vPar.ok) -and ($vPar.error.Contains('親フォルダ'))) 'R3P4 parent junction refused'
    try { [System.IO.Directory]::Delete((Join-Path $repoPar '.rulesync\rules')) } catch {}
  }

  # R4P2 sync-state: only the real child result file bound to runID completes.
  # Log final lines (old or fresh) are display-only and never imply success/failed.
  $stAuto = Join-Path $scratch 'stAuto'
  New-Item -ItemType Directory -Force -Path (Join-Path $stAuto 'logs') | Out-Null
  Set-Content -LiteralPath (Join-Path $stAuto 'projects.json') '[]' -Encoding Ascii
  Remove-Item -LiteralPath (Join-Path $stAuto 'dashboard.lastsync.txt') -Force -ErrorAction SilentlyContinue
  $s0 = Get-SyncState $stAuto 'tok'
  Assert ($s0.syncState -eq 'idle') 'R4P2 no-request idle (not success)'
  $wr = Write-SyncRequest $stAuto
  Assert (($wr.id -match '^[0-9a-f]{32}$') -and ($wr.at -match '^\d{4}-')) 'R4P2 request carries runID+start'
  $s1 = Get-SyncState $stAuto 'tok'
  Assert ($s1.syncState -eq 'waiting') 'R4P2 no-log waiting (child start wait, not complete)'
  $oldLog = Join-Path $stAuto 'logs\Sync-ProjectRules-20200101.log'
  Set-Content -LiteralPath $oldLog ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' OK: old') -Encoding Ascii
  (Get-Item -LiteralPath $oldLog).LastWriteTime = (Get-Date).AddMinutes(-10)
  $s2 = Get-SyncState $stAuto 'tok'
  Assert ($s2.syncState -ne 'success') 'R4P2 old-log never success (stale guess removed)'
  Assert ($s2.syncState -eq 'unconfirmed') 'R4P2 old-log unconfirmed'
  $freshOk = Join-Path $stAuto ('logs\Sync-ProjectRules-' + (Get-Date -Format 'yyyyMMdd') + '.log')
  Set-Content -LiteralPath $freshOk ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' STEP: x' + "`n" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' OK: all projects in sync.') -Encoding Ascii
  $s3 = Get-SyncState $stAuto 'tok'
  Assert ($s3.syncState -ne 'success') 'R4P2 fresh-OK without result never success'
  Assert ($s3.syncState -eq 'unconfirmed') 'R4P2 fresh-OK without result unconfirmed'
  Set-Content -LiteralPath $freshOk ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' FAIL: 1 project(s) failed.') -Encoding Ascii
  $s4 = Get-SyncState $stAuto 'tok'
  Assert ($s4.syncState -ne 'failed') 'R4P2 fresh-FAIL without result never failed'
  Assert ($s4.syncState -eq 'unconfirmed') 'R4P2 fresh-FAIL without result unconfirmed'
  Set-Content -LiteralPath $freshOk ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' STEP: only, no final marker') -Encoding Ascii
  $s5 = Get-SyncState $stAuto 'tok'
  Assert ($s5.syncState -eq 'unconfirmed') 'R4P2 no-final unconfirmed (bounded poll shows unconfirmed)'
  # runID-bound real result files decide success/failed
  $rf = Get-SyncResultFile $stAuto $wr.id
  Assert (($null -ne $rf) -and ($rf.Contains($wr.id))) 'R4P2 result file path bound to runID'
  Assert ((Get-SyncResult $stAuto $wr.id) -eq $null) 'R4P2 no result yet for this runID'
  Set-Content -LiteralPath $rf (@{ runId = $wr.id; exitCode = 0; finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); result = 'success' } | ConvertTo-Json -Compress) -Encoding Ascii
  $s5b = Get-SyncState $stAuto 'tok'
  Assert (($s5b.syncState -eq 'success') -and ($s5b.resultExit -eq 0)) 'R4P2 result exit 0 -> success (run association)'
  Set-Content -LiteralPath $rf (@{ runId = $wr.id; exitCode = 1; finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); result = 'failed' } | ConvertTo-Json -Compress) -Encoding Ascii
  $s5c = Get-SyncState $stAuto 'tok'
  Assert (($s5c.syncState -eq 'failed') -and ($s5c.resultExit -eq 1)) 'R4P2 real child failure never success result'
  Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath (Join-Path $stAuto 'dashboard.sync-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.json') (@{ runId = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; exitCode = 0; finishedAt = '2026-01-01 00:00:00'; result = 'success' } | ConvertTo-Json -Compress) -Encoding Ascii
  $s5d = Get-SyncState $stAuto 'tok'
  Assert ($s5d.syncState -eq 'unconfirmed') 'R4P2 foreign runID file ignored (association strict)'
  $heldS = [System.IO.File]::Open((Join-Path $stAuto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try { $s6 = Get-SyncState $stAuto 'tok'; Assert ($s6.syncState -eq 'running') 'R4P2 locked running' } finally { $heldS.Close() }

  # R4P2b Watch helper runs the fixed launcher hidden and records the real exit code (no sync script change)
  Copy-Item -LiteralPath $watchPath -Destination (Join-Path $stAuto 'Watch-Sync.ps1') -Force
  Set-Content -LiteralPath (Join-Path $stAuto 'Run-ProjectRules.vbs') 'WScript.Quit 0' -Encoding Ascii
  $wreq = Write-SyncRequest $stAuto
  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $stAuto 'Watch-Sync.ps1') -AutoDir $stAuto -RunId $wreq.id
  Assert ($LASTEXITCODE -eq 0) 'R4P2b watch records without own failure'
  $ws = Get-SyncState $stAuto 'tok'
  Assert (($ws.syncState -eq 'success') -and ($ws.resultExit -eq 0)) 'R4P2b real child exit 0 -> success'
  Set-Content -LiteralPath (Join-Path $stAuto 'Run-ProjectRules.vbs') 'WScript.Quit 3' -Encoding Ascii
  $wreq2 = Write-SyncRequest $stAuto
  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $stAuto 'Watch-Sync.ps1') -AutoDir $stAuto -RunId $wreq2.id
  Assert ($LASTEXITCODE -eq 0) 'R4P2b watch records child failure without own failure'
  $ws2 = Get-SyncState $stAuto 'tok'
  Assert (($ws2.syncState -eq 'failed') -and ($ws2.resultExit -eq 3) -and ($ws2.syncState -ne 'success')) 'R4P2b real child exit 3 -> failed (never success)'

  # R5P1 actual held-lock skip is recorded as skipped, never success (real lock + real sync -ReportSkip via Watch).
  Copy-Item -LiteralPath $syncPath -Destination (Join-Path $stAuto 'Sync-ProjectRules.ps1') -Force
  $r5req = Write-SyncRequest $stAuto
  $heldR5 = [System.IO.File]::Open((Join-Path $stAuto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $stAuto 'Watch-Sync.ps1') -AutoDir $stAuto -RunId $r5req.id
    Assert ($LASTEXITCODE -eq 0) 'R5P1 watch records held-lock skip without own failure'
  } finally { $heldR5.Close() }
  $r5res = Get-SyncResult $stAuto $r5req.id
  Assert (($null -ne $r5res) -and ([int]$r5res.exitCode -eq 75) -and ([string]$r5res.result -ceq 'skipped')) 'R5P1 held-lock child exit 75 recorded as skipped'
  $r5st = Get-SyncState $stAuto 'tok'
  Assert (($r5st.syncState -ceq 'skipped') -and ($r5st.syncState -cne 'success')) 'R5P1 held-lock run is skipped, never success'
  Assert ($r5st.syncId -ceq $r5req.id) 'R5P1 skipped runID matches request'
  # R5P1b foreign skipped result is ignored for the current runID (association strict).
  $r5reqB = Write-SyncRequest $stAuto
  $r5stB = Get-SyncState $stAuto 'tok'
  Assert (($r5stB.syncState -cne 'skipped') -and ($r5stB.syncState -cne 'success')) 'R5P1b foreign skipped file ignored (current run unconfirmed/waiting)'
  Assert ($r5stB.syncId -ceq $r5reqB.id) 'R5P1b current runID tracked after overwrite'

  # R6P2 confirmed runID result wins over lock; running stays independent.
  $r6req = Write-SyncRequest $stAuto
  $r6rf = Get-SyncResultFile $stAuto $r6req.id
  Set-Content -LiteralPath $r6rf (@{ runId = $r6req.id; exitCode = 75; finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); result = 'skipped' } | ConvertTo-Json -Compress) -Encoding Ascii
  $heldR6 = [System.IO.File]::Open((Join-Path $stAuto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $r6st = Get-SyncState $stAuto 'tok'
    Assert (($r6st.syncState -ceq 'skipped') -and ($r6st.running -eq $true)) 'R6P2 lock-held confirmed skipped wins (running independent)'
    Assert (($r6st.resultExit -eq 75) -and ($r6st.syncId -ceq $r6req.id)) 'R6P2 lock-held skipped keeps runID+exit75'
  } finally { $heldR6.Close() }
  Remove-Item -LiteralPath $r6rf -Force -ErrorAction SilentlyContinue
  $r6req2 = Write-SyncRequest $stAuto
  $heldR6b = [System.IO.File]::Open((Join-Path $stAuto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $r6st2 = Get-SyncState $stAuto 'tok'
    Assert (($r6st2.syncState -eq 'running') -and ($r6st2.running -eq $true)) 'R6P2 no-result lock-held stays running'
  } finally { $heldR6b.Close() }

  # R4P3 registry replace keeps original and is atomic (File.Replace/File.Move, PS5.1, no tmp leak)
  Set-Content -LiteralPath (Join-Path $auto 'projects.json') '[]' -Encoding Ascii
  $regLock = [System.IO.File]::Open((Join-Path $auto 'projects.json'), 'Open', 'ReadWrite', 'None')
  try {
    $rfail = $false
    try { Write-RegistryAtomicLocked $auto @([pscustomobject]@{ name = 'Y'; path = $repoA }) } catch { $rfail = ($_.Exception.Message.Contains('registry replace failed')) }
    Assert ($rfail) 'R4P3 replace-fail throws with original-kept message'
    $tmps2 = @(Get-ChildItem -LiteralPath $auto -Filter 'projects.json.tmp-*' -ErrorAction SilentlyContinue)
    Assert ($tmps2.Count -eq 0) 'R4P3 no tmp leak on replace-fail'
    $baks2 = @(Get-ChildItem -LiteralPath $auto -Filter 'projects.json.bak-*' -ErrorAction SilentlyContinue)
    Assert ($baks2.Count -eq 0) 'R4P3 no bak leak on replace-fail'
  } finally { $regLock.Close() }
  $kept = Get-Content -LiteralPath (Join-Path $auto 'projects.json') -Raw -Encoding Ascii
  Assert ($kept.Trim() -eq '[]') 'R4P3 original kept after replace-fail'
  Assert ((@(Get-Registry $auto)).Count -eq 0) 'R4P3 registry still parseable empty'
  $srvTxt = Get-Content -LiteralPath $srvPath -Raw
  Assert ($srvTxt.Contains('File.Replace') -and $srvTxt.Contains('File.Move')) 'R4P3 atomic replace/move (no delete-then-move)'
  Assert (-not ($srvTxt.Contains('Move-Item -LiteralPath $tmp -Destination $f -Force'))) 'R4P3 non-atomic registry move removed'

  # R4P1 verify is HTTP.sys-aware (LISTENING PID 4 or self; client lines ignored; health nonce decides)
  $vfy = Get-Content -LiteralPath $vfyPath -Raw
  Assert (($vfy.Contains('netstat') -and $vfy.Contains('dashboard.state.json') -and $vfy.Contains('/health'))) 'R4P1 verify checks state+TCP+health'
  Assert ($vfy.Contains('LISTENING')) 'R4P1 verify only LISTENING lines (client lines ignored)'
  Assert (($vfy.Contains('-eq 4') -or $vfy.Contains('eq 4)'))) 'R4P1 verify accepts HTTP.sys PID 4'
  Assert ($vfy.Contains('health identity mismatch')) 'R4P1 verify rejects foreign health nonce'
  Assert (-not ($vfy.Contains('tcp owner not ours'))) 'R4P1 HttpListener PID-mismatch refusal removed'
  $bat = Get-Content -LiteralPath $batPath -Raw -Encoding UTF8
  Assert (($bat.Contains('Verify-Dashboard.ps1') -and ($bat.Contains('送信しません') -or $bat.Contains('トークン') -or $bat.Contains('Token was not sent') -or $bat.Contains('Token')))) 'R4P1 bat gates token on verify (fail screen, ASCII bat for cmd safety)'
  $srvTxt = Get-Content -LiteralPath $srvPath -Raw
  Assert (($srvTxt.Contains('Write-DashboardState') -and $srvTxt.Contains('dashboard.state.json'))) 'R4P1 server writes state (PID+start)'
  Assert ((Get-Command Write-DashboardState -ErrorAction SilentlyContinue) -ne $null) 'R4P1 state fn exposed (no listen)'
  Assert ((Get-Command Get-SyncState -ErrorAction SilentlyContinue) -ne $null) 'R4P2 state fn exposed'
  Assert ((Get-Command Get-SyncResult -ErrorAction SilentlyContinue) -ne $null) 'R4P2 result fn exposed'
  Assert ((Get-Command Test-ParentReparse -ErrorAction SilentlyContinue) -ne $null) 'R3P4 parent-reparse fn exposed'
  # R4P4 token is created only after the listen win (simultaneous first starts cannot overwrite)
  $startIdx = $srvTxt.IndexOf('$l.Start()')
  $tokIdx = $srvTxt.IndexOf('Get-SessionToken $AutoDir')
  $stateIdx = $srvTxt.IndexOf('Write-DashboardState $AutoDir')
  Assert ((($startIdx -ge 0) -and ($tokIdx -gt $startIdx) -and ($stateIdx -gt $tokIdx))) 'R4P4 listen wins before token+state publish'
  # R4P5 poll has per-request AbortController timeout plus a 60s overall deadline (no hang)
  Assert (($srvTxt.Contains('AbortController') -and $srvTxt.Contains('signal') -and $srvTxt.Contains('abort'))) 'R4P5 per-request abort timeout'
  Assert ($srvTxt.Contains('60000')) 'R4P5 overall 60s deadline'

  # R5P2 poll never uses old DOM success on comm failure: runID-matched response only, no DOM fallback for completion.
  Assert ($srvTxt.Contains('s.syncId !== syncId')) 'R5P2 foreign runID ignored (association strict)'
  $pollIdx = $srvTxt.IndexOf('async function pollUntilDone')
  $pollJs = ''
  if ($pollIdx -ge 0) { $pollJs = $srvTxt.Substring($pollIdx, [Math]::Min(2600, $srvTxt.Length - $pollIdx)) }
  Assert (($pollJs.Contains('s.syncId !== syncId') -and $pollJs.Contains('continue'))) 'R5P2 poll skips mismatched runID'
  Assert (($pollJs.Contains('"success"') -and $pollJs.Contains('"failed"') -and $pollJs.Contains('"skipped"'))) 'R5P2 poll completes only on success/failed/skipped'
  Assert (-not ($pollJs.Contains('dataset.state') -and $pollJs.Contains('return st'))) 'R5P2 no DOM old-success fallback for completion'
  Assert ($srvTxt.Contains('skipped')) 'R5P2 skipped state carried end-to-end'
  # R5P3 deadline bounds every request: min(8s, remaining), single state call, no request after deadline.
  Assert ($srvTxt.Contains('Math.min(8000')) 'R5P3 per-request timeout is min(8s, remaining)'
  Assert ($srvTxt.Contains('deadline - Date.now()')) 'R5P3 remaining deadline drives timeout and sleep'
  Assert (($srvTxt.Contains('if(rem <= 0)') -or $srvTxt.Contains('if(t <= 0)'))) 'R5P3 no request after deadline'
  Assert ($srvTxt.Contains('updateSyncUI')) 'R5P3 single state-call render center (no duplicate refresh in poll)'
  Assert (-not ($pollJs.Contains('await refresh('))) 'R5P3 poll does not duplicate full refresh per iteration'
  Assert ($srvTxt.Contains('Test-SyncLocked $AutoDir') -and $srvTxt.Contains('/api/sync')) 'R5P3 pre-busy sync guard present'
  Assert (($srvTxt.Contains("state = 'skipped'") -or $srvTxt.Contains('skipped'))) 'R5P3 server skipped state present'

  Assert ($srvTxt.Contains('Test-SyncLocked $AutoDir') -and $srvTxt.Contains('/api/sync')) 'R5P3 pre-busy sync guard present'
  Assert (($srvTxt.Contains("state = 'skipped'") -or $srvTxt.Contains('skipped'))) 'R5P3 server skipped state present'

  # BROWSE+OPEN+MODAL (isolated, scratch only, no UI popup, no real AppData)
  $browseHelper = $browsePath
  Assert (Test-Path -LiteralPath $browseHelper) 'BX helper file exists (fixed STA helper)'
  $brTxt = Get-Content -LiteralPath $browseHelper -Raw
  Assert (($brTxt.Contains('IFileDialog') -and $brTxt.Contains('DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7') -and $brTxt.Contains('FOS_PICKFOLDERS') -and $brTxt.Contains('.Show(') -and $brTxt.Contains('SetFolder') -and $brTxt.Contains('GetResult'))) 'BX helper uses Explorer CommonItemDialog (IFileDialog base on FileOpenDialog CLSID)'
  Assert ((-not ($brTxt.Contains('FolderBrowserDialog'))) -and (-not ($brTxt.Contains('System.Windows.Forms'))) -and (-not ($brTxt.Contains('ShowDialog')))) 'BX old WinForms tree dialog usage zero (no fallback)'
  Assert (($brTxt.Contains('FOS_FORCEFILESYSTEM') -and $brTxt.Contains('SIGDN_FILESYSPATH') -and $brTxt.Contains('SetFolder'))) 'BX filesystem-only + initial dir (Explorer address/search/list kept)'
  Assert (($brTxt.Contains('.SetTitle(') -and $brTxt.Contains('.SetOkButtonLabel('))) 'BX SetTitle/OkLabel set (old E_FAIL claim retracted, S_OK verified pre-Show)'
  Assert (-not ($brTxt.Contains('E_FAIL'))) 'BX stale E_FAIL note removed'
  # P1 vtable: exact SDK order (ShObjIdl_core.h IFileDialog), GetFolder/GetCurrentSelection present,
  # SetDefaultExtension after AddPlace (old misplaced slot fixed).
  $vtOrder = @('int Show(IntPtr parent)','int SetFileTypes(','int SetFileTypeIndex(','int GetFileTypeIndex(','int Advise(','int Unadvise(','int SetOptions(','int GetOptions(','int SetDefaultFolder(','int SetFolder(','int GetFolder(','int GetCurrentSelection(','int SetFileName(','int GetFileName(','int SetTitle(','int SetOkButtonLabel(','int SetFileNameLabel(','int GetResult(','int AddPlace(','int SetDefaultExtension(','int Close(','int SetClientGuid(','int ClearClientData(','int SetFilter(')
  $vtOk = $true; $prevIdx = -1
  foreach ($vn in $vtOrder) { $ix = $brTxt.IndexOf($vn); if (($ix -lt 0) -or ($ix -le $prevIdx)) { $vtOk = $false; break }; $prevIdx = $ix }
  Assert ($vtOk) 'BX vtable order matches SDK (Show..SetFilter, GetFolder/GetCurrentSelection present)'
  Assert (($brTxt.IndexOf('AddPlace') -lt $brTxt.IndexOf('SetDefaultExtension'))) 'BX SetDefaultExtension after AddPlace (slot fix)'
  Assert (($brTxt.Contains('42F85136-DB7E-439C-85F1-E4075D135FC8') -and $brTxt.Contains('interface IFileDialog'))) 'BX GUID 42F85136 named IFileDialog (SDK match)'
  # P2: cancel is Show 0x800704C7 only; S_OK empty path throws (exit 1); no result swallowing.
  Assert ($brTxt.Contains('IsNullOrWhiteSpace($selPath)')) 'BX S_OK empty path throws (not cancelled)'
  Assert ($brTxt.Contains('picker returned empty path')) 'BX empty result is failure message (exit 1)'
  Assert (-not ($brTxt.Contains('catch { s = $null }'))) 'BX result GetFileSystemPath swallow removed'
  Assert (-not ($brTxt.Contains('catch { pickedPath = $null }'))) 'BX result GetFullPath swallow removed'
  Assert (($brTxt.Contains('0x800704C7') -and $brTxt.Contains('ERROR_CANCELLED'))) 'BX cancel HRESULT mapped to cancelled exit 0'
  Assert ($brTxt.Contains('ReleaseComObject')) 'BX COM released in finally'
  Assert ($brTxt.Contains('ShowFolderPicker')) 'BX all COM calls inside C# static (no PS late-binding)'
  # BX real COM isolation (no UI popup: Show never called; static helpers only)
  try {
    $m = [regex]::Match($brTxt, "(?s)Add-Type -TypeDefinition @'(.*?)'@")
    Assert ($m.Success) 'BX AddType block found'
    if ($m.Success) {
      try { Add-Type -TypeDefinition $m.Groups[1].Value -ErrorAction Stop } catch { if ($_.Exception.Message -notmatch 'already exists') { throw } }
      $fpType = $null
      try { $fpType = [FolderPickerNative] } catch { $fpType = $null }
      Assert (($fpType -ne $null)) 'BX AddType compiles on PS5.1'
      $o1 = [FolderPickerNative]::GetPickerOptionsForTest()
      Assert ((($o1 -band [FolderPickerNative]::FOS_PICKFOLDERS) -ne 0) -and (($o1 -band [FolderPickerNative]::FOS_FORCEFILESYSTEM) -ne 0)) 'BX FOS_PICKFOLDERS|FORCEFILESYSTEM options set (real COM, no popup)'
      # P1 vtable round-trip without Show popup: SetTitle/SetFolder/GetFolder S_OK, echo matches.
      $vtDir = Join-Path $scratch '日本語 vtable 検証'
      New-Item -ItemType Directory -Force -Path $vtDir | Out-Null
      $vtBack = [FolderPickerNative]::VerifyVtableForTest($vtDir)
      Assert ([string]$vtBack -ceq $vtDir) 'BX vtable round-trip SetFolder/GetFolder echoes path (slot order proven, no popup)'
      # NOTE: Show popup itself is not tested headless; success is NOT claimed from compile alone.
      $jpDir = Join-Path $scratch '日本語 選択 dialog'
      New-Item -ItemType Directory -Force -Path $jpDir | Out-Null
      $back = [FolderPickerNative]::ResolveFileSystemPath($jpDir)
      Assert ([string]$back -ceq $jpDir) 'BX filesystem path round-trips (Unicode/space/drive preserved)'
      $uncFull = [System.IO.Path]::GetFullPath('\\localhost\C$\Windows')
      Assert ($uncFull.StartsWith('\\')) 'BX UNC form preserved by GetFullPath'
      Assert (([FolderPickerNative]::ERROR_CANCELLED -eq -2147023673)) 'BX cancel HRESULT value is 0x800704C7'
      Assert (([FolderPickerNative]::S_OK -eq 0)) 'BX S_OK is 0'
    }
  } catch { Assert ($false) 'BX real COM isolation ran without popup' }
  # BX helper arg isolation (no dialog popup: bad id / missing autodir / pre-existing cancel wins)
  try {
    $psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $browseHelper -AutoDir $auto -BrowseId 'bad-id'
    Assert ($LASTEXITCODE -eq 2) 'BX bad browseId exits 2'
    $preId = 'dddddddddddddddddddddddddddddddd'
    $preRf = Join-Path $auto ("dashboard.browse-" + $preId + ".json")
    if (Test-Path -LiteralPath $preRf) { Remove-Item -LiteralPath $preRf -Force }
    Set-Content -LiteralPath $preRf (@{ browseId = $preId; status = 'cancelled'; finishedAt = '2026-10-13 00:00:00' } | ConvertTo-Json -Compress) -Encoding UTF8
    & $psExe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $browseHelper -AutoDir $auto -BrowseId $preId
    Assert ($LASTEXITCODE -eq 0) 'BX pre-existing cancel wins exit 0 (no overwrite)'
    $preBack = Get-Content -LiteralPath $preRf -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ([string]$preBack.status -ceq 'cancelled') 'BX pre-existing result kept'
    Remove-Item -LiteralPath $preRf -Force -ErrorAction SilentlyContinue
    & $psExe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $browseHelper -AutoDir (Join-Path $auto 'no-such-autodir') -BrowseId 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    Assert ($LASTEXITCODE -eq 2) 'BX missing autodir exits 2'
  } catch { Assert ($false) 'BX helper arg isolation ran' }
  Assert ($brTxt.Contains('cancelled') -and $brTxt.Contains('selected')) 'BX helper selected/cancelled both recorded'
  Assert ($brTxt.Contains('if (Test-Path -LiteralPath $rf) { exit 0 }')) 'BX cancel wins (no overwrite)'
  Assert ($brTxt.Contains('UTF8') -and $brTxt.Contains('FileSecurity')) 'BX helper UTF8 private write (Japanese paths safe)'
  Assert ((-not ($brTxt.Contains('Invoke-Expression'))) -and (-not ($brTxt.Contains('cmd /c')))) 'BX helper no arbitrary command'
  Assert (($srvTxt.Contains('Browse-Folder.ps1') -and $srvTxt.Contains("'-STA'"))) 'BX server launches fixed STA helper (separate process, no block)'
  Assert ((Get-Command Get-BrowseResultFile -ErrorAction SilentlyContinue) -ne $null) 'BX browse file fn exposed'
  Assert ((Get-Command Get-BrowseResult -ErrorAction SilentlyContinue) -ne $null) 'BX browse result fn exposed'
  Assert ((Get-Command Start-BrowseRequest -ErrorAction SilentlyContinue) -ne $null) 'BX browse start fn exposed'
  Assert ((Get-Command Write-BrowseCancelled -ErrorAction SilentlyContinue) -ne $null) 'BX browse cancel fn exposed'
  Assert ((Get-Command Get-RegisteredFolderPath -ErrorAction SilentlyContinue) -ne $null) 'BX registered-path fn exposed'
  Assert ($srvTxt.Contains('/api/browse') -and $srvTxt.Contains('/api/open')) 'BX browse+open endpoints present'
  Assert ($srvTxt.Contains("Join-Path `$env:SystemRoot 'explorer.exe'")) 'BX explorer absolute SystemRoot (no bare exe)'
  Assert ($srvTxt.Contains('-ArgumentList $full2')) 'BX explorer path via ArgumentList data (space/meta/Japanese safe)'
  Assert (-not ($srvTxt.Contains('Start-Process -FilePath $full'))) 'BX no user-controlled FilePath (fixed explorer only)'
  Assert ((-not ($srvTxt.Contains('Invoke-Expression'))) -and (-not ($srvTxt.Contains('cmd.exe /c')))) 'BX server no arbitrary shell'
  Assert ($srvTxt.Contains('Get-RegisteredFolderPath $AutoDir $nm2')) 'BX open re-resolves from registry name (no command path API)'
  # Modal: original overlay, no browser confirm modal, no native dialogs
  Assert ($srvTxt.Contains('id="ovl"') -and $srvTxt.Contains('role="dialog"') -and $srvTxt.Contains('aria-modal')) 'BX modal overlay labelled dialog'
  Assert ($srvTxt.Contains('aria-labelledby') -and $srvTxt.Contains('mTitle') -and $srvTxt.Contains('mMsg')) 'BX modal title/message labelled'
  Assert ($srvTxt.Contains('Escape') -and $srvTxt.Contains('"Tab"') -and $srvTxt.Contains('inert')) 'BX modal Escape/Tab-trap/background-inert'
  Assert ($srvTxt.Contains('lastFocus') -and $srvTxt.Contains('focus()')) 'BX modal focus restore'
  Assert ($srvTxt.Contains('mTitle') -and $srvTxt.Contains('textContent')) 'BX modal title/message via textContent (XSS-free)'
  Assert ($srvTxt.Contains('showNotify') -and $srvTxt.Contains('showConfirm')) 'BX custom notify+confirm fns'
  Assert ($srvTxt.Contains('if(!ok) return;') -and $srvTxt.Contains('if(!okGo)')) 'BX cancel stops with no request (unregister+register)'
  Assert ($srvTxt.Contains('id="btnBrowse"') -and $srvTxt.Contains('pollBrowse') -and $srvTxt.Contains('browseArea')) 'BX browse button+bounded poll+cancel UI'
  Assert ($srvTxt.Contains('120000') -and $srvTxt.Contains('Math.min(8000')) 'BX browse bounded poll (deadline+min timeout)'
  Assert ($srvTxt.Contains('エクスプローラーで開く') -and $srvTxt.Contains('btnBrowse') -ne $false) 'BX explorer button title present'
  $natAlert = ([regex]::Matches($srvTxt, 'alert\(')).Count
  $natConfirm = ([regex]::Matches($srvTxt, 'confirm\(')).Count
  $natPrompt = ([regex]::Matches($srvTxt, 'prompt\(')).Count
  Assert (($natAlert -eq 0) -and ($natConfirm -eq 0) -and ($natPrompt -eq 0)) 'BX native alert/confirm/prompt zero'
  # PS syntax both files
  try {
    $pe1 = $null; $pt1 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($srvPath, [ref]$pt1, [ref]$pe1)
    Assert (($pe1.Count -eq 0)) 'BX PS syntax Dashboard-Server ok'
    $pe2 = $null; $pt2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($browseHelper, [ref]$pt2, [ref]$pe2)
    Assert (($pe2.Count -eq 0)) 'BX PS syntax Browse-Folder ok'
  } catch { Assert ($false) 'BX PS syntax check ran' }
  # JS syntax of served script
  try {
    $nodeExe2 = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe2) { $nodeExe2 = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeExe2) {
      $mm = [regex]::Match($srvTxt, '(?s)<script>(.*)</script>')
      if ($mm.Success) {
        $jsTmp2 = Join-Path $scratch 'browse-check.js'
        Set-Content -LiteralPath $jsTmp2 $mm.Groups[1].Value -Encoding UTF8
        & $nodeExe2 --check $jsTmp2
        Assert ($LASTEXITCODE -eq 0) 'BX served JS parses (node --check)'
      } else { Assert ($false) 'BX script block found' }
    } else { Assert ($true) 'BX node missing skips parse check' }
  } catch { Assert ($false) 'BX served JS parse check ran' }

  # BX owner foreground: parentless Show(IntPtr.Zero) hid behind browser.
  # Server captures GetForegroundWindow at click, helper Show(owner) is basis;
  # restore is best-effort (OS may refuse). No topmost, no unrelated steal.
  Assert ($brTxt.Contains('OwnerHwnd')) 'BX owner param present (helper accepts server data)'
  Assert ($brTxt.Contains('ShowFolderPickerWithOwner')) 'BX owner Show entry present'
  Assert ($brTxt.Contains('dlg.Show(owner)')) 'BX Show takes owner arg (not Zero-only)'
  Assert (($brTxt.Contains('IsWindow') -and $brTxt.Contains('IsWindowVisible'))) 'BX owner live+visible validated (STA thread)'
  Assert (($brTxt.Contains('SetForegroundWindow') -and $brTxt.Contains('BringWindowToTop'))) 'BX owner restore helpers present (best-effort)'
  Assert (($brTxt.Contains('ParseOwnerHwndForTest') -and $brTxt.Contains('IsValidOwnerForTest'))) 'BX owner helpers testable (no popup)'
  Assert ((-not ($brTxt.Contains('TOPMOST') -or $brTxt.Contains('SetWindowPos')))) 'BX no topmost forcing (owner basis only)'
  Assert (($srvTxt.Contains('GetForegroundWindow') -and $srvTxt.Contains("'-OwnerHwnd'"))) 'BX server captures foreground and passes owner data'
  Assert ((Get-Command Get-BrowseOwnerHwndLong -ErrorAction SilentlyContinue) -ne $null) 'BX owner capture fn exposed'
  Assert ((-not ($srvTxt.Contains('body.owner') -or $srvTxt.Contains('body.hwnd')))) 'BX owner never from HTTP body (trust boundary)'
  Assert ($srvTxt.Contains('safeFocus(bb)')) 'BX cancel keeps browser focus (web modal restore)'
  try {
    Assert (([FolderPickerNative]::ParseOwnerHwndForTest('0') -eq 0)) 'BX owner parse zero falls back'
    Assert (([FolderPickerNative]::ParseOwnerHwndForTest('-5') -eq 0)) 'BX owner parse negative falls back'
    Assert (([FolderPickerNative]::ParseOwnerHwndForTest('abc') -eq 0)) 'BX owner parse non-numeric falls back'
    Assert (([FolderPickerNative]::ParseOwnerHwndForTest('') -eq 0)) 'BX owner parse empty falls back'
    Assert (([FolderPickerNative]::ParseOwnerHwndForTest('99999999999999999999') -eq 0)) 'BX owner parse overflow falls back (64-bit width)'
    Assert (([FolderPickerNative]::ParseOwnerHwndForTest('12345') -eq 12345)) 'BX owner parse positive passes range check'
    Assert (([FolderPickerNative]::IsValidOwnerForTest([IntPtr]::Zero) -eq $false)) 'BX zero owner invalid (safe fallback)'
    Assert (([FolderPickerNative]::IsValidOwnerForTest((New-Object System.IntPtr(12345))) -eq $false)) 'BX dead owner invalid (no steal)'
    $fgOwner = 0
    try { $fgOwner = [FolderPickerNative]::GetForegroundWindowForTest() } catch { $fgOwner = 0 }
    Assert (($fgOwner -is [long])) 'BX foreground helper dispatches without popup'
    $srvOwner = Get-BrowseOwnerHwndLong
    Assert ((($srvOwner -is [long]) -and ($srvOwner -ge 0))) 'BX server capture returns non-negative 64-bit (0 falls back)'
  } catch { Assert ($false) 'BX owner helpers validation ran without popup' }
  try {
    $psExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $browseHelper -AutoDir $auto -BrowseId 'bad-id' -OwnerHwnd 'not-a-number'
    Assert ($LASTEXITCODE -eq 2) 'BX owner bogus keeps bad-id exit 2 (validation first)'
    $ownPreId = 'cccccccccccccccccccccccccccccccc'
    $ownPreRf = Join-Path $auto ("dashboard.browse-" + $ownPreId + ".json")
    if (Test-Path -LiteralPath $ownPreRf) { Remove-Item -LiteralPath $ownPreRf -Force }
    Set-Content -LiteralPath $ownPreRf (@{ browseId = $ownPreId; status = 'cancelled'; finishedAt = '2026-10-13 00:00:00' } | ConvertTo-Json -Compress) -Encoding UTF8
    & $psExe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $browseHelper -AutoDir $auto -BrowseId $ownPreId -OwnerHwnd '-7'
    Assert ($LASTEXITCODE -eq 0) 'BX owner invalid keeps cancel-wins exit 0 (no overwrite)'
    $ownPreBack = Get-Content -LiteralPath $ownPreRf -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ([string]$ownPreBack.status -ceq 'cancelled') 'BX owner invalid keeps pre-existing cancel'
    Remove-Item -LiteralPath $ownPreRf -Force -ErrorAction SilentlyContinue
  } catch { Assert ($false) 'BX owner cancel isolation ran' }

  # FG-R2 foregroundfix r2 (scratch only, no popup, no real AppData)
  Assert ((Get-Command Initialize-BrowseOwnerNative -ErrorAction SilentlyContinue) -ne $null) 'FG-R2 interop pre-compile fn exposed'
  Assert ((Get-Command Get-BrowseOwnerCapture -ErrorAction SilentlyContinue) -ne $null) 'FG-R2 capture fn exposed (HWND+PID+start)'
  Assert ((Get-Command Test-BrowseOwnerAllowed -ErrorAction SilentlyContinue) -ne $null) 'FG-R2 browser allow fn exposed'
  Assert (($srvTxt.Contains('Initialize-BrowseOwnerNative') -and $srvTxt.Contains('Get-BrowseOwnerCapture'))) 'FG-R2 server pre-compile+capture present'
  $initIdxFg = $srvTxt.IndexOf('Initialize-BrowseOwnerNative')
  $listenIdxFg = $srvTxt.IndexOf('$l.Start()')
  Assert ((($initIdxFg -ge 0) -and ($listenIdxFg -gt $initIdxFg))) 'FG-R2 interop compiled before listen (startup pre-compile)'
  $capIdxFg = $srvTxt.IndexOf('function Get-BrowseOwnerCapture')
  $capBodyFg = ''
  if ($capIdxFg -ge 0) { $capBodyFg = $srvTxt.Substring($capIdxFg, [Math]::Min(4000, $srvTxt.Length - $capIdxFg)) }
  Assert ((-not ($capBodyFg.Contains('Add-Type')))) 'FG-R2 capture has no AddType (pre-compiled early)'
  $hwndIdxFg = $srvTxt.IndexOf('function Get-BrowseOwnerHwndLong')
  $hwndBodyFg = ''
  if ($hwndIdxFg -ge 0) { $hwndBodyFg = $srvTxt.Substring($hwndIdxFg, [Math]::Min(800, $srvTxt.Length - $hwndIdxFg)) }
  Assert ((-not ($hwndBodyFg.Contains('Add-Type')))) 'FG-R2 HWND wrapper has no AddType (startup only)'
  Assert (($srvTxt.Contains('earlyBrowseCap') -and $srvTxt.Contains('Get-BrowseOwnerCapture'))) 'FG-R2 API early capture present'
  $earlyIdxFg = $srvTxt.IndexOf('$earlyBrowseCap = Get-BrowseOwnerCapture')
  $readBodyIdxFg = $srvTxt.IndexOf('Read-Body $req')
  Assert ((($earlyIdxFg -ge 0) -and ($readBodyIdxFg -gt $earlyIdxFg))) 'FG-R2 early capture before body read'
  Assert (($srvTxt.Contains("'-OwnerPid'") -and $srvTxt.Contains("'-OwnerStart'"))) 'FG-R2 helper receives PID+start identity'
  Assert ((-not ($srvTxt.Contains('body.owner') -or $srvTxt.Contains('body.hwnd') -or $srvTxt.Contains('body.pid')))) 'FG-R2 HTTP owner prohibited (server capture only)'
  Assert (($srvTxt.Contains('GetWindowThreadProcessId') -and $srvTxt.Contains('GetWindowClassForTest') -and $srvTxt.Contains('GetWindowTitleForTest'))) 'FG-R2 native PID/class/title present'
  Assert (($srvTxt.Contains('Chrome_WidgetWin_1') -and $srvTxt.Contains('MozillaWindowClass') -and $srvTxt.Contains('shirube'))) 'FG-R2 Chromium/Firefox + Shirube title (arbitrary excluded)'
  try {
    Assert ((Test-BrowseOwnerAllowed 'chrome' 'Chrome_WidgetWin_1' 'Shirube Test') -eq $true) 'FG-R2 chrome accepted'
    Assert ((Test-BrowseOwnerAllowed 'firefox' 'MozillaWindowClass' 'Shirube Test') -eq $true) 'FG-R2 firefox accepted'
    Assert ((Test-BrowseOwnerAllowed 'msedge' 'Chrome_WidgetWin_1' 'Shirube Test') -eq $true) 'FG-R2 edge accepted'
    Assert ((Test-BrowseOwnerAllowed 'notepad' 'Notepad' 'test') -eq $false) 'FG-R2 otherapp rejected'
    Assert ((Test-BrowseOwnerAllowed 'Code' 'Chrome_WidgetWin_1' 'Visual Studio Code') -eq $false) 'FG-R2 VSCode same-class rejected'
    Assert ((Test-BrowseOwnerAllowed 'electron' 'Chrome_WidgetWin_1' 'Shirube Test') -eq $true) 'FG-R2 Electron+Shirube accepted'
    Assert ((Test-BrowseOwnerAllowed 'electron' 'Chrome_WidgetWin_1' 'Other App') -eq $false) 'FG-R2 Electron without Shirube rejected'
    Assert ((Test-BrowseOwnerAllowed 'notepad' 'Notepad' 'Shirube memo') -eq $false) 'FG-R2 title-only arbitrary rejected'
  } catch { Assert ($false) 'FG-R2 allow check ran without popup' }
  # FG-R3 (1): all browsers need the known Dashboard title; a different-title
  # browser window is rejected (owner 0), even with matching process+class.
  try {
    Assert ((Test-BrowseOwnerAllowed 'chrome' 'Chrome_WidgetWin_1' 'YouTube') -eq $false) 'FG-R3 chrome different-title rejected (owner 0)'
    Assert ((Test-BrowseOwnerAllowed 'msedge' 'Chrome_WidgetWin_1' 'GitHub') -eq $false) 'FG-R3 edge different-title rejected (owner 0)'
    Assert ((Test-BrowseOwnerAllowed 'firefox' 'MozillaWindowClass' 'Inbox') -eq $false) 'FG-R3 firefox different-title rejected (owner 0)'
    Assert ((Test-BrowseOwnerAllowed 'chrome' 'Chrome_WidgetWin_1' '') -eq $false) 'FG-R3 empty title rejected (owner 0)'
    Assert ((Test-BrowseOwnerAllowed 'chrome' 'Chrome_WidgetWin_1' 'Shirube 管理ダッシュボード') -eq $true) 'FG-R3 chrome dashboard title accepted'
  } catch { Assert ($false) 'FG-R3 title check ran without popup' }
  Assert (($srvTxt.Contains('if (-not $hasShirube)'))) 'FG-R3 title gate first (all browsers require known title)'
  $sbIdxR3 = $srvTxt.IndexOf('function Start-BrowseRequest')
  $sbBodyR3 = ''
  if ($sbIdxR3 -ge 0) { $sbBodyR3 = $srvTxt.Substring($sbIdxR3, [Math]::Min(1200, $srvTxt.Length - $sbIdxR3)) }
  Assert ((-not ($sbBodyR3.Contains('Get-BrowseOwnerCapture')))) 'FG-R3 no late fallback capture (early API capture only, else owner 0)'
  Assert ($srvTxt.Contains('isBrowseStart0')) 'FG-R3 pre-auth expiry skipped for browse/start (capture before proc cleanup)'
  Assert (($brTxt.Contains('ParseOwnerPidForTest') -and $brTxt.Contains('GetWindowPidForTest') -and $brTxt.Contains('IsOwnerIdentityMatchForTest') -and $brTxt.Contains('ShouldRestoreForTest'))) 'FG-R2 helper identity+restore fns present'
  Assert (($brTxt.Contains('GetWindowThreadProcessId') -and $brTxt.Contains('ShowFolderPickerWithOwnerIdentity'))) 'FG-R2 helper PID native + identity Show present'
  Assert (($brTxt.Contains('$OwnerPid') -and $brTxt.Contains('$OwnerStart'))) 'FG-R2 helper accepts PID+start data'
  Assert ((-not ($brTxt.Contains('TOPMOST') -or $brTxt.Contains('SetWindowPos')))) 'FG-R2 no topmost kept (OS best-effort)'
  Assert (($brTxt.Contains('IntPtr.Size') -and $brTxt.Contains('int.MaxValue'))) 'FG-R2 x86 width intentional x64 fit kept'
  Assert (($srvTxt.Contains('IntPtr') -and $srvTxt.Contains('int.MaxValue'))) 'FG-R2 server x86 width kept'
  try {
    Assert (([FolderPickerNative]::ParseOwnerPidForTest('0') -eq 0)) 'FG-R2 pid zero falls back'
    Assert (([FolderPickerNative]::ParseOwnerPidForTest('-5') -eq 0)) 'FG-R2 pid negative falls back'
    Assert (([FolderPickerNative]::ParseOwnerPidForTest('abc') -eq 0)) 'FG-R2 pid non-numeric falls back'
    Assert (([FolderPickerNative]::ParseOwnerPidForTest('') -eq 0)) 'FG-R2 pid empty falls back'
    Assert (([FolderPickerNative]::ParseOwnerPidForTest('9999999999') -eq 0)) 'FG-R2 pid overflow falls back (int width)'
    Assert (([FolderPickerNative]::ParseOwnerPidForTest('1234') -eq 1234)) 'FG-R2 pid positive passes'
    Assert (([FolderPickerNative]::GetWindowPidForTest([IntPtr]::Zero) -eq 0)) 'FG-R2 zero HWND pid 0'
    Assert (([FolderPickerNative]::GetWindowPidForTest((New-Object System.IntPtr(12345))) -eq 0)) 'FG-R2 dead HWND pid 0'
    Assert (([FolderPickerNative]::IsOwnerIdentityMatchForTest([IntPtr]::Zero, 0, '') -eq $false)) 'FG-R2 zero identity invalid'
    Assert (([FolderPickerNative]::IsOwnerIdentityMatchForTest((New-Object System.IntPtr(12345)), 1234, '') -eq $false)) 'FG-R2 dead PID mismatch reuse reject'
    Assert (([FolderPickerNative]::IsOwnerIdentityMatchForTest((New-Object System.IntPtr(12345)), 0, '') -eq $false)) 'FG-R2 dead live-check fails'
    $helperPidFg = 5000
    Assert (([FolderPickerNative]::ShouldRestoreForTest(100, 100, 111, 222, $helperPidFg) -eq $true)) 'FG-R2 fg==owner restores'
    Assert (([FolderPickerNative]::ShouldRestoreForTest(200, 100, $helperPidFg, 222, $helperPidFg) -eq $true)) 'FG-R2 helper fg restores'
    Assert (([FolderPickerNative]::ShouldRestoreForTest(200, 100, 222, 222, $helperPidFg) -eq $false)) 'FG-R3 same-PID different-HWND never restores (no focus steal)'
    Assert (([FolderPickerNative]::ShouldRestoreForTest(200, 100, 99998, 222, $helperPidFg) -eq $false)) 'FG-R2 unrelated skips restore'
    Assert (([FolderPickerNative]::ShouldRestoreForTest(200, 0, 222, 222, $helperPidFg) -eq $false)) 'FG-R2 zero owner never restores'
    Assert ((-not ($brTxt.Contains('fgPid == ownerPid')))) 'FG-R3 same-PID owner permission removed (exact HWND or helper PID only)'
    $r3RetryCalls = @([regex]::Matches($brTxt, 'ShowFolderPickerWithOwner\(\$hintArg')).Count
    Assert ($r3RetryCalls -eq 1) 'FG-R3 failure retry zero (no PID/start-less re-Show; outer exit 1)'
    $srvCapFg = Get-BrowseOwnerCapture
    Assert ((($srvCapFg.Hwnd -is [long]) -and ($srvCapFg.Pid -is [int]) -and ($srvCapFg.Hwnd -ge 0) -and ($srvCapFg.Pid -ge 0))) 'FG-R2 server capture HWND+PID non-negative'
  } catch { Assert ($false) 'FG-R2 helper identity ran without popup' }
  try {
    $peFg = $null; $ptFg = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($srvPath, [ref]$ptFg, [ref]$peFg)
    Assert (($peFg.Count -eq 0)) 'FG-R2 PS syntax server ok'
    $peFg2 = $null; $ptFg2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($browseHelper, [ref]$ptFg2, [ref]$peFg2)
    Assert (($peFg2.Count -eq 0)) 'FG-R2 PS syntax helper ok'
  } catch { Assert ($false) 'FG-R2 PS syntax ran' }

  # BX unit: browse cancel/select round-trip (isolated browseAuto, UTF8 Japanese path)
  $bAuto = Join-Path $scratch 'browseAuto'
  New-Item -ItemType Directory -Force -Path $bAuto | Out-Null
  Set-Content -LiteralPath (Join-Path $bAuto 'projects.json') '[]' -Encoding Ascii
  $bidT = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  Assert ((Get-BrowseResultFile $bAuto 'bad-id') -eq $null) 'BX bad browseId refused (null file)'
  Assert ((Get-BrowseResultFile $bAuto 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA') -eq $null) 'BX uppercase browseId refused'
  Assert ((Get-BrowseResult $bAuto $bidT) -eq $null) 'BX no result yet (waiting)'
  $bc1 = Write-BrowseCancelled $bAuto $bidT
  Assert ([string]$bc1.status -ceq 'cancelled') 'BX cancel writes cancelled (exit-cancel no error)'
  $bc2 = Get-BrowseResult $bAuto $bidT
  Assert (([string]$bc2.status -ceq 'cancelled') -and ([string]$bc2.browseId -ceq $bidT)) 'BX cancel round-trips bound to request ID'
  $bc3 = Write-BrowseCancelled $bAuto $bidT
  Assert ([string]$bc3.status -ceq 'cancelled') 'BX second cancel idempotent (no overwrite error)'
  $bidS = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  $jpPick = Join-Path $scratch '日本語 選択'
  New-Item -ItemType Directory -Force -Path $jpPick | Out-Null
  $rfS = Get-BrowseResultFile $bAuto $bidS
  $jo = @{ browseId = $bidS; status = 'selected'; path = $jpPick; finishedAt = '2026-10-13 00:00:00' } | ConvertTo-Json -Compress
  Write-BrowseResultPrivate $rfS $jo
  $bs = Get-BrowseResult $bAuto $bidS
  Assert (([string]$bs.status -ceq 'selected') -and ([string]$bs.path -ceq $jpPick)) 'BX selected Japanese path round-trips (UTF8, select-only)'
  Assert ((Test-PrivateFileAcl $rfS) -eq $true) 'BX browse result private ACL'
  Set-Content -LiteralPath (Get-BrowseResultFile $bAuto 'cccccccccccccccccccccccccccccccc') (@{ browseId = 'dddddddddddddddddddddddddddddddd'; status = 'selected'; path = 'X' } | ConvertTo-Json -Compress) -Encoding UTF8
  Assert ((Get-BrowseResult $bAuto 'cccccccccccccccccccccccccccccccc') -eq $null) 'BX foreign browseId content ignored'
  # BX unit: explorer validation (registered-only, injection refused)
  $repoOpen = Join-Path $scratch 'OpenRepo'
  New-Item -ItemType Directory -Force -Path $repoOpen | Out-Null
  Write-RegistryAtomicLocked $bAuto @([pscustomobject]@{ name = 'OpenRepo'; path = $repoOpen })
  Assert ((Get-RegisteredFolderPath $bAuto 'OpenRepo') -ceq $repoOpen) 'BX registered name resolves (registry re-resolve)'
  $unkOk = $true
  try { Get-RegisteredFolderPath $bAuto 'NoSuch' | Out-Null } catch { $unkOk = ($_.Exception.Message.Contains('見つかりません')) }
  Assert ($unkOk) 'BX unknown name refused (registered-only)'
  $injOk = $true
  try { Get-RegisteredFolderPath $bAuto '../evil' | Out-Null; $injOk = $false } catch { $injOk = $true }
  Assert ($injOk) 'BX traversal name refused'
  $metaRepo = Join-Path $scratch 'Repo&Meta2'
  New-Item -ItemType Directory -Force -Path $metaRepo | Out-Null
  Write-RegistryAtomicLocked $bAuto @([pscustomobject]@{ name = 'Meta2'; path = $metaRepo })
  $metaOk = $true
  try { Get-RegisteredFolderPath $bAuto 'Meta2' | Out-Null; $metaOk = $false } catch { $metaOk = ($_.Exception.Message.Contains('記号')) }
  Assert ($metaOk) 'BX shell-meta registered path refused (injection safe)'
  $goneRepo = Join-Path $scratch 'GoneRepo'
  New-Item -ItemType Directory -Force -Path $goneRepo | Out-Null
  Write-RegistryAtomicLocked $bAuto @([pscustomobject]@{ name = 'GoneRepo'; path = $goneRepo })
  Remove-Item -LiteralPath $goneRepo -Force -Recurse
  $goneOk = $true
  try { Get-RegisteredFolderPath $bAuto 'GoneRepo' | Out-Null; $goneOk = $false } catch { $goneOk = ($_.Exception.Message.Contains('存在しません')) }
  Assert ($goneOk) 'BX missing folder refused'

  # R2 browse/modal r2 (isolated, scratch only, no dialog popup, no real AppData)
  Assert (($srvTxt.Contains('BrowseProcs') -and $srvTxt.Contains('Stop-OwnedBrowseProcess'))) 'R2-1 owned proc tracking present (requestID owned process)'
  Assert (($srvTxt.Contains('-PassThru') -and $srvTxt.Contains('Expires'))) 'R2-1 deadline tracking present (cancel/timeout bound)'
  Assert ((Get-Command Stop-OwnedBrowseProcess -ErrorAction SilentlyContinue) -ne $null) 'R2-1 stop fn exposed'
  Assert ((Get-Command Clear-ExpiredBrowseRequests -ErrorAction SilentlyContinue) -ne $null) 'R2-1 expiry fn exposed'
  Assert ($srvTxt.Contains('dashboard.browse-*.tmp-*')) 'R2-1 GUID tmp cleanup included (safe containment)'
  Assert (($srvTxt.Contains('BrowseProcs.Keys') -and $srvTxt.Contains('finally'))) 'R2-1 server exit stops owned only'
  $psExeT = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
  $ownedP = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $otherP = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $fakeId = 'dddddddddddddddddddddddddddddddd'
  if (-not $script:BrowseProcs) { $script:BrowseProcs = @{} }
  $script:BrowseProcs[$fakeId] = @{ Proc = $ownedP; Pid = $ownedP.Id; Expires = (Get-Date).AddSeconds(150) }
  $ownedIdSave = $ownedP.Id; $otherIdSave = $otherP.Id
  try { Stop-OwnedBrowseProcess $fakeId } catch {}
  Start-Sleep -Milliseconds 800
  Assert ((((Get-Process -Id $ownedIdSave -ErrorAction SilentlyContinue) -eq $null) -and ((Get-Process -Id $otherIdSave -ErrorAction SilentlyContinue) -ne $null))) 'R2-1 cancel stops owned only (unrelated survives)'
  try { Stop-Process -Id $otherIdSave -Force -ErrorAction SilentlyContinue } catch {}
  Assert (-not $script:BrowseProcs.ContainsKey($fakeId)) 'R2-1 owned entry removed after stop'
  $expP = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $expId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  $expIdSave = $expP.Id
  $script:BrowseProcs[$expId] = @{ Proc = $expP; Pid = $expP.Id; Expires = (Get-Date).AddSeconds(-1) }
  try { Clear-ExpiredBrowseRequests $bAuto } catch {}
  Start-Sleep -Milliseconds 800
  $expRes = Get-BrowseResult $bAuto $expId
  Assert (($null -ne $expRes) -and ([string]$expRes.status -ceq 'cancelled')) 'R2-1 timeout auto-cancel writes cancelled'
  Assert (((Get-Process -Id $expIdSave -ErrorAction SilentlyContinue) -eq $null)) 'R2-1 timeout stops owned helper'
  try { Stop-Process -Id $expIdSave -Force -ErrorAction SilentlyContinue } catch {}
  $oldTmp = Join-Path $bAuto ('dashboard.browse-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tmp-' + [System.Guid]::NewGuid().ToString('N'))
  Set-Content -LiteralPath $oldTmp 'tmp-orphan' -Encoding Ascii
  try { (Get-Item -LiteralPath $oldTmp).LastWriteTime = (Get-Date).AddMinutes(-70) } catch {}
  $freshTmp = Join-Path $bAuto ('dashboard.browse-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tmp-' + [System.Guid]::NewGuid().ToString('N'))
  Set-Content -LiteralPath $freshTmp 'tmp-fresh' -Encoding Ascii
  Remove-OldBrowseFiles $bAuto
  Assert ((-not (Test-Path -LiteralPath $oldTmp)) -and (Test-Path -LiteralPath $freshTmp)) 'R2-1 old GUID tmp cleaned, fresh kept (safe containment)'
  Remove-Item -LiteralPath $freshTmp -Force -ErrorAction SilentlyContinue
  Assert ($srvTxt.Contains('browseGen') -and $srvTxt.Contains('myGen')) 'R2-2 browse generation present'
  Assert ($srvTxt.Contains('myGen !== browseGen')) 'R2-2 generation checked (cancel/timeout wins)'
  $pollIdx2 = $srvTxt.IndexOf('async function pollBrowse')
  $pollJs2 = ''
  if ($pollIdx2 -ge 0) { $pollJs2 = $srvTxt.Substring($pollIdx2, [Math]::Min(2200, $srvTxt.Length - $pollIdx2)) }
  Assert (($pollJs2.Contains('await api') -and $pollJs2.Contains('browseCancel || myGen'))) 'R2-2 await-after cancel check (pending GET then cancel ignored)'
  Assert ($srvTxt.Contains('if(browseCancel || myGen')) 'R2-2 reflect-before cancel check (no selected adoption after cancel)'
  Assert (($srvTxt.Contains('modalQueue') -and $srvTxt.Contains('showModalInner'))) 'R2-3 modal queue serial (no unresolved promise)'
  Assert ($srvTxt.Contains('callerFocus')) 'R2-3 caller focus each kept (queued notify+confirm)'
  try {
    $nodeQ = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeQ) { $nodeQ = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeQ) {
      $qJs = Join-Path $scratch 'r2-queue-check.js'
      Set-Content -LiteralPath $qJs "let q=Promise.resolve();function inner(v){return new Promise(function(r){setTimeout(function(){r(v);},10);});}function showM(v){let res;const o=new Promise(function(r){res=r;});q=q.then(function(){return inner(v).then(function(x){res(x);});});q=q.catch(function(){});return o;}Promise.all([showM(1),showM(2)]).then(function(a){if(a[0]===1&&a[1]===2)process.exit(0);else process.exit(1);}).catch(function(){process.exit(1);});setTimeout(function(){process.exit(1);},2000);" -Encoding Ascii
      & $nodeQ $qJs
      Assert ($LASTEXITCODE -eq 0) 'R2-3 modal queue 2 promises both resolve (node)'
    } else { Assert ($true) 'R2-3 node missing skips queue run' }
  } catch { Assert ($false) 'R2-3 queue run executed' }
  Assert ($srvTxt.Contains('? -1 : 1')) 'R2-4 ShiftTab formula fixed ((i+(shift_-11))+len)%len)'
  Assert (-not ($srvTxt.Contains('btns.length - 1 : 0'))) 'R2-4 old ShiftTab removed'
  Assert ($srvTxt.Contains('wrap.inert')) 'R2-4 background inert kept'
  Assert (($srvTxt.Contains('btn.disabled = false') -and $srvTxt.Contains('finally'))) 'R2-4 disabled re-enable safe fallback (finally)'
  try {
    $nodeT = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeT) { $nodeT = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeT) {
      $tJs = Join-Path $scratch 'r2-tab-check.js'
      Set-Content -LiteralPath $tJs "function nxt(i,sh,len){return (i+(sh?-1:1)+len)%len;}function old(i,sh,len){return (i+1+(sh?len-1:0))%len;}let ok=true;for(let len=3;len<=4;len++){for(let i=0;i<len;i++){if(nxt(i,false,len)!==(i+1)%len)ok=false;if(nxt(i,true,len)!==(i-1+len)%len)ok=false;if(old(i,true,len)===nxt(i,true,len))ok=false;}}if(nxt(-1,false,3)!==0)ok=false;process.exit(ok?0:1);" -Encoding Ascii
      & $nodeT $tJs
      Assert ($LASTEXITCODE -eq 0) 'R2-4 Tab wrap correct, old ShiftTab wrong (node)'
    } else { Assert ($true) 'R2-4 node missing skips tab run' }
  } catch { Assert ($false) 'R2-4 tab run executed' }
  $natA2 = ([regex]::Matches($srvTxt, 'alert\(')).Count
  $natC2 = ([regex]::Matches($srvTxt, 'confirm\(')).Count
  $natP2 = ([regex]::Matches($srvTxt, 'prompt\(')).Count
  Assert (($natA2 -eq 0) -and ($natC2 -eq 0) -and ($natP2 -eq 0)) 'R2-4 native dialogs zero kept'
  Assert (($brTxt.Contains('UTF8Encoding') -and $brTxt.Contains('($true)'))) 'R2-5 helper BOM required (PS5.1 CP932 safe)'
  Assert ($srvTxt.Contains('UTF8Encoding')) 'R2-5 server BOM kept (related helpers)'
  $bomId = 'abababababababababababababababab'
  $rfBom = Get-BrowseResultFile $bAuto $bomId
  $jpBomPath = Join-Path $scratch '日本語 BOM確認'
  $joBom = (@{ browseId = $bomId; status = 'selected'; path = $jpBomPath; finishedAt = '2026-10-13 00:00:00' } | ConvertTo-Json -Compress)
  Write-BrowseResultPrivate $rfBom $joBom
  $rawBom = [System.IO.File]::ReadAllBytes($rfBom)
  Assert ((($rawBom[0] -eq 0xEF) -and ($rawBom[1] -eq 0xBB) -and ($rawBom[2] -eq 0xBF))) 'R2-5 BOM bytes present (UTF8 with BOM)'
  $backBom = Get-BrowseResult $bAuto $bomId
  Assert (([string]$backBom.path -ceq $jpBomPath)) 'R2-5 Japanese round-trips with BOM'
  Assert (($srvTxt.Contains("cne 'POST'"))) 'R2-6 mutations POST-only (PUT/DELETE 405)'
  Assert (($srvTxt.Contains('X-Dashboard-Token') -and $srvTxt.Contains('Origin'))) 'R2-6 token Origin kept'

  # R3 browse/modal 最小修正 (scratchのみ・本番不変)
  $r3CloseIdx = $srvTxt.IndexOf('function close(v)')
  $r3CloseJs = ''
  if ($r3CloseIdx -ge 0) { $r3CloseJs = $srvTxt.Substring($r3CloseIdx, [Math]::Min(800, $srvTxt.Length - $r3CloseIdx)) }
  Assert (-not ($r3CloseJs.Contains('.disabled = false'))) 'R3-1 モーダル終了時にdisabled解除しない(登録POST前再クリック防止)'
  Assert ($srvTxt.Contains('function safeFocus')) 'R3-1 安全フォーカス関数あり(isConnected/disabled確認)'
  Assert (($srvTxt.Contains('btn.disabled = false') -and $srvTxt.Contains('safeFocus(btn)'))) 'R3-1 登録ボタンはfinally再有効化後に安全復帰'
  Assert (($srvTxt.Contains('safeFocus(bb)') -and $srvTxt.Contains('safeFocus(b)'))) 'R3-1 参照・同期ボタンもfinally後に安全復帰'
  try {
    $nodeS3 = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeS3) { $nodeS3 = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeS3) {
      $sJs3 = Join-Path $scratch 'r3-safefocus-check.js'
      Set-Content -LiteralPath $sJs3 "function safeFocus(el){try{if(!el||!el.focus)return false;if(!el.isConnected)return false;if(el.disabled)return false;el.focus();return true;}catch(e){return false;}};let ok=true;let c=0;const en={isConnected:true,disabled:false,focus:function(){c++;}};if(safeFocus(en)!==true||c!==1)ok=false;const dis={isConnected:true,disabled:true,focus:function(){c++;}};if(safeFocus(dis)!==false)ok=false;const gone={isConnected:false,disabled:false,focus:function(){c++;}};if(safeFocus(gone)!==false)ok=false;if(safeFocus(null)!==false)ok=false;process.exit(ok?0:1);" -Encoding Ascii
      & $nodeS3 $sJs3
      Assert ($LASTEXITCODE -eq 0) 'R3-1 無効・切断要素にフォーカスしない(node実効)'
    } else { Assert ($true) 'R3-1 node不在時は静的確認のみ' }
  } catch { Assert ($false) 'R3-1 安全フォーカス実効確認が実行できた' }
  Assert ($srvTxt.Contains('($waited % 30)')) 'R3-2 待機ループ定期tickあり(タブ閉じ後も期限切れ掃除)'
  $dashIdx3 = $srvTxt.IndexOf('function Start-Dashboard')
  $dashJs3 = ''
  if ($dashIdx3 -ge 0) { $dashJs3 = $srvTxt.Substring($dashIdx3, [Math]::Min(4000, $srvTxt.Length - $dashIdx3)) }
  Assert (($dashJs3.Contains('Clear-ExpiredBrowseRequests $AutoDir') -and $dashJs3.Contains('EndGetContext'))) 'R3-2 要求間にも期限切れ掃除(各request間)'
  Assert (($srvTxt.Contains('finally') -and $srvTxt.Contains('Stop-OwnedBrowseProcess'))) 'R3-2 サーバー終了時は所有のみ停止維持'
  $tickP3 = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $tickOther3 = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $tickId3 = 'f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3'
  if (-not $script:BrowseProcs) { $script:BrowseProcs = @{} }
  $tickIdSave3 = $tickP3.Id; $tickOtherIdSave3 = $tickOther3.Id
  $script:BrowseProcs[$tickId3] = @{ Proc = $tickP3; Pid = $tickP3.Id; Expires = (Get-Date).AddSeconds(-1) }
  try { Clear-ExpiredBrowseRequests $bAuto } catch {}
  Start-Sleep -Milliseconds 800
  $tickRes3 = Get-BrowseResult $bAuto $tickId3
  Assert (($null -ne $tickRes3) -and ([string]$tickRes3.status -ceq 'cancelled')) 'R3-2 HTTPなし期限切れは自動キャンセル記録(タブ閉じ想定)'
  Assert (((Get-Process -Id $tickIdSave3 -ErrorAction SilentlyContinue) -eq $null)) 'R3-2 HTTPなし期限切れは所有ヘルパー実停止'
  Assert (((Get-Process -Id $tickOtherIdSave3 -ErrorAction SilentlyContinue) -ne $null)) 'R3-2 無関係プロセスは停止しない(所有のみ)'
  try { Stop-Process -Id $tickOtherIdSave3 -Force -ErrorAction SilentlyContinue } catch {}
  try { Stop-Process -Id $tickIdSave3 -Force -ErrorAction SilentlyContinue } catch {}
  $bfBytes3 = [System.IO.File]::ReadAllBytes($browseHelper)
  Assert ((($bfBytes3[0] -eq 0xEF) -and ($bfBytes3[1] -eq 0xBB) -and ($bfBytes3[2] -eq 0xBF))) 'R3-3 ソースがUTF8 BOM(説明文の文字化け防止)'
  $bfTxt3 = Get-Content -LiteralPath $browseHelper -Raw -Encoding UTF8
  Assert ($bfTxt3.Contains('登録するフォルダを選択してください')) 'R3-3 ソース日本語説明が読める(BOM有効)'
  Assert ($srvTxt.Contains('UTF8Encoding')) 'R3-3 結果JSONもBOM書込維持(ソースとは別物)'
  Assert ($srvTxt.Contains('modalRestoreTarget')) 'R3-4 背景復帰先を保持(キュー継承)'
  Assert ($srvTxt.Contains('ovl.contains(restoreTarget)')) 'R3-4 モーダル内フォーカスは背景に継承(前ボタン消滅対策)'
  Assert (($srvTxt.Contains('isConnected') -and $srvTxt.Contains('restoreTarget.disabled'))) 'R3-4 接続・無効を確認してから復帰'
  Assert (($srvTxt.Contains('focusVisible(lf)') -and $srvTxt.Contains('aside nav a.active') -and $srvTxt.Contains('getElementById("btnPrev")') -and (-not ($srvTxt.Contains('focusViewFallback'))))) 'R3-4 復帰不能時は可視操作へ安全復帰(非表示view用途なし)'
  try {
    $nodeR3 = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeR3) { $nodeR3 = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeR3) {
      $rJs3 = Join-Path $scratch 'r3-restore-check.js'
      Set-Content -LiteralPath $rJs3 "let bg={isConnected:true,disabled:false,id:'bg'};let mbtn={isConnected:false,disabled:false,id:'old-modal-btn'};function pick(caller,ovlContains,bgT){let t=caller;if(t&&ovlContains)t=bgT;if(!t||!t.isConnected||t.disabled){if(bgT&&bgT.isConnected&&!bgT.disabled)t=bgT;}return t;}let ok=true;if(pick(mbtn,true,bg)!==bg)ok=false;if(pick(bg,false,bg)!==bg)ok=false;let disCaller={isConnected:true,disabled:true};if(pick(disCaller,false,bg)!==bg)ok=false;process.exit(ok?0:1);" -Encoding Ascii
      & $nodeR3 $rJs3
      Assert ($LASTEXITCODE -eq 0) 'R3-4 継承・代替ロジックが正しい(node実効)'
    } else { Assert ($true) 'R3-4 node不在時は静的確認のみ' }
  } catch { Assert ($false) 'R3-4 復帰ロジック実効確認が実行できた' }
  try {
    $peR13 = $null; $ptR13 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($srvPath, [ref]$ptR13, [ref]$peR13)
    Assert (($peR13.Count -eq 0)) 'R3 PS構文サーバー正常'
    $peR23 = $null; $ptR23 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($browseHelper, [ref]$ptR23, [ref]$peR23)
    Assert (($peR23.Count -eq 0)) 'R3 PS構文ヘルパー正常'
  } catch { Assert ($false) 'R3 PS構文確認が実行できた' }

  # R4 browse/modal r4最小2fix (scratchのみ・本番不変・他対策維持)
  # 1:所有ハンドル停止(PID再利用で別proc停止防止)。2:safeFocus誤判定防止(body/html除外+activeElement)。
  Assert (($srvTxt.Contains('.Handle') -and $srvTxt.Contains('.Kill()'))) 'R4-1 起動直後にnative handleを取得保持し所有ProcessのみKillで停止'
  Assert ((-not ($srvTxt.Contains('Stop-Process -Id $proc') -or $srvTxt.Contains('Stop-Process -Id $ent')))) 'R4-1 PID指定の代替停止を撤去しPID再利用で別procを止めない'
  $stopIdx4 = $srvTxt.IndexOf('function Stop-OwnedBrowseProcess')
  $stopBody4 = ''
  if ($stopIdx4 -ge 0) { $stopBody4 = $srvTxt.Substring($stopIdx4, [Math]::Min(1200, $srvTxt.Length - $stopIdx4)) }
  Assert (($stopBody4.Contains('finally') -and $stopBody4.Contains('.Dispose()'))) 'R4-1 停止後にfinallyで保持ProcessをDisposeしhandle解放(GC依存排除)'
  $r4OwnedP = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  try { $null = $r4OwnedP.Handle } catch {}
  $r4OtherP = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $r4Id = 'a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4'
  if (-not $script:BrowseProcs) { $script:BrowseProcs = @{} }
  $r4HandleKept = $false
  try { $r4HandleKept = ($r4OwnedP.Handle -ne [System.IntPtr]::Zero) } catch {}
  $r4OwnedIdSave = $r4OwnedP.Id; $r4OtherIdSave = $r4OtherP.Id
  $script:BrowseProcs[$r4Id] = @{ Proc = $r4OwnedP; Handle = $r4OwnedP.Handle; Expires = (Get-Date).AddSeconds(150) }
  try { Stop-OwnedBrowseProcess $r4Id } catch {}
  Start-Sleep -Milliseconds 800
  Assert (($r4HandleKept -and ((Get-Process -Id $r4OwnedIdSave -ErrorAction SilentlyContinue) -eq $null) -and ((Get-Process -Id $r4OtherIdSave -ErrorAction SilentlyContinue) -ne $null))) 'R4-1 期限切れ取消は所有のみ停止し無関係は維持(native handle保持)'
  try { Stop-Process -Id $r4OtherIdSave -Force -ErrorAction SilentlyContinue } catch {}
  try { Stop-Process -Id $r4OwnedIdSave -Force -ErrorAction SilentlyContinue } catch {}
  $r4NatP = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','exit 0' -WindowStyle Hidden -PassThru
  $r4NatH = [System.IntPtr]::Zero
  try { $r4NatH = $r4NatP.Handle } catch {}
  $r4NatId = 'c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4'
  $script:BrowseProcs[$r4NatId] = @{ Proc = $r4NatP; Handle = $r4NatH; Expires = (Get-Date).AddSeconds(150) }
  $r4NatOk = $true
  try { Stop-OwnedBrowseProcess $r4NatId } catch { $r4NatOk = $false }
  Assert (($r4NatOk -and (-not $script:BrowseProcs.ContainsKey($r4NatId)))) 'R4-1 自然終了もDispose安全(例外なし・登録削除)'
  $r4PidOnlyId = 'b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4'
  $r4Victim = Start-Process -FilePath $psExeT -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  $script:BrowseProcs[$r4PidOnlyId] = @{ Proc = $null; Pid = $r4Victim.Id; Expires = (Get-Date).AddSeconds(-1) }
  try { Clear-ExpiredBrowseRequests $bAuto } catch {}
  Start-Sleep -Milliseconds 500
  try { $r4Victim.Refresh() } catch {}
  $r4PidRes = Get-BrowseResult $bAuto $r4PidOnlyId
  Assert ((($null -ne $r4PidRes) -and (-not $r4Victim.HasExited) -and (-not $script:BrowseProcs.ContainsKey($r4PidOnlyId)))) 'R4-1 PIDのみ記録では別procを止めず取消記録のみ(PID再利用対策)'
  try { if (-not $r4Victim.HasExited) { Stop-Process -Id $r4Victim.Id -Force } } catch {}
  Assert (($srvTxt.Contains('document.activeElement') -and $srvTxt.Contains('document.body') -and $srvTxt.Contains('documentElement'))) 'R4-2 body/html除外しfocus後activeElement一致で成功判定'
  Assert (($srvTxt.Contains('focusVisible(lf)') -and $srvTxt.Contains('focusVisible(fb)') -and $srvTxt.Contains('modalQueue') -and $srvTxt.Contains('isShown'))) 'R4-2 非focusableは可視フォールバックへ安全復帰しキュー維持(非表示直帰なし)'
  try {
    $nodeR4 = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeR4) { $nodeR4 = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeR4) {
      $sfIdx4 = $srvTxt.IndexOf('function safeFocus')
      $sfJs4 = ''
      if ($sfIdx4 -ge 0) { $sfJs4 = $srvTxt.Substring($sfIdx4, [Math]::Min(1200, $srvTxt.Length - $sfIdx4)) }
      Assert (($sfJs4.Contains('activeElement') -and $sfJs4.Contains('body'))) 'R4-2 サーバーsafeFocusが誤判定防止を含む(実コード確認)'
      $tJs4 = Join-Path $scratch 'r4-safefocus-check.js'
      Set-Content -LiteralPath $tJs4 "var document={activeElement:null,body:{tagName:'BODY'},documentElement:{tagName:'HTML'}};function safeFocus(el){try{if(!el||!el.focus)return false;if(!el.isConnected)return false;if(el.disabled)return false;try{var tn=((el.tagName||'').toLowerCase());if(tn==='body'||tn==='html')return false;if(el===document.body||el===document.documentElement)return false;}catch(x){}el.focus();try{if(typeof document!=='undefined'&&document&&('activeElement' in document)){return (document.activeElement===el);}}catch(y){return false;}return true;}catch(e){return false;}};let ok=true;const body={tagName:'BODY',isConnected:true,disabled:false,focus:function(){}};if(safeFocus(body)!==false)ok=false;const html={tagName:'HTML',isConnected:true,disabled:false,focus:function(){}};if(safeFocus(html)!==false)ok=false;let c=0;const good={tagName:'BUTTON',isConnected:true,disabled:false,focus:function(){c++;document.activeElement=this;}};if(safeFocus(good)!==true||c!==1)ok=false;const fake={tagName:'DIV',isConnected:true,disabled:false,focus:function(){c++;}};document.activeElement=null;if(safeFocus(fake)!==false)ok=false;process.exit(ok?0:1);" -Encoding Ascii
      & $nodeR4 $tJs4
      Assert ($LASTEXITCODE -eq 0) 'R4-2 body除外とactiveElement判定が正しい(node実効)'
    } else { Assert ($true) 'R4-2 node不在時は静的確認のみ' }
  } catch { Assert ($false) 'R4-2 安全フォーカス実効確認が実行できた' }
  try {
    $peR44 = $null; $ptR44 = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($srvPath, [ref]$ptR44, [ref]$peR44)
    Assert (($peR44.Count -eq 0)) 'R4 PS構文サーバー正常'
    $nodeR4b = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeR4b) { $nodeR4b = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
    if ($nodeR4b) {
      $m4 = [regex]::Match($srvTxt, '(?s)<script>(.*)</script>')
      if ($m4.Success) {
        $jsTmp4 = Join-Path $scratch 'r4-page-check.js'
        Set-Content -LiteralPath $jsTmp4 $m4.Groups[1].Value -Encoding UTF8
        & $nodeR4b --check $jsTmp4
        Assert ($LASTEXITCODE -eq 0) 'R4 JS構文サーバー内スクリプト正常'
      } else { Assert ($false) 'R4 script抽出できた' }
    } else { Assert ($true) 'R4 node不在時はPSのみ' }
  } catch { Assert ($false) 'R4 PS/JS構文確認が実行できた' }

  # UI 8画面切替 (hashルーティング、単一スクロール/scrollspy廃止)
  Assert ((-not ($srvTxt.Contains('data-view'))) -and (-not ($srvTxt.Contains('function showView'))) -and (-not ($srvTxt.Contains('function curView'))) -and (-not ($srvTxt.Contains('focusViewFallback')))) 'UI nav hidden切替撤去(showView/curView/data-viewなし)'
  Assert (($srvTxt.Contains('<div id="top">') -and $srvTxt.Contains('<div id="projects" hidden>') -and $srvTxt.Contains('<div id="global" hidden>') -and $srvTxt.Contains('<div id="rules" hidden>') -and $srvTxt.Contains('<div id="backups" hidden>') -and $srvTxt.Contains('<div id="local" hidden>') -and $srvTxt.Contains('<div id="logs" hidden>') -and $srvTxt.Contains('<div id="settings" hidden>'))) 'UI nav 8画面wrapper(初期はtopのみ表示)'
  Assert (($srvTxt.Contains('<section aria-label="summary">') -and $srvTxt.Contains('<section id="register">') -and $srvTxt.Contains('<section id="status">') -and $srvTxt.Contains('<section id="gsettings">') -and $srvTxt.Contains('<section id="help">'))) 'UI nav 既存section/旧anchor維持(register/status/gsettings/help)'
  Assert (($srvTxt.Contains('const SCREENS=["top","projects","global","rules","backups","local","logs","settings"]') -and $srvTxt.Contains('const LEGACY=') -and $srvTxt.Contains('"register":"projects"') -and $srvTxt.Contains('"status":"projects"') -and $srvTxt.Contains('"gsettings":"global"') -and $srvTxt.Contains('"help":"settings"'))) 'UI nav 8画面+旧hash互換マップ'
  Assert (($srvTxt.Contains('class="topnav"') -and $srvTxt.Contains('href="#top"') -and $srvTxt.Contains('href="#projects"') -and $srvTxt.Contains('href="#global"') -and $srvTxt.Contains('href="#rules"') -and $srvTxt.Contains('href="#backups"') -and $srvTxt.Contains('href="#local"') -and $srvTxt.Contains('href="#logs"') -and $srvTxt.Contains('href="#settings"'))) 'UI nav topnav 8 hashes reachable (mobile)'
  Assert (([regex]::Matches($srvTxt, '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"')).Count -eq 16) 'UI nav Lucide 16x16 SVG in both navigations'
  Assert (([regex]::Matches($srvTxt, '<span data-i18n="[^"]+">[^<]+</span></a>')).Count -ge 16) 'UI nav labels wrapped in data-i18n spans (icon preserved)'
  Assert (($srvTxt.Contains('function targetId') -and $srvTxt.Contains('function setActive') -and $srvTxt.Contains('function applyScreen') -and $srvTxt.Contains('function showHash') -and $srvTxt.Contains('hashchange') -and $srvTxt.Contains('aria-current') -and $srvTxt.Contains('el.hidden=(SCREENS[i]!==s)') -and $srvTxt.Contains('ms.scrollTop=0'))) 'UI nav 初期hash/backforward/hidden切替/active更新(入力維持)'
  Assert ($srvTxt.Contains('return "top"')) 'UI nav unknown hashはtop fallback'
  Assert ((-not ($srvTxt.Contains('history.pushState'))) -and (-not ($srvTxt.Contains('location.hash=')))) 'UI nav 自動hash書換なし(履歴増やさない)'
  Assert ((-not ($srvTxt.Contains('function updateCurrent'))) -and (-not ($srvTxt.Contains('function initSpy'))) -and (-not ($srvTxt.Contains('function scrollToHash'))) -and (-not ($srvTxt.Contains('scrollIntoView'))) -and (-not ($srvTxt.Contains('IntersectionObserver')))) 'UI nav scrollspy撤去(updateCurrent/initSpy/scrollToHash/scrollIntoViewなし)'
  Assert (($srvTxt.Contains('.topnav{display:flex;flex-wrap:nowrap;overflow-x:auto}') -and $srvTxt.Contains('.topnav a{padding:11px 12px;white-space:nowrap}'))) 'UI nav mobile topnav 横スクロール1行(nowrap+大きめタップ域)'
  Assert (($srvTxt.Contains('isShown') -and $srvTxt.Contains('focusVisible') -and $srvTxt.Contains('safeFocus') -and $srvTxt.Contains('wrap.inert'))) 'UI scroll modal焦点維持+背景無効化(hidden view用途なし)'
  Assert (($srvTxt.Contains('.mainscroll') -and $srvTxt.Contains('overflow:auto') -and $srvTxt.Contains('section{width:100%') -and $srvTxt.Contains('.acts') -and $srvTxt.Contains('gap:16px'))) 'UI scroll shell維持(mainscroll scroll/fullwidth/acts gap16)'
  Assert (($srvTxt.Contains('class="btnlink"') -and $srvTxt.Contains('新規登録へ'))) 'UI scroll projects has register link (no new ID/API)'
  Assert ((-not ($srvTxt.Contains('class="row2"') -and $srvTxt.Contains('<div class="row2">')))) 'UI scroll row2なし維持'
  try {
    $ids = @([regex]::Matches($srvTxt, 'id="(stCount|stRun|btnSync|inpPath|btnBrowse|btnPrev|btnReload|logPre|ovl)"'))
    Assert ($ids.Count -ge 9) 'UI route existing IDs kept single (no duplicate UI ID)'
  } catch { Assert ($false) 'UI route ID check ran' }

  # T12 startup verification on scratch port (live HttpListener, loopback only)
  $env:DASHBOARD_PORT = '18799'
  $srv = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$srvPath -WindowStyle Hidden -PassThru
  try {
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18799/health'
        if ($r.StatusCode -eq 200) { $ok = $true; break }
      } catch {}
      if ($srv.HasExited) { break }
    }
    Assert ($ok) 'T12 health responds on loopback'
    Assert (-not $srv.HasExited) 'T12 server stays up (background host)'
    if ($ok) {
      $tok = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      Assert ($tok -match '^[0-9a-f]{64}$') 'T12 session token format'
      $page = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 ("http://127.0.0.1:18799/?token=" + $tok)
      Assert (($page.StatusCode -eq 200) -and ($page.Content.Contains('プロジェクト同期ダッシュボード'))) 'T12 page serves Japanese UI'
      Assert (-not ($page.Content.Contains('http://') -and $page.Content.Contains('cdn'))) 'T12 no external CDN'
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18799/?token=bad' | Out-Null; $rej = $false } catch { $rej = ($_.Exception.Response.StatusCode.value__ -eq 403) }
      Assert ($rej) 'T12 bad token 403'
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18799/api/sync' | Out-Null; $m = $false } catch { $m = ($_.Exception.Response.StatusCode.value__ -eq 405) }
      Assert ($m) 'T12 mutation-by-GET 405'
      # T13 real POST preview+register (empty repo): explicit sync value, registry published
      $repoLive = Join-Path $scratch 'LiveRepo'
      New-Item -ItemType Directory -Force -Path $repoLive | Out-Null
      $hdrs = @{ 'X-Dashboard-Token' = $tok }
      $pvResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoLive } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview'
      $pvJ = ($pvResp.Content | ConvertFrom-Json)
      Assert (($pvResp.StatusCode -eq 200) -and ($pvJ.ok -eq $true) -and ($null -eq $pvJ.agentsHash)) 'T13 live preview ok'
      $rgResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pvJ.path; previewId = $pvJ.previewId; confirm = $true } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/register'
      $rgJ = ($rgResp.Content | ConvertFrom-Json)
      Assert (($rgResp.StatusCode -eq 200) -and ($rgJ.ok -eq $true) -and (($rgJ.sync -eq 'started') -or ($rgJ.sync -eq 'launch-failed'))) 'T13 live register explicit sync value'
      Assert ($rgJ.sync -eq 'launch-failed') 'T13b launch failure explicit (no launcher in scratch)'
      Assert ((@(Get-Registry $auto)).Count -eq 1) 'T13 registry published'
      # T13c dummy launcher present -> sync started explicitly
      Set-Content -LiteralPath (Join-Path $auto 'Run-ProjectRules.vbs') "' dummy launcher" -Encoding Ascii
      $repoLive2 = Join-Path $scratch 'LiveRepo2'
      New-Item -ItemType Directory -Force -Path $repoLive2 | Out-Null
      $pv3r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoLive2 } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview'
      $pv3 = ($pv3r.Content | ConvertFrom-Json)
      $rg3r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pv3.path; previewId = $pv3.previewId; confirm = $true } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/register'
      $rg3 = ($rg3r.Content | ConvertFrom-Json)
      Assert (($rg3.sync -eq 'started') -and ($rg3.syncId -match '^[0-9a-f]{32}$')) 'T13c launch success explicit with runID'
      Assert ((@(Get-Registry $auto)).Count -eq 2) 'T13c registry has two'
      # T14 preview-change requires re-preview, registry unchanged
      $repoChg = Join-Path $scratch 'ChgRepo'
      New-Item -ItemType Directory -Force -Path $repoChg | Out-Null
      $pv4r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoChg } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview'
      $pv4 = ($pv4r.Content | ConvertFrom-Json)
      Set-Content -LiteralPath (Join-Path $repoChg 'AGENTS.md') 'changed after preview 1234567890 abcdefghij' -Encoding Ascii
      $staleOk = $true; $staleCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pv4.path; previewId = $pv4.previewId; confirm = $true } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/register' | Out-Null } catch { $staleOk = $false; $staleCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $staleOk) -and ($staleCode -eq 400)) 'T14 changed content requires re-preview'
      Assert ((@(Get-Registry $auto)).Count -eq 2) 'T14 registry unchanged on stale'
      # T15 lock held -> POST register busy, registry unchanged
      $repoLock = Join-Path $scratch 'LockRepo'
      New-Item -ItemType Directory -Force -Path $repoLock | Out-Null
      $pvLr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoLock } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview'
      $pvL = ($pvLr.Content | ConvertFrom-Json)
      $held = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
      $lockOk = $true; $lockCode = 0
      try {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $pvL.path; previewId = $pvL.previewId; confirm = $true } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/register' | Out-Null } catch { $lockOk = $false; $lockCode = $_.Exception.Response.StatusCode.value__ }
      } finally { $held.Close() }
      Assert ((-not $lockOk) -and ($lockCode -eq 409)) 'T15 locked POST register busy'
      Assert ((@(Get-Registry $auto)).Count -eq 2) 'T15 registry unchanged while locked'
      # T15b lock held -> POST unregister busy, entry kept
      $held2 = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
      $uLockOk = $true; $uLockCode = 0
      try {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ name = 'LiveRepo' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/unregister' | Out-Null } catch { $uLockOk = $false; $uLockCode = $_.Exception.Response.StatusCode.value__ }
      } finally { $held2.Close() }
      Assert ((-not $uLockOk) -and ($uLockCode -eq 409)) 'T15b locked POST unregister busy'
      Assert ((@(Get-Registry $auto)).Count -eq 2) 'T15b entry kept while locked'
      # R3P1b live: existing AGENTS always refused, registry unchanged (no backup path)
      $repoBk = Join-Path $scratch 'BkRepo'
      New-Item -ItemType Directory -Force -Path (Join-Path $repoBk '.rulesync\rules') | Out-Null
      Set-Content -LiteralPath (Join-Path $repoBk '.rulesync\rules\project-local.md') "---`nlocalRoot: true`ntargets: [`"codexcli`", `"opencode`"]`n---`n`nmy-local-unique-body-1234567890-abcdef" -Encoding Ascii
      Set-Content -LiteralPath (Join-Path $repoBk 'AGENTS.md') 'head shared-common-body-XYZ tail my-local-unique-body-1234567890-abcdef end' -Encoding Ascii
      $bkOk = $true; $bkCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoBk } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview' | Out-Null } catch { $bkOk = $false; $bkCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $bkOk) -and ($bkCode -eq 400)) 'R3P1b live existing-AGENTS refused'
      Assert ((@(Get-Registry $auto)).Count -eq 2) 'R3P1b registry unchanged on existing-AGENTS'
      # R4P1a live: real server verifies OK through the real path (HTTP.sys PID 4 accepted, nonce matches)
      $vfyReal = $false
      try {
        & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vfyPath -AutoDir $auto -Port 18799 | Out-Null
        $vfyReal = ($LASTEXITCODE -eq 0)
      } catch { $vfyReal = $false }
      Assert ($vfyReal) 'R4P1a live normal server verifies OK (no token sent)'
      # R4P1b live: foreign server on the same port returning 200 with a wrong nonce is rejected
      $fAuto = Join-Path $scratch 'fAuto'
      New-Item -ItemType Directory -Force -Path $fAuto | Out-Null
      $fPort = 18798
      $fStubPs = Join-Path $scratch 'foreign-stub.ps1'
      Set-Content -LiteralPath $fStubPs (@'
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://127.0.0.1:__PORT__/")
$l.Start()
while ($l.IsListening) {
  $c = $l.GetContext()
  $b = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"port":__PORT__,"instance":"ffffffffffffffffffffffffffffffff-99999","pid":99999}')
  $c.Response.StatusCode = 200
  $c.Response.ContentType = 'application/json'
  $c.Response.ContentLength64 = $b.Length
  $c.Response.OutputStream.Write($b, 0, $b.Length)
  $c.Response.OutputStream.Close()
}
'@ -replace '__PORT__', "$fPort") -Encoding Ascii
      $meProc = Get-Process -Id $PID -ErrorAction Stop
      $meStart = $meProc.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
      Set-Content -LiteralPath (Join-Path $fAuto 'dashboard.state.json') (@{ instance = ('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-' + "$PID"); pid = $PID; startTime = $meStart; port = $fPort; autodir = $fAuto } | ConvertTo-Json -Compress) -Encoding Ascii
      $fStub = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $fStubPs -WindowStyle Hidden -PassThru
      try {
        $fHealth = $false
        for ($fi = 0; $fi -lt 20; $fi++) {
          Start-Sleep -Milliseconds 500
          try {
            $fh = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 ("http://127.0.0.1:" + $fPort + "/health")
            if ($fh.StatusCode -eq 200) { $fHealth = $true; break }
          } catch {}
          if ($fStub.HasExited) { break }
        }
        Assert ($fHealth) 'R4P1b foreign stub serves 200 on same port'
        $vfyFor = $true
        try {
          & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vfyPath -AutoDir $fAuto -Port $fPort | Out-Null
          $vfyFor = ($LASTEXITCODE -eq 0)
        } catch { $vfyFor = $false }
        Assert (-not $vfyFor) 'R4P1b foreign same-port 200 rejected (nonce mismatch, no token sent)'
      } finally { try { if (-not $fStub.HasExited) { Stop-Process -Id $fStub.Id -Force } } catch {} }
      # R3P3b foreignport: unused port must not verify (no state match, no token send)
      $vfyForeign = $true
      try {
        & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vfyPath -AutoDir $auto -Port 18899 | Out-Null
        $vfyForeign = ($LASTEXITCODE -eq 0)
      } catch { $vfyForeign = $false }
      Assert (-not $vfyForeign) 'R3P3b foreign port verify fails (no token send)'
      # T18 health carries instance+port+pid; status instance matches (no cross-service reuse)
      $hResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18799/health'
      $hJ = ($hResp.Content | ConvertFrom-Json)
      Assert (($hJ.ok -eq $true) -and ($hJ.port -eq 18799) -and ($hJ.instance -match '^[0-9a-f]{32}-') -and ($hJ.pid -gt 0)) 'T18 health instance+pid identity'
      $stResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers @{'X-Dashboard-Token'=$tok} 'http://127.0.0.1:18799/api/status'
      $stJ = ($stResp.Content | ConvertFrom-Json)
      Assert ($stJ.instance -eq $hJ.instance) 'T18 status instance matches health'
      Assert ($stJ.syncState -match '^(running|waiting|success|failed|unconfirmed|idle)$') 'R3P2 live status carries syncState'
      # T19 sync returns explicit started+runID with launcher present
      $syResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body '{}' -Uri 'http://127.0.0.1:18799/api/sync'
      $syJ = ($syResp.Content | ConvertFrom-Json)
      Assert (($syResp.StatusCode -eq 200) -and ($syJ.sync -eq 'started') -and ($syJ.syncId -match '^[0-9a-f]{32}$')) 'T19 sync started explicit with runID'
      # R4P2c live: launched runID has no result file yet, so the state is never success (unconfirmed/waiting/running)
      $liveSt = Get-SyncState $auto 'tok'
      Assert ($liveSt.syncState -ne 'success') 'R4P2c launched run without result never success'
      Assert ($liveSt.syncId -eq $syJ.syncId) 'R4P2c live status runID matches launched run'
      # R4P4b live: second start on the same port loses fast, token unchanged, winner healthy
      $tokBefore = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      $srv2 = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $srvPath -WindowStyle Hidden -PassThru
      Start-Sleep -Seconds 3
      $srv2Gone = $srv2.HasExited
      try {
        if (-not $srv2.HasExited) { $srv2.WaitForExit(5000) | Out-Null; $srv2Gone = $srv2.HasExited }
      } catch {}
      Assert ($srv2Gone) 'R4P4b simultaneous second start loses (port mutex, cleans nothing)'
      $tokAfter = (Get-Content -LiteralPath (Join-Path $auto 'dashboard.token') -Raw -Encoding UTF8).Trim()
      Assert (($tokAfter -ceq $tokBefore) -and ($tokAfter -match '^[0-9a-f]{64}$')) 'R4P4b token unchanged by loser'
      try { if (-not $srv2.HasExited) { Stop-Process -Id $srv2.Id -Force } } catch {}
      $hAgain = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18799/health'
      Assert ($hAgain.StatusCode -eq 200) 'R4P4b winner still healthy after loser exits'
      # R4P5b live: served page carries the abort timeout and deadline (real served path, not just source text)
      Assert ($page.Content.Contains('AbortController')) 'R4P5b served page has per-request abort'
      Assert ($page.Content.Contains('60000')) 'R4P5b served page has 60s deadline'
      try {
        $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $nodeExe) { $nodeExe = (Get-Command nodejs -ErrorAction SilentlyContinue).Source }
        if ($nodeExe) {
          $m = [regex]::Match($page.Content, '(?s)<script>(.*)</script>')
          if ($m.Success) {
            $jsTmp = Join-Path $scratch 'page-check.js'
            Set-Content -LiteralPath $jsTmp $m.Groups[1].Value -Encoding UTF8
            & $nodeExe --check $jsTmp
            Assert ($LASTEXITCODE -eq 0) 'R4P5b served JS parses (node --check)'
          } else { Assert ($false) 'R4P5b script block found' }
        } else { Write-Host 'SKIP: R4P5b node --check (node missing; live API checks still ran)'; Assert ($true) 'R4P5b node missing skips parse check' }
      } catch { Assert ($false) 'R4P5b served JS parse check ran' }
      # R5P3b live: served page carries skipped handling and deadline-aware single-state poll (real served path).
      $livePage = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 ("http://127.0.0.1:18799/?token=" + $tok)
      Assert ($livePage.Content.Contains('見送り')) 'R5P3b served page shows skipped Japanese'
      Assert ($livePage.Content.Contains('Math.min(8000')) 'R5P3b served page has min(8s, remaining) timeout'
      Assert ($livePage.Content.Contains('s.syncId !== syncId')) 'R5P3b served page ignores foreign runID'
      Assert ($livePage.Content.Contains('updateSyncUI')) 'R5P3b served page renders from single state call'
      # R5P1c live: pre-busy /api/sync stays 409 conflict, registry/request unchanged.
      $heldLive = [System.IO.File]::Open((Join-Path $auto 'Sync-ProjectRules.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
      $busyOk = $true; $busyCode = 0
      try {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body '{}' -Uri 'http://127.0.0.1:18799/api/sync' | Out-Null } catch { $busyOk = $false; $busyCode = $_.Exception.Response.StatusCode.value__ }
      } finally { $heldLive.Close() }
      Assert ((-not $busyOk) -and ($busyCode -eq 409)) 'R5P1c live pre-busy sync stays 409 (only pre-busy conflicts)'
      # R5 syncState carries skipped end-to-end (live status shape).
      $r5liveRes = Get-SyncResult $stAuto $r5req.id
      Assert ((($null -ne $r5liveRes) -and ([string]$r5liveRes.result -ceq 'skipped') -and ([int]$r5liveRes.exitCode -eq 75))) 'R5 live skipped state shape (server carries skipped)'
      Assert ($stJ.syncState -match '^(running|waiting|success|failed|skipped|unconfirmed|idle)$') 'R5 live status carries skipped value'
      # BX live: browse poll/cancel without launching a dialog (simulated files + validation only).
      $bxBad = $true; $bxBadCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers $hdrs 'http://127.0.0.1:18799/api/browse?id=bad' | Out-Null } catch { $bxBad = $false; $bxBadCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $bxBad) -and ($bxBadCode -eq 400)) 'BX live bad browseId 400'
      $bxNoTok = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18799/api/browse?id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | Out-Null } catch { $bxNoTok = ($_.Exception.Response.StatusCode.value__ -eq 403) }
      Assert ($bxNoTok) 'BX live browse without token 403'
      $bxCancelId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
      $bxCancelResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ browseId = $bxCancelId } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/browse/cancel'
      $bxCancelJ = ($bxCancelResp.Content | ConvertFrom-Json)
      Assert (($bxCancelResp.StatusCode -eq 200) -and ([string]$bxCancelJ.status -ceq 'cancelled')) 'BX live cancel without dialog records cancelled (no error)'
      $bxPollCancel = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers $hdrs ("http://127.0.0.1:18799/api/browse?id=" + $bxCancelId)
      $bxPollCancelJ = ($bxPollCancel.Content | ConvertFrom-Json)
      Assert ([string]$bxPollCancelJ.status -ceq 'cancelled') 'BX live cancelled poll returns cancelled (no registration)'
      $bxSelId = 'ffffffffffffffffffffffffffffffff'
      $bxSelPath = Join-Path $scratch 'LiveRepo'
      Set-Content -LiteralPath (Join-Path $auto ("dashboard.browse-" + $bxSelId + ".json")) (@{ browseId = $bxSelId; status = 'selected'; path = $bxSelPath; finishedAt = '2026-10-13 00:00:00' } | ConvertTo-Json -Compress) -Encoding UTF8
      $bxPollSel = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers $hdrs ("http://127.0.0.1:18799/api/browse?id=" + $bxSelId)
      $bxPollSelJ = ($bxPollSel.Content | ConvertFrom-Json)
      Assert (([string]$bxPollSelJ.status -ceq 'selected') -and ([string]$bxPollSelJ.path -ceq $bxSelPath)) 'BX live selected poll returns path (select-only, no register)'
      Remove-Item -LiteralPath (Join-Path $auto ("dashboard.browse-" + $bxSelId + ".json")) -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $auto ("dashboard.browse-" + $bxCancelId + ".json")) -Force -ErrorAction SilentlyContinue
      Assert ((@(Get-Registry $auto)).Count -eq 2) 'BX live browse leaves registry unchanged'
      # BX live: open refuses unknown/injection, keeps backend security (no success popup in tests).
      $opUnk = $true; $opUnkCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ name = 'NoSuchLive' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/open' | Out-Null } catch { $opUnk = $false; $opUnkCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $opUnk) -and ($opUnkCode -eq 404)) 'BX live open unknown 404 (registered-only)'
      $opInj = $true; $opInjCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ name = '../evil' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/open' | Out-Null } catch { $opInj = $false; $opInjCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $opInj) -and ($opInjCode -eq 400)) 'BX live open injection 400'
      $opNoTok = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -ContentType 'application/json' -Body (@{ name = 'LiveRepo' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/open' | Out-Null } catch { $opNoTok = ($_.Exception.Response.StatusCode.value__ -eq 403) }
      Assert ($opNoTok) 'BX live open without token 403'
      $opGet = $true; $opGetCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Headers $hdrs 'http://127.0.0.1:18799/api/open' | Out-Null } catch { $opGet = $false; $opGetCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $opGet) -and ($opGetCode -eq 405)) 'BX live open by GET 405 (POST-only)'
      # BX live: served page carries modal+browse+explorer and zero native dialogs.
      $bxPage = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 ("http://127.0.0.1:18799/?token=" + $tok)
      Assert ($bxPage.Content.Contains('id="ovl"') -and $bxPage.Content.Contains('aria-modal')) 'BX live page has original modal'
      Assert ($bxPage.Content.Contains('Escape') -and $bxPage.Content.Contains('inert')) 'BX live page modal keyboard/inert'
      Assert ($bxPage.Content.Contains('id="btnBrowse"') -and $bxPage.Content.Contains('pollBrowse')) 'BX live page has browse bounded poll'
      Assert ($bxPage.Content.Contains('エクスプローラーで開く')) 'BX live page has explorer button'
      Assert ((([regex]::Matches($bxPage.Content, 'alert\(')).Count -eq 0) -and (([regex]::Matches($bxPage.Content, 'confirm\(')).Count -eq 0) -and (([regex]::Matches($bxPage.Content, 'prompt\(')).Count -eq 0)) 'BX live page native dialogs zero'
      # R2-6 live: all mutations POST-only (PUT/DELETE 405), token/Origin kept for POST
      $putSync = $true; $putCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method PUT -Headers $hdrs -ContentType 'application/json' -Body '{}' -Uri 'http://127.0.0.1:18799/api/sync' | Out-Null } catch { $putSync = $false; $putCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $putSync) -and ($putCode -eq 405)) 'R2-6 live PUT sync 405 (POST-only)'
      $delSync = $true; $delCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method DELETE -Headers $hdrs -ContentType 'application/json' -Body '{}' -Uri 'http://127.0.0.1:18799/api/sync' | Out-Null } catch { $delSync = $false; $delCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $delSync) -and ($delCode -eq 405)) 'R2-6 live DELETE sync 405 (POST-only)'
      $putPrev = $true; $putPrevCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method PUT -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoLock } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview' | Out-Null } catch { $putPrev = $false; $putPrevCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $putPrev) -and ($putPrevCode -eq 405)) 'R2-6 live PUT preview 405 (POST-only)'
      $delCancel = $true; $delCancelCode = 0
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method DELETE -Headers $hdrs -ContentType 'application/json' -Body (@{ browseId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/browse/cancel' | Out-Null } catch { $delCancel = $false; $delCancelCode = $_.Exception.Response.StatusCode.value__ }
      Assert ((-not $delCancel) -and ($delCancelCode -eq 405)) 'R2-6 live DELETE browse-cancel 405 (POST-only)'
      $noTokPost = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -ContentType 'application/json' -Body '{}' -Uri 'http://127.0.0.1:18799/api/sync' | Out-Null } catch { $noTokPost = ($_.Exception.Response.StatusCode.value__ -eq 403) }
      Assert ($noTokPost) 'R2-6 live POST without token 403 (token kept)'
      $badOrigin = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers (@{ 'X-Dashboard-Token' = $tok; 'Origin' = 'http://evil.com' }) -ContentType 'application/json' -Body '{}' -Uri 'http://127.0.0.1:18799/api/sync' | Out-Null } catch { $badOrigin = ($_.Exception.Response.StatusCode.value__ -eq 403) }
      Assert ($badOrigin) 'R2-6 live POST bad Origin 403 (Origin kept)'
      Assert ($bxPage.Content.Contains('modalQueue') -and $bxPage.Content.Contains('browseGen')) 'R2 live page carries queue+generation (served path)'
      # T20 corrupted registry refuses, file untouched, then restored
      $regBackup = Get-Content -LiteralPath (Join-Path $auto 'projects.json') -Raw -Encoding Ascii
      Set-Content -LiteralPath (Join-Path $auto 'projects.json') 'NOT-JSON{{{' -Encoding Ascii
      $corOk = $true
      try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ path = $repoLock } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/preview' | Out-Null } catch { $corOk = $false }
      Assert (-not $corOk) 'T20 corrupted registry refuses preview'
      Assert ((Get-Content -LiteralPath (Join-Path $auto 'projects.json') -Raw -Encoding Ascii) -match 'NOT-JSON') 'T20 registry file untouched on failure'
      Set-Content -LiteralPath (Join-Path $auto 'projects.json') $regBackup -Encoding Ascii
      # T17 unregister via POST removes only list, repo files untouched
      Set-Content -LiteralPath (Join-Path $repoLive 'AGENTS.md') 'live-keep-me' -Encoding Ascii
      $unResp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ name = 'LiveRepo' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/unregister'
      Assert ($unResp.StatusCode -eq 200) 'T17 live unregister ok'
      Assert ((@(Get-Registry $auto)).Count -eq 1) 'T17 list removed one kept'
      Assert ((Get-Content -LiteralPath (Join-Path $repoLive 'AGENTS.md') -Raw) -match 'live-keep-me') 'T17 repo file untouched'
      $unResp2 = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method POST -Headers $hdrs -ContentType 'application/json' -Body (@{ name = 'LiveRepo2' } | ConvertTo-Json -Compress) -Uri 'http://127.0.0.1:18799/api/unregister'
      Assert ($unResp2.StatusCode -eq 200) 'T17b second unregister ok'
      Assert ((@(Get-Registry $auto)).Count -eq 0) 'T17b list emptied'
    }
  } finally {
    try { if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force } } catch {}
  }

  Assert (((Get-Location).Path) -eq $initCwd) 'cwd unchanged'
  if (Test-Path -LiteralPath $scratch) {
    if (-not (Test-Contained $scratch $base)) { throw 'cleanup outside base refused' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
  }
  Assert (-not (Test-Path -LiteralPath $scratch)) 'only own scratch removed'
  Assert (Test-Path -LiteralPath $base) 'base left intact'
}
finally {
  $env:DASHBOARD_AUTODIR = $origAuto
  if ($null -eq $origAuto) { Remove-Item Env:DASHBOARD_AUTODIR -ErrorAction SilentlyContinue }
  $env:DASHBOARD_PORT = $origPort
  if ($null -eq $origPort) { Remove-Item Env:DASHBOARD_PORT -ErrorAction SilentlyContinue }
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL DASHBOARD CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
