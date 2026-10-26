# Sync-ProjectRules.ps1 - Auto-sync project rules via Shirube standard commands only.
# Reads shared project rules (project-common-preview cwd) plus each repo's local
# rule file, and writes the registered repos' AGENTS.md files.
# Run hidden from Task Scheduler (at logon + every 15 min). No MCP/model APIs.
# Generated AGENTS.md files are overwritten by design; do not edit them by hand.
# Failures exit non-zero for retry.
# r5: optional -ReportSkip only. Busy lock returns 75 when present (dashboard
# distinguishes skipped vs success); default 0 preserves periodic skip behavior.
param([switch]$DryRun, [switch]$ReportSkip, [string[]]$ProjectNames = @(), [switch]$PreviewOnly, [string]$PlanPath = "", [string]$RequestPath = "")

# 個人設定 (settings.json) は Settings.ps1 経由。Settings.ps1 が無い単体コピー
# (scratch 配備) でも既定値で動くよう、その場合だけ既定値スタブを置く。
$shirubeSettingsScript = Join-Path $PSScriptRoot 'Settings.ps1'
if (Test-Path -LiteralPath $shirubeSettingsScript -PathType Leaf) { . $shirubeSettingsScript }
# GitHub integration (optional: single-file copies keep the gh fallback below).
$ghMgmtScript = Join-Path $PSScriptRoot 'GitHub-Management.ps1'
if (Test-Path -LiteralPath $ghMgmtScript -PathType Leaf) { . $ghMgmtScript }
if (-not (Get-Command Get-ShirubeSetting -ErrorAction SilentlyContinue)) { function Get-ShirubeSetting { param([string]$Name = '', $Default = $null) return $Default } }

function Invoke-ProjectSync {
  param([switch]$DryRun, [switch]$ReportSkip, [string[]]$ProjectNames = @(), [switch]$PreviewOnly, [string]$PlanPath = "", [string]$RequestPath = "")

  $ErrorActionPreference = 'Stop'
  $Targets = 'codexcli,opencode'
  $Pkg = 'rulesync@' + (Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0')

  $AutoDir = $PSScriptRoot
  $PreviewDir = Join-Path (Split-Path $AutoDir -Parent) 'project-common-preview'
  $PreviewConfig = Join-Path $PreviewDir 'rulesync.jsonc'
  $CommonRoot = Join-Path $PreviewDir '.rulesync'
  $CuratedCommon = Join-Path $CommonRoot 'rules\.curated\project.md'
  $ProjectsFile = Join-Path $AutoDir 'projects.json'
  $LogDir = Join-Path $AutoDir 'logs'
  $BackupRoot = Join-Path $AutoDir 'backups'
  $LockPath = Join-Path $AutoDir 'Sync-ProjectRules.lock'

  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $LogFile = Join-Path $LogDir ("Sync-ProjectRules-" + (Get-Date -Format 'yyyyMMdd') + ".log")
  $Secrets = @()
  function Write-Log([string]$Message) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
  }
  function Redact([string]$Text) {
    $r = $Text
    foreach ($v in $Secrets) { if ($v) { $r = $r.Replace($v, '***') } }
    return $r
  }
  # Bounded redacted tail for failure messages: surfaces the real CLI cause
  # without dumping full output, secrets, or authorized file bodies.
  function Get-RedactedTail([string]$Text) {
    $r = Redact $Text
    if ([string]::IsNullOrEmpty($r)) { return '' }
    $max = 800
    if ($r.Length -gt $max) { return $r.Substring($r.Length - $max) }
    return $r
  }
  function Resolve-Exe([string]$Primary, [string]$Fallback) {
    $c = Get-Command $Primary -ErrorAction SilentlyContinue
    if ((-not $c) -and $Fallback) { $c = Get-Command $Fallback -ErrorAction SilentlyContinue }
    if (-not $c) { throw ("Required command not found: " + $Primary) }
    return $c.Source
  }
  function Invoke-Step([string]$Desc, [string]$Exe, [string[]]$Argv) {
    Write-Log ("STEP: " + $Desc)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $out = & $Exe @Argv 2>&1 | ForEach-Object { [string]$_ } | Out-String
      $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    if ($null -eq $code) { $code = 1 }
    Write-Log (Redact("EXIT=" + $code + ' ' + $Desc + "`n" + $out))
    $script:LastStepTail = Get-RedactedTail $out
    return $code
  }
  function Get-NormPath([string]$P) {
    return [System.IO.Path]::GetFullPath(($P -replace '/', '\'))
  }
  function Test-Contained([string]$Candidate, [string]$Root) {
    $c = Get-NormPath $Candidate
    $r = Get-NormPath $Root
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
    return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
  }
  # PS5.1-compatible fully-qualified check (IsPathFullyQualified is .NET Core only).
  # IsPathRooted('C:repo') is true but drive-relative, so require drive:\ or UNC.
  function Test-FullyQualified([string]$P) {
    return ($P -match '^[A-Za-z]:\\') -or ($P -match '^\\\\')
  }
  # Single-basename registry names only: no separators, traversal, or drive syntax.
  function Test-SafeName([string]$N) {
    return ($N -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
  }
  function Test-Reparse([string]$P) {
    $it = Get-Item -LiteralPath $P -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $false }
    return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  }
  # Strict frontmatter gate, not a YAML parser: fixed known frontmatter only.
  # Rejects indented keys (e.g. under "description: |" block scalars),
  # block scalars ("|" / ">"), duplicate or non-true values, and mixed
  # root/localRoot. Allowlist of known single-line keys only: quoted keys,
  # unknown keys, aliases, and flow/block styles outside the fixed format
  # are refused. CLI stays authoritative; ambiguous input is refused.
  # PS5.1-compatible, no new deps.
  function Test-FrontmatterFlag([string]$Text, [string]$Key) {
    $norm = $Text -replace "`r`n", "`n"
    $norm = $norm -replace "`r", "`n"
    if ($norm -notmatch '\A---[ \t]*\n') { return $false }
    $m = [regex]::Match($norm, '\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\Z)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return $false }
    $lines = ($m.Groups[1].Value -split "`n")
    $hits = 0
    $seenTargets = 0
    $seenDesc = 0
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
    if ($Key -eq 'localRoot') {
      foreach ($ln in $lines) { if ($ln -cmatch '^root\s*:') { return $false } }
    }
    if ($Key -eq 'root') {
      foreach ($ln in $lines) { if ($ln -cmatch '^localRoot\s*:') { return $false } }
    }
    return $true
  }

  function Test-PrivateJsonAcl([string]$Path) {
    try {
      $acl = Get-Acl -LiteralPath $Path
      return [bool]$acl.AreAccessRulesProtected
    } catch { return $false }
  }
  function Repair-PrivateJsonAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { try { [void]$acl.RemoveAccessRule($r) } catch {} }
    foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
      $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
  }
  function Write-PrivateJson([string]$Path, $Value) {
    if (-not (Test-Contained $Path $AutoDir)) { throw 'private output escaped automation root.' }
    if (Test-Reparse $Path) { throw 'private output is a reparse point.' }
    $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    $sec = New-Object System.Security.AccessControl.FileSecurity
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
      $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Value -Depth 12))
    $fs = [System.IO.File]::Create($tmp, 4096, [System.IO.FileOptions]::None, $sec)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    try {
      # PS5.1/.NET FW rejects a null backup path, so use a sibling backup and
      # delete it on success. Replace keeps the destination ACL; a loose
      # pre-existing file is repaired without resetting the owner.
      if (Test-Path -LiteralPath $Path) {
        $bak = $Path + '.bak-' + [guid]::NewGuid().ToString('N')
        [System.IO.File]::Replace($tmp, $Path, $bak)
        try { Remove-Item -LiteralPath $bak -Force } catch {}
        if (-not (Test-PrivateJsonAcl $Path)) { Repair-PrivateJsonAcl $Path }
      }
      else { [System.IO.File]::Move($tmp, $Path) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
  }
  function Write-PrivateBytes([string]$Path, [byte[]]$Bytes) {
    if (-not (Test-Contained $Path $script:BackupRoot)) { throw 'private backup output escaped backup root.' }
    if (Test-Reparse $Path) { throw 'private backup output is a reparse point.' }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'private backup directory missing.' }
    $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    $sec = New-Object System.Security.AccessControl.FileSecurity
    $sec.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
      $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    }
    $fs = [System.IO.File]::Create($tmp, 4096, [System.IO.FileOptions]::None, $sec)
    try { if ($Bytes -and $Bytes.Length -gt 0) { $fs.Write($Bytes, 0, $Bytes.Length) } } finally { $fs.Dispose() }
    try {
      if (Test-Path -LiteralPath $Path) {
        $bak = $Path + '.bak-' + [guid]::NewGuid().ToString('N')
        [System.IO.File]::Replace($tmp, $Path, $bak)
        try { Remove-Item -LiteralPath $bak -Force } catch {}
      } else { [System.IO.File]::Move($tmp, $Path) }
      if (-not (Test-PrivateJsonAcl $Path)) { Repair-PrivateJsonAcl $Path }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
  }
  function Get-FileHashValue([string]$Path) {
    try {
      if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
      $bytes = [System.IO.File]::ReadAllBytes($Path)
      $h = [System.Security.Cryptography.SHA256]::Create()
      try { return ((($h.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')) }
      finally { $h.Dispose() }
    } catch { return $null }
  }
  function Save-ProjectResult([string]$Name, [string]$Result, [string]$Message, [string]$BackupId = '') {
    if ($PreviewOnly -or $DryRun -or (-not (Test-SafeName $Name))) { return }
    $at = [DateTime]::UtcNow.ToString('o')
    $previous = $script:ProjectStatus[$Name]
    $lastSuccess = $null
    if ($previous) { $lastSuccess = $previous.lastSuccessAt }
    if ($Result -eq 'success') { $lastSuccess = $at }
    $row = @{name=$Name; lastAttemptAt=$at; lastSuccessAt=$lastSuccess; result=$Result; commonSha=$script:CommonSha; commonCommit=$script:CommonCommit; error=(Redact $Message); backupId=$BackupId}
    $script:ProjectStatus[$Name] = $row
    Write-PrivateJson (Join-Path $AutoDir 'project-status.json') @{schemaVersion=1; projects=$script:ProjectStatus}
    $history = Join-Path $AutoDir ('project-history-' + $Name + '.json')
    $old = @()
    if (Test-Path -LiteralPath $history) {
      if (Test-Reparse $history) { throw 'history is a reparse point.' }
      $old = @(Get-Content -LiteralPath $history -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    # A bounded ledger keeps the dashboard fast; actual backups remain untouched.
    $rows = @($old + @($row))
    if ($rows.Count -gt 200) { $rows = @($rows | Select-Object -Last 200) }
    Write-PrivateJson $history $rows
  }
  function New-OwnedSnapshot {
    $root = Join-Path $AutoDir 'snapshots'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    if (Test-Reparse $root) { throw 'snapshot root is a reparse point.' }
    $dir = Join-Path $root ('ProjectSyncSnap-' + [guid]::NewGuid().ToString('N'))
    if (-not (Test-Contained $dir $root)) { throw 'snapshot escaped snapshot root.' }
    if (Test-Path -LiteralPath $dir) { throw 'snapshot exists, refusing reuse.' }
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
  }
  # Live input snapshot mirroring Get-MgmtPlanLive (server side): same fields,
  # same hashes, so plan-bound applies compare identical values.
  # Rereads the actual registry/common/config live on every call: missing or
  # corrupt sources fail closed (throw), never silently empty or cached.
  function Build-PlanLiveInputs {
    $regPath = Join-Path $AutoDir 'projects.json'
    if ((-not (Test-Path -LiteralPath $regPath -PathType Leaf)) -or (Test-Reparse $regPath)) { throw 'registry missing.' }
    # NOTE: never wrap ConvertFrom-Json in @() (it nests arrays); same
    # shape guard as the initial registry read below.
    $liveReg = $null
    try { $liveReg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'registry unreadable.' }
    if ($liveReg -isnot [array]) { $liveReg = @($liveReg) }
    # Mirror Get-MgmtPlanLive (server side): all registry entries, same fields.
    # Callers filter by selected names; unselected drift never fails them,
    # while the preview name-set comparison still sees added/removed rows.
    $curFile = Join-Path $CommonRoot 'rules\.curated\project.md'
    if ((-not (Test-Path -LiteralPath $curFile -PathType Leaf)) -or (Test-Reparse $curFile)) { throw 'shared rule cache missing.' }
    $ctLive = ''
    try { $ctLive = [System.IO.File]::ReadAllText($curFile, [System.Text.Encoding]::UTF8) } catch { throw 'shared rule unreadable.' }
    if ([string]::IsNullOrWhiteSpace($ctLive)) { throw 'shared rule unreadable.' }
    $shaLive = ''
    try { $shaLive = Get-FileHashValue $curFile } catch { throw 'shared rule hash failed.' }
    if (-not $shaLive) { throw 'shared rule hash failed.' }
    $cfgH = ''
    try { $cfgH = Get-FileHashValue $PreviewConfig } catch { throw 'config unreadable.' }
    if (-not $cfgH) { throw 'config unreadable.' }
    $ents = @()
    foreach ($e in @($liveReg)) {
      $nm = [string]$e.name
      $rp = ''
      try { $rp = Get-NormPath ([string]$e.path) } catch { $rp = [string]$e.path }
      $en = $true
      try { if ($e.PSObject.Properties['enabled'] -and ($e.enabled -is [bool])) { $en = [bool]$e.enabled } } catch {}
      $lf2 = Join-Path $rp '.rulesync\rules\project-local.md'
      $af2 = Join-Path $rp 'AGENTS.md'
      $lh2 = $null; $ah2 = $null; $le2 = $false; $ae2 = $false
      try { if ((Test-Path -LiteralPath $lf2 -PathType Leaf) -and (-not (Test-Reparse $lf2))) { $le2 = $true; $lh2 = Get-FileHashValue $lf2 } } catch {}
      try { if ((Test-Path -LiteralPath $af2 -PathType Leaf) -and (-not (Test-Reparse $af2))) { $ae2 = $true; $ah2 = Get-FileHashValue $af2 } } catch {}
      $ents += @{ name = $nm; path = $rp; enabled = $en; localExists = $le2; localHash = $lh2; agentsExists = $ae2; agentsHash = $ah2 }
    }
    return @{ commonSha = $shaLive; commonText = $ctLive; configHash = $cfgH; targets = [string]$Targets; entries = $ents }
  }

  function Invoke-OneProject($Entry) {
    $Name = '?'
    $snap = $null
    $snapCreated = $false
    $cliPushed = $false
    $backupId = ''
    # Dedicated snapshot root under AutoDir, not shared TEMP.
    # Basis: execution side inherits %LOCALAPPDATA% ACL (sandbox RX only,
    # user/SYSTEM/Admins full); TEMP grants sandbox Modify so it is avoided.
    # Snapshots stay per-run GUID dirs; cleanup deletes only own ($snapCreated).
    $SnapRoot = Join-Path $script:AutoDir 'snapshots'
    try {
      $Name = [string]$Entry.name
      $RepoPath = [string]$Entry.path
      if ((-not $Name) -or (-not $RepoPath)) { throw 'registry entry needs name+path.' }
      if (-not (Test-SafeName $Name)) { throw ("unsafe registry name: " + $Name) }
      if ($Entry.PSObject.Properties['enabled'] -and ($Entry.enabled -isnot [bool])) { throw 'enabled must be boolean.' }
      if ($Entry.PSObject.Properties['enabled'] -and (-not $Entry.enabled)) {
        if ($PreviewOnly) { $script:Plans.Add(@{name=$Name; path=$RepoPath; result='skipped'; error='disabled'}) }
        Save-ProjectResult $Name 'skipped' 'disabled'
        Write-Log ($Name + ': SKIP disabled.'); return 0
      }
      # Plan-bound apply: this project must carry an approved successful output.
      $approvedOut = $null
      if ($script:ApprovedPlanId -ne '') {
        $apj = @()
        try { $apj = @($script:ApprovedPlan.projects | Where-Object { [string]$_.name -ceq $Name }) } catch {}
        if (($apj.Count -ne 1) -or ([string]$apj[0].result -cne 'success') -or ([string]$apj[0].generatedText -eq '')) {
          throw ($Name + ': no approved plan output; rebuild it from preview.')
        }
        $approvedOut = [string]$apj[0].generatedText
      }
      if (-not (Test-FullyQualified $RepoPath)) { throw ("not fully-qualified absolute path: " + $Name) }
      $RepoFull = Get-NormPath $RepoPath
      if (-not (Test-Path -LiteralPath $RepoFull -PathType Container)) { throw ("repo dir missing: " + $Name) }
      if (Test-Reparse $RepoFull) { throw ("refusing reparse point: " + $Name) }
      $AgentsPath = Join-Path $RepoFull 'AGENTS.md'
      $AgentsFull = Get-NormPath $AgentsPath
      if (Test-Reparse $AgentsPath) { throw ('refusing reparse AGENTS: ' + $Name) }

      # Snapshot only the single local rule file; never read repo configs or cwd.
      $Roots = @((Get-NormPath $script:CommonRoot))
      $LocalFile = Join-Path $RepoFull '.rulesync\rules\project-local.md'
      # The snapshot copy decides the backup source: a local rule that appears
      # later (dashboard import or save) must never be read from a missing path.
      $snapLocal = ''
      if (Test-Path -LiteralPath $LocalFile) {
        if ((Get-Item -LiteralPath $LocalFile -Force).PSIsContainer) { throw ("local rule is a directory: " + $Name) }
        if (Test-Reparse $LocalFile) { throw ("refusing reparse local rule: " + $Name) }
        $pd = Get-NormPath (Split-Path $LocalFile -Parent)
        $guard = 0
        while (($pd -ne $RepoFull) -and (Test-Contained $pd $RepoFull) -and ($guard -lt 16)) {
          if (Test-Reparse $pd) { throw ("refusing reparse parent: " + $Name) }
          $pd = Get-NormPath (Split-Path $pd -Parent)
          $guard++
        }
        $lt = Get-Content -LiteralPath $LocalFile -Raw -Encoding UTF8
        if (-not (Test-FrontmatterFlag $lt 'localRoot')) { throw ("local rule lost localRoot:true: " + $Name) }
        New-Item -ItemType Directory -Force -Path $SnapRoot | Out-Null
        if (Test-Reparse $SnapRoot) { throw 'snapshot root is a reparse point.' }
        $snap = Join-Path $SnapRoot ("ProjectSyncSnap-" + [System.Guid]::NewGuid().ToString('N'))
        if (-not (Test-Contained $snap $SnapRoot)) { throw 'snapshot escaped snapshot root.' }
        if (Test-Path -LiteralPath $snap) { throw 'snapshot exists, refusing reuse.' }
        New-Item -ItemType Directory -Force -Path (Join-Path $snap 'rules') | Out-Null
        if (Test-Reparse $snap) { throw 'snapshot is a reparse point.' }
        $snapCreated = $true
        Copy-Item -LiteralPath $LocalFile -Destination (Join-Path $snap 'rules\project-local.md') -Force
        $snapLocal = Join-Path $snap 'rules\project-local.md'
        $Roots += (Get-NormPath $snap)
      }

      $BaseArgs = @()
      $previewArgs = @()
      # Immutable staged inputs (preview + plan-bound apply only): verify the
      # live common/config/local bytes against the pinned hashes, then let
      # the CLI consume the staged private copies exclusively. A concurrent
      # A->B->A swap of the live files can never be consumed under the pin.
      # Scheduled runs keep live consumption (behavior preserved).
      $UseRoots = $Roots
      $UseConfig = Get-NormPath $script:PreviewConfig
      $usedCommonH = ''; $usedConfigH = ''; $usedLocalH = $null
      $stagePin = $null
      if ($PreviewOnly -and ($null -ne $previewBase)) {
        $pe0 = @($previewBase.entries | Where-Object { [string]$_.name -ceq $Name })
        if ($pe0.Count -ne 1) { throw ($Name + ': preview inputs changed; retry.') }
        $stagePin = @{ commonSha = [string]$previewBase.commonSha; configHash = [string]$previewBase.configHash; localHash = [string]$pe0[0].localHash; localExists = [bool]$pe0[0].localExists }
      }
      elseif (($script:ApprovedPlanId -ne '') -and ($null -ne $script:ApprovedPlan)) {
        $pe1 = @()
        try { $pe1 = @((Get-MgmtField (Get-MgmtField $script:ApprovedPlan 'inputs') 'entries') | Where-Object { [string](Get-MgmtField $_ 'name') -ceq $Name }) } catch {}
        if ($pe1.Count -ne 1) { throw ($Name + ': plan inputs changed, refusing write: approved entry missing.') }
        $stagePin = @{ commonSha = [string](Get-MgmtField $script:ApprovedPlan 'commonSha'); configHash = [string](Get-MgmtField $script:ApprovedPlan 'configHash'); localHash = [string](Get-MgmtField $pe1[0] 'localHash'); localExists = [bool](Get-MgmtField $pe1[0] 'localExists') }
      }
      if ($null -ne $stagePin) {
        if (-not $snapCreated) { $snap = New-OwnedSnapshot; $snapCreated = $true }
        $staged = Join-Path $snap 'staged'
        $stagedRules = Join-Path $staged 'rules'
        $stagedCommon = Join-Path $staged 'common\.rulesync'
        New-Item -ItemType Directory -Force -Path $stagedRules, (Join-Path $stagedCommon 'rules\.curated') | Out-Null
        $sh = [System.Security.Cryptography.SHA256]::Create()
        try {
          $cbBytes = [System.IO.File]::ReadAllBytes((Join-Path $script:CommonRoot 'rules\.curated\project.md'))
          $usedCommonH = (($sh.ComputeHash($cbBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
          if ($usedCommonH -cne [string]$stagePin.commonSha) { throw ($Name + ': shared rule changed; retry.') }
          [System.IO.File]::WriteAllBytes((Join-Path $stagedCommon 'rules\.curated\project.md'), $cbBytes)
          $cfgBytes = [System.IO.File]::ReadAllBytes($script:PreviewConfig)
          $usedConfigH = (($sh.ComputeHash($cfgBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
          if ($usedConfigH -cne [string]$stagePin.configHash) { throw ($Name + ': config changed; retry.') }
          $stagedCfg = Join-Path $staged 'rulesync.jsonc'
          [System.IO.File]::WriteAllBytes($stagedCfg, $cfgBytes)
          $UseRoots = @((Get-NormPath $stagedCommon))
          $UseConfig = Get-NormPath $stagedCfg
          if ([bool]$stagePin.localExists) {
            $lfBytes = [System.IO.File]::ReadAllBytes($LocalFile)
            $usedLocalH = (($sh.ComputeHash($lfBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
            if ($usedLocalH -cne [string]$stagePin.localHash) { throw ($Name + ': local rule changed; retry.') }
            [System.IO.File]::WriteAllBytes((Join-Path $stagedRules 'project-local.md'), $lfBytes)
            $UseRoots += (Get-NormPath $staged)
          }
        } finally { $sh.Dispose() }
      }

      $BaseArgs = @('--yes', $script:Pkg, 'generate', '--config', $UseConfig, '--input-roots') + $UseRoots + @('--output-roots', $RepoFull, '--targets', $script:Targets, '--features', 'rules')
      # Shirube32 resolves --config against the process cwd (path-traversal
      # guard): a staged config outside the install cwd is rejected. Run every
      # per-project CLI call from the directory containing UseConfig. Args stay
      # absolute; only the cwd changes. Single push per project, popped in
      # finally before own snapshot cleanup (never deleting the cwd).
      $CliDir = Split-Path $UseConfig -Parent
      if ($CliDir) { Push-Location -LiteralPath $CliDir; $cliPushed = $true }
      if ($PreviewOnly) {
        if (-not $snapCreated) { $snap = New-OwnedSnapshot; $snapCreated = $true }
        $outDir = Join-Path $snap 'output'
        New-Item -ItemType Directory -Path $outDir | Out-Null
        $previewArgs = @('--yes', $script:Pkg, 'generate', '--config', $UseConfig, '--input-roots') + $UseRoots + @('--output-roots', $outDir, '--targets', $script:Targets, '--features', 'rules')
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $planOut = & $script:npx @($previewArgs + @('--dry-run')) 2>&1 | Out-String; $planCode = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prevEap }
        if ($planCode -ne 0) { throw ('preview dry-run failed. ' + (Get-RedactedTail $planOut)) }
        $count = 0
        foreach ($ln in ($planOut -split "`n")) {
          $m = [regex]::Match($ln, 'Would write:\s*(.+?)\s*$')
          if ($m.Success) {
            if (-not (Get-NormPath $m.Groups[1].Value.Trim()).Equals((Join-Path $outDir 'AGENTS.md'), [StringComparison]::OrdinalIgnoreCase)) { throw 'preview refusing unexpected output.' }
            $count++
          }
        }
        if ($count -lt 1) { throw 'preview planned no writes.' }
        if ((Invoke-Step ($Name + ': preview generate') $script:npx $previewArgs) -ne 0) { throw ('preview generate failed. ' + $script:LastStepTail) }
        $generated = Join-Path $outDir 'AGENTS.md'
        $files = @(Get-ChildItem -LiteralPath $outDir -Recurse -Force)
        if (($files.Count -ne 1) -or (-not (Test-Path -LiteralPath $generated -PathType Leaf)) -or (Test-Reparse $generated)) { throw 'preview generated unexpected files.' }
        $current = ''
        if (Test-Path -LiteralPath $AgentsPath) { $current = [IO.File]::ReadAllText($AgentsPath) }
        # Consumed hashes recorded here are the verified staged bytes, so the
        # matcher can bind each output to its approved inputs.
        $recCommonH = $usedCommonH
        if ([string]::IsNullOrWhiteSpace($recCommonH)) { $recCommonH = $script:CommonSha }
        $recConfigH = $usedConfigH
        if ([string]::IsNullOrWhiteSpace($recConfigH)) { try { $recConfigH = Get-FileHashValue $script:PreviewConfig } catch { $recConfigH = '' } }
        $recLocalH = $usedLocalH
        if ($null -eq $recLocalH) { $recLocalH = Get-FileHashValue $LocalFile }
        $script:Plans.Add(@{name=$Name; path=$RepoFull; result='success'; currentText=$current; generatedText=[IO.File]::ReadAllText($generated); agentsHash=(Get-FileHashValue $AgentsPath); localHash=$recLocalH; commonSha=$recCommonH; commonCommit=$script:CommonCommit; configHash=$recConfigH; error=$null})
        return 0
      }
      $check = Invoke-Step ($Name + ': generate --check') $script:npx ($BaseArgs + @('--check'))
      if ($check -eq 0) { Save-ProjectResult $Name 'success' ''; Write-Log ($Name + ': OK no changes.'); return 0 }
      if ($check -ne 1) { throw ($Name + ': check failed with exit=' + $check + '. ' + $script:LastStepTail) }
      # Exit 1 means drift OR error, so confirm with --dry-run and inspect
      # every planned path before touching the repo.
      $prevEap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $dryOut = & $script:npx @($BaseArgs + @('--dry-run')) 2>&1 | Out-String
        $dryCode = $LASTEXITCODE
      }
      finally { $ErrorActionPreference = $prevEap }
      if ($null -eq $dryCode) { $dryCode = 1 }
      Write-Log (Redact("EXIT=" + $dryCode + ' ' + $Name + ': generate --dry-run' + "`n" + $dryOut))
      if ($dryCode -ne 0) { throw ($Name + ': dry-run failed; not a clean update candidate. ' + (Get-RedactedTail $dryOut)) }
      $planned = 0
      foreach ($ln in ($dryOut -split "`n")) {
        $m = [regex]::Match($ln, 'Would write:\s*(.+?)\s*$')
        if ($m.Success) {
          $cand = Get-NormPath $m.Groups[1].Value.Trim()
          if (-not $cand.Equals($AgentsFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw ($Name + ': refusing unexpected output.') }
          $planned++
        }
      }
      if ($planned -lt 1) { throw ($Name + ': dry-run planned no writes; not a clean update candidate.') }
      if ($DryRun) { Write-Log ($Name + ': DRYRUN: updates available; skipped backup/generate.'); return 0 }

      # Plan-bound apply: re-verify this project's approved inputs immediately
      # before mutating it (a sibling's run may have overlapped an edit).
      # Only this entry plus shared inputs are compared, so an already-applied
      # sibling never fails this project; unselected entries are ignored.
      if ($script:ApprovedPlanId -ne '') {
        if (-not $script:HavePlanMatch) { throw ($Name + ': plan-bound sync unavailable (validation module missing).') }
        $preLive = Build-PlanLiveInputs
        $preChk = Test-MgmtPlanMatch $script:ApprovedPlan $preLive @($Name)
        if (-not $preChk.ok) { throw ($Name + ': plan inputs changed, refusing write: ' + $preChk.error) }
        # Execution identity: the actual entry used for writes must equal the
        # approved input (name/path/enabled), so an old/new path mix is
        # impossible even if the registry moved after the startup check.
        $pinEnts = @()
        try { $pinEnts = @(Get-MgmtField (Get-MgmtField $script:ApprovedPlan 'inputs') 'entries') } catch { $pinEnts = @() }
        $pinMe = @($pinEnts | Where-Object { [string](Get-MgmtField $_ 'name') -ceq $Name })
        if ($pinMe.Count -ne 1) { throw ($Name + ': plan inputs changed, refusing write: approved entry missing.') }
        $pinPath = ''
        try { $pinPath = Get-NormPath ([string](Get-MgmtField $pinMe[0] 'path')) } catch { $pinPath = '' }
        if (($pinPath -eq '') -or (-not $pinPath.Equals($RepoFull, [System.StringComparison]::OrdinalIgnoreCase))) { throw ($Name + ': plan inputs changed, refusing write: execution path differs from approved input.') }
        $pinEn = $true
        try { $pinEn = [bool](Get-MgmtField $pinMe[0] 'enabled') } catch {}
        $myEn = $true
        try { if ($Entry.PSObject.Properties['enabled'] -and ($Entry.enabled -is [bool])) { $myEn = [bool]$Entry.enabled } } catch {}
        if ($pinEn -ne $myEn) { throw ($Name + ': plan inputs changed, refusing write: enabled differs from approved input.') }
      }

      # Re-check immediately before touching the repo (best-effort TOCTOU
      # mitigation, not a guarantee): a symlinked AGENTS.md would redirect
      # the write outside version control.
      if (Test-Reparse $RepoFull) { throw ("refusing reparse point: " + $Name) }
      if ((Test-Path -LiteralPath $AgentsPath) -and (Test-Reparse $AgentsPath)) { throw ("refusing reparse AGENTS: " + $Name) }

      $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
      $bdir = Join-Path $script:BackupRoot ($ts + '-' + $Name)
      $n = 0
      while (Test-Path $bdir) { $n++; $bdir = Join-Path $script:BackupRoot ($ts + '-' + $Name + '-' + $n) }
      if (-not (Test-Contained $bdir $script:BackupRoot)) { throw ($Name + ': backup escaped root.') }
      $dirSec = New-Object System.Security.AccessControl.DirectorySecurity
      $dirSec.SetAccessRuleProtection($true, $false)
      foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
        $dirSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
      }
      [System.IO.Directory]::CreateDirectory($bdir, $dirSec) | Out-Null
      if (Test-Reparse $bdir) { throw 'backup is a reparse point.' }
      $backupId = Split-Path $bdir -Leaf
      $localPresent = [bool](($snapLocal -ne '') -and (Test-Path -LiteralPath $snapLocal -PathType Leaf))
      $agentsPresent = Test-Path -LiteralPath $AgentsPath -PathType Leaf
      $localBytes = $null
      if ($localPresent) { $localBytes = [System.IO.File]::ReadAllBytes($snapLocal) }
      $agentsBytes = $null
      if ($agentsPresent) { $agentsBytes = [System.IO.File]::ReadAllBytes($AgentsPath) }
      $agentsHashVal = $null
      if ($agentsPresent) {
        try {
          $hA = [System.Security.Cryptography.SHA256]::Create()
          try { $agentsHashVal = (($hA.ComputeHash($agentsBytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
          finally { $hA.Dispose() }
        } catch { $agentsHashVal = $null }
      }
      $localHashVal = $null
      if ($localPresent) {
        try {
          $hL = [System.Security.Cryptography.SHA256]::Create()
          try { $localHashVal = (($hL.ComputeHash($localBytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
          finally { $hL.Dispose() }
        } catch { $localHashVal = $null }
      }
      try {
        if ($localPresent) {
          Write-PrivateBytes (Join-Path $bdir 'project-local.md') $localBytes
          $gotLocalH = Get-FileHashValue (Join-Path $bdir 'project-local.md')
          if ([string]::IsNullOrWhiteSpace($gotLocalH) -or [string]::IsNullOrWhiteSpace($localHashVal) -or $gotLocalH -cne $localHashVal) { throw ($Name + ': local backup hash mismatch.') }
          if (-not (Test-PrivateJsonAcl (Join-Path $bdir 'project-local.md'))) { throw ($Name + ': local backup ACL is not private.') }
        }
        if ($agentsPresent -and [string]::IsNullOrWhiteSpace($agentsHashVal)) { throw ($Name + ': agents hash unavailable; refusing generate.') }
        if ($localPresent -and [string]::IsNullOrWhiteSpace($localHashVal)) { throw ($Name + ': local hash unavailable; refusing generate.') }
        Write-PrivateJson (Join-Path $bdir 'manifest.json') @{schemaVersion=1; name=$Name; path=$RepoFull; createdAt=[DateTime]::UtcNow.ToString('o'); agentsPresent=$agentsPresent; localPresent=$localPresent; commonSha=$script:CommonSha; commonCommit=$script:CommonCommit; commonText=$script:CommonText; agentsHash=$agentsHashVal; localHash=$localHashVal}
        if ($agentsPresent) {
          Write-PrivateBytes (Join-Path $bdir 'AGENTS.md') $agentsBytes
          $gotAgentsH = Get-FileHashValue (Join-Path $bdir 'AGENTS.md')
          if ([string]::IsNullOrWhiteSpace($gotAgentsH) -or [string]::IsNullOrWhiteSpace($agentsHashVal) -or $gotAgentsH -cne $agentsHashVal) { throw ($Name + ': AGENTS backup hash mismatch.') }
          if (-not (Test-PrivateJsonAcl (Join-Path $bdir 'AGENTS.md'))) { throw ($Name + ': AGENTS backup ACL is not private.') }
          Write-Log ($Name + ': BACKUP: ' + $AgentsPath)
        }
      } catch {
        try { if (Test-Path -LiteralPath $bdir) { Remove-Item -LiteralPath $bdir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        throw
      }
      $agentsWasPresent = $agentsPresent

      # Rollback helper: restores AGENTS.md from this run's backup (or removes
      # it when absent before generate) and verifies the result. Returns
      # $null on a verified restore, else an error string. Never throws.
      function Restore-OneBackup {
        try {
          # Trust anchor: the manifest hash recorded at backup time (before
          # generate). Never derive the expected hash from the backup file
          # itself — it may have been corrupted after the backup.
          $mfH = $null; $mfPresent = $agentsWasPresent
          try {
            $mfRaw = Get-Content -LiteralPath (Join-Path $bdir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($mfRaw.PSObject.Properties['agentsHash']) { $mfH = [string]$mfRaw.agentsHash }
            if ($mfRaw.PSObject.Properties['agentsPresent']) { $mfPresent = [bool]$mfRaw.agentsPresent }
          } catch { return 'backup manifest unreadable, original kept as-is' }
          $rbAgents = Join-Path $bdir 'AGENTS.md'
          if ($mfPresent) {
            if (-not (Test-Path -LiteralPath $rbAgents -PathType Leaf)) { return 'backup unavailable, original kept as-is' }
            $bakH = Get-FileHashValue $rbAgents
            if (($null -eq $mfH) -or ($mfH -eq '') -or ($bakH -cne $mfH)) { return 'backup corrupt, original kept as-is' }
            Copy-Item -LiteralPath $rbAgents -Destination $AgentsPath -Force
            $gotH = Get-FileHashValue $AgentsPath
            if ($gotH -cne $mfH) { return 'restored content mismatch' }
          }
          elseif (-not $agentsWasPresent) {
            if (Test-Path -LiteralPath $AgentsPath) {
              Remove-Item -LiteralPath $AgentsPath -Force
            }
            if (Test-Path -LiteralPath $AgentsPath) { return 'unapproved file not removed' }
          }
          else { return 'backup unavailable, original kept as-is' }
          return $null
        } catch { return $_.Exception.Message }
      }
      try {
        if ((Invoke-Step ($Name + ': generate') $script:npx $BaseArgs) -ne 0) {
          throw ($Name + ': generate failed. ' + $script:LastStepTail)
        }
        # Plan-bound apply: the fresh output must equal the approved output.
        if ($null -ne $approvedOut) {
          $freshT = ''
          try { $freshT = [System.IO.File]::ReadAllText($AgentsPath, [System.Text.Encoding]::UTF8) } catch { $freshT = '' }
          if ($freshT -cne $approvedOut) {
            throw ($Name + ': generated output differs from the approved plan.')
          }
        }
        if ((Invoke-Step ($Name + ': final check') $script:npx ($BaseArgs + @('--check'))) -ne 0) {
          throw ($Name + ': final check failed. ' + $script:LastStepTail)
        }
      }
      catch {
        # Every post-backup failure rolls back to the pre-generate state.
        # The restore is verified; a rollback failure is reported explicitly
        # and never claimed as restored.
        $failMsg = $_.Exception.Message
        $rbErr = Restore-OneBackup
        if ($rbErr) { throw ($failMsg + ' rollback also failed: ' + $rbErr) }
        throw ($failMsg + ' restored backup.')
      }
      Save-ProjectResult $Name 'success' '' $backupId
      Write-Log ($Name + ': OK updated.')
      return 0
    }
    catch {
      $message = Redact $_.Exception.Message
      Write-Log ($Name + ' FAIL: ' + $message)
      if ($PreviewOnly) { $script:Plans.Add(@{name=$Name; path=[string]$Entry.path; result='failed'; error=$message}) }
      else { try { Save-ProjectResult $Name 'failed' $message $backupId } catch { Write-Log ('status save failed: ' + (Redact $_.Exception.Message)) } }
      return 1
    }
    finally {
      # Restore the per-project CLI cwd before touching the snapshot: popping
      # first guarantees the snapshot dir is never the cwd when deleted.
      # Flagged so a failed push never pops the outer install location.
      if ($cliPushed) {
        try { Pop-Location } catch { Write-Log (Redact($Name + ' cwd restore note: ' + $_.Exception.Message)) }
        $cliPushed = $false
      }
      # Delete only the snapshot this run created (ownership); never another run's.
      # Best-effort; TOCTOU race after the checks cannot be fully excluded.
      try {
        if ($snapCreated -and $snap -and (Test-Path -LiteralPath $snap) -and (Test-Contained $snap $SnapRoot) -and (-not (Test-Reparse $snap))) {
          Remove-Item -LiteralPath $snap -Recurse -Force
        }
      }
      catch { Write-Log (Redact($Name + ' snapshot cleanup note: ' + $_.Exception.Message)) }
    }
  }

  $lockStream = $null
  try { $lockStream = [System.IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
  catch {
    $e = $_.Exception
    while (($e -is [System.Management.Automation.MethodInvocationException]) -and ($e.InnerException)) { $e = $e.InnerException }
    $win32 = -1
    if ($e -is [System.IO.IOException]) { $win32 = ($e.HResult -band 0xFFFF) }
    if (($e -is [System.IO.IOException]) -and ($win32 -eq 32)) {
      Write-Log 'SKIP: another run is in progress.'
      if ($ReportSkip) { return 75 }
      return 0
    }
    Write-Log (Redact('FAIL: lock failed: ' + $e.Message))
    return 1
  }

  try {
    $script:npx = Resolve-Exe 'npx.cmd' 'npx'
    $script:gh = Resolve-Exe 'gh' $null
    $script:Pkg = $Pkg
    $script:Targets = $Targets
    $script:CommonRoot = $CommonRoot
    $script:PreviewConfig = $PreviewConfig
    $script:BackupRoot = $BackupRoot
    $script:AutoDir = $AutoDir
    $script:ApprovedPlan = $null
    $script:ApprovedPlanId = ''
    $script:LastStepTail = ''
    # Plan-bound applies reuse the shared pure matcher when the management
    # module is deployed alongside; direct/scheduled syncs never need it.
    $script:HavePlanMatch = $false
    try {
      $pmMod = Join-Path $AutoDir 'Project-Management.ps1'
      if ((Test-Path -LiteralPath $pmMod -PathType Leaf) -and (-not (Test-Reparse $pmMod))) {
        . $pmMod
        if (Get-Command Test-MgmtPlanMatch -ErrorAction SilentlyContinue) { $script:HavePlanMatch = $true }
      }
    } catch { $script:HavePlanMatch = $false }

    if (-not (Test-Path -LiteralPath $ProjectsFile)) { throw 'projects registry missing.' }
    $Projects = Get-Content -LiteralPath $ProjectsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Projects -isnot [array]) { $Projects = @($Projects) }

    $script:Plans = New-Object 'System.Collections.Generic.List[object]'
    $script:ProjectStatus = @{}
    $statusFile = Join-Path $AutoDir 'project-status.json'
    if (Test-Path -LiteralPath $statusFile) {
      if (Test-Reparse $statusFile) { throw 'status is a reparse point.' }
      $existing = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($prop in $existing.projects.PSObject.Properties) { $script:ProjectStatus[$prop.Name] = $prop.Value }
    }
    if ($RequestPath) {
      $requestFull = Get-NormPath $RequestPath
      if ((Split-Path $requestFull -Parent) -ne (Get-NormPath $AutoDir)) { throw 'request must be directly inside automation root.' }
      if ((Split-Path $requestFull -Leaf) -cnotmatch '^dashboard\.request-[0-9a-f]{32}\.json$') { throw 'invalid request filename.' }
      if (Test-Reparse $requestFull) { throw 'request is a reparse point.' }
      $request = Get-Content -LiteralPath $requestFull -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($request.PSObject.Properties['projectNames']) { $ProjectNames = @($request.projectNames) }
      if ($request.PSObject.Properties['previewOnly']) {
        if ($request.previewOnly -isnot [bool]) { throw 'previewOnly must be boolean.' }
        $PreviewOnly = $request.previewOnly
      }
      if ($request.PSObject.Properties['planPath']) { $PlanPath = [string]$request.planPath }
      $script:ApprovedPlanId = ''
      if ($request.PSObject.Properties['planId'] -and ([string]$request.planId).Trim() -ne '') {
        $script:ApprovedPlanId = [string]$request.planId
        if ($script:ApprovedPlanId -cnotmatch '^[0-9a-f]{32}$') { throw 'invalid plan id.' }
      }
    }
    if ($PreviewOnly) {
      if (-not $PlanPath) { throw 'preview requires planPath.' }
      $PlanPath = Get-NormPath $PlanPath
      if ((Split-Path $PlanPath -Parent) -ne (Get-NormPath $AutoDir)) { throw 'plan must be directly inside automation root.' }
      if ((Split-Path $PlanPath -Leaf) -cnotmatch '^dashboard\.plan-[0-9a-f]{32}\.json$') { throw 'invalid plan filename.' }
      if (Test-Reparse $PlanPath) { throw 'plan is a reparse point.' }
    }
    if ($PreviewOnly -and ($script:ApprovedPlanId -ne '')) { throw 'preview runs do not consume plans.' }
    if ($ProjectNames.Count -gt 0) {
      foreach ($selected in $ProjectNames) {
        if ((-not (Test-SafeName $selected)) -or (@($Projects | Where-Object { $_.name -ceq $selected }).Count -ne 1)) { throw 'unknown or ambiguous selected project.' }
      }
      $Projects = @($Projects | Where-Object { $ProjectNames -ccontains $_.name })
    }
    $script:CommonSha = $null; $script:CommonCommit = $null; $script:CommonText = $null
    # Immutable startup pin: the execution set is loaded before install, so a
    # registry change during install must refuse later (never mix stale
    # execution paths with fresh inputs).
    $script:StartupPin = @($Projects | ForEach-Object {
      $sp2 = ''; try { $sp2 = Get-NormPath ([string]$_.path) } catch { $sp2 = [string]$_.path }
      $se2 = $true
      try { if ($_.PSObject.Properties['enabled'] -and ($_.enabled -is [bool])) { $se2 = [bool]$_.enabled } } catch {}
      @{ name = [string]$_.name; normPath = $sp2; enabled = [bool]$se2 }
    })

    $prevGithubToken = $env:GITHUB_TOKEN
    $prevGhToken = $env:GH_TOKEN
    $addedToken = $false
    try {
      if ($env:GITHUB_TOKEN) { $Secrets += $env:GITHUB_TOKEN }
      if ($env:GH_TOKEN) { $Secrets += $env:GH_TOKEN }
      if ((-not $env:GITHUB_TOKEN) -and (-not $env:GH_TOKEN)) {
        # Stored GitHub-integration token wins; gh stays the fallback.
        $tok = ''
        if (Get-Command Get-GitHubSyncToken -ErrorAction SilentlyContinue) {
          try { $tok = [string](Get-GitHubSyncToken $AutoDir) } catch { $tok = '' }
        }
        if (-not $tok) {
          $prevEapGh = $ErrorActionPreference
          $ErrorActionPreference = 'SilentlyContinue'
          try {
            $tok = (& $gh auth token 2>$null | Out-String).Trim()
            $tokCode = $LASTEXITCODE
          }
          finally { $ErrorActionPreference = $prevEapGh }
          if (($null -eq $tokCode) -or ($tokCode -ne 0)) { throw 'GitHub auth failed (gh auth token).' }
        }
        if (-not $tok) { throw 'GitHub auth returned empty token.' }
        $env:GITHUB_TOKEN = $tok
        $Secrets += $tok
        $addedToken = $true
      }

      Push-Location $PreviewDir
      try {
        # Shared fetch once; a failure stops everything before any repo is touched.
        if ((Invoke-Step 'install --update' $npx @('--yes', $Pkg, 'install', '--update')) -ne 0) {
          throw 'install --update failed.'
        }
        if (-not (Test-Path -LiteralPath $CuratedCommon)) { throw 'shared rule cache missing.' }
        $commonText = [System.IO.File]::ReadAllText($CuratedCommon, [System.Text.Encoding]::UTF8)
        $script:CommonSha = Get-FileHashValue $CuratedCommon
        # Plain .NET read: Get-Content -Raw keeps ETS props (PSPath etc.) that explode ConvertTo-Json.
        $script:CommonText = $commonText
        $lockFile = Join-Path $PreviewDir 'rulesync.lock'
        if (Test-Path -LiteralPath $lockFile) {
          try {
            $lockText = Get-Content -LiteralPath $lockFile -Raw -Encoding UTF8
            $commitMatch = [regex]::Match($lockText, '["''](?:sha|commit|resolvedRef)["'']\s*:\s*["'']([0-9a-f]{40})["'']')
            if ($commitMatch.Success) { $script:CommonCommit = $commitMatch.Groups[1].Value }
          } catch {}
        }
        if (-not (Test-FrontmatterFlag $commonText 'root')) { throw 'shared rule lost root:true, refusing.' }

        # Startup race guard: re-read the registry after install and refuse
        # when any selected entry moved (path/enabled/presence changed).
        # Covers preview and apply before anything is generated or written.
        $reReg = $null
        try {
          if ((-not (Test-Path -LiteralPath $ProjectsFile -PathType Leaf)) -or (Test-Reparse $ProjectsFile)) { throw 'projects registry missing.' }
          $reReg = Get-Content -LiteralPath $ProjectsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { throw 'registry changed during startup; retry.' }
        if ($reReg -isnot [array]) { $reReg = @($reReg) }
        foreach ($sp in $script:StartupPin) {
          $hit = @($reReg | Where-Object { [string]$_.name -ceq [string]$sp.name })
          if ($hit.Count -ne 1) { throw 'registry changed during startup; retry.' }
          $hitPath = ''; try { $hitPath = Get-NormPath ([string]$hit[0].path) } catch { $hitPath = '' }
          if ($hitPath -cne [string]$sp.normPath) { throw 'registry changed during startup; retry.' }
          $hitEn = $true
          try { if ($hit[0].PSObject.Properties['enabled'] -and ($hit[0].enabled -is [bool])) { $hitEn = [bool]$hit[0].enabled } } catch {}
          if ($hitEn -ne [bool]$sp.enabled) { throw 'registry changed during startup; retry.' }
        }

        # Plan-bound apply: the server pre-checks without a lock (read-only),
        # but this under-lock gate is authoritative — no project is touched
        # before the approved inputs are re-verified against live state here.
        if ($script:ApprovedPlanId -ne '') {
          if (-not $script:HavePlanMatch) { throw 'plan-bound sync unavailable (validation module missing).' }
          $apFile = Join-Path $AutoDir ("dashboard.plan-" + $script:ApprovedPlanId + ".json")
          if ((-not (Test-Contained $apFile $AutoDir)) -or (-not (Test-Path -LiteralPath $apFile -PathType Leaf)) -or (Test-Reparse $apFile)) { throw 'plan not found.' }
          if (((Get-Date) - (Get-Item -LiteralPath $apFile).LastWriteTime).TotalMinutes -gt 120) { throw 'plan expired. Recreate it from preview.' }
          try { $script:ApprovedPlan = Get-Content -LiteralPath $apFile -Raw -Encoding UTF8 | ConvertFrom-Json }
          catch { throw 'plan unreadable.' }
          $gateNames = @($Projects | ForEach-Object { [string]$_.name })
          $gateLive = Build-PlanLiveInputs
          $gateChk = Test-MgmtPlanMatch $script:ApprovedPlan $gateLive $gateNames
          if (-not $gateChk.ok) { Write-Log ('FAIL: plan inputs changed: ' + $gateChk.error); return 1 }
        }

        # Registered projects are independent: one failure never skips the next.
        $failed = 0
        $previewBase = $null
        $execList = $Projects
        if ($PreviewOnly) {
          $previewBase = Build-PlanLiveInputs
          # Single snapshot: derive the exact executor rows from the same
          # approved input set (never the pre-install cached rows), so a
          # registry change between the startup check and here cannot mix
          # old execution targets with new inputs.
          $selExec = @($Projects | ForEach-Object { [string]$_.name })
          $execRows = @()
          foreach ($snm in $selExec) {
            $shit = @($previewBase.entries | Where-Object { [string]$_.name -ceq $snm })
            if ($shit.Count -ne 1) { throw 'preview inputs changed; retry.' }
            $execRows += [pscustomobject]@{ name = [string]$shit[0].name; path = [string]$shit[0].path; enabled = [bool]$shit[0].enabled }
          }
          $execList = $execRows
        }
        foreach ($pr in $execList) {
          if ((Invoke-OneProject $pr) -ne 0) { $failed++ }
        }
        if ($PreviewOnly) {
          # End-of-preview gate: refuse to publish when any selected input
          # moved during generation (cross-project race). No plan file then.
          if ($script:HavePlanMatch) {
            $previewLive = Build-PlanLiveInputs
            $baseNames = @($previewBase.entries | ForEach-Object { [string]$_.name } | Sort-Object)
            $liveNames = @($previewLive.entries | ForEach-Object { [string]$_.name } | Sort-Object)
            if (Compare-Object $baseNames $liveNames) { throw 'preview inputs changed (registry); not publishing plan.' }
            $endChk = Test-MgmtInputsMatch $previewBase $previewLive $baseNames
            if (-not $endChk.ok) { throw ('preview inputs changed; not publishing plan: ' + $endChk.error) }
          }
          else { Write-Log 'note: preview inputs gate skipped (validation module missing).' }
          # Publish only when every generated output belongs to its approved
          # input entry (same path); then publish the original immutable pin.
          foreach ($ppj in @($script:Plans.ToArray())) {
            if ([string]$ppj.result -cne 'success') { continue }
            $pie = @($previewBase.entries | Where-Object { [string]$_.name -ceq [string]$ppj.name })
            if (($pie.Count -ne 1) -or (-not ([string]$ppj.path).Equals([string]$pie[0].path, [System.StringComparison]::OrdinalIgnoreCase))) {
              throw 'preview inputs changed; not publishing plan.'
            }
          }
          # Publish the original immutable pin: never re-read inputs after the
          # end gate (a late edit must not become new approved input).
          Write-PrivateJson $PlanPath @{schemaVersion=2; commonSha=$previewBase.commonSha; commonCommit=$script:CommonCommit; commonText=$previewBase.commonText; configHash=$previewBase.configHash; targets=$previewBase.targets; createdAt=[DateTime]::UtcNow.ToString('o'); projects=@($script:Plans.ToArray()); inputs=@{ entries=$previewBase.entries }}
        }
        if ($failed -gt 0) { Write-Log ("FAIL: " + $failed + " project(s) failed."); return 1 }
        Write-Log 'OK: all projects in sync.'
        return 0
      }
      finally { Pop-Location }
    }
    finally {
      if ($addedToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
      elseif ($null -eq $prevGithubToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
      else { $env:GITHUB_TOKEN = $prevGithubToken }
      if ($null -eq $prevGhToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
      else { $env:GH_TOKEN = $prevGhToken }
    }
  }
  catch { Write-Log (Redact('FAIL: ' + $_.Exception.Message)); return 1 }
  finally { if ($lockStream) { $lockStream.Close() } }
}

# Dot-sourced by self-checks (no exit); executed directly by Task Scheduler.
if ($MyInvocation.InvocationName -ne '.') {
  $code = Invoke-ProjectSync -DryRun:$DryRun -ReportSkip:$ReportSkip -ProjectNames $ProjectNames -PreviewOnly:$PreviewOnly -PlanPath $PlanPath -RequestPath $RequestPath
  exit $code
}
