# Baut das MSIX-Paket fuer den Microsoft Store aus der fertigen App (Tauri-exe und PyInstaller-Backend samt Chromium).
# Aufbau wie nach der NSIS-Installation: uniflow-desktop.exe, daneben backend\ (Tauri sucht das Backend im
# Ressourcenordner = Ordner der exe). Bilder aus app-icon.png, Manifest aus msix\AppxManifest.xml.in + msix\store.json,
# Version aus src-tauri\tauri.conf.json (MSIX: vierstellig, letzte Stelle 0 wie vom Store verlangt).
#
# Ohne -TestSign entsteht das unsignierte Paket fuer Partner Center (der Store signiert selbst). Mit -TestSign wird es
# zusaetzlich mit einem selbst erzeugten Zertifikat (Subject = Publisher aus store.json) signiert, damit es sich zum
# Testen installieren laesst (check-msix.ps1); die .cer liegt daneben.
param(
    [Parameter(Mandatory = $true)][string]$AppExe,
    [Parameter(Mandatory = $true)][string]$BackendDir,
    [string]$OutDir = "apps/windows/msix/out",
    [string]$StoreJson = "apps/windows/msix/store.json",
    [string]$TauriConf = "apps/windows/src-tauri/tauri.conf.json",
    [string]$Template = "apps/windows/msix/AppxManifest.xml.in",
    [string]$Icon = "apps/windows/app-icon.png",
    [switch]$TestSign
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

function Find-SdkTool([string]$name) {
    $root = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $hit = Get-ChildItem -Path $root -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $hit) { throw "$name nicht gefunden (Windows SDK unter $root)" }
    return $hit.FullName
}

function New-Png([string]$src, [string]$dst, [int]$w, [int]$h) {
    # Symbol mittig auf transparentem Grund, Kantenlaenge = kleinere Seite (Wide310x150: 150 hoch, mittig)
    $img = [System.Drawing.Image]::FromFile((Resolve-Path $src))
    try {
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $side = [Math]::Min($w, $h)
        $g.DrawImage($img, [int](($w - $side) / 2), [int](($h - $side) / 2), $side, $side)
        $g.Dispose()
        $bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    } finally { $img.Dispose() }
}

function Escape-Xml([string]$s) { return [System.Security.SecurityElement]::Escape($s) }

if (-not (Test-Path $AppExe)) { throw "App fehlt: $AppExe" }
if (-not (Test-Path (Join-Path $BackendDir "uniflow-backend.exe"))) { throw "Backend fehlt: $BackendDir\uniflow-backend.exe" }
if (-not (Get-ChildItem -Path (Join-Path $BackendDir "ms-playwright") -Directory -Filter "chromium-*" -ErrorAction SilentlyContinue)) {
    throw "Chromium fehlt unter $BackendDir\ms-playwright (Hochschul-Anmeldung und Abgleich brauchen es)"
}

$store = Get-Content $StoreJson -Raw -Encoding UTF8 | ConvertFrom-Json
$appVersion = (Get-Content $TauriConf -Raw -Encoding UTF8 | ConvertFrom-Json).version
if ($appVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Unerwartete App-Version '$appVersion' in $TauriConf" }
$version = "$appVersion.0"

$stage = Join-Path $OutDir "stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage "Assets") | Out-Null
Copy-Item $AppExe (Join-Path $stage "uniflow-desktop.exe")
Copy-Item $BackendDir (Join-Path $stage "backend") -Recurse

New-Png $Icon (Join-Path $stage "Assets\StoreLogo.png") 50 50
New-Png $Icon (Join-Path $stage "Assets\Square44x44Logo.png") 44 44
New-Png $Icon (Join-Path $stage "Assets\Square150x150Logo.png") 150 150
New-Png $Icon (Join-Path $stage "Assets\Wide310x150Logo.png") 310 150

$manifest = Get-Content $Template -Raw -Encoding UTF8
$values = @{
    "IDENTITY_NAME" = $store.identity_name; "PUBLISHER" = $store.publisher; "VERSION" = $version
    "DISPLAY_NAME" = $store.display_name; "PUBLISHER_DISPLAY_NAME" = $store.publisher_display_name
    "DESCRIPTION" = $store.description
}
foreach ($k in $values.Keys) { $manifest = $manifest.Replace("{{$k}}", (Escape-Xml ([string]$values[$k]))) }
if ($manifest -match '\{\{[A-Z_]+\}\}') { throw "Platzhalter im Manifest nicht ersetzt: $($Matches[0])" }
[System.IO.File]::WriteAllText((Join-Path $stage "AppxManifest.xml"), $manifest, (New-Object System.Text.UTF8Encoding $false))

$name = "UniFlow_${version}_x64"
$msix = Join-Path $OutDir "$name.msix"
Remove-Item $msix -Force -ErrorAction SilentlyContinue
$makeappx = Find-SdkTool "makeappx.exe"
& $makeappx pack /d $stage /p $msix /o /h SHA256
if ($LASTEXITCODE -ne 0) { throw "makeappx pack fehlgeschlagen ($LASTEXITCODE)" }
Write-Host "MSIX: $msix ($([math]::Round((Get-Item $msix).Length / 1MB)) MB), Version $version, Identity $($store.identity_name)"
if (-not $store.store_ready) { Write-Warning "store.json hat noch Testwerte (store_ready=false): das Paket ist nur zum Testen, nicht fuer Partner Center" }

if ($TestSign) {
    $signtool = Find-SdkTool "signtool.exe"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $store.publisher -KeyUsage DigitalSignature `
        -FriendlyName "UniFlow MSIX Test" -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    try {
        $pwd = ConvertTo-SecureString -String ([guid]::NewGuid().ToString("N")) -Force -AsPlainText
        $pfx = Join-Path $OutDir "test-signing.pfx"
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pwd | Out-Null
        Export-Certificate -Cert $cert -FilePath (Join-Path $OutDir "$name-test.cer") | Out-Null
        $signed = Join-Path $OutDir "$name-test.msix"
        Copy-Item $msix $signed -Force
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))
        & $signtool sign /fd SHA256 /f $pfx /p $plain $signed
        if ($LASTEXITCODE -ne 0) { throw "signtool fehlgeschlagen ($LASTEXITCODE)" }
        Remove-Item $pfx -Force
        Write-Host "Testsigniert: $signed (Zertifikat $name-test.cer)"
    } finally {
        Remove-Item -Path ("Cert:\CurrentUser\My\" + $cert.Thumbprint) -Force -ErrorAction SilentlyContinue
    }
}
