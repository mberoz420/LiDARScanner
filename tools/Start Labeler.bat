@echo off
echo Starting LiDAR Scan Watcher...
echo.

:: Install watchdog if not present
python -c "import watchdog" 2>nul || (
    echo Installing watchdog...
    pip install watchdog
)

python "%~dp0watch_scans.py"
pause
