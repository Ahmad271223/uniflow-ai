"""Einstieg der uniflow-backend.exe (PyInstaller): Server fuer das Tauri-Fenster, siehe app/desktop.py."""
import sys

from app.desktop import main

if __name__ == "__main__":
    sys.exit(main())
