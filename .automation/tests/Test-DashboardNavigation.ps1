# Test-DashboardNavigation.ps1 - bounded screen-switch checks for the dashboard page.
# Static checks read the served HTML/JS source; the node harness runs the real routing
# code against a small DOM stub (no server start, no writes outside temp).
$ErrorActionPreference = 'Stop'
$initCwd = (Get-Location).Path
$failures = @()
function Assert([bool]$Cond, [string]$Name) {
  if ($Cond) { Write-Host ("PASS: " + $Name) }
  else { Write-Host ("FAIL: " + $Name); $script:failures += $Name }
}
$devAuto = Split-Path -Parent $PSScriptRoot
$srvPath = Join-Path $devAuto 'Dashboard-Server.ps1'
$srvTxt = Get-Content -LiteralPath $srvPath -Raw
$screenIds = @('top', 'projects', 'global', 'extensions', 'rules', 'backups', 'local', 'logs', 'settings')
$legacy = @{ register = 'projects'; status = 'projects'; gsettings = 'global'; help = 'settings' }

try {
  # --- static: both navigations reach the same nine screens (desktop sidebar / narrow topnav)
  $aside = [regex]::Match($srvTxt, '(?s)<aside>.*?</aside>')
  $topnav = [regex]::Match($srvTxt, '(?s)<nav class="topnav".*?</nav>')
  Assert ($aside.Success -and $topnav.Success) 'NAV both navigations present'
  $asideLinks = [regex]::Matches($aside.Value, 'href="#([a-z]+)"')
  $topLinks = [regex]::Matches($topnav.Value, 'href="#([a-z]+)"')
  $asideIds = @($asideLinks | ForEach-Object { $_.Groups[1].Value })
  $topIds = @($topLinks | ForEach-Object { $_.Groups[1].Value })
  Assert (($asideIds.Count -eq 9) -and ($topIds.Count -eq 9)) 'NAV each navigation has exactly nine links'
  Assert ((@($asideIds | Sort-Object) -join ',') -eq ((@($screenIds) | Sort-Object) -join ',')) 'NAV desktop sidebar reaches all nine screens'
  Assert ((@($topIds | Sort-Object) -join ',') -eq ((@($screenIds) | Sort-Object) -join ',')) 'NAV narrow topnav reaches all nine screens'
  Assert ((@($asideIds) -join ',') -eq (@($topIds) -join ',')) 'NAV both navigations point at the same screens in the same order'
  Assert ((@($asideIds) -join ',') -eq (@($screenIds) -join ',')) 'NAV screens keep the documented order'

  # --- static: every link uses an inline Lucide icon with the label in a span
  $iconPrefix = 'width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
  $inlineSvg = [regex]::Matches($srvTxt, '<svg ' + [regex]::Escape($iconPrefix))
  Assert ($inlineSvg.Count -eq 18) 'NAV both navigations carry one 16x16 Lucide SVG per link'
  foreach ($nav in @($aside.Value, $topnav.Value)) {
    $anchors = [regex]::Matches($nav, '(?s)<a [^>]*>.*?</a>')
    $badIcons = @($anchors | Where-Object { $_.Value -notmatch [regex]::Escape($iconPrefix) })
    $badLabels = @($anchors | Where-Object { $_.Value -notmatch '<span data-i18n="[^"]+">[^<]+</span>' })
    $badAnchorI18n = @($anchors | Where-Object { $_.Value -match '<a [^>]*data-i18n=' })
    Assert (($anchors.Count -eq 9) -and ($badIcons.Count -eq 0)) 'NAV each link holds the Lucide SVG'
    Assert ($badLabels.Count -eq 0) 'NAV each label is wrapped in a data-i18n span'
    Assert ($badAnchorI18n.Count -eq 0) 'NAV the anchor carries no data-i18n (static language never wipes the SVG)'
  }

  # --- static: one container per screen, hidden except the initial overview (no flash, no Tab stops)
  foreach ($id in $screenIds) {
    $m = [regex]::Match($srvTxt, ('<div id="' + $id + '"([^>]*)>'))
    Assert ($m.Success) ("SCREEN container present: " + $id)
    if ($m.Success) {
      $isHidden = ($m.Groups[1].Value -match 'hidden')
      if ($id -eq 'top') { Assert (-not $isHidden) 'SCREEN overview is visible before scripts run' }
      else { Assert ($isHidden) ("SCREEN starts hidden: " + $id) }
    }
  }
  Assert ($srvTxt.Contains('[hidden]{display:none!important}')) 'SCREEN hidden screens leave the Tab order (display:none)'

  # --- static: wrappers stay inside their screen (no empty grid wrapper left with padding)
  $iTop = $srvTxt.IndexOf('<div id="top"')
  $iProj = $srvTxt.IndexOf('<div id="projects"')
  $iGlob = $srvTxt.IndexOf('<div id="global"')
  $iBack = $srvTxt.IndexOf('<div id="backups"')
  $iGrid3 = $srvTxt.IndexOf('<div class="grid3">')
  $iCols2 = $srvTxt.IndexOf('<div class="cols2">')
  $iCols2b = $srvTxt.IndexOf('<div class="cols2">', $iCols2 + 1)
  $iStatus = $srvTxt.IndexOf('<section id="status">')
  $iSummary = $srvTxt.IndexOf('<div class="summarybar">')
  $iMainscroll = $srvTxt.IndexOf('<div class="mainscroll">')
  Assert (($iSummary -ge 0) -and ($iSummary -lt $iTop)) 'SCREEN summary region is a common header above all screens'
  Assert (($iGrid3 -ge 0) -and ($iGrid3 -lt $iTop) -and ($iGrid3 -gt $iSummary)) 'SCREEN summary grid lives in the common header, not an overview screen'
  Assert (($iMainscroll -ge 0) -and ($iSummary -lt $iMainscroll) -and ($iMainscroll -lt $iTop)) 'SCREEN common summary stays outside the scrolling region'
  Assert (($iProj -lt $iCols2) -and ($iCols2 -lt $iGlob)) 'SCREEN projects columns belong to the projects screen'
  Assert (($iCols2 -lt $iStatus) -and ($iStatus -lt $iGlob)) 'SCREEN retry table moved onto the projects screen'
  Assert (($iGlob -lt $iCols2b) -and ($iCols2b -lt $iBack)) 'SCREEN global columns belong to the global screen'
  Assert (([regex]::Matches($srvTxt, '<div class="cols2">')).Count -eq 2) 'SCREEN only the two existing column wrappers remain'

  # --- static: legacy hashes and routing code
  Assert (($srvTxt.Contains('const LEGACY=') -and $srvTxt.Contains('"register":"projects"') -and $srvTxt.Contains('"status":"projects"') -and $srvTxt.Contains('"gsettings":"global"') -and $srvTxt.Contains('"help":"settings"'))) 'HASH legacy anchors map onto their new screens'
  Assert (($srvTxt.Contains('function targetId') -and $srvTxt.Contains('function applyScreen') -and $srvTxt.Contains('function showHash') -and $srvTxt.Contains('function setActive') -and $srvTxt.Contains('function syncHelp'))) 'HASH routing helpers present'
  Assert ($srvTxt.Contains('window.addEventListener("hashchange",function(){showHash();});')) 'HASH back/forward handled via hashchange'
  Assert (([regex]::Matches($srvTxt, 'window\.addEventListener\("hashchange"')).Count -eq 1) 'HASH exactly one hashchange listener (no stale scroll listener left)'
  Assert ($srvTxt.Contains('showHash();refresh();refreshGlobal();')) 'HASH initial hash applied before the first refresh'
  Assert ((-not ($srvTxt.Contains('history.pushState'))) -and (-not ($srvTxt.Contains('location.hash=')))) 'HASH screen switch never rewrites history'
  Assert ((-not ($srvTxt.Contains('initSpy'))) -and (-not ($srvTxt.Contains('updateCurrent'))) -and (-not ($srvTxt.Contains('scrollToHash'))) -and (-not ($srvTxt.Contains('curActiveId'))) -and (-not ($srvTxt.Contains('navWant'))) -and (-not ($srvTxt.Contains('function bindNav'))) -and (-not ($srvTxt.Contains('scrollIntoView')))) 'HASH old scroll spy removed (single switch path)'
  Assert (-not ($srvTxt.Contains('data-view'))) 'HASH no second view mechanism added'

  # --- static: overview reuses the existing status calls, no new endpoint and no polling
  Assert ($srvTxt.Contains('id="ovGlobal"')) 'SUMMARY overview carries a Global state line'
  $ugIdx = $srvTxt.IndexOf('function updateGlobalUI(g){')
  $ugEnd = $srvTxt.IndexOf("`nasync function refreshGlobal", $ugIdx)
  Assert (($ugIdx -ge 0) -and ($ugEnd -gt $ugIdx)) 'SUMMARY updateGlobalUI slice located'
  $ugTxt = ''
  if (($ugIdx -ge 0) -and ($ugEnd -gt $ugIdx)) { $ugTxt = $srvTxt.Substring($ugIdx, $ugEnd - $ugIdx) }
  Assert ($ugTxt.Contains('ovGlobal')) 'SUMMARY overview line is fed from the existing global status response'
  Assert (-not ($ugTxt.Contains('api('))) 'SUMMARY overview adds no request of its own'
  Assert (-not ($srvTxt.Contains('setInterval('))) 'SUMMARY no always-on polling'

  # --- static: existing cards, ids and handlers are reused (no page regeneration)
  $keptIds = @('inpSearch', 'tbl', 'rows', 'emptyProj', 'prevArea', 'btnPrev', 'logPre', 'globalLogPre',
    'tblGlobal', 'globalRows', 'tblBackups', 'backupRows', 'tblGlobalBackups', 'globalBackupRows',
    'selLocal', 'localArea', 'importArea', 'numInterval', 'numGlobalInterval', 'helpDetail', 'ovl', 'msgGlobalBackup', 'btnGlobalBackups')
  $missingIds = @($keptIds | Where-Object { -not $srvTxt.Contains('id="' + $_ + '"') })
  Assert ($missingIds.Count -eq 0) ('REUSE existing card ids kept' + $(if ($missingIds.Count) { ': missing ' + ($missingIds -join ',') } else { '' }))
  $idMatches = [regex]::Matches($srvTxt, '\sid="([A-Za-z0-9_-]+)"')
  $dupIds = @($idMatches | ForEach-Object { $_.Groups[1].Value } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  Assert ($dupIds.Count -eq 0) ('REUSE no duplicate element ids' + $(if ($dupIds.Count) { ': ' + ($dupIds -join ',') } else { '' }))

  # --- static: modal focus return and the black theme spacing are untouched
  Assert (($srvTxt.Contains('wrap.inert') -and $srvTxt.Contains('focusVisible(lf)') -and $srvTxt.Contains('function focusVisibleNav') -and $srvTxt.Contains('done=focusVisibleNav();'))) 'FOCUS modal returns focus to a visible control (per-candidate nav fallback)'
  Assert (($srvTxt.Contains('background:#000') -and $srvTxt.Contains('background:#0a0a0a') -and $srvTxt.Contains('border-radius:14px'))) 'THEME black palette and card radius kept'
  Assert (($srvTxt.Contains('.mainscroll{flex:1;min-height:0;overflow:auto;padding:22px 28px 40px'))) 'THEME main padding kept'

  # --- static: narrow layout keeps one row of reachable 44px-class targets
  Assert ($srvTxt.Contains('@media(max-width:1000px){.topnav{display:flex;flex-wrap:nowrap;overflow-x:auto}')) 'MOBILE topnav stays one scrollable row'
  Assert ($srvTxt.Contains('.topnav a{padding:11px 12px;white-space:nowrap}')) 'MOBILE topnav link meets the 44px tap target'
  Assert ($srvTxt.Contains('aside{display:none}')) 'MOBILE desktop sidebar hidden below the breakpoint'

  # --- runtime: real routing code against a DOM stub (routing, legacy, retention, focus)
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  Assert (($null -ne $nodeExe) -and ($nodeExe -ne '')) 'RUNTIME node available for the routing harness'
  if ($nodeExe) {
    $uijs = Join-Path ([System.IO.Path]::GetTempPath()) ('dashnav-' + [System.Guid]::NewGuid().ToString('N') + '.js')
    Set-Content -LiteralPath $uijs @'
var fs = require('fs');
var fails = [];
function ok(c, n) { console.log((c ? 'PASS: ' : 'FAIL: ') + n); if (!c) fails.push(n); }
var src = fs.readFileSync(process.argv[2], 'utf8');
var js = src.substring(src.indexOf('<script>') + 8, src.indexOf('</script>'));
function slice(a, b) { var i = js.indexOf(a); if (i < 0) throw new Error('slice miss: ' + a); var j = js.indexOf(b, i); if (j < 0) throw new Error('slice miss: ' + b); return js.substring(i, j); }
var SEARCHCODE = slice('function applySearchFilter(', '\nfunction selectedNames');
var NAVCODE = slice('const SCREENS', '\nasync function api(');
var SCREEN_IDS = ['top', 'projects', 'global', 'extensions', 'rules', 'backups', 'local', 'logs', 'settings'];
var el = {};
SCREEN_IDS.forEach(function (id) { el[id] = { id: id, hidden: null, value: 'entered-' + id, mark: { screen: id } }; });
el.helpDetail = { id: 'helpDetail', open: false };
var scroll = { scrollTop: 9 };
var idCalls = [];
function mkTable(id, search) {
  var tb = { id: id, children: [] };
  for (var i = 0; i < 2; i++) tb.children.push({ style: { display: '' }, dataset: { search: search } });
  return tb;
}
el.inpSearch = { id: 'inpSearch', value: '' };
el.rows = mkTable('rows', 'alpha');
el.statusRows = mkTable('statusRows', 'alpha');
el.backupRows = mkTable('backupRows', 'alpha');
el.globalRows = mkTable('globalRows', 'alpha');
el.globalBackupRows = mkTable('globalBackupRows', 'alpha');
function mkLink(href, sel) {
  var l = { href: href, sel: sel, classes: {}, attrs: { href: href }, focused: false };
  l.getAttribute = function (n) { return l.attrs[n] === undefined ? null : l.attrs[n]; };
  l.setAttribute = function (n, v) { l.attrs[n] = v; };
  l.removeAttribute = function (n) { delete l.attrs[n]; };
  l.classList = { add: function (c) { l.classes[c] = true; }, remove: function (c) { delete l.classes[c]; } };
  l.focus = function () { l.focused = true; };
  return l;
}
var links = [];
['aside nav a', '.topnav a'].forEach(function (sel) {
  SCREEN_IDS.forEach(function (id) { links.push(mkLink('#' + id, sel)); });
});
var handlers = {};
global.location = { hash: '' };
global.window = { addEventListener: function (t, f) { (handlers[t] = handlers[t] || []).push(f); } };
global.document = {
  activeElement: null,
  getElementById: function (id) { idCalls.push(id); if (!el[id]) el[id] = { id: id, hidden: null }; return el[id]; },
  querySelector: function (s) { return s === '.mainscroll' ? scroll : null; },
  querySelectorAll: function (s) { var out = []; links.forEach(function (l) { if (s.indexOf(l.sel) >= 0) out.push(l); }); return out; }
};
eval(NAVCODE);
function visible() { var out = []; SCREEN_IDS.forEach(function (id) { if (!el[id].hidden) out.push(id); }); return out; }
function hiddenTrue() { var n = 0; SCREEN_IDS.forEach(function (id) { if (el[id].hidden === true) n++; }); return n; }
function active() { var out = []; links.forEach(function (l) { if (l.classes.active && l.attrs['aria-current'] === 'page') out.push(l.href); }); return out; }
function fireHash() { var hs = handlers.hashchange || []; for (var i = 0; i < hs.length; i++) hs[i](); }
function route(h) { location.hash = h; if (!handlers.hashchange || !handlers.hashchange.length) throw new Error('no hashchange handler'); fireHash(); }

ok((handlers.hashchange || []).length === 1, 'exactly one hashchange listener registered (no stale scroll listener)');
ok(typeof handlers.hashchange[0] === 'function', 'hashchange handler registered for back and forward');
route('#projects');
var keepValue = el.projects.value, keepMark = el.projects.mark, keepKids = el.projects.children;
route('#logs'); route('#settings'); route('#projects');
ok(el.projects.value === keepValue && el.projects.mark === keepMark && el.projects.children === keepKids, 'switching only toggles visibility, so typed values and results survive');
ok(links.every(function (l) { return !l.focused; }) && document.activeElement === null, 'screen switch never steals focus');
ok(SCREEN_IDS.every(function (id) { return typeof el[id].hidden === 'boolean'; }), 'every screen carries an explicit hidden flag');

var cases = [['', 'top'], ['#top', 'top'], ['#projects', 'projects'], ['#register', 'projects'], ['#status', 'projects'],
  ['#global', 'global'], ['#gsettings', 'global'], ['#extensions', 'extensions'], ['#rules', 'rules'], ['#backups', 'backups'], ['#local', 'local'],
  ['#logs', 'logs'], ['#settings', 'settings'], ['#help', 'settings'], ['#missing', 'top'],
  ['#constructor', 'top'], ['#toString', 'top'], ['#__proto__', 'top']];
cases.forEach(function (c) {
  scroll.scrollTop = 9;
  route(c[0]);
  ok(visible().join('') === c[1] && hiddenTrue() === 8 && scroll.scrollTop === 0, 'route ' + (c[0] || '(empty)') + ' shows only ' + c[1]);
  ok(active().join(',') === '#' + c[1] + ',#' + c[1], 'route ' + (c[0] || '(empty)') + ' marks ' + c[1] + ' active in both navigations');
});
route('#help');
ok(el.helpDetail.open === true, '#help opens the help card on the settings screen');
route('#top');
ok(el.helpDetail.open === true, 'help card keeps its opened state afterwards');

// --- the project search box filters only the project list and its status table
eval(SEARCHCODE);
el.inpSearch.value = 'zzz';
idCalls = [];
applySearchFilter();
var touched = idCalls.filter(function (v, i) { return idCalls.indexOf(v) === i; });
ok(touched.join(',') === 'inpSearch,rows,statusRows', 'project search reads only the project list and status table (touched: ' + touched.join(',') + ')');
ok(el.rows.children.every(function (c) { return c.style.display === 'none'; }), 'project search hides non-matching project rows');
ok(el.statusRows.children.every(function (c) { return c.style.display === 'none'; }), 'project search hides non-matching status rows');
ok(el.backupRows.children.every(function (c) { return c.style.display === ''; }) &&
   el.globalRows.children.every(function (c) { return c.style.display === ''; }) &&
   el.globalBackupRows.children.every(function (c) { return c.style.display === ''; }), 'project search leaves the other screens rows untouched');
ok(el.inpSearch.value === 'zzz', 'project search keeps the typed query');
el.inpSearch.value = '';
applySearchFilter();
ok(el.rows.children.every(function (c) { return c.style.display === ''; }), 'clearing the query restores every project row');

// --- modal focus return on a narrow layout: hidden sidebar link must be skipped
var stubFocus = null;
global.getComputedStyle = function (node) { return node._cs; };
global.safeFocus = function (node) { stubFocus = node; return true; };
function mkNav(href, display) {
  var l = mkLink(href, '.topnav a');
  l.isConnected = true;
  l.disabled = false;
  l._cs = { display: display, position: 'static' };
  l.offsetParent = display === 'none' ? null : {};
  l.getBoundingClientRect = function () { return { width: 20, height: 20 }; };
  return l;
}
var sideNav = mkNav('#logs', 'none');
var topNav = mkNav('#logs', 'inline');
document.querySelectorAll = function (s) { return s.indexOf('aside nav a.active') >= 0 ? [sideNav, topNav] : []; };
stubFocus = null;
ok(focusVisibleNav() === true && stubFocus === topNav, 'narrow focus return skips the hidden sidebar link and takes the visible topnav link');
document.querySelectorAll = function () { return [sideNav]; };
stubFocus = null;
ok(focusVisibleNav() === false && stubFocus === null, 'all-hidden nav candidates leave the focus fallback unused');
if (fails.length) { console.log('FAILED: ' + fails.length); process.exit(1); }
console.log('ALL NAVIGATION CHECKS PASSED');
'@ -Encoding ASCII
    try {
      & $nodeExe $uijs $srvPath
      Assert ($LASTEXITCODE -eq 0) 'RUNTIME routing harness passes (routes/legacy/retention/focus)'
    } finally {
      Remove-Item -LiteralPath $uijs -Force -ErrorAction SilentlyContinue
    }
  }

  Assert (((Get-Location).Path) -eq $initCwd) 'END cwd unchanged'
}
finally {
  Set-Location -LiteralPath $initCwd -ErrorAction SilentlyContinue
}
if ($failures.Count -eq 0) { Write-Host 'ALL DASHBOARD NAVIGATION CHECKS PASSED'; exit 0 }
else { Write-Host ('FAILURES: ' + ($failures -join '; ')); exit 1 }
