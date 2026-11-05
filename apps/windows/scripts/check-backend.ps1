# Startet das gepackte Backend (uniflow-backend.exe) ohne Fenster, wartet auf die Zustandsdatei, prueft
# /api/account/info und die Content-Security-Policy der Oberflaeche und beendet es wieder. Die Zustandsdatei muss die
# PID des gestarteten Prozesses nennen, die URL genau http://127.0.0.1:<port>/ sein und der Port sofort annehmen
# (app/desktop.py bindet ihn, bevor es die Datei schreibt). Genutzt vom Workflow fuer das PyInstaller-Paket und fuer
# das installierte Paket (check-installer.ps1); lokal: pwsh apps/windows/scripts/check-backend.ps1 -Exe <pfad>.
#
# Smoke-Test (05.11.2026, docs/release/WINDOWS-BAU-2026-11-05.md): eine eigene /api/health gibt es nicht; als
# Lebenszeichen gilt /api/account/info. Dazu: Konto-Pflicht aktiv (Status signed_out, Token-Ablage = Windows-
# Anmeldeinformationsverwaltung, gesperrte Route 401 account_required), Anmeldung im Browser mit Loopback-Rueckleitung
# auf genau diesen Server (ohne Browser zu oeffnen), Rueckleitung /konto/rueckkehr erreichbar, Oberflaechen-Dateien vom
# 05.11. und Daten des Studienverlaufs im Paket.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Base = (Join-Path $env:TEMP "uniflow-base"),
    [int]$TimeoutSeconds = 90
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path $Exe)) { throw "Backend fehlt: $Exe" }

# Daten, die app/*.py zur Laufzeit aus dem Paket liest (uniflow-backend.spec; PyInstaller 6 legt sie unter _internal)
$exeDir = Split-Path -Parent (Resolve-Path $Exe)
$dataRoot = if (Test-Path (Join-Path $exeDir "_internal")) { Join-Path $exeDir "_internal" } else { $exeDir }
foreach ($f in @("app\static\index.html", "app\static\study-plan.js", "app\static\study-plan-logic.js",
                 "packages\shared-contracts\study-sources.json", "packages\shared-contracts\study-sources-all.json",
                 "packages\shared-contracts\exam-registration-luh.json",
                 "apps\apple\UniFlow\Resources\StudyCatalogSeed\luh.json.gz")) {
    if (-not (Test-Path (Join-Path $dataRoot $f))) { throw "Im Paket fehlt $f (unter $dataRoot) - uniflow-backend.spec pruefen" }
}
Write-Host "Paketdaten OK ($dataRoot)"

$state = Join-Path $env:TEMP ("uniflow-state-" + [guid]::NewGuid().ToString("N") + ".json")
$p = Start-Process -FilePath $Exe -ArgumentList "--state", "`"$state`"", "--base", "`"$Base`"" -PassThru

function Get-Http([string]$Url, [string]$Method = "GET", [string]$Body = $null) {
    # -SkipHttpErrorCheck: 4xx/5xx sind hier erwartete Antworten, keine Ausnahme (pwsh 7)
    $a = @{ Uri = $Url; Method = $Method; UseBasicParsing = $true; TimeoutSec = 60; SkipHttpErrorCheck = $true }
    if ($Body) { $a.Body = $Body; $a.ContentType = "application/json" }
    return Invoke-WebRequest @a
}

try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path $state) -and (Get-Date) -lt $deadline -and -not $p.HasExited) { Start-Sleep -Milliseconds 300 }
    if ($p.HasExited) { throw "Backend hat sich beendet (Exitcode $($p.ExitCode)); Protokoll: $Base\logs\backend.log" }
    if (-not (Test-Path $state)) { throw "Backend hat in $TimeoutSeconds s keine Zustandsdatei geschrieben" }
    $st = Get-Content $state -Raw | ConvertFrom-Json
    if ($st.pid -ne $p.Id) { throw "Zustandsdatei nennt PID $($st.pid), gestartet wurde $($p.Id)" }
    if ($st.url -notmatch '^http://127\.0\.0\.1:[0-9]+/$') { throw "Unerwartete URL in der Zustandsdatei: $($st.url)" }
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", [int]$st.port)       # muss sofort gehen: der Port ist vor der Datei gebunden
    $tcp.Close()
    $r = Invoke-WebRequest -Uri ($st.url + "api/account/info") -UseBasicParsing -TimeoutSec 60
    if ($r.StatusCode -ne 200) { throw "Backend antwortet nicht: $($r.StatusCode)" }
    $info = $r.Content | ConvertFrom-Json
    if (-not $info.mode) { throw "Antwort ohne 'mode': $($r.Content)" }
    Write-Host "Backend OK ($($st.url)): $($r.Content)"
    $h = Invoke-WebRequest -Uri $st.url -UseBasicParsing -TimeoutSec 60
    if (-not $h.Headers["Content-Security-Policy"]) { throw "Oberflaeche ohne Content-Security-Policy" }
    Write-Host "Content-Security-Policy OK"

    # Oberflaechen-Dateien (Studienverlauf, Abo-Seite, Probe-Hinweis)
    foreach ($f in @("app.js", "study-plan.js", "study-plan-logic.js", "views-abo.js", "trial-hint.js")) {
        $s = Get-Http ($st.url + $f)
        if ($s.StatusCode -ne 200) { throw "Oberflaeche: $f antwortet $($s.StatusCode)" }
    }
    Write-Host "Oberflaechen-Dateien OK"

    # Konto-Pflicht der Windows-App (app/account_mode.py): ohne Anmeldung gesperrt, Token-Ablage im Credential Manager
    $a = Get-Http ($st.url + "api/app-account/status")
    if ($a.StatusCode -ne 200) { throw "api/app-account/status antwortet $($a.StatusCode): $($a.Content)" }
    $acc = $a.Content | ConvertFrom-Json
    if (-not $acc.required) { throw "Konto-Pflicht ist im Paket nicht aktiv: $($a.Content)" }
    if ($acc.state -ne "signed_out") { throw "Frisches Paket sollte abgemeldet sein, Zustand: $($acc.state)" }
    if ($acc.token_store -ne "windows_credential_manager") { throw "Token-Ablage ist '$($acc.token_store)', erwartet windows_credential_manager (ctypes/advapi32 im Paket?)" }
    Write-Host "Konto-Pflicht OK (signed_out, Token-Ablage $($acc.token_store), Dienst $($acc.service_url))"
    $g = Get-Http ($st.url + "api/overview")
    if ($g.StatusCode -ne 401 -or $g.Content -notmatch "account_required") { throw "Gesperrte Route ohne Anmeldung: erwartet 401 account_required, erhalten $($g.StatusCode) $($g.Content)" }
    Write-Host "Sperre ohne Anmeldung OK (401 account_required)"

    # Anmeldung im Systembrowser: Rueckleitung auf genau diesen Server (Loopback, PKCE), Browser bleibt zu
    $b = Get-Http ($st.url + "api/app-account/browser-login") "POST" '{"mode":"login","open_browser":false}'
    if ($b.StatusCode -ne 200) { throw "browser-login antwortet $($b.StatusCode): $($b.Content)" }
    $bl = $b.Content | ConvertFrom-Json
    $expect = $st.url + "konto/rueckkehr"
    if ($bl.redirect_uri -ne $expect) { throw "Rueckleitung '$($bl.redirect_uri)', erwartet $expect" }
    if ($bl.url -notmatch '^https://[^/]+/login\?' -or $bl.url -notmatch 'app=windows' -or $bl.url -notmatch 'code_challenge=') {
        throw "Anmeldeadresse unerwartet: $($bl.url)"
    }
    $cb = Get-Http ($st.url + "konto/rueckkehr?state=unbekannt&code=x")
    if ($cb.StatusCode -ne 400 -or $cb.Content -notmatch "abgelaufen") { throw "Rueckleitung /konto/rueckkehr: erwartet 400 mit Hinweis, erhalten $($cb.StatusCode)" }
    Write-Host "Anmeldung im Browser OK (Rueckleitung $expect, fremder state abgelehnt)"
}
finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Remove-Item -Path $state -Force -ErrorAction SilentlyContinue
}
