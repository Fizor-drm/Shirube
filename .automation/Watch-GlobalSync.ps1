# Watch-GlobalSync.ps1 - hidden monitor for dashboard global sync.
# Runs the fixed global sync script with -ReportSkip and records the real child
# exit code bound to runID. No new deps, PS5.1 only. Never runs arbitrary
# commands: only Sync-GlobalRules.ps1 (preferred, with fixed -ReportSkip) or
# Run-GlobalRules.vbs (legacy when ps1 missing) in AutoDir.
# Result file: dashboard.global-sync-<runID>.json (atomic write; existing ->
# File.Replace, new -> File.Move).
# Busy skip (exit 75) is recorded as skipped, not success. Periodic without flag
# still exits 0. Fixed absolute exes only, no bare fallback. Private ACL results.
# Selection/preview plans travel in dashboard.global-request-<runID>.json.
param([string]$AutoDir = '', [string]$RunId = '', [string]$RequestPath = '')
$ErrorActionPreference = 'Stop'
function Set-PrivateFileAclLocal([string]$File) {
  $acl = Get-Acl -LiteralPath $File
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($r in @($acl.Access)) { try { [void]$acl.RemoveAccessRule($r) } catch {} }
  $sids = @()
  try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' } catch {}
  try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544' } catch {}
  foreach ($sid in @($sids | Where-Object { $_ -ne $null })) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
    [void]$acl.AddAccessRule($rule)
  }
  Set-Acl -LiteralPath $File -AclObject $acl
}
function Test-PrivateFileAclLocal([string]$File) {
  try {
    $acl = Get-Acl -LiteralPath $File
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $exp = @{}
    try { $exp[[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value] = $true } catch {}
    $exp['S-1-5-18'] = $true; $exp['S-1-5-32-544'] = $true
    foreach ($r in @($acl.Access)) {
      try { $v = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return $false }
      if (-not $exp.ContainsKey($v)) { return $false }
    }
    return $true
  } catch { return $false }
}
function Write-PrivateTextLocal([string]$File, [string]$Content) {
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($Content)
  if (Test-Path -LiteralPath $File) {
    if (-not (Test-PrivateFileAclLocal $File)) { Set-PrivateFileAclLocal $File }
    $fs = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
  }
  else {
    $sec = New-Object System.Security.AccessControl.FileSecurity
    $sec.SetAccessRuleProtection($true, $false)
    $sids = @()
    try { $sids += [System.Security.Principal.WindowsIdentity]::GetCurrent().User } catch {}
    try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' } catch {}
    try { $sids += New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544' } catch {}
    foreach ($sid in @($sids | Where-Object { $_ -ne $null })) {
      $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
      $sec.AddAccessRule($rule)
    }
    try {
      $fs = [System.IO.File]::Create($File, 4096, [System.IO.FileOptions]::None, $sec)
      try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    }
    catch [System.IO.IOException] {
      if (-not (Test-PrivateFileAclLocal $File)) { Set-PrivateFileAclLocal $File }
      $fs2 = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
      try { $fs2.Write($bytes, 0, $bytes.Length) } finally { $fs2.Close() }
    }
  }
}
$ErrorActionPreference = 'Stop'
try {
  if ($RunId -cnotmatch '^[0-9a-f]{32}$') { exit 2 }
  if (-not (Test-Path -LiteralPath $AutoDir -PathType Container)) { exit 2 }
  try { $ad = [System.IO.Path]::GetFullPath($AutoDir) } catch { exit 2 }
  $ps1 = Join-Path $ad 'Sync-GlobalRules.ps1'
  $vbs = Join-Path $ad 'Run-GlobalRules.vbs'
  $usePs1 = ((Test-Path -LiteralPath $ps1) -and (-not (Get-Item -LiteralPath $ps1 -Force -ErrorAction SilentlyContinue).PSIsContainer))
  $useVbs = ((Test-Path -LiteralPath $vbs) -and (-not (Get-Item -LiteralPath $vbs -Force -ErrorAction SilentlyContinue).PSIsContainer))
  if ((-not $usePs1) -and (-not $useVbs)) { exit 2 }
  $w = Join-Path $env:SystemRoot 'System32\wscript.exe'
  if (-not (Test-Path -LiteralPath $w)) { exit 2 }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe)) { exit 2 }
  $code = 1
  $reqArg = @()
  if ($RequestPath -and ($RequestPath.Trim() -ne '')) {
    try { $rq = [System.IO.Path]::GetFullPath($RequestPath) } catch { exit 2 }
    $sep2 = [System.IO.Path]::DirectorySeparatorChar
    $root2 = $ad
    if ($root2[$root2.Length - 1] -ne $sep2) { $root2 = $root2 + $sep2 }
    if (-not $rq.StartsWith($root2, [System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }
    if ((Split-Path $rq -Leaf) -cnotmatch '^dashboard\.global-request-[0-9a-f]{32}\.json$') { exit 2 }
    if (-not (Test-Path -LiteralPath $rq)) { exit 2 }
    $reqArg = @('-RequestPath', "`"$rq`"")
  }
  $isPreview = $false
  if ($reqArg.Count -gt 0) {
    try {
      $rqObj = Get-Content -LiteralPath $rq -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($rqObj.PSObject.Properties['previewOnly'] -and ([bool]$rqObj.previewOnly)) { $isPreview = $true }
    } catch {}
  }
  try {
    if ($usePs1) {
      # Preview runs write only the plan file: pass -PreviewOnly with the plan path.
      $prevArg = @()
      $planArg = @()
      if ($isPreview) {
        $planId = ''
        try { $planId = ([string]$rqObj.planId).Trim() } catch {}
        if ($planId -cnotmatch '^[0-9a-f]{32}$') { exit 2 }
        $planFile = Join-Path $ad ("dashboard.global-plan-" + $planId + ".json")
        $sep3 = [System.IO.Path]::DirectorySeparatorChar
        $root3 = $ad
        if ($root3[$root3.Length - 1] -ne $sep3) { $root3 = $root3 + $sep3 }
        if (-not $planFile.StartsWith($root3, [System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }
        $prevArg = @('-PreviewOnly')
        $planArg = @('-PlanPath', "`"$planFile`"")
      }
      $argv = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`"", '-ReportSkip') + $reqArg + $prevArg + $planArg
      $p = Start-Process -FilePath $psExe -ArgumentList $argv -WindowStyle Hidden -Wait -PassThru
      $code = [int]$p.ExitCode
    }
    else {
      if ($reqArg.Count -gt 0) { exit 2 }
      $p = Start-Process -FilePath $w -ArgumentList '//B', '//Nologo', "$vbs" -WindowStyle Hidden -Wait -PassThru
      $code = [int]$p.ExitCode
    }
  } catch { $code = 1 }
  $rf = Join-Path $ad ("dashboard.global-sync-" + $RunId + ".json")
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $root = $ad
  if ($root[$root.Length - 1] -ne $sep) { $root = $root + $sep }
  if (-not $rf.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }
  $tmp = Join-Path $ad ("dashboard.global-sync-" + $RunId + ".tmp-" + [System.Guid]::NewGuid().ToString('N'))
  if (-not $tmp.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }
  $at = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $res = 'failed'
  if ([int]$code -eq 0) { $res = 'success' }
  elseif ([int]$code -eq 75) { $res = 'skipped' }
  $o = @{ runId = $RunId; exitCode = [int]$code; finishedAt = $at; result = $res }
  $j = ConvertTo-Json -InputObject $o -Depth 3 -Compress
  Write-PrivateTextLocal $tmp $j
  try {
    if (Test-Path -LiteralPath $rf) {
      $bak = Join-Path $ad ("dashboard.global-sync-" + $RunId + ".bak-" + [System.Guid]::NewGuid().ToString('N'))
      [System.IO.File]::Replace($tmp, $rf, $bak) | Out-Null
      try { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue } catch {}
      try { Set-PrivateFileAclLocal $rf } catch {}
    }
    else { [System.IO.File]::Move($tmp, $rf) | Out-Null; try { Set-PrivateFileAclLocal $rf } catch {} }
  } catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    exit 1
  }
  exit 0
} catch { exit 1 }
