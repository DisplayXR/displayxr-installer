; DisplayXR end-user meta-installer (issue DisplayXR/displayxr-runtime#284)
; Chains the runtime + Shell + Leia plug-in + MCP Tools installers in
; one guided flow. Each child is invoked silently (/S); the bundle
; itself takes the single UAC prompt + SmartScreen warning at launch.
;
; Build inputs (passed by scripts/build-bundle.bat via /D):
;   BUNDLE_VERSION   e.g. 0.1.0
;   RUNTIME_EXE      filename of staged runtime installer
;   SHELL_EXE        filename of staged shell installer
;   LEIA_EXE         filename of staged leia plug-in installer
;   MCP_EXE          filename of staged mcp tools installer
;   BUNDLE_STAGE     absolute path to dir containing the four .exe files + LICENSE
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
!ifndef BUNDLE_STAGE
    !error "BUNDLE_STAGE not defined"
!endif
!ifndef OUTPUT_DIR
    !error "OUTPUT_DIR not defined"
!endif

Name        "DisplayXR ${BUNDLE_VERSION}"
OutFile     "${OUTPUT_DIR}\DisplayXRBundle-${BUNDLE_VERSION}.exe"
RequestExecutionLevel admin
; The bundle itself doesn't install files long-term; everything goes to
; staging in $TEMP and is wiped after the children run. The children
; install into their own Program Files locations.
InstallDir  "$TEMP\DisplayXRBundle-${BUNDLE_VERSION}"
ShowInstDetails show
ShowUninstDetails show

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${BUNDLE_STAGE}\LICENSE"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;--------------------------------
; Init — run all HKLM access in the 64-bit view.
;
; NSIS bundles default to 32-bit, which silently redirects
; HKLM\Software\... reads and writes through WOW6432Node. All four
; child installers (runtime, shell, leia, mcp) write their state to
; the real 64-bit view, so without SetRegView 64 our ARP entry lands
; in WOW6432Node (where Add/Remove Programs doesn't show it) and the
; uninstall section's ReadRegStr for each child returns empty —
; silently skipping the whole chain.
;--------------------------------

Function .onInit
    SetRegView 64
FunctionEnd

Function un.onInit
    SetRegView 64
FunctionEnd

;--------------------------------
; Install
;--------------------------------

Section "DisplayXR full stack" SecMain
    SectionIn RO

    SetOutPath "$INSTDIR"
    File "${BUNDLE_STAGE}\${RUNTIME_EXE}"
    File "${BUNDLE_STAGE}\${SHELL_EXE}"
    File "${BUNDLE_STAGE}\${LEIA_EXE}"
    File "${BUNDLE_STAGE}\${MCP_EXE}"

    ; -- Runtime --
    DetailPrint "Installing DisplayXR Runtime..."
    ClearErrors
    ExecWait '"$INSTDIR\${RUNTIME_EXE}" /S' $0
    ${If} $0 != 0
        MessageBox MB_OK|MB_ICONSTOP "DisplayXR Runtime installer exited with code $0. Aborting bundle."
        Abort
    ${EndIf}

    ; -- Shell --
    DetailPrint "Installing DisplayXR Shell..."
    ClearErrors
    ExecWait '"$INSTDIR\${SHELL_EXE}" /S' $0
    ${If} $0 != 0
        MessageBox MB_OK|MB_ICONSTOP "DisplayXR Shell installer exited with code $0. Aborting bundle."
        Abort
    ${EndIf}

    ; -- Leia SR Plug-in --
    DetailPrint "Installing Leia SR Plug-in..."
    ClearErrors
    ExecWait '"$INSTDIR\${LEIA_EXE}" /S' $0
    ${If} $0 != 0
        MessageBox MB_OK|MB_ICONSTOP "Leia SR Plug-in installer exited with code $0. Aborting bundle."
        Abort
    ${EndIf}

    ; -- MCP Tools --
    DetailPrint "Installing DisplayXR MCP Tools..."
    ClearErrors
    ExecWait '"$INSTDIR\${MCP_EXE}" /S' $0
    ${If} $0 != 0
        MessageBox MB_OK|MB_ICONSTOP "DisplayXR MCP Tools installer exited with code $0. Aborting bundle."
        Abort
    ${EndIf}

    ; Bundle Add/Remove Programs entry so the user has one place to
    ; remove the whole stack. UninstallString runs our reverse-chain.
    WriteUninstaller "$INSTDIR\Uninstall-DisplayXRBundle.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "DisplayName"     "DisplayXR ${BUNDLE_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "Publisher"       "DisplayXR"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "DisplayVersion"  "${BUNDLE_VERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "UninstallString" "$INSTDIR\Uninstall-DisplayXRBundle.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "QuietUninstallString" '"$INSTDIR\Uninstall-DisplayXRBundle.exe" /S'
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle" \
        "NoRepair" 1

    ; Wipe the staged .exe copies — children have already landed their
    ; files in Program Files, so the staged installers are dead weight.
    ; Keep Uninstall-DisplayXRBundle.exe.
    Delete "$INSTDIR\${RUNTIME_EXE}"
    Delete "$INSTDIR\${SHELL_EXE}"
    Delete "$INSTDIR\${LEIA_EXE}"
    Delete "$INSTDIR\${MCP_EXE}"
SectionEnd


;--------------------------------
; Uninstall
;--------------------------------
;
; Walk each child's UninstallString in reverse install order
; (MCP → Leia → Shell → Runtime). Runtime last so its
; DeleteRegKey /ifempty Software\DisplayXR cleanup catches any orphan
; subkeys (per PR DisplayXR/displayxr-runtime#291 fix #4).

Section "Uninstall"
    Var /GLOBAL ChildUninstall

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

    ; Tear down our own ARP entry.
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXRBundle"

    ; Catch any orphan parent key the runtime's own /ifempty cleanup
    ; missed. Defensive — runtime already does this, but harmless if
    ; the key is gone or non-empty.
    DeleteRegKey /ifempty HKLM "Software\DisplayXR"

    Delete "$INSTDIR\Uninstall-DisplayXRBundle.exe"
    RMDir "$INSTDIR"
SectionEnd
