# Installiert den gebauten NSIS-Installer still (/S, aktueller Benutzer, kein Admin), prueft die installierten Dateien,
# startet das installierte Backend (check-backend.ps1) und deinstalliert wieder still. Fuer GitHub-Windows-Runner.
# Installationsordner bei installMode currentUser: %LOCALAPPDATA%\UniFlow (Tauri-NSIS: $LOCALAPPDATA\<productName>).
param(
    [string]$Bundle = "apps/windows/src-tauri/target/release/bundle/nsis",
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "UniFlow")
)
$ErrorActionPreference = "Stop"
$setup = @(Get-ChildItem -Path $Bundle -Filter "*-setup.exe" -ErrorAction SilentlyContinue)
if ($setup.Count -ne 1) { throw "Erwartet genau einen Installer *-setup.exe unter $Bundle, gefunden: $($setup.Count)" }
Write-Host "Installer: $($setup[0].Name) ($([math]::Round($setup[0].Length / 1MB)) MB)"

$p = Start-Process -FilePath $setup[0].FullName -ArgumentList "/S" -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "Installation fehlgeschlagen: Exitcode $($p.ExitCode)" }
$exes = @(Get-ChildItem -Path $InstallDir -Filter "*.exe" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "uninstall.exe" })
if ($exes.Count -ne 1) { throw "Erwartet genau eine App-exe unter $InstallDir, gefunden: $($exes.Name -join ', ')" }
foreach ($f in @("uninstall.exe", "backend\uniflow-backend.exe", "backend\ms-playwright")) {
    if (-not (Test-Path (Join-Path $InstallDir $f))) { throw "Nach der Installation fehlt $f unter $InstallDir" }
}
$chromium = @(Get-ChildItem -Path (Join-Path $InstallDir "backend\ms-playwright") -Directory -Filter "chromium-*")
if ($chromium.Count -eq 0) { throw "Installiertes Paket ohne chromium-* unter backend\ms-playwright" }
Write-Host "Installiert: $($exes[0].Name) unter $InstallDir, Chromium: $($chromium.Name -join ', ')"

& (Join-Path $PSScriptRoot "check-backend.ps1") -Exe (Join-Path $InstallDir "backend\uniflow-backend.exe") -Base (Join-Path $env:TEMP "uniflow-installed-base")

# _?=<ordner>: der Deinstallierer laeuft an Ort und Stelle (sonst kopiert er sich nach %TEMP% und -Wait kehrt zu frueh
# zurueck); dafuer bleibt uninstall.exe selbst liegen und wird danach geloescht.
$u = Start-Process -FilePath (Join-Path $InstallDir "uninstall.exe") -ArgumentList "/S", "_?=$InstallDir" -Wait -PassThru
if ($u.ExitCode -ne 0) { throw "Deinstallation fehlgeschlagen: Exitcode $($u.ExitCode)" }
if (Test-Path (Join-Path $InstallDir $exes[0].Name)) { throw "$($exes[0].Name) ist nach der Deinstallation noch da" }
if (Test-Path (Join-Path $InstallDir "backend\uniflow-backend.exe")) { throw "backend\uniflow-backend.exe ist nach der Deinstallation noch da" }
Remove-Item -Path (Join-Path $InstallDir "uninstall.exe") -Force -ErrorAction SilentlyContinue
Write-Host "Deinstallation OK"
