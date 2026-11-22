"""Formelblaetter (Auftrag des Inhabers 22.11.2026): fertige PDFs zu einem Modul, mit Pro AI einmal fuer feste Credits
kaufen (das erste: Formelblatt zur Kurzklausur „Grundlagen digitaler Systeme“, LUH, 3 Credits). Wortlaut: „alle die jz
sich anmelden bei studinow und modul grundlagen digitaler system hat soll das haben koennen wenn er pro ai hat und das
… formelblatt einmalig kauft fuer 3 credits“.

- Katalog und PDFs liegen NUR auf dem Server unter `BASE_DATA_DIR/formelblatt/` (`katalog.json` + PDF-Dateien), nicht im
  oeffentlichen Repo; hochgeladen mit `tools/formelblatt-hochladen.sh`. Ohne Katalog gibt es keine Angebote.
- Welche Blaetter ein Konto sieht: gleiche Hochschule wie das Konto und ein Modulname aus der Anfrage, der zu einem Namen
  des Eintrags passt (Gross-/Kleinschreibung, Umlaute und Satzzeichen egal). Die App schickt nur den Namen des Moduls,
  das gerade offen ist.
- Kauf: einmal je Konto und Blatt, fester Preis aus dem Katalog (reserve + settle mit fester Zahl, wie die Wissensbank);
  ein zweiter Kauf berechnet nichts. Gekauft bleibt gekauft, auch fuer eine neue Fassung desselben Blatts (gleiche `id`).

katalog.json:
    {"stand": "2026-11-22", "blaetter": [{"id": "luh-gds-kurzklausur", "titel": "Formelblatt Kurzklausur",
      "hochschule": "luh", "module": ["Grundlagen digitaler Systeme"], "credits": 3, "datei": "luh-gds-kurzklausur.pdf",
      "seiten": 2, "fassung": "2026-11-22", "beschreibung": "…"}]}
"""
from __future__ import annotations

import json
import re
import sqlite3
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

from . import config

PURPOSE = "shop:formelblatt"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")
MAX_MODULES = 20
MAX_CREDITS = 50

SCHEMA = """
CREATE TABLE IF NOT EXISTS formelblatt_purchases (
    user_id TEXT NOT NULL,
    sheet_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    credits INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (user_id, sheet_id)
);
"""


class SheetError(Exception):
    def __init__(self, status: int, code: str, detail: str, extra: dict | None = None):
        super().__init__(detail)
        self.status, self.code, self.detail, self.extra = status, code, detail, extra or {}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def base_dir() -> Path:
    return config.BASE_DATA_DIR / "formelblatt"


def ensure_schema(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    from . import accounts, credits, db
    conn = credits.connect()
    db.schema_once(conn, "formelblatt", accounts.db_path(), ensure_schema)
    return conn


# ---------------------------------------------------------------- Katalog

def norm(name: object) -> str:
    """Modulname zum Vergleich: klein, ohne Akzente, ß -> ss, nur Buchstaben/Ziffern, einfache Leerzeichen"""
    s = unicodedata.normalize("NFKD", str(name or "")).replace("ß", "ss")
    s = "".join(ch for ch in s if not unicodedata.combining(ch)).lower()
    return " ".join(re.sub(r"[^a-z0-9]+", " ", s).split())


_cache: dict = {"key": None, "items": []}


def catalog() -> list[dict]:
    """Gueltige Eintraege aus katalog.json (neu gelesen, wenn sich die Datei aendert). Eintraege ohne PDF, mit
    ungueltiger id oder unpassendem Preis fallen weg."""
    p = base_dir() / "katalog.json"
    try:
        st = p.stat()
    except OSError:
        return []
    key = (st.st_mtime_ns, st.st_size)
    if _cache["key"] == key:
        return _cache["items"]
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = []
    for b in (raw.get("blaetter") if isinstance(raw, dict) else None) or []:
        if not isinstance(b, dict):
            continue
        sid, datei = str(b.get("id") or ""), str(b.get("datei") or "")
        credits = b.get("credits")
        mods = [str(m) for m in (b.get("module") or []) if str(m).strip()]
        if not ID_RE.match(sid) or not isinstance(credits, int) or not 1 <= credits <= MAX_CREDITS or not mods:
            continue
        pdf = base_dir() / Path(datei).name
        if not datei or not pdf.is_file():
            continue
        items.append({"id": sid, "titel": str(b.get("titel") or "Formelblatt"), "hochschule": config.normalize_university(b.get("hochschule")),
                      "module": mods, "match": {norm(m) for m in mods}, "credits": credits, "pdf": pdf,
                      "seiten": b.get("seiten") if isinstance(b.get("seiten"), int) else None,
                      "fassung": str(b.get("fassung") or raw.get("stand") or ""), "beschreibung": str(b.get("beschreibung") or "")})
    _cache.update(key=key, items=items)
    return items


def _find(sheet_id: str, university: str) -> dict:
    for it in catalog():
        if it["id"] == sheet_id and it["hochschule"] == university:
            return it
    raise SheetError(404, "not_found", "Dieses Formelblatt gibt es nicht.")


def _public(it: dict, owned: bool, module: str | None = None) -> dict:
    return {"id": it["id"], "title": it["titel"], "module": module or it["module"][0], "credits": it["credits"],
            "pages": it["seiten"], "version": it["fassung"], "description": it["beschreibung"], "owned": owned}


def _owned(conn: sqlite3.Connection, user_id: str) -> set[str]:
    return {r[0] for r in conn.execute("SELECT sheet_id FROM formelblatt_purchases WHERE user_id=?", (user_id,))}


# ---------------------------------------------------------------- Ablauf

def offers(user_id: str, university: str, modules: object) -> dict:
    """Blaetter zu den genannten Modulen (hoechstens MAX_MODULES Namen) fuer die Hochschule des Kontos"""
    if not isinstance(modules, list):
        raise SheetError(422, "bad_request", "Module fehlen.")
    wanted: dict[str, str] = {}
    for m in modules[:MAX_MODULES]:
        if isinstance(m, str) and norm(m):
            wanted.setdefault(norm(m), m)
    conn = connect()
    try:
        owned = _owned(conn, user_id)
    finally:
        conn.close()
    out = []
    for it in catalog():
        if it["hochschule"] != university:
            continue
        hit = next((wanted[n] for n in wanted if n in it["match"]), None)
        if hit is not None:
            out.append(_public(it, it["id"] in owned, hit))
    return {"items": out}


def buy(user_id: str, university: str, sheet_id: str) -> dict:
    """Einmal kaufen: fester Preis aus dem Katalog. Schon gekauft -> nichts berechnen. Credits reichen nicht -> 429
    credits_exhausted (wie ueberall), nichts gekauft."""
    from . import credits as ledger
    it = _find(sheet_id, university)
    rid = f"formelblatt:{it['id']}"
    conn = connect()
    try:
        if it["id"] in _owned(conn, user_id):
            return {"item": _public(it, True), "credits_charged": 0}
        try:
            held = ledger.reserve(conn, user_id, rid, PURPOSE, it["credits"], model="formelblatt")
        except ledger.CreditsError as e:
            raise SheetError(e.status, e.code, e.message, e.extra)
        charged = 0
        if not held.replay:                          # eine schon abgerechnete Kennung (Abbruch nach settle) nicht noch einmal
            charged = ledger.settle(conn, user_id, rid, 0, model="formelblatt", fixed_credits=it["credits"])
        conn.execute("INSERT OR IGNORE INTO formelblatt_purchases(user_id, sheet_id, request_id, credits, created_at) VALUES (?,?,?,?,?)",
                     (user_id, it["id"], rid, it["credits"], _now().isoformat()))
        conn.commit()
    finally:
        conn.close()
    return {"item": _public(it, True), "credits_charged": charged}


def pdf_for(user_id: str, university: str, sheet_id: str) -> Path:
    it = _find(sheet_id, university)
    conn = connect()
    try:
        if it["id"] not in _owned(conn, user_id):
            raise SheetError(404, "not_found", "Dieses Formelblatt hast du nicht gekauft.")
    finally:
        conn.close()
    return it["pdf"]


def purchases(user_id: str) -> list[dict]:
    """Fuer den Konto-Export"""
    conn = connect()
    try:
        return [{"blatt": r[0], "credits": r[1], "gekauft_am": r[2]}
                for r in conn.execute("SELECT sheet_id, credits, created_at FROM formelblatt_purchases WHERE user_id=? ORDER BY created_at", (user_id,))]
    finally:
        conn.close()
