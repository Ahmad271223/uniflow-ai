"""Erklaerungsspeicher der KI-Hilfe im Editor fuer Web und Windows (Stand 05.11.2026).

Gleiche Regeln wie auf dem iPad (docs/ERKLAERUNGSSPEICHER-2026-11-04.md, PageExplain.swift): Die Antworten fuer GANZE
Seiten (Erklaeren, Einfach erklaeren, Zusammenfassen, Fachbegriffe, Aufgabe loesen, Nur Hinweise) werden gemerkt. Wer
dieselbe Seite im selben Modus noch einmal oeffnet, bekommt die Antwort sofort und ehrlich beschriftet
("Schon erklaert - 0 Credits"), und "Neu erklaeren lassen" (`force`) fragt live nach und belegt den naechsten freien
Platz: hoechstens drei Varianten je Seite und Modus, nie ueberschreiben, Leser nehmen die niedrigste.

Unterschied zum iPad: Hier liegt der Speicher in der Datenbank des Kontos bzw. des PCs (Tabelle `page_explain_local`,
bei Bedarf angelegt wie `page_texts`), nicht in CloudKit. Geteilt wird nichts zwischen Konten; im gehosteten Dienst
kommt die "gemeinsame" Antwort (`source: "cloud"`) aus dem Zwischenspeicher der StudiNow-KI (`ai_backend`, gleiche
Anfrage = gleiche Antwort). Der Schluessel ist der Abdruck des Seitentextes: aendert sich die Seite, gibt es nichts
Altes. Keine Namen, keine Dateinamen, nur der Antworttext.

Geteilt/gemerkt wird nur ohne markierten Text, ohne eigene Frage, ohne eigene Loesung und ohne eigene Notizen
(`is_shareable`); alles andere bleibt live."""
from __future__ import annotations

import hashlib
import re
import sqlite3

from . import db

MAX_VARIANTS = 3
SHAREABLE_MODES = ("explain", "explain_simple", "summary", "terms", "steps", "hints")
MAX_ROWS = 4000                          # aelteste Eintraege fallen heraus
MAX_ANSWER_CHARS = 60000

_MARKS = re.compile(r"[ \t]*\[\d{1,2}\]")


def ensure_table(conn: sqlite3.Connection) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS page_explain_local (
        text_hash TEXT NOT NULL, page INTEGER NOT NULL, mode TEXT NOT NULL, variant INTEGER NOT NULL,
        answer TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'ai', created_at TEXT NOT NULL,
        PRIMARY KEY (text_hash, page, mode, variant))""")


def text_hash(page_text: str) -> str:
    """Abdruck des Seitentextes (Leerraum zusammengefasst): derselbe Text, derselbe Abdruck"""
    return hashlib.sha256(" ".join(str(page_text or "").split()).encode("utf-8")).hexdigest()


def is_shareable(mode: str, selection: str = "", question: str = "", own_solution: str = "", own_notes: str = "") -> bool:
    """Nur Antworten fuer die ganze Seite im Modus der Liste, ohne Markierung, Frage, eigene Loesung und Notizen"""
    if mode not in SHAREABLE_MODES:
        return False
    return not any(str(x or "").strip() for x in (selection, question, own_solution, own_notes))


def strip_marks(answer: str) -> str:
    """Quellenmarken [n] entfernen: die Quellen des ersten Fragenden hat der naechste nicht"""
    return _MARKS.sub("", str(answer or ""))


def lookup(conn: sqlite3.Connection, page_text: str, page: int, mode: str) -> dict | None:
    """Niedrigste vorhandene Variante: {answer, source, variant, created_at} oder None"""
    ensure_table(conn)
    r = conn.execute("SELECT answer, source, variant, created_at FROM page_explain_local WHERE text_hash=? AND page=? AND mode=? "
                     "ORDER BY variant LIMIT 1", (text_hash(page_text), int(page), mode)).fetchone()
    return {"answer": r[0], "source": r[1], "variant": r[2], "created_at": r[3]} if r else None


def store(conn: sqlite3.Connection, page_text: str, page: int, mode: str, answer: str, source: str = "ai") -> int:
    """Antwort auf den naechsten freien Platz 1..3 legen (ohne Quellenmarken); 0, wenn alle belegt sind oder die Antwort
    unbrauchbar ist (dann bleibt sie nur auf dem Bildschirm). Nie ueberschreiben."""
    ensure_table(conn)
    text = strip_marks(answer).strip()
    if not text or len(text) > MAX_ANSWER_CHARS or not str(page_text or "").strip():
        return 0
    h = text_hash(page_text)
    taken = {r[0] for r in conn.execute("SELECT variant FROM page_explain_local WHERE text_hash=? AND page=? AND mode=?", (h, int(page), mode))}
    free = [v for v in range(1, MAX_VARIANTS + 1) if v not in taken]
    if not free:
        return 0
    v = free[0]
    cur = conn.execute("INSERT OR IGNORE INTO page_explain_local(text_hash, page, mode, variant, answer, source, created_at) VALUES (?,?,?,?,?,?,?)",
                       (h, int(page), mode, v, text, "cloud" if source == "cloud" else "ai", db.now_iso()))
    if not cur.rowcount:                  # Wettlauf: der Platz war inzwischen belegt
        return 0
    conn.execute("DELETE FROM page_explain_local WHERE rowid IN (SELECT rowid FROM page_explain_local ORDER BY created_at DESC "
                 "LIMIT -1 OFFSET ?)", (MAX_ROWS,))
    return v


def descriptor(*, stored: bool, source: str = "local", variant: int = 0, created_at: str | None = None, shared: bool = False) -> dict:
    """Das Feld `explain` der Antwort von POST /api/ai/tutor (Vertrag wie auf dem iPad, packages/shared-contracts/page-explain.md):
    gespeichert {"stored": true, "source": "local"|"cloud", "variant", "created_at"}, frisch {"stored": false, "variant", "shared"}"""
    if stored:
        return {"stored": True, "source": "cloud" if source == "cloud" else "local", "variant": variant, "created_at": created_at}
    return {"stored": False, "variant": variant, "shared": shared}
