; DisplayXR end-user meta-installer (issue DisplayXR/displayxr-runtime#284)
; Chains the Runtime + Shell + Leia plug-in + MCP Tools + Gaussian Splat
; demo installers in one guided flow. Each child is invoked silently
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
Var G_LeiaProbeHit       ; 1 iff SR Platform DLLs found on disk

; Where we cache a copy of the bundle .exe so ARP Modify can re-run it.
!define BUNDLE_CACHE_DIR  "$APPDATA\DisplayXR\BundleInstaller"
!define BUNDLE_CACHE_FILE "${BUNDLE_CACHE_DIR}\DisplayXRBundle-${BUNDLE_VERSION}.exe"

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

Section "DisplayXR Runtime (required)" SecRuntime
    SectionIn RO
    SetOutPath "$INSTDIR"

    ${If} $G_RuntimeInstalled == 1
        DetailPrint "DisplayXR Runtime already installed — skipping."
    ${Else}
        DetailPrint "Installing DisplayXR Runtime..."
        File "${BUNDLE_STAGE}\${RUNTIME_EXE}"
        ClearErrors
        ExecWait '"$INSTDIR\${RUNTIME_EXE}" /S' $0
        ${If} $0 != 0
            MessageBox MB_OK|MB_ICONSTOP "DisplayXR Runtime installer exited with code $0. Aborting bundle."
            Abort
        ${EndIf}
        Delete "$INSTDIR\${RUNTIME_EXE}"
    ${EndIf}
SectionEnd

SectionGroup /e "Workspace" SecGrpWorkspace
    Section "DisplayXR Shell" SecShell
        SetOutPath "$INSTDIR"
        ${If} ${SectionIsSelected} ${SecShell}
            ${If} $G_ShellInstalled == 1
                DetailPrint "DisplayXR Shell already installed — skipping."
            ${Else}
                DetailPrint "Installing DisplayXR Shell..."
                File "${BUNDLE_STAGE}\${SHELL_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${SHELL_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "DisplayXR Shell installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${SHELL_EXE}"
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
            ${If} $G_McpInstalled == 1
                DetailPrint "DisplayXR MCP Tools already installed — skipping."
            ${Else}
                DetailPrint "Installing DisplayXR MCP Tools..."
                File "${BUNDLE_STAGE}\${MCP_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${MCP_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "DisplayXR MCP Tools installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${MCP_EXE}"
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
            ${If} $G_LeiaInstalled == 1
                DetailPrint "Leia SR plug-in already installed — skipping."
            ${Else}
                DetailPrint "Installing Leia SR plug-in..."
                File "${BUNDLE_STAGE}\${LEIA_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${LEIA_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "Leia SR plug-in installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${LEIA_EXE}"
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
            ${If} $G_GaussInstalled == 1
                DetailPrint "Gaussian Splat viewer already installed — skipping."
            ${Else}
                DetailPrint "Installing Gaussian Splat viewer..."
                File "${BUNDLE_STAGE}\${GAUSS_EXE}"
                ClearErrors
                ExecWait '"$INSTDIR\${GAUSS_EXE}" /S' $0
                ${If} $0 != 0
                    MessageBox MB_OK|MB_ICONSTOP "Gaussian Splat installer exited with code $0. Aborting bundle."
                    Abort
                ${EndIf}
                Delete "$INSTDIR\${GAUSS_EXE}"
            ${EndIf}
        ${ElseIf} $G_GaussInstalled == 1
            DetailPrint "Removing Gaussian Splat viewer..."
            ReadRegStr $1 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
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
SectionEnd

;--------------------------------
; .onInit — SetRegView 64 (so HKLM\Software\... isn't redirected to
; WOW6432Node, which was bug #2 in PR #1), then read each child's
; current install state and pre-check the matching section. For Leia
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
    StrCpy $G_LeiaProbeHit     0

    ; Runtime is RO so its checkbox state can't be unset; still record
    ; install state to skip a redundant /S re-run.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_RuntimeInstalled 1
    ${EndIf}

    ; Shell — default-checked. Pre-checked when already installed too.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRShell" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_ShellInstalled 1
        !insertmacro SelectSection ${SecShell}
    ${EndIf}

    ; MCP — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRMCP" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_McpInstalled 1
        !insertmacro SelectSection ${SecMcp}
    ${EndIf}

    ; Gauss demo — default-checked. Pre-checked when already installed.
    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRGaussianSplat" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_GaussInstalled 1
        !insertmacro SelectSection ${SecGauss}
    ${EndIf}

    ; Leia — probe SR Platform install path before deciding default.
    ; The SR Platform installer puts core DLLs under one of these dirs
    ; (current "LeiaSR" branding + legacy "Simulated Reality" branding,
    ; both seen in the field). Either present → user has the platform
    ; layer + likely the hardware, so default-check Leia.
    ${If} ${FileExists} "$PROGRAMFILES64\LeiaSR\Platform\bin\*.dll"
        StrCpy $G_LeiaProbeHit 1
    ${ElseIf} ${FileExists} "$PROGRAMFILES32\Simulated Reality\Platform\*.dll"
        StrCpy $G_LeiaProbeHit 1
    ${EndIf}

    ReadRegStr $0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRLeiaSR" "UninstallString"
    ${If} $0 != ""
        StrCpy $G_LeiaInstalled 1
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

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecRuntime} $(DESC_SecRuntime)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecShell}   $(DESC_SecShell)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMcp}     $(DESC_SecMcp)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecLeia}    $(DESC_SecLeia)
    !insertmacro MUI_DESCRIPTION_TEXT ${SecGauss}   $(DESC_SecGauss)
!insertmacro MUI_FUNCTION_DESCRIPTION_END


;--------------------------------
; Uninstall
;--------------------------------
;
; Walk each child's UninstallString in reverse install order
; (Gauss → MCP → Leia → Shell → Runtime). Runtime last so its
; DeleteRegKey /ifempty Software\DisplayXR cleanup catches any orphan
; subkeys (per PR DisplayXR/displayxr-runtime#291 fix #4). The chain
; gracefully skips any child whose ARP key is absent — covers
; partial-install scenarios from the Components page.

Section "Uninstall"
    Var /GLOBAL ChildUninstall

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
