"""Auf Stud.IP-Nachrichten antworten - Windows-App/Einzelplatz (05.11.2026), wie die iPad-App
(apps/apple/.../StudIPMessageReply.swift, docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md). Echter Test am iPad (05.11.2026):
`POST jsonapi.php/v1/messages` mit dem Sitzungs-Cookie nimmt die LUH ohne weiteres Token an.

Gesendet wird nur auf Knopfdruck ("Senden"), nie im Abgleich, nie still wiederholt; ueber Stud.IP unter dem eigenen
Namen. Namen werden nie gespeichert (Regel 02.11.2026): der Abgleich merkt sich je Nachricht nur die Zahl der Empfaenger
(Tabelle `studip_message_meta`), die Namen stehen nur in der Antwort von GET .../reply.

Routen (nur lokal; im Dienst 404):
  GET    /api/studip/messages/{id}/reply?all=0|1   Kontext live aus dem Posteingang: Absender, weitere Empfaenger
                                                   (Namen nur mit all=1), Betreff "RE: ...", Zitat, Entwurf
  POST   /api/studip/messages/{id}/reply           {mode: sender|all, subject, text, quote} -> senden, Verlauf
  PUT    /api/studip/messages/{id}/draft           {mode, subject, text, quote} -> Entwurf (ohne Text: geloescht)
  DELETE /api/studip/messages/{id}/draft           Entwurf verwerfen
Die Liste (GET /api/studip/messages) nennt je Nachricht `recipients` (Zahl oder null), `replyable`, `replies`
(eigene Antworten, neueste zuerst) und `reply_url` (Ausweg "In Stud.IP antworten").

Entwurf und Verlauf liegen in den Einstellungen dieses PCs (`studip_reply_drafts`, hoechstens 50; `studip_replies`,
hoechstens 300; sync_client.LOCAL_SETTINGS): eigener Text, Betreff, Modus, mit Zitat ja/nein, Zahl der Empfaenger,
Kennung der neuen Nachricht - keine Namen. Die Empfaenger-Kennungen nimmt der Server beim Senden selbst wieder aus dem
Posteingang (die Oberflaeche kann so an niemand anderen schreiben).
"""
from __future__ import annotations

import json
import re
import urllib.error
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, HTTPException, Query

from . import announcements, db, studip_live

router = APIRouter(prefix="/api/studip/messages", tags=["studip-reply"])

MAX_REPLY_ALL = 20
INBOX_PAGES = 3
LOCAL_PREFIX = "sp-msg-"
SYSTEM_SENDER = "____%system%____"
DRAFTS_KEY = "studip_reply_drafts"
LOG_KEY = "studip_replies"
DRAFT_LIMIT = 50
LOG_LIMIT = 300
MAX_TEXT = 20_000
MAX_SUBJECT = 250
BERLIN = ZoneInfo("Europe/Berlin")
NOTICE = "Wird über Stud.IP unter deinem Namen gesendet. Die Empfänger sehen deinen Namen."
UNKNOWN_USER = "Stud.IP-Nutzer/in"

META_TABLE = """CREATE TABLE IF NOT EXISTS studip_message_meta (
    id TEXT PRIMARY KEY,               -- wie studip_messages.id
    recipients INTEGER                 -- Zahl der Empfaenger (mit einem selbst), keine Kennungen, keine Namen
)"""

ERRORS = {
    "system_message": "Diese Nachricht kam von Stud.IP selbst. Auf Systemnachrichten kann man nicht antworten.",
    "not_found": "Die Nachricht ist in Stud.IP nicht mehr im Posteingang (gelöscht oder sehr alt). Antworte bitte direkt in Stud.IP.",
    "security_token": "Stud.IP hat das Senden aus der App abgelehnt (Sicherheitsprüfung). Antworte bitte direkt in Stud.IP.",
    "forbidden": "Stud.IP hat das Senden abgelehnt (keine Berechtigung). Antworte bitte direkt in Stud.IP.",
    "rejected": "Stud.IP hat die Nachricht nicht angenommen (HTTP {status}). Antworte bitte direkt in Stud.IP.",
    "http": "Stud.IP antwortet mit HTTP {status}. Die Nachricht wurde vermutlich nicht gesendet; prüfe in Stud.IP unter „Gesendet“, bevor du es noch einmal versuchst.",
    "offline": "Keine Verbindung zu Stud.IP. Die Nachricht wurde nicht gesendet.",
    "not_connected": "Stud.IP ist nicht verbunden. Melde dich unter Einstellungen → Zugang bei der Hochschule an.",
    "login": "Bitte bei Stud.IP anmelden (Einstellungen → Zugang). Dein Entwurf bleibt erhalten.",
}


class ReplyError(Exception):
    def __init__(self, code: str, status: int | None = None):
        super().__init__(code)
        self.code, self.http_status = code, status

    @property
    def message(self) -> str:
        return ERRORS[self.code].format(status=self.http_status)

    @property
    def offers_web_fallback(self) -> bool:
        return self.code not in ("offline", "not_connected", "login")


# ---------------------------------------------------------------------------- Regeln ohne Netz (wie der Swift-Kern)

def raw_id(local_id: str) -> str:
    return local_id[len(LOCAL_PREFIX):] if local_id.startswith(LOCAL_PREFIX) else local_id


def local_id(raw: str) -> str:
    return LOCAL_PREFIX + raw


def is_replyable(sender_label) -> bool:
    """Systemnachricht nach der gespeicherten Absender-Anzeige ("Stud.IP" bzw. leer)"""
    s = str(sender_label or "").strip()
    return bool(s) and s != "Stud.IP"


def offers_reply_all(recipients) -> bool:
    """"Allen antworten" im Leser: der Abgleich kennt die Zahl der Empfaenger (mit einem selbst), 2 bis MAX_REPLY_ALL + 1"""
    if not isinstance(recipients, int) or isinstance(recipients, bool):
        return False
    return recipients >= 2 and recipients - 1 <= MAX_REPLY_ALL


def reply_subject(subject: str) -> str:
    """"RE: " davor wie Stud.IP im Browser, aber nicht doppelt"""
    s = (subject or "").strip()
    if not s or s == "(ohne Betreff)":
        return "RE: "
    lower = s.lower()
    if any(lower.startswith(p) for p in ("re:", "aw:", "re :", "antw:")):
        return s
    return "RE: " + s


def instant(s) -> datetime | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo is not None else None


def quote(text: str, sender_name: str, sent_at) -> str:
    """Zitat: "Am 02.11.2026 um 08:15 schrieb Prof. Test:" und jede Zeile mit "> " (leere Zeilen ">")"""
    head = f"{sender_name or 'Absender'} schrieb:"
    d = instant(sent_at)
    if d is not None:
        head = f"Am {d.astimezone(BERLIN).strftime('%d.%m.%Y um %H:%M')} " + head
    lines = (text or "").replace("\r\n", "\n").split("\n")
    return "\n".join([head] + [">" if not ln else f"> {ln}" for ln in lines])


def body(text: str, quoted: str | None) -> str:
    own = (text or "").strip()
    return own + "\n\n" + quoted if quoted else own


def payload(subject: str, text: str, recipient_ids: list[str]) -> dict:
    seen: set[str] = set()
    rec = [r for r in recipient_ids if r and not (r in seen or seen.add(r))]
    return {"data": {"type": "messages",
                     "attributes": {"subject": subject, "message": text, "priority": "normal"},
                     "relationships": {"recipients": {"data": [{"type": "users", "id": r} for r in rec]}}}}


def send_error(status: int, data: bytes) -> ReplyError | None:
    if 200 <= status < 300:
        return None
    text = data[:4000].decode("utf-8", "replace").lower()
    if status == 403:
        if any(k in text for k in ("csrf", "security token", "security_token", "sicherheits")):
            return ReplyError("security_token", 403)
        return ReplyError("forbidden", 403)
    if status in (400, 422):
        return ReplyError("rejected", status)
    return ReplyError("http", status)


def sent_id(location: str | None, data: bytes) -> str | None:
    try:
        j = json.loads(data.decode("utf-8")) if data else None
    except (ValueError, UnicodeDecodeError):
        j = None
    if isinstance(j, dict) and isinstance(j.get("data"), dict) and j["data"].get("id"):
        return str(j["data"]["id"])
    if location and "messages/" in location:
        rest = re.split(r"[/?#]", location.split("messages/", 1)[1])[0]
        if rest:
            return rest
    return None


def display_name(attrs) -> str | None:
    a = attrs if isinstance(attrs, dict) else {}
    f = str(a.get("formatted-name") or "").strip()
    if f:
        return f
    parts = [str(a.get(k) or "").strip() for k in ("given-name", "family-name")]
    parts = [p for p in parts if p]
    if parts:
        return " ".join(parts)
    u = str(a.get("username") or "")
    return u or None


def _rel_id(m: dict, name: str):
    """Kennung einer Beziehung: (True, id|None) wenn die Beziehung da ist, sonst (False, None)"""
    rel = m.get("relationships") if isinstance(m.get("relationships"), dict) else {}
    if name not in rel:
        return False, None
    d = rel[name].get("data") if isinstance(rel[name], dict) else None
    return True, (str(d["id"]) if isinstance(d, dict) and d.get("id") else None)


def context(message_id: str, page: dict, me: str) -> dict | None:
    """Antwort-Kontext aus einer Seite des Posteingangs; None, wenn die Nachricht nicht auf der Seite steht.
    ReplyError("system_message") fuer Systemnachrichten und Nachrichten ohne Absender."""
    data = page.get("data") if isinstance(page.get("data"), list) else []
    m = next((x for x in data if isinstance(x, dict) and str(x.get("id")) == message_id), None)
    if m is None:
        return None
    has, sender = _rel_id(m, "sender")
    if not has or not sender or sender == SYSTEM_SENDER:
        raise ReplyError("system_message")
    names = {}
    for u in page.get("included") or []:
        if isinstance(u, dict) and u.get("type") == "users" and u.get("id"):
            n = display_name(u.get("attributes"))
            if n:
                names[str(u["id"])] = n
    rel = m.get("relationships") if isinstance(m.get("relationships"), dict) else {}
    rdata = rel.get("recipients", {}).get("data") if isinstance(rel.get("recipients"), dict) else None
    seen = {me, sender}
    others = []
    for r in rdata if isinstance(rdata, list) else []:
        rid = str(r.get("id")) if isinstance(r, dict) and r.get("id") else None
        if rid and rid not in seen:
            seen.add(rid)
            others.append(rid)
    attrs = m.get("attributes") if isinstance(m.get("attributes"), dict) else {}
    subject = announcements.html_to_text(str(attrs.get("subject") or ""))
    return {"message_id": message_id, "subject": subject, "sender": {"id": sender, "name": names.get(sender, "Absender")},
            "other_ids": others, "recipients_known": isinstance(rdata, list)}


def allows_reply_all(ctx: dict) -> bool:
    return 0 < len(ctx["other_ids"]) <= MAX_REPLY_ALL


def is_circular(ctx: dict) -> bool:
    return len(ctx["other_ids"]) > MAX_REPLY_ALL


def reply_web_url(base: str, message_id: str) -> str:
    from urllib.parse import quote as q
    return f"{base.rstrip('/')}/dispatch.php/messages/write?answer_to={q(raw_id(message_id), safe='')}"


def outbox_web_url(base: str) -> str:
    return f"{base.rstrip('/')}/dispatch.php/messages/sent"


# ---------------------------------------------------------------------------- Empfaengerzahl beim Abgleich

def parse_message_meta(data) -> dict[str, int]:
    """Zahl der Empfaenger je Nachricht, wenn die Liste die Beziehung `recipients` liefert (sonst fehlt der Eintrag)"""
    out = {}
    for m in data if isinstance(data, list) else []:
        if not isinstance(m, dict) or not m.get("id"):
            continue
        rel = m.get("relationships") if isinstance(m.get("relationships"), dict) else {}
        r = rel.get("recipients", {}).get("data") if isinstance(rel.get("recipients"), dict) else None
        if isinstance(r, list):
            out[local_id(str(m["id"]))] = len({str(x.get("id")) for x in r if isinstance(x, dict) and x.get("id")})
    return out


def store_message_meta(conn, meta: dict[str, int]) -> None:
    conn.execute(META_TABLE)
    conn.execute("DELETE FROM studip_message_meta")
    for k in sorted(meta):
        conn.execute("INSERT OR REPLACE INTO studip_message_meta(id, recipients) VALUES (?, ?)", (k, int(meta[k])))


def message_meta(conn) -> dict[str, int]:
    if not conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_message_meta'").fetchone():
        return {}
    return {r[0]: r[1] for r in conn.execute("SELECT id, recipients FROM studip_message_meta") if r[1] is not None}


# ---------------------------------------------------------------------------- Entwurf und Verlauf (nur dieser PC)

def _load(conn, key: str) -> list[dict]:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    try:
        v = json.loads(r[0]) if r and r[0] else []
    except ValueError:
        v = []
    return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []


def _save(conn, key: str, items: list[dict]) -> None:
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (key, json.dumps(items, ensure_ascii=False)))


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def clean_mode(v) -> str:
    return "all" if v == "all" else "sender"


def drafts(conn) -> list[dict]:
    return _load(conn, DRAFTS_KEY)


def draft_for(conn, message_id: str) -> dict | None:
    return next((d for d in drafts(conn) if d.get("message_id") == message_id), None)


def put_draft(conn, message_id: str, b: dict, now: str | None = None) -> dict | None:
    """Entwurf setzen (ohne eigenen Text: entfernen), neueste zuerst, hoechstens DRAFT_LIMIT"""
    items = [d for d in drafts(conn) if d.get("message_id") != message_id]
    text = str(b.get("text") or "")[:MAX_TEXT]
    d = None
    if text.strip():
        d = {"message_id": message_id, "mode": clean_mode(b.get("mode")), "subject": str(b.get("subject") or "")[:MAX_SUBJECT],
             "text": text, "quote": bool(b.get("quote")), "saved_at": now or now_iso()}
        items.insert(0, d)
    _save(conn, DRAFTS_KEY, items[:DRAFT_LIMIT])
    return d


def remove_draft(conn, message_id: str) -> None:
    _save(conn, DRAFTS_KEY, [d for d in drafts(conn) if d.get("message_id") != message_id])


def replies(conn) -> list[dict]:
    return _load(conn, LOG_KEY)


def add_reply(conn, record: dict) -> None:
    items = replies(conn)
    items.insert(0, record)
    _save(conn, LOG_KEY, items[:LOG_LIMIT])


def replied_line(at: str) -> str:
    """"Beantwortet am 05.11.2026, 14:30" (Ortszeit Berlin)"""
    d = instant(at)
    return f"Beantwortet am {d.astimezone(BERLIN).strftime('%d.%m.%Y, %H:%M')}" if d else "Beantwortet"


def annotate(conn, messages: list[dict]) -> list[dict]:
    """Liste ergaenzen: recipients, replyable, replies (eigene Antworten), reply_url"""
    from . import config
    meta = message_meta(conn)
    log = replies(conn)
    base = config.STUDIP_BASE
    for m in messages:
        mid = m.get("id") or ""
        m["recipients"] = meta.get(mid)
        m["replyable"] = is_replyable(m.get("sender"))
        m["replies"] = [{**r, "line": replied_line(r.get("at") or "")} for r in log if r.get("message_id") == mid]
        m["reply_url"] = reply_web_url(base, mid) if mid.startswith(LOCAL_PREFIX) else None
        if mid.startswith("lw-msg-"):                     # Learnweb (Uni Hildesheim): Antwort in der Unterhaltung
            m["reply_url"] = m.get("url")
            m["source"] = "learnweb"
        elif mid.startswith("moodle-"):                   # Moodle (HsH, app/moodle.py): Antwort in der Unterhaltung
            m["reply_url"] = m.get("url")
            m["source"] = "moodle"
            m["replyable"] = True
    return messages


# ---------------------------------------------------------------------------- Learnweb (Uni Hildesheim)

def _learnweb_session():
    """Sitzung des Learnwebs (gemerkte Cookies wie filestream); ohne: nicht verbunden"""
    from . import filestream, hildesheim, learnweb_messages as lm
    base = hildesheim.learnweb_base()
    return lm.LiveSession(base, filestream.cookie_header("LEARNWEB_COOKIES", base))


def _learnweb_fail(e: Exception, m: dict):
    from . import learnweb_messages as lm
    web = m.get("url")
    if isinstance(e, lm.MessageError):
        status = 409 if e.code in ("login", "self", "not_allowed") else 404 if e.code == "not_found" else 502
        code = "learnweb_login" if e.code == "login" else f"reply_{e.code}"
        raise HTTPException(status, {"detail": e.message, "code": code, "web_url": web})
    if isinstance(e, (urllib.error.URLError, OSError, TimeoutError)):
        raise HTTPException(503, {"detail": lm.ERRORS["offline"], "code": "reply_offline", "web_url": web})
    raise e


def learnweb_context(message_id: str, session=None) -> dict:
    from . import learnweb_messages as lm
    with db.cursor() as conn:
        m = _stored(conn, message_id)
        draft = draft_for(conn, message_id)
    try:
        s = session or _learnweb_session()
        ctx = lm.live_context(s, lm.conversation_of(message_id))
    except Exception as e:  # noqa: BLE001
        _learnweb_fail(e, m)
    if not ctx["replyable"]:
        _learnweb_fail(lm.MessageError(ctx.get("reason") or "not_allowed"), m)
    first = ctx["recipients"][0]
    return {"message_id": message_id, "source": "learnweb", "subject": m.get("subject") or "", "reply_subject": "",
            "no_subject": True, "group": ctx["group"], "member_count": ctx["member_count"],
            "sender": {"id": str(first["id"]), "name": ctx["name"] or first["name"]},
            "others": [{"id": str(r["id"]), "name": r["name"]} for r in ctx["recipients"][1:]] if ctx["group"] else [],
            "other_count": max(0, len(ctx["recipients"]) - 1), "recipients_known": True, "allows_reply_all": False,
            "is_circular": False, "quote": quote(m.get("text") or "", ctx["name"] or first["name"], m.get("sent_at")),
            "draft": draft, "notice": lm.NOTICE, "web_url": m.get("url"), "outbox_url": (m.get("url") or "").split("?")[0] or None}


def learnweb_send(message_id: str, b: dict, session=None) -> dict:
    from . import learnweb_messages as lm
    text = str(b.get("text") or "")
    if not text.strip():
        raise HTTPException(400, {"detail": "Bitte einen Text schreiben.", "code": "reply_empty"})
    if len(text) > lm.MAX_TEXT:
        raise HTTPException(400, {"detail": "Der Text ist zu lang.", "code": "reply_too_long"})
    with db.cursor() as conn:
        m = _stored(conn, message_id)
    conv = lm.conversation_of(message_id)
    try:
        s = session or _learnweb_session()
        ctx = lm.live_context(s, conv)                     # Empfaenger nur aus dem Learnweb, nie vom Browser
        if not ctx["replyable"]:
            raise lm.MessageError(ctx.get("reason") or "not_allowed")
        name = ctx["name"] or (ctx["recipients"][0]["name"] if ctx["recipients"] else "")
        q = quote(m.get("text") or "", name, m.get("sent_at")) if b.get("quote") else None
        new_id = lm.live_send(s, conv, body(text, q))
    except Exception as e:  # noqa: BLE001
        _learnweb_fail(e, m)
    at = now_iso()
    record = {"message_id": message_id, "at": at, "subject": "", "text": text.strip(), "quoted": bool(q), "mode": "sender",
              "recipients": len(ctx["recipients"]), "sent_id": str(new_id) if new_id is not None else None}
    with db.cursor() as conn:
        add_reply(conn, record)
        remove_draft(conn, message_id)
    return {"sent": True, "record": {**record, "line": replied_line(at)}, "outbox_url": m.get("url")}


# ---------------------------------------------------------------------------- Moodle (Hochschule Hannover)

def _moodle_fail(e: Exception, m: dict):
    from . import moodle
    web = m.get("url")
    if isinstance(e, moodle.MoodleError):
        if e.code == "login":
            raise HTTPException(409, {"detail": e.message, "code": "moodle_login", "web_url": web})
        if e.code == "offline":
            raise HTTPException(503, {"detail": "Keine Verbindung zu Moodle. Dein Text bleibt als Entwurf.", "code": "reply_offline", "web_url": web})
        raise HTTPException(502, {"detail": e.message, "code": f"reply_{e.code}", "web_url": web})
    raise e


def moodle_context(message_id: str, web=None) -> dict:
    """Antwortfenster fuer eine Moodle-Nachricht: Namen live aus der Unterhaltung (nie gespeichert)"""
    from . import moodle
    with db.cursor() as conn:
        m = _stored(conn, message_id)
        draft = draft_for(conn, message_id)
    try:
        w = web or moodle.live()
        names = moodle.member_names(w, moodle.conversation_id(message_id))
    except Exception as e:  # noqa: BLE001
        _moodle_fail(e, m)
    group = m.get("sender") not in (moodle.SENDER,)
    first = names[0] if names else "Moodle"
    return {"message_id": message_id, "source": "moodle", "subject": m.get("subject") or "", "reply_subject": "",
            "no_subject": True, "group": group, "member_count": len(names) + 1,
            "sender": {"id": "", "name": m.get("sender") if group else first},
            "others": [{"id": "", "name": n} for n in names[1:]] if group else [],
            "other_count": max(0, len(names) - 1), "recipients_known": True, "allows_reply_all": False,
            "is_circular": False, "quote": quote(m.get("text") or "", first, m.get("sent_at")),
            "draft": draft, "notice": moodle.NOTICE, "web_url": m.get("url"), "outbox_url": m.get("url")}


def moodle_send(message_id: str, b: dict, web=None) -> dict:
    """Antwort in die Unterhaltung, genau ein Versuch, nur auf Knopfdruck"""
    from . import moodle
    text = str(b.get("text") or "")
    if not text.strip():
        raise HTTPException(400, {"detail": "Bitte einen Text schreiben.", "code": "reply_empty"})
    if len(text) > moodle.MAX_TEXT:
        raise HTTPException(400, {"detail": "Der Text ist zu lang.", "code": "reply_too_long"})
    with db.cursor() as conn:
        m = _stored(conn, message_id)
    try:
        w = web or moodle.live()
        q = None
        if b.get("quote"):
            names = moodle.member_names(w, moodle.conversation_id(message_id))
            q = quote(m.get("text") or "", names[0] if names else "Moodle", m.get("sent_at"))
        new_id = moodle.reply(w, moodle.conversation_id(message_id), body(text, q))
    except Exception as e:  # noqa: BLE001
        _moodle_fail(e, m)
    at = now_iso()
    record = {"message_id": message_id, "at": at, "subject": "", "text": text.strip(), "quoted": bool(q), "mode": "sender",
              "recipients": None, "sent_id": str(new_id) if new_id is not None else None}
    with db.cursor() as conn:
        add_reply(conn, record)
        remove_draft(conn, message_id)
    return {"sent": True, "record": {**record, "line": replied_line(at)}, "outbox_url": m.get("url")}


# ---------------------------------------------------------------------------- Live (Stud.IP)

def fetch_context(message_id: str) -> tuple[dict, str]:
    """Kontext live aus dem Posteingang (dieselbe Liste wie der Abgleich, markiert nichts als gelesen): eigene
    Kennung, dann bis zu INBOX_PAGES Seiten zu je 50. Liefert (Kontext, eigene Kennung)."""
    me = studip_live.current_user()["id"]
    path = f"jsonapi.php/v1/users/{me}/inbox?page[limit]=50&include=sender"
    with_include, pages, rid = True, 0, raw_id(message_id)
    while path and pages < INBOX_PAGES:
        r = studip_live.call("GET", path)
        if r.status == 400 and with_include:
            with_include = False
            path = f"jsonapi.php/v1/users/{me}/inbox?page[limit]=50"
            continue
        if not r.ok:
            raise ReplyError("http", r.status)
        page = r.json() if isinstance(r.json(), dict) else {}
        pages += 1
        c = context(rid, page, me)
        if c is not None:
            return c, me
        nxt = (page.get("links") or {}).get("next") if isinstance(page.get("links"), dict) else None
        if isinstance(nxt, dict):
            nxt = nxt.get("href")
        path = studip_live._next_path(nxt) if isinstance(nxt, str) and nxt else None
    raise ReplyError("not_found")


def recipient_names(ids: list[str]) -> list[dict]:
    """Namen weiterer Empfaenger (`users/{id}`, hoechstens MAX_REPLY_ALL); Unbekannte heissen "Stud.IP-Nutzer/in".
    Eine abgelaufene Sitzung bricht ab."""
    out = []
    for i in ids[:MAX_REPLY_ALL]:
        name = UNKNOWN_USER
        try:
            r = studip_live.call("GET", f"jsonapi.php/v1/users/{i}")
            j = r.json() if r.ok else None
            if isinstance(j, dict) and isinstance(j.get("data"), dict):
                name = display_name(j["data"].get("attributes")) or name
        except studip_live.SessionExpired:
            raise
        except Exception:  # noqa: BLE001 - ein unsichtbarer Nutzer heisst eben "Stud.IP-Nutzer/in"
            pass
        out.append({"id": i, "name": name})
    return out


def send(subject: str, text: str, recipient_ids: list[str]) -> str | None:
    """`POST messages`: genau ein Versuch (die stille Erneuerung bei 401 zaehlt nicht, da hat Stud.IP nichts angenommen)."""
    data = json.dumps(payload(subject, text, recipient_ids), ensure_ascii=False).encode("utf-8")
    r = studip_live.call("POST", "jsonapi.php/v1/messages", body=data,
                         headers={"Content-Type": studip_live.JSONAPI, "Accept": studip_live.JSONAPI,
                                  "X-Requested-With": "XMLHttpRequest"})
    e = send_error(r.status, r.body)
    if e:
        raise e
    return sent_id(r.location, r.body)


# ---------------------------------------------------------------------------- Routen

def _stored(conn, message_id: str) -> dict:
    from . import studip_messages
    msgs, _ = studip_messages.stored_messages(conn)
    m = next((x for x in msgs if x["id"] == message_id), None)
    if m is None:
        raise HTTPException(404, {"detail": "Nachricht nicht gefunden.", "code": "not_found"})
    return m


def _fail(e: Exception, message_id: str):
    """Fehler -> HTTP-Antwort mit Code und Ausweg"""
    base = studip_live.base()
    web = reply_web_url(base, message_id)
    if isinstance(e, studip_live.NotAvailable):
        raise HTTPException(404, {"detail": "Antworten gibt es nur in der Windows-App mit Stud.IP.", "code": "not_available"})
    if isinstance(e, studip_live.NotConnected):
        raise HTTPException(409, {"detail": ERRORS["not_connected"], "code": "studip_not_connected", "web_url": web})
    if isinstance(e, studip_live.SessionExpired):
        raise HTTPException(409, {"detail": ERRORS["login"], "code": "studip_login", "web_url": web})
    if isinstance(e, ReplyError):
        status = 422 if e.code == "system_message" else 502 if e.code == "http" else 409
        raise HTTPException(status, {"detail": e.message, "code": f"reply_{e.code}", "web_url": web if e.offers_web_fallback else None})
    if isinstance(e, studip_live.StudIPHTTPError):
        raise HTTPException(502, {"detail": ERRORS["http"].format(status=e.status), "code": "reply_http", "web_url": web})
    if isinstance(e, (urllib.error.URLError, OSError, TimeoutError)):
        raise HTTPException(503, {"detail": ERRORS["offline"], "code": "reply_offline", "web_url": web})
    raise e


def _check_learnweb():
    """Antworten im Learnweb nur am PC/in der Windows-App (im Dienst liegen keine Nachrichten)"""
    from . import studip_extras
    if not studip_extras.messages_allowed():
        raise HTTPException(404, {"detail": "Antworten gibt es nur in der Windows-App.", "code": "not_available"})


def _check_local():
    if not studip_live.available():
        raise HTTPException(404, {"detail": "Antworten gibt es nur in der Windows-App mit Stud.IP.", "code": "not_available"})


@router.get("/{message_id}/reply")
def api_reply_context(message_id: str, all: int = Query(default=0, ge=0, le=1)):
    if message_id.startswith("lw-msg-"):
        _check_learnweb()
        return learnweb_context(message_id)
    if message_id.startswith("moodle-"):
        _check_learnweb()
        return moodle_context(message_id)
    _check_local()
    with db.cursor() as conn:
        m = _stored(conn, message_id)
        draft = draft_for(conn, message_id)
    if not is_replyable(m.get("sender")):
        _fail(ReplyError("system_message"), message_id)
    try:
        ctx, _ = fetch_context(message_id)
        others = recipient_names(ctx["other_ids"]) if all and allows_reply_all(ctx) else []
    except Exception as e:  # noqa: BLE001
        _fail(e, message_id)
    base = studip_live.base()
    return {"message_id": message_id, "subject": ctx["subject"] or m.get("subject") or "",
            "reply_subject": reply_subject(ctx["subject"] or m.get("subject") or ""),
            "sender": ctx["sender"], "others": others, "other_count": len(ctx["other_ids"]),
            "recipients_known": ctx["recipients_known"], "allows_reply_all": allows_reply_all(ctx),
            "is_circular": is_circular(ctx), "quote": quote(m.get("text") or "", ctx["sender"]["name"], m.get("sent_at")),
            "draft": draft, "notice": NOTICE, "web_url": reply_web_url(base, message_id), "outbox_url": outbox_web_url(base)}


@router.post("/{message_id}/reply")
def api_reply_send(message_id: str, b: dict = Body(...)):
    if message_id.startswith("lw-msg-"):
        _check_learnweb()
        return learnweb_send(message_id, b)
    if message_id.startswith("moodle-"):
        _check_learnweb()
        return moodle_send(message_id, b)
    _check_local()
    text = str(b.get("text") or "")
    if not text.strip():
        raise HTTPException(400, {"detail": "Bitte einen Text schreiben.", "code": "reply_empty"})
    if len(text) > MAX_TEXT:
        raise HTTPException(400, {"detail": "Der Text ist zu lang.", "code": "reply_too_long"})
    mode = clean_mode(b.get("mode"))
    with db.cursor() as conn:
        m = _stored(conn, message_id)
    if not is_replyable(m.get("sender")):
        _fail(ReplyError("system_message"), message_id)
    try:
        ctx, _ = fetch_context(message_id)                                   # Empfaenger nur aus Stud.IP, nie vom Browser
        if mode == "all" and not allows_reply_all(ctx):
            mode = "sender"
        ids = [ctx["sender"]["id"]] + (ctx["other_ids"] if mode == "all" else [])
        subject = str(b.get("subject") or "").strip()[:MAX_SUBJECT] or reply_subject(ctx["subject"] or m.get("subject") or "")
        q = quote(m.get("text") or "", ctx["sender"]["name"], m.get("sent_at")) if b.get("quote") else None
        new_id = send(subject, body(text, q), ids)
    except Exception as e:  # noqa: BLE001
        _fail(e, message_id)
    at = now_iso()
    record = {"message_id": message_id, "at": at, "subject": subject, "text": text.strip(), "quoted": bool(q),
              "mode": mode, "recipients": len(ids), "sent_id": new_id}
    with db.cursor() as conn:
        add_reply(conn, record)
        remove_draft(conn, message_id)
    return {"sent": True, "record": {**record, "line": replied_line(at)}, "outbox_url": outbox_web_url(studip_live.base())}


@router.put("/{message_id}/draft")
def api_draft_put(message_id: str, b: dict = Body(...)):
    _check_learnweb() if message_id.startswith(("lw-msg-", "moodle-")) else _check_local()
    with db.cursor() as conn:
        _stored(conn, message_id)
        return {"draft": put_draft(conn, message_id, b)}


@router.delete("/{message_id}/draft")
def api_draft_delete(message_id: str):
    _check_learnweb() if message_id.startswith(("lw-msg-", "moodle-")) else _check_local()
    with db.cursor() as conn:
        remove_draft(conn, message_id)
    return {"draft": None}
