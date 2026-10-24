"""Zentrale Konfiguration: Pfade und .env-Werte."""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
# LERNAPP_DATA_DIR / LERNAPP_LOG_DIR: fuer Tests auf einen Temp-Ordner umlenken (echte Daten bleiben unberuehrt)
DATA_DIR = Path(os.environ.get("LERNAPP_DATA_DIR") or ROOT / "data")
FILES_DIR = DATA_DIR / "files"
LOG_DIR = Path(os.environ.get("LERNAPP_LOG_DIR") or ROOT / "logs")
DB_PATH = DATA_DIR / "lernapp.db"
STATIC_DIR = ROOT / "app" / "static"

for d in (DATA_DIR, FILES_DIR, LOG_DIR):
    d.mkdir(parents=True, exist_ok=True)

load_dotenv(ROOT / ".env")

STUDIP_BASE = os.getenv("STUDIP_BASE", "https://studip.uni-hannover.de").rstrip("/")
STUDIP_USER = os.getenv("STUDIP_USER", "")
STUDIP_PASSWORD = os.getenv("STUDIP_PASSWORD", "")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "sonnet")
SEMESTER_FILTER = os.getenv("SEMESTER_FILTER", "")
PORT = int(os.getenv("PORT", "8765"))

PLACEHOLDERS = {"", "DEINE-LUH-ID", "DEIN-WEBSSO-PASSWORT"}


def credentials() -> tuple[str, str]:
    """Liest LUH-ID und Passwort frisch aus der .env (damit Aenderungen zur Laufzeit wirken)."""
    from dotenv import dotenv_values

    v = dotenv_values(ROOT / ".env") if (ROOT / ".env").exists() else {}
    user = (v.get("STUDIP_USER") or "").strip()
    pw = (v.get("STUDIP_PASSWORD") or "").strip()
    return ("" if user in PLACEHOLDERS else user, "" if pw in PLACEHOLDERS else pw)


def set_env(values: dict) -> None:
    """Setzt/entfernt Schluessel in der .env (None = Zeile entfernen); andere Zeilen bleiben erhalten."""
    path = ROOT / ".env"
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else \
        ((ROOT / ".env.example").read_text(encoding="utf-8").splitlines() if (ROOT / ".env.example").exists() else [])
    out, seen = [], set()
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
        if key in values:
            seen.add(key)
            if values[key] is not None:
                out.append(f"{key}={str(values[key]).strip()}")
        else:
            out.append(line)
    for k, v in values.items():
        if k not in seen and v is not None:
            out.append(f"{k}={str(v).strip()}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def save_credentials(user: str, password: str, prefix: str = "STUDIP") -> None:
    """Schreibt <PREFIX>_USER/<PREFIX>_PASSWORD in die .env (andere Zeilen bleiben erhalten)."""
    set_env({f"{prefix}_USER": user, f"{prefix}_PASSWORD": password, f"{prefix}_SAME_AS": None})


def _env() -> dict:
    from dotenv import dotenv_values
    return dotenv_values(ROOT / ".env") if (ROOT / ".env").exists() else {}


def service_status(prefix: str) -> dict:
    """Status eines Dienst-Zugangs: eigener Zugang, Verweis auf anderen Dienst oder nichts."""
    v = _env()
    same = (v.get(f"{prefix}_SAME_AS") or "").strip().upper()
    user = (v.get(f"{prefix}_USER") or "").strip(); pw = (v.get(f"{prefix}_PASSWORD") or "").strip()
    own = bool(user and pw and user not in PLACEHOLDERS and pw not in PLACEHOLDERS)
    return {"own": own, "same_as": same.lower() if same else None, "user": user if own else None, "configured": own or bool(same)}


def service_credentials(prefix: str, _depth: int = 0) -> tuple[str, str]:
    """Zugangsdaten eines Dienstes: eigener Eintrag, Verweis (<P>_SAME_AS=QIS) oder Fallback auf die LUH-ID aus Stud.IP."""
    v = _env()
    same = (v.get(f"{prefix}_SAME_AS") or "").strip().upper()
    if same and _depth < 5:
        return credentials() if same == "STUDIP" else service_credentials(same, _depth + 1)
    user = (v.get(f"{prefix}_USER") or "").strip()
    pw = (v.get(f"{prefix}_PASSWORD") or "").strip()
    if user and pw and user not in PLACEHOLDERS and pw not in PLACEHOLDERS:
        return user, pw
    return credentials()


# Dateitypen, deren Text fuer die KI extrahiert wird
TEXT_EXTENSIONS = {".pdf", ".txt", ".md", ".py", ".c", ".h", ".java", ".tex", ".csv", ".pf"}
