"""Eigene Karteikarten-Stapel in der Modul-Community teilen (Entscheidung des Inhabers vom 04.11.2026,
docs/KARTEIKARTEN-STAPEL-2026-11-04.md): je Stapel, nie einzelne Karten. "Stapel teilen" legt eine Kopie der Karten
unter dem Community-Schluessel des Moduls ab (ohne Lehrwoche unter "Allgemein", mit Lehrwoche unter der Woche); andere
Mitglieder sehen sie in der Karteikarten-Ansicht ihres Moduls (Filter nach Woche), koennen sie uebernehmen (Kopie als
eigener Stapel, Lernstand getrennt), liken und melden wie Loesungen; Autor nur als Pseudonym. Teilen ist freiwillig
(Standard privat), der Autor kann zurueckziehen. Kein Teilen ueber Module hinweg: der Schluessel ist der des Moduls.

Gegenstueck im iPad ohne Dienst: CloudKit-Datensatz `CardStackShare` (CardStackCloudKit.swift), Inhalt verschluesselt
mit dem Modul-Geheimnis; im Dienst liegen die Karten im Klartext hinter der Mitgliedschaft (wie `shared_tests`).
Tabellen in community.db (eigenes Schema, dieselbe Datei wie app/community.py; Sperrliste, Bann und Mitgliedschaft
kommen von dort).
"""
from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

from . import community, config, db

CommunityError = community.CommunityError

MAX_NAME = 120
MAX_CARDS = 500                      # Deckel je geteiltem Stapel (eigene Stapel koennen groesser sein)
MAX_CARD_CHARS = 2_000
REPORTS_TO_HIDE = community.REPORTS_TO_HIDE
REPORT_REASONS = community.REPORT_REASONS
KINDS = ("vorlesung", "uebung", "eigene")

SCHEMA = """
CREATE TABLE IF NOT EXISTS card_stacks (
    id TEXT PRIMARY KEY,                 -- UUID (hex, klein)
    community_key TEXT NOT NULL,         -- Modul-Schluessel (CommunityKeys.moduleKey), nie der Modulname
    university TEXT NOT NULL,
    author_id TEXT NOT NULL,             -- Konto-ID (intern), nach aussen nur das Pseudonym
    pseudonym TEXT NOT NULL,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,                  -- vorlesung | uebung | eigene
    week INTEGER,                        -- Lehrwoche, NULL = Allgemein
    cards TEXT NOT NULL,                 -- JSON [{question, answer}]
    card_count INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT,                     -- zuletzt ersetzt (PUT /api/flashcard-stacks/{id}/share)
    status TEXT NOT NULL DEFAULT 'active',   -- active | withdrawn | hidden
    report_count INTEGER NOT NULL DEFAULT 0,
    adopt_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_card_stacks_key ON card_stacks(community_key, status);
CREATE TABLE IF NOT EXISTS card_stack_likes (
    stack_id TEXT NOT NULL REFERENCES card_stacks(id),
    user_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (stack_id, user_id)
);
CREATE TABLE IF NOT EXISTS card_stack_reports (
    stack_id TEXT NOT NULL REFERENCES card_stacks(id),
    reporter_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    note TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (stack_id, reporter_id)
);
"""


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@contextmanager
def cursor():
    """community.db mit den Tabellen dieses Moduls (und denen von app/community.py: Mitglieder, Sperren, Bann)."""
    with community.cursor() as conn:
        db.schema_once(conn, "community_cards", community.db_path(), ensure_schema)
        yield conn


def _schema(conn) -> None:
    """Schema auf einer fremden Verbindung zu community.db (Moderation, Bann): einmal je Prozess wie `cursor`."""
    db.schema_once(conn, "community_cards", community.db_path(), ensure_schema)


def ensure_schema(conn) -> None:
    """Tabellen anlegen; aeltere community.db bekommt die Spalte updated_at (Ersetzen, 04.11.2026)."""
    conn.executescript(SCHEMA)
    db.add_column(conn, "card_stacks", "updated_at", "TEXT")      # mehrere Prozesse zugleich (Audit P11-02)


# ---------------------------------------------------------------- Pruefungen

def clean_cards(cards) -> list[dict]:
    """Nur Frage und Antwort als Text ohne Leerraum aussen, hoechstens MAX_CARDS; leer = 422."""
    if not isinstance(cards, list):
        raise CommunityError("cards_invalid", "Karten fehlen.", 422)
    out = []
    for c in cards:
        if not isinstance(c, dict):
            continue
        q, a = str(c.get("question") or "").strip(), str(c.get("answer") or "").strip()
        if q and a:
            out.append({"question": q[:MAX_CARD_CHARS], "answer": a[:MAX_CARD_CHARS]})
    if not out:
        raise CommunityError("stack_empty", "Der Stapel hat keine Karten.", 422)
    if len(out) > MAX_CARDS:
        raise CommunityError("too_many_cards", f"Höchstens {MAX_CARDS} Karten je geteiltem Stapel.", 413)
    return out


def _week(v):
    if v is None:
        return None
    if isinstance(v, bool) or not isinstance(v, int) or v < 1:
        raise CommunityError("week_invalid", "week: ganze Zahl ab 1 oder null erwartet.", 422)
    return v


def _summary(r, me: str, conn, reported: set[str], adopted: set[str] | None = None) -> dict:
    return {"id": r["id"], "community_key": r["community_key"], "name": r["name"], "kind": r["kind"], "week": r["week"],
            "cards": r["card_count"], "pseudonym": r["pseudonym"], "created_at": r["created_at"], "updated_at": r["updated_at"],
            "status": r["status"],
            "mine": r["author_id"] == me, "reported_by_me": r["id"] in reported,
            "adopted": r["id"] in (adopted or set()), "adopt_count": r["adopt_count"],
            "likes": conn.execute("SELECT COUNT(*) FROM card_stack_likes WHERE stack_id=?", (r["id"],)).fetchone()[0],
            "liked_by_me": bool(conn.execute("SELECT 1 FROM card_stack_likes WHERE stack_id=? AND user_id=?", (r["id"], me)).fetchone())}


def _require_member(conn, user: dict, key: str) -> None:
    if not community._member(conn, user, key):
        raise CommunityError("not_a_member", "Tritt zuerst der Community dieses Moduls bei.", 403)


def _visible(conn, user: dict, stack_id: str):
    """Geteilter Stapel, den dieses Konto sehen darf (aktiv, Autor nicht gebannt oder gesperrt, Mitglied) oder der eigene."""
    r = conn.execute("SELECT * FROM card_stacks WHERE id=?", ((stack_id or "").lower(),)).fetchone()
    if not r or (r["status"] != "active" and r["author_id"] != user["id"]):
        raise CommunityError("not_found", "Geteilter Stapel nicht gefunden.", 404)
    if r["author_id"] != user["id"]:
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (r["author_id"],)).fetchone():
            raise CommunityError("not_found", "Geteilter Stapel nicht gefunden.", 404)
        if conn.execute("SELECT 1 FROM blocks WHERE user_id=? AND pseudonym=?", (user["id"], r["pseudonym"])).fetchone():
            raise CommunityError("not_found", "Geteilter Stapel nicht gefunden.", 404)
        _require_member(conn, user, r["community_key"])
    return r


# ---------------------------------------------------------------- Teilen, Zurueckziehen, Liste

def share(user: dict, university: str, community_key, name, kind, week, cards, stack_id: str | None = None) -> dict:
    """Kopie eines eigenen Stapels in die Modul-Community (Tarif wie Loesungen teilen, bestaetigte E-Mail, Mitglied)."""
    key = community._community_key(community_key)
    community.require_plan(user)
    community._require_verified(user, "Stapel zu teilen")
    if not isinstance(name, str) or not name.strip():
        raise CommunityError("name_required", "Name des Stapels fehlt.", 422)
    if kind not in KINDS:
        raise CommunityError("kind_invalid", "kind: vorlesung, uebung oder eigene erwartet.", 422)
    week = _week(week)
    clean = clean_cards(cards)
    sid = (stack_id or uuid.uuid4().hex).lower()
    with cursor() as conn:
        if community._kind_is(conn, key, "group"):
            raise CommunityError("community_invalid", "Stapel lassen sich nur in der Community eines Moduls teilen.", 422)
        _require_member(conn, user, key)
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf in der Community nichts mehr schreiben.", 403)
        if conn.execute("SELECT 1 FROM card_stacks WHERE id=?", (sid,)).fetchone():
            raise CommunityError("already_shared", "Dieser Stapel ist schon geteilt.", 409)
        community._limit("deck_user", user["id"])               # neue geteilte Stapel je Konto und Tag
        conn.execute("""INSERT INTO card_stacks(id, community_key, university, author_id, pseudonym, name, kind, week, cards, card_count, created_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                     (sid, key, university, user["id"], community.pseudonym(user["id"]), name.strip()[:MAX_NAME], kind, week,
                      json.dumps(clean, ensure_ascii=False), len(clean), _now()))
        r = conn.execute("SELECT * FROM card_stacks WHERE id=?", (sid,)).fetchone()
        return _summary(r, user["id"], conn, set())


def replace(user: dict, stack_id: str, name, cards) -> dict:
    """Geteilten Stapel mit dem aktuellen Stand des eigenen ersetzen (Karten und Name); Kennung, Modul, Woche, Likes
    und Uebernahmen bleiben. Nur der Autor, nicht nach dem Zurueckziehen, nicht solange er nach Meldungen verborgen ist.
    Wer schon uebernommen hat, behaelt seine Kopie."""
    community._require_verified(user, "Stapel zu teilen")
    clean = clean_cards(cards)
    with cursor() as conn:
        r = conn.execute("SELECT * FROM card_stacks WHERE id=? AND status<>'withdrawn'", ((stack_id or "").lower(),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Geteilter Stapel nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur der Autor kann einen geteilten Stapel ändern.", 403)
        if r["status"] == "hidden":
            raise CommunityError("stack_hidden", "Der Stapel ist nach Meldungen verborgen und wird geprüft.", 403)
        _require_member(conn, user, r["community_key"])
        n = name.strip()[:MAX_NAME] if isinstance(name, str) and name.strip() else r["name"]
        community._limit("update_user", user["id"])
        conn.execute("UPDATE card_stacks SET name=?, cards=?, card_count=?, updated_at=? WHERE id=?",
                     (n, json.dumps(clean, ensure_ascii=False), len(clean), _now(), r["id"]))
        return _summary(conn.execute("SELECT * FROM card_stacks WHERE id=?", (r["id"],)).fetchone(), user["id"], conn, set())


def withdraw(user: dict, stack_id: str) -> dict:
    with cursor() as conn:
        r = conn.execute("SELECT * FROM card_stacks WHERE id=?", ((stack_id or "").lower(),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Geteilter Stapel nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur der Autor kann einen geteilten Stapel zurückziehen.", 403)
        if r["status"] == "withdrawn":
            return {"withdrawn": True, "already": True}
        conn.execute("UPDATE card_stacks SET status='withdrawn', cards='[]' WHERE id=?", (r["id"],))
    return {"withdrawn": True, "already": False}


def listing(user: dict, community_key, week=None, adopted: set[str] | None = None) -> list[dict]:
    """Geteilte Stapel eines Moduls fuer Mitglieder, ohne gesperrte und gebannte Autoren; `week` None = alle,
    0 = nur Allgemein, sonst die Woche. Meistgelikte zuerst, bei Gleichstand die neuesten."""
    key = community._community_key(community_key)
    with cursor() as conn:
        _require_member(conn, user, key)
        rows = conn.execute("SELECT * FROM card_stacks WHERE community_key=? AND status='active' ORDER BY created_at DESC", (key,)).fetchall()
        blocked = {r["pseudonym"] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}
        banned = {r["author_id"] for r in conn.execute("SELECT author_id FROM bans")}
        reported = {r["stack_id"] for r in conn.execute("SELECT stack_id FROM card_stack_reports WHERE reporter_id=?", (user["id"],))}
        out = []
        for r in rows:
            if r["pseudonym"] in blocked or r["author_id"] in banned:
                continue
            if week is not None and (r["week"] is not None if week == 0 else r["week"] != week):
                continue
            out.append(_summary(r, user["id"], conn, reported, adopted))
        out.sort(key=lambda x: x["created_at"], reverse=True)
        out.sort(key=lambda x: -x["likes"])
        return out


def get(user: dict, stack_id: str) -> dict:
    """Ein geteilter Stapel mit seinen Karten (Mitglieder)."""
    with cursor() as conn:
        r = _visible(conn, user, stack_id)
        reported = {x["stack_id"] for x in conn.execute("SELECT stack_id FROM card_stack_reports WHERE reporter_id=?", (user["id"],))}
        return {**_summary(r, user["id"], conn, reported), "cards_list": json.loads(r["cards"] or "[]")}


def count_adopted(user: dict, stack_id: str) -> None:
    with cursor() as conn:
        conn.execute("UPDATE card_stacks SET adopt_count=adopt_count+1 WHERE id=?", ((stack_id or "").lower(),))


def mine(user: dict) -> list[dict]:
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM card_stacks WHERE author_id=? AND status<>'withdrawn' ORDER BY created_at DESC", (user["id"],)).fetchall()
        return [_summary(r, user["id"], conn, set()) for r in rows]


# ---------------------------------------------------------------- Like, Melden

def like(user: dict, stack_id: str, on: bool = True) -> dict:
    community._require_verified(user, "Stapel zu liken")
    with cursor() as conn:
        r = _visible(conn, user, stack_id)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_stack", "Der eigene Stapel lässt sich nicht liken.")
        if on:
            if not conn.execute("SELECT 1 FROM card_stack_likes WHERE stack_id=? AND user_id=?", (r["id"], user["id"])).fetchone():
                community._limit("like_user", user["id"])
                conn.execute("INSERT OR IGNORE INTO card_stack_likes(stack_id, user_id, created_at) VALUES (?,?,?)", (r["id"], user["id"], _now()))
        else:
            conn.execute("DELETE FROM card_stack_likes WHERE stack_id=? AND user_id=?", (r["id"], user["id"]))
        n = conn.execute("SELECT COUNT(*) FROM card_stack_likes WHERE stack_id=?", (r["id"],)).fetchone()[0]
    return {"id": r["id"], "liked": on, "likes": n}


def report(user: dict, stack_id: str, reason: str, note: str | None) -> dict:
    """Melden wie Loesungen: ein Konto einmal je Stapel, ab REPORTS_TO_HIDE Meldungen verborgen."""
    if reason not in REPORT_REASONS:
        raise CommunityError("reason_invalid", "Unbekannter Meldegrund.")
    community._require_verified(user, "Stapel zu melden")
    with cursor() as conn:
        r = _visible(conn, user, stack_id)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_stack", "Der eigene Stapel lässt sich nicht melden, aber zurückziehen.")
        if conn.execute("SELECT 1 FROM card_stack_reports WHERE stack_id=? AND reporter_id=?", (r["id"], user["id"])).fetchone():
            raise CommunityError("already_reported", "Du hast diesen Stapel schon gemeldet.", 409)
        community._limit("report_user", user["id"])
        conn.execute("INSERT INTO card_stack_reports(stack_id, reporter_id, reason, note, created_at) VALUES (?,?,?,?,?)",
                     (r["id"], user["id"], reason, (note or "")[:500] or None, _now()))
        n = conn.execute("SELECT COUNT(*) FROM card_stack_reports WHERE stack_id=?", (r["id"],)).fetchone()[0]
        hidden = r["status"] == "hidden"
        if n >= REPORTS_TO_HIDE and r["status"] == "active":
            conn.execute("UPDATE card_stacks SET status='hidden', report_count=? WHERE id=?", (n, r["id"]))
            hidden = True
        else:
            conn.execute("UPDATE card_stacks SET report_count=? WHERE id=?", (n, r["id"]))
    return {"reported": True, "hidden": hidden, "reports": n}


# ---------------------------------------------------------------- Moderation, Bann, Konto, Export

def moderation_items(conn) -> list[dict]:
    """Gemeldete oder verborgene Stapel fuer die Moderation (Name und die ersten Karten als Text); `conn` auf community.db."""
    _schema(conn)
    items = []
    for r in conn.execute("SELECT * FROM card_stacks WHERE status='hidden' OR (status='active' AND report_count>0) "
                          "ORDER BY status='hidden' DESC, report_count DESC, created_at DESC, rowid DESC"):
        reps = [{"reason": x["reason"], "created_at": x["created_at"], "reporter": community.reporter_info(x["reporter_id"])}
                for x in conn.execute("SELECT reason, created_at, reporter_id FROM card_stack_reports WHERE stack_id=? ORDER BY created_at, rowid",
                                      (r["id"],))]
        cards = json.loads(r["cards"] or "[]")
        text = r["name"] + "\n" + "\n".join(f"{c['question']} — {c['answer']}" for c in cards[:5])
        items.append({"id": r["id"], "kind": "card_stack", "status": r["status"], "pseudonym": r["pseudonym"], "text": text[:300],
                      "context": r["community_key"], "week": r["week"], "cards": r["card_count"],
                      "created_at": r["created_at"], "report_count": r["report_count"], "reports": reps})
    return items


def restore(conn, stack_id: str):
    """Moderation: verborgenen Stapel freigeben (Meldungen werden geloescht). None = kein verborgener mit dieser Kennung."""
    _schema(conn)
    r = conn.execute("SELECT id FROM card_stacks WHERE id=? AND status='hidden'", ((stack_id or "").lower(),)).fetchone()
    if r:
        conn.execute("UPDATE card_stacks SET status='active', report_count=0 WHERE id=?", (r["id"],))
        conn.execute("DELETE FROM card_stack_reports WHERE stack_id=?", (r["id"],))
    return r


def withdraw_all(conn, user_id: str) -> int:
    """Bann oder Konto geloescht (community.withdraw_all): alle geteilten Stapel sofort weg (Karten geleert)."""
    _schema(conn)
    return conn.execute("UPDATE card_stacks SET status='withdrawn', cards='[]' WHERE author_id=? AND status<>'withdrawn'",
                        (user_id,)).rowcount


def exported(user: dict) -> list[dict]:
    """Eigene geteilte Stapel fuer den Datenexport (mit Karten), ohne Konto-IDs."""
    with cursor() as conn:
        return [{"id": r["id"], "community_key": r["community_key"], "name": r["name"], "kind": r["kind"], "week": r["week"],
                 "created_at": r["created_at"], "updated_at": r["updated_at"], "status": r["status"], "adopt_count": r["adopt_count"],
                 "cards": json.loads(r["cards"] or "[]")}
                for r in conn.execute("SELECT * FROM card_stacks WHERE author_id=? ORDER BY created_at, rowid", (user["id"],))]


def forget_author(user_id: str) -> int:
    """Konto loeschen: eigene geteilte Stapel, Likes und Meldungen entfernen."""
    with cursor() as conn:
        n = conn.execute("UPDATE card_stacks SET status='withdrawn', cards='[]' WHERE author_id=? AND status<>'withdrawn'", (user_id,)).rowcount
        conn.execute("DELETE FROM card_stack_likes WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM card_stack_reports WHERE reporter_id=?", (user_id,))
    return n


# ---------------------------------------------------------------- Modul-Schluessel der lokalen Datenbank

def module_key(conn, module_id: int) -> tuple[str | None, str | None]:
    """(Modulname, Community-Schluessel des Moduls) aus der lokalen Datenbank: der Schluessel des Modulnamens
    (community_module_key, wie `courses_community_keys`); (None, None) ohne Modul."""
    from .solution_format import community_module_key
    m = db.row(conn, "SELECT name FROM modules WHERE id=?", (module_id,))
    if not m or not m["name"]:
        return None, None
    return m["name"], community_module_key(config.university(), m["name"])


def module_for_key(conn, key: str) -> dict | None:
    """Lokales Modul zu einem Community-Schluessel (Modulname oder Kurstitel), sonst None."""
    from .solution_format import community_module_key
    from .studip_sync import classify
    uni = config.university()
    for m in db.rows(conn, "SELECT id, name FROM modules ORDER BY id"):
        if m["name"] and community_module_key(uni, m["name"]) == key:
            return m
    for c in db.rows(conn, "SELECT title, module_id FROM courses WHERE id<>'__user__' AND module_id IS NOT NULL"):
        if community_module_key(uni, classify(c["title"])[0]) == key:
            return db.row(conn, "SELECT id, name FROM modules WHERE id=?", (c["module_id"],))
    return None
