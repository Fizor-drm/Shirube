# Sync-GlobalRules.ps1 - Auto-sync global rules via Shirube standard commands only.
# Reads GitHub rules (global-preview cwd) and writes real home files.
# Run hidden from Task Scheduler (at logon + every 15 min). No MCP/model APIs.
# Manual home edits are overwritten by design. Failures exit non-zero for retry.
# r2: -ReportSkip (busy lock returns 75 for dashboard skipped vs success),
# stored target selection (Codex/OpenCode subset), structured per-provider
# status, non-writing preview plans, and plan-bound applies share the same
# fetch/generate entry (no CLI duplication). Defaults preserve periodic behavior.
param([switch]$DryRun, [switch]$ReportSkip, [string[]]$TargetNames = @(), [switch]$PreviewOnly, [string]$PlanPath = "", [string]$RequestPath = "")

$GlobalMgmtFile = Join-Path $PSScriptRoot 'Global-Management.ps1'
if (-not (Test-Path -LiteralPath $GlobalMgmtFile -PathType Leaf)) { throw 'Global-Management.ps1 missing next to Sync-GlobalRules.ps1.' }
. $GlobalMgmtFile

# rulesync resolves rulesync.jsonc plus the merged rulesync.local.jsonc from
# the Global preview cwd. Parse JSONC (comments/trailing commas) so a real
# top-level language key cannot hide behind comments, strings or nesting.
function ConvertFrom-GlobalJsoncText([string]$Text) {
  $src = [string]$Text
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escape = $false
  $i = 0
  while ($i -lt $src.Length) {
    $ch = $src[$i]
    if ($inString) {
      [void]$sb.Append($ch)
      if ($escape) { $escape = $false }
      elseif ($ch -eq '\') { $escape = $true }
      elseif ($ch -eq '"') { $inString = $false }
      $i++
      continue
    }
    if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); $i++; continue }
    if (($ch -eq '/') -and (($i + 1) -lt $src.Length)) {
      $next = $src[$i + 1]
      if ($next -eq '/') {
        $i += 2
        while (($i -lt $src.Length) -and ($src[$i] -ne "`r") -and ($src[$i] -ne "`n")) { $i++ }
        continue
      }
      if ($next -eq '*') {
        $i += 2
        while ((($i + 1) -lt $src.Length) -and -not (($src[$i] -eq '*') -and ($src[$i + 1] -eq '/'))) { $i++ }
        if (($i + 1) -lt $src.Length) { $i += 2 } else { $i = $src.Length }
        continue
      }
    }
    [void]$sb.Append($ch)
    $i++
  }
  $clean = $sb.ToString()
  $out = New-Object System.Text.StringBuilder
  $inString = $false
  $escape = $false
  for ($j = 0; $j -lt $clean.Length; $j++) {
    $ch = $clean[$j]
    if ($inString) {
      [void]$out.Append($ch)
      if ($escape) { $escape = $false }
      elseif ($ch -eq '\') { $escape = $true }
      elseif ($ch -eq '"') { $inString = $false }
      continue
    }
    if ($ch -eq '"') { $inString = $true; [void]$out.Append($ch); continue }
    if ($ch -eq ',') {
      $k = $j + 1
      while (($k -lt $clean.Length) -and [char]::IsWhiteSpace($clean[$k])) { $k++ }
      if (($k -lt $clean.Length) -and (($clean[$k] -eq '}') -or ($clean[$k] -eq ']'))) { continue }
    }
    [void]$out.Append($ch)
  }
  $json = $out.ToString().Trim()
  if ($json -eq '') { return $null }
  return ($json | ConvertFrom-Json)
}

function Get-GlobalRulesyncLanguage([string]$PreviewDir) {
  $language = $null
  foreach ($name in @('rulesync.jsonc', 'rulesync.local.jsonc')) {
    $file = Join-Path $PreviewDir $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    try {
      $obj = ConvertFrom-GlobalJsoncText (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
    }
    catch { throw ('rulesync setting is unreadable: ' + $name) }
    if ($null -eq $obj) { continue }
    $prop = $null
    try { $prop = $obj.PSObject.Properties['language'] } catch {}
    if ($null -eq $prop) { continue }
    $value = $prop.Value
    if ($null -eq $value) { $language = $null; continue }
    $language = [string]$value
  }
  return $language
}

function Invoke-GlobalSync {
  param([switch]$DryRun, [switch]$ReportSkip, [string[]]$TargetNames = @(), [switch]$PreviewOnly, [string]$PlanPath = "", [string]$RequestPath = "")

  $ErrorActionPreference = 'Stop'
  # One version per run: install, check, dry-run and generate all use this value.
  $ShirubeVersion = [string](Get-ShirubeSetting -Name 'rulesyncVersion' -Default '32.0.0')
  $Pkg = 'rulesync@' + $ShirubeVersion

  $script:GblHaveTargets = $false
  $script:GblEffTargets = @()
  $script:GblCommit = ''
  $script:GblApprovedPlan = $null
  $script:GblStatusSaved = $false

  $AutoDir = $PSScriptRoot
  $PreviewDir = Join-Path (Split-Path $AutoDir -Parent) 'global-preview'
  $LogDir = Join-Path $AutoDir 'logs'
  $BackupRoot = Join-Path $AutoDir 'backups'
  $LockPath = Join-Path $AutoDir 'Sync-GlobalRules.lock'

  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $LogFile = Join-Path $LogDir ("Sync-GlobalRules-" + (Get-Date -Format 'yyyyMMdd') + ".log")
  $Secrets = @()
  function Write-Log([string]$Message) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
  }
  function Redact([string]$Text) {
    $r = $Text
    foreach ($v in $Secrets) { if ($v) { $r = $r.Replace($v, '***') } }
    $r = Redact-GlobalText $r ''
    return $r
  }
  function Get-RedactedTail([string]$Text) {
    $r = Redact $Text
    if ([string]::IsNullOrEmpty($r)) { return '' }
    $max = 800
    if ($r.Length -gt $max) { return $r.Substring($r.Length - $max) }
    return $r
  }
  function Save-GlobalRunStatus([string]$Result, [string]$Message, [string]$BackupId) {
    if ($PreviewOnly -or $DryRun) { return }
    if (-not $script:GblHaveTargets) { return }
    try {
      foreach ($t in $script:GblEffTargets) {
        Save-GlobalProviderResult $AutoDir $t $Result $Message $script:GblCommit $BackupId | Out-Null
      }
      $script:GblStatusSaved = $true
    } catch { Write-Log (Redact('status save note: ' + $_.Exception.Message)) }
  }
  function Resolve-Exe([string]$Primary, [string]$Fallback) {
    $c = Get-Command $Primary -ErrorAction SilentlyContinue
    if ((-not $c) -and $Fallback) { $c = Get-Command $Fallback -ErrorAction SilentlyContinue }
    if (-not $c) { throw ("Required command not found: " + $Primary) }
    return $c.Source
  }
  function Invoke-Step([string]$Desc, [string]$Exe, [string[]]$Argv) {
    try { Assert-GlobalCliParents $Desc } catch { Write-Log (Redact('FAIL: parent changed before ' + $Desc + ': ' + $_.Exception.Message)); throw }
    Write-Log ("STEP: " + $Desc)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $out = & $Exe @Argv 2>&1 | Out-String
      $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    if ($null -eq $code) { $code = 1 }
    Write-Log (Redact("EXIT=" + $code + ' ' + $Desc + "`n" + $out))
    $script:LastStepTail = Get-RedactedTail $out
    # Post-CLI guard: a swap DURING the CLI (even on exit 0) must fail closed.
    # Callers must never record success after this throws.
    try { Assert-GlobalCliParents ($Desc + ' (post)') } catch { Write-Log (Redact('FAIL: parent changed after ' + $Desc + ': ' + $_.Exception.Message)); throw }
    return $code
  }
  function Get-NormPathLocal([string]$P) { return [System.IO.Path]::GetFullPath(($P -replace '/', '\')) }
  function Test-ContainedLocal([string]$Candidate, [string]$Root) {
    $c = Get-NormPathLocal $Candidate
    $r = Get-NormPathLocal $Root
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
    return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
  }
  function Test-ReparseLocal([string]$P) {
    $it = Get-Item -LiteralPath $P -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $false }
    return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  }
  # Centralized pre-CLI guard: re-inspect the SELECTED real-home paths (incl
  # parents) rooted at the trusted HomeBase immediately before EVERY CLI call.
  # The initial check stays, but install/check/dry-run/generate can swap
  # parents in between, so no CLI step may bypass this. Throws fail-closed;
  # callers never record success after a throw.
  function Assert-GlobalCliParents([string]$Desc) {
    if (-not $HomeBase) { return }
    if ((-not $EffArr) -or ($EffArr.Count -eq 0)) { return }
    if (-not $ContentPaths) { return }
    if (Global-Reparse $HomeBase) { throw '配置先を確認できませんでした。' }
    foreach ($vt in $EffArr) {
      Global-AssertNoLinkChain ([string]$ContentPaths[$vt]) $HomeBase $vt
    }
  }

  $script:LastStepTail = ''
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
    # Dashboard request file (selection/preview/plan). Fixed name inside AutoDir only.
    $ReqTargets = @()
    $ReqPreviewOnly = $false
    $ReqPlanPath = ''
    $ReqPlanId = ''
    if ($RequestPath -and ($RequestPath.Trim() -ne '')) {
      $rqFull = ''
      try { $rqFull = Get-NormPathLocal ($RequestPath.Trim()) } catch { throw 'request must be directly inside automation root.' }
      if ((Split-Path $rqFull -Parent) -cne (Get-NormPathLocal $AutoDir)) { throw 'request must be directly inside automation root.' }
      if ((Split-Path $rqFull -Leaf) -cnotmatch '^dashboard\.global-request-[0-9a-f]{32}\.json$') { throw 'invalid request filename.' }
      if (Test-ReparseLocal $rqFull) { throw 'request is a reparse point.' }
      $req = Get-Content -LiteralPath $rqFull -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($req.PSObject.Properties['targetNames']) {
        foreach ($tn in @($req.targetNames)) { $ReqTargets += [string]$tn }
      }
      if ($req.PSObject.Properties['previewOnly']) {
        if ($req.previewOnly -isnot [bool]) { throw 'previewOnly must be boolean.' }
        $ReqPreviewOnly = [bool]$req.previewOnly
      }
      if ($req.PSObject.Properties['planPath']) { $ReqPlanPath = [string]$req.planPath }
      if ($req.PSObject.Properties['planId'] -and ([string]$req.planId).Trim() -ne '') {
        $ReqPlanId = [string]$req.planId
        if ($ReqPlanId -cnotmatch '^[0-9a-f]{32}$') { throw 'invalid plan id.' }
      }
      if ($ReqPreviewOnly) { $PreviewOnly = $true }
      if (($ReqPlanPath -ne '') -and ($PlanPath -eq '')) { $PlanPath = $ReqPlanPath }
    }
    if ($TargetNames -and ($TargetNames.Count -gt 0)) { $ReqTargets = @($TargetNames | ForEach-Object { [string]$_ }) }

    # Effective targets: explicit selection wins, then stored settings, then defaults.
    $EffArr = @(Get-GlobalEffectiveTargets $AutoDir $ReqTargets)
    $script:GblEffTargets = $EffArr
    $script:GblHaveTargets = $true
    $Targets = ($EffArr -join ',')
    # Provider env overrides are checked before ANY CLI process or home write.
    Assert-GlobalProviderEnvironment $EffArr
    # rulesync 32 also patches a top-level language into Claude's shared
    # ~/.claude/settings.json under --features rules. That file is outside the
    # reviewed/backed-up fixed rule paths, so refuse rather than write it
    # unpreviewed. Only the selected target matters, and both config files
    # (base + local merge) are inspected. This is the pre-install fast path;
    # the authoritative pin below is taken after install, because rulesync
    # re-reads the config for every CLI call.
    if ($EffArr -contains 'claudecode') {
      $confLanguage = Get-GlobalRulesyncLanguage $PreviewDir
      if ($null -ne $confLanguage) {
        throw 'Claude Code cannot be synced while rulesync has a language setting: it also writes ~/.claude/settings.json, which is not previewed or backed up. Remove language from rulesync.jsonc/rulesync.local.jsonc, or deselect Claude Code.'
      }
    }

    $npx = Resolve-Exe 'npx.cmd' 'npx'
    $gh = Resolve-Exe 'gh' $null
    $nodeExe = Resolve-Exe 'node' $null

    # Home must match CLI: HOME_DIR if set, else current Node os.homedir().
    $HomeBase = $env:HOME_DIR
    if (-not $HomeBase) {
      $prevEapNode = $ErrorActionPreference
      $ErrorActionPreference = 'SilentlyContinue'
      try {
        $HomeBase = (& $nodeExe -e "process.stdout.write(require('node:os').homedir())" 2>$null | Out-String).Trim()
        $nodeCode = $LASTEXITCODE
      }
      finally { $ErrorActionPreference = $prevEapNode }
      if (($null -eq $nodeCode) -or ($nodeCode -ne 0) -or (-not $HomeBase)) { throw 'Failed to resolve home via node os.homedir().' }
    }
    $ContentPaths = Get-GlobalContentPaths $HomeBase

    # Selected real-home paths (incl parents) are inspected BEFORE any CLI
    # check/dry-run/generate: the nochange fastpath must never bypass this.
    if (Global-Reparse $HomeBase) { throw '配置先を確認できませんでした。' }
    foreach ($vt in $EffArr) {
      Global-AssertNoLinkChain ([string]$ContentPaths[$vt]) $HomeBase $vt
    }
    # Backup scope follows the SAME selection: unselected providers are never
    # read/hashed/copied, and opencode.json/jsonc bytes stay a private
    # precaution only when opencode is selected (never restored).
    $BackupTargets = @()
    foreach ($vt in $EffArr) { $BackupTargets += [string]$ContentPaths[$vt] }
    if ($EffArr -contains 'opencode') {
      $BackupTargets += (Join-Path $HomeBase '.config\opencode\opencode.json')
      $BackupTargets += (Join-Path $HomeBase '.config\opencode\opencode.jsonc')
    }

    if ($PreviewOnly) {
      # Preview requests carry the OUTPUT plan id (where this run writes the
      # plan). Apply requests carry an approved INPUT plan id instead; the two
      # are never confused: preview never consumes, apply never writes.
      if (($PlanPath -eq '') -and ($ReqPlanId -ne '')) {
        $PlanPath = Join-Path $AutoDir ("dashboard.global-plan-" + $ReqPlanId + ".json")
      }
      if (-not $PlanPath) { throw 'preview requires planPath.' }
      $PlanPath = Get-NormPathLocal $PlanPath
      if ((Split-Path $PlanPath -Parent) -cne (Get-NormPathLocal $AutoDir)) { throw 'plan must be directly inside automation root.' }
      if ((Split-Path $PlanPath -Leaf) -cnotmatch '^dashboard\.global-plan-[0-9a-f]{32}\.json$') { throw 'invalid plan filename.' }
      if ((Test-Path -LiteralPath $PlanPath) -and (Test-ReparseLocal $PlanPath)) { throw 'plan is a reparse point.' }
    }

    $PinnedConfigDir = ''
    $PinnedConfigArgv = @()
    $prevGithubToken = $env:GITHUB_TOKEN
    $prevGhToken = $env:GH_TOKEN
    $addedToken = $false
    try {
      if ($env:GITHUB_TOKEN) { $Secrets += $env:GITHUB_TOKEN }
      if ($env:GH_TOKEN) { $Secrets += $env:GH_TOKEN }
      if ((-not $env:GITHUB_TOKEN) -and (-not $env:GH_TOKEN)) {
        $prevEapGh = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
          $tok = (& $gh auth token 2>$null | Out-String).Trim()
          $tokCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEapGh }
        if (($null -eq $tokCode) -or ($tokCode -ne 0)) { throw 'GitHub auth failed (gh auth token).' }
        if (-not $tok) { throw 'GitHub auth returned empty token.' }
        $env:GITHUB_TOKEN = $tok
        $Secrets += $tok
        $addedToken = $true
      }

      Push-Location $PreviewDir
      try {
        if ((Invoke-Step 'install --update' $npx @('--yes', $Pkg, 'install', '--update')) -ne 0) {
          throw 'install --update failed.'
        }
        $script:GblCommit = Get-GlobalSourceCommit $PreviewDir

        # Plan-bound apply: re-verify approved inputs under the lock before touching home.
        # Preview runs only produce the output plan and never consume one.
        if (($ReqPlanId -ne '') -and (-not $PreviewOnly)) {
          $apFile = Join-Path $AutoDir ("dashboard.global-plan-" + $ReqPlanId + ".json")
          if ((-not (Test-ContainedLocal $apFile $AutoDir)) -or (-not (Test-Path -LiteralPath $apFile -PathType Leaf)) -or (Test-ReparseLocal $apFile)) { throw 'plan not found.' }
          if (((Get-Date) - (Get-Item -LiteralPath $apFile).LastWriteTime).TotalMinutes -gt 120) { throw 'plan expired. Recreate it from preview.' }
          Assert-GlobalPlanFileSize $apFile
          try { $script:GblApprovedPlan = Get-Content -LiteralPath $apFile -Raw -Encoding UTF8 | ConvertFrom-Json }
          catch { throw 'plan unreadable.' }
          $gateLive = Get-GlobalPlanLive $AutoDir $HomeBase $EffArr
          $gateChk = Test-GlobalPlanMatch $script:GblApprovedPlan $gateLive $EffArr
          if (-not $gateChk.ok) {
            Save-GlobalRunStatus 'failed' ([string]$gateChk.error) ''
            Write-Log (Redact('FAIL: plan inputs changed: ' + [string]$gateChk.error))
            return 1
          }
        }

        # rulesync re-reads the resolved base+local config for every CLI call,
        # so the pre-install check can be defeated by a change during install
        # or between steps. Pin the exact bytes generation will read:
        # rulesync merges rulesync.local.jsonc from the --config file's
        # directory, so both files are copied into one private dir under the
        # preview cwd (a --config path outside cwd is rejected as traversal)
        # and the copied bytes are checked again AFTER the copy. Every later
        # generate/check/dry-run passes this config, so later live edits cannot
        # reach the write path.
        if ($EffArr -contains 'claudecode') {
          $PinnedConfigDir = Join-Path $PreviewDir ('.config-pin-' + [System.Guid]::NewGuid().ToString('N'))
          if (-not (Test-ContainedLocal $PinnedConfigDir $PreviewDir)) { throw 'pinned config escaped preview root.' }
          New-Item -ItemType Directory -Force -Path $PinnedConfigDir | Out-Null
          if (Test-ReparseLocal $PinnedConfigDir) { throw 'pinned config is a reparse point.' }
          foreach ($cfgName in @('rulesync.jsonc', 'rulesync.local.jsonc')) {
            $cfgSrc = Join-Path $PreviewDir $cfgName
            if (Test-Path -LiteralPath $cfgSrc -PathType Leaf) {
              Copy-Item -LiteralPath $cfgSrc -Destination (Join-Path $PinnedConfigDir $cfgName) -Force
            }
          }
          if ($null -ne (Get-GlobalRulesyncLanguage $PinnedConfigDir)) {
            throw 'Claude Code cannot be synced while rulesync has a language setting: it also writes ~/.claude/settings.json, which is not previewed or backed up. Remove language from rulesync.jsonc/rulesync.local.jsonc, or deselect Claude Code.'
          }
          $PinnedConfigArgv = @('--config', (Join-Path $PinnedConfigDir 'rulesync.jsonc'))
        }

        # Preview: same fetch above, generate into an isolated GUID home, compare
        # with actual home bytes. Real home is never written here.
        if ($PreviewOnly) {
          $actualTexts = @{}
          $actualHashes = @{}
          $actualExists = @{}
          $actualTooLarge = @{}
          $actualReadFailed = @{}
          foreach ($t in $EffArr) {
            $ap = [string]$ContentPaths[$t]
            Global-AssertNoLinkChain $ap $HomeBase $t
            $txt = ''
            $ex = ((Test-Path -LiteralPath $ap -PathType Leaf) -and (-not (Test-ReparseLocal $ap)))
            $tooBig = $false
            $readFailed = $false
            $sameHash = $null
            if ($ex) {
              try {
                if ((Get-Item -LiteralPath $ap -Force -ErrorAction Stop).Length -gt 1048576) { $tooBig = $true }
                else {
                  $rtb = Global-ReadBoundedBytes $ap 1048576
                  if ([bool]$rtb.truncated) { $tooBig = $true }
                  else {
                    $rbytes = [byte[]]$rtb.bytes
                    $txt = [System.Text.Encoding]::UTF8.GetString($rbytes)
                    $sameHash = Global-HashBytesHex $rbytes
                  }
                }
              } catch { $readFailed = $true; $txt = ''; $sameHash = $null }
            }
            if ((-not $readFailed) -and (-not (Test-GlobalTextSizeOk $txt))) { $tooBig = $true; $txt = '' }
            if ($readFailed) { $tooBig = $false }
            $actualTexts[$t] = $txt
            $actualExists[$t] = [bool]$ex
            $actualTooLarge[$t] = [bool]$tooBig
            $actualReadFailed[$t] = [bool]$readFailed
            # Same-bytes hash: absent and unreadable stay null and distinct
            # via exists/readFailed (never a reopened Get-FileHash).
            if ($readFailed) { $actualHashes[$t] = $null }
            elseif ($tooBig) { $actualHashes[$t] = $null }
            elseif ($ex) { $actualHashes[$t] = $sameHash }
            else { $actualHashes[$t] = $null }
          }
          $iso = Join-Path $AutoDir ('preview-home-' + [System.Guid]::NewGuid().ToString('N'))
          if (-not (Test-ContainedLocal $iso $AutoDir)) { throw 'preview home escaped automation root.' }
          New-Item -ItemType Directory -Force -Path $iso | Out-Null
          if (Test-ReparseLocal $iso) { throw 'preview home is a reparse point.' }
          Global-AssertNoLinkChain $iso $AutoDir 'preview'
          $prevHomeDir = $env:HOME_DIR
          $env:HOME_DIR = $iso
          $genCode = 1
          $genTail = ''
          try {
            # Same pre-CLI guard as the real-home steps: install may have
            # swapped real parents after the initial check, and the isolated
            # home itself must stay rooted at the trusted AutoDir.
            Assert-GlobalCliParents 'preview generate --global'
            Global-AssertNoLinkChain $iso $AutoDir 'preview'
            $genArgv = @(Get-GlobalGenerateArgv $Targets '' $ShirubeVersion) + $PinnedConfigArgv
            Write-Log 'STEP: preview generate --global'
            $prevEap2 = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
              $genOut = & $npx @genArgv 2>&1 | Out-String
              $genCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $prevEap2 }
            if ($null -eq $genCode) { $genCode = 1 }
            Write-Log (Redact("EXIT=" + $genCode + ' preview generate --global' + "`n" + $genOut))
            $genTail = Get-RedactedTail $genOut
            # Post-generate guard: a swap DURING generate (even on exit 0) must
            # never become a success entry. Force the failed path below and skip
            # success publishing; the plan below contains only failed entries.
            try {
              Assert-GlobalCliParents 'preview generate --global (post)'
              Global-AssertNoLinkChain $iso $AutoDir 'preview'
            } catch {
              Write-Log (Redact('FAIL: parent changed after preview generate --global: ' + $_.Exception.Message))
              $genCode = 1
              $genTail = ('parent changed after preview generate; not a clean preview. ' + $genTail)
            }
            # Collect BEFORE the finally cleanup below deletes the isolated home.
            $entries = @()
            $failedPrev = 0
            $isoPaths = Get-GlobalContentPaths $iso
            foreach ($t in $EffArr) {
              $isoFile = [string]$isoPaths[$t]
              if ([bool]$actualReadFailed[$t]) {
                $failedPrev++
                $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $null; generatedHash = ''; generatedText = ''; currentText = ''; result = 'failed'; error = '現在の内容を確認できませんでした。' }
              }
              elseif ([bool]$actualTooLarge[$t]) {
                $failedPrev++
                $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $actualHashes[$t]; generatedHash = ''; generatedText = ''; currentText = ''; result = 'failed'; error = '現在のファイルが大きすぎるためプレビューできません。' }
              }
              elseif (($genCode -eq 0) -and (Test-Path -LiteralPath $isoFile -PathType Leaf) -and (-not (Test-ReparseLocal $isoFile))) {
                if (-not (Test-ContainedLocal $isoFile $iso)) { throw 'preview generated outside isolated home.' }
                Global-AssertNoLinkChain $isoFile $AutoDir ('preview-' + $t)
                if ((Get-Item -LiteralPath $isoFile -Force -ErrorAction Stop).Length -gt 1048576) {
                  $failedPrev++
                  $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $actualHashes[$t]; generatedHash = ''; generatedText = ''; currentText = [string]$actualTexts[$t]; result = 'failed'; error = '生成結果が大きすぎるため適用可能なプランにしません。' }
                }
                else {
                  $gtb = Global-ReadBoundedBytes $isoFile 1048576
                  if ([bool]$gtb.truncated) {
                    $failedPrev++
                    $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $actualHashes[$t]; generatedHash = ''; generatedText = ''; currentText = [string]$actualTexts[$t]; result = 'failed'; error = '生成結果が大きすぎるため適用可能なプランにしません。' }
                  }
                  else {
                    $gt = [System.Text.Encoding]::UTF8.GetString([byte[]]$gtb.bytes)
                    if (-not (Test-GlobalTextSizeOk $gt)) {
                      $failedPrev++
                      $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $actualHashes[$t]; generatedHash = ''; generatedText = ''; currentText = [string]$actualTexts[$t]; result = 'failed'; error = '生成結果が大きすぎるため適用可能なプランにしません。' }
                    }
                    else {
                      $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $actualHashes[$t]; generatedHash = (Global-HashBytesHex ([byte[]]$gtb.bytes)); generatedText = $gt; currentText = [string]$actualTexts[$t]; result = 'success'; error = '' }
                    }
                  }
                }
              }
              else {
                $failedPrev++
                $entries += @{ target = $t; path = [string]$ContentPaths[$t]; exists = [bool]$actualExists[$t]; currentHash = $actualHashes[$t]; generatedHash = ''; generatedText = ''; currentText = [string]$actualTexts[$t]; result = 'failed'; error = ('preview generated no output for target. ' + $genTail) }
              }
            }
          }
          finally {
            $env:HOME_DIR = $prevHomeDir
            if ($null -eq $prevHomeDir) { Remove-Item Env:HOME_DIR -ErrorAction SilentlyContinue }
            try {
              # Cleanup guard: re-inspect the AutoDir-rooted chain IMMEDIATELY
              # before the recursive delete. A linked AutoDir/parent must abort
              # the cleanup (fail-closed) instead of deleting through the link.
              Global-AssertNoLinkChain $iso $AutoDir 'preview'
              if ((Test-Path -LiteralPath $iso) -and (Test-ContainedLocal $iso $AutoDir) -and (-not (Test-ReparseLocal $iso))) {
                Remove-Item -LiteralPath $iso -Recurse -Force
              }
            } catch { Write-Log (Redact('preview cleanup skipped (unsafe root): ' + $_.Exception.Message)) }
          }
          $totalGenPrev = 0
          foreach ($enPrev in $entries) {
            try { if ([string]$enPrev.generatedText -ne '') { $totalGenPrev += ([string]$enPrev.generatedText).Length } } catch {}
          }
          if ($totalGenPrev -gt (Global-MaxPlanTextChars)) {
            foreach ($enPrev in $entries) {
              if ([string]$enPrev.result -ceq 'success') { $enPrev.result = 'failed'; $enPrev.error = 'プラン全体が大きすぎるため適用可能なプランにしません。'; $enPrev.generatedText = ''; $enPrev.generatedHash = '' }
            }
            $failedPrev = @($entries | Where-Object { [string]$_.result -cne 'success' }).Count
          }
          # Real JSON byte cap (current + generated + escaping): the fetch API
          # refuses files over 2MiB, so an overlarge success plan would apply
          # but never display. Serialize the exact publish payload first.
          $planObj = @{ schemaVersion = 1; createdAt = ([DateTime]::UtcNow.ToString('o')); sourceCommit = $script:GblCommit; targets = $EffArr; entries = $entries }
          $planJson = ConvertTo-Json -InputObject $planObj -Depth 12
          $planBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($planJson)
          if ($planBytes.Length -gt (Global-MaxPlanBytes)) {
            foreach ($enPrev in $entries) {
              if ([string]$enPrev.result -ceq 'success') { $enPrev.result = 'failed'; $enPrev.error = 'プラン全体が大きすぎるため適用可能なプランにしません。'; $enPrev.generatedText = ''; $enPrev.generatedHash = '' }
              $enPrev.currentText = ''
            }
            $failedPrev = @($entries | Where-Object { [string]$_.result -cne 'success' }).Count
            if ($failedPrev -eq 0) { $failedPrev = $entries.Count }
            $planObj = @{ schemaVersion = 1; createdAt = ([DateTime]::UtcNow.ToString('o')); sourceCommit = $script:GblCommit; targets = $EffArr; entries = $entries }
          }
          Write-GlobalPrivateJson $PlanPath $planObj $AutoDir
          if ($failedPrev -gt 0) { Write-Log ("FAIL: preview failed for " + $failedPrev + " target(s)."); return 1 }
          Write-Log 'OK: preview plan ready.'
          return 0
        }

        $check = Invoke-Step 'generate --global --check' $npx (@(Get-GlobalGenerateArgv $Targets 'check' $ShirubeVersion) + $PinnedConfigArgv)
        if ($check -eq 0) {
          Save-GlobalRunStatus 'success' '' ''
          Write-Log 'OK: no changes.'
          return 0
        }
        if ($check -ne 1) {
          Save-GlobalRunStatus 'failed' ("check failed with exit=" + $check + '. ' + $script:LastStepTail) ''
          throw ("check failed with exit=" + $check + '.')
        }
        # Exit 1 means drift OR error, so confirm with --dry-run before touching home.
        if ((Invoke-Step 'generate --global --dry-run' $npx (@(Get-GlobalGenerateArgv $Targets 'dry-run' $ShirubeVersion) + $PinnedConfigArgv)) -ne 0) {
          Save-GlobalRunStatus 'failed' ('dry-run failed; not a clean update candidate. ' + $script:LastStepTail) ''
          throw 'dry-run failed; not a clean update candidate.'
        }
        if ($DryRun) { Write-Log 'DRYRUN: updates available; skipped backup/generate.'; return 0 }

        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bdir = Join-Path $BackupRoot $ts
        $n = 0
        while (Test-Path $bdir) { $n++; $bdir = Join-Path $BackupRoot ($ts + '-' + $n) }
        if (-not (Test-ContainedLocal $bdir $BackupRoot)) { throw 'backup escaped root.' }
        if (Test-ReparseLocal $BackupRoot) { throw 'backup root is a reparse point.' }
        Global-AssertNoLinkChain $BackupRoot $AutoDir 'バックアップ先'
        if (Global-ParentReparse $BackupRoot $AutoDir) { throw 'バックアップ先の親フォルダがリンクになっています。' }
        New-Item -ItemType Directory -Force -Path $bdir | Out-Null
        if (Test-ReparseLocal $bdir) { throw 'backup is a reparse point.' }
        Global-AssertNoLinkChain $bdir $AutoDir 'バックアップ先'
        if (Global-Reparse $HomeBase) { throw '配置先を確認できませんでした。' }
        $backupId = Split-Path $bdir -Leaf
        # Trust anchors recorded BEFORE generate (never re-derived from backup files later).
        # Each copy/read is validated immediately: home side rooted HomeBase,
        # backup-dest side rooted AutoDir (intermediate backups/bdir can be swapped).
        $anchorFiles = @()
        $anchorHashes = @{}
        foreach ($f in $BackupTargets) {
          Global-AssertNoLinkChain $f $HomeBase 'backup'
          if (Test-Path $f) {
            if ((Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw '大きすぎるため待避できません。' }
            $rel = $f.Substring($HomeBase.Length).TrimStart('\', '/') -replace '[\\/:]', '_'
            $dstBk = Join-Path $bdir $rel
            if (-not (Test-ContainedLocal $dstBk $bdir)) { throw 'backup escaped root.' }
            Global-AssertNoLinkChain $dstBk $AutoDir 'バックアップ先'
            Copy-GlobalVerified $f $dstBk $HomeBase $AutoDir
            $hh = Global-FileHashHex $dstBk
            if ((-not $hh) -or ($hh -cne (Global-FileHashHex $f))) { throw 'backup verify hash mismatch.' }
            $anchorHashes[$rel] = $hh
            Write-Log ("BACKUP: " + $f)
          }
        }
        foreach ($t in $EffArr) {
          $anchP = [string]$ContentPaths[$t]
          $rel = ''
          try { $rel = $anchP.Substring($HomeBase.Length).TrimStart('\', '/') -replace '[\\/:]', '_' } catch {}
          $present = (Test-Path -LiteralPath $anchP -PathType Leaf)
          $anchorFiles += @{ target = $t; kind = 'agents'; rel = $rel; present = [bool]$present; hash = $anchorHashes[$rel] }
        }
        if ($EffArr -contains 'opencode') {
          foreach ($cf in @((Join-Path $HomeBase '.config\opencode\opencode.json'), (Join-Path $HomeBase '.config\opencode\opencode.jsonc'))) {
            if (Test-Path -LiteralPath $cf -PathType Leaf) {
              $rel = $cf.Substring($HomeBase.Length).TrimStart('\', '/') -replace '[\\/:]', '_'
              $anchorFiles += @{ target = 'opencode'; kind = 'config'; rel = $rel; present = $true; hash = $anchorHashes[$rel] }
            }
          }
        }
        Global-AssertNoLinkChain (Join-Path $bdir 'manifest.json') $AutoDir 'バックアップ先'
        Write-GlobalPrivateJson (Join-Path $bdir 'manifest.json') @{ schemaVersion = 1; scope = 'global'; createdAt = ([DateTime]::UtcNow.ToString('o')); homeBase = $HomeBase; targets = $EffArr; files = $anchorFiles } $AutoDir

        function Restore-GlobalRunBackup {
          try {
            # Rule restore covers AGENTS files only: opencode.json/jsonc bytes
            # stay a private precaution and are never written back.
            Global-AssertNoLinkChain $bdir $AutoDir 'バックアップ先'
            $agentsRels = @{}
            foreach ($t in $EffArr) {
              Global-AssertNoLinkChain ([string]$ContentPaths[$t]) $HomeBase $t
              try { $agentsRels[([string]$ContentPaths[$t]).Substring($HomeBase.Length).TrimStart('\', '/') -replace '[\\/:]', '_'] = $true } catch {}
            }
            foreach ($rel in @($anchorHashes.Keys)) {
              if (-not $agentsRels.ContainsKey($rel)) { continue }
              $dst = $null
              foreach ($bt in $BackupTargets) {
                $btRel = $bt.Substring($HomeBase.Length).TrimStart('\', '/') -replace '[\\/:]', '_'
                if ($btRel -ceq $rel) { $dst = $bt; break }
              }
              if ($null -eq $dst) { return ('unknown backup entry: ' + $rel) }
              $srcRb = Join-Path $bdir $rel
              if (-not (Test-ContainedLocal $srcRb $bdir)) { return ('巻戻し元を確認できません: ' + $rel) }
              try { Global-AssertNoLinkChain $srcRb $AutoDir 'バックアップ' } catch { return $_.Exception.Message }
              try { Global-AssertNoLinkChain $dst $HomeBase '巻戻し' } catch { return $_.Exception.Message }
              try { Copy-GlobalExpectedBytes $srcRb $dst ([string]$anchorHashes[$rel]) (Split-Path $dst -Leaf) $AutoDir $HomeBase } catch { return $_.Exception.Message }
            }
            # Files absent before generate but created by it are removed again.
            foreach ($ae in $anchorFiles) {
              if ((-not [bool]$ae.present) -and ([string]$ae.kind -ceq 'agents')) {
                $ap2 = [string]$ContentPaths[[string]$ae.target]
                try { Global-AssertNoLinkChain $ap2 $HomeBase '巻戻し' } catch { return $_.Exception.Message }
                try { Global-AssertNoLinkChain $ap2 $HomeBase '巻戻し' } catch { return $_.Exception.Message }
                if ((Test-Path -LiteralPath $ap2) -and (-not (Test-ReparseLocal $ap2))) { Remove-Item -LiteralPath $ap2 -Force }
                if (Test-Path -LiteralPath $ap2) { return ('unapproved file not removed: ' + [string]$ae.target) }
              }
            }
            return $null
          } catch { return $_.Exception.Message }
        }
        try {
          # global.md only (global-preview config); never --delete.
          if ((Invoke-Step 'generate --global' $npx (@(Get-GlobalGenerateArgv $Targets '' $ShirubeVersion) + $PinnedConfigArgv)) -ne 0) {
            throw 'generate --global failed.'
          }
          # Plan-bound apply: fresh output must equal the approved output.
          if ($null -ne $script:GblApprovedPlan) {
            foreach ($t in $EffArr) {
              $pj = @($script:GblApprovedPlan.entries | Where-Object { [string]$_.target -ceq $t })
              if (($pj.Count -ne 1) -or ([string]$pj[0].result -cne 'success')) { throw ($t + ': no approved plan output; refusing.') }
              Global-AssertNoLinkChain ([string]$ContentPaths[$t]) $HomeBase $t
              if ((Get-Item -LiteralPath ([string]$ContentPaths[$t]) -Force -ErrorAction Stop).Length -gt (Global-MaxContentBytes)) { throw ($t + ': generated output too large; refusing.') }
              $frb = Global-ReadBoundedBytes ([string]$ContentPaths[$t]) (Global-MaxContentBytes)
              if ([bool]$frb.truncated) { throw ($t + ': generated output too large; refusing.') }
              $freshT = [System.Text.Encoding]::UTF8.GetString([byte[]]$frb.bytes)
              if (-not (Test-GlobalTextSizeOk $freshT)) { throw ($t + ': generated output too large; refusing.') }
              if ($freshT -cne [string]$pj[0].generatedText) { throw ($t + ': generated output differs from the approved plan.') }
            }
          }
          if ((Invoke-Step 'final generate --global --check' $npx (@(Get-GlobalGenerateArgv $Targets 'check' $ShirubeVersion) + $PinnedConfigArgv)) -ne 0) {
            throw 'final check failed.'
          }
        }
        catch {
          $failMsg = $_.Exception.Message
          $rbErr = Restore-GlobalRunBackup
          if ($rbErr) {
            Save-GlobalRunStatus 'failed' ($failMsg + ' rollback also failed: ' + $rbErr) $backupId
            throw ($failMsg + ' rollback also failed: ' + $rbErr)
          }
          Save-GlobalRunStatus 'failed' ($failMsg + ' restored backup.') $backupId
          throw ($failMsg + ' restored backup.')
        }
        Save-GlobalRunStatus 'success' '' $backupId
        Write-Log 'OK: global rules updated.'
        return 0
      }
      finally {
        Pop-Location
        if ($PinnedConfigDir) {
          try {
            Global-AssertNoLinkChain $PinnedConfigDir $PreviewDir 'pinned config'
            if ((Test-Path -LiteralPath $PinnedConfigDir) -and (Test-ContainedLocal $PinnedConfigDir $PreviewDir) -and (-not (Test-ReparseLocal $PinnedConfigDir))) {
              Remove-Item -LiteralPath $PinnedConfigDir -Recurse -Force
            }
          } catch { Write-Log (Redact('pinned config cleanup skipped (unsafe root): ' + $_.Exception.Message)) }
        }
      }
    }
    finally {
      if ($addedToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
      elseif ($null -eq $prevGithubToken) { Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue }
      else { $env:GITHUB_TOKEN = $prevGithubToken }
      if ($null -eq $prevGhToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
      else { $env:GH_TOKEN = $prevGhToken }
    }
  }
  catch {
    $msg = Redact('FAIL: ' + $_.Exception.Message)
    # Post-target failures already saved a specific status above (flagged);
    # this fallback covers pre-target failures so they still surface in logs.
    if ($script:GblStatusSaved -or (-not $script:GblHaveTargets)) { Write-Log $msg; return 1 }
    try { Save-GlobalRunStatus 'failed' (Get-RedactedTail $_.Exception.Message) '' } catch {}
    Write-Log $msg
    return 1
  }
  finally { if ($lockStream) { $lockStream.Close() } }
}

# Dot-sourced by self-checks (no exit); executed directly by Task Scheduler.
if ($MyInvocation.InvocationName -ne '.') {
  $code = Invoke-GlobalSync -DryRun:$DryRun -ReportSkip:$ReportSkip -TargetNames $TargetNames -PreviewOnly:$PreviewOnly -PlanPath $PlanPath -RequestPath $RequestPath
  exit $code
}
