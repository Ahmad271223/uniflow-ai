# Startet das gepackte Backend (uniflow-backend.exe) ohne Fenster, wartet auf die Zustandsdatei, prueft
# /api/account/info und die Content-Security-Policy der Oberflaeche und beendet es wieder. Die Zustandsdatei muss die
# PID des gestarteten Prozesses nennen, die URL genau http://127.0.0.1:<port>/ sein und der Port sofort annehmen
# (app/desktop.py bindet ihn, bevor es die Datei schreibt). Genutzt vom Workflow fuer das PyInstaller-Paket und fuer
# das installierte Paket (check-installer.ps1); lokal: pwsh apps/windows/scripts/check-backend.ps1 -Exe <pfad>.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Base = (Join-Path $env:TEMP "uniflow-base"),
    [int]$TimeoutSeconds = 90
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path $Exe)) { throw "Backend fehlt: $Exe" }
$state = Join-Path $env:TEMP ("uniflow-state-" + [guid]::NewGuid().ToString("N") + ".json")
$p = Start-Process -FilePath $Exe -ArgumentList "--state", "`"$state`"", "--base", "`"$Base`"" -PassThru
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
}
finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Remove-Item -Path $state -Force -ErrorAction SilentlyContinue
}
