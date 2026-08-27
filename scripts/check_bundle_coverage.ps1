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

    Exit 0 when every component is chained on both platforms; exit 1 (listing
    the orphans per platform) otherwise.
#>

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$versionsPath = Join-Path $repoRoot 'versions.json'
$batPath = Join-Path $repoRoot 'scripts\build-bundle.bat'
$shPath  = Join-Path $repoRoot 'scripts\build-bundle.sh'

if (-not (Test-Path $versionsPath)) { Write-Error "versions.json not found at $versionsPath"; exit 1 }
if (-not (Test-Path $batPath))      { Write-Error "build-bundle.bat not found at $batPath"; exit 1 }
if (-not (Test-Path $shPath))       { Write-Error "build-bundle.sh not found at $shPath"; exit 1 }

$versions = Get-Content -Raw $versionsPath | ConvertFrom-Json
$bat = Get-Content -Raw $batPath
$sh  = Get-Content -Raw $shPath

# Pins that are deliberately NOT chained by the bundle. Being in versions.json
# only means setup-displayxr can install the component from a released asset;
# enrolment in DisplayXRBundle-*.exe is a separate decision. Keep the reason
# next to the entry - a bare allowlist decays into "someone silenced the guard
# once, and nobody remembers why".
$IntentionallyUnbundled = @{
    browser = 'Opt-in only (setup-displayxr --with browser): the preview is rebased ~monthly onto Chrome stable but is NOT patched to Chrome mid-cycle security releases, so it must not ride the default install. Its tags are preview-X.Y.Z, so versions-bump validates its shape separately too.'
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
