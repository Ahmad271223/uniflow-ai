"""StudiNow-Erklärungen zum Kaufen: je Kursdatei ein fertiges PDF (Erklärung Seite für Seite bzw. Lösung Schritt für
Schritt, Wasserzeichen „StudiNow“), einmal mit Credits gekauft, danach immer dabei (Auftrag des Inhabers vom 22.11.2026:
„neben VL 3 anzeigen mit einem Kreis ‚es gibt Erklärung von StudiNow‘, man klickt drauf, bestätigt mit 15 Credits
kaufen, dann hat man das immer dazu“; „Ja, App-Teil bauen“).

Woher die PDFs kommen: Sie entstehen auf dem Mac des Inhabers aus der Wissensbibliothek (dort von Claude ausgearbeitet
und nachgerechnet) und werden mit tools/erklaerungen-pdf-hochladen.sh in das Daten-Volume gelegt:
BASE_DATA_DIR/erklaerungen-pdf/index.json (sha256 -> titel, art, pdf_seiten, pfad) und pdf/<sha[:2]>/<sha>.pdf.
Schlüssel ist die SHA-256 der Kursdatei: Wer dieselbe Datei hat (Stud.IP liefert allen im Kurs dieselbe), bekommt
dasselbe PDF. Der Dienst erfährt dabei nur Prüfsummen, keine Dateinamen.

Kaufen: fester Preis (LERNAPP_ERKLAERUNG_PREIS, Standard 15 Credits), über credits.reserve + settle wie der
Klausur-Generator. Ein zweiter Kauf derselben Datei kostet nichts. Gekauft bleibt gekauft, auch wenn das PDF später
durch eine verbesserte Fassung ersetzt wird (dann bekommt der Käufer die neue). Käufe in accounts.db
(`erklaerung_kaeufe`), beim Löschen des Kontos mit gelöscht, im Datenexport enthalten.

Nur Pro AI (Recht `can_use_ai_explanations`) und mit bestätigter E-Mail-Adresse, wie der Klausur-Generator.
Ausgeschaltet (LERNAPP_ERKLAERUNGEN nicht „1“) oder ohne index.json: das Angebot ist leer, die App zeigt nichts.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

from . import config

PURPOSE = "shop:erklaerung"
MAX_OFFER = 2000                      # so viele Prüfsummen fragt ein Gerät höchstens auf einmal
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
ARTEN = ("Erklärung Seite für Seite", "Lösung Schritt für Schritt")

_lock = threading.Lock()
_cache: dict = {"stamp": None, "index": {}}


class ShopError(Exception):
    def __init__(self, status: int, code: str, detail: str, extra: dict | None = None):
        super().__init__(detail)
        self.status, self.code, self.detail, self.extra = status, code, detail, extra or {}


def switched_on() -> bool:
    return (os.environ.get("LERNAPP_ERKLAERUNGEN") or "").strip() == "1"


def price() -> int:
    try:
        return max(1, min(1000, int(os.environ.get("LERNAPP_ERKLAERUNG_PREIS") or 15)))
    except ValueError:
        return 15


def directory() -> Path:
    return config.BASE_DATA_DIR / "erklaerungen-pdf"


# ---------------------------------------------------------------- Verzeichnis der PDFs

def index() -> dict:
    """sha256 -> Eintrag; neu gelesen, sobald sich index.json ändert (Upload tauscht den Ordner aus)"""
    p = directory() / "index.json"
    try:
        st = p.stat()
    except OSError:
        return {}
    stamp = (st.st_ino, st.st_mtime_ns, st.st_size)
    with _lock:
        if _cache["stamp"] == stamp:
            return _cache["index"]
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    out = {}
    for sha, e in (raw.items() if isinstance(raw, dict) else []):
        if not (isinstance(e, dict) and SHA_RE.match(str(sha)) and isinstance(e.get("pfad"), str)):
            continue
        rel = Path(e["pfad"])
        if rel.is_absolute() or ".." in rel.parts:                 # nur Pfade innerhalb des Ordners
            continue
        out[str(sha)] = {"title": str(e.get("titel") or "")[:200], "kind": str(e.get("art") or "")[:60],
                         "pages": int(e.get("pdf_seiten") or 0), "file": rel.as_posix(),
                         "stand": str(e.get("stand") or "")[:20]}
    with _lock:
        _cache.update(stamp=stamp, index=out)
    return out


def available() -> dict:
    return index() if switched_on() else {}


def clean_shas(v: object) -> list[str]:
    if not isinstance(v, list) or len(v) > MAX_OFFER:
        raise ShopError(422, "bad_request", f"sha256: Liste mit höchstens {MAX_OFFER} Prüfsummen erwartet.")
    out = []
    for s in v:
        s = str(s or "").strip().lower()
        if SHA_RE.match(s) and s not in out:
            out.append(s)
    return out


# ---------------------------------------------------------------- Käufe (accounts.db)

SCHEMA = """
CREATE TABLE IF NOT EXISTS erklaerung_kaeufe (
    user_id TEXT NOT NULL,
    sha256 TEXT NOT NULL,                  -- Prüfsumme der Kursdatei
    request_id TEXT NOT NULL,
    credits INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (user_id, sha256)
);
"""


def _ensure(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    from . import accounts, billing, db
    conn = billing.connect()
    db.schema_once(conn, "erklaerung_kaeufe", accounts.db_path(), _ensure)
    return conn


def owned(user_id: str) -> set[str]:
    conn = connect()
    try:
        return {r[0] for r in conn.execute("SELECT sha256 FROM erklaerung_kaeufe WHERE user_id=?", (user_id,))}
    finally:
        conn.close()


def _item(sha: str, e: dict, mine: set[str]) -> dict:
    return {"sha256": sha, "title": e["title"], "kind": e["kind"], "pages": e["pages"], "owned": sha in mine,
            "stand": e["stand"]}


def offer(user_id: str, shas_in: object) -> dict:
    """Welche der Dateien eine StudiNow-Erklärung haben, mit Preis und ob das Konto sie schon hat"""
    shas = clean_shas(shas_in)
    idx = available()
    mine = owned(user_id) if idx else set()
    return {"enabled": bool(idx), "price": price(), "items": [_item(s, idx[s], mine) for s in shas if s in idx]}


def mine(user_id: str) -> dict:
    """Alles, was das Konto gekauft hat und das es noch gibt (damit holt jedes Gerät Gekauftes von selbst ab)"""
    idx = index()
    have = owned(user_id)
    return {"items": [_item(s, idx[s], have) for s in sorted(have) if s in idx]}


def buy(user_id: str, sha_in: object) -> dict:
    from . import ai_prices, credits
    sha = str(sha_in or "").strip().lower()
    if not SHA_RE.match(sha):
        raise ShopError(422, "bad_request", "sha256 erwartet.")
    idx = available()
    if sha not in idx:
        raise ShopError(404, "not_available", "Zu dieser Datei gibt es (noch) keine Erklärung von StudiNow.")
    if sha in owned(user_id):
        return {**_item(sha, idx[sha], {sha}), "charged": 0}
    cost = price()
    rid = f"erkl:{sha}"
    conn = credits.connect()
    try:
        try:
            r = credits.reserve(conn, user_id, rid, PURPOSE, cost)
        except credits.CreditsError as e:
            raise ShopError(e.status, e.code, e.message, getattr(e, "extra", None) or {}) from e
        charged = 0 if r.replay else credits.settle(conn, user_id, rid, cost * ai_prices.MICROEUR_PER_CREDIT, model="shop")
    finally:
        conn.close()
    c = connect()
    try:
        with c:
            c.execute("INSERT OR IGNORE INTO erklaerung_kaeufe(user_id, sha256, request_id, credits, created_at) VALUES (?,?,?,?,?)",
                      (user_id, sha, rid, cost, datetime.now(timezone.utc).isoformat()))
    finally:
        c.close()
    return {**_item(sha, idx[sha], {sha}), "charged": int(charged or 0)}


def pdf_for(user_id: str, sha_in: str) -> Path:
    sha = str(sha_in or "").strip().lower()
    idx = index()
    if not SHA_RE.match(sha) or sha not in idx:
        raise ShopError(404, "not_found", "Nicht gefunden.")
    if sha not in owned(user_id):
        raise ShopError(402, "not_owned", "Diese Erklärung ist noch nicht gekauft.")
    p = (directory() / idx[sha]["file"]).resolve()
    if directory().resolve() not in p.parents or not p.is_file():
        raise ShopError(404, "not_found", "Nicht gefunden.")
    return p

