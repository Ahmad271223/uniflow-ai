"""Seite "Nachrichten" (Einzelplatz/Windows, 05.11.2026): der Stud.IP-Posteingang, wie ihn der Abgleich lokal speichert
(app/studip_extras.py, Tabelle `studip_messages`). Gleiche Regeln wie `StudIPExtras.messageList` und `MessagesInbox` der
iPad-App (apps/apple, Commit 1f99d9b), damit beide Seiten dasselbe zeigen.

Datenschutz (gilt hier wie dort):
 - nur die Liste des Posteingangs, nie die Einzelansicht einer Nachricht (die koennte sie in Stud.IP als gelesen
   markieren); die App markiert nie etwas in Stud.IP;
 - nur lokal: im gehosteten Dienst gibt es keine Nachrichten (`studip_extras.messages_allowed`), die Routen antworten leer;
 - die Antworten gehen nie in den Offline-Speicher des Browsers (sw-policy.js, API_NEVER), nie an die KI, nie an einen Dienst.

Routen:
  GET  /api/studip/messages?q=      {messages, total, fetched_at, q, available, seen_up_to, new_count}
  GET  /api/studip/messages/status  {available, stored, new_count}  (klein: fuer Menuepunkt und Zaehler)
  POST /api/studip/messages/seen    alles Gespeicherte gilt als gesehen (Marke = juengste `sent_at`)

"Neu" heisst: gesendet nach der juengsten Nachricht, die beim letzten Oeffnen der Seite da war. Die Marke steht in den
Einstellungen (`messages_seen_up_to`, nur auf diesem Geraet: sync_client.LOCAL_SETTINGS). Nie geoeffnet: alle neu.
"""
from __future__ import annotations

import json
import unicodedata
from datetime import datetime
from functools import cmp_to_key

from fastapi import APIRouter

from . import config, db, studip_extras

router = APIRouter(prefix="/api/studip/messages", tags=["studip-messages"])

SEEN_KEY = "messages_seen_up_to"


def instant(s) -> datetime | None:
    """Zeitpunkt einer Stud.IP-Zeitangabe ("2026-11-02T08:15:00+01:00", auch mit Sekundenbruchteilen oder "Z"); None,
    wenn unlesbar oder ohne Zeitzone (ohne Versatz laesst sich nicht vergleichen). Wie `StudIPExtras.messageInstant`."""
    if not isinstance(s, str) or not s:
        return None
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo is not None else None


def is_new(sent_at, mark) -> bool:
    """Neuer als die Marke? Ohne Marke ja. Verglichen wird der Zeitpunkt (der Versatz zur Weltzeit wechselt im Herbst),
    ohne lesbaren Zeitpunkt der Text. Wie `MessagesInbox.isNew`."""
    if not mark:
        return True
    if not sent_at:
        return False
    a, b = instant(sent_at), instant(mark)
    if a is not None and b is not None:
        return a > b
    return sent_at > mark


def newest(messages: list[dict]) -> str | None:
    """Juengste `sent_at` einer Liste (nach Zeitpunkt)."""
    best = None
    for m in messages:
        s = m.get("sent_at")
        if s and (best is None or is_new(s, best)):
            best = s
    return best


def _fold(s: str) -> str:
    """Klein und ohne Akzente: "prufung" findet "Prüfung"."""
    return "".join(c for c in unicodedata.normalize("NFD", s.casefold()) if not unicodedata.combining(c))


def matches(m: dict, words: list[str]) -> bool:
    """Jedes Wort der Suche steht in Absender, Betreff oder Text (ohne Gross-/Kleinschreibung und Akzente)."""
    hay = _fold("\n".join(str(m.get(k) or "") for k in ("sender", "subject", "text")))
    return all(_fold(w) in hay for w in words)


def _compare(a: dict, b: dict) -> int:
    """Neueste zuerst (nach Zeitpunkt); eine ohne lesbaren Zeitpunkt steht hinter denen mit; bei Gleichstand der Text der
    Zeitangabe absteigend, dann die Kennung aufsteigend (wie `StudIPExtras.messageList`)."""
    x, y = instant(a.get("sent_at")), instant(b.get("sent_at"))
    if x is not None and y is not None and x != y:
        return -1 if x > y else 1
    if (x is None) != (y is None):
        return -1 if x is not None else 1
    sa, sb = str(a.get("sent_at") or ""), str(b.get("sent_at") or "")
    if sa != sb:
        return -1 if sa > sb else 1
    ia, ib = str(a.get("id") or ""), str(b.get("id") or "")
    return (ia > ib) - (ia < ib)


def _order(all_: list[dict]) -> list[dict]:
    return sorted(all_, key=cmp_to_key(_compare))


def stored_messages(conn) -> tuple[list[dict], str | None]:
    """Alle gespeicherten Nachrichten (neueste zuerst) und der juengste Abruf. Ohne Tabelle oder im Dienst leer."""
    if not studip_extras.messages_allowed() or not studip_extras._has(conn, "studip_messages"):
        return [], None
    out, fetched = [], None
    for r in conn.execute("SELECT id, sender, subject, preview, sent_at, url, dates, fetched_at FROM studip_messages"):
        try:
            dates = json.loads(r[6] or "[]")
        except ValueError:
            dates = []
        out.append({"id": r[0], "sender": r[1], "subject": r[2], "text": r[3], "sent_at": r[4], "url": r[5],
                    "dates": dates if isinstance(dates, list) else []})
        if r[7] and (fetched is None or str(r[7]) > fetched):
            fetched = str(r[7])
    return _order(out), fetched


def seen_mark(conn) -> str | None:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (SEEN_KEY,)).fetchone()
    return (r[0] or None) if r else None


def stud_ip_offered() -> bool:
    """Hat die Hochschule dieser App Stud.IP? (Hildesheim: Learnweb und LSF, dort gibt es keine Nachrichten.)"""
    from . import universities
    try:
        return universities.PROFILES.get(universities.current_key(), {}).get("files_source") == "Stud.IP"
    except Exception:  # noqa: BLE001
        return False


def stud_ip_connected() -> bool:
    """Stud.IP ist verbunden: gemerkte Sitzung (auch abgelaufen) oder freiwillig hinterlegte Zugangsdaten."""
    from . import unilogin
    try:
        if unilogin.saved_cookies("STUDIP_COOKIES"):
            return True
        user, pw = config.credentials()
        return bool(user and pw)
    except Exception:  # noqa: BLE001
        return False


def shows_nav_item(local: bool, offered: bool, connected: bool, stored: int) -> bool:
    """Menuepunkt zeigen? Nur lokal; dort mit verbundenem Stud.IP (die Hochschule hat Stud.IP und es ist verbunden) oder
    schon gespeicherten Nachrichten. Wie `MessagesInbox.showsNavItem`."""
    return bool(local and ((offered and connected) or stored > 0))


def status(conn) -> dict:
    msgs, _ = stored_messages(conn)
    mark = seen_mark(conn)
    local = studip_extras.messages_allowed()
    return {"available": shows_nav_item(local, stud_ip_offered(), stud_ip_connected() if local else False, len(msgs)),
            "stored": len(msgs), "new_count": sum(1 for m in msgs if is_new(m["sent_at"], mark))}


def message_list(conn, query: str = "") -> dict:
    """Antwort von GET /api/studip/messages: gefilterte Nachrichten, alle gespeicherten gezaehlt (`total`)."""
    q = (query or "").strip()
    msgs, fetched = stored_messages(conn)
    mark = seen_mark(conn)
    words = q.split()
    shown = [m for m in msgs if matches(m, words)] if words else msgs
    st = status(conn)
    return {"messages": shown, "total": len(msgs), "fetched_at": fetched, "q": q, "available": st["available"],
            "seen_up_to": mark, "new_count": st["new_count"]}


def mark_seen(conn) -> str | None:
    """Alles Gespeicherte gilt als gesehen: Marke = juengste `sent_at`, nie zurueck."""
    msgs, _ = stored_messages(conn)
    latest = newest(msgs)
    mark = seen_mark(conn)
    if latest and is_new(latest, mark):
        db.set_setting(conn, SEEN_KEY, latest)
        return latest
    return mark


@router.get("")
def api_list(q: str = ""):
    with db.cursor() as conn:
        return message_list(conn, q[:200])


@router.get("/status")
def api_status():
    with db.cursor() as conn:
        return status(conn)


@router.post("/seen")
def api_seen():
    with db.cursor() as conn:
        mark_seen(conn)
        return status(conn)
