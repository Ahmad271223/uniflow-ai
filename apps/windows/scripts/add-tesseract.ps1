# Legt Tesseract fuer die Texterkennung (app/pageocr.py, docs/OCR-WINDOWS.md) neben das gepackte Backend:
#   <Target>\tesseract.exe, die DLLs, tessdata\deu.traineddata und tessdata\eng.traineddata, LIZENZEN.txt.
# Quelle des Programms: Windows-Build der UB Mannheim 5.4.0.20240606 (Apache-2.0), Sprachdaten: tessdata_fast 4.1.0
# (Apache-2.0). Version und SHA-256 jedes Downloads sind fest (Werte am 04.11.2026 beim ersten Laden gebildet; eine
# geaenderte Datei bricht den Lauf ab). Fuer GitHub-Windows-Runner (der Installer braucht Adminrechte, die der Runner hat).
#
# Ablauf (05.11.2026 robuster gemacht, Ursache des Fehlers vom 04.11. in docs/release/WINDOWS-BAU-2026-11-05.md):
#  1. Installer laden (3 Versuche) und Pruefsumme vergleichen.
#  2. Still installieren. Der Installer der UB Mannheim uebergeht "/D=<ordner>" und installiert nach
#     "C:\Program Files\Tesseract-OCR" (Lauf 41929677402 brach daran ab); darum werden danach nur feste Orte geprueft:
#     /D-Ordner, Registry (InstallDir / Uninstall-Eintrag), %ProgramFiles%\Tesseract-OCR - bis zu 120 s lang, ohne
#     Platte rekursiv zu durchsuchen (das kostete im Lauf 41993722721 zweieinhalb Minuten).
#  3. Rueckfall: den NSIS-Installer mit 7-Zip entpacken (auf windows-latest vorhanden), ganz ohne Installation.
#  4. Gefundenes Programm muss genau Version 5.4.0 melden (kein zufaellig vorinstalliertes anderes Tesseract).
#  5. Kopieren, Pflichtdateien pruefen, aus dem Zielordner starten (DLLs vollstaendig?), Sprachen und Probe-Erkennung.
# Jeder Fehler endet mit "add-tesseract: ..." und sagt, was fehlt und wo gesucht wurde.
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Work = (Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) "tesseract-build"),
    [string]$Setup = ""          # optional: bereits geladener Installer (Pruefsumme wird trotzdem verglichen)
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Fortschrittsbalken bremst Invoke-WebRequest stark
$tessVersion = "5.4.0.20240606"
$setupUrl = "https://github.com/UB-Mannheim/tesseract/releases/download/v$tessVersion/tesseract-ocr-w64-setup-$tessVersion.exe"
$setupSha = "c885fff6998e0608ba4bb8ab51436e1c6775c2bafc2559a19b423e18678b60c9"
$langs = @{
    "deu" = "19d219bbb6672c869d20a9636c6816a81eb9a71796cb93ebe0cb1530e2cdb22d"
    "eng" = "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"
}
# ohne diese Dateien startet tesseract.exe nicht (Kern und Bildbibliothek)
$requiredFiles = @("tesseract.exe", "libtesseract-5.dll", "libleptonica-6.dll")

function Fail([string]$Message) { throw "add-tesseract: $Message" }

function Test-Sha([string]$Path, [string]$Sha) {
    $h = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $h -eq $Sha
}

function Get-Checked([string]$Url, [string]$Out, [string]$Sha) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -TimeoutSec 300
        } catch {
            Write-Host "Download $i/3 von $Url gescheitert: $($_.Exception.Message)"
            if ($i -eq 3) { Fail "Download gescheitert nach 3 Versuchen: $Url" }
            Start-Sleep -Seconds (5 * $i)
            continue
        }
        break
    }
    $h = (Get-FileHash -Path $Out -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $Sha) { throw "Pruefsumme stimmt nicht fuer $Url`n erwartet $Sha`n erhalten $h`n(Datei auf dem Server geaendert? Dann Version und Pruefsumme bewusst neu festlegen.)" }
    Write-Host "OK $([System.IO.Path]::GetFileName($Out)) ($([math]::Round((Get-Item $Out).Length / 1MB, 1)) MB)"
}

function Get-TessVersion([string]$Exe) {
    # "tesseract v5.4.0.20240606" in der ersten Zeile (stdout oder stderr, je nach Build)
    $out = & $Exe --version 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Find-Installed([string]$DDir) {
    $cands = [System.Collections.Generic.List[string]]::new()
    $cands.Add($DDir)
    foreach ($key in @("HKLM:\SOFTWARE\Tesseract-OCR", "HKLM:\SOFTWARE\WOW6432Node\Tesseract-OCR")) {
        $v = (Get-ItemProperty -Path $key -Name "InstallDir" -ErrorAction SilentlyContinue).InstallDir
        if ($v) { $cands.Add($v) }
    }
    foreach ($key in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Tesseract-OCR",
                       "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Tesseract-OCR")) {
        $u = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($u.InstallLocation) { $cands.Add($u.InstallLocation) }
        if ($u.UninstallString) { $cands.Add((Split-Path ($u.UninstallString.Trim('"')) -Parent)) }
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($root) { $cands.Add((Join-Path $root "Tesseract-OCR")); $cands.Add((Join-Path $root "Programs\Tesseract-OCR")) }
    }
    foreach ($c in ($cands | Select-Object -Unique)) {
        $exe = Join-Path $c "tesseract.exe"
        if (Test-Path $exe) { return Get-Item $exe }
    }
    $script:searched = $cands | Select-Object -Unique
    return $null
}

# ---------------------------------------------------------------- 1. Installer
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$setupFile = Join-Path $Work "tesseract-setup.exe"
if ($Setup) {
    if (-not (Test-Path $Setup)) { Fail "Installer nicht gefunden: $Setup" }
    Copy-Item $Setup $setupFile -Force
    if (-not (Test-Sha $setupFile $setupSha)) { throw "Pruefsumme stimmt nicht fuer $Setup (erwartet $setupSha)" }
    Write-Host "OK vorhandener Installer $Setup"
} elseif ((Test-Path $setupFile) -and (Test-Sha $setupFile $setupSha)) {
    Write-Host "OK Installer schon geladen ($setupFile)"
} else {
    Get-Checked $setupUrl $setupFile $setupSha
}

# ---------------------------------------------------------------- 2. still installieren, feste Orte pruefen
# /D muss das letzte Argument sein, ohne Anfuehrungszeichen (NSIS); der Installer uebergeht es, siehe Kopf.
$inst = Join-Path $Work "installiert"
$found = $null
$p = Start-Process -FilePath $setupFile -ArgumentList "/S", "/D=$inst" -Wait -PassThru
Write-Host "Installer-Exitcode: $($p.ExitCode)"
if ($p.ExitCode -eq 0) {
    # der Installer kann sich neu starten (UAC/Elevation) und schreibt dann noch: bis zu 120 s auf die Datei warten
    $deadline = (Get-Date).AddSeconds(120)
    do {
        $found = Find-Installed $inst
        if ($found) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if (-not $found) { Write-Host "Nach der Installation kein tesseract.exe an diesen Orten: $($script:searched -join '; ')" }
} else {
    Write-Host "Installer meldet Fehler $($p.ExitCode) - weiter mit 7-Zip"
}
if ($found) {
    $v = Get-TessVersion $found.FullName
    if ($v.Text -notmatch [regex]::Escape("5.4.0")) {
        Write-Host "Gefundenes Tesseract unter $($found.DirectoryName) meldet '$($v.Text)', erwartet $tessVersion - nicht genommen"
        $found = $null
    }
}

# ---------------------------------------------------------------- 3. Rueckfall: NSIS-Installer mit 7-Zip entpacken
if (-not $found) {
    $seven = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") + @((Get-Command 7z.exe -ErrorAction SilentlyContinue).Source) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $seven) { Fail "tesseract.exe nicht gefunden: Installation fand nichts ($($script:searched -join '; ')) und 7-Zip (7z.exe) fehlt fuer den Rueckfall" }
    $x = Join-Path $Work "entpackt"
    Remove-Item -Recurse -Force $x -ErrorAction SilentlyContinue
    Write-Host "Entpacke den Installer mit $seven"
    & $seven x $setupFile "-o$x" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "7-Zip konnte den Installer nicht entpacken (Exitcode $LASTEXITCODE)" }
    $found = Get-ChildItem -Path $x -Recurse -Filter "tesseract.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        Write-Host "--- Inhalt von ${x} (Auszug):"
        Get-ChildItem -Path $x -Recurse -ErrorAction SilentlyContinue | Select-Object -First 80 FullName, Length | Format-Table -AutoSize | Out-String | Write-Host
        Fail "tesseract.exe nicht gefunden (Installation und 7-Zip-Entpacken gescheitert, siehe Liste oben)"
    }
}
$src = $found.Directory.FullName
Write-Host "Tesseract gefunden unter $src"
foreach ($f in $requiredFiles) {
    if (-not (Test-Path (Join-Path $src $f))) { Fail "Im Tesseract-Ordner $src fehlt $f (unvollstaendige Installation/Entpackung?)" }
}

# ---------------------------------------------------------------- 4. kopieren
# nur, was die Erkennung braucht: Programm, DLLs, Konfiguration, Lizenz-/Hinweistexte (keine Trainingsprogramme)
Remove-Item -Recurse -Force $Target -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $Target "tessdata") | Out-Null
Copy-Item (Join-Path $src "tesseract.exe") $Target
Get-ChildItem $src -Filter "*.dll" | Copy-Item -Destination $Target
foreach ($d in @("configs", "tessconfigs")) {
    $cfg = Join-Path $src "tessdata\$d"
    if (Test-Path $cfg) { Copy-Item -Recurse $cfg (Join-Path $Target "tessdata\$d") }
}
$notices = Join-Path $Target "lizenzen"
New-Item -ItemType Directory -Force -Path $notices | Out-Null
Get-ChildItem $src -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|AUTHORS)' -or $_.Name -match '\.(license|licence)$' } |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $notices ($_.Directory.Name + "-" + $_.Name)) -Force }
foreach ($l in $langs.Keys) {
    Get-Checked "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/4.1.0/$l.traineddata" (Join-Path $Target "tessdata\$l.traineddata") $langs[$l]
}
@"
Texterkennung in StudiNow: Tesseract OCR $tessVersion (Windows-Build der UB Mannheim, $setupUrl)
Lizenz: Apache License 2.0, https://github.com/tesseract-ocr/tesseract/blob/main/LICENSE
Sprachdaten deu und eng: tessdata_fast 4.1.0, Apache License 2.0, https://github.com/tesseract-ocr/tessdata_fast
Mitgelieferte Bibliotheken (DLLs dieses Ordners) stammen aus dem Build der UB Mannheim; ihre Hinweise liegen, soweit
der Installer sie mitbringt, im Ordner "lizenzen" (u. a. Leptonica BSD-2, zlib, libpng, libtiff, libjpeg, openjpeg, webp, giflib).
"@ | Set-Content -Path (Join-Path $Target "LIZENZEN.txt") -Encoding utf8

# ---------------------------------------------------------------- 5. pruefen: Dateien, Start aus dem Ziel, Sprachen, Probe
foreach ($f in ($requiredFiles + @("tessdata\deu.traineddata", "tessdata\eng.traineddata", "LIZENZEN.txt"))) {
    if (-not (Test-Path (Join-Path $Target $f))) { Fail "Nach dem Kopieren fehlt $f unter $Target" }
}
$exe = Join-Path $Target "tesseract.exe"
$tessdata = Join-Path $Target "tessdata"
$v = Get-TessVersion $exe
if ($v.Code -ne 0 -or $v.Text -notmatch [regex]::Escape("5.4.0")) {
    Fail "tesseract.exe startet im Zielordner nicht richtig (Exitcode $($v.Code), fehlt eine DLL?): $($v.Text)"
}
Write-Host "Version: $(($v.Text -split "`n")[0])"

# Probe 1: Sprachen
$list = & $exe --tessdata-dir $tessdata --list-langs 2>&1 | Out-String
foreach ($l in $langs.Keys) { if ($list -notmatch "(?m)^$l\s*$") { Fail "Sprache $l fehlt: $list" } }

# Probe 2: erzeugtes Bild mit deutschem Text als PGM (wie app/pageocr.py) lesen
Add-Type -AssemblyName System.Drawing
$w = 1400; $hgt = 220
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$font = New-Object System.Drawing.Font "Arial", 40
$g.DrawString("Übungsblatt Klausur Größe", $font, [System.Drawing.Brushes]::Black, 30, 60)
$g.Dispose()
$pixels = New-Object byte[] ($w * $hgt)
$rect = New-Object System.Drawing.Rectangle 0, 0, $w, $hgt
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$row = New-Object byte[] ($data.Stride)
for ($y = 0; $y -lt $hgt; $y++) {
    [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $y * $data.Stride), $row, 0, $data.Stride)
    for ($x = 0; $x -lt $w; $x++) { $pixels[$y * $w + $x] = [byte](($row[3 * $x] + $row[3 * $x + 1] + $row[3 * $x + 2]) / 3) }
}
$bmp.UnlockBits($data); $bmp.Dispose()
$pgm = Join-Path $Work "probe.pgm"
$head = [System.Text.Encoding]::ASCII.GetBytes("P5`n$w $hgt`n255`n")
[System.IO.File]::WriteAllBytes($pgm, [byte[]]($head + $pixels))
$out = & $exe $pgm stdout --tessdata-dir $tessdata -l deu+eng --psm 3 2>$null | Out-String
Write-Host "Erkannt: $($out.Trim())"
if ($out -notmatch "Klausur") { Fail "Probe-Erkennung fand 'Klausur' nicht: $out" }

$size = (Get-ChildItem $Target -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host "Tesseract im Paket: $Target ($([math]::Round($size / 1MB, 1)) MB)"
