# probe-zero-filled.ps1 -- does a component's install dir hold a zero-filled file?
#
# Called by the bundle's ProbeContent (DisplayXRBundleInstaller.nsi) for a
# component whose registry marker and files are all present. Presence is not
# integrity: a write cut short by a power loss or hard reset can leave NTFS with
# the file's SIZE committed but its DATA never flushed, so the file reads back as
# the right length and nothing but zeros. Field case: the four .glb models of a
# demo, correct sizes, all zeros -> "Auto-load failed", and re-running the bundle
# fixed nothing because the version had not moved and the component was skipped.
#
# A file counts as zero-filled when its first AND last 4 KiB (the whole file,
# if smaller) are all zero bytes. Checking both ends keeps a legitimate data file
# that merely starts with zeros (a raw buffer, padding) from reading as damaged,
# and reads at most 8 KiB per file, so a multi-GB asset tree stays cheap.
# Empty files are skipped: a 0-byte file is a state some components write on
# purpose, and it is not the torn-write signature.
#
# Exit 1 + prints the first damaged file's path relative to -Dir.
# Exit 0 when nothing is damaged. Any other outcome (no PowerShell, a script
# error) the caller treats as "intact": this probe must never be the reason an
# install breaks, only a reason to repair one.

param([Parameter(Mandatory = $true)][string]$Dir)

$ErrorActionPreference = 'Stop'
$Block = 4096

function Test-AllZero([byte[]]$buf, [int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        if ($buf[$i] -ne 0) { return $false }
    }
    return $true
}

function Test-ZeroFilled([System.IO.FileInfo]$file) {
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
        $buf = New-Object byte[] $Block
        $n = $fs.Read($buf, 0, $Block)
        if (-not (Test-AllZero $buf $n)) { return $false }
        if ($file.Length -gt $Block) {
            [void]$fs.Seek(-$Block, 'End')
            $n = $fs.Read($buf, 0, $Block)
            if (-not (Test-AllZero $buf $n)) { return $false }
        }
        return $true
    } catch {
        return $false   # unreadable (locked, ACL) is not evidence of damage
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { exit 0 }

$root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue) {
    if ($f.Length -gt 0 -and (Test-ZeroFilled $f)) {
        Write-Output $f.FullName.Substring($root.Length + 1)
        exit 1
    }
}
exit 0
