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
; The bundle itself doesn't install files long-term to $INSTDIR;
; child installers go to their own Program Files locations. We DO copy
; the bundle .exe itself to $APPDATA so the ARP Modify button
; has something stable to re-launch (see SecFinalize below).
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
; .onInit, consumed in each component section. "Installed" = the
; child's ARP UninstallString is present in HKLM 64-bit view.
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
Var G_LeiaProbeHit       ; 1 iff SR Platform DLLs found on disk

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

; Where we cache a copy of the bundle .exe so ARP Modify can re-run it.
!define BUNDLE_CACHE_DIR  "$APPDATA\DisplayXR\BundleInstaller"
!define BUNDLE_CACHE_FILE "${BUNDLE_CACHE_DIR}\DisplayXRBundle-${BUNDLE_VERSION}.exe"

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
; Args: InstalledVer (a $Var)  TargetVer (literal)  ExeName  Human  ExtraArgs
;--------------------------------
!macro UpgradeOrSkip InstalledVer TargetVer ExeName Human ExtraArgs
    ${VersionCompare} "${InstalledVer}" "${TargetVer}" $R0
    ${If} $R0 == 2
        DetailPrint "Upgrading ${Human} (${InstalledVer} -> ${TargetVer})..."
        File "${BUNDLE_STAGE}\${ExeName}"
        ClearErrors
        ExecWait '"$INSTDIR\${ExeName}" /S ${ExtraArgs}' $0
        ${If} $0 != 0
            MessageBox MB_OK|MB_ICONSTOP "${Human} installer exited with code $0. Aborting bundle."
            Abort
        ${EndIf}
        Delete "$INSTDIR\${ExeName}"
    ${Else}
        DetailPrint "${Human} ${InstalledVer} is current (target ${TargetVer}) — skipping."
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
            MessageBox MB_OK|MB_ICONSTOP "DisplayXR Runtime installer exited with code $0. Aborting bundle."
            Abort
        ${EndIf}
        Delete "$INSTDIR\${RUNTIME_EXE}"
    ${Else}
        !insertmacro UpgradeOrSkip $G_RuntimeVer "${RUNTIME_VER}" "${RUNTIME_EXE}" "DisplayXR Runtime" "/NOSTART"
    ${EndIf}
SectionEnd

SectionGroup /e "Workspace" SecGrpWorkspace
    Section "DisplayXR Shell" SecShell
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecShell}
            ${If} $G_ShellInstalled == 0
                DetailPrint "Installing DisplayXR Shell..."
                File "${BUNDLE_STAGE}\${SHELL_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${SHELL_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "DisplayXR Shell installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${SHELL_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_ShellVer "${SHELL_VER}" "${SHELL_EXE}" "DisplayXR Shell" ""
            ${EndIf}
        ${ElseIf} $G_ShellInstalled == 1
            DetailPrint "Removing DisplayXR Shell..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "MCP Tools" SecMcp
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecMcp}
            ${If} $G_McpInstalled == 0
                DetailPrint "Installing DisplayXR MCP Tools..."
                File "${BUNDLE_STAGE}\${MCP_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MCP_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "DisplayXR MCP Tools installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${MCP_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_McpVer "${MCP_VER}" "${MCP_EXE}" "DisplayXR MCP Tools" ""
            ${EndIf}
        ${ElseIf} $G_McpInstalled == 1
            DetailPrint "Removing DisplayXR MCP Tools..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMCP" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd
SectionGroupEnd

SectionGroup /e "Vendor plug-ins" SecGrpVendors
    Section "Leia SR plug-in" SecLeia
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecLeia}
            ${If} $G_LeiaInstalled == 0
                DetailPrint "Installing Leia SR plug-in..."
                File "${BUNDLE_STAGE}\${LEIA_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${LEIA_EXE}" /S /NOSTART' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "Leia SR plug-in installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${LEIA_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_LeiaVer "${LEIA_VER}" "${LEIA_EXE}" "Leia SR plug-in" "/NOSTART"
            ${EndIf}
        ${ElseIf} $G_LeiaInstalled == 1
            DetailPrint "Removing Leia SR plug-in..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd
SectionGroupEnd

SectionGroup /e "Demos & samples" SecGrpDemos
    Section "Gaussian Splat viewer" SecGauss
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecGauss}
            ${If} $G_GaussInstalled == 0
                DetailPrint "Installing Gaussian Splat viewer..."
                File "${BUNDLE_STAGE}\${GAUSS_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${GAUSS_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "Gaussian Splat installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${GAUSS_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_GaussVer "${GAUSS_VER}" "${GAUSS_EXE}" "Gaussian Splat viewer" ""
            ${EndIf}
        ${ElseIf} $G_GaussInstalled == 1
            DetailPrint "Removing Gaussian Splat viewer..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "3D Model Viewer" SecModelViewer
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecModelViewer}
            ${If} $G_ModelViewerInstalled == 0
                DetailPrint "Installing 3D Model Viewer..."
                File "${BUNDLE_STAGE}\${MODELVIEWER_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MODELVIEWER_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "3D Model Viewer installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${MODELVIEWER_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_ModelViewerVer "${MODELVIEWER_VER}" "${MODELVIEWER_EXE}" "3D Model Viewer" ""
            ${EndIf}
        ${ElseIf} $G_ModelViewerInstalled == 1
            DetailPrint "Removing 3D Model Viewer..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRModelViewer" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "Stereo Media Player" SecMediaPlayer
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecMediaPlayer}
            ${If} $G_MediaPlayerInstalled == 0
                DetailPrint "Installing Stereo Media Player..."
                File "${BUNDLE_STAGE}\${MEDIAPLAYER_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MEDIAPLAYER_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "Stereo Media Player installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${MEDIAPLAYER_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_MediaPlayerVer "${MEDIAPLAYER_VER}" "${MEDIAPLAYER_EXE}" "Stereo Media Player" ""
            ${EndIf}
        ${ElseIf} $G_MediaPlayerInstalled == 1
            DetailPrint "Removing Stereo Media Player..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMediaPlayer" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "3D Avatar" SecAvatar
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecAvatar}
            ${If} $G_AvatarInstalled == 0
                DetailPrint "Installing 3D Avatar..."
                File "${BUNDLE_STAGE}\${AVATAR_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${AVATAR_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "3D Avatar installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${AVATAR_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_AvatarVer "${AVATAR_VER}" "${AVATAR_EXE}" "3D Avatar" ""
            ${EndIf}
        ${ElseIf} $G_AvatarInstalled == 1
            DetailPrint "Removing 3D Avatar..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRAvatar" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd

    Section "EarthView" SecEarthView
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecEarthView}
            ${If} $G_EarthViewInstalled == 0
                DetailPrint "Installing EarthView..."
                File "${BUNDLE_STAGE}\${EARTHVIEW_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${EARTHVIEW_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "EarthView installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${EARTHVIEW_EXE}"
            ${Else}
                !insertmacro UpgradeOrSkip $G_EarthViewVer "${EARTHVIEW_VER}" "${EARTHVIEW_EXE}" "EarthView" ""
            ${EndIf}
        ${ElseIf} $G_EarthViewInstalled == 1
            DetailPrint "Removing EarthView..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXREarthView" "UninstallString"
            ${If} $1 != ""
                ExecWait '$1 /S' $0
            ${EndIf}
        ${EndIf}
    SectionEnd
SectionGroupEnd

;--------------------------------
; Hidden bookkeeping section — always runs, writes bundle ARP entry,
; caches a copy of the bundle .exe for the Modify button.
;--------------------------------

Section "-FinalizeBundleArp"
    ; Cache the bundle .exe in a stable location so ARP Modify can
    ; re-launch it after the user has discarded the original download.
    CreateDirectory "${BUNDLE_CACHE_DIR}"
    CopyFiles /SILENT "$EXEPATH" "${BUNDLE_CACHE_FILE}"

    WriteUninstaller "$INSTDIR\Uninstall-DisplayXRBundle.exe"

    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "DisplayName"          "DisplayXR ${BUNDLE_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "Publisher"            "DisplayXR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "DisplayVersion"       "${BUNDLE_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "UninstallString"      "$INSTDIR\Uninstall-DisplayXRBundle.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "QuietUninstallString" '"$INSTDIR\Uninstall-DisplayXRBundle.exe" /S'
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

    ; -----------------------------------------------------------------
    ; #342: Restart displayxr-service so it re-probes display processors
    ; AFTER every component (esp. the Leia plug-in) has registered its
    ; HKLM\Software\DisplayXR\DisplayProcessors\* manifest. The runtime
    ; installer starts the service at the end of its OWN section, which
    ; runs before the later Leia SR section — so without this, a fresh
    ; install's service binds the sim-display fallback (ProbeOrder 200)
    ; instead of leia-sr (50) and shows no weave until the next restart.
    ; -----------------------------------------------------------------
    DetailPrint "Restarting DisplayXR Service to re-probe display processors..."
    nsExec::ExecToLog 'taskkill /f /im displayxr-service.exe'
    Pop $0
    Sleep 1500   ; let the killed process release its handles

    ReadRegStr $1 HKLM "Software\DisplayXR\Runtime" "InstallPath"
    ${If} $1 != ""
    ${AndIf} ${FileExists} "$1\displayxr-service.exe"
        Exec '"$1\displayxr-service.exe"'   ; non-blocking, mirrors the runtime installer
        DetailPrint "DisplayXR Service restarted from $1."
    ${Else}
        DetailPrint "displayxr-service.exe not found via Software\DisplayXR\Runtime\InstallPath ($1) — skipping restart."
    ${EndIf}
SectionEnd

;--------------------------------
; .onInit — SetRegView 64 (so HKLM\Software\... isn't redirected to
; WOW6432Node, which was bug #2 in PR #1), then read each child's
; current install state and pre-check the matching section. For Leia SR
; on a fresh-install machine, also probe for SR Platform DLLs to
; decide whether to default-check the box.
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
    StrCpy $G_LeiaProbeHit     0
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
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_RuntimeInstalled 1
        ReadRegStr $G_RuntimeVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR" "DisplayVersion"
    ${EndIf}

    ; Shell — default-checked. Pre-checked when already installed too.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_ShellInstalled 1
        ReadRegStr $G_ShellVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "DisplayVersion"
        !insertmacro SelectSection ${SecShell}
    ${EndIf}

    ; MCP — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMCP" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_McpInstalled 1
        ReadRegStr $G_McpVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMCP" "DisplayVersion"
        !insertmacro SelectSection ${SecMcp}
    ${EndIf}

    ; Gauss demo — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_GaussInstalled 1
        ReadRegStr $G_GaussVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "DisplayVersion"
        !insertmacro SelectSection ${SecGauss}
    ${EndIf}

    ; Model viewer demo — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRModelViewer" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_ModelViewerInstalled 1
        ReadRegStr $G_ModelViewerVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRModelViewer" "DisplayVersion"
        !insertmacro SelectSection ${SecModelViewer}
    ${EndIf}

    ; Media player demo — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMediaPlayer" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_MediaPlayerInstalled 1
        ReadRegStr $G_MediaPlayerVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMediaPlayer" "DisplayVersion"
        !insertmacro SelectSection ${SecMediaPlayer}
    ${EndIf}

    ; Avatar demo — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRAvatar" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_AvatarInstalled 1
        ReadRegStr $G_AvatarVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRAvatar" "DisplayVersion"
        !insertmacro SelectSection ${SecAvatar}
    ${EndIf}

    ; EarthView demo — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXREarthView" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_EarthViewInstalled 1
        ReadRegStr $G_EarthViewVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXREarthView" "DisplayVersion"
        !insertmacro SelectSection ${SecEarthView}
    ${EndIf}

    ; Leia SR — probe SR Platform install path before deciding default.
    ; The SR Platform installer puts core DLLs under one of these dirs
    ; (current "LeiaSR" branding + legacy "Simulated Reality" branding,
    ; both seen in the field). Either present → user has the platform
    ; layer + likely the hardware, so default-check Leia SR.
    ${If} ${FileExists} "$PROGRAMFILES64\LeiaSR\Platform\bin\*.dll"
        StrCpy $G_LeiaProbeHit 1
    ${ElseIf} ${FileExists} "$PROGRAMFILES32\Simulated Reality\Platform\*.dll"
        StrCpy $G_LeiaProbeHit 1
    ${EndIf}

    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_LeiaInstalled 1
        ReadRegStr $G_LeiaVer HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "DisplayVersion"
        !insertmacro SelectSection ${SecLeia}
    ${ElseIf} $G_LeiaProbeHit == 1
        !insertmacro SelectSection ${SecLeia}
    ${Else}
        !insertmacro UnselectSection ${SecLeia}
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
LangString DESC_SecLeia    ${LANG_ENGLISH} "Display processor for Leia SR 3D monitors. Auto-selected when SR Platform is detected."
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
    ${EndIf}

    ; -- 3D Avatar --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRAvatar" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling 3D Avatar..."
        ExecWait '$ChildUninstall /S' $0
    ${EndIf}

    ; -- Stereo Media Player --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMediaPlayer" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling Stereo Media Player..."
        ExecWait '$ChildUninstall /S' $0
    ${EndIf}

    ; -- 3D Model Viewer --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRModelViewer" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling 3D Model Viewer..."
        ExecWait '$ChildUninstall /S' $0
    ${EndIf}

    ; -- Gaussian Splat viewer --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling Gaussian Splat viewer..."
        ExecWait '$ChildUninstall /S' $0
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
    ${EndIf}

    ; -- Leia SR Plug-in --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling Leia SR Plug-in..."
        ExecWait '$ChildUninstall /S' $0
    ${EndIf}

    ; -- Shell --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling DisplayXR Shell..."
        ExecWait '$ChildUninstall /S' $0
    ${EndIf}

    ; -- Runtime --
    ClearErrors
    ReadRegStr $ChildUninstall HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR" "UninstallString"
    ${If} $ChildUninstall != ""
        DetailPrint "Uninstalling DisplayXR Runtime..."
        ExecWait '$ChildUninstall /S' $0
    ${EndIf}

    ; Tear down our own ARP entry + cached bundle .exe.
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle"
    Delete "${BUNDLE_CACHE_FILE}"
    RMDir "${BUNDLE_CACHE_DIR}"
    RMDir "$APPDATA\DisplayXR"

    ; Catch any orphan parent key the runtime's own /ifempty cleanup
    ; missed. Defensive — runtime already does this, but harmless if
    ; the key is gone or non-empty.
    DeleteRegKey /ifempty HKLM "Software\DisplayXR"

    Delete "$INSTDIR\Uninstall-DisplayXRBundle.exe"
    RMDir "$INSTDIR"
SectionEnd
