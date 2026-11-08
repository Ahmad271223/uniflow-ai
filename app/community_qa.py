"""Community, Teil 2 (Vertrag G4, 28.10.2026): Fragen je Kurs mit Antworten, Lesezeichen, Benachrichtigungen.

- **Fragen je Kurs:** Schluessel wie auf dem iPad (`CommunityKeys.courseKey`): SHA-256 aus
  "uniflow.community.course.v1\\0<hochschule>\\0<kurs-id>". Der Dienst kennt nie die Kurs-ID oder den Kursnamen; wer
  die Kurs-ID nicht kennt (kein Kursmitglied), kann den Schluessel nicht bilden (Entscheidung des Inhabers vom
  26.10.2026). Optional mit Bezug auf eine PDF (Fingerabdruck) und Seite. Antworten mit "hilfreich"-Stimmen; wer die
  Frage gestellt hat, kann eine Antwort als Loesung markieren. Melden wie bei Kommentaren (ab 3 Meldungen verborgen),
  gesperrte Autoren und eigene Sperrliste gelten auch hier. Melden verlangt eine bestaetigte E-Mail-Adresse, die
  Sichtbarkeit der Frage und ist je Konto und Tag begrenzt (`report_user`); die Moderation kann Verborgenes freigeben.
- **Lesezeichen** fuer Loesungen und Fragen (privat).
- **Benachrichtigungen** im Konto (keine Push-Nachricht): Kommentar oder Antwort auf eigene Loesung, Antwort auf
  eigenen Kommentar, Like auf eigene Loesung (gebuendelt je Loesung und Tag), Antwort auf eigene Frage, eigene Antwort
  als Loesung markiert. Nie ueber sich selbst.
Schreiben (Frage, Antwort) ab StudiNow Plus mit bestaetigter E-Mail und Grenzen je Stunde; lesen alle Konten.
"""
from __future__ import annotations

import re
import uuid
from contextlib import contextmanager

from . import community, db
from .community import CommunityError, _limit, _now, _require_verified, pseudonym

SCHEMA = """
CREATE TABLE IF NOT EXISTS questions (
    id TEXT PRIMARY KEY, course_key TEXT NOT NULL, university TEXT NOT NULL, author_id TEXT NOT NULL, pseudonym TEXT NOT NULL,
    title TEXT NOT NULL, body TEXT NOT NULL, fingerprint TEXT, page INTEGER, created_at TEXT NOT NULL, edited_at TEXT,
    status TEXT NOT NULL DEFAULT 'active', report_count INTEGER DEFAULT 0, accepted_answer TEXT, last_activity TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_questions_course ON questions(course_key, university, last_activity);
CREATE TABLE IF NOT EXISTS answers (
    id TEXT PRIMARY KEY, question_id TEXT NOT NULL REFERENCES questions(id), author_id TEXT NOT NULL, pseudonym TEXT NOT NULL,
    body TEXT NOT NULL, created_at TEXT NOT NULL, edited_at TEXT, status TEXT NOT NULL DEFAULT 'active', report_count INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_answers_question ON answers(question_id, created_at);
CREATE TABLE IF NOT EXISTS answer_votes (answer_id TEXT NOT NULL, user_id TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (answer_id, user_id));
CREATE TABLE IF NOT EXISTS question_likes (question_id TEXT NOT NULL, user_id TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (question_id, user_id));
CREATE TABLE IF NOT EXISTS qa_reports (kind TEXT NOT NULL, target_id TEXT NOT NULL, reporter_id TEXT NOT NULL, reason TEXT NOT NULL,
    created_at TEXT NOT NULL, PRIMARY KEY (kind, target_id, reporter_id));
CREATE TABLE IF NOT EXISTS bookmarks (user_id TEXT NOT NULL, kind TEXT NOT NULL, target_id TEXT NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY (user_id, kind, target_id));
CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY, user_id TEXT NOT NULL, kind TEXT NOT NULL, target_kind TEXT NOT NULL, target_id TEXT NOT NULL,
    context_id TEXT, actor TEXT, text TEXT, count INTEGER DEFAULT 1, created_at TEXT NOT NULL, read_at TEXT, bundle TEXT);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_bundle ON notifications(user_id, bundle) WHERE bundle IS NOT NULL;
"""
HEX64 = re.compile(r"^[0-9a-f]{64}\Z")          # \Z statt $: kein Zeilenende am Schluss (Audit 08.11.2026, Nr. 114)
MAX_TITLE, MAX_BODY, MAX_ANSWER = 160, 4000, 4000
PAGE = 30
REPORTS_TO_HIDE = 3
NOTIFY_KEEP_DAYS = 90


@contextmanager
def cursor():
    with community.cursor() as conn:                    # legt auch diese Tabellen an (community.cursor)
        yield conn


def _can_write(user: dict, what: str) -> None:
    from . import entitlements
    if not entitlements.has(user, "can_write_community_comments"):
        raise CommunityError("plan_required", f"{what} gibt es ab StudiNow Plus.", 403)
    _require_verified(user, what.lower())


def _banned(conn, user_id: str) -> bool:
    return bool(conn.execute("SELECT 1 FROM bans WHERE author_id=?", (user_id,)).fetchone())


def _blocked(conn, user: dict) -> set[str]:
    return {r[0] for r in conn.execute("SELECT pseudonym FROM blocks WHERE user_id=?", (user["id"],))}


def _text(v, limit: int, what: str, required: bool = True) -> str:
    s = (v or "").strip() if isinstance(v, str) or v is None else str(v).strip()
    if required and not s:
        raise CommunityError("text_empty", f"{what} ist leer.")
    if len(s) > limit:
        raise CommunityError("text_too_long", f"{what}: höchstens {limit} Zeichen.")
    return s


def _key(course_key: str) -> str:
    k = (course_key or "").lower()
    if not HEX64.match(k):
        raise CommunityError("course_invalid", "Ungültiger Kurs-Schlüssel.")
    return k


def _require_member(conn, user: dict, course_key: str) -> None:
    """Fragen eines Kurses nur fuer Mitglieder der Community (Entscheidung des Inhabers vom 04.11.2026: wie auf dem
    iPad nur Leute, die den Kurs haben oder hatten; Beitritt prueft den eigenen Hochschul-Abgleich, auch fruehere
    Semester). Vorher reichte das Format des Schluessels, und seit der Community je Modul ist er eher zu erraten."""
    if user.get("role") == "admin" or community._member(conn, user, course_key):
        return
    raise CommunityError("not_a_member", "Tritt zuerst der Community dieses Kurses bei.", 403)


# ---------------------------------------------------------------- Benachrichtigungen

def notify(conn, user_id: str, kind: str, target_kind: str, target_id: str, actor: str | None, text: str | None,
           context_id: str | None = None, actor_id: str | None = None, bundle: str | None = None) -> None:
    """Benachrichtigung anlegen (nie an sich selbst). `bundle`: gleiche Art je Ziel zusammenfassen (Zaehler hoch)."""
    if not user_id or (actor_id and actor_id == user_id):
        return
    now = _now()
    if bundle:
        cur = conn.execute("SELECT id FROM notifications WHERE user_id=? AND bundle=?", (user_id, bundle)).fetchone()
        if cur:
            conn.execute("UPDATE notifications SET count=count+1, actor=?, created_at=?, read_at=NULL WHERE id=?", (actor, now, cur[0]))
            return
    conn.execute("""INSERT INTO notifications(id, user_id, kind, target_kind, target_id, context_id, actor, text, created_at, bundle)
                    VALUES (?,?,?,?,?,?,?,?,?,?)""", (uuid.uuid4().hex, user_id, kind, target_kind, target_id, context_id, actor,
                                                    (text or "")[:160] or None, now, bundle))


def notifications(user: dict, unread_only: bool = False, limit: int = 50) -> dict:
    with cursor() as conn:
        rows = conn.execute(f"""SELECT * FROM notifications WHERE user_id=? {"AND read_at IS NULL" if unread_only else ""}
                                ORDER BY created_at DESC LIMIT ?""", (user["id"], max(1, min(int(limit or 50), 200)))).fetchall()
        unread = conn.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL", (user["id"],)).fetchone()[0]
        out = []
        for r in rows:
            n = {"id": r["id"], "kind": r["kind"], "target_kind": r["target_kind"], "target_id": r["target_id"], "context_id": r["context_id"],
                 "actor": r["actor"], "text": r["text"], "count": r["count"], "created_at": r["created_at"], "read": bool(r["read_at"])}
            if r["target_kind"] == "solution":
                s = conn.execute("SELECT fingerprint, title, display_name FROM solutions WHERE id=?", (r["target_id"],)).fetchone()
                n.update(fingerprint=s["fingerprint"] if s else None, title=(s["title"] or s["display_name"]) if s else None)
            else:
                q = conn.execute("SELECT title, course_key FROM questions WHERE id=?", (r["target_id"],)).fetchone()
                n.update(title=q["title"] if q else None, course_key=q["course_key"] if q else None)
            out.append(n)
    return {"unread": unread, "notifications": out}


def mark_read(user: dict, ids: list | None = None) -> dict:
    with cursor() as conn:
        if ids:
            q = ",".join("?" * len(ids))
            conn.execute(f"UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL AND id IN ({q})", (_now(), user["id"], *map(str, ids)))
        else:
            conn.execute("UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL", (_now(), user["id"]))
        unread = conn.execute("SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL", (user["id"],)).fetchone()[0]
    return {"unread": unread}


def prune(days: int = NOTIFY_KEEP_DAYS) -> int:
    """Alte gelesene Benachrichtigungen loeschen (app/retention.py)."""
    from datetime import datetime, timedelta, timezone
    cut = (datetime.now(timezone.utc) - timedelta(days=days)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    with cursor() as conn:
        return conn.execute("DELETE FROM notifications WHERE created_at < ? AND read_at IS NOT NULL", (cut,)).rowcount


# ---------------------------------------------------------------- Fragen und Antworten

def _q_out(conn, r, me: str, blocked: set[str] | None = None) -> dict:
    answers = conn.execute("SELECT COUNT(*) FROM answers WHERE question_id=? AND status='active'", (r["id"],)).fetchone()[0]
    return {"id": r["id"], "course_key": r["course_key"], "title": r["title"], "body": r["body"] if r["status"] == "active" else "",
            "pseudonym": r["pseudonym"], "fingerprint": r["fingerprint"], "page": r["page"], "created_at": r["created_at"],
            "edited_at": r["edited_at"], "last_activity": r["last_activity"], "answers": answers, "accepted_answer": r["accepted_answer"],
            "mine": r["author_id"] == me, "status": r["status"],
            "likes": conn.execute("SELECT COUNT(*) FROM question_likes WHERE question_id=?", (r["id"],)).fetchone()[0],
            "liked_by_me": bool(conn.execute("SELECT 1 FROM question_likes WHERE question_id=? AND user_id=?", (r["id"], me)).fetchone()),
            "bookmarked": bool(conn.execute("SELECT 1 FROM bookmarks WHERE user_id=? AND kind='question' AND target_id=?", (me, r["id"])).fetchone())}


def _a_out(conn, r, me: str, question_author: str) -> dict:
    votes = conn.execute("SELECT COUNT(*) FROM answer_votes WHERE answer_id=?", (r["id"],)).fetchone()[0]
    mine_vote = bool(conn.execute("SELECT 1 FROM answer_votes WHERE answer_id=? AND user_id=?", (r["id"], me)).fetchone())
    return {"id": r["id"], "question_id": r["question_id"], "pseudonym": r["pseudonym"], "body": r["body"], "created_at": r["created_at"],
            "edited_at": r["edited_at"], "votes": votes, "voted_by_me": mine_vote, "mine": r["author_id"] == me,
            "by_asker": r["author_id"] == question_author}


def list_questions(user: dict, university: str, course_key: str, limit: int = PAGE, before: str | None = None,
                   fingerprint: str | None = None, unanswered: bool = False) -> dict:
    """Fragen eines Kurses, neueste Aktivitaet zuerst, seitenweise (`before` = `last_activity` der letzten Zeile).
    `unanswered`: nur Fragen ohne aktive Antwort (Filter "Unbeantwortet" der Community-Seite)."""
    key = _key(course_key)
    limit = max(1, min(int(limit or PAGE), 100))
    with cursor() as conn:
        _require_member(conn, user, key)
        blocked = _blocked(conn, user)
        banned = {r[0] for r in conn.execute("SELECT author_id FROM bans")}
        sql = "SELECT * FROM questions WHERE course_key=? AND university=? AND status='active'"
        args: list = [key, university]
        if fingerprint:
            sql += " AND fingerprint=?"
            args.append(fingerprint.lower())
        if unanswered:
            sql += " AND NOT EXISTS (SELECT 1 FROM answers a WHERE a.question_id=questions.id AND a.status='active')"
        if before:
            sql += " AND last_activity < ?"
            args.append(before)
        rows = conn.execute(sql + " ORDER BY last_activity DESC, id LIMIT ?", (*args, limit + 1)).fetchall()
        rows = [r for r in rows if r["pseudonym"] not in blocked and r["author_id"] not in banned]
        more = len(rows) > limit
        rows = rows[:limit]
        return {"questions": [_q_out(conn, r, user["id"]) for r in rows], "next": rows[-1]["last_activity"] if more and rows else None}


def ask(user: dict, university: str, course_key: str, title, body, fingerprint=None, page=None) -> dict:
    _can_write(user, "Fragen stellen")
    key = _key(course_key)
    title, body = _text(title, MAX_TITLE, "Der Titel"), _text(body, MAX_BODY, "Die Frage", required=False)
    fp = (fingerprint or "").lower() or None
    if fp and not HEX64.match(fp):
        raise CommunityError("fingerprint_invalid", "Ungültiger Fingerabdruck.")
    pg = int(page) if isinstance(page, int) and 0 < page < 100000 else None
    with cursor() as conn:
        _require_member(conn, user, key)
        if _banned(conn, user["id"]):
            raise CommunityError("author_banned", "Dein Konto darf in der Community nichts mehr schreiben.", 403)
        _limit("question_user", user["id"])
        qid, now = uuid.uuid4().hex, _now()
        conn.execute("""INSERT INTO questions(id, course_key, university, author_id, pseudonym, title, body, fingerprint, page, created_at, last_activity)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)""", (qid, key, university, user["id"], pseudonym(user["id"]), title, body, fp, pg, now, now))
        return _q_out(conn, conn.execute("SELECT * FROM questions WHERE id=?", (qid,)).fetchone(), user["id"])


def _visible_question(conn, user: dict, qid: str):
    r = conn.execute("SELECT * FROM questions WHERE id=?", (str(qid),)).fetchone()
    if not r or (r["status"] != "active" and r["author_id"] != user["id"] and user.get("role") != "admin"):
        raise CommunityError("not_found", "Frage nicht gefunden.", 404)
    if r["author_id"] != user["id"] and (_banned(conn, r["author_id"]) or r["pseudonym"] in _blocked(conn, user)):
        raise CommunityError("not_found", "Frage nicht gefunden.", 404)
    if r["author_id"] != user["id"] and user.get("role") != "admin" and not community._member(conn, user, r["course_key"]):
        raise CommunityError("not_found", "Frage nicht gefunden.", 404)
    return r


def get_question(user: dict, qid: str) -> dict:
    with cursor() as conn:
        q = _visible_question(conn, user, qid)
        blocked = _blocked(conn, user)
        banned = {r[0] for r in conn.execute("SELECT author_id FROM bans")}
        rows = conn.execute("SELECT * FROM answers WHERE question_id=? AND status='active' ORDER BY created_at, rowid", (q["id"],)).fetchall()
        answers = [_a_out(conn, a, user["id"], q["author_id"]) for a in rows if a["pseudonym"] not in blocked and a["author_id"] not in banned]
        # markierte Loesung zuerst, dann nach Stimmen, sonst in Reihenfolge
        answers.sort(key=lambda a: (a["id"] != q["accepted_answer"], -a["votes"]))
        return {**_q_out(conn, q, user["id"]), "answer_list": answers}


def answer(user: dict, qid: str, body) -> dict:
    _can_write(user, "Antworten")
    body = _text(body, MAX_ANSWER, "Die Antwort")
    with cursor() as conn:
        q = _visible_question(conn, user, qid)
        if q["status"] != "active":
            raise CommunityError("not_found", "Frage nicht gefunden.", 404)
        if _banned(conn, user["id"]):
            raise CommunityError("author_banned", "Dein Konto darf in der Community nichts mehr schreiben.", 403)
        _limit("answer_user", user["id"])
        aid, now = uuid.uuid4().hex, _now()
        conn.execute("INSERT INTO answers(id, question_id, author_id, pseudonym, body, created_at) VALUES (?,?,?,?,?,?)",
                     (aid, q["id"], user["id"], pseudonym(user["id"]), body, now))
        conn.execute("UPDATE questions SET last_activity=? WHERE id=?", (now, q["id"]))
        notify(conn, q["author_id"], "answer", "question", q["id"], pseudonym(user["id"]), body, aid, user["id"])
        return _a_out(conn, conn.execute("SELECT * FROM answers WHERE id=?", (aid,)).fetchone(), user["id"], q["author_id"])


def vote(user: dict, answer_id: str, on: bool = True) -> dict:
    _require_verified(user, "abzustimmen")
    with cursor() as conn:
        a = conn.execute("SELECT * FROM answers WHERE id=? AND status='active'", (str(answer_id),)).fetchone()
        if not a:
            raise CommunityError("not_found", "Antwort nicht gefunden.", 404)
        _visible_question(conn, user, a["question_id"])
        if a["author_id"] == user["id"]:
            raise CommunityError("own_answer", "Die eigene Antwort lässt sich nicht als hilfreich markieren.")
        if on:
            if not conn.execute("SELECT 1 FROM answer_votes WHERE answer_id=? AND user_id=?", (a["id"], user["id"])).fetchone():
                _limit("like_user", user["id"])
                conn.execute("INSERT OR IGNORE INTO answer_votes(answer_id, user_id, created_at) VALUES (?,?,?)", (a["id"], user["id"], _now()))
        else:
            conn.execute("DELETE FROM answer_votes WHERE answer_id=? AND user_id=?", (a["id"], user["id"]))
        n = conn.execute("SELECT COUNT(*) FROM answer_votes WHERE answer_id=?", (a["id"],)).fetchone()[0]
    return {"answer_id": a["id"], "voted": on, "votes": n}


def like_question(user: dict, qid: str, on: bool = True) -> dict:
    """Gefaellt mir fuer eine Frage (wie die Likes auf Fragen in CloudKit, `post:<id>`): nicht fuer die eigene Frage,
    bestaetigte E-Mail, Grenze `like_user`, idempotent."""
    _require_verified(user, "Fragen zu liken")
    with cursor() as conn:
        q = _visible_question(conn, user, qid)
        if q["status"] != "active":
            raise CommunityError("not_found", "Frage nicht gefunden.", 404)
        if q["author_id"] == user["id"]:
            raise CommunityError("own_post", "Die eigene Frage lässt sich nicht liken.")
        if on:
            if not conn.execute("SELECT 1 FROM question_likes WHERE question_id=? AND user_id=?", (q["id"], user["id"])).fetchone():
                _limit("like_user", user["id"])
                conn.execute("INSERT OR IGNORE INTO question_likes(question_id, user_id, created_at) VALUES (?,?,?)", (q["id"], user["id"], _now()))
        else:
            conn.execute("DELETE FROM question_likes WHERE question_id=? AND user_id=?", (q["id"], user["id"]))
        n = conn.execute("SELECT COUNT(*) FROM question_likes WHERE question_id=?", (q["id"],)).fetchone()[0]
    return {"question_id": q["id"], "liked": on, "likes": n}


def accept(user: dict, qid: str, answer_id: str | None) -> dict:
    """Wer gefragt hat, markiert eine Antwort als Loesung (None = Markierung aufheben)."""
    with cursor() as conn:
        q = _visible_question(conn, user, qid)
        if q["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur wer gefragt hat, kann eine Antwort als Lösung markieren.", 403)
        if answer_id:
            a = conn.execute("SELECT * FROM answers WHERE id=? AND question_id=? AND status='active'", (str(answer_id), q["id"])).fetchone()
            if not a:
                raise CommunityError("not_found", "Antwort nicht gefunden.", 404)
            notify(conn, a["author_id"], "accepted", "question", q["id"], pseudonym(user["id"]), q["title"], a["id"], user["id"])
        conn.execute("UPDATE questions SET accepted_answer=? WHERE id=?", (str(answer_id) if answer_id else None, q["id"]))
    return {"question_id": q["id"], "accepted_answer": answer_id}


def edit(user: dict, kind: str, target_id: str, body=None, title=None) -> dict:
    with cursor() as conn:
        t = "questions" if kind == "question" else "answers"
        r = conn.execute(f"SELECT * FROM {t} WHERE id=? AND status='active'", (str(target_id),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Nicht gefunden.", 404)
        if r["author_id"] != user["id"]:
            raise CommunityError("not_owner", "Nur der Verfasser kann das.", 403)
        if kind == "question":
            conn.execute("UPDATE questions SET title=?, body=?, edited_at=? WHERE id=?",
                         (_text(title if title is not None else r["title"], MAX_TITLE, "Der Titel"),
                          _text(body if body is not None else r["body"], MAX_BODY, "Die Frage", required=False), _now(), r["id"]))
        else:
            conn.execute("UPDATE answers SET body=?, edited_at=? WHERE id=?", (_text(body, MAX_ANSWER, "Die Antwort"), _now(), r["id"]))
    return {"ok": True}


def delete(user: dict, kind: str, target_id: str) -> dict:
    with cursor() as conn:
        t = "questions" if kind == "question" else "answers"
        r = conn.execute(f"SELECT * FROM {t} WHERE id=? AND status='active'", (str(target_id),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Nicht gefunden.", 404)
        allowed = r["author_id"] == user["id"] or user.get("role") == "admin"
        if kind == "answer" and not allowed:
            q = conn.execute("SELECT author_id FROM questions WHERE id=?", (r["question_id"],)).fetchone()
            allowed = bool(q and q["author_id"] == user["id"])          # wer gefragt hat, darf Antworten entfernen
        if not allowed:
            raise CommunityError("not_owner", "Nur der Verfasser kann das.", 403)
        conn.execute(f"UPDATE {t} SET status='deleted' WHERE id=?", (r["id"],))
        if kind == "answer":
            conn.execute("UPDATE questions SET accepted_answer=NULL WHERE accepted_answer=?", (r["id"],))
    return {"ok": True}


def report(user: dict, kind: str, target_id: str, reason: str) -> dict:
    if reason not in community.REPORT_REASONS:
        raise CommunityError("reason_invalid", "Unbekannter Meldegrund.")
    _require_verified(user, "Beiträge zu melden")
    with cursor() as conn:
        t = "questions" if kind == "question" else "answers"
        r = conn.execute(f"SELECT * FROM {t} WHERE id=? AND status='active'", (str(target_id),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Nicht gefunden.", 404)
        _visible_question(conn, user, r["id"] if kind == "question" else r["question_id"])
        if r["author_id"] == user["id"]:
            raise CommunityError("own_post", "Den eigenen Beitrag kannst du löschen statt melden.")
        if not conn.execute("SELECT 1 FROM qa_reports WHERE kind=? AND target_id=? AND reporter_id=?", (kind, r["id"], user["id"])).fetchone():
            _limit("report_user", user["id"])
        cur = conn.execute("INSERT OR IGNORE INTO qa_reports(kind, target_id, reporter_id, reason, created_at) VALUES (?,?,?,?,?)",
                           (kind, r["id"], user["id"], reason, _now()))
        if cur.rowcount:
            n = conn.execute("SELECT COUNT(*) FROM qa_reports WHERE kind=? AND target_id=?", (kind, r["id"])).fetchone()[0]
            conn.execute(f"UPDATE {t} SET report_count=?, status=CASE WHEN ? >= ? THEN 'hidden' ELSE status END WHERE id=?",
                         (n, n, REPORTS_TO_HIDE, r["id"]))
    return {"reported": True}


def moderation_posts(user: dict) -> dict:
    """Nur Admin: gemeldete oder verborgene Kommentare, Fragen und Antworten, je Meldung mit Angaben zum Meldenden."""
    community.require_admin(user)
    out = {}
    with cursor() as conn:
        specs = (("comments", "comment", "text", "comment_reports", "comment_id", "solution_id"),
                 ("questions", "question", "title", "qa_reports", "target_id", "course_key"),
                 ("answers", "answer", "body", "qa_reports", "target_id", "question_id"))
        for table, kind, text_col, rep_table, rep_col, ctx_col in specs:
            rows = conn.execute(f"SELECT * FROM {table} WHERE status='hidden' OR (status='active' AND report_count>0) "
                                "ORDER BY status='hidden' DESC, report_count DESC, created_at DESC").fetchall()
            items = []
            for r in rows:
                where = f"{rep_col}=?" + (" AND kind=?" if rep_table == "qa_reports" else "")
                args = (r["id"], kind) if rep_table == "qa_reports" else (r["id"],)
                reps = [{"reason": x["reason"], "created_at": x["created_at"], "reporter": community.reporter_info(x["reporter_id"])}
                        for x in conn.execute(f"SELECT reason, created_at, reporter_id FROM {rep_table} WHERE {where} ORDER BY created_at, rowid", args)]
                items.append({"id": r["id"], "kind": kind, "status": r["status"], "pseudonym": r["pseudonym"], "text": (r[text_col] or "")[:300],
                              "context": r[ctx_col], "created_at": r["created_at"], "report_count": r["report_count"], "reports": reps})
            out[table] = items
        from . import community_cards, community_corrections
        out["corrections"] = community_corrections.moderation_items(conn)
        out["card_stacks"] = community_cards.moderation_items(conn)          # geteilte Karteikarten-Stapel (04.11.2026)
    return out


def moderate_post(user: dict, kind: str, target_id: str, action: str) -> dict:
    """Nur Admin: verborgenen Kommentar, verborgene Frage oder Antwort wiederherstellen (Meldungen werden geloescht,
    wie bei `community.moderate` 'restore' fuer Loesungen)."""
    community.require_admin(user)
    if action != "restore":
        raise CommunityError("action_invalid", "Unbekannte Aktion.")
    t = {"comment": "comments", "question": "questions", "answer": "answers", "correction": "corrections",
         "card_stack": "card_stacks"}.get(kind)
    if not t:
        raise CommunityError("kind_invalid", "Unbekannter Beitrag.")
    if kind in ("correction", "card_stack"):
        from . import community_cards, community_corrections
        with cursor() as conn:
            r = (community_corrections if kind == "correction" else community_cards).restore(conn, target_id)
        if not r:
            raise CommunityError("not_found", "Kein verborgener Beitrag mit dieser Kennung.", 404)
        return {"action": action, "kind": kind, "id": r["id"], "status": "active"}
    with cursor() as conn:
        r = conn.execute(f"SELECT id FROM {t} WHERE id=? AND status='hidden'", (str(target_id),)).fetchone()
        if not r:
            raise CommunityError("not_found", "Kein verborgener Beitrag mit dieser Kennung.", 404)
        conn.execute(f"UPDATE {t} SET status='active', report_count=0 WHERE id=?", (r["id"],))
        if kind == "comment":
            conn.execute("DELETE FROM comment_reports WHERE comment_id=?", (r["id"],))
        else:
            conn.execute("DELETE FROM qa_reports WHERE kind=? AND target_id=?", (kind, r["id"]))
    return {"action": action, "kind": kind, "id": r["id"], "status": "active"}


# ---------------------------------------------------------------- Lesezeichen

def bookmarks(user: dict) -> dict:
    with cursor() as conn:
        rows = conn.execute("SELECT * FROM bookmarks WHERE user_id=? ORDER BY created_at DESC", (user["id"],)).fetchall()
        out = []
        for b in rows:
            if b["kind"] == "question":
                q = conn.execute("SELECT * FROM questions WHERE id=? AND status='active'", (b["target_id"],)).fetchone()
                if q and (q["author_id"] == user["id"] or user.get("role") == "admin" or community._member(conn, user, q["course_key"])):
                    out.append({"kind": "question", "id": q["id"], "title": q["title"], "course_key": q["course_key"], "created_at": b["created_at"]})
            else:
                s = conn.execute("SELECT * FROM solutions WHERE id=? AND status='active'", (b["target_id"],)).fetchone()
                if s:
                    out.append({"kind": "solution", "id": s["id"], "title": s["title"] or s["display_name"] or "Lösung", "fingerprint": s["fingerprint"],
                                "created_at": b["created_at"]})
    return {"bookmarks": out}


def bookmark(user: dict, kind: str, target_id: str, on: bool = True) -> dict:
    if kind not in ("solution", "question"):
        raise CommunityError("kind_invalid", "Lesezeichen gibt es für Lösungen und Fragen.")
    with cursor() as conn:
        if on:
            t = "questions" if kind == "question" else "solutions"
            if not conn.execute(f"SELECT 1 FROM {t} WHERE id=?", (str(target_id).lower() if kind == "solution" else str(target_id),)).fetchone():
                raise CommunityError("not_found", "Nicht gefunden.", 404)
            if kind == "question":
                _visible_question(conn, user, str(target_id))
            conn.execute("INSERT OR IGNORE INTO bookmarks(user_id, kind, target_id, created_at) VALUES (?,?,?,?)",
                         (user["id"], kind, str(target_id).lower() if kind == "solution" else str(target_id), _now()))
        else:
            conn.execute("DELETE FROM bookmarks WHERE user_id=? AND kind=? AND target_id=?", (user["id"], kind, str(target_id)))
    return {"bookmarked": on}


def forget(user_id: str) -> None:
    """Konto geloescht: Fragen, Antworten, Stimmen, Meldungen, Lesezeichen, Benachrichtigungen des Kontos entfernen."""
    with cursor() as conn:
        qids = [r[0] for r in conn.execute("SELECT id FROM questions WHERE author_id=?", (user_id,))]
        for q in qids:
            conn.execute("DELETE FROM answer_votes WHERE answer_id IN (SELECT id FROM answers WHERE question_id=?)", (q,))
            conn.execute("DELETE FROM qa_reports WHERE kind='answer' AND target_id IN (SELECT id FROM answers WHERE question_id=?)", (q,))
            conn.execute("DELETE FROM answers WHERE question_id=?", (q,))
            conn.execute("DELETE FROM question_likes WHERE question_id=?", (q,))
            conn.execute("DELETE FROM qa_reports WHERE kind='question' AND target_id=?", (q,))
            conn.execute("DELETE FROM bookmarks WHERE kind='question' AND target_id=?", (q,))
            conn.execute("DELETE FROM questions WHERE id=?", (q,))
        conn.execute("DELETE FROM answer_votes WHERE user_id=? OR answer_id IN (SELECT id FROM answers WHERE author_id=?)", (user_id, user_id))
        conn.execute("DELETE FROM qa_reports WHERE reporter_id=? OR (kind='answer' AND target_id IN (SELECT id FROM answers WHERE author_id=?))", (user_id, user_id))
        conn.execute("UPDATE questions SET accepted_answer=NULL WHERE accepted_answer IN (SELECT id FROM answers WHERE author_id=?)", (user_id,))
        conn.execute("DELETE FROM answers WHERE author_id=?", (user_id,))
        conn.execute("DELETE FROM bookmarks WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM question_likes WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM notifications WHERE user_id=?", (user_id,))
