"""Neuigkeiten aus Stud.IP ueber die Kurse hinaus (02.11.2026, Auftrag des Inhabers "alles schlau einbauen, nicht
ueberladen"). Alles nur lesend; die App schreibt nie in Stud.IP.

 - Stud.IP-weite Ankuendigungen (`studip/news`): wie Kurs-Ankuendigungen in `announcements` (Fristen und Termine
   erkannt, app/announcements.py), aber ohne Kurs (course_id NULL). Eine Ankuendigung, die auch in einem Kurs steht,
   bleibt dem Kurs zugeordnet.
 - Nachrichten (`users/{id}/inbox`): nur die Liste, nie die Einzelansicht (die koennte eine Nachricht als gelesen
   markieren). Die Liste liefert den ganzen Text (Attribut `message`, MessageSchema; `is-read` wird nur gelesen, die
   Liste markiert nichts, geprueft im Stud.IP-Quelltext 03.11.2026). Gespeichert werden Absender (Rolle statt Name,
   wenn Stud.IP sie nennt), Betreff, Datum, der ganze Text (Spalte `preview`, Zeilenumbrueche bleiben), ein Link auf den Posteingang und die erkannten Tage (ohne Satz). Datenschutz: nur lokal
   (am PC nur im Einzelplatz-Betrieb, nie im Dienst), nicht in der Community, nicht automatisch in der KI.
 - Activity-Stream (`users/{id}/activitystream`): nur Hinweisquelle "Neu in Kurs X". Kurse damit beim Abgleich zu
   ueberspringen ist nicht sicher: der Stream nennt nicht jede Aenderung (geloeschte Dateien, Ordner, Termine aus
   Serien), ist gekuerzt und je Hochschule anders konfiguriert. Der Abgleich liest deshalb weiter jeden Kurs.
   Teilnehmende-, Nachrichten- und Blubber-Eintraege werden nie gelesen oder gespeichert, Namen von Personen auch nicht.
 - Sprechstunden (`users/{id}/consultation-bookings`): eigene Buchungen als Termine im Planer, nur lesend.

Endpunkte, die eine Hochschule nicht anbietet (404, 403), merkt sich die App (`settings.studip_missing_endpoints`) und
fragt sie erst nach RETRY_DAYS wieder an. Feldnamen, die an der LUH nicht belegt sind, werden defensiv gelesen
(Annahmen jeweils am Feld). Gleiche Regeln im Swift-Kern (StudIPExtras.swift), Fixture tools/gen-studip-extras-fixture.py.
"""
from __future__ import annotations

import json
import re
from datetime import date, timedelta

from . import announcements

RETRY_DAYS = 30
MISSING_KEY = "studip_missing_endpoints"
SYSTEM_SENDER = "____%system%____"
# globale Rolle (Annahme: Attribut `permission` des Nutzers, Stud.IP 5 UserSchema) -> Anzeige statt des Namens
ROLE_LABELS = {"dozent": "Lehrende", "tutor": "Tutor/in", "autor": "Studierende", "user": "Studierende",
               "admin": "Verwaltung", "root": "Stud.IP-Team"}
# Arten im Activity-Stream (Annahme: Attribut `activity-type`), die als Hinweis zaehlen; Einzahl, Mehrzahl.
# Ankuendigungen fehlen (sie stehen schon als Ankuendigung da), Teilnehmende und Nachrichten werden nie gelesen.
ACTIVITY_LABELS = {"documents": ("Datei", "Dateien"), "forum": ("Forumsbeitrag", "Forumsbeiträge"),
                   "wiki": ("Wiki-Änderung", "Wiki-Änderungen"), "schedule": ("Terminänderung", "Terminänderungen"),
                   "courseware": ("Courseware-Änderung", "Courseware-Änderungen")}
ACTIVITY_DAYS = 14
CHIP_KINDS = {"frist": "Frist", "pruefung": "Prüfung", "ausfall": "Ausfall?", "verlegt": "Verlegung?"}
CONSULT_COLOR = "#0e9f9a"

MESSAGES_TABLE = """CREATE TABLE IF NOT EXISTS studip_messages (
    id TEXT PRIMARY KEY,
    sender TEXT,                       -- Rolle (Lehrende, Verwaltung ...) oder hoechstens der Name
    subject TEXT,
    preview TEXT,                      -- ganzer Text der Nachricht (Name der Spalte von frueher)
    sent_at TEXT,
    url TEXT,                          -- Posteingang (nicht die Einzelansicht)
    dates TEXT,                        -- erkannte Tage [{date, time, kind}]
    fetched_at TEXT
)"""
ACTIVITY_TABLE = """CREATE TABLE IF NOT EXISTS studip_activity (
    id TEXT PRIMARY KEY,
    course_id TEXT NOT NULL,
    type TEXT NOT NULL,
    at TEXT NOT NULL,
    url TEXT,
    fetched_at TEXT
)"""
CONSULT_TABLE = """CREATE TABLE IF NOT EXISTS studip_consultations (
    id TEXT PRIMARY KEY,
    start TEXT NOT NULL,               -- YYYY-MM-DDTHH:MM:SS, Ortszeit
    end TEXT NOT NULL,
    room TEXT,
    fetched_at TEXT
)"""

_DT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}")


def _id(x) -> str | None:
    v = x.get("id") if isinstance(x, dict) else None
    if isinstance(v, bool) or not isinstance(v, (str, int)) or v == "":
        return None
    return str(v)


def _attrs(x) -> dict:
    a = x.get("attributes") if isinstance(x, dict) else None
    return a if isinstance(a, dict) else {}


def _rel(x, name: str):
    """Ziel einer Beziehung: dict mit type/id, None bei `data: null`, "" ohne Beziehung."""
    r = (x.get("relationships") or {}) if isinstance(x, dict) else {}
    r = r.get(name) if isinstance(r, dict) else None
    if not isinstance(r, dict) or "data" not in r:
        return ""
    return r["data"] if isinstance(r["data"], dict) else None


def _str(v) -> str:
    return v if isinstance(v, str) else ""


# ----------------------------------------------------------------------------
# Fehlende Endpunkte merken
# ----------------------------------------------------------------------------

def should_ask(missing: dict, name: str, today: str) -> bool:
    """Endpunkt anfragen? Nein, wenn er vor weniger als RETRY_DAYS Tagen fehlte."""
    seen = missing.get(name)
    if not isinstance(seen, str):
        return True
    try:
        return (date.fromisoformat(today) - date.fromisoformat(seen[:10])).days >= RETRY_DAYS
    except ValueError:
        return True


def remember(missing: dict, name: str, status: int, today: str) -> dict:
    """Nach einer Antwort: 404/403 merken, Erfolg vergessen, alles andere (Netz, 500) laesst den Stand."""
    out = dict(missing)
    if status in (403, 404):
        out[name] = today
    elif 200 <= status < 300:
        out.pop(name, None)
    return out


def load_missing(conn) -> dict:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (MISSING_KEY,)).fetchone()
    try:
        v = json.loads(r[0]) if r and r[0] else {}
    except ValueError:
        v = {}
    return v if isinstance(v, dict) else {}


def save_missing(conn, missing: dict) -> None:
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (MISSING_KEY, json.dumps(missing, sort_keys=True)))


# ----------------------------------------------------------------------------
# Lesen (reine Funktionen, gleich im Swift-Kern)
# ----------------------------------------------------------------------------

def global_news(data, base: str) -> list[dict]:
    """`data` von studip/news -> Ankuendigungen ohne Kurs (announcements.make); Link auf die Startseite."""
    out = []
    for n in data if isinstance(data, list) else []:
        nid = _id(n)
        if nid is None:
            continue
        a = _attrs(n)
        posted = _str(a.get("publication-start")) or _str(a.get("mkdate"))
        out.append(announcements.make(f"sp-news-{nid}", "studip", None, _str(a.get("title")), _str(a.get("content")), "",
                                      posted, f"{base}/dispatch.php/start"))
    return out


def sender_label(m: dict, users: dict) -> str:
    """Absender einer Nachricht: Systemnachricht "Stud.IP", sonst die Rolle, sonst "Absender" (nie der Name)."""
    s = _rel(m, "sender")
    if s is None or (isinstance(s, dict) and s.get("id") == SYSTEM_SENDER):
        return "Stud.IP"
    if not isinstance(s, dict):
        return ""
    a = users.get(str(s.get("id")), {})
    role = ROLE_LABELS.get(_str(a.get("permission")).lower())
    return role or "Absender"


def parse_messages(data, included, base: str, today: date) -> list[dict]:
    """`data` und `included` (Absender, `include=sender`) von users/{id}/inbox -> Nachrichten zum Speichern.
    Annahme (Stud.IP 5, MessageSchema): Attribute subject, message (HTML), mkdate; Beziehung sender. Die Tage werden
    aus Betreff und ganzem Text erkannt, gespeichert bleiben nur Tag, Uhrzeit und Art."""
    users = {_id(u): _attrs(u) for u in (included if isinstance(included, list) else [])
             if isinstance(u, dict) and u.get("type") == "users" and _id(u)}
    out = []
    for m in data if isinstance(data, list) else []:
        mid = _id(m)
        if mid is None:
            continue
        a = _attrs(m)
        subject = announcements.html_to_text(_str(a.get("subject")))[:announcements.MAX_TITLE] or "(ohne Betreff)"
        text = announcements.html_to_text(_str(a.get("message")))
        sent = _str(a.get("mkdate"))
        posted = announcements._posted_day_or_none(sent) or today
        dates = [{"date": d["date"], "time": d["time"], "kind": d["kind"]} for d in announcements.dates_for(subject, text, posted)]
        preview = text[:announcements.MAX_TEXT]      # ganzer Text (Inhaber 03.11.2026: nie "…")
        out.append({"id": f"sp-msg-{mid}", "sender": sender_label(m, users), "subject": subject, "preview": preview,
                    "sent_at": sent, "url": f"{base}/dispatch.php/messages/overview", "dates": dates})
    return out


def parse_activity(data, base: str) -> list[dict]:
    """`data` von users/{id}/activitystream -> [{id, course_id, type, at, url}] nur fuer Kurse und die Arten in
    ACTIVITY_LABELS. Annahme: Attribute activity-type, mkdate (ISO); Beziehung context (Typ courses). Titel und
    Inhalt (nennen Personen) werden nicht gelesen."""
    out = []
    for x in data if isinstance(data, list) else []:
        xid = _id(x)
        if xid is None:
            continue
        a = _attrs(x)
        typ = _str(a.get("activity-type")).lower()
        ctx = _rel(x, "context")
        at = _str(a.get("mkdate"))
        if typ not in ACTIVITY_LABELS or not isinstance(ctx, dict) or ctx.get("type") != "courses" or not _id(ctx) or len(at) < 10:
            continue
        cid = _id(ctx)
        out.append({"id": xid, "course_id": cid, "type": typ, "at": at, "url": f"{base}/dispatch.php/course/overview?cid={cid}"})
    return out


def _local_dt(v) -> str | None:
    """Zeitpunkt -> "YYYY-MM-DDTHH:MM:SS" Ortszeit: ISO-Text wie geliefert (erste 19 Zeichen), Unix-Zeit in Berlin."""
    if isinstance(v, str) and _DT_RE.match(v):
        s = v[:19]
        return s if len(s) == 19 else s[:16] + ":00"
    if isinstance(v, int) and not isinstance(v, bool) and v > 0:
        from .learnweb import local_iso
        return local_iso(v) + ":00"
    return None


def parse_bookings(data, included) -> list[dict]:
    """`data` von users/{id}/consultation-bookings (mit `include=slot,slot.block`) -> [{id, start, end, room}].
    Annahme (nicht an der LUH belegt): Buchung -> Beziehung slot (consultation-slots, Attribute start-time/end-time,
    sonst start/end, ISO oder Unix-Zeit) -> Beziehung block (consultation-blocks, Attribut room). Ohne lesbare Zeit
    fehlt die Buchung."""
    inc = {(i.get("type"), _id(i)): i for i in included if isinstance(i, dict)} if isinstance(included, list) else {}
    out = []
    for b in data if isinstance(data, list) else []:
        bid = _id(b)
        slot_ref = _rel(b, "slot")
        if bid is None or not isinstance(slot_ref, dict):
            continue
        slot = inc.get(("consultation-slots", _id(slot_ref)))
        sa = _attrs(slot)
        start = _local_dt(sa.get("start-time") if "start-time" in sa else sa.get("start"))
        end = _local_dt(sa.get("end-time") if "end-time" in sa else sa.get("end"))
        if not start or not end or end <= start:
            continue
        block_ref = _rel(slot, "block") if slot else ""
        block = inc.get(("consultation-blocks", _id(block_ref))) if isinstance(block_ref, dict) else None
        room = _str(_attrs(block).get("room")).strip()[:120]
        out.append({"id": bid, "start": start, "end": end, "room": room})
    return sorted(out, key=lambda x: (x["start"], x["id"]))


def chips(dates: list, today: str) -> list[dict]:
    """Hinweis-Chips einer Zeile: kommende Fristen, Pruefungen, Ausfaelle, Verlegungen ("Frist 12.11."), hoechstens zwei."""
    out: list[dict] = []
    for d in dates if isinstance(dates, list) else []:
        if not isinstance(d, dict) or not isinstance(d.get("date"), str) or d["date"] < today or d.get("kind") not in CHIP_KINDS:
            continue
        label = f"{CHIP_KINDS[d['kind']]} {d['date'][8:10]}.{d['date'][5:7]}."
        if any(c["label"] == label for c in out):
            continue
        out.append({"label": label, "kind": d["kind"], "date": d["date"]})
        if len(out) == 2:
            break
    return out


def activity_title(types: list[str]) -> str:
    """"Neu: 2 Dateien, 1 Forumsbeitrag" in der Reihenfolge von ACTIVITY_LABELS."""
    parts = []
    for t, (one, many) in ACTIVITY_LABELS.items():
        n = types.count(t)
        if n:
            parts.append(f"{n} {one if n == 1 else many}")
    return "Neu: " + ", ".join(parts)


def feed(news: list[dict], messages: list[dict], activity: list[dict], today: str, limit: int = 50, extra: list[dict] | None = None) -> list[dict]:
    """Eine Liste fuer die Karte "Neuigkeiten": Ankuendigungen (Kurs und Stud.IP-weit, aus announcements.recent),
    Nachrichten und Aenderungen (je Kurs und Tag zusammengefasst, mit course_title), neueste zuerst.
    Zeile: {id, kind (ankuendigung | nachricht | aenderung), who, title, at, url, text, chips, source, color}."""
    out = []
    for a in news:
        who = a.get("course_title") or ("Stud.IP-weit" if a.get("course_id") is None and a.get("source") == "studip" else
                                        "Learnweb" if a.get("source") == "learnweb" else "Stud.IP")
        out.append({"id": a["id"], "kind": "ankuendigung", "who": who, "title": a.get("title") or "Ankündigung", "at": a.get("posted_at") or "",
                    "url": a.get("url"), "text": a.get("text") or "", "chips": chips(a.get("dates"), today), "source": a.get("source"),
                    "color": a.get("color")})
    for m in messages:
        out.append({"id": m["id"], "kind": "nachricht", "who": m.get("sender") or "Nachricht", "title": m.get("subject") or "(ohne Betreff)",
                    "at": m.get("sent_at") or "", "url": m.get("url"), "text": m.get("preview") or "", "chips": chips(m.get("dates"), today),
                    "source": "studip", "color": None})
    groups: dict[tuple, list[dict]] = {}
    for x in activity:
        groups.setdefault((x["course_id"], x["at"][:10]), []).append(x)
    for (cid, day), xs in groups.items():
        latest = max(x["at"] for x in xs)
        out.append({"id": f"act-{cid}-{day}", "kind": "aenderung", "who": xs[0].get("course_title") or "Kurs",
                    "title": activity_title([x["type"] for x in xs]), "at": latest, "url": xs[0].get("url"), "text": "",
                    "chips": [], "source": "studip", "color": xs[0].get("color")})
    out += extra or []          # fertige Zeilen (Blubber, app/studip_blubber.py; Abgleich vorerst aus), werden mitsortiert
    out.sort(key=lambda x: x["at"], reverse=True)
    return out[:limit]


# ----------------------------------------------------------------------------
# Speicher
# ----------------------------------------------------------------------------

def _has(conn, table: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def store_global_news(conn, items: list[dict], fetched_at: str) -> dict:
    """Stud.IP-weite Ankuendigungen speichern; nicht mehr gelieferte (ohne Kurs) entfernen. Steht dieselbe auch in
    einem Kurs, bleibt sie dort."""
    in_course = {r[0] for r in conn.execute("SELECT id FROM announcements WHERE source='studip' AND course_id IS NOT NULL").fetchall()}
    keep = [a for a in items if a["id"] not in in_course]
    res = announcements.store(conn, keep, "studip", fetched_at)
    ids = [a["id"] for a in keep]
    res["removed"] = conn.execute(f"""DELETE FROM announcements WHERE source='studip' AND course_id IS NULL
                                      AND id NOT IN ({",".join("?" * len(ids)) or "''"})""", ids).rowcount
    return res


def messages_allowed() -> bool:
    """Nachrichten nur lokal: im Dienst (hosted) nie speichern."""
    from . import config
    return not config.is_hosted()


def store_messages(conn, items: list[dict], fetched_at: str) -> int:
    """Nachrichten ersetzen (in Stud.IP Geloeschtes verschwindet). Im Dienst: nichts speichern, Reste loeschen."""
    conn.execute(MESSAGES_TABLE)
    if not messages_allowed():
        conn.execute("DELETE FROM studip_messages")
        return 0
    ids = [m["id"] for m in items]
    conn.execute(f"""DELETE FROM studip_messages WHERE id NOT IN ({",".join("?" * len(ids)) or "''"})""", ids)
    for m in items:
        conn.execute("""INSERT OR REPLACE INTO studip_messages(id, sender, subject, preview, sent_at, url, dates, fetched_at)
                        VALUES (?,?,?,?,?,?,?,?)""",
                     (m["id"], m["sender"], m["subject"], m["preview"], m["sent_at"], m["url"], json.dumps(m["dates"], ensure_ascii=False), fetched_at))
    return len(items)


def store_activity(conn, items: list[dict], fetched_at: str, today: date) -> int:
    """Aenderungen dazuschreiben, aeltere als ACTIVITY_DAYS entfernen."""
    conn.execute(ACTIVITY_TABLE)
    for x in items:
        conn.execute("INSERT OR REPLACE INTO studip_activity(id, course_id, type, at, url, fetched_at) VALUES (?,?,?,?,?,?)",
                     (x["id"], x["course_id"], x["type"], x["at"], x["url"], fetched_at))
    conn.execute("DELETE FROM studip_activity WHERE substr(at, 1, 10) < ?", ((today - timedelta(days=ACTIVITY_DAYS)).isoformat(),))
    return len(items)


def store_consultations(conn, items: list[dict], fetched_at: str) -> int:
    """Eigene Sprechstunden-Buchungen ersetzen."""
    conn.execute(CONSULT_TABLE)
    conn.execute("DELETE FROM studip_consultations")
    for x in items:
        conn.execute("INSERT OR REPLACE INTO studip_consultations(id, start, end, room, fetched_at) VALUES (?,?,?,?,?)",
                     (x["id"], x["start"], x["end"], x["room"], fetched_at))
    return len(items)


def consultation_occurrences(conn, start: date, end: date) -> list[dict]:
    """Sprechstunden im Zeitraum als Vorkommen ohne Serie (wie timetable.studip_dated, nur lesend)."""
    if not _has(conn, "studip_consultations"):
        return []
    out = []
    for r in conn.execute("SELECT id, start, end, room FROM studip_consultations WHERE start >= ? AND start < ? ORDER BY start, id",
                          (start.isoformat(), (end + timedelta(days=1)).isoformat())).fetchall():
        cid, st, en, room = tuple(r)
        out.append({"event_id": None, "studip_id": f"consult-{cid}", "date": st[:10], "start": st[11:16],
                    "end": en[11:16] if en[:10] == st[:10] else "23:59", "title": "Sprechstunde", "kind": "sprechstunde",
                    "module_id": None, "module_name": None, "color": CONSULT_COLOR, "room": room or "", "lecturer": None,
                    "course_id": None, "status": "teilnahme", "permanent_skip": False, "exception": None,
                    "source": "studip-sprechstunde"})
    return out


def with_consultations(conn, occ: list[dict], start: date, end: date) -> list[dict]:
    """Vorkommen des Planers mit den Sprechstunden, nach Tag und Beginn (ohne Sprechstunden unveraendert)."""
    extra = consultation_occurrences(conn, start, end)
    if not extra:
        return occ
    return sorted(occ + extra, key=lambda o: (o["date"], o["start"] or ""))


def feed_for(conn, today: date, limit: int = 50) -> list[dict]:
    """Neuigkeiten aus der Datenbank (Endpunkt /api/news)."""
    t = today.isoformat()
    news = announcements.recent(conn, days=30, limit=limit, today=today)
    messages = []
    if messages_allowed() and _has(conn, "studip_messages"):
        for r in conn.execute("SELECT id, sender, subject, preview, sent_at, url, dates FROM studip_messages ORDER BY sent_at DESC, id").fetchall():
            try:
                dates = json.loads(r[6] or "[]")
            except ValueError:
                dates = []
            messages.append({"id": r[0], "sender": r[1], "subject": r[2], "preview": r[3], "sent_at": r[4], "url": r[5], "dates": dates})
    activity = []
    if _has(conn, "studip_activity"):
        since = (today - timedelta(days=ACTIVITY_DAYS)).isoformat()
        for r in conn.execute("""SELECT x.id, x.course_id, x.type, x.at, x.url, c.title, m.color FROM studip_activity x
                                 JOIN courses c ON c.id=x.course_id LEFT JOIN modules m ON m.id=c.module_id
                                 WHERE c.active=1 AND substr(x.at, 1, 10) >= ? ORDER BY x.at, x.id""", (since,)).fetchall():
            activity.append({"id": r[0], "course_id": r[1], "type": r[2], "at": r[3], "url": r[4], "course_title": r[5], "color": r[6]})
    from . import studip_blubber
    return feed(news, messages, activity, t, limit, extra=studip_blubber.feed_lines(conn, today))


# ----------------------------------------------------------------------------
# Abruf (am PC mit der angemeldeten Browsersitzung)
# ----------------------------------------------------------------------------

def sync(get, conn, uid: str, base: str, today: date, fetched_at: str) -> dict:
    """Alle Ergaenzungen lesen und speichern. `get(path)` -> (HTTP-Status, JSON oder None), Pfad relativ zu
    jsonapi.php/v1/. Fehlende Endpunkte werden gemerkt; ein Fehler eines Teils laesst die anderen und den Bestand.
    Liefert je Teil die Zahl der gespeicherten Eintraege (fehlt der Teil: nicht gelesen)."""
    from . import studip_terms
    missing = load_missing(conn)
    t = today.isoformat()
    res: dict = {}

    def ask(name: str, *paths: str):
        """Erste Antwort mit Liste `data`; nach 400 (z. B. include unbekannt) der naechste Pfad."""
        nonlocal missing
        if not should_ask(missing, name, t):
            return None
        for p in paths:
            try:
                status, body = get(p)
            except Exception:  # noqa: BLE001 - Netz: Bestand bleibt, beim naechsten Abgleich erneut
                return None
            missing = remember(missing, name, status, t)
            if status == 400:
                continue
            if 200 <= status < 300 and isinstance(body, dict) and isinstance(body.get("data"), list):
                return body
            return None
        return None

    if (b := ask("semesters", "semesters?page[limit]=100")) is not None:
        res["semesters"] = studip_terms.store(conn, "semester", studip_terms.parse_semesters(b["data"]), fetched_at)
    if (b := ask("holidays", "holidays?page[limit]=100")) is not None:
        res["holidays"] = studip_terms.store(conn, "holiday", studip_terms.parse_holidays(b["data"]), fetched_at)
    if (b := ask("studip-news", "studip/news?page[limit]=50")) is not None:
        res["global_news"] = store_global_news(conn, global_news(b["data"], base), fetched_at)["total"]
    if messages_allowed() and (b := ask("inbox", f"users/{uid}/inbox?page[limit]=30&include=sender", f"users/{uid}/inbox?page[limit]=30")) is not None:
        res["messages"] = store_messages(conn, parse_messages(b["data"], b.get("included"), base, today), fetched_at)
    if (b := ask("activitystream", f"users/{uid}/activitystream")) is not None:
        res["activity"] = store_activity(conn, parse_activity(b["data"], base), fetched_at, today)
    if (b := ask("consultations", f"users/{uid}/consultation-bookings?include=slot,slot.block",
                 f"users/{uid}/consultation-bookings")) is not None:
        res["consultations"] = store_consultations(conn, parse_bookings(b["data"], b.get("included")), fetched_at)
    save_missing(conn, missing)
    return res
