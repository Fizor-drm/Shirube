# Watch-Sync.ps1 - hidden monitor for dashboard sync (r5).
# Runs the fixed sync script with -ReportSkip and records the real child exit code bound to runID.
# No new deps, PS5.1 only. Never runs arbitrary commands: only Sync-ProjectRules.ps1
# (preferred, with fixed -ReportSkip) or Run-ProjectRules.vbs (legacy when ps1 missing) in AutoDir.
# Result file: dashboard.sync-<runID>.json (atomic write; existing -> File.Replace, new -> File.Move).
# r5: busy skip (exit 75) is recorded as skipped, not success. Periodic without flag still exits 0.
# r7: CWD乗っ取り防止のため固定absoluteのみ。裸fallbackなし。結果は私的ACLに限定。
# 選択同期・反映前プランは dashboard.request-<runID>.json で渡す (Sync が読む)。
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
# r7b: 結果tmpも新規作成時から私的ACLで作り、読める時間を避ける。PS5.1組込のみ。
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
  $ps1 = Join-Path $ad 'Sync-ProjectRules.ps1'
  $vbs = Join-Path $ad 'Run-ProjectRules.vbs'
  $usePs1 = ((Test-Path -LiteralPath $ps1) -and (-not (Get-Item -LiteralPath $ps1 -Force -ErrorAction SilentlyContinue).PSIsContainer))
  $useVbs = ((Test-Path -LiteralPath $vbs) -and (-not (Get-Item -LiteralPath $vbs -Force -ErrorAction SilentlyContinue).PSIsContainer))
  if ((-not $usePs1) -and (-not $useVbs)) { exit 2 }
  $w = Join-Path $env:SystemRoot 'System32\wscript.exe'
  if (-not (Test-Path -LiteralPath $w)) { exit 2 }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe)) { exit 2 }
  # wscript is windowed: call-operator does not report its exit code, so wait explicitly.
  $code = 1
  $reqArg = @()
  if ($RequestPath -and ($RequestPath.Trim() -ne '')) {
    try { $rq = [System.IO.Path]::GetFullPath($RequestPath) } catch { exit 2 }
    $sep2 = [System.IO.Path]::DirectorySeparatorChar
    $root2 = $ad
    if ($root2[$root2.Length - 1] -ne $sep2) { $root2 = $root2 + $sep2 }
    if (-not $rq.StartsWith($root2, [System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }
    if ((Split-Path $rq -Leaf) -cnotmatch '^dashboard\.request-[0-9a-f]{32}\.json$') { exit 2 }
    if (-not (Test-Path -LiteralPath $rq)) { exit 2 }
    $reqArg = @('-RequestPath', "`"$rq`"")
  }
  try {
    if ($usePs1) {
      $argv = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`"", '-ReportSkip') + $reqArg
      $p = Start-Process -FilePath $psExe -ArgumentList $argv -WindowStyle Hidden -Wait -PassThru
      $code = [int]$p.ExitCode
    }
    else {
      if ($reqArg.Count -gt 0) { exit 2 }
      $p = Start-Process -FilePath $w -ArgumentList '//B', '//Nologo', "$vbs" -WindowStyle Hidden -Wait -PassThru
      $code = [int]$p.ExitCode
    }
  } catch { $code = 1 }
  $rf = Join-Path $ad ("dashboard.sync-" + $RunId + ".json")
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $root = $ad
  if ($root[$root.Length - 1] -ne $sep) { $root = $root + $sep }
  if (-not $rf.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { exit 2 }
  $tmp = Join-Path $ad ("dashboard.sync-" + $RunId + ".tmp-" + [System.Guid]::NewGuid().ToString('N'))
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
      $bak = Join-Path $ad ("dashboard.sync-" + $RunId + ".bak-" + [System.Guid]::NewGuid().ToString('N'))
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
