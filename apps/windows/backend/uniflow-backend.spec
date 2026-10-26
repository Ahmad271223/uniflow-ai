# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller-Paket des UniFlow-Backends fuer die Windows-App (Ordner-Paket, kein Entpacken beim Start).

Aufruf im Projektordner:  pyinstaller apps/windows/backend/uniflow-backend.spec --noconfirm --distpath apps/windows/backend/dist
Ergebnis: apps/windows/backend/dist/uniflow-backend/uniflow-backend.exe (+ _internal). Chromium kommt NICHT aus
PyInstaller: der Workflow legt Playwrights Browser-Ordner als `ms-playwright` neben die exe (app/desktop.py sucht dort).
"""
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

ROOT = Path(SPECPATH).resolve().parents[2]
sys.path.insert(0, str(ROOT))

datas = [(str(ROOT / "app" / "static"), "app/static"), (str(ROOT / ".env.example"), ".")]
datas += collect_data_files("tzdata")                 # Zeitzonen (Windows hat keine eigene Datenbank)
datas += collect_data_files("playwright")             # Node-Treiber von Playwright (ohne Browser)
hidden = collect_submodules("app") + [
    "uvicorn.logging", "uvicorn.loops.auto", "uvicorn.loops.asyncio", "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl", "uvicorn.protocols.websockets.auto", "uvicorn.protocols.websockets.websockets_impl",
    "uvicorn.lifespan.on", "uvicorn.lifespan.off", "multipart", "python_multipart", "dotenv", "pypdf", "cryptography",
]

a = Analysis(
    [str(Path(SPECPATH) / "entry.py")],
    pathex=[str(ROOT)],
    binaries=[],
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
