# Legt Tesseract fuer die Texterkennung (app/pageocr.py, docs/OCR-WINDOWS.md) neben das gepackte Backend:
#   <Target>\tesseract.exe, die DLLs, tessdata\deu.traineddata und tessdata\eng.traineddata, LIZENZEN.txt.
# Quelle des Programms: Windows-Build der UB Mannheim (Apache-2.0), Sprachdaten: tessdata_fast 4.1.0 (Apache-2.0).
# Alle Downloads sind mit SHA-256 festgelegt (Werte am 04.11.2026 beim ersten Laden gebildet; eine geaenderte Datei
# bricht den Lauf ab). Danach Probe: Sprachen auflisten und ein erzeugtes Graustufenbild (PGM wie in pageocr.py) lesen.
# Fuer GitHub-Windows-Runner (Installer der UB Mannheim braucht Adminrechte, die der Runner hat).
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Work = (Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) "tesseract-build")
)
$ErrorActionPreference = "Stop"
$setupUrl = "https://github.com/UB-Mannheim/tesseract/releases/download/v5.4.0.20240606/tesseract-ocr-w64-setup-5.4.0.20240606.exe"
$setupSha = "c885fff6998e0608ba4bb8ab51436e1c6775c2bafc2559a19b423e18678b60c9"
$langs = @{
    "deu" = "19d219bbb6672c869d20a9636c6816a81eb9a71796cb93ebe0cb1530e2cdb22d"
    "eng" = "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"
}

function Get-Checked([string]$Url, [string]$Out, [string]$Sha) {
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
    $h = (Get-FileHash -Path $Out -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $Sha) { throw "Pruefsumme stimmt nicht fuer $Url`n erwartet $Sha`n erhalten $h" }
    Write-Host "OK $([System.IO.Path]::GetFileName($Out)) ($([math]::Round((Get-Item $Out).Length / 1MB, 1)) MB)"
}

Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$setup = Join-Path $Work "tesseract-setup.exe"
Get-Checked $setupUrl $setup $setupSha

# Weg 1: NSIS still in einen eigenen Ordner installieren (/D muss das letzte Argument sein, ohne Anfuehrungszeichen).
# Der Installer kann sich selbst neu starten; darum danach kurz warten und die Datei ueberall suchen.
$inst = Join-Path $Work "installiert"
$p = Start-Process -FilePath $setup -ArgumentList "/S", "/D=$inst" -Wait -PassThru
Write-Host "Installer-Exitcode: $($p.ExitCode)"
Start-Sleep -Seconds 10
function Find-Tesseract {
    $roots = @($Work, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        $hit = Get-ChildItem -Path $r -Recurse -Filter "tesseract.exe" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\tesseract-build\\tesseract-setup' } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}
$found = Find-Tesseract
# Weg 2: der NSIS-Installer laesst sich mit 7-Zip entpacken, ganz ohne Installation
if (-not $found) {
    Write-Host "tesseract.exe nach der Installation nicht gefunden - versuche 7-Zip"
    $seven = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($seven) {
        $x = Join-Path $Work "entpackt"
        & $seven x $setup "-o$x" -y | Out-Null
        $found = Get-ChildItem -Path $x -Recurse -Filter "tesseract.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    } else { Write-Host "7-Zip nicht gefunden" }
}
if (-not $found) {
    Write-Host "--- Inhalt von ${Work}:"
    Get-ChildItem -Path $Work -Recurse -ErrorAction SilentlyContinue | Select-Object -First 80 FullName, Length | Format-Table -AutoSize | Out-String | Write-Host
    throw "tesseract.exe nicht gefunden (Installation und 7-Zip-Entpacken gescheitert, siehe Liste oben)"
}
$inst = $found.Directory.FullName
Write-Host "Tesseract gefunden unter $inst"

# nur, was die Erkennung braucht: Programm, DLLs, Konfiguration, Lizenz-/Hinweistexte (keine Trainingsprogramme)
Remove-Item -Recurse -Force $Target -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $Target "tessdata") | Out-Null
Copy-Item (Join-Path $inst "tesseract.exe") $Target
Get-ChildItem $inst -Filter "*.dll" | Copy-Item -Destination $Target
foreach ($d in @("configs", "tessconfigs")) {
    $src = Join-Path $inst "tessdata\$d"
    if (Test-Path $src) { Copy-Item -Recurse $src (Join-Path $Target "tessdata\$d") }
}
$notices = Join-Path $Target "lizenzen"
New-Item -ItemType Directory -Force -Path $notices | Out-Null
Get-ChildItem $inst -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|AUTHORS)' -or $_.Name -match '\.(license|licence)$' } |
    ForEach-Object { Copy-Item $_.FullName (Join-Path $notices ($_.Directory.Name + "-" + $_.Name)) -Force }
foreach ($l in $langs.Keys) {
    Get-Checked "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/4.1.0/$l.traineddata" (Join-Path $Target "tessdata\$l.traineddata") $langs[$l]
}
@"
Texterkennung in StudiNow: Tesseract OCR 5.4.0 (Windows-Build der UB Mannheim, $setupUrl)
Lizenz: Apache License 2.0, https://github.com/tesseract-ocr/tesseract/blob/main/LICENSE
Sprachdaten deu und eng: tessdata_fast 4.1.0, Apache License 2.0, https://github.com/tesseract-ocr/tessdata_fast
Mitgelieferte Bibliotheken (DLLs dieses Ordners) stammen aus dem Build der UB Mannheim; ihre Hinweise liegen, soweit
der Installer sie mitbringt, im Ordner "lizenzen" (u. a. Leptonica BSD-2, zlib, libpng, libtiff, libjpeg, openjpeg, webp, giflib).
"@ | Set-Content -Path (Join-Path $Target "LIZENZEN.txt") -Encoding utf8

# Probe 1: Sprachen
$exe = Join-Path $Target "tesseract.exe"
$tessdata = Join-Path $Target "tessdata"
$list = & $exe --tessdata-dir $tessdata --list-langs 2>&1 | Out-String
foreach ($l in $langs.Keys) { if ($list -notmatch "(?m)^$l\s*$") { throw "Sprache $l fehlt: $list" } }

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
if ($out -notmatch "Klausur") { throw "Probe-Erkennung fand 'Klausur' nicht: $out" }

$size = (Get-ChildItem $Target -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host "Tesseract im Paket: $Target ($([math]::Round($size / 1MB, 1)) MB)"
