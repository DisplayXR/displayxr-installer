# update-addons.ps1 -- bring installed catalog add-ons the bundle does not carry
# up to the catalog's version.
#
# Called ONCE by the bundle's "-UpdateAddons" section (DisplayXRBundleInstaller.nsi),
# after every component section and before the service restart. The bundle stopped
# carrying the DisplayXR Shell (2026-11-28), and a user can add other catalog items
# (the DisplayXR Browser, a third-party provider) that it never carried. Without
# this pass those would stay at whatever version they were installed at while the
# bundle moves the runtime on (David, 2026-11-28).
#
# It drives the runtime's install engine and makes no decision of its own:
#   1. `dxr-get outdated --json --no-runtime`  -> the installed items whose version
#      is behind the catalog's (state `outdated`), or the same version from another
#      build (`rebuilt`, a reinstall). --no-runtime: the runtime is the one the
#      bundle just installed and is fixed; an item that needs another one reads
#      `compatible: false`.
#   2. Drops what the bundle's own sections handle (-Skip: ids and aliases), the
#      runtime, and every `research` item (those install only when named).
#   3. `dxr-get install <id> --yes --no-runtime --no-start-service`, ONE CALL PER
#      ID so each gets its own exit code. Skip-if-current, never-downgrade and the
#      trust rules are dxr-get's (runtime docs/specs/runtime/dxr-get.md). The
#      service stays down: the bundle restarts it once, at the end.
#
# BOUNDED (the runtime installer's #2841 / #2869 rule). Every dxr-get line is
# copied to stdout as it arrives, so the caller's nsExec silence limit keeps
# working; and this script kills a dxr-get that prints nothing for -SilenceSec.
# dxr-get from #2869 on prints a line every 30 s while a component's own
# installer runs; an older one is silent for the whole child install, which the
# 10-minute default still covers for any add-on we ship.
#
# NEVER FAILS THE BUNDLE. Exit 0 always. Results go to -Results, one line each:
#   updated|<id>|<name>|<from>|<to>
#   failed|<id>|<name>|<reason>        dxr-get refused or the install failed
#   skipped|<id>|<name>|<reason>       not installable / not compatible here
#   offline|-|-|<reason>               no catalog: nothing was attempted
#   error|-|-|<reason>                 dxr-get could not be run / its answer read
#   none|-|-|-                         nothing installed is behind the catalog
#   (an empty field is always written as "-")
#
# In:  -DxrGet <the INSTALLED runtime's dxr-get.exe>  -Skip "id1,id2,..."
#      -Results <file>  [-Catalog <url|file>]  [-SilenceSec N] (default 600)

param(
    [Parameter(Mandatory = $true)][string]$DxrGet,
    [Parameter(Mandatory = $true)][string]$Results,
    [string]$Skip = '',
    [string]$Catalog = '',
    [int]$SilenceSec = 600
)

$script:lines = New-Object System.Collections.Generic.List[string]

# Empty fields are written as "-": NSIS's WordFind would otherwise collapse "||".
function Clean([string]$s) { $c = (($s -replace '[\r\n\t|]+', ' ').Trim()); if ($c) { return $c } else { return '-' } }
function Say([string]$s) { [Console]::Out.WriteLine("add-ons: $s"); [Console]::Out.Flush() }
function Result([string]$kind, [string]$id = '', [string]$name = '', [string]$a = '', [string]$b = '') {
    $f = @($kind, (Clean $id), (Clean $name), (Clean $a))
    if ($b) { $f += (Clean $b) }
    $script:lines.Add(($f -join '|'))
}
function Finish {
    try { [IO.File]::WriteAllLines($Results, $script:lines) } catch { }
    exit 0
}

# Run dxr-get; copy its stderr (and stdout, unless -Capture) to our stdout line
# by line; kill it after SilenceSec without a line. Returns code + stdout.
function Invoke-DxrGet([string[]]$argv, [switch]$Capture) {
    $pre = @()
    if ($Catalog) { $pre = @('--catalog', ('"' + $Catalog.Replace('"', '') + '"')) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $DxrGet
    $psi.Arguments = (($pre + $argv) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = New-Object System.Text.StringBuilder
    $tOut = $p.StandardOutput.ReadLineAsync()
    $tErr = $p.StandardError.ReadLineAsync()
    $last = [DateTime]::UtcNow
    while ($tOut -or $tErr) {
        $any = $false
        if ($tOut -and $tOut.Wait(100)) {
            $l = $tOut.Result
            if ($null -eq $l) { $tOut = $null } else {
                $any = $true
                [void]$out.AppendLine($l)
                if (-not $Capture) { [Console]::Out.WriteLine("  $l") }
                $tOut = $p.StandardOutput.ReadLineAsync()
            }
        }
        if ($tErr -and $tErr.Wait(100)) {
            $l = $tErr.Result
            if ($null -eq $l) { $tErr = $null } else {
                $any = $true
                [Console]::Out.WriteLine("  $l")
                $tErr = $p.StandardError.ReadLineAsync()
            }
        }
        if ($any) { [Console]::Out.Flush(); $last = [DateTime]::UtcNow }
        elseif (([DateTime]::UtcNow - $last).TotalSeconds -gt $SilenceSec) {
            try { $p.Kill() } catch { }
            return @{ code = 'timeout'; out = $out.ToString() }
        }
    }
    $p.WaitForExit()
    return @{ code = $p.ExitCode; out = $out.ToString() }
}

function Reason($code) {
    switch ("$code") {
        'timeout' { return "dxr-get printed nothing for $SilenceSec s and was ended" }
        '10' { return 'no connection, or the catalog could not be read' }
        '11' { return 'the catalog failed its signature check' }
        '20' { return 'the download failed' }
        '21' { return 'the download failed its verification' }
        '30' { return "the add-on's own installer failed" }
        '40' { return 'the catalog has no signed Windows build of it' }
        '41' { return 'it is not compatible with this runtime' }
        '50' { return 'it needs an elevated installer' }
        default { return "dxr-get exited $code" }
    }
}

try {
    if (-not (Test-Path -LiteralPath $DxrGet)) { Result 'error' '' '' "no dxr-get at $DxrGet"; Say "no dxr-get at $DxrGet - skipped"; Finish }

    $skipSet = @{}
    foreach ($s in ($Skip -split ',')) { if ($s.Trim()) { $skipSet[$s.Trim().ToLowerInvariant()] = $true } }

    Say 'checking which installed add-ons are behind the catalog (dxr-get outdated)'
    $r = Invoke-DxrGet @('outdated', '--json', '--no-runtime') -Capture
    if ("$($r.code)" -eq '10') { Result 'offline' '' '' (Reason 10); Say 'no connection or no catalog - add-on updates skipped'; Finish }
    if ("$($r.code)" -ne '0') { Result 'error' '' '' (Reason $r.code); Say "could not list outdated add-ons: $(Reason $r.code)"; Finish }

    $doc = $r.out | ConvertFrom-Json
    $todo = @()
    foreach ($it in @($doc.outdated)) {
        if ($null -eq $it -or -not $it.id) { continue }
        $names = @([string]$it.id) + @($it.aliases | ForEach-Object { [string]$_ })
        $name = if ($it.name) { [string]$it.name } else { [string]$it.id }
        if ($names | Where-Object { $skipSet.ContainsKey($_.ToLowerInvariant()) }) {
            Say "$name ($($it.id)): handled by the bundle's own sections - left to them"; continue
        }
        if ($it.class -eq 'runtime') { continue }
        if ($it.research -eq $true) { Say "$name ($($it.id)): research item - installs only when named"; continue }
        if ($it.installable -eq $false) {
            Result 'skipped' $it.id $name 'the catalog has no signed Windows build of it'
            Say "$name ($($it.id)): not installable from the catalog - skipped"; continue
        }
        if ($it.compatible -eq $false) {
            $why = if ($it.incompatible_reason) { [string]$it.incompatible_reason } else { 'it is not compatible with this runtime' }
            Result 'skipped' $it.id $name $why
            Say "$name ($($it.id)): $why - skipped"; continue
        }
        $todo += $it
    }

    if ($todo.Count -eq 0) { Result 'none'; Say 'nothing to update'; Finish }

    $offline = $false
    foreach ($it in $todo) {
        $name = if ($it.name) { [string]$it.name } else { [string]$it.id }
        if ($offline) { Result 'failed' $it.id $name 'not attempted: the connection was lost'; continue }
        $from = [string]$it.installed; $to = [string]$it.available
        $what = if ($it.state -eq 'rebuilt') { "reinstalling $to (another build)" } else { "$from -> $to" }
        Say "$name ($($it.id)): updating, $what"
        $r = Invoke-DxrGet @('install', [string]$it.id, '--yes', '--no-runtime', '--no-start-service')
        if ("$($r.code)" -eq '0') {
            Result 'updated' $it.id $name $from $to
            Say "$name ($($it.id)): done"
        } else {
            Result 'failed' $it.id $name (Reason $r.code)
            Say "$name ($($it.id)): NOT updated - $(Reason $r.code)"
            if ("$($r.code)" -eq '10') { Say 'no connection - the remaining add-ons are not attempted'; $offline = $true }
        }
    }
    Finish
} catch {
    Result 'error' '' '' $_.Exception.Message
    Say "error: $($_.Exception.Message)"
    Finish
}
