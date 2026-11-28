<#
.SYNOPSIS
    Drift guard: every component pinned in versions.json must be chained by
    BOTH bundle build scripts (Windows build-bundle.bat + macOS build-bundle.sh).

.DESCRIPTION
    The bundle gap that shipped in v0.15.0 — mediaplayer_demo was pinned in
    versions.json (auto-mirrored by the runtime's versions-bump flow) but the
    bundle's build scripts + NSI never consumed it, so it was silently dropped
    from the installer. Adding a pin to versions.json does NOT auto-wire it
    into the bundle; this check makes that omission fail CI instead of
    shipping a bundle that's missing a component.

    Windows  — every component key must have a COMPONENT_REPO_<key>= entry in
               build-bundle.bat.
    macOS    — every component key must have a `process_component <key>` call
               in build-bundle.sh. process_component itself gracefully skips a
               component whose runtime components.sh table has no macOS .pkg
               glob, so calling it unconditionally is safe; what we guard
               against is forgetting to call it at all.

    Not every pin is a bundle component. Membership in versions.json means
    "the dev orchestrator can install this as a released asset", which is a
    wider set than "the meta-bundle chains this" - so a pin may be
    deliberately unbundled. Those are named in $IntentionallyUnbundled below
    with the reason, and reported as skipped rather than passed over in
    silence. An unlisted pin still fails, which is the point of the guard.

    One pin is CONDITIONALLY bundled: leia_conversion (the Leia conversion
    component). The rule is scripts/leia_conversion_gate.ps1:

      leia_plugin >= the gate version  -> it MUST be chained (it is treated
                                          like any other component below);
      leia_plugin <  the gate version  -> it must NOT be chained (reported as
                                          skipped, with the reason).

    The state flips when the runtime mirrors a new leia_plugin pin into
    versions.json - a commit no PR in this repo reviews. So the wiring is
    checked in BOTH states: the build scripts and the .nsi must already carry
    the gated component, and the three copies of the gate version (the .ps1,
    scripts/lib/leia-conversion-gate.sh, LEIACONV_MIN_LEIA_VER in the .nsi)
    must be equal. Otherwise the day the plug-in pin moves, the bundle would
    quietly ship without the component.

    Two more decisions are held here, because nothing else would notice them
    regress (David, 2026-11-28):

      shell  - the DisplayXR Shell is NOT a bundle component on any platform;
               it is a catalog add-on. Its pin stays in versions.json (dev
               orchestrator, catalog generator), so it is listed as
               intentionally unbundled AND the build scripts / .nsi must not
               chain it - a section for it would also bring back the
               "unticked + installed -> uninstall" branch that removes a Shell
               the bundle no longer owns.
      leia   - on Windows the Leia SR plug-in and Leia conversion rows start
               UNTICKED (Section /o) and are ticked only by the catalog's
               display detection (dxr-get, embedded from the runtime
               installer), an existing install, or /LEIASR=1. The wiring for
               that is checked below.

    Exit 0 when every component is chained on both platforms; exit 1 (listing
    the orphans per platform) otherwise.
#>

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionsPath = Join-Path $repoRoot 'versions.json'
$batPath = Join-Path $repoRoot 'scripts/build-bundle.bat'
$shPath  = Join-Path $repoRoot 'scripts/build-bundle.sh'
$linuxPath   = Join-Path $repoRoot 'scripts/build-bundle-linux.sh'
$gateShPath  = Join-Path $repoRoot 'scripts/lib/leia-conversion-gate.sh'
$nsiPath     = Join-Path $repoRoot 'installer/windows/DisplayXRBundleInstaller.nsi'

# Defines $LeiaConversionMinPlugin and Test-LeiaConversionChained.
. (Join-Path $PSScriptRoot 'leia_conversion_gate.ps1')

if (-not (Test-Path $versionsPath)) { Write-Error "versions.json not found at $versionsPath"; exit 1 }
if (-not (Test-Path $batPath))      { Write-Error "build-bundle.bat not found at $batPath"; exit 1 }
if (-not (Test-Path $shPath))       { Write-Error "build-bundle.sh not found at $shPath"; exit 1 }

$versions = Get-Content -Raw $versionsPath | ConvertFrom-Json
$bat = Get-Content -Raw $batPath
$sh  = Get-Content -Raw $shPath
foreach ($p in @($linuxPath, $gateShPath, $nsiPath)) {
    if (-not (Test-Path $p)) { Write-Error "$p not found"; exit 1 }
}
$linux  = Get-Content -Raw $linuxPath
$gateSh = Get-Content -Raw $gateShPath
$nsi    = Get-Content -Raw $nsiPath

# Pins that are deliberately NOT chained by the bundle. Being in versions.json
# only means setup-displayxr can install the component from a released asset;
# enrolment in DisplayXRBundle-*.exe is a separate decision. Keep the reason
# next to the entry - a bare allowlist decays into "someone silenced the guard
# once, and nobody remembers why".
$IntentionallyUnbundled = @{
    browser = 'Opt-in only (setup-displayxr --with browser): a full standalone browser is something a user asks for, not part of the display stack the default install lays down, so it must not ride the default install. Enrolling it in the default install / the desktop bundle is a separate decision (browser-pvt#120 D4). Its tags are vX.Y.Z from v1.0.0, validated by versions-bump like every other component.'
      cnsdk_services = 'Android only, and not installable by setup-displayxr at all: it pins the pair of CNSDK display-service APKs on the PRIVATE repo LeiaInc/CNSDK, fetched with LEIALOFT_GITHUB_TOKEN by build-android-bundle.yml to assemble the Android tablet bundle. The desktop bundle is Windows/macOS installers and has no Android lane to chain it into. This is the pin that made versions.json membership mean "desktop orchestrator installs it OR a platform bundle pins it".'
    shell = 'A catalog add-on, not a bundle component, on every platform (David, 2026-11-28): the DisplayXR Shell is installed from the Dashboard (catalog id displayxr-shell) or its own installer. The pin stays for setup-displayxr, the offline paths and the catalog generator. The bundle leaves an installed Shell alone on upgrade (it has no section for it, so nothing can remove it); a bundle uninstall still takes it away because the runtime uninstaller cascades every registered workspace controller.'
    leia_conversion = "CONDITIONAL, and not chained by this bundle: the pinned Leia SR plug-in (leia_plugin) is older than v$LeiaConversionMinPlugin and still carries the conversion provider itself, so its installer would take the provider registration back from the component (Windows) and the two packages conflict (Linux). The component is wired into every build script behind scripts/leia_conversion_gate.ps1 and is chained - and required - from the first bundle whose leia_plugin pin is >= v$LeiaConversionMinPlugin. Until then: setup-displayxr --with leia-conversion. It needs the display maker's conversion runtime, which has its own installer and is never fetched by DisplayXR."
    ultraleap = 'NOT RELEASED YET (same as the entry above: listed ahead of the key). Ultraleap hands input provider, DisplayXR/displayxr-ultraleap, moved out of the runtime trunk. Opt-in (setup-displayxr --with ultraleap): it needs the Ultraleap tracking software and a camera, and a build installs only on the one runtime release it was built at (runtime ADR-063), so a bundle that pins a newer runtime could not install it anyway. Offered from the signed catalog, with its exact runtime range, never embedded by default.'
}

# leia_conversion is unbundled only while the gate says "skip". Once the
# plug-in pin reaches the gate version it leaves the table and is held to the
# same "chained by both build scripts" check as every other component.
$leiaPluginPin = $versions.leia_plugin
if (-not $leiaPluginPin) { Write-Error "versions.json has no 'leia_plugin' pin"; exit 1 }
$leiaConvChained = Test-LeiaConversionChained $leiaPluginPin
if ($leiaConvChained) {
    $IntentionallyUnbundled.Remove('leia_conversion')
    if (-not $versions.leia_conversion) {
        Write-Host "ERROR: leia_plugin $leiaPluginPin no longer carries the conversion provider, so the bundle must chain leia_conversion - but versions.json has no 'leia_conversion' pin." -ForegroundColor Red
        exit 1
    }
    Write-Host "GATE: leia_plugin $leiaPluginPin >= v$LeiaConversionMinPlugin - leia_conversion MUST be chained."
} else {
    Write-Host "GATE: leia_plugin $leiaPluginPin < v$LeiaConversionMinPlugin - leia_conversion must NOT be chained."
}

# Every property except the JSON-schema pointer is a pinned component.
$allPins    = $versions.PSObject.Properties.Name | Where-Object { $_ -ne '$schema' }
$components = $allPins | Where-Object { -not $IntentionallyUnbundled.ContainsKey($_) }
$skipped    = @($allPins | Where-Object { $IntentionallyUnbundled.ContainsKey($_) })

foreach ($s in $skipped) {
    Write-Host "SKIP: '$s' is pinned but intentionally unbundled - $($IntentionallyUnbundled[$s])"
}

$winOrphans = @()
$macOrphans = @()
foreach ($c in $components) {
    if ($bat -notmatch [regex]::Escape("COMPONENT_REPO_$c=")) { $winOrphans += $c }
    if ($sh  -notmatch ("process_component\s+" + [regex]::Escape($c) + "\b")) { $macOrphans += $c }
}

$failed = $false

# --- leia_conversion wiring, checked in both gate states ---------------------
$wiring = @()
if ($bat -notmatch [regex]::Escape('COMPONENT_REPO_leia_conversion='))   { $wiring += 'build-bundle.bat has no COMPONENT_REPO_leia_conversion= entry' }
if ($bat -notmatch [regex]::Escape('leia_conversion_gate.ps1'))          { $wiring += 'build-bundle.bat does not call scripts\leia_conversion_gate.ps1' }
if ($bat -notmatch [regex]::Escape('/DLEIACONV_EXE='))                   { $wiring += 'build-bundle.bat never passes /DLEIACONV_EXE to makensis' }
if ($sh  -notmatch 'process_component\s+leia_conversion\b')               { $wiring += 'build-bundle.sh has no gated `process_component leia_conversion` call' }
if ($sh  -notmatch [regex]::Escape('leia-conversion-gate.sh'))           { $wiring += 'build-bundle.sh does not source scripts/lib/leia-conversion-gate.sh' }
if ($linux -notmatch [regex]::Escape('leia-conversion-gate.sh'))         { $wiring += 'build-bundle-linux.sh does not source scripts/lib/leia-conversion-gate.sh' }
if ($linux -notmatch 'COMPONENTS\+=\(leia_conversion\)')                 { $wiring += 'build-bundle-linux.sh never adds leia_conversion to COMPONENTS' }
if ($nsi -notmatch '(?m)^\s*Section\s+(/o\s+)?"Leia conversion"\s+SecLeiaConv')  { $wiring += 'the bundle .nsi has no "Leia conversion" section (SecLeiaConv)' }
if ($nsi -notmatch '(?m)^!ifdef LEIACONV_EXE')                           { $wiring += 'the bundle .nsi does not gate the section on LEIACONV_EXE' }

# The section must come after the plug-in's: the handover depends on the order.
$iLeia = $nsi.IndexOf('"Leia SR plug-in" SecLeia')
$iConv = $nsi.IndexOf('"Leia conversion" SecLeiaConv')
if ($iLeia -ge 0 -and $iConv -ge 0 -and $iConv -lt $iLeia) { $wiring += 'the "Leia conversion" section is declared BEFORE "Leia SR plug-in" (it must run after it)' }

# One gate version, three copies.
$shMin  = if ($gateSh -match '(?m)^LEIA_CONVERSION_MIN_PLUGIN="([^"]+)"') { $Matches[1] } else { '<missing>' }
$nsiMin = if ($nsi    -match '(?m)^!define LEIACONV_MIN_LEIA_VER "([^"]+)"') { $Matches[1] } else { '<missing>' }
if ($shMin -ne $LeiaConversionMinPlugin -or $nsiMin -ne $LeiaConversionMinPlugin) {
    $wiring += "the gate version differs: leia_conversion_gate.ps1=$LeiaConversionMinPlugin, leia-conversion-gate.sh=$shMin, .nsi LEIACONV_MIN_LEIA_VER=$nsiMin"
}

# --- shell: unbundled on every platform, and kept that way --------------------
$shellWiring = @()
if ($bat   -match [regex]::Escape('COMPONENT_REPO_shell='))        { $shellWiring += 'build-bundle.bat has a COMPONENT_REPO_shell= entry' }
if ($bat   -match [regex]::Escape('/DSHELL_EXE='))                 { $shellWiring += 'build-bundle.bat passes /DSHELL_EXE to makensis' }
if ($sh    -match 'process_component\s+shell\b')                   { $shellWiring += 'build-bundle.sh calls process_component shell' }
if ($linux -match '(?m)^COMPONENTS=.*\bshell\b|COMPONENTS\+=\(shell\)') { $shellWiring += 'build-bundle-linux.sh chains shell' }
if ($nsi   -match '(?m)^\s*Section\s+(/o\s+)?"DisplayXR Shell"')    { $shellWiring += 'the bundle .nsi has a "DisplayXR Shell" section' }
if ($nsi   -match 'SecShell\b')                                    { $shellWiring += 'the bundle .nsi still references SecShell' }
if ($shellWiring.Count -gt 0) {
    $failed = $true
    Write-Host "ERROR: the DisplayXR Shell is a catalog add-on, not a bundle component, but the bundle chains it again:" -ForegroundColor Red
    foreach ($w in $shellWiring) { Write-Host "  - $w" -ForegroundColor Red }
}

# --- macOS: MCP Tools ships a .pkg, so the macOS bundle must extract it ------
# process_component alone is not enough: without an extraction rule the .pkg is
# downloaded and then skipped with a WARN (how MCP stayed out of the macOS
# bundle until 2026-11-28).
if ($sh -notmatch '(?m)^extract_mcp_tools\(\)' -or $sh -notmatch '(?m)^\s*mcp_tools\)\s*$') {
    $failed = $true
    Write-Host "ERROR: build-bundle.sh has no extract_mcp_tools rule - the macOS bundle would download DisplayXRMCP-*.pkg and skip it." -ForegroundColor Red
}

# --- Leia SR rows: unticked unless the catalog's detection says this PC has the display
$leiaSrWiring = @()
if ($nsi -notmatch '(?m)^\s*Section\s+/o\s+"Leia SR plug-in"\s+SecLeia\b') { $leiaSrWiring += 'the "Leia SR plug-in" section is not declared /o (unticked by default)' }
if ($nsi -match    '(?m)^\s*Section\s+"Leia conversion"\s+SecLeiaConv\b')   { $leiaSrWiring += 'the "Leia conversion" section is not declared /o (unticked by default)' }
if ($nsi -notmatch 'Call DetectDisplay')                                     { $leiaSrWiring += 'the bundle .nsi never calls DetectDisplay' }
if ($nsi -notmatch '(?m)^!ifndef DXR_GET_EXE')                               { $leiaSrWiring += 'the bundle .nsi does not require DXR_GET_EXE' }
if ($nsi -notmatch [regex]::Escape('detect-display.ps1'))                   { $leiaSrWiring += 'the bundle .nsi does not embed detect-display.ps1' }
if ($nsi -notmatch [regex]::Escape('"/LEIASR="'))                             { $leiaSrWiring += 'the bundle .nsi lost the /LEIASR= override' }
if ($bat -notmatch [regex]::Escape('/DDXR_GET_EXE='))                       { $leiaSrWiring += 'build-bundle.bat never passes /DDXR_GET_EXE to makensis' }
if (-not (Test-Path (Join-Path $repoRoot 'installer/windows/detect-display.ps1'))) { $leiaSrWiring += 'installer/windows/detect-display.ps1 is missing' }
if ($leiaSrWiring.Count -gt 0) {
    $failed = $true
    Write-Host "ERROR: the Leia SR rows are not wired to start unticked and follow display detection:" -ForegroundColor Red
    foreach ($w in $leiaSrWiring) { Write-Host "  - $w" -ForegroundColor Red }
}

# User-facing bundle text names the component "Leia conversion" and its
# prerequisite "the Leia conversion runtime"; the vendor's technology name
# stays out of the installer UI and the Linux bundle's scripts and README.
$tech = 'Neur' + 'D'
foreach ($f in @($nsiPath, $linuxPath) + @(Get-ChildItem (Join-Path $repoRoot 'installer/linux') -File | ForEach-Object { $_.FullName })) {
    if ((Get-Content -Raw $f) -match $tech) { $wiring += "$f names the vendor conversion technology in user-facing bundle text" }
}

if ($wiring.Count -gt 0) {
    $failed = $true
    Write-Host "ERROR: the Leia conversion component is not wired the way the gate needs:" -ForegroundColor Red
    foreach ($w in $wiring) { Write-Host "  - $w" -ForegroundColor Red }
    Write-Host "  See scripts/leia_conversion_gate.ps1 for the rule."
}

if ($winOrphans.Count -gt 0) {
    $failed = $true
    Write-Host "ERROR: versions.json pins components the WINDOWS bundle does not chain:" -ForegroundColor Red
    foreach ($o in $winOrphans) { Write-Host "  - $o" -ForegroundColor Red }
    Write-Host "  Fix: wire into scripts\build-bundle.bat (COMPONENT_REPO_/EXE_, read_pin,"
    Write-Host "  download_component, find_exe, copy, makensis /D) + DisplayXRBundleInstaller.nsi."
}
if ($macOrphans.Count -gt 0) {
    $failed = $true
    Write-Host "ERROR: versions.json pins components the macOS bundle does not chain:" -ForegroundColor Red
    foreach ($o in $macOrphans) { Write-Host "  - $o" -ForegroundColor Red }
    Write-Host "  Fix: add a `process_component <key>` call in scripts\build-bundle.sh"
    Write-Host "  (+ an extract_<key> rule if it ships a macOS .pkg)."
}
if ($failed) {
    Write-Host ""
    Write-Host "...or drop the pin from versions.json if the component is intentionally unbundled."
    exit 1
}

Write-Host "OK: all $($components.Count) bundled versions.json components are chained by both bundle scripts ($($skipped.Count) intentionally unbundled)."
exit 0
