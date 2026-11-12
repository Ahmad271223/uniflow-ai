# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller-Paket des UniFlow-Backends fuer die Windows-App (Ordner-Paket, kein Entpacken beim Start).

Aufruf im Projektordner:  pyinstaller apps/windows/backend/uniflow-backend.spec --noconfirm --distpath apps/windows/backend/dist
Ergebnis: apps/windows/backend/dist/uniflow-backend/uniflow-backend.exe (+ _internal). Chromium kommt NICHT aus
PyInstaller: der Workflow legt Playwrights Browser-Ordner als `ms-playwright` neben die exe (app/desktop.py sucht dort).
"""
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules

ROOT = Path(SPECPATH).resolve().parents[2]
sys.path.insert(0, str(ROOT))

datas = [(str(ROOT / "app" / "static"), "app/static"), (str(ROOT / ".env.example"), "."),
         (str(ROOT / "docs" / "release"), "docs/release")]            # Rechtsseiten (app/legal.py)
# Studienverlauf (app/study_catalog.py liest ROOT/packages/... und ROOT/apps/apple/...): Register der Quellen und
# Grundstock der Modulkataloge (nur Fakten, 0,3 MB) im selben Unterpfad wie im Repo, sonst bleibt die Katalogsuche leer.
# Nicht noetig: study-area-rules-luh.json (steckt schon im Grundstock, tools/build-luh-seed.py) und luh-index.json (nur
# der Swift-Kern). tests/test_windows_package.py prueft, dass jede Datei, die app/*.py so liest, hier steht.
datas += [(str(ROOT / "packages" / "shared-contracts" / "study-sources.json"), "packages/shared-contracts"),
          (str(ROOT / "packages" / "shared-contracts" / "study-sources-all.json"), "packages/shared-contracts"),
          # Pruefungsanmeldung der LUH und der Uni Hildesheim (app/exam_registration.py liest sie zur Laufzeit; 30 + 30 KB)
          (str(ROOT / "packages" / "shared-contracts" / "exam-registration-luh.json"), "packages/shared-contracts"),
          (str(ROOT / "packages" / "shared-contracts" / "exam-registration-hildesheim.json"), "packages/shared-contracts"),
          (str(ROOT / "packages" / "shared-contracts" / "exam-registration-hsh.json"), "packages/shared-contracts"),
          (str(ROOT / "packages" / "shared-contracts" / "mensa.json"), "packages/shared-contracts"),
          (str(ROOT / "packages" / "shared-contracts" / "rooms.json"), "packages/shared-contracts"),
          (str(ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed" / "luh.json.gz"),
           "apps/apple/UniFlow/Resources/StudyCatalogSeed"),
          # Grundstock der Universitaet Hildesheim (tools/build-hildesheim-seed.py, 0,1 MB)
          (str(ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed" / "hildesheim.json.gz"),
           "apps/apple/UniFlow/Resources/StudyCatalogSeed"),
          # Grundstock der Hochschule Hannover (tools/build-hsh-seed.py, 0,1 MB)
          (str(ROOT / "apps" / "apple" / "UniFlow" / "Resources" / "StudyCatalogSeed" / "hsh.json.gz"),
           "apps/apple/UniFlow/Resources/StudyCatalogSeed")]
datas += collect_data_files("tzdata")                 # Zeitzonen (Windows hat keine eigene Datenbank)
datas += collect_data_files("playwright")             # Node-Treiber von Playwright (ohne Browser)
# Texterkennung fuer Scan-Seiten (app/pageocr.py, docs/OCR-WINDOWS.md): pypdfium2 rendert die Seiten (pdfium.dll). Ohne das
# Paket im Build bleiben die Listen leer und die App laeuft wie bisher. tesseract.exe und tessdata (deu, eng) liegen NICHT
# in diesem Paket, sondern als Ordner `tesseract` neben der exe (wie `ms-playwright`; legt der Workflow hinein, noch offen).
binaries = []
for _pkg in ("pypdfium2", "pypdfium2_raw"):
    datas += collect_data_files(_pkg)
    binaries += collect_dynamic_libs(_pkg)
hidden = collect_submodules("app") + [
    "uvicorn.logging", "uvicorn.loops.auto", "uvicorn.loops.asyncio", "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl", "uvicorn.protocols.websockets.auto", "uvicorn.protocols.websockets.websockets_impl",
    "uvicorn.lifespan.on", "uvicorn.lifespan.off", "multipart", "python_multipart", "dotenv", "pypdf", "cryptography",
    "pypdfium2", "pypdfium2_raw",
    # Bild importieren (Pillow legt das Bild als PDF-Seite ab, app/server.py api_notebook_create; 12.11.2026). Der Import steht in einer
    # Funktion; PyInstaller findet ihn meist selbst, hier zur Sicherheit genannt. Nicht unter Windows gebaut (Kurzpruefung im Workflow).
    "PIL", "PIL.Image", "PIL.PngImagePlugin", "PIL.JpegImagePlugin", "PIL.GifImagePlugin", "PIL.WebPImagePlugin",
]

a = Analysis(
    [str(Path(SPECPATH) / "entry.py")],
    pathex=[str(ROOT)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hidden,
    hookspath=[],
    runtime_hooks=[],
    excludes=["tkinter", "pytest", "PyInstaller", "pip", "setuptools"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="uniflow-backend",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,                                    # kein Konsolenfenster; Protokoll unter %LOCALAPPDATA%\UniFlow\logs
    icon=None,
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="uniflow-backend")
