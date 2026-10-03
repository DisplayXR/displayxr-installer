; DisplayXR end-user meta-installer (issue DisplayXR/displayxr-runtime#284)
; Chains the Runtime + Shell + Leia plug-in + MCP Tools + Gaussian Splat,
; 3D Model Viewer, and Stereo Media Player demo installers in one guided
; flow. Each child is invoked silently
; (/S); the bundle itself takes the single UAC prompt + SmartScreen
; warning at launch.
;
; Component-selection UI (PR #2): MUI Components page lets the user
; pick which optional components to install or remove. Runtime is
; required (SectionIn RO); the others are individually toggleable with
; smart defaults. Re-running the bundle from Add/Remove Programs'
; Modify button re-shows the page with current install state
; pre-checked — checking a new box installs it, un-checking an
; installed box uninstalls it.
;
; Build inputs (passed by scripts/build-bundle.bat via /D):
;   BUNDLE_VERSION   e.g. 0.2.0
;   RUNTIME_EXE      filename of staged runtime installer
;   SHELL_EXE        filename of staged shell installer
;   LEIA_EXE         filename of staged leia plug-in installer
;   MCP_EXE          filename of staged mcp tools installer
;   GAUSS_EXE        filename of staged gaussian splat demo installer
;   MODELVIEWER_EXE  filename of staged 3D model viewer demo installer
;   MEDIAPLAYER_EXE  filename of staged stereo media player demo installer
;   AVATAR_EXE       filename of staged 3D avatar demo installer
;   EARTHVIEW_EXE    filename of staged earthview demo installer
;   BUNDLE_STAGE     absolute path to dir containing the staged .exe files + LICENSE
;   OUTPUT_DIR       absolute path for OutFile

!ifndef BUNDLE_VERSION
    !error "BUNDLE_VERSION not defined"
!endif
!ifndef RUNTIME_EXE
    !error "RUNTIME_EXE not defined"
!endif
!ifndef SHELL_EXE
    !error "SHELL_EXE not defined"
!endif
!ifndef LEIA_EXE
    !error "LEIA_EXE not defined"
!endif
!ifndef MCP_EXE
    !error "MCP_EXE not defined"
!endif
!ifndef GAUSS_EXE
    !error "GAUSS_EXE not defined"
!endif
!ifndef MODELVIEWER_EXE
    !error "MODELVIEWER_EXE not defined"
!endif
!ifndef MEDIAPLAYER_EXE
    !error "MEDIAPLAYER_EXE not defined"
!endif
!ifndef AVATAR_EXE
    !error "AVATAR_EXE not defined"
!endif
!ifndef EARTHVIEW_EXE
    !error "EARTHVIEW_EXE not defined"
!endif
; Bare (no leading 'v') target versions for the version-compare gate (#346),
; passed by build-bundle.bat alongside the *_EXE filenames.
!ifndef RUNTIME_VER
    !error "RUNTIME_VER not defined"
!endif
!ifndef SHELL_VER
    !error "SHELL_VER not defined"
!endif
!ifndef LEIA_VER
    !error "LEIA_VER not defined"
!endif
!ifndef MCP_VER
    !error "MCP_VER not defined"
!endif
!ifndef GAUSS_VER
    !error "GAUSS_VER not defined"
!endif
!ifndef MODELVIEWER_VER
    !error "MODELVIEWER_VER not defined"
!endif
!ifndef MEDIAPLAYER_VER
    !error "MEDIAPLAYER_VER not defined"
!endif
!ifndef AVATAR_VER
    !error "AVATAR_VER not defined"
!endif
!ifndef EARTHVIEW_VER
    !error "EARTHVIEW_VER not defined"
!endif
!ifndef BUNDLE_STAGE
    !error "BUNDLE_STAGE not defined"
!endif
!ifndef OUTPUT_DIR
    !error "OUTPUT_DIR not defined"
!endif

Name        "DisplayXR ${BUNDLE_VERSION}"
OutFile     "${OUTPUT_DIR}\DisplayXRBundle-${BUNDLE_VERSION}.exe"
RequestExecutionLevel admin
; $INSTDIR is PURE SCRATCH: each section extracts its staged child .exe
; here, runs it, and deletes it again immediately — child installers put
; their real payload in their own Program Files locations. $TEMP is the
; right home for that transient churn.
;
; Nothing that must outlive the install may live here: $TEMP is wiped by
; Storage Sense / Disk Cleanup. Both survivors go to ${BUNDLE_CACHE_DIR}
; (a stable ProgramData path) instead — the cached bundle .exe behind the
; ARP Modify button, and the uninstaller itself. Parking the uninstaller
; in $TEMP orphaned the ARP entry as soon as Windows swept the dir: the
; "DisplayXR <ver>" row survived pointing at a deleted .exe, leaving the
; stack un-uninstallable and blocking clean upgrades.
InstallDir  "$TEMP\DisplayXRBundle-${BUNDLE_VERSION}"
ShowInstDetails show
ShowUninstDetails show

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "Sections.nsh"
!include "WordFunc.nsh"
!insertmacro VersionCompare

!define MUI_ABORTWARNING

; Installer / wizard / uninstaller icon — the DisplayXR app tile (bundled
; alongside this .nsi; __FILEDIR__ resolves at makensis time). Without this
; the bundle .exe + its uninstaller show the generic NSIS icon.
!define MUI_ICON   "${__FILEDIR__}\assets\displayxr_app.ico"
!define MUI_UNICON "${__FILEDIR__}\assets\displayxr_app.ico"

; Components page: show per-section description on hover. SMALLDESC
; renders the description below the section list (compact layout).
!define MUI_COMPONENTSPAGE_SMALLDESC

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${BUNDLE_STAGE}\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;--------------------------------
; Globals — track current install state per child, populated in
; .onInit, consumed in each component section. "Installed" = the child's
; ARP entry is present in the HKLM 64-bit view AND the files it points at
; still exist (#1233 — a marker alone is not evidence of an install; see
; ProbeComponent).
;--------------------------------

Var G_RuntimeInstalled
Var G_ShellInstalled
Var G_LeiaInstalled
Var G_McpInstalled
Var G_GaussInstalled
Var G_ModelViewerInstalled
Var G_MediaPlayerInstalled
Var G_AvatarInstalled
Var G_EarthViewInstalled

; Child-installer failures (install-order epic, runtime #1803 / installer #74).
; A failing child used to `Abort` its section, which also skipped
; -FinalizeBundleArp -- the only place the service is restarted after
; -StopDisplayXRProcesses killed it -- so one bad child left the box with no
; service until the next logon. Failures are now RECORDED and the chain
; continues; only a runtime failure stops the remaining children (they all
; need a runtime), and even then the finalize section runs.
;   G_ChildFailures  "<Human>=<exit code>; ..." -- written to the bundle's
;                    ARP key as LastChildFailure, and drives the exit code
;   G_RuntimeFailed  1 iff the runtime install/upgrade failed
Var G_ChildFailures
Var G_RuntimeFailed

; #1233: human-readable list of components whose registry marker survived
; but whose files did not, built in .onInit and printed once at the top of
; the install so a repair run says WHY it is reinstalling.
Var G_RepairList

; Installed DisplayVersion per child (from its ARP key), read in .onInit
; and compared against the bundle's pinned target version (#346).
Var G_RuntimeVer
Var G_ShellVer
Var G_LeiaVer
Var G_McpVer
Var G_GaussVer
Var G_ModelViewerVer
Var G_MediaPlayerVer
Var G_AvatarVer
Var G_EarthViewVer

; Stable home for everything that must outlive the install. Under
; SetShellVarContext all (.onInit / un.onInit) $APPDATA is C:\ProgramData,
; which matches this installer's per-machine (HKLM) scope and is never
; swept the way $TEMP is.
!define BUNDLE_CACHE_DIR   "$APPDATA\DisplayXR\BundleInstaller"
; A copy of the bundle .exe, so ARP Modify can re-run it.
!define BUNDLE_CACHE_FILE  "${BUNDLE_CACHE_DIR}\DisplayXRBundle-${BUNDLE_VERSION}.exe"
; The bundle's own uninstaller. Must NOT live in $INSTDIR ($TEMP).
!define BUNDLE_UNINST_FILE "${BUNDLE_CACHE_DIR}\Uninstall-DisplayXRBundle.exe"

;--------------------------------
; PurgeBundleCaches — delete cached DisplayXRBundle-*.exe copies in
; ${BUNDLE_CACHE_DIR}, keeping the one named ${KEEP} (pass "" to purge
; all). Without this the cache dir grows one full installer (~55-95 MB)
; per version forever — only the current version's copy was ever
; removed on uninstall, so every prior bundle leaked (#25).
;
; KEEP must be a bare filename, not a path — FindFirst yields names.
; Runs AFTER the current version is cached (install) so ${KEEP} exists
; to be kept. On uninstall KEEP="" removes every copy, which also lets
; the following RMDir succeed instead of tripping on leftovers.
;
; UNIQ makes the loop labels unique per expansion. $R0/$R1 are saved
; and restored so the macro is safe to drop into any section.
;--------------------------------
!macro PurgeBundleCaches KEEP UNIQ
    Push $R0
    Push $R1
    FindFirst $R0 $R1 "${BUNDLE_CACHE_DIR}\DisplayXRBundle-*.exe"
  purge_loop_${UNIQ}:
    StrCmp $R1 "" purge_done_${UNIQ}
    StrCmp $R1 "${KEEP}" purge_next_${UNIQ} 0
    Delete "${BUNDLE_CACHE_DIR}\$R1"
  purge_next_${UNIQ}:
    FindNext $R0 $R1
    Goto purge_loop_${UNIQ}
  purge_done_${UNIQ}:
    FindClose $R0
    Pop $R1
    Pop $R0
!macroend

;--------------------------------
; ChildFailed -- record a failed child installer and keep going.
;
; Never a bare modal: every MessageBox carries /SD so a silent (/S) bundle
; can never block on one. IsRuntime=1 stops the rest of the chain (every
; other component needs a runtime) without skipping -FinalizeBundleArp;
; IsRuntime=0 lets the chain continue past the failed component.
;
; Args: Human (literal)  Code (a $Var / literal)  IsRuntime (0|1)
;--------------------------------
!macro ChildFailed Human Code IsRuntime
    DetailPrint "ERROR: ${Human} installer exited with code ${Code}."
    StrCpy $G_ChildFailures "$G_ChildFailures${Human}=${Code}; "
    !if ${IsRuntime} == 1
        StrCpy $G_RuntimeFailed 1
        ; Exit code 6 = a program is holding the runtime; the runtime
        ; installer names it in its own registry value (under /S it has no
        ; window of its own).
        ReadRegStr $R9 HKLM "Software\DisplayXR\Runtime" "LastInstallBlockers"
        ${If} $R9 != ""
            DetailPrint "Programs using the runtime: $R9"
        ${EndIf}
        DetailPrint "The remaining components will not be installed; the DisplayXR Service is still restarted."
        MessageBox MB_OK|MB_ICONSTOP "${Human} installer exited with code ${Code}.$\n$\nThe remaining components were not installed. Close any program using DisplayXR and run this installer again." /SD IDOK
    !else
        MessageBox MB_OK|MB_ICONEXCLAMATION "${Human} installer exited with code ${Code}.$\n$\nThe other components are still being installed. Run this installer again to retry ${Human}." /SD IDOK
    !endif
!macroend

;--------------------------------
; SkipIfRuntimeFailed -- first statement of every optional section: after a
; failed runtime install nothing else is installed OR removed. `Return`
; leaves the section; later sections (incl. -FinalizeBundleArp) still run,
; which is the difference from the old `Abort`.
;--------------------------------
!macro SkipIfRuntimeFailed Human
    ${If} $G_RuntimeFailed == 1
        DetailPrint "Skipping ${Human}: the DisplayXR Runtime install failed."
        Return
    ${EndIf}
!macroend

;--------------------------------
; ChildRemoved -- log the exit code of a Modify-remove uninstall. Recorded
; as a failure but never fatal. NOTE: an NSIS uninstaller run without
; `_?=<dir>` re-launches itself from %TEMP% and returns at once, so this
; code is usually the launcher's (0); it is logged for the cases where the
; launch itself fails.
;--------------------------------
!macro ChildRemoved Human Code
    DetailPrint "  ${Human} uninstaller exit code: ${Code}"
    ${If} ${Code} != 0
        StrCpy $G_ChildFailures "$G_ChildFailures${Human} (remove)=${Code}; "
    ${EndIf}
!macroend

;--------------------------------
; UpgradeOrSkip — for an ALREADY-installed component, re-run its staged
; sub-installer /S only when the bundle's pinned target version is strictly
; newer than what's installed (#346). Never downgrades.
;
; ${VersionCompare} A B $R0 → $R0: 0 = equal, 1 = A(first) newer,
; 2 = B(second) newer  (NSIS WordFunc.nsh convention). We pass
; installed-first, target-second, so "target newer" ⇒ $R0 == 2 ⇒ upgrade.
; Inverting the argument order silently disables all upgrades.
;
; ExtraArgs: extra switches for the child's silent run — "/NOSTART" for
; children that would otherwise launch displayxr-service mid-chain
; (runtime, leia-plugin; #461 on the runtime repo), "" for the rest. Older child
; installers ignore unknown switches, so passing it is always safe.
;
; IsRuntime: 1 for the runtime (a failure stops the chain), else 0 -- see
; ChildFailed.
;
; Args: InstalledVer (a $Var)  TargetVer (literal)  ExeName  Human  ExtraArgs  IsRuntime
;--------------------------------
!macro UpgradeOrSkip InstalledVer TargetVer ExeName Human ExtraArgs IsRuntime
    ${VersionCompare} "${InstalledVer}" "${TargetVer}" $R0
    ${If} $R0 == 2
        DetailPrint "Upgrading ${Human} (${InstalledVer} -> ${TargetVer})..."
        File "${BUNDLE_STAGE}\${ExeName}"
        ClearErrors
        ExecWait '"$INSTDIR\${ExeName}" /S ${ExtraArgs}' $0
        ${If} $0 != 0
            !insertmacro ChildFailed "${Human}" $0 ${IsRuntime}
        ${EndIf}
        Delete "$INSTDIR\${ExeName}"
    ${Else}
        DetailPrint "${Human} ${InstalledVer} is current (target ${TargetVer}) — skipping."
    ${EndIf}
!macroend

;--------------------------------
; Unquote — strip one pair of surrounding double quotes from VAR in place.
; TMP is a scratch $Var the caller owns. ARP values are conventionally
; quoted ("C:\...\Uninstall.exe"); ${FileExists} needs them bare.
;--------------------------------
!macro Unquote VAR TMP
    StrCpy ${TMP} ${VAR} 1
    ${If} ${TMP} == '$\"'
        StrCpy ${VAR} ${VAR} "" 1
        StrCpy ${TMP} ${VAR} 1 -1
        ${If} ${TMP} == '$\"'
            StrCpy ${VAR} ${VAR} -1
        ${EndIf}
    ${EndIf}
!macroend

;--------------------------------
; ProbeComponent — decide whether a component is REALLY installed, not
; merely remembered (#1233).
;
; The bundle used to read "is it installed?" off the existence of the ARP
; UninstallString alone, and then let UpgradeOrSkip decide on a version
; compare. A registry marker is not evidence that any file survives: after
; an AV/EDR quarantine (the field case: SentinelOne ate the shell, the file
; picker, MCP and 4 of 5 demo exes) every marker was intact, so the bundle
; skipped all six components whose pin had not moved, left the box broken,
; and exited 0 reporting success. It could not self-heal, which is the one
; thing a user re-runs it for.
;
; So probe the marker's own targets. Both are checked, because the observed
; damage hit them independently — Uninstall-Shell.exe was quarantined for
; the shell, while for a demo the payload exe went and the uninstaller
; stayed. Probing either one alone misses half the real cases:
;   UninstallString -> "$INSTDIR\Uninstall*.exe"  (quoted, no args;
;                      QuietUninstallString is the one that carries /S)
;   DisplayIcon     -> the component's main payload file
; Verified to hold for all nine children (runtime, shell, leia-plugin, mcp,
; five demos), which is why one uniform probe needs no per-component table.
;
; DisplayIcon also has a documented "path,index" form. None of ours use it;
; one that did would read as permanently broken here and reinstall on every
; run. Fixing that means splitting on the last comma, and is only worth
; doing if a child ever starts writing it.
;
; Stack in:  ARP key name (e.g. "DisplayXRShell")
; Stack out: "1" installed and intact
;            "0" marker present, files missing -> caller should REINSTALL
;            ""  no marker at all -> not installed
;--------------------------------
Function ProbeComponent
    Exch $R5                 ; in: ARP key -> out: verdict
    Push $R1
    Push $R2
    Push $R3
    Push $R4
    StrCpy $R4 $R5           ; keep the key; $R5 is now the result slot

    ReadRegStr $R1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\$R4" "UninstallString"
    ${If} $R1 == ""
        StrCpy $R5 ""
        Goto pc_done
    ${EndIf}

    ; Marker present. Believe it only as far as its targets survive.
    StrCpy $R5 "1"

    !insertmacro Unquote $R1 $R3
    ${IfNot} ${FileExists} "$R1"
        StrCpy $R5 "0"
        Goto pc_done
    ${EndIf}

    ReadRegStr $R2 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\$R4" "DisplayIcon"
    ${If} $R2 != ""
        !insertmacro Unquote $R2 $R3
        ${IfNot} ${FileExists} "$R2"
            StrCpy $R5 "0"
        ${EndIf}
    ${EndIf}

  pc_done:
    Pop $R4
    Pop $R3
    Pop $R2
    Pop $R1
    Exch $R5
FunctionEnd

;--------------------------------
; DetectComponent — ProbeComponent + the per-child bookkeeping .onInit did
; inline nine times over. Leaves the verdict in $0 so callers can keep
; driving SelectSection off "is there a marker" (`$0 != ""`), which is a
; different question from "are its files there" and stays the right one:
; a component whose payload was eaten should come back PRE-CHECKED so the
; run repairs it.
;
; A broken component is reported as NOT installed, so the section's
; existing "not installed -> install" branch does a full reinstall — which
; also rewrites the ARP entry and restores the uninstaller, curing an entry
; that was unremovable while its uninstaller was missing.
;
; Args: ArpKey (literal)  InstalledVar ($Var)  VerVar ($Var)  Human (literal)
;--------------------------------
!macro DetectComponent ArpKey InstalledVar VerVar Human
    Push "${ArpKey}"
    Call ProbeComponent
    Pop $0
    ${If} $0 != ""
        ReadRegStr ${VerVar} HKLM \
            "Software\Microsoft\Windows\CurrentVersion\Uninstall\${ArpKey}" "DisplayVersion"
        ${If} $0 == "1"
            StrCpy ${InstalledVar} 1
        ${Else}
            ; Marker without files. Drop the recorded version too: leaving it
            ; set would send this through UpgradeOrSkip, which compares
            ; versions and would answer "current - skipping" over an empty dir.
            StrCpy ${InstalledVar} 0
            StrCpy ${VerVar} ""
            StrCpy $G_RepairList "$G_RepairList${Human}, "
        ${EndIf}
    ${EndIf}
!macroend

;--------------------------------
; Component sections.
;
; Each optional section follows the same diff-and-act template:
;   selected + not installed → install
;   selected + already installed → no-op (avoid spurious /S re-runs)
;   not selected + already installed → uninstall (modify-remove)
;   not selected + not installed → no-op
;
; The Runtime section is SectionIn RO so it's always selected; its
; body just skips re-install when already present.
;--------------------------------

;--------------------------------
; #461 (runtime repo): stop DisplayXR processes ONCE before any child
; installer runs. A running displayxr-service has plug-in DLLs mapped;
; NSIS /S installs skip locked files SILENTLY (exit 0), which is how the
; v0.14.0 bundle left a stale Leia SR DLL on disk under a fresh registry
; Version. Covers every chain shape — including "Leia-SR-only upgrade",
; where the logon-started service would otherwise hold the DLL. The
; service is restarted exactly once at the end (-FinalizeBundleArp,
; #342); children are invoked with /NOSTART so none of them brings it
; back mid-chain.
;--------------------------------
Section "-StopDisplayXRProcesses"
    ; #1233: say out loud that this run is a repair, and for what. A
    ; component listed here had an intact registry marker over missing
    ; files, so it is being reinstalled rather than version-skipped.
    ${If} $G_RepairList != ""
        StrCpy $0 $G_RepairList -2      ; drop the trailing ", "
        DetailPrint "Repairing (registry entry present, files missing): $0"
    ${EndIf}
    DetailPrint "Stopping DisplayXR processes for the install chain..."
    nsExec::ExecToLog 'taskkill /f /im displayxr-shell.exe'
    Pop $0
    nsExec::ExecToLog 'taskkill /f /im displayxr-service.exe'
    Pop $0
    Sleep 1500   ; let killed processes release their file handles
SectionEnd

Section "DisplayXR Runtime (required)" SecRuntime
    SectionIn RO
    SetOutPath "$INSTDIR"

    ${If} $G_RuntimeInstalled == 0
        DetailPrint "Installing DisplayXR Runtime..."
        File "${BUNDLE_STAGE}\${RUNTIME_EXE}"
        ClearErrors
        ExecWait '"$INSTDIR\${RUNTIME_EXE}" /S /NOSTART' $0
        ${If} $0 != 0
            !insertmacro ChildFailed "DisplayXR Runtime" $0 1
        ${EndIf}
        Delete "$INSTDIR\${RUNTIME_EXE}"
    ${Else}
        !insertmacro UpgradeOrSkip $G_RuntimeVer "${RUNTIME_VER}" "${RUNTIME_EXE}" "DisplayXR Runtime" "/NOSTART" 1
    ${EndIf}

    ; A failed runtime install/upgrade stops here (the old `Abort` did the
    ; same, but also skipped -FinalizeBundleArp and so the service restart).
    ${If} $G_RuntimeFailed == 1
        Return
    ${EndIf}

    ; Re-assert the OpenXR ActiveRuntime registration UNCONDITIONALLY —
    ; including on the version-skip path above, which is the whole point.
    ;
    ; ActiveRuntime is machine state this bundle owns, not versioned payload.
    ; Any OpenXR runtime installed after us overwrites the single Khronos value
    ; and every DisplayXR app on the box silently starts loading that one
    ; instead. Re-running the bundle is the first thing a user tries, and it did
    ; nothing: the files were all intact, so ProbeComponent said "installed";
    ; the pin had not moved, so UpgradeOrSkip said "current - skipping"; so the
    ; runtime sub-installer never ran and its ActiveRuntime write never
    ; executed. Same structural failure as #1233 (a marker is not evidence of
    ; correct state), a different flavour of state.
    ;
    ; This is not a background land-grab: it happens only inside an install the
    ; user explicitly started. Nothing re-asserts the key at logon.
    ;
    ; Written inline rather than shelled out to `displayxr-cli runtime activate`
    ; on purpose - on the skip path the CLI on disk is the OLD one, which may
    ; predate the both-views fix, so the bundle must not depend on its version.
    ReadRegStr $R1 HKLM "Software\DisplayXR\Runtime" "InstallPath"
    ${If} $R1 != ""
    ${AndIf} ${FileExists} "$R1\DisplayXR_win64.json"
        ReadRegStr $R2 HKLM "Software\Khronos\OpenXR\1" "ActiveRuntime"
        ${If} $R2 != "$R1\DisplayXR_win64.json"
            ${If} $R2 == ""
                DetailPrint "OpenXR ActiveRuntime was unset - pointing it at DisplayXR."
            ${Else}
                DetailPrint "OpenXR ActiveRuntime pointed at another runtime ($R2) - restoring DisplayXR."
            ${EndIf}
        ${EndIf}
        WriteRegStr HKLM "Software\Khronos\OpenXR\1" "ActiveRuntime" "$R1\DisplayXR_win64.json"
        WriteRegDWORD HKLM "Software\Khronos\OpenXR\1\AvailableRuntimes" "$R1\DisplayXR_win64.json" 0
        ; 32-bit apps read the WOW6432Node view instead of the one above.
        SetRegView 32
        WriteRegStr HKLM "Software\Khronos\OpenXR\1" "ActiveRuntime" "$R1\DisplayXR_win64.json"
        WriteRegDWORD HKLM "Software\Khronos\OpenXR\1\AvailableRuntimes" "$R1\DisplayXR_win64.json" 0
        SetRegView 64
        ; A per-user value silently outranks every write above.
        DeleteRegValue HKCU "Software\Khronos\OpenXR\1" "ActiveRuntime"
        SetRegView 32
        DeleteRegValue HKCU "Software\Khronos\OpenXR\1" "ActiveRuntime"
        SetRegView 64
    ${Else}
        DetailPrint "WARNING: no DisplayXR InstallPath on record - cannot assert ActiveRuntime."
    ${EndIf}
SectionEnd

SectionGroup /e "Workspace" SecGrpWorkspace
    Section "DisplayXR Shell" SecShell
        !insertmacro SkipIfRuntimeFailed "DisplayXR Shell"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecShell}
            ${If} $G_ShellInstalled == 0
                DetailPrint "Installing DisplayXR Shell..."
                File "${BUNDLE_STAGE}\${SHELL_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${SHELL_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "DisplayXR Shell" $0 0
                ${EndIf}
                Delete "$INSTDIR\${SHELL_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_ShellVer "${SHELL_VER}" "${SHELL_EXE}" "DisplayXR Shell" "" 0
            ${EndIf}
        ${ElseIf} $G_ShellInstalled == 1
            DetailPrint "Removing DisplayXR Shell..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "DisplayXR Shell" $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "MCP Tools" SecMcp
        !insertmacro SkipIfRuntimeFailed "DisplayXR MCP Tools"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecMcp}
            ${If} $G_McpInstalled == 0
                DetailPrint "Installing DisplayXR MCP Tools..."
                File "${BUNDLE_STAGE}\${MCP_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MCP_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "DisplayXR MCP Tools" $0 0
                ${EndIf}
                Delete "$INSTDIR\${MCP_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_McpVer "${MCP_VER}" "${MCP_EXE}" "DisplayXR MCP Tools" "" 0
            ${EndIf}
        ${ElseIf} $G_McpInstalled == 1
            DetailPrint "Removing DisplayXR MCP Tools..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMCP" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "DisplayXR MCP Tools" $0
            ${EndIf}
        ${EndIf}
    SectionEnd
SectionGroupEnd

SectionGroup /e "Vendor plug-ins" SecGrpVendors
    Section "Leia SR plug-in" SecLeia
        !insertmacro SkipIfRuntimeFailed "Leia SR plug-in"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecLeia}
            ${If} $G_LeiaInstalled == 0
                DetailPrint "Installing Leia SR plug-in..."
                File "${BUNDLE_STAGE}\${LEIA_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${LEIA_EXE}" /S /NOSTART' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "Leia SR plug-in" $0 0
                ${EndIf}
                Delete "$INSTDIR\${LEIA_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_LeiaVer "${LEIA_VER}" "${LEIA_EXE}" "Leia SR plug-in" "/NOSTART" 0
            ${EndIf}
        ${ElseIf} $G_LeiaInstalled == 1
            DetailPrint "Removing Leia SR plug-in..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "Leia SR plug-in" $0
            ${EndIf}
        ${EndIf}
    SectionEnd
SectionGroupEnd

SectionGroup /e "Demos & samples" SecGrpDemos
    Section "Gaussian Splat viewer" SecGauss
        !insertmacro SkipIfRuntimeFailed "Gaussian Splat viewer"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecGauss}
            ${If} $G_GaussInstalled == 0
                DetailPrint "Installing Gaussian Splat viewer..."
                File "${BUNDLE_STAGE}\${GAUSS_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${GAUSS_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "Gaussian Splat" $0 0
                ${EndIf}
                Delete "$INSTDIR\${GAUSS_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_GaussVer "${GAUSS_VER}" "${GAUSS_EXE}" "Gaussian Splat viewer" "" 0
            ${EndIf}
        ${ElseIf} $G_GaussInstalled == 1
            DetailPrint "Removing Gaussian Splat viewer..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "Gaussian Splat viewer" $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "3D Model Viewer" SecModelViewer
        !insertmacro SkipIfRuntimeFailed "3D Model Viewer"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecModelViewer}
            ${If} $G_ModelViewerInstalled == 0
                DetailPrint "Installing 3D Model Viewer..."
                File "${BUNDLE_STAGE}\${MODELVIEWER_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MODELVIEWER_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "3D Model Viewer" $0 0
                ${EndIf}
                Delete "$INSTDIR\${MODELVIEWER_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_ModelViewerVer "${MODELVIEWER_VER}" "${MODELVIEWER_EXE}" "3D Model Viewer" "" 0
            ${EndIf}
        ${ElseIf} $G_ModelViewerInstalled == 1
            DetailPrint "Removing 3D Model Viewer..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRModelViewer" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "3D Model Viewer" $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "Stereo Media Player" SecMediaPlayer
        !insertmacro SkipIfRuntimeFailed "Stereo Media Player"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecMediaPlayer}
            ${If} $G_MediaPlayerInstalled == 0
                DetailPrint "Installing Stereo Media Player..."
                File "${BUNDLE_STAGE}\${MEDIAPLAYER_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MEDIAPLAYER_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "Stereo Media Player" $0 0
                ${EndIf}
                Delete "$INSTDIR\${MEDIAPLAYER_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_MediaPlayerVer "${MEDIAPLAYER_VER}" "${MEDIAPLAYER_EXE}" "Stereo Media Player" "" 0
            ${EndIf}
        ${ElseIf} $G_MediaPlayerInstalled == 1
            DetailPrint "Removing Stereo Media Player..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMediaPlayer" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "Stereo Media Player" $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "3D Avatar" SecAvatar
        !insertmacro SkipIfRuntimeFailed "3D Avatar"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecAvatar}
            ${If} $G_AvatarInstalled == 0
                DetailPrint "Installing 3D Avatar..."
                File "${BUNDLE_STAGE}\${AVATAR_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${AVATAR_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "3D Avatar" $0 0
                ${EndIf}
                Delete "$INSTDIR\${AVATAR_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_AvatarVer "${AVATAR_VER}" "${AVATAR_EXE}" "3D Avatar" "" 0
            ${EndIf}
        ${ElseIf} $G_AvatarInstalled == 1
            DetailPrint "Removing 3D Avatar..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRAvatar" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "3D Avatar" $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "EarthView" SecEarthView
        !insertmacro SkipIfRuntimeFailed "EarthView"
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecEarthView}
            ${If} $G_EarthViewInstalled == 0
                DetailPrint "Installing EarthView..."
                File "${BUNDLE_STAGE}\${EARTHVIEW_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${EARTHVIEW_EXE}" /S' $0
                ${If} $0 != 0
                    !insertmacro ChildFailed "EarthView" $0 0
                ${EndIf}
                Delete "$INSTDIR\${EARTHVIEW_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_EarthViewVer "${EARTHVIEW_VER}" "${EARTHVIEW_EXE}" "EarthView" "" 0
            ${EndIf}
        ${ElseIf} $G_EarthViewInstalled == 1
            DetailPrint "Removing EarthView..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXREarthView" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
                !insertmacro ChildRemoved "EarthView" $0
            ${EndIf}
        ${EndIf}
    SectionEnd
SectionGroupEnd

;--------------------------------
; Hidden bookkeeping section — ALWAYS runs, also after a failed child
; (no section Aborts any more — see G_ChildFailures): writes the bundle
; ARP entry, caches a copy of the bundle .exe for the Modify button,
; records the failures, and restarts the service.
;--------------------------------

Section "-FinalizeBundleArp"
    ; After a failed runtime install the bundle did not install this
    ; version: leave the ARP entry / cache of whatever version was there
    ; (if any) untouched, exactly as the old Abort did, and go straight to
    ; the failure record + service restart.
    StrCmp $G_RuntimeFailed 1 finalize_record

    ; Cache the bundle .exe in a stable location so ARP Modify can
    ; re-launch it after the user has discarded the original download.
    CreateDirectory "${BUNDLE_CACHE_DIR}"
    CopyFiles /SILENT "$EXEPATH" "${BUNDLE_CACHE_FILE}"

    ; #25: now that this version is cached, drop every OLDER cached bundle
    ; installer so the dir doesn't accumulate one per version forever.
    !insertmacro PurgeBundleCaches "DisplayXRBundle-${BUNDLE_VERSION}.exe" INSTALL

    ; Uninstaller goes to the stable cache dir, NOT $INSTDIR — $INSTDIR is
    ; $TEMP and gets swept, which orphans the ARP entry below.
    WriteUninstaller "${BUNDLE_UNINST_FILE}"

    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "DisplayName"          "DisplayXR ${BUNDLE_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "Publisher"            "DisplayXR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "DisplayVersion"       "${BUNDLE_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "UninstallString"      '"${BUNDLE_UNINST_FILE}"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "QuietUninstallString" '"${BUNDLE_UNINST_FILE}" /S'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "InstallLocation"      "${BUNDLE_CACHE_DIR}"
    ; ModifyPath re-launches the cached bundle .exe so the user can
    ; re-show the Components page and add/remove components without
    ; uninstalling the whole stack. NoModify=0 makes Windows surface
    ; the Modify button in Add/Remove Programs.
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "ModifyPath"           '"${BUNDLE_CACHE_FILE}"'
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "NoModify" 0
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "NoRepair" 1

  finalize_record:
    ; Record which children failed (cleared on a clean run). The value
    ; lives on the bundle's own ARP key; after a failed FIRST install that
    ; key holds only this value, which Windows does not list (no
    ; DisplayName) and which the next run or the bundle uninstaller replaces.
    ${If} $G_ChildFailures != ""
        StrCpy $G_ChildFailures $G_ChildFailures -2      ; drop the trailing "; "
        WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
            "LastChildFailure" "$G_ChildFailures"
        DetailPrint "Components that did not install cleanly: $G_ChildFailures"
    ${Else}
        DeleteRegValue HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
            "LastChildFailure"
    ${EndIf}

    ; -----------------------------------------------------------------
    ; #342: Restart displayxr-service so it re-probes display processors
    ; AFTER every component (esp. a vendor plug-in) has registered its
    ; HKLM\Software\DisplayXR\DisplayProcessors\* entry. The runtime
    ; installer is passed /NOSTART and -StopDisplayXRProcesses killed any
    ; running instance, so this is the ONLY start of the chain — which is
    ; why it must run even when a child failed (a runtime that was already
    ; installed is still there after a failed upgrade, and must come back).
    ; -----------------------------------------------------------------
    DetailPrint "Restarting DisplayXR Service to re-probe display processors..."
    nsExec::ExecToLog 'taskkill /f /im displayxr-service.exe'
    Pop $0
    Sleep 1500   ; let the killed process release its handles

    ReadRegStr $1 HKLM "Software\DisplayXR\Runtime" "InstallPath"
    ${If} $1 != ""
    ${AndIf} ${FileExists} "$1\displayxr-service.exe"
        ; #1478 (runtime repo): the bundle runs elevated, so a plain Exec would
        ; hand the service a High-integrity token, which the IPC layer does not
        ; expect (a Medium client cannot OpenProcess(PROCESS_DUP_HANDLE) a High
        ; service, and every child the service spawns inherits the elevation).
        ; Launch through the user's explorer.exe (Medium), the same way the
        ; logon Run key starts it. Non-blocking, mirrors the runtime installer.
        Exec 'explorer.exe "$1\displayxr-service.exe"'
        DetailPrint "DisplayXR Service restarted from $1."
    ${Else}
        DetailPrint "displayxr-service.exe not found via Software\DisplayXR\Runtime\InstallPath ($1) — skipping restart."
    ${EndIf}

    ; Exit code for unattended callers: 2 = the runtime failed (nothing
    ; after it was installed; same code the old Abort produced), 3 = the
    ; runtime is fine but at least one other component failed. Details in
    ; the log and in LastChildFailure.
    ${If} $G_RuntimeFailed == 1
        SetErrorLevel 2
    ${ElseIf} $G_ChildFailures != ""
        SetErrorLevel 3
    ${EndIf}
SectionEnd

;--------------------------------
; .onInit — SetRegView 64 (so HKLM\Software\... isn't redirected to
; WOW6432Node, which was bug #2 in PR #1), then read each child's
; current install state and pre-check the matching section.
;
; Must run AFTER all Section declarations so the ${SecShell} /
; ${SecMcp} / ${SecLeia} / ${SecGauss} !defines are populated by NSIS.
;--------------------------------

Function .onInit
    SetRegView 64
    ; Per-machine installer → $APPDATA maps to C:\ProgramData rather
    ; than the current user's roaming dir. Affects BUNDLE_CACHE_DIR.
    SetShellVarContext all

    StrCpy $G_RuntimeInstalled 0
    StrCpy $G_ShellInstalled   0
    StrCpy $G_LeiaInstalled    0
    StrCpy $G_McpInstalled     0
    StrCpy $G_GaussInstalled   0
    StrCpy $G_ModelViewerInstalled 0
    StrCpy $G_MediaPlayerInstalled 0
    StrCpy $G_AvatarInstalled  0
    StrCpy $G_EarthViewInstalled 0
    StrCpy $G_ChildFailures    ""
    StrCpy $G_RuntimeFailed    0
    StrCpy $G_RepairList       ""
    StrCpy $G_RuntimeVer       ""
    StrCpy $G_ShellVer         ""
    StrCpy $G_LeiaVer          ""
    StrCpy $G_McpVer           ""
    StrCpy $G_GaussVer         ""
    StrCpy $G_ModelViewerVer   ""
    StrCpy $G_MediaPlayerVer   ""
    StrCpy $G_AvatarVer        ""
    StrCpy $G_EarthViewVer     ""

    ; Runtime is RO so its checkbox state can't be unset; still record
    ; install state to skip a redundant /S re-run.
    !insertmacro DetectComponent "DisplayXR" $G_RuntimeInstalled $G_RuntimeVer "DisplayXR Runtime"

    ; Shell — default-checked. Pre-checked when already installed too.
    !insertmacro DetectComponent "DisplayXRShell" $G_ShellInstalled $G_ShellVer "DisplayXR Shell"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecShell}
    ${EndIf}

    ; MCP — default-checked. Pre-checked when already installed.
    !insertmacro DetectComponent "DisplayXRMCP" $G_McpInstalled $G_McpVer "DisplayXR MCP Tools"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecMcp}
    ${EndIf}

    ; Gauss demo — default-checked. Pre-checked when already installed.
    !insertmacro DetectComponent "DisplayXRGaussianSplat" $G_GaussInstalled $G_GaussVer "Gaussian Splat viewer"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecGauss}
    ${EndIf}

    ; Model viewer demo — default-checked. Pre-checked when already installed.
    !insertmacro DetectComponent "DisplayXRModelViewer" $G_ModelViewerInstalled $G_ModelViewerVer "3D Model Viewer"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecModelViewer}
    ${EndIf}

    ; Media player demo — default-checked. Pre-checked when already installed.
    !insertmacro DetectComponent "DisplayXRMediaPlayer" $G_MediaPlayerInstalled $G_MediaPlayerVer "Stereo Media Player"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecMediaPlayer}
    ${EndIf}

    ; Avatar demo — default-checked. Pre-checked when already installed.
    !insertmacro DetectComponent "DisplayXRAvatar" $G_AvatarInstalled $G_AvatarVer "3D Avatar"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecAvatar}
    ${EndIf}

    ; EarthView demo — default-checked. Pre-checked when already installed.
    !insertmacro DetectComponent "DisplayXREarthView" $G_EarthViewInstalled $G_EarthViewVer "EarthView"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecEarthView}
    ${EndIf}

    ; Vendor display plug-in — default-checked like every other component,
    ; pre-checked when already installed. The bundle does NOT look for the
    ; vendor's own platform software (install-order epic, runtime #1803,
    ; B-a): the bundle knows its component list, not vendor paths. A plug-in
    ; without its platform is inert (the runtime keeps using its sim-display
    ; fallback) and becomes active once the platform is installed, in either
    ; order. Gating the default on a vendor path made a silent bundle on a
    ; box without the platform never install the plug-in at all, so
    ; installing the platform afterwards changed nothing.
    !insertmacro DetectComponent "DisplayXRLeiaSR" $G_LeiaInstalled $G_LeiaVer "Leia SR plug-in"
    ${If} $0 != ""
        !insertmacro SelectSection ${SecLeia}
    ${EndIf}
FunctionEnd

Function un.onInit
    SetRegView 64
    SetShellVarContext all
FunctionEnd

;--------------------------------
; Section descriptions — shown as tooltips on hover (SMALLDESC layout).
;--------------------------------

LangString DESC_SecRuntime ${LANG_ENGLISH} "Core OpenXR runtime, service, and native compositors. Required by every other component."
LangString DESC_SecShell   ${LANG_ENGLISH} "Spatial workspace + window manager for 3D apps. Multi-app layouts, chrome, file picker."
LangString DESC_SecMcp     ${LANG_ENGLISH} "Claude / AI control adapter for DisplayXR. Required for the displayxr-mcp Tools experience."
LangString DESC_SecLeia    ${LANG_ENGLISH} "Display processor plug-in for Leia SR 3D monitors. Safe to install on any PC: it stays inactive until the monitor's own platform software is installed (before or after DisplayXR)."
LangString DESC_SecGauss   ${LANG_ENGLISH} "Sample 3D scene viewer (Gaussian splatting renderer). Standalone DisplayXR app."
LangString DESC_SecModelViewer ${LANG_ENGLISH} "glTF 2.0 PBR model viewer (.glb/.gltf). Standalone DisplayXR app."
LangString DESC_SecMediaPlayer ${LANG_ENGLISH} "Stereo 3D photo/video media player. Standalone DisplayXR app."
LangString DESC_SecAvatar    ${LANG_ENGLISH} "See-through 3D avatar over the live screen. Standalone DisplayXR app."
LangString DESC_SecEarthView ${LANG_ENGLISH} "Streaming 3D city viewer on Google Photorealistic 3D Tiles. Needs a Google Map Tiles API key. Standalone DisplayXR app."

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecRuntime} $(DESC_SecRuntime)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecShell}   $(DESC_SecShell)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMcp}     $(DESC_SecMcp)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecLeia}    $(DESC_SecLeia)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecGauss}   $(DESC_SecGauss)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecModelViewer} $(DESC_SecModelViewer)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMediaPlayer} $(DESC_SecMediaPlayer)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecAvatar} $(DESC_SecAvatar)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecEarthView} $(DESC_SecEarthView)
!insertmacro MUI_FUNCTION_DESCRIPTION_END


;--------------------------------
; Uninstall
;--------------------------------
;
; Exit codes are logged, not acted on: an NSIS uninstaller started without
; `_?=<dir>` copies itself to %TEMP%, relaunches and returns at once, so a 0
; here means "launched", not "finished". The order below therefore does not
; rely on any child having completed before the next one starts.
;
; Vendor plug-ins are removed by THEIR OWN uninstaller, explicitly, below.
; Since install-order epic runtime #1803 the runtime uninstaller no longer
; cascades into plug-in uninstallers nor deletes their registration, so the
; bundle must not rely on it to remove a plug-in.
;
; Walk each child's UninstallString in reverse install order
; (EarthView → Avatar → MediaPlayer → ModelViewer → Gauss → MCP → Leia SR → Shell → Runtime). Runtime last so its
; DeleteRegKey /ifempty Software\DisplayXR cleanup catches any orphan
; subkeys (per PR DisplayXR/displayxr-runtime#291 fix #4). The chain
; gracefully skips any child whose ARP key is absent — covers
; partial-install scenarios from the Components page.

Section "Uninstall"
    Var /GLOBAL ChildUninstall

    ; -- EarthView --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXREarthView" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling EarthView..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- 3D Avatar --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRAvatar" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling 3D Avatar..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- Stereo Media Player --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMediaPlayer" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling Stereo Media Player..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- 3D Model Viewer --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRModelViewer" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling 3D Model Viewer..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- Gaussian Splat viewer --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling Gaussian Splat viewer..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- MCP Tools --
    ; ARP key names are the children's own ProductName slugs — no hyphens
    ; between "DisplayXR" and the component (the child installers write
    ; "DisplayXRMCP", "DisplayXRLeiaSR", "DisplayXRShell"). A hyphenated
    ; lookup silently misses every child.
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMCP" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling DisplayXR MCP Tools..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- Leia SR Plug-in --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling Leia SR Plug-in..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- Shell --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling DisplayXR Shell..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; -- Standalone Unity test/sample apps --
    ; These are NOT chained by the bundle; they are installed out-of-band
    ; from the displayxr-unity-test* repos, each registering
    ; Software\DisplayXR\Unity\<name> with an InstallPath and its own
    ; Uninstall.exe underneath. Enumerate the subkeys so every present or
    ; future variant (Test, Test2DUI, TestHDRP, TestTransparent, …) is
    ; removed without hardcoding names — otherwise a bundle uninstall
    ; strands them under $PROGRAMFILES64\DisplayXR\Unity and blocks the
    ; DeleteRegKey /ifempty Software\DisplayXR cleanup below. Uninstall
    ; them before the runtime (they depend on it). Always enumerate index
    ; 0 and force-delete the component key each pass so the loop makes
    ; forward progress even if a child's async /S uninstall lags releasing
    ; the key; $R1 is a hard cap against a stuck key.
    StrCpy $R1 0
    unity_loop:
        EnumRegKey $R0 HKLM "Software\DisplayXR\Unity" 0
        StrCmp $R0 "" unity_done
        ClearErrors
        ReadRegStr $R2 HKLM "Software\DisplayXR\Unity\$R0" "InstallPath"
        ${If} $R2 != ""
        ${AndIf} ${FileExists} "$R2\Uninstall.exe"
            DetailPrint "Uninstalling Unity test app '$R0'..."
            ExecWait '"$R2\Uninstall.exe" /S' $0
            DetailPrint "  exit code: $0"
        ${EndIf}
        DeleteRegKey HKLM "Software\DisplayXR\Unity\$R0"
        IntOp $R1 $R1 + 1
        IntCmp $R1 64 unity_done unity_loop unity_done
    unity_done:
    RMDir "$PROGRAMFILES64\DisplayXR\Unity"
    DeleteRegKey /ifempty HKLM "Software\DisplayXR\Unity"

    ; -- Runtime --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling DisplayXR Runtime..."
        ExecWait '$ChildUninstall /S' $0
        DetailPrint "  exit code: $0"
    ${EndIf}

    ; Tear down our own ARP entry + every cached bundle .exe.
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle"
    ; #25: purge ALL cached bundle installers (KEEP=""), not just the current
    ; version — otherwise older copies survive and block the RMDir below.
    !insertmacro PurgeBundleCaches "" UNINSTALL
    ; We are RUNNING from ${BUNDLE_UNINST_FILE}, so Windows holds the file
    ; locked and a plain Delete silently no-ops. /REBOOTOK queues both the
    ; .exe and its now-empty dir for removal on next boot. The ARP key is
    ; already gone above, so the lingering .exe is inert either way.
    Delete /REBOOTOK "${BUNDLE_UNINST_FILE}"
    RMDir /REBOOTOK "${BUNDLE_CACHE_DIR}"
    RMDir /REBOOTOK "$APPDATA\DisplayXR"

    ; Catch any orphan parent key the runtime's own /ifempty cleanup
    ; missed. Defensive — runtime already does this, but harmless if
    ; the key is gone or non-empty.
    DeleteRegKey /ifempty HKLM "Software\DisplayXR"

    ; NOTE: no $INSTDIR cleanup here. In an uninstaller NSIS points $INSTDIR
    ; at the uninstaller's OWN dir — now ${BUNDLE_CACHE_DIR}, already swept
    ; above — not the $TEMP staging dir it meant back when the uninstaller
    ; lived there. The install-time staging dir is emptied by each section
    ; and self-cleans with $TEMP.
SectionEnd
