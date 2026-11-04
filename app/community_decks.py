"""Karteikarten teilen und nutzen im Dienst (Wunsch des Inhabers vom 04.11.2026, docs/PREISLISTE.md: "Karteikarten teilen
und die anderer nutzen, je Lernwoche oder fuers ganze Modul", ab StudiNow Plus).

Ein Stapel gehoert zu genau einer Community (Kurs/Modul oder Lerngruppe, `community_key`) und optional zu einer Lehrwoche
(`lecture_week`, NULL = ganzes Modul). Sichtbar nur fuer Mitglieder der Community (gleiche Pruefung wie Fragen,
`community_qa._require_member`; wer den Kurs hat oder hatte). Autoren erscheinen nur mit Pseudonym, nie mit Konto-ID
oder E-Mail.

**Speicherung wie Kommentare und Fragen im Dienst** (docs/LOESUNGEN-TEILEN.md, Abschnitt 6c): Frage und Antwort liegen als
Text in `community.db` (Tabelle `flashcard_decks`, Spalte `cards` als JSON), geschuetzt durch die Mitgliedschaft; die
Moderation sieht den Text. Keine Ende-zu-Ende-Verschluesselung wie bei Loesungen: Karteikarten sind eigener Text der
Studierenden (kein Material aus der PDF) und muessen fuer Meldungen lesbar sein.

Regeln: Veroeffentlichen und Ersetzen mit dem Recht `can_share_flashcards` (Plus), bestaetigter E-Mail, Mitgliedschaft und
ohne Sperre; hoechstens `deck_user` neue Stapel je Konto und Tag, `update_user` Ersetzungen; je Konto, Community und
Lehrwoche ein Stapel (409 `already_published` mit `deck_id`, dann PUT); 1..MAX_CARDS Karten, je Seite hoechstens
MAX_SIDE Zeichen, Titel hoechstens MAX_TITLE. Uebernehmen (Kopie in die eigenen Karten) mit `can_share_flashcards`;
gezaehlt wird jedes Konto einmal (`uses`). Zurueckziehen: nur der Autor oder die Moderation, die Karten werden geleert.
Melden: bestaetigte E-Mail, `report_user`, eine Meldung je Konto, ab REPORTS_TO_HIDE verborgen; die Moderation kann
freigeben. Konto loeschen: Stapel sofort zurueckgezogen, beim endgueltigen Loeschen samt Meldungen und Nutzungen
entfernt; der Datenexport enthaelt die eigenen Stapel.
"""
from __future__ import annotations

import json
import uuid

from . import community
from .community import CommunityError, REPORT_REASONS, REPORTS_TO_HIDE, _limit, _now, _require_verified, pseudonym

SCHEMA = """
CREATE TABLE IF NOT EXISTS flashcard_decks (
    id TEXT PRIMARY KEY,                       -- 32 Hex-Zeichen (uuid4)
    community_key TEXT NOT NULL,
    university TEXT NOT NULL,
    author_id TEXT NOT NULL,                   -- Konto-ID (intern), nach aussen nur das Pseudonym
    pseudonym TEXT NOT NULL,
    title TEXT NOT NULL,
    lecture_week INTEGER,                      -- NULL = ganzes Modul
    cards TEXT NOT NULL,                       -- JSON [{question, answer}]; leer nach dem Zurueckziehen
    card_count INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT,
    status TEXT NOT NULL DEFAULT 'active',     -- active | withdrawn | hidden
    report_count INTEGER NOT NULL DEFAULT 0,
    uses INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_decks_community ON flashcard_decks(community_key, status, lecture_week);
CREATE INDEX IF NOT EXISTS idx_decks_author ON flashcard_decks(author_id);
CREATE TABLE IF NOT EXISTS deck_reports (
    deck_id TEXT NOT NULL REFERENCES flashcard_decks(id),
    reporter_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (deck_id, reporter_id)
);
CREATE TABLE IF NOT EXISTS deck_uses (
    deck_id TEXT NOT NULL REFERENCES flashcard_decks(id),
    user_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (deck_id, user_id)
);
"""

MAX_CARDS = 500
MAX_SIDE = 1_000
MAX_TITLE = 120
WEEK_MAX = 30
PREVIEW = 3                                    # so viele Fragen zeigt die Liste je Stapel


# ---------------------------------------------------------------- Eingaben

def _week(v) -> int | None:
    if v is None or v == "" or v == "module":
        return None
    if isinstance(v, bool) or (isinstance(v, float) and v != int(v)):
        raise CommunityError("week_invalid", "Ungültige Lernwoche.")
    try:
        w = int(v)
    except (TypeError, ValueError):
        raise CommunityError("week_invalid", "Ungültige Lernwoche.")
    if not 1 <= w <= WEEK_MAX:
        raise CommunityError("week_invalid", f"Die Lernwoche liegt zwischen 1 und {WEEK_MAX}.")
    return w


def _title(v, week: int | None) -> str:
    t = " ".join(str(v or "").split())
    if not t:
        t = f"Karteikarten Woche {week}" if week is not None else "Karteikarten zum Modul"
    if len(t) > MAX_TITLE:
        raise CommunityError("text_too_long", f"Der Titel hat höchstens {MAX_TITLE} Zeichen.")
    return t


def _cards(raw) -> list[dict]:
    """Karten pruefen: Liste von {question, answer} als Text; leere Karten fallen weg, gleiche Fragen nur einmal."""
    if not isinstance(raw, list):
        raise CommunityError("cards_invalid", "Der Stapel hat keine Karten.")
    if len(raw) > MAX_CARDS:
        raise CommunityError("too_many_cards", f"Ein Stapel hat höchstens {MAX_CARDS} Karten.", 413)
    out, seen = [], set()
    for c in raw:
        if not isinstance(c, dict) or not isinstance(c.get("question"), str) or not isinstance(c.get("answer"), str):
            continue
        q, a = c["question"].strip(), c["answer"].strip()
        if not q or not a:
            continue
        if len(q) > MAX_SIDE or len(a) > MAX_SIDE:
            raise CommunityError("text_too_long", f"Eine Kartenseite hat höchstens {MAX_SIDE} Zeichen.")
        key = " ".join(q.lower().split())
        if key in seen:
            continue
        seen.add(key)
        out.append({"question": q, "answer": a})
    if not out:
        raise CommunityError("cards_invalid", "Der Stapel hat keine Karten.")
    return out


def _deck_id(v) -> str:
    return str(v or "").lower()[:64]


def _can_share(user: dict, what: str) -> None:
    from . import entitlements
    if not entitlements.has(user, "can_share_flashcards"):
        raise CommunityError("plan_required", f"{what} gibt es ab StudiNow Plus.", 403)


# ---------------------------------------------------------------- Ausgabe

def _out(conn, r, me: str, with_cards: bool = False) -> dict:
    cards = json.loads(r["cards"] or "[]")
    out = {"id": r["id"], "community_key": r["community_key"], "title": r["title"], "lecture_week": r["lecture_week"],
           "card_count": r["card_count"], "pseudonym": r["pseudonym"], "created_at": r["created_at"], "updated_at": r["updated_at"],
           "uses": r["uses"], "status": r["status"], "mine": r["author_id"] == me,
           "used_by_me": bool(conn.execute("SELECT 1 FROM deck_uses WHERE deck_id=? AND user_id=?", (r["id"], me)).fetchone()),
           "reported_by_me": bool(conn.execute("SELECT 1 FROM deck_reports WHERE deck_id=? AND reporter_id=?", (r["id"], me)).fetchone()),
           "preview": [c["question"] for c in cards[:PREVIEW]]}
    if with_cards:
        out["cards"] = cards
    return out


def _hidden_for(conn, user: dict) -> tuple[set[str], set[str]]:
    blocked = {r[0] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}
    banned = {r[0] for r in conn.execute("SELECT author_id FROM bans")}
    return blocked, banned


def _visible(conn, user: dict, deck_id: str):
    """Stapel, den dieses Konto sehen darf: aktiv und Mitglied der Community (oder der eigene, oder Moderation)."""
    r = conn.execute("SELECT * FROM flashcard_decks WHERE id=?", (_deck_id(deck_id),)).fetchone()
    admin = user.get("role") == "admin"
    if not r or r["status"] == "withdrawn" or (r["status"] != "active" and r["author_id"] != user["id"] and not admin):
        raise CommunityError("not_found", "Stapel nicht gefunden.", 404)
    if r["author_id"] != user["id"] and not admin:
        blocked, banned = _hidden_for(conn, user)
        if r["pseudonym"] in blocked or r["author_id"] in banned or not community._member(conn, user, r["community_key"]):
            raise CommunityError("not_found", "Stapel nicht gefunden.", 404)
    return r


# ---------------------------------------------------------------- Lesen

def list_decks(user: dict, university: str, community_key, week=None) -> dict:
    """Stapel einer Community fuer Mitglieder: meistgenutzte zuerst. `week`: Zahl = nur diese Lehrwoche, "module" = nur
    Stapel fuers ganze Modul, leer = alle. `weeks` zaehlt alle sichtbaren Stapel je Woche ("module" = ganzes Modul)."""
    from .community_qa import _require_member
    key = community._community_key(community_key)
    only = "module" if week == "module" else (_week(week) if week not in (None, "", "all") else None)
    with community.cursor() as conn:
        _require_member(conn, user, key)
        blocked, banned = _hidden_for(conn, user)
        rows = conn.execute("SELECT * FROM flashcard_decks WHERE community_key=? AND university=? AND status='active' "
                            "ORDER BY uses DESC, created_at DESC, rowid DESC", (key, university)).fetchall()
        rows = [r for r in rows if r["pseudonym"] not in blocked and r["author_id"] not in banned]
        weeks: dict[str, int] = {}
        for r in rows:
            k = "module" if r["lecture_week"] is None else str(r["lecture_week"])
            weeks[k] = weeks.get(k, 0) + 1
        if only == "module":
            rows = [r for r in rows if r["lecture_week"] is None]
        elif only is not None:
            rows = [r for r in rows if r["lecture_week"] == only]
        return {"decks": [_out(conn, r, user["id"]) for r in rows], "weeks": weeks}


def get(user: dict, deck_id: str) -> dict:
    with community.cursor() as conn:
        return _out(conn, _visible(conn, user, deck_id), user["id"], with_cards=True)


def mine(user: dict) -> list[dict]:
    with community.cursor() as conn:
        rows = conn.execute("SELECT * FROM flashcard_decks WHERE author_id=? AND status<>'withdrawn' ORDER BY created_at DESC, rowid DESC",
                            (user["id"],)).fetchall()
        return [_out(conn, r, user["id"]) for r in rows]


# ---------------------------------------------------------------- Schreiben

def publish(user: dict, university: str, community_key, title, lecture_week, cards) -> dict:
    """Stapel veroeffentlichen. Je Konto, Community und Lehrwoche einer: ein zweiter antwortet 409 already_published."""
    from .community_qa import _require_member
    _can_share(user, "Karteikarten teilen")
    _require_verified(user, "teilen")
    key = community._community_key(community_key)
    week = _week(lecture_week)
    t, cs = _title(title, week), _cards(cards)
    with community.cursor() as conn:
        _require_member(conn, user, key)
        if conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user["id"],)).fetchone():
            raise CommunityError("author_banned", "Dein Konto darf in der Community nichts mehr schreiben.", 403)
        own = conn.execute("SELECT id FROM flashcard_decks WHERE author_id=? AND community_key=? AND lecture_week IS ? "
                           "AND status IN ('active','hidden') ORDER BY created_at DESC LIMIT 1", (user["id"], key, week)).fetchone()
        if own:
            raise CommunityError("already_published", "Du hast für diese Woche schon einen Stapel geteilt. Aktualisieren?", 409,
                                 {"deck_id": own["id"]})
        _limit("deck_user", user["id"])
        did, now = uuid.uuid4().hex, _now()
        conn.execute("""INSERT INTO flashcard_decks(id, community_key, university, author_id, pseudonym, title, lecture_week, cards,
                        card_count, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
                     (did, key, university, user["id"], pseudonym(user["id"]), t, week, json.dumps(cs, ensure_ascii=False), len(cs), now))
        return _out(conn, conn.execute("SELECT * FROM flashcard_decks WHERE id=?", (did,)).fetchone(), user["id"], with_cards=True)


def update(user: dict, deck_id: str, title, cards) -> dict:
    """Karten (und Titel) des eigenen Stapels ersetzen; ID, Community, Woche und Nutzungen bleiben."""
    from .community_qa import _require_member
    _can_share(user, "Karteikarten teilen")
    _require_verified(user, "teilen")
    cs = _cards(cards)
    with community.cursor() as conn:
        r = conn.execute("SELECT * FROM flashcard_decks WHERE id=? AND status<>'withdrawn'", (_deck_id(deck_id),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Stapel nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur wer den Stapel geteilt hat, kann ihn ändern.", 403)
        if r["status"] == "hidden":
            raise CommunityError("deck_blocked", "Der Stapel ist nach Meldungen verborgen und wird geprüft.", 403)
        _require_member(conn, user, r["community_key"])
        t = _title(title, r["lecture_week"]) if title is not None else r["title"]
        _limit("update_user", user["id"])
        conn.execute("UPDATE flashcard_decks SET title=?, cards=?, card_count=?, updated_at=? WHERE id=?",
                     (t, json.dumps(cs, ensure_ascii=False), len(cs), _now(), r["id"]))
        return _out(conn, conn.execute("SELECT * FROM flashcard_decks WHERE id=?", (r["id"],)).fetchone(), user["id"], with_cards=True)


def adopt(user: dict, deck_id: str) -> dict:
    """In die eigenen Karten uebernehmen: liefert die Karten (die Kopie legt das Geraet bzw. der Browser an, mit
    Herkunft `community:<id>`) und zaehlt das Konto einmal als Nutzer des Stapels."""
    _can_share(user, "Karteikarten anderer nutzen")
    with community.cursor() as conn:
        r = _visible(conn, user, deck_id)
        if r["status"] != "active":
            raise CommunityError("not_found", "Stapel nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            if conn.execute("INSERT OR IGNORE INTO deck_uses(deck_id, user_id, created_at) VALUES (?,?,?)",
                            (r["id"], user["id"], _now())).rowcount:
                conn.execute("UPDATE flashcard_decks SET uses=uses+1 WHERE id=?", (r["id"],))
        r = conn.execute("SELECT * FROM flashcard_decks WHERE id=?", (r["id"],)).fetchone()
        d = _out(conn, r, user["id"], with_cards=True)
    return {"deck": {k: v for k, v in d.items() if k != "cards"}, "cards": d["cards"], "origin": f"community:{r['id']}"}


def withdraw(user: dict, deck_id: str) -> dict:
    """Zurueckziehen: nur der Autor oder die Moderation; die Karten werden geleert."""
    with community.cursor() as conn:
        r = conn.execute("SELECT * FROM flashcard_decks WHERE id=?", (_deck_id(deck_id),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Stapel nicht gefunden.", 404)
        if r["author_id"] != user["id"] and user.get("role") != "admin":
            raise CommunityError("not_owner", "Nur wer den Stapel geteilt hat, kann ihn zurückziehen.", 403)
        if r["status"] == "withdrawn":
            return {"withdrawn": True, "already": True}
        conn.execute("UPDATE flashcard_decks SET status='withdrawn', cards='[]', card_count=0 WHERE id=?", (r["id"],))
    return {"withdrawn": True, "already": False}


def report(user: dict, deck_id: str, reason) -> dict:
    if reason not in REPORT_REASONS:
        raise CommunityError("reason_invalid", "Unbekannter Meldegrund.")
    _require_verified(user, "melden")
    with community.cursor() as conn:
        r = _visible(conn, user, deck_id)
        if r["author_id"] == user["id"]:
            raise CommunityError("own_post", "Den eigenen Stapel kannst du zurückziehen statt melden.")
        if conn.execute("SELECT 1 FROM deck_reports WHERE deck_id=? AND reporter_id=?", (r["id"], user["id"])).fetchone():
            raise CommunityError("already_reported", "Du hast diesen Stapel schon gemeldet.", 409)
        _limit("report_user", user["id"])
        conn.execute("INSERT INTO deck_reports(deck_id, reporter_id, reason, created_at) VALUES (?,?,?,?)", (r["id"], user["id"], reason, _now()))
        n = conn.execute("SELECT COUNT(*) FROM deck_reports WHERE deck_id=?", (r["id"],)).fetchone()[0]
        hidden = n >= REPORTS_TO_HIDE
        conn.execute("UPDATE flashcard_decks SET report_count=?, status=CASE WHEN ? AND status='active' THEN 'hidden' ELSE status END WHERE id=?",
                     (n, hidden, r["id"]))
    return {"reported": True, "hidden": hidden, "reports": n}


# ---------------------------------------------------------------- Moderation, Konto, Export

def moderation_items(conn) -> list[dict]:
    """Gemeldete oder verborgene Stapel fuer die Moderation (Titel und die ersten Fragen als Text)."""
    items = []
    for r in conn.execute("SELECT * FROM flashcard_decks WHERE status='hidden' OR (status='active' AND report_count>0) "
                          "ORDER BY status='hidden' DESC, report_count DESC, created_at DESC, rowid DESC"):
        reps = [{"reason": x["reason"], "created_at": x["created_at"], "reporter": community.reporter_info(x["reporter_id"])}
                for x in conn.execute("SELECT reason, created_at, reporter_id FROM deck_reports WHERE deck_id=? ORDER BY created_at, rowid", (r["id"],))]
        cards = json.loads(r["cards"] or "[]")
        text = r["title"] + "\n" + "\n".join(f"{c['question']} — {c['answer']}" for c in cards[:5])
        items.append({"id": r["id"], "kind": "deck", "status": r["status"], "pseudonym": r["pseudonym"], "text": text[:300],
                      "context": r["community_key"], "lecture_week": r["lecture_week"], "card_count": r["card_count"],
                      "created_at": r["created_at"], "report_count": r["report_count"], "reports": reps})
    return items


def restore(conn, deck_id: str):
    """Moderation: verborgenen Stapel freigeben (Meldungen werden geloescht). None = kein verborgener mit dieser Kennung."""
    r = conn.execute("SELECT id FROM flashcard_decks WHERE id=? AND status='hidden'", (_deck_id(deck_id),)).fetchone()
    if r:
        conn.execute("UPDATE flashcard_decks SET status='active', report_count=0 WHERE id=?", (r["id"],))
        conn.execute("DELETE FROM deck_reports WHERE deck_id=?", (r["id"],))
    return r


def withdraw_all(conn, user_id: str) -> int:
    """Konto geloescht: alle Stapel sofort nicht mehr sichtbar (Karten geleert)."""
    return conn.execute("UPDATE flashcard_decks SET status='withdrawn', cards='[]', card_count=0 WHERE author_id=? AND status<>'withdrawn'",
                        (user_id,)).rowcount


def forget(conn, user_id: str) -> None:
    """Konto endgueltig geloescht: eigene Stapel samt Meldungen und Nutzungen, eigene Meldungen und Nutzungen entfernen."""
    for (did,) in conn.execute("SELECT id FROM flashcard_decks WHERE author_id=?", (user_id,)).fetchall():
        conn.execute("DELETE FROM deck_reports WHERE deck_id=?", (did,))
        conn.execute("DELETE FROM deck_uses WHERE deck_id=?", (did,))
        conn.execute("DELETE FROM flashcard_decks WHERE id=?", (did,))
    conn.execute("DELETE FROM deck_reports WHERE reporter_id=?", (user_id,))
    conn.execute("DELETE FROM deck_uses WHERE user_id=?", (user_id,))


def exported(user: dict) -> list[dict]:
    """Eigene Stapel fuer den Datenexport (mit Karten), ohne Konto-IDs."""
    with community.cursor() as conn:
        return [{"id": r["id"], "community_key": r["community_key"], "title": r["title"], "lecture_week": r["lecture_week"],
                 "created_at": r["created_at"], "updated_at": r["updated_at"], "status": r["status"], "uses": r["uses"],
                 "cards": json.loads(r["cards"] or "[]")}
                for r in conn.execute("SELECT * FROM flashcard_decks WHERE author_id=? ORDER BY created_at, rowid", (user["id"],))]
