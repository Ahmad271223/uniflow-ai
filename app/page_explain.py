"""Erklaerungsspeicher ("Einmal erklaeren, alle profitieren"), Dienst-Seite (04.11.2026).

Spiegelt den CloudKit-Datensatz `PageExplain` (docs/ERKLAERUNGSSPEICHER-2026-11-04.md,
packages/shared-contracts/page-explain.md) fuer Web und Windows. Das iPad nutzt in V1 nur CloudKit; der Dienst bietet
dieselben Regeln, damit spaeter alle Geraete denselben Speicher sehen koennen:

- Schluessel: `<fileKey>#<page>#<mode>#<variant>` (record_name). `fileKey` ist der HMAC des Datei-SHA wie beim
  Dokument-Index (app/doc_index.py file_key), `page` ab 1, `mode` einer der sechs geteilten Modi, `variant` 1…3.
- Hoechstens MAX_VARIANTS Datensaetze je `<fileKey>#<page>#<mode>`; ein Datensatz wird nie ueberschrieben, auch nicht
  vom Ersteller. Wer speichert, bekommt den niedrigsten freien Platz (next_slot); sind alle belegt: 409 explain_full.
- `payload` ist das Chiffrat (Base64, Version 1 Byte + Salz 32 + Nonce 12 + AES-GCM mit 16-Byte-Tag), hoechstens
  MAX_PAYLOAD_CHARS wie beim Dokument-Index (DocIndexCrypto.maxPayloadChars). Der Dienst prueft nur Form und Groesse;
  er kennt weder den Datei-SHA noch den Seiten-Abdruck und kann die Antworten nicht lesen.
- Loeschen darf nur der Ersteller oder der Inhaber (Rolle admin). Beim endgueltigen Loeschen eines Kontos bleibt
  das Chiffrat fuer die anderen, der Besitzer wird anonymisiert wie in credit_ledger (forget_owner).

Ablage: Tabelle `page_explain` in accounts.db (zentral, nie im Nutzerordner), Schema ueber db.schema_once wie
app/credits.py. Reine Pruef- und Regelfunktionen oben (tests/test_page_explain.py), Ablage darunter.
"""
from __future__ import annotations

import base64
import binascii
import re
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone

from . import db

# Formatfassung des Datensatzes (PageExplain.version im Kern); eine neue Fassung mischt sich nicht mit alten
VERSION = 1
# hoechstens so viele Varianten je Schluessel (wie testshare.MAX_VARIANTS und PageExplain.maxVariants)
MAX_VARIANTS = 3
# die geteilten Modi der KI-Hilfe (PageExplain.sharedModes); alles andere bleibt live und ungeteilt
SHARED_MODES = ("explain", "explain_simple", "summary", "terms", "steps", "hints")
# wie DocIndexCrypto.maxPayloadChars (256 KiB Base64)
MAX_PAYLOAD_CHARS = 256 * 1024
# kleinstes Chiffrat: Versionsbyte + Salz + Nonce + Tag (leerer Klartext)
MIN_PAYLOAD_BYTES = 1 + 32 + 12 + 16
MAX_PAGE = 10_000
# so viele Datensaetze je Datei hoechstens in einer Abfrage (wie PageExplainCloudRecord.queryLimit)
QUERY_LIMIT = 900
# Grenze je Konto und Tag fuer Speichern und Loeschen (accounts.LIMITS["explain_user"], LERNAPP_LIMIT_EXPLAIN_USER)
LIMIT_NAME = "explain_user"

_FILE_KEY = re.compile(r"^[0-9a-f]{64}$")
_B64 = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS page_explain (
    record_name TEXT PRIMARY KEY,          -- <fileKey>#<page>#<mode>#<variant>
    file_key TEXT NOT NULL,                -- HMAC des Datei-SHA (nie der SHA)
    page INTEGER NOT NULL,                 -- ab 1
    mode TEXT NOT NULL,                    -- explain | explain_simple | summary | terms | steps | hints
    variant INTEGER NOT NULL,              -- 1..3
    payload TEXT NOT NULL,                 -- Chiffrat, Base64
    version INTEGER NOT NULL,              -- Formatfassung
    created_at TEXT NOT NULL,              -- ISO 8601, UTC (Zeit des Dienstes)
    owner_id TEXT NOT NULL,                -- Konto des Erstellers; nach dem Loeschen des Kontos "deleted:<zufall>"
    UNIQUE (file_key, page, mode, variant)
);
CREATE INDEX IF NOT EXISTS idx_page_explain_owner ON page_explain(owner_id);
"""


class PageExplainError(ValueError):
    """Fachlicher Fehler mit stabilem Code ({"detail", "code", ...} in der API)."""

    def __init__(self, code: str, message: str, status: int = 400, extra: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.extra = code, message, status, extra or {}


# ---------------------------------------------------------------- Pruefung (reine Funktionen)

def check_file_key(value) -> str:
    if not isinstance(value, str) or not _FILE_KEY.match(value):
        raise PageExplainError("bad_file_key", "file_key muss der Dateischlüssel sein (64 Hexziffern, klein).")
    return value


def check_page(value) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        try:
            value = int(str(value).strip())
        except (TypeError, ValueError):
            raise PageExplainError("bad_page", "page muss eine Seitenzahl ab 1 sein.") from None
    if not 1 <= value <= MAX_PAGE:
        raise PageExplainError("bad_page", f"page muss zwischen 1 und {MAX_PAGE} liegen.")
    return value


def check_mode(value) -> str:
    from . import doc_explain
    # Teile eines Laufs fuer das ganze Dokument (05.11.2026, doc_explain.store_mode): doc<Fassung>_<Art>_<n>_<bis>
    if not isinstance(value, str) or (value not in SHARED_MODES and not doc_explain.is_store_mode(value)):
        raise PageExplainError("bad_mode", "mode muss einer der geteilten Modi sein: " + ", ".join(SHARED_MODES) + ".")
    return value


def check_variant(value) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        try:
            value = int(str(value).strip())
        except (TypeError, ValueError):
            raise PageExplainError("bad_variant", f"variant muss zwischen 1 und {MAX_VARIANTS} liegen.") from None
    if not 1 <= value <= MAX_VARIANTS:
        raise PageExplainError("bad_variant", f"variant muss zwischen 1 und {MAX_VARIANTS} liegen.")
    return value


def check_version(value) -> int:
    if value is None:
        return VERSION
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 255:
        raise PageExplainError("bad_version", "version muss eine Formatfassung zwischen 1 und 255 sein.")
    return value


def check_payload(value, version: int = VERSION) -> str:
    """Nur Form und Groesse: Base64 ohne Zeilenumbrueche, hoechstens MAX_PAYLOAD_CHARS, entschluesselbar nie hier.
    Das erste Byte des Chiffrats ist die Formatfassung und muss zu `version` passen (Fassungen mischen sich nicht)."""
    if not isinstance(value, str) or not value:
        raise PageExplainError("bad_payload", "payload fehlt (Chiffrat als Base64).")
    if len(value) > MAX_PAYLOAD_CHARS:
        raise PageExplainError("payload_too_large", f"payload ist zu groß (höchstens {MAX_PAYLOAD_CHARS // 1024} KiB Base64).", 413)
    if not _B64.match(value) or len(value) % 4:
        raise PageExplainError("bad_payload", "payload muss Base64 ohne Zeilenumbrüche sein.")
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise PageExplainError("bad_payload", "payload muss Base64 ohne Zeilenumbrüche sein.") from None
    if len(raw) < MIN_PAYLOAD_BYTES:
        raise PageExplainError("bad_payload", "payload ist zu kurz für ein Chiffrat (Version, Salz, Nonce, Tag).")
    if raw[0] != version:
        raise PageExplainError("version_mismatch", f"payload trägt Formatfassung {raw[0]}, der Datensatz nennt {version}.")
    return value


# ---------------------------------------------------------------- Regeln (reine Funktionen, wie PageExplain im Kern)

def record_name(file_key: str, page: int, mode: str, variant: int) -> str:
    return f"{file_key}#{page}#{mode}#{variant}"


def parse_record_name(name: str) -> tuple[str, int, str, int] | None:
    """Umkehrung von record_name; None bei fremder Form (wie PageExplain.parse im Kern)."""
    if not isinstance(name, str):
        return None
    parts = name.split("#")
    if len(parts) != 4:
        return None
    try:
        return check_file_key(parts[0]), check_page(parts[1]), check_mode(parts[2]), check_variant(parts[3])
    except PageExplainError:
        return None


def free_variants(existing) -> list[int]:
    """Freie Plaetze 1..MAX_VARIANTS, aufsteigend (PageExplain.freeVariants)."""
    taken = {int(v) for v in existing}
    return [v for v in range(1, MAX_VARIANTS + 1) if v not in taken]


def next_slot(existing) -> int | None:
    """Niedrigster freier Platz oder None, wenn alle MAX_VARIANTS belegt sind (dann bleibt die Antwort lokal, Variante 0)."""
    free = free_variants(existing)
    return free[0] if free else None


def preferred_variant(existing) -> int | None:
    """Leser nehmen die niedrigste vorhandene Variante (PageExplain.preferredVariant)."""
    valid = [int(v) for v in existing if 1 <= int(v) <= MAX_VARIANTS]
    return min(valid) if valid else None


def is_admin(user: dict | None) -> bool:
    return bool(user) and user.get("role") == "admin"


def may_delete(record_owner: str, user: dict | None) -> bool:
    """Loeschen darf der Ersteller oder der Inhaber (admin); ein anonymisierter Besitzer ("deleted:…") gehoert niemandem."""
    if not user or not user.get("id"):
        return False
    return is_admin(user) or (record_owner == user["id"] and not record_owner.startswith("deleted:"))


def public(row, user: dict | None = None) -> dict:
    """Datensatz fuer die API: wie der CloudKit-Datensatz, der Besitzer nur als `mine`; die Kennung sieht nur der Inhaber."""
    out = {"record_name": row["record_name"], "file_key": row["file_key"], "page": int(row["page"]), "mode": row["mode"],
           "variant": int(row["variant"]), "payload": row["payload"], "version": int(row["version"]), "created_at": row["created_at"],
           "mine": bool(user) and row["owner_id"] == user.get("id")}
    if is_admin(user):
        out["owner_id"] = row["owner_id"]
    return out


# ---------------------------------------------------------------- Ablage (accounts.db)

def ensure_schema(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


@contextmanager
def cursor():
    """Verbindung zu accounts.db mit Schema (einmal je Prozess, db.schema_once wie app/credits.py); committet am Ende."""
    from . import accounts
    with accounts.cursor() as conn:
        db.schema_once(conn, "page_explain", accounts.db_path(), ensure_schema)
        yield conn


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def list_records(file_key: str, page: int | None = None, mode: str | None = None, user: dict | None = None) -> list[dict]:
    """Alle Datensaetze einer Datei, bei Bedarf auf Seite und Modus eingegrenzt; Seite, Modus, Variante aufsteigend
    (Leser nehmen die niedrigste Variante)."""
    sql, params = "SELECT * FROM page_explain WHERE file_key=?", [check_file_key(file_key)]
    if page is not None:
        sql += " AND page=?"
        params.append(check_page(page))
    if mode is not None:
        sql += " AND mode=?"
        params.append(check_mode(mode))
    sql += " ORDER BY page, mode, variant LIMIT ?"
    params.append(QUERY_LIMIT)
    with cursor() as conn:
        rows = conn.execute(sql, params).fetchall()
    return [public(r, user) for r in rows]


def get_record(file_key: str, page: int, mode: str, variant: int, user: dict | None = None) -> dict | None:
    name = record_name(check_file_key(file_key), check_page(page), check_mode(mode), check_variant(variant))
    with cursor() as conn:
        r = conn.execute("SELECT * FROM page_explain WHERE record_name=?", (name,)).fetchone()
    return public(r, user) if r else None


def store(user: dict, file_key: str, page: int, mode: str, payload: str, version: int | None = None,
          variant: int | None = None) -> dict:
    """Neuen Datensatz anlegen. Ohne `variant` den niedrigsten freien Platz; mit `variant` genau diesen, wenn er frei
    ist (wie das Anlegen nach Name bei CloudKit). Nie ueberschreiben: belegt -> 409 explain_taken (mit freien Plaetzen),
    alle belegt -> 409 explain_full. Ein Wettlauf zweier Speichernder entscheidet sich an UNIQUE: der zweite bekommt
    den naechsten freien Platz, bei vollem Schluessel explain_full."""
    file_key, page, mode = check_file_key(file_key), check_page(page), check_mode(mode)
    version = check_version(version)
    payload = check_payload(payload, version)
    wanted = check_variant(variant) if variant is not None else None
    with cursor() as conn:
        for _attempt in range(MAX_VARIANTS + 1):
            taken = [int(r[0]) for r in conn.execute("SELECT variant FROM page_explain WHERE file_key=? AND page=? AND mode=?",
                                                     (file_key, page, mode))]
            free = free_variants(taken)
            if wanted is not None and wanted not in free:
                raise PageExplainError("explain_taken", f"Variante {wanted} ist schon belegt und wird nie überschrieben.", 409,
                                       {"free": free, "max_variants": MAX_VARIANTS})
            if not free:
                raise PageExplainError("explain_full", "Für diese Seite gibt es schon drei geteilte Antworten in diesem Modus. "
                                       "Die neue Antwort bleibt nur auf dem Gerät.", 409, {"free": [], "max_variants": MAX_VARIANTS})
            slot = wanted if wanted is not None else free[0]
            name, t = record_name(file_key, page, mode, slot), _now()
            try:
                conn.execute("INSERT INTO page_explain(record_name, file_key, page, mode, variant, payload, version, created_at, owner_id) "
                             "VALUES (?,?,?,?,?,?,?,?,?)", (name, file_key, page, mode, slot, payload, version, t, user["id"]))
            except sqlite3.IntegrityError:
                if wanted is not None:
                    raise PageExplainError("explain_taken", f"Variante {wanted} ist schon belegt und wird nie überschrieben.", 409,
                                           {"free": [v for v in free if v != wanted], "max_variants": MAX_VARIANTS}) from None
                continue                                          # Wettlauf: jemand war schneller, naechster Platz
            conn.commit()
            return public(conn.execute("SELECT * FROM page_explain WHERE record_name=?", (name,)).fetchone(), user)
    raise PageExplainError("explain_full", "Für diese Seite gibt es schon drei geteilte Antworten in diesem Modus.", 409,
                           {"free": [], "max_variants": MAX_VARIANTS})


def delete(user: dict, file_key: str, page: int, mode: str, variant: int) -> bool:
    """Loeschen nur durch den Ersteller oder den Inhaber; 404 wenn es den Datensatz nicht gibt, 403 sonst."""
    name = record_name(check_file_key(file_key), check_page(page), check_mode(mode), check_variant(variant))
    with cursor() as conn:
        r = conn.execute("SELECT owner_id FROM page_explain WHERE record_name=?", (name,)).fetchone()
        if not r:
            raise PageExplainError("not_found", "Diese Erklärung gibt es nicht (mehr).", 404)
        if not may_delete(r["owner_id"], user):
            raise PageExplainError("not_owner", "Nur wer die Erklärung geteilt hat, kann sie löschen.", 403)
        conn.execute("DELETE FROM page_explain WHERE record_name=?", (name,))
    return True


def forget_owner(conn: sqlite3.Connection, user_id: str) -> int:
    """Konto endgueltig geloescht (accounts._purge_user): die Chiffrate bleiben fuer die anderen, der Besitzer wird
    anonymisiert wie in credit_ledger. Laeuft in der Verbindung und Transaktion der Kontoloeschung (accounts.db), darum
    kein Schema-Lauf hier: ohne Tabelle gibt es nichts zu vergessen."""
    if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_explain'").fetchone() is None:
        return 0
    return conn.execute("UPDATE page_explain SET owner_id=? WHERE owner_id=?", ("deleted:" + secrets.token_hex(8), user_id)).rowcount


def count_for_owner(user_id: str) -> int:
    with cursor() as conn:
        return int(conn.execute("SELECT COUNT(*) FROM page_explain WHERE owner_id=?", (user_id,)).fetchone()[0])
