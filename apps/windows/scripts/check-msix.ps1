# Prueft das testsignierte MSIX-Paket auf einem GitHub-Windows-Runner (nur dort: das Testzertifikat wird dafuer der
# Maschine als vertrauenswuerdig hinzugefuegt). Installiert das Paket, prueft die Dateien am Installationsort, startet
# das Backend IM Paketkontext (Invoke-CommandInDesktopPackage, also mit derselben Dateisystem-Umleitung wie die App),
# wartet auf die Zustandsdatei, fragt /api/account/info ab und deinstalliert wieder. Das Fenster (WebView2) wird nicht
# gestartet; das prueft der Mensch auf einem echten Rechner.
param(
    [string]$OutDir = "apps/windows/msix/out",
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = "Stop"
$signed = @(Get-ChildItem -Path $OutDir -Filter "*-test.msix")
$cer = @(Get-ChildItem -Path $OutDir -Filter "*-test.cer")
if ($signed.Count -ne 1 -or $cer.Count -ne 1) { throw "Erwartet genau ein *-test.msix und *-test.cer unter $OutDir" }

Import-Certificate -FilePath $cer[0].FullName -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
Add-AppxPackage -Path $signed[0].FullName
$pkg = Get-AppxPackage | Where-Object { $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation "uniflow-desktop.exe")) } | Select-Object -First 1
if (-not $pkg) { throw "Paket nach Add-AppxPackage nicht gefunden" }
Write-Host "Installiert: $($pkg.PackageFullName) unter $($pkg.InstallLocation)"
try {
    foreach ($f in @("uniflow-desktop.exe", "backend\uniflow-backend.exe", "backend\ms-playwright", "AppxManifest.xml", "Assets\Square150x150Logo.png")) {
        if (-not (Test-Path (Join-Path $pkg.InstallLocation $f))) { throw "Im installierten Paket fehlt $f" }
    }
    if (-not (Get-ChildItem -Path (Join-Path $pkg.InstallLocation "backend\ms-playwright") -Directory -Filter "chromium-*")) {
        throw "Installiertes Paket ohne chromium-* unter backend\ms-playwright"
    }

    # Zustandsdatei und Datenordner ausserhalb von AppData: dort schreibt auch ein Paketprozess ohne Umleitung
    $work = "C:\uniflow-msix-check"
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $state = Join-Path $work "state.json"
    $exe = Join-Path $pkg.InstallLocation "backend\uniflow-backend.exe"
    Invoke-CommandInDesktopPackage -PackageFamilyName $pkg.PackageFamilyName -AppId "UniFlow" -Command $exe `
        -Args "--state `"$state`" --base `"$work\base`""
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path $state) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path $state)) {
        $log = Join-Path $work "base\logs\backend.log"
        if (Test-Path $log) { Get-Content $log -Tail 30 }
        throw "Backend im Paket hat in $TimeoutSeconds s keine Zustandsdatei geschrieben"
    }
    $st = Get-Content $state -Raw | ConvertFrom-Json
    if ($st.url -notmatch '^http://127\.0\.0\.1:[0-9]+/$') { throw "Unerwartete URL: $($st.url)" }
    $r = Invoke-WebRequest -Uri ($st.url + "api/account/info") -UseBasicParsing -TimeoutSec 60
    if ($r.StatusCode -ne 200 -or -not ($r.Content | ConvertFrom-Json).mode) { throw "Backend im Paket antwortet nicht richtig: $($r.StatusCode) $($r.Content)" }
    Write-Host "Backend im Paketkontext OK ($($st.url)): $($r.Content)"
}
finally {
    Get-Process -Name "uniflow-backend" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-AppxPackage -Package $pkg.PackageFullName
    Write-Host "Deinstalliert"
}
