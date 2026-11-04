"""Geteilte Wochenstapel ("Einmal erzeugen, alle profitieren", Entscheidung des Inhabers vom 04.11.2026,
docs/KARTEIKARTEN-STAPEL-2026-11-04.md): je Modul und Lehrwoche gibt es zwei erzeugte Karteikarten-Stapel, Art
`vorlesung` (aus den Vorlesungsunterlagen der Woche) und `uebung` (aus den Uebungsblaettern der Woche). Sie werden
EINMAL je Modul und Woche erzeugt und geteilt, nie je Person.

Schluessel wie bei den Wochentests (app/testshare.py): Hochschule, Art und die Inhalts-Hashes der Dateien der Woche;
nicht im Schluessel sind Nutzer, Modulname und Wochennummer. Wer dieselben Dateien hat, bekommt denselben Stapel.
Varianten, Platz belegen, uebernehmen statt erzeugen: dieselben reinen Funktionen wie bei den Wochentests
(`testshare.variant`, `testshare.pick`, hoechstens MAX_VARIANTS = 3 Stapel je Schluessel). Uebernehmen kostet 0 Credits.

Kosten: ein Stapel ist eine KI-Anfrage mit dem Prompt der Karteikarten (`ai.flashcards_prompt`, WEEK_CARDS Karten,
hoechstens ai.FLASHCARDS_MAX); mit dem kleinen Modell rund 0,5 ct je Stapel, und das hoechstens dreimal je Modul,
Woche und Art - egal wie viele Studierende das Modul hat.

Pool des Dienstes (hosted): Tabelle `shared_card_stacks` in library.db wie `shared_tests` (Klartext, Besitzer nur als
Kurzwert). Die iPad-App ohne Dienst teilt ueber CloudKit (Datensatz `WeekCardStack`, verschluesselt mit einem
Schluessel aus den Inhalts-Hashes; CardStackShare.swift). Dieselben Erwartungswerte fuer Schluessel und Namen stehen
in packages/shared-contracts/fixtures/cardshare/cases.json (tools/gen-cardshare-fixture.py).
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

from . import testshare

VERSION = "cs1"
# Arten der erzeugten Wochenstapel und die Dokumentarten, aus denen sie entstehen
KINDS = ("vorlesung", "uebung")
WEEK_DOC_TYPES = {"vorlesung": ("vorlesung", "skript"), "uebung": ("uebung", "loesung")}
# so viele Karten verlangt ein Stapel von der KI (Deckel je Satz: ai.FLASHCARDS_MAX = 30)
WEEK_CARDS = 20
# hoechstens so viele Dateien einer Woche gehen in den Prompt, so viel Text je Datei
WEEK_FILES_MAX = 10
WEEK_TEXT_CHARS = 3500
MAX_VARIANTS = testshare.MAX_VARIANTS
# Quelle eines uebernommenen Stapels (flashcard_stacks.source)
SOURCE_WEEK = "week"              # geteilter Wochenstapel (source_ref = Schluessel)
SOURCE_COMMUNITY = "community"    # aus der Modul-Community uebernommen (source_ref = Kennung des geteilten Stapels)

SCHEMA = """
CREATE TABLE IF NOT EXISTS shared_card_stacks (
    share_key TEXT NOT NULL,
    variant INTEGER NOT NULL,            -- 0..2
    status TEXT NOT NULL,                -- pending | ready
    cards TEXT,                          -- JSON [{question, answer}] (ready)
    owner_hash TEXT NOT NULL,            -- Kurzwert des Kontos (test_library.owner_hash), nie die Konto-ID
    created_at TEXT NOT NULL,
    published_at TEXT,
    uses INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (share_key, variant)
);
"""


# ---------------------------------------------------------------- reine Funktionen (gleich in CardStackShare.swift)

def stack_name(kind: str, week: int) -> str:
    """Name des uebernommenen Stapels: "Vorlesung Woche 5" / "Übung Woche 5"."""
    return ("Vorlesung" if kind == "vorlesung" else "Übung") + f" Woche {int(week)}"


def week_key(university: str, kind: str, materials: list[dict]) -> str | None:
    """Schluessel eines Wochenstapels oder None, wenn eine Datei keinen Inhalts-Hash hat (dann nicht teilen)."""
    if kind not in KINDS:
        return None
    prints = testshare.fingerprints(materials)
    if prints is None:
        return None
    canon = json.dumps({"v": VERSION, "uni": university, "kind": kind, "materials": prints}, separators=(",", ":"), sort_keys=True)
    return f"{VERSION}:" + hashlib.sha256(canon.encode("utf-8")).hexdigest()


def week_text(files: list[dict]) -> str:
    """Text fuer den Prompt: je Datei eine Ueberschrift mit dem Namen und der Textauszug (gleich im Kern)."""
    parts = []
    for f in files:
        parts.append(f"### Datei: {f.get('name') or ''}\n{(f.get('text') or '').strip()[:WEEK_TEXT_CHARS]}")
    return "\n\n".join(parts)


def prompt(module: str, kind: str, week: int, files: list[dict]) -> str:
    """Prompt des Wochenstapels: der Karteikarten-Prompt mit dem Modul als Kurs, dem Stapelnamen als Datei und dem
    Text aller Dateien der Woche (WEEK_CARDS Karten)."""
    from . import ai
    return ai.flashcards_prompt(module, stack_name(kind, week), None, week_text(files), WEEK_CARDS)


def canonical_cards(cards: list[dict]) -> str:
    """Klartext eines geteilten Stapels (Chiffrat bei CloudKit, Spalte `cards` im Dienst): nur Frage und Antwort,
    sortierte Schluessel, ohne ASCII-Zwang."""
    return json.dumps({"cards": [{"answer": c["answer"], "question": c["question"]} for c in cards]},
                      ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def variant(user_id: str, key: str) -> int:
    return testshare.variant(user_id, key)


def shared_info(row: dict | None) -> dict | None:
    """`shared` eines Stapels fuer die Oberflaeche: Variante 1-basiert, of = 3, adopted (uebernommen statt erzeugt)."""
    if not row or row.get("source") != SOURCE_WEEK:
        return None
    return {"key": row.get("source_ref"), "of": MAX_VARIANTS}


# ---------------------------------------------------------------- Pool des Dienstes (wie test_library.shared_*)

@contextmanager
def cursor():
    from . import db, test_library
    p = test_library.db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, timeout=15, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    db.wal_once(conn, p)                    # WAL nur einmal je Datei (Wettlauf auf neuer Datei, db.wal_once)
    db.schema_once(conn, "cardshare", p, lambda c: c.executescript(SCHEMA))
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def _now(now: datetime | None = None) -> str:
    return (now or datetime.now(timezone.utc)).isoformat()


def _stale_cutoff(now: datetime | None = None) -> str:
    return ((now or datetime.now(timezone.utc)) - timedelta(seconds=testshare.PENDING_STALE_S)).isoformat()


def _row(r: sqlite3.Row) -> dict:
    return {"variant": int(r["variant"]), "status": r["status"], "cards": json.loads(r["cards"]) if r["cards"] else [],
            "created_at": r["created_at"], "published_at": r["published_at"], "owner_hash": r["owner_hash"]}


def slots(key: str, now: datetime | None = None) -> dict[int, dict]:
    """Plaetze eines Schluessels; verwaiste Belegungen (pending, aelter als PENDING_STALE_S) werden freigegeben."""
    with cursor() as conn:
        conn.execute("DELETE FROM shared_card_stacks WHERE share_key=? AND status='pending' AND created_at<?", (key, _stale_cutoff(now)))
        rows = conn.execute("SELECT * FROM shared_card_stacks WHERE share_key=? ORDER BY variant", (key,)).fetchall()
    return {int(r["variant"]): _row(r) for r in rows}


def claim(key: str, v: int, user_id: str, now: datetime | None = None) -> bool:
    """Platz atomar belegen (PRIMARY KEY); False bei einem Wettlauf."""
    from . import test_library
    if not 0 <= int(v) < MAX_VARIANTS:
        raise ValueError("Variante ausserhalb 0..2")
    with cursor() as conn:
        conn.execute("DELETE FROM shared_card_stacks WHERE share_key=? AND variant=? AND status='pending' AND created_at<?",
                     (key, int(v), _stale_cutoff(now)))
        return conn.execute("INSERT OR IGNORE INTO shared_card_stacks(share_key, variant, status, owner_hash, created_at) VALUES (?,?,'pending',?,?)",
                            (key, int(v), test_library.owner_hash(user_id), _now(now))).rowcount == 1


def publish(key: str, v: int, user_id: str, cards: list[dict], now: datetime | None = None) -> None:
    """Fertigen Stapel in den eigenen belegten Platz schreiben."""
    from . import test_library
    with cursor() as conn:
        n = conn.execute("""UPDATE shared_card_stacks SET status='ready', cards=?, published_at=?
                            WHERE share_key=? AND variant=? AND owner_hash=? AND status='pending'""",
                         (json.dumps(cards, ensure_ascii=False), _now(now), key, int(v), test_library.owner_hash(user_id))).rowcount
    if n != 1:
        raise KeyError("Platz nicht belegt oder nicht der eigene")


def release(key: str, v: int, user_id: str) -> None:
    from . import test_library
    with cursor() as conn:
        conn.execute("DELETE FROM shared_card_stacks WHERE share_key=? AND variant=? AND owner_hash=? AND status='pending'",
                     (key, int(v), test_library.owner_hash(user_id)))


def get(key: str, v: int, count_use: bool = True) -> dict | None:
    with cursor() as conn:
        r = conn.execute("SELECT * FROM shared_card_stacks WHERE share_key=? AND variant=? AND status='ready'", (key, int(v))).fetchone()
        if r and count_use:
            conn.execute("UPDATE shared_card_stacks SET uses=uses+1 WHERE share_key=? AND variant=?", (key, int(v)))
    return _row(r) if r else None


def wait(key: str, v: int, timeout_s: float, poll_s: float = 1.0) -> dict | None:
    """Wartet, bis der Platz fertig ist (ein anderer erzeugt gerade); None, wenn frei geworden oder Zeit um."""
    import time
    end = time.monotonic() + max(0.0, timeout_s)
    while True:
        slot = slots(key).get(int(v))
        if slot is None:
            return None
        if slot["status"] == "ready":
            return get(key, v)
        if time.monotonic() >= end:
            return None
        time.sleep(min(poll_s, max(0.0, end - time.monotonic())) or 0.01)


def obtain(key: str, uid: str, generate, log=print, wait_s: float | None = None, can_generate: bool = True) -> dict:
    """Wochenstapel zum Schluessel holen oder erzeugen nach der Varianten-Regel (wie testshare.obtain). Liefert
    {cards, variant, adopted_from}: ohne Dienst (Einzelplatz) wird erzeugt und nur die Variante gemerkt; im Dienst
    eigene Variante fertig -> uebernehmen (0 Credits), in Arbeit -> warten, sonst Platz belegen, erzeugen,
    veroeffentlichen (scheitert das Erzeugen, wird der Platz frei).
    `can_generate=False` (Konto ohne StudiNow-KI, z. B. Plus, 04.11.2026): jede fertige Variante uebernehmen (die
    naechste zur eigenen), auf eine entstehende einmal warten, nie einen Platz belegen; gibt es nichts, ruft es
    `generate` auf, das dann mit der Tarifsperre (403) scheitert."""
    from . import config, test_library
    assigned = variant(uid, key)
    if not config.is_hosted():
        return {"cards": generate(), "variant": assigned, "adopted_from": None}
    waited = False
    for _ in range(MAX_VARIANTS + 2):
        have = slots(key)
        ready = {v for v, s in have.items() if s["status"] == "ready"}
        pending = {v for v, s in have.items() if s["status"] == "pending"}
        if assigned in ready:
            return _adopt(have[assigned], assigned, log, key)
        if assigned in pending and not waited:
            waited = True
            done = wait(key, assigned, test_library.SHARED_WAIT_S if wait_s is None else wait_s)
            if done:
                return _adopt(done, assigned, log, key)
            continue
        if not can_generate:
            near = lambda vs: sorted(vs, key=lambda x: (x - assigned) % MAX_VARIANTS)  # noqa: E731
            if ready:
                v = near(ready)[0]
                return _adopt(have[v], v, log, key)
            if pending and not waited:
                waited, v = True, near(pending)[0]
                done = wait(key, v, test_library.SHARED_WAIT_S if wait_s is None else wait_s)
                if done:
                    return _adopt(done, v, log, key)
                continue
            break
        action, v = testshare.pick(ready, assigned, pending)
        if action == "adopt":
            return _adopt(have[v], v, log, key)
        if action == "none":
            break
        if not claim(key, v, uid):
            continue
        try:
            cards = generate()
            publish(key, v, uid, cards)
        except Exception:
            release(key, v, uid)
            raise
        log(f"Wochenstapel erzeugt und geteilt ({key[:16]}…, Variante {v + 1} von {MAX_VARIANTS})")
        return {"cards": cards, "variant": v, "adopted_from": None}
    return {"cards": generate(), "variant": assigned, "adopted_from": None}


def _adopt(slot: dict, v: int, log, key: str) -> dict:
    log(f"Wochenstapel uebernommen ({key[:16]}…, Variante {v + 1} von {MAX_VARIANTS})")
    return {"cards": slot.get("cards") or [], "variant": v, "adopted_from": testshare.ADOPTED_SERVICE}
