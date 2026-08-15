@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: ComfyUI Launcher / Stopper  (Windows)
::
:: Bootstraps and launches a ComfyUI install:
::   1. find or create the Python venv (AMD AI Bundle venv is reused)
::   2. install requirements (AMD ROCm torch handled specially)
::   3. launch main.py in the background, wait until healthy, open browser
::
:: No PID file. Source of truth = whatever is listening on :8188,
:: identity-verified via its command line.
::
:: Usage:
::   comfyui-launcher.cmd              -> start (or reuse) ComfyUI
::   comfyui-launcher.cmd install      -> bootstrap venv + deps only (no launch)
::   comfyui-launcher.cmd stop         -> stop a running ComfyUI instance
::   comfyui-launcher.cmd status       -> print whether ComfyUI is running
::   comfyui-launcher.cmd --no-browser -> start without opening the browser
::
:: Env overrides:
::   COMFYUI_APP    folder containing main.py (default: AMD AI Bundle)
::   COMFYUI_VENV   venv path (default: AMD bundle venv, else COMFYUI_APP\venv)
::   COMFYUI_PORT   port (default: 8188)
:: ============================================================

if defined COMFYUI_PORT (set "PORT=%COMFYUI_PORT%") else (set "PORT=8188")
set "URL=http://127.0.0.1:%PORT%"

:: --- paths ---
if not defined COMFYUI_APP set "COMFYUI_APP=%LOCALAPPDATA%\AMD\AI_Bundle\ComfyUI\ComfyUI"
set "AMD_VENV=%LOCALAPPDATA%\AMD\AI_Bundle\ComfyUI\venv"

if defined COMFYUI_VENV (
    set "VENV_DIR=%COMFYUI_VENV%"
) else if exist "%AMD_VENV%\Scripts\python.exe" (
    set "VENV_DIR=%AMD_VENV%"
) else (
    set "VENV_DIR=%COMFYUI_APP%\venv"
)

set "PY_BIN=%VENV_DIR%\Scripts\python.exe"
set "PYW_BIN=%VENV_DIR%\Scripts\pythonw.exe"
set "REQUIREMENTS=%COMFYUI_APP%\requirements.txt"
set "LOGFILE=%COMFYUI_APP%\comfyui_launcher.log"
set "ERRFILE=%COMFYUI_APP%\comfyui_launcher.err"
set "SENTINEL=%VENV_DIR%\.deps-ready"
set "AMD_INDEX=https://repo.amd.com/rocm/whl-multi-arch/"
if not defined TORCH_CUDA_VER set "TORCH_CUDA_VER=cu126"
set "CUDA_INDEX=https://download.pytorch.org/whl/%TORCH_CUDA_VER%"

:: --- arg parsing ---
set "CMD=start"
set "NO_BROWSER=0"
if /I "%~1"=="stop"         set "CMD=stop"
if /I "%~1"=="install"      set "CMD=install"
if /I "%~1"=="setup"        set "CMD=install"
if /I "%~1"=="status"       set "CMD=status"
if /I "%~1"=="start"        set "CMD=start"
if /I "%~1"=="--no-browser" set "NO_BROWSER=1"
if /I "%~2"=="--no-browser" set "NO_BROWSER=1"
if /I "%~1"=="help"   goto :USAGE
if /I "%~1"=="-h"     goto :USAGE
if /I "%~1"=="--help" goto :USAGE

if "!CMD!"=="status"  goto :STATUS
if "!CMD!"=="stop"    goto :STOP
if "!CMD!"=="install" goto :INSTALL

:: ============================================================
:: START (or reuse)
:: ============================================================
echo ============================================
echo  ComfyUI Launcher
echo ============================================

call :FIND_PORT_OWNER LIVE_PID
if defined LIVE_PID (
    call :VERIFY_IS_COMFYUI "!LIVE_PID!" VERIFIED
    if "!VERIFIED!"=="1" (
        echo ComfyUI is already running ^(PID !LIVE_PID!, verified^).
        if "!NO_BROWSER!"=="0" start "" "%URL%"
        exit /b 0
    ) else (
        echo [WARN] Port %PORT% is already in use by PID !LIVE_PID!, but it is NOT ComfyUI.
        echo Not touching it. Close whatever that is before launching.
        pause
        exit /b 1
    )
)

if not exist "%COMFYUI_APP%\main.py" (
    echo [FATAL] main.py not found at "%COMFYUI_APP%\main.py"
    pause
    exit /b 1
)

call :ENSURE_PYTHON
if errorlevel 1 exit /b 1
call :ENSURE_DEPS
if errorlevel 1 exit /b 1

:: --- launch ---
set "RUN_PY=%PY_BIN%"
if exist "%PYW_BIN%" set "RUN_PY=%PYW_BIN%"

echo Launching ComfyUI in background...
del "%LOGFILE%" >nul 2>&1
del "%ERRFILE%" >nul 2>&1
set "PIDFILE=%VENV_DIR%\.launchpid"
del "%PIDFILE%" >nul 2>&1

powershell -NoProfile -Command "(Start-Process -FilePath '%RUN_PY%' -ArgumentList 'main.py','--port','%PORT%' -WorkingDirectory '%COMFYUI_APP%' -WindowStyle Hidden -PassThru -RedirectStandardOutput '%LOGFILE%' -RedirectStandardError '%ERRFILE%').Id | Set-Content -Encoding Ascii -Path '%PIDFILE%'"

set "NEWPID="
if exist "%PIDFILE%" set /p NEWPID=<"%PIDFILE%"
del "%PIDFILE%" >nul 2>&1

if not defined NEWPID (
    echo [FATAL] Failed to launch ComfyUI process.
    pause
    exit /b 1
)
echo Started with PID !NEWPID! ^(only used to monitor THIS startup^).

:: --- health check ---
set "HEALTHCHECK_PY=%VENV_DIR%\_healthcheck.py"
> "%HEALTHCHECK_PY%" (
    echo import sys, urllib.request
    echo url = sys.argv[1]
    echo try:
    echo     opener = urllib.request.build_opener^(urllib.request.ProxyHandler^({}^)^)
    echo     r = opener.open^(url, timeout=2^)
    echo     print^(r.status^)
    echo except Exception:
    echo     print^('ERROR'^)
    echo     sys.exit^(1^)
)

echo Waiting for ComfyUI to become ready...
set /a TRIES=0
:POLL
tasklist /FI "PID eq !NEWPID!" 2>nul | find "!NEWPID!" >nul
if errorlevel 1 (
    echo.
    echo [FATAL] ComfyUI process ^(PID !NEWPID!^) exited unexpectedly during startup.
    echo ---- Error output ^(%ERRFILE%^) ----
    type "%ERRFILE%"
    echo -------------------------------------
    pause
    exit /b 1
)

set /a TRIES+=1
set "HC_OUT=%VENV_DIR%\_healthcheck_out.txt"
"%PY_BIN%" "%HEALTHCHECK_PY%" "%URL%" > "%HC_OUT%" 2>nul
set "HTTPCODE="
set /p HTTPCODE=<"%HC_OUT%"
if "!HTTPCODE!"=="200" goto :READY

echo   attempt !TRIES!/40 - not ready yet ^(server still starting^)...

if !TRIES! GEQ 40 (
    echo [FATAL] Timed out after !TRIES! attempts ^(~2 minutes^), but the process is still alive.
    echo Check %LOGFILE% / %ERRFILE%, or just open %URL% manually.
    pause
    exit /b 1
)
timeout /t 3 >nul
goto :POLL

:READY
del "%HEALTHCHECK_PY%" >nul 2>&1
del "%VENV_DIR%\_healthcheck_out.txt" >nul 2>&1
echo ComfyUI is up and responding.
if "!NO_BROWSER!"=="0" start "" "%URL%"
exit /b 0

:: ============================================================
:: INSTALL (bootstrap only, do not launch)
:: ============================================================
:INSTALL
if not exist "%COMFYUI_APP%\main.py" (
    echo [FATAL] main.py not found at "%COMFYUI_APP%\main.py"
    pause
    exit /b 1
)
call :ENSURE_PYTHON
if errorlevel 1 exit /b 1
call :ENSURE_DEPS
if errorlevel 1 exit /b 1
echo Bootstrap complete. Launch with: comfyui-launcher.cmd
exit /b 0

:: ============================================================
:: STATUS
:: ============================================================
:STATUS
call :FIND_PORT_OWNER LIVE_PID
if defined LIVE_PID (
    call :VERIFY_IS_COMFYUI "!LIVE_PID!" VERIFIED
    if "!VERIFIED!"=="1" (
        echo ComfyUI is running ^(PID !LIVE_PID!^).
        exit /b 0
    )
)
echo ComfyUI is not running.
exit /b 1

:: ============================================================
:: STOP
:: ============================================================
:STOP
echo Stopping ComfyUI...
call :FIND_PORT_OWNER LIVE_PID
if not defined LIVE_PID (
    echo Nothing is listening on port %PORT%. Nothing to stop.
    exit /b 0
)
call :VERIFY_IS_COMFYUI "!LIVE_PID!" VERIFIED
if "!VERIFIED!"=="1" (
    taskkill /PID !LIVE_PID! /F >nul 2>&1
    echo Stopped PID !LIVE_PID! ^(verified ComfyUI^).
) else (
    echo [WARN] PID !LIVE_PID! is on port %PORT% but is NOT ComfyUI. Not touching it.
)
exit /b 0

:: ============================================================
:: USAGE
:: ============================================================
:USAGE
echo Usage:
echo   comfyui-launcher.cmd              start (or reuse) ComfyUI
echo   comfyui-launcher.cmd install      bootstrap venv + deps only
echo   comfyui-launcher.cmd stop         stop a running instance
echo   comfyui-launcher.cmd status       print running state
echo   comfyui-launcher.cmd --no-browser start without opening the browser
exit /b 0

:: ============================================================
:: Subroutine: ENSURE_PYTHON
:: ============================================================
:ENSURE_PYTHON
if exist "%PY_BIN%" (
    "%PY_BIN%" -m pip --version >nul 2>&1
    if not errorlevel 1 (
        echo Using venv python: %PY_BIN%
        exit /b 0
    )
    echo [WARN] venv at %VENV_DIR% has no working pip - trying to repair...
    "%PY_BIN%" -m ensurepip --upgrade >nul 2>&1
    if not errorlevel 1 (
        echo Repaired pip via ensurepip.
        exit /b 0
    )
    echo [FATAL] Could not repair pip. Remove or recreate the venv manually:
    echo   rmdir /s /q "%VENV_DIR%"   ^(then re-run this script^)
    pause
    exit /b 1
)
echo No venv found - creating one...
set "SYSPY="
for /f "delims=" %%P in ('where python 2^>nul') do if not defined SYSPY set "SYSPY=%%P"
if not defined SYSPY (
    echo [FATAL] No Python found. Install Python 3 first.
    pause
    exit /b 1
)
echo Creating venv at "%VENV_DIR%" using "%SYSPY%" ...
"%SYSPY%" -m venv "%VENV_DIR%"
if not exist "%PY_BIN%" (
    echo [FATAL] venv creation failed.
    pause
    exit /b 1
)
"%PY_BIN%" -m pip --version >nul 2>&1
if errorlevel 1 (
    echo [FATAL] venv created but pip is missing. Reinstall Python with venv support.
    pause
    exit /b 1
)
echo Created venv: %VENV_DIR%
exit /b 0

:: ============================================================
:: Subroutine: ENSURE_DEPS
:: ============================================================
:ENSURE_DEPS
if not exist "%REQUIREMENTS%" (
    echo [FATAL] requirements.txt not found at "%REQUIREMENTS%"
    pause
    exit /b 1
)

:: detect backend: torch's own report wins, else environment markers
set "BACKEND=cpu"
"%PY_BIN%" -c "import torch" >nul 2>&1
if not errorlevel 1 (
    "%PY_BIN%" -c "import torch; import sys; sys.exit(0 if torch.version.hip else 1)" >nul 2>&1
    if not errorlevel 1 set "BACKEND=rocm"
    "%PY_BIN%" -c "import torch; import sys; sys.exit(0 if torch.version.cuda else 1)" >nul 2>&1
    if not errorlevel 1 set "BACKEND=cuda"
) else (
    if exist "%AMD_VENV%\Scripts\python.exe" set "BACKEND=rocm"
    if "!BACKEND!"=="cpu" (
        nvidia-smi >nul 2>&1
        if not errorlevel 1 set "BACKEND=cuda"
    )
)

:: torch stack: only ROCm and Windows-CUDA need a special index
if "!BACKEND!"=="rocm" (
    "%PY_BIN%" -c "import torch; import sys; sys.exit(0 if torch.version.hip else 1)" >nul 2>&1
    if errorlevel 1 (
        echo Installing ROCm torch stack ...
        "%PY_BIN%" -m pip install --index-url "%AMD_INDEX%" torch torchvision torchaudio
        if errorlevel 1 (
            echo [FATAL] Failed to install ROCm torch stack.
            pause
            exit /b 1
        )
    ) else (
        echo ROCm torch already installed - skipping torch stack.
    )
) else if "!BACKEND!"=="cuda" (
    "%PY_BIN%" -c "import torch; import sys; sys.exit(0 if torch.version.cuda else 1)" >nul 2>&1
    if errorlevel 1 (
        echo Installing CUDA torch stack ^(index %TORCH_CUDA_VER%^) ...
        "%PY_BIN%" -m pip install --index-url "%CUDA_INDEX%" torch torchvision torchaudio
        if errorlevel 1 (
            echo [FATAL] Failed to install CUDA torch stack.
            pause
            exit /b 1
        )
    ) else (
        echo CUDA torch already installed - skipping torch stack.
    )
)

:: sentinel hash of requirements.txt
set "COMFY_REQ=%REQUIREMENTS%"
set "STAMP="
for /f "delims=" %%H in ('"%PY_BIN%" -c "import hashlib,os;print(hashlib.sha256(open(os.environ['COMFY_REQ'],'rb').read()).hexdigest())" 2^>nul') do set "STAMP=%%H"

if exist "%SENTINEL%" (
    set /p OLDSTAMP=<"%SENTINEL%"
    if "!OLDSTAMP!"=="!STAMP!" (
        echo Dependencies up to date - skipping install.
        exit /b 0
    )
)

echo Installing requirements ...
"%PY_BIN%" -m pip install -r "%REQUIREMENTS%"
if errorlevel 1 (
    echo [FATAL] Failed to install requirements.
    pause
    exit /b 1
)
if defined STAMP (
    > "%SENTINEL%" echo !STAMP!
)
echo Dependencies installed.
exit /b 0

:: ============================================================
:: Subroutine: FIND_PORT_OWNER
:: ============================================================
:FIND_PORT_OWNER
set "%~1="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT%" ^| findstr "LISTENING"') do (
    set "%~1=%%a"
)
exit /b 0

:: ============================================================
:: Subroutine: VERIFY_IS_COMFYUI
:: ============================================================
:VERIFY_IS_COMFYUI
setlocal
set "CHECK_PID=%~1"
set "RESULT=0"
tasklist /FI "PID eq %CHECK_PID%" 2>nul | find "%CHECK_PID%" >nul
if errorlevel 1 (
    endlocal & set "%~2=0" & exit /b 0
)
set "CMDFILE=%TEMP%\_comfy_cmdline_%CHECK_PID%.txt"
powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"ProcessId=%CHECK_PID%\").CommandLine" > "%CMDFILE%" 2>nul
set "CMDLINE="
set /p CMDLINE=<"%CMDFILE%"
del "%CMDFILE%" >nul 2>&1
echo !CMDLINE! | findstr /I "main.py" >nul
if not errorlevel 1 set "RESULT=1"
endlocal & set "%~2=%RESULT%"
exit /b 0
