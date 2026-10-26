"""Zentrale Konfiguration: Pfade und .env-Werte."""
from __future__ import annotations

import contextvars
import os
import re
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent


def env_file() -> Path:
    """Die .env: im Projektordner; die Windows-App (app/desktop.py) legt sie im Benutzerprofil ab
    (LERNAPP_ENV_FILE), weil der Programmordner nicht beschreibbar ist."""
    return Path(os.environ["LERNAPP_ENV_FILE"]) if os.environ.get("LERNAPP_ENV_FILE") else ROOT / ".env"


load_dotenv(env_file(), interpolate=False)

# Hochschule dieser App-Instanz (UNIVERSITY in der .env, Standard universities.DEFAULT). Sie wird beim Start
# festgelegt: jede Uni hat einen eigenen Datenordner (Datenbank, Dateien, Browser-Profile, Protokolle), damit sich
# Daten verschiedener Hochschulen nie vermischen. Ein Wechsel greift nach einem Neustart. Welche Hochschulen es gibt,
# steht nur in universities.PROFILES (eine neue dort wurde hier frueher still zu "luh").


def normalize_university(key: str | None) -> str:
    from . import universities
    k = (key or "").strip().lower()
    return k if universities.valid(k) else universities.DEFAULT


def known_universities() -> tuple[str, ...]:
    """Schluessel aller Hochschulen (Konten, Registrierung): eine Quelle, universities.PROFILES"""
    from . import universities
    return tuple(universities.PROFILES)


def data_dir_for(base: Path, university: str) -> Path:
    """LUH bleibt im bisherigen Ordner (bestehende Daten unveraendert), jede weitere Uni in base/unis/<key>."""
    return base if university == "luh" else base / "unis" / university


UNIVERSITY = normalize_university(os.getenv("UNIVERSITY"))
# LERNAPP_DATA_DIR / LERNAPP_LOG_DIR: fuer Tests auf einen Temp-Ordner umlenken (echte Daten bleiben unberuehrt)
BASE_DATA_DIR = Path(os.environ.get("LERNAPP_DATA_DIR") or ROOT / "data")
BASE_LOG_DIR = Path(os.environ.get("LERNAPP_LOG_DIR") or ROOT / "logs")
DATA_DIR = data_dir_for(BASE_DATA_DIR, UNIVERSITY)
LOG_DIR = data_dir_for(BASE_LOG_DIR, UNIVERSITY)
FILES_DIR = DATA_DIR / "files"
DB_PATH = DATA_DIR / "lernapp.db"
STATIC_DIR = ROOT / "app" / "static"

for d in (DATA_DIR, FILES_DIR, LOG_DIR):
    d.mkdir(parents=True, exist_ok=True)

# Betriebsart: local = eine Person auf dem eigenen PC (PIN im WLAN, Zugangsdaten in der .env);
# hosted = gehosteter Dienst mit UniFlow-Konten (app/accounts.py), jedes Konto mit eigenem Datenordner.
MODE = (os.getenv("LERNAPP_MODE") or "local").strip().lower() or "local"


def is_hosted() -> bool:
    return MODE == "hosted"


# Aktueller Nutzer der laufenden Anfrage (nur hosted): (UniFlow-ID, Hochschule). Contextvars gelten je Aufgabe und
# werden in den Threadpool der Endpunkte kopiert; ohne Kontext gelten die Einzelplatz-Pfade oben.
_ctx_user: contextvars.ContextVar = contextvars.ContextVar("uniflow_user", default=None)
_USER_ID_RE = re.compile(r"^[a-f0-9]{32}$")
_made_dirs: set = set()


def set_user_context(user_id: str | None, university: str | None = None):
    if user_id is not None and not _USER_ID_RE.match(user_id):
        raise ValueError("Ungueltige Nutzer-ID")
    return _ctx_user.set((user_id, normalize_university(university)) if user_id else None)


def reset_user_context(token) -> None:
    _ctx_user.reset(token)


def current_user_id() -> str | None:
    ctx = _ctx_user.get()
    return ctx[0] if ctx else None


def user_data_dir(user_id: str, university: str) -> Path:
    if not _USER_ID_RE.match(user_id or ""):
        raise ValueError("Ungueltige Nutzer-ID")
    return data_dir_for(BASE_DATA_DIR / "users" / user_id, normalize_university(university))


def data_dir() -> Path:
    """Datenordner der laufenden Anfrage: Nutzerordner (hosted) oder der Einzelplatz-Ordner."""
    ctx = _ctx_user.get()
    if not ctx:
        return DATA_DIR
    d = user_data_dir(*ctx)
    if d not in _made_dirs:
        for sub in ("", "files", "logs"):
            (d / sub).mkdir(parents=True, exist_ok=True)
        _made_dirs.add(d)
    return d


def files_dir() -> Path:
    return data_dir() / "files"


def log_dir() -> Path:
    return data_dir() / "logs" if _ctx_user.get() else LOG_DIR


def db_path() -> Path:
    return data_dir() / "lernapp.db"


def university() -> str:
    ctx = _ctx_user.get()
    return ctx[1] if ctx else UNIVERSITY


# Zugangsdaten-Abbild der laufenden Aufgabe (Dienst-Job): dict wie die .env. Ohne Kontext und im gehosteten Modus
# kommen die Werte aus dem Tresor des angemeldeten Kontos (app/vault.py), im Einzelplatzmodus aus der .env.
_ctx_env: contextvars.ContextVar = contextvars.ContextVar("uniflow_env", default=None)


def set_env_context(values: dict | None):
    return _ctx_env.set(dict(values) if values is not None else None)


def reset_env_context(token) -> None:
    _ctx_env.reset(token)


def retire_user_data_dir(user_id: str) -> Path | None:
    """Beim Loeschen eines Kontos: Nutzerordner beiseitelegen (30 Tage), dann `accounts.purge_deleted`."""
    if not _USER_ID_RE.match(user_id or ""):
        raise ValueError("Ungueltige Nutzer-ID")
    src = BASE_DATA_DIR / "users" / user_id
    if not src.exists():
        return None
    from datetime import datetime
    dst = BASE_DATA_DIR / "users-deleted" / f"{user_id}-{datetime.now().strftime('%Y%m%d%H%M%S')}"
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)
    _made_dirs.discard(src)
    return dst


def retired_user_data_dirs(user_id: str) -> list[Path]:
    base = BASE_DATA_DIR / "users-deleted"
    return sorted(base.glob(f"{user_id}-*")) if base.exists() else []

STUDIP_BASE = os.getenv("STUDIP_BASE", "https://studip.uni-hannover.de").rstrip("/")
STUDIP_USER = os.getenv("STUDIP_USER", "")
STUDIP_PASSWORD = os.getenv("STUDIP_PASSWORD", "")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "sonnet")
# Modell fuer Lehrmaterial (Dateianalyse, Wochentests). Vergleich vom 25.10.2026 an 20 Mathe-/ET-Dateien:
# Haiku 5.5 mit PDF-Seiten so gut wie Sonnet 5.5 mit PDF, etwa 1/17 der Kosten (docs/KI-MODELLVERGLEICH-2026-10-25.md)
CLAUDE_MODEL_MATERIAL = os.getenv("CLAUDE_MODEL_MATERIAL", "haiku")
SEMESTER_FILTER = os.getenv("SEMESTER_FILTER", "")
PORT = int(os.getenv("PORT", "8765"))

PLACEHOLDERS = {"", "DEINE-LUH-ID", "DEIN-WEBSSO-PASSWORT"}


def credentials() -> tuple[str, str]:
    """LUH-ID und Passwort: frisch aus der .env (Einzelplatz) bzw. aus dem Tresor des Kontos (Dienst)."""
    v = _env()
    user = (v.get("STUDIP_USER") or "").strip()
    pw = (v.get("STUDIP_PASSWORD") or "").strip()
    return ("" if user in PLACEHOLDERS else user, "" if pw in PLACEHOLDERS else pw)


def set_env(values: dict) -> None:
    """Setzt/entfernt Schluessel in der .env (None = Zeile entfernen); andere Zeilen bleiben erhalten.
    Im gehosteten Modus landen die Werte verschluesselt im Tresor des angemeldeten Kontos, nie in der .env."""
    uid = current_user_id()
    if uid and is_hosted():
        from . import vault
        vault.set_values(uid, values)
        if _ctx_env.get() is not None:
            _ctx_env.set(vault.env_for(uid))
        return
    path = env_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else \
        ((ROOT / ".env.example").read_text(encoding="utf-8").splitlines() if (ROOT / ".env.example").exists() else [])
    for k, v in values.items():
        if v is not None and ("\n" in str(v) or "\r" in str(v)):
            raise ValueError(f"{k}: Zeilenumbrueche sind nicht erlaubt")
    out, seen = [], set()
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
        if key in values:
            seen.add(key)
            if values[key] is not None:
                out.append(f"{key}={_env_quote(values[key])}")
        else:
            out.append(line)
    for k, v in values.items():
        if k not in seen and v is not None:
            out.append(f"{k}={_env_quote(v)}")
    # atomar: erst Temp-Datei, dann ersetzen (ein Absturz mitten im Schreiben darf die Zugangsdaten nicht loeschen)
    tmp = path.with_name(".env.tmp")
    tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _env_quote(v) -> str:
    """Wert in doppelten Anfuehrungszeichen, damit '#', Leerzeichen und Anfuehrungszeichen erhalten bleiben."""
    s = str(v).strip()
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def save_credentials(user: str, password: str, prefix: str = "STUDIP") -> None:
    """Schreibt <PREFIX>_USER/<PREFIX>_PASSWORD in die .env (andere Zeilen bleiben erhalten)."""
    set_env({f"{prefix}_USER": user, f"{prefix}_PASSWORD": password, f"{prefix}_SAME_AS": None})


def _env() -> dict:
    ctx = _ctx_env.get()
    if ctx is not None:
        return dict(ctx)
    uid = current_user_id()
    if uid and is_hosted():
        from . import vault
        return vault.env_for(uid)
    from dotenv import dotenv_values
    return dotenv_values(env_file(), interpolate=False) if env_file().exists() else {}


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


def configured_university() -> str:
    """UNIVERSITY aus der .env, wie sie beim naechsten Start gilt (kann von der laufenden UNIVERSITY abweichen)."""
    if is_hosted():
        return university()                                      # im Dienst steht die Hochschule am Konto
    v = _env().get("UNIVERSITY")
    return normalize_university(v) if v else UNIVERSITY       # nichts in der .env: kein Wechsel vorgemerkt


def own_credentials(prefix: str, _depth: int = 0) -> tuple[str, str]:
    """Nur der eigene Eintrag <PREFIX>_USER/_PASSWORD (oder <PREFIX>_SAME_AS), OHNE Rueckfall auf die LUH-ID.
    Fuer andere Hochschulen waere der LUH-Rueckfall falsch (fremde Zugangsdaten an ein fremdes SSO)."""
    v = _env()
    same = (v.get(f"{prefix}_SAME_AS") or "").strip().upper()
    if same and same != prefix and _depth < 5:
        return own_credentials(same, _depth + 1) if same != "STUDIP" else credentials()
    user = (v.get(f"{prefix}_USER") or "").strip()
    pw = (v.get(f"{prefix}_PASSWORD") or "").strip()
    if user and pw and user not in PLACEHOLDERS and pw not in PLACEHOLDERS:
        return user, pw
    return "", ""


def secret(key: str) -> str:
    """Einzelner geheimer Wert aus der .env (z. B. LEARNWEB_TOKEN), leer wenn nicht gesetzt."""
    val = (_env().get(key) or "").strip()
    return "" if val in PLACEHOLDERS else val


# Dateitypen, deren Text fuer die KI extrahiert wird
TEXT_EXTENSIONS = {".pdf", ".txt", ".md", ".py", ".c", ".h", ".java", ".tex", ".csv", ".pf"}
