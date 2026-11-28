# detect-display.ps1 -- does the signed catalog's detection say this PC has the
# display a component is for?
#
# Called ONCE by the bundle's .onInit (DisplayXRBundleInstaller.nsi, see
# DetectDisplay) to decide whether the Leia SR plug-in and Leia conversion rows
# start ticked. The bundle does no hardware detection of its own: it runs the
# `dxr-get.exe` of the runtime release it chains (extracted from that runtime
# installer by scripts\build-bundle.bat) and reads its verdict. dxr-get
# evaluates the `detect` rules of the signed DisplayXR Catalog -- monitor EDID
# ids and a registry rule -- so supporting a new panel is a catalog change, not
# a bundle change (runtime docs/specs/runtime/dxr-get.md, "Detection").
#
# Why a script and not nsExec on dxr-get directly: `dxr-get detect --json`
# prints one line that lists every monitor EDID and up to 128 USB ids before the
# item verdicts, which can be longer than an NSIS string (1024 chars) -- the
# verdict would be cut off and read as "no match". This script parses the JSON
# properly and also bounds the wait: dxr-get fetches the catalog, and with no
# network it retries for up to ~20 s before giving up (exit 10).
#
# In:  -DxrGet <path to dxr-get.exe>  -Component <schema-1 name, e.g. leia_plugin>
#      [-Catalog <url|file>]  passed to dxr-get as --catalog (testing)
#      [-TimeoutSec N]        default 25
# Out: ONE line, first word = the verdict:
#        high <evidence>   a rule matched with HIGH confidence  -> the caller ticks
#        low <evidence>    only a low-confidence rule matched   -> never ticks
#        none              the catalog has rules for it and none matched
#        offline           no catalog (exit 10: no network, captive portal, expired)
#        timeout           dxr-get did not finish in time (it is killed)
#        error <detail>    anything else (dxr-get missing, a refused signature, bad JSON)
#      Exit 0 always. Only "high" ever ticks a row; every other answer leaves it
#      unticked, so a failure here can only cost an automatic tick, never install
#      vendor software on a PC that does not have the display.

param(
    [Parameter(Mandatory = $true)][string]$DxrGet,
    [Parameter(Mandatory = $true)][string]$Component,
    [string]$Catalog = '',
    [int]$TimeoutSec = 25
)

# One line, no control characters: NSIS reads it off the stack as one string.
function Out-Verdict([string]$word, [string]$detail = '') {
    $line = if ($detail) { "$word $detail" } else { $word }
    $line = ($line -replace '[\r\n\t]+', ' ').Trim()
    if ($line.Length -gt 400) { $line = $line.Substring(0, 400) }
    Write-Output $line
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $DxrGet)) { Out-Verdict 'error' "dxr-get not found at $DxrGet" }

    $dxrArgs = @()
    if ($Catalog) { $dxrArgs += @('--catalog', ('"' + $Catalog.Replace('"', '') + '"')) }
    $dxrArgs += @('detect', '--json')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $DxrGet
    $psi.Arguments = ($dxrArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    # Read both pipes asynchronously: dxr-get logs to stderr, and a full stderr
    # pipe would block it while we wait on stdout.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        Out-Verdict 'timeout' "after $TimeoutSec s"
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    $out = $outTask.Result
    $null = $errTask.Result

    if ($code -eq 10) { Out-Verdict 'offline' }
    if ($code -ne 0) { Out-Verdict 'error' "dxr-get detect exited $code" }

    $j = $out | ConvertFrom-Json

    # The verdict per item. `detected_items` (runtime #2742) and `display_plugins`
    # (#2737) hold flat objects {id, component, label, class, match,
    # high_confidence, evidence}; older engines have only the per-name object
    # (`"leia_plugin": {match, high_confidence, evidence, id}`). Read whichever
    # this engine prints, newest first.
    $entry = $null
    foreach ($list in @('detected_items', 'display_plugins')) {
        if ($null -ne $j.$list) {
            $entry = @($j.$list) | Where-Object { $_.component -eq $Component } | Select-Object -First 1
            if ($entry) { break }
        }
    }
    if (-not $entry -and $null -ne $j.$Component) { $entry = $j.$Component }
    if (-not $entry) { Out-Verdict 'none' 'the catalog has no detect rules for it' }

    if ($entry.match -eq $true -and $entry.high_confidence -eq $true) { Out-Verdict 'high' ([string]$entry.evidence) }
    if ($entry.match -eq $true) { Out-Verdict 'low' ([string]$entry.evidence) }
    Out-Verdict 'none'
} catch {
    Out-Verdict 'error' $_.Exception.Message
}
