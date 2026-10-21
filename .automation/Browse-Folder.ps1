# Browse-Folder.ps1 - visible folder picker helper for Dashboard-Server.ps1 (dev source).
# STA Explorer-type CommonItemDialog (IFileDialog FOS_PICKFOLDERS) only. No new deps. Never runs arbitrary commands.
# CLSID is FileOpenDialog, queried as base IFileDialog (single-select GetResult is enough;
# multi-select GetResults would need IFileOpenDialog IID d57c7288-d4ad-4768-be02-9d969532d960
# with the full base vtable redeclared; .NET COM interop has no interface inheritance slicing).
# Title/OK label are set explicitly (SetTitle/SetOkButtonLabel return S_OK pre-Show).
# Invoked once per browse request with fixed -AutoDir + -BrowseId (+ optional -InitialPath hint).
# Writes dashboard.browse-<browseId>.json atomically (selected|cancelled). Cancel wins:
# if the result file already exists (server cancel), exit 0 without overwriting.
# Cancel/close dialog is not an error: status cancelled, exit 0, no registration.
param([string]$AutoDir = '', [string]$BrowseId = '', [string]$InitialPath = '', [string]$OwnerHwnd = '', [string]$OwnerPid = '', [string]$OwnerStart = '')
$ErrorActionPreference = 'Stop'
function Test-ContainedLocal([string]$Candidate, [string]$Root) {
  try {
    $c = [System.IO.Path]::GetFullPath($Candidate); $r = [System.IO.Path]::GetFullPath($Root)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($r[$r.Length - 1] -ne $sep) { $r = $r + $sep }
    return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}
function Set-PrivateAclLocal([string]$File) {
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
function Test-PrivateAclLocal([string]$File) {
  try {
    $acl = Get-Acl -LiteralPath $File
    if (-not $acl.AreAccessRulesProtected) { return $false }
    return $true
  } catch { return $false }
}
# UTF8 with BOM private write (BOM-less corrupts Japanese paths on PS5.1 CP932). PS5.1 built-ins only.
function Write-PrivateTextUtf8([string]$File, [string]$Content) {
  $utf8bom = New-Object System.Text.UTF8Encoding($true)
  $bytes = $utf8bom.GetPreamble() + $utf8bom.GetBytes($Content)
  if (Test-Path -LiteralPath $File) {
    if (-not (Test-PrivateAclLocal $File)) { Set-PrivateAclLocal $File }
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
      if (-not (Test-PrivateAclLocal $File)) { Set-PrivateAclLocal $File }
      $fs2 = New-Object System.IO.FileStream($File, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
      try { $fs2.Write($bytes, 0, $bytes.Length) } finally { $fs2.Close() }
    }
  }
}
try {
  if ($BrowseId -cnotmatch '^[0-9a-f]{32}$') { exit 2 }
  if (-not (Test-Path -LiteralPath $AutoDir -PathType Container)) { exit 2 }
  try { $ad = [System.IO.Path]::GetFullPath($AutoDir) } catch { exit 2 }
  $rf = Join-Path $ad ("dashboard.browse-" + $BrowseId + ".json")
  if (-not (Test-ContainedLocal $rf $ad)) { exit 2 }
  # Cancel wins: server already recorded cancel, keep it.
  if (Test-Path -LiteralPath $rf) { exit 0 }
  # Explorer-type standard dialog only (COM interop, PS5.1 built-in AddType).
  # No WinForms fallback: AddType/COM failure is an honest error (exit 1).
  # Must run on STA (server launches with -STA); MTA Show fails honestly.
  # All COM interface calls stay inside C# (PS late-binding cannot dispatch
  # IUnknown-only methods on __ComObject); PS only calls static helpers.
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport]
[Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItem {
  void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
  void GetParent(out IShellItem ppsi);
  void GetDisplayName(uint sigdnName, out IntPtr ppszName);
  void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
  void Compare(IShellItem psi, uint hint, out int piOrder);
}
[ComImport]
[Guid("42F85136-DB7E-439C-85F1-E4075D135FC8")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IFileDialog {
  // Exact SDK order: ShObjIdl_core.h IFileDialog (Show is inherited IModalWindow).
  [PreserveSig] int Show(IntPtr parent);
  [PreserveSig] int SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
  [PreserveSig] int SetFileTypeIndex(uint iFileType);
  [PreserveSig] int GetFileTypeIndex(out uint piFileType);
  [PreserveSig] int Advise(IntPtr pfde, out uint pdwCookie);
  [PreserveSig] int Unadvise(uint dwCookie);
  [PreserveSig] int SetOptions(uint fos);
  [PreserveSig] int GetOptions(out uint pfos);
  [PreserveSig] int SetDefaultFolder(IShellItem psi);
  [PreserveSig] int SetFolder(IShellItem psi);
  [PreserveSig] int GetFolder(out IShellItem ppsi);
  [PreserveSig] int GetCurrentSelection(out IShellItem ppsi);
  [PreserveSig] int SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
  [PreserveSig] int GetFileName(out IntPtr pszName);
  [PreserveSig] int SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
  [PreserveSig] int SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
  [PreserveSig] int SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
  [PreserveSig] int GetResult(out IShellItem ppsi);
  [PreserveSig] int AddPlace(IShellItem psi, int fdap);
  [PreserveSig] int SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
  [PreserveSig] int Close(int hr);
  [PreserveSig] int SetClientGuid(ref Guid guid);
  [PreserveSig] int ClearClientData();
  [PreserveSig] int SetFilter(IntPtr pFilter);
}
public static class FolderPickerNative {
  public const uint FOS_PICKFOLDERS = 0x20;
  public const uint FOS_FORCEFILESYSTEM = 0x40;
  public const uint SIGDN_FILESYSPATH = 0x80058000;
  public const int S_OK = 0;
  public const int ERROR_CANCELLED = unchecked((int)0x800704C7);
  private static readonly Guid CLSID_FileOpenDialog = new Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7");
  private static readonly Guid IID_IShellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
  private static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);
  [DllImport("ole32.dll")]
  private static extern void CoTaskMemFree(IntPtr pv);
  // Owner/foreground is stock user32 only (no new deps). Show(owner) is the
  // z-order basis; restore calls are best-effort (OS may refuse foreground).
  // No topmost forcing, no unrelated focus steal: only helper/owner foreground restores.
  [DllImport("user32.dll")]
  private static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]
  private static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  private static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")]
  private static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  private static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll", SetLastError=true)]
  private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  // Trust boundary: owner strings come from the server command line (server-side
  // GetForegroundWindow + PID/start capture), never from browser JSON.
  // HWND positive 64-bit range checked (x86 int.MaxValue intentional, x64 long.MaxValue);
  // PID positive int checked; non-numeric/zero/negative/overflow all fall back to Zero.
  public static long ParseOwnerHwndForTest(string s) {
    if (s == null) { return 0; }
    s = s.Trim();
    if (s == "") { return 0; }
    long v = 0;
    if (!long.TryParse(s, out v)) { return 0; }
    if (v <= 0) { return 0; }
    try {
      long max = (IntPtr.Size == 4) ? (long)int.MaxValue : (long)long.MaxValue;
      if (v > max) { return 0; }
    } catch { return 0; }
    return v;
  }
  public static long ParseOwnerPidForTest(string s) {
    if (s == null) { return 0; }
    s = s.Trim();
    if (s == "") { return 0; }
    long v = 0;
    if (!long.TryParse(s, out v)) { return 0; }
    if (v <= 0) { return 0; }
    if (v > (long)int.MaxValue) { return 0; }
    return v;
  }
  public static int GetWindowPidForTest(IntPtr h) {
    try {
      if (h == IntPtr.Zero) { return 0; }
      uint pid = 0;
      GetWindowThreadProcessId(h, out pid);
      if (pid == 0) { return 0; }
      if (pid > (uint)int.MaxValue) { return 0; }
      return (int)pid;
    } catch { return 0; }
  }
  public static string GetProcessStartTimeForTest(int pid) {
    try {
      if (pid <= 0) { return ""; }
      using (System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById(pid)) {
        try { return p.StartTime.ToString("o"); } catch { return ""; }
      }
    } catch { return ""; }
  }
  // Live-window check on the helper STA thread: IsWindow + visible. The helper
  // runs on the same interactive desktop as the server/browser, so a visible
  // live top-level window is usable; anything else falls back to Zero (safe).
  public static bool IsValidOwnerForTest(IntPtr h) {
    try {
      if (h == IntPtr.Zero) { return false; }
      if (!IsWindow(h)) { return false; }
      if (!IsWindowVisible(h)) { return false; }
      return true;
    } catch { return false; }
  }
  // Identity: HWND reuse / PID reuse reject via live+visible + PID (+start when available).
  // expectedPid<=0 keeps old live+visible behavior (safe fallback path).
  public static bool IsOwnerIdentityMatchForTest(IntPtr h, long expectedPid, string expectedStart) {
    try {
      if (h == IntPtr.Zero) { return false; }
      if (!IsValidOwnerForTest(h)) { return false; }
      if (expectedPid <= 0) { return true; }
      int curPid = GetWindowPidForTest(h);
      if (curPid <= 0) { return false; }
      if (curPid != (int)expectedPid) { return false; }
      if (string.IsNullOrEmpty(expectedStart)) { return true; }
      string curStart = GetProcessStartTimeForTest(curPid);
      if (string.IsNullOrEmpty(curStart)) { return false; }
      try {
        if (curStart.Equals(expectedStart, StringComparison.Ordinal)) { return true; }
        DateTime a; DateTime b;
        if (DateTime.TryParse(curStart, out a) && DateTime.TryParse(expectedStart, out b)) { return a == b; }
        return false;
      } catch { return false; }
    } catch { return false; }
  }
  // Restore gate (pure, testable): only the helper dialog (own PID) or the exact
  // owner HWND foreground restores. Same-PID different-HWND never restores
  // (another tab/window of the owner process must not steal focus).
  // Unrelated app foreground skips (no focus steal).
  public static bool ShouldRestoreForTest(long fgHwnd, long ownerHwnd, int fgPid, int ownerPid, int helperPid) {
    try {
      if (ownerHwnd <= 0) { return false; }
      if (fgHwnd == ownerHwnd) { return true; }
      if (fgPid <= 0 || ownerPid <= 0 || helperPid <= 0) { return false; }
      if (fgPid == helperPid) { return true; }
      return false;
    } catch { return false; }
  }
  public static long GetForegroundWindowForTest() {
    try { return GetForegroundWindow().ToInt64(); } catch { return 0; }
  }
  private static IntPtr NormalizeOwner(IntPtr hint) {
    try { if (IsValidOwnerForTest(hint)) { return hint; } } catch {}
    return IntPtr.Zero;
  }
  private static IntPtr NormalizeOwnerWithIdentity(IntPtr hint, long expectedPid, string expectedStart) {
    try {
      if (!IsOwnerIdentityMatchForTest(hint, expectedPid, expectedStart)) { return IntPtr.Zero; }
      return hint;
    } catch { return IntPtr.Zero; }
  }
  private static void RestoreOwnerBestEffort(IntPtr owner) {
    try { RestoreOwnerBestEffort(owner, 0, null); } catch {}
  }
  private static void RestoreOwnerBestEffort(IntPtr owner, long expectedPid, string expectedStart) {
    try {
      if (owner == IntPtr.Zero) { return; }
      if (!IsOwnerIdentityMatchForTest(owner, expectedPid, expectedStart)) { return; }
      IntPtr fg = IntPtr.Zero;
      try { fg = GetForegroundWindow(); } catch { return; }
      if (fg == owner) {
        try { BringWindowToTop(owner); } catch {}
        try { SetForegroundWindow(owner); } catch {}
        return;
      }
      int fgPid = 0; int ownerPid = 0; int helperPid = 0;
      try { fgPid = GetWindowPidForTest(fg); } catch {}
      try { ownerPid = GetWindowPidForTest(owner); } catch {}
      try { helperPid = System.Diagnostics.Process.GetCurrentProcess().Id; } catch {}
      bool should = false;
      try { should = ShouldRestoreForTest(fg.ToInt64(), owner.ToInt64(), fgPid, ownerPid, helperPid); } catch { should = false; }
      if (!should) { return; }
      try { BringWindowToTop(owner); } catch {}
      try { SetForegroundWindow(owner); } catch {}
    } catch {}
  }
  private static void CheckHr(int hr, string what) {
    if (hr != S_OK) { throw new InvalidOperationException(what + " failed HRESULT=" + hr); }
  }
  private static IFileDialog CreateDialog() {
    Type t = Type.GetTypeFromCLSID(CLSID_FileOpenDialog);
    return (IFileDialog)Activator.CreateInstance(t);
  }
  private static IShellItem CreateItemFromParsingName(string path) {
    Guid iid = IID_IShellItem;
    IShellItem item;
    SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item);
    return item;
  }
  private static string GetFileSystemPath(IShellItem item) {
    IntPtr p = IntPtr.Zero;
    try {
      item.GetDisplayName(SIGDN_FILESYSPATH, out p);
      if (p == IntPtr.Zero) { throw new InvalidOperationException("no filesystem path"); }
      return Marshal.PtrToStringUni(p);
    } finally {
      if (p != IntPtr.Zero) { CoTaskMemFree(p); }
    }
  }
  // Verified on real PS5.1/COM (S_OK): GetOptions/SetOptions/SetTitle/
  // SetOkButtonLabel/SetFolder/GetFolder all succeed pre-Show (no popup).
  // GetCurrentSelection pre-Show returns an error HRESULT (no selection yet);
  // calling it only proves the slot dispatches without crashing.
  private static void ApplyFolderOptions(IFileDialog dlg) {
    uint opts = 0;
    CheckHr(dlg.GetOptions(out opts), "GetOptions");
    CheckHr(dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM), "SetOptions");
    CheckHr(dlg.SetTitle("登録するフォルダを選択してください"), "SetTitle");
    CheckHr(dlg.SetOkButtonLabel("選択する"), "SetOkButtonLabel");
  }
  public static uint GetPickerOptionsForTest() {
    IFileDialog dlg = null;
    try {
      dlg = CreateDialog();
      ApplyFolderOptions(dlg);
      uint opts = 0;
      CheckHr(dlg.GetOptions(out opts), "GetOptions");
      return opts;
    } finally {
      if (dlg != null) { try { Marshal.ReleaseComObject(dlg); } catch {} }
    }
  }
  // Real COM vtable round-trip without Show popup: SetTitle/SetFolder/GetFolder
  // must return S_OK and GetFolder must echo the SetFolder path. Proves the
  // declared vtable order matches ShObjIdl_core.h (a shifted slot would call
  // the wrong method and fail here). Show popup itself is not tested headless.
  public static string VerifyVtableForTest(string dir) {
    IFileDialog dlg = null;
    IShellItem init = null;
    try {
      dlg = CreateDialog();
      ApplyFolderOptions(dlg);
      init = CreateItemFromParsingName(dir);
      CheckHr(dlg.SetFolder(init), "SetFolder");
      IShellItem got = null;
      try {
        CheckHr(dlg.GetFolder(out got), "GetFolder");
        return GetFileSystemPath(got);
      } finally {
        if (got != null) { try { Marshal.ReleaseComObject(got); } catch {} }
      }
    } finally {
      if (init != null) { try { Marshal.ReleaseComObject(init); } catch {} }
      if (dlg != null) { try { Marshal.ReleaseComObject(dlg); } catch {} }
    }
  }
  public static string ResolveFileSystemPath(string path) {
    IShellItem item = null;
    try {
      item = CreateItemFromParsingName(path);
      return GetFileSystemPath(item);
    } finally {
      if (item != null) { try { Marshal.ReleaseComObject(item); } catch {} }
    }
  }
  public static int ShowFolderPicker(string initialPath, out string pickedPath) {
    return ShowFolderPickerWithOwner(initialPath, IntPtr.Zero, out pickedPath);
  }
  public static int ShowFolderPickerWithOwner(string initialPath, IntPtr ownerHint, out string pickedPath) {
    return ShowFolderPickerWithOwnerIdentity(initialPath, ownerHint, 0, null, out pickedPath);
  }
  public static int ShowFolderPickerWithOwnerIdentity(string initialPath, IntPtr ownerHint, long expectedPid, string expectedStart, out string pickedPath) {
    pickedPath = null;
    IFileDialog dlg = null;
    IShellItem res = null;
    IntPtr owner = IntPtr.Zero;
    try { owner = NormalizeOwnerWithIdentity(ownerHint, expectedPid, expectedStart); } catch { owner = IntPtr.Zero; }
    try {
      dlg = CreateDialog();
      ApplyFolderOptions(dlg);
      if (initialPath != null && initialPath.Trim() != "") {
        try {
          string full = System.IO.Path.GetFullPath(initialPath.Trim());
          if (System.IO.Directory.Exists(full)) {
            IShellItem init = null;
            try { init = CreateItemFromParsingName(full); CheckHr(dlg.SetFolder(init), "SetFolder"); }
            catch {}
            finally { if (init != null) { try { Marshal.ReleaseComObject(init); } catch {} } }
          }
        } catch {}
      }
      int hr = dlg.Show(owner);
      try { RestoreOwnerBestEffort(owner, expectedPid, expectedStart); } catch {}
      if (hr == S_OK) {
        // P2: S_OK must yield a real path. Empty/parse failure is exit 1,
        // never cancelled. Only Show hr 0x800704C7 is cancel. No swallowing.
        CheckHr(dlg.GetResult(out res), "GetResult");
        string s = GetFileSystemPath(res);
        if (s == null || s.Trim() == "") { throw new InvalidOperationException("picker returned empty path"); }
        pickedPath = System.IO.Path.GetFullPath(s.Trim());
      }
      return hr;
    } finally {
      if (res != null) { try { Marshal.ReleaseComObject(res); } catch {} }
      if (dlg != null) { try { Marshal.ReleaseComObject(dlg); } catch {} }
    }
  }
}
'@
  $picked = $null
  $hintArg = ''
  if ($InitialPath -and ($InitialPath.Trim() -ne '')) {
    try {
      $hintFull = [System.IO.Path]::GetFullPath($InitialPath.Trim())
      if ((Test-Path -LiteralPath $hintFull -PathType Container)) { $hintArg = $hintFull }
    } catch {}
  }
  $selPath = $null
  # Owner trust boundary: $OwnerHwnd/$OwnerPid/$OwnerStart are server-captured command-line
  # data only (never browser JSON). HWND positive 64-bit validated, PID positive int
  # validated, live+visible+PID/start identity checked on the STA thread (HWND/PID reuse
  # reject); anything else falls back to Zero (safe, current parentless behavior).
  # Restore is conditional: only helper/owner foreground restores, unrelated skips.
  [IntPtr]$ownerPtr = [IntPtr]::Zero
  [long]$ownerPidVal = 0
  [string]$ownerStartVal = ''
  try { try { $ownerStartVal = [string]$OwnerStart } catch { $ownerStartVal = '' } } catch { $ownerStartVal = '' }
  try {
    [long]$ownerLong = [FolderPickerNative]::ParseOwnerHwndForTest($OwnerHwnd)
    try { $ownerPidVal = [FolderPickerNative]::ParseOwnerPidForTest($OwnerPid) } catch { $ownerPidVal = 0 }
    if ($ownerLong -gt 0) {
      try { $ownerPtr = New-Object System.IntPtr($ownerLong) } catch { $ownerPtr = [IntPtr]::Zero }
      try { if (-not [FolderPickerNative]::IsOwnerIdentityMatchForTest($ownerPtr, $ownerPidVal, $ownerStartVal)) { $ownerPtr = [IntPtr]::Zero } } catch { $ownerPtr = [IntPtr]::Zero }
    } else { $ownerPidVal = 0; $ownerStartVal = '' }
    if ($ownerPtr -eq [IntPtr]::Zero) { $ownerPidVal = 0; $ownerStartVal = '' }
  } catch { $ownerPtr = [IntPtr]::Zero; $ownerPidVal = 0; $ownerStartVal = '' }
  [int]$hr = 0
  # r3: no retry. A 438/COM throw must stay an honest outer exit 1; a PID/start-less
  # re-Show would drop identity and pop a second dialog. Owner-invalid 0 fallback
  # stays at the first native normalization only (above + NormalizeOwnerWithIdentity).
  if ($ownerPidVal -gt 0) { $hr = [FolderPickerNative]::ShowFolderPickerWithOwnerIdentity($hintArg, $ownerPtr, $ownerPidVal, $ownerStartVal, [ref]$selPath) }
  else { $hr = [FolderPickerNative]::ShowFolderPickerWithOwner($hintArg, $ownerPtr, [ref]$selPath) }
  # P2: cancel is Show hr 0x800704C7 only. S_OK with empty path is failure (exit 1).
  if ($hr -eq 0) {
    if ([string]::IsNullOrWhiteSpace($selPath)) { throw 'picker returned empty path.' }
    $picked = $selPath
  }
  elseif ($hr -eq [FolderPickerNative]::ERROR_CANCELLED) {
    # 0x800704C7 ERROR_CANCELLED: user cancel/close is cancelled, exit 0.
    $picked = $null
  } else {
    throw ('picker Show failed HRESULT=' + $hr)
  }
  # Late cancel wins: do not overwrite a server-cancelled result.
  if (Test-Path -LiteralPath $rf) { exit 0 }
  $at = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  if ($picked) { $o = @{ browseId = $BrowseId; status = 'selected'; path = $picked; finishedAt = $at } }
  else { $o = @{ browseId = $BrowseId; status = 'cancelled'; finishedAt = $at } }
  $j = ConvertTo-Json -InputObject $o -Depth 3 -Compress
  $tmp = Join-Path $ad ("dashboard.browse-" + $BrowseId + ".tmp-" + [System.Guid]::NewGuid().ToString('N'))
  if (-not (Test-ContainedLocal $tmp $ad)) { exit 2 }
  Write-PrivateTextUtf8 $tmp $j
  try {
    if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    else { [System.IO.File]::Move($tmp, $rf) | Out-Null; try { Set-PrivateAclLocal $rf } catch {} }
  } catch {
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    exit 1
  }
  exit 0
} catch { exit 1 }
