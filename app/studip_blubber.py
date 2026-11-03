"""Blubber aus Stud.IP (Kurs-Chats), VORBEREITET und AUSGESCHALTET (Entscheidung des Inhabers 03.11.2026, Commit c740713).
Python-Fassung des Swift-Kerns (StudIPBlubber.swift), gleiche Regeln und Antworten der Endpunkte, aber `SYNC_ENABLED` ist
False: nichts im Abgleich (app/studip_sync.py) ruft dieses Modul, und `fetch` fragt Stud.IP auch bei einem Aufruf nie, solange
der Schalter aus ist.

Warum aus: `GET blubber-threads` raeumt in Stud.IP leere, ueber eine Stunde alte Threads ohne Beitrag auf (loescht sie, wie
das Oeffnen von Blubber im Browser); das ist kein reines Lesen. Die Route `courses/{id}/blubber-threads` LEGT sogar den
Standard-Thread des Kurses an (BlubberThread::findByContext -> store()) und wird darum nie benutzt. Beides siehe
docs/IPAD-STUDIP-SYNC.md, Abschnitt 12.

Vorbereitet sind: Lesen der Threads und Beitraege (nur Rolle statt Name, Erwaehnungen und Zitate entfernt, Text ganz), Speichern
(Tabelle studip_blubber, nur lokal), die Antworten von GET /api/studip/blubber und /api/studip/blubber/{id} (ohne Daten leer)
und die Zeilen fuer die Karte "Neuigkeiten" (`feed_lines`). Anfragen sind nur GET auf `blubber-threads` und
`blubber-threads/{id}/comments`, hoechstens eine Liste und MAX_THREADS Kommentar-Listen je Abruf.
"""
from __future__ import annotations

import json
import re
from datetime import date, timedelta

from . import announcements, config, studip_extras, studip_texts

SYNC_ENABLED = False             # Entscheidung des Inhabers 03.11.2026: vorerst aus (siehe oben)
PER_THREAD = 20                  # neueste Beitraege je Thread
MAX_TEXT = 50000                 # nur Notbremse: Beitraege bleiben ganz (nie "…")
MAX_THREADS = 12                 # Kommentar-Listen je Abruf
LIST_LIMIT = 40                  # Threads in der Liste (Stud.IP sortiert nach letzter Aktivitaet)
MISSING_NAME = "blubber"
NEW_DAYS = 7
GLOBAL_ID = "global"             # Kennung des Stud.IP-weiten Threads
ACTIVITY_KEY = "studip_blubber_activity"
FETCHED_KEY = "studip_blubber_fetched_at"
API = "jsonapi.php/v1/"
UNKNOWN_ROLE = "Teilnehmende"    # ohne erkennbare Rolle
OWN_ROLE = "du"

TABLE = """CREATE TABLE IF NOT EXISTS studip_blubber (
    id TEXT PRIMARY KEY,
    course_id TEXT,                    -- NULL = Stud.IP-weiter Thread
    thread_id TEXT NOT NULL,
    author_role TEXT NOT NULL,         -- Lehrende, Tutor/in, Studierende, du ... nie ein Name
    text TEXT NOT NULL,                -- ganzer Text ohne Formatierung und Erwaehnungen
    posted_at TEXT,                    -- YYYY-MM-DDTHH:MM:SS, Ortszeit
    url TEXT,                          -- Thread in Stud.IP
    fetched_at TEXT
)"""


class SessionExpired(Exception):
    pass


# ----------------------------------------------------------------------------
# Lesen
# ----------------------------------------------------------------------------

def _str(v) -> str:
    return v if isinstance(v, str) else ""


def thread_url(base: str, thread_id: str, course_id: str | None) -> str:
    """Link in Stud.IP wie `BlubberThread::getURL`"""
    b = base.rstrip("/")
    if course_id:
        return f"{b}/dispatch.php/course/messenger/course/{thread_id}?cid={course_id}"
    return f"{b}/dispatch.php/blubber/index/{thread_id}"


def _users(included) -> dict:
    """Nutzer aus `included` (nur die Rolle wird gelesen)"""
    out = {}
    for u in included if isinstance(included, list) else []:
        if isinstance(u, dict) and u.get("type") == "users" and studip_extras._id(u):
            out[studip_extras._id(u)] = studip_extras._attrs(u)
    return out


def _role(x, users: dict, user_id: str) -> str:
    """Rolle statt Name: "du" fuer eigene Beitraege, sonst die globale Rolle (`permission`) wie bei den Nachrichten"""
    r = studip_extras._rel(x, "author")
    uid = studip_extras._id(r) if isinstance(r, dict) else None
    if not uid:
        return UNKNOWN_ROLE
    if user_id and uid == user_id:
        return OWN_ROLE
    return studip_extras.ROLE_LABELS.get(_str(users.get(uid, {}).get("permission")).lower(), UNKNOWN_ROLE)


# Erwaehnung, wie Stud.IP sie speichert: `[Vorname Nachname]https://…/dispatch.php/profile?username=x`
_MENTION_LINK = re.compile(r"\[[^\]\n]*\]\s*\S*dispatch\.php/profile\S*")
_PROFILE_URL = re.compile(r"\S*dispatch\.php/profile\?\S*")
_QUOTED_MENTION = re.compile(r'(?<![\w@])@"[^"\n]*"')
_PROFILE_ANCHOR = re.compile(r"(?is)<a\b[^>]*dispatch\.php/profile[^>]*>.*?</a>")
_LINK_MARKUP = re.compile(r"\[([^\]\n]+)\](https?://\S+)")
_ANY_SPACE = re.compile(r"\s+")


def clean(content: str, html: str) -> str:
    """Text eines Beitrags ohne Namen: Erwaehnungen, Profil-Links und Zitate fallen weg, Formatierung wird Text,
    Leerraum zusammengefasst, ganz (MAX_TEXT ist nur eine Notbremse)"""
    if content.strip():
        t = _MENTION_LINK.sub("@Person", content)
        t = _PROFILE_URL.sub("", t)
        t = _QUOTED_MENTION.sub("@Person", t)
        t = _LINK_MARKUP.sub(r"\1", t)
        t = studip_texts.rich_to_text(studip_texts.anonymize(t))
    else:
        t = announcements.html_to_text(studip_texts.anonymize(_PROFILE_ANCHOR.sub("@Person", html)))
        t = _QUOTED_MENTION.sub("@Person", _PROFILE_URL.sub("", t))
    return studip_texts.full(_ANY_SPACE.sub(" ", t), MAX_TEXT)


def local(v) -> str:
    """Zeitpunkt (ISO mit Zone) -> "YYYY-MM-DDTHH:MM:SS" Ortszeit Berlin; "" ohne lesbare Zeit"""
    t = studip_texts.berlin_local(v)
    return t + ":00" if t else ""


def parse_threads(j, course_ids: set, user_id: str, base: str) -> list[dict]:
    """Threads aus `blubber-threads`: nur Kurse aus `course_ids` und der Stud.IP-weite Thread; private Gespraeche,
    Einrichtungen und andere oeffentliche Threads nie. Der Name des Threads (bei oeffentlichen und privaten der Name
    einer Person) wird nicht gelesen. Thread: {id, course_id, latest_activity, url, opening}."""
    users = _users((j or {}).get("included"))
    out, seen = [], set()
    for x in (j or {}).get("data") or []:
        tid = studip_extras._id(x)
        if tid is None or tid in seen:
            continue
        a = studip_extras._attrs(x)
        kind = _str(a.get("context-type")).lower()
        course_id = None
        if kind == "course":
            ctx = studip_extras._rel(x, "context")
            cid = studip_extras._id(ctx) if isinstance(ctx, dict) else None
            if cid is None or cid not in course_ids:
                continue
            course_id = cid
        elif not (kind == "public" and tid == GLOBAL_ID):
            continue
        seen.add(tid)
        url = thread_url(base, tid, course_id)
        opening = None
        text = clean(_str(a.get("content")), _str(a.get("content-html")))
        if text and tid != GLOBAL_ID:
            opening = {"id": f"bt-{tid}", "course_id": course_id, "thread_id": tid, "author_role": _role(x, users, user_id),
                       "text": text, "posted_at": local(a.get("mkdate")), "url": url}
        out.append({"id": tid, "course_id": course_id, "latest_activity": _str(a.get("latest-activity")), "url": url, "opening": opening})
    return out


def parse_comments(j, thread: dict, user_id: str) -> list[dict]:
    """Beitraege aus `blubber-threads/{id}/comments` (neueste zuerst angefragt), hoechstens PER_THREAD, ohne leere"""
    users = _users((j or {}).get("included"))
    out, seen = [], set()
    for x in (j or {}).get("data") or []:
        cid = studip_extras._id(x)
        if cid is None or cid in seen:
            continue
        seen.add(cid)
        a = studip_extras._attrs(x)
        text = clean(_str(a.get("content")), _str(a.get("content-html")))
        if not text:
            continue
        out.append({"id": f"bc-{cid}", "course_id": thread["course_id"], "thread_id": thread["id"], "author_role": _role(x, users, user_id),
                    "text": text, "posted_at": local(a.get("mkdate")), "url": thread["url"]})
        if len(out) >= PER_THREAD:
            break
    return out


# ----------------------------------------------------------------------------
# Abruf (ausgeschaltet)
# ----------------------------------------------------------------------------

class Download:
    def __init__(self, missing: dict):
        self.threads: list[dict] | None = None      # None = Liste nicht gelesen (fehlt, Fehler, Sitzung); der Bestand bleibt
        self.posts: dict[str, list[dict]] = {}      # neu gelesene Threads -> Beitraege; nicht genannte bleiben wie gespeichert
        self.activity: dict[str, str] = {}
        self.missing = missing
        self.session_expired = False
        self.requests = 0


def fetch(get, user_id: str, course_ids: list, missing: dict, known: dict, today: str, base: str = "") -> Download:
    """Liste und die geaenderten Threads. `get(pfad)` -> (HTTP-Status, JSON oder None), nur GET. Wirft nie. Ist
    SYNC_ENABLED aus, wird nichts gefragt (leerer Abruf, Bestand bleibt). `known`: Thread -> zuletzt gelesene
    `latest-activity`; `course_ids`: die gewaehlten aktuellen Kurse."""
    d = Download(missing)
    if not SYNC_ENABLED or not studip_extras.should_ask(missing, MISSING_NAME, today):
        return d

    def ask(path: str):
        d.requests += 1
        status, body = get(path)
        if status == 401 or (200 <= status < 300 and not isinstance(body, dict)):
            raise SessionExpired()                  # Anmeldeseite statt JSON
        return status, body

    try:
        status, body = ask(f"{API}blubber-threads?page[limit]={LIST_LIMIT}&include=author")
    except SessionExpired:
        d.session_expired = True
        return d
    except Exception:  # noqa: BLE001 - Netz: Bestand bleibt
        return d
    if not 200 <= status < 300:
        d.missing = studip_extras.remember(missing, MISSING_NAME, status, today)
        return d
    if not isinstance(body.get("data"), list):
        return d
    d.missing = studip_extras.remember(missing, MISSING_NAME, 200, today)
    threads = parse_threads(body, set(course_ids), user_id, base)
    d.threads = threads
    asked = 0
    for t in threads:
        if t["latest_activity"] and known.get(t["id"]) == t["latest_activity"]:
            continue                                # unveraendert
        if asked >= MAX_THREADS:
            break
        asked += 1
        try:
            status, body = ask(f"{API}blubber-threads/{t['id']}/comments?sort=-mkdate&page[limit]={PER_THREAD}&include=author")
        except SessionExpired:
            d.session_expired = True
            return d
        except Exception:  # noqa: BLE001 - dieser Thread bleibt wie gespeichert
            continue
        if not 200 <= status < 300 or not isinstance(body.get("data"), list):
            continue
        posts = parse_comments(body, t, user_id)
        if t["opening"]:
            posts.append(t["opening"])
        d.posts[t["id"]] = posts
        d.activity[t["id"]] = t["latest_activity"]
    return d


# ----------------------------------------------------------------------------
# Speicher
# ----------------------------------------------------------------------------

def _has(conn) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_blubber'").fetchone() is not None


def _setting(conn, key: str) -> str | None:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return r[0] if r else None


def known(conn) -> dict:
    """Zuletzt gelesene `latest-activity` je Thread (fuer `fetch`)"""
    try:
        v = json.loads(_setting(conn, ACTIVITY_KEY) or "{}")
    except ValueError:
        return {}
    return {k: s for k, s in v.items() if isinstance(s, str)} if isinstance(v, dict) else {}


def store(d: Download, conn, now: str) -> int:
    """Schreibt den Abruf: Threads, die nicht mehr in der Liste stehen (Kurs abgewaehlt, in Stud.IP geloescht), fallen weg;
    neu gelesene Threads werden ersetzt, die anderen bleiben. Im gehosteten Dienst wird nichts gespeichert."""
    studip_extras.save_missing(conn, d.missing)
    if d.threads is None or config.is_hosted():
        return 0
    conn.execute(TABLE)
    ids = [t["id"] for t in d.threads]
    conn.execute(f"""DELETE FROM studip_blubber WHERE thread_id NOT IN ({",".join("?" * len(ids)) or "''"})""", ids)
    n = 0
    for tid, posts in d.posts.items():
        conn.execute("DELETE FROM studip_blubber WHERE thread_id=?", (tid,))
        for p in posts:
            conn.execute("""INSERT OR REPLACE INTO studip_blubber(id, course_id, thread_id, author_role, text, posted_at, url, fetched_at)
                            VALUES (?,?,?,?,?,?,?,?)""", (p["id"], p["course_id"], p["thread_id"], p["author_role"], p["text"], p["posted_at"], p["url"], now))
            n += 1
    activity = {k: v for k, v in known(conn).items() if k in ids} | d.activity
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (ACTIVITY_KEY, json.dumps(activity, sort_keys=True)))
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (FETCHED_KEY, now))
    return n


# ----------------------------------------------------------------------------
# Lesen: Karte, Leser, Neuigkeiten
# ----------------------------------------------------------------------------

def _opt(s):
    return s if s else None


def thread_rows(conn, course_id: str | None, module_id: int | None, today: date) -> list[dict]:
    """Threads mit Zahlen. Filter: Kurs (`course`) oder Modul (`module`), sonst alle (auch der Stud.IP-weite)"""
    if config.is_hosted() or not _has(conn):
        return []
    sql = """SELECT b.thread_id, b.course_id, b.author_role, b.text, b.posted_at, b.url, c.title AS course_title, m.color
             FROM studip_blubber b LEFT JOIN courses c ON c.id=b.course_id LEFT JOIN modules m ON m.id=c.module_id"""
    args: tuple = ()
    if course_id:
        sql, args = sql + " WHERE b.course_id=?", (course_id,)
    elif module_id is not None:
        sql, args = sql + " WHERE c.module_id=?", (module_id,)
    sql += " ORDER BY b.posted_at DESC, b.id"
    since = (today - timedelta(days=NEW_DAYS)).isoformat()
    order: list[str] = []
    groups: dict[str, list] = {}
    for r in conn.execute(sql, args).fetchall():
        if r["thread_id"] not in groups:
            order.append(r["thread_id"])
        groups.setdefault(r["thread_id"], []).append(r)
    out = []
    for tid in order:
        rs = groups[tid]
        first = rs[0]                                           # neuester Beitrag
        fresh = [r for r in rs if (r["posted_at"] or "") and r["posted_at"][:10] >= since and r["author_role"] != OWN_ROLE]
        where = "Stud.IP-weit" if first["course_id"] is None else (first["course_title"] or "Kurs")
        out.append({"id": tid, "course_id": first["course_id"], "course_title": where, "count": len(rs), "new_count": len(fresh),
                    "changed": _opt(first["posted_at"]), "new_at": _opt(fresh[0]["posted_at"]) if fresh else None,
                    "preview": f"{first['author_role']}: {first['text']}", "url": _opt(first["url"]), "color": first["color"]})
    return out


def overview(conn, course_id: str | None, module_id: int | None, today: date) -> dict:
    """`GET /api/studip/blubber?course=&module=`: {threads: [...], count, fetched_at}; Threads mit dem neuesten Beitrag zuerst"""
    threads = thread_rows(conn, course_id, module_id, today)
    return {"threads": threads, "count": sum(t["count"] for t in threads),
            "fetched_at": None if config.is_hosted() else _setting(conn, FETCHED_KEY)}


def thread(conn, thread_id: str) -> dict | None:
    """`GET /api/studip/blubber/{thread_id}`: Beitraege zum Lesen, aelteste zuerst; None = unbekannt"""
    if config.is_hosted() or not _has(conn):
        return None
    rows = conn.execute("""SELECT b.id, b.course_id, b.author_role, b.text, b.posted_at, b.url, c.title AS course_title
                           FROM studip_blubber b LEFT JOIN courses c ON c.id=b.course_id WHERE b.thread_id=? ORDER BY b.posted_at, b.id""",
                        (thread_id,)).fetchall()
    if not rows:
        return None
    first = rows[0]
    return {"id": thread_id, "course_id": first["course_id"],
            "course_title": "Stud.IP-weit" if first["course_id"] is None else (first["course_title"] or "Kurs"),
            "url": _opt(first["url"]),
            "comments": [{"id": r["id"], "role": r["author_role"], "text": r["text"], "posted_at": _opt(r["posted_at"])} for r in rows]}


def feed_title(course: str, is_global: bool, count: int) -> str:
    """"Blubber in Analysis I: 3 neue Beiträge" """
    n = "1 neuer Beitrag" if count == 1 else f"{count} neue Beiträge"
    return f"Blubber Stud.IP-weit: {n}" if is_global else f"Blubber in {course}: {n}"


def feed_lines(conn, today: date) -> list[dict]:
    """Zeilen fuer die Karte "Neuigkeiten": je Thread mit neuen Beitraegen anderer (letzte NEW_DAYS Tage) eine Zeile, nur
    aktive Kurse und der Stud.IP-weite Thread"""
    if config.is_hosted() or not _has(conn):
        return []
    active = {r[0] for r in conn.execute("SELECT id FROM courses WHERE active=1").fetchall()}
    out = []
    for t in thread_rows(conn, None, None, today):
        is_global = t["course_id"] is None
        if t["new_count"] <= 0 or not (is_global or t["course_id"] in active):
            continue
        out.append({"id": f"blubber-{t['id']}", "kind": "blubber", "who": "Stud.IP-weit" if is_global else t["course_title"],
                    "title": feed_title(t["course_title"], is_global, t["new_count"]), "at": t["new_at"] or "", "url": t["url"],
                    "text": t["preview"], "chips": [], "source": "studip", "color": t["color"], "thread_id": t["id"]})
    return out
