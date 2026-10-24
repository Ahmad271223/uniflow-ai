@echo off
rem Startet die Lern-App im WLAN-Modus (iPad-Zugriff, PIN-geschuetzt). Laufenden Server vorher beenden.
cd /d "%~dp0"
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8765 " ^| findstr "0.0.0.0:0"') do taskkill /PID %%p /F >nul 2>&1
echo UniFlow AI startet im WLAN-Modus ...
".venv\Scripts\python.exe" serve.py --lan
pause
