"""Weitermachen und "Zuletzt benutzt" fuer PC und Web (docs/WEITERMACHEN-2026-11-04.md, Gegenstueck zu
RecentEndpoints.swift, RecentItems.swift und TutorConversations.swift der iPad-App).

- GET    /api/recent?limit=15                 Dokumente (files.last_opened, Seite, Anzahl), KI-Gespraeche und Wochentests
                                              (begonnen oder abgegeben) in einer Liste nach Zeit, neuestes zuerst
- GET    /api/tutor-conversations             die gespeicherten Gespraeche der KI-Hilfe (ohne Beitraege), neuestes zuerst
- GET    /api/tutor-conversations/{key}       ein Gespraech mit allen Beitraegen (404, wenn es keines gibt)
- PUT    /api/tutor-conversations/{key}       {file_name, messages} speichern; leere Liste loescht
- DELETE /api/tutor-conversations/{key}       "Neu" in der KI-Hilfe

Schluessel ist die Datei-ID oder "exam:<Test-ID>:<Aufgabe>" (Frag die KI zu Aufgabe n), wie auf dem iPad. Es bleiben
die letzten 15 Gespraeche (`KEEP`), das aelteste faellt heraus. Die Daten liegen in der Datenbank des PCs bzw. im
Dienst in der Datenbank des Kontos (config.set_user_context), verlassen also wie auf dem iPad nie den eigenen
Datenbestand. Die Tabelle entsteht erst bei Bedarf (wie due_hits auf dem iPad).
"""
from __future__ import annotations

import json

from fastapi import APIRouter, Body, HTTPException

from . import db

router = APIRouter()

DEFAULT_LIMIT = 15
MAX_LIMIT = 50
KEEP = 15                       # wie TutorConversations.keep
MAX_MESSAGES = 80               # je Gespraech; aeltere Beitraege fallen vorn heraus
MAX_BYTES = 400_000             # je Gespraech (JSON); groessere werden von vorn gekuerzt
EXAM_PREFIX = "exam:"

SCHEMA = """
CREATE TABLE IF NOT EXISTS tutor_conversations (
    key TEXT PRIMARY KEY,          -- Datei-ID oder exam:<Test-ID>:<Aufgabe>
    file_name TEXT,
    messages TEXT NOT NULL,        -- JSON-Liste der Beitraege (fromUser, text, cards, sources, mode, explain, quote, saved)
    last_question TEXT,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_tutor_conversations_updated ON tutor_conversations(updated_at);
"""


def ensure_schema(conn) -> None:
    conn.executescript(SCHEMA)


def parse_exam_key(key: str):
    """(Test-ID, Aufgabe) aus "exam:12:3"; None fuer Gespraeche zu Dokumenten (TutorConversations.parseExamKey)."""
    if not isinstance(key, str) or not key.startswith(EXAM_PREFIX):
        return None
    rest = key[len(EXAM_PREFIX):]
    tid, sep, nr = rest.partition(":")
    if not sep or not tid.isdigit():
        return None
    return int(tid), nr


def _clean_key(key: str) -> str:
    k = str(key or "").strip()
    if not k or len(k) > 200:
        raise HTTPException(400, {"detail": "Ungültiger Schlüssel.", "code": "conversation_key_invalid"})
    return k


def clean_messages(messages) -> list[dict]:
    """Nur Beitraege mit Text oder Karten, hoechstens MAX_MESSAGES und MAX_BYTES (aelteste fallen weg)."""
    if not isinstance(messages, list):
        return []
    out = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        text = str(m.get("text") or "")
        cards = m.get("cards") if isinstance(m.get("cards"), list) else []
        if not text.strip() and not cards:
            continue
        item = {"fromUser": bool(m.get("fromUser")), "text": text[:20000]}
        if cards:
            item["cards"] = [c for c in cards if isinstance(c, dict)][:50]
        if isinstance(m.get("sources"), list) and m["sources"]:
            item["sources"] = [s for s in m["sources"] if isinstance(s, dict)][:20]
        for k in ("mode", "quote"):
            if isinstance(m.get(k), str) and m[k]:
                item[k] = m[k][:2000]
        if m.get("saved"):
            item["saved"] = True
        if isinstance(m.get("explain"), dict):
            item["explain"] = m["explain"]
        out.append(item)
    out = out[-MAX_MESSAGES:]
    while len(out) > 1 and len(json.dumps(out, ensure_ascii=False)) > MAX_BYTES:
        out = out[1:]
    return out


def last_question(messages: list[dict]) -> str | None:
    for m in reversed(messages):
        if m.get("fromUser") and str(m.get("text") or "").strip():
            return str(m["text"])
    return None


def save_conversation(conn, key: str, file_name: str | None, messages, now: str | None = None) -> dict | None:
    """Gespraech speichern (leer = loeschen) und nur die letzten KEEP behalten."""
    ensure_schema(conn)
    msgs = clean_messages(messages)
    if not msgs:
        conn.execute("DELETE FROM tutor_conversations WHERE key=?", (key,))
        return None
    at = now or db.now_iso()
    conn.execute("""INSERT INTO tutor_conversations(key, file_name, messages, last_question, updated_at) VALUES (?,?,?,?,?)
                    ON CONFLICT(key) DO UPDATE SET file_name=COALESCE(excluded.file_name, tutor_conversations.file_name),
                    messages=excluded.messages, last_question=excluded.last_question, updated_at=excluded.updated_at""",
                 (key, (file_name or None) and str(file_name)[:300], json.dumps(msgs, ensure_ascii=False), last_question(msgs), at))
    conn.execute("""DELETE FROM tutor_conversations WHERE key NOT IN
                    (SELECT key FROM tutor_conversations ORDER BY updated_at DESC, key DESC LIMIT ?)""", (KEEP,))
    return {"key": key, "file_name": file_name, "messages": msgs, "updated_at": at}


def get_conversation(conn, key: str) -> dict | None:
    ensure_schema(conn)
    r = conn.execute("SELECT key, file_name, messages, updated_at FROM tutor_conversations WHERE key=?", (key,)).fetchone()
    if not r:
        return None
    try:
        msgs = json.loads(r[2])
    except ValueError:
        msgs = []
    return {"key": r[0], "file_name": r[1], "messages": msgs, "updated_at": r[3]}


def list_conversations(conn) -> list[dict]:
    ensure_schema(conn)
    return db.rows(conn, """SELECT key, file_name, last_question, updated_at FROM tutor_conversations
                            ORDER BY updated_at DESC, key DESC""")


def _backend_items(conn, limit: int) -> list[dict]:
    """Dokumente und Wochentests wie RecentEndpoints.swift (ohne geloeschte Dateien)."""
    docs = db.rows(conn, """
        SELECT f.id, COALESCE(a.title, f.title, f.name) AS title, c.subject AS sub, f.last_opened AS at,
               f.last_page AS page, COALESCE(f.opened_count, 0) AS opened_count
        FROM files f LEFT JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
        WHERE f.last_opened IS NOT NULL AND f.last_opened != '' AND f.deleted_at IS NULL
        ORDER BY f.last_opened DESC LIMIT ?""", (limit,))
    tests = db.rows(conn, """
        SELECT id, COALESCE(title, subject) AS title, subject AS sub, COALESCE(submitted_at, started_at) AS at,
               score, max_score, submitted_at
        FROM tests WHERE COALESCE(submitted_at, started_at) IS NOT NULL
        ORDER BY COALESCE(submitted_at, started_at) DESC LIMIT ?""", (limit,))
    items = [{**d, "kind": "document"} for d in docs]
    for t in tests:
        t = dict(t)
        t["done"] = t.pop("submitted_at") is not None
        t["id"] = str(t["id"])
        items.append({**t, "kind": "test"})
    return items


def merge(backend: list[dict], conversations: list[dict], limit: int) -> list[dict]:
    """Alles nach Zeit absteigend, je Art und Kennung nur der neueste Eintrag (RecentItem.merge)."""
    out = []
    for it in backend:
        if it.get("at") and str(it.get("id") or ""):
            out.append(it)
    for c in conversations:
        exam = parse_exam_key(c["key"])
        if exam:
            out.append({"kind": "conversation", "id": c["key"], "title": c.get("file_name") or "KI-Gespräch", "sub": "Wochentest",
                        "at": c["updated_at"], "page": None, "test_id": exam[0], "nr": exam[1]})
            continue
        q = " ".join(str(c.get("last_question") or "")[:80].split())
        out.append({"kind": "conversation", "id": c["key"], "title": q or "KI-Gespräch", "sub": c.get("file_name"),
                    "at": c["updated_at"], "page": None})
    out.sort(key=lambda x: (str(x["at"]), x["kind"] + ":" + str(x["id"])), reverse=True)
    seen, res = set(), []
    for it in out:
        k = (it["kind"], str(it["id"]))
        if k in seen:
            continue
        seen.add(k)
        res.append(it)
    return res[:max(0, limit)]


def recent(conn, limit: int = DEFAULT_LIMIT) -> list[dict]:
    limit = min(MAX_LIMIT, max(1, int(limit)))
    ensure_schema(conn)
    return merge(_backend_items(conn, limit), list_conversations(conn), limit)


# ---------------------------------------------------------------- Endpunkte

@router.get("/api/recent")
def api_recent(limit: int = DEFAULT_LIMIT):
    with db.cursor() as conn:
        return {"items": recent(conn, limit)}


@router.get("/api/tutor-conversations")
def api_conversations():
    with db.cursor() as conn:
        return {"items": list_conversations(conn), "keep": KEEP}


@router.get("/api/tutor-conversations/{key:path}")
def api_conversation(key: str):
    k = _clean_key(key)
    with db.cursor() as conn:
        c = get_conversation(conn, k)
    if not c:
        raise HTTPException(404, {"detail": "Kein Gespräch gespeichert.", "code": "conversation_missing"})
    return c


@router.put("/api/tutor-conversations/{key:path}")
def api_save_conversation(key: str, body: dict = Body(...)):
    k = _clean_key(key)
    with db.cursor() as conn:
        c = save_conversation(conn, k, body.get("file_name"), body.get("messages"))
    return {"saved": c is not None, "updated_at": c["updated_at"] if c else None, "messages": len(c["messages"]) if c else 0}


@router.delete("/api/tutor-conversations/{key:path}")
def api_delete_conversation(key: str):
    k = _clean_key(key)
    with db.cursor() as conn:
        ensure_schema(conn)
        conn.execute("DELETE FROM tutor_conversations WHERE key=?", (k,))
    return {"deleted": True}
