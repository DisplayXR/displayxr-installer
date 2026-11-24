<#
.SYNOPSIS
    The rule that decides whether a bundle chains the Leia conversion component
    (versions.json `leia_conversion`).

.DESCRIPTION
    leia_plugin pin >= $LeiaConversionMinPlugin  -> "chain" (and it is required)
    leia_plugin pin <  $LeiaConversionMinPlugin  -> "skip"  (and it is forbidden)

    The reasons are in scripts/lib/leia-conversion-gate.sh, which holds the same
    rule for the bash build scripts. Keep the two values and LEIACONV_MIN_LEIA_VER
    in installer/windows/DisplayXRBundleInstaller.nsi equal;
    check_bundle_coverage.ps1 fails when they differ.

    Run:         leia_conversion_gate.ps1 -PluginTag v2.24.0   -> prints chain | skip
    Dot-source:  . leia_conversion_gate.ps1                    -> defines the function only

    ASCII only: Windows PowerShell 5.1 (which build-bundle.bat calls) reads a
    file without a BOM in the ANSI code page.
#>
param([string]$PluginTag)

$LeiaConversionMinPlugin = '2.24.0'

function Test-LeiaConversionChained {
    param([string]$Tag)
    if ($Tag -notmatch '^v?(\d+)\.(\d+)\.(\d+)$') {
        throw "leia_plugin pin '$Tag' is not vX.Y.Z"
    }
    $have = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
    return ($have -ge [version]$LeiaConversionMinPlugin)
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (Test-LeiaConversionChained $PluginTag) { Write-Output 'chain' } else { Write-Output 'skip' }
    } catch {
        [Console]::Error.WriteLine("leia_conversion_gate: $($_.Exception.Message)")
        exit 2
    }
    exit 0
}
