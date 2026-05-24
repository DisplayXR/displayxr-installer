@echo off
:: Build the DisplayXR end-user meta-installer .exe for Windows.
::
:: Reads versions.json, downloads each component's Windows installer
:: from its GitHub Release, and wraps the four .exe files in a single
:: NSIS bundle that chains them via ExecWait /S at install time.
::
:: Output: _out\DisplayXRBundle-<version>.exe
::
:: Mirrors the per-component asset table inline (Windows batch can't
:: source the runtime repo's scripts/lib/components.sh which is bash).
:: Keep the table in sync with that file when components change.

setlocal EnableDelayedExpansion

set "BUNDLE_VERSION="
set "KEEP_STAGE=0"

:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--version" (
    set "BUNDLE_VERSION=%~2"
    shift & shift
    goto :parse_args
)
if /i "%~1"=="--keep-stage" (
    set "KEEP_STAGE=1"
    shift
    goto :parse_args
)
if /i "%~1"=="-h" goto :usage
if /i "%~1"=="--help" goto :usage
echo ERROR: unknown arg '%~1'
exit /b 1

:usage
echo Usage: %~nx0 --version vX.Y.Z [--keep-stage]
echo.
echo Builds _out\DisplayXRBundle-X.Y.Z.exe from the per-component .exe
echo installers pinned in versions.json.
echo.
echo Prerequisites: gh (authenticated), makensis (NSIS 3.x), PowerShell.
exit /b 0

:args_done
if "%BUNDLE_VERSION%"=="" (
    echo ERROR: --version is required ^(e.g. --version v0.1.0^)
    exit /b 1
)
:: Strip leading 'v' from the version string for NSIS PRODUCT_VERSION.
if /i "%BUNDLE_VERSION:~0,1%"=="v" set "BUNDLE_VERSION=%BUNDLE_VERSION:~1%"

:: Determine REPO_ROOT. cmd's %~dp0 is unreliable under
::   cmd /S /C "CALL <temp.cmd>"
:: (the GitHub Actions `shell: cmd` invocation pattern): it returns the
:: caller's CWD instead of the script's own directory. Two sources we
:: can trust:
::   - GITHUB_WORKSPACE is always set on GitHub Actions runners.
::   - %CD% is the repo root for local-dev invocations from the repo
::     root (the documented usage).
:: Using `if defined ... set` (no parenthesized block) avoids the
:: delayed-expansion pitfall with %VAR% inside parens.
set "REPO_ROOT="
if defined GITHUB_WORKSPACE set "REPO_ROOT=%GITHUB_WORKSPACE%"
if "%REPO_ROOT%"=="" set "REPO_ROOT=%CD%"
set "VERSIONS_JSON=%REPO_ROOT%\versions.json"
set "STAGE=%REPO_ROOT%\_stage"
set "OUT_DIR=%REPO_ROOT%\_out"

if not exist "%VERSIONS_JSON%" (
    echo ERROR: versions.json not found at %VERSIONS_JSON%
    echo        Run scripts\build-bundle.bat from the repo root.
    exit /b 1
)

:: Wipe stage; preserve _out for prior artifacts.
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%" 2>nul
mkdir "%OUT_DIR%" 2>nul

:: --- Component table (mirrors displayxr-runtime/scripts/lib/components.sh) ---
:: Keep in lockstep with that file. Columns: REPO, EXE_WINDOWS glob.

set "COMPONENT_REPO_runtime=DisplayXR/displayxr-runtime"
set "COMPONENT_EXE_runtime=DisplayXRSetup-*.exe"

set "COMPONENT_REPO_shell=DisplayXR/displayxr-shell-releases"
set "COMPONENT_EXE_shell=DisplayXRShellSetup-*.exe"

set "COMPONENT_REPO_leia_plugin=DisplayXR/displayxr-leia-plugin"
set "COMPONENT_EXE_leia_plugin=DisplayXRLeiaSRSetup-*.exe"

set "COMPONENT_REPO_mcp_tools=DisplayXR/displayxr-mcp"
set "COMPONENT_EXE_mcp_tools=DisplayXRMCPSetup-*.exe"

:: --- Read pins from versions.json ---
:: Per PR DisplayXR/displayxr-runtime#291 fix #1: use function-call form
:: for ConvertFrom-Json, NOT a pipe inside `for /f`. cmd's re-quoting of
:: paths-with-spaces inside `for /f usebackq` breaks the pipe form.

call :read_pin runtime     RUNTIME_TAG
call :read_pin shell       SHELL_TAG
call :read_pin leia_plugin LEIA_TAG
call :read_pin mcp_tools   MCP_TAG

if "%RUNTIME_TAG%"=="" ( echo ERROR: versions.json missing 'runtime' pin & exit /b 1 )
if "%SHELL_TAG%"==""   ( echo ERROR: versions.json missing 'shell' pin & exit /b 1 )
if "%LEIA_TAG%"==""    ( echo ERROR: versions.json missing 'leia_plugin' pin & exit /b 1 )
if "%MCP_TAG%"==""     ( echo ERROR: versions.json missing 'mcp_tools' pin & exit /b 1 )

echo ==^> DisplayXR bundle build
echo     bundle:      v%BUNDLE_VERSION%
echo     runtime:     %RUNTIME_TAG%
echo     shell:       %SHELL_TAG%
echo     leia_plugin: %LEIA_TAG%
echo     mcp_tools:   %MCP_TAG%

:: --- Download each component's installer into _stage\<name>\ ---
call :download_component runtime     %RUNTIME_TAG% || exit /b 1
call :download_component shell       %SHELL_TAG%   || exit /b 1
call :download_component leia_plugin %LEIA_TAG%    || exit /b 1
call :download_component mcp_tools   %MCP_TAG%    || exit /b 1

:: --- Capture the actual downloaded filenames (globs may match different builds) ---
call :find_exe runtime     RUNTIME_EXE_FILE || exit /b 1
call :find_exe shell       SHELL_EXE_FILE   || exit /b 1
call :find_exe leia_plugin LEIA_EXE_FILE    || exit /b 1
call :find_exe mcp_tools   MCP_EXE_FILE    || exit /b 1

:: Copy all four .exe files into _stage\bundle\ where NSIS expects them.
set "BUNDLE_STAGE=%STAGE%\bundle"
mkdir "%BUNDLE_STAGE%" 2>nul
copy /Y "%STAGE%\runtime\%RUNTIME_EXE_FILE%"        "%BUNDLE_STAGE%\" >nul || exit /b 1
copy /Y "%STAGE%\shell\%SHELL_EXE_FILE%"            "%BUNDLE_STAGE%\" >nul || exit /b 1
copy /Y "%STAGE%\leia_plugin\%LEIA_EXE_FILE%"       "%BUNDLE_STAGE%\" >nul || exit /b 1
copy /Y "%STAGE%\mcp_tools\%MCP_EXE_FILE%"         "%BUNDLE_STAGE%\" >nul || exit /b 1
copy /Y "%REPO_ROOT%\LICENSE"                       "%BUNDLE_STAGE%\" >nul || exit /b 1

:: --- Invoke makensis ---
echo ==^> makensis -^> %OUT_DIR%\DisplayXRBundle-%BUNDLE_VERSION%.exe

:: Quote every /D value so makensis doesn't tokenize on whitespace when
:: BUNDLE_STAGE / OUT_DIR contains a space (e.g. dev machines under
:: C:\Users\<name with space>\...). CI's GITHUB_WORKSPACE is space-free
:: so this only surfaces on local runs.
makensis ^
    "/DBUNDLE_VERSION=%BUNDLE_VERSION%" ^
    "/DRUNTIME_EXE=%RUNTIME_EXE_FILE%" ^
    "/DSHELL_EXE=%SHELL_EXE_FILE%" ^
    "/DLEIA_EXE=%LEIA_EXE_FILE%" ^
    "/DMCP_EXE=%MCP_EXE_FILE%" ^
    "/DBUNDLE_STAGE=%BUNDLE_STAGE%" ^
    "/DOUTPUT_DIR=%OUT_DIR%" ^
    "%REPO_ROOT%\installer\windows\DisplayXRBundleInstaller.nsi"
if errorlevel 1 (
    echo ERROR: makensis failed
    exit /b 1
)

if "%KEEP_STAGE%"=="0" rmdir /s /q "%STAGE%"

echo ==^> Done. Output: %OUT_DIR%\DisplayXRBundle-%BUNDLE_VERSION%.exe
exit /b 0


:: ============================================================
:: Helpers
:: ============================================================

:read_pin
:: %1 = key name (e.g. runtime, shell)
:: %2 = output variable name
:: Per PR #291 fix #1: ConvertFrom-Json (Get-Content ...) — NOT a pipe.
set "_RP_KEY=%~1"
set "_RP_VAR=%~2"
set "%_RP_VAR%="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "$d = ConvertFrom-Json (Get-Content -Raw '%VERSIONS_JSON%'); $v = $d.%_RP_KEY%; if ($v) { Write-Output $v }"`) do set "%_RP_VAR%=%%i"
exit /b 0


:download_component
:: %1 = component name (runtime, shell, leia_plugin, mcp_tools)
:: %2 = tag (e.g. v1.4.2)
set "_DC_NAME=%~1"
set "_DC_TAG=%~2"
call set "_DC_REPO=%%COMPONENT_REPO_%_DC_NAME%%%"
call set "_DC_GLOB=%%COMPONENT_EXE_%_DC_NAME%%%"
set "_DC_DIR=%STAGE%\%_DC_NAME%"
mkdir "%_DC_DIR%" 2>nul

echo ==^> [%_DC_NAME% @ %_DC_TAG%] downloading from %_DC_REPO% ^(pattern: %_DC_GLOB%^)
gh release download "%_DC_TAG%" --repo "%_DC_REPO%" --pattern "%_DC_GLOB%" --dir "%_DC_DIR%"
if errorlevel 1 (
    echo ERROR: gh release download failed for %_DC_NAME%
    exit /b 1
)
exit /b 0


:find_exe
:: %1 = component name
:: %2 = output variable name (filename only, not full path)
:: Resolves the wildcard to a real filename and sets the output variable.
set "_FE_NAME=%~1"
set "_FE_VAR=%~2"
set "%_FE_VAR%="
for %%f in ("%STAGE%\%_FE_NAME%\*.exe") do set "%_FE_VAR%=%%~nxf"
if "!%_FE_VAR%!"=="" (
    echo ERROR: no .exe landed for %_FE_NAME% in %STAGE%\%_FE_NAME%\
    exit /b 1
)
exit /b 0
