# probe-zero-filled.ps1 -- which components' install dirs hold a zero-filled file?
#
# Called ONCE by the bundle's .onInit (DisplayXRBundleInstaller.nsi, see
# ProbeContent) for every component whose registry marker and files are all
# present. Presence is not integrity: a write cut short by a power loss or hard
# reset can leave NTFS with the file's SIZE committed but its DATA never flushed,
# so the file reads back as the right length and nothing but zeros. Field case
# (installer#86): the four .glb models of a demo, correct sizes, all zeros ->
# "Auto-load failed", and re-running the bundle fixed nothing because the
# version had not moved and the component was skipped.
#
# A file counts as zero-filled when its first AND last 4 KiB (the whole file,
# if smaller) are all zero bytes. Checking both ends keeps a legitimate data file
# that merely starts with zeros (a raw buffer, padding) from reading as damaged,
# and reads at most 8 KiB per file, so a multi-GB asset tree stays cheap.
# Empty files are skipped: a 0-byte file is a state some components write on
# purpose, and it is not the torn-write signature.
#
# One process for all components, not one per component: a PowerShell launch
# per component made a no-op bundle run ~4x slower (installer#88 validation:
# 4.3 s -> 17.9 s with 7 serial launches and a per-byte PowerShell loop).
#
# In:  -Map "KEY1=C:\dir1|KEY2=C:\dir2|..."  (ARP key = install dir; '|' cannot
#      occur in a Windows path, and only the first '=' splits)
# Out: one line "|KEY1=rel\path|KEY2=rel\path|" naming, per damaged component,
#      the first zero-filled file relative to its dir; "|" when none.
#      Exit 0 either way. Any other outcome (no PowerShell, a script error) the
#      caller treats as "nothing damaged": this probe must never be the reason an
#      install breaks, only a reason to repair one.

param([Parameter(Mandatory = $true)][string]$Map)

$Block = 4096

# All-zero test without a per-byte PowerShell loop: Base64 of zero bytes is all
# 'A' plus '=' padding, and any non-zero byte yields some other character. The
# encode and the regex both run natively.
function Test-AllZero([byte[]]$buf, [int]$n) {
    if ($n -le 0) { return $true }
    return [Convert]::ToBase64String($buf, 0, $n) -match '^A*=*$'
}

function Test-ZeroFilled([string]$path, [long]$len, [byte[]]$buf) {
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $n = $fs.Read($buf, 0, $Block)
        if (-not (Test-AllZero $buf $n)) { return $false }
        if ($len -gt $Block) {
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

function Find-ZeroFilled([string]$dir, [byte[]]$buf) {
    if (-not [System.IO.Directory]::Exists($dir)) { return $null }
    $root = $dir.TrimEnd('\')
    try {
        foreach ($p in [System.IO.Directory]::EnumerateFiles($root, '*', 'AllDirectories')) {
            $len = (New-Object System.IO.FileInfo $p).Length
            if ($len -gt 0 -and (Test-ZeroFilled $p $len $buf)) {
                return $p.Substring($root.Length + 1)
            }
        }
    } catch {
        # An unreadable subtree aborts this dir's scan only: fail open.
    }
    return $null
}

$buf = New-Object byte[] $Block
$out = '|'
foreach ($entry in $Map.Split('|')) {
    $i = $entry.IndexOf('=')
    if ($i -lt 1) { continue }
    $hit = Find-ZeroFilled $entry.Substring($i + 1) $buf
    if ($hit) { $out += $entry.Substring(0, $i) + '=' + $hit + '|' }
}
Write-Output $out
exit 0
